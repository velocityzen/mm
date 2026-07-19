import Logging
import MMWire
import Metrics
import NIOConcurrencyHelpers
import NIOCore

/// The bounds of one request stream's inbound element buffer.
///
/// Fixed at the spec's initial-credit window: the client may have at most
/// ``MMStreamFlowControl/initialWindow`` request items outstanding (unconsumed
/// by the handler) at once, and the server grants more credit as the handler
/// drains — watermark-batched, never per item (see ``MMRequestStreamSource``).
extension MMStreamFlowControl {
    /// This server's consumer-side grant policy (local, not a wire constant —
    /// the shared constants live in MMWire): the source accrues consumed
    /// items and emits one additive grant once at least this many have been
    /// consumed since the last grant, so a steady consumer sends one grant
    /// per half-window rather than one per item.
    static let grantWatermark: UInt32 = 4
}

/// The typed, backpressured sequence of request-stream elements handed to a
/// client- or bidirectional-streaming handler.
///
/// Its **normal end** (`next()` returns `nil`) is the graceful client END: the
/// client finished its request direction. The sequence also ends on client
/// CANCEL, connection death, or the terminal — the handler cannot distinguish
/// those from END through this surface (it learns cancellation through task
/// cancellation instead).
///
/// Backed by `NIOAsyncSequenceProducer`, never a bare `AsyncStream`: the buffer
/// is bounded by the credit window (`MMStreamFlowControl.initialWindow`), so
/// a client cannot outrun a slow handler — items past the window would be a
/// credit overrun, which the stream table rejects with a code-6 terminal.
///
/// ## Single consumer
///
/// Exactly one iterator (a second violates the producer's precondition); the
/// handler body iterates it, and each element it pulls advances credit.
public struct MMRequestStream<Element: Codable & Sendable>: AsyncSequence, Sendable {
    typealias Base = NIOAsyncSequenceProducer<
        Element,
        NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
        MMRequestStreamSource<Element>
    >

    let base: Base
    let source: MMRequestStreamSource<Element>

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        let source: MMRequestStreamSource<Element>

        /// The next request element, or `nil` once the client's request
        /// direction has ended (END, CANCEL, connection death, or terminal) and
        /// the buffer is drained. Non-throwing: an element that fails to decode
        /// was already turned into a code-6 stream violation on the producing
        /// side and never reaches here.
        ///
        /// Consuming an element accounts it toward the credit grant: once the
        /// handler has drained a watermark's worth since the last grant, the
        /// source tops the client's window back up (kind 2), so a client
        /// streaming past the initial window is granted more as the handler keeps
        /// up — the grant fires on the *consumption* edge, not only when the
        /// producer buffer happens to hit its high watermark (which a fast
        /// handler never reaches).
        public mutating func next() async -> Element? {
            let element = await self.base.next()
            if element != nil { self.source.didConsume() }
            return element
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: self.base.makeAsyncIterator(), source: self.source)
    }

    /// Server-initiated STOP: asks the client to gracefully finish its request
    /// direction (sends kind 5, code 0). Advisory — the call continues to its
    /// terminal, and items already in flight are still delivered. Idempotent.
    public func stop() async {
        await self.source.requestStop()
    }
}

/// The producer-side state machine for one request stream: it decodes inbound
/// `item` slices to `Element`, yields them into the `NIOAsyncSequenceProducer`,
/// and computes credit grants back to the client as the handler consumes.
///
/// A locked value (not actor state), for the same reason as the client's
/// `CallTable`: the
/// `NIOAsyncSequenceProducerDelegate` callbacks (`produceMore`, `didTerminate`)
/// are synchronous and arrive on arbitrary threads, so they must resolve state
/// without suspending. The lock is never held across a suspension point.
///
/// ## Credit accounting (server is the *receiver* of request items)
///
/// The client begins with ``MMStreamFlowControl/initialWindow`` implicit
/// credits. Each accepted item spends one (`clientCredit -= 1`); an item that
/// arrives at zero client credit is a **credit overrun** — a code-6 violation,
/// which the stream table detects via `hasCreditForItem` before delivery. When
/// the handler drains the producer buffer below its low watermark the delegate's
/// `produceMore` fires: the source grants exactly the *deficit* below the
/// initial window in one additive kind-2 frame (via the grant pump), topping the
/// client's window back up. Granting on the drain edge — never per item — is the
/// watermark-batching policy, and granting only the deficit keeps
/// `clientCredit ≤ initialWindow` so the overrun check stays exact.
///
/// ## No continuations
///
/// This type parks nothing. Consumer-side demand suspension lives entirely in
/// the `NIOAsyncSequenceProducer`; item delivery drops rather than parks once
/// the buffer is full (the credit window guarantees it never fills under a
/// conforming client). Its only outbound effects are credit grants (via the
/// pump) and one idempotent STOP.
final class MMRequestStreamSource<Element: Codable & Sendable>: Sendable {
    typealias Sequence = MMRequestStream<Element>.Base
    typealias Source = Sequence.Source

    /// Emits one outbound frame for this stream (credit grants, STOP) through
    /// the connection's single writer funnel. Returns whether the write landed.
    typealias FrameSink = @Sendable (MMEnvelope) async -> Bool

    private struct State {
        var source: Source?
        var terminated = false
        /// Credits the client still holds — it may send this many more items
        /// before a grant. Starts at the initial window; spent per item,
        /// replenished by grants.
        var clientCredit: UInt32
        /// Items the handler has consumed since the last grant. The consume edge
        /// (`didConsume`) accrues this and, once it crosses the grant watermark,
        /// tops the client's window back up — this is what keeps a client
        /// streaming past the initial window flowing under a fast handler.
        var consumedSinceGrant: UInt32 = 0
        /// Credits computed but not yet written to the wire. The grant pump
        /// drains this into one kind-2 frame per wakeup.
        var pendingGrant: UInt32 = 0
        /// The server already asked the client to stop (kind 5 sent).
        var stopSent = false
    }

    let msgid: UInt32
    private let state: NIOLockedValueBox<State>
    private let frameSink: FrameSink
    /// Coalesced "grant may be due" nudges to the pump loop. Dropping duplicate
    /// nudges is correct: the pump reads the exact `pendingGrant` amount, so one
    /// wakeup can flush several accrued grants — the sanctioned `AsyncStream`
    /// use (a wake-up signal, not a data channel).
    private let grantNudge: AsyncStream<Void>.Continuation
    let grantNudges: AsyncStream<Void>
    private let metrics: MMStreamMetrics

    init(
        msgid: UInt32,
        frameSink: @escaping FrameSink,
        metrics: MMStreamMetrics
    ) {
        self.msgid = msgid
        self.state = NIOLockedValueBox(
            State(source: nil, clientCredit: MMStreamFlowControl.initialWindow)
        )
        self.frameSink = frameSink
        self.metrics = metrics
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.grantNudges = stream
        self.grantNudge = continuation
    }

    /// Installs the producer source after `makeSequence` (the delegate must
    /// exist before the source). Called exactly once, before any item arrives.
    func adopt(source: Source) {
        self.state.withLockedValue { $0.source = source }
    }

    /// Whether accepting one more item is within the client's current credit.
    /// The stream table calls this under its own lock *before* `deliver`, so the
    /// overrun decision and the acceptance are one atomic step. Pure credit —
    /// termination is a separate question (``isTerminated``) so a terminated
    /// source's in-flight item is a drop, not a spurious overrun.
    func hasCreditForItem() -> Bool {
        self.state.withLockedValue { $0.clientCredit > 0 }
    }

    /// Whether the source has terminated (handler returned / stopped consuming /
    /// terminal / CANCEL / connection death). The stream table checks this
    /// before the credit check so an item racing termination is a tolerated
    /// late-drop rather than a violation.
    func isTerminated() -> Bool {
        self.state.withLockedValue { $0.terminated }
    }

    /// Decodes and yields one request item, spending one client credit (the
    /// caller has already confirmed `hasCreditForItem`). A decode failure is a
    /// stream violation surfaced to the caller (which sends the code-6
    /// terminal); the element is dropped.
    func deliver(_ item: ByteBuffer) -> Result<Void, MMWireError> {
        let decoded: Element
        switch MMPackDecoder().decode(Element.self, from: item) {
            case .failure(let error):
                return .failure(error)
            case .success(let value):
                decoded = value
        }
        let source = self.state.withLockedValue { state -> Source? in
            guard !state.terminated, let source = state.source else { return nil }
            state.clientCredit &-= 1
            return source
        }
        guard let source else { return .success(()) }
        self.metrics.itemsIn.increment()
        // Yield outside the lock; the source is internally synchronized.
        _ = source.yield(decoded)
        return .success(())
    }

    /// Client END for the request direction: finish the sequence cleanly
    /// (buffered items still drain to the handler, then `next()` returns nil).
    /// Idempotent.
    func finishFromEnd() {
        self.terminate()?.finish()
    }

    /// Terminal / CANCEL / connection death: finish the sequence so the
    /// handler's consumption loop ends. Idempotent.
    func finishFromTerminal() {
        self.terminate()?.finish()
    }

    private func terminate() -> Source? {
        let source = self.state.withLockedValue { state -> Source? in
            state.terminated = true
            let source = state.source
            state.source = nil
            return source
        }
        // Wake the pump so it observes termination and exits.
        self.grantNudge.yield(())
        self.grantNudge.finish()
        return source
    }

    /// Server-initiated STOP. Sends kind 5 (code 0) once; the call continues.
    fileprivate func requestStop() async {
        let shouldSend = self.state.withLockedValue { state -> Bool in
            guard !state.stopSent, !state.terminated else { return false }
            state.stopSent = true
            return true
        }
        guard shouldSend else { return }
        self.metrics.stopsOut.increment()
        _ = await self.frameSink(.stop(msgid: self.msgid, code: 0))
    }

    /// The handler consumed one request element (its iterator returned an item).
    /// Accrue it toward the credit grant; once a full watermark has been drained
    /// since the last grant, top the client's window back up to the initial
    /// window in one additive kind-2 frame (the deficit) and nudge the pump.
    ///
    /// This is the primary grant trigger — it fires whenever the handler keeps up
    /// (the common, fast-handler case), independent of whether the producer
    /// buffer ever reaches its high watermark. `produceMore` remains a secondary
    /// trigger for the parked-then-drains case (a handler that fills the window
    /// before consuming). Granting exactly the deficit keeps
    /// `clientCredit ≤ initialWindow`, so the overrun check stays exact and the
    /// two triggers can never over-grant past the window.
    func didConsume() {
        let due = self.state.withLockedValue { state -> Bool in
            guard !state.terminated else { return false }
            state.consumedSinceGrant &+= 1
            guard state.consumedSinceGrant >= MMStreamFlowControl.grantWatermark else {
                return false
            }
            state.consumedSinceGrant = 0
            let deficit = Self.windowDeficit(state)
            guard deficit > 0 else { return false }
            Self.applyDeficitGrant(&state, deficit)
            return true
        }
        if due {
            self.grantNudge.yield(())
        }
    }

    /// How far the window is from full — the top-up amount both triggers use.
    private static func windowDeficit(_ state: State) -> UInt32 {
        MMStreamFlowControl.initialWindow - state.clientCredit
    }

    /// The one over-grant-proof top-up: refill the window and accrue the
    /// pending additive grant, always by the same deficit.
    private static func applyDeficitGrant(_ state: inout State, _ deficit: UInt32) {
        state.clientCredit &+= deficit
        state.pendingGrant &+= deficit
    }

    // MARK: - Grant pump

    /// Drains accrued credit grants and writes them as additive kind-2 frames,
    /// one per wakeup batch. Run as a structured child task by the stream handle
    /// for the stream's lifetime; it ends when the nudge stream finishes (on
    /// termination). Not a free-floating task — the handle owns it.
    func runGrantPump() async {
        for await _ in self.grantNudges {
            let amount = self.state.withLockedValue { state -> UInt32 in
                let amount = state.pendingGrant
                state.pendingGrant = 0
                return amount
            }
            guard amount > 0 else { continue }
            self.metrics.creditGrantsOut.increment()
            _ = await self.frameSink(.credit(msgid: self.msgid, credits: amount))
        }
        // Flush any last batch accrued between the final nudge and finish.
        let tail = self.state.withLockedValue { state -> UInt32 in
            let amount = state.pendingGrant
            state.pendingGrant = 0
            return amount
        }
        if tail > 0 {
            self.metrics.creditGrantsOut.increment()
            _ = await self.frameSink(.credit(msgid: self.msgid, credits: tail))
        }
    }
}

extension MMRequestStreamSource: NIOAsyncSequenceProducerDelegate {
    /// The consumer drained the producer buffer below its low watermark — the
    /// handler has made room for more request items. Secondary grant trigger: it
    /// covers the case where a handler fills the whole window before consuming
    /// (the buffer reaches the high watermark, so this backpressure edge fires
    /// once it drains). The common fast-handler case is granted on the
    /// consumption edge (``didConsume``) instead, which fires whether or not the
    /// buffer ever reaches the high watermark. Tops the client's window back up
    /// in one additive grant (the *deficit*) and nudges the pump. Synchronous:
    /// the actual wire write happens on the pump task, never here.
    ///
    /// Granting exactly the deficit keeps `clientCredit ≤ initialWindow` by
    /// construction, so the accounting can never over-grant past the window and
    /// the overrun check (`hasCreditForItem`) stays exact — and because both
    /// triggers grant only the deficit, whichever fires first drives the window
    /// to full and the other computes a zero deficit (a no-op), so they can never
    /// double-grant.
    func produceMore() {
        let due = self.state.withLockedValue { state -> Bool in
            guard !state.terminated else { return false }
            let deficit = Self.windowDeficit(state)
            guard deficit >= MMStreamFlowControl.grantWatermark else { return false }
            Self.applyDeficitGrant(&state, deficit)
            // Reset the consume-edge accumulator: the window is now full, so the
            // consume trigger should re-arm from zero rather than double-grant.
            state.consumedSinceGrant = 0
            return true
        }
        if due {
            self.grantNudge.yield(())
        }
    }

    /// The handler stopped consuming (returned, or its task was cancelled).
    /// Mark terminated so a racing `deliver` drops; the stream table drives the
    /// rest of teardown.
    func didTerminate() {
        _ = self.terminate()
    }
}
