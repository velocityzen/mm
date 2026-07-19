import FP
import Logging
import MMSchema
import MMWire
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
/// authorization. The builtin `server.schema` opts in (its response is filtered
/// by per-method traversal rights); `server.entity` does not (root carries no
/// ACL to report, so a root stat is denied like any absent record).
public struct Router: Sendable {
    /// `SchemaFingerprint.compute` over **all** registered signatures and
    /// type definitions, memoized at init. This is the hello-preamble
    /// fingerprint.
    public let fingerprint: UInt64
    /// Every registered method's signature, sorted by name. `server.schema`
    /// serves a per-peer filtered subset of this list.
    public let signatures: [MethodSignature]
    /// Every registered named-type definition, sorted by name — the union of
    /// the declared namespaces' tables and the shared `Types` containers.
    /// `server.schema` serves the subset transitively reachable from a peer's
    /// visible methods.
    public let types: [TypeDefinition]

    private let routesByName: [String: Route]
    private let aclProvider: any EntityACLProvider
    private let logger: Logger
    private let decoder: MMPackDecoder
    private let metrics: RouterMetrics

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
    ///     `server.schema` (traversal-filtered discovery) and `server.entity` — and
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
        // The boot-validation pipeline, one named step per invariant; every
        // step fails the daemon boot, never the first call.
        let applicationRoutes = routes()
        let builtinDescriptors = registerBuiltins ? Builtins.all : []
        let names = applicationRoutes.map(\.name) + builtinDescriptors.map(\.name)
        if let duplicate = firstDuplicate(names) {
            preconditionFailure("Router: duplicate route registered for method '\(duplicate)'")
        }

        let (types, typesByName) = Self.assembleTypeTable(
            namespaces: namespaces,
            sharedTypes: sharedTypes
        )
        let signatures = Self.probeSignatures(
            routes: applicationRoutes,
            builtins: builtinDescriptors
        )
        Self.requireResolvedReferences(signatures: signatures, types: types, in: typesByName)

        let fingerprint = SchemaFingerprint.compute(signatures, types: types)
        let prefixByName = Self.prefixTable(names: names)
        let allRoutes =
            applicationRoutes
            + (registerBuiltins
                ? Self.builtinRoutes(
                    signatures: signatures,
                    prefixByName: prefixByName,
                    types: types,
                    typesByName: typesByName,
                    fingerprint: fingerprint,
                    aclProvider: aclProvider,
                    logger: logger
                )
                : [])

        // Unique by the name check above.
        let routesByName = Dictionary(uniqueKeysWithValues: allRoutes.map { ($0.name, $0) })
        Self.requireNamespaceOwnership(
            of: namespaces + (registerBuiltins ? [Builtins.self] : []),
            over: routesByName
        )

        self.fingerprint = fingerprint
        self.signatures = signatures
        self.types = types
        self.routesByName = routesByName
        self.aclProvider = aclProvider
        self.logger = logger
        self.decoder = MMPackDecoder()
        self.metrics = RouterMetrics()
    }

    // MARK: - Boot-validation steps

    /// The nominal type table: definitions from every declared namespace plus
    /// the shared containers, sorted by name, with a by-name index. Duplicate
    /// names fail the boot.
    private static func assembleTypeTable(
        namespaces: [any MethodNamespace.Type],
        sharedTypes: [any TypeNamespace.Type]
    ) -> (types: [TypeDefinition], typesByName: [String: TypeDefinition]) {
        let typeTable = namespaces.flatMap { $0.types } + sharedTypes.flatMap { $0.types }
        if let duplicate = firstDuplicate(typeTable.map(\.name)) {
            preconditionFailure("Router: duplicate type definition '\(duplicate)'")
        }
        return (
            types: typeTable.sorted { $0.name < $1.name },
            typesByName: Dictionary(uniqueKeysWithValues: typeTable.map { ($0.name, $0) })
        )
    }

    /// Probes every signature at startup: an unprobeable type fails the
    /// daemon boot, not the first call, and the fingerprint needs them all.
    private static func probeSignatures(
        routes: [Route],
        builtins: [AnyMethod]
    ) -> [MethodSignature] {
        let named =
            routes.map { ($0.name, $0.signatureThunk()) }
            + builtins.map { ($0.name, $0.signature()) }

        return
            named
            .map { name, probed in
                probed.getOrElse { error in
                    preconditionFailure(
                        "Router: schema probe failed for method '\(name)': \(error)"
                    )
                }
            }
            .sorted { $0.name < $1.name }
    }

    /// Every reference in the registered schemas (and in the definitions
    /// themselves) must resolve — a dangling name would surface as an
    /// unresolvable discovery response on some peer, so it fails the boot.
    private static func requireResolvedReferences(
        signatures: [MethodSignature],
        types: [TypeDefinition],
        in typesByName: [String: TypeDefinition]
    ) {
        let referenced = types.reduce(
            into: signatures.reduce(into: Set<String>()) { collected, signature in
                signature.collectReferencedTypeNames(into: &collected)
            }
        ) { collected, definition in
            definition.schema.collectReferencedTypeNames(into: &collected)
        }

        if let unresolved = referenced.sorted().first(where: { typesByName[$0] == nil }) {
            preconditionFailure(
                """
                Router: unresolved type reference '\(unresolved)' — no declared namespace or \
                shared Types container defines it
                """
            )
        }
    }

    /// Each method's namespace prefix as an entity, for `server.schema`
    /// filtering: "journal.append" → "journal"; a single-segment name → root.
    private static func prefixTable(names: [String]) -> [String: EntityName] {
        Dictionary(
            uniqueKeysWithValues: names.map { name in
                (
                    name,
                    EntityName.parse(Self.methodNamePrefix(of: name)).getOrElse { error in
                        preconditionFailure(
                            "Router: method name '\(name)' has an invalid namespace prefix: \(error)"
                        )
                    }
                )
            }
        )
    }

    /// The two builtin routes, closing over the validated tables so the
    /// handlers never rebuild what init already proved (`typesByName` rides
    /// the capture for the reachability filter).
    private static func builtinRoutes(
        signatures: [MethodSignature],
        prefixByName: [String: EntityName],
        types: [TypeDefinition],
        typesByName: [String: TypeDefinition],
        fingerprint: UInt64,
        aclProvider: any EntityACLProvider,
        logger: Logger
    ) -> [Route] {
        [
            // acceptsRoot: discovery scoped to root is the method's
            // documented tree-wide semantics; the handler filters its
            // response by per-method traversal rights.
            Handle(Builtins.schema, acceptsRoot: true) { _, context in
                await Self.filteredSchema(
                    scope: context.entity,
                    peer: context.peer,
                    signatures: signatures,
                    prefixByName: prefixByName,
                    types: types,
                    typesByName: typesByName,
                    fingerprint: fingerprint,
                    provider: aclProvider,
                    logger: logger
                )
            },
            Handle(Builtins.entity) { _, context in
                await Self.stat(entity: context.entity, provider: aclProvider, logger: logger)
            },
        ]
    }

    /// Namespace cross-check: every descriptor a namespace lists is bound to
    /// a route, and every route under a namespace-owned method-name prefix is
    /// listed by that namespace.
    private static func requireNamespaceOwnership(
        of namespaces: [any MethodNamespace.Type],
        over routesByName: [String: Route]
    ) {
        for namespace in namespaces {
            let descriptors = namespace.all
            if let unbound = descriptors.first(where: { routesByName[$0.name] == nil }) {
                preconditionFailure(
                    """
                    Router: unbound descriptor '\(unbound.name)' — listed in \
                    \(namespace).all but no route registered
                    """
                )
            }
            let namespaceNames = Set(descriptors.map(\.name))
            let ownedPrefixes = Set(descriptors.map { Self.methodNamePrefix(of: $0.name) })
            if let orphan = routesByName.keys.first(where: { name in
                ownedPrefixes.contains(Self.methodNamePrefix(of: name))
                    && !namespaceNames.contains(name)
            }) {
                preconditionFailure(
                    """
                    Router: route '\(orphan)' is under a method-name prefix owned by \
                    \(namespace) but missing from its `all` list
                    """
                )
            }
        }
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
                self.metrics.inboundResponsesDropped.increment()
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
                        error: Self.error(.unknownMethod),
                        result: nil
                    )
                }
                return await self.authorizeAndInvoke(
                    route: route,
                    entity: entity,
                    params: params,
                    context: context,
                    method: method
                )
                .match(
                    { result in .response(msgid: msgid, error: nil, result: result) },
                    { error in .response(msgid: msgid, error: error, result: nil) }
                )

            case .credit(let msgid, _), .item(let msgid, _, _), .end(let msgid),
                .stop(let msgid, _), .cancel(let msgid):
                // On a live connection the per-connection stream table consumes
                // kinds 2–6 before dispatch is ever called (see the type docs), so
                // this arm only fires for a Router driven directly with no
                // connection — a unit test, or a broken/premature peer.
                // Tolerate-and-drop, never fatal — log at debug, count, keep the
                // connection alive.
                self.metrics.streamFramesDropped.increment()
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
    /// it (and `.execute` on every ancestor), or the wire `MMError` to
    /// answer with.
    func authorize(
        route: Route,
        entity entityPath: String,
        context: MMContext,
        method: String
    ) async -> Result<EntityName, MMError> {
        // (3) Parse the envelope's entity slot; params stay untouched.
        await EntityName.parse(entityPath)
            .tapError { error in
                self.logger.debug(
                    "target entity invalid",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "method": "\(method)",
                        "error": "\(error)",
                    ]
                )
            }
            .mapError { _ in Self.error(.malformedParams) }
            .flatMapAsync { entity in
                // Root targets: root has no ancestors and carries no ACL, so
                // nothing below would gate the dispatch — deny unless the
                // route opted in via `acceptsRoot` (see the type docs).
                if entity.isRoot && !route.acceptsRoot {
                    return .failure(
                        self.authorizationDenied(
                            method: method,
                            entity: entity,
                            reason: "root_target",
                            context: context
                        )
                    )
                }

                // (4) Traversal: x on every ancestor prefix, outermost first.
                for ancestor in entity.ancestors {
                    if case .failure(let error) = await self.requireAccess(
                        .execute,
                        on: ancestor,
                        context: context,
                        method: method
                    ) {
                        return .failure(error)
                    }
                }

                // (5) Target check. Root is "the whole tree" and carries no
                // ACL, so there is nothing to check here — root only reaches
                // this point on an opted-in route (see the root gate above).
                if !entity.isRoot {
                    if case .failure(let error) = await self.requireAccess(
                        route.access,
                        on: entity,
                        context: context,
                        method: method
                    ) {
                        return .failure(error)
                    }
                }
                return .success(entity)
            }
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
    ) async -> Result<ByteBuffer, MMError> {
        return await self.authorize(
            route: route,
            entity: entity,
            context: baseContext,
            method: method
        )
        .flatMapAsync { target in
            await self.invoke(
                route: route,
                context: baseContext.scoped(to: target),
                method: method,
                params: params
            )
        }
    }

    /// Step 6: the typed handler, with the context already scoped to the
    /// authorized target.
    private func invoke(
        route: Route,
        context: MMContext,
        method: String,
        params: ByteBuffer
    ) async -> Result<ByteBuffer, MMError> {
        guard let handler = route.handler else {
            // Unreachable: the connection routes stream opens away from
            // dispatch, so only unary routes arrive here.
            self.logger.error(
                "stream route reached unary dispatch",
                metadata: ["connection": "\(context.connectionID)", "method": "\(method)"]
            )
            return .failure(Self.error(.internalError))
        }

        // (6) Full params decode + typed handler, only after authorization.
        switch await handler(params, context) {
            case .reply(let buffer):
                return .success(buffer)
            case .handlerError(let error):
                return .failure(error)
            case .malformedParams(let error):
                self.logger.debug(
                    "params decode failed",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "method": "\(method)",
                        "error": "\(error)",
                    ]
                )
                return .failure(Self.error(.malformedParams))
            case .responseEncodingFailed(let error):
                self.logger.error(
                    "response encoding failed",
                    metadata: [
                        "connection": "\(context.connectionID)",
                        "method": "\(method)",
                        "error": "\(error)",
                    ]
                )
                return .failure(Self.error(.internalError))
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
    ) async -> Result<Void, MMError> {
        switch await self.aclProvider.acl(for: entity) {
            case .failure(let error):
                return .failure(
                    Self.aclProviderFailed(
                        error,
                        method: method,
                        entity: entity,
                        connection: "\(context.connectionID)",
                        logger: self.logger
                    )
                )
            case .success(.none):
                return .failure(
                    self.authorizationDenied(
                        method: method,
                        entity: entity,
                        reason: "no_acl",
                        context: context
                    )
                )
            case .success(.some(let acl)):
                guard acl.permitted(for: context.peer, required) else {
                    return .failure(
                        self.authorizationDenied(
                            method: method,
                            entity: entity,
                            reason: "mode",
                            context: context
                        )
                    )
                }
                return .success(())
        }
    }

    // MARK: - Builtin handlers

    /// `server.schema`: discovery filtered by traversal rights.
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
        typesByName: [String: TypeDefinition],
        fingerprint: UInt64,
        provider: any EntityACLProvider,
        logger: Logger
    ) async -> Result<SchemaResponse, MMError> {
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
                            return .failure(
                                Self.aclProviderFailed(
                                    error,
                                    method: "server.schema",
                                    entity: step,
                                    connection: nil,
                                    logger: logger
                                )
                            )
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
            SchemaResponse(fingerprint: fingerprint, methods: visible, types: visibleTypes)
        )
    }

    /// `server.entity`: the target's ten-byte ACL. Dispatch already required
    /// `.read` on the target, so a nil ACL is reachable only for root — which
    /// has no ACL to report and denies like any other absent record.
    private static func stat(
        entity: EntityName,
        provider: any EntityACLProvider,
        logger: Logger
    ) async -> Result<StatResponse, MMError> {
        switch await provider.acl(for: entity) {
            case .failure(let error):
                return .failure(
                    Self.aclProviderFailed(
                        error,
                        method: "server.entity",
                        entity: entity,
                        connection: nil,
                        logger: logger
                    )
                )
            case .success(.none):
                return .failure(Self.error(.permissionDenied))
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

    /// One implementation behind every deny site: count the denial, log it
    /// with its reason, produce the wire error.
    private func authorizationDenied(
        method: String,
        entity: EntityName,
        reason: String,
        context: MMContext
    ) -> MMError {
        self.metrics.authorizationDenials.increment()
        self.logger.debug(
            "authorization denied",
            metadata: [
                "connection": "\(context.connectionID)",
                "method": "\(method)",
                "entity": "\(entity)",
                "reason": "\(reason)",
            ]
        )
        return Self.error(.permissionDenied)
    }

    /// The one mapping for an ACL-provider failure: error log plus
    /// `internalError` — details stay in server logs, never on the wire.
    private static func aclProviderFailed(
        _ error: ACLProviderError,
        method: String,
        entity: EntityName,
        connection: String?,
        logger: Logger
    ) -> MMError {
        var metadata: Logger.Metadata = [
            "method": "\(method)",
            "entity": "\(entity)",
            "error": "\(error.description)",
        ]
        if let connection {
            metadata["connection"] = "\(connection)"
        }
        logger.error("acl provider failed", metadata: metadata)
        return Self.error(.internalError)
    }

    /// The wire `MMError` for a protocol code, with a constant message —
    /// details stay in server logs, never on the wire.
    static func error(_ code: MMErrorCode) -> MMError {
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
        return MMError(code: code.code, message: message)
    }

    private func recordDispatchLatency(since start: ContinuousClock.Instant) {
        // swift-metrics owns the Duration→nanoseconds conversion (saturating).
        self.metrics.dispatchDuration.record(duration: start.duration(to: ContinuousClock.now))
    }
}
