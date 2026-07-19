import MMSchema

/// Result builder for `Router.init`'s route list.
///
/// Supports plain `Handle(...)` expressions, pre-built `[Route]` groups,
/// `if` (buildOptional), `if`/`else` (buildEither), and `for` loops
/// (buildArray), so routes can be registered conditionally at daemon startup.
@resultBuilder
public enum RouterBuilder: MMListBuilding {
    public typealias Element = Route

    public static func buildExpression(_ expression: Route) -> [Route] {
        [expression]
    }

    public static func buildExpression(_ expression: [Route]) -> [Route] {
        expression
    }





}
