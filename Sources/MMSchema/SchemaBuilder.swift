/// Declarative construction of a namespace's method list.
///
/// A ``MethodNamespace``'s `all` property is the sealed list the router
/// cross-checks at startup. Building it by hand means wrapping every
/// descriptor in ``AnyMethod`` and remembering to keep the array in sync —
/// exactly the kind of imperative bookkeeping a result builder removes:
///
/// ```swift
/// public enum Journal: MethodNamespace {
///     public static let append = Method<AppendRequest, AppendResponse>(
///         name: "journal.append", access: .write)
///     public static let read = Method<ReadRequest, ReadResponse>(
///         name: "journal.read", access: .read)
///
///     @SchemaBuilder public static var all: [AnyMethod] {
///         append
///         read
///     }
/// }
/// ```
///
/// Method values appear bare — the builder erases them. Conditional
/// composition works the way `RouterBuilder` does on the server side:
///
/// ```swift
/// @SchemaBuilder public static var all: [AnyMethod] {
///     append
///     read
///     if FeatureFlags.compaction {   // ship the descriptor only when built in
///         compact
///     }
/// }
/// ```
///
/// ## Why the descriptors themselves stay `static let`
///
/// The builder composes the *list*; it cannot declare the members. Call sites
/// depend on the descriptors' full generic types — `client.call(Journal.append,
/// request)` type-checks the request and response *because* `Journal.append`
/// is a `Method<AppendRequest, AppendResponse>` the compiler can see. A result
/// builder produces one homogeneous value, so a namespace declared entirely
/// inside a builder could only ever hand back type-erased methods, and the
/// typed call surface — the point of the whole design — would be gone. Sealed
/// descriptor constants plus a declarative `all` is the deliberate division
/// of labor.
@resultBuilder
public enum SchemaBuilder: MMListBuilding {
    public typealias Element = AnyMethod

    /// A bare `Method` expression, erased into the list.
    public static func buildExpression<Request: Codable & Sendable, Response: Codable & Sendable>(
        _ method: Method<Request, Response>
    ) -> [AnyMethod] {
        [AnyMethod(method)]
    }

    /// A bare `ServerStreamMethod` expression, erased into the list.
    public static func buildExpression<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: ServerStreamMethod<Request, Element, Response>
    ) -> [AnyMethod] {
        [AnyMethod(method)]
    }

    /// A bare `ClientStreamMethod` expression, erased into the list.
    public static func buildExpression<
        Request: Codable & Sendable,
        Element: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: ClientStreamMethod<Request, Element, Response>
    ) -> [AnyMethod] {
        [AnyMethod(method)]
    }

    /// A bare `BidirectionalStreamMethod` expression, erased into the list.
    public static func buildExpression<
        Request: Codable & Sendable,
        RequestElement: Codable & Sendable,
        ResponseElement: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ method: BidirectionalStreamMethod<Request, RequestElement, ResponseElement, Response>
    ) -> [AnyMethod] {
        [AnyMethod(method)]
    }

    /// An already-erased method.
    public static func buildExpression(_ method: AnyMethod) -> [AnyMethod] {
        [method]
    }

    /// A pre-built group — composing one namespace's list into another.
    public static func buildExpression(_ methods: [AnyMethod]) -> [AnyMethod] {
        methods
    }






    public static func buildLimitedAvailability(_ component: [AnyMethod]) -> [AnyMethod] {
        component
    }
}
