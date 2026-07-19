import MMWire
import Metrics
import NIOConcurrencyHelpers
import NIOCore

/// The outbound half of a server response stream, handed to server- and
/// bidirectional-streaming handlers. The handler pushes elements with ``send(_:)``; the
/// call is otherwise closed by returning the handler's terminal `Result`.
///
/// ## Flow control (server is the *sender* of response items)
///
/// The server begins with `MMStreamFlowControl.initialWindow` implicit
/// credits — it may send that many items before any grant. Each accepted send
/// spends one credit; at zero credit ``send(_:)`` **suspends** until the client
/// grants more (additive kind-2 frames), so a slow consumer parks the producing
/// task and memory stays bounded by the window. No head-of-line blocking: a
/// stalled response stream starves only itself.
///
/// ## Outcomes
///
/// Every ``send(_:)`` returns a ``StreamSendOutcome`` — all graceful:
/// `.sent` keep going, `.peerStopped` the client asked you to wrap up (the item
/// just passed was NOT delivered — the sink drops it once STOP is observed),
/// `.callEnded` the call is already over (the item was not delivered).
public struct MMResponseSink<Element: Codable & Sendable>: Sendable {
    let state: MMResponseSinkState

    /// Encodes and enqueues one response element, suspending at zero credit
    /// until the client grants more. See ``MMResponseSink`` for the outcomes.
    ///
    /// An element that fails to encode is a server-side programmer error
    /// (an `Element` whose `Encodable` conformance throws). The stream cannot
    /// continue past a frame it could not serialize, so the sink is marked ended
    /// and `.callEnded` is reported; the handler then wraps up and returns its
    /// terminal. The element is not delivered.
    public func send(_ element: Element) async -> StreamSendOutcome {
        let item: ByteBuffer
        switch MMPackEncoder().encode(element) {
            case .failure:
                self.state.end()
                return .callEnded
            case .success(let encoded):
                item = encoded
        }
        return await self.state.send(item)
    }

    /// Suspends until the client asks this response direction to STOP (or the
    /// call ends). ``send(_:)`` already reports a STOP as `.peerStopped` — this
    /// is for handlers relaying a **quiet** source, whose next send may be
    /// arbitrarily far away: watch from a structured sibling and release
    /// whatever the relay is parked on, so the terminal goes out promptly
    /// instead of on the source's next event. Returns immediately when the
    /// STOP (or the end) already happened, and on task cancellation — the
    /// normal release when the relay ends first and cancels its watcher.
    public func stopRequested() async {
        await self.state.stopRequested()
    }
}

/// The credit-gated send state machine behind ``MMResponseSink``.
///
/// A locked value (not actor state): the credit-grant and terminal paths must
/// resolve the parked sender synchronously from the connection's frame-routing
/// path and its teardown, neither of which can suspend. The lock is never held
/// across a suspension point — `send` computes its action under the lock, then
/// suspends (or writes) outside it.
///
/// ## Single-resume audit
///
/// At most one sender parks at a time: ``send(_:)`` is called from the single
/// handler task, serially. The parked continuation lives only in `parked`, and
/// every transition that produces it removes it in the same locked mutation:
/// `grant` (credit arrived → resume `.proceed`), `peerStop` (client STOP →
/// resume `.stopped`), and `end` (terminal/cancel/death → resume `.ended`).
/// A grant or stop that races the park is folded into `pendingGrant` /
/// `stopped` and observed by the next park attempt, so no wakeup is lost and no
/// continuation is resumed twice.
///
/// `stopRequested()` watchers park separately in `stopWaiters` (any number,
/// keyed): each is resumed exactly once by STOP, by end, or by its own
/// cancellation — the register↔cancel race is made deterministic by the
/// `cancelledStopWaiters` tombstone, mirroring the client-side park utility.
final class MMResponseSinkState: Sendable {
    /// Emits one outbound item frame through the connection's single writer
    /// funnel. Returns whether the write landed (false ⇒ the connection died).
    typealias ItemSink = @Sendable (_ seq: UInt32, _ item: ByteBuffer) async -> Bool

    /// What `send` should do after inspecting state under the lock.
    private enum SendAction {
        /// Credit available and consumed; write the item at this seq, outside
        /// the lock.
        case write(seq: UInt32)
        /// The client asked to stop; the item is dropped, report `.peerStopped`.
        case peerStopped
        /// The call is over; the item is dropped, report `.callEnded`.
        case callEnded
        /// No credit; park on this continuation (installed under the lock).
        case park
    }

    /// The resolution a parked sender wakes with.
    private enum ParkResolution: Sendable {
        case proceed(seq: UInt32)
        case stopped
        case ended
    }

    private struct State {
        /// Credits the server still holds — it may send this many more items
        /// before parking. Starts at the initial window; spent per item,
        /// replenished by client grants.
        var serverCredit: UInt32
        /// Next outbound item seq, u32 from 0, server-stamped.
        var nextSeq: UInt32 = 0
        /// The client sent STOP for this direction; every send from now reports
        /// `.peerStopped` (in-flight sends still delivered). Sticky.
        var peerStopped = false
        /// The call ended (terminal/cancel/death); every send reports
        /// `.callEnded`. Sticky.
        var ended = false
        /// A grant that arrived while no sender was parked, folded in for the
        /// next park attempt so a racing grant is never lost.
        var parked: CheckedContinuation<ParkResolution, Never>?
        /// Handlers parked in `stopRequested()`, keyed so a cancelled watcher
        /// removes exactly itself. All resumed on STOP and on end.
        var stopWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        /// Watchers whose cancellation ran before their park installed
        /// (the register↔cancel race): the tombstone makes the register step
        /// resume immediately instead of parking unresumable.
        var cancelledStopWaiters: Set<UInt64> = []
        /// Key generator for `stopWaiters` / `cancelledStopWaiters`.
        var nextStopWaiterID: UInt64 = 0
    }

    let msgid: UInt32
    private let state = NIOLockedValueBox(State(serverCredit: MMStreamFlowControl.initialWindow))
    private let itemSink: ItemSink
    private let metrics: MMStreamMetrics

    init(
        msgid: UInt32,
        itemSink: @escaping ItemSink,
        metrics: MMStreamMetrics
    ) {
        self.msgid = msgid
        self.itemSink = itemSink
        self.metrics = metrics
    }

    /// Encodes-then-sends path: enqueue one already-encoded item, gating on
    /// credit. Loops across a single park: at zero credit it suspends once,
    /// then re-decides on the resolution.
    func send(_ item: ByteBuffer) async -> StreamSendOutcome {
        while true {
            let action: SendAction = self.state.withLockedValue { state in
                if state.ended { return .callEnded }
                if state.peerStopped { return .peerStopped }
                if state.serverCredit > 0 {
                    state.serverCredit &-= 1
                    let seq = state.nextSeq
                    state.nextSeq &+= 1
                    return .write(seq: seq)
                }
                return .park
            }
            switch action {
                case .write(let seq):
                    let landed = await self.itemSink(seq, item)
                    if landed {
                        self.metrics.itemsOut.increment()
                        return .sent
                    }
                    // The write failed (connection gone). Mark ended so subsequent
                    // sends short-circuit, and report it.
                    self.markEnded()
                    return .callEnded
                case .peerStopped:
                    return .peerStopped
                case .callEnded:
                    return .callEnded
                case .park:
                    self.metrics.creditStalls.increment()
                    let resolution = await self.parkForCredit()
                    switch resolution {
                        case .proceed(let seq):
                            let landed = await self.itemSink(seq, item)
                            if landed {
                                self.metrics.itemsOut.increment()
                                return .sent
                            }
                            self.markEnded()
                            return .callEnded
                        case .stopped:
                            return .peerStopped
                        case .ended:
                            return .callEnded
                    }
            }
        }
    }

    /// Suspends until a grant, STOP, or terminal resolves the park. On the
    /// `.proceed` resolution the resolver has already spent one credit and
    /// stamped the seq, so the caller writes directly without re-checking.
    private func parkForCredit() async -> ParkResolution {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<ParkResolution, Never>) in
            let immediate: ParkResolution? = self.state.withLockedValue { state in
                if state.ended { return .ended }
                if state.peerStopped { return .stopped }
                if state.serverCredit > 0 {
                    state.serverCredit &-= 1
                    let seq = state.nextSeq
                    state.nextSeq &+= 1
                    return .proceed(seq: seq)
                }
                state.parked = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    /// A client credit grant (kind 2): add credits and, if a sender is parked,
    /// spend one immediately and resume it with a stamped seq; otherwise the
    /// added credit waits for the next `send`.
    func grant(_ credits: UInt32) {
        let resume = self.state.withLockedValue {
            state -> (CheckedContinuation<ParkResolution, Never>, ParkResolution)? in
            guard !state.ended else { return nil }
            state.serverCredit &+= credits
            guard let continuation = state.parked, state.serverCredit > 0 else { return nil }
            state.parked = nil
            state.serverCredit &-= 1
            let seq = state.nextSeq
            state.nextSeq &+= 1
            return (continuation, .proceed(seq: seq))
        }
        if let (continuation, resolution) = resume {
            continuation.resume(returning: resolution)
        }
    }

    /// Client STOP (kind 5) for the response direction: mark sticky, resume
    /// any parked sender with `.stopped`, and release every `stopRequested()`
    /// watcher. Idempotent.
    func peerStop() {
        let (sender, watchers) = self.state.withLockedValue {
            state -> (
                CheckedContinuation<ParkResolution, Never>?,
                [CheckedContinuation<Void, Never>]
            ) in
            state.peerStopped = true
            let parked = state.parked
            state.parked = nil
            let waiters = Array(state.stopWaiters.values)
            state.stopWaiters.removeAll()
            return (parked, waiters)
        }
        sender?.resume(returning: .stopped)
        for watcher in watchers {
            watcher.resume()
        }
    }

    /// Terminal / CANCEL / connection death: mark ended, resume any parked
    /// sender with `.ended`, and release every `stopRequested()` watcher (a
    /// call that is over can never be stopped — waiting on would park
    /// forever). Idempotent.
    func end() {
        self.markEnded()
    }

    /// The `stopRequested()` park: register-or-immediate under the state lock,
    /// with a synchronous cancel hand-off (the same single-resume discipline as
    /// the sender park — exactly one of register / STOP-or-end / cancel touches
    /// the continuation).
    func stopRequested() async {
        let id = self.state.withLockedValue { state -> UInt64 in
            defer { state.nextStopWaiterID &+= 1 }
            return state.nextStopWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let immediate: Bool = self.state.withLockedValue { state in
                    if state.peerStopped || state.ended { return true }
                    if state.cancelledStopWaiters.remove(id) != nil { return true }
                    state.stopWaiters[id] = continuation
                    return false
                }
                if immediate {
                    continuation.resume()
                }
            }
        } onCancel: {
            let continuation = self.state.withLockedValue {
                state -> CheckedContinuation<Void, Never>? in
                if let parked = state.stopWaiters.removeValue(forKey: id) {
                    return parked
                }
                state.cancelledStopWaiters.insert(id)
                return nil
            }
            continuation?.resume()
        }
    }

    private func markEnded() {
        let (sender, watchers) = self.state.withLockedValue {
            state -> (
                CheckedContinuation<ParkResolution, Never>?,
                [CheckedContinuation<Void, Never>]
            ) in
            state.ended = true
            let parked = state.parked
            state.parked = nil
            let waiters = Array(state.stopWaiters.values)
            state.stopWaiters.removeAll()
            return (parked, waiters)
        }
        sender?.resume(returning: .ended)
        for watcher in watchers {
            watcher.resume()
        }
    }
}
