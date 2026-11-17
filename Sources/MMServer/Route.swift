import FP
import MMSchema
import MMWire
import NIOCore

/// Handlers return their domain failures as the wire `MMError` directly
/// (`Result<Response, MMError>`), so it needs `Error` in this module. MMWire
/// deliberately does not conform it — there, `MMError` is wire *data*,
/// not a Swift error channel.
extension MMError: Error {}

/// What one erased handler invocation produced. Internal: the router maps
/// these onto wire error codes and logs the internal cases.
enum RouteOutcome: Sendable {
    /// The handler succeeded; the payload is the encoded response value.
    case reply(ByteBuffer)
    /// The handler returned its typed failure; sent to the peer verbatim.
    case handlerError(MMError)
    /// The params slice failed to decode as the method's request type, or
    /// decoded and broke a constraint the request declares. Maps to
    /// `MMErrorCode.malformedParams`, naming the failing path when it can.
    case malformedParams(IngressRejection)
    /// The handler's response value failed to encode. Programmer error on the
    /// server side; maps to `MMErrorCode.internalError` and is logged.
    case responseEncodingFailed(MMWireError)
}

/// One registered method: the wire name, the access class its verb requires on
/// its target entity, a signature thunk for fingerprinting/discovery, and the
/// erased handler (unary or streaming).
///
/// Construct routes with `Handle` — the single type-erasure point,
/// overloaded per descriptor (unary `Method` and the three stream
/// descriptors). Authorization is identical for every kind (it runs on the
/// open envelope's entity, before any params byte is decoded); only what
/// happens *after* authorization differs — a unary handler produces one
/// `RouteOutcome`, a stream handler registers stream state and runs for the
/// call's lifetime.
public struct Route: Sendable {
    /// What kind of handler backs this route, once authorization has passed.
    enum Kind: Sendable {
        /// A unary handler: decode `Request`, run the body, encode `Response`.
        case unary(@Sendable (ByteBuffer, MMContext) async -> RouteOutcome)
        /// A streaming handler: builds the typed source/sink and returns a
        /// ``StreamStartup`` the connection registers and runs, or the
        /// rejection of params that ingress refused.
        case stream(ErasedStreamHandler)
    }

    /// The wire method name (`journal.append`).
    public let name: String
    /// The rwx class required on the target entity, from the descriptor.
    public let access: AccessMode
    /// The entities the call's contract declares it targets; nil when the
    /// contract declares none.
    public let target: [EntityPattern]?
    /// What targets this route accepts, see ``Accepts``: the route's own
    /// `Accepts`, else the declared ``target``, else `Accepts(.all)`, any
    /// non-root entity the ACL admits. Root always requires the explicit
    /// `.root` pattern because it carries no ACL to authorize against.
    public let accepts: Accepts
    /// The route's own `Accepts`, when it declares one: the router checks at
    /// boot that it falls within the declared ``target``.
    let explicitAccepts: Accepts?

    /// Probes the descriptor's request/response types lazily; memoized per
    /// type by the schema probe cache.
    let signatureThunk: @Sendable () -> Result<MethodSignature, SchemaError>
    /// The erased handler, unary or streaming.
    let kind: Kind

    /// The unary handler, or nil for stream routes. The router's unary dispatch
    /// path uses this; stream opens use ``streamHandler`` instead.
    var handler: (@Sendable (ByteBuffer, MMContext) async -> RouteOutcome)? {
        if case .unary(let handler) = self.kind { return handler }
        return nil
    }

    /// The stream handler, or nil for unary routes.
    var streamHandler: ErasedStreamHandler? {
        if case .stream(let handler) = self.kind { return handler }
        return nil
    }

    init(
        name: String,
        access: AccessMode,
        target: [EntityPattern]?,
        accepts: Accepts?,
        signatureThunk: @escaping @Sendable () -> Result<MethodSignature, SchemaError>,
        kind: Kind
    ) {
        self.name = name
        self.access = access
        self.target = target
        self.explicitAccepts = accepts
        self.accepts = accepts ?? target.map { Accepts(patterns: $0) } ?? Accepts(.all)
        self.signatureThunk = signatureThunk
        self.kind = kind
    }

    /// The first pattern of the route's own `Accepts` outside its declared
    /// target, or nil when the route declares no `Accepts`, its call
    /// declares no target, or every pattern falls within the target.
    var patternOutsideTarget: EntityPattern? {
        guard let explicitAccepts, let target else { return nil }
        return EntityPattern.firstOutside(explicitAccepts.patterns, target)
    }
}

/// What targets a route accepts: one declarative vocabulary for both the
/// root opt-in and entity scoping, passed as the second argument of `On` /
/// `Handle`. The router checks it immediately after the target parses,
/// **before any ACL lookup**, and answers an unaccepted target with the
/// same wire error as an authorization denial, so a caller cannot
/// distinguish "outside this method's world" from "no access", and the ACL
/// provider is never consulted for it.
///
/// Patterns are ``EntityPattern``s, variadic; a target is accepted when
/// **any** pattern admits it:
///
/// - `Accepts(.all)` or `Accepts("*")`: any entity, root excluded.
/// - `Accepts("journal.*")`: strict descendants of `journal`, at any depth.
///   Glob discipline: the prefix entity itself is NOT included; list it
///   explicitly (`Accepts("journal", "journal.*")`) when the namespace
///   entity is also a valid target.
/// - `Accepts("tenants.*.journal")`: a `*` **segment** matches exactly one
///   segment: `tenants.acme.journal` yes, `tenants.a.b.journal` no. Only a
///   whole segment may be a wildcard (`"jour*"` is invalid), and segment
///   wildcards compose with the trailing form:
///   `"tenants.*.journal.*"` is any tenant's journal subtree.
/// - `Accepts("system.log", "system.audit")`: exactly these entities.
/// - `Accepts(.root)`: `EntityName.root`. Root carries no ACL, so nothing
///   else gates a root-targeted dispatch: accept it only for methods with
///   documented tree-wide semantics whose handlers enforce their own
///   authorization (the builtin `server.schema` does, by filtering its
///   response by traversal rights). Combine when the route serves both:
///   `Accepts(.root, .all)`.
///
/// ## The declared target
///
/// A call's contract may declare the entities it targets with `Target(...)`
/// in the same vocabulary. Then the target is contract: discovery serves
/// it, the fingerprint hashes it, and clients check it before they call.
/// A route without `Accepts` takes its call's declared target, and with
/// neither a route accepts `.all`. An explicit `Accepts` narrows the
/// declared target and must fall within it: every pattern within one of
/// the target's, which the router checks at boot, refusing to start
/// otherwise. A deployment may narrow a target, never widen it.
///
/// ## Entity inference
///
/// A vocabulary that names **exactly one concrete entity** (one pattern,
/// all literal, no trailing depth: `Accepts("system.log")`) additionally
/// lets callers omit the target: an entity-less request (the wire's root
/// target, which such a route could never otherwise accept) is inferred to
/// mean that entity, and traversal plus the target ACL check run on the
/// inferred value exactly as if the caller had spelled it. Any wider
/// vocabulary denies an entity-less request like any other unaccepted
/// target, so omission never becomes ambiguous.
///
/// Why this exists: ACL grants are per-entity-per-mode, never per-method
/// (Unix discipline: the read bit on a file gates every program that opens
/// it). In a daemon serving several method families over one entity tree,
/// `Accepts` keeps a family's verbs on its own nouns even when the ACL would
/// admit the peer. `Accepts` itself is routing policy: what the contract
/// promises is the declared target, never a route's narrowing of it.
public struct Accepts: Sendable {
    /// One target pattern; string literals use the grammar on
    /// ``EntityPattern``. An invalid pattern is a programmer error caught at
    /// construction (server boot), not at dispatch.
    public typealias Pattern = EntityPattern

    let patterns: [EntityPattern]
    /// The single concrete entity this vocabulary names, when it names
    /// exactly one: the router infers it for entity-less requests (see
    /// ``Accepts`` § Entity inference); nil for any wider vocabulary.
    let soleEntity: EntityName?
    /// Whether root-targeted dispatches are accepted.
    let admitsRoot: Bool

    public init(_ patterns: Pattern...) {
        self.init(patterns: patterns)
    }

    init(patterns: [EntityPattern]) {
        precondition(
            !patterns.isEmpty,
            "Accepts() with no patterns would deny every target — declare at least one"
        )
        self.patterns = patterns
        self.soleEntity = EntityPattern.soleEntity(of: patterns)
        self.admitsRoot = patterns.contains(.root)
    }

    /// Whether the (non-root) `entity` is accepted.
    func admits(_ entity: EntityName) -> Bool {
        EntityPattern.admits(self.patterns, entity)
    }
}

/// Binds a typed handler to a method descriptor — the **single type-erasure
/// point** of the server.
///
/// The erased handler (a) decodes `Request` from the raw params slice via
/// `MMPackDecoder`, (b) runs the typed body, (c) encodes `Response` via
/// `MMPackEncoder`. Decode failure maps to `malformedParams`, as does a
/// request that decodes and breaks a constraint the descriptor's
/// `requestCheck` declares; encode failure of the response maps to
/// `internalError` (and is logged by the router).
/// Types the schema macros generated MessagePack code for go through that
/// code, chosen once here rather than on every call.
///
/// Handlers return `Result<Response, MMError>` — the wire error
/// directly, so a domain failure reaches the peer verbatim. Protocol codes
/// 1–63 are reserved (`MMErrorCode`); application handlers use codes >= 64.
///
/// The optional second argument declares what targets the route accepts —
/// `Accepts("journal.*")`, `Accepts(.root)`, exact entities — replacing both
/// a separate root opt-in and any ad-hoc handler-side scoping; see
/// ``Accepts``. Without it the route accepts the call's declared target, or
/// any non-root entity the ACL admits when the call declares none.
///
/// Every handler shape runs in its call's own task (`@concurrent`), off any
/// actor.
///
/// Inlinable, as every `Handle` is: the coders are picked in the caller's
/// module, where the types are concrete, so a type's generated code is
/// specialized there instead of running unspecialized in this one.
@inlinable
public func Handle<Request: Codable & Sendable, Response: Codable & Sendable>(
    _ method: Method<Request, Response>,
    _ accepts: Accepts? = nil,
    _ body: @escaping @Sendable @concurrent (Request, MMContext) async -> Result<Response, MMError>
) -> Route {
    unaryRoute(
        method,
        accepts,
        signature: { method.signature() },
        decodeRequest: MMPackDecoder().decoding(Request.self),
        encodeResponse: MMPackEncoder().encoding(Response.self),
        body
    )
}

/// The unary ``Handle(_:_:_:)``'s route, with the coders its shell picked.
@usableFromInline
func unaryRoute<Request: Codable & Sendable, Response: Codable & Sendable>(
    _ method: Method<Request, Response>,
    _ accepts: Accepts?,
    signature: @escaping @Sendable () -> Result<MethodSignature, SchemaError>,
    decodeRequest: @escaping @Sendable (ByteBuffer) -> Result<Request, MMWireError>,
    encodeResponse: @escaping @Sendable (Response) -> Result<ByteBuffer, MMWireError>,
    _ body: @escaping @Sendable @concurrent (Request, MMContext) async -> Result<Response, MMError>
) -> Route {
    let decodeRequest = checkedDecoding(decodeRequest, method.requestCheck)
    return Route(
        name: method.name,
        access: method.access,
        target: method.target,
        accepts: accepts,
        signatureThunk: signature,
        kind: .unary { params, context in
            // Three stages, each folding its failure into the outcome that
            // names it: decode → handler → encode.
            await decodeRequest(params).matchAsync(
                { request in
                    await body(request, context).match(
                        { response in
                            encodeResponse(response).match(
                                { .reply($0) },
                                { .responseEncodingFailed($0) }
                            )
                        },
                        { .handlerError($0) }
                    )
                },
                { .malformedParams($0) }
            )
        }
    )
}

// MARK: - Stream handler registration

/// Encodes a handler's terminal `Result<Response, MMError>` into a
/// ``StreamTerminal`` through `encode`, the response encode its `Handle`
/// picked. A response that fails to encode is a server-side programmer error,
/// mapped to an internal-error terminal (the peer never sees the cause).
private func streamTerminal<Response: Codable & Sendable>(
    _ result: Result<Response, MMError>,
    encode: (Response) -> Result<ByteBuffer, MMWireError>
) -> StreamTerminal {
    result.match(
        { response in
            encode(response).match(
                { .success($0) },
                { _ in .failure(Router.error(.internalError)) }
            )
        },
        { .failure($0) }
    )
}

/// The construction every stream `Handle` shares: open-request decode (a
/// request that ingress refuses abandons startup with its rejection; the
/// connection replies `malformedParams` itself) and the `Route` assembly. Each shape supplies
/// only its startup — control wiring and run choreography. Like the unary
/// `Handle`, every coder is picked once per route, in each shape's inlinable
/// `Handle`, so a stream's items reach the generated code without a check
/// per item.
private func streamRoute<Request: Codable & Sendable>(
    name: String,
    access: AccessMode,
    target: [EntityPattern]?,
    accepts: Accepts?,
    signatureThunk: @escaping @Sendable () -> Result<MethodSignature, SchemaError>,
    decodeRequest: @escaping @Sendable (ByteBuffer) -> Result<Request, IngressRejection>,
    startup:
        @escaping @Sendable (
            Request, MMContext, UInt32, StreamWireSeams, MMStreamMetrics
        ) -> StreamStartup
) -> Route {
    Route(
        name: name,
        access: access,
        target: target,
        accepts: accepts,
        signatureThunk: signatureThunk,
        kind: .stream { params, context, msgid, seams, metrics in
            decodeRequest(params).map { request in
                startup(request, context, msgid, seams, metrics)
            }
        }
    )
}

/// The run choreography shared by the two request-stream-carrying shapes:
/// grant pump as a sibling task, the handler's terminal, finish the inbound
/// sequence (which ends the pump), optionally end the response sink, join.
private func runWithGrantPump(
    _ source: MMRequestStreamSource,
    endSink: (@Sendable () -> Void)? = nil,
    _ handler: @escaping @Sendable () async -> StreamTerminal
) async -> StreamTerminal {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await source.runGrantPump() }
        let terminal = await handler()
        source.finishFromTerminal()
        endSink?()
        await group.waitForAll()
        return terminal
    }
}

/// Builds a request-stream source and its typed sequence, wiring credit grants
/// through `seams`. Shared by the client- and bidirectional-streaming
/// `Handle`s, which pass the element decode they picked for the route.
private func makeRequestStream<Element: Codable & Sendable>(
    decoding decode: @escaping @Sendable (ByteBuffer) -> Result<Element, IngressRejection>,
    msgid: UInt32,
    seams: StreamWireSeams,
    metrics: MMStreamMetrics
) -> (source: MMRequestStreamSource, stream: MMRequestStream<Element>) {
    MMRequestStream<Element>.make(
        msgid: msgid,
        decoding: decode,
        frameSink: seams.sendFrame,
        metrics: metrics
    )
}

/// Binds a server-streaming handler: `(request, sink, context)`. The server streams
/// `Element` values through `sink` before returning its terminal `Response`.
/// Authorization runs on `Request`'s entity at open, exactly as for unary methods.
@inlinable
public func Handle<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: ServerStreamMethod<Request, Element, Response>,
    _ accepts: Accepts? = nil,
    _ body:
        @escaping @Sendable @concurrent (Request, MMResponseSink<Element>, MMContext) async ->
        Result<Response, MMError>
) -> Route {
    serverStreamRoute(
        method,
        accepts,
        signature: { method.signature() },
        decodeRequest: MMPackDecoder().decoding(Request.self),
        encodeElement: MMPackEncoder().encoding(Element.self),
        encodeResponse: MMPackEncoder().encoding(Response.self),
        body
    )
}

/// The server-streaming `Handle`'s route, with the coders its shell picked.
@usableFromInline
func serverStreamRoute<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: ServerStreamMethod<Request, Element, Response>,
    _ accepts: Accepts?,
    signature: @escaping @Sendable () -> Result<MethodSignature, SchemaError>,
    decodeRequest: @escaping @Sendable (ByteBuffer) -> Result<Request, MMWireError>,
    encodeElement: @escaping @Sendable (Element) -> Result<ByteBuffer, MMWireError>,
    encodeResponse: @escaping @Sendable (Response) -> Result<ByteBuffer, MMWireError>,
    _ body:
        @escaping @Sendable @concurrent (Request, MMResponseSink<Element>, MMContext) async ->
        Result<Response, MMError>
) -> Route {
    streamRoute(
        name: method.name,
        access: method.access,
        target: method.target,
        accepts: accepts,
        signatureThunk: signature,
        decodeRequest: checkedDecoding(decodeRequest, method.requestCheck)
    ) { (request: Request, context, msgid, seams, metrics) in
        let sinkState = MMResponseSinkState(
            msgid: msgid,
            itemSink: seams.sendItem,
            metrics: metrics
        )
        let control = ConcreteStreamControl(
            requestSource: nil,
            responseSink: sinkState
        )
        let sink = MMResponseSink<Element>(state: sinkState, encode: encodeElement)
        return StreamStartup(control: control) {
            streamTerminal(await body(request, sink, context), encode: encodeResponse)
        }
    }
}

/// Binds a client-streaming handler: `(request, elements, context)`. The client streams
/// `Element` values (the `elements` sequence; its normal end is the client's
/// END) after opening with `Request`; the server answers with one terminal `Response`.
/// `elements.stop()` sends a server-initiated STOP (advisory; the call
/// continues). Authorization runs on `Request`'s entity at open.
@inlinable
public func Handle<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: ClientStreamMethod<Request, Element, Response>,
    _ accepts: Accepts? = nil,
    _ body:
        @escaping @Sendable @concurrent (Request, MMRequestStream<Element>, MMContext) async ->
        Result<Response, MMError>
) -> Route {
    clientStreamRoute(
        method,
        accepts,
        signature: { method.signature() },
        decodeRequest: MMPackDecoder().decoding(Request.self),
        decodeElement: MMPackDecoder().decoding(Element.self),
        encodeResponse: MMPackEncoder().encoding(Response.self),
        body
    )
}

/// The client-streaming `Handle`'s route, with the coders its shell picked.
@usableFromInline
func clientStreamRoute<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: ClientStreamMethod<Request, Element, Response>,
    _ accepts: Accepts?,
    signature: @escaping @Sendable () -> Result<MethodSignature, SchemaError>,
    decodeRequest: @escaping @Sendable (ByteBuffer) -> Result<Request, MMWireError>,
    decodeElement: @escaping @Sendable (ByteBuffer) -> Result<Element, MMWireError>,
    encodeResponse: @escaping @Sendable (Response) -> Result<ByteBuffer, MMWireError>,
    _ body:
        @escaping @Sendable @concurrent (Request, MMRequestStream<Element>, MMContext) async ->
        Result<Response, MMError>
) -> Route {
    let decodeElement = checkedDecoding(decodeElement, method.elementCheck)
    return streamRoute(
        name: method.name,
        access: method.access,
        target: method.target,
        accepts: accepts,
        signatureThunk: signature,
        decodeRequest: checkedDecoding(decodeRequest, method.requestCheck)
    ) { (request: Request, context, msgid, seams, metrics) in
        let (source, stream) = makeRequestStream(
            decoding: decodeElement,
            msgid: msgid,
            seams: seams,
            metrics: metrics
        )

        let control = ConcreteStreamControl(
            requestSource: source,
            responseSink: nil,
            requestItemSchema: { (try? signature().get())?.requestStream }
        )
        return StreamStartup(control: control) {
            await runWithGrantPump(source) {
                streamTerminal(await body(request, stream, context), encode: encodeResponse)
            }
        }
    }
}

/// Binds a bidirectional-streaming handler: `(request, elements, sink, context)`. The client
/// streams `RequestElement` values (the `elements` sequence), the server streams
/// `ResponseElement` values (through `sink`), and the call terminates with one
/// `Response`. Authorization runs on `Request`'s entity at open.
@inlinable
public func Handle<
    Request: Codable & Sendable,
    RequestElement: Codable & Sendable,
    ResponseElement: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>,
    _ accepts: Accepts? = nil,
    _ body:
        @escaping @Sendable @concurrent (
            Request, MMRequestStream<RequestElement>, MMResponseSink<ResponseElement>, MMContext
        ) async -> Result<Response, MMError>
) -> Route {
    bidirectionalStreamRoute(
        method,
        accepts,
        signature: { method.signature() },
        decodeRequest: MMPackDecoder().decoding(Request.self),
        decodeRequestElement: MMPackDecoder().decoding(RequestElement.self),
        encodeResponseElement: MMPackEncoder().encoding(ResponseElement.self),
        encodeResponse: MMPackEncoder().encoding(Response.self),
        body
    )
}

/// The bidirectional `Handle`'s route, with the coders its shell picked.
@usableFromInline
func bidirectionalStreamRoute<
    Request: Codable & Sendable,
    RequestElement: Codable & Sendable,
    ResponseElement: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>,
    _ accepts: Accepts?,
    signature: @escaping @Sendable () -> Result<MethodSignature, SchemaError>,
    decodeRequest: @escaping @Sendable (ByteBuffer) -> Result<Request, MMWireError>,
    decodeRequestElement: @escaping @Sendable (ByteBuffer) -> Result<RequestElement, MMWireError>,
    encodeResponseElement: @escaping @Sendable (ResponseElement) -> Result<ByteBuffer, MMWireError>,
    encodeResponse: @escaping @Sendable (Response) -> Result<ByteBuffer, MMWireError>,
    _ body:
        @escaping @Sendable @concurrent (
            Request, MMRequestStream<RequestElement>, MMResponseSink<ResponseElement>, MMContext
        ) async -> Result<Response, MMError>
) -> Route {
    let decodeRequestElement = checkedDecoding(decodeRequestElement, method.requestElementCheck)
    return streamRoute(
        name: method.name,
        access: method.access,
        target: method.target,
        accepts: accepts,
        signatureThunk: signature,
        decodeRequest: checkedDecoding(decodeRequest, method.requestCheck)
    ) { (request: Request, context, msgid, seams, metrics) in
        let (source, stream) = makeRequestStream(
            decoding: decodeRequestElement,
            msgid: msgid,
            seams: seams,
            metrics: metrics
        )

        let sinkState = MMResponseSinkState(
            msgid: msgid,
            itemSink: seams.sendItem,
            metrics: metrics
        )

        let control = ConcreteStreamControl(
            requestSource: source,
            responseSink: sinkState,
            requestItemSchema: { (try? signature().get())?.requestStream }
        )
        let sink = MMResponseSink<ResponseElement>(state: sinkState, encode: encodeResponseElement)
        return StreamStartup(control: control) {
            await runWithGrantPump(source, endSink: { sinkState.end() }) {
                streamTerminal(
                    await body(request, stream, sink, context),
                    encode: encodeResponse
                )
            }
        }
    }
}

/// A `Codable & Sendable` placeholder for the absent element direction of a
/// half-streaming method (the request side of a server stream, the response
/// side of a client stream). Never instantiated — the corresponding source/sink
/// is always `nil` — so its `Codable` conformance is unreachable.
struct NeverElement: Codable, Sendable {}
