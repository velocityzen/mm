// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMCLI
    import MMSchema
    import MMWire
    import Testing

    @Suite("Dynamic coding properties", .hegel, .offTheCooperativePool)
    struct DynamicCodingProperties {
        /// A request built from `--params` sends the canonical form of its
        /// input, and the response decoder reads it back as that value: an
        /// explicit null in an optional field left out, a float slot narrowed
        /// to `Float`, integer map keys in canonical decimal, and map members
        /// sorted by key. The request refuses exactly what `validated`
        /// refuses and anything filling an `.unknown` slot, and refuses a
        /// root that is not a structure; such a root is sent wrapped in one.
        ///
        /// The input is a fitting value in loose forms, sometimes with one
        /// node replaced by something close to it or by any tree, and
        /// sometimes with an integer-keyed map member repeated under
        /// another spelling of its key, which `validated` must refuse: both
        /// spellings are one wire key, and the decoder keeps one entry.
        ///
        /// Mutation check: `validated` taking two spellings of one integer
        /// key; the request sending a float slot as a double, integer map
        /// keys as text, a uint as an int or a date as text, never sending
        /// a union's fields, taking a root that is not a structure, or
        /// letting an unknown slot inside an array through; or the decoder
        /// sorting map keys backwards, reading `fields` for a union case
        /// without any, or reading a null array item as a value, fails
        /// here. A 100-case run catches most of them, a 1,000-case run all
        /// but the unknown slot inside an array, and the nightly 10,000
        /// that one too.
        @Test
        func requestsDecodeToTheCanonicalValue() throws {
            try property(
                reaching: [
                    "an optional field left out", "sent and read back",
                    "validated refuses the input",
                ],
                reachingAfter: [
                    "a bool": 1_000, "a date": 1_000, "a datetime": 1_000,
                    "a definition inside itself": 1_000, "a double": 1_000, "a float": 1_000,
                    "a later enumeration case": 1_000, "a map keyed by integers": 1_000,
                    "a map keyed by reference": 1_000, "a map keyed by strings": 1_000,
                    "a map keyed by unsigned integers": 1_000, "a negative map key": 1_000,
                    "a reference chain": 1_000, "a respelled map key": 1_000,
                    "a root that is not a structure": 1_000, "a string": 1_000,
                    "a timestamp": 1_000, "a duration": 1_000, "a uint": 1_000, "a uuid": 1_000,
                    "a union case with fields": 1_000,
                    "a union case without fields": 1_000, "a value four levels deep": 1_000,
                    "an array with items": 1_000, "an empty array": 1_000, "an empty map": 1_000,
                    "an empty structure": 1_000, "an explicit null left out": 1_000,
                    "an int": 1_000, "an int given as a double": 1_000,
                    "an optional field set to null": 1_000, "an optional of an optional": 1_000,
                    "bytes": 1_000, "members out of order": 1_000,
                    "null in an optional slot": 1_000, "one node replaced": 1_000,
                    "the first enumeration case": 1_000, "union members out of order": 1_000,
                ]
            ) { tc in
                let unknownSlots = try #draw(Gen<Bool>.bool(probability: 0.4), from: tc)
                var policy = try #draw(
                    SchemaValueGenerators.policies(unknownSlots: unknownSlots),
                    from: tc
                )
                policy.doublesInFloatSlots = try #draw(Gen<Bool>.bool(), from: tc)
                // A quarter of the cases are about maps, whose keys the round
                // trip rewrites and sorts, and a quarter about arrays, whose
                // null and unknown items it must carry or refuse: that kind
                // and optionals the only composites, every field present,
                // and room to nest and to hold several items.
                if try #draw(Gen<Bool>.bool(), from: tc) {
                    let mapFocus = try #draw(Gen<Bool>.bool(), from: tc)
                    policy.composites = [mapFocus ? .map : .array, .optional]
                    policy.optionalFieldRate = 0
                    policy.schemaDepth = max(policy.schemaDepth, 2)
                    policy.valueDepth = max(policy.valueDepth, 3)
                    policy.maxItems = max(policy.maxItems, 3)
                }
                let fitting = try #draw(SchemaValueGenerators.fitting(policy), from: tc)
                let table = DefinitionTable(fitting.definitions)
                var schema = fitting.schema
                var value = fitting.value
                let structureRoot =
                    if case .structure = try table.resolve(schema) { true } else { false }
                if !structureRoot {
                    try tc.event("a root that is not a structure")
                    #expect(
                        throws: (any Error).self,
                        "a request took a root that is not a structure"
                    ) {
                        _ = try MMCLIDynamicRequest(
                            schema: schema,
                            definitions: fitting.definitions,
                            json: value
                        )
                    }
                    schema = .structure(fields: [
                        TypeSchema.Field(key: nil, name: "value", type: schema)
                    ])
                    value = .object([SchemaValue.Member("value", value)])
                }
                for label in reachLabels(
                    of: FittingValue(schema: schema, definitions: fitting.definitions, value: value)
                )
                .sorted() {
                    try tc.event(label)
                }

                let values = ValueDrawing(policy: policy, table: table)
                var counter = IntegerKeyRepeater(values: values, target: nil)
                _ = try counter.repeating(tc, value, schema)
                var repeated = value
                if counter.eligible > 0, try #draw(Gen<Bool>.bool(probability: 0.3), from: tc) {
                    try tc.event("an integer key spelled twice")
                    var repeater = IntegerKeyRepeater(
                        values: values,
                        target: try #draw(Gen<Int>.int(in: 0..<counter.eligible), from: tc)
                    )
                    repeated = try repeater.repeating(tc, value, schema)
                }

                let looseRate = try #draw(Gen<Double>.element(of: [0, 0.5, 1.0]), from: tc)
                var loosener = Loosener(table: table, rate: looseRate)
                var input = try loosener.loosen(tc, repeated, schema).loose
                for label in loosener.labels.sorted() {
                    try tc.event(label)
                }
                if try #draw(Gen<Bool>.bool(probability: 0.25), from: tc) {
                    try tc.event("one node replaced")
                    let count = nodeCount(input)
                    let position = try #draw(
                        Gen<Int>.int(in: (count > 1 ? 1 : 0)..<count),
                        from: tc
                    )
                    let replacement = try #draw(
                        Gen<SchemaValue>.oneOf(
                            SchemaValueGenerators.nearby(node(of: input, at: position) ?? .null),
                            SchemaValueGenerators.looseValues
                        ),
                        from: tc
                    )
                    input = replacing(input, at: position, with: replacement)
                }

                var echo = Echo(table: table)
                let expected: SchemaValue?
                switch input.validated(against: schema, resolver: fitting.resolver) {
                    case .failure:
                        try tc.event("validated refuses the input")
                        expected = nil
                    case .success(let canonical):
                        expected = try echo.echoed(canonical, as: schema)
                        if expected == nil { try tc.event("the input fills an unknown slot") }
                }
                for label in echo.labels.sorted() {
                    try tc.event(label)
                }
                let request = Result {
                    try MMCLIDynamicRequest(
                        schema: schema,
                        definitions: fitting.definitions,
                        json: input
                    )
                }
                switch (request, expected) {
                    case (.failure, nil):
                        break
                    case (.success, nil):
                        Issue.record("the request took \(input), which it cannot send")
                    case (.failure(let error), .some):
                        Issue.record("the request refused \(input): \(error)")
                    case (.success(let request), .some(let expected)):
                        try tc.event("sent and read back")
                        let bytes = try MMPackEncoder().encode(request).get()
                        let response = try MMCLIDynamicResponse.$schema.withValue(
                            (schema, fitting.definitions)
                        ) {
                            try MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes).get()
                        }
                        #expect(
                            identical(response.tree, expected),
                            "\(input) was read back as \(response.tree), not \(expected)"
                        )
                }
            }
        }

        /// An integer map key passes `validated` exactly when the wire
        /// carries it, and the request then sends the integer the key
        /// names. A wire map key is a 64-bit signed integer, so an
        /// unsigned-keyed map refuses a negative key, and every
        /// integer-keyed map refuses a key past 64 bits as out of range
        /// rather than as no integer at all. Two spellings of one integer
        /// are refused at the second, and a key refused for itself is no
        /// spelling of anything. `KeyReading` reads keys digit by digit,
        /// apart from `Int64(_:)`.
        ///
        /// The keys are integer text of any length, with or without a sign
        /// and leading zeros, at the edges of `Int64` and past them, or
        /// text that is close to an integer or not one at all, and now and
        /// then an earlier key again, as it was or respelled. The key
        /// schema is `.int` or `.uint` itself, or a reference to it, direct
        /// or through a chain, which `validated` resolves as the request
        /// does. A Swift peer reads the request into a dictionary keyed by
        /// `Int64` or `UInt64`, which its coder carries as a wire map.
        ///
        /// Mutation check: `validated` taking a negative key in an
        /// unsigned-keyed map, refusing zero in one, refusing negative keys
        /// in a signed-keyed map instead, calling a key past 64 bits no
        /// integer, reading a minus sign as part of the digits, counting a
        /// refused key as a repeat, or taking two spellings of one key,
        /// fails here. A 100-case run catches all but the refused key
        /// counted as a repeat, which needs a negative key spelled twice in
        /// an unsigned-keyed map (2–3% of cases), and a 1,000-case run
        /// catches that one too. So does `validated` checking a referenced
        /// key schema without resolving it, or the coder reading an integer
        /// key type's dictionary as `Codable`'s array of keys and values.
        @Test
        func integerMapKeysPassExactlyWhenTheWireCarriesThem() throws {
            try property(
                reaching: [
                    "a key schema by reference", "a key that is not an integer", "a uint-keyed map",
                    "accepted and sent", "an int-keyed map",
                ],
                reachingAfter: [
                    "a key at Int64.max": 1_000, "a key of 20 digits or more": 1_000,
                    "a key one past Int64.max": 1_000, "a leading zero": 1_000,
                    "a minus sign": 1_000, "a negative key in a uint-keyed map": 1_000,
                    "a negative key in an int-keyed map": 1_000, "a plus sign": 1_000,
                    "minus zero": 1_000, "refused for a repeated integer": 1_000,
                    "refused: duplicate key": 1_000,
                    "refused: key is negative, and the map's keys are unsigned": 1_000,
                    "refused: key is not an integer": 1_000,
                    "refused: key is out of range: a wire map key is a 64-bit signed integer":
                        1_000,
                ]
            ) { tc in
                // The key schema as written, or a reference to it, direct or
                // through a chain.
                let reference = try #draw(
                    Gen<String?>.element(of: [nil, "keys.Integer", "keys.Alias"]),
                    from: tc
                )
                let unsigned = try #draw(Gen<Bool>.bool(), from: tc)
                let keys = try #draw(KeyReading.mapKeys, from: tc)
                let definitions = [
                    TypeDefinition(name: "keys.Integer", schema: unsigned ? .uint : .int),
                    TypeDefinition(name: "keys.Alias", schema: .reference("keys.Integer")),
                ]
                let keySchema: TypeSchema =
                    reference.map { .reference($0) } ?? (unsigned ? .uint : .int)
                if case .reference = keySchema {
                    try tc.event("a key schema by reference")
                }
                let readings = keys.map { KeyReading($0.text, unsigned: unsigned) }
                let expected = KeyReading.verdict(of: readings)
                try tc.event(unsigned ? "a uint-keyed map" : "an int-keyed map")
                for label in Set(readings.flatMap(\.labels)).sorted() {
                    try tc.event(label)
                }
                try tc.event(expected.label)
                // A refused key spelled again is no repeat: the first
                // spelling is refused for itself.
                let negatives = readings.compactMap { reading -> Int64? in
                    if case .negative(let number) = reading.verdict { number } else { nil }
                }
                if Set(negatives).count < negatives.count {
                    try tc.event("a negative key spelled twice in a uint-keyed map")
                }

                let map = SchemaValue.object(
                    keys.map { SchemaValue.Member($0.text, .bool($0.flag)) }
                )
                let schema = TypeSchema.structure(fields: [
                    TypeSchema.Field(
                        key: nil,
                        name: "map",
                        type: .map(key: keySchema, value: .bool)
                    )
                ])
                let input = SchemaValue.object([SchemaValue.Member("map", map)])
                let request = Result {
                    try MMCLIDynamicRequest(schema: schema, definitions: definitions, json: input)
                }
                switch (
                    map.validated(
                        against: .map(key: keySchema, value: .bool),
                        resolver: TypeResolver(definitions)
                    ),
                    expected
                ) {
                    case (.failure(let error), .refused(let key, let problem)):
                        #expect(
                            error.path == key && error.problem == problem,
                            "\(keys.map(\.text)) refused as \(error), not at \(key): \(problem)"
                        )
                        #expect(throws: (any Error).self, "the request took \(keys.map(\.text))") {
                            try request.get()
                        }
                    case (.success, .refused(let key, let problem)):
                        Issue.record(
                            "validated took \(keys.map(\.text)), not refusing \(key): \(problem)"
                        )
                    case (.failure(let error), .accepted):
                        Issue.record("validated refused \(keys.map(\.text)): \(error)")
                    case (.success(let canonical), .accepted(let numbers)):
                        #expect(
                            identical(canonical, map),
                            "validated rewrote \(map) as \(canonical)"
                        )
                        let bytes = try MMPackEncoder().encode(try request.get()).get()
                        if unsigned {
                            let sent = try MMPackDecoder().decode(SentUnsignedMap.self, from: bytes)
                                .get()
                            let carried = Dictionary(
                                uniqueKeysWithValues: zip(
                                    try numbers.map { try #require(UInt64(exactly: $0)) },
                                    keys.map(\.flag)
                                )
                            )
                            #expect(
                                sent.map == carried,
                                "\(keys.map(\.text)) went out as \(sent.map)"
                            )
                        } else {
                            let sent = try MMPackDecoder().decode(SentMap.self, from: bytes).get()
                            let carried = Dictionary(
                                uniqueKeysWithValues: zip(numbers, keys.map(\.flag))
                            )
                            #expect(
                                sent.map == carried,
                                "\(keys.map(\.text)) went out as \(sent.map)"
                            )
                        }
                }
            }
        }

        /// The wire map a request built from `{"map": {...}}` sends, read by
        /// a Swift peer whose keys are `Int64`.
        struct SentMap: Decodable {
            let map: [Int64: Bool]
        }

        /// The same, with `UInt64` keys.
        struct SentUnsignedMap: Decodable {
            let map: [UInt64: Bool]
        }
    }

    /// An integer map key's text read the way a wire map key must be:
    /// worked out digit by digit, apart from `Int64(_:)`, as the wire
    /// integer it names, or why it names none.
    struct KeyReading {
        enum Verdict: Equatable {
            case number(Int64)
            case notAnInteger
            case outOfRange
            /// A negative integer in an unsigned-keyed map, which refuses it.
            case negative(Int64)
        }

        /// The map's verdict: the integers its keys name, or the key it is
        /// refused at, with the problem.
        enum MapVerdict {
            case accepted([Int64])
            case refused(key: String, problem: String)

            var label: String {
                switch self {
                    case .accepted: "accepted and sent"
                    case .refused(_, let problem) where problem.hasPrefix("duplicate key ("):
                        "refused for a repeated integer"
                    case .refused(_, let problem): "refused: \(problem)"
                }
            }
        }

        let text: String
        let verdict: Verdict
        let labels: [String]

        static let notAnInteger = "key is not an integer"
        static let outOfRange = "key is out of range: a wire map key is a 64-bit signed integer"
        static let negative = "key is negative, and the map's keys are unsigned"

        /// 2^63: `Int64.min`'s magnitude, one past `Int64.max`.
        static let twoToThe63: UInt64 = 1 << 63

        init(_ text: String, unsigned: Bool) {
            self.text = text
            var digits = Substring(text).utf8
            var minus = false
            var labels: [String] = []
            if let sign = digits.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                minus = sign == UInt8(ascii: "-")
                labels.append(minus ? "a minus sign" : "a plus sign")
                digits = digits.dropFirst()
            }
            guard !digits.isEmpty,
                digits.allSatisfy({ UInt8(ascii: "0") <= $0 && $0 <= UInt8(ascii: "9") })
            else {
                self.verdict = .notAnInteger
                self.labels = ["a key that is not an integer"]
                return
            }
            let significant = digits.drop { $0 == UInt8(ascii: "0") }
            if significant.count < digits.count, !significant.isEmpty {
                labels.append("a leading zero")
            }
            // Twenty digits are past 2^64 already; nineteen fit a UInt64.
            var magnitude: UInt64?
            if significant.count <= 19 {
                magnitude = significant.reduce(0) { $0 * 10 + UInt64($1 - UInt8(ascii: "0")) }
            }
            switch magnitude {
                case let magnitude? where minus && magnitude <= Self.twoToThe63:
                    let number = magnitude == Self.twoToThe63 ? Int64.min : -Int64(magnitude)
                    if number == .min { labels.append("a key at Int64.min") }
                    if magnitude == 0 { labels.append("minus zero") }
                    if unsigned && number < 0 {
                        self.verdict = .negative(number)
                        labels.append("a negative key in a uint-keyed map")
                    } else {
                        self.verdict = .number(number)
                        if number < 0 { labels.append("a negative key in an int-keyed map") }
                    }
                case let magnitude? where !minus && magnitude < Self.twoToThe63:
                    self.verdict = .number(Int64(magnitude))
                    if magnitude == UInt64(Int64.max) { labels.append("a key at Int64.max") }
                case let magnitude?:
                    self.verdict = .outOfRange
                    if magnitude == Self.twoToThe63 + (minus ? 1 : 0) {
                        labels.append(
                            minus ? "a key one below Int64.min" : "a key one past Int64.max"
                        )
                    } else {
                        labels.append("a key past Int64 in under 20 digits")
                    }
                case nil:
                    self.verdict = .outOfRange
                    labels.append("a key of 20 digits or more")
            }
            self.labels = labels
        }

        /// What `validated` must make of a map with these keys, in its
        /// order: a key spelled exactly as an earlier one, then a key that
        /// names the same integer as an earlier key it takes, then the
        /// first key it refuses for itself.
        static func verdict(of readings: [KeyReading]) -> MapVerdict {
            var texts: Set<String> = []
            for reading in readings where !texts.insert(reading.text).inserted {
                return .refused(key: reading.text, problem: "duplicate key")
            }
            var earlier: [Int64: String] = [:]
            for reading in readings {
                guard case .number(let number) = reading.verdict else { continue }
                if let first = earlier[number] {
                    return .refused(
                        key: reading.text,
                        problem: "duplicate key (the same integer as '\(first)')"
                    )
                }
                earlier[number] = reading.text
            }
            var numbers: [Int64] = []
            for reading in readings {
                switch reading.verdict {
                    case .number(let number): numbers.append(number)
                    case .notAnInteger: return .refused(key: reading.text, problem: notAnInteger)
                    case .outOfRange: return .refused(key: reading.text, problem: outOfRange)
                    case .negative: return .refused(key: reading.text, problem: negative)
                }
            }
            return .accepted(numbers)
        }

        /// Up to three keys, each with the value it maps to. A key is
        /// integer text, text close to an integer, or any text; one time in
        /// four after the first, it is an earlier key again, mostly with a
        /// zero after its sign, which reads as the same integer, else as it
        /// was. More repeats would crowd out the edge keys.
        static let mapKeys: Gen<[(text: String, flag: Bool)]> = Gen { tc in
            let count = try tc.draw(.int(in: 0...3))
            var keys: [(text: String, flag: Bool)] = []
            for _ in 0..<count {
                let flag = try tc.draw(.bool())
                if !keys.isEmpty, try tc.draw(.bool(probability: 0.25)) {
                    let earlier = keys[try tc.draw(.int(in: 0..<keys.count))].text
                    let respell = try tc.draw(.bool(probability: 0.75))
                    keys.append((respell ? withZeroAfterSign(earlier) : earlier, flag))
                } else {
                    keys.append((try tc.draw(texts), flag))
                }
            }
            return keys
        }

        static func withZeroAfterSign(_ text: String) -> String {
            guard let sign = text.first, sign == "+" || sign == "-" else { return "0" + text }
            return String(sign) + "0" + text.dropFirst()
        }

        /// A key from the edge menu two times in seven, other integer text
        /// three times, then text close to an integer, then any text.
        static let texts: Gen<String> = .oneOf(
            .element(of: edgeTexts),
            .element(of: edgeTexts),
            integerTexts,
            integerTexts,
            integerTexts,
            .element(of: [
                "", "+", "-", "+-1", "--1", " 1", "1 ", "1.0", "1e3", "0x10", "1_000",
                "\u{661}", "\u{FF15}", "1\u{301}",
            ]),
            SchemaValueGenerators.names
        )

        /// Zero in each spelling, and either side of each end of `Int64`
        /// and of the end of `UInt64`.
        static let edgeTexts = [
            "0", "-0", "+0", "1", "-1", "9223372036854775807", "-9223372036854775808",
            "9223372036854775808", "-9223372036854775809", "18446744073709551615",
            "18446744073709551616",
        ]

        /// A sign or none, a leading zero or none, and a magnitude: a small
        /// one, one up to `Int64.max`, one at the edges of `Int64` and
        /// `UInt64`, any `UInt64`, or one of 21 digits or more.
        static let integerTexts: Gen<String> = Gen { tc in
            let sign = try tc.draw(.element(of: ["", "", "+", "-"]))
            let zeros = try tc.draw(.element(of: ["", "", "0", "00"]))
            let magnitude = try tc.draw(
                Gen<String>.oneOf(
                    Gen<UInt64>.integer(in: 0...9).map { String($0) },
                    Gen<UInt64>.integer(in: 0...UInt64(Int64.max)).map { String($0) },
                    Gen<UInt64>.element(of: SchemaValueGenerators.uint64Edges).map { String($0) },
                    Gen<UInt64>.integer().map { String($0) },
                    Gen { tc in
                        let leading = try tc.draw(Gen<UInt64>.integer(in: 1...UInt64.max))
                        let trailing = try tc.draw(Gen<UInt64>.integer())
                        let padded = String(trailing)
                        return String(leading) + String(repeating: "0", count: 20 - padded.count)
                            + padded
                    }
                )
            )
            return sign + zeros + magnitude
        }
    }

    /// What the response decoder reads back for a canonical request value,
    /// or nil when the value fills an `.unknown` slot, which the request
    /// refuses to send.
    ///
    /// The request leaves out an optional field holding null, and the
    /// decoder leaves out an absent one. A float slot travels as a `Float`.
    /// An integer map key travels as its integer and comes back in
    /// canonical decimal. The wire map is unordered, so the decoder sorts
    /// map members: integer keys numerically, string keys by Swift's string
    /// ordering. Everything else comes back as it was sent, date text
    /// included, since `validated` only takes canonical date text that the
    /// generator writes.
    struct Echo {
        let table: DefinitionTable
        var labels: Set<String> = []

        mutating func echoed(_ value: SchemaValue, as schema: TypeSchema) throws -> SchemaValue? {
            switch (try table.resolve(schema), value) {
                case (.unknown, _):
                    return nil
                case (.optional, .null):
                    return .null
                case (.optional(let wrapped), _):
                    return try echoed(value, as: wrapped)
                case (.float, .double(let number)):
                    let narrowed = Double(Float(number))
                    if narrowed.bitPattern != number.bitPattern {
                        labels.insert("a float slot narrowed")
                    }
                    return .double(narrowed)
                case (.array(let element), .array(let items)):
                    var echoes: [SchemaValue] = []
                    for item in items {
                        guard let echo = try echoed(item, as: element) else {
                            labels.insert("an unknown slot in an array")
                            return nil
                        }
                        if case .null = echo { labels.insert("a null array item") }
                        echoes.append(echo)
                    }
                    return .array(echoes)
                case (.map(let keySchema, let valueSchema), .object(let members)):
                    var echoes: [SchemaValue.Member] = []
                    for member in members {
                        guard let echo = try echoed(member.value, as: valueSchema) else {
                            return nil
                        }
                        echoes.append(SchemaValue.Member(member.name, echo))
                    }
                    switch try table.resolve(keySchema) {
                        case .int, .uint: break
                        default:
                            let sorted = echoes.sorted { $0.name < $1.name }
                            if sorted.map(\.name) != echoes.map(\.name) {
                                labels.insert("string map keys sorted")
                            }
                            return .object(sorted)
                    }
                    var numbered: [(key: Int64, value: SchemaValue)] = []
                    for echo in echoes {
                        guard let key = Int64(echo.name) else {
                            throw GeneratorFault(
                                description: "validated took map key '\(echo.name)'"
                            )
                        }
                        if String(key) != echo.name {
                            labels.insert("an integer key respelled back")
                        }
                        numbered.append((key, echo.value))
                    }
                    let sorted = numbered.sorted { $0.key < $1.key }
                    if sorted.map(\.key) != numbered.map(\.key) {
                        labels.insert("integer map keys sorted")
                    }
                    return .object(sorted.map { SchemaValue.Member(String($0.key), $0.value) })
                case (.structure(let fields), .object(let members)):
                    var echoes: [SchemaValue.Member] = []
                    for field in fields {
                        guard let member = members.first(where: { $0.name == field.name }) else {
                            continue
                        }
                        if case .optional = field.type, case .null = member.value {
                            labels.insert("an explicit null left out")
                            continue
                        }
                        guard let echo = try echoed(member.value, as: field.type) else {
                            return nil
                        }
                        echoes.append(SchemaValue.Member(field.name, echo))
                    }
                    return .object(echoes)
                case (.union(let cases), .object(let members)):
                    guard
                        case .string(let name)? = members.first(where: { $0.name == "case" })?
                            .value,
                        let chosen = cases.first(where: { $0.name == name })
                    else {
                        throw GeneratorFault(description: "validated took union value \(value)")
                    }
                    let tag = SchemaValue.Member("case", .string(name))
                    guard !chosen.fields.isEmpty else { return .object([tag]) }
                    let fields = members.first(where: { $0.name == "fields" })?.value ?? .object([])
                    guard let echo = try echoed(fields, as: .structure(fields: chosen.fields))
                    else {
                        return nil
                    }
                    return .object([tag, SchemaValue.Member("fields", echo)])
                default:
                    return value
            }
        }
    }

#endif
