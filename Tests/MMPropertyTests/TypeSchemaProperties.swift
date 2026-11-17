// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMWire
    import NIOCore
    import Testing

    @Suite("TypeSchema properties", .hegel, .offTheCooperativePool)
    struct TypeSchemaProperties {
        /// Any schema encodes as `TypeSchema`'s documentation lays out its
        /// wire form: a map with the case tag from the documented table at
        /// key 0, the first payload at key 1 and the second at key 2, and
        /// fields and cases as maps keyed by their `CodingKeys`.
        ///
        /// Mutation check: a map's key and value written to each other's
        /// keys, datetime given the date tag, a field's description moved to
        /// key 4, a union case's fields and description keys swapped, or a
        /// field's default and deprecation keys swapped, fails here at 100
        /// cases. The last four keep the round trip below whole, since
        /// encoder and decoder agree on them.
        @Test
        func schemasEncodeAsDocumented() throws {
            try property(
                reaching: ["a reference", "an array"],
                reachingAfter: [
                    "a case name beyond ASCII": 1_000, "a documented case": 1_000,
                    "a documented field": 1_000, "a field key at an end of Int": 1_000,
                    "a field name beyond ASCII": 1_000, "a field with no key": 1_000,
                    "a map": 1_000, "a negative field key": 1_000, "a node three deep": 1_000,
                    "a reference name beyond ASCII": 1_000, "a scalar, tag 0": 1_000,
                    "a scalar, tag 1": 1_000, "a scalar, tag 13": 1_000, "a scalar, tag 14": 1_000,
                    "a scalar, tag 15": 1_000, "a scalar, tag 17": 1_000, "a scalar, tag 18": 1_000,
                    "a scalar, tag 2": 1_000, "a scalar, tag 3": 1_000,
                    "a scalar, tag 4": 1_000, "a scalar, tag 5": 1_000, "a scalar, tag 6": 1_000,
                    "a structure": 1_000, "a union": 1_000, "a union case without fields": 1_000,
                    "an empty case name": 1_000, "an empty enumeration": 1_000,
                    "an empty field name": 1_000, "an empty reference name": 1_000,
                    "an empty structure": 1_000, "an empty union": 1_000, "an enumeration": 1_000,
                    "an optional": 1_000, "unknown": 1_000, "a boolean default": 1_000,
                    "an integer default": 1_000, "a floating default": 1_000,
                    "a whole floating default": 1_000, "a string default": 1_000,
                    "a deprecated field": 1_000, "a deprecated case": 1_000,
                ]
            ) { tc in
                let schema = try #draw(FingerprintGenerators.schemas, from: tc)
                for label in kindLabels(of: schema).sorted() {
                    try tc.event(label)
                }
                #expect(
                    try packedBytes(schema) == packedBytes(DocumentedSchema(schema)),
                    "\(schema) does not encode as documented"
                )
            }
        }

        /// Any schema, and any named type definition, decodes from its
        /// MessagePack form back to itself, every name, description and
        /// deprecation byte for byte, and every field default as the kind it
        /// was: a whole floating default stays floating, never an integer.
        ///
        /// Mutation check: date decoded as datetime, a map's key and value
        /// swapped, or a union no longer decoded, fails here at 100 cases.
        @Test
        func schemasDecodeToThemselves() throws {
            try property(
                reaching: ["a documented case", "a reference"],
                reachingAfter: [
                    "a case name beyond ASCII": 1_000, "a documented field": 1_000,
                    "a field key at an end of Int": 1_000, "a field name beyond ASCII": 1_000,
                    "a field with no key": 1_000, "a map": 1_000, "a negative field key": 1_000,
                    "a node three deep": 1_000, "a reference name beyond ASCII": 1_000,
                    "a scalar, tag 0": 1_000, "a scalar, tag 1": 1_000, "a scalar, tag 13": 1_000,
                    "a scalar, tag 14": 1_000, "a scalar, tag 15": 1_000, "a scalar, tag 17": 1_000,
                    "a scalar, tag 18": 1_000, "a scalar, tag 2": 1_000,
                    "a scalar, tag 3": 1_000, "a scalar, tag 4": 1_000, "a scalar, tag 5": 1_000,
                    "a scalar, tag 6": 1_000, "a structure": 1_000, "a union": 1_000,
                    "a union case without fields": 1_000, "an array": 1_000,
                    "an empty case name": 1_000, "an empty enumeration": 1_000,
                    "an empty field name": 1_000, "an empty reference name": 1_000,
                    "an empty structure": 1_000, "an empty union": 1_000, "an enumeration": 1_000,
                    "an optional": 1_000, "unknown": 1_000, "a boolean default": 1_000,
                    "an integer default": 1_000, "a floating default": 1_000,
                    "a whole floating default": 1_000, "a string default": 1_000,
                    "a deprecated field": 1_000, "a deprecated case": 1_000,
                    "a deprecated definition": 1_000,
                ]
            ) { tc in
                let definition = try #draw(FingerprintGenerators.definitions, from: tc)
                if definition.deprecation != nil { try tc.event("a deprecated definition") }
                for label in kindLabels(of: definition.schema).sorted() {
                    try tc.event(label)
                }
                let schemaBytes = try packedBytes(definition.schema)
                let schema = try MMPackDecoder()
                    .decode(TypeSchema.self, from: ByteBuffer(bytes: schemaBytes)).get()
                #expect(
                    try packedBytes(schema) == schemaBytes,
                    "\(definition.schema) decoded as \(schema)"
                )
                let definitionBytes = try packedBytes(definition)
                let decoded = try MMPackDecoder()
                    .decode(TypeDefinition.self, from: ByteBuffer(bytes: definitionBytes)).get()
                #expect(
                    try packedBytes(decoded) == definitionBytes,
                    "\(definition) decoded as \(decoded)"
                )
            }
        }

        /// A schema whose encoding has one node written wrong still decodes,
        /// to the schema with that node `.unknown`: a tag the table does not
        /// have, no tag, a tag that is not a byte, a payload left out or of
        /// the wrong kind, or no map at all. A key the layout does not use,
        /// or a second tag after the first, is skipped, and the node decodes
        /// as it was.
        ///
        /// Mutation check: a tag read as any integer and cut to a byte, or a
        /// reference with no name decoded as the empty name, fails here at
        /// 100 cases; an optional whose payload must be there, so that its
        /// absence throws, at 1,000.
        @Test
        func damagedNodesDecodeAsUnknown() throws {
            try property(
                reaching: ["a node below the root"],
                reachingAfter: [
                    "a key the layout does not use": 1_000, "a payload left out": 1_000,
                    "a payload of the wrong kind": 1_000, "a second tag": 1_000,
                    "a tag that is not a byte": 1_000, "a tag the table does not have": 1_000,
                    "no map": 1_000, "no tag": 1_000,
                ]
            ) { tc in
                let schema = try #draw(FingerprintGenerators.schemas, from: tc)
                let places = nodes(of: schema)
                let place = places[try #draw(Gen<Int>.int(in: 0..<places.count), from: tc)]
                let damage = try #draw(NodeDamage.damages(for: place.node), from: tc)
                try tc.event(damage.label)
                if !place.path.isEmpty { try tc.event("a node below the root") }
                let bytes = try packedBytes(DocumentedSchema(schema, damage: (place.path, damage)))
                let expected =
                    damage.leavesTheNode
                    ? schema : replacing(at: place.path, in: schema, with: .unknown)
                switch MMPackDecoder().decode(TypeSchema.self, from: ByteBuffer(bytes: bytes)) {
                    case .failure(let error):
                        Issue.record("\(schema) with \(damage) did not decode: \(error)")
                    case .success(let decoded):
                        #expect(
                            try packedBytes(decoded) == packedBytes(expected),
                            "\(schema) with \(damage) decoded as \(decoded), not \(expected)"
                        )
                }
            }
        }

        /// With no definitions, a fold that rebuilds each node gives back the
        /// schema, byte for byte, and reports every reference as unresolved;
        /// `collectReferencedTypeNames`, a fold over the same empty table,
        /// gathers exactly the names the schema references.
        ///
        /// Mutation check: a map's value folded from its key, a structure's
        /// last field left out of the fold, or `collectReferencedTypeNames`
        /// missing references in map keys or union fields, fails here at
        /// 100 cases.
        @Test
        func foldRebuildsTheOriginal() throws {
            try property(reaching: ["a reference", "no reference"]) { tc in
                let schema = try #draw(FingerprintGenerators.schemas, from: tc)
                let references = referenceNames(in: schema)
                try tc.event(references.isEmpty ? "no reference" : "a reference")
                var cuts: [TypeResolutionFailure: Int] = [:]
                let rebuilt: TypeSchema = schema.fold(resolver: TypeResolver([])) { step in
                    rebuilding(step, cuts: &cuts)
                }
                #expect(
                    try packedBytes(rebuilt) == packedBytes(schema),
                    "\(schema) folded back as \(rebuilt)"
                )
                #expect(
                    cuts == references.reduce(into: [:]) { $0[.unresolved($1), default: 0] += 1 },
                    "\(schema) reported \(cuts)"
                )
                var collected: Set<String> = []
                schema.collectReferencedTypeNames(into: &collected)
                #expect(collected == Set(references), "\(schema) collected \(collected)")
            }
        }

        /// With definitions, a fold that rebuilds each node gives back the
        /// schema with every reference that resolves replaced by its
        /// definition's schema, itself folded, the first definition of a
        /// name winning. A reference back into a definition being folded is
        /// left in place and reported as a cycle, and one with no definition
        /// is left in place and reported as unresolved.
        ///
        /// Mutation check: a cycle reported as unresolved, the later of two
        /// definitions with one name winning, a map's value folded from its
        /// key, or a structure's last field left out, fails here at 100
        /// cases.
        @Test
        func foldInlinesWhatResolves() throws {
            try property(
                reaching: ["a reference inlined"],
                reachingAfter: [
                    "a cycle cut": 1_000, "a definition that is a reference": 1_000,
                    "a reference inside an inlined one": 1_000, "an unresolved reference": 1_000,
                    "two definitions with one name": 1_000,
                ]
            ) { tc in
                var schema = try #draw(FingerprintGenerators.schemas, from: tc)
                var bodies = try #draw(
                    Gen<[TypeSchema]>.array(of: FingerprintGenerators.schemas, count: 0...4),
                    from: tc
                )
                // Half the cases take every name, referenced or defined,
                // from a pool of one to three, so references resolve, chain
                // and loop back. The rest name each definition after a
                // reference the schemas make or anything at all.
                let pooled = try #draw(Gen<Bool>.bool(), from: tc)
                let pool = Array(
                    ["a", "b", "c"].prefix(try #draw(Gen<Int>.int(in: 1...3), from: tc))
                )
                if pooled {
                    schema = try renamingReferences(in: schema, from: pool, tc)
                    bodies = try bodies.map { body in
                        let renamed = try renamingReferences(in: body, from: pool, tc)
                        // Half the bodies refer onward, so references chain.
                        guard try #draw(Gen<Bool>.bool(), from: tc) else { return renamed }
                        let places = nodes(of: renamed)
                        let place = places[try #draw(Gen<Int>.int(in: 0..<places.count), from: tc)]
                        let name = pool[try #draw(Gen<Int>.int(in: 0..<pool.count), from: tc)]
                        return replacing(at: place.path, in: renamed, with: .reference(name))
                    }
                    // Starting at a reference starts the fold inside a
                    // definition.
                    if try #draw(Gen<Bool>.bool(), from: tc) {
                        schema = .reference(
                            pool[try #draw(Gen<Int>.int(in: 0..<pool.count), from: tc)]
                        )
                    }
                }
                let referenced = pooled ? pool : ([schema] + bodies).flatMap(referenceNames)
                var definitions: [TypeDefinition] = []
                for body in bodies {
                    let named = try pooled || #draw(Gen<Bool>.bool(), from: tc)
                    let name =
                        named && !referenced.isEmpty
                        ? referenced[try #draw(Gen<Int>.int(in: 0..<referenced.count), from: tc)]
                        : try #draw(FingerprintGenerators.names, from: tc)
                    definitions.append(TypeDefinition(name: name, schema: body))
                }

                var inlining = Inlining(definitions: definitions)
                let expected = inlining.inlined(schema, inFlight: [])
                for label in inlining.labels.sorted() {
                    try tc.event(label)
                }
                var cuts: [TypeResolutionFailure: Int] = [:]
                let rebuilt: TypeSchema = schema.fold(resolver: TypeResolver(definitions)) { step in
                    rebuilding(step, cuts: &cuts)
                }
                #expect(
                    try packedBytes(rebuilt) == packedBytes(expected),
                    "\(schema) over \(definitions) folded as \(rebuilt), not \(expected)"
                )
                #expect(
                    cuts == inlining.cuts,
                    "\(schema) over \(definitions) reported \(cuts), not \(inlining.cuts)"
                )
            }
        }
    }

    /// The node a fold step stands for, rebuilt from its folded children,
    /// with each reference the fold could not follow put back and counted.
    func rebuilding(
        _ step: TypeSchema.FoldStep<TypeSchema>,
        cuts: inout [TypeResolutionFailure: Int]
    ) -> TypeSchema {
        func field(_ pair: (field: TypeSchema.Field, value: TypeSchema)) -> TypeSchema.Field {
            var field = pair.field
            field.type = pair.value
            return field
        }
        switch step {
            case .bool: return .bool
            case .int: return .int
            case .uint: return .uint
            case .float: return .float
            case .double: return .double
            case .string: return .string
            case .bytes: return .bytes
            case .date: return .date
            case .datetime: return .datetime
            case .timestamp: return .timestamp
            case .duration: return .duration
            case .uuid: return .uuid
            case .optional(let wrapped): return .optional(wrapped)
            case .array(let element): return .array(element)
            case .map(let key, let value): return .map(key: key, value: value)
            case .structure(let fields): return .structure(fields: fields.map(field))
            case .enumeration(let cases): return .enumeration(cases: cases)
            case .union(let cases):
                return .union(
                    cases: cases.map {
                        TypeSchema.UnionCase(
                            name: $0.unionCase.name,
                            fields: $0.fields.map(field),
                            description: $0.unionCase.description,
                            deprecation: $0.unionCase.deprecation
                        )
                    }
                )
            case .unresolvedReference(let failure):
                cuts[failure, default: 0] += 1
                switch failure {
                    case .unresolved(let name), .cycle(let name): return .reference(name)
                }
            case .unknown: return .unknown
        }
    }

    /// The schema with each reference renamed to a name drawn from `pool`.
    func renamingReferences(in schema: TypeSchema, from pool: [String], _ tc: TestCase) throws
        -> TypeSchema
    {
        var renamed = schema
        for place in nodes(of: schema) {
            guard case .reference = place.node else { continue }
            let name = pool[try tc.draw(Gen<Int>.int(in: 0..<pool.count))]
            renamed = replacing(at: place.path, in: renamed, with: .reference(name))
        }
        return renamed
    }

    /// Every name the schema references, in order, repeats included.
    func referenceNames(in schema: TypeSchema) -> [String] {
        nodes(of: schema).compactMap {
            if case .reference(let name) = $0.node { name } else { nil }
        }
    }

    /// The schema with its references inlined, written out directly: each
    /// reference whose name a definition has (the first one with it) is
    /// replaced by that definition's schema, inlined in turn with the name
    /// in flight; a reference to a name in flight, or to one with no
    /// definition, stays, and is counted.
    struct Inlining {
        let definitions: [TypeDefinition]
        var cuts: [TypeResolutionFailure: Int] = [:]
        var labels: Set<String> = []

        mutating func inlined(_ schema: TypeSchema, inFlight: Set<String>) -> TypeSchema {
            func fields(_ fields: [TypeSchema.Field]) -> [TypeSchema.Field] {
                fields.map {
                    var field = $0
                    field.type = inlined($0.type, inFlight: inFlight)
                    return field
                }
            }
            switch schema {
                case .optional(let wrapped):
                    return .optional(inlined(wrapped, inFlight: inFlight))
                case .array(let element):
                    return .array(inlined(element, inFlight: inFlight))
                case .map(let key, let value):
                    let keyInlined = inlined(key, inFlight: inFlight)
                    return .map(key: keyInlined, value: inlined(value, inFlight: inFlight))
                case .structure(let members):
                    return .structure(fields: fields(members))
                case .union(let cases):
                    return .union(
                        cases: cases.map {
                            TypeSchema.UnionCase(
                                name: $0.name,
                                fields: fields($0.fields),
                                description: $0.description,
                                deprecation: $0.deprecation
                            )
                        }
                    )
                case .reference(let name):
                    if inFlight.contains(name) {
                        labels.insert("a cycle cut")
                        cuts[.cycle(name), default: 0] += 1
                        return schema
                    }
                    let matching = definitions.filter { $0.name == name }
                    guard let definition = matching.first else {
                        labels.insert("an unresolved reference")
                        cuts[.unresolved(name), default: 0] += 1
                        return schema
                    }
                    labels.insert(
                        inFlight.isEmpty
                            ? "a reference inlined" : "a reference inside an inlined one"
                    )
                    if matching.count > 1 { labels.insert("two definitions with one name") }
                    if !definition.name.utf8.elementsEqual(name.utf8) {
                        labels.insert("a definition named by canonically equivalent text")
                    }
                    if case .reference = definition.schema {
                        labels.insert("a definition that is a reference")
                    }
                    return inlined(definition.schema, inFlight: inFlight.union([name]))
                default:
                    return schema
            }
        }
    }

    /// One way to write a schema node wrong.
    enum NodeDamage: Sendable, CustomStringConvertible {
        /// A tag the documented table does not have.
        case unlistedTag(UInt8)
        /// The tag key left out.
        case noTag
        /// The tag as a value that is not a `UInt8`.
        case tagNotAByte(Junk)
        /// A payload key left out: 1, or 2 for a map's value.
        case payloadLeftOut(Int)
        /// The first payload as a value of the wrong kind.
        case payloadOfTheWrongKind(Junk)
        /// A value that is not a map in the node's place.
        case notAMap(Junk)
        /// A key the layout does not use, holding any value.
        case unusedKey(Int, Junk)
        /// A second tag after the payload; the decoder keeps the first.
        case tagRepeated(UInt8)

        var description: String {
            switch self {
                case .unlistedTag(let tag): "tag \(tag)"
                case .noTag: "no tag"
                case .tagNotAByte(let junk): "tag \(junk)"
                case .payloadLeftOut(let key): "key \(key) left out"
                case .payloadOfTheWrongKind(let junk): "payload \(junk)"
                case .notAMap(let junk): "\(junk) in place of the map"
                case .unusedKey(let key, let junk): "key \(key) holding \(junk)"
                case .tagRepeated(let tag): "a second tag \(tag)"
            }
        }

        var label: String {
            switch self {
                case .unlistedTag: "a tag the table does not have"
                case .noTag: "no tag"
                case .tagNotAByte: "a tag that is not a byte"
                case .payloadLeftOut: "a payload left out"
                case .payloadOfTheWrongKind: "a payload of the wrong kind"
                case .notAMap: "no map"
                case .unusedKey: "a key the layout does not use"
                case .tagRepeated: "a second tag"
            }
        }

        /// Whether the node decodes as it was, the damage skipped.
        var leavesTheNode: Bool {
            switch self {
                case .unusedKey, .tagRepeated: true
                default: false
            }
        }

        /// Tags past the table's 0...18, short of its 255.
        static let unlistedTags: Gen<UInt8> = .oneOf(
            .element(of: [19, 128, 254]),
            .integer(in: 19...254)
        )

        /// Integers no `UInt8` holds.
        static let notBytes: Gen<Int64> = .oneOf(
            .element(of: [256, -1, .min, .max]),
            .integer(in: 256...Int64.max),
            .integer(in: Int64.min...(-1))
        )

        static let anyTag: Gen<UInt8> = .integer()

        /// The damages that apply to this node.
        static func damages(for node: TypeSchema) -> Gen<NodeDamage> {
            var choices: [Gen<NodeDamage>] = [
                unlistedTags.map { .unlistedTag($0) },
                .just(.noTag),
                Gen<Junk>.oneOf(
                    notBytes.map { .integer($0) },
                    Junk.texts,
                    Junk.booleans,
                    .just(.emptyArray),
                    .just(.null)
                ).map { .tagNotAByte($0) },
                Junk.values.map { .notAMap($0) },
                Hegel.zip(
                    Gen<Int>.oneOf(
                        .element(of: [3, 4, 127, 128, 65_535, -1, .max]),
                        .integer(in: 3...Int.max)
                    ),
                    Junk.values
                ).map { .unusedKey($0, $1) },
                anyTag.map { .tagRepeated($0) },
            ]
            switch node {
                case .optional, .array, .structure, .enumeration, .union, .reference:
                    choices.append(.just(.payloadLeftOut(1)))
                case .map:
                    choices.append(Gen<Int>.element(of: [1, 2]).map { .payloadLeftOut($0) })
                default:
                    break
            }
            switch node {
                case .structure, .enumeration, .union:
                    // A list payload: anything but a list.
                    choices.append(
                        Gen<Junk>.oneOf(Junk.integers, Junk.texts, Junk.booleans, .just(.null))
                            .map { .payloadOfTheWrongKind($0) }
                    )
                case .reference:
                    // A name: anything but text.
                    choices.append(
                        Gen<Junk>.oneOf(
                            Junk.integers,
                            Junk.booleans,
                            .just(.emptyArray),
                            .just(.null)
                        )
                        .map { .payloadOfTheWrongKind($0) }
                    )
                default:
                    break
            }
            return .oneOf(choices)
        }
    }

    /// A MessagePack value of one kind or another.
    enum Junk: Encodable, Sendable, CustomStringConvertible {
        case integer(Int64)
        case text(String)
        case boolean(Bool)
        case emptyArray
        case null

        static let integers: Gen<Junk> = Gen<Int64>.oneOf(
            .element(of: [0, 7, -1, .min, .max]),
            .integer()
        ).map { .integer($0) }
        static let texts: Gen<Junk> = Gen<String>.oneOf(.element(of: ["", "7", "tag"]), .string())
            .map { .text($0) }
        static let booleans: Gen<Junk> = Gen<Bool>.bool().map { .boolean($0) }
        static let values: Gen<Junk> = .oneOf(
            integers,
            texts,
            booleans,
            .just(.emptyArray),
            .just(.null)
        )

        var description: String {
            switch self {
                case .integer(let value): "\(value)"
                case .text(let value): value.debugDescription
                case .boolean(let value): "\(value)"
                case .emptyArray: "[]"
                case .null: "nil"
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
                case .integer(let value):
                    var container = encoder.singleValueContainer()
                    try container.encode(value)
                case .text(let value):
                    var container = encoder.singleValueContainer()
                    try container.encode(value)
                case .boolean(let value):
                    var container = encoder.singleValueContainer()
                    try container.encode(value)
                case .emptyArray:
                    _ = encoder.unkeyedContainer()
                case .null:
                    var container = encoder.singleValueContainer()
                    try container.encodeNil()
            }
        }
    }

    /// An integer map key.
    struct WireKey: CodingKey {
        let intValue: Int?
        var stringValue: String { String(intValue ?? 0) }

        init(_ value: Int) { intValue = value }
        init?(intValue: Int) { self.intValue = intValue }
        init?(stringValue: String) { nil }
    }

    /// A schema written as `TypeSchema`'s documentation lays out its wire
    /// form, apart from `TypeSchema.encode(to:)`, with optionally one node,
    /// found by its path as `children(of:)` counts, written wrong.
    struct DocumentedSchema: Encodable {
        let schema: TypeSchema
        let damage: (path: [Int], kind: NodeDamage)?

        init(_ schema: TypeSchema, damage: (path: [Int], kind: NodeDamage)? = nil) {
            self.schema = schema
            self.damage = damage
        }

        /// The case tags, from the table in `TypeSchema`'s documentation.
        static func tag(of schema: TypeSchema) -> UInt8 {
            switch schema {
                case .bool: 0
                case .int: 1
                case .uint: 2
                case .float: 3
                case .double: 4
                case .string: 5
                case .bytes: 6
                case .optional: 7
                case .array: 8
                case .map: 9
                case .structure: 10
                case .enumeration: 11
                case .reference: 12
                case .date: 13
                case .datetime: 14
                case .timestamp: 15
                case .union: 16
                case .duration: 17
                case .uuid: 18
                case .unknown: 255
            }
        }

        /// The child at `index`, carrying the damage if it lies there.
        func child(_ index: Int, _ schema: TypeSchema) -> DocumentedSchema {
            guard let damage, damage.path.first == index else { return DocumentedSchema(schema) }
            return DocumentedSchema(schema, damage: (Array(damage.path.dropFirst()), damage.kind))
        }

        func encode(to encoder: any Encoder) throws {
            let here = damage.flatMap { $0.path.isEmpty ? $0.kind : nil }
            if case .notAMap(let junk)? = here {
                try junk.encode(to: encoder)
                return
            }
            var container = encoder.container(keyedBy: WireKey.self)
            switch here {
                case .unlistedTag(let tag)?: try container.encode(tag, forKey: WireKey(0))
                case .noTag?: break
                case .tagNotAByte(let junk)?: try container.encode(junk, forKey: WireKey(0))
                default: try container.encode(Self.tag(of: schema), forKey: WireKey(0))
            }
            let payloads: [(key: Int, value: any Encodable)]
            switch schema {
                case .optional(let wrapped):
                    payloads = [(1, child(0, wrapped))]
                case .array(let element):
                    payloads = [(1, child(0, element))]
                case .map(let key, let value):
                    payloads = [(1, child(0, key)), (2, child(1, value))]
                case .structure(let fields):
                    payloads = [
                        (
                            1,
                            fields.enumerated().map {
                                DocumentedField($1, type: child($0, $1.type))
                            }
                        )
                    ]
                case .enumeration(let cases):
                    payloads = [(1, cases.map(DocumentedEnumCase.init))]
                case .union(let cases):
                    var offset = 0
                    var documented: [DocumentedUnionCase] = []
                    for unionCase in cases {
                        let fields = unionCase.fields.enumerated().map {
                            DocumentedField($1, type: child(offset + $0, $1.type))
                        }
                        documented.append(DocumentedUnionCase(unionCase, fields: fields))
                        offset += unionCase.fields.count
                    }
                    payloads = [(1, documented)]
                case .reference(let name):
                    payloads = [(1, name)]
                default:
                    payloads = []
            }
            for payload in payloads {
                switch here {
                    case .payloadLeftOut(payload.key)?:
                        continue
                    case .payloadOfTheWrongKind(let junk)? where payload.key == 1:
                        try container.encode(junk, forKey: WireKey(1))
                    default:
                        try container.encode(payload.value, forKey: WireKey(payload.key))
                }
            }
            switch here {
                case .unusedKey(let key, let junk)?:
                    try container.encode(junk, forKey: WireKey(key))
                case .tagRepeated(let tag)?: try container.encode(tag, forKey: WireKey(0))
                default: break
            }
        }
    }

    /// A field as its `CodingKeys` lay it out: 0 the integer key, 1 the
    /// name, 2 the type, 3 the description, 5 the default as the bare
    /// value, 6 the deprecation, each optional one left out when absent.
    struct DocumentedField: Encodable {
        let field: TypeSchema.Field
        let type: DocumentedSchema

        init(_ field: TypeSchema.Field, type: DocumentedSchema) {
            self.field = field
            self.type = type
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: WireKey.self)
            try container.encodeIfPresent(field.key, forKey: WireKey(0))
            try container.encode(field.name, forKey: WireKey(1))
            try container.encode(type, forKey: WireKey(2))
            try container.encodeIfPresent(field.description, forKey: WireKey(3))
            switch field.defaultValue {
                case .bool(let value)?: try container.encode(value, forKey: WireKey(5))
                case .integer(let value)?: try container.encode(value, forKey: WireKey(5))
                case .floating(let value)?: try container.encode(value, forKey: WireKey(5))
                case .string(let value)?: try container.encode(value, forKey: WireKey(5))
                case nil: break
            }
            try container.encodeIfPresent(field.deprecation, forKey: WireKey(6))
        }
    }

    /// An enumeration case: 0 the name, 1 the description and 2 the
    /// deprecation when present.
    struct DocumentedEnumCase: Encodable {
        let enumCase: TypeSchema.EnumCase

        init(_ enumCase: TypeSchema.EnumCase) { self.enumCase = enumCase }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: WireKey.self)
            try container.encode(enumCase.name, forKey: WireKey(0))
            try container.encodeIfPresent(enumCase.description, forKey: WireKey(1))
            try container.encodeIfPresent(enumCase.deprecation, forKey: WireKey(2))
        }
    }

    /// A union case: 0 the name, 1 the fields, 2 the description and 3 the
    /// deprecation when present.
    struct DocumentedUnionCase: Encodable {
        let unionCase: TypeSchema.UnionCase
        let fields: [DocumentedField]

        init(_ unionCase: TypeSchema.UnionCase, fields: [DocumentedField]) {
            self.unionCase = unionCase
            self.fields = fields
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: WireKey.self)
            try container.encode(unionCase.name, forKey: WireKey(0))
            try container.encode(fields, forKey: WireKey(1))
            try container.encodeIfPresent(unionCase.description, forKey: WireKey(2))
            try container.encodeIfPresent(unionCase.deprecation, forKey: WireKey(3))
        }
    }

    /// What a schema holds that its wire form must carry.
    func kindLabels(of schema: TypeSchema) -> Set<String> {
        var labels: Set<String> = []
        func text(_ value: String, as kind: String) {
            if value.isEmpty { labels.insert("an empty \(kind)") }
            if value.unicodeScalars.contains(where: { $0.value > 0x7F }) {
                labels.insert("a \(kind) beyond ASCII")
            }
        }
        func field(_ field: TypeSchema.Field) {
            text(field.name, as: "field name")
            switch field.key {
                case nil: labels.insert("a field with no key")
                case .some(let key) where key == .min || key == .max:
                    labels.insert("a field key at an end of Int")
                case .some(let key) where key < 0: labels.insert("a negative field key")
                default: break
            }
            if field.description != nil { labels.insert("a documented field") }
            if field.deprecation != nil { labels.insert("a deprecated field") }
            switch field.defaultValue {
                case .bool?: labels.insert("a boolean default")
                case .integer?: labels.insert("an integer default")
                case .floating(let value)?:
                    labels.insert(
                        value.rounded() == value && abs(value) < 0x1p63
                            ? "a whole floating default" : "a floating default"
                    )
                case .string?: labels.insert("a string default")
                case nil: break
            }
        }
        for place in nodes(of: schema) {
            if place.path.count >= 3 { labels.insert("a node three deep") }
            switch place.node {
                case .bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime,
                    .timestamp, .duration, .uuid:
                    labels.insert("a scalar, tag \(DocumentedSchema.tag(of: place.node))")
                case .unknown: labels.insert("unknown")
                case .optional: labels.insert("an optional")
                case .array: labels.insert("an array")
                case .map: labels.insert("a map")
                case .structure(let fields):
                    labels.insert(fields.isEmpty ? "an empty structure" : "a structure")
                    fields.forEach(field)
                case .enumeration(let cases):
                    labels.insert(cases.isEmpty ? "an empty enumeration" : "an enumeration")
                    for enumCase in cases {
                        text(enumCase.name, as: "case name")
                        if enumCase.description != nil { labels.insert("a documented case") }
                        if enumCase.deprecation != nil { labels.insert("a deprecated case") }
                    }
                case .union(let cases):
                    labels.insert(cases.isEmpty ? "an empty union" : "a union")
                    for unionCase in cases {
                        text(unionCase.name, as: "case name")
                        if unionCase.fields.isEmpty { labels.insert("a union case without fields") }
                        if unionCase.description != nil { labels.insert("a documented case") }
                        if unionCase.deprecation != nil { labels.insert("a deprecated case") }
                        unionCase.fields.forEach(field)
                    }
                case .reference(let name):
                    labels.insert("a reference")
                    text(name, as: "reference name")
            }
        }
        return labels
    }

#endif
