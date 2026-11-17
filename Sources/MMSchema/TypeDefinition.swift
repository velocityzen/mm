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
/// `enumeration` for `Enum` declarations, a `union` for `Union`
/// declarations, a scalar kind for `Alias` declarations), **2** the optional
/// description, **3** the optional ``TypeSchema/Constraints`` every value of
/// the type keeps (named scalars only), **4** the optional deprecation.
/// The description and deprecation are documentation only — served by
/// discovery, never hashed or compared. The constraints are part of the
/// contract.
public struct TypeDefinition: Sendable, Hashable, Codable {
    /// The qualified name (`<namespace>.<TypeName>`).
    public var name: String
    /// The underlying shape the name resolves to.
    public var schema: TypeSchema
    /// Human-readable documentation, served by discovery. Never part of the
    /// fingerprint or of compatibility comparisons.
    public var description: String?
    /// The rules every value of a named scalar keeps beyond its shape; nil
    /// when it declares none. Part of the contract: served by discovery and
    /// hashed into the fingerprint.
    public var constraints: TypeSchema.Constraints?
    /// Why the type is deprecated, or nil when it is not. Documentation, like
    /// ``description``.
    public var deprecation: String?

    public init(
        name: String,
        schema: TypeSchema,
        description: String? = nil,
        constraints: TypeSchema.Constraints? = nil,
        deprecation: String? = nil
    ) {
        self.name = name
        self.schema = schema
        self.description = description
        self.constraints = constraints
        self.deprecation = deprecation
    }

    enum CodingKeys: Int, CodingKey {
        case name = 0
        case schema = 1
        case description = 2
        case constraints = 3
        case deprecation = 4
    }
}

extension TypeDefinition {
    /// The same definition with every description and deprecation removed —
    /// the form the fingerprint hashes and `verify`/`SchemaDifference`
    /// compare.
    public var strippingDescriptions: TypeDefinition {
        TypeDefinition(
            name: self.name,
            schema: self.schema.strippingDescriptions,
            constraints: self.constraints
        )
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
                case .union(let cases):
                    return cases.reduce(into: Set<String>()) { names, unionCase in
                        for field in unionCase.fields { names.formUnion(field.value) }
                    }
                case .bool, .int, .uint, .float, .double, .string, .bytes,
                    .date, .datetime, .timestamp, .duration, .uuid, .enumeration, .unknown:
                    return []
            }
        }
        names.formUnion(collected)
    }
}

extension MethodSignature {
    /// Every ``TypeSchema/reference(_:)`` name across the four payload slots
    /// and the declared errors.
    public func collectReferencedTypeNames(into names: inout Set<String>) {
        self.request.collectReferencedTypeNames(into: &names)
        self.response.collectReferencedTypeNames(into: &names)
        self.requestStream?.collectReferencedTypeNames(into: &names)
        self.responseStream?.collectReferencedTypeNames(into: &names)
        self.errors?.collectReferencedTypeNames(into: &names)
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
