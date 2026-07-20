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
    /// What targets this route accepts — see ``Accepts``. The default,
    /// `Accepts(.all)`, is any non-root entity the ACL admits; root always
    /// requires the explicit `.root` pattern because it carries no ACL to
    /// authorize against.
    public let accepts: Accepts

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

/// What targets a route accepts — one declarative vocabulary for both the
/// root opt-in and entity scoping, passed as the second argument of `On` /
/// `Handle`. The router checks it immediately after the target parses —
/// **before any ACL lookup** — and answers an unaccepted target with the
/// same wire error as an authorization denial, so a caller cannot
/// distinguish "outside this method's world" from "no access", and the ACL
/// provider is never consulted for it.
///
/// Patterns are variadic; a target is accepted when **any** pattern admits
/// it:
///
/// - `Accepts(.all)` or `Accepts("*")` — any entity (the default; root still
///   excluded).
/// - `Accepts("journal.*")` — strict descendants of `journal`, at any depth.
///   Glob discipline: the prefix entity itself is NOT included — list it
///   explicitly (`Accepts("journal", "journal.*")`) when the namespace
///   entity is also a valid target.
/// - `Accepts("tenants.*.journal")` — a `*` **segment** matches exactly one
///   segment: `tenants.acme.journal` yes, `tenants.a.b.journal` no. Only a
///   whole segment may be a wildcard (`"jour*"` is invalid), and segment
///   wildcards compose with the trailing form —
///   `"tenants.*.journal.*"` is any tenant's journal subtree.
/// - `Accepts("system.log", "system.audit")` — exactly these entities.
/// - `Accepts(.root)` — `EntityName.root`. Root carries no ACL, so nothing
///   else gates a root-targeted dispatch: accept it only for methods with
///   documented tree-wide semantics whose handlers enforce their own
///   authorization (the builtin `server.schema` does, by filtering its
///   response by traversal rights). Combine when the route serves both:
///   `Accepts(.root, .all)`.
///
/// One grammar rule underneath: a pattern is dot-separated segments, each a
/// literal or `*` (exactly one segment); a **trailing** `.*` means one or
/// more further segments (any depth). Bare `"*"` is that rule's degenerate
/// case — no prefix, any depth — which is why it means "everything".
///
/// Why this exists: ACL grants are per-entity-per-mode, never per-method
/// (Unix discipline — the read bit on a file gates every program that opens
/// it). In a daemon serving several method families over one entity tree,
/// `Accepts` keeps a family's verbs on its own nouns even when the ACL would
/// admit the peer. It is routing policy, not contract: never fingerprinted,
/// never served by discovery.
public struct Accepts: Sendable {
    /// One target pattern; string literals use the grammar in ``Accepts``.
    /// An invalid pattern is a programmer error caught at construction
    /// (server boot), not at dispatch.
    public struct Pattern: Sendable, ExpressibleByStringLiteral {
        enum Segment: Sendable, Equatable {
            /// Matches this segment text exactly.
            case literal(String)
            /// `*` — matches exactly one segment, whatever its text.
            case anyOne
        }

        enum Kind: Sendable {
            case root
            /// The one grammar rule: match `segments` position-for-position;
            /// with `descendants`, one or more further segments must follow
            /// (so `[]` + descendants = any non-root entity).
            case entities(segments: [Segment], descendants: Bool)
        }

        let kind: Kind

        /// `EntityName.root` as a target.
        public static let root = Pattern(kind: .root)
        /// Any non-root entity.
        public static let all = Pattern(kind: .entities(segments: [], descendants: true))

        /// The explicit spelling of the string grammar:
        /// `.entity("tenants.*.journal")` ≡ `"tenants.*.journal"`.
        public static func entity(_ pattern: String) -> Pattern {
            Pattern(parsing: pattern)
        }

        public init(stringLiteral value: String) {
            self.init(parsing: value)
        }

        private init(kind: Kind) {
            self.kind = kind
        }

        private init(parsing pattern: String) {
            var raw = pattern.split(separator: ".", omittingEmptySubsequences: false)
            precondition(
                raw.allSatisfy { !$0.isEmpty },
                "Accepts pattern \"\(pattern)\" is not valid: empty segment"
            )
            var descendants = false
            if raw.last == "*" {
                raw.removeLast()
                descendants = true
            }
            let segments = raw.map { segment -> Segment in
                if segment == "*" {
                    return .anyOne
                }
                // A lone segment is itself a valid entity name; parsing it
                // enforces the character rules (and rejects `*` mixed into
                // a segment, like "jour*al").
                return EntityName.parse(String(segment)).match(
                    { _ in Segment.literal(String(segment)) },
                    { error -> Segment in
                        preconditionFailure(
                            "Accepts pattern \"\(pattern)\" is not valid: \(error)")
                    }
                )
            }
            precondition(
                !segments.isEmpty || descendants,
                "Accepts pattern \"\(pattern)\" is not valid: empty pattern"
            )
            self.kind = .entities(segments: segments, descendants: descendants)
        }
    }

    let patterns: [Pattern]

    public init(_ patterns: Pattern...) {
        precondition(
            !patterns.isEmpty,
            "Accepts() with no patterns would deny every target — declare at least one"
        )
        self.patterns = patterns
    }

    /// Whether root-targeted dispatches are accepted.
    var admitsRoot: Bool {
        self.patterns.contains { pattern in
            if case .root = pattern.kind { return true }
            return false
        }
    }

    /// Whether the (non-root) `entity` is accepted.
    func admits(_ entity: EntityName) -> Bool {
        let entitySegments = entity.rawValue.split(separator: ".")
        return self.patterns.contains { pattern in
            switch pattern.kind {
                case .root:
                    return false
                case .entities(let segments, let descendants):
                    guard
                        descendants
                            ? entitySegments.count > segments.count
                            : entitySegments.count == segments.count
                    else {
                        return false
                    }
                    return zip(segments, entitySegments).allSatisfy { pattern, actual in
                        switch pattern {
                            case .anyOne:
                                return true
                            case .literal(let text):
                                return text == actual
                        }
                    }
            }
        }
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
/// Handlers return `Result<Response, MMError>` — the wire error
/// directly, so a domain failure reaches the peer verbatim. Protocol codes
/// 1–63 are reserved (`MMErrorCode`); application handlers use codes >= 64.
///
/// The optional second argument declares what targets the route accepts —
/// `Accepts("journal.*")`, `Accepts(.root)`, exact entities — replacing both
/// a separate root opt-in and any ad-hoc handler-side scoping; see
/// ``Accepts``. The default accepts any non-root entity the ACL admits.
public func Handle<Request: Codable & Sendable, Response: Codable & Sendable>(
    _ method: Method<Request, Response>,
    _ accepts: Accepts = Accepts(.all),
    _ body: @escaping @Sendable (Request, MMContext) async -> Result<Response, MMError>
) -> Route {
    Route(
        name: method.name,
        access: method.access,
        accepts: accepts,
        signatureThunk: { method.signature() },
        kind: .unary { params, context in
            // Three stages, each folding its failure into the outcome that
            // names it: decode → handler → encode.
            await MMPackDecoder().decode(Request.self, from: params).matchAsync(
                { request in
                    await body(request, context).match(
                        { response in
                            MMPackEncoder().encode(response).match(
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
/// ``StreamTerminal``. A response that fails to encode is a server-side
/// programmer error, mapped to an internal-error terminal (the peer never sees
/// the cause).
private func streamTerminal<Response: Codable & Sendable>(
    _ result: Result<Response, MMError>
) -> StreamTerminal {
    result.match(
        { response in
            MMPackEncoder().encode(response).match(
                { .success($0) },
                { _ in .failure(Router.error(.internalError)) }
            )
        },
        { .failure($0) }
    )
}

/// The construction every stream `Handle` shares: open-request decode (a
/// malformed request abandons startup with `nil`; the router replies
/// `malformedParams` itself) and the `Route` assembly. Each shape supplies
/// only its startup — control wiring and run choreography.
private func streamRoute<Request: Codable & Sendable>(
    name: String,
    access: AccessMode,
    accepts: Accepts,
    signatureThunk: @escaping @Sendable () -> Result<MethodSignature, SchemaError>,
    startup:
        @escaping @Sendable (
            Request, MMContext, UInt32, StreamWireSeams, MMStreamMetrics
        ) -> StreamStartup
) -> Route {
    Route(
        name: name,
        access: access,
        accepts: accepts,
        signatureThunk: signatureThunk,
        kind: .stream { params, context, msgid, seams, metrics in
            switch MMPackDecoder().decode(Request.self, from: params) {
                case .failure:
                    return nil
                case .success(let request):
                    return startup(request, context, msgid, seams, metrics)
            }
        }
    )
}

/// The run choreography shared by the two request-stream-carrying shapes:
/// grant pump as a sibling task, the handler's terminal, finish the inbound
/// sequence (which ends the pump), optionally end the response sink, join.
private func runWithGrantPump<Element: Codable & Sendable>(
    _ source: MMRequestStreamSource<Element>,
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
/// `Handle`s. The element type parameter exists purely to pin `Element` —
/// nothing else in the argument list mentions it (the house convention for
/// return-type-only generics, as in `openStream(inbound:outbound:response:)`).
private func makeRequestStream<Element: Codable & Sendable>(
    of _: Element.Type,
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
    _ accepts: Accepts = Accepts(.all),
    _ body:
        @escaping @Sendable (Request, MMResponseSink<Element>, MMContext) async ->
        Result<Response, MMError>
) -> Route {
    streamRoute(
        name: method.name,
        access: method.access,
        accepts: accepts,
        signatureThunk: { method.signature() }
    ) { (request: Request, context, msgid, seams, metrics) in
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
    _ accepts: Accepts = Accepts(.all),
    _ body:
        @escaping @Sendable (Request, MMRequestStream<Element>, MMContext) async ->
        Result<Response, MMError>
) -> Route {
    streamRoute(
        name: method.name,
        access: method.access,
        accepts: accepts,
        signatureThunk: { method.signature() }
    ) { (request: Request, context, msgid, seams, metrics) in
        let (source, stream) = makeRequestStream(
            of: Element.self,
            msgid: msgid,
            seams: seams,
            metrics: metrics
        )

        let control = ConcreteStreamControl<Element, NeverElement>(
            requestSource: source,
            responseSink: nil
        )
        return StreamStartup(control: control) {
            await runWithGrantPump(source) {
                streamTerminal(await body(request, stream, context))
            }
        }
    }
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
    _ accepts: Accepts = Accepts(.all),
    _ body:
        @escaping @Sendable (
            Request, MMRequestStream<RequestElement>, MMResponseSink<ResponseElement>, MMContext
        ) async -> Result<Response, MMError>
) -> Route {
    streamRoute(
        name: method.name,
        access: method.access,
        accepts: accepts,
        signatureThunk: { method.signature() }
    ) { (request: Request, context, msgid, seams, metrics) in
        let (source, stream) = makeRequestStream(
            of: RequestElement.self,
            msgid: msgid,
            seams: seams,
            metrics: metrics
        )

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
            await runWithGrantPump(source, endSink: { sinkState.end() }) {
                streamTerminal(await body(request, stream, sink, context))
            }
        }
    }
}

/// A `Codable & Sendable` placeholder for the absent element direction of a
/// half-streaming method (the request side of a server stream, the response
/// side of a client stream). Never instantiated — the corresponding source/sink
/// is always `nil` — so its `Codable` conformance is unreachable.
struct NeverElement: Codable, Sendable {}
