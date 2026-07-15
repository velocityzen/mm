import Logging
import MMSchema
import MMWire
import NIOCore
import NIOPosix

/// The fully declarative server form: configuration, authorization, logging,
/// and namespace-grouped handlers in one builder —
///
/// ```swift
/// let service = MMService {
///     Configuration(endpoint: .unix(path: socketPath))
///     ACLProvider(provider)
///     Log(logger)
///     OnBind { address in logger.info("listening", metadata: ["address": "\(address)"]) }
///
///     For(Journal.self) {
///         // inline, right in the definition —
///         On(Journal.append) { auth, request in
///             ...
///         }
///         // — or a reusable group declared elsewhere (its own file, its own
///         // dependencies), also declaratively:
///         JournalHandlers(store: store)
///     }
/// }
/// ```
///
/// `For(Namespace.self)` both groups the routes and enrolls the namespace in
/// the router's startup cross-check (every descriptor in `Namespace.all` must
/// have a handler; every handler under the namespace's prefix must be
/// declared) — the builder equivalent of the `namespaces:` parameter.
///
/// Exactly one `Configuration` and exactly one `ACLProvider` are required;
/// `Log` and `OnBind` are optional (at most one each). Violations are
/// programmer error and fail at daemon startup, per the router's precondition
/// discipline.
public struct ServerPart {
    enum Kind {
        case configuration(MMServerConfiguration)
        case aclProvider(any EntityACLProvider)
        case logger(Logger)
        case onBind(@Sendable (SocketAddress) -> Void)
        case ready(ServiceReadiness)
        case group(namespace: any MethodNamespace.Type, routes: [Route])
        case routes([Route])
        case sharedTypes(any TypeNamespace.Type)
    }

    let kind: Kind
}

// MARK: - Elements

/// The server's tunables, as a builder element. Pass a prebuilt
/// ``MMServerConfiguration`` or use the mirrored parameter form.
public func Configuration(_ configuration: MMServerConfiguration) -> ServerPart {
    ServerPart(kind: .configuration(configuration))
}

/// Mirrors ``MMServerConfiguration/init(endpoint:maxFrameLength:maxConnections:maxInFlightRequestsPerConnection:maxConcurrentStreamsPerConnection:idleTimeout:unixSocketMode:capabilities:)``.
public func Configuration(
    endpoint: MMEndpoint,
    maxFrameLength: UInt32 = MMWireInfo.defaultMaxFrameLength,
    maxConnections: Int = 128,
    maxInFlightRequestsPerConnection: Int = 16,
    maxConcurrentStreamsPerConnection: Int = 8,
    idleTimeout: TimeAmount = .seconds(120),
    unixSocketMode: UInt16 = 0o660,
    capabilities: UInt32 = 0
) -> ServerPart {
    ServerPart(
        kind: .configuration(
            MMServerConfiguration(
                endpoint: endpoint,
                maxFrameLength: maxFrameLength,
                maxConnections: maxConnections,
                maxInFlightRequestsPerConnection: maxInFlightRequestsPerConnection,
                maxConcurrentStreamsPerConnection: maxConcurrentStreamsPerConnection,
                idleTimeout: idleTimeout,
                unixSocketMode: unixSocketMode,
                capabilities: capabilities
            )))
}

/// The authorization backend — required, exactly once. There is deliberately
/// no default: which entities exist and who may touch them is the host's one
/// security decision, never something a library should assume.
public func ACLProvider(_ provider: any EntityACLProvider) -> ServerPart {
    ServerPart(kind: .aclProvider(provider))
}

/// The server's logger. Optional; defaults to `Logger(label: "mm.server")`.
public func Log(_ logger: Logger) -> ServerPart {
    ServerPart(kind: .logger(logger))
}

/// Label-and-level form: `Log(label: "eyed.rpc", level: .debug)`.
public func Log(label: String = "mm.server", level: Logger.Level = .info) -> ServerPart {
    var logger = Logger(label: label)
    logger.logLevel = level
    return ServerPart(kind: .logger(logger))
}

/// Closure form: route every server log line into your own sink —
/// `Log { level, message in myLogger.log(level: level, message: message) }`.
/// Structured metadata is preserved through the underlying handler; the
/// closure receives the level and composed message.
public func Log(
    _ sink: @escaping @Sendable (Logger.Level, Logger.Message) -> Void
) -> ServerPart {
    ServerPart(
        kind: .logger(Logger(label: "mm.server", factory: { _ in ClosureLogHandler(sink: sink) })))
}

/// Invoked once the endpoint is bound, with the bound address — the hook
/// tests and supervisors use to learn the ephemeral port or confirm the
/// socket path. Optional, at most once.
public func OnBind(_ body: @escaping @Sendable (SocketAddress) -> Void) -> ServerPart {
    ServerPart(kind: .onBind(body))
}

/// Groups routes under a namespace and enrolls the namespace in the router's
/// startup cross-check. The body takes the same expressions as any route
/// builder: `On`/`Handle` registrations and ``RouteGroup`` instances.
public func For(
    _ namespace: any MethodNamespace.Type,
    @RouterBuilder _ routes: () -> [Route]
) -> ServerPart {
    ServerPart(kind: .group(namespace: namespace, routes: routes()))
}

/// Registers a shared `TypeNamespace` container (e.g. a `#schemaTypes`
/// block): its definitions join the router's type table, its references are
/// validated at startup, and discovery serves them to peers whose visible
/// methods reach them. Namespaces declared with `For` contribute their own
/// `types` automatically — this element is only for containers that declare
/// no methods.
public func Types(_ container: any TypeNamespace.Type) -> ServerPart {
    ServerPart(kind: .sharedTypes(container))
}

// MARK: - On: builder-native handler registration (authorization first)

/// Registers a unary handler; identical to ``Handle(_:acceptsRoot:_:)-(Method<Request,Response>,_,_)``
/// with the closure parameters in builder order — the authorized connection
/// context first, then the decoded request.
public func On<Request: Codable & Sendable, Response: Codable & Sendable>(
    _ method: Method<Request, Response>,
    acceptsRoot: Bool = false,
    _ body: @escaping @Sendable (MMContext, Request) async -> Result<Response, MMErrorObject>
) -> Route {
    Handle(method, acceptsRoot: acceptsRoot) { request, context in
        await body(context, request)
    }
}

/// Server-streaming form: context, request, then the element sink.
public func On<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: ServerStreamMethod<Request, Element, Response>,
    acceptsRoot: Bool = false,
    _ body:
        @escaping @Sendable (MMContext, Request, MMResponseSink<Element>) async ->
        Result<Response, MMErrorObject>
) -> Route {
    Handle(method, acceptsRoot: acceptsRoot) { request, sink, context in
        await body(context, request, sink)
    }
}

/// Client-streaming form: context, request, then the element sequence.
public func On<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: ClientStreamMethod<Request, Element, Response>,
    acceptsRoot: Bool = false,
    _ body:
        @escaping @Sendable (MMContext, Request, MMRequestStream<Element>) async ->
        Result<Response, MMErrorObject>
) -> Route {
    Handle(method, acceptsRoot: acceptsRoot) { request, elements, context in
        await body(context, request, elements)
    }
}

/// Bidirectional form: context, request, inbound elements, outbound sink.
public func On<
    Request: Codable & Sendable,
    RequestElement: Codable & Sendable,
    ResponseElement: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>,
    acceptsRoot: Bool = false,
    _ body:
        @escaping @Sendable (
            MMContext, Request, MMRequestStream<RequestElement>,
            MMResponseSink<ResponseElement>
        ) async -> Result<Response, MMErrorObject>
) -> Route {
    Handle(method, acceptsRoot: acceptsRoot) { request, elements, sink, context in
        await body(context, request, elements, sink)
    }
}

// MARK: - Reusable handler groups

/// A reusable, separately-declared bundle of routes — the handler analogue of
/// a custom SwiftUI view. Conforming types carry their own dependencies and
/// compose into any route builder position:
///
/// ```swift
/// struct JournalHandlers: RouteGroup {
///     let store: JournalStore
///
///     @RouterBuilder var routes: [Route] {
///         On(Journal.append) { auth, request in ... }
///         On(Journal.read) { auth, request in ... }
///     }
/// }
/// ```
public protocol RouteGroup: Sendable {
    @RouterBuilder var routes: [Route] { get }
}

extension RouterBuilder {
    /// A ``RouteGroup`` instance contributes its routes in place.
    public static func buildExpression(_ group: any RouteGroup) -> [Route] {
        group.routes
    }
}

// MARK: - Builder + assembly

@resultBuilder
public enum ServerBuilder {
    public static func buildExpression(_ part: ServerPart) -> [ServerPart] { [part] }
    /// Bare routes (no namespace cross-check) are allowed at the top level.
    public static func buildExpression(_ route: Route) -> [ServerPart] {
        [ServerPart(kind: .routes([route]))]
    }
    public static func buildExpression(_ group: any RouteGroup) -> [ServerPart] {
        [ServerPart(kind: .routes(group.routes))]
    }
    public static func buildBlock(_ components: [ServerPart]...) -> [ServerPart] {
        components.flatMap { $0 }
    }
    public static func buildOptional(_ component: [ServerPart]?) -> [ServerPart] {
        component ?? []
    }
    public static func buildEither(first component: [ServerPart]) -> [ServerPart] { component }
    public static func buildEither(second component: [ServerPart]) -> [ServerPart] { component }
    public static func buildArray(_ components: [[ServerPart]]) -> [ServerPart] {
        components.flatMap { $0 }
    }
}

extension MMService {
    /// Assembles a server from declarative parts. See ``ServerPart`` for the
    /// element inventory and the exactly-once rules.
    public init(
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        threadPool: NIOThreadPool = .singleton,
        @ServerBuilder _ content: () -> [ServerPart]
    ) {
        var configuration: MMServerConfiguration?
        var aclProvider: (any EntityACLProvider)?
        var logger: Logger?
        var onBind: (@Sendable (SocketAddress) -> Void)?
        var readinessSignals: [ServiceReadiness] = []
        var namespaces: [any MethodNamespace.Type] = []
        var seenNamespaces: Set<ObjectIdentifier> = []
        var sharedTypes: [any TypeNamespace.Type] = []
        var seenSharedTypes: Set<ObjectIdentifier> = []
        var routes: [Route] = []
        for part in content() {
            switch part.kind {
                case .configuration(let value):
                    precondition(configuration == nil, "MMService declares Configuration twice")
                    configuration = value
                case .aclProvider(let value):
                    precondition(aclProvider == nil, "MMService declares ACLProvider twice")
                    aclProvider = value
                case .logger(let value):
                    precondition(logger == nil, "MMService declares Log twice")
                    logger = value
                case .onBind(let value):
                    precondition(onBind == nil, "MMService declares OnBind twice")
                    onBind = value
                case .ready(let readiness):
                    readinessSignals.append(readiness)
                case .group(let namespace, let groupRoutes):
                    precondition(
                        seenNamespaces.insert(ObjectIdentifier(namespace)).inserted,
                        "MMService declares For(\(namespace)) twice"
                    )
                    namespaces.append(namespace)
                    routes.append(contentsOf: groupRoutes)
                case .routes(let bare):
                    routes.append(contentsOf: bare)
                case .sharedTypes(let container):
                    precondition(
                        seenSharedTypes.insert(ObjectIdentifier(container)).inserted,
                        "MMService declares Types(\(container)) twice"
                    )
                    sharedTypes.append(container)
            }
        }
        guard let configuration else {
            preconditionFailure(
                "MMService declares no Configuration — the endpoint is not defaultable")
        }
        guard let aclProvider else {
            preconditionFailure(
                "MMService declares no ACLProvider — authorization is never defaulted")
        }
        let userOnBind = onBind
        let signals = readinessSignals
        let combinedOnBind: (@Sendable (SocketAddress) -> Void)? =
            signals.isEmpty
            ? userOnBind
            : { @Sendable address in
                userOnBind?(address)
                for signal in signals {
                    signal.signalReady()
                }
            }
        self.init(
            configuration: configuration,
            namespaces: namespaces,
            sharedTypes: sharedTypes,
            aclProvider: aclProvider,
            eventLoopGroup: eventLoopGroup,
            threadPool: threadPool,
            logger: logger ?? Logger(label: "mm.server"),
            onBind: combinedOnBind,
            routes: { routes }
        )
    }
}

/// Minimal `LogHandler` backing the closure form of ``Log(_:)-closure``.
struct ClosureLogHandler: LogHandler {
    let sink: @Sendable (Logger.Level, Logger.Message) -> Void
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        sink(event.level, event.message)
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        sink(level, message)
    }
}
