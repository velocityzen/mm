import Logging
import MMSchema
import MMWire
import Metrics
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ServiceLifecycle

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Startup failures of ``MMService``. Thrown from `run()` before the
/// accept loop starts; steady-state failures never use this type — they are
/// logged per connection and the connection closed.
public enum MMServiceError: Error, Sendable, Hashable {
    /// A live server is already listening on the unix socket path (the
    /// liveness probe's `connect(2)` succeeded). Startup fails rather than
    /// stealing the path.
    case socketPathInUse(path: String)
    /// Something that is not a socket exists at the unix socket path. Never
    /// unlinked — refusing to delete unknown files is deliberate.
    case socketPathOccupied(path: String)
    /// The unix socket path is empty or too long for `sockaddr_un.sun_path`.
    case invalidSocketPath(path: String)
    /// A startup syscall failed in a non-branch-worthy way. Coarse by design:
    /// startup infrastructure failures are for logs, not `switch`.
    case io(description: String)
}

/// The transport: binds an ``MMEndpoint``, accepts connections, runs the hello
/// exchange and per-connection request loop, and dispatches through the
/// ``Router``. Conforms to swift-service-lifecycle's `Service`.
///
/// Every server auto-registers the builtin methods (`rpc.schema`,
/// `entity.stat`): the initializer constructs its ``Router`` with
/// `registerBuiltins: true`, so discovery and ACL inspection exist without
/// user code.
///
/// ## Lifecycle recipe (host application)
///
/// Run the service inside a `ServiceGroup` and map signals conventionally —
/// SIGTERM (systemd/launchd stop) to graceful shutdown, SIGINT (dev Ctrl-C)
/// to cancellation:
///
/// ```swift
/// let server = MMService(configuration: config, aclProvider: acls) { … }
/// let group = ServiceGroup(configuration: .init(
///     services: [.init(service: server)],
///     gracefulShutdownSignals: [.sigterm],
///     cancellationSignals: [.sigint],
///     logger: logger
/// ))
/// try await group.run()
/// ```
///
/// ## Graceful shutdown semantics
///
/// On graceful shutdown the server (1) stops accepting — the listening channel
/// closes; (2) every open connection — including one still waiting for its
/// peer's hello — stops *reading* (input-half close) while in-flight handlers
/// complete and their responses flush through the connection's writer;
/// (3) connection channels close; (4) for unix endpoints, the socket file is
/// removed, unless another server instance has already replaced it at the same
/// path during the drain (the file's device/inode is compared against the one
/// this instance bound — see `removeSocketFile`); then `run()` returns.
/// Cancellation instead tears connections down immediately via
/// `executeThenClose` and task-group cancellation — no descriptors leak on
/// either path.
public struct MMService: Service {
    /// The assembled router, exposed for its `fingerprint` and `signatures`.
    public let router: Router

    private let configuration: MMServerConfiguration
    private let group: any EventLoopGroup
    private let threadPool: NIOThreadPool
    private let logger: Logger
    private let onBind: (@Sendable (SocketAddress) -> Void)?
    private let serverHello: MMHello

    private let connectionsAccepted: Counter
    private let connectionsRejected: Counter
    private let framesIn: Counter
    private let framesOut: Counter
    private let protocolViolations: Counter
    private let acceptFailures: Counter
    private let activeConnectionsGauge: Gauge
    /// Stream frames dropped for an unknown/retired msgid, or an advisory frame
    /// legal to ignore (same label the router used transitionally in S1/S2).
    private let streamFramesDropped: Counter

    private enum TransportKind: Sendable {
        case unix
        case tcp
    }

    /// Assembles a server: builds the router (with builtins), computes the
    /// hello preamble from the router's fingerprint, and prepares metrics.
    ///
    /// - Parameters:
    ///   - configuration: Endpoint and hardening caps.
    ///   - namespaces: Sealed descriptor namespaces cross-checked against the
    ///     registered routes at startup (see
    ///     ``Router/init(namespaces:sharedTypes:aclProvider:logger:registerBuiltins:routes:)``).
    ///   - sharedTypes: Types-only `TypeNamespace` containers whose
    ///     definitions join the router's type table (see
    ///     ``Router/init(namespaces:sharedTypes:aclProvider:logger:registerBuiltins:routes:)``).
    ///   - aclProvider: The host's ACL source, consulted per dispatch.
    ///   - eventLoopGroup: NIO event loops; defaults to the process singleton.
    ///   - threadPool: Used for startup socket syscalls and (on Linux) the
    ///     one-time `/proc` supplementary-groups read; defaults to the process
    ///     singleton.
    ///   - logger: Base logger; per-connection ids ride in metadata.
    ///   - onBind: Invoked once with the bound local address before accepting
    ///     — how hosts (and tests) learn the ephemeral port of a
    ///     `tcp(host:port: 0)` endpoint.
    ///   - routes: The application's routes, built with `Handle`.
    public init(
        configuration: MMServerConfiguration,
        namespaces: [any MethodNamespace.Type] = [],
        sharedTypes: [any TypeNamespace.Type] = [],
        aclProvider: any EntityACLProvider,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        threadPool: NIOThreadPool = .singleton,
        logger: Logger = Logger(label: "mm.server"),
        onBind: (@Sendable (SocketAddress) -> Void)? = nil,
        @RouterBuilder routes: () -> [Route]
    ) {
        var serviceLogger = logger
        serviceLogger[metadataKey: "service"] = "mm.server"
        self.configuration = configuration
        self.group = eventLoopGroup
        self.threadPool = threadPool
        self.logger = serviceLogger
        self.onBind = onBind
        self.router = Router(
            namespaces: namespaces,
            sharedTypes: sharedTypes,
            aclProvider: aclProvider,
            logger: serviceLogger,
            registerBuiltins: true,
            routes: routes
        )
        self.serverHello = MMHello(
            protocolVersion: MMWireInfo.protocolVersion,
            schemaFingerprint: self.router.fingerprint,
            capabilities: configuration.capabilities
        )
        self.connectionsAccepted = Counter(label: "mm_server_connections_accepted_total")
        self.connectionsRejected = Counter(label: "mm_server_connections_rejected_total")
        self.framesIn = Counter(label: "mm_server_frames_in_total")
        self.framesOut = Counter(label: "mm_server_frames_out_total")
        self.protocolViolations = Counter(label: "mm_server_protocol_violations_total")
        self.acceptFailures = Counter(label: "mm_server_accept_failures_total")
        self.activeConnectionsGauge = Gauge(label: "mm_server_active_connections")
        self.streamFramesDropped = Counter(label: "mm_server_stream_frames_dropped_total")
    }

    // MARK: - Service

    public func run() async throws {
        switch self.configuration.endpoint {
            case .unix(let path):
                try await self.runUnixDomainSocket(path: path)
            case .tcp(let host, let port):
                try await self.runTCP(host: host, port: port)
        }
    }

    // MARK: - Bind

    private func runUnixDomainSocket(path: String) async throws {
        // Startup socket work is blocking syscalls (connect probe, bind) —
        // run on the thread pool, never on a loop or the cooperative pool.
        try await self.threadPool.runIfActive {
            try Self.prepareUnixSocketPath(path)
        }
        let mode = mode_t(self.configuration.unixSocketMode)
        // The bound file's device/inode identity is captured immediately so
        // the shutdown unlink can prove the path still holds *this* server's
        // socket — a slow drain must never delete a successor's file.
        let (descriptor, fileIdentity) = try await self.threadPool.runIfActive {
            let descriptor = try Self.makeBoundUnixSocket(path: path, mode: mode)
            return (descriptor, Self.socketFileIdentity(path: path))
        }

        let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
        do {
            // NIO adopts the descriptor and calls listen(2) itself — see
            // makeBoundUnixSocket for why chmod already happened.
            server = try await ServerBootstrap(group: self.group)
                .serverChannelInitializer { channel in
                    self.initializeServerChannel(channel)
                }
                // Half-closure is load-bearing for the graceful drain: the
                // shutdown path closes the input half (see handleConnection)
                // and expects in-flight responses to keep flushing. Without
                // this option, Linux (epoll) reports the shut-down input as
                // read-EOF and NIO escalates it to a full channel close,
                // killing the write side before terminals flush; kqueue does
                // not, which is how the drain worked on Darwin only.
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .bind(descriptor) { channel in
                    self.initializeChildChannel(channel)
                }
        } catch {
            // Adoption failed. NIO closes the descriptor on every post-creation
            // failure path; the pre-creation ones may leave it open, but
            // closing here would risk double-closing a possibly reused fd.
            // Startup failure is fatal to the service, so the bounded leak is
            // the safer trade. Remove the never-served socket file.
            Self.removeSocketFile(path: path, owned: fileIdentity, logger: self.logger)
            throw error
        }
        self.logger.info("server listening", metadata: ["path": "\(path)"])
        if let address = server.channel.localAddress {
            self.onBind?(address)
        }

        do {
            try await self.acceptLoop(server: server, transport: .unix)
        } catch {
            Self.removeSocketFile(path: path, owned: fileIdentity, logger: self.logger)
            throw error
        }
        // Graceful-shutdown ordering: acceptLoop returns only after every
        // connection drained and closed; the socket file goes last.
        Self.removeSocketFile(path: path, owned: fileIdentity, logger: self.logger)
    }

    private func runTCP(host: String, port: Int) async throws {
        let server = try await ServerBootstrap(group: self.group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in
                self.initializeServerChannel(channel)
            }
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            // Same rationale as the unix bootstrap: the graceful-shutdown
            // input close must not escalate to a full close on Linux.
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .bind(host: host, port: port) { channel in
                self.initializeChildChannel(channel)
            }
        self.logger.info(
            "server listening",
            metadata: [
                "address": "\(server.channel.localAddress.map(String.init(describing:)) ?? "-")"
            ]
        )
        if let address = server.channel.localAddress {
            self.onBind?(address)
        }
        try await self.acceptLoop(server: server, transport: .tcp)
    }

    /// Server (listening) channel pipeline: just the accept-error filter that
    /// keeps a peer connecting-and-resetting from failing the accept stream
    /// (see ``AcceptErrorFilterHandler``). Runs before NIO adds its own
    /// accept machinery, so the filter sits closest to the head and sees the
    /// error first.
    private func initializeServerChannel(_ channel: any Channel) -> EventLoopFuture<Void> {
        let logger = self.logger
        let acceptFailures = self.acceptFailures
        return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(
                AcceptErrorFilterHandler(logger: logger, acceptFailures: acceptFailures)
            )
        }
    }

    private func initializeChildChannel(
        _ channel: any Channel
    ) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> {
        let maxFrameLength = self.configuration.maxFrameLength
        let idleTimeout = self.configuration.idleTimeout
        let serverHello = self.serverHello
        let violations = self.protocolViolations
        return channel.eventLoop.makeCompletedFuture {
            try Self.configureChildPipeline(
                channel: channel,
                maxFrameLength: maxFrameLength,
                idleTimeout: idleTimeout,
                serverHello: serverHello,
                protocolViolations: violations
            )
        }
    }

    /// Per-connection pipeline, head to tail: idle timeout (+ close on idle,
    /// which also reaps pre-hello dead clients), framing codec with the
    /// configured cap, then the hello handler. Must run on the channel's
    /// event loop. Internal so handler assembly is testable on
    /// `EmbeddedChannel`.
    ///
    /// Idleness is judged on **all** traffic (`allTimeout`), not reads alone:
    /// a consumer of a server→client stream legitimately sends nothing while
    /// the server actively pushes items to it, so outbound writes count as
    /// liveness and keep the connection open. A peer that neither sends nor
    /// receives for the timeout is reaped.
    static func configureChildPipeline(
        channel: any Channel,
        maxFrameLength: UInt32,
        idleTimeout: TimeAmount,
        serverHello: MMHello,
        protocolViolations: Counter
    ) throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        let sync = channel.pipeline.syncOperations
        try sync.addHandler(IdleStateHandler(allTimeout: idleTimeout))
        try sync.addHandler(IdleCloseHandler())
        try sync.addHandler(ByteToMessageHandler(MMFrameDecoder(maxFrameLength: maxFrameLength)))
        try sync.addHandler(MessageToByteHandler(MMFrameEncoder(maxFrameLength: maxFrameLength)))
        try sync.addHandler(
            ServerHelloHandler(serverHello: serverHello, protocolViolations: protocolViolations)
        )
        return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
    }

    // MARK: - Accept loop

    private func acceptLoop(
        server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>,
        transport: TransportKind
    ) async throws {
        // Shared with connection child tasks for the decrement, hence a locked
        // box rather than accept-loop-local state. A counter, not domain state.
        let activeConnections = NIOLockedValueBox(0)
        try await withThrowingDiscardingTaskGroup { connections in
            try await server.executeThenClose { acceptStream in
                try await withGracefulShutdownHandler {
                    var nextConnectionID: UInt64 = 0
                    for try await connection in acceptStream {
                        nextConnectionID &+= 1
                        // Cap enforced AT accept, before any child task exists.
                        let admitted = activeConnections.withLockedValue { count in
                            guard count < self.configuration.maxConnections else { return false }
                            count += 1
                            return true
                        }
                        guard admitted else {
                            // Busy-rejection choice: close immediately, no busy
                            // frame. Pre-hello there is no msgid to correlate an
                            // error response to, and inventing a hello-level busy
                            // code is a capability for a future version. The
                            // pipeline may already have flushed the server hello
                            // at activation; a rejected peer can observe it
                            // before the close.
                            self.connectionsRejected.increment()
                            self.logger.debug(
                                "connection rejected",
                                metadata: ["reason": "connection_cap"]
                            )
                            connections.addTask {
                                // Empty executeThenClose is the sanctioned
                                // teardown: it finishes the outbound writer and
                                // closes the channel (a bare close would trip
                                // NIOAsyncWriter's finish precondition).
                                try? await connection.executeThenClose { _, _ in }
                            }
                            continue
                        }
                        self.connectionsAccepted.increment()
                        self.activeConnectionsGauge.record(
                            activeConnections.withLockedValue { $0 }
                        )
                        let connectionID = nextConnectionID
                        connections.addTask {
                            // Task-local binding: hosts that bootstrap
                            // swift-log with MMLogContext.metadataProvider get
                            // the connection id on every log line in this task
                            // tree, including application handler bodies.
                            await MMLogContext.$connectionID.withValue(connectionID) {
                                await self.handleConnection(
                                    connection,
                                    connectionID: connectionID,
                                    transport: transport
                                )
                            }
                            let remaining = activeConnections.withLockedValue { count in
                                count -= 1
                                return count
                            }
                            self.activeConnectionsGauge.record(remaining)
                        }
                    }
                } onGracefulShutdown: {
                    // Stop accepting; the accept stream finishes and the group
                    // then waits for open connections to drain.
                    server.channel.close(promise: nil)
                }
            }
        }
    }

    // MARK: - Per-connection

    private func handleConnection(
        _ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        connectionID: UInt64,
        transport: TransportKind
    ) async {
        var logger = self.logger
        logger[metadataKey: "connection"] = "\(connectionID)"
        let channel = connection.channel
        do {
            // Graceful-shutdown coverage starts BEFORE the first await on the
            // channel: a connection still waiting for its peer's hello would
            // otherwise be invisible to shutdown and stall the whole drain
            // until the idle timeout (or indefinitely, against a peer that
            // trickles bytes without ever completing a frame). Input-half
            // close is safe in every phase — it ends the hello read and the
            // request loop alike (the inbound stream finishes), while
            // in-flight handlers still complete and their responses flush
            // through the writer before `executeThenClose` closes the channel.
            try await withGracefulShutdownHandler {
                try await self.serveConnection(
                    connection,
                    connectionID: connectionID,
                    transport: transport,
                    logger: logger
                )
            } onGracefulShutdown: {
                channel.close(mode: .input, promise: nil)
            }
        } catch {
            // The per-connection do/catch — the only one on the data path.
            // Cancellation and transport failures both land here;
            // executeThenClose has already closed the channel.
            logger.debug(
                "connection ended",
                metadata: ["error": "\(error)"]
            )
        }
    }

    private func serveConnection(
        _ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        connectionID: UInt64,
        transport: TransportKind,
        logger: Logger
    ) async throws {
        try await connection.executeThenClose { inbound, outbound in
            // Peer identity, frozen for the connection's lifetime. TCP has
            // no kernel credentials in v1: anonymous, no syscalls.
            let peer: PeerIdentity
            switch transport {
                case .tcp:
                    peer = .anonymous
                case .unix:
                    switch await PeerCredentials.captureUnixPeer(
                        channel: connection.channel,
                        threadPool: self.threadPool
                    ) {
                        case .success(let identity):
                            peer = identity
                        case .failure(let error):
                            // Fail closed: identity is the only authorization
                            // input, so no identity means no dispatch.
                            logger.warning(
                                "peer credential capture failed",
                                metadata: ["error": "\(error)"]
                            )
                            return
                    }
            }

            // Hello exchange: the server hello went out at channel
            // activation (ServerHelloHandler); the peer's first frame
            // must be its hello. The handler already closed on garbage,
            // in which case the stream ends before yielding a frame. On
            // graceful shutdown the input-half close (registered by
            // handleConnection) ends this read with a nil frame.
            var frames = inbound.makeAsyncIterator()
            guard let helloFrame = try await frames.next() else {
                return
            }
            guard case .success(let clientHello) = MMHello.decode(from: helloFrame) else {
                // Defensive only — the hello handler forwards nothing
                // that does not decode.
                self.protocolViolations.increment()
                return
            }
            let negotiated = HelloNegotiation.negotiate(
                server: self.serverHello,
                client: clientHello
            )
            // Fingerprint mismatch is NOT checked: schema discovery is the
            // client's concern, never a reason to disconnect. Negotiated
            // capabilities are logged only — v1 defines no bits and
            // MMContext (part A, frozen API) carries the version.
            logger.debug(
                "hello exchanged",
                metadata: [
                    "peer_uid": "\(peer.uid)",
                    "peer_pid": "\(peer.pid)",
                    "version": "\(negotiated.protocolVersion)",
                    "capabilities": "\(negotiated.capabilities)",
                ]
            )

            let writer = ConnectionWriter(outbound: outbound, framesOut: self.framesOut)
            let context = MMContext(
                peer: peer,
                protocolVersion: negotiated.protocolVersion,
                connectionID: connectionID
            )

            await self.requestLoop(
                frames: frames,
                writer: writer,
                context: context,
                logger: logger
            )
        }
    }

    /// The request loop: decode envelope → route.
    ///
    /// - **Unary request** (kind 1 to a unary route): dispatched in a bounded
    ///   child task — never more than the configured in-flight cap, never
    ///   queued beyond it. Over cap → immediate `tooManyInFlight`. Byte-for-byte
    ///   unchanged from the pre-streaming path, save the unary-msgid guard the
    ///   stream table needs.
    /// - **Stream open** (kind 1 to a stream route): authorized inline (in frame
    ///   order, so the stream is registered before any following item), then run
    ///   as a long-lived handler child task. Counted against
    ///   `maxConcurrentStreamsPerConnection`, *not* the unary in-flight cap.
    /// - **Stream lifecycle** (kinds 2–6): routed to the ``StreamRuntime`` inline
    ///   and in order — seq validation is per-connection sequential. Frames for
    ///   unknown/retired msgids drop-and-count; violations answer with a code-6
    ///   terminal; the graceful frames apply their effect.
    /// - **Inbound response**: a peer protocol error, logged and dropped
    ///   through `router.dispatch`.
    /// - A frame that fails envelope decode is a protocol violation: logged,
    ///   counted, and the connection closed (the loop returns; in-flight
    ///   handlers and live streams drain first — see the drain below).
    private func requestLoop(
        frames: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator,
        writer: ConnectionWriter,
        context: MMContext,
        logger: Logger
    ) async {
        var frames = frames
        let cap = self.configuration.maxInFlightRequestsPerConnection
        let inFlight = NIOLockedValueBox(0)
        let streams = StreamRuntime(
            writer: writer,
            metrics: MMStreamMetrics(),
            maxConcurrentStreams: self.configuration.maxConcurrentStreamsPerConnection,
            logger: logger
        )
        await withDiscardingTaskGroup { handlers in
            do {
                while let frame = try await frames.next() {
                    self.framesIn.increment()
                    let envelope: MMEnvelope
                    switch MMEnvelope.decode(from: frame) {
                        case .failure(let error):
                            self.protocolViolations.increment()
                            logger.debug(
                                "envelope decode failed",
                                metadata: ["error": "\(error)"]
                            )
                            break  // out of the switch; the while condition re-checked
                        case .success(let decoded):
                            envelope = decoded
                            await self.route(
                                envelope,
                                streams: streams,
                                handlers: &handlers,
                                inFlight: inFlight,
                                cap: cap,
                                writer: writer,
                                context: context,
                                logger: logger
                            )
                            continue
                    }
                    // Decode failure: close the connection (drain first, below).
                    break
                }
            } catch {
                // Transport failure while reading — including
                // MMWireError.frameTooLarge thrown by the frame decoder for an
                // oversized claim. Log; the loop ends and the channel closes.
                logger.debug(
                    "connection read failed",
                    metadata: ["error": "\(error)"]
                )
            }
            // The read loop ended (peer EOF, graceful-shutdown input close,
            // decode violation, or transport error): drain live streams so their
            // handlers unwind and flush terminals through the writer, then the
            // discarding group waits for every handler (unary and stream) to
            // finish before returning.
            streams.drain()
        }
    }

    /// Routes one decoded inbound envelope. Kept off `requestLoop` so the loop
    /// body stays legible; the `handlers` group is passed `inout` so unary and
    /// stream handlers become children of the connection's one task group.
    private func route(
        _ envelope: MMEnvelope,
        streams: StreamRuntime,
        handlers: inout DiscardingTaskGroup,
        inFlight: NIOLockedValueBox<Int>,
        cap: Int,
        writer: ConnectionWriter,
        context: MMContext,
        logger: Logger
    ) async {
        switch envelope {
            case .request(let msgid, let method, let entity, let params):
                if let route = self.router.streamRoute(for: method) {
                    // Stream open: authorize in frame order (so the stream registers
                    // before any following item), then launch the handler with the
                    // context scoped to the authorized target.
                    switch await self.router.authorize(
                        route: route, entity: entity, context: context, method: method
                    ) {
                        case .failure(let errorObject):
                            _ = await writer.send(
                                .response(msgid: msgid, error: errorObject, result: nil)
                            )
                        case .success(let target):
                            if let plan = await streams.openStream(
                                msgid: msgid, route: route, params: params,
                                context: context.scoped(to: target),
                                framesDropped: self.streamFramesDropped
                            ) {
                                handlers.addTask { await plan.run() }
                            }
                    }
                    return
                }
                // Unary request: the bounded-dispatch path, plus the unary-msgid
                // guard so a stream frame misaddressed to this live call becomes a
                // code-6 violation rather than a silent drop.
                //
                // A msgid already owned by a live stream or unary call is a reused
                // msgid (client bug): its original call still owns the single
                // terminal for it, so this reopen is dropped-and-counted — never
                // admitted, never given a terminal of its own (the single-terminal
                // invariant).
                guard streams.registerUnary(msgid: msgid) else {
                    self.streamFramesDropped.increment()
                    return
                }
                let admitted = inFlight.withLockedValue { count in
                    guard count < cap else { return false }
                    count += 1
                    return true
                }
                guard admitted else {
                    // Retire the just-registered unary entry so it does not linger,
                    // then answer the over-cap open with a code-4 terminal (this is
                    // this msgid's own single terminal — it was not owned before).
                    _ = streams.shouldSendUnaryTerminal(msgid: msgid)
                    _ = await writer.send(
                        .response(
                            msgid: msgid,
                            error: Router.errorObject(.tooManyInFlight),
                            result: nil
                        )
                    )
                    return
                }
                handlers.addTask {
                    let response = await self.router.dispatch(envelope: envelope, context: context)
                    // Retire the unary msgid; suppress the terminal if a stream frame
                    // already forced a code-6 for it (the misaddressed-frame guard).
                    if streams.shouldSendUnaryTerminal(msgid: msgid), let response {
                        _ = await writer.send(response)
                    }
                    inFlight.withLockedValue { $0 -= 1 }
                }

            case .credit, .item, .end, .stop, .cancel:
                await streams.route(envelope, framesDropped: self.streamFramesDropped)

            case .response:
                // Inbound response: a peer protocol error, logged and dropped by
                // the dispatch path. Not capped — it produces no response frame.
                if let response = await self.router.dispatch(envelope: envelope, context: context) {
                    _ = await writer.send(response)
                }
        }
    }

    // MARK: - Unix socket startup syscalls (blocking; thread pool only)

    /// Handles a pre-existing file at the socket path.
    ///
    /// - No entry: nothing to do.
    /// - A non-socket: `socketPathOccupied` — never unlinked.
    /// - A socket: liveness-probe it with `connect(2)`. Refused or vanished
    ///   means a stale file from a dead server — unlink it. A successful
    ///   connect means a live server — `socketPathInUse`, startup fails.
    static func prepareUnixSocketPath(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw MMServiceError.io(description: "lstat(\(path)) failed, errno \(errno)")
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw MMServiceError.socketPathOccupied(path: path)
        }
        let probe = try Self.makeUnixStreamSocket()
        defer { close(probe) }
        let connected = try Self.withSockaddrUn(path: path) { pointer, length in
            connect(probe, pointer, length)
        }
        if connected == 0 {
            throw MMServiceError.socketPathInUse(path: path)
        }
        switch errno {
            case ECONNREFUSED, ENOENT:
                // Stale (or concurrently removed): safe to replace.
                guard unlink(path) == 0 || errno == ENOENT else {
                    throw MMServiceError.io(
                        description: "unlink(\(path)) failed, errno \(errno)"
                    )
                }
            default:
                throw MMServiceError.io(
                    description: "liveness probe connect(\(path)) failed, errno \(errno)"
                )
        }
    }

    /// `socket(2)` for an `AF_UNIX` stream socket with close-on-exec set —
    /// used for both the liveness probe and the listening descriptor.
    ///
    /// ## Why CLOEXEC is mandatory here
    ///
    /// The host daemon may fork/exec child processes; a *listening* descriptor
    /// inherited by one keeps the socket connectable after this process dies,
    /// which defeats the stale-socket liveness probe in
    /// `prepareUnixSocketPath`: a restarted instance's probe would connect,
    /// classify the path as live, and fail with `socketPathInUse` until the
    /// unrelated child is killed. NIO's descriptor adoption
    /// (`ServerBootstrap.bind(_:)`) sets non-blocking only, never
    /// close-on-exec, so it must happen at creation. Linux sets `SOCK_CLOEXEC`
    /// atomically in `socket(2)` (no window against a concurrent fork);
    /// Darwin has no such flag, so `fcntl(2)` applies `FD_CLOEXEC` right
    /// after — run unconditionally on every platform for uniformity.
    static func makeUnixStreamSocket() throws -> CInt {
        #if canImport(Glibc)
        // Glibc imports SOCK_STREAM/SOCK_CLOEXEC as the __socket_type enum,
        // not CInt, so OR the raw values and convert once.
        let socketType = CInt(bitPattern: SOCK_STREAM.rawValue | Glibc.SOCK_CLOEXEC.rawValue)
        #elseif canImport(Musl)
        let socketType = SOCK_STREAM | Musl.SOCK_CLOEXEC
        #else
        let socketType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_UNIX, socketType, 0)
        guard descriptor >= 0 else {
            throw MMServiceError.io(description: "socket(2) failed, errno \(errno)")
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) >= 0 else {
            let fcntlErrno = errno
            close(descriptor)
            throw MMServiceError.io(
                description: "fcntl(F_SETFD, FD_CLOEXEC) failed, errno \(fcntlErrno)"
            )
        }
        return descriptor
    }

    /// Creates the listening descriptor: `socket(2)`, `bind(2)`, then
    /// `chmod(2)` — deliberately **not** `listen(2)`.
    ///
    /// ## Socket-mode mechanism (and its window)
    ///
    /// `umask` is process-global and races other threads, so the mode is
    /// applied with `chmod(2)` on the path instead. Ordering closes the
    /// window completely: after `bind(2)` the socket file exists but
    /// `connect(2)` to it fails with `ECONNREFUSED` until `listen(2)` — and
    /// NIO performs the `listen` only when it adopts this descriptor
    /// (`ServerBootstrap.bind(_:)` → `ServerSocketChannel(socket:)`), strictly
    /// after this function's `chmod` has returned. No connection can ever be
    /// accepted while the file still carries its default (umask-derived)
    /// mode.
    static func makeBoundUnixSocket(path: String, mode: mode_t) throws -> CInt {
        let descriptor = try Self.makeUnixStreamSocket()
        do {
            let bound = try Self.withSockaddrUn(path: path) { pointer, length in
                bind(descriptor, pointer, length)
            }
            guard bound == 0 else {
                throw MMServiceError.io(
                    description: "bind(\(path)) failed, errno \(errno)"
                )
            }
            guard chmod(path, mode) == 0 else {
                let chmodErrno = errno
                unlink(path)
                throw MMServiceError.io(
                    description: "chmod(\(path)) failed, errno \(chmodErrno)"
                )
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func withSockaddrUn<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1  // NUL terminator
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= capacity else {
            throw MMServiceError.invalidSocketPath(path: path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                body(rebound, length)
            }
        }
    }

    /// Filesystem identity (device + inode) of the socket file this instance
    /// bound, captured right after `bind(2)` and compared before the shutdown
    /// unlink. Internal so the guard is unit-testable.
    struct SocketFileIdentity: Hashable, Sendable {
        var device: UInt64
        var inode: UInt64
    }

    /// `lstat(2)` the path into a ``SocketFileIdentity``; nil when the path
    /// does not exist (or cannot be stat'ed). Blocking one-shot metadata
    /// syscall — startup/shutdown carve-out only.
    static func socketFileIdentity(path: String) -> SocketFileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return SocketFileIdentity(
            device: UInt64(truncatingIfNeeded: info.st_dev),
            inode: UInt64(truncatingIfNeeded: info.st_ino)
        )
    }

    /// One-shot metadata syscall at startup-failure/shutdown — the same
    /// carve-out as the other startup ops; never on a data path.
    ///
    /// ## Why the identity guard
    ///
    /// Graceful shutdown closes the listener first and unlinks last, after
    /// every connection drained — a window that can last as long as the
    /// slowest in-flight handler. During it, `connect(2)` to the still-present
    /// path is refused, so a *successor* instance's liveness probe rightly
    /// classifies the file as stale, unlinks it, and binds its own socket at
    /// the same path. An unconditional unlink here would then delete the
    /// successor's live socket. Comparing the path's current device/inode
    /// against the identity captured at bind time restricts the unlink to the
    /// file this instance actually created. (The lstat→unlink pair is not
    /// atomic; the guard is best-effort against the drain-window race, which
    /// is the one that occurs in practice.)
    static func removeSocketFile(
        path: String,
        owned: SocketFileIdentity?,
        logger: Logger
    ) {
        if let owned, let current = Self.socketFileIdentity(path: path), current != owned {
            logger.debug(
                "socket file replaced by another server; leaving it",
                metadata: ["path": "\(path)"]
            )
            return
        }
        if unlink(path) != 0 && errno != ENOENT {
            logger.warning(
                "socket file removal failed",
                metadata: ["path": "\(path)", "errno": "\(errno)"]
            )
        }
    }
}
