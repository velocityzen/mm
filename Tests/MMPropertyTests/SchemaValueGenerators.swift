// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import Foundation
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
        /// How many more named types a map's key schema can point at: an
        /// alias of `.string`, `.int` or `.uint`, an enumeration, or a chain
        /// to an earlier one.
        var keyDefinitionCount: Int
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
        /// Whether a float slot may hold any double, which `validated` keeps
        /// and a request narrows to `Float`, rather than only a `Float`'s
        /// value. Off unless a property turns it on.
        var doublesInFloatSlots = false
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
        /// names, canonically equal spellings (`é` precomposed and
        /// decomposed) and what JSON text must escape (a quote, a backslash
        /// and control characters) come up, or any text.
        static let names: Gen<String> = .oneOf(
            .element(of: [
                "a", "b", "case", "fields", "0", "5", "05", "\u{E9}", "e\u{301}", "",
                "\"\\/", "\u{0}\u{8}\t\n\u{C}\r\u{1F}\u{7F}",
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

        /// Unsigned integers at the ends of the range and either side of
        /// `Int64.max`, with 2^63 + 1, the first past it that a double
        /// cannot hold.
        static let uint64Edges: [UInt64] = [
            0, 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64(Int64.max) + 2, .max,
        ]

        /// Doubles at the edges of the format, NaN and the infinities
        /// included, and where whole doubles stop being exact integers
        /// (2^53) and stop fitting `Int64` (2^63).
        static let doubleEdges: [Double] = [
            0, -0.0, .nan, .infinity, -.infinity, .leastNonzeroMagnitude,
            .greatestFiniteMagnitude, 9_007_199_254_740_992, 0x1p63,
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

        /// Map keys as text for a resolved key schema: any string, an
        /// integer in its canonical decimal form, which is what the dynamic
        /// decoder renders, or an enumeration's case name. An unsigned key
        /// stays in `0...Int64.max`: a wire map key is a 64-bit signed
        /// integer, so `validated` refuses a negative key in an
        /// unsigned-keyed map and any key past `Int64`. The keys it refuses
        /// are `integerMapKeysPassExactlyWhenTheWireCarriesThem`'s.
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
                case .enumeration(let cases) where !cases.isEmpty:
                    return .element(of: cases.map(\.name))
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
                    keyDefinitionCount: try tc.draw(.int(in: 0...3)),
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
                let keyNames = try SchemaDrawing.uniqueNames(
                    tc,
                    count: policy.keyDefinitionCount...policy.keyDefinitionCount,
                    avoiding: names
                )
                let drawing = SchemaDrawing(
                    policy: policy,
                    definitionNames: names,
                    keyDefinitionNames: keyNames
                )
                var definitions: [TypeDefinition] = []
                for index in names.indices {
                    definitions.append(
                        TypeDefinition(
                            name: names[index],
                            schema: try drawing.definitionBody(tc, index: index)
                        )
                    )
                }
                for index in keyNames.indices {
                    definitions.append(
                        TypeDefinition(
                            name: keyNames[index],
                            schema: try drawing.keyDefinitionBody(tc, index: index)
                        )
                    )
                }
                let named = names + keyNames
                if policy.shadowedDefinition, !named.isEmpty {
                    let shadowed = named[try tc.draw(.int(in: 0..<named.count))]
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
        /// The definitions a map's key schema may reference, each one a key
        /// kind: see ``keyDefinitionBody(_:index:)``.
        var keyDefinitionNames: [String] = []

        enum BodyKind: Sendable {
            case structure, enumeration, union, chain
        }

        var leaves: [TypeSchema] {
            [
                .bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime, .timestamp,
                .duration, .uuid,
            ]
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
        static func uniqueNames(
            _ tc: TestCase,
            count: ClosedRange<Int>,
            avoiding taken: [String] = []
        ) throws -> [String] {
            let count = try Self.count(tc, in: count)
            var unique: [String] = []
            for name in try tc.draw(.array(of: SchemaValueGenerators.names, count: count...count)) {
                var name = name
                while unique.contains(name) || taken.contains(name) { name += "'" }
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
                    // A key kind written out, or as often a key definition
                    // when there is one.
                    let written: Gen<TypeSchema> = .element(of: [.string, .int, .uint])
                    return .map(
                        key: try tc.draw(
                            keyDefinitionNames.isEmpty
                                ? written
                                : .oneOf(
                                    written,
                                    .element(of: keyDefinitionNames.map { .reference($0) })
                                )
                        ),
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

        /// What key definition `index` names: an alias of `.string`, `.int`
        /// or `.uint`, an enumeration of one case or more, whose case names
        /// are the map's keys (twice as often as each alias), or a chain to
        /// an earlier key definition.
        func keyDefinitionBody(_ tc: TestCase, index: Int) throws -> TypeSchema {
            switch try tc.draw(.int(in: 0...(index > 0 ? 5 : 4))) {
                case 0: return .string
                case 1: return .int
                case 2: return .uint
                case 3, 4:
                    return .enumeration(
                        cases: try Self.uniqueNames(tc, count: caseCounts(required: true))
                            .map { TypeSchema.EnumCase(name: $0) }
                    )
                default:
                    return .reference(keyDefinitionNames[try tc.draw(.int(in: 0..<index))])
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
                    if policy.doublesInFloatSlots, try tc.draw(.bool()) {
                        return .double(
                            try tc.draw(SchemaValueGenerators.doubles(edgeRate: policy.edgeRate))
                        )
                    }
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
                case .duration:
                    return .string(try tc.draw(DurationGenerators.durations).description)
                case .uuid:
                    return .string(try tc.draw(UUIDGenerators.uuids).description)
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
                    let resolvedKey = try table.resolve(keySchema)
                    guard depth > 0, try table.holdsAValue(valueSchema),
                        resolvedKey != .enumeration(cases: [])
                    else {
                        return .object([])
                    }
                    let count = try SchemaDrawing.count(tc, in: 0...policy.maxItems)
                    let entries = try tc.draw(
                        .array(
                            of: Hegel.zip(
                                SchemaValueGenerators.mapKeys(
                                    resolvedKey,
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
            switch (try? table.resolve(schema)) ?? schema {
                case .int: return "integers"
                case .uint: return "unsigned integers"
                case .enumeration: return "enumeration cases"
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
                case (.duration, _): labels.insert("a duration")
                case (.uuid, _): labels.insert("a uuid")
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
                    if !members.isEmpty, case .reference = keySchema {
                        labels.insert("a map keyed by reference")
                    }
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

    /// Repeats a member of an integer-keyed map under another spelling of
    /// its key, with a fresh value: `{"5": a}` becomes `{"5": a, "05": b}`.
    /// Each spelling is a valid key, and both name wire key 5.
    ///
    /// The non-empty integer-keyed maps are numbered as the walk meets them,
    /// and only the `target`th gets a repeated member. With no target the
    /// walk draws nothing and only counts them in `eligible`, so a first
    /// pass can count and a second pass can pick one evenly.
    struct IntegerKeyRepeater {
        let values: ValueDrawing
        let target: Int?
        var eligible = 0

        mutating func repeating(_ tc: TestCase, _ value: SchemaValue, _ schema: TypeSchema)
            throws -> SchemaValue
        {
            switch (try values.table.resolve(schema), value) {
                case (.optional, .null):
                    return value
                case (.optional(let wrapped), _):
                    return try repeating(tc, value, wrapped)
                case (.array(let element), .array(let items)):
                    return .array(try items.map { try repeating(tc, $0, element) })
                case (.map(let keySchema, let valueSchema), .object(let members)):
                    var result = try members.map {
                        SchemaValue.Member($0.name, try repeating(tc, $0.value, valueSchema))
                    }
                    switch try values.table.resolve(keySchema) {
                        case .int, .uint: break
                        default: return .object(result)
                    }
                    guard !members.isEmpty else { return .object(result) }
                    let index = eligible
                    eligible += 1
                    guard index == target else { return .object(result) }
                    let key = members[try tc.draw(.int(in: 0..<members.count))].name
                    let spelling =
                        key.hasPrefix("-")
                        ? "-0" + key.dropFirst()
                        : try tc.draw(.element(of: ["+" + key, "0" + key]))
                    result.append(
                        SchemaValue.Member(
                            spelling,
                            try values.value(tc, for: valueSchema, depth: 1)
                        )
                    )
                    return .object(result)
                case (.structure(let fields), .object(let members)):
                    return .object(
                        try members.map { member in
                            guard let field = fields.first(where: { $0.name == member.name })
                            else { return member }
                            return SchemaValue.Member(
                                member.name,
                                try repeating(tc, member.value, field.type)
                            )
                        }
                    )
                case (.union(let cases), .object(let members)):
                    guard
                        case .string(let name)? = members.first(where: { $0.name == "case" })?
                            .value,
                        let chosen = cases.first(where: { $0.name == name })
                    else { return value }
                    return .object(
                        try members.map { member in
                            guard member.name == "fields" else { return member }
                            return SchemaValue.Member(
                                member.name,
                                try repeating(tc, member.value, .structure(fields: chosen.fields))
                            )
                        }
                    )
                default:
                    return value
            }
        }
    }

    /// A value as a user might write it, and the canonical value
    /// `validated` should make of it.
    struct LooseValue: Sendable {
        var loose: SchemaValue
        var expected: SchemaValue
    }

    /// Rewrites a canonical value into loose forms `validated` takes: a
    /// number in another kind that holds it exactly, bytes as base64 with or
    /// without padding, structure and union members out of order, a union's
    /// `fields` left out when nothing in it is present or given empty for a
    /// case without fields, and an integer map key respelled (`+5`, `05`,
    /// `-0`). Each eligible position is rewritten at `rate`.
    ///
    /// The expected value is the canonical one, except that a respelled map
    /// key keeps its spelling: `validated` checks map keys and leaves them
    /// as written. Base64 comes from Foundation, not from MMSchema's own
    /// encoder, so a decoding bug can't hide behind a matching encoding one.
    struct Loosener {
        let table: DefinitionTable
        let rate: Double
        var labels: Set<String> = []

        init(table: DefinitionTable, rate: Double) {
            self.table = table
            self.rate = rate
        }

        mutating func loosen(_ tc: TestCase, _ value: SchemaValue, _ schema: TypeSchema) throws
            -> LooseValue
        {
            switch (try table.resolve(schema), value) {
                case (.optional, .null):
                    return LooseValue(loose: .null, expected: .null)
                case (.optional(let wrapped), _):
                    return try loosen(tc, value, wrapped)
                case (.int, .int(let number)):
                    var forms: [(String, SchemaValue)] = []
                    if let unsigned = UInt64(exactly: number) {
                        forms.append(("an int given as a uint", .uint(unsigned)))
                    }
                    if let double = Double(exactly: number) {
                        forms.append(("an int given as a double", .double(double)))
                    }
                    return LooseValue(loose: try pick(tc, value, forms), expected: value)
                case (.uint, .uint(let number)):
                    var forms: [(String, SchemaValue)] = []
                    if let signed = Int64(exactly: number) {
                        forms.append(("a uint given as an int", .int(signed)))
                    }
                    if let double = Double(exactly: number) {
                        forms.append(("a uint given as a double", .double(double)))
                    }
                    return LooseValue(loose: try pick(tc, value, forms), expected: value)
                case (.float, .double(let number)), (.double, .double(let number)):
                    // Only a form that converts back to the same bits: −0
                    // as an integer would come back as +0.
                    var forms: [(String, SchemaValue)] = []
                    if let signed = Int64(exactly: number),
                        Double(signed).bitPattern == number.bitPattern
                    {
                        forms.append(("a double given as an int", .int(signed)))
                    }
                    if let unsigned = UInt64(exactly: number),
                        Double(unsigned).bitPattern == number.bitPattern
                    {
                        forms.append(("a double given as a uint", .uint(unsigned)))
                    }
                    return LooseValue(loose: try pick(tc, value, forms), expected: value)
                case (.bytes, .bytes(let bytes)):
                    let padded = Data(bytes).base64EncodedString()
                    var forms: [(String, SchemaValue)] = [
                        ("bytes given as base64", .string(padded))
                    ]
                    if padded.hasSuffix("=") {
                        forms.append(
                            (
                                "bytes given as unpadded base64",
                                .string(String(padded.filter { $0 != "=" }))
                            )
                        )
                    }
                    return LooseValue(loose: try pick(tc, value, forms), expected: value)
                case (.array(let element), .array(let items)):
                    var loose: [SchemaValue] = []
                    var expected: [SchemaValue] = []
                    for item in items {
                        let rewritten = try loosen(tc, item, element)
                        loose.append(rewritten.loose)
                        expected.append(rewritten.expected)
                    }
                    return LooseValue(loose: .array(loose), expected: .array(expected))
                case (.map(let keySchema, let valueSchema), .object(let members)):
                    var rewritten: [SchemaValue.Member] = []
                    var expected: [SchemaValue.Member] = []
                    for member in members {
                        let name = try respelled(tc, member.name, keySchema)
                        let entry = try loosen(tc, member.value, valueSchema)
                        rewritten.append(SchemaValue.Member(name, entry.loose))
                        expected.append(SchemaValue.Member(name, entry.expected))
                    }
                    return LooseValue(loose: .object(rewritten), expected: .object(expected))
                case (.structure(let fields), .object(let members)):
                    return try loosenStructure(tc, members, fields)
                case (.union(let cases), .object(let members)):
                    guard
                        case .string(let name)? = members.first(where: { $0.name == "case" })?.value,
                        let chosen = cases.first(where: { $0.name == name })
                    else {
                        throw GeneratorFault(description: "a union value with no known case")
                    }
                    let tag = SchemaValue.Member("case", .string(name))
                    var loose = [tag]
                    var expected = [tag]
                    if case .object(let fieldMembers)? = members.first(where: {
                        $0.name == "fields"
                    })?.value {
                        let fields = try loosenStructure(tc, fieldMembers, chosen.fields)
                        expected.append(SchemaValue.Member("fields", fields.expected))
                        if fieldMembers.isEmpty, try tc.draw(.bool(probability: rate)) {
                            labels.insert("union fields left out")
                        } else {
                            loose.append(SchemaValue.Member("fields", fields.loose))
                        }
                    } else if try tc.draw(.bool(probability: rate)) {
                        labels.insert("union fields given for a case without any")
                        loose.append(SchemaValue.Member("fields", .object([])))
                    }
                    return LooseValue(
                        loose: .object(
                            try shuffled(tc, loose, label: "union members out of order")
                        ),
                        expected: .object(expected)
                    )
                default:
                    return LooseValue(loose: value, expected: value)
            }
        }

        mutating func loosenStructure(
            _ tc: TestCase,
            _ members: [SchemaValue.Member],
            _ fields: [TypeSchema.Field]
        ) throws -> LooseValue {
            var loose: [SchemaValue.Member] = []
            var expected: [SchemaValue.Member] = []
            for member in members {
                guard let field = fields.first(where: { $0.name == member.name }) else {
                    throw GeneratorFault(description: "member '\(member.name)' has no field")
                }
                let rewritten = try loosen(tc, member.value, field.type)
                loose.append(SchemaValue.Member(member.name, rewritten.loose))
                expected.append(SchemaValue.Member(member.name, rewritten.expected))
            }
            return LooseValue(
                loose: .object(try shuffled(tc, loose, label: "members out of order")),
                expected: .object(expected)
            )
        }

        /// One of the forms at `rate`, the value itself otherwise.
        mutating func pick(
            _ tc: TestCase,
            _ value: SchemaValue,
            _ forms: [(String, SchemaValue)]
        ) throws -> SchemaValue {
            guard !forms.isEmpty, try tc.draw(.bool(probability: rate)) else { return value }
            let (label, form) = forms[try tc.draw(.int(in: 0..<forms.count))]
            labels.insert(label)
            return form
        }

        /// An integer map key written another way that reads as the same
        /// number: a plus sign, a leading zero, or `-0`.
        mutating func respelled(_ tc: TestCase, _ key: String, _ keySchema: TypeSchema) throws
            -> String
        {
            switch try table.resolve(keySchema) {
                case .int, .uint:
                    guard try tc.draw(.bool(probability: rate)) else { return key }
                    labels.insert("a respelled map key")
                    if key.hasPrefix("-") { return "-0" + key.dropFirst() }
                    return try tc.draw(.element(of: ["+" + key, "0" + key]))
                default:
                    return key
            }
        }

        /// The members in a drawn order at `rate`.
        mutating func shuffled(
            _ tc: TestCase,
            _ members: [SchemaValue.Member],
            label: String
        ) throws -> [SchemaValue.Member] {
            guard members.count > 1, try tc.draw(.bool(probability: rate)) else { return members }
            var order = members
            for index in stride(from: order.count - 1, to: 0, by: -1) {
                order.swapAt(index, try tc.draw(.int(in: 0...index)))
            }
            if zip(order, members).contains(where: { $0.name != $1.name }) { labels.insert(label) }
            return order
        }
    }

    /// How many nodes a value has: itself, and every item and member value
    /// below it.
    func nodeCount(_ value: SchemaValue) -> Int {
        switch value {
            case .array(let items): return 1 + items.map(nodeCount).reduce(0, +)
            case .object(let members): return 1 + members.map { nodeCount($0.value) }.reduce(0, +)
            default: return 1
        }
    }

    /// The value with its node at `target`, counted in pre-order, replaced.
    func replacing(_ value: SchemaValue, at target: Int, with replacement: SchemaValue)
        -> SchemaValue
    {
        var index = 0
        func rebuild(_ value: SchemaValue) -> SchemaValue {
            let here = index
            index += 1
            if here == target { return replacement }
            switch value {
                case .array(let items):
                    return .array(items.map(rebuild))
                case .object(let members):
                    return .object(members.map { SchemaValue.Member($0.name, rebuild($0.value)) })
                default:
                    return value
            }
        }
        return rebuild(value)
    }

    /// The node at `target`, counted in pre-order as `replacing` counts.
    func node(of value: SchemaValue, at target: Int) -> SchemaValue? {
        var flat: [SchemaValue] = []
        func flatten(_ value: SchemaValue) {
            flat.append(value)
            switch value {
                case .array(let items): items.forEach(flatten)
                case .object(let members): members.forEach { flatten($0.value) }
                default: break
            }
        }
        flatten(value)
        return flat.indices.contains(target) ? flat[target] : nil
    }

    extension SchemaValueGenerators {
        /// Text a bytes slot may or may not take as base64: well formed,
        /// unpadded, a lone character, padding in the wrong place, a
        /// character outside the alphabet, or any text.
        static let base64Texts: Gen<String> = .oneOf(
            .element(of: [
                "", "AA==", "AAA=", "AA", "A", "A=", "=", "A===", "AAAA====", "!!!!", "AA AA",
            ]),
            Gen<[UInt8]>.bytes().map { Data($0).base64EncodedString() },
            names
        )

        /// A value close to `value`: the same number in another kind,
        /// exact or not, as text, or moved by a step; bytes as any text and
        /// text as bytes; a member dropped, repeated or added; an item
        /// dropped or repeated; null, or an empty container. Some fit the
        /// slot `value` came from and some don't, which is the point.
        static func nearby(_ value: SchemaValue) -> Gen<SchemaValue> {
            var forms: [Gen<SchemaValue>] = [.element(of: [.null, .object([]), .array([])])]
            switch value {
                case .int(let number):
                    forms += [
                        .just(.uint(UInt64(bitPattern: number))),
                        .just(.double(Double(number))),
                        .just(.double(Double(number) + 0.5)),
                        .just(.string(String(number))),
                    ]
                case .uint(let number):
                    forms += [
                        .just(.int(Int64(bitPattern: number))),
                        .just(.double(Double(number))),
                        .just(.string(String(number))),
                    ]
                case .double(let number):
                    let whole = number.isFinite ? number.rounded(.towardZero) : 0
                    forms += [
                        .just(.int(Int64(exactly: whole) ?? 0)),
                        .just(.uint(UInt64(exactly: whole) ?? 0)),
                        .just(.double(number.nextUp)),
                        .just(.string(String(number))),
                    ]
                case .bytes(let bytes):
                    forms += [
                        base64Texts.map { .string($0) },
                        .just(.array(bytes.map { .uint(UInt64($0)) })),
                    ]
                case .string(let text):
                    forms += [
                        .just(.bytes(Array(text.utf8))),
                        .just(.string(text + "x")),
                        base64Texts.map { .string($0) },
                    ]
                case .bool(let flag):
                    forms += [.just(.int(flag ? 1 : 0)), .just(.string(String(flag)))]
                case .array(let items) where !items.isEmpty:
                    forms += [
                        Gen<Int>.int(in: 0..<items.count).map { index in
                            var fewer = items
                            fewer.remove(at: index)
                            return .array(fewer)
                        },
                        Gen<Int>.int(in: 0..<items.count).map { .array(items + [items[$0]]) },
                    ]
                case .object(let members) where !members.isEmpty:
                    forms += [
                        Gen<Int>.int(in: 0..<members.count).map { index in
                            var fewer = members
                            fewer.remove(at: index)
                            return .object(fewer)
                        },
                        Gen<Int>.int(in: 0..<members.count).map {
                            .object(members + [members[$0]])
                        },
                        Hegel.zip(names, looseScalars).map {
                            .object(members + [SchemaValue.Member($0, $1)])
                        },
                    ]
                default:
                    break
            }
            return .oneOf(forms)
        }
    }

#endif
