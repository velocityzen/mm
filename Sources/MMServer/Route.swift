import MMSchema
import MMWire
import NIOCore

/// Handlers return their domain failures as the wire error object directly
/// (`Result<Response, MMErrorObject>`), so it needs `Error` in this module. MMWire
/// deliberately does not conform it — there, the error object is wire *data*,
/// not a Swift error channel.
extension MMErrorObject: Error {}

/// What one erased handler invocation produced. Internal: the router maps
/// these onto wire error codes and logs the internal cases.
enum RouteOutcome: Sendable {
    /// The handler succeeded; the payload is the encoded response value.
    case reply(ByteBuffer)
    /// The handler returned its typed failure; sent to the peer verbatim.
    case handlerError(MMErrorObject)
    /// The params slice failed to decode as the method's request type.
    /// Maps to `MMErrorCode.malformedParams`.
    case malformedParams(MMWireError)
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
        /// ``StreamStartup`` the connection registers and runs. `nil` means the
        /// params failed to decode as `Request`.
        case stream(ErasedStreamHandler)
    }

    /// The wire method name (`journal.append`).
    public let name: String
    /// The rwx class required on the target entity, from the descriptor.
    public let access: AccessMode
    /// Whether the route accepts `EntityName.root` as its target. Root carries
    /// no ACL, so nothing gates a root-targeted dispatch; the router therefore
    /// denies such requests with `permissionDenied` unless the route opted in
    /// via `Handle(method, acceptsRoot: true)`. Opting in is a declaration
    /// that the handler has documented tree-wide semantics and enforces its
    /// own authorization (as the builtin `rpc.schema` does by filtering its
    /// response by traversal rights).
    public let acceptsRoot: Bool

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
}

/// Binds a typed handler to a method descriptor — the **single type-erasure
/// point** of the server.
///
/// The erased handler (a) decodes `Request` from the raw params slice via
/// `MMPackDecoder`, (b) runs the typed body, (c) encodes `Response` via
/// `MMPackEncoder`. Decode failure maps to `malformedParams`; encode failure
/// of the response maps to `internalError` (and is logged by the router).
///
/// Handlers return `Result<Response, MMErrorObject>` — the wire error object
/// directly, so a domain failure reaches the peer verbatim. Protocol codes
/// 1–63 are reserved (`MMErrorCode`); application handlers use codes >= 64.
///
/// `acceptsRoot` (default false) opts the route into `EntityName.root`
/// targets, which the router otherwise denies with `permissionDenied` because
/// root carries no ACL to authorize against. Opt in only for methods with
/// documented tree-wide semantics whose handlers enforce their own
/// authorization — see ``Route/acceptsRoot``.
public func Handle<Request: Codable & Sendable, Response: Codable & Sendable>(
    _ method: Method<Request, Response>,
    acceptsRoot: Bool = false,
    _ body: @escaping @Sendable (Request, MMContext) async -> Result<Response, MMErrorObject>
) -> Route {
    Route(
        name: method.name,
        access: method.access,
        acceptsRoot: acceptsRoot,
        signatureThunk: { method.signature() },
        kind: .unary { params, context in
            let request: Request
            switch MMPackDecoder().decode(Request.self, from: params) {
                case .failure(let error):
                    return .malformedParams(error)
                case .success(let decoded):
                    request = decoded
            }
            switch await body(request, context) {
                case .failure(let errorObject):
                    return .handlerError(errorObject)
                case .success(let response):
                    switch MMPackEncoder().encode(response) {
                        case .failure(let error):
                            return .responseEncodingFailed(error)
                        case .success(let buffer):
                            return .reply(buffer)
                    }
            }
        }
    )
}

// MARK: - Stream handler registration

/// Encodes a handler's terminal `Result<Response, MMErrorObject>` into a
/// ``StreamTerminal``. A response that fails to encode is a server-side
/// programmer error, mapped to an internal-error terminal (the peer never sees
/// the cause).
private func streamTerminal<Response: Codable & Sendable>(
    _ result: Result<Response, MMErrorObject>
) -> StreamTerminal {
    switch result {
        case .failure(let errorObject):
            return .failure(errorObject)
        case .success(let response):
            switch MMPackEncoder().encode(response) {
                case .failure:
                    return .failure(
                        MMErrorObject(
                            code: MMErrorCode.internalError.code, message: "internal error"))
                case .success(let buffer):
                    return .success(buffer)
            }
    }
}

/// Builds a request-stream source and its typed sequence, wiring credit grants
/// through `seams`. Shared by the client- and bidirectional-streaming `Handle`s.
private func makeRequestStream<Element: Codable & Sendable>(
    msgid: UInt32,
    seams: StreamWireSeams,
    metrics: MMStreamMetrics
) -> (source: MMRequestStreamSource<Element>, stream: MMRequestStream<Element>) {
    let source = MMRequestStreamSource<Element>(
        msgid: msgid,
        frameSink: seams.sendFrame,
        metrics: metrics
    )
    let made = MMRequestStream<Element>.Base.makeSequence(
        elementType: Element.self,
        backPressureStrategy: .init(
            lowWatermark: MMStreamFlowControl.lowWatermark,
            highWatermark: Int(MMStreamFlowControl.initialWindow)
        ),
        finishOnDeinit: false,
        delegate: source
    )
    source.adopt(source: made.source)
    return (source, MMRequestStream(base: made.sequence, source: source))
}

/// Binds a server-streaming handler: `(request, sink, context)`. The server streams
/// `Element` values through `sink` before returning its terminal `Response`.
/// Authorization runs on `Request`'s entity at open, exactly as for unary methods.
public func Handle<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: ServerStreamMethod<Request, Element, Response>,
    acceptsRoot: Bool = false,
    _ body:
        @escaping @Sendable (Request, MMResponseSink<Element>, MMContext) async ->
        Result<Response, MMErrorObject>
) -> Route {
    Route(
        name: method.name,
        access: method.access,
        acceptsRoot: acceptsRoot,
        signatureThunk: { method.signature() },
        kind: .stream { params, context, msgid, seams, metrics in
            let request: Request
            switch MMPackDecoder().decode(Request.self, from: params) {
                case .failure:
                    return nil
                case .success(let decoded):
                    request = decoded
            }
            let sinkState = MMResponseSinkState(
                msgid: msgid,
                itemSink: seams.sendItem,
                metrics: metrics
            )
            let control = ConcreteStreamControl<NeverElement, Element>(
                requestSource: nil,
                responseSink: sinkState
            )
            let sink = MMResponseSink<Element>(state: sinkState)
            return StreamStartup(control: control) {
                streamTerminal(await body(request, sink, context))
            }
        }
    )
}

/// Binds a client-streaming handler: `(request, elements, context)`. The client streams
/// `Element` values (the `elements` sequence; its normal end is the client's
/// END) after opening with `Request`; the server answers with one terminal `Response`.
/// `elements.stop()` sends a server-initiated STOP (advisory; the call
/// continues). Authorization runs on `Request`'s entity at open.
public func Handle<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: ClientStreamMethod<Request, Element, Response>,
    acceptsRoot: Bool = false,
    _ body:
        @escaping @Sendable (Request, MMRequestStream<Element>, MMContext) async ->
        Result<Response, MMErrorObject>
) -> Route {
    Route(
        name: method.name,
        access: method.access,
        acceptsRoot: acceptsRoot,
        signatureThunk: { method.signature() },
        kind: .stream { params, context, msgid, seams, metrics in
            let request: Request
            switch MMPackDecoder().decode(Request.self, from: params) {
                case .failure:
                    return nil
                case .success(let decoded):
                    request = decoded
            }
            let (source, stream) =
                makeRequestStream(
                    msgid: msgid, seams: seams, metrics: metrics
                ) as (MMRequestStreamSource<Element>, MMRequestStream<Element>)
            let control = ConcreteStreamControl<Element, NeverElement>(
                requestSource: source,
                responseSink: nil
            )
            return StreamStartup(control: control) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await source.runGrantPump() }
                    let terminal = streamTerminal(await body(request, stream, context))
                    // Handler returned: finish the inbound sequence and end the
                    // grant nudge so the pump loop exits, then join.
                    source.finishFromTerminal()
                    await group.waitForAll()
                    return terminal
                }
            }
        }
    )
}

/// Binds a bidirectional-streaming handler: `(request, elements, sink, context)`. The client
/// streams `RequestElement` values (the `elements` sequence), the server streams
/// `ResponseElement` values (through `sink`), and the call terminates with one
/// `Response`. Authorization runs on `Request`'s entity at open.
public func Handle<
    Request: Codable & Sendable,
    RequestElement: Codable & Sendable,
    ResponseElement: Codable & Sendable,
    Response: Codable & Sendable
>(
    _ method: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>,
    acceptsRoot: Bool = false,
    _ body:
        @escaping @Sendable (
            Request, MMRequestStream<RequestElement>, MMResponseSink<ResponseElement>, MMContext
        ) async -> Result<Response, MMErrorObject>
) -> Route {
    Route(
        name: method.name,
        access: method.access,
        acceptsRoot: acceptsRoot,
        signatureThunk: { method.signature() },
        kind: .stream { params, context, msgid, seams, metrics in
            let request: Request
            switch MMPackDecoder().decode(Request.self, from: params) {
                case .failure:
                    return nil
                case .success(let decoded):
                    request = decoded
            }
            let (source, stream) =
                makeRequestStream(
                    msgid: msgid, seams: seams, metrics: metrics
                ) as (MMRequestStreamSource<RequestElement>, MMRequestStream<RequestElement>)
            let sinkState = MMResponseSinkState(
                msgid: msgid,
                itemSink: seams.sendItem,
                metrics: metrics
            )
            let control = ConcreteStreamControl<RequestElement, ResponseElement>(
                requestSource: source,
                responseSink: sinkState
            )
            let sink = MMResponseSink<ResponseElement>(state: sinkState)
            return StreamStartup(control: control) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await source.runGrantPump() }
                    let terminal = streamTerminal(await body(request, stream, sink, context))
                    source.finishFromTerminal()
                    sinkState.end()
                    await group.waitForAll()
                    return terminal
                }
            }
        }
    )
}

/// A `Codable & Sendable` placeholder for the absent element direction of a
/// half-streaming method (the request side of a server stream, the response
/// side of a client stream). Never instantiated — the corresponding source/sink
/// is always `nil` — so its `Codable` conformance is unreachable.
struct NeverElement: Codable, Sendable {}
