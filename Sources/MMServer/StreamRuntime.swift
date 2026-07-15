import Logging
import MMWire
import Metrics
import NIOConcurrencyHelpers
import NIOCore

/// The connection-scoped stream coordinator: it owns the ``StreamTable`` and the
/// stream metrics, routes inbound stream frames (kinds 2–6) to live streams, and
/// builds accepted opens into a ``StreamRuntime/OpenPlan`` the request loop
/// launches as a child task.
///
/// It lives entirely inside one connection's `requestLoop` scope — never in the
/// ``Router`` (which is shared and stateless). All shared state is the single
/// `NIOLockedValueBox<StreamTable>`; every side effect that must suspend (wire
/// writes, element yields, sink resumes) happens outside that lock.
final class StreamRuntime: Sendable {
    /// The table decides frame legality; the runtime applies the effects.
    private let table = NIOLockedValueBox(StreamTable())
    private let writer: any WriterFunnel
    private let metrics: MMStreamMetrics
    private let maxConcurrentStreams: Int
    private let logger: Logger

    init(
        writer: any WriterFunnel,
        metrics: MMStreamMetrics,
        maxConcurrentStreams: Int,
        logger: Logger
    ) {
        self.writer = writer
        self.metrics = metrics
        self.maxConcurrentStreams = maxConcurrentStreams
        self.logger = logger
    }

    // MARK: - Unary guard

    /// Marks `msgid` a live unary call so a stream frame misaddressed to it is a
    /// violation, not a silent drop. Returns false if the msgid is already owned
    /// by a live stream or unary call (a reused msgid), so the caller drops it
    /// rather than registering a second terminal owner.
    func registerUnary(msgid: UInt32) -> Bool {
        self.table.withLockedValue { $0.registerUnary(msgid: msgid) }
    }

    /// Whether the unary handler's terminal for `msgid` should still be sent
    /// (false when a stream frame already forced a code-6 terminal for it),
    /// retiring the unary entry either way.
    func shouldSendUnaryTerminal(msgid: UInt32) -> Bool {
        self.table.withLockedValue { $0.consumeUnaryTerminal(msgid: msgid) }
    }

    // MARK: - Opening a stream

    /// The launch plan for an accepted stream open: the child-task body the
    /// request loop runs (which drives the handler and flushes its terminal),
    /// already wired to cancel the handler on group cancellation.
    struct OpenPlan: Sendable {
        let run: @Sendable () async -> Void
    }

    /// Authorization has already passed (the router ran it). Build the wire
    /// seams, enforce the per-connection stream cap, construct the typed
    /// handler, register it, and return the launch plan — or send the terminal
    /// and return nil when the open is rejected (over cap, decode failure, or
    /// msgid reuse).
    func openStream(
        msgid: UInt32,
        route: Route,
        params: ByteBuffer,
        context: MMContext,
        framesDropped: Counter
    ) async -> OpenPlan? {
        guard let streamHandler = route.streamHandler else {
            // Unreachable: the caller only calls this for stream routes.
            return nil
        }

        // Ownership check FIRST, before the cap and malformed-params checks: a
        // reopen on a msgid whose original call is still live is a client bug,
        // but that original call still owns the single terminal for the msgid.
        // Emitting any rejection terminal here (over-cap, malformed, or reuse)
        // would put a SECOND terminal on the wire for that msgid. So a reused
        // live msgid is dropped-and-counted, never terminated.
        let alreadyOwned = self.table.withLockedValue { $0.isOwned(msgid: msgid) }
        guard !alreadyOwned else {
            framesDropped.increment()
            return nil
        }

        // Cap: counted separately from the unary in-flight cap. An open over
        // the cap gets an immediate code-4 terminal and registers no state.
        let underCap = self.table.withLockedValue { table in
            table.openStreamCount < self.maxConcurrentStreams
        }
        guard underCap else {
            self.metrics.overCap.increment()
            _ = await self.writer.send(
                .response(msgid: msgid, error: Router.errorObject(.tooManyInFlight), result: nil)
            )
            return nil
        }

        let seams = StreamWireSeams(
            sendItem: { [writer] seq, item in
                await writer.send(.item(msgid: msgid, seq: seq, item: item)).isSuccess
            },
            sendFrame: { [writer] envelope in
                await writer.send(envelope).isSuccess
            }
        )

        guard let startup = streamHandler(params, context, msgid, seams, self.metrics) else {
            // Params failed to decode as the method's request type.
            _ = await self.writer.send(
                .response(msgid: msgid, error: Router.errorObject(.malformedParams), result: nil)
            )
            return nil
        }

        let registered = self.table.withLockedValue { table in
            table.registerStream(
                msgid: msgid,
                entry: StreamTable.Entry(
                    control: startup.control,
                    hasRequestStream: startup.control.hasRequestStream,
                    hasResponseStream: startup.control.hasResponseStream
                )
            )
        }
        guard registered else {
            // Defensive: the up-front ownership check already caught msgid
            // reuse, so this can only happen if a frame registered the msgid
            // between that check and here — impossible under the single request
            // loop. Drop-and-count rather than emit a rejection terminal that
            // would double-terminate the owning call.
            framesDropped.increment()
            return nil
        }
        self.metrics.opened.increment()

        let control = startup.control
        return OpenPlan { [self] in
            // The handler runs as a cancellable unit. It is created and awaited
            // inside this child task, and the cancellation handler forwards
            // group cancellation (connection teardown) into the handler — so it
            // never outlives its parent: not a free-floating task.
            let handlerTask = Task { await startup.run() }
            control.attachCancel { handlerTask.cancel() }
            let terminal = await withTaskCancellationHandler {
                await handlerTask.value
            } onCancel: {
                handlerTask.cancel()
            }
            await self.finishStream(msgid: msgid, terminal: terminal)
        }
    }

    /// The handler returned: send its terminal and retire the stream — but only
    /// if the stream is still live. A CANCEL or a violation may have retired it
    /// and already sent a code-6/7 terminal; in that case the handler's terminal
    /// is discarded (the single-terminal guarantee).
    private func finishStream(msgid: UInt32, terminal: StreamTerminal) async {
        let stillLive = self.table.withLockedValue { $0.retireStream(msgid: msgid) }
        guard stillLive else { return }
        self.metrics.ended.increment()
        let envelope: MMEnvelope
        switch terminal {
            case .success(let result):
                envelope = .response(msgid: msgid, error: nil, result: result)
            case .failure(let errorObject):
                envelope = .response(msgid: msgid, error: errorObject, result: nil)
        }
        _ = await self.writer.send(envelope)
    }

    // MARK: - Routing inbound stream frames (kinds 2–6)

    /// Routes one stream-lifecycle frame to its live stream. Unknown/retired
    /// msgids drop-and-count; violations send a code-6 terminal (and tear down
    /// the offending stream); the graceful frames apply their effect. Returns
    /// nothing — every effect is applied here.
    func route(_ envelope: MMEnvelope, framesDropped: Counter) async {
        switch envelope {
            case .item(let msgid, let seq, let item):
                await self.routeItem(
                    msgid: msgid, seq: seq, item: item, framesDropped: framesDropped)
            case .credit(let msgid, let credits):
                let control = self.table.withLockedValue { $0.routeCredit(msgid: msgid) }
                if let control {
                    control.grantResponse(credits)
                } else {
                    framesDropped.increment()
                }
            case .end(let msgid):
                await self.routeEnd(msgid: msgid, framesDropped: framesDropped)
            case .stop(let msgid, _):
                let control = self.table.withLockedValue { $0.routeStop(msgid: msgid) }
                if let control {
                    self.metrics.stopped.increment()
                    control.clientStopResponse()
                } else {
                    framesDropped.increment()
                }
            case .cancel(let msgid):
                await self.routeCancel(msgid: msgid, framesDropped: framesDropped)
            case .request, .response:
                // Not a stream-lifecycle frame; the caller never routes these here.
                break
        }
    }

    private func routeItem(
        msgid: UInt32, seq: UInt32, item: ByteBuffer, framesDropped: Counter
    ) async {
        let decision = self.table.withLockedValue { $0.routeItem(msgid: msgid, seq: seq) }
        switch decision {
            case .deliver(let control):
                if case .failure = control.deliver(item) {
                    // Element decode failure: a stream violation. Unlike the
                    // `.violation` decisions (which nil the entry under the table
                    // lock), a `.deliver` decision deliberately keeps the entry live
                    // to advance seq/credit — so retire it here before the code-6
                    // terminal, or the later `finishStream` would emit a SECOND
                    // terminal for this msgid (the single-terminal invariant).
                    let stillLive = self.table.withLockedValue { $0.retireStream(msgid: msgid) }
                    if stillLive {
                        await self.violation(msgid: msgid, control: control)
                    } else {
                        // A CANCEL / drain retired it between deliver and here; the
                        // terminal was already sent. Just drop.
                        framesDropped.increment()
                    }
                }
            case .violation(let control):
                await self.violation(msgid: msgid, control: control)
            case .unaryViolation:
                await self.unaryViolation(msgid: msgid)
            case .drop:
                framesDropped.increment()
        }
    }

    private func routeEnd(msgid: UInt32, framesDropped: Counter) async {
        let decision = self.table.withLockedValue { $0.routeEnd(msgid: msgid) }
        switch decision {
            case .end(let control):
                control.clientEndRequest()
            case .violation(let control):
                await self.violation(msgid: msgid, control: control)
            case .unaryViolation:
                await self.unaryViolation(msgid: msgid)
            case .drop:
                framesDropped.increment()
        }
    }

    private func routeCancel(msgid: UInt32, framesDropped: Counter) async {
        let control = self.table.withLockedValue { $0.routeCancel(msgid: msgid) }
        guard let control else {
            framesDropped.increment()
            return
        }
        // The runtime — not the handler — sends the code-7 terminal to retire
        // the msgid; the handler task is cancelled cooperatively and its later
        // completion is discarded (the entry is already gone).
        self.metrics.cancelled.increment()
        control.cancelHandler()
        control.endStreams()
        _ = await self.writer.send(
            .response(msgid: msgid, error: Router.errorObject(.cancelled), result: nil)
        )
    }

    /// A stream-contract violation on a live stream: tear the handler down and
    /// send the code-6 terminal. The entry was already removed by the table.
    private func violation(msgid: UInt32, control: any StreamControl) async {
        self.metrics.violations.increment()
        control.cancelHandler()
        control.endStreams()
        _ = await self.writer.send(
            .response(msgid: msgid, error: Router.errorObject(.streamViolation), result: nil)
        )
    }

    /// A stream frame misaddressed to a live unary msgid: the caller broke the
    /// contract. Send a code-6 terminal; the unary handler's own terminal is
    /// suppressed (the table flipped the entry to `.suppressed`).
    private func unaryViolation(msgid: UInt32) async {
        self.metrics.violations.increment()
        _ = await self.writer.send(
            .response(msgid: msgid, error: Router.errorObject(.streamViolation), result: nil)
        )
    }

    // MARK: - Teardown

    /// Connection teardown / graceful shutdown: cancel every live handler and
    /// finish its streams so the handler tasks unwind. The entries are left in
    /// the table, so each handler's completion still flows through
    /// `finishStream` and flushes its terminal through the writer before the
    /// channel closes (the graceful-drain contract). Idempotent — cancelling an
    /// already-finished handler and ending an already-ended stream are no-ops.
    func drain() {
        let controls = self.table.withLockedValue { $0.liveControls() }
        for control in controls {
            control.cancelHandler()
            control.endStreams()
        }
    }
}

extension Result {
    /// Whether this is `.success`, discarding both payloads. Used to reduce a
    /// writer send outcome to "did it land on the wire".
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
