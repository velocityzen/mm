// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import Testing

    @Suite("Constraint declaration properties", .hegel, .offTheCooperativePool)
    struct ConstraintDeclarationProperties {
        /// `#schema` refuses a field's `constraints:` list exactly when the
        /// runtime's rules refuse the constraints it declares on the field's
        /// kind, and for the same reason: a rule on a kind that does not
        /// take it, a fractional bound on an integer kind, a range or a
        /// length whose minimum passes its maximum, a negative length, a
        /// pattern that does not compile. Integer bounds on a floating kind
        /// become floating ones first, as both declare.
        @Test
        func theMacroRefusesTheConstraintsTheRuntimeRefuses() throws {
            try property(
                reaching: ["accepted", "refused"],
                reachingAfter: [
                    "refused: takes integer bounds": 1_000,
                    "refused: a range applies to": 1_000,
                    "refused: a length applies to": 1_000,
                    "refused: a pattern applies to": 1_000,
                    "refused: a range's minimum": 1_000,
                    "refused: a length's minimum": 1_000,
                    "refused: not negative": 1_000,
                    "refused: does not compile": 1_000,
                    "accepted: integer bounds on a floating kind": 1_000,
                ]
            ) { tc in
                // Mostly one rule drawn for the case on a kind that takes
                // it, so the rules' own bounds and patterns decide; else one
                // the kind does not take. Other rules join sometimes.
                let allRules = ["range", "length", "pattern"]
                let kind: DeclaredKind
                var declared: Set<String> = []
                if try #draw(.bool(probability: 0.8), from: tc) {
                    // A pattern applies to strings alone, so it is the focus
                    // half as often.
                    let focus = try #draw(.element(of: ["range", "range", "length", "length", "pattern"]), from: tc)
                    kind = try #draw(.element(of: DeclaredKind.all.filter { $0.takes.contains(focus) }), from: tc)
                    declared.insert(focus)
                    for rule in kind.takes.sorted() where try #draw(.bool(probability: 0.3), from: tc) {
                        declared.insert(rule)
                    }
                } else {
                    kind = try #draw(.element(of: DeclaredKind.all), from: tc)
                    declared.insert(try #draw(.element(of: allRules.filter { !kind.takes.contains($0) }), from: tc))
                    for rule in allRules where try #draw(.bool(probability: 0.25), from: tc) {
                        declared.insert(rule)
                    }
                }
                var rules: [DeclaredRule] = []
                if declared.contains("range") { rules.append(try #draw(DeclaredRule.ranges, from: tc)) }
                if declared.contains("length") { rules.append(try #draw(DeclaredRule.lengths, from: tc)) }
                if declared.contains("pattern") { rules.append(try #draw(DeclaredRule.patterns, from: tc)) }
                guard !rules.isEmpty else { return }
                rules = try #draw(.element(of: [rules, rules.reversed()]), from: tc)

                let constraints = declaredConstraints(rules, on: kind.schema)
                let problem = constraints.problem(applyingTo: kind.schema)
                let source = """
                    #schema("box") {
                        Call("put") {
                            Access(.write)
                            Request {
                                Field("f", \(kind.source), constraints: \(rules.map(\.source).joined(separator: ", ")))
                            }
                        }
                    }
                    """
                try tc.note(source)
                if let problem {
                    try tc.event("refused")
                    for fragment in [
                        "takes integer bounds", "a range applies to", "a length applies to",
                        "a pattern applies to", "a range's minimum", "a length's minimum", "not negative",
                        "does not compile",
                    ] where problem.contains(fragment) {
                        try tc.event("refused: \(fragment)")
                    }
                } else {
                    try tc.event("accepted")
                    if kind.floating, rules.contains(where: \.integerRange) {
                        try tc.event("accepted: integer bounds on a floating kind")
                    }
                }
                #expect(schemaDiagnosis(source) == problem.map { #"put.Request: Field("f"): \#($0)"# })
            }
        }

        /// `#schema` refuses an integer range on an integer kind exactly
        /// when its minimum passes its maximum, however close the two and
        /// however far from zero: the bounds compare as integers, never as
        /// the doubles that cannot tell neighbors apart past 2^53.
        @Test
        func theMacroComparesIntegerBoundsExactly() throws {
            try property(
                reaching: ["accepted", "refused"],
                reachingAfter: [
                    "refused: bounds one double holds": 1_000,
                    "accepted: bounds one double holds": 1_000,
                ]
            ) { tc in
                let kind = try #draw(
                    .element(of: DeclaredKind.all.filter { $0.takes.contains("range") && !$0.floating }), from: tc)
                let edgeRate = try #draw(.element(of: [0.1, 0.5]), from: tc)
                let minimum = try #draw(SchemaValueGenerators.int64s(edgeRate: edgeRate), from: tc)
                let step: Int64 = try #draw(.integer(in: -2...2), from: tc)
                let (sum, overflow) = minimum.addingReportingOverflow(step)
                let maximum = overflow ? minimum - step : sum
                let problem =
                    minimum > maximum ? "a range's minimum \(minimum) is more than its maximum \(maximum)" : nil
                let outcome = problem == nil ? "accepted" : "refused"
                try tc.event(outcome)
                if minimum != maximum, Double(minimum) == Double(maximum) {
                    try tc.event("\(outcome): bounds one double holds")
                }
                let source = """
                    #schema("box") {
                        Call("put") {
                            Access(.write)
                            Request {
                                Field("f", \(kind.source), constraints: .range(\(minimum)...\(maximum)))
                            }
                        }
                    }
                    """
                try tc.note(source)
                #expect(schemaDiagnosis(source) == problem.map { #"put.Request: Field("f"): \#($0)"# })
            }
        }
    }

    /// A field kind as `#schema` source and as the runtime's schema.
    struct DeclaredKind: Sendable {
        let source: String
        let schema: TypeSchema

        var floating: Bool {
            var kind = self.schema
            while case .optional(let wrapped) = kind { kind = wrapped }
            return kind == .float || kind == .double
        }

        /// The rules the kind takes.
        var takes: Set<String> {
            var kind = self.schema
            while case .optional(let wrapped) = kind { kind = wrapped }
            switch kind {
                case .int, .uint, .float, .double: return ["range"]
                case .string: return ["length", "pattern"]
                case .bytes, .array, .map: return ["length"]
                default: return []
            }
        }

        static let all: [DeclaredKind] = [
            DeclaredKind(source: ".int", schema: .int),
            DeclaredKind(source: ".uint", schema: .uint),
            DeclaredKind(source: ".float", schema: .float),
            DeclaredKind(source: ".double", schema: .double),
            DeclaredKind(source: ".string", schema: .string),
            DeclaredKind(source: ".bytes", schema: .bytes),
            DeclaredKind(source: ".bool", schema: .bool),
            DeclaredKind(source: ".date", schema: .date),
            DeclaredKind(source: ".array(.string)", schema: .array(.string)),
            DeclaredKind(source: ".map(key: .string, value: .int)", schema: .map(key: .string, value: .int)),
            DeclaredKind(source: ".optional(.int)", schema: .optional(.int)),
            DeclaredKind(source: ".optional(.float)", schema: .optional(.float)),
            DeclaredKind(source: ".optional(.double)", schema: .optional(.double)),
            DeclaredKind(source: ".optional(.string)", schema: .optional(.string)),
        ]
    }

    /// One rule as `#schema` source and as what it declares.
    struct DeclaredRule: Sendable {
        enum Rule: Sendable {
            case range(TypeSchema.Bound?, TypeSchema.Bound?)
            case length(Int?, Int?)
            case pattern(String)
        }

        let source: String
        let rule: Rule

        var integerRange: Bool {
            switch self.rule {
                case .range(.integer?, _), .range(_, .integer?): true
                default: false
            }
        }

        /// Ranges of integer or of floating bounds, closed or one-sided,
        /// either way round, around zero and the ends of `Int64`.
        static let ranges: Gen<DeclaredRule> = Gen { tc in
            let floating = try tc.draw(.bool())
            func bound() throws -> TypeSchema.Bound {
                floating
                    ? .floating(try tc.draw(.element(of: [-2.5, -0.0, 0, 0.5, 1, 1e300])))
                    : .integer(try tc.draw(.element(of: [Int64.min, -5, -1, 0, 1, 5, Int64.max - 1, .max])))
            }
            let (minimum, maximum): (TypeSchema.Bound?, TypeSchema.Bound?) =
                switch try tc.draw(.int(in: 0...4)) {
                    case 0...2: (try bound(), try bound())
                    case 3: (try bound(), nil)
                    default: (nil, try bound())
                }
            let source = ".range(\(minimum?.description ?? "")...\(maximum?.description ?? ""))"
            return DeclaredRule(source: source, rule: .range(minimum, maximum))
        }

        /// Lengths, closed or one-sided, either way round, negative ones
        /// among them, and `.nonEmpty`.
        static let lengths: Gen<DeclaredRule> = Gen { tc in
            if try tc.draw(.bool(probability: 0.15)) {
                return DeclaredRule(source: ".nonEmpty", rule: .length(1, nil))
            }
            func length() throws -> Int {
                try tc.draw(.bool(probability: 0.12)) ? -1 : try tc.draw(.int(in: 0...3))
            }
            let minimum = try length()
            let maximum = try length()
            switch try tc.draw(.int(in: 0...9)) {
                case 0...7: return DeclaredRule(source: ".length(\(minimum)...\(maximum))", rule: .length(minimum, maximum))
                case 8: return DeclaredRule(source: ".length(\(minimum)...)", rule: .length(minimum, nil))
                default: return DeclaredRule(source: ".length(...\(maximum))", rule: .length(nil, maximum))
            }
        }

        /// Patterns that compile and ones that do not.
        static let patterns: Gen<DeclaredRule> = Gen { tc in
            let pattern = try tc.draw(.element(of: ["[a-z]+", "a|b", "", "[a-", "(", "x{2,1}", #"\d+"#]))
            return DeclaredRule(source: ".pattern(#\"\(pattern)\"#)", rule: .pattern(pattern))
        }
    }

    /// The constraints `rules` declare on a value of `kind`, as both
    /// declarations combine them: integer bounds on a floating kind become
    /// floating ones, and -0.0 is 0.
    func declaredConstraints(_ rules: [DeclaredRule], on kind: TypeSchema) -> TypeSchema.Constraints {
        var unwrapped = kind
        while case .optional(let wrapped) = unwrapped { unwrapped = wrapped }
        let floating = unwrapped == .float || unwrapped == .double
        func bound(_ bound: TypeSchema.Bound?) -> TypeSchema.Bound? {
            switch bound {
                case .integer(let value) where floating: .floating(Double(value))
                case .floating(let value): .floating(value == 0 ? 0 : value)
                default: bound
            }
        }
        var constraints = TypeSchema.Constraints()
        for rule in rules {
            switch rule.rule {
                case .range(let minimum, let maximum):
                    constraints.minimum = bound(minimum)
                    constraints.maximum = bound(maximum)
                case .length(let minimum, let maximum):
                    constraints.minimumLength = minimum
                    constraints.maximumLength = maximum
                case .pattern(let pattern):
                    constraints.pattern = pattern
            }
        }
        return constraints
    }

#endif
