/// Result builder for `Router.init`'s route list.
///
/// Supports plain `Handle(...)` expressions, pre-built `[Route]` groups,
/// `if` (buildOptional), `if`/`else` (buildEither), and `for` loops
/// (buildArray), so routes can be registered conditionally at daemon startup.
@resultBuilder
public enum RouterBuilder {
    public static func buildExpression(_ expression: Route) -> [Route] {
        [expression]
    }

    public static func buildExpression(_ expression: [Route]) -> [Route] {
        expression
    }

    public static func buildBlock(_ components: [Route]...) -> [Route] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [Route]?) -> [Route] {
        component ?? []
    }

    public static func buildEither(first component: [Route]) -> [Route] {
        component
    }

    public static func buildEither(second component: [Route]) -> [Route] {
        component
    }

    public static func buildArray(_ components: [[Route]]) -> [Route] {
        components.flatMap { $0 }
    }
}
