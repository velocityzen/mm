/// A named type in the wire contract: the definition a
/// ``TypeSchema/reference(_:)`` resolves to.
///
/// Names are **nominal** (fixed decision): the qualified name
/// (`journal.Priority`, `common.LineMeta`) is part of the contract, hashed
/// into the schema fingerprint, and renaming a type is a schema change.
/// Definitions travel in `SchemaResponse.types` next to the method list, and
/// servers validate at startup that every reference in their registered
/// schemas resolves.
///
/// ## Wire encoding (fixed)
///
/// A map with integer keys: **0** the qualified name (string), **1** the
/// underlying ``TypeSchema`` (a `structure` for `Type` declarations, an
/// `enumeration` for `Enum` declarations), **2** the optional description.
/// The description is documentation only — served by discovery, never hashed
/// or compared.
public struct TypeDefinition: Sendable, Hashable, Codable {
    /// The qualified name (`<namespace>.<TypeName>`).
    public var name: String
    /// The underlying shape the name resolves to.
    public var schema: TypeSchema
    /// Human-readable documentation, served by discovery. Never part of the
    /// fingerprint or of compatibility comparisons.
    public var description: String?

    public init(name: String, schema: TypeSchema, description: String? = nil) {
        self.name = name
        self.schema = schema
        self.description = description
    }

    enum CodingKeys: Int, CodingKey {
        case name = 0
        case schema = 1
        case description = 2
    }
}

extension TypeDefinition {
    /// The same definition with every description removed — the form the
    /// fingerprint hashes and `verify`/`SchemaDifference` compare.
    public var strippingDescriptions: TypeDefinition {
        TypeDefinition(name: self.name, schema: self.schema.strippingDescriptions)
    }
}

extension TypeSchema {
    /// Collects every ``reference(_:)`` name in this shape (one level — the
    /// caller chases definitions for the transitive closure). Servers use
    /// this to validate resolvability at startup and to filter discovery to
    /// the types a peer's visible methods actually reach.
    public func collectReferencedTypeNames(into names: inout Set<String>) {
        // A fold with an empty resolver surfaces every reference as
        // unresolved — exactly the collect-without-chasing semantics this
        // API documents.
        let collected: Set<String> = self.fold(resolver: TypeResolver([])) { step in
            switch step {
                case .unresolvedReference(.unresolved(let name)),
                    .unresolvedReference(.cycle(let name)):
                    return [name]
                case .optional(let child), .array(let child):
                    return child
                case .map(let key, let value):
                    return key.union(value)
                case .structure(let fields):
                    return fields.reduce(into: Set<String>()) { $0.formUnion($1.value) }
                case .bool, .int, .uint, .float, .double, .string, .bytes,
                    .date, .datetime, .timestamp, .enumeration, .unknown:
                    return []
            }
        }
        names.formUnion(collected)
    }
}

extension MethodSignature {
    /// Every ``TypeSchema/reference(_:)`` name across the four payload slots.
    public func collectReferencedTypeNames(into names: inout Set<String>) {
        self.request.collectReferencedTypeNames(into: &names)
        self.response.collectReferencedTypeNames(into: &names)
        self.requestStream?.collectReferencedTypeNames(into: &names)
        self.responseStream?.collectReferencedTypeNames(into: &names)
    }
}

/// A sealed group of named type definitions — the types-only counterpart of
/// ``MethodNamespace``, produced by `#schemaTypes` blocks (or written by hand)
/// so shared types can live in a container that declares no methods.
/// ``MethodNamespace`` refines this protocol, so every method namespace can
/// also carry the definitions its methods reference (defaulted empty).
public protocol TypeNamespace {
    /// Every named type the container defines, qualified names included.
    static var types: [TypeDefinition] { get }

    /// Decoder-behavior probes of the Swift types backing the definitions,
    /// keyed by qualified name (``TypeSchema/probed(_:)`` on each). `#schema`
    /// generates this so `verify(against:)` can check that a generated type's
    /// actual decoder matches its definition — a self-described type cannot
    /// vouch for itself. Hand-written namespaces may leave the default empty
    /// table; the definition-vs-contract check still runs without it.
    static var probedTypes: [String: Result<TypeSchema, SchemaError>] { get }
}

extension TypeNamespace {
    public static var types: [TypeDefinition] { [] }
    public static var probedTypes: [String: Result<TypeSchema, SchemaError>] { [:] }
}
