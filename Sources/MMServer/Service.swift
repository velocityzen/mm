import FP
import FPBracket
import FPService
import Logging
import MMSchema
import MMWire
import Metrics
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Failures of the ``MMService`` bracket. Acquire fails with one when an
/// endpoint cannot be bound, before anything is accepted, and closes the
/// endpoints it already bound; dispose fails with one only when an accept
/// loop itself failed. Per-connection failures never
/// use this type — they are logged and the connection closed.
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
    /// A socket operation failed in a non-branch-worthy way: a startup
    /// syscall, the bind, or the accept loop. Coarse by design: transport
    /// infrastructure failures are for logs, not `switch`.
    case io(description: String)

    /// Bridges a thrown error into the typed channel: an `MMServiceError`
    /// stays itself; anything else (an NIO bind or accept error) is `.io`.
    static func from(_ error: any Error) -> MMServiceError {
        error as? MMServiceError ?? .io(description: "\(error)")
    }
}

/// The server, as a scoped resource (fp-swift-bracket's `BracketAsync`):
/// acquire binds every endpoint and starts accepting, so the server is
/// listening once acquire returns; dispose drains it gracefully and joins it.
/// The resource is the bound addresses, one per endpoint in declaration
/// order — how hosts and tests learn the ephemeral port of a
/// `tcp(host:port: 0)` endpoint.
///
/// Every endpoint is the same server: one router, one connection cap
/// (`maxConnections` counts connections on all of them), one drain. Serving
/// a local unix socket and a loopback TCP port together is one
/// `Configuration(endpoints: [.unix(path: sock), .tcp(host: "127.0.0.1", port: 7000)])`.
///
/// Declare it with the builder, then compose it with the host's other
/// resources — they start in order and stop in reverse — and run the result
/// with the host's lifecycle, for instance fp-swift-service, which runs
/// dispose on a shutdown signal:
///
/// ```swift
/// let server = MMService {
///     Configuration(endpoint: .unix(path: sock))
///     ACLProvider(provider)
///     For(Journal.self) { JournalHandlers(store: store) }
/// }
/// let withService = Service(server, shutdownSignals: [SIGTERM, SIGINT])
/// let result = await withService()
/// ```
///
/// Every server auto-registers the builtin methods (`server.schema`,
/// `server.entity`), so discovery and ACL inspection exist without user code.
/// The routes are assembled and cross-checked when the value is built, so
/// declaration mistakes stop the daemon before anything binds. The value is
/// a reusable recipe: each run binds afresh.
///
/// - Acquire returns once every endpoint is bound and listening, so a
///   resource composed after this one (`flatMap`, `BracketAsyncDo`) starts
///   only once the server can take connections, and stops before it. It
///   fails with an ``MMServiceError`` when an endpoint cannot be bound, after
///   closing the ones already bound; the body and dispose are skipped then.
/// - Dispose drains: it returns once every connection drained and closed and
///   the socket files are gone. Run in a cancelled task, it tears connections
///   down at once instead. It fails only when an accept loop failed, which
///   also tears down every other endpoint's connections.
///
/// ## Graceful shutdown semantics
///
/// On graceful shutdown (the bracket's dispose) the server (1) stops
/// accepting — every listening channel closes; (2) every open connection —
/// including one still waiting for its peer's hello — stops *reading*
/// (input-half close) while in-flight handlers complete and their responses
/// flush through the connection's writer; (3) connection channels close;
/// (4) for unix endpoints, each socket file is removed, unless another server
/// instance has already replaced it at the same path during the drain (the
/// file's device/inode is compared against the one this instance bound — see
/// `removeSocketFile`); then the dispose returns. Cancelling the task that
/// runs dispose instead tears connections down immediately via
/// `executeThenClose` and task-group cancellation — no descriptors leak on
/// either path.
public typealias MMService = BracketAsync<[SocketAddress], MMServiceError>

extension BracketAsync where R == [SocketAddress], E == MMServiceError {
    /// Declares a server from explicit parameters; the builder form
    /// (``ServerPart``) declares the same server.
    ///
    /// - Parameters:
    ///   - configuration: Endpoints and hardening caps.
    ///   - namespaces: Sealed descriptor namespaces cross-checked against the
    ///     registered routes at startup (see
    ///     ``Router/init(namespaces:sharedTypes:aclProvider:logger:registerBuiltins:routes:)``).
    ///   - sharedTypes: Types-only `TypeNamespace` containers whose
    ///     definitions join the router's type table (see
    ///     ``Router/init(namespaces:sharedTypes:aclProvider:logger:registerBuiltins:routes:)``).
    ///   - aclProvider: The host's ACL source, consulted per dispatch.
    ///   - eventLoopGroup: NIO event loops; defaults to the process singleton.
    ///   - threadPool: Used for startup socket syscalls; defaults to the
    ///     process singleton.
    ///   - logger: Base logger; per-connection ids ride in metadata.
    ///   - routes: The application's routes, built with `Handle`.
    public init(
        configuration: MMServerConfiguration,
        namespaces: [any MethodNamespace.Type] = [],
        sharedTypes: [any TypeNamespace.Type] = [],
        aclProvider: any EntityACLProvider,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        threadPool: NIOThreadPool = .singleton,
        logger: Logger = Logger(label: "mm.server"),
        @RouterBuilder routes: sending () -> [Route]
    ) {
        self = ServerRuntime(
            configuration: configuration,
            namespaces: namespaces,
            sharedTypes: sharedTypes,
            aclProvider: aclProvider,
            eventLoopGroup: eventLoopGroup,
            threadPool: threadPool,
            logger: logger,
            routes: routes
        )
        .start()
    }
}

/// The assembled server behind an ``MMService`` bracket: the router, the
/// hello preamble, and the transport that binds each ``MMEndpoint``, accepts
/// connections, runs the hello exchange and per-connection request loop, and
/// dispatches through the ``Router``. Package-internal: hosts only ever hold
/// the bracket; tests reach the router through it.
package struct ServerRuntime: Sendable {
    /// The assembled router; tests read its `fingerprint` and `signatures`.
    package let router: Router

    private let configuration: MMServerConfiguration
    private let group: any EventLoopGroup
    private let threadPool: NIOThreadPool
    private let logger: Logger
    private let serverHello: MMHello

    private let metrics: ServiceMetrics
    /// Stream frames dropped for an unknown/retired msgid, or an advisory frame
    /// legal to ignore (same label the router used transitionally in S1/S2).

    private enum TransportKind: Sendable {
        case unix
        case tcp
    }

    /// An accepted connection, with the peer identity captured for it at
    /// accept and frozen for its lifetime.
    private struct AcceptedConnection: Sendable {
        let connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        let peer: PeerIdentity
    }

    /// A listening channel: its inbound stream yields accepted connections.
    private typealias Listener = NIOAsyncChannel<AcceptedConnection, Never>

    /// A bound, listening server channel, and how to undo what binding
    /// created on disk.
    private struct BoundServer: Sendable {
        let channel: Listener
        let localAddress: SocketAddress
        /// Removes the unix socket file (identity-guarded); nothing for TCP.
        let removeFiles: @Sendable () -> Void

        /// Closes a listener that never accepted, and removes its file.
        func close() async {
            try? await self.channel.executeThenClose { _ in }
            self.removeFiles()
        }
    }

    /// Connections open across every listener, and the last connection id
    /// handed out: one cap and one id sequence for the whole server.
    private struct ConnectionCounts: Sendable {
        var open = 0
        var lastID: UInt64 = 0
    }

    /// The bracket-owned running server behind `start()`. The accept loop
    /// is NOT a free-floating `Task {}` (house rule): dispose is its
    /// guaranteed owner — it requests the drain and joins the loop before the
    /// scope returns, so the task can neither leak nor outlive the resource.
    private struct RunningServer: Sendable {
        let localAddresses: [SocketAddress]
        /// Requesting it starts the drain: every listener and every open
        /// connection stop reading. Idempotent.
        let shutdown: Shutdown
        /// The accept loops; returns once every connection has closed.
        let loop: Task<Result<Void, MMServiceError>, Never>
    }

    /// Assembles a server: builds the router (with builtins), computes the
    /// hello preamble from the router's fingerprint, and prepares metrics.
    /// Parameters as in the ``MMService`` parameter initializer.
    package init(
        configuration: MMServerConfiguration,
        namespaces: [any MethodNamespace.Type] = [],
        sharedTypes: [any TypeNamespace.Type] = [],
        aclProvider: any EntityACLProvider,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        threadPool: NIOThreadPool = .singleton,
        logger: Logger = Logger(label: "mm.server"),
        @RouterBuilder routes: () -> [Route]
    ) {
        var serviceLogger = logger
        serviceLogger[metadataKey: "service"] = "mm.server"
        self.configuration = configuration
        self.group = eventLoopGroup
        self.threadPool = threadPool
        self.logger = serviceLogger
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
        self.metrics = ServiceMetrics()
    }

    // MARK: - Start

    /// The server as a bracket: acquire binds and starts accepting; dispose
    /// drains gracefully and joins (see ``MMService``).
    package func start() -> MMService {
        BracketAsync<RunningServer, MMServiceError>(
            acquire: {
                await self.bindEndpoints().map(self.startAccepting)
            },
            dispose: { running in
                running.shutdown.request()
                // Cancelling the disposing task (a host's second signal, its
                // timeout) cancels the loop: the drain becomes a teardown.
                return await withTaskCancellationHandler {
                    await running.loop.value
                } onCancel: {
                    running.loop.cancel()
                }
            }
        )
        .map(\.localAddresses)
    }

    /// Starts the accept loops in the task ``RunningServer`` owns: they
    /// drain and close every connection before it returns, so the socket
    /// files go last.
    private func startAccepting(_ bound: [BoundServer]) -> RunningServer {
        let shutdown = Shutdown()
        let loop = Task {
            let stopped = await self.acceptLoop(servers: bound.map(\.channel), shutdown: shutdown)
            for server in bound {
                server.removeFiles()
            }
            return stopped
        }
        return RunningServer(
            localAddresses: bound.map(\.localAddress),
            shutdown: shutdown,
            loop: loop
        )
    }

    // MARK: - Bind

    /// Binds the endpoints in declaration order. When one fails, the ones
    /// already bound are closed before the failure returns, so a failed
    /// start leaves no listener and no socket file behind.
    private func bindEndpoints() async -> Result<[BoundServer], MMServiceError> {
        var bound: [BoundServer] = []
        for endpoint in self.configuration.endpoints {
            switch await self.bindEndpoint(endpoint) {
                case .success(let server):
                    bound.append(server)
                case .failure(let error):
                    for server in bound {
                        await server.close()
                    }
                    return .failure(error)
            }
        }
        return .success(bound)
    }

    private func bindEndpoint(_ endpoint: MMEndpoint) async -> Result<BoundServer, MMServiceError> {
        await Result.fromAsync {
            switch endpoint {
                case .unix(let path):
                    try await self.bindUnixDomainSocket(path: path)
                case .tcp(let host, let port):
                    try await self.bindTCP(host: host, port: port)
            }
        }
        .mapError(MMServiceError.from)
    }

    private func bindUnixDomainSocket(path: String) async throws -> BoundServer {
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

        let server: Listener
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
                    self.initializeChildChannel(channel, transport: .unix)
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
        let logger = self.logger
        let removeFiles: @Sendable () -> Void = {
            Self.removeSocketFile(path: path, owned: fileIdentity, logger: logger)
        }
        let bound = try await Self.boundServer(server, removeFiles: removeFiles)
        self.logger.info("listening", metadata: ["path": "\(path)"])
        return bound
    }

    private func bindTCP(host: String, port: Int) async throws -> BoundServer {
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
                self.initializeChildChannel(channel, transport: .tcp)
            }
        let bound = try await Self.boundServer(server, removeFiles: {})
        self.logger.info("listening", metadata: ["address": "\(bound.localAddress)"])
        return bound
    }

    /// Pairs a bound channel with its local address. A bound channel always
    /// has one; should it not, the channel closes and what binding created is
    /// removed, so a listener never exists without an address.
    private static func boundServer(
        _ channel: Listener,
        removeFiles: @escaping @Sendable () -> Void
    ) async throws -> BoundServer {
        guard let localAddress = channel.channel.localAddress else {
            try? await channel.executeThenClose { _ in }
            removeFiles()
            throw MMServiceError.io(description: "the bound socket has no local address")
        }
        return BoundServer(
            channel: channel,
            localAddress: localAddress,
            removeFiles: removeFiles
        )
    }

    /// Server (listening) channel pipeline: just the accept-error filter that
    /// keeps a peer connecting-and-resetting from failing the accept stream
    /// (see ``AcceptErrorFilterHandler``). Runs before NIO adds its own
    /// accept machinery, so the filter sits closest to the head and sees the
    /// error first.
    private func initializeServerChannel(_ channel: any Channel) -> EventLoopFuture<Void> {
        let logger = self.logger
        let acceptFailures = self.metrics.acceptFailures
        return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(
                AcceptErrorFilterHandler(logger: logger, acceptFailures: acceptFailures)
            )
        }
    }

    /// Captures the peer's identity, then builds the connection's pipeline.
    /// Runs on the child's event loop before NIO registers the channel, so a
    /// peer whose identity cannot be captured is closed before it is sent
    /// the server hello or counted against the connection cap.
    private func initializeChildChannel(
        _ channel: any Channel,
        transport: TransportKind
    ) -> EventLoopFuture<AcceptedConnection> {
        let maxFrameLength = self.configuration.maxFrameLength
        let idleTimeout = self.configuration.idleTimeout
        let serverHello = self.serverHello
        let violations = self.metrics.protocolViolations
        return self.capturePeer(of: channel, transport: transport)
            .flatMapThrowing { peer in
                let connection = try Self.configureChildPipeline(
                    channel: channel,
                    maxFrameLength: maxFrameLength,
                    idleTimeout: idleTimeout,
                    serverHello: serverHello,
                    protocolViolations: violations
                )
                // NIO drops a connection whose initializer completes after the
                // listener closed (apple/swift-nio#2637), and releasing a
                // wrapper with an unfinished writer traps. Hold it until the
                // channel has closed, which finishes the writer; the peer or
                // the idle timeout closes a dropped one.
                channel.closeFuture.whenComplete { _ in
                    withExtendedLifetime(connection) {}
                }
                return AcceptedConnection(connection: connection, peer: peer)
            }
            .flatMapErrorThrowing { error in
                // NIO neither registers nor closes a child whose initializer
                // failed; left open, its socket would leak.
                channel.close(promise: nil)
                throw error
            }
    }

    /// The identity a connection is authorized with. TCP has no kernel
    /// credentials in v1: anonymous, no syscalls. A unix peer whose
    /// credentials cannot be captured fails closed — identity is the only
    /// authorization input, so no identity means no connection.
    private func capturePeer(
        of channel: any Channel,
        transport: TransportKind
    ) -> EventLoopFuture<PeerIdentity> {
        switch transport {
            case .tcp:
                return channel.eventLoop.makeSucceededFuture(.anonymous)
            case .unix:
                let logger = self.logger
                return PeerCredentials.captureUnixPeer(channel: channel)
                    .flatMapErrorThrowing { error in
                        logger.warning(
                            "peer credential capture failed",
                            metadata: ["error": "\(error)"]
                        )
                        throw error
                    }
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
        try sync.addHandler(MMIdleCloseHandler())
        try sync.addHandler(ByteToMessageHandler(MMFrameDecoder(maxFrameLength: maxFrameLength)))
        try sync.addHandler(MessageToByteHandler(MMFrameEncoder(maxFrameLength: maxFrameLength)))
        try sync.addHandler(
            ServerHelloHandler(serverHello: serverHello, protocolViolations: protocolViolations)
        )
        return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
    }

    // MARK: - Accept loop

    /// Accepts on every listener until the graceful drain or cancellation
    /// ends their accept streams, and returns once every connection has
    /// closed. A listener whose accepting fails cancels the others: the
    /// server stops as a whole.
    ///
    /// - Returns: `.success` for a stop the owner asked for (a drain, or
    ///   cancellation); `.io` when accepting itself failed.
    private func acceptLoop(
        servers: [Listener],
        shutdown: Shutdown
    ) async -> Result<Void, MMServiceError> {
        // Shared with every listener and connection child task, hence a
        // locked box rather than loop-local state. Counters, not domain state.
        let counts = NIOLockedValueBox(ConnectionCounts())
        return await Result.fromAsync {
            try await withThrowingDiscardingTaskGroup { listeners in
                for server in servers {
                    listeners.addTask {
                        try await self.accept(server: server, counts: counts, shutdown: shutdown)
                    }
                }
            }
        }
        .flatMapError(Self.stopResult)
    }

    /// Cancellation is a stop the server's owner asked for, not a failure;
    /// anything else ended accepting on its own.
    private static func stopResult(_ error: any Error) -> Result<Void, MMServiceError> {
        error is CancellationError ? .success(()) : .failure(.from(error))
    }

    private func accept(
        server: Listener,
        counts: NIOLockedValueBox<ConnectionCounts>,
        shutdown: Shutdown
    ) async throws {
        try await withThrowingDiscardingTaskGroup { connections in
            try await server.executeThenClose { acceptStream in
                // Stop accepting on graceful shutdown; the accept stream
                // finishes and the group then waits for open connections to
                // drain.
                try await withShutdownHandler(on: shutdown, { server.channel.close(promise: nil) }) {
                    await Result.fromAsync {
                        for try await accepted in acceptStream {
                            let connection = accepted.connection
                            // Cap enforced AT accept, before any child task exists.
                            let admittedID = counts.withLockedValue { state -> UInt64? in
                                guard state.open < self.configuration.maxConnections else {
                                    return nil
                                }
                                state.open += 1
                                state.lastID &+= 1
                                return state.lastID
                            }
                            guard let connectionID = admittedID else {
                                // Busy-rejection choice: close immediately, no busy
                                // frame. Pre-hello there is no msgid to correlate an
                                // error response to, and inventing a hello-level busy
                                // code is a capability for a future version. The
                                // pipeline may already have flushed the server hello
                                // at activation; a rejected peer can observe it
                                // before the close. Its identity was captured at
                                // accept, but nothing is dispatched for it.
                                self.metrics.connectionsRejected.increment()
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
                            self.metrics.connectionsAccepted.increment()
                            self.metrics.activeConnections.record(
                                counts.withLockedValue { $0.open }
                            )
                            connections.addTask {
                                // Task-local binding: hosts that bootstrap
                                // swift-log with MMLogContext.metadataProvider get
                                // the connection id on every log line in this task
                                // tree, including application handler bodies.
                                await MMLogContext.$connectionID.withValue(connectionID) {
                                    await self.handleConnection(
                                        connection,
                                        peer: accepted.peer,
                                        connectionID: connectionID,
                                        shutdown: shutdown
                                    )
                                }
                                let remaining = counts.withLockedValue { state in
                                    state.open -= 1
                                    return state.open
                                }
                                self.metrics.activeConnections.record(remaining)
                            }
                        }
                    }
                }
                .get()
            }
        }
    }

    // MARK: - Per-connection

    private func handleConnection(
        _ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        peer: PeerIdentity,
        connectionID: UInt64,
        shutdown: Shutdown
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
            try await withShutdownHandler(on: shutdown, { channel.close(mode: .input, promise: nil) }) {
                await Result.fromAsync {
                    try await self.serveConnection(
                        connection,
                        peer: peer,
                        connectionID: connectionID,
                        logger: logger
                    )
                }
            }
            .get()
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
        peer: PeerIdentity,
        connectionID: UInt64,
        logger: Logger
    ) async throws {
        try await connection.executeThenClose { inbound, outbound in
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
                self.metrics.protocolViolations.increment()
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

            let writer = ConnectionWriter(outbound: outbound, framesOut: self.metrics.framesOut)
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
            // executeThenClose closes the channel fully once this body
            // returns, and a full close discards what the kernel has not
            // taken yet: a slow reader would lose the tail of the last
            // responses, the drain's included.
            await Self.flushPendingWrites(connection.channel)
        }
    }

    /// Returns once every write queued so far has reached the kernel, or the
    /// channel has closed. An empty buffer written from the idle handler's
    /// context (the head of the pipeline, so it skips the frame encoder)
    /// queues behind them, and NIO completes writes in order. A reader that
    /// never drains is bounded by the idle timeout, which closes the channel;
    /// cancellation closes it at once.
    static func flushPendingWrites(_ channel: any Channel) async {
        let flushed = channel.eventLoop.flatSubmit {
            let promise = channel.eventLoop.makePromise(of: Void.self)
            do {
                try channel.pipeline.syncOperations
                    .context(handlerType: IdleStateHandler.self)
                    .writeAndFlush(NIOAny(ByteBuffer()), promise: promise)
            } catch {
                // The pipeline is already torn down: nothing is left to flush.
                promise.succeed(())
            }
            return promise.futureResult
        }
        await withTaskCancellationHandler {
            _ = try? await flushed.get()
        } onCancel: {
            channel.close(promise: nil)
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
                    self.metrics.framesIn.increment()
                    let envelope: MMEnvelope
                    switch MMEnvelope.decode(from: frame) {
                        case .failure(let error):
                            self.metrics.protocolViolations.increment()
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
                        case .failure(let error):
                            _ = await writer.send(
                                .response(msgid: msgid, error: error, result: nil)
                            )
                        case .success(let target):
                            if let plan = await streams.openStream(
                                msgid: msgid, route: route, params: params,
                                context: context.scoped(to: target),
                                framesDropped: self.metrics.streamFramesDropped
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
                    self.metrics.streamFramesDropped.increment()
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
                            error: Router.error(.tooManyInFlight),
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
                await streams.route(envelope, framesDropped: self.metrics.streamFramesDropped)

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
    /// close-on-exec, so it must happen at creation. Linux and Android set
    /// `SOCK_CLOEXEC` atomically in `socket(2)` (no window against a concurrent fork);
    /// Darwin has no such flag, so `fcntl(2)` applies `FD_CLOEXEC` right
    /// after — run unconditionally on every platform for uniformity.
    static func makeUnixStreamSocket() throws -> CInt {
        #if canImport(Glibc)
        // Glibc imports SOCK_STREAM/SOCK_CLOEXEC as the __socket_type enum,
        // not CInt, so OR the raw values and convert once.
        let socketType = CInt(bitPattern: SOCK_STREAM.rawValue | Glibc.SOCK_CLOEXEC.rawValue)
        #elseif canImport(Musl)
        let socketType = SOCK_STREAM | Musl.SOCK_CLOEXEC
        #elseif canImport(Android)
        let socketType = SOCK_STREAM | Android.SOCK_CLOEXEC
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

    /// Filesystem identity (device + inode + change time) of the socket file
    /// this instance bound, captured right after `bind(2)` and compared before
    /// the shutdown unlink. Device+inode alone is not enough: ext4 (and
    /// friends) reuse a freed inode number immediately, so a successor's
    /// replacement file at the same path can collide with the identity
    /// captured here — the ctime (set at creation, untouched thereafter; the
    /// bind-time chmod happens before capture) disambiguates the two files.
    /// APFS never reuses inode numbers, which is why the collision only
    /// occurs on Linux. Internal so the guard is unit-testable.
    struct SocketFileIdentity: Hashable, Sendable {
        var device: UInt64
        var inode: UInt64
        var changeTimeSeconds: Int64
        var changeTimeNanoseconds: Int64
    }

    /// `lstat(2)` the path into a ``SocketFileIdentity``; nil when the path
    /// does not exist (or cannot be stat'ed). Blocking one-shot metadata
    /// syscall — startup/shutdown carve-out only.
    static func socketFileIdentity(path: String) -> SocketFileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let changeTime = info.st_ctimespec
        #else
        let changeTime = info.st_ctim
        #endif
        return SocketFileIdentity(
            device: UInt64(truncatingIfNeeded: info.st_dev),
            inode: UInt64(truncatingIfNeeded: info.st_ino),
            changeTimeSeconds: Int64(changeTime.tv_sec),
            changeTimeNanoseconds: Int64(changeTime.tv_nsec)
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
    /// successor's live socket. Comparing the path's current identity (see
    /// ``SocketFileIdentity``) against the one captured at bind time restricts
    /// the unlink to the file this instance actually created. (The
    /// lstat→unlink pair is not
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
