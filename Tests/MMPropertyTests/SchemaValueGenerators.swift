// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema

    /// A schema, the named types its references resolve through, and a
    /// canonical value that fits it: one that
    /// `validated(against:resolver:path:)` gives back unchanged.
    struct FittingValue: Sendable {
        var schema: TypeSchema
        var definitions: [TypeDefinition]
        var value: SchemaValue

        var resolver: TypeResolver { TypeResolver(definitions) }
    }

    /// The shape of one test case's schemas and values, drawn once at the
    /// top so each case lands in its own region: no named types or several,
    /// flat or nested schemas, optional slots always empty, sometimes filled
    /// or always filled.
    struct SchemaValuePolicy: Sendable {
        /// How many named types references can point at.
        var definitionCount: Int
        /// Whether a later definition reuses an earlier one's name with a
        /// shape no value fits, which the resolver must ignore.
        var shadowedDefinition: Bool
        /// Whether the root is a structure with at least one field, as a
        /// request or a response almost always is, rather than any schema.
        var structureRoot: Bool
        /// How deep a schema nests before only leaves and references remain.
        /// A structure root and a definition's body sit outside the count,
        /// as the declaration that holds the nesting.
        var schemaDepth: Int
        /// The composite kinds this case's schemas use; the rest stay off,
        /// so the ones on nest in each other more.
        var composites: [CompositeKind]
        /// How often a position draws a reference when it may.
        var referenceRate: Double
        /// How often a structure's field is optional, as most fields are in
        /// real types; an optional field may reference any definition, its
        /// own included.
        var optionalFieldRate: Double
        /// The most fields a structure or union case declares, and the most
        /// cases an enumeration or union declares.
        var maxMembers: Int
        /// How many levels a value fills before every optional slot is null
        /// and every array and map is empty.
        var valueDepth: Int
        /// The most items an array or map holds.
        var maxItems: Int
        /// How often an optional slot holds a value and an optional field is
        /// present.
        var fillRate: Double
        /// How often a number or an integer map key comes from its edge
        /// menu rather than the whole domain.
        var edgeRate: Double
        /// Whether `.unknown` slots appear. The wire coders refuse to encode
        /// them.
        var unknownSlots: Bool
    }

    /// The schema kinds that hold other schemas.
    enum CompositeKind: Sendable, CaseIterable {
        case optional, array, map, structure, enumeration, union
    }

    /// A generator that broke its own contract: a reference it made did not
    /// resolve, or a valid date failed to build.
    struct GeneratorFault: Error, CustomStringConvertible {
        let description: String
    }

    enum SchemaValueGenerators {
        /// Names from a small pool, so duplicates, numerals (which the wire
        /// coders' integer-key rule treats apart), a union value's own member
        /// names and canonically equal spellings (`é` precomposed and
        /// decomposed) come up, or any text.
        static let names: Gen<String> = .oneOf(
            .element(of: [
                "a", "b", "case", "fields", "0", "5", "05", "\u{E9}", "e\u{301}", "",
            ]),
            .string()
        )

        /// A value from the edge menu at `rate`, from the whole domain
        /// otherwise.
        static func edged<Value: Sendable>(
            _ edges: [Value],
            _ domain: Gen<Value>,
            rate: Double
        ) -> Gen<Value> {
            Gen { tc in
                try tc.draw(.bool(probability: rate))
                    ? try tc.draw(.element(of: edges)) : try tc.draw(domain)
            }
        }

        static let int64Edges: [Int64] = [0, 1, -1, .min, .max]

        static let uint64Edges: [UInt64] = [
            0, 1, UInt64(Int64.max), UInt64(Int64.max) + 1, .max,
        ]

        /// Doubles at the edges of the format, NaN and the infinities
        /// included.
        static let doubleEdges: [Double] = [
            0, -0.0, .nan, .infinity, -.infinity, .leastNonzeroMagnitude,
            .greatestFiniteMagnitude, 9_007_199_254_740_992,
        ]

        /// A float slot holds a `Float`: the same edges at single precision.
        static let floatEdges: [Float] = [
            0, -0.0, .nan, .infinity, -.infinity, .leastNonzeroMagnitude,
            .greatestFiniteMagnitude, 16_777_216,
        ]

        static func int64s(edgeRate: Double) -> Gen<Int64> {
            edged(int64Edges, .integer(), rate: edgeRate)
        }

        static func uint64s(edgeRate: Double) -> Gen<UInt64> {
            edged(uint64Edges, .integer(), rate: edgeRate)
        }

        static func doubles(edgeRate: Double) -> Gen<Double> {
            edged(doubleEdges, .double(), rate: edgeRate)
        }

        static func floats(edgeRate: Double) -> Gen<Float> {
            edged(floatEdges, .float(), rate: edgeRate)
        }

        /// Map keys as text: any string, or an integer in its canonical
        /// decimal form, which is what the dynamic decoder renders. An
        /// unsigned key stays at or under `Int64.max`: `validated` reads map
        /// keys as `Int64`, and a `CodingKey`'s integer is an `Int`.
        static func mapKeys(_ keySchema: TypeSchema, edgeRate: Double) -> Gen<String> {
            switch keySchema {
                case .int:
                    return int64s(edgeRate: edgeRate).map { String($0) }
                case .uint:
                    return edged(
                        [0, 1, UInt64(Int64.max)],
                        .integer(in: 0...UInt64(Int64.max)),
                        rate: edgeRate
                    )
                    .map { String($0) }
                default:
                    return names
            }
        }

        static let looseScalars: Gen<SchemaValue> = .oneOf(
            .just(.null),
            Gen<Bool>.bool().map { .bool($0) },
            int64s(edgeRate: 0.5).map { .int($0) },
            uint64s(edgeRate: 0.5).map { .uint($0) },
            doubles(edgeRate: 0.5).map { .double($0) },
            names.map { .string($0) },
            Gen<[UInt8]>.bytes().map { .bytes($0) }
        )

        /// Any tree at all, for an `.unknown` slot, which takes whatever it
        /// is given: duplicate member names included.
        static let looseValues: Gen<SchemaValue> = .recursive(
            maxDepth: 3,
            maxLeaves: 8,
            leaf: looseScalars
        ) { tree in
            .oneOf(
                Gen<[SchemaValue]>.array(of: tree, count: 0...3).map { .array($0) },
                Gen<[SchemaValue.Member]>.array(
                    of: Hegel.zip(names, tree).map { SchemaValue.Member($0, $1) },
                    count: 0...3
                )
                .map { .object($0) }
            )
        }

        static func policies(unknownSlots: Bool) -> Gen<SchemaValuePolicy> {
            Gen { tc in
                SchemaValuePolicy(
                    definitionCount: try tc.draw(
                        Gen<Int>.oneOf(.int(in: 0...4), .element(of: [0, 1, 4]))
                    ),
                    shadowedDefinition: try tc.draw(.bool()),
                    structureRoot: try tc.draw(.bool(probability: 0.75)),
                    schemaDepth: try tc.draw(.int(in: 0...4)),
                    composites: try CompositeKind.allCases.filter { _ in
                        try tc.draw(.bool(probability: 0.6))
                    },
                    referenceRate: try tc.draw(.element(of: [0.0, 0.25, 0.75])),
                    optionalFieldRate: try tc.draw(.element(of: [0.0, 0.5, 1.0])),
                    // Each count is then drawn from zero up, so empty
                    // structures, arrays and maps still come up.
                    maxMembers: try tc.draw(.int(in: 1...5)),
                    valueDepth: try tc.draw(.int(in: 1...5)),
                    maxItems: try tc.draw(.int(in: 1...4)),
                    fillRate: try tc.draw(.element(of: [0.0, 0.5, 1.0])),
                    edgeRate: try tc.draw(.element(of: [0.1, 0.5, 0.9])),
                    unknownSlots: unknownSlots
                )
            }
        }

        /// A schema and its named types, then a canonical value that fits
        /// them, under the policy.
        static func fitting(_ policy: SchemaValuePolicy) -> Gen<FittingValue> {
            Gen { tc in
                let names = try SchemaDrawing.uniqueNames(
                    tc,
                    count: policy.definitionCount...policy.definitionCount
                )
                let drawing = SchemaDrawing(policy: policy, definitionNames: names)
                var definitions: [TypeDefinition] = []
                for index in names.indices {
                    definitions.append(
                        TypeDefinition(
                            name: names[index],
                            schema: try drawing.definitionBody(tc, index: index)
                        )
                    )
                }
                if policy.shadowedDefinition, !names.isEmpty {
                    let shadowed = names[try tc.draw(.int(in: 0..<names.count))]
                    definitions.append(
                        TypeDefinition(name: shadowed, schema: .enumeration(cases: []))
                    )
                }
                let schema: TypeSchema =
                    policy.structureRoot
                    ? .structure(
                        fields: try drawing.fields(
                            tc,
                            depth: policy.schemaDepth,
                            bound: names.count,
                            count: 1...max(1, policy.maxMembers)
                        )
                    )
                    : try drawing.schema(
                        tc,
                        depth: policy.schemaDepth,
                        required: true,
                        bound: names.count
                    )
                let values = ValueDrawing(policy: policy, table: DefinitionTable(definitions))
                return FittingValue(
                    schema: schema,
                    definitions: definitions,
                    value: try values.value(tc, for: schema, depth: policy.valueDepth)
                )
            }
        }

        /// A policy, then a fitting value under it.
        static func fittingValues(unknownSlots: Bool) -> Gen<FittingValue> {
            Gen { tc in try tc.draw(fitting(try tc.draw(policies(unknownSlots: unknownSlots)))) }
        }
    }

    /// Draws schemas in which every required position can hold a value.
    ///
    /// A required position (the root, a definition's body, a structure's or
    /// a union case's field) never draws an empty enumeration or union, and
    /// references only the definitions below `bound`: inside definition `i`
    /// that is the ones before it, so a chain of required positions always
    /// ends. A position that may stay empty (under an optional, an array or
    /// a map) references any definition, the one being defined included, and
    /// may draw an empty enumeration or union: that is where recursive types
    /// and slots only null or empty fits come from.
    struct SchemaDrawing: Sendable {
        let policy: SchemaValuePolicy
        let definitionNames: [String]

        enum BodyKind: Sendable {
            case structure, enumeration, union, chain
        }

        var leaves: [TypeSchema] {
            [.bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime, .timestamp]
                + (policy.unknownSlots ? [.unknown] : [])
        }

        /// A count drawn evenly from the range, not skewed short like a
        /// collection's own length, so wide structures come up as often as
        /// narrow ones.
        static func count(_ tc: TestCase, in range: ClosedRange<Int>) throws -> Int {
            try tc.draw(.int(in: range))
        }

        /// A number of names from the pool, made distinct by priming repeats:
        /// field, case and definition names are unique in real schemas.
        static func uniqueNames(_ tc: TestCase, count: ClosedRange<Int>) throws -> [String] {
            let count = try Self.count(tc, in: count)
            var unique: [String] = []
            for name in try tc.draw(.array(of: SchemaValueGenerators.names, count: count...count)) {
                var name = name
                while unique.contains(name) { name += "'" }
                unique.append(name)
            }
            return unique
        }

        func schema(_ tc: TestCase, depth: Int, required: Bool, bound: Int) throws -> TypeSchema {
            let referable = required ? bound : definitionNames.count
            if referable > 0, try tc.draw(.bool(probability: policy.referenceRate)) {
                return .reference(definitionNames[try tc.draw(.int(in: 0..<referable))])
            }
            // A leaf or one of the composite kinds on, alike: the fewer are
            // on, the more often each comes up.
            let kinds: [CompositeKind?] = [nil] + (depth > 0 ? policy.composites : [])
            guard let kind = try tc.draw(.element(of: kinds)) else {
                return try tc.draw(.element(of: leaves))
            }
            let all = definitionNames.count
            switch kind {
                case .optional:
                    return .optional(
                        try schema(tc, depth: depth - 1, required: false, bound: all)
                    )
                case .array:
                    return .array(try schema(tc, depth: depth - 1, required: false, bound: all))
                case .map:
                    return .map(
                        key: try tc.draw(.element(of: [.string, .int, .uint])),
                        value: try schema(tc, depth: depth - 1, required: false, bound: all)
                    )
                case .structure:
                    return .structure(fields: try fields(tc, depth: depth - 1, bound: bound))
                case .enumeration:
                    return .enumeration(
                        cases: try Self.uniqueNames(tc, count: caseCounts(required: required))
                            .map { TypeSchema.EnumCase(name: $0) }
                    )
                case .union:
                    return .union(
                        cases: try Self.uniqueNames(tc, count: caseCounts(required: required))
                            .map {
                                TypeSchema.UnionCase(
                                    name: $0,
                                    fields: try fields(tc, depth: depth - 1, bound: bound)
                                )
                            }
                    )
            }
        }

        func caseCounts(required: Bool) -> ClosedRange<Int> {
            required ? 1...max(1, policy.maxMembers) : 0...policy.maxMembers
        }

        /// A structure's fields: distinct names, every type a required
        /// position, and either no keys or integer keys counted up from a
        /// drawn first key, the edges of `Int` included.
        func fields(
            _ tc: TestCase,
            depth: Int,
            bound: Int,
            count: ClosedRange<Int>? = nil
        ) throws -> [TypeSchema.Field] {
            let names = try Self.uniqueNames(tc, count: count ?? 0...policy.maxMembers)
            let firstKey: Int? = try tc.draw(
                .optional(
                    Gen<Int>.oneOf(
                        .element(of: [0, 1, -1, .min, .max - policy.maxMembers]),
                        .int(in: -1_000...1_000)
                    )
                )
            )
            return try names.enumerated().map { offset, name in
                let optional = try tc.draw(.bool(probability: policy.optionalFieldRate))
                return TypeSchema.Field(
                    key: firstKey.map { $0 + offset },
                    name: name,
                    type: optional
                        ? .optional(
                            try schema(
                                tc,
                                depth: depth,
                                required: false,
                                bound: definitionNames.count
                            )
                        )
                        : try schema(tc, depth: depth, required: true, bound: bound)
                )
            }
        }

        /// What definition `index` names: a structure, an enumeration or a
        /// union, as declarations make, or a chain to an earlier definition.
        func definitionBody(_ tc: TestCase, index: Int) throws -> TypeSchema {
            let kinds: [BodyKind] =
                [.structure, .enumeration, .union] + (index > 0 ? [.chain] : [])
            let depth = policy.schemaDepth
            switch try tc.draw(.element(of: kinds)) {
                case .structure:
                    return .structure(fields: try fields(tc, depth: depth, bound: index))
                case .enumeration:
                    return .enumeration(
                        cases: try Self.uniqueNames(tc, count: caseCounts(required: true))
                            .map { TypeSchema.EnumCase(name: $0) }
                    )
                case .union:
                    return .union(
                        cases: try Self.uniqueNames(tc, count: caseCounts(required: true))
                            .map {
                                TypeSchema.UnionCase(
                                    name: $0,
                                    fields: try fields(tc, depth: depth, bound: index)
                                )
                            }
                    )
                case .chain:
                    return .reference(definitionNames[try tc.draw(.int(in: 0..<index))])
            }
        }
    }

    /// The named types as the wire contract reads them, the first of a
    /// name winning, with references followed to what they name. A model of
    /// the resolver's documented rule, kept apart from `TypeResolver` so the
    /// generator does not lean on the code under test.
    struct DefinitionTable: Sendable {
        let schemas: [String: TypeSchema]

        init(_ definitions: [TypeDefinition]) {
            var schemas: [String: TypeSchema] = [:]
            for definition in definitions where schemas[definition.name] == nil {
                schemas[definition.name] = definition.schema
            }
            self.schemas = schemas
        }

        /// The schema a reference chain ends at. The generator makes no
        /// dangling reference and no loop, so either is its own fault.
        func resolve(_ schema: TypeSchema) throws -> TypeSchema {
            var current = schema
            var followed = 0
            while case .reference(let name) = current {
                guard let named = schemas[name], followed <= schemas.count else {
                    throw GeneratorFault(description: "reference '\(name)' does not resolve")
                }
                current = named
                followed += 1
            }
            return current
        }

        /// Whether some value fits the schema: everything but an empty
        /// enumeration or union does, once references resolve.
        func holdsAValue(_ schema: TypeSchema) throws -> Bool {
            switch try resolve(schema) {
                case .enumeration(let cases): return !cases.isEmpty
                case .union(let cases): return !cases.isEmpty
                default: return true
            }
        }
    }

    /// Draws the canonical value for a schema: kinds exact, members in field
    /// order, a union's `fields` exactly when its case declares some.
    ///
    /// `depth` counts down one per level: a structure's or union case's
    /// fields, an array's items, a map's values. Past it every optional
    /// field is absent and every array and map empty, so a recursive type's
    /// value ends: every cycle through the definitions passes one of those,
    /// since a definition is a structure, an enumeration, a union or a chain
    /// to an earlier one. Required positions keep filling, which ends because
    /// a chain of them never meets the same definition twice; an optional
    /// slot that is not a field fills at any depth, since it is never on a
    /// cycle by itself.
    struct ValueDrawing: Sendable {
        let policy: SchemaValuePolicy
        let table: DefinitionTable

        func value(_ tc: TestCase, for schema: TypeSchema, depth: Int) throws -> SchemaValue {
            switch try table.resolve(schema) {
                case .optional(let wrapped):
                    guard try table.holdsAValue(wrapped), try filled(tc) else { return .null }
                    return try value(tc, for: wrapped, depth: depth)
                case .bool:
                    return .bool(try tc.draw(.bool()))
                case .int:
                    return .int(
                        try tc.draw(SchemaValueGenerators.int64s(edgeRate: policy.edgeRate))
                    )
                case .uint:
                    return .uint(
                        try tc.draw(SchemaValueGenerators.uint64s(edgeRate: policy.edgeRate))
                    )
                case .float:
                    return .double(
                        Double(try tc.draw(SchemaValueGenerators.floats(edgeRate: policy.edgeRate)))
                    )
                case .double:
                    return .double(
                        try tc.draw(SchemaValueGenerators.doubles(edgeRate: policy.edgeRate))
                    )
                case .string:
                    return .string(try tc.draw(SchemaValueGenerators.names))
                case .bytes:
                    return .bytes(try tc.draw(.bytes()))
                case .date:
                    return .string(try dateText(tc, as: .date))
                case .datetime:
                    return .string(try dateText(tc, as: .dateTime))
                case .timestamp:
                    return .string(try dateText(tc, as: .timestamp))
                case .array(let element):
                    guard depth > 0, try table.holdsAValue(element) else { return .array([]) }
                    let count = try SchemaDrawing.count(tc, in: 0...policy.maxItems)
                    return .array(
                        try tc.draw(
                            .array(
                                of: Gen { tc in try self.value(tc, for: element, depth: depth - 1)
                                },
                                count: count...count
                            )
                        )
                    )
                case .map(let keySchema, let valueSchema):
                    guard depth > 0, try table.holdsAValue(valueSchema) else {
                        return .object([])
                    }
                    let count = try SchemaDrawing.count(tc, in: 0...policy.maxItems)
                    let entries = try tc.draw(
                        .array(
                            of: Hegel.zip(
                                SchemaValueGenerators.mapKeys(
                                    keySchema,
                                    edgeRate: policy.edgeRate
                                ),
                                Gen { tc in
                                    try self.value(tc, for: valueSchema, depth: depth - 1)
                                }
                            ),
                            count: count...count
                        )
                    )
                    var members: [SchemaValue.Member] = []
                    for (key, value) in entries where !members.contains(where: { $0.name == key }) {
                        members.append(SchemaValue.Member(key, value))
                    }
                    return .object(members)
                case .structure(let fields):
                    return .object(try members(tc, fields, depth: depth))
                case .enumeration(let cases):
                    guard !cases.isEmpty else {
                        throw GeneratorFault(description: "a required empty enumeration")
                    }
                    return .string(cases[try tc.draw(.int(in: 0..<cases.count))].name)
                case .union(let cases):
                    guard !cases.isEmpty else {
                        throw GeneratorFault(description: "a required empty union")
                    }
                    let chosen = cases[try tc.draw(.int(in: 0..<cases.count))]
                    let tag = SchemaValue.Member("case", .string(chosen.name))
                    guard !chosen.fields.isEmpty else { return .object([tag]) }
                    return .object([
                        tag,
                        SchemaValue.Member(
                            "fields",
                            .object(try members(tc, chosen.fields, depth: depth))
                        ),
                    ])
                case .unknown:
                    return try tc.draw(SchemaValueGenerators.looseValues)
                case .reference(let name):
                    throw GeneratorFault(description: "reference '\(name)' was not followed")
            }
        }

        /// A structure's members in field order: every required field, and
        /// each optional one when it is drawn present, null or not.
        func members(_ tc: TestCase, _ fields: [TypeSchema.Field], depth: Int) throws
            -> [SchemaValue.Member]
        {
            var members: [SchemaValue.Member] = []
            for field in fields {
                if case .optional = field.type {
                    guard depth > 0, try filled(tc) else { continue }
                }
                members.append(
                    SchemaValue.Member(field.name, try value(tc, for: field.type, depth: depth - 1))
                )
            }
            return members
        }

        func filled(_ tc: TestCase) throws -> Bool {
            try tc.draw(.bool(probability: policy.fillRate))
        }

        /// A valid date of the kind in its canonical text, which is what the
        /// dynamic decoder renders.
        func dateText(_ tc: TestCase, as kind: DateKind) throws -> String {
            let fields = try tc.draw(DateGenerators.validFields)
            guard let value = dateValue(of: fields, as: kind) else {
                throw GeneratorFault(description: "valid fields \(fields) made no \(kind.rawValue)")
            }
            return value.description
        }
    }

    /// Whether two values are the same: strings and names by their UTF-8
    /// bytes, so a respelling shows, and doubles by bit pattern, so NaN
    /// matches NaN and −0 differs from 0, which `==` gets wrong both ways.
    func identical(_ left: SchemaValue, _ right: SchemaValue) -> Bool {
        switch (left, right) {
            case (.string(let a), .string(let b)):
                return a.utf8.elementsEqual(b.utf8)
            case (.double(let a), .double(let b)):
                return a.bitPattern == b.bitPattern
            case (.array(let a), .array(let b)):
                return a.count == b.count && zip(a, b).allSatisfy(identical)
            case (.object(let a), .object(let b)):
                return a.count == b.count
                    && zip(a, b).allSatisfy {
                        $0.name.utf8.elementsEqual($1.name.utf8) && identical($0.value, $1.value)
                    }
            default:
                return left == right
        }
    }

    /// What a fitting value exercises, for `tc.event`: each kind of slot it
    /// fills and the shapes around them, from absent and null optional
    /// fields to reference chains and a definition met inside itself.
    func reachLabels(of fitting: FittingValue) -> Set<String> {
        let table = DefinitionTable(fitting.definitions)
        var labels: Set<String> = []

        func keyKind(_ schema: TypeSchema) -> String {
            switch schema {
                case .int: return "integers"
                case .uint: return "unsigned integers"
                default: return "strings"
            }
        }

        func visit(_ value: SchemaValue, _ schema: TypeSchema, open: [String], depth: Int) {
            var open = open
            var current = schema
            var chain = 0
            while case .reference(let name) = current {
                if open.contains(name) { labels.insert("a definition inside itself") }
                open.append(name)
                chain += 1
                guard let named = table.schemas[name], chain <= table.schemas.count else {
                    labels.insert("an unresolved reference")
                    return
                }
                current = named
            }
            if chain > 1 { labels.insert("a reference chain") }
            if depth >= 4 { labels.insert("a value four levels deep") }
            switch (current, value) {
                case (.optional(let wrapped), .null):
                    let fits = (try? table.holdsAValue(wrapped)) ?? true
                    labels.insert(fits ? "null in an optional slot" : "null where only null fits")
                case (.optional(let wrapped), _):
                    if case .optional = wrapped { labels.insert("an optional of an optional") }
                    visit(value, wrapped, open: open, depth: depth)
                case (.bool, _): labels.insert("a bool")
                case (.int, _): labels.insert("an int")
                case (.uint, _): labels.insert("a uint")
                case (.float, .double(let number)):
                    labels.insert(number.isFinite ? "a float" : "a non-finite float")
                case (.double, .double(let number)):
                    labels.insert(number.isFinite ? "a double" : "a non-finite double")
                case (.string, _): labels.insert("a string")
                case (.bytes, _): labels.insert("bytes")
                case (.date, _): labels.insert("a date")
                case (.datetime, _): labels.insert("a datetime")
                case (.timestamp, _): labels.insert("a timestamp")
                case (.array(let element), .array(let items)):
                    if items.isEmpty {
                        let fits = (try? table.holdsAValue(element)) ?? true
                        labels.insert(fits ? "an empty array" : "an array only empty fits")
                    } else {
                        labels.insert("an array with items")
                    }
                    for item in items { visit(item, element, open: open, depth: depth + 1) }
                case (.map(let keySchema, let valueSchema), .object(let members)):
                    labels.insert(
                        members.isEmpty ? "an empty map" : "a map keyed by \(keyKind(keySchema))"
                    )
                    if members.contains(where: { $0.name.hasPrefix("-") }) {
                        labels.insert("a negative map key")
                    }
                    for member in members {
                        visit(member.value, valueSchema, open: open, depth: depth + 1)
                    }
                case (.structure(let fields), .object(let members)):
                    if fields.isEmpty { labels.insert("an empty structure") }
                    for field in fields {
                        guard let member = members.first(where: { $0.name == field.name }) else {
                            labels.insert("an optional field left out")
                            continue
                        }
                        if case .optional = field.type, case .null = member.value {
                            labels.insert("an optional field set to null")
                        }
                        visit(member.value, field.type, open: open, depth: depth + 1)
                    }
                case (.enumeration(let cases), .string(let name)):
                    labels.insert(
                        cases.first?.name == name
                            ? "the first enumeration case" : "a later enumeration case"
                    )
                case (.union(let cases), .object(let members)):
                    guard
                        case .string(let name)? = members.first(where: { $0.name == "case" })?.value,
                        let chosen = cases.first(where: { $0.name == name })
                    else {
                        labels.insert("a union value with no case")
                        return
                    }
                    if chosen.fields.isEmpty {
                        labels.insert("a union case without fields")
                    } else if let fields = members.first(where: { $0.name == "fields" }) {
                        labels.insert("a union case with fields")
                        visit(
                            fields.value,
                            .structure(fields: chosen.fields),
                            open: open,
                            depth: depth + 1
                        )
                    }
                case (.unknown, _):
                    labels.insert("an unknown slot")
                default:
                    labels.insert("a value its schema does not describe")
            }
        }

        visit(fitting.value, fitting.schema, open: [], depth: 0)
        return labels
    }

#endif
