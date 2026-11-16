// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMWire
    import NIOCore
    import Testing

    /// A method set and the named types it references.
    struct SchemaSet: Sendable {
        var signatures: [MethodSignature]
        var types: [TypeDefinition]

        var fingerprint: UInt64 { SchemaFingerprint.compute(signatures, types: types) }
    }

    func packedBytes(_ value: some Encodable) throws -> [UInt8] {
        Array(try MMPackEncoder().encode(value).get().readableBytesView)
    }

    /// The set as the wire carries it, with no order and no descriptions:
    /// each signature's and each definition's MessagePack form with its
    /// descriptions stripped, sorted. Two sets with the same form describe
    /// the same schema, byte for byte in every name; any other two differ.
    func wireForm(_ set: SchemaSet) throws -> [[[UInt8]]] {
        let signatures = try set.signatures.map { try packedBytes($0.strippingDescriptions) }
        let types = try set.types.map { try packedBytes($0.strippingDescriptions) }
        return [
            signatures.sorted { $0.lexicographicallyPrecedes($1) },
            types.sorted { $0.lexicographicallyPrecedes($1) },
        ]
    }

    /// The schema's every description and deprecation, field, case and
    /// nested, set to `text`.
    func describing(_ schema: TypeSchema, _ text: String?) -> TypeSchema {
        func fields(_ fields: [TypeSchema.Field]) -> [TypeSchema.Field] {
            fields.map {
                var field = $0
                field.type = describing($0.type, text)
                field.description = text
                field.deprecation = text
                return field
            }
        }
        switch schema {
            case .optional(let wrapped): return .optional(describing(wrapped, text))
            case .array(let element): return .array(describing(element, text))
            case .map(let key, let value):
                return .map(key: describing(key, text), value: describing(value, text))
            case .structure(let list): return .structure(fields: fields(list))
            case .enumeration(let cases):
                return .enumeration(
                    cases: cases.map {
                        TypeSchema.EnumCase(name: $0.name, description: text, deprecation: text)
                    }
                )
            case .union(let cases):
                return .union(
                    cases: cases.map {
                        TypeSchema.UnionCase(
                            name: $0.name,
                            fields: fields($0.fields),
                            description: text,
                            deprecation: text
                        )
                    }
                )
            default: return schema
        }
    }

    func describing(_ signature: MethodSignature, _ text: String?) -> MethodSignature {
        MethodSignature(
            name: signature.name,
            access: signature.access,
            request: describing(signature.request, text),
            response: describing(signature.response, text),
            requestStream: signature.requestStream.map { describing($0, text) },
            responseStream: signature.responseStream.map { describing($0, text) },
            errors: signature.errors.map { describing($0, text) },
            description: text,
            requestDescription: text,
            responseDescription: text,
            requestStreamDescription: text,
            responseStreamDescription: text,
            deprecation: text
        )
    }

    /// The schemas directly inside one.
    func children(of schema: TypeSchema) -> [TypeSchema] {
        switch schema {
            case .optional(let wrapped): [wrapped]
            case .array(let element): [element]
            case .map(let key, let value): [key, value]
            case .structure(let fields): fields.map(\.type)
            case .union(let cases): cases.flatMap { $0.fields.map(\.type) }
            default: []
        }
    }

    /// The schema with its child at `index`, as `children(of:)` counts,
    /// replaced.
    func replacingChild(_ index: Int, of schema: TypeSchema, with child: TypeSchema) -> TypeSchema {
        func replaced(_ field: TypeSchema.Field) -> TypeSchema.Field {
            var field = field
            field.type = child
            return field
        }
        switch schema {
            case .optional: return .optional(child)
            case .array: return .array(child)
            case .map(let key, let value):
                return index == 0 ? .map(key: child, value: value) : .map(key: key, value: child)
            case .structure(var fields):
                fields[index] = replaced(fields[index])
                return .structure(fields: fields)
            case .union(var cases):
                var remaining = index
                for caseIndex in cases.indices {
                    if remaining < cases[caseIndex].fields.count {
                        var fields = cases[caseIndex].fields
                        fields[remaining] = replaced(fields[remaining])
                        cases[caseIndex].fields = fields
                        return .union(cases: cases)
                    }
                    remaining -= cases[caseIndex].fields.count
                }
                return schema
            default: return schema
        }
    }

    /// Every schema inside this one, itself first, each with the child
    /// indexes, as `children(of:)` counts them, that lead to it.
    func nodes(of schema: TypeSchema, at path: [Int] = []) -> [(path: [Int], node: TypeSchema)] {
        [(path, schema)]
            + children(of: schema).enumerated().flatMap { index, child in
                nodes(of: child, at: path + [index])
            }
    }

    /// The schema with the node at `path` replaced.
    func replacing(at path: [Int], in schema: TypeSchema, with replacement: TypeSchema)
        -> TypeSchema
    {
        guard let index = path.first else { return replacement }
        let child = replacing(
            at: Array(path.dropFirst()),
            in: children(of: schema)[index],
            with: replacement
        )
        return replacingChild(index, of: schema, with: child)
    }

    /// One edit inside a schema.
    enum SchemaEdit: String, CaseIterable, Sendable {
        case fieldRenamed = "a field renamed"
        case fieldKeyChanged = "a field key changed"
        case fieldsSwapped = "two fields swapped"
        case fieldDropped = "a field dropped"
        case fieldAdded = "a field added"
        case fieldDefaultChanged = "a field's default changed"
        case enumCaseRenamed = "an enum case renamed"
        case enumCasesSwapped = "two enum cases swapped"
        case enumCaseDropped = "an enum case dropped"
        case unionCaseRenamed = "a union case renamed"
        case unionCasesSwapped = "two union cases swapped"
        case unionCaseDropped = "a union case dropped"
        case unionCaseFieldEdited = "a union case's field edited"
        case schemaReplaced = "a schema replaced"

        static let fieldEdits: [SchemaEdit] = [
            .fieldRenamed, .fieldKeyChanged, .fieldsSwapped, .fieldDropped, .fieldAdded,
            .fieldDefaultChanged,
        ]

        /// Whether the edit can be made at this node.
        func applies(to node: TypeSchema) -> Bool {
            switch (self, node) {
                case (.fieldRenamed, .structure(let fields)),
                    (.fieldKeyChanged, .structure(let fields)),
                    (.fieldDropped, .structure(let fields)),
                    (.fieldDefaultChanged, .structure(let fields)):
                    !fields.isEmpty
                case (.fieldsSwapped, .structure(let fields)): fields.count >= 2
                case (.fieldAdded, .structure): true
                case (.enumCaseRenamed, .enumeration(let cases)),
                    (.enumCaseDropped, .enumeration(let cases)):
                    !cases.isEmpty
                case (.enumCasesSwapped, .enumeration(let cases)): cases.count >= 2
                case (.unionCaseRenamed, .union(let cases)), (.unionCaseDropped, .union(let cases)),
                    (.unionCaseFieldEdited, .union(let cases)):
                    !cases.isEmpty
                case (.unionCasesSwapped, .union(let cases)): cases.count >= 2
                case (.schemaReplaced, _): true
                default: false
            }
        }
    }

    /// One change to the set or to a signature, outside its schemas.
    enum SetChange: String, CaseIterable, Sendable {
        case signatureAdded = "a signature added"
        case definitionAdded = "a definition added"
        case methodRenamed = "a method renamed"
        case accessChanged = "access changed"
        case requestStreamChanged = "the request stream changed"
        case responseStreamChanged = "the response stream changed"
        case streamMoved = "a stream moved to the other slot"
        case streamsSwapped = "the streams swapped slots"
        case signatureDoubled = "a signature doubled"
        case signatureDropped = "a signature dropped"
        case definitionRenamed = "a definition renamed"
        case definitionDropped = "a definition dropped"

        var needsDefinition: Bool { self == .definitionRenamed || self == .definitionDropped }
    }

    /// Where a schema sits in a set.
    enum SchemaSlot: Sendable {
        case request(Int), response(Int), requestStream(Int), responseStream(Int), errors(Int)
        case definition(Int)
    }

    extension SchemaSet {
        var slots: [SchemaSlot] {
            signatures.indices.flatMap { index in
                [.request(index), .response(index)]
                    + (signatures[index].requestStream == nil ? [] : [.requestStream(index)])
                    + (signatures[index].responseStream == nil ? [] : [.responseStream(index)])
                    + (signatures[index].errors == nil ? [] : [.errors(index)])
            } + types.indices.map { .definition($0) }
        }

        func schema(at slot: SchemaSlot) -> TypeSchema {
            switch slot {
                case .request(let index): signatures[index].request
                case .response(let index): signatures[index].response
                case .requestStream(let index): signatures[index].requestStream!
                case .responseStream(let index): signatures[index].responseStream!
                case .errors(let index): signatures[index].errors!
                case .definition(let index): types[index].schema
            }
        }

        mutating func replace(_ slot: SchemaSlot, with schema: TypeSchema) {
            switch slot {
                case .request(let index): signatures[index].request = schema
                case .response(let index): signatures[index].response = schema
                case .requestStream(let index): signatures[index].requestStream = schema
                case .responseStream(let index): signatures[index].responseStream = schema
                case .errors(let index): signatures[index].errors = schema
                case .definition(let index):
                    types[index] = TypeDefinition(name: types[index].name, schema: schema)
            }
        }

        /// Every node in every schema of the set where the edit applies.
        func places(for edit: SchemaEdit) -> [(slot: SchemaSlot, path: [Int], node: TypeSchema)] {
            slots.flatMap { slot in
                nodes(of: schema(at: slot)).filter { edit.applies(to: $0.node) }.map {
                    (slot, $0.path, $0.node)
                }
            }
        }

        /// The signatures a change to one signature applies to, or nil for
        /// a change to the set.
        func signatures(for change: SetChange) -> [Int]? {
            switch change {
                case .signatureAdded, .definitionAdded, .definitionRenamed, .definitionDropped: nil
                case .streamMoved:
                    signatures.indices.filter {
                        (signatures[$0].requestStream == nil)
                            != (signatures[$0].responseStream == nil)
                    }
                case .streamsSwapped:
                    signatures.indices.filter {
                        signatures[$0].requestStream != nil && signatures[$0].responseStream != nil
                    }
                default: Array(signatures.indices)
            }
        }
    }

    enum FingerprintGenerators {
        /// Names from a small pool, so duplicates and near misses come up
        /// (`é` precomposed and decomposed are equal Strings with different
        /// bytes), or any text.
        static let names: Gen<String> = .oneOf(
            .element(of: [
                "a", "b", "aa", "journal.append", "server.schema", "\u{E9}", "e\u{301}", "",
            ]),
            .string()
        )

        static let descriptions: Gen<String?> = .optional(.string())

        /// A field's default of each kind: booleans, integers and floating
        /// numbers around their edges, whole floating numbers among them,
        /// and the names.
        static let defaults: Gen<TypeSchema.Default> = .oneOf(
            Gen<Bool>.bool().map { .bool($0) },
            SchemaValueGenerators.int64s(edgeRate: 0.3).map { .integer($0) },
            SchemaValueGenerators.doubles(edgeRate: 0.3).map { .floating($0) },
            Gen<Int64>.integer(in: -3...3).map { .floating(Double($0)) },
            names.map { .string($0) }
        )

        static let keys: Gen<Int?> = .optional(
            .oneOf(.int(), .element(of: [0, 1, -1, .min, .max]))
        )

        static let leaves: Gen<TypeSchema> = .oneOf(
            .element(of: [
                .bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime, .timestamp,
                .unknown,
            ]),
            names.map { .reference($0) }
        )

        static func fields(_ schemas: Gen<TypeSchema>) -> Gen<TypeSchema.Field> {
            Gen { tc in
                TypeSchema.Field(
                    key: try tc.draw(keys),
                    name: try tc.draw(names),
                    type: try tc.draw(schemas),
                    description: try tc.draw(descriptions),
                    defaultValue: try tc.draw(.optional(defaults)),
                    deprecation: try tc.draw(descriptions)
                )
            }
        }

        static let enumCases: Gen<TypeSchema.EnumCase> = Hegel.zip(
            names,
            descriptions,
            descriptions
        )
        .map { TypeSchema.EnumCase(name: $0, description: $1, deprecation: $2) }

        static func unions(_ schemas: Gen<TypeSchema>) -> Gen<TypeSchema> {
            Gen<[TypeSchema.UnionCase]>.array(
                of: Hegel.zip(
                    names,
                    .array(of: fields(schemas), count: 0...3),
                    descriptions,
                    descriptions
                )
                .map {
                    TypeSchema.UnionCase(name: $0, fields: $1, description: $2, deprecation: $3)
                }
            )
            .map { .union(cases: $0) }
        }

        static let schemas: Gen<TypeSchema> = .recursive(maxDepth: 4, maxLeaves: 8, leaf: leaves) {
            schema in
            .oneOf(
                schema.map { .optional($0) },
                schema.map { .array($0) },
                Hegel.zip(schema, schema).map { .map(key: $0, value: $1) },
                Gen<[TypeSchema.Field]>.array(of: fields(schema), count: 0...4).map {
                    .structure(fields: $0)
                },
                Gen<[TypeSchema.EnumCase]>.array(of: enumCases, count: 0...4).map {
                    .enumeration(cases: $0)
                },
                unions(schema)
            )
        }

        static let accesses: Gen<AccessMode> = Gen<UInt8>.oneOf(.integer(in: 0...7), .integer())
            .map { AccessMode(rawValue: $0) }

        /// A request or response: half the time a structure, as most are.
        static let payloads: Gen<TypeSchema> = .oneOf(
            Gen<[TypeSchema.Field]>.array(of: fields(schemas), count: 1...4).map {
                .structure(fields: $0)
            },
            schemas
        )

        /// A call's declared errors: a union, as `Errors` blocks resolve to.
        static let errors: Gen<TypeSchema> = unions(schemas)

        static let signatures: Gen<MethodSignature> = Gen { tc in
            MethodSignature(
                name: try tc.draw(names),
                access: try tc.draw(accesses),
                request: try tc.draw(payloads),
                response: try tc.draw(payloads),
                requestStream: try tc.draw(.optional(schemas)),
                responseStream: try tc.draw(.optional(schemas)),
                errors: try tc.draw(.optional(errors)),
                description: try tc.draw(descriptions),
                requestDescription: try tc.draw(descriptions),
                responseDescription: try tc.draw(descriptions),
                requestStreamDescription: try tc.draw(descriptions),
                responseStreamDescription: try tc.draw(descriptions),
                deprecation: try tc.draw(descriptions)
            )
        }

        static let definitions: Gen<TypeDefinition> = Gen { tc in
            TypeDefinition(
                name: try tc.draw(names),
                schema: try tc.draw(schemas),
                description: try tc.draw(descriptions),
                deprecation: try tc.draw(descriptions)
            )
        }

        /// Up to six signatures and four definitions: enough for order and
        /// duplicates to matter, few enough to keep a case cheap.
        static func sets(signatureCount: ClosedRange<Int>) -> Gen<SchemaSet> {
            Hegel.zip(
                .array(of: signatures, count: signatureCount),
                .array(of: definitions, count: 0...4)
            )
            .map { SchemaSet(signatures: $0, types: $1) }
        }

        /// The list in an order drawn by sorting on drawn keys.
        static func shuffled<Element>(_ list: [Element], _ tc: TestCase) throws -> [Element] {
            let order = try tc.draw(
                Gen<[UInt64]>.array(of: .integer(), count: list.count...list.count)
            )
            return zip(list, order).sorted { $0.1 < $1.1 }.map(\.0)
        }

        /// The set reordered, with every description set to one drawn text
        /// or removed.
        static func restated(_ set: SchemaSet, _ tc: TestCase) throws -> SchemaSet {
            let text = try tc.draw(descriptions)
            return SchemaSet(
                signatures: try shuffled(set.signatures.map { describing($0, text) }, tc),
                types: try shuffled(
                    set.types.map {
                        TypeDefinition(
                            name: $0.name,
                            schema: describing($0.schema, text),
                            description: text,
                            deprecation: text
                        )
                    },
                    tc
                )
            )
        }

        /// The fields with one edit: a structure's, or a union case's.
        static func editedFields(
            _ fields: [TypeSchema.Field],
            _ edit: SchemaEdit,
            _ tc: TestCase
        ) throws -> [TypeSchema.Field] {
            var fields = fields
            switch edit {
                case .fieldRenamed:
                    let index = try pick(fields.count, tc)
                    fields[index].name = try tc.draw(names)
                case .fieldKeyChanged:
                    let index = try pick(fields.count, tc)
                    var key = try tc.draw(keys)
                    if key == fields[index].key { key = key == nil ? 0 : nil }
                    fields[index].key = key
                case .fieldsSwapped:
                    try swapTwo(&fields, tc)
                case .fieldDropped:
                    fields.remove(at: try pick(fields.count, tc))
                case .fieldDefaultChanged:
                    // Added, dropped, or another value, of its kind or not.
                    let index = try pick(fields.count, tc)
                    var value = try tc.draw(.optional(defaults))
                    if value == fields[index].defaultValue {
                        value = value == nil ? .bool(false) : nil
                    }
                    fields[index].defaultValue = value
                default:
                    let added = try tc.draw(FingerprintGenerators.fields(leaves))
                    fields.insert(added, at: try tc.draw(Gen<Int>.int(in: 0...fields.count)))
            }
            return fields
        }

        /// The node with the edit made, and a label for the statistics.
        static func applying(_ edit: SchemaEdit, to node: TypeSchema, _ tc: TestCase) throws -> (
            TypeSchema, String
        ) {
            switch node {
                case .structure(let fields) where edit != .schemaReplaced:
                    return (.structure(fields: try editedFields(fields, edit, tc)), edit.rawValue)
                case .enumeration(var cases) where edit != .schemaReplaced:
                    switch edit {
                        case .enumCaseRenamed:
                            cases[try pick(cases.count, tc)] = TypeSchema.EnumCase(
                                name: try tc.draw(names)
                            )
                        case .enumCasesSwapped:
                            try swapTwo(&cases, tc)
                        default:
                            cases.remove(at: try pick(cases.count, tc))
                    }
                    return (.enumeration(cases: cases), edit.rawValue)
                case .union(var cases) where edit != .schemaReplaced:
                    let index = try pick(cases.count, tc)
                    let unionCase = cases[index]
                    switch edit {
                        case .unionCaseRenamed:
                            cases[index] = TypeSchema.UnionCase(
                                name: try tc.draw(names),
                                fields: unionCase.fields
                            )
                        case .unionCasesSwapped:
                            try swapTwo(&cases, tc)
                        case .unionCaseDropped:
                            cases.remove(at: index)
                        default:
                            let fieldEdits = SchemaEdit.fieldEdits.filter {
                                $0.applies(to: .structure(fields: unionCase.fields))
                            }
                            let fieldEdit = try tc.draw(Gen<SchemaEdit>.element(of: fieldEdits))
                            let fields = try editedFields(unionCase.fields, fieldEdit, tc)
                            cases[index] = TypeSchema.UnionCase(
                                name: unionCase.name,
                                fields: fields
                            )
                            return (.union(cases: cases), "a union case: " + fieldEdit.rawValue)
                    }
                    return (.union(cases: cases), edit.rawValue)
                default:
                    return (try tc.draw(schemas), SchemaEdit.schemaReplaced.rawValue)
            }
        }

        /// The set with one edit inside one of its schemas. Every kind of
        /// edit the set has a place for is drawn as often as the others,
        /// and made at a place drawn from all its places. A set always has
        /// a place to replace a schema, since it has a signature.
        static func edited(_ set: SchemaSet, _ tc: TestCase) throws -> (SchemaSet, String) {
            var set = set
            let edits = SchemaEdit.allCases.filter { !set.places(for: $0).isEmpty }
            let edit = try tc.draw(Gen<SchemaEdit>.element(of: edits))
            let places = set.places(for: edit)
            let place = places[try pick(places.count, tc)]
            let (node, label) = try applying(edit, to: place.node, tc)
            set.replace(
                place.slot,
                with: replacing(at: place.path, in: set.schema(at: place.slot), with: node)
            )
            return (set, label)
        }

        /// The set with one change to the set or to a signature, outside
        /// its schemas. Every kind of change the set allows is drawn as
        /// often as the others, and made to a signature drawn from those it
        /// applies to. A set always allows adding a signature.
        static func changed(_ set: SchemaSet, _ tc: TestCase) throws -> (SchemaSet, String) {
            var set = set
            let changes = SetChange.allCases.filter {
                set.signatures(for: $0)?.isEmpty != true
                    && !($0.needsDefinition && set.types.isEmpty)
            }
            let change = try tc.draw(Gen<SetChange>.element(of: changes))
            let candidates = set.signatures(for: change) ?? Array(set.signatures.indices)
            let index = candidates[try pick(candidates.count, tc)]
            let typeIndex = set.types.isEmpty ? 0 : try pick(set.types.count, tc)
            switch change {
                case .signatureAdded:
                    set.signatures.append(try tc.draw(signatures))
                case .definitionAdded:
                    set.types.append(try tc.draw(definitions))
                case .methodRenamed:
                    set.signatures[index].name = try tc.draw(names)
                case .accessChanged:
                    set.signatures[index].access = try tc.draw(accesses)
                case .requestStreamChanged:
                    set.signatures[index].requestStream = try tc.draw(.optional(schemas))
                case .responseStreamChanged:
                    set.signatures[index].responseStream = try tc.draw(.optional(schemas))
                case .streamMoved, .streamsSwapped:
                    let signature = set.signatures[index]
                    set.signatures[index].requestStream = signature.responseStream
                    set.signatures[index].responseStream = signature.requestStream
                case .signatureDoubled:
                    set.signatures.append(set.signatures[index])
                case .signatureDropped:
                    set.signatures.remove(at: index)
                case .definitionRenamed:
                    set.types[typeIndex] = TypeDefinition(
                        name: try tc.draw(names),
                        schema: set.types[typeIndex].schema
                    )
                case .definitionDropped:
                    set.types.remove(at: typeIndex)
            }
            return (set, change.rawValue)
        }

        static func pick(_ count: Int, _ tc: TestCase) throws -> Int {
            try tc.draw(Gen<Int>.int(in: 0...(count - 1)))
        }

        /// Two members of the list, at different places, swapped.
        static func swapTwo<Element>(_ list: inout [Element], _ tc: TestCase) throws {
            let first = try pick(list.count, tc)
            let step = try pick(list.count - 1, tc)
            list.swapAt(first, (first + 1 + step) % list.count)
        }
    }

    @Suite("SchemaFingerprint properties", .hegel, .offTheCooperativePool)
    struct SchemaFingerprintProperties {
        /// Reordering the signatures and the type definitions, and
        /// rewriting or removing every description and deprecation, leaves
        /// the fingerprint as it was, duplicate method names and field
        /// defaults included.
        ///
        /// Mutation check: dropping the tie-break on the full encoding, so
        /// two methods of one name stay in the order they came in, hashing
        /// an enum case's description, or hashing a field's deprecation,
        /// fails here.
        @Test
        func fingerprintIgnoresOrderAndDescriptions() throws {
            try property(
                reachingAfter: [
                    "duplicate method names": 1_000, "a field default": 1_000,
                    "a deprecation": 1_000,
                ]
            ) { tc in
                let set = try #draw(FingerprintGenerators.sets(signatureCount: 0...6), from: tc)
                let restated = try FingerprintGenerators.restated(set, tc)
                try tc.event("signatures", value: Double(set.signatures.count))
                if Set(set.signatures.map(\.name)).count < set.signatures.count {
                    try tc.event("duplicate method names")
                }
                let schemas =
                    set.signatures.flatMap {
                        [$0.request, $0.response]
                            + [$0.requestStream, $0.responseStream, $0.errors].compactMap { $0 }
                    } + set.types.map(\.schema)
                let labels = schemas.reduce(into: Set<String>()) {
                    $0.formUnion(kindLabels(of: $1))
                }
                if labels.contains(where: { $0.hasSuffix(" default") }) {
                    try tc.event("a field default")
                }
                if !labels.isDisjoint(with: ["a deprecated field", "a deprecated case"])
                    || set.signatures.contains(where: { $0.deprecation != nil })
                    || set.types.contains(where: { $0.deprecation != nil })
                {
                    try tc.event("a deprecation")
                }
                #expect(restated.fingerprint == set.fingerprint)
            }
        }

        /// Two sets fingerprint the same exactly when their wire forms, with
        /// no order and no descriptions, are the same: one edit inside a
        /// schema, a field's name, key, default or place, a field or a case added or
        /// dropped, a case renamed or moved, or a schema replaced, changes
        /// the fingerprint unless it changes nothing on the wire.
        ///
        /// Mutation check: leaving a field's key, a union case's fields or
        /// a field's default out of the hash fails here.
        @Test
        func fingerprintSeesEverySchemaEdit() throws {
            try property(
                reaching: ["the wire form changed"],
                reachingAfter: [
                    "a field added": 1_000, "a field dropped": 1_000, "a field key changed": 1_000,
                    "a field renamed": 1_000, "a field's default changed": 1_000,
                    "a schema replaced": 1_000,
                    "a union case dropped": 1_000, "a union case renamed": 1_000,
                    "an enum case dropped": 1_000, "an enum case renamed": 1_000,
                    "two enum cases swapped": 1_000, "two fields swapped": 1_000,
                    "two union cases swapped": 1_000,
                ]
            ) { tc in
                let set = try #draw(FingerprintGenerators.sets(signatureCount: 1...6), from: tc)
                let (changed, label) = try FingerprintGenerators.edited(set, tc)
                let restated = try FingerprintGenerators.restated(changed, tc)
                let same = try wireForm(set) == wireForm(restated)
                try tc.event(label)
                try tc.event(same ? "nothing changed on the wire" : "the wire form changed")
                #expect((restated.fingerprint == set.fingerprint) == same, "\(label)")
            }
        }

        /// Two sets fingerprint the same exactly when their wire forms, with
        /// no order and no descriptions, are the same: one change outside
        /// the schemas, a signature added, dropped or doubled, a method's
        /// name or access mode, a stream or its slot, or a definition added,
        /// renamed or dropped, changes the fingerprint unless it changes
        /// nothing on the wire.
        ///
        /// Mutation check: leaving the access mode out of the hash, or
        /// tagging a response stream as a request stream, fails here.
        @Test
        func fingerprintSeesEverySetChange() throws {
            try property(
                reaching: ["the wire form changed"],
                reachingAfter: [
                    "a definition added": 1_000, "a definition dropped": 1_000,
                    "a definition renamed": 1_000, "a method renamed": 1_000,
                    "a signature added": 1_000, "a signature doubled": 1_000,
                    "a signature dropped": 1_000, "a stream moved to the other slot": 1_000,
                    "access changed": 1_000, "nothing changed on the wire": 1_000,
                    "the request stream changed": 1_000, "the response stream changed": 1_000,
                    "the streams swapped slots": 1_000,
                ]
            ) { tc in
                let set = try #draw(FingerprintGenerators.sets(signatureCount: 1...6), from: tc)
                let (changed, label) = try FingerprintGenerators.changed(set, tc)
                let restated = try FingerprintGenerators.restated(changed, tc)
                let same = try wireForm(set) == wireForm(restated)
                try tc.event(label)
                try tc.event(same ? "nothing changed on the wire" : "the wire form changed")
                #expect((restated.fingerprint == set.fingerprint) == same, "\(label)")
            }
        }

        /// One schema fingerprints apart in each slot a signature can hold
        /// it in beside its request and response: the request stream, the
        /// response stream, the errors, and none of them.
        ///
        /// Mutation check: tagging the errors as either stream fails here.
        @Test
        func slotsFingerprintApart() throws {
            try property { tc in
                let drawn = try #draw(FingerprintGenerators.signatures, from: tc)
                let schema = try #draw(FingerprintGenerators.schemas, from: tc)
                var bare = drawn
                bare.requestStream = nil
                bare.responseStream = nil
                bare.errors = nil
                var placed = [bare, bare, bare, bare]
                placed[1].requestStream = schema
                placed[2].responseStream = schema
                placed[3].errors = schema
                let fingerprints = placed.map { SchemaFingerprint.compute([$0]) }
                #expect(Set(fingerprints).count == placed.count)
            }
        }
    }

#endif
