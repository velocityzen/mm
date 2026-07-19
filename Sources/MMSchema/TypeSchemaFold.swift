extension TypeSchema {
    /// One flattened layer of a schema during a ``fold(resolver:_:)``: every
    /// child position already carries the child's folded result, so a
    /// transform handles exactly one case with no recursion of its own.
    public enum FoldStep<Result> {
        case bool, int, uint, float, double, string, bytes
        case optional(Result)
        case array(Result)
        case map(key: Result, value: Result)
        case structure([(field: Field, value: Result)])
        case enumeration([EnumCase])
        /// A `.reference` that could not be followed — missing definition, a
        /// definition chain that loops, or a structure recursing into itself.
        /// The transform decides whether that degrades or fails.
        case unresolvedReference(TypeResolutionFailure)
        case unknown
    }

    /// The schema catamorphism: the recursion over ``TypeSchema`` written
    /// once, so analyses (describing shapes, collecting names, rendering)
    /// are a single per-case transform instead of another hand-rolled
    /// walker. References resolve through `resolver`; a structure that
    /// recurses into itself surfaces as
    /// ``FoldStep/unresolvedReference(_:)`` with `.cycle` — a *schema* fold
    /// has no value to bound that recursion, unlike the value-directed
    /// walkers (``SchemaValue/validated(against:resolver:path:)``, the wire
    /// coders), which handle recursive shapes naturally.
    public func fold<Result>(
        resolver: TypeResolver,
        _ transform: (FoldStep<Result>) throws -> Result
    ) rethrows -> Result {
        try self.foldImplementation(resolver, [], transform)
    }

    private func foldImplementation<Result>(
        _ resolver: TypeResolver,
        _ inFlight: Set<String>,
        _ transform: (FoldStep<Result>) throws -> Result
    ) rethrows -> Result {
        switch self {
            case .bool: return try transform(.bool)
            case .int: return try transform(.int)
            case .uint: return try transform(.uint)
            case .float: return try transform(.float)
            case .double: return try transform(.double)
            case .string: return try transform(.string)
            case .bytes: return try transform(.bytes)
            case .optional(let wrapped):
                return try transform(
                    .optional(try wrapped.foldImplementation(resolver, inFlight, transform))
                )
            case .array(let element):
                return try transform(
                    .array(try element.foldImplementation(resolver, inFlight, transform))
                )
            case .map(let key, let value):
                return try transform(
                    .map(
                        key: try key.foldImplementation(resolver, inFlight, transform),
                        value: try value.foldImplementation(resolver, inFlight, transform)
                    )
                )
            case .structure(let fields):
                return try transform(
                    .structure(
                        try fields.map { field in
                            (
                                field,
                                try field.type.foldImplementation(resolver, inFlight, transform)
                            )
                        }
                    )
                )
            case .enumeration(let cases):
                return try transform(.enumeration(cases))
            case .reference(let name):
                guard !inFlight.contains(name) else {
                    return try transform(.unresolvedReference(.cycle(name)))
                }
                guard let definition = resolver.definition(named: name) else {
                    return try transform(.unresolvedReference(.unresolved(name)))
                }
                return try definition.schema.foldImplementation(
                    resolver,
                    inFlight.union([name]),
                    transform
                )
            case .unknown:
                return try transform(.unknown)
        }
    }
}
