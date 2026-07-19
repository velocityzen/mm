import FP
import Logging
import MMSchema
import MMWire
import Metrics
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// One client connection: typed calls, msgid multiplexing, and the inbound
/// response loop.
///
/// ## Lifecycle is structured — the host owns `run()`
///
/// `connect(to:configuration:)` performs the transport bootstrap and the hello
/// exchange, nothing more; no task is spawned (no free-floating `Task { }`,
/// per house rules). The returned connection is inert until the **host** runs
/// the inbound loop, ``run()``, as a structured child. Two sanctioned shapes:
///
/// ```swift
/// // 1. swift-service-lifecycle (daemons): drop the adapter in a ServiceGroup.
/// let connection = try await MMClientConnection.connect(to: .unix(path: sock)).get()
/// let group = ServiceGroup(configuration: .init(
///     services: [.init(service: MMClientConnectionService(connection: connection))],
///     gracefulShutdownSignals: [.sigterm],
///     logger: logger
/// ))
/// try await group.run()
///
/// // 2. Plain structured concurrency (tools, tests):
/// await withTaskGroup(of: Void.self) { tasks in
///     tasks.addTask { _ = await connection.run() }
///     let reply = await connection.call(Journal.append, request)
///     connection.close()
/// }
/// ```
///
/// Calls may be issued before `run()` has started — they park (bounded by the
/// in-flight cap and their own callers) until the loop produces the outbound
/// writer — but no response can arrive until `run()` is consuming the inbound
/// stream, so start it promptly.
///
/// ## Death and reconnection
///
/// When the loop terminates — EOF, transport error, protocol violation,
/// ``close()``, or cancellation of the `run()` task — every pending call fails
/// with `MMCallError.connectionClosed` (or `.transport`), the ``state``
/// transitions to `.closed(reason:)`, and `run()` returns. Reconnection is
/// deliberately out of scope for v1: a closed connection stays closed, and
/// retry policy belongs to the application, driven by ``stateUpdates()``.
public actor MMClientConnection {
    typealias Writer = NIOAsyncChannelOutboundWriter<ByteBuffer>

    /// The outcome of the hello exchange, fixed for the connection's lifetime.
    public nonisolated let server: ServerInfo

    nonisolated let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    private nonisolated let configuration: MMClientConfiguration
    private nonisolated let logger: Logger
    private nonisolated let metrics: ClientMetrics
    /// The multiplexing state machine. A locked value (not actor state)
    /// because synchronous task-cancellation handlers must resolve pending
    /// entries; the lock is never held across a suspension point and every
    /// continuation is resumed outside it. See `CallTable` for the
    /// single-resume audit.
    private nonisolated let calls: NIOLockedValueBox<CallTable>
    private nonisolated let states: NIOLockedValueBox<StateHub>
    /// The automatic schema-verification verdict, replay-once. Resolved by
    /// the verification child of `run()`, or by `finish(reason:)` when the
    /// connection ends first. Awaited via ``verify()``.
    private nonisolated let verification = SchemaVerificationCell()

    /// Who owns the channel's scoped teardown. `NIOAsyncChannel` requires its
    /// writer to be finished via `executeThenClose` exactly once: `run()`
    /// normally does it; `close()` on a never-run connection does it instead.
    private enum Lifecycle {
        case idle
        case running
        case finished
    }

    private var lifecycle: Lifecycle = .idle

    private static let connectionIDs = NIOLockedValueBox<UInt64>(0)

    init(
        channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        server: ServerInfo,
        configuration: MMClientConfiguration,
        logger: Logger
    ) {
        let connectionID = Self.connectionIDs.withLockedValue { next in
            next &+= 1
            return next
        }
        var connectionLogger = logger
        connectionLogger[metadataKey: "service"] = "mm.client"
        connectionLogger[metadataKey: "connection"] = "\(connectionID)"
        let metrics = ClientMetrics()
        self.channel = channel
        self.server = server
        self.configuration = configuration
        self.logger = connectionLogger
        self.metrics = metrics
        self.calls = NIOLockedValueBox(CallTable())
        self.states = NIOLockedValueBox(StateHub())
    }

    // MARK: - Connect

    /// Bootstraps the transport, exchanges hellos, and returns a connected
    /// (but not yet running — see the type docs) connection.
    ///
    /// The client sends its hello as the first outbound frame without waiting
    /// for the server's. The server's first frame must be a decodable hello
    /// (anything else is ``MMClientError/badHello``); the negotiated version
    /// is min-wins, and a fingerprint mismatch is surfaced on
    /// ``ServerInfo/fingerprintMatched`` — never a disconnect, per the fixed
    /// wire decision. TCP endpoints get `TCP_NODELAY`.
    public static func connect(
        to endpoint: MMEndpoint,
        configuration: MMClientConfiguration = MMClientConfiguration(),
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger = Logger(label: "mm.client")
    ) async -> Result<MMClientConnection, MMClientError> {
        var bootstrap = ClientBootstrap(group: eventLoopGroup)
        if let connectTimeout = configuration.connectTimeout {
            bootstrap = bootstrap.connectTimeout(connectTimeout)
        }
        // The hello promise is created inside the initializer, on the channel's
        // loop: it exists exactly when the hello handler exists, so it is
        // completed on every path (the handler completes it on success, close,
        // and removal) and can never leak or double-complete.
        let initializer: @Sendable (any Channel) -> EventLoopFuture<ConnectedPipeline> = {
            channel in
            channel.eventLoop.makeCompletedFuture {
                let helloPromise = channel.eventLoop.makePromise(of: MMHello.self)
                let wrapped = try Self.configurePipeline(
                    channel: channel,
                    configuration: configuration,
                    helloPromise: helloPromise
                )
                return ConnectedPipeline(channel: wrapped, serverHello: helloPromise.futureResult)
            }
        }

        // Seam adapter: bootstrap throws untyped; collapse to transport.
        return await Result.fromAsync {
            switch endpoint {
                case .unix(let path):
                    try await bootstrap.connect(
                        unixDomainSocketPath: path,
                        channelInitializer: initializer
                    )
                case .tcp(let host, let port):
                    try await bootstrap
                        .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                        .connect(host: host, port: port, channelInitializer: initializer)
            }
        }
        .mapError { MMClientError.transport(description: String(describing: $0)) }
        .flatMapAsync { pipeline in
            await Self.establish(
                channel: pipeline.channel,
                serverHello: pipeline.serverHello,
                configuration: configuration,
                logger: logger
            )
        }
    }

    private struct ConnectedPipeline: Sendable {
        var channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        var serverHello: EventLoopFuture<MMHello>
    }

    /// Per-connection pipeline, head to tail: optional idle reaper, framing
    /// codec with the configured cap, hello handler. Must run on the channel's
    /// event loop. Internal so tests assemble the identical pipeline on a
    /// `NIOAsyncTestingChannel`.
    static func configurePipeline(
        channel: any Channel,
        configuration: MMClientConfiguration,
        helloPromise: EventLoopPromise<MMHello>
    ) throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        let sync = channel.pipeline.syncOperations
        if let idleTimeout = configuration.idleTimeout {
            try sync.addHandler(IdleStateHandler(allTimeout: idleTimeout))
            try sync.addHandler(MMIdleCloseHandler())
        }
        try sync.addHandler(
            ByteToMessageHandler(MMFrameDecoder(maxFrameLength: configuration.maxFrameLength))
        )
        try sync.addHandler(
            MessageToByteHandler(MMFrameEncoder(maxFrameLength: configuration.maxFrameLength))
        )
        try sync.addHandler(
            ClientHelloHandler(clientHello: configuration.clientHello, helloPromise: helloPromise)
        )
        return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
    }

    /// Awaits the server hello, negotiates, and assembles the connection.
    /// Failure closes the channel. Internal so tests drive it over a
    /// `NIOAsyncTestingChannel`.
    static func establish(
        channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        serverHello: EventLoopFuture<MMHello>,
        configuration: MMClientConfiguration,
        logger: Logger
    ) async -> Result<MMClientConnection, MMClientError> {
        // The hello await must be bounded and cancellable: the peer fully
        // controls progress here (a server that accepts the socket but never
        // writes would otherwise park connect() forever), and
        // `EventLoopFuture.get()` is not cancellation-aware. Both escapes —
        // the default hello deadline and task cancellation — close the
        // channel, which fails the promise via channelInactive →
        // closedBeforeHello; the promise itself is completed only by the
        // hello handler, so it can never double-complete.
        let raw = channel.channel
        let helloDeadline: Scheduled<Void>? = configuration.helloTimeout.map { timeout in
            raw.eventLoop.scheduleTask(in: timeout) { raw.close(promise: nil) }
        }
        defer { helloDeadline?.cancel() }
        // Seam adapter: the promise carries HelloFailure or transport errors;
        // every failure — bad hello, transport, or a negotiation the next
        // stage rejects — discards the channel.
        return await Result.fromAsync {
            try await withTaskCancellationHandler {
                try await serverHello.get()
            } onCancel: {
                raw.close(promise: nil)
            }
        }
        .mapError { error in
            (error as? HelloFailure)?.clientError
                ?? .transport(description: String(describing: error))
        }
        .flatMap { hello in Self.negotiate(serverHello: hello, configuration: configuration) }
        .tapErrorAsync { _ in await Self.discard(channel) }
        .map { server in
            MMClientConnection(
                channel: channel,
                server: server,
                configuration: configuration,
                logger: logger
            )
        }
    }

    /// Pure negotiation math: min-wins version (a server advertising version 0
    /// is unsupported — v1 is the first version), bitwise-intersected
    /// capabilities, and the fingerprint verdict (compared only when the
    /// configuration expects one; a mismatch is data, not an error).
    static func negotiate(
        serverHello: MMHello,
        configuration: MMClientConfiguration
    ) -> Result<ServerInfo, MMClientError> {
        let negotiated = HelloNegotiation.negotiate(
            localVersion: MMWireInfo.protocolVersion,
            localCapabilities: configuration.capabilities,
            remote: serverHello
        )
        guard negotiated.protocolVersion >= 1 else {
            return .failure(.versionUnsupported(serverVersion: serverHello.protocolVersion))
        }
        return .success(
            ServerInfo(
                protocolVersion: negotiated.protocolVersion,
                fingerprint: serverHello.schemaFingerprint,
                fingerprintMatched: configuration.schema?.serverFingerprint.map {
                    $0 == serverHello.schemaFingerprint
                },
                capabilities: negotiated.capabilities
            )
        )
    }

    /// The sanctioned teardown for a channel that never got a `run()`:
    /// an empty `executeThenClose` finishes the outbound writer and closes
    /// (a bare close would trip `NIOAsyncWriter`'s finish precondition).
    private static func discard(_ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        try? await channel.executeThenClose { _, _ in }
    }

    // MARK: - Run (inbound loop)

    /// The inbound loop; the host runs it as a structured child (see the type
    /// docs). Consumes the channel's inbound stream, routes responses and
    /// stream frames to pending calls, and drops inbound requests (a server
    /// calling a client is a protocol violation in v1).
    ///
    /// Returns when the connection dies: `.success` for a clean end (EOF,
    /// local ``close()``, or cancellation of this task — cancellation is the
    /// host dismantling its task tree, a deliberate stop, not a fault),
    /// `.failure` for transport errors and protocol violations. On every exit
    /// path, all pending calls have already been failed and ``state`` is
    /// `.closed` by the time this returns.
    public func run() async -> Result<Void, MMClientError> {
        switch self.lifecycle {
            case .running:
                return .failure(.alreadyRunning)
            case .finished:
                // Closed before it ever ran: nothing to consume, clean end.
                return .success(())
            case .idle:
                self.lifecycle = .running
        }
        var terminal: MMClientError?
        do {
            // The four blessed seams: this is the NIOAsyncChannel data plane.
            // The per-connection do/catch below is the only one on the path.
            try await self.channel.executeThenClose { inbound, outbound in
                let waiters = self.calls.withLockedValue { $0.installWriter(outbound) }
                for waiter in waiters {
                    waiter.resume(returning: .success(outbound))
                }
                // The inbound loop and the automatic schema verification run
                // as structured siblings: verification rides the normal call
                // path, so it needs this loop routing responses concurrently.
                // The defer cancels a verification still in flight when the
                // loop ends first — its pending call resumes `.cancelled` and
                // the verdict resolves as skipped, so the implicit
                // group-exit await can never park on a response that will
                // never arrive.
                try await withThrowingTaskGroup(of: Void.self) { verifier in
                    verifier.addTask { await self.performAutoVerification() }
                    defer { verifier.cancelAll() }
                    for try await frame in inbound {
                        if let violation = await self.handleFrame(frame) {
                            terminal = violation
                            return
                        }
                    }
                }
            }
        } catch is CancellationError {
            terminal = nil
        } catch {
            terminal = .transport(description: String(describing: error))
        }
        self.lifecycle = .finished
        self.finish(reason: terminal)
        if let terminal {
            self.logger.debug("connection closed", metadata: ["reason": "\(terminal)"])
            return .failure(terminal)
        }
        self.logger.debug("connection closed")
        return .success(())
    }

    // MARK: - Automatic schema verification

    /// The automatic schema verification verdict — replay-once: awaitable
    /// any number of times, from any task, resolving exactly once per
    /// connection. Resolves shortly after ``run()`` starts (immediately when
    /// a complete expectation already matches the hello), and always
    /// resolves by the time the connection closes. Purely informational —
    /// see ``MMSchemaVerification``.
    public nonisolated func verify() async -> Result<
        MMSchemaVerification, MMSchemaVerificationError
    > {
        await self.verification.value()
    }

    /// The verification child of `run()`: a complete expectation whose
    /// folded fingerprint matches the hello is proven with zero round-trips;
    /// anything else — a partial slice, or a complete expectation the hello
    /// contradicts — is confirmed with one scoped discovery diff per
    /// declared contract. A difference logs a warning and lands in the
    /// verdict; nothing here ever closes the connection (soft-verdict rule).
    private nonisolated func performAutoVerification() async {
        guard let expectation = self.configuration.schema else {
            self.verification.failure(.noExpectation)
            return
        }

        if self.server.fingerprintMatched == true {
            self.verification.success(.ok)
            return
        }

        switch await self.verifyContracts(expectation.contracts) {
            case .success(let differences) where differences.isEmpty:
                self.verification.success(.partial)

            case .success(let differences):
                self.logger.warning(
                    "schema difference",
                    metadata: ["namespaces": "\(differences.count)"]
                )
                self.verification.success(.difference(differences))

            case .failure(.denied):
                // A peer may hold call rights without read on the namespace
                // entity; verification never blocks what authorization allows.
                self.verification.failure(.denied)

            case .failure(let error):
                self.verification.failure(.failed(error))
        }
    }

    /// Handles one inbound frame. A non-nil return is a fatal protocol
    /// violation: the loop stops and the connection closes.
    private func handleFrame(_ frame: ByteBuffer) async -> MMClientError? {
        await MMEnvelope.decode(from: frame)
            .tapError { error in
                self.logger.debug("envelope decode failed", metadata: ["error": "\(error)"])
            }
            .matchAsync(
                { @Sendable envelope in await self.route(envelope) },
                { @Sendable error in self.protocolViolation(String(describing: error)) }
            )
    }

    /// Routes one decoded envelope; same fatality contract as `handleFrame`.
    private func route(_ envelope: MMEnvelope) async -> MMClientError? {
        switch envelope {
            case .response(let msgid, let error, let result):
                let slots = ResponseSlots(error: error, result: result)
                let action = self.calls.withLockedValue {
                    $0.complete(msgid: msgid, outcome: .success(slots))
                }
                switch action {
                    case .resume(let continuation):
                        continuation.resume(returning: .success(slots))
                    case .parked:
                        break
                    case .stream(let control):
                        // The terminal retires a live stream: resolve its terminal,
                        // finish its inbound sequence, release any parked sender.
                        control.resolveTerminal(slots)
                    case .dropped:
                        self.dropResponse(msgid: msgid)
                }
                return nil
            case .request(let msgid, let method, _, _):
                // v1 servers never call clients; tolerate-and-drop (not fatal) so
                // a future capability-gated extension does not kill old clients.
                self.dropInboundRequest(msgid: msgid, method: method)
                return nil
            case .item(let msgid, let seq, let item):
                return await self.handleInboundItem(msgid: msgid, seq: seq, item: item)
            case .credit(let msgid, let credits):
                return self.routeStreamLifecycle(msgid: msgid, kind: "credit") {
                    $0.grantOutbound(credits)
                }
            case .end(let msgid):
                return self.routeStreamLifecycle(msgid: msgid, kind: "end") {
                    $0.serverEndInbound()
                }
            case .stop(let msgid, _):
                return self.routeStreamLifecycle(msgid: msgid, kind: "stop") {
                    $0.serverStopOutbound()
                }
            case .cancel(let msgid):
                // CANCEL is client→server only in v1; a server never sends it. A
                // stray kind-6 is unexpected — drop-and-count, never fatal (a live
                // stream is retired by its terminal, not by an inbound cancel).
                self.dropStreamFrame(msgid: msgid, kind: "cancel")
                return nil
        }
    }

    /// Routes one inbound stream item to its stream control, enforcing the
    /// client-side violation policy: an item on a call with no declared response
    /// stream, on a live unary msgid, or with a seq gap is a **server protocol
    /// violation** — connection-fatal, exactly like an undecodable envelope. A
    /// late item (after the stream ended) or an item for an unknown/retired
    /// msgid is a tolerated drop-and-count. On a legal item whose delivery fills
    /// the per-stream buffer, the loop parks (``awaitInboundDemand``) before
    /// returning — real backpressure to the socket.
    private func handleInboundItem(
        msgid: UInt32,
        seq: UInt32,
        item: ByteBuffer
    ) async -> MMClientError? {
        let control: any ClientStreamControl
        switch self.streamControlForFrame(msgid: msgid, kind: "item") {
            case .dropped:
                return nil
            case .violation(let error):
                return error
            case .control(let routed):
                control = routed
        }
        switch control.validateInboundItem(seq: seq) {
            case .drop:
                self.dropStreamFrame(msgid: msgid, kind: "item")
                return nil
            case .violation:
                return self.protocolViolation(
                    "stream item violation on msgid \(msgid) (seq \(seq))"
                )
            case .deliver:
                switch control.deliverInboundItem(item) {
                    case .produceMore, .dropped:
                        return nil
                    case .stopProducing:
                        // Buffer full: park before reading the next frame so lag reaches
                        // the socket. The park releases on consumer drain, stream end,
                        // or task cancellation (loop teardown).
                        await control.awaitInboundDemand()
                        return nil
                }
        }
    }

    /// Routes a stream-lifecycle frame (credit, END, STOP) to its live stream
    /// control, applying the same client-side violation policy as the item arm:
    /// a lifecycle frame addressed to a **live unary** msgid is a server protocol
    /// violation (connection-fatal), exactly as a stream item on a unary msgid is;
    /// a frame for an unknown/retired msgid is a tolerated drop-and-count. Keeping
    /// all stream-lifecycle kinds on one policy (rather than the item path being
    /// fatal while credit/END/STOP silently dropped) makes a misaddressed
    /// lifecycle frame classified the same way regardless of kind.
    private func routeStreamLifecycle(
        msgid: UInt32,
        kind: String,
        _ apply: (any ClientStreamControl) -> Void
    ) -> MMClientError? {
        switch self.streamControlForFrame(msgid: msgid, kind: kind) {
            case .dropped:
                return nil
            case .violation(let error):
                return error
            case .control(let control):
                apply(control)
                return nil
        }
    }

    /// The routing verdict for a stream-addressed frame.
    private enum StreamFrameRouting {
        case control(any ClientStreamControl)
        case violation(MMClientError)
        case dropped
    }

    /// The one lookup policy for every stream-addressed frame kind (item,
    /// credit, END, STOP): the live stream's control, a connection-fatal
    /// violation when the msgid belongs to a live *unary* call, or a
    /// tolerated drop-and-count for unknown/retired msgids.
    private func streamControlForFrame(msgid: UInt32, kind: String) -> StreamFrameRouting {
        let (control, isUnary) = self.calls.withLockedValue {
            ($0.streamControl(msgid: msgid), $0.isLiveUnary(msgid: msgid))
        }
        guard let control else {
            if isUnary {
                return .violation(
                    self.protocolViolation("stream \(kind) on unary msgid \(msgid)")
                )
            }
            self.dropStreamFrame(msgid: msgid, kind: kind)
            return .dropped
        }
        return .control(control)
    }

    // MARK: - Observability (count + log, one name per event)

    /// Drop-and-count a stream frame for an unknown/retired msgid.
    private nonisolated func dropStreamFrame(msgid: UInt32, kind: String) {
        self.metrics.streamFramesDropped.increment()
        self.logger.debug(
            "stream frame dropped",
            metadata: ["msgid": "\(msgid)", "kind": "\(kind)"]
        )
    }

    /// Drop-and-count a late response for an abandoned (cancelled) msgid, or
    /// a server bug. Never an error.
    private nonisolated func dropResponse(msgid: UInt32) {
        self.metrics.responsesUnmatched.increment()
        self.logger.debug("response dropped", metadata: ["msgid": "\(msgid)"])
    }

    /// Drop-and-count an inbound request (v1 servers never call clients).
    /// Debug, not warning: the peer controls this line's rate.
    private nonisolated func dropInboundRequest(msgid: UInt32, method: String) {
        self.metrics.protocolViolations.increment()
        self.logger.debug(
            "inbound request dropped",
            metadata: ["msgid": "\(msgid)", "method": "\(method)"]
        )
    }

    /// Counts a server protocol violation and builds the connection-fatal
    /// error in one step, so no violation path can forget the counter.
    private nonisolated func protocolViolation(_ description: String) -> MMClientError {
        self.metrics.protocolViolations.increment()
        return .protocolViolation(description: description)
    }

    /// Counts and logs one failed call (any error shape, local or remote).
    private nonisolated func recordCallFailure(method: String, error: MMCallError) {
        self.metrics.callFailures.increment()
        self.logger.debug(
            "call failed",
            metadata: ["method": "\(method)", "error": "\(error)"]
        )
    }

    // MARK: - Call

    /// Performs one typed call: encodes `request`, allocates a msgid, sends
    /// the request envelope, and suspends until the response (routed by the
    /// `run()` loop) arrives.
    ///
    /// Bounded: at most ``MMClientConfiguration/maxInFlightCalls`` calls wait
    /// at once — the excess fails immediately with `.tooManyInFlight`, it is
    /// never queued.
    ///
    /// ## Cancellation
    ///
    /// Cancelling the awaiting task abandons the msgid: the call returns
    /// `.failure(.cancelled)` promptly and a late response for that msgid is
    /// dropped with a debug log. **The request may still execute
    /// server-side** — cancellation is local abandonment, not a remote abort;
    /// only its response delivery is cut.
    public nonisolated func call<Request: Codable & Sendable, Response: Codable & Sendable>(
        _ method: Method<Request, Response>,
        on entity: EntityName,
        _ request: Request
    ) async -> Result<Response, MMCallError> {
        self.metrics.calls.increment()

        return await self.call(
            methodName: method.name,
            entity: entity,
            request: request,
            as: Response.self
        )
        .tapError { error in
            self.recordCallFailure(method: method.name, error: error)
        }
    }

    /// The untyped-descriptor core of ``call(_:on:_:)``: the wire name is a
    /// plain string, so the dynamic surfaces (discovery, the CLI's raw call)
    /// and the typed overload share one send path.
    private nonisolated func call<Request: Codable & Sendable, Response: Codable & Sendable>(
        methodName: String,
        entity: EntityName,
        request: Request,
        as _: Response.Type
    ) async -> Result<Response, MMCallError> {
        guard !Task.isCancelled else {
            return .failure(.cancelled)
        }
        return await self.prepareRequestSend(
            methodName: methodName,
            entity: entity,
            request: request
        )
        .flatMapAsync { msgid, frame, writer in
            await self.sendAndAwaitResponse(
                msgid: msgid,
                frame: frame,
                writer: writer,
                as: Response.self
            )
        }
    }

    /// Writes the prepared request and suspends until the response arrives.
    private nonisolated func sendAndAwaitResponse<Response: Codable & Sendable>(
        msgid: UInt32,
        frame: ByteBuffer,
        writer: Writer,
        as _: Response.Type
    ) async -> Result<Response, MMCallError> {
        let start = ContinuousClock.now
        do {
            // Seam adapter: writer backpressure suspends here; a throw means
            // the channel is gone — or the task was cancelled mid-write.
            try await writer.write(frame)
        } catch {
            // The writer's yield resumes with CancellationError when the
            // awaiting task is cancelled while suspended on outbound
            // backpressure (or was already cancelled); the connection is
            // still alive then, so honor the documented cancellation
            // contract (.cancelled, never .connectionClosed). Either way a
            // parked response wins over the write failure, same as the
            // `cancel(msgid:)` path.
            return self.calls.withLockedValue { $0.abandon(msgid: msgid) }
                .map { parked in self.resolve(parked, as: Response.self, start: start) }
                ?? .failure(error is CancellationError ? .cancelled : .connectionClosed)
        }
        let outcome: CallTable.Outcome = await withParkedContinuation(
            register: { continuation in
                self.calls.withLockedValue {
                    $0.register(msgid: msgid, continuation: continuation)
                }
            },
            takeParkedOnCancel: {
                self.calls.withLockedValue { $0.cancel(msgid: msgid) }
            },
            cancelled: .failure(.cancelled)
        )
        return self.resolve(outcome, as: Response.self, start: start)
    }

    private nonisolated func resolve<Response: Codable & Sendable>(
        _ outcome: CallTable.Outcome,
        as _: Response.Type,
        start: ContinuousClock.Instant
    ) -> Result<Response, MMCallError> {
        outcome
            .tap { _ in
                self.metrics.callRoundtrip.record(duration: start.duration(to: .now))
            }
            // The shared unary/terminal decode rule (spec §4) —
            // ``ResponseSlots/decodeResponse(_:)``.
            .flatMap { slots in slots.decodeResponse(Response.self) }
    }

    /// Waits for the outbound writer that `run()` produces. Cancellation-safe:
    /// a cancelled waiter resumes with `.cancelled` even if `run()` never
    /// starts.
    private nonisolated func awaitWriter() async -> Result<Writer, MMCallError> {
        let id = self.calls.withLockedValue { $0.allocateWriterWaiterID() }
        return await withParkedContinuation(
            register: { continuation in
                self.calls.withLockedValue {
                    $0.registerWriterWaiter(id: id, continuation: continuation)
                }
            },
            takeParkedOnCancel: {
                self.calls.withLockedValue { $0.cancelWriterWaiter(id: id) }
            },
            cancelled: .failure(.cancelled)
        )
    }

    // MARK: - Stream open (internal, shared by the typed overloads)

    /// Writes one already-encoded envelope through the outbound writer,
    /// awaiting the writer if `run()` has not produced it yet. Returns whether
    /// the frame reached the transport (false on connection death or a local
    /// failure). Used for every post-open stream frame (items, credits, END,
    /// STOP, CANCEL). Best-effort by design: a failed write means the connection
    /// is dying and the terminal resolves the call — no error is surfaced here.
    nonisolated func writeStreamFrame(_ envelope: MMEnvelope) async -> Bool {
        // Best-effort: the errors carry no information here, so each stage
        // erases to an optional. The size gate drops an oversized frame
        // locally rather than poison the frame encoder (connection-fatal for
        // every call).
        guard
            let frame = try? envelope.encoded().get(),
            frame.readableBytes <= Int(self.configuration.maxFrameLength),
            let writer = try? await self.awaitWriter().get()
        else {
            return false
        }

        return (try? await writer.write(frame)) != nil
    }

    /// Opens a streaming call: encodes and sends the opening request (the normal
    /// untyped `call(methodName:)` open path — msgid reservation, in-flight cap, outbound cap,
    /// writer wait), builds the stream state with its wire sinks, and installs
    /// the control in the CallTable. Local failures before the control is
    /// installed (encode, cap, connection closed) are surfaced by pre-resolving
    /// the stream state's terminal, so the returned handle uniformly reports
    /// failures through `result()` with an empty element sequence — server-side
    /// authorization failures arrive the same way, as the terminal frame.
    nonisolated func openStream<
        Inbound: Codable & Sendable,
        Outbound: Codable & Sendable,
        Response: Codable & Sendable
    >(
        methodName: String,
        entity: EntityName,
        request: some Codable & Sendable,
        hasResponseStream: Bool,
        hasRequestStream: Bool,
        inbound _: Inbound.Type,
        outbound _: Outbound.Type,
        response _: Response.Type
    ) async -> ClientStreamState<Inbound, Outbound, Response> {
        self.metrics.streamsOpened.increment()
        // The shared send path; a pre-send failure resolves the terminal
        // immediately on a state that never entered the table.
        return await self.prepareRequestSend(
            methodName: methodName,
            entity: entity,
            request: request
        )
        .matchAsync(
            { msgid, frame, writer in
                await self.openPreparedStream(
                    msgid: msgid,
                    frame: frame,
                    writer: writer,
                    methodName: methodName,
                    hasResponseStream: hasResponseStream,
                    hasRequestStream: hasRequestStream,
                    inbound: Inbound.self,
                    outbound: Outbound.self,
                    response: Response.self
                )
            },
            { error in
                self.failedStream(
                    hasResponseStream: hasResponseStream,
                    hasRequestStream: hasRequestStream,
                    error: error
                )
            }
        )
    }

    /// The post-prepare half of ``openStream``: write the opening request,
    /// build the stream state with its wire sinks, install it in the table,
    /// and hand it any terminal that raced ahead.
    private nonisolated func openPreparedStream<
        Inbound: Codable & Sendable,
        Outbound: Codable & Sendable,
        Response: Codable & Sendable
    >(
        msgid: UInt32,
        frame: ByteBuffer,
        writer: Writer,
        methodName: String,
        hasResponseStream: Bool,
        hasRequestStream: Bool,
        inbound _: Inbound.Type,
        outbound _: Outbound.Type,
        response _: Response.Type
    ) async -> ClientStreamState<Inbound, Outbound, Response> {
        do {
            try await writer.write(frame)
        } catch {
            // The open request never reached the wire. Reclaim the reservation
            // (claiming a parked terminal if one somehow raced) and fail the
            // handle. Cancellation and death both land here.
            let parked = self.calls.withLockedValue { $0.abandon(msgid: msgid) }
            let reason: MMCallError
            switch parked {
                case .some(.success(let slots)) where slots.error != nil:
                    // A terminal raced in before the write failed: honor it.
                    reason = .from(error: slots.error!)
                case .some(.failure(let closeReason)):
                    // The connection closed and parked the reservation as a failure.
                    reason = closeReason
                case .some(.success), .none:
                    // No terminal raced (or a nil-error terminal, impossible for an
                    // un-installed stream): the write failed on cancellation or death.
                    reason = error is CancellationError ? .cancelled : .connectionClosed
            }
            return self.failedStream(
                hasResponseStream: hasResponseStream,
                hasRequestStream: hasRequestStream,
                error: reason
            )
        }

        // The open request is on the wire. Build the state with its wire sinks,
        // then install it — claiming a terminal that raced ahead of the install.
        let state = self.makeStreamState(
            msgid: msgid,
            hasResponseStream: hasResponseStream,
            hasRequestStream: hasRequestStream,
            inbound: Inbound.self,
            outbound: Outbound.self,
            response: Response.self
        )
        // A terminal (or a close) that resolved before the control was
        // installed is handed to the state so `result()` sees it.
        self.calls.withLockedValue { $0.installStream(msgid: msgid, control: state) }?
            .match(state.resolveTerminal, state.failTerminal)
        return state
    }

    /// The open-request send path every call shape shares: encode params,
    /// reserve a msgid under the in-flight cap, build the envelope, enforce
    /// the outbound frame cap *before* the pipeline (`MMFrameEncoder` would
    /// throw at the handler seam, poisoning the encoder and tearing down the
    /// whole connection — one oversized request must fail one call, locally),
    /// and obtain the writer. Two phases: before the reservation a failure
    /// needs no cleanup; after it, *every* failure must reclaim the msgid —
    /// stated once, as the `tapError` on the composed second phase, so a new
    /// failure site cannot forget it. Callers map the `MMCallError` into
    /// their own failure shape.
    private nonisolated func prepareRequestSend(
        methodName: String,
        entity: EntityName,
        request: some Codable & Sendable
    ) async -> Result<(msgid: UInt32, frame: ByteBuffer, writer: Writer), MMCallError> {
        await MMPackEncoder().encode(request)
            .mapError { MMCallError.encode($0) }
            .flatMap { params in
                self.calls.withLockedValue {
                    $0.reserve(cap: self.configuration.maxInFlightCalls)
                }
                .map { msgid in (msgid: msgid, params: params) }
            }
            .flatMapAsync { msgid, params in
                await self.frameAndWriter(
                    msgid: msgid, methodName: methodName, entity: entity, params: params
                )
                .tapError { _ in
                    _ = self.calls.withLockedValue { $0.abandon(msgid: msgid) }
                }
            }
    }

    /// The post-reservation half of ``prepareRequestSend``: envelope encode,
    /// the outbound size gate, and the writer wait. Owns no cleanup — the
    /// caller reclaims the reservation on any failure.
    private nonisolated func frameAndWriter(
        msgid: UInt32,
        methodName: String,
        entity: EntityName,
        params: ByteBuffer
    ) async -> Result<(msgid: UInt32, frame: ByteBuffer, writer: Writer), MMCallError> {
        await MMEnvelope.request(
            msgid: msgid,
            method: methodName,
            entity: entity.rawValue,
            params: params
        )
        .encoded()
        .mapError { MMCallError.encode($0) }
        .flatMap { frame in
            frame.readableBytes <= Int(self.configuration.maxFrameLength)
                ? .success(frame)
                : .failure(
                    .encode(
                        .frameTooLarge(
                            length: UInt32(clamping: frame.readableBytes),
                            limit: self.configuration.maxFrameLength
                        )
                    )
                )
        }
        .flatMapAsync { frame in
            await self.awaitWriter().map { writer in (msgid: msgid, frame: frame, writer: writer) }
        }
    }

    /// Builds a stream state wired to write its own lifecycle frames through the
    /// connection's outbound writer.
    private nonisolated func makeStreamState<
        Inbound: Codable & Sendable,
        Outbound: Codable & Sendable,
        Response: Codable & Sendable
    >(
        msgid: UInt32,
        hasResponseStream: Bool,
        hasRequestStream: Bool,
        inbound _: Inbound.Type,
        outbound _: Outbound.Type,
        response _: Response.Type
    ) -> ClientStreamState<Inbound, Outbound, Response> {
        let sinks = ClientStreamSinks(
            grantCredit: { [self] credits in
                _ = await self.writeStreamFrame(.credit(msgid: msgid, credits: credits))
            },
            sendItem: { [self] seq, item in
                await self.writeStreamFrame(.item(msgid: msgid, seq: seq, item: item))
            },
            sendEnd: { [self] in
                _ = await self.writeStreamFrame(.end(msgid: msgid))
            },
            sendStop: { [self] in
                _ = await self.writeStreamFrame(.stop(msgid: msgid, code: 0))
            },
            sendCancel: { [self] in
                // A CANCEL retires the stream locally in the table so the
                // server's later code-7 terminal drops; then the frame goes out.
                _ = self.calls.withLockedValue { $0.retireStreamForCancel(msgid: msgid) }
                _ = await self.writeStreamFrame(.cancel(msgid: msgid))
            }
        )
        let state = ClientStreamState<Inbound, Outbound, Response>(
            msgid: msgid,
            hasResponseStream: hasResponseStream,
            hasRequestStream: hasRequestStream,
            sinks: sinks,
            logger: self.logger,
            metrics: self.metrics
        )
        let new = ClientStreamState<Inbound, Outbound, Response>.Producer.makeSequence(
            elementType: Inbound.self,
            backPressureStrategy: .init(
                lowWatermark: StreamBackpressure.lowWatermark,
                highWatermark: StreamBackpressure.highWatermark
            ),
            finishOnDeinit: false,
            delegate: state
        )
        state.adopt(source: new.source, sequence: new.sequence)
        return state
    }

    /// A stream state that never entered the CallTable, born with its
    /// terminal already failed — the uniform handle for every local pre-send
    /// failure (encode, cap, connection closed): `result()` reports the
    /// error, the element sequence is empty (already finished). Server-side
    /// authorization failures never come through here; they arrive as the
    /// normal terminal frame on an installed stream.
    private nonisolated func failedStream<
        Inbound: Codable & Sendable,
        Outbound: Codable & Sendable,
        Response: Codable & Sendable
    >(
        hasResponseStream: Bool,
        hasRequestStream: Bool,
        error: MMCallError
    ) -> ClientStreamState<Inbound, Outbound, Response> {
        // msgid 0 is only a log label here; the state is not in the table.
        let state = self.makeStreamState(
            msgid: 0,
            hasResponseStream: hasResponseStream,
            hasRequestStream: hasRequestStream,
            inbound: Inbound.self,
            outbound: Outbound.self,
            response: Response.self
        )
        state.failTerminal(error)
        return state
    }

    // MARK: - State

    /// The connection's current lifecycle state.
    public nonisolated var state: ClientState {
        self.states.withLockedValue { $0.current }
    }

    /// A stream of state changes for this connection.
    ///
    /// This is the sanctioned coalesced-signal `AsyncStream` (house-rule
    /// exception), and it qualifies because state is a *level*, not a data
    /// stream: there is exactly one transition ever (`connected` → `closed`),
    /// consumers only care about the latest level, and dropping a superseded
    /// element is correct by construction. Buffering is bounded at
    /// `.bufferingNewest(1)` and `onTermination` is wired to unregister the
    /// subscriber, so an abandoned stream leaks nothing and a loop-side yield
    /// after consumer cancellation goes nowhere. Data paths (responses, stream
    /// items) never touch this mechanism.
    ///
    /// Each call returns an independent stream; it yields the current state
    /// (possibly already `.closed`) and finishes after the terminal `.closed`.
    public nonisolated func stateUpdates() -> AsyncStream<ClientState> {
        AsyncStream(ClientState.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let states = self.states
            let terminal: ClientState? = states.withLockedValue { hub in
                switch hub.current {
                    case .closed:
                        return hub.current
                    case .connected:
                        hub.nextSubscriberID &+= 1
                        let id = hub.nextSubscriberID
                        hub.subscribers[id] = continuation
                        continuation.onTermination = { _ in
                            states.withLockedValue { _ = $0.subscribers.removeValue(forKey: id) }
                        }
                        // Yield the initial state under the same lock that
                        // registered the subscriber (yield is synchronous and
                        // non-suspending, so the lock discipline holds).
                        // Registration + initial yield must be atomic with
                        // respect to finish()'s drain: a .connected yielded after
                        // the drain could land between the drain's .closed and
                        // its finish(), evicting the terminal element from the
                        // .bufferingNewest(1) buffer.
                        continuation.yield(.connected)
                        return nil
                }
            }
            if let terminal {
                continuation.yield(terminal)
                continuation.finish()
            }
        }
    }

    // MARK: - Close

    /// Closes the connection. Idempotent. If `run()` is active it observes the
    /// close, fails pending calls, and returns; if `run()` never started, the
    /// channel is torn down here (finishing the writer) and the pending state
    /// failed directly, so no caller parks forever. There is no drain:
    /// in-flight calls fail with `.connectionClosed` — a caller wanting their
    /// responses awaits them before closing. Every connected
    /// `MMClientConnection` must eventually see `run()` or `close()`.
    public func close() async {
        switch self.lifecycle {
            case .running, .finished:
                // run() owns (or owned) the scoped teardown; just signal.
                self.channel.channel.close(promise: nil)
            case .idle:
                self.lifecycle = .finished
                try? await self.channel.executeThenClose { _, _ in }
                self.finish(reason: nil)
        }
    }

    /// Terminal transition, idempotent (the first reason wins): fails all
    /// pending calls and writer waiters, moves the state to `.closed`, and
    /// finishes every state subscriber.
    private nonisolated func finish(reason: MMClientError?) {
        let callFailure: MMCallError
        switch reason {
            case nil, .protocolViolation:
                callFailure = .connectionClosed
            case .transport(let description):
                callFailure = .transport(description: description)
            case .some(let other):
                callFailure = .transport(description: String(describing: other))
        }
        // A verdict that never got to run (closed before run(), or death mid
        // discovery) fails so no awaiter parks forever; a verdict already
        // resolved wins (the cell is first-resolution-wins).
        self.verification.failure(
            self.configuration.schema == nil ? .noExpectation : .failed(callFailure)
        )
        let (pending, writerWaiters, streams) = self.calls.withLockedValue {
            $0.close(reason: callFailure)
        }
        for continuation in pending {
            continuation.resume(returning: .failure(callFailure))
        }
        for waiter in writerWaiters {
            waiter.resume(returning: .failure(callFailure))
        }
        // Fail every live stream's terminal (and finish its inbound sequence and
        // release any parked sender) with the connection-death reason — exactly
        // like a unary call, resolved exactly once.
        for control in streams {
            control.failTerminal(callFailure)
        }
        let subscribers = self.states.withLockedValue {
            hub -> [AsyncStream<ClientState>.Continuation] in
            guard case .connected = hub.current else { return [] }
            hub.current = .closed(reason: reason)
            let drained = Array(hub.subscribers.values)
            hub.subscribers.removeAll()
            return drained
        }
        for subscriber in subscribers {
            subscriber.yield(.closed(reason: reason))
            subscriber.finish()
        }
    }

    // MARK: - Test seams

    /// Test-only: seeds the next msgid so wrap-around is reachable without
    /// 2^32 calls.
    nonisolated func _seedNextMsgid(_ value: UInt32) {
        self.calls.withLockedValue { $0.nextMsgid = value }
    }
}

/// State-sequence subscriber registry; lives in a `NIOLockedValueBox` because
/// `AsyncStream` termination handlers are synchronous.
struct StateHub: Sendable {
    var current: ClientState = .connected
    var subscribers: [UInt64: AsyncStream<ClientState>.Continuation] = [:]
    var nextSubscriberID: UInt64 = 0
}

/// swift-metrics instruments, created per connection (labels are process-wide;
/// the backend aggregates). Library code bootstraps nothing.
struct ClientMetrics: Sendable {
    let calls = Counter(label: "mm_client_calls_total")
    let callFailures = Counter(label: "mm_client_call_failures_total")
    let responsesUnmatched = Counter(label: "mm_client_responses_unmatched_total")
    let protocolViolations = Counter(label: "mm_client_protocol_violations_total")
    let streamFramesDropped = Counter(label: "mm_client_stream_frames_dropped_total")
    let streamItemDecodeFailures = Counter(label: "mm_client_stream_item_decode_failures_total")
    let streamsOpened = Counter(label: "mm_client_streams_opened_total")
    let callRoundtrip = Metrics.Timer(label: "mm_client_call_roundtrip_ns")
}
