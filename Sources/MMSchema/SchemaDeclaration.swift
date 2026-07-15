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
    /// The declared method signatures, full wire names (`journal.append`),
    /// in declaration order.
    public let signatures: [MethodSignature]
    /// The named types the block declares (``Enum(_:description:_:)`` /
    /// ``Type(_:description:_:)``), qualified names included, in declaration
    /// order.
    public let types: [TypeDefinition]

    public init(namespace: String, signatures: [MethodSignature], types: [TypeDefinition] = []) {
        self.namespace = namespace
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
                    declared: self.types, defined: namespace.types, probes: namespace.probedTypes)
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
        var implemented: [String: (probed: MethodSignature, described: MethodSignature)] = [:]
        for method in methods {
            switch method.probedSignature() {
                case .failure(let error):
                    return .failure(error)
                case .success(let probed):
                    switch method.signature() {
                        case .failure(let error):
                            return .failure(error)
                        case .success(let described):
                            implemented[probed.name] = (
                                probed: probed.strippingDescriptions,
                                described: described.strippingDescriptions
                            )
                    }
            }
        }
        let definitions = Dictionary(
            self.types.map { ($0.name, $0.strippingDescriptions.schema) },
            uniquingKeysWith: { first, _ in first }
        )
        var mismatches: [String] = []
        for declaredSignature in self.signatures {
            let declared = declaredSignature.strippingDescriptions
            guard let actual = implemented.removeValue(forKey: declared.name) else {
                mismatches.append("\(declared.name): declared but not implemented")
                continue
            }
            if actual.probed.access != declared.access {
                mismatches.append(
                    "\(declared.name): access is \(actual.probed.access.rawValue), contract says \(declared.access.rawValue)"
                )
            }
            mismatches.append(
                contentsOf: slotMismatches(
                    name: declared.name, slot: "request",
                    declared: declared.request,
                    probed: actual.probed.request, described: actual.described.request,
                    definitions: definitions))
            mismatches.append(
                contentsOf: slotMismatches(
                    name: declared.name, slot: "response",
                    declared: declared.response,
                    probed: actual.probed.response, described: actual.described.response,
                    definitions: definitions))
            mismatches.append(
                contentsOf: streamMismatches(
                    name: declared.name,
                    slot: "request stream",
                    declared: declared.requestStream,
                    probed: actual.probed.requestStream,
                    described: actual.described.requestStream,
                    definitions: definitions
                )
            )
            mismatches.append(
                contentsOf: streamMismatches(
                    name: declared.name,
                    slot: "response stream",
                    declared: declared.responseStream,
                    probed: actual.probed.responseStream,
                    described: actual.described.responseStream,
                    definitions: definitions
                )
            )
        }
        for extra in implemented.keys.sorted() {
            mismatches.append("\(extra): implemented but not in the contract")
        }
        return .success(mismatches)
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
        if behavior == declared { return true }
        guard case .reference(let name) = declared else { return false }
        guard let definition = definitions[name] else { return true }
        if case .enumeration = definition { return behavior == .string }
        return behavior == definition
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
        declared: TypeSchema,
        probed: TypeSchema,
        described: TypeSchema,
        definitions: [String: TypeSchema]
    ) -> [String] {
        let behavior = probed == .unknown ? described : probed
        if !behaviorMatches(declared: declared, behavior: behavior, definitions: definitions) {
            return ["\(name): \(slot) shape diverges from the contract"]
        }
        if described != declared {
            return ["\(name): \(slot) described schema diverges from the contract"]
        }
        return []
    }

    /// Compares one stream slot of a declared and an implemented signature:
    /// presence must agree in both directions, and present elements must match.
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
                // .unknown probe → described carries the check (see slotMismatches).
                let behavior =
                    probedElement == .unknown ? (described ?? probedElement) : probedElement
                if !behaviorMatches(
                    declared: declaredElement, behavior: behavior, definitions: definitions)
                {
                    return ["\(name): \(slot) element shape diverges from the contract"]
                }
                if let describedElement = described, describedElement != declaredElement {
                    return ["\(name): \(slot) element described schema diverges from the contract"]
                }
                return []
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
    var definedByName: [String: TypeDefinition] = [:]
    for definition in defined {
        definedByName[definition.name] = definition
    }
    var mismatches: [String] = []
    for declaredDefinition in declaredTypes {
        let declared = declaredDefinition.strippingDescriptions
        guard let actual = definedByName.removeValue(forKey: declared.name) else {
            mismatches.append("\(declared.name): type declared but not defined by the namespace")
            continue
        }
        if actual.strippingDescriptions.schema != declared.schema {
            mismatches.append("\(declared.name): type definition diverges from the contract")
        }
        switch probes[declared.name] {
            case nil:
                break
            case .failure:
                mismatches.append("\(declared.name): type probe failed")
            case .success(let probed):
                let expected: TypeSchema
                if case .enumeration = declared.schema {
                    expected = .string
                } else {
                    expected = declared.schema
                }
                // .unknown = unknowable behavior (empty structs); the
                // definition-vs-contract check above still holds.
                if probed != .unknown, probed.strippingDescriptions != expected {
                    mismatches.append(
                        "\(declared.name): decoder behavior diverges from the type definition")
                }
        }
    }
    for extra in definedByName.keys.sorted() {
        mismatches.append("\(extra): type defined by the namespace but not in the contract")
    }
    return mismatches
}

/// One declared method, before the namespace prefix is applied. Produced by
/// ``Call(_:description:_:)`` inside a ``Schema(_:_:)`` block.
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
}

/// One declared named type, produced by ``Enum(_:description:_:)`` or
/// ``Type(_:description:_:)`` inside a ``Schema(_:_:)`` or ``Types(_:_:)``
/// block. The enclosing block qualifies the name with its namespace.
public struct TypeDeclaration: Sendable, Hashable {
    enum Payload: Sendable, Hashable {
        case structure([Field])
        case enumeration([EnumCaseDeclaration])
    }

    let name: String
    let description: String?
    let payload: Payload
}

/// One declared case of an ``Enum(_:description:_:)``. The name is the wire
/// value (string-valued enums, fixed decision).
public struct EnumCaseDeclaration: Sendable, Hashable {
    let name: String
    let description: String?
}

/// Declares one enum case: `Case("high", description: "wakes the pager")`.
public func Case(_ name: String, description: String? = nil) -> EnumCaseDeclaration {
    precondition(!name.isEmpty, "enum case names cannot be empty")
    return EnumCaseDeclaration(name: name, description: description)
}

@resultBuilder
public enum EnumCasesBuilder {
    public static func buildExpression(_ enumCase: EnumCaseDeclaration) -> [EnumCaseDeclaration] {
        [enumCase]
    }
    public static func buildBlock(_ components: [EnumCaseDeclaration]...) -> [EnumCaseDeclaration] {
        components.flatMap { $0 }
    }
    public static func buildOptional(_ component: [EnumCaseDeclaration]?) -> [EnumCaseDeclaration] {
        component ?? []
    }
    public static func buildEither(first component: [EnumCaseDeclaration]) -> [EnumCaseDeclaration]
    {
        component
    }
    public static func buildEither(second component: [EnumCaseDeclaration]) -> [EnumCaseDeclaration]
    {
        component
    }
    public static func buildArray(_ components: [[EnumCaseDeclaration]]) -> [EnumCaseDeclaration] {
        components.flatMap { $0 }
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
/// Decoders map unrecognized values to their local `unknown` case.
public func Enum(
    _ name: String,
    description: String? = nil,
    @EnumCasesBuilder _ cases: () -> [EnumCaseDeclaration]
) -> TypeDeclaration {
    let caseList = cases()
    precondition(!caseList.isEmpty, "Enum(\"\(name)\") declares no cases")
    var seen: Set<String> = []
    for enumCase in caseList {
        precondition(
            seen.insert(enumCase.name).inserted,
            "Enum(\"\(name)\") declares case \"\(enumCase.name)\" twice")
    }
    return TypeDeclaration(
        name: validTypeName(name), description: description, payload: .enumeration(caseList))
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
    @SchemaFieldsBuilder _ fields: () -> [Field]
) -> TypeDeclaration {
    TypeDeclaration(
        name: validTypeName(name), description: description, payload: .structure(fields()))
}

private func validTypeName(_ name: String) -> String {
    precondition(
        !name.isEmpty && !name.contains("."),
        "type names are unqualified within their block (\"\(name)\") — the namespace qualifies them"
    )
    return name
}

/// One declared field of a request, response, or nested structure. Unpinned
/// fields take their integer key from declaration order; pinned fields keep
/// the pin (see ``SchemaDeclaration`` — Keys). Every form takes an optional
/// trailing `description:` — served by discovery, never part of the
/// fingerprint or of compatibility comparisons.
public struct Field: Sendable, Hashable {
    let pinnedKey: Int?
    let name: String
    let type: TypeSchema
    let description: String?

    /// An auto-keyed field of any wire shape: `Field("line", .string)`,
    /// `Field("note", .optional(.string))`, `Field("tags", .array(.string))`.
    public init(_ name: String, _ type: TypeSchema, description: String? = nil) {
        self.pinnedKey = nil
        self.name = name
        self.type = type
        self.description = description
    }

    /// A key-pinned field — the evolution-safe form.
    public init(_ key: Int, _ name: String, _ type: TypeSchema, description: String? = nil) {
        precondition(key >= 0, "field keys are non-negative integers (\(name) pinned \(key))")
        self.pinnedKey = key
        self.name = name
        self.type = type
        self.description = description
    }

    /// An auto-keyed field referencing a named type by name:
    /// `Field("priority", "Priority")` for a type declared in the same block
    /// (qualified by the enclosing `Schema`/`Types`), or
    /// `Field("meta", "common.LineMeta")` for a dotted, already-qualified
    /// cross-schema reference (validated at server startup).
    public init(_ name: String, _ typeName: String, description: String? = nil) {
        self.init(name, .reference(typeName), description: description)
    }

    /// A key-pinned named-type reference.
    public init(_ key: Int, _ name: String, _ typeName: String, description: String? = nil) {
        self.init(key, name, .reference(typeName), description: description)
    }

    /// A field referencing a named type through its generated Swift type —
    /// the cross-schema form (`Field("tags", CommonTypes.TagSet.self)`): the
    /// type's described schema (a qualified `.reference`) lands in the wire
    /// contract, and `#schema` emits the Swift type as the property type.
    public init(
        _ name: String, _ type: (some SchemaDescribable).Type, description: String? = nil
    ) {
        self.init(name, type.schema, description: description)
    }

    /// A key-pinned Swift-type reference.
    public init(
        _ key: Int, _ name: String, _ type: (some SchemaDescribable).Type,
        description: String? = nil
    ) {
        self.init(key, name, type.schema, description: description)
    }

    /// An auto-keyed nested structure: `Field("owner") { Field("uid", .uint) }`.
    public init(
        _ name: String, description: String? = nil, @SchemaFieldsBuilder _ fields: () -> [Field]
    ) {
        self.init(name, Fields(fields), description: description)
    }

    /// A key-pinned nested structure.
    public init(
        _ key: Int, _ name: String, description: String? = nil,
        @SchemaFieldsBuilder _ fields: () -> [Field]
    ) {
        self.init(key, name, Fields(fields), description: description)
    }
}

/// Builds a standalone ``TypeSchema/structure(fields:)`` from `Field`
/// declarations — the composition point for arrays and maps of structures
/// (`.array(Fields { ... })`) and for hand-written ``SchemaDescribable``
/// conformances.
public func Fields(@SchemaFieldsBuilder _ content: () -> [Field]) -> TypeSchema {
    .structure(fields: assignKeys(content()))
}

@resultBuilder
public enum SchemaFieldsBuilder {
    public static func buildExpression(_ field: Field) -> [Field] { [field] }
    public static func buildExpression(_ fields: [Field]) -> [Field] { fields }
    public static func buildBlock(_ components: [Field]...) -> [Field] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [Field]?) -> [Field] { component ?? [] }
    public static func buildEither(first component: [Field]) -> [Field] { component }
    public static func buildEither(second component: [Field]) -> [Field] { component }
    public static func buildArray(_ components: [[Field]]) -> [Field] { components.flatMap { $0 } }
}

/// One element inside a ``Call(_:description:_:)`` block: `Access`,
/// `Request`, `RequestStream`, `Response` or
/// `ResponseStream`.
public struct MethodPart: Sendable {
    enum Kind {
        case access(AccessMode)
        case request(TypeSchema, description: String?)
        case requestStream(TypeSchema, description: String?)
        case response(TypeSchema, description: String?)
        case responseStream(TypeSchema, description: String?)
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
    description: String? = nil, @SchemaFieldsBuilder _ fields: () -> [Field]
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
    _ type: (some SchemaDescribable).Type, description: String? = nil
) -> MethodPart {
    MethodPart(kind: .request(type.schema, description: description))
}

/// The response payload's declared fields. Optional — omit the block for an
/// empty (acknowledgement-only) response.
public func Response(
    description: String? = nil, @SchemaFieldsBuilder _ fields: () -> [Field]
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
    _ type: (some SchemaDescribable).Type, description: String? = nil
) -> MethodPart {
    MethodPart(kind: .response(type.schema, description: description))
}

/// Type-name hint forms: the leading string names the Swift type `#schema`
/// generates for this part. At runtime the name carries no meaning — the
/// declaration describes wire shapes, not Swift types — so these overloads
/// simply forward.
public func Request(
    _ typeName: String, description: String? = nil, @SchemaFieldsBuilder _ fields: () -> [Field]
) -> MethodPart {
    MethodPart(kind: .request(Fields(fields), description: description))
}

public func Response(
    _ typeName: String, description: String? = nil, @SchemaFieldsBuilder _ fields: () -> [Field]
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
    _ type: (some SchemaDescribable).Type, description: String? = nil
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
    _ type: (some SchemaDescribable).Type, description: String? = nil
) -> MethodPart {
    MethodPart(kind: .responseStream(type.schema, description: description))
}

@resultBuilder
public enum MethodDeclarationBuilder {
    public static func buildExpression(_ part: MethodPart) -> [MethodPart] { [part] }
    public static func buildBlock(_ components: [MethodPart]...) -> [MethodPart] {
        components.flatMap { $0 }
    }
    public static func buildOptional(_ component: [MethodPart]?) -> [MethodPart] { component ?? [] }
    public static func buildEither(first component: [MethodPart]) -> [MethodPart] { component }
    public static func buildEither(second component: [MethodPart]) -> [MethodPart] { component }
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
    @MethodDeclarationBuilder _ parts: () -> [MethodPart]
) -> MethodDeclaration {
    var access: AccessMode?
    var request: (payload: TypeSchema, description: String?)?
    var requestStream: (element: TypeSchema, description: String?)?
    var response: (payload: TypeSchema, description: String?)?
    var responseStream: (element: TypeSchema, description: String?)?
    for part in parts() {
        switch part.kind {
            case .access(let mode):
                precondition(access == nil, "Call(\"\(name)\"): Access declared twice")
                access = mode
            case .request(let payload, let partDescription):
                precondition(request == nil, "Call(\"\(name)\"): Request declared twice")
                request = (payload, partDescription)
            case .requestStream(let element, let partDescription):
                precondition(
                    requestStream == nil, "Call(\"\(name)\"): RequestStream declared twice")
                requestStream = (element, partDescription)
            case .response(let payload, let partDescription):
                precondition(response == nil, "Call(\"\(name)\"): Response declared twice")
                response = (payload, partDescription)
            case .responseStream(let element, let partDescription):
                precondition(
                    responseStream == nil, "Call(\"\(name)\"): ResponseStream declared twice")
                responseStream = (element, partDescription)
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
        responseStreamDescription: responseStream?.description
    )
}

/// One entry of a ``Schema(_:_:)`` block: a ``Call(_:description:_:)`` method
/// or an ``Enum(_:description:_:)`` / ``Type(_:description:_:)`` named type.
public struct SchemaEntry: Sendable {
    enum Kind {
        case method(MethodDeclaration)
        case type(TypeDeclaration)
    }

    let kind: Kind
}

@resultBuilder
public enum SchemaDeclarationBuilder {
    public static func buildExpression(_ method: MethodDeclaration) -> [SchemaEntry] {
        [SchemaEntry(kind: .method(method))]
    }
    public static func buildExpression(_ type: TypeDeclaration) -> [SchemaEntry] {
        [SchemaEntry(kind: .type(type))]
    }
    public static func buildBlock(_ components: [SchemaEntry]...) -> [SchemaEntry] {
        components.flatMap { $0 }
    }
    public static func buildOptional(_ component: [SchemaEntry]?) -> [SchemaEntry] {
        component ?? []
    }
    public static func buildEither(first component: [SchemaEntry]) -> [SchemaEntry] {
        component
    }
    public static func buildEither(second component: [SchemaEntry]) -> [SchemaEntry] {
        component
    }
    public static func buildArray(_ components: [[SchemaEntry]]) -> [SchemaEntry] {
        components.flatMap { $0 }
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
    @SchemaDeclarationBuilder _ content: () -> [SchemaEntry]
) -> SchemaDeclaration {
    guard case .success(let prefix) = EntityName.parse(namespace), !prefix.isRoot else {
        preconditionFailure(
            "Schema namespace \"\(namespace)\" is not a valid non-root entity path — discovery filters methods by their prefix entity"
        )
    }
    var methods: [MethodDeclaration] = []
    var typeDeclarations: [TypeDeclaration] = []
    for entry in content() {
        switch entry.kind {
            case .method(let method): methods.append(method)
            case .type(let type): typeDeclarations.append(type)
        }
    }
    let types = assembleTypes(typeDeclarations, namespace: prefix.rawValue)
    let localNames = Set(typeDeclarations.map(\.name))
    var seen: Set<String> = []
    var signatures: [MethodSignature] = []
    for method in methods {
        let full = "\(prefix.rawValue).\(method.name)"
        precondition(seen.insert(full).inserted, "Schema declares \"\(full)\" twice")
        signatures.append(
            MethodSignature(
                name: full,
                access: method.access,
                request: qualifyReferences(
                    in: method.request, namespace: prefix.rawValue, localTypes: localNames),
                response: qualifyReferences(
                    in: method.response, namespace: prefix.rawValue, localTypes: localNames),
                requestStream: method.requestStream.map {
                    qualifyReferences(in: $0, namespace: prefix.rawValue, localTypes: localNames)
                },
                responseStream: method.responseStream.map {
                    qualifyReferences(in: $0, namespace: prefix.rawValue, localTypes: localNames)
                },
                description: method.description,
                requestDescription: method.requestDescription,
                responseDescription: method.responseDescription,
                requestStreamDescription: method.requestStreamDescription,
                responseStreamDescription: method.responseStreamDescription
            )
        )
    }
    return SchemaDeclaration(
        namespace: prefix.rawValue,
        signatures: signatures,
        types: types
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
            declared: self.types, defined: namespace.types, probes: namespace.probedTypes)
    }
}

@resultBuilder
public enum SchemaTypesBuilder {
    public static func buildExpression(_ type: TypeDeclaration) -> [TypeDeclaration] {
        [type]
    }
    public static func buildBlock(_ components: [TypeDeclaration]...) -> [TypeDeclaration] {
        components.flatMap { $0 }
    }
    public static func buildOptional(_ component: [TypeDeclaration]?) -> [TypeDeclaration] {
        component ?? []
    }
    public static func buildEither(first component: [TypeDeclaration]) -> [TypeDeclaration] {
        component
    }
    public static func buildEither(second component: [TypeDeclaration]) -> [TypeDeclaration] {
        component
    }
    public static func buildArray(_ components: [[TypeDeclaration]]) -> [TypeDeclaration] {
        components.flatMap { $0 }
    }
}

/// Qualifies and resolves a block's type declarations: names become
/// `namespace.Name`, duplicate names are programmer error, and references
/// inside the definitions themselves resolve against the same block.
private func assembleTypes(
    _ declarations: [TypeDeclaration],
    namespace: String
) -> [TypeDefinition] {
    var seen: Set<String> = []
    for declaration in declarations {
        precondition(
            seen.insert(declaration.name).inserted,
            "\"\(namespace)\" declares type \"\(declaration.name)\" twice")
    }
    let localNames = Set(declarations.map(\.name))
    return declarations.map { declaration in
        let schema: TypeSchema
        switch declaration.payload {
            case .structure(let fields):
                schema = qualifyReferences(
                    in: .structure(fields: assignKeys(fields)),
                    namespace: namespace,
                    localTypes: localNames
                )
            case .enumeration(let cases):
                schema = .enumeration(
                    cases: cases.map {
                        TypeSchema.EnumCase(name: $0.name, description: $0.description)
                    })
        }
        return TypeDefinition(
            name: "\(namespace).\(declaration.name)",
            schema: schema,
            description: declaration.description
        )
    }
}

/// Rewrites undotted references to their block-qualified form, validating
/// they resolve locally; dotted (cross-schema) references pass through.
private func qualifyReferences(
    in schema: TypeSchema,
    namespace: String,
    localTypes: Set<String>
) -> TypeSchema {
    switch schema {
        case .bool, .int, .uint, .float, .double, .string, .bytes, .unknown, .enumeration:
            return schema
        case .reference(let name):
            if name.contains(".") {
                return schema
            }
            precondition(
                localTypes.contains(name),
                "reference to \"\(name)\" does not resolve to an Enum/Type declared in \"\(namespace)\" — qualify cross-schema references (\"other.\(name)\")"
            )
            return .reference("\(namespace).\(name)")
        case .optional(let wrapped):
            return .optional(
                qualifyReferences(in: wrapped, namespace: namespace, localTypes: localTypes))
        case .array(let element):
            return .array(
                qualifyReferences(in: element, namespace: namespace, localTypes: localTypes))
        case .map(let key, let value):
            return .map(
                key: qualifyReferences(in: key, namespace: namespace, localTypes: localTypes),
                value: qualifyReferences(in: value, namespace: namespace, localTypes: localTypes)
            )
        case .structure(let fields):
            return .structure(
                fields: fields.map { field in
                    TypeSchema.Field(
                        key: field.key,
                        name: field.name,
                        type: qualifyReferences(
                            in: field.type, namespace: namespace, localTypes: localTypes),
                        description: field.description
                    )
                }
            )
    }
}

/// Assigns declaration-order keys to unpinned fields, skipping pinned and
/// reserved values; duplicate pins are programmer error.
private func assignKeys(
    _ fields: [Field],
    startingAt first: Int = 0,
    reserving reserved: Set<Int> = []
) -> [TypeSchema.Field] {
    var used = reserved
    for field in fields {
        if let pin = field.pinnedKey {
            precondition(used.insert(pin).inserted, "duplicate field key \(pin) (\(field.name))")
        }
    }
    var next = first
    return fields.map { field in
        let key: Int
        if let pin = field.pinnedKey {
            key = pin
        } else {
            while used.contains(next) { next += 1 }
            key = next
            used.insert(next)
        }
        return TypeSchema.Field(
            key: key, name: field.name, type: field.type, description: field.description)
    }
}
