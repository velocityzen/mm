import MMSchema
import MMWire

/// The typed streaming `call` overloads — one per stream descriptor. Each opens
/// the call on the normal open path (encode, msgid, in-flight cap, outbound
/// cap, writer wait) and returns a typed handle; server-side authorization
/// failures, and any local pre-send failure, surface uniformly through the
/// handle's `result()` terminal (with an empty element sequence).
extension MMClientConnection {
    /// Opens a **server-streaming** call: the server streams `Element` values
    /// then a terminal `Response`. Returns an ``InboundStreamHandle`` — a
    /// single-iteration `AsyncSequence` of elements (consumption grants credit),
    /// plus `stop()` / `cancel()` and an awaitable `result()`.
    ///
    /// Iterate the element sequence from a task that does not also await other
    /// traffic on this connection (backpressure head-of-line caveat).
    public nonisolated func call<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: ServerStreamMethod<Request, Element, Response>,
        on entity: EntityName,
        _ request: Request
    ) async -> InboundStreamHandle<Element, Response> {
        let state = await self.openStream(
            methodName: method.name,
            entity: entity,
            request: request,
            hasResponseStream: true,
            hasRequestStream: false,
            inbound: Element.self,
            outbound: NoStreamElement.self,
            response: Response.self
        )
        return InboundStreamHandle(state: state)
    }

    /// Opens a **client-streaming** call: the client streams `Element` values
    /// after opening with `request`; the server answers with one terminal `Response`.
    /// Returns an ``OutboundStreamHandle`` — credit-gated `send(_:)`, a one-shot
    /// `finish()` (END), and an awaitable `result()`.
    public nonisolated func call<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: ClientStreamMethod<Request, Element, Response>,
        on entity: EntityName,
        _ request: Request
    ) async -> OutboundStreamHandle<Element, Response> {
        let state = await self.openStream(
            methodName: method.name,
            entity: entity,
            request: request,
            hasResponseStream: false,
            hasRequestStream: true,
            inbound: NoStreamElement.self,
            outbound: Element.self,
            response: Response.self
        )
        return OutboundStreamHandle(state: state)
    }

    /// Opens a **bidirectional** call: the client streams `RequestElement`
    /// values, the server streams `ResponseElement` values, and the call
    /// terminates with one `Response`. Returns a ``BidirectionalStreamHandle`` whose two
    /// halves (`inbound`, `outbound`) are usable independently from different
    /// tasks and share the one terminal.
    public nonisolated func call<
        Request: Codable & Sendable,
        RequestElement: Codable & Sendable,
        ResponseElement: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>,
        on entity: EntityName,
        _ request: Request
    ) async -> BidirectionalStreamHandle<RequestElement, ResponseElement, Response> {
        let state = await self.openStream(
            methodName: method.name,
            entity: entity,
            request: request,
            hasResponseStream: true,
            hasRequestStream: true,
            inbound: ResponseElement.self,
            outbound: RequestElement.self,
            response: Response.self
        )
        return BidirectionalStreamHandle(state: state)
    }
}
