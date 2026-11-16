import MMSchema
import MMWire
import NIOCore

// MARK: - Handle: calls with declared errors

/// Binds a unary handler to a call with declared errors. The handler returns
/// the call's error type (`Journal.AppendError`), which reaches the peer as
/// a declared error: code 64, the case name as the message, and the union
/// value as the payload. Decoding, authorization and encoding failures stay
/// the protocol's, exactly as for ``Handle(_:_:_:)-(Method<Request,Response>,_,_)``.
@inlinable
public func Handle<
    Request: Codable & Sendable,
    Response: Codable & Sendable,
    Failure: MMDeclaredError
>(
    _ method: MethodWithErrors<Method<Request, Response>, Failure>,
    _ accepts: Accepts = Accepts(.all),
    _ body: @escaping @Sendable @concurrent (Request, MMContext) async -> Result<Response, Failure>
) -> Route {
    unaryRoute(
        method.base,
        accepts,
        signature: { method.signature() },
        decodeRequest: MMPackDecoder().decoding(Request.self),
        encodeResponse: MMPackEncoder().encoding(Response.self)
    ) { request, context in
        await body(request, context).mapError(declaredFailure)
    }
}

/// Binds a server-streaming handler to a call with declared errors; its
/// terminal fails with the call's error type.
@inlinable
public func Handle<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable,
    Failure: MMDeclaredError
>(
    _ method: MethodWithErrors<ServerStreamMethod<Request, Element, Response>, Failure>,
    _ accepts: Accepts = Accepts(.all),
    _ body:
        @escaping @Sendable @concurrent (Request, MMResponseSink<Element>, MMContext) async ->
        Result<Response, Failure>
) -> Route {
    serverStreamRoute(
        method.base,
        accepts,
        signature: { method.signature() },
        decodeRequest: MMPackDecoder().decoding(Request.self),
        encodeElement: MMPackEncoder().encoding(Element.self),
        encodeResponse: MMPackEncoder().encoding(Response.self)
    ) { request, sink, context in
        await body(request, sink, context).mapError(declaredFailure)
    }
}

/// Binds a client-streaming handler to a call with declared errors; its
/// terminal fails with the call's error type.
@inlinable
public func Handle<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable,
    Failure: MMDeclaredError
>(
    _ method: MethodWithErrors<ClientStreamMethod<Request, Element, Response>, Failure>,
    _ accepts: Accepts = Accepts(.all),
    _ body:
        @escaping @Sendable @concurrent (Request, MMRequestStream<Element>, MMContext) async ->
        Result<Response, Failure>
) -> Route {
    clientStreamRoute(
        method.base,
        accepts,
        signature: { method.signature() },
        decodeRequest: MMPackDecoder().decoding(Request.self),
        decodeElement: MMPackDecoder().decoding(Element.self),
        encodeResponse: MMPackEncoder().encoding(Response.self)
    ) { request, elements, context in
        await body(request, elements, context).mapError(declaredFailure)
    }
}

/// Binds a bidirectional-streaming handler to a call with declared errors;
/// its terminal fails with the call's error type.
@inlinable
public func Handle<
    Request: Codable & Sendable,
    RequestElement: Codable & Sendable,
    ResponseElement: Codable & Sendable,
    Response: Codable & Sendable,
    Failure: MMDeclaredError
>(
    _ method: MethodWithErrors<
        BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>, Failure
    >,
    _ accepts: Accepts = Accepts(.all),
    _ body:
        @escaping @Sendable @concurrent (
            Request, MMRequestStream<RequestElement>, MMResponseSink<ResponseElement>, MMContext
        ) async -> Result<Response, Failure>
) -> Route {
    bidirectionalStreamRoute(
        method.base,
        accepts,
        signature: { method.signature() },
        decodeRequest: MMPackDecoder().decoding(Request.self),
        decodeRequestElement: MMPackDecoder().decoding(RequestElement.self),
        encodeResponseElement: MMPackEncoder().encoding(ResponseElement.self),
        encodeResponse: MMPackEncoder().encoding(Response.self)
    ) { request, elements, sink, context in
        await body(request, elements, sink, context).mapError(declaredFailure)
    }
}

/// A handler's declared error as the wire error. One whose own coding fails
/// is a server-side programmer error: the peer sees an internal error, never
/// the cause.
@usableFromInline
func declaredFailure<Failure: MMDeclaredError>(_ failure: Failure) -> MMError {
    MMError.declaring(failure).match({ $0 }, { _ in Router.error(.internalError) })
}

// MARK: - On: calls with declared errors

/// Registers a unary handler for a call with declared errors; identical to
/// the matching `Handle` with the context first.
public func On<
    Request: Codable & Sendable,
    Response: Codable & Sendable,
    Failure: MMDeclaredError
>(
    _ method: MethodWithErrors<Method<Request, Response>, Failure>,
    _ accepts: Accepts = Accepts(.all),
    _ body: @escaping @Sendable @concurrent (MMContext, Request) async -> Result<Response, Failure>
) -> Route {
    Handle(method, accepts) { request, context in
        await body(context, request)
    }
}

/// Server-streaming form with declared errors: context, request, then the
/// element sink.
public func On<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable,
    Failure: MMDeclaredError
>(
    _ method: MethodWithErrors<ServerStreamMethod<Request, Element, Response>, Failure>,
    _ accepts: Accepts = Accepts(.all),
    _ body:
        @escaping @Sendable @concurrent (MMContext, Request, MMResponseSink<Element>) async ->
        Result<Response, Failure>
) -> Route {
    Handle(method, accepts) { request, sink, context in
        await body(context, request, sink)
    }
}

/// Client-streaming form with declared errors: context, request, then the
/// element sequence.
public func On<
    Request: Codable & Sendable,
    Element: Codable & Sendable,
    Response: Codable & Sendable,
    Failure: MMDeclaredError
>(
    _ method: MethodWithErrors<ClientStreamMethod<Request, Element, Response>, Failure>,
    _ accepts: Accepts = Accepts(.all),
    _ body:
        @escaping @Sendable @concurrent (MMContext, Request, MMRequestStream<Element>) async ->
        Result<Response, Failure>
) -> Route {
    Handle(method, accepts) { request, elements, context in
        await body(context, request, elements)
    }
}

/// Bidirectional form with declared errors: context, request, inbound
/// elements, outbound sink.
public func On<
    Request: Codable & Sendable,
    RequestElement: Codable & Sendable,
    ResponseElement: Codable & Sendable,
    Response: Codable & Sendable,
    Failure: MMDeclaredError
>(
    _ method: MethodWithErrors<
        BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>, Failure
    >,
    _ accepts: Accepts = Accepts(.all),
    _ body:
        @escaping @Sendable @concurrent (
            MMContext, Request, MMRequestStream<RequestElement>,
            MMResponseSink<ResponseElement>
        ) async -> Result<Response, Failure>
) -> Route {
    Handle(method, accepts) { request, elements, sink, context in
        await body(context, request, elements, sink)
    }
}
