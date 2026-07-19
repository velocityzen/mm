/// The list-combinator plumbing every result builder in this package shares,
/// stated once: variadic block flattening, `if`/`if-else` passthrough, and
/// `for` flattening. Conforming builders declare only their `Element` and
/// their `buildExpression` lifts. Public because the builder transform
/// resolves these members from the *calling* module's code.
public protocol MMListBuilding {
    associatedtype Element
}

extension MMListBuilding {
    public static func buildBlock(_ components: [Element]...) -> [Element] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [Element]?) -> [Element] {
        component ?? []
    }

    public static func buildEither(first component: [Element]) -> [Element] {
        component
    }

    public static func buildEither(second component: [Element]) -> [Element] {
        component
    }

    public static func buildArray(_ components: [[Element]]) -> [Element] {
        components.flatMap { $0 }
    }
}
