/// The one canonical resolution of `.reference` schemas through a
/// ``TypeDefinition`` table — the lookup previously re-implemented by every
/// schema walker (dynamic coding, contract verification, router startup).
///
/// Resolution follows reference *chains* (`.reference("A")` whose definition
/// is itself `.reference("B")`) and reports cycles instead of spinning.
/// Recursive *structures* (a type with a field referencing itself) are a
/// legal wire shape and are not an error here — value-directed walkers
/// terminate by value depth; only ``TypeSchema/fold(resolver:_:)`` needs the
/// explicit cycle cut it applies itself.
public struct TypeResolver: Sendable {
    private let definitions: [String: TypeDefinition]

    /// Later duplicates are ignored; servers precondition uniqueness at boot,
    /// and a resolver built from a discovery response mirrors what the server
    /// validated.
    public init(_ definitions: [TypeDefinition]) {
        var table: [String: TypeDefinition] = [:]
        table.reserveCapacity(definitions.count)
        for definition in definitions where table[definition.name] == nil {
            table[definition.name] = definition
        }
        self.definitions = table
    }

    public func definition(named name: String) -> TypeDefinition? {
        self.definitions[name]
    }

    /// Resolves a top-level reference chain to its defined schema. Non-references
    /// return themselves unchanged.
    public func resolve(_ schema: TypeSchema) -> Result<TypeSchema, TypeResolutionFailure> {
        var current = schema
        var visited: Set<String> = []
        while case .reference(let name) = current {
            guard visited.insert(name).inserted else {
                return .failure(.cycle(name))
            }
            guard let definition = self.definitions[name] else {
                return .failure(.unresolved(name))
            }
            current = definition.schema
        }
        return .success(current)
    }
}

/// Why a `.reference` did not resolve: no definition, or a definition chain
/// that loops back on itself.
public enum TypeResolutionFailure: Error, Sendable, Hashable {
    case unresolved(String)
    case cycle(String)
}
