// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import Testing

    @Suite("Constraint properties", .hegel)
    struct ConstraintProperties {
        /// A value that fits its schema's shape is accepted by
        /// `validated(checkingConstraints: true)` exactly when every
        /// constraint on every value in it holds, and otherwise refused with
        /// the path of the first value that breaks one and the rule it
        /// broke. First means validation order: a structure's fields in
        /// declaration order, array items by index, map entries as they
        /// come, the values inside a value before its own rules, and a chain
        /// of named scalars outermost first. Without `checkingConstraints`
        /// the value is accepted whatever its constraints say.
        ///
        /// The schemas are the schema value generators' (every kind,
        /// references, recursive types, unions), mostly held in a structure
        /// beside probe fields of the kinds rules apply to, with constraints
        /// drawn for the fields that take them and scalars sometimes moved
        /// behind a chain of named scalars.
        @Test
        func validationAcceptsExactlyTheValuesThatKeepTheirConstraints() throws {
            try property(
                reaching: ["a checked value kept its constraints", "refused"],
                reachingAfter: [
                    "accepted after checking constraints": 1_000,
                    "refused by a named scalar": 1_000,
                    "refused by the inner named scalar of a chain": 1_000,
                    "refused inside an array": 1_000,
                    "refused inside a map": 1_000,
                    "refused inside a union case": 1_000,
                    "refused two levels down": 1_000,
                    "refused by a later field while an earlier one holds": 1_000,
                ]
            ) { tc in
                let policy = try #draw(SchemaValueGenerators.policies(unknownSlots: true), from: tc)
                let fitting = try #draw(SchemaValueGenerators.fitting(policy), from: tc)
                var root = (schema: fitting.schema, value: fitting.value)
                if try #draw(.bool(probability: 0.9), from: tc) {
                    let focus = try #draw(.element(of: ConstraintProbe.scalarKinds), from: tc)
                    let probes = try #draw(
                        .array(of: ConstraintProbe.probes(edgeRate: policy.edgeRate, focus: focus), count: 1...3),
                        from: tc)
                    let position = try #draw(.int(in: 0...probes.count), from: tc)
                    var fields = probes.enumerated().map { index, probe in
                        TypeSchema.Field(key: nil, name: "probe\(index)", type: probe.schema)
                    }
                    var members = probes.enumerated().map { index, probe in
                        SchemaValue.Member("probe\(index)", probe.value)
                    }
                    fields.insert(TypeSchema.Field(key: nil, name: "value", type: fitting.schema), at: position)
                    members.insert(SchemaValue.Member("value", fitting.value), at: position)
                    root = (.structure(fields: fields), .object(members))
                }
                try Self.checkDecorated(
                    tc, root.schema, root.value, definitions: fitting.definitions,
                    constraintRates: [0.25, 0.6, 1.0], ruleRates: [0.15, 0.4, 0.7], aliasRates: [0.0, 0.3, 0.7])
            }
        }

        /// Each rule refuses exactly the values on its wrong side, worded as
        /// documented: a range on int, uint and floating-point values (NaN
        /// keeping none) and on durations (compared to the attosecond, and
        /// named by their canonical text whatever text they came in), a
        /// length on strings (in Unicode scalars), bytes,
        /// arrays and maps, and a pattern matched against the whole string.
        /// The same check as above, over structures of one to three
        /// constrained fields of one kind, so every rule meets values on
        /// both sides of its bounds in many cases.
        @Test
        func everyRuleRefusesTheValuesOnItsWrongSide() throws {
            try property(
                reaching: ["a checked value kept its constraints", "refused"],
                reachingAfter: [
                    "accepted after checking constraints": 1_000,
                    "refused by a range on an int": 1_000,
                    "refused by a range on a uint": 1_000,
                    "refused by a range on a double": 1_000,
                    "refused by a range on a duration": 1_000,
                    "refused for not being a number": 1_000,
                    "refused by a length on a string": 1_000,
                    "refused by a pattern": 1_000,
                    "refused by a length on bytes": 1_000,
                    "refused by a length on an array": 1_000,
                    "refused by a length on a map": 1_000,
                ]
            ) { tc in
                let edgeRate = try #draw(.element(of: [0.1, 0.5, 0.9]), from: tc)
                let kind = try #draw(.element(of: ConstraintProbe.ruleKinds), from: tc)
                let probes = try #draw(
                    .array(of: ConstraintProbe.probes(of: kind, edgeRate: edgeRate), count: 1...3), from: tc)
                let schema = TypeSchema.structure(
                    fields: probes.enumerated().map { index, probe in
                        TypeSchema.Field(key: nil, name: "probe\(index)", type: probe.schema)
                    })
                let value = SchemaValue.object(
                    probes.enumerated().map { index, probe in SchemaValue.Member("probe\(index)", probe.value) })
                try Self.checkDecorated(
                    tc, schema, value, definitions: [], constraintRates: [1], ruleRates: [0.4, 0.7],
                    aliasRates: [0.0, 0.2])
            }
        }

        /// Adds drawn constraints and named scalars to `undecorated` and
        /// `definitions`, then checks `value` against them: refused with the
        /// model's first violation, or accepted unchanged when there is
        /// none, and accepted whatever its constraints say when they are not
        /// checked.
        private static func checkDecorated(
            _ tc: TestCase, _ undecorated: TypeSchema, _ value: SchemaValue, definitions: [TypeDefinition],
            constraintRates: [Double], ruleRates: [Double], aliasRates: [Double]
        ) throws {
            var decorator = ConstraintDecorator(
                definitions: definitions,
                constraintRate: try #draw(.element(of: constraintRates), from: tc),
                ruleRate: try #draw(.element(of: ruleRates), from: tc),
                aliasRate: try #draw(.element(of: aliasRates), from: tc)
            )
            let schema = try decorator.decorate(tc, undecorated)
            try decorator.decorateDefinitions(tc)
            let resolver = TypeResolver(decorator.definitions)
            var model = ConstraintModel(decorator.definitions)
            let expected = model.firstViolation(value, schema, path: "")
            for label in model.labels(for: expected).sorted() {
                try tc.event(label)
            }
            if model.kept > 0 {
                try tc.event("a checked value kept its constraints")
            }
            if expected == nil, model.checks > 0 {
                try tc.event("accepted after checking constraints")
            }
            switch value.validated(against: schema, resolver: resolver, checkingConstraints: true) {
                case .success(let canonical):
                    #expect(expected == nil, "accepted a value that breaks \(expected!)")
                    #expect(identical(canonical, value), "validated changed it to \(canonical)")
                case .failure(let error):
                    #expect(error == expected, "refused the value with \(error)")
            }
            if case .failure(let error) = value.validated(against: schema, resolver: resolver) {
                Issue.record("refused without checking constraints: \(error)")
            }
        }
    }

    extension TypeSchema.Bound {
        /// The bound as Swift prints its number, `5`, `0.5`, `1.0`, or as a
        /// duration's canonical text.
        fileprivate var text: String {
            switch self {
                case .integer(let value): "\(value)"
                case .floating(let value): "\(value)"
                case .duration(let value): canonicalDurationText(of: value.duration.attoseconds)
            }
        }

        /// The bound as a real number; NaN for a duration, which no number
        /// is compared with.
        fileprivate var real: Double {
            switch self {
                case .integer(let value): Double(value)
                case .floating(let value): value
                case .duration: .nan
            }
        }

        /// Whether this bound lies above `other`, exactly for two integers
        /// and two durations.
        fileprivate func isMore(than other: Self) -> Bool {
            if case .integer(let value) = self, case .integer(let otherValue) = other {
                return value > otherValue
            }
            if let value = self.attoseconds, let otherValue = other.attoseconds {
                return value > otherValue
            }
            return self.real > other.real
        }
    }

    /// Patterns whose meaning the model states without regular expressions:
    /// each holds for the strings its predicate accepts, compared by
    /// `Character` as Swift's `Regex` matches by default.
    let modelPatterns: [(pattern: String, matches: @Sendable (String) -> Bool)] = [
        ("a", { $0 == "a" }),
        ("", { $0.isEmpty }),
        ("[a-z]*", { $0.allSatisfy { ("a"..."z").contains($0) } }),
        ("[0-9]+", { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }),
        ("(case|fields)", { $0 == "case" || $0 == "fields" }),
        ("[^a]*", { !$0.contains("a") }),
    ]

    /// A field's schema and a value that fits it, of a kind a rule applies
    /// to: a scalar, or an array, a map or a union case holding one (or a
    /// structure of one field holding one), with values around the rules'
    /// menus.
    struct ConstraintProbe: Sendable {
        var schema: TypeSchema
        var value: SchemaValue

        /// The scalar kinds rules apply to, a string twice: it takes two
        /// kinds of rule, a length and a pattern.
        static let scalarKinds: [TypeSchema] = [
            .int, .uint, .double, .float, .duration, .string, .string, .bytes,
        ]

        /// Probes whose scalars are mostly of the `focus` kind, so a case
        /// meets that kind's rules many times.
        static func probes(edgeRate: Double, focus: TypeSchema) -> Gen<ConstraintProbe> {
            Gen { tc in
                var probe: ConstraintProbe
                switch try tc.draw(.int(in: 0...9)) {
                    case 0...2:
                        probe = try tc.draw(Self.scalars(edgeRate: edgeRate, focus: focus))
                    case 3...5:
                        let element = try tc.draw(Self.elements(edgeRate: edgeRate, focus: focus))
                        let more = try tc.draw(
                            .array(of: Self.values(of: element.schema, edgeRate: edgeRate), count: 0...4))
                        let items = try tc.draw(.bool(probability: 0.2)) ? [] : [element.value] + more
                        probe = ConstraintProbe(schema: .array(element.schema), value: .array(items))
                    case 6...8:
                        let entry = try tc.draw(Self.elements(edgeRate: edgeRate, focus: focus))
                        var members: [SchemaValue.Member] = []
                        let density = try tc.draw(.element(of: [0.2, 0.8]))
                        for key in ["b", "a", "d", "c", "e"] where try tc.draw(.bool(probability: density)) {
                            let value = try tc.draw(Self.values(of: entry.schema, edgeRate: edgeRate))
                            members.append(SchemaValue.Member(key, value))
                        }
                        probe = ConstraintProbe(
                            schema: .map(key: .string, value: entry.schema), value: .object(members))
                    default:
                        let field = try tc.draw(Self.scalars(edgeRate: edgeRate, focus: focus))
                        probe = ConstraintProbe(
                            schema: .union(cases: [
                                TypeSchema.UnionCase(
                                    name: "one", fields: [TypeSchema.Field(key: nil, name: "x", type: field.schema)])
                            ]),
                            value: .object([
                                SchemaValue.Member("case", .string("one")),
                                SchemaValue.Member("fields", .object([SchemaValue.Member("x", field.value)])),
                            ])
                        )
                }
                if try tc.draw(.bool(probability: 0.25)) {
                    probe.schema = .optional(probe.schema)
                    if try tc.draw(.bool(probability: 0.3)) { probe.value = .null }
                }
                return probe
            }
        }

        static func scalars(edgeRate: Double, focus: TypeSchema) -> Gen<ConstraintProbe> {
            Gen { tc in
                let schema =
                    try tc.draw(.bool(probability: 0.6)) ? focus : try tc.draw(.element(of: Self.scalarKinds))
                let value = try tc.draw(Self.values(of: schema, edgeRate: edgeRate))
                return ConstraintProbe(schema: schema, value: value)
            }
        }

        /// An array's element or a map's value: a scalar, or a structure
        /// whose one field holds one, so the field's own rules apply inside.
        static func elements(edgeRate: Double, focus: TypeSchema) -> Gen<ConstraintProbe> {
            Gen { tc in
                let scalar = try tc.draw(Self.scalars(edgeRate: edgeRate, focus: focus))
                guard try tc.draw(.bool()) else { return scalar }
                return ConstraintProbe(
                    schema: .structure(fields: [TypeSchema.Field(key: nil, name: "x", type: scalar.schema)]),
                    value: .object([SchemaValue.Member("x", scalar.value)])
                )
            }
        }

        /// The kinds whose rules `everyRuleRefusesTheValuesOnItsWrongSide`
        /// visits, one per case: a string twice, for its length and its
        /// pattern.
        static let ruleKinds: [TypeSchema] = [
            .int, .uint, .double, .float, .duration, .string, .string, .bytes, .array(.int),
            .map(key: .string, value: .int),
        ]

        /// A probe of exactly `kind`: a scalar, an array of zero to six
        /// items, or a map of sparse or dense entries.
        static func probes(of kind: TypeSchema, edgeRate: Double) -> Gen<ConstraintProbe> {
            Gen { tc in
                switch kind {
                    case .array(let element):
                        let items = try tc.draw(
                            .array(of: Self.values(of: element, edgeRate: edgeRate), count: 0...6))
                        return ConstraintProbe(schema: kind, value: .array(items))
                    case .map(_, let entry):
                        var members: [SchemaValue.Member] = []
                        let density = try tc.draw(.element(of: [0.2, 0.8]))
                        for key in ["b", "a", "d", "c", "e", "f"] where try tc.draw(.bool(probability: density)) {
                            members.append(
                                SchemaValue.Member(key, try tc.draw(Self.values(of: entry, edgeRate: edgeRate))))
                        }
                        return ConstraintProbe(schema: kind, value: .object(members))
                    default:
                        return ConstraintProbe(schema: kind, value: try tc.draw(Self.values(of: kind, edgeRate: edgeRate)))
                }
            }
        }

        /// Values of a probe's element kind: for a scalar, the generators'
        /// edges and whole domain, and small values on either side of the
        /// rules' small bounds. NaN, which keeps no range, is a third of
        /// the floating-point values. A duration is its canonical text or
        /// the same span in seconds alone, its fraction's 18 digits kept.
        static func values(of schema: TypeSchema, edgeRate: Double) -> Gen<SchemaValue> {
            let small: [Double] = [-1.5, -0.5, 0.25, 0.5, 1, 1.5]
            switch schema {
                case .structure(let fields):
                    return Self.values(of: fields[0].type, edgeRate: edgeRate)
                        .map { .object([SchemaValue.Member(fields[0].name, $0)]) }
                case .int:
                    return Gen<Int64>.oneOf(
                        SchemaValueGenerators.int64s(edgeRate: edgeRate), .integer(in: -3...3)
                    )
                    .map { .int($0) }
                case .uint:
                    return Gen<UInt64>.oneOf(
                        SchemaValueGenerators.uint64s(edgeRate: edgeRate), .integer(in: 0...3)
                    )
                    .map { .uint($0) }
                case .double:
                    return Gen<Double>.oneOf(
                        SchemaValueGenerators.doubles(edgeRate: edgeRate), .element(of: small),
                        .element(of: [.nan])
                    )
                    .map { .double($0) }
                case .float:
                    return Gen<Float>.oneOf(
                        SchemaValueGenerators.floats(edgeRate: edgeRate),
                        .element(of: small.map { Float($0) }), .element(of: [.nan])
                    )
                    .map { .double(Double($0)) }
                case .duration:
                    let attoseconds = Gen<Int128>.oneOf(
                        DurationGenerators.attoseconds,
                        .element(
                            of: ConstraintDecorator.durationEdges.flatMap {
                                [$0 &- 1, $0, $0 &+ 1]
                            }
                        )
                    )
                    return Gen { tc in
                        .string(
                            try tc.draw(DurationGenerators.spellings(of: try tc.draw(attoseconds)))
                        )
                    }
                case .string:
                    return Gen<String>.oneOf(
                        SchemaValueGenerators.names,
                        .element(of: ["", "a", "b", "ab", "abc", "case", "fields", "0", "12", "A"])
                    )
                    .map { .string($0) }
                default:
                    return Gen<[UInt8]>.bytes(count: 0...6).map { .bytes($0) }
            }
        }
    }

    /// Adds drawn constraints to a schema and its named types: to every
    /// field whose kind takes one, at `constraintRate`, and, at
    /// `aliasRate`, moves a scalar behind a new named scalar (or a chain of
    /// two) holding constraints of its own.
    struct ConstraintDecorator {
        var definitions: [TypeDefinition]
        let constraintRate: Double
        /// How often a constraint sets each bound or length it may.
        let ruleRate: Double
        let aliasRate: Double
        private var aliasCount = 0

        init(definitions: [TypeDefinition], constraintRate: Double, ruleRate: Double, aliasRate: Double) {
            self.definitions = definitions
            self.constraintRate = constraintRate
            self.ruleRate = ruleRate
            self.aliasRate = aliasRate
        }

        /// Minimums and maximums around the generators' integer edges, and
        /// wide ones the small values keep. A minimum leans low and a
        /// maximum high, as declared ranges do, so values land on either
        /// side.
        static let integerMinimums: [TypeSchema.Bound] = [
            .min, -100, -1, 0, 1, 2, Int64.max - 1, .max,
        ].map { .integer($0) }
        static let integerMaximums: [TypeSchema.Bound] = [
            .min, -1, 0, 1, 2, 100, Int64.max - 1, .max,
        ].map { .integer($0) }
        /// The same around the generators' double edges, integer bounds
        /// included.
        static let floatingMinimums: [TypeSchema.Bound] = [
            .floating(-.greatestFiniteMagnitude), .floating(-100), .floating(-1), .floating(0),
            .floating(0.5), .floating(9_007_199_254_740_992), .integer(-1), .integer(0),
        ]
        static let floatingMaximums: [TypeSchema.Bound] = [
            .floating(-1), .floating(0), .floating(0.5), .floating(1), .floating(100),
            .floating(9_007_199_254_740_992), .floating(.greatestFiniteMagnitude), .integer(1),
        ]
        /// Spans, in attoseconds, around the ends of `Duration` and the
        /// units a range is written in, each a duration bound and, with its
        /// neighbors, a duration value.
        static let durationEdges: [Int128] = [
            .min, -1_000_000_000_000_000_000, -1, 0, 1, 1_000_000_000, 500_000_000_000_000_000,
            1_000_000_000_000_000_000, 86_400_000_000_000_000_000_000, .max,
        ]
        /// The same as minimums and maximums, leaning low and high.
        static let durationMinimums: [TypeSchema.Bound] = durationEdges.dropLast(2).map {
            .duration(MMDuration(Duration(attoseconds: $0)))
        }
        static let durationMaximums: [TypeSchema.Bound] = durationEdges.dropFirst(2).map {
            .duration(MMDuration(Duration(attoseconds: $0)))
        }

        /// `schema` with constraints drawn for the fields in it, and each
        /// scalar in it (the root, an array's element, a map's value, a
        /// field) sometimes moved behind new named scalars.
        mutating func decorate(_ tc: TestCase, _ schema: TypeSchema) throws -> TypeSchema {
            switch schema {
                case .optional(let wrapped):
                    return .optional(try self.decorate(tc, wrapped))
                case .array(let element):
                    return .array(try self.decorate(tc, element))
                case .map(let key, let value):
                    return .map(key: key, value: try self.decorate(tc, value))
                case .structure(let fields):
                    return .structure(fields: try self.decorate(tc, fields))
                case .union(let cases):
                    return .union(
                        cases: try cases.map { unionCase in
                            TypeSchema.UnionCase(
                                name: unionCase.name,
                                fields: try self.decorate(tc, unionCase.fields)
                            )
                        })
                case .int, .uint, .float, .double, .duration, .string, .bytes:
                    guard try tc.draw(.bool(probability: self.aliasRate)) else { return schema }
                    return .reference(try self.alias(tc, of: schema))
                default:
                    return schema
            }
        }

        /// The named types with their composite bodies decorated. A scalar
        /// body, which only a map's key refers to, stays as it is: a key's
        /// named scalar is not checked.
        mutating func decorateDefinitions(_ tc: TestCase) throws {
            for index in self.definitions.indices {
                switch self.definitions[index].schema {
                    case .int, .uint, .float, .double, .duration, .string, .bytes:
                        continue
                    default:
                        let body = try self.decorate(tc, self.definitions[index].schema)
                        self.definitions[index].schema = body
                }
            }
        }

        private mutating func decorate(
            _ tc: TestCase, _ fields: [TypeSchema.Field]
        ) throws -> [TypeSchema.Field] {
            try fields.map { field in
                var decorated = field
                decorated.type = try self.decorate(tc, field.type)
                var kind = decorated.type
                while case .optional(let wrapped) = kind { kind = wrapped }
                if try tc.draw(.bool(probability: self.constraintRate)) {
                    decorated.constraints = try self.constraints(tc, for: kind)
                }
                return decorated
            }
        }

        /// A new named scalar of `kind` with constraints, sometimes behind a
        /// second one that adds its own.
        private mutating func alias(_ tc: TestCase, of kind: TypeSchema) throws -> String {
            self.aliasCount += 1
            let inner = "constrained.Inner\(self.aliasCount)"
            self.definitions.append(
                TypeDefinition(
                    name: inner, schema: kind, constraints: try self.constraints(tc, for: kind)))
            guard try tc.draw(.bool()) else { return inner }
            let outer = "constrained.Outer\(self.aliasCount)"
            // Sometimes only the inner name holds rules: the outer one's
            // are checked first and would otherwise decide most cases.
            let constraints = try tc.draw(.bool(probability: 0.6)) ? try self.constraints(tc, for: kind) : nil
            self.definitions.append(
                TypeDefinition(name: outer, schema: .reference(inner), constraints: constraints))
            return outer
        }

        /// Constraints that fit `kind`, or nil for a kind that takes none.
        func constraints(
            _ tc: TestCase, for kind: TypeSchema
        ) throws -> TypeSchema.Constraints? {
            var constraints = TypeSchema.Constraints()
            switch kind {
                case .int, .uint:
                    (constraints.minimum, constraints.maximum) = Self.ordered(
                        try self.bound(tc, from: Self.integerMinimums),
                        try self.bound(tc, from: Self.integerMaximums)
                    )
                case .float, .double:
                    (constraints.minimum, constraints.maximum) = Self.ordered(
                        try self.bound(tc, from: Self.floatingMinimums),
                        try self.bound(tc, from: Self.floatingMaximums)
                    )
                case .duration:
                    (constraints.minimum, constraints.maximum) = Self.ordered(
                        try self.bound(tc, from: Self.durationMinimums),
                        try self.bound(tc, from: Self.durationMaximums)
                    )
                case .string:
                    (constraints.minimumLength, constraints.maximumLength) = try self.lengths(tc)
                    if try tc.draw(.bool(probability: 0.6)) {
                        constraints.pattern = try tc.draw(.element(of: modelPatterns.map(\.pattern)))
                    }
                case .bytes, .array, .map:
                    (constraints.minimumLength, constraints.maximumLength) = try self.lengths(tc)
                default:
                    return nil
            }
            guard !constraints.isEmpty else { return nil }
            if let problem = constraints.problem(applyingTo: kind) {
                throw GeneratorFault(description: "drew constraints that do not fit: \(problem)")
            }
            return constraints
        }

        private func bound(
            _ tc: TestCase, from menu: [TypeSchema.Bound]
        ) throws -> TypeSchema.Bound? {
            try tc.draw(.bool(probability: self.ruleRate)) ? try tc.draw(.element(of: menu)) : nil
        }

        private static func ordered(
            _ first: TypeSchema.Bound?, _ second: TypeSchema.Bound?
        ) -> (TypeSchema.Bound?, TypeSchema.Bound?) {
            guard let first, let second else { return (first, second) }
            return first.isMore(than: second) ? (second, first) : (first, second)
        }

        private func lengths(_ tc: TestCase) throws -> (Int?, Int?) {
            let minimum = try tc.draw(.bool(probability: self.ruleRate)) ? try tc.draw(.int(in: 0...3)) : nil
            let maximum = try tc.draw(.bool(probability: self.ruleRate)) ? try tc.draw(.int(in: 0...6)) : nil
            if let minimum, let maximum, maximum < minimum { return (maximum, minimum) }
            return (minimum, maximum)
        }
    }

    /// The documented constraint rules, stated over `SchemaValue` without
    /// the code under test: the first value, in validation order, that
    /// breaks a constraint, with the rule it broke.
    struct ConstraintModel {
        /// The named types, the first of a name winning.
        let definitions: [String: TypeDefinition]
        /// What the last refusal passed through on its way down.
        private var passed: Set<String> = []
        private var refusedLabel = ""
        private var depth = 0
        private var refusedDepth = 0
        /// How many values the last search checked against constraints,
        /// and how many of those kept them.
        private(set) var checks = 0
        private(set) var kept = 0

        init(_ definitions: [TypeDefinition]) {
            var table: [String: TypeDefinition] = [:]
            for definition in definitions where table[definition.name] == nil {
                table[definition.name] = definition
            }
            self.definitions = table
        }

        mutating func firstViolation(
            _ value: SchemaValue, _ schema: TypeSchema, path: String
        ) -> SchemaValueError? {
            self.passed = []
            self.depth = 0
            self.refusedDepth = 0
            self.checks = 0
            self.kept = 0
            return self.violation(value, schema, path: path)
        }

        private mutating func violation(
            _ value: SchemaValue, _ schema: TypeSchema, path: String
        ) -> SchemaValueError? {
            switch schema {
                case .optional(let wrapped):
                    if case .null = value { return nil }
                    return self.violation(value, wrapped, path: path)
                case .reference:
                    // The chain's named scalars, outermost first, then the
                    // schema it ends at.
                    var chain: [TypeDefinition] = []
                    var current = schema
                    while case .reference(let name) = current, let definition = self.definitions[name],
                        !chain.contains(where: { $0.name == name })
                    {
                        chain.append(definition)
                        current = definition.schema
                    }
                    // A chain of names that never reaches a schema fits no
                    // value; the generators make none.
                    if case .reference = current { return nil }
                    if let inner = self.violation(value, current, path: path) { return inner }
                    for (index, definition) in chain.enumerated() {
                        if let constraints = definition.constraints,
                            let problem = self.problem(value, constraints)
                        {
                            self.passed.insert("a named scalar")
                            if index > 0 { self.passed.insert("the inner named scalar of a chain") }
                            return SchemaValueError(path: path, problem: problem)
                        }
                    }
                    return nil
                case .array(let element):
                    guard case .array(let items) = value else { return nil }
                    for (index, item) in items.enumerated() {
                        if let found = self.nested("an array", {
                            $0.violation(item, element, path: "\(path)[\(index)]")
                        }) {
                            return found
                        }
                    }
                    return nil
                case .map(_, let valueSchema):
                    guard case .object(let members) = value else { return nil }
                    for member in members {
                        if let found = self.nested("a map", {
                            $0.violation(member.value, valueSchema, path: Self.member(member.name, under: path))
                        }) {
                            return found
                        }
                    }
                    return nil
                case .structure(let fields):
                    guard case .object(let members) = value else { return nil }
                    return self.fields(fields, members, path: path)
                case .union(let cases):
                    guard case .object(let members) = value,
                        case .string(let name)? = members.first(where: { $0.name == "case" })?.value,
                        let unionCase = cases.first(where: { $0.name == name })
                    else { return nil }
                    var fieldMembers: [SchemaValue.Member] = []
                    if case .object(let given)? = members.first(where: { $0.name == "fields" })?.value {
                        fieldMembers = given
                    }
                    return self.nested("a union case") {
                        $0.fields(unionCase.fields, fieldMembers, path: Self.member("fields", under: path))
                    }
                default:
                    return nil
            }
        }

        private mutating func fields(
            _ fields: [TypeSchema.Field], _ members: [SchemaValue.Member], path: String
        ) -> SchemaValueError? {
            var held = false
            for field in fields {
                guard let member = members.first(where: { $0.name == field.name }) else { continue }
                let fieldPath = Self.member(field.name, under: path)
                if let found = self.nested(nil, { $0.violation(member.value, field.type, path: fieldPath) }) {
                    if held { self.passed.insert("a later field while an earlier one holds") }
                    return found
                }
                if let constraints = field.constraints, let problem = self.problem(member.value, constraints) {
                    if held { self.passed.insert("a later field while an earlier one holds") }
                    return SchemaValueError(path: fieldPath, problem: problem)
                }
                if field.constraints != nil { held = true }
            }
            return nil
        }

        /// `body` one level down, noting `container` when it finds a
        /// violation there.
        private mutating func nested(
            _ container: String?, _ body: (inout Self) -> SchemaValueError?
        ) -> SchemaValueError? {
            self.depth += 1
            defer { self.depth -= 1 }
            let found = body(&self)
            if found != nil {
                if let container { self.passed.insert("inside \(container)") }
                self.refusedDepth = max(self.refusedDepth, self.depth)
            }
            return found
        }

        private static func member(_ name: String, under path: String) -> String {
            path.isEmpty ? name : "\(path).\(name)"
        }

        /// Why `value` breaks `constraints`, worded as the rules are
        /// documented, or nil.
        private mutating func problem(
            _ value: SchemaValue, _ constraints: TypeSchema.Constraints
        ) -> String? {
            self.checks += 1
            let found = self.brokenRule(value, constraints)
            if found == nil { self.kept += 1 }
            return found
        }

        private mutating func brokenRule(
            _ value: SchemaValue, _ constraints: TypeSchema.Constraints
        ) -> String? {
            func range(_ text: String, below: (TypeSchema.Bound) -> Bool, above: (TypeSchema.Bound) -> Bool)
                -> String?
            {
                if let minimum = constraints.minimum, below(minimum) {
                    return "is \(text), less than the minimum \(minimum.text)"
                }
                if let maximum = constraints.maximum, above(maximum) {
                    return "is \(text), more than the maximum \(maximum.text)"
                }
                return nil
            }
            func length(_ count: Int, _ kind: String) -> String? {
                if let minimum = constraints.minimumLength, count < minimum {
                    self.refusedLabel = "refused by a length on \(kind)"
                    return "has length \(count), less than the minimum length \(minimum)"
                }
                if let maximum = constraints.maximumLength, count > maximum {
                    self.refusedLabel = "refused by a length on \(kind)"
                    return "has length \(count), more than the maximum length \(maximum)"
                }
                return nil
            }
            switch value {
                case .int(let number):
                    self.refusedLabel = "refused by a range on an int"
                    return range(
                        "\(number)",
                        below: {
                            switch $0 {
                                case .integer(let bound): number < bound
                                case .floating(let bound): Double(number) < bound
                                case .duration: false
                            }
                        },
                        above: {
                            switch $0 {
                                case .integer(let bound): number > bound
                                case .floating(let bound): Double(number) > bound
                                case .duration: false
                            }
                        })
                case .uint(let number):
                    self.refusedLabel = "refused by a range on a uint"
                    return range(
                        "\(number)",
                        below: {
                            switch $0 {
                                case .integer(let bound): bound > 0 && number < UInt64(bound)
                                case .floating(let bound): Double(number) < bound
                                case .duration: false
                            }
                        },
                        above: {
                            switch $0 {
                                case .integer(let bound): bound < 0 || number > UInt64(bound)
                                case .floating(let bound): Double(number) > bound
                                case .duration: false
                            }
                        })
                case .double(let number):
                    if number.isNaN, constraints.minimum != nil || constraints.maximum != nil {
                        self.refusedLabel = "refused for not being a number"
                        return "is not a number, outside every range"
                    }
                    self.refusedLabel = "refused by a range on a double"
                    return range(
                        "\(number)",
                        below: { number < $0.real },
                        above: { number > $0.real })
                case .string(let text)
                where constraints.minimum?.attoseconds != nil
                    || constraints.maximum?.attoseconds != nil:
                    // Duration bounds sit only on durations, whose text the
                    // schema already holds to the grammar.
                    guard case .success(let span) = modelDuration(text) else {
                        return "is \(text), no duration"
                    }
                    self.refusedLabel = "refused by a range on a duration"
                    return range(
                        canonicalDurationText(of: span),
                        below: { span < $0.attoseconds! },
                        above: { span > $0.attoseconds! }
                    )
                case .string(let text):
                    if let problem = length(text.unicodeScalars.count, "a string") { return problem }
                    if let pattern = constraints.pattern,
                        let model = modelPatterns.first(where: { $0.pattern == pattern }),
                        !model.matches(text)
                    {
                        self.refusedLabel = "refused by a pattern"
                        return "does not match the pattern \(pattern)"
                    }
                    return nil
                case .bytes(let bytes):
                    return length(bytes.count, "bytes")
                case .array(let items):
                    return length(items.count, "an array")
                case .object(let members):
                    return length(members.count, "a map")
                case .null, .bool:
                    return nil
            }
        }

        /// The reach labels for a case whose first violation is `found`.
        func labels(for found: SchemaValueError?) -> Set<String> {
            guard found != nil else { return [] }
            var labels: Set<String> = ["refused", self.refusedLabel]
            for passed in self.passed {
                labels.insert(passed.hasPrefix("inside") ? "refused \(passed)" : "refused by \(passed)")
            }
            if self.refusedDepth >= 2 { labels.insert("refused two levels down") }
            return labels
        }
    }

#endif
