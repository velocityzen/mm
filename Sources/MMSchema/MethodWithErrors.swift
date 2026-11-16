/// A call's declared errors as one Swift type — what `#schema` generates for
/// each call that can fail (`Journal.AppendError`, flat: the namespace's
/// cases and the call's own) and for the namespace's errors
/// (`Journal.Error`).
///
/// Its coding is the union wire form: `{0: "<case>", 1: <the case's
/// fields>}`, key 1 left out for a case without fields. A case this build
/// does not know decodes to an `unknown` case that keeps the tag. Errors are
/// the cold path, so the coding is `Codable` only — no generated MessagePack
/// code, unlike the payload types.
public protocol MMDeclaredError: Swift.Error, Codable, Hashable {
    /// The cases, as a method signature's ``MethodSignature/errors`` slot
    /// serves them: a ``TypeSchema/union(cases:)`` whose case names are the
    /// wire tags.
    static var declaredErrors: TypeSchema { get }
    /// The wire tag of this value's case. An `unknown` value keeps the tag it
    /// arrived with.
    var caseName: String { get }
}

/// A method descriptor whose call can fail with a declared error: `Base` is
/// the descriptor of any of the four shapes (`Method`, `ServerStreamMethod`,
/// `ClientStreamMethod`, `BidirectionalStreamMethod`) and `Failure` the
/// call's error type.
///
/// `#schema` emits one for every call with errors. Handlers bound to it
/// return `Result<Response, Failure>`, and calls made with it fail with
/// `MMDeclaredCallError<Failure>`: the declared error, typed, or the
/// protocol failure.
public struct MethodWithErrors<Base: Sendable, Failure: MMDeclaredError>: Sendable {
    /// The descriptor without its errors.
    public let base: Base
    /// The wire method name.
    public let name: String
    /// The rwx class this verb needs on its target entity.
    public let access: AccessMode
    private let baseSignature: @Sendable () -> Result<MethodSignature, SchemaError>
    private let baseProbedSignature: @Sendable () -> Result<MethodSignature, SchemaError>

    private init(
        base: Base,
        name: String,
        access: AccessMode,
        signature: @escaping @Sendable () -> Result<MethodSignature, SchemaError>,
        probedSignature: @escaping @Sendable () -> Result<MethodSignature, SchemaError>
    ) {
        self.base = base
        self.name = name
        self.access = access
        self.baseSignature = signature
        self.baseProbedSignature = probedSignature
    }

    /// A unary call that can fail with `Failure`.
    public init<Request, Response>(
        _ base: Method<Request, Response>,
        errors: Failure.Type
    ) where Base == Method<Request, Response> {
        self.init(
            base: base,
            name: base.name,
            access: base.access,
            signature: { base.signature() },
            probedSignature: { base.probedSignature() }
        )
    }

    /// A server-streaming call that can fail with `Failure`.
    public init<Request, Element, Response>(
        _ base: ServerStreamMethod<Request, Element, Response>,
        errors: Failure.Type
    ) where Base == ServerStreamMethod<Request, Element, Response> {
        self.init(
            base: base,
            name: base.name,
            access: base.access,
            signature: { base.signature() },
            probedSignature: { base.probedSignature() }
        )
    }

    /// A client-streaming call that can fail with `Failure`.
    public init<Request, Element, Response>(
        _ base: ClientStreamMethod<Request, Element, Response>,
        errors: Failure.Type
    ) where Base == ClientStreamMethod<Request, Element, Response> {
        self.init(
            base: base,
            name: base.name,
            access: base.access,
            signature: { base.signature() },
            probedSignature: { base.probedSignature() }
        )
    }

    /// A bidirectional-streaming call that can fail with `Failure`.
    public init<Request, RequestElement, ResponseElement, Response>(
        _ base: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>,
        errors: Failure.Type
    ) where Base == BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response> {
        self.init(
            base: base,
            name: base.name,
            access: base.access,
            signature: { base.signature() },
            probedSignature: { base.probedSignature() }
        )
    }

    /// The base descriptor's signature with `Failure`'s cases in its
    /// ``MethodSignature/errors`` slot.
    public func signature() -> Result<MethodSignature, SchemaError> {
        self.baseSignature().map { signature in
            var withErrors = signature
            withErrors.errors = Failure.declaredErrors
            return withErrors
        }
    }

    /// The decoder-behavior signature. A union's decoder is data-dependent, so
    /// the errors slot carries the described cases.
    func probedSignature() -> Result<MethodSignature, SchemaError> {
        self.baseProbedSignature().map { signature in
            var withErrors = signature
            withErrors.errors = Failure.declaredErrors
            return withErrors
        }
    }
}

extension AnyMethod {
    public init<Base, Failure>(_ method: MethodWithErrors<Base, Failure>) {
        self.init(
            name: method.name,
            access: method.access,
            signature: { method.signature() },
            probedSignature: { method.probedSignature() }
        )
    }
}

extension SchemaBuilder {
    /// A bare `MethodWithErrors` expression, erased into the list.
    public static func buildExpression<Base, Failure>(
        _ method: MethodWithErrors<Base, Failure>
    ) -> [AnyMethod] {
        [AnyMethod(method)]
    }
}
