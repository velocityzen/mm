import NIOCore
import NIOPosix
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// The reading side of an ``MMCLIInput``: one blocking `read(2)` at a time
/// on NIO's singleton thread pool. The awaiting task races the read against
/// an interrupt and its own cancellation, so a read parked on a terminal or
/// an idle pipe never holds the command up. The abandoned read finishes on
/// its pool thread and its bytes are dropped. The command is ending anyway.
final class MMCLIInputReader: Sendable {
    enum Outcome: Sendable {
        case chunk([UInt8])
        case end
        case failed(reason: String)
    }

    private struct State {
        var interrupted = false
        var parked: MMCLIResumeOnce<Outcome>?
        var inFlight: EventLoopFuture<Outcome>?
    }

    /// The most one read returns.
    static let chunkCapacity = 64 * 1024

    private let state = Mutex(State())

    var isInterrupted: Bool {
        self.state.withLock { $0.interrupted }
    }

    /// Whether a read is waiting for input (a test seam).
    var hasParkedRead: Bool {
        self.state.withLock { $0.parked != nil }
    }

    /// Ends reading: the parked read, if any, returns `.end` at once, and so
    /// does every later one.
    func interrupt() {
        let parked = self.state.withLock { state -> MMCLIResumeOnce<Outcome>? in
            state.interrupted = true
            defer { state.parked = nil }
            return state.parked
        }
        parked?.resume(with: .end)
    }

    /// Reads the next chunk from `descriptor`.
    func nextChunk(from descriptor: CInt) async -> Outcome {
        let cell = MMCLIResumeOnce<Outcome>()
        let started = self.state.withLock { state -> EventLoopFuture<Outcome>? in
            guard !state.interrupted else { return nil }
            let read = NIOThreadPool.singleton.runIfActive(
                eventLoop: NIOSingletons.posixEventLoopGroup.any()
            ) {
                Self.blockingRead(descriptor)
            }
            state.parked = cell
            state.inFlight = read
            return read
        }
        guard let started else { return .end }
        started.whenComplete { result in
            switch result {
                case .success(let outcome):
                    cell.resume(with: outcome)
                case .failure(let error):
                    cell.resume(with: .failed(reason: "\(error)"))
            }
        }
        let outcome = await withTaskCancellationHandler {
            await cell.value()
        } onCancel: {
            cell.resume(with: .end)
        }
        self.state.withLock { $0.parked = nil }
        return outcome
    }

    /// Waits for an abandoned read still running on the pool, so the
    /// descriptor can be closed under no one.
    func settle() async {
        let inFlight = self.state.withLock { $0.inFlight }
        _ = try? await inFlight?.get()
    }

    private static func blockingRead(_ descriptor: CInt) -> Outcome {
        var failure: CInt = 0
        let bytes = [UInt8](unsafeUninitializedCapacity: Self.chunkCapacity) { buffer, initialized in
            var count: Int
            repeat {
                count = read(descriptor, buffer.baseAddress, buffer.count)
            } while count < 0 && errno == EINTR
            if count < 0 {
                failure = errno
            }
            initialized = max(count, 0)
        }
        guard failure == 0 else {
            return .failed(reason: String(cString: strerror(failure)))
        }
        return bytes.isEmpty ? .end : .chunk(bytes)
    }
}

/// A one-shot rendezvous: the first of several racing outcomes resumes the
/// one waiter, and later ones are dropped. An outcome that arrives before the
/// waiter parks is kept and handed over when it does.
final class MMCLIResumeOnce<Value: Sendable>: Sendable {
    private enum State {
        case initial
        case parked(CheckedContinuation<Value, Never>)
        case pending(Value)
        case done
    }

    private let state = Mutex(State.initial)

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let immediate = self.state.withLock { current -> Value? in
                switch current {
                    case .initial:
                        current = .parked(continuation)
                        return nil
                    case .pending(let value):
                        current = .done
                        return value
                    case .parked, .done:
                        preconditionFailure("MMCLIResumeOnce awaited twice")
                }
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func resume(with value: Value) {
        let parked = self.state.withLock { current -> CheckedContinuation<Value, Never>? in
            switch current {
                case .initial:
                    current = .pending(value)
                    return nil
                case .parked(let continuation):
                    current = .done
                    return continuation
                case .pending, .done:
                    return nil
            }
        }
        parked?.resume(returning: value)
    }
}
