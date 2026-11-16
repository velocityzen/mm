import MMSchema
import MMWire
import NIOCore

/// The typed streaming `call` overloads — one per stream descriptor. Each opens
/// the call on the normal open path (encode, msgid, in-flight cap, outbound
/// cap, writer wait) and returns a typed handle; server-side authorization
/// failures, and any local pre-send failure, surface uniformly through the
/// handle's `result()` terminal (with an empty element sequence).
///
/// `on:` defaults to `EntityName.root` — an entity-less open, valid only
/// against a route whose server-side `Accepts` names exactly one concrete
/// entity (the server infers and authorizes it); any other route answers
/// with `.denied` through the terminal.
///
/// Each overload is inlinable: the request's encode, the element coders and
/// the terminal's decode are picked in the caller's module, where the types
/// are concrete, so a type's generated code is specialized there instead of
/// running unspecialized in this one.
extension MMClientConnection {
    /// Opens a **server-streaming** call: the server streams `Element` values
    /// then a terminal `Response`. Returns an ``InboundStreamHandle`` — a
    /// single-iteration `AsyncSequence` of elements (consumption grants credit),
    /// plus `stop()` / `cancel()` and an awaitable `result()`.
    ///
    /// Iterate the element sequence from a task that does not also await other
    /// traffic on this connection (backpressure head-of-line caveat).
    @inlinable
    public nonisolated func call<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: ServerStreamMethod<Request, Element, Response>,
        on entity: EntityName = .root,
        _ request: Request
    ) async -> InboundStreamHandle<Element, Never, Response, MMCallError> {
        InboundStreamHandle(state: await self.openStream(method, on: entity, request))
    }

    /// Opens a **client-streaming** call: the client streams `Element` values
    /// after opening with `request`; the server answers with one terminal `Response`.
    /// Returns an ``OutboundStreamHandle`` — credit-gated `send(_:)`, a one-shot
    /// `finish()` (END), and an awaitable `result()`.
    @inlinable
    public nonisolated func call<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: ClientStreamMethod<Request, Element, Response>,
        on entity: EntityName = .root,
        _ request: Request
    ) async -> OutboundStreamHandle<Element, Never, Response, MMCallError> {
        OutboundStreamHandle(
            state: await self.openStream(method, on: entity, request),
            encode: MMPackEncoder().encoding(Element.self)
        )
    }

    /// Opens a **bidirectional** call: the client streams `RequestElement`
    /// values, the server streams `ResponseElement` values, and the call
    /// terminates with one `Response`. Returns a ``BidirectionalStreamHandle`` whose two
    /// halves (`inbound`, `outbound`) are usable independently from different
    /// tasks and share the one terminal.
    @inlinable
    public nonisolated func call<
        Request: Codable & Sendable,
        RequestElement: Codable & Sendable,
        ResponseElement: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>,
        on entity: EntityName = .root,
        _ request: Request
    ) async -> BidirectionalStreamHandle<RequestElement, ResponseElement, Response, MMCallError> {
        BidirectionalStreamHandle(
            state: await self.openStream(method, on: entity, request),
            encode: MMPackEncoder().encoding(RequestElement.self)
        )
    }

    /// Opens a server-streaming call's state: the request encoded and the
    /// element and terminal decoders picked here, in the caller's module.
    @inlinable
    nonisolated func openStream<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: ServerStreamMethod<Request, Element, Response>,
        on entity: EntityName,
        _ request: Request
    ) async -> ClientStreamState {
        await self.openStream(
            methodName: method.name,
            entity: entity,
            encodeRequest: { MMPackEncoder().encodeCheckingForGeneratedCode(request) },
            hasResponseStream: true,
            hasRequestStream: false,
            decoders: ClientStreamDecoders(inbound: Element.self, response: Response.self)
        )
    }

    /// Opens a client-streaming call's state: the request encoded and the
    /// terminal decoder picked here, in the caller's module.
    @inlinable
    nonisolated func openStream<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: ClientStreamMethod<Request, Element, Response>,
        on entity: EntityName,
        _ request: Request
    ) async -> ClientStreamState {
        await self.openStream(
            methodName: method.name,
            entity: entity,
            encodeRequest: { MMPackEncoder().encodeCheckingForGeneratedCode(request) },
            hasResponseStream: false,
            hasRequestStream: true,
            decoders: ClientStreamDecoders(inbound: Never.self, response: Response.self)
        )
    }

    /// Opens a bidirectional call's state: the request encoded and the
    /// element and terminal decoders picked here, in the caller's module.
    @inlinable
    nonisolated func openStream<
        Request: Codable & Sendable,
        RequestElement: Codable & Sendable,
        ResponseElement: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>,
        on entity: EntityName,
        _ request: Request
    ) async -> ClientStreamState {
        await self.openStream(
            methodName: method.name,
            entity: entity,
            encodeRequest: { MMPackEncoder().encodeCheckingForGeneratedCode(request) },
            hasResponseStream: true,
            hasRequestStream: true,
            decoders: ClientStreamDecoders(inbound: ResponseElement.self, response: Response.self)
        )
    }
}
