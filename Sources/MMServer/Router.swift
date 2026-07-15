import Logging
import MMSchema
import MMWire
import Metrics
import NIOCore

/// The message router: route table, authorization, and dispatch.
///
/// Immutable after `init` — the route table, fingerprint, and signature list
/// are all fixed at daemon startup, and every misregistration is a
/// `precondition` failure there rather than a surprise at first call.
///
/// ## Dispatch order (fixed, all before the handler runs)
///
/// 1. Request/response split — inbound *responses* are protocol errors:
///    logged and dropped.
/// 2. Route lookup — an unknown method on a request gets an `unknownMethod`
///    error **response** (never a dropped frame).
/// 3. Target-entity parsing — the open envelope's entity slot is parsed as an
///    `EntityName`; an invalid path is `malformedParams`. The params slice is
///    not touched.
/// 4. Traversal — every ancestor prefix of the target requires `.execute`
///    for the peer, outermost first.
/// 5. Target check — the target entity's ACL must grant the route's access
///    class. An entity with no ACL record is `permissionDenied` (existence is
///    never leaked). ACL semantics are first-matching-class-wins, implemented
///    once in `EntityACL.permitted`.
/// 6. Only now are the params decoded and the typed handler invoked, with the
///    context scoped to the authorized target (`context.entity`).
///
/// Authorization never interprets a single payload byte before step 5 passes —
/// the entity is envelope metadata, not payload.
///
/// ## Root targets
///
/// `EntityName.root` is "the whole tree", never a concrete entity: it has no
/// ancestors and carries no ACL, so steps 4–5 have nothing to check for it.
/// An unchecked dispatch would mean any peer — including an anonymous TCP
/// peer — could run any handler by sending an empty target, so root-targeted
/// envelopes are **denied with `permissionDenied` by default**. Only routes
/// registered with `Handle(method, acceptsRoot: true)` accept them: methods
/// with documented tree-wide semantics whose handlers enforce their own
/// authorization. The builtin `rpc.schema` opts in (its response is filtered
/// by per-method traversal rights); `entity.stat` does not (root carries no
/// ACL to report, so a root stat is denied like any absent record).
public struct Router: Sendable {
    /// `SchemaFingerprint.compute` over **all** registered signatures and
    /// type definitions, memoized at init. This is the hello-preamble
    /// fingerprint.
    public let fingerprint: UInt64
    /// Every registered method's signature, sorted by name. `rpc.schema`
    /// serves a per-peer filtered subset of this list.
    public let signatures: [MethodSignature]
    /// Every registered named-type definition, sorted by name — the union of
    /// the declared namespaces' tables and the shared `Types` containers.
    /// `rpc.schema` serves the subset transitively reachable from a peer's
    /// visible methods.
    public let types: [TypeDefinition]

    private let routesByName: [String: Route]
    private let aclProvider: any EntityACLProvider
    private let logger: Logger
    private let decoder: MMPackDecoder
    private let authorizationDenials: Counter
    private let inboundResponsesDropped: Counter
    private let streamFramesDropped: Counter
    private let dispatchTimer: Timer

    /// Builds the route table and runs all startup cross-checks.
    ///
    /// - Parameters:
    ///   - namespaces: Sealed descriptor namespaces to cross-check against the
    ///     registered routes. Two preconditions per namespace: every method in
    ///     its `all` list must have a registered route (no unbound
    ///     descriptors), and every registered route under a namespace-owned
    ///     method-name prefix must appear in that namespace's `all` list. A
    ///     prefix is owned by at most one declared namespace.
    ///   - sharedTypes: `TypeNamespace` containers (e.g. `#schemaTypes`
    ///     blocks) whose definitions belong to no method namespace. Declared
    ///     namespaces contribute their own `types` automatically.
    ///   - aclProvider: The host's ACL source, consulted per dispatch.
    ///   - logger: Structured logger; messages are constant, variables ride in
    ///     metadata.
    ///   - registerBuiltins: When true, wires the `Builtins` namespace —
    ///     `rpc.schema` (traversal-filtered discovery) and `entity.stat` — and
    ///     includes it in the cross-checks. The server (part B) passes true;
    ///     it defaults to false so router-only tests stay minimal.
    ///   - routes: The application's routes, built with `Handle`.
    ///
    /// Preconditions (programmer error, daemon startup): duplicate method
    /// names; unbound namespace descriptors; routes under a namespace prefix
    /// missing from its `all` list; a method name whose namespace prefix is
    /// not a valid `EntityName`; a request/response type the schema probe
    /// cannot walk; duplicate type-definition names; a `.reference` anywhere
    /// in the registered schemas that no registered definition resolves
    /// (names are nominal — the table must be complete at startup, not at
    /// first decode).
    public init(
        namespaces: [any MethodNamespace.Type] = [],
        sharedTypes: [any TypeNamespace.Type] = [],
        aclProvider: any EntityACLProvider,
        logger: Logger = Logger(label: "mm.server.router"),
        registerBuiltins: Bool = false,
        @RouterBuilder routes: () -> [Route]
    ) {
        let applicationRoutes = routes()

        var names = applicationRoutes.map(\.name)
        if registerBuiltins {
            names.append(contentsOf: Builtins.all.map(\.name))
        }
        var seenNames = Set<String>()
        for name in names {
            precondition(
                seenNames.insert(name).inserted,
                "Router: duplicate route registered for method '\(name)'"
            )
        }

        // The nominal type table: definitions from every declared namespace
        // plus the shared containers. Names must be unique, and every
        // reference in the registered schemas (and in the definitions
        // themselves) must resolve — a dangling name would surface as an
        // unresolvable discovery response on some peer, so it fails the boot.
        var typeTable: [TypeDefinition] = []
        for namespace in namespaces {
            typeTable.append(contentsOf: namespace.types)
        }
        for container in sharedTypes {
            typeTable.append(contentsOf: container.types)
        }
        var typesByName: [String: TypeDefinition] = [:]
        for definition in typeTable {
            precondition(
                typesByName.updateValue(definition, forKey: definition.name) == nil,
                "Router: duplicate type definition '\(definition.name)'"
            )
        }

        // Probe every signature at startup: an unprobeable type fails the
        // daemon boot, not the first call, and the fingerprint needs them all.
        var namedResults: [(name: String, result: Result<MethodSignature, SchemaError>)] =
            applicationRoutes.map { ($0.name, $0.signatureThunk()) }
        if registerBuiltins {
            namedResults.append(contentsOf: Builtins.all.map { ($0.name, $0.signature()) })
        }
        var signatures: [MethodSignature] = []
        signatures.reserveCapacity(namedResults.count)
        for entry in namedResults {
            switch entry.result {
                case .success(let signature):
                    signatures.append(signature)
                case .failure(let error):
                    preconditionFailure(
                        "Router: schema probe failed for method '\(entry.name)': \(error)"
                    )
            }
        }
        signatures.sort { $0.name < $1.name }

        var referencedNames: Set<String> = []
        for signature in signatures {
            signature.collectReferencedTypeNames(into: &referencedNames)
        }
        for definition in typeTable {
            definition.schema.collectReferencedTypeNames(into: &referencedNames)
        }
        for name in referencedNames.sorted() {
            precondition(
                typesByName[name] != nil,
                """
                Router: unresolved type reference '\(name)' — no declared namespace or shared \
                Types container defines it
                """
            )
        }
        let types = typeTable.sorted { $0.name < $1.name }
        let fingerprint = SchemaFingerprint.compute(signatures, types: types)

        // Each method's namespace prefix as an entity, for rpc.schema
        // filtering: "journal.append" → "journal"; a single-segment name → root.
        var prefixByName: [String: EntityName] = [:]
        for name in names {
            switch EntityName.parse(Self.methodNamePrefix(of: name)) {
                case .success(let prefix):
                    prefixByName[name] = prefix
                case .failure(let error):
                    preconditionFailure(
                        "Router: method name '\(name)' has an invalid namespace prefix: \(error)"
                    )
            }
        }

        var allRoutes = applicationRoutes
        if registerBuiltins {
            allRoutes.append(
                // acceptsRoot: discovery scoped to root is the method's
                // documented tree-wide semantics; the handler filters its
                // response by per-method traversal rights.
                Handle(Builtins.schema, acceptsRoot: true) {
                    [signatures, prefixByName, types] _, context in
                    await Self.filteredSchema(
                        scope: context.entity,
                        peer: context.peer,
                        signatures: signatures,
                        prefixByName: prefixByName,
                        types: types,
                        fingerprint: fingerprint,
                        provider: aclProvider,
                        logger: logger
                    )
                }
            )
            allRoutes.append(
                Handle(Builtins.stat) { _, context in
                    await Self.stat(entity: context.entity, provider: aclProvider, logger: logger)
                }
            )
        }
        var routesByName: [String: Route] = [:]
        routesByName.reserveCapacity(allRoutes.count)
        for route in allRoutes {
            routesByName[route.name] = route
        }

        var declaredNamespaces = namespaces
        if registerBuiltins {
            declaredNamespaces.append(Builtins.self)
        }
        for namespace in declaredNamespaces {
            let descriptors = namespace.all
            let namespaceNames = Set(descriptors.map(\.name))
            for descriptor in descriptors {
                precondition(
                    routesByName[descriptor.name] != nil,
                    """
                    Router: unbound descriptor '\(descriptor.name)' — listed in \
                    \(namespace).all but no route registered
                    """
                )
            }
            let ownedPrefixes = Set(descriptors.map { Self.methodNamePrefix(of: $0.name) })
            for name in routesByName.keys
            where ownedPrefixes.contains(Self.methodNamePrefix(of: name)) {
                precondition(
                    namespaceNames.contains(name),
                    """
                    Router: route '\(name)' is under a method-name prefix owned by \
                    \(namespace) but missing from its `all` list
                    """
                )
            }
        }

        self.fingerprint = fingerprint
        self.signatures = signatures
        self.types = types
        self.routesByName = routesByName
        self.aclProvider = aclProvider
        self.logger = logger
        self.decoder = MMPackDecoder()
        self.authorizationDenials = Counter(label: "mm_server_auth_denials_total")
        self.inboundResponsesDropped = Counter(label: "mm_server_inbound_responses_dropped_total")
        self.streamFramesDropped = Counter(label: "mm_server_stream_frames_dropped_total")
        self.dispatchTimer = Timer(label: "mm_server_dispatch_duration_ns")
    }

    // MARK: - Stream classification

    /// The route for `method` if it is a **stream** route, else nil (unknown
    /// method or a unary route). The connection consults this on a kind-1 open:
    /// a non-nil result means "authorize and register a stream" (see
    /// ``authorize``); nil falls through to the unchanged unary ``dispatch``
    /// path. This is the single classification seam — the router stays
    /// stateless and the stream table lives on the connection.
    func streamRoute(for method: String) -> Route? {
        guard let route = self.routesByName[method], route.streamHandler != nil else {
            return nil
        }
        return route
    }

    // MARK: - Dispatch

    /// Dispatches one inbound *unary* envelope. Returns the response envelope
    /// for a request, or `nil` for inbound responses (which a server logs and
    /// drops — they are a peer protocol error).
    ///
    /// Stream-lifecycle frames (kinds 2–6) and stream opens (kind-1 to a stream
    /// route) are handled by the connection's stream table *before* dispatch is
    /// called, so on the live data path they never reach here. The kinds-2–6
    /// arm below therefore only fires for a ``Router`` driven directly in a unit
    /// test with no connection: it drops and counts, exactly as a connection
    /// drops a stream frame for an unknown msgid.
    public func dispatch(envelope: MMEnvelope, context: MMContext) async -> MMEnvelope? {
        let start = ContinuousClock.now
        defer { self.recordDispatchLatency(since: start) }

        switch envelope {
            case .response(let msgid, _, _):
                // A peer protocol error, but a peer-controlled per-frame event:
                // logged at debug (warning would let a hostile client force a
                // log line per frame at line rate) and counted for operators.
                self.inboundResponsesDropped.increment()
                self.logger.debug(
                    "inbound response dropped",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "msgid": "\(msgid)",
                    ]
                )
                return nil

            case .request(let msgid, let method, let entity, let params):
                guard let route = self.routesByName[method] else {
                    self.logger.debug(
                        "unknown method",
                        metadata: [
                            "connection": "\(context.connectionID)",
                            "method": "\(method)",
                        ]
                    )
                    return .response(
                        msgid: msgid,
                        error: Self.errorObject(.unknownMethod),
                        result: nil
                    )
                }
                switch await self.authorizeAndInvoke(
                    route: route, entity: entity, params: params, context: context, method: method
                ) {
                    case .success(let result):
                        return .response(msgid: msgid, error: nil, result: result)
                    case .failure(let errorObject):
                        return .response(msgid: msgid, error: errorObject, result: nil)
                }

            case .credit(let msgid, _), .item(let msgid, _, _), .end(let msgid),
                .stop(let msgid, _), .cancel(let msgid):
                // On a live connection the per-connection stream table consumes
                // kinds 2–6 before dispatch is ever called (see the type docs), so
                // this arm only fires for a Router driven directly with no
                // connection — a unit test, or a broken/premature peer.
                // Tolerate-and-drop, never fatal — log at debug, count, keep the
                // connection alive.
                self.streamFramesDropped.increment()
                self.logger.debug(
                    "stream frame dropped",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "msgid": "\(msgid)",
                        "kind": "\(Self.kindName(of: envelope))",
                    ]
                )
                return nil
        }
    }

    /// Steps 3–5 of the dispatch order: entity parsing, traversal, and the
    /// target check. Identical for unary calls and stream opens — authorization
    /// always runs on the open envelope's entity slot, never on any payload
    /// byte (the params slice is not interpreted before this passes). Returns
    /// the parsed target when the peer is authorized for the route's access on
    /// it (and `.execute` on every ancestor), or the wire error object to
    /// answer with.
    func authorize(
        route: Route,
        entity entityPath: String,
        context: MMContext,
        method: String
    ) async -> Result<EntityName, MMErrorObject> {
        // (3) Parse the envelope's entity slot; params stay untouched.
        let entity: EntityName
        switch EntityName.parse(entityPath) {
            case .failure(let error):
                self.logger.debug(
                    "target entity invalid",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "method": "\(method)",
                        "error": "\(error)",
                    ]
                )
                return .failure(Self.errorObject(.malformedParams))
            case .success(let target):
                entity = target
        }

        // Root targets: root has no ancestors and carries no ACL, so nothing
        // below would gate the dispatch — deny unless the route opted in via
        // `acceptsRoot` (see the type documentation).
        if entity.isRoot && !route.acceptsRoot {
            self.authorizationDenials.increment()
            self.logger.debug(
                "authorization denied",
                metadata: [
                    "connection": "\(context.connectionID)",
                    "method": "\(method)",
                    "entity": "\(entity)",
                    "reason": "root_target",
                ]
            )
            return .failure(Self.errorObject(.permissionDenied))
        }

        // (4) Traversal: x on every ancestor prefix, outermost first.
        for ancestor in entity.ancestors {
            if case .failure(let errorObject) = await self.requireAccess(
                .execute, on: ancestor, context: context, method: method
            ) {
                return .failure(errorObject)
            }
        }

        // (5) Target check. Root is "the whole tree" and carries no ACL, so
        // there is nothing to check here — root only reaches this point on an
        // opted-in route (see the root gate above).
        if !entity.isRoot {
            if case .failure(let errorObject) = await self.requireAccess(
                route.access, on: entity, context: context, method: method
            ) {
                return .failure(errorObject)
            }
        }
        return .success(entity)
    }

    /// Steps 3–6 of the dispatch order for unary calls: authorization
    /// (``authorize``) then handler invocation with the context scoped to the
    /// authorized target. Only unary routes reach here — stream opens are
    /// classified out in the connection before dispatch — so `route.handler`
    /// is always present.
    private func authorizeAndInvoke(
        route: Route,
        entity: String,
        params: ByteBuffer,
        context baseContext: MMContext,
        method: String
    ) async -> Result<ByteBuffer, MMErrorObject> {
        let context: MMContext
        switch await self.authorize(
            route: route, entity: entity, context: baseContext, method: method
        ) {
            case .failure(let errorObject):
                return .failure(errorObject)
            case .success(let target):
                context = baseContext.scoped(to: target)
        }
        guard let handler = route.handler else {
            // Unreachable: the connection routes stream opens away from
            // dispatch, so only unary routes arrive here.
            self.logger.error(
                "stream route reached unary dispatch",
                metadata: ["connection": "\(context.connectionID)", "method": "\(method)"]
            )
            return .failure(Self.errorObject(.internalError))
        }

        // (6) Full params decode + typed handler, only after authorization.
        switch await handler(params, context) {
            case .reply(let buffer):
                return .success(buffer)
            case .handlerError(let errorObject):
                return .failure(errorObject)
            case .malformedParams(let error):
                self.logger.debug(
                    "params decode failed",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "method": "\(method)",
                        "error": "\(error)",
                    ]
                )
                return .failure(Self.errorObject(.malformedParams))
            case .responseEncodingFailed(let error):
                self.logger.error(
                    "response encoding failed",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "method": "\(method)",
                        "error": "\(error)",
                    ]
                )
                return .failure(Self.errorObject(.internalError))
        }
    }

    /// Resolves one entity's ACL and requires `required` for the peer.
    /// No ACL record denies without leaking existence; provider failures are
    /// logged and surface as `internalError`.
    private func requireAccess(
        _ required: AccessMode,
        on entity: EntityName,
        context: MMContext,
        method: String
    ) async -> Result<Void, MMErrorObject> {
        switch await self.aclProvider.acl(for: entity) {
            case .failure(let error):
                self.logger.error(
                    "acl provider failed",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "method": "\(method)",
                        "entity": "\(entity)",
                        "error": "\(error.description)",
                    ]
                )
                return .failure(Self.errorObject(.internalError))
            case .success(.none):
                self.authorizationDenials.increment()
                self.logger.debug(
                    "authorization denied",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "method": "\(method)",
                        "entity": "\(entity)",
                        "reason": "no_acl",
                    ]
                )
                return .failure(Self.errorObject(.permissionDenied))
            case .success(.some(let acl)):
                guard acl.permitted(for: context.peer, required) else {
                    self.authorizationDenials.increment()
                    self.logger.debug(
                        "authorization denied",
                        metadata: [
                            "connection": "\(context.connectionID)",
                            "method": "\(method)",
                            "entity": "\(entity)",
                            "reason": "mode",
                        ]
                    )
                    return .failure(Self.errorObject(.permissionDenied))
                }
                return .success(())
        }
    }

    // MARK: - Builtin handlers

    /// `rpc.schema`: discovery filtered by traversal rights.
    ///
    /// ## Filtering rule (fixed)
    ///
    /// Each method's **method-name prefix** — its name minus the final verb
    /// segment (`journal.append` → `journal`) — is treated as an entity. A
    /// method is included iff the peer holds `.execute` on that prefix entity
    /// *and* on every ancestor of it; a missing ACL anywhere on that chain
    /// excludes the method. A method with a root prefix (single-segment name)
    /// has no chain and is always included. The call's envelope entity (the
    /// authorized `scope`) narrows the listing to methods whose prefix equals
    /// it or descends from it; root means the whole tree.
    ///
    /// The response `fingerprint` is the **unfiltered** router fingerprint —
    /// it identifies the server's schema for hello comparison, not what this
    /// peer can see. The response `types` list is the type definitions
    /// **transitively reachable** from the visible methods' schemas: you
    /// discover the types you can reach, nothing more.
    private static func filteredSchema(
        scope: EntityName,
        peer: PeerIdentity,
        signatures: [MethodSignature],
        prefixByName: [String: EntityName],
        types: [TypeDefinition],
        fingerprint: UInt64,
        provider: any EntityACLProvider,
        logger: Logger
    ) async -> Result<SchemaResponse, MMErrorObject> {
        // Per-request memo only; the router holds no cross-request ACL cache.
        var aclByEntity: [EntityName: EntityACL?] = [:]
        var visible: [MethodSignature] = []
        for signature in signatures {
            guard let prefix = prefixByName[signature.name] else {
                continue  // Unreachable: every registered name has a prefix.
            }
            if !scope.isRoot {
                guard prefix == scope || prefix.isDescendant(of: scope) else {
                    continue
                }
            }
            var reachable = true
            for step in prefix.ancestors + (prefix.isRoot ? [] : [prefix]) {
                let acl: EntityACL?
                if let memoized = aclByEntity[step] {
                    acl = memoized
                } else {
                    switch await provider.acl(for: step) {
                        case .failure(let error):
                            logger.error(
                                "acl provider failed",
                                metadata: [
                                    "method": "rpc.schema",
                                    "entity": "\(step)",
                                    "error": "\(error.description)",
                                ]
                            )
                            return .failure(Self.errorObject(.internalError))
                        case .success(let resolved):
                            aclByEntity[step] = resolved
                            acl = resolved
                    }
                }
                guard let acl, acl.permitted(for: peer, .execute) else {
                    reachable = false
                    break
                }
            }
            if reachable {
                visible.append(signature)
            }
        }
        // Types reachable from the visible methods, chased transitively
        // through the definitions themselves (a struct definition may
        // reference further named types). Startup validated resolvability,
        // so every collected name has a definition.
        var reachableTypeNames: Set<String> = []
        for signature in visible {
            signature.collectReferencedTypeNames(into: &reachableTypeNames)
        }
        let typesByName = Dictionary(
            types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var frontier = reachableTypeNames
        while !frontier.isEmpty {
            var discovered: Set<String> = []
            for name in frontier {
                typesByName[name]?.schema.collectReferencedTypeNames(into: &discovered)
            }
            frontier = discovered.subtracting(reachableTypeNames)
            reachableTypeNames.formUnion(frontier)
        }
        let visibleTypes = types.filter { reachableTypeNames.contains($0.name) }
        return .success(
            SchemaResponse(fingerprint: fingerprint, methods: visible, types: visibleTypes))
    }

    /// `entity.stat`: the target's ten-byte ACL. Dispatch already required
    /// `.read` on the target, so a nil ACL is reachable only for root — which
    /// has no ACL to report and denies like any other absent record.
    private static func stat(
        entity: EntityName,
        provider: any EntityACLProvider,
        logger: Logger
    ) async -> Result<StatResponse, MMErrorObject> {
        switch await provider.acl(for: entity) {
            case .failure(let error):
                logger.error(
                    "acl provider failed",
                    metadata: [
                        "method": "entity.stat",
                        "entity": "\(entity)",
                        "error": "\(error.description)",
                    ]
                )
                return .failure(Self.errorObject(.internalError))
            case .success(.none):
                return .failure(Self.errorObject(.permissionDenied))
            case .success(.some(let acl)):
                return .success(
                    StatResponse(owner: UInt32(acl.owner), group: UInt32(acl.group), mode: acl.mode)
                )
        }
    }

    // MARK: - Helpers

    /// Human-readable envelope kind for drop logs.
    static func kindName(of envelope: MMEnvelope) -> String {
        switch envelope {
            case .request: return "request"
            case .response: return "response"
            case .credit: return "credit"
            case .item: return "item"
            case .end: return "end"
            case .stop: return "stop"
            case .cancel: return "cancel"
        }
    }

    /// `journal.append` → `journal`; a single-segment name → `""` (root).
    static func methodNamePrefix(of name: String) -> String {
        guard let lastDot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.startIndex..<lastDot])
    }

    /// The wire error object for a protocol code, with a constant message —
    /// details stay in server logs, never on the wire.
    static func errorObject(_ code: MMErrorCode) -> MMErrorObject {
        let message: String
        switch code {
            case .unknownMethod: message = "unknown method"
            case .permissionDenied: message = "permission denied"
            case .malformedParams: message = "malformed params"
            case .tooManyInFlight: message = "too many in-flight requests"
            case .internalError: message = "internal error"
            case .streamViolation: message = "stream violation"
            case .cancelled: message = "cancelled"
            case .unknown(let raw): message = "error \(raw)"
        }
        return MMErrorObject(code: code.code, message: message)
    }

    private func recordDispatchLatency(since start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: ContinuousClock.now)
        let nanoseconds =
            elapsed.components.seconds &* 1_000_000_000
            &+ elapsed.components.attoseconds / 1_000_000_000
        self.dispatchTimer.recordNanoseconds(nanoseconds)
    }
}
