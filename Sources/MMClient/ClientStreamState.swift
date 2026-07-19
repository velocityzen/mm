import Logging
import MMWire
import NIOConcurrencyHelpers
import NIOCore

/// The per-msgid streaming state machine on the client, the streaming analogue
/// of a unary call's ``CallTable`` continuation. One instance backs one live
/// stream call; it owns three independent surfaces plus the terminal, all
/// serialized by a single `NIOLockedValueBox` (a lock, not an actor, for the
/// same reason as ``CallTable``: the
/// `NIOAsyncSequenceProducer` delegate callbacks and task-cancellation handlers
/// are synchronous and must resolve parked continuations without suspending).
///
/// ## The four surfaces
///
/// 1. **Inbound elements** (response direction) — an `NIOAsyncSequenceProducer`
///    whose delegate is this object. The inbound loop yields items via
///    ``deliverInboundItem(_:)`` and parks on ``awaitInboundDemand()`` when the
///    buffer fills. As the *consumer* drains (via the handle's iterator), this
///    object grants credit back to the server watermark-batched.
/// 2. **Outbound credit gate** (request direction) — ``send(_:)`` stamps a seq,
///    consumes one credit, and suspends at zero credit until ``grantOutbound``
///    resumes it. STOP flips it to `.peerStopped`; death to `.connectionClosed`.
/// 3. **Terminal** — a replay-once cache: every awaiter of ``result()`` gets the
///    same resolved value; the terminal resolves exactly once across the
///    terminal frame, cancel, connection death, and protocol violation.
/// 4. **Control frames out** (STOP, END, CANCEL, credit) — written through the
///    ``ClientStreamSinks`` closures the connection installs.
///
/// ## Single-resume audit
///
/// Three continuation kinds live here; each is removed from state in the same
/// locked mutation that resumes it:
///
/// - **inbound park** (`State.inboundParked`): resumed by `produceMore`,
///   `didTerminate`, `serverEndInbound`, terminal/fail/cancel, and the cancel
///   handler of `awaitInboundDemand`; the sticky `inboundParkCancelled` /
///   `demandAvailable` flags cover the register↔signal races.
/// - **outbound sender park** (`State.senderParked`): at most one sender parks
///   at a time — the request direction is driven by one task, and `parkSender`
///   enforces it with a precondition (a concurrent same-direction `send` traps
///   rather than silently overwriting the parked continuation). Resumed by
///   `grantOutbound`, `serverStop`, terminal/fail/cancel, and the send's own
///   cancel handler. Sticky `senderParkCancelled` covers the register↔cancel
///   race; the send gate re-reads it and returns `.callEnded` so a cancelled
///   parked sender exits deterministically instead of re-parking.
/// - **terminal awaiters** (`State.terminalAwaiters`): all resumed (and cleared)
///   in the one mutation that transitions `terminalState` from `.pending` to
///   `.resolved`; late awaiters read the cached `.resolved` value and resume
///   themselves immediately.
final class ClientStreamState<
    Inbound: Codable & Sendable,
    Outbound: Codable & Sendable,
    Response: Codable & Sendable
>: Sendable {
    typealias TerminalOutcome = Result<Response, MMCallError>

    typealias Producer = NIOAsyncSequenceProducer<
        Inbound,
        NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
        ClientStreamState<Inbound, Outbound, Response>
    >
    typealias Source = Producer.Source

    /// The terminal's replay-once lifecycle.
    private enum TerminalState {
        /// No terminal yet; awaiters have registered continuations.
        case pending([CheckedContinuation<TerminalOutcome, Never>])
        /// Resolved; the cached value is replayed to every future awaiter.
        case resolved(TerminalOutcome)
    }

    private struct State {
        // Inbound (response) direction.
        var source: Source?
        /// The consumer-facing sequence, vended exactly once through
        /// `makeInboundIterator()`; nil after it is taken.
        var sequence: Producer?
        var inboundEnded = false
        /// Next inbound item seq expected, u32 from 0, validated strictly.
        var expectedInSeq: UInt32 = 0
        /// Producer buffer drained below low watermark while no producer was
        /// parked; consumed by the next park so a demand signal racing the park
        /// is never lost.
        var demandAvailable = false
        var inboundParked: CheckedContinuation<Void, Never>?
        /// The inbound loop's task was cancelled: future parks pass through so
        /// the loop can unwind. Sticky.
        var inboundParkCancelled = false
        /// Items the consumer has drained since the last credit grant, for the
        /// watermark-batched grant.
        var consumedSinceGrant: UInt32 = 0

        // Outbound (request) direction.
        var outboundCredit: UInt32
        var nextOutSeq: UInt32 = 0
        /// The client sent its own END; further sends return `.callEnded`.
        var outboundEnded = false
        /// The server sent STOP for our request direction; sends return
        /// `.peerStopped`.
        var peerStopped = false
        var senderParked: CheckedContinuation<Void, Never>?
        var senderParkCancelled = false

        // Terminal.
        var terminalState: TerminalState = .pending([])
        /// Set once the terminal resolves, so the outbound gate stops sending.
        var terminated = false
        /// The terminal resolved because the connection died (as opposed to a
        /// graceful terminal frame / END / local cancel). A sender released by
        /// death re-reads the gate and must observe `.connectionClosed`, not
        /// `.callEnded` — matching an in-flight send's outcome and the
        /// termination matrix's "connection death → `.connectionClosed`" row.
        var connectionClosed = false

        init(outboundCredit: UInt32) {
            self.outboundCredit = outboundCredit
        }
    }

    let msgid: UInt32
    let hasResponseStream: Bool
    let hasRequestStream: Bool
    private let state: NIOLockedValueBox<State>
    private let sinks: ClientStreamSinks
    private let logger: Logger
    private let metrics: ClientMetrics

    init(
        msgid: UInt32,
        hasResponseStream: Bool,
        hasRequestStream: Bool,
        sinks: ClientStreamSinks,
        logger: Logger,
        metrics: ClientMetrics
    ) {
        self.msgid = msgid
        self.hasResponseStream = hasResponseStream
        self.hasRequestStream = hasRequestStream
        // The client's outbound direction opens with the initial window of
        // credit (the server grants itself the same window for the response
        // direction). A stream with no request direction never sends items, so
        // its credit is irrelevant; keep it at the window for uniformity.
        self.state = NIOLockedValueBox(State(outboundCredit: MMStreamFlowControl.initialWindow))
        self.sinks = sinks
        self.logger = logger
        self.metrics = metrics
    }

    /// Installs the producer source and its consumer sequence after
    /// `makeSequence` (the delegate must exist before the source). Called once,
    /// before the stream is registered in the CallTable — nothing can deliver or
    /// terminate earlier.
    func adopt(source: Source, sequence: Producer) {
        self.state.withLockedValue {
            $0.source = source
            $0.sequence = sequence
        }
    }

    /// Vends the single inbound iterator (the producer permits exactly one). The
    /// handle's `makeAsyncIterator()` calls this. A second call traps the
    /// producer's precondition — the public handle is documented single-iterator.
    func makeInboundIterator() -> Producer.AsyncIterator {
        let sequence = self.state.withLockedValue { state -> Producer? in
            let sequence = state.sequence
            state.sequence = nil
            return sequence
        }
        guard let sequence else {
            preconditionFailure("stream \(self.msgid): inbound sequence already iterated")
        }
        return sequence.makeAsyncIterator()
    }

    // MARK: - Test seams

    /// Whether the inbound producer is currently parked on consumer demand.
    var isInboundParked: Bool {
        self.state.withLockedValue { $0.inboundParked != nil }
    }

    /// Whether an outbound sender is currently parked at zero credit.
    var isSenderParked: Bool {
        self.state.withLockedValue { $0.senderParked != nil }
    }

    /// The current outbound credit (test aid).
    var currentOutboundCredit: UInt32 {
        self.state.withLockedValue { $0.outboundCredit }
    }
}

// MARK: - Inbound consumer (credit granting)

extension ClientStreamState {
    /// Accounts one consumed inbound element toward the credit grant, returning
    /// the additive credit to write now (or nil to withhold). Called by the
    /// handle's iterator after each delivered element.
    func creditToGrantAfterConsume() -> UInt32? {
        self.state.withLockedValue { state -> UInt32? in
            guard self.hasResponseStream, !state.terminated else { return nil }
            state.consumedSinceGrant &+= 1
            guard state.consumedSinceGrant >= MMStreamFlowControl.initialWindow else {
                return nil
            }
            let grant = state.consumedSinceGrant
            state.consumedSinceGrant = 0
            return grant
        }
    }

    /// Grants any accumulated credit to the server (kind 2), best-effort.
    func grantConsumed(_ credits: UInt32) async {
        await self.sinks.grantCredit(credits)
    }
}

// MARK: - ClientStreamControl

extension ClientStreamState: ClientStreamControl {
    func validateInboundItem(seq: UInt32) -> InboundItemValidation {
        self.state.withLockedValue { state -> InboundItemValidation in
            guard self.hasResponseStream else {
                // An item on a call with no declared response stream is a server
                // protocol violation.
                return .violation
            }
            if state.inboundEnded {
                // The server already ended its response direction (END or
                // terminal), or the consumer stopped: a late item is a tolerated
                // drop, never a violation.
                return .drop
            }
            guard seq == state.expectedInSeq else {
                return .violation
            }
            state.expectedInSeq &+= 1
            return .deliver
        }
    }

    func deliverInboundItem(_ item: ByteBuffer) -> InboundDeliveryOutcome {
        let element: Inbound
        switch MMPackDecoder().decode(Inbound.self, from: item) {
            case .failure(let error):
                self.metrics.streamItemDecodeFailures.increment()
                self.logger.warning(
                    "stream item decode failed",
                    metadata: ["msgid": "\(self.msgid)", "error": "\(error)"]
                )
                return .dropped
            case .success(let decoded):
                element = decoded
        }
        let source = self.state.withLockedValue { state -> Source? in
            state.inboundEnded ? nil : state.source
        }
        guard let source else { return .dropped }
        switch source.yield(element) {
            case .produceMore:
                return .produceMore
            case .dropped:
                return .dropped
            case .stopProducing:
                return .stopProducing
        }
    }

    func awaitInboundDemand() async {
        await withParkedContinuation(
            register: { continuation in
                self.state.withLockedValue { state -> Void? in
                    if state.inboundEnded || state.inboundParkCancelled || state.demandAvailable {
                        state.demandAvailable = false
                        return ()
                    }
                    state.inboundParked = continuation
                    return nil
                }
            },
            takeParkedOnCancel: {
                // Unparks the inbound loop so run() can unwind and close.
                self.state.withLockedValue { state in
                    state.inboundParkCancelled = true
                    let parked = state.inboundParked
                    state.inboundParked = nil
                    return parked
                }
            },
            cancelled: ()
        )
    }

    /// The one end-inbound mutation, shared by the server's END, the
    /// consumer's iterator drop, and terminal resolution: idempotently marks
    /// the inbound direction ended and yields the parked producer plus the
    /// source (the caller resumes/finishes them OUTSIDE the lock).
    private static func endInbound(
        _ state: inout State
    ) -> (parked: CheckedContinuation<Void, Never>?, source: Source?) {
        guard !state.inboundEnded else { return (nil, nil) }
        state.inboundEnded = true
        let parked = state.inboundParked
        state.inboundParked = nil
        let source = state.source
        state.source = nil
        return (parked, source)
    }

    func serverEndInbound() {
        guard self.hasResponseStream else { return }
        let (parked, source) = self.state.withLockedValue { Self.endInbound(&$0) }
        parked?.resume()
        // Finish after buffered items drain; also satisfies the producer's
        // finish-before-deinit requirement (`finishOnDeinit: false`).
        source?.finish()
    }

    func grantOutbound(_ credits: UInt32) {
        guard self.hasRequestStream else { return }
        let parked = self.state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            state.outboundCredit &+= credits
            if let parked = state.senderParked {
                state.senderParked = nil
                return parked
            }
            return nil
        }
        parked?.resume()
    }

    func serverStopOutbound() {
        guard self.hasRequestStream else { return }
        let parked = self.state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            state.peerStopped = true
            let parked = state.senderParked
            state.senderParked = nil
            return parked
        }
        parked?.resume()
    }

    func resolveTerminal(_ slots: ResponseSlots) {
        self.resolve(Self.decodeTerminal(slots))
    }

    func failTerminal(_ reason: MMCallError) {
        // Connection death (as opposed to a graceful terminal): a parked sender
        // released here must observe `.connectionClosed`, so mark the state.
        self.resolve(.failure(reason), connectionClosed: true)
    }

    func cancelLocally() {
        self.resolve(.failure(.cancelled))
    }
}

// MARK: - Terminal resolution

extension ClientStreamState {
    /// Decodes the terminal response slots into `Response` — the shared unary
    /// rule (``ResponseSlots/decodeResponse(_:)``).
    private static func decodeTerminal(_ slots: ResponseSlots) -> TerminalOutcome {
        slots.decodeResponse(Response.self)
    }

    /// The single terminal-resolving transition, shared by the terminal frame,
    /// connection death, and local cancel. Resolves every terminal awaiter with
    /// the same outcome (and caches it for late awaiters), finishes the inbound
    /// sequence (buffered items drain first), and releases a parked sender (it
    /// re-reads state and returns `.callEnded`). Idempotent: after `.resolved`
    /// the first outcome wins, but surfaces are still torn down defensively so a
    /// death-after-terminal releases any straggler.
    private func resolve(_ outcome: TerminalOutcome, connectionClosed: Bool = false) {
        let effects = self.state.withLockedValue {
            state -> (
                awaiters: [CheckedContinuation<TerminalOutcome, Never>],
                inboundParked: CheckedContinuation<Void, Never>?,
                source: Source?,
                senderParked: CheckedContinuation<Void, Never>?
            ) in
            var awaiters: [CheckedContinuation<TerminalOutcome, Never>] = []
            if case .pending(let pending) = state.terminalState {
                awaiters = pending
                state.terminalState = .resolved(outcome)
            }
            state.terminated = true
            // Sticky, and only ever set true: the first resolution wins the
            // terminal outcome, so a death-after-terminal must not relabel an
            // already-graceful terminal, but a straggler sender released by the
            // death still reads `.connectionClosed`.
            if connectionClosed { state.connectionClosed = true }

            let (inboundParked, source) = Self.endInbound(&state)

            state.outboundEnded = true
            let senderParked = state.senderParked
            state.senderParked = nil
            return (awaiters, inboundParked, source, senderParked)
        }
        for awaiter in effects.awaiters {
            awaiter.resume(returning: outcome)
        }
        effects.inboundParked?.resume()
        effects.source?.finish()
        effects.senderParked?.resume()
    }

    /// Awaits the call's terminal. Valid after the sequence ends OR concurrently
    /// with iteration, from any task, any number of times — every awaiter
    /// resolves exactly once with the same cached outcome.
    func result() async -> TerminalOutcome {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<TerminalOutcome, Never>) in
            let cached = self.state.withLockedValue { state -> TerminalOutcome? in
                switch state.terminalState {
                    case .resolved(let outcome):
                        return outcome
                    case .pending(var awaiters):
                        awaiters.append(continuation)
                        state.terminalState = .pending(awaiters)
                        return nil
                }
            }
            if let cached { continuation.resume(returning: cached) }
        }
    }
}

// MARK: - Outbound send gate

/// The gate decision for one `send`: send with a stamped seq, report a graceful
/// terminal disposition, or park at zero credit.
private enum SendGate {
    case send(seq: UInt32)
    case peerStopped
    case callEnded
    case connectionClosed
    case park
}

extension ClientStreamState {
    /// Encodes and sends one request-stream element, credit-gated. Suspends at
    /// zero credit until a grant (or STOP / death / END). The seq is stamped
    /// from 0 under the lock, so concurrent senders never collide on seq.
    func send(_ element: Outbound) async -> StreamSendOutcome {
        // Encode outside the lock.
        let item: ByteBuffer
        switch MMPackEncoder().encode(element) {
            case .failure:
                // A local encode failure on an outbound element: treat as call
                // ended rather than inventing a new outcome — the caller cannot
                // send this element. (Element types are validated at open by the
                // schema probe, so this is not expected in practice.)
                return .callEnded
            case .success(let encoded):
                item = encoded
        }

        // Acquire a credit + seq, or a terminal disposition, possibly parking.
        while true {
            let gate: SendGate = self.state.withLockedValue { state in
                // This send's own task was cancelled while parked: resolve the
                // loop deterministically instead of re-parking forever. Checked
                // first — a cancelled sender exits regardless of other state.
                if state.senderParkCancelled { return .callEnded }
                // Connection death: distinguished from a graceful terminal so a
                // parked sender released by the death reports `.connectionClosed`
                // (matching an in-flight send), not `.callEnded`.
                if state.connectionClosed { return .connectionClosed }
                if state.terminated { return .callEnded }
                if state.outboundEnded { return .callEnded }
                if state.peerStopped { return .peerStopped }
                if state.outboundCredit == 0 { return .park }
                state.outboundCredit &-= 1
                let seq = state.nextOutSeq
                state.nextOutSeq &+= 1
                return .send(seq: seq)
            }
            switch gate {
                case .send(let seq):
                    let delivered = await self.sinks.sendItem(seq, item)
                    return delivered ? .sent : .connectionClosed
                case .peerStopped:
                    return .peerStopped
                case .callEnded:
                    return .callEnded
                case .connectionClosed:
                    return .connectionClosed
                case .park:
                    await self.parkSender()
            // Loop: re-evaluate the gate after the grant/stop/death.
            }
        }
    }

    /// Suspends the sender at zero credit; resumed by `grantOutbound`,
    /// `serverStopOutbound`, terminal/fail/cancel, or the cancel handler.
    private func parkSender() async {
        await withParkedContinuation(
            register: { continuation in
                self.state.withLockedValue { state -> Void? in
                    // Any disposition that lets the loop make progress resolves
                    // the park immediately.
                    if state.terminated || state.outboundEnded || state.peerStopped
                        || state.senderParkCancelled || state.outboundCredit > 0
                    {
                        return ()
                    }
                    // Single-sender discipline: exactly one send may park at a
                    // time (the request direction is driven by one task). A
                    // second concurrent `send` parking here would overwrite —
                    // and permanently leak — the first's continuation, hanging
                    // that send forever. Trap instead, mirroring
                    // `makeInboundIterator`'s single-iterator precondition, so
                    // the misuse is an immediate, debuggable crash rather than a
                    // silent hang.
                    precondition(
                        state.senderParked == nil,
                        "stream \(self.msgid): concurrent send on one outbound direction"
                    )
                    state.senderParked = continuation
                    return nil
                }
            },
            takeParkedOnCancel: {
                self.state.withLockedValue { state in
                    state.senderParkCancelled = true
                    let parked = state.senderParked
                    state.senderParked = nil
                    return parked
                }
            },
            cancelled: ()
        )
    }

    /// Sends the outbound END (kind 4) exactly once. Idempotent: a second
    /// `finish()` (or a `finish()` after the terminal) is a no-op.
    func finish() async {
        let (shouldSend, parked) = self.state.withLockedValue {
            state -> (Bool, CheckedContinuation<Void, Never>?) in
            guard self.hasRequestStream, !state.outboundEnded, !state.terminated else {
                return (false, nil)
            }
            state.outboundEnded = true
            // Release a parked sender in the same mutation: it re-reads
            // outboundEnded and observes .callEnded.
            let parked = state.senderParked
            state.senderParked = nil
            return (true, parked)
        }
        parked?.resume()
        if shouldSend {
            await self.sinks.sendEnd()
        }
    }

    /// Sends a STOP (kind 5) asking the server to finish its response stream —
    /// graceful, advisory. Idempotent-ish: after the terminal it is a no-op.
    func stop() async {
        let shouldSend = self.state.withLockedValue { state -> Bool in
            self.hasResponseStream && !state.terminated
        }
        if shouldSend { await self.sinks.sendStop() }
    }

    /// Sends a CANCEL (kind 6) and resolves every local surface as `.cancelled`.
    /// The connection drops the server's code-7 terminal. Idempotent.
    func cancel() async {
        let shouldSend = self.state.withLockedValue { !$0.terminated }
        self.cancelLocally()
        if shouldSend { await self.sinks.sendCancel() }
    }
}

// MARK: - NIOAsyncSequenceProducerDelegate

extension ClientStreamState: NIOAsyncSequenceProducerDelegate {
    /// The consumer drained the buffer below the low watermark: release the
    /// parked inbound producer or record the demand for the next park.
    func produceMore() {
        let parked = self.state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            if let parked = state.inboundParked {
                state.inboundParked = nil
                return parked
            }
            state.demandAvailable = true
            return nil
        }
        parked?.resume()
    }

    /// The consumer stopped iterating (dropped the iterator or its task was
    /// cancelled): mark inbound ended and release the parked producer so the
    /// inbound loop can proceed. The terminal is unaffected — a consumer that
    /// stops iterating still awaits `result()`.
    func didTerminate() {
        let (parked, source) = self.state.withLockedValue { Self.endInbound(&$0) }
        parked?.resume()
        source?.finish()
    }
}
