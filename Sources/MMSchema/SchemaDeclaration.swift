/// A wire contract declared as data — the fully declarative face of the
/// schema system:
///
/// ```swift
/// let journal = Schema("journal") {
///     Call("append") {
///         Access { .write }
///         Request {
///             Field("line", .string)
///         }
///         Response {
///             Field("count", .int)
///         }
///     }
///     Call("read") {
///         Access { .read }
///         Response {
///             Field("lines", .array(Fields {
///                 Field("line", .string)
///                 Field("count", .int)
///             }))
///         }
///     }
/// }
/// ```
///
/// The declaration produces plain ``MethodSignature`` values, so everything
/// that consumes signatures consumes contracts: `journal.fingerprint()` pins
/// the expected hello fingerprint, `SchemaDifference(local: journal.signatures,
/// remote:)` diffs the contract against a live server's discovery response,
/// and ``SchemaDeclaration/verify(against:)-(MethodNamespace.Type)`` checks that the `Codable`
/// request/response types a namespace actually ships match the contract —
/// declaration-first development with the compiler-visible types held to it.
///
/// ## What the declaration is not
///
/// It cannot mint the typed descriptors themselves: `client.call(Journal.append,
/// request)` type-checks because `Journal.append` is a compiler-visible
/// `Method<AppendRequest, AppendResponse>`, and no runtime value can conjure
/// those generics. The division of labor is deliberate — types implement the
/// contract, the declaration *is* the contract, and `verify(against:)` welds
/// the two together in a test.
///
/// ## Keys
///
/// Fields encode as MessagePack maps with integer keys. Unpinned fields are
/// numbered in declaration order; pin a key (`Field(3, "note", .string)`) when
/// evolving a struct, because inserting an unpinned field renumbers everything
/// after it — the same contract as reordering `CodingKeys`. Every part —
/// Request, Response, and the stream elements — keys its fields from 0: the
/// call's target entity is **envelope metadata** (the open frame's entity
/// slot), never part of any payload. A method with no `Request` block at all
/// declares the common empty request.
public struct SchemaDeclaration: Sendable, Hashable {
    /// The namespace prefix — also the entity whose traversal rights gate
    /// discovery of these methods.
    public let namespace: String
    /// Human-readable namespace documentation — doc-only, like every other
    /// description: served by discovery (the response's `namespaces` list),
    /// used by generated CLI groups for their abstract, never fingerprinted.
    public let description: String?
    /// The declared method signatures, full wire names (`journal.append`),
    /// in declaration order.
    public let signatures: [MethodSignature]
    /// The named types the block declares (``Enum(_:description:deprecated:_:)`` /
    /// ``Union(_:description:deprecated:_:)`` / ``Type(_:description:deprecated:_:)``), qualified
    /// names included, in declaration order.
    public let types: [TypeDefinition]

    public init(
        namespace: String,
        description: String? = nil,
        signatures: [MethodSignature],
        types: [TypeDefinition] = []
    ) {
        self.namespace = namespace
        self.description = description
        self.signatures = signatures
        self.types = types
    }

    /// The stable 64-bit fingerprint of exactly these method signatures and
    /// named types. Matches a server's hello fingerprint only when the
    /// declaration covers the server's *complete* method set (all namespaces
    /// plus the builtins) and type table.
    public func fingerprint() -> UInt64 {
        SchemaFingerprint.compute(self.signatures, types: self.types)
    }

    /// Checks a namespace's type-derived signatures against this contract.
    ///
    /// Resolves every ``AnyMethod`` signature (probing the real `Codable`
    /// types) and compares by wire name: methods missing from the namespace,
    /// methods the namespace has but the contract does not, and per-method
    /// access/request/response divergence. Returns the mismatches as
    /// human-readable lines — empty means the implementation honors the
    /// contract:
    ///
    /// ```swift
    /// @Test func contractHolds() throws {
    ///     #expect(try journalContract.verify(against: Journal.self).get().isEmpty)
    /// }
    /// ```
    public func verify(against namespace: any MethodNamespace.Type) -> Result<[String], SchemaError>
    {
        self.verify(against: namespace.all).map { methodMismatches in
            methodMismatches
                + verifyTypeTable(
                    declared: self.types,
                    defined: namespace.types,
                    probes: namespace.probedTypes
                )
        }
    }

    /// The unbundled form of ``verify(against:)-(MethodNamespace.Type)`` for callers
    /// holding raw descriptor lists. Checks methods only; the namespace form
    /// also checks the declared type table.
    ///
    /// All shape comparisons are **description-stripped** (docs are never
    /// compatibility) and run against each descriptor's decoder-behavior
    /// probe, so a `SchemaDescribable` conformance cannot vouch for itself:
    /// when the behavior matches the contract but the described schema does
    /// not, the divergence is reported as a lying description.
    public func verify(
        against methods: [AnyMethod]
    ) -> Result<[String], SchemaError> {
        // Traverse: probe every implemented method (behavior + description),
        // short-circuiting on the first probe failure; then the diff is pure.
        methods
            .reduce(
                Result<[String: Implementation], SchemaError>.success([:])
            ) { collected, method in
                collected.flatMap { implemented in
                    method.probedSignature().flatMap { probed in
                        method.signature().map { described in
                            var implemented = implemented
                            implemented[probed.name] = Implementation(
                                probed: probed.strippingDescriptions,
                                described: described.strippingDescriptions
                            )
                            return implemented
                        }
                    }
                }
            }
            .map { implemented in
                let definitions = Dictionary(
                    self.types.map { ($0.name, $0.strippingDescriptions.schema) },
                    uniquingKeysWith: { first, _ in first }
                )
                let declaredNames = Set(self.signatures.map(\.name))
                return self.signatures.flatMap { signature in
                    self.mismatches(
                        for: signature,
                        implemented: implemented,
                        definitions: definitions
                    )
                }
                    + implemented.keys
                    .filter { !declaredNames.contains($0) }
                    .sorted()
                    .map { "\($0): implemented but not in the contract" }
            }
    }

    /// One implemented method's two signatures: decoder behavior (probed) and
    /// described schema, both description-stripped.
    private struct Implementation {
        var probed: MethodSignature
        var described: MethodSignature
    }

    /// Every mismatch between one declared method and its implementation:
    /// presence, then access, then the four payload slots, then the errors.
    private func mismatches(
        for declaredSignature: MethodSignature,
        implemented: [String: Implementation],
        definitions: [String: TypeSchema]
    ) -> [String] {
        let declared = declaredSignature.strippingDescriptions
        guard let actual = implemented[declared.name] else {
            return ["\(declared.name): declared but not implemented"]
        }
        let access: [String] =
            actual.probed.access == declared.access
            ? []
            : [
                "\(declared.name): access is \(actual.probed.access.rawValue), contract says \(declared.access.rawValue)"
            ]
        return access
            + slotMismatches(
                name: declared.name,
                slot: "request",
                declared: declared.request,
                probed: actual.probed.request,
                described: actual.described.request,
                definitions: definitions
            )
            + slotMismatches(
                name: declared.name,
                slot: "response",
                declared: declared.response,
                probed: actual.probed.response,
                described: actual.described.response,
                definitions: definitions
            )
            + streamMismatches(
                name: declared.name,
                slot: "request stream",
                declared: declared.requestStream,
                probed: actual.probed.requestStream,
                described: actual.described.requestStream,
                definitions: definitions
            )
            + streamMismatches(
                name: declared.name,
                slot: "response stream",
                declared: declared.responseStream,
                probed: actual.probed.responseStream,
                described: actual.described.responseStream,
                definitions: definitions
            )
            + errorMismatches(
                name: declared.name,
                declared: declared.errors,
                described: actual.described.errors
            )
    }

    /// Compares the declared errors with the ones the implementation's error
    /// type describes. A union's decoder is data-dependent, so there is no
    /// behavior to probe: the described set carries the check.
    private func errorMismatches(
        name: String,
        declared: TypeSchema?,
        described: TypeSchema?
    ) -> [String] {
        switch (declared, described) {
            case (nil, nil):
                return []
            case (.some, nil):
                return ["\(name): errors declared but not implemented"]
            case (nil, .some):
                return ["\(name): errors implemented but not in the contract"]
            case (.some(let declaredErrors), .some(let describedErrors)):
                return declaredErrors == describedErrors
                    ? [] : ["\(name): errors diverge from the contract"]
        }
    }

    /// Whether decoder behavior honors a declared slot. Equality is the
    /// common case; a slot that IS a named type (`Response(.reference(...))`)
    /// needs one resolution step, because the behavior probe deliberately
    /// bypassed the payload type's own `SchemaDescribable`: the behavior must
    /// match the declared *definition* (`.string` for enumerations — enums
    /// decode their raw value). A reference this declaration does not define
    /// (cross-schema) cannot be resolved here — the described check (nominal
    /// reference equality) carries it, and the defining container's own
    /// contract verifies the behavior.
    private func behaviorMatches(
        declared: TypeSchema,
        behavior: TypeSchema,
        definitions: [String: TypeSchema]
    ) -> Bool {
        // Constraints are checked after decoding, so no probe sees them.
        let declared = declared.strippingConstraints
        if behavior == declared { return true }
        guard case .reference(let name) = declared else { return false }
        guard let definition = definitions[name] else { return true }
        switch definition {
            case .enumeration: return behavior == .string
            // A union's decoder reads the case's fields only for the case it
            // finds, so its behavior is unknowable; the described check
            // carries it.
            case .union: return true
            default: return behavior == definition.strippingConstraints
        }
    }

    /// Compares one payload slot: decoder behavior against the contract first
    /// (authoritative), then the described schema — a `SchemaDescribable`
    /// drifting from the behavior it describes is its own mismatch. A probe of
    /// `.unknown` means the behavior is unknowable (empty structs request no
    /// container; data-dependent decoders cannot be walked) — exactly the
    /// ``SchemaDescribable`` escape hatch — so the described schema carries
    /// the check alone.
    private func slotMismatches(
        name: String,
        slot: String,
        shapeNoun: String = "shape",
        describedNoun: String = "described schema",
        declared: TypeSchema,
        probed: TypeSchema,
        described: TypeSchema?,
        definitions: [String: TypeSchema]
    ) -> [String] {
        let behavior = probed == .unknown ? (described ?? probed) : probed
        if !behaviorMatches(declared: declared, behavior: behavior, definitions: definitions) {
            return ["\(name): \(slot) \(shapeNoun) diverges from the contract"]
        }
        if let described, described != declared {
            return ["\(name): \(slot) \(describedNoun) diverges from the contract"]
        }
        return []
    }

    /// Compares one stream slot of a declared and an implemented signature:
    /// presence must agree in both directions; present elements share the
    /// unary slot comparison (with element-flavored wording).
    private func streamMismatches(
        name: String,
        slot: String,
        declared: TypeSchema?,
        probed: TypeSchema?,
        described: TypeSchema?,
        definitions: [String: TypeSchema]
    ) -> [String] {
        switch (declared, probed) {
            case (nil, nil):
                return []
            case (.some, nil):
                return ["\(name): \(slot) declared but not implemented"]
            case (nil, .some):
                return ["\(name): \(slot) implemented but not in the contract"]
            case (.some(let declaredElement), .some(let probedElement)):
                return self.slotMismatches(
                    name: name,
                    slot: slot,
                    shapeNoun: "element shape",
                    describedNoun: "element described schema",
                    declared: declaredElement,
                    probed: probedElement,
                    described: described,
                    definitions: definitions
                )
        }
    }

}

/// Checks a declared type table against a namespace's definitions and
/// decoder-behavior probes. Definitions compare description-stripped and by
/// qualified name (names are nominal). A probe for an `enumeration`
/// definition must record `.string` — string-valued enums decode their raw
/// value; anything else must match the definition's shape. Shared by
/// ``SchemaDeclaration/verify(against:)-swift.method`` and
/// ``TypeNamespaceDeclaration/verify(against:)``.
func verifyTypeTable(
    declared declaredTypes: [TypeDefinition],
    defined: [TypeDefinition],
    probes: [String: Result<TypeSchema, SchemaError>]
) -> [String] {
    let definedByName = Dictionary(
        defined.map { ($0.name, $0) },
        uniquingKeysWith: { _, latest in latest }
    )
    let declaredNames = Set(declaredTypes.map(\.name))
    return declaredTypes.flatMap { declaredDefinition in
        typeMismatches(
            for: declaredDefinition,
            definedByName: definedByName,
            probes: probes
        )
    }
        + definedByName.keys
        .filter { !declaredNames.contains($0) }
        .sorted()
        .map { "\($0): type defined by the namespace but not in the contract" }
}

/// Every mismatch between one declared type and the namespace's definition:
/// presence, then the definition against the contract, then decoder behavior
/// against the definition.
private func typeMismatches(
    for declaredDefinition: TypeDefinition,
    definedByName: [String: TypeDefinition],
    probes: [String: Result<TypeSchema, SchemaError>]
) -> [String] {
    let declared = declaredDefinition.strippingDescriptions
    guard let actual = definedByName[declared.name] else {
        return ["\(declared.name): type declared but not defined by the namespace"]
    }
    let definition: [String] =
        actual.strippingDescriptions.schema == declared.schema
            && actual.constraints == declared.constraints
        ? []
        : ["\(declared.name): type definition diverges from the contract"]
    return definition + probeMismatch(for: declared, probe: probes[declared.name])
}

/// The decoder-behavior check for one declared type; empty when no probe
/// exists for the name.
private func probeMismatch(
    for declared: TypeDefinition,
    probe: Result<TypeSchema, SchemaError>?
) -> [String] {
    switch probe {
        case nil:
            return []
        case .failure:
            return ["\(declared.name): type probe failed"]
        case .success(let probed):
            // A union's decoder is data-dependent: the probe sees only the
            // tag, never a case's fields.
            if case .union = declared.schema { return [] }
            let expected: TypeSchema =
                if case .enumeration = declared.schema {
                    .string
                } else {
                    declared.schema.strippingConstraints
                }
            // .unknown = unknowable behavior (empty structs); the
            // definition-vs-contract check still holds.
            return probed != .unknown && probed.strippingDescriptions != expected
                ? ["\(declared.name): decoder behavior diverges from the type definition"]
                : []
    }
}

/// One declared method, before the namespace prefix is applied. Produced by
/// ``Call(_:description:deprecated:_:)`` inside a ``Schema(_:_:)`` block.
public struct MethodDeclaration: Sendable, Hashable {
    public let name: String
    public let access: AccessMode
    public let request: TypeSchema
    public let response: TypeSchema
    /// Element shape of the declared `RequestStream`; `nil` when the
    /// method declares none.
    public let requestStream: TypeSchema?
    /// Element shape of the declared `ResponseStream`; `nil` when the
    /// method declares none.
    public let responseStream: TypeSchema?
    /// The five documentation slots (call + four parts), served by discovery,
    /// never compared or fingerprinted.
    public let description: String?
    public let requestDescription: String?
    public let responseDescription: String?
    public let requestStreamDescription: String?
    public let responseStreamDescription: String?
    /// Why the call is deprecated, or nil when it is not. Documentation,
    /// like the descriptions.
    public let deprecation: String?
    /// The CLI presentation overlay, when the call declares one. Local to the
    /// declaration: never forwarded into ``MethodSignature``, never on the
    /// wire — consumed by `#schema`'s CLI generation.
    public let cli: CLIOverlay?
    /// The call's own `Errors { ... }` cases, before the enclosing schema
    /// resolves them and adds the namespace's.
    public let errors: [ErrorCaseDeclaration]
}

/// One declared named type, produced by ``Enum(_:description:deprecated:_:)``,
/// ``Union(_:description:deprecated:_:)``, ``Type(_:description:deprecated:_:)`` or
/// ``Alias(_:_:constraints:description:deprecated:)`` inside a
/// ``Schema(_:_:)`` or ``Types(_:_:)`` block. The enclosing block qualifies
/// the name with its namespace.
public struct TypeDeclaration: Sendable, Hashable {
    enum Payload: Sendable, Hashable {
        case structure([Field])
        case enumeration([EnumCaseDeclaration])
        case union([UnionCaseDeclaration])
        case alias(TypeSchema, TypeSchema.Constraints?)
    }

    let name: String
    let description: String?
    let deprecation: String?
    let payload: Payload
}

/// One declared case of an ``Enum(_:description:deprecated:_:)``. The name is the wire
/// value (string-valued enums, fixed decision).
public struct EnumCaseDeclaration: Sendable, Hashable {
    let name: String
    let description: String?
    let deprecation: String?
}

/// Declares one enum case: `Case("high", description: "wakes the pager")`.
/// `deprecated:` says why the case is deprecated.
public func Case(
    _ name: String,
    description: String? = nil,
    deprecated deprecation: String? = nil
) -> EnumCaseDeclaration {
    precondition(!name.isEmpty, "enum case names cannot be empty")
    return EnumCaseDeclaration(name: name, description: description, deprecation: deprecation)
}

@resultBuilder
public enum EnumCasesBuilder: MMListBuilding {
    public typealias Element = EnumCaseDeclaration

    public static func buildExpression(_ enumCase: EnumCaseDeclaration) -> [EnumCaseDeclaration] {
        [enumCase]
    }
}

/// Declares a named string-valued enum:
///
/// ```swift
/// Enum("Priority", description: "How urgent a line is") {
///     Case("low")
///     Case("high", description: "Wakes the pager")
/// }
/// ```
///
/// The wire value is the case name; renaming a case is a wire break,
/// reordering is not (though it changes the fingerprint, like field order).
/// Decoders map unrecognized values to their local `unknown` case, which
/// keeps the value so it encodes back unchanged.
public func Enum(
    _ name: String,
    description: String? = nil,
    deprecated deprecation: String? = nil,
    @EnumCasesBuilder _ cases: () -> [EnumCaseDeclaration]
) -> TypeDeclaration {
    let caseList = cases()
    precondition(!caseList.isEmpty, "Enum(\"\(name)\") declares no cases")
    if let duplicate = firstDuplicate(caseList.map(\.name)) {
        preconditionFailure("Enum(\"\(name)\") declares case \"\(duplicate)\" twice")
    }
    return TypeDeclaration(
        name: validTypeName(name),
        description: description,
        deprecation: deprecation,
        payload: .enumeration(caseList)
    )
}

/// One declared case of a ``Union(_:description:deprecated:_:)``: its name (the wire
/// tag) and its own fields, keyed from 0 independently of the other cases.
public struct UnionCaseDeclaration: Sendable, Hashable {
    let name: String
    let description: String?
    let deprecation: String?
    let fields: [Field]
}

/// Declares a union case carrying fields:
/// `Case("seq") { Field("seq", .uint) }`. A field-less case is a plain
/// `Case("live")`.
public func Case(
    _ name: String,
    description: String? = nil,
    deprecated deprecation: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> UnionCaseDeclaration {
    precondition(!name.isEmpty, "union case names cannot be empty")
    return UnionCaseDeclaration(
        name: name,
        description: description,
        deprecation: deprecation,
        fields: fields()
    )
}

@resultBuilder
public enum UnionCasesBuilder: MMListBuilding {
    public typealias Element = UnionCaseDeclaration

    public static func buildExpression(
        _ unionCase: UnionCaseDeclaration
    ) -> [UnionCaseDeclaration] {
        [unionCase]
    }

    /// A field-less case, written as a plain enum case.
    public static func buildExpression(
        _ enumCase: EnumCaseDeclaration
    ) -> [UnionCaseDeclaration] {
        [
            UnionCaseDeclaration(
                name: enumCase.name,
                description: enumCase.description,
                deprecation: enumCase.deprecation,
                fields: []
            )
        ]
    }
}

/// Declares a named tagged union — exactly one of its cases, each with its
/// own fields:
///
/// ```swift
/// Union("Cursor", description: "Where a subscription starts") {
///     Case("beginning")
///     Case("seq") { Field("seq", .uint) }
///     Case("live")
/// }
/// ```
///
/// On the wire a value is `{0: "<case>", 1: {<the case's fields>}}`, key 1
/// left out for a field-less case. Renaming a case is a wire break,
/// reordering is not (though it changes the fingerprint, like field order).
/// Decoders map unrecognized case names to their local `unknown` case,
/// which keeps the name and the fields' bytes so it encodes back unchanged.
public func Union(
    _ name: String,
    description: String? = nil,
    deprecated deprecation: String? = nil,
    @UnionCasesBuilder _ cases: () -> [UnionCaseDeclaration]
) -> TypeDeclaration {
    let caseList = cases()
    precondition(!caseList.isEmpty, "Union(\"\(name)\") declares no cases")
    if let duplicate = firstDuplicate(caseList.map(\.name)) {
        preconditionFailure("Union(\"\(name)\") declares case \"\(duplicate)\" twice")
    }
    return TypeDeclaration(
        name: validTypeName(name),
        description: description,
        deprecation: deprecation,
        payload: .union(caseList)
    )
}

/// Declares a named structure type, referenceable from fields by name:
///
/// ```swift
/// Type("LineMeta", description: "Metadata attached to every line") {
///     Field("author", .string, description: "uid of the writer")
///     Field("priority", "Priority")
/// }
/// ```
///
/// A named type can also stand as a whole request, response, or stream-element
/// payload via `Request(.reference("Name"))` and friends — with no shape
/// requirement: the call's target entity is envelope metadata, never a payload
/// field, and the type remains an ordinary named type everywhere else. For a
/// referenced part `#schema` generates no struct; the descriptor's payload
/// generic is the named Swift type itself:
///
/// ```swift
/// Type("SetPayload") {
///     Field("line", .string)
/// }
/// Call("set") {
///     Access { .write }
///     Request(.reference("SetPayload"))
/// }
/// ```
public func Type(
    _ name: String,
    description: String? = nil,
    deprecated deprecation: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> TypeDeclaration {
    TypeDeclaration(
        name: validTypeName(name),
        description: description,
        deprecation: deprecation,
        payload: .structure(fields())
    )
}

/// Declares a named scalar: a scalar kind under its own name, with the
/// constraints every value of it keeps:
///
/// ```swift
/// Alias("Slug", .string, constraints: .length(1...64), .pattern("[a-z0-9-]+"))
/// Alias("Percent", .double, constraints: .range(0...100))
/// ```
///
/// Fields refer to it by name (`Field("slug", "Slug")`), and it travels as a
/// ``TypeSchema/reference(_:)`` whose ``TypeDefinition`` holds the scalar
/// kind and the constraints. `#schema` generates a wrapper struct for it
/// that encodes as the bare scalar. The kind is `bool`, `int`, `uint`,
/// `float`, `double`, `string`, `bytes`, `date`, `datetime` or
/// `timestamp`.
public func Alias(
    _ name: String,
    _ type: TypeSchema,
    constraints rules: Constraint...,
    description: String? = nil,
    deprecated deprecation: String? = nil
) -> TypeDeclaration {
    precondition(
        type.isScalarKind,
        "Alias(\"\(name)\") names \(type.kindName): an Alias names a scalar kind"
    )
    return TypeDeclaration(
        name: validTypeName(name),
        description: description,
        deprecation: deprecation,
        payload: .alias(type, combinedConstraints(rules, for: type, context: "Alias(\"\(name)\")"))
    )
}

func validTypeName(_ name: String) -> String {
    precondition(
        !name.isEmpty && !name.contains("."),
        "type names are unqualified within their block (\"\(name)\") — the namespace qualifies them"
    )
    return name
}

/// The literal behind a field's `default:` — written directly as a string,
/// integer, float, or boolean literal matching the field's wire type, or
/// ``now`` on a calendar/clock field.
public struct FieldDefault: Sendable, Hashable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    enum Kind: Sendable, Hashable {
        case string(String)
        case integer(Int64)
        case floating(Double)
        case boolean(Bool)
        case now
    }

    let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    /// The moment of use, for `.date`/`.datetime`/`.timestamp` fields (the
    /// only default they take): a generated CLI evaluates it per invocation
    /// — `MMTimestamp.now()` (offset zero), `MMDateTime.now()`, or
    /// `MMDate.today()` by field kind.
    public static let now = FieldDefault(kind: .now)

    public init(stringLiteral value: String) { self.kind = .string(value) }
    public init(integerLiteral value: Int64) { self.kind = .integer(value) }
    public init(floatLiteral value: Double) { self.kind = .floating(value) }
    public init(booleanLiteral value: Bool) { self.kind = .boolean(value) }
}

/// One declared field of a request, response, or nested structure. Unpinned
/// fields take their integer key from declaration order; pinned fields keep
/// the pin (see ``SchemaDeclaration`` — Keys). Every form takes an optional
/// trailing `description:` — served by discovery, never part of the
/// fingerprint or of compatibility comparisons — and `deprecated:`, why the
/// field is deprecated, served and kept out of comparisons the same way.
///
/// A `default:` on a field that is not optional is a wire default:
/// `Field("limit", .int, default: 50)` travels as an optional whose
/// ``TypeSchema/Field/defaultValue`` is 50, and the code `#schema`
/// generates holds a plain `Int` that reads 50 when the key is absent, so a
/// peer may leave it out and a field added later reads its default from a
/// peer that never wrote it. The default is a value of the field's kind
/// that keeps its constraints: a boolean, an integer, a floating number or
/// a string, or for a named type declared in the same block a case name
/// (an enum) or a value of its scalar (an alias).
///
/// An optional field's `default:` is declaration-level metadata like the
/// description: never on the wire (an absent field still decodes as nil),
/// but generators apply it. `#schema`'s CLI generation turns it into a
/// hybrid option automatically (ArgumentParser's `defaultAsFlag`): bare
/// `--format` means the default, `--format yaml` parses the value, absent
/// stays nil.
public struct Field: Sendable, Hashable {
    let pinnedKey: Int?
    let name: String
    /// The wire shape: the declared type, made optional when the field has
    /// a wire default.
    let type: TypeSchema
    let description: String?
    /// Why the field is deprecated; nil when it is not.
    let deprecation: String?
    /// The declared default; see the type-level note.
    let defaultValue: FieldDefault?
    /// The value an absent key reads as, for a field that is not optional
    /// with a `default:`. A named type's default is checked against the
    /// declaration when the enclosing block assembles.
    let wireDefault: TypeSchema.Default?
    /// CLI presentation hint, consumed by `#schema`'s CLI generation; never
    /// part of the wire contract (dropped when the declaration's shapes are
    /// assembled).
    let cli: CLIArgument?
    /// The rules the value keeps beyond its shape; see
    /// ``TypeSchema/Constraints``.
    let constraints: TypeSchema.Constraints?
    /// Set when this entry is a ``Reserved(_:)`` among the fields rather
    /// than a field; the other properties are then empty.
    let reservation: FieldReservation?

    /// An auto-keyed field of any wire shape: `Field("line", .string)`,
    /// `Field("note", .optional(.string))`, `Field("tags", .array(.string))`.
    /// `constraints:` lists the rules its value keeps:
    /// `Field("limit", .int, constraints: .range(1...1000))`.
    public init(
        _ name: String,
        _ type: TypeSchema,
        constraints rules: Constraint...,
        description: String? = nil,
        deprecated deprecation: String? = nil,
        default defaultValue: FieldDefault? = nil,
        cli: CLIArgument? = nil
    ) {
        self.init(
            pinnedKey: nil,
            name: name,
            type: type,
            constraints: combinedConstraints(rules, for: type, context: "Field(\"\(name)\")"),
            description: description,
            deprecated: deprecation,
            default: defaultValue,
            cli: cli
        )
    }

    /// A key-pinned field — the evolution-safe form.
    public init(
        _ key: Int,
        _ name: String,
        _ type: TypeSchema,
        constraints rules: Constraint...,
        description: String? = nil,
        deprecated deprecation: String? = nil,
        default defaultValue: FieldDefault? = nil,
        cli: CLIArgument? = nil
    ) {
        precondition(key >= 0, "field keys are non-negative integers (\(name) pinned \(key))")
        self.init(
            pinnedKey: key,
            name: name,
            type: type,
            constraints: combinedConstraints(rules, for: type, context: "Field(\"\(name)\")"),
            description: description,
            deprecated: deprecation,
            default: defaultValue,
            cli: cli
        )
    }

    private init(
        pinnedKey: Int?,
        name: String,
        type: TypeSchema,
        constraints: TypeSchema.Constraints?,
        description: String?,
        deprecated deprecation: String?,
        default defaultValue: FieldDefault?,
        cli: CLIArgument?
    ) {
        self.pinnedKey = pinnedKey
        self.name = name
        self.description = description
        self.deprecation = deprecation
        self.defaultValue = defaultValue
        self.cli = cli
        self.constraints = constraints
        self.reservation = nil
        if case .optional = type {
            self.type = type
            self.wireDefault = nil
        } else if let defaultValue {
            self.type = .optional(type)
            self.wireDefault = Self.wireDefault(
                defaultValue,
                for: type,
                constraints: constraints,
                field: name
            )
        } else {
            self.type = type
            self.wireDefault = nil
        }
    }

    /// The entry a ``Reserved(_:)`` adds to a fields block.
    init(reservation: FieldReservation) {
        self.pinnedKey = nil
        self.name = ""
        self.type = .unknown
        self.description = nil
        self.deprecation = nil
        self.defaultValue = nil
        self.wireDefault = nil
        self.cli = nil
        self.constraints = nil
        self.reservation = reservation
    }

    /// A non-optional field's `default:` as its wire default. A reference to
    /// a type of the same block keeps the literal for the block to check; a
    /// reference to another block's type cannot be checked, so it takes no
    /// default.
    private static func wireDefault(
        _ literal: FieldDefault,
        for type: TypeSchema,
        constraints: TypeSchema.Constraints?,
        field: String
    ) -> TypeSchema.Default {
        let value: TypeSchema.Default
        switch literal.kind {
            case .boolean(let boolean): value = .bool(boolean)
            case .integer(let integer): value = .integer(integer)
            case .floating(let floating): value = .floating(floating)
            case .string(let string): value = .string(string)
            case .now:
                preconditionFailure(
                    "Field(\"\(field)\"): .now is a CLI default, read when the command runs; a field that is not optional takes a fixed default"
                )
        }
        if case .reference(let typeName) = type {
            precondition(
                !typeName.contains("."),
                "Field(\"\(field)\"): \"\(typeName)\" is declared in another block, which this one cannot check a default against — a cross-schema reference takes no default"
            )
            return value
        }
        switch value.fitted(to: type, constraints: constraints) {
            case .success(let fitted):
                return fitted
            case .failure(let refusal):
                preconditionFailure("Field(\"\(field)\"): \(refusal)")
        }
    }

    /// An auto-keyed field referencing a named type by name:
    /// `Field("priority", "Priority")` for a type declared in the same block
    /// (qualified by the enclosing `Schema`/`Types`), or
    /// `Field("meta", "common.LineMeta")` for a dotted, already-qualified
    /// cross-schema reference (validated at server startup).
    public init(
        _ name: String,
        _ typeName: String,
        description: String? = nil,
        deprecated deprecation: String? = nil,
        default defaultValue: FieldDefault? = nil,
        cli: CLIArgument? = nil
    ) {
        self.init(
            name,
            .reference(typeName),
            description: description,
            deprecated: deprecation,
            default: defaultValue,
            cli: cli
        )
    }

    /// A key-pinned named-type reference.
    public init(
        _ key: Int,
        _ name: String,
        _ typeName: String,
        description: String? = nil,
        deprecated deprecation: String? = nil,
        default defaultValue: FieldDefault? = nil,
        cli: CLIArgument? = nil
    ) {
        self.init(
            key,
            name,
            .reference(typeName),
            description: description,
            deprecated: deprecation,
            default: defaultValue,
            cli: cli
        )
    }

    /// A field referencing a named type through its generated Swift type —
    /// the cross-schema form (`Field("tags", CommonTypes.TagSet.self)`): the
    /// type's described schema (a qualified `.reference`) lands in the wire
    /// contract, and `#schema` emits the Swift type as the property type.
    public init(
        _ name: String,
        _ type: (some SchemaDescribable).Type,
        description: String? = nil,
        deprecated deprecation: String? = nil,
        default defaultValue: FieldDefault? = nil,
        cli: CLIArgument? = nil
    ) {
        self.init(
            name,
            type.schema,
            description: description,
            deprecated: deprecation,
            default: defaultValue,
            cli: cli
        )
    }

    /// A key-pinned Swift-type reference.
    public init(
        _ key: Int,
        _ name: String,
        _ type: (some SchemaDescribable).Type,
        description: String? = nil,
        deprecated deprecation: String? = nil,
        default defaultValue: FieldDefault? = nil,
        cli: CLIArgument? = nil
    ) {
        self.init(
            key,
            name,
            type.schema,
            description: description,
            deprecated: deprecation,
            default: defaultValue,
            cli: cli
        )
    }

    /// An auto-keyed nested structure: `Field("owner") { Field("uid", .uint) }`.
    public init(
        _ name: String,
        description: String? = nil,
        deprecated deprecation: String? = nil,
        cli: CLIArgument? = nil,
        @SchemaFieldsBuilder _ fields: () -> [Field]
    ) {
        self.init(
            name,
            Fields(fields),
            description: description,
            deprecated: deprecation,
            default: nil,
            cli: cli
        )
    }

    /// A key-pinned nested structure.
    public init(
        _ key: Int,
        _ name: String,
        description: String? = nil,
        deprecated deprecation: String? = nil,
        cli: CLIArgument? = nil,
        @SchemaFieldsBuilder _ fields: () -> [Field]
    ) {
        self.init(
            key,
            name,
            Fields(fields),
            description: description,
            deprecated: deprecation,
            default: nil,
            cli: cli
        )
    }
}

/// Builds a standalone ``TypeSchema/structure(fields:)`` from `Field`
/// declarations — the composition point for arrays and maps of structures
/// (`.array(Fields { ... })`) and for hand-written ``SchemaDescribable``
/// conformances.
public func Fields(@SchemaFieldsBuilder _ content: () -> [Field]) -> TypeSchema {
    .structure(fields: assignKeys(content()))
}

/// Fields declared once and used in several fields blocks: a `Type`'s, a
/// union case's, a call part's, a nested structure's:
///
/// ```swift
/// Schema("journal") {
///     let audit = FieldGroup {
///         Field("author", .string)
///         Field("written", .timestamp)
///     }
///     Type("Line") {
///         Field("text", .string)
///         audit
///     }
///     Call("append") {
///         Access { .write }
///         Request {
///             Field("text", .string)
///             audit
///         }
///     }
/// }
/// ```
///
/// A group's fields take their places where it is used, as if written
/// there: an unpinned field takes the smallest key the block has not used,
/// a pinned one keeps its pin, and a `Reserved(...)` reserves for the whole
/// block. So a field added to a group moves the keys of the unpinned fields
/// after the group in every block that uses it, as adding the field there by
/// hand would: a block whose keys have to stay uses its groups after its own
/// fields, or pins its keys. The wire, discovery and the fingerprint see
/// only the fields, never the group.
///
/// `#schema` and `#schemaTypes` expand a group declared with `let` at the
/// top of their block; the runtime DSL takes one declared anywhere.
public struct FieldGroup: Sendable, Hashable {
    let fields: [Field]

    public init(@SchemaFieldsBuilder _ fields: () -> [Field]) {
        self.fields = fields()
    }
}

@resultBuilder
public enum SchemaFieldsBuilder: MMListBuilding {
    public typealias Element = Field

    public static func buildExpression(_ field: Field) -> [Field] { [field] }
    public static func buildExpression(_ fields: [Field]) -> [Field] { fields }
    /// A ``FieldGroup``'s fields, in its place.
    public static func buildExpression(_ group: FieldGroup) -> [Field] { group.fields }
    public static func buildExpression(_ reservation: FieldReservation) -> [Field] {
        [Field(reservation: reservation)]
    }
}

/// One element inside a ``Call(_:description:deprecated:_:)`` block: `Access`,
/// `Request`, `RequestStream`, `Response`, `ResponseStream`, `Errors` or the
/// presentation-only `CLI`.
public struct MethodPart: Sendable {
    enum Kind {
        case access(AccessMode)
        case request(TypeSchema, description: String?)
        case requestStream(TypeSchema, description: String?)
        case response(TypeSchema, description: String?)
        case responseStream(TypeSchema, description: String?)
        case errors([ErrorCaseDeclaration])
        case cli(CLIOverlay)
    }

    let kind: Kind
}

/// Per-stream open options. Empty in v1 — a reserved slot so future knobs
/// (initial credit, byte windows, priorities) are non-breaking additions to
/// `RequestStream` / `ResponseStream` declarations.
public struct StreamOptions: Sendable, Hashable {
    public init() {}
}

/// The access class this verb requires on its target entity. Required, exactly
/// once per method — authorization policy is never defaulted silently.
public func Access(_ mode: AccessMode) -> MethodPart {
    MethodPart(kind: .access(mode))
}

/// Block form, matching the declaration style: `Access { .write }`.
public func Access(_ mode: () -> AccessMode) -> MethodPart {
    MethodPart(kind: .access(mode()))
}

/// The request payload's declared fields, keyed from 0 like every other part
/// (the call's target entity is envelope metadata, not payload). Optional —
/// omit the block for an empty request. Every part form takes an optional
/// `description:`, served by discovery.
public func Request(
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> MethodPart {
    MethodPart(kind: .request(Fields(fields), description: description))
}

/// A request that IS a named type (or any bare wire shape):
/// `Request(.reference("LineMeta"))` — fully symmetric with
/// `Response(_:description:)`.
public func Request(_ payload: TypeSchema, description: String? = nil) -> MethodPart {
    MethodPart(kind: .request(payload, description: description))
}

/// Cross-schema form: `Request(Other.LineMeta.self)`.
public func Request(
    _ type: (some SchemaDescribable).Type,
    description: String? = nil
) -> MethodPart {
    MethodPart(kind: .request(type.schema, description: description))
}

/// The response payload's declared fields. Optional — omit the block for an
/// empty (acknowledgement-only) response.
public func Response(
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> MethodPart {
    MethodPart(kind: .response(Fields(fields), description: description))
}

/// A response that IS a named type (or any bare wire shape):
/// `Response(.reference("LineMeta"))`. The reference qualifies against the
/// enclosing block like any field reference.
public func Response(_ payload: TypeSchema, description: String? = nil) -> MethodPart {
    MethodPart(kind: .response(payload, description: description))
}

/// A response that is another container's Swift type — the cross-schema form
/// (`Response(CommonTypes.Stamp.self)`).
public func Response(
    _ type: (some SchemaDescribable).Type,
    description: String? = nil
) -> MethodPart {
    MethodPart(kind: .response(type.schema, description: description))
}

/// Type-name hint forms: the leading string names the Swift type `#schema`
/// generates for this part. At runtime the name carries no meaning — the
/// declaration describes wire shapes, not Swift types — so these overloads
/// simply forward.
public func Request(
    _ typeName: String,
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> MethodPart {
    MethodPart(kind: .request(Fields(fields), description: description))
}

public func Response(
    _ typeName: String,
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> MethodPart {
    MethodPart(kind: .response(Fields(fields), description: description))
}

public func RequestStream(
    _ typeName: String,
    _ options: StreamOptions = StreamOptions(),
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> MethodPart {
    MethodPart(kind: .requestStream(Fields(fields), description: description))
}

public func ResponseStream(
    _ typeName: String,
    _ options: StreamOptions = StreamOptions(),
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> MethodPart {
    MethodPart(kind: .responseStream(Fields(fields), description: description))
}

/// The element shape the client may stream after opening the call, as a
/// structure of declared fields. Stream elements are values riding an
/// already-authorized call, not requests — no entity field is injected and no
/// key is reserved; declared fields are keyed from 0 exactly like Response
/// fields. At most one per method, freely combined with the other parts.
public func RequestStream(
    _ options: StreamOptions = StreamOptions(),
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> MethodPart {
    MethodPart(kind: .requestStream(Fields(fields), description: description))
}

/// A request stream whose element is a bare wire shape:
/// `RequestStream(payload: .bytes)`.
public func RequestStream(
    _ options: StreamOptions = StreamOptions(),
    payload: TypeSchema,
    description: String? = nil
) -> MethodPart {
    MethodPart(kind: .requestStream(payload, description: description))
}

/// A request stream whose elements ARE a named type:
/// `RequestStream(.reference("ImportLine"))`.
public func RequestStream(_ payload: TypeSchema, description: String? = nil) -> MethodPart {
    MethodPart(kind: .requestStream(payload, description: description))
}

/// Cross-schema form: `RequestStream(CommonTypes.Stamp.self)`.
public func RequestStream(
    _ type: (some SchemaDescribable).Type,
    description: String? = nil
) -> MethodPart {
    MethodPart(kind: .requestStream(type.schema, description: description))
}

/// The element shape the server may stream before its terminal response, as a
/// structure of declared fields. Same rules as ``RequestStream(_:description:_:)``:
/// no entity injection, no reserved key, at most one per method.
public func ResponseStream(
    _ options: StreamOptions = StreamOptions(),
    description: String? = nil,
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> MethodPart {
    MethodPart(kind: .responseStream(Fields(fields), description: description))
}

/// A response stream whose element is a bare wire shape:
/// `ResponseStream(payload: .uint)`.
public func ResponseStream(
    _ options: StreamOptions = StreamOptions(),
    payload: TypeSchema,
    description: String? = nil
) -> MethodPart {
    MethodPart(kind: .responseStream(payload, description: description))
}

/// A response stream whose elements ARE a named type:
/// `ResponseStream(.reference("ChangeEvent"))`.
public func ResponseStream(_ payload: TypeSchema, description: String? = nil) -> MethodPart {
    MethodPart(kind: .responseStream(payload, description: description))
}

/// Cross-schema form: `ResponseStream(CommonTypes.Stamp.self)`.
public func ResponseStream(
    _ type: (some SchemaDescribable).Type,
    description: String? = nil
) -> MethodPart {
    MethodPart(kind: .responseStream(type.schema, description: description))
}

@resultBuilder
public enum MethodDeclarationBuilder: MMListBuilding {
    public typealias Element = MethodPart

    public static func buildExpression(_ part: MethodPart) -> [MethodPart] { [part] }

    /// The call's own `Errors { ... }`.
    public static func buildExpression(_ errors: ErrorsDeclaration) -> [MethodPart] {
        [MethodPart(kind: .errors(errors.cases))]
    }
}

/// Declares one method of a ``Schema(_:_:)`` contract by its local name; the
/// namespace prefix is applied by the enclosing schema (`"append"` becomes
/// `"journal.append"`).
///
/// Named `Call`, not `Method`, because `Method<Request, Response>` is the typed
/// descriptor type — a free function and a type cannot share a name in one
/// module. The declaration and the descriptor describe the same method at
/// different layers: the descriptor gives the compiler-checked call surface,
/// this declaration gives the data-only contract.
public func Call(
    _ name: String,
    description: String? = nil,
    deprecated deprecation: String? = nil,
    @MethodDeclarationBuilder _ parts: () -> [MethodPart]
) -> MethodDeclaration {
    var access: AccessMode?
    var request: (payload: TypeSchema, description: String?)?
    var requestStream: (element: TypeSchema, description: String?)?
    var response: (payload: TypeSchema, description: String?)?
    var responseStream: (element: TypeSchema, description: String?)?
    var errors: [ErrorCaseDeclaration]?
    var cli: CLIOverlay?
    // The one duplicate-part rule, stated once: each part kind may appear at
    // most once per Call.
    func setOnce<Value>(_ slot: inout Value?, _ value: Value, _ part: String) {
        precondition(slot == nil, "Call(\"\(name)\"): \(part) declared twice")
        slot = value
    }
    for part in parts() {
        switch part.kind {
            case .access(let mode):
                setOnce(&access, mode, "Access")
            case .request(let payload, let partDescription):
                setOnce(&request, (payload, partDescription), "Request")
            case .requestStream(let element, let partDescription):
                setOnce(&requestStream, (element, partDescription), "RequestStream")
            case .response(let payload, let partDescription):
                setOnce(&response, (payload, partDescription), "Response")
            case .responseStream(let element, let partDescription):
                setOnce(&responseStream, (element, partDescription), "ResponseStream")
            case .errors(let cases):
                setOnce(&errors, cases, "Errors")
            case .cli(let overlay):
                setOnce(&cli, overlay, "CLI")
        }
    }
    guard let access else {
        preconditionFailure(
            "Call(\"\(name)\") declares no Access — authorization policy is never defaulted"
        )
    }
    return MethodDeclaration(
        name: name,
        access: access,
        request: request?.payload ?? .structure(fields: []),
        response: response?.payload ?? .structure(fields: []),
        requestStream: requestStream?.element,
        responseStream: responseStream?.element,
        description: description,
        requestDescription: request?.description,
        responseDescription: response?.description,
        requestStreamDescription: requestStream?.description,
        responseStreamDescription: responseStream?.description,
        deprecation: deprecation,
        cli: cli,
        errors: errors ?? []
    )
}

/// One entry of a ``Schema(_:_:)`` block: a ``Call(_:description:deprecated:_:)`` method,
/// an ``Enum(_:description:deprecated:_:)`` / ``Union(_:description:deprecated:_:)`` /
/// ``Type(_:description:deprecated:_:)`` named type, a named
/// ``Error(_:exitCode:description:_:)``, or the namespace's ``Errors(_:)``.
public struct SchemaEntry: Sendable {
    enum Kind {
        case method(MethodDeclaration)
        case type(TypeDeclaration)
        case namedError(NamedErrorDeclaration)
        /// The namespace's errors: every call in the block can return them.
        case errors([ErrorCaseDeclaration])
        /// The schema-level CLI mode — presentation-only; the runtime
        /// declaration ignores it (the `#schema` macro is its one consumer).
        case cli(SchemaCLIMode)
    }

    let kind: Kind
}

@resultBuilder
public enum SchemaDeclarationBuilder: MMListBuilding {
    public typealias Element = SchemaEntry

    public static func buildExpression(_ method: MethodDeclaration) -> [SchemaEntry] {
        [SchemaEntry(kind: .method(method))]
    }
    public static func buildExpression(_ type: TypeDeclaration) -> [SchemaEntry] {
        [SchemaEntry(kind: .type(type))]
    }
    public static func buildExpression(_ error: NamedErrorDeclaration) -> [SchemaEntry] {
        [SchemaEntry(kind: .namedError(error))]
    }
    public static func buildExpression(_ errors: ErrorsDeclaration) -> [SchemaEntry] {
        [SchemaEntry(kind: .errors(errors.cases))]
    }
    public static func buildExpression(_ entry: SchemaEntry) -> [SchemaEntry] {
        [entry]
    }
}

/// Declares a namespace contract: `Schema("journal") { Call("append") { ... } }`.
/// See ``SchemaDeclaration`` for the full story.
///
/// ## Named types and references
///
/// `Enum`/`Type` entries declare named types; the block qualifies their names
/// with its namespace (`Priority` → `journal.Priority`). Field references by
/// **undotted** name must resolve to a type declared in the same block
/// (programmer error otherwise) and are rewritten to the qualified form.
/// **Dotted** references (`common.LineMeta`) are cross-schema: they pass
/// through untouched and are validated at server startup, when every
/// registered namespace's table is known.
public func Schema(
    _ namespace: String,
    description: String? = nil,
    @SchemaDeclarationBuilder _ content: () -> [SchemaEntry]
) -> SchemaDeclaration {
    guard case .success(let prefix) = EntityName.parse(namespace), !prefix.isRoot else {
        preconditionFailure(
            "Schema namespace \"\(namespace)\" is not a valid non-root entity path — discovery filters methods by their prefix entity"
        )
    }
    let entries = content()
    let methods = entries.compactMap { entry -> MethodDeclaration? in
        if case .method(let method) = entry.kind { method } else { nil }
    }
    let typeDeclarations = entries.compactMap { entry -> TypeDeclaration? in
        if case .type(let type) = entry.kind { type } else { nil }
    }
    let types = assembleTypes(typeDeclarations, namespace: prefix.rawValue)
    let localTypes = localTypeTable(typeDeclarations)
    let errorScope = errorResolutionScope(
        entries: entries,
        typeDeclarations: typeDeclarations,
        namespace: prefix.rawValue
    )
    let namespaceErrorBlocks = entries.compactMap { entry -> [ErrorCaseDeclaration]? in
        if case .errors(let cases) = entry.kind { cases } else { nil }
    }
    precondition(
        namespaceErrorBlocks.count <= 1,
        "Schema \"\(prefix.rawValue)\" declares Errors twice — one block lists the namespace's errors"
    )
    let namespaceErrors = errorScope.resolve(
        namespaceErrorBlocks.first ?? [],
        context: "Schema \"\(prefix.rawValue)\" Errors"
    )
    // `Call("@")` is the namespace root call: the method IS the namespace
    // (`search`, not `search.@`). At most one per schema — a second folds to
    // the same wire name and trips the duplicate check below.
    func wireName(_ callName: String) -> String {
        callName == "@" ? prefix.rawValue : "\(prefix.rawValue).\(callName)"
    }
    if let duplicate = firstDuplicate(methods.map { wireName($0.name) }) {
        preconditionFailure("Schema declares \"\(duplicate)\" twice")
    }
    let signatures = methods.map { method in
        MethodSignature(
            name: wireName(method.name),
            access: method.access,
            request: qualifyReferences(
                in: method.request,
                namespace: prefix.rawValue,
                localTypes: localTypes
            ),
            response: qualifyReferences(
                in: method.response,
                namespace: prefix.rawValue,
                localTypes: localTypes
            ),
            requestStream: method.requestStream.map {
                qualifyReferences(in: $0, namespace: prefix.rawValue, localTypes: localTypes)
            },
            responseStream: method.responseStream.map {
                qualifyReferences(in: $0, namespace: prefix.rawValue, localTypes: localTypes)
            },
            errors: flattenedErrors(
                namespace: namespaceErrors,
                own: errorScope.resolve(method.errors, context: "Call(\"\(method.name)\") Errors"),
                call: method.name
            ),
            description: method.description,
            requestDescription: method.requestDescription,
            responseDescription: method.responseDescription,
            requestStreamDescription: method.requestStreamDescription,
            responseStreamDescription: method.responseStreamDescription,
            deprecation: method.deprecation
        )
    }
    return SchemaDeclaration(
        namespace: prefix.rawValue,
        description: description,
        signatures: signatures,
        types: types
    )
}

/// The block's named errors and structure types, which its `Errors` cases
/// resolve against. A named error may not share a name with a type.
private func errorResolutionScope(
    entries: [SchemaEntry],
    typeDeclarations: [TypeDeclaration],
    namespace: String
) -> ErrorResolutionScope {
    let namedErrors = entries.compactMap { entry -> NamedErrorDeclaration? in
        if case .namedError(let error) = entry.kind { error } else { nil }
    }
    let typeNames = typeDeclarations.map(\.name)
    if let duplicate = firstDuplicate(namedErrors.map(\.name) + typeNames) {
        preconditionFailure(
            "\"\(namespace)\" declares \"\(duplicate)\" twice (as an Error or a type)"
        )
    }
    let structures = Dictionary(
        uniqueKeysWithValues: typeDeclarations.compactMap { declaration -> (String, [Field])? in
            if case .structure(let fields) = declaration.payload {
                (declaration.name, fields)
            } else {
                nil
            }
        }
    )
    return ErrorResolutionScope(
        namespace: namespace,
        namedErrors: Dictionary(uniqueKeysWithValues: namedErrors.map { ($0.name, $0) }),
        structures: structures,
        localTypes: localTypeTable(typeDeclarations)
    )
}

/// A named collection of shared types belonging to no method namespace:
///
/// ```swift
/// let common = Types("common") {
///     Enum("Priority") { Case("low"); Case("high") }
///     Type("LineMeta") { Field("author", .string) }
/// }
/// ```
///
/// The runtime counterpart of `#schemaTypes` — hand-written ``TypeNamespace``
/// conformers return `common.types`.
public func Types(
    _ namespace: String,
    @SchemaTypesBuilder _ content: () -> [TypeDeclaration]
) -> TypeNamespaceDeclaration {
    guard case .success(let prefix) = EntityName.parse(namespace), !prefix.isRoot else {
        preconditionFailure(
            "Types namespace \"\(namespace)\" is not a valid non-root dotted name"
        )
    }
    return TypeNamespaceDeclaration(
        namespace: prefix.rawValue,
        types: assembleTypes(content(), namespace: prefix.rawValue)
    )
}

/// The value a ``Types(_:_:)`` block produces: qualified ``TypeDefinition``
/// values ready to serve from a ``TypeNamespace``.
public struct TypeNamespaceDeclaration: Sendable, Hashable {
    public let namespace: String
    public let types: [TypeDefinition]

    public init(namespace: String, types: [TypeDefinition]) {
        self.namespace = namespace
        self.types = types
    }

    /// Checks the declared types against a ``TypeNamespace``'s definitions
    /// and decoder-behavior probes — the types-only counterpart of
    /// ``SchemaDeclaration/verify(against:)-(MethodNamespace.Type)``, and the
    /// `#schemaTypes` fidelity check. Returns human-readable mismatch lines;
    /// empty means the container honors the declaration.
    public func verify(against namespace: any TypeNamespace.Type) -> [String] {
        verifyTypeTable(
            declared: self.types,
            defined: namespace.types,
            probes: namespace.probedTypes
        )
    }
}

extension SchemaDeclaration {
    /// This declaration's own types plus every shared definition its
    /// signatures reference, transitively — the local twin of discovery's
    /// reachability filter (a scoped discovery response lists exactly the
    /// types reachable through the scope's methods). Use as the local side
    /// of a `SchemaDifference` when the server also registers shared
    /// `Types(...)` containers, so shared definitions neither surface as
    /// server-only nor flag as missing when unreferenced.
    public func types(sharing shared: [TypeNamespaceDeclaration]) -> [TypeDefinition] {
        guard !shared.isEmpty else { return self.types }
        var referenced = Set<String>()
        for signature in self.signatures {
            signature.collectReferencedTypeNames(into: &referenced)
        }
        // Transitive closure over both tables: a referenced shared type may
        // itself reference further shared types.
        let definitionsByName = Dictionary(
            (self.types + shared.flatMap(\.types)).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var frontier = referenced
        while !frontier.isEmpty {
            var next = Set<String>()
            for name in frontier {
                definitionsByName[name]?.schema.collectReferencedTypeNames(into: &next)
            }
            frontier = next.subtracting(referenced)
            referenced.formUnion(next)
        }
        let ownNames = Set(self.types.map(\.name))
        let reachableShared = shared.flatMap(\.types).filter { definition in
            referenced.contains(definition.name) && !ownNames.contains(definition.name)
        }
        return self.types + reachableShared
    }
}

@resultBuilder
public enum SchemaTypesBuilder: MMListBuilding {
    public typealias Element = TypeDeclaration

    public static func buildExpression(_ type: TypeDeclaration) -> [TypeDeclaration] {
        [type]
    }
}

/// Qualifies and resolves a block's type declarations: names become
/// `namespace.Name`, duplicate names are programmer error, and references
/// inside the definitions themselves resolve against the same block.
private func assembleTypes(
    _ declarations: [TypeDeclaration],
    namespace: String
) -> [TypeDefinition] {
    if let duplicate = firstDuplicate(declarations.map(\.name)) {
        preconditionFailure("\"\(namespace)\" declares type \"\(duplicate)\" twice")
    }
    let localTypes = localTypeTable(declarations)
    return declarations.map { declaration in
        let schema: TypeSchema
        switch declaration.payload {
            case .structure(let fields):
                schema = qualifyReferences(
                    in: .structure(fields: assignKeys(fields)),
                    namespace: namespace,
                    localTypes: localTypes
                )
            case .enumeration(let cases):
                schema = .enumeration(
                    cases: cases.map {
                        TypeSchema.EnumCase(
                            name: $0.name,
                            description: $0.description,
                            deprecation: $0.deprecation
                        )
                    }
                )
            case .union(let cases):
                schema = qualifyReferences(
                    in: .union(
                        cases: cases.map {
                            TypeSchema.UnionCase(
                                name: $0.name,
                                fields: assignKeys($0.fields),
                                description: $0.description,
                                deprecation: $0.deprecation
                            )
                        }
                    ),
                    namespace: namespace,
                    localTypes: localTypes
                )
            case .alias(let scalar, let constraints):
                return TypeDefinition(
                    name: "\(namespace).\(declaration.name)",
                    schema: scalar,
                    description: declaration.description,
                    constraints: constraints,
                    deprecation: declaration.deprecation
                )
        }
        return TypeDefinition(
            name: "\(namespace).\(declaration.name)",
            schema: schema,
            description: declaration.description,
            deprecation: declaration.deprecation
        )
    }
}

/// A block's type declarations by unqualified name: what its references
/// resolve to and its named-type defaults are checked against.
func localTypeTable(_ declarations: [TypeDeclaration]) -> [String: TypeDeclaration.Payload] {
    Dictionary(
        declarations.map { ($0.name, $0.payload) },
        uniquingKeysWith: { first, _ in first }
    )
}

/// The first name that appears more than once, or nil — the shared
/// duplicate-name guard (enum cases, method names, type names, dynamic-value
/// object members).
package func firstDuplicate(_ names: some Sequence<String>) -> String? {
    var seen: Set<String> = []
    for name in names where !seen.insert(name).inserted {
        return name
    }
    return nil
}

/// Rewrites undotted references to their block-qualified form, validating
/// they resolve locally; dotted (cross-schema) references pass through. A
/// field's default on a local named type is checked against its declaration
/// here: an enum's must name one of its cases, an alias's must be a value of
/// its scalar that keeps its constraints.
func qualifyReferences(
    in schema: TypeSchema,
    namespace: String,
    localTypes: [String: TypeDeclaration.Payload]
) -> TypeSchema {
    // One rewrite rule on the shared structure-preserving walk: unqualified
    // local references gain the namespace; dotted references pass through.
    schema.rewritten(
        node: { rebuilt in
            guard case .reference(let name) = rebuilt, !name.contains(".") else {
                return rebuilt
            }
            precondition(
                localTypes[name] != nil,
                "reference to \"\(name)\" does not resolve to an Enum/Type declared in \"\(namespace)\" — qualify cross-schema references (\"other.\(name)\")"
            )
            return .reference("\(namespace).\(name)")
        },
        field: { field in
            // A field's own type is rewritten first, so a local reference
            // already carries the namespace. Only a field that is not
            // optional takes a default on a reference, and only a local one.
            guard let defaultValue = field.defaultValue,
                case .optional(.reference(let qualified)) = field.type,
                qualified.hasPrefix("\(namespace).")
            else { return field }
            let name = String(qualified.dropFirst(namespace.count + 1))
            guard let payload = localTypes[name] else { return field }
            var checked = field
            checked.defaultValue = namedTypeDefault(
                defaultValue,
                of: payload,
                field: field.name,
                typeName: name
            )
            return checked
        }
    )
}

/// A default on a field of a local named type, fitted to the type: the
/// literal as written becomes a case name for an enum, or a value of the
/// scalar for an alias, checked against the alias's constraints.
private func namedTypeDefault(
    _ literal: TypeSchema.Default,
    of payload: TypeDeclaration.Payload,
    field: String,
    typeName: String
) -> TypeSchema.Default {
    let kind: TypeSchema
    let constraints: TypeSchema.Constraints?
    switch payload {
        case .enumeration(let cases):
            kind = .enumeration(cases: cases.map { TypeSchema.EnumCase(name: $0.name) })
            constraints = nil
        case .alias(let scalar, let aliasConstraints):
            kind = scalar
            constraints = aliasConstraints
        case .structure:
            kind = .structure(fields: [])
            constraints = nil
        case .union:
            kind = .union(cases: [])
            constraints = nil
    }
    switch literal.fitted(to: kind, constraints: constraints) {
        case .success(let fitted):
            return fitted
        case .failure(let refusal):
            preconditionFailure("Field(\"\(field)\") of \(typeName): \(refusal)")
    }
}

/// Assigns keys to a fields block's fields (see ``fieldKeys(for:reservedKeys:reservedNames:)``)
/// and drops its ``Reserved(_:)`` entries; a conflict is programmer error.
func assignKeys(_ entries: [Field]) -> [TypeSchema.Field] {
    let reservations = entries.compactMap(\.reservation)
    let fields = entries.filter { $0.reservation == nil }
    let keys = fieldKeys(
        for: fields.map { ($0.pinnedKey, $0.name) },
        reservedKeys: Set(reservations.flatMap(\.keys)),
        reservedNames: Set(reservations.flatMap(\.names))
    )
    switch keys {
        case .failure(let conflict):
            preconditionFailure("\(conflict)")
        case .success(let keys):
            return zip(fields, keys).map { field, key in
                TypeSchema.Field(
                    key: key,
                    name: field.name,
                    type: field.type,
                    description: field.description,
                    constraints: field.constraints,
                    defaultValue: field.wireDefault,
                    deprecation: field.deprecation
                )
            }
    }
}
