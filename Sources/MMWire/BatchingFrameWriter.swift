import NIOCore
import Synchronization

/// Writes one connection's frames for any number of concurrent senders,
/// several frames to a write.
///
/// A sender that finds nobody writing becomes the writer: it writes its own
/// frame, then every frame other senders queued meanwhile, each batch with
/// one `write(contentsOf:)`, until the queue is empty. One pass through the
/// outbound writer's lock and one hop to the event loop then carry a whole
/// batch. A sender that finds a writer at work queues its frame and returns
/// at once, without suspending. Frames go out in the order they were queued,
/// so one sender's frames keep their order.
///
/// ## Backpressure
///
/// Only the writer waits for the channel: a write suspends while the
/// channel is not writable. Senders that queue behind it return at once, so
/// the queue is bounded by what the connection lets its senders have in
/// flight (the in-flight caps and the streams' credit), not by the channel.
///
/// ## Results
///
/// `.success` means the frame was written or queued, not that it reached
/// the socket: a write into the channel never meant that either. Frames
/// still queued when the channel goes are dropped, and every later write
/// fails with `.channelClosed`.
///
/// ## Cancellation and the stand-by task
///
/// The outbound writer refuses a write from a cancelled task with
/// `CancellationError`, without writing anything. A sender cancelled before
/// it writes or queues fails at once with `.cancelled`. A writer whose task
/// is cancelled mid-write puts the frames it took back at the front of the
/// queue, its own frame excepted (that send fails with `.cancelled`), and
/// hands them to ``standBy()``: a task that lives as long as the connection
/// and does nothing else. It writes them, and whatever queues behind them,
/// so a queued frame is never left without a writer.
package final class BatchingFrameWriter: Sendable {
    /// Why a frame was not written.
    package enum Failure: Error, Sendable, Equatable {
        /// The sending task was cancelled. Nothing was written, and the
        /// channel is fine.
        case cancelled
        /// The channel is gone.
        case channelClosed
    }

    private struct State {
        /// Someone is writing: the sender that became the writer, or the
        /// stand-by task.
        var writing = false
        var queued: [ByteBuffer] = []
        var closed = false
        /// A cancelled writer handed the writing on while the stand-by task
        /// was not parked.
        var handedOn = false
        var finished = false
        /// The parked stand-by task: resumed with `true` to take over the
        /// writing, with `false` to end.
        var standingBy: CheckedContinuation<Bool, Never>?
    }

    /// How a run of batch writes ended.
    private enum WritingEnd {
        /// The queue is empty and the writing has ended.
        case emptied
        /// The writer's task was cancelled: the frames it held are back at
        /// the front of the queue, and the stand-by task has the writing.
        case cancelled(inFirstBatch: Bool)
        /// The channel is gone.
        case channelClosed(inFirstBatch: Bool)
    }

    private let writeBatch: @Sendable ([ByteBuffer]) async throws -> Void
    private let state = Mutex(State())

    /// A writer over a channel's outbound writer.
    package convenience init(outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        self.init { batch in try await outbound.write(contentsOf: batch) }
    }

    /// A writer over any batch write that, like the outbound writer, throws
    /// `CancellationError` for a cancelled task, having written nothing,
    /// and anything else once the channel is gone.
    package init(writing writeBatch: @escaping @Sendable ([ByteBuffer]) async throws -> Void) {
        self.writeBatch = writeBatch
    }

    /// Writes `frame`, or queues it behind the writer at work.
    package func write(_ frame: ByteBuffer) async -> Result<Void, Failure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let writesNow = self.state.withLock { state -> Result<Bool, Failure> in
            guard !state.closed else { return .failure(.channelClosed) }
            guard !state.writing else {
                state.queued.append(frame)
                return .success(false)
            }
            state.writing = true
            return .success(true)
        }
        switch writesNow {
            case .failure(let failure):
                return .failure(failure)
            case .success(false):
                return .success(())
            case .success(true):
                // The writer's own frame is the first batch's first: only
                // a failure of that batch is this send's failure.
                switch await self.writeUntilEmpty(startingWith: [frame], ownFrameFirst: true) {
                    case .emptied:
                        return .success(())
                    case .cancelled(let inFirstBatch):
                        return inFirstBatch ? .failure(.cancelled) : .success(())
                    case .channelClosed(let inFirstBatch):
                        return inFirstBatch ? .failure(.channelClosed) : .success(())
                }
        }
    }

    /// Stands by for the frames a cancelled writer leaves, and writes them
    /// and whatever queues behind them. Runs for the connection's lifetime,
    /// as a structured child of it, and returns after ``finish()``, having
    /// closed the writer: with nobody left to stand by, every later write
    /// fails with `.channelClosed`.
    package func standBy() async {
        while await self.awaitHandOn() {
            // Taking the queue and ending the writing are one step: a frame
            // queued between them would find the writing taken, and nobody
            // left to write it.
            let batch = self.state.withLock { state in
                let batch = state.queued
                state.queued.removeAll(keepingCapacity: true)
                if batch.isEmpty { state.writing = false }
                return batch
            }
            guard !batch.isEmpty else { continue }
            if case .cancelled = await self.writeUntilEmpty(
                startingWith: batch,
                ownFrameFirst: false
            ) {
                // The stand-by task itself was cancelled: the connection is
                // ending, and nothing is left to write its frames.
                self.close()
                return
            }
        }
        self.close()
    }

    /// Ends ``standBy()`` once it has written what it holds: the connection
    /// is ending.
    package func finish() {
        let standingBy = self.state.withLock { state in
            state.finished = true
            let standingBy = state.standingBy
            state.standingBy = nil
            return standingBy
        }
        standingBy?.resume(returning: false)
    }

    /// Parks the stand-by task until a cancelled writer hands it the
    /// writing (`true`) or ``finish()`` ends it (`false`).
    private func awaitHandOn() async -> Bool {
        await withCheckedContinuation { continuation in
            let now = self.state.withLock { state -> Bool? in
                if state.handedOn {
                    state.handedOn = false
                    return true
                }
                if state.finished { return false }
                state.standingBy = continuation
                return nil
            }
            if let now { continuation.resume(returning: now) }
        }
    }

    /// Writes `first`, then each batch that queued meanwhile, until the
    /// queue is empty, and ends the writing.
    private func writeUntilEmpty(
        startingWith first: [ByteBuffer],
        ownFrameFirst: Bool
    ) async -> WritingEnd {
        var batch = first
        var inFirstBatch = true
        while true {
            do {
                try await self.writeBatch(batch)
            } catch is CancellationError {
                // Nothing was written. The frames go back first in line, the
                // writer's own excepted, and the stand-by task takes over.
                self.handOn(ownFrameFirst && inFirstBatch ? Array(batch.dropFirst()) : batch)
                return .cancelled(inFirstBatch: inFirstBatch)
            } catch {
                self.close()
                return .channelClosed(inFirstBatch: inFirstBatch)
            }
            batch = self.state.withLock { state in
                let next = state.queued
                state.queued.removeAll(keepingCapacity: true)
                if next.isEmpty { state.writing = false }
                return next
            }
            if batch.isEmpty { return .emptied }
            inFirstBatch = false
        }
    }

    /// Puts `frames` back at the front of the queue and wakes the stand-by
    /// task to write them. The writing stays taken: it passes to that task.
    /// Once the writer is closed, the frames are dropped.
    private func handOn(_ frames: [ByteBuffer]) {
        let standingBy = self.state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard !state.closed else { return nil }
            state.queued.insert(contentsOf: frames, at: 0)
            guard let standingBy = state.standingBy else {
                state.handedOn = true
                return nil
            }
            state.standingBy = nil
            return standingBy
        }
        standingBy?.resume(returning: true)
    }

    /// The channel is gone: drops what is queued, and every later write
    /// fails.
    private func close() {
        self.state.withLock { state in
            state.closed = true
            state.writing = false
            state.queued.removeAll()
        }
    }
}
