import MMSchema
import MMWire

/// What a call's terminal fails with: ``MMCallError`` for a call without
/// declared errors, ``MMDeclaredCallError`` for one with them. The stream
/// handles are generic over it, so a handle's `result()` fails with the
/// call's own error type.
public protocol MMCallFailure: Error, Equatable, Sendable {
    /// The failure a call reports for this protocol-level call error.
    init(_ error: MMCallError)
}

extension MMCallError: MMCallFailure {
    /// The error itself: a call without declared errors fails with it as is.
    public init(_ error: MMCallError) {
        self = error
    }
}

/// How a call with declared errors fails: with one of the errors its
/// contract declares, typed, or with a protocol failure that no contract
/// declares (denied, transport, decode, an application error outside the
/// contract, ...).
///
/// A declared error the server sent under a case this build does not know
/// arrives as `.declared(.unknown(caseName))`, so an older client keeps
/// working against a newer server.
public enum MMDeclaredCallError<Declared: MMDeclaredError>: MMCallFailure {
    /// One of the call's declared errors.
    case declared(Declared)
    /// A failure outside the call's contract.
    case undeclared(MMCallError)

    /// Lifts a declared error out of a `.remote` call error: one with code 64
    /// whose payload decodes as `Declared`. Anything else stays undeclared.
    public init(_ error: MMCallError) {
        if case .remote(let remote) = error, let declared = remote.declared(as: Declared.self) {
            self = .declared(declared)
        } else {
            self = .undeclared(error)
        }
    }
}

extension MMDeclaredCallError: CustomStringConvertible {
    /// Log-ready one-liner: the declared case name, or the protocol failure's
    /// own description.
    public var description: String {
        switch self {
            case .declared(let declared):
                return "declared error \(declared.caseName)"
            case .undeclared(let error):
                return error.description
        }
    }
}

extension MMClientConnection {
    /// Makes a unary call whose contract declares errors. It fails with
    /// `.declared(Failure)` when the handler returned one of them and with
    /// `.undeclared(MMCallError)` for everything else; see
    /// ``call(_:on:_:)-(Method<Request,Response>,_,_)`` for the rest of the
    /// call's behavior.
    @inlinable
    public nonisolated func call<
        Request: Codable & Sendable,
        Response: Codable & Sendable,
        Failure: MMDeclaredError
    >(
        _ method: MethodWithErrors<Method<Request, Response>, Failure>,
        on entity: EntityName = .root,
        _ request: Request
    ) async -> Result<Response, MMDeclaredCallError<Failure>> {
        await self.call(method.base, on: entity, request).mapError(MMDeclaredCallError.init)
    }

    /// Opens a server-streaming call whose contract declares errors: its
    /// terminal fails with `MMDeclaredCallError<Failure>`.
    @inlinable
    public nonisolated func call<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable,
        Failure: MMDeclaredError
    >(
        _ method: MethodWithErrors<ServerStreamMethod<Request, Element, Response>, Failure>,
        on entity: EntityName = .root,
        _ request: Request
    ) async -> InboundStreamHandle<Element, Never, Response, MMDeclaredCallError<Failure>> {
        InboundStreamHandle(state: await self.openStream(method.base, on: entity, request))
    }

    /// Opens a client-streaming call whose contract declares errors: its
    /// terminal fails with `MMDeclaredCallError<Failure>`.
    @inlinable
    public nonisolated func call<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable,
        Failure: MMDeclaredError
    >(
        _ method: MethodWithErrors<ClientStreamMethod<Request, Element, Response>, Failure>,
        on entity: EntityName = .root,
        _ request: Request
    ) async -> OutboundStreamHandle<Element, Never, Response, MMDeclaredCallError<Failure>> {
        OutboundStreamHandle(
            state: await self.openStream(method.base, on: entity, request),
            encode: MMPackEncoder().encoding(Element.self)
        )
    }

    /// Opens a bidirectional call whose contract declares errors: its
    /// terminal, shared by both halves, fails with
    /// `MMDeclaredCallError<Failure>`.
    @inlinable
    public nonisolated func call<
        Request: Codable & Sendable,
        RequestElement: Codable & Sendable,
        ResponseElement: Codable & Sendable,
        Response: Codable & Sendable,
        Failure: MMDeclaredError
    >(
        _ method: MethodWithErrors<
            BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>, Failure
        >,
        on entity: EntityName = .root,
        _ request: Request
    ) async -> BidirectionalStreamHandle<
        RequestElement, ResponseElement, Response, MMDeclaredCallError<Failure>
    > {
        BidirectionalStreamHandle(
            state: await self.openStream(method.base, on: entity, request),
            encode: MMPackEncoder().encoding(RequestElement.self)
        )
    }
}
