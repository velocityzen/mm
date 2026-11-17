// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMSchemaCodeGenerator
    import MMWire
    import NIOCore
    import SwiftParser
    import SwiftSyntax
    import Testing

    /// A record as the release before wire defaults declares it.
    enum FirstEdition: TypeNamespace {
        #schemaTypes("edition") {
            Type("Record") {
                Field("id", .int)
                Field("old", .optional(.string))
                Field("note", .optional(.string))
            }
        }
    }

    /// The same record a release later: `old` removed, its key and name
    /// reserved, and fields added with a wire default of every kind that
    /// takes one, one of them deprecated.
    enum SecondEdition: TypeNamespace {
        #schemaTypes("edition") {
            Enum("Level") {
                Case("low")
                Case("high")
            }
            Alias("Ratio", .double)
            Type("Record") {
                Field("id", .int)
                Reserved(1, "old")
                Field("note", .optional(.string))
                Field("limit", .int, default: 50)
                Field("count", .uint, default: 7)
                Field("score", .float, default: 0.5)
                Field("weight", .double, default: -2.5)
                Field("ratio", "Ratio", default: 1)
                Field("on", .bool, default: true)
                Field("tag", .string, default: "untitled")
                Field("level", "Level", default: "high")
                Field("label", .string, deprecated: "use tag", default: "none")
            }
        }
    }

    /// What a peer wrote under one field's key: nothing, a nil, or a value.
    enum Written<Value: Sendable>: Sendable {
        case absent
        case null
        case value(Value)

        var value: Value? {
            if case .value(let value) = self { value } else { nil }
        }

        var label: String {
            switch self {
                case .absent: "absent"
                case .null: "nil"
                case .value: "a value"
            }
        }
    }

    extension Written where Value: Encodable {
        /// The map entry this is under `key`, if any.
        func entry(key: Int) -> MapEntry? {
            switch self {
                case .absent: nil
                case .null: MapEntry(key: encodedBytes(key), value: [0xc0])
                case .value(let value): MapEntry(key: encodedBytes(key), value: encodedBytes(value))
            }
        }
    }

    /// The map a peer of either edition, or of one later still, wrote for a
    /// record: each field's key absent, holding nil or holding a value.
    struct WrittenRecord: Sendable {
        var id: Int
        var old: Written<String>
        var note: Written<String>
        var limit: Written<Int>
        var count: Written<UInt64>
        var score: Written<Float>
        var weight: Written<Double>
        var ratio: Written<Double>
        var on: Written<Bool>
        var tag: Written<String>
        var level: Written<SecondEdition.Level>
        var label: Written<String>
        /// Entries under keys only a later edition declares.
        var later: [MapEntry]

        /// The second edition's defaulted fields, by name, as written.
        var defaulted: [(name: String, written: String)] {
            [
                ("limit", limit.label), ("count", count.label), ("score", score.label),
                ("weight", weight.label), ("ratio", ratio.label), ("on", on.label),
                ("tag", tag.label), ("level", level.label), ("label", label.label),
            ]
        }

        /// The entries in the encoder's order: by key, then the later ones.
        var entries: [MapEntry] {
            [
                MapEntry(key: encodedBytes(0), value: encodedBytes(id)),
                old.entry(key: 1), note.entry(key: 2), limit.entry(key: 3), count.entry(key: 4),
                score.entry(key: 5), weight.entry(key: 6), ratio.entry(key: 7), on.entry(key: 8),
                tag.entry(key: 9), level.entry(key: 10), label.entry(key: 11),
            ].compactMap { $0 } + later
        }

        /// The record the second edition reads: each value written, and the
        /// field's default where the key is absent or holds nil.
        var secondEdition: SecondEdition.Record {
            SecondEdition.Record(
                id: id,
                note: note.value,
                limit: limit.value ?? 50,
                count: count.value ?? 7,
                score: score.value ?? 0.5,
                weight: weight.value ?? -2.5,
                ratio: SecondEdition.Ratio(ratio.value ?? 1),
                on: on.value ?? true,
                tag: tag.value ?? "untitled",
                level: level.value ?? .high,
                label: label.value ?? "none"
            )
        }

        /// The record the first edition reads, which knows nothing of the
        /// second edition's fields.
        var firstEdition: FirstEdition.Record {
            FirstEdition.Record(id: id, old: old.value, note: note.value)
        }
    }

    /// Which peer wrote a record's map.
    enum RecordWriter: String, CaseIterable, Sendable {
        /// A first-edition peer: none of the second edition's fields.
        case firstEdition = "the first edition"
        /// A second-edition peer: every field, `old` never.
        case secondEdition = "the second edition"
        /// Any peer: every key absent, nil or a value.
        case any = "any peer"
        /// Any peer of an edition later still, with keys neither declares.
        case later = "a later edition"
    }

    enum EditionGenerators {
        static func written<Value: Sendable>(
            _ values: Gen<Value>,
            by writer: RecordWriter,
            inEdition edition: Int
        ) -> Gen<Written<Value>> {
            switch (writer, edition) {
                case (.firstEdition, 2), (.secondEdition, 1): .just(.absent)
                case (.secondEdition, 2): values.map { .value($0) }
                default: .oneOf(.just(.absent), .just(.null), values.map { .value($0) })
            }
        }

        /// Texts: the defaults themselves, the empty string, and any.
        static let texts: Gen<String> = .oneOf(
            .element(of: ["", "untitled", "none", "low"]),
            .string()
        )

        static func records(by writer: RecordWriter) -> Gen<WrittenRecord> {
            Gen { tc in
                let edgeRate = try tc.draw(.element(of: [0.1, 0.5]))
                func written<Value: Sendable>(_ values: Gen<Value>, _ edition: Int) throws
                    -> Written<Value>
                {
                    try tc.draw(Self.written(values, by: writer, inEdition: edition))
                }
                let later: [MapEntry] =
                    writer == .later
                    ? try tc.draw(
                        .array(
                            of: Hegel.zip(
                                Gen<Int>.oneOf(.int(in: 12...15), .int(in: 12...Int.max)),
                                unknownValues
                            ).map { MapEntry(key: encodedBytes($0), value: $1) },
                            count: 1...3
                        )
                    ) : []
                return WrittenRecord(
                    id: Int(try tc.draw(SchemaValueGenerators.int64s(edgeRate: edgeRate))),
                    old: try written(texts, 1),
                    note: try tc.draw(
                        .oneOf(.just(.absent), .just(.null), texts.map { .value($0) })
                    ),
                    limit: try written(
                        SchemaValueGenerators.int64s(edgeRate: edgeRate).map { Int($0) },
                        2
                    ),
                    count: try written(SchemaValueGenerators.uint64s(edgeRate: edgeRate), 2),
                    score: try written(SchemaValueGenerators.floats(edgeRate: edgeRate), 2),
                    weight: try written(SchemaValueGenerators.doubles(edgeRate: edgeRate), 2),
                    ratio: try written(SchemaValueGenerators.doubles(edgeRate: edgeRate), 2),
                    on: try written(.bool(), 2),
                    tag: try written(texts, 2),
                    level: try written(.element(of: [.low, .high]), 2),
                    label: try written(texts, 2),
                    later: later
                )
            }
        }
    }

    /// A field kind a `default:` meets, as `#schema` source and as the
    /// runtime fits a default to it.
    struct DefaultedKind: Sendable {
        let source: String
        let schema: TypeSchema
        /// The rules a field of the kind takes.
        let takes: Set<String>

        /// The kind a default of `literal` is most often written for.
        var literalKind: String {
            switch schema {
                case .int, .uint: "integer"
                case .float: "float"
                case .double: "number"
                case .string: "string"
                case .bool: "boolean"
                default: "any"
            }
        }

        static let scalars: [DefaultedKind] = [
            DefaultedKind(source: ".int", schema: .int, takes: ["range"]),
            DefaultedKind(source: ".uint", schema: .uint, takes: ["range"]),
            DefaultedKind(source: ".float", schema: .float, takes: ["range"]),
            DefaultedKind(source: ".double", schema: .double, takes: ["range"]),
            DefaultedKind(source: ".string", schema: .string, takes: ["length", "pattern"]),
            DefaultedKind(source: ".bool", schema: .bool, takes: []),
            DefaultedKind(source: ".bytes", schema: .bytes, takes: ["length"]),
            DefaultedKind(source: ".date", schema: .date, takes: []),
        ]

        /// Kinds no default fits, beyond the scalars: a field of one takes
        /// no default.
        static let others: [DefaultedKind] = [
            DefaultedKind(source: ".timestamp", schema: .timestamp, takes: []),
            DefaultedKind(source: ".duration", schema: .duration, takes: []),
            DefaultedKind(source: ".uuid", schema: .uuid, takes: []),
            DefaultedKind(source: ".array(.string)", schema: .array(.string), takes: ["length"]),
            DefaultedKind(
                source: ".map(key: .string, value: .int)",
                schema: .map(key: .string, value: .int),
                takes: ["length"]
            ),
        ]
    }

    /// A `default:` literal as `#schema` source and as the value the Swift
    /// compiler makes of it.
    struct DefaultLiteral: Sendable {
        let source: String
        let value: TypeSchema.Default

        /// Integers around zero and the ends of `Int64`, in decimal, with
        /// digit separators, in hexadecimal and binary, and zero written
        /// negative.
        static let integers: Gen<DefaultLiteral> = Gen { tc in
            let value = try tc.draw(
                .oneOf(
                    .element(of: [Int64.min, .min + 1, -5, -1, 0, 1, 5, 7, 50, 100, .max - 1, .max]
                    ),
                    SchemaValueGenerators.int64s(edgeRate: 0.2)
                )
            )
            let sign = value < 0 ? "-" : ""
            let magnitude = value.magnitude
            let source: String
            switch try tc.draw(.int(in: 0...4)) {
                case 0: source = sign + "0x" + String(magnitude, radix: 16)
                case 1: source = sign + "0b" + String(magnitude, radix: 2)
                case 2:
                    var digits = Array(String(magnitude))
                    for index in stride(from: digits.count - 3, to: 0, by: -3) {
                        digits.insert("_", at: index)
                    }
                    source = sign + String(digits)
                case 3 where value == 0: source = "-0"
                default: source = "\(value)"
            }
            return DefaultLiteral(source: source, value: .integer(value))
        }

        /// Finite numbers: around zero, at the edges of `Float` and of
        /// `Double`, and any.
        static let numbers: Gen<DefaultLiteral> = Gen<Double>.oneOf(
            .element(of: [
                0, -0.0, 0.5, 1, -2.5, 1e39, 1e-46, 5e-324, 1e300, .greatestFiniteMagnitude,
                Double(Float.greatestFiniteMagnitude), -Double(Float.greatestFiniteMagnitude),
                // Either side of the point past which a Float rounds to
                // infinity.
                3.4028235677973362e38, 3.4028235677973366e38,
            ]),
            .double(allowNaN: false, allowInfinity: false)
        )
        .map { DefaultLiteral(source: "\($0)", value: .floating($0)) }

        static let booleans: Gen<DefaultLiteral> = Gen<Bool>.bool().map {
            DefaultLiteral(source: "\($0)", value: .bool($0))
        }

        /// Short strings, the enum's case names among them.
        static let strings: Gen<DefaultLiteral> = Gen<String>.element(
            of: ["", "a", "ab", "abc", "A", "a1", "low", "high", "\u{E9}"]
        )
        .map { DefaultLiteral(source: "\"\($0)\"", value: .string($0)) }

        /// Numbers about the largest `Float`: either side of where one
        /// rounds to infinity, and well past it.
        static let floatEdges: Gen<DefaultLiteral> = Gen<Double>.element(
            of: [
                3.4028235677973362e38, 3.4028235677973366e38, -3.4028235677973366e38, 1e39,
                Double(Float.greatestFiniteMagnitude), 1e-46,
            ]
        )
        .map { DefaultLiteral(source: "\($0)", value: .floating($0)) }

        static func literals(kind: String) -> Gen<DefaultLiteral> {
            switch kind {
                case "integer": integers
                case "float": .oneOf(integers, numbers, floatEdges)
                case "number": .oneOf(integers, numbers)
                case "string": strings
                case "boolean": booleans
                default: .oneOf(integers, numbers, strings, booleans)
            }
        }
    }

    /// Rules a field of `kind` takes that apply to it, around `value`: a
    /// range whose bounds sit on, beside or away from the value, a length
    /// about the value's, and patterns that compile. A third of the time a
    /// bound or a length sits just past the value on one side or the
    /// other.
    func declaredRules(for kind: DefaultedKind, around value: TypeSchema.Default, _ tc: TestCase)
        throws -> [DeclaredRule]
    {
        var rules: [DeclaredRule] = []
        let floating = kind.schema == .float || kind.schema == .double
        let placement = try tc.draw(
            .element(of: ["near", "near", "past the minimum", "past the maximum", "on a bound"])
        )
        if kind.takes.contains("range"), try tc.draw(.bool(probability: 0.8)) {
            func bound() throws -> TypeSchema.Bound {
                switch value {
                    case .floating(let number) where floating && number.isFinite:
                        let near = [number, number.nextDown, number.nextUp, -2.5, 0, 0.5, 1e300]
                        return .floating(try tc.draw(.element(of: near.filter(\.isFinite))))
                    case .integer(let integer):
                        let (below, belowOverflow) = integer.subtractingReportingOverflow(1)
                        let (above, aboveOverflow) = integer.addingReportingOverflow(1)
                        let near =
                            [
                                integer, belowOverflow ? integer : below,
                                aboveOverflow ? integer : above,
                            ]
                            + [Int64.min, -5, 0, 5, .max]
                        return .integer(try tc.draw(.element(of: near)))
                    default:
                        return .integer(try tc.draw(.element(of: [Int64.min, -5, 0, 5, .max])))
                }
            }
            func ordered(_ first: TypeSchema.Bound, _ second: TypeSchema.Bound) -> Bool {
                switch (first, second) {
                    case (.integer(let a), .integer(let b)): a <= b
                    default: first.doubleValue <= second.doubleValue
                }
            }
            /// The bound on the value, or one step past it above or below.
            func past(above: Bool?) -> TypeSchema.Bound? {
                switch value {
                    case .floating(let number) where floating && number.isFinite:
                        let step = above.map { $0 ? number.nextUp : number.nextDown } ?? number
                        return step.isFinite ? .floating(step) : nil
                    case .integer(let integer):
                        let (step, overflow) =
                            above.map {
                                $0
                                    ? integer.addingReportingOverflow(1)
                                    : integer.subtractingReportingOverflow(1)
                            } ?? (integer, false)
                        return overflow ? nil : .integer(step)
                    default:
                        return nil
                }
            }
            var minimum: TypeSchema.Bound? = try bound()
            var maximum: TypeSchema.Bound? = try bound()
            if let low = minimum, let high = maximum, !ordered(low, high) {
                (minimum, maximum) = (high, low)
            }
            switch try tc.draw(.int(in: 0...3)) {
                case 0: minimum = nil
                case 1: maximum = nil
                default: break
            }
            if placement == "past the minimum", let step = past(above: true) {
                (minimum, maximum) = (step, maximum.map { ordered(step, $0) ? $0 : step })
            } else if placement == "past the maximum", let step = past(above: false) {
                (minimum, maximum) = (minimum.map { ordered($0, step) ? $0 : step }, step)
            } else if placement == "on a bound", let bound = past(above: nil) {
                if try tc.draw(.bool()) {
                    (minimum, maximum) = (bound, maximum.map { ordered(bound, $0) ? $0 : bound })
                } else {
                    (minimum, maximum) = (minimum.map { ordered($0, bound) ? $0 : bound }, bound)
                }
            }
            let source = ".range(\(minimum?.description ?? "")...\(maximum?.description ?? ""))"
            rules.append(DeclaredRule(source: source, rule: .range(minimum, maximum)))
        }
        if kind.takes.contains("length"), try tc.draw(.bool(probability: 0.75)) {
            let length = if case .string(let text) = value { text.unicodeScalars.count } else { 1 }
            let near = [0, 1, 2, 3, length, max(length - 1, 0), length + 1]
            var minimum = try tc.draw(.element(of: near))
            var maximum = try tc.draw(.element(of: near))
            if minimum > maximum { (minimum, maximum) = (maximum, minimum) }
            if placement == "past the minimum" {
                (minimum, maximum) = (length + 1, max(maximum, length + 1))
            } else if placement == "past the maximum", length > 0 {
                (minimum, maximum) = (min(minimum, length - 1), length - 1)
            }
            rules.append(
                DeclaredRule(
                    source: ".length(\(minimum)...\(maximum))",
                    rule: .length(minimum, maximum)
                )
            )
        }
        if kind.takes.contains("pattern"), try tc.draw(.bool(probability: 0.5)) {
            let pattern = try tc.draw(.element(of: ["[a-z]+", "a|b", "", ".*", #"\d+"#]))
            rules.append(
                DeclaredRule(source: ".pattern(#\"\(pattern)\"#)", rule: .pattern(pattern))
            )
        }
        return rules
    }

    extension TypeSchema.Bound {
        var doubleValue: Double {
            switch self {
                case .integer(let value): Double(value)
                case .floating(let value): value
            }
        }
    }

    /// What `#schema` makes of a source: the declarations it expands to,
    /// joined, or the diagnostic it refuses it with.
    enum SchemaExpansion {
        case success(String)
        case failure(String)
    }

    func schemaExpansion(_ source: String) -> SchemaExpansion {
        let item = Parser.parse(source: source).statements.first?.item
        do {
            if let declaration = item?.as(MacroExpansionDeclSyntax.self) {
                return .success(
                    try SchemaCodeGenerator.expandSchema(declaration).declarations.joined(
                        separator: "\n"
                    )
                )
            } else if let expression = item?.as(MacroExpansionExprSyntax.self) {
                return .success(
                    try SchemaCodeGenerator.expandSchema(expression).declarations.joined(
                        separator: "\n"
                    )
                )
            }
            return .failure("not a macro expansion")
        } catch {
            return .failure("\(error)")
        }
    }

    /// The value of a Swift integer literal: decimal, hexadecimal, octal or
    /// binary, with digit separators, and a sign.
    func integerLiteralValue(_ text: String) -> Int64? {
        let digits = text.filter { $0 != "_" }
        let negative = digits.hasPrefix("-")
        let body = negative ? String(digits.dropFirst()) : digits
        let (radix, magnitudeDigits): (Int, Substring) =
            body.hasPrefix("0x")
            ? (16, body.dropFirst(2))
            : body.hasPrefix("0o")
                ? (8, body.dropFirst(2))
                : body.hasPrefix("0b") ? (2, body.dropFirst(2)) : (10, Substring(body))
        guard let magnitude = UInt64(magnitudeDigits, radix: radix) else { return nil }
        if negative {
            return magnitude == Int64.min.magnitude ? .min : Int64(exactly: magnitude).map { -$0 }
        }
        return Int64(exactly: magnitude)
    }

    /// The field defaults an expansion's schema literals carry, as the
    /// compiler makes of them.
    func expandedDefaults(_ expansion: String) -> [TypeSchema.Default?] {
        expansion.ranges(of: "defaultValue: .").map { range in
            let rest = expansion[range.upperBound...]
            guard let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") else {
                return nil
            }
            let kind = rest[..<open]
            let argument = String(rest[rest.index(after: open)..<close])
            switch kind {
                case "bool":
                    return argument == "true"
                        ? .bool(true) : argument == "false" ? .bool(false) : nil
                case "integer": return integerLiteralValue(argument).map { .integer($0) }
                case "floating":
                    if let integer = integerLiteralValue(argument) {
                        return .floating(Double(integer))
                    }
                    return Double(argument.filter { $0 != "_" }).map { .floating($0) }
                case "string":
                    guard argument.hasPrefix("\""), argument.hasSuffix("\""), argument.count >= 2
                    else {
                        return nil
                    }
                    return .string(String(argument.dropFirst().dropLast()))
                default: return nil
            }
        }
    }

    /// Whether two defaults are the same value of the same kind, a floating
    /// one bit for bit.
    func sameDefault(_ first: TypeSchema.Default?, _ second: TypeSchema.Default?) -> Bool {
        switch (first, second) {
            case (.floating(let a)?, .floating(let b)?): a.bitPattern == b.bitPattern
            default: first == second
        }
    }

    /// The reason a default is refused, as a word both declarations agree
    /// on: the kind takes none, the value is none of the kind's, or the
    /// value breaks one of the rules.
    func refusalReason(_ message: String) -> String {
        if message.hasSuffix("takes no default") { return "takes no default" }
        if message.contains("is no value of") || message.contains("is beyond float")
            || message.contains("must name a case of")
        {
            return "no value of the kind"
        }
        for rule in [
            "less than the minimum length", "more than the maximum length", "less than the minimum",
            "more than the maximum", "does not match the pattern",
        ] where message.contains(rule) {
            return rule
        }
        return "another reason: \(message)"
    }

    @Suite("Schema evolution properties", .hegel, .offTheCooperativePool)
    struct SchemaEvolutionProperties {
        /// The second edition of a record reads any map a peer of either
        /// edition, or of one later still, writes for it: a value where the
        /// key holds one, and the field's default where the key is absent
        /// or holds nil, whatever order the keys come in and whether a key
        /// comes as its integer or its name. The reserved key of the removed
        /// field and keys a later edition adds are skipped. The first
        /// edition reads the same map, knowing none of the second edition's
        /// fields. The generated code and `Codable` read alike.
        ///
        /// The second edition writes every field, a defaulted one whatever
        /// its value, under keys that skip the reserved one, and the first
        /// edition reads what it writes.
        ///
        /// Mutation check: `Codable` decoding that requires a defaulted key,
        /// a generated decoder that requires one when the keys come out of
        /// the encoder's order, or the macro's auto keys taking a reserved
        /// key, fails here.
        @Test
        func aLaterEditionReadsWhatAnyEditionWrote() throws {
            try property(
                reaching: [
                    "a default read for an absent key", "a default read for a nil",
                    "keys out of the encoder's order", "a key under its name",
                    "the removed field's key written",
                ],
                reachingAfter: [
                    "every defaulted field written": 1_000, "a later edition's key": 1_000,
                    "writer: the first edition": 1_000,
                ]
            ) { tc in
                let writer = try #draw(.element(of: RecordWriter.allCases), from: tc)
                let written = try #draw(EditionGenerators.records(by: writer), from: tc)
                try tc.event("writer: \(writer.rawValue)")
                let states = written.defaulted.map(\.written)
                if states.contains("absent") { try tc.event("a default read for an absent key") }
                if states.contains("nil") { try tc.event("a default read for a nil") }
                if states.allSatisfy({ $0 == "a value" }) {
                    try tc.event("every defaulted field written")
                }
                if written.old.value != nil || written.old.label == "nil" {
                    try tc.event("the removed field's key written")
                }
                if !written.later.isEmpty { try tc.event("a later edition's key") }

                // The keys in an order drawn for the case, some written as
                // their field's name.
                var entries = written.entries
                if try #draw(.bool(), from: tc) {
                    entries = try FingerprintGenerators.shuffled(entries, tc)
                }
                let names = [
                    "id", "old", "note", "limit", "count", "score", "weight", "ratio", "on", "tag",
                    "level",
                    "label",
                ]
                let renameRate = try #draw(.element(of: [0.0, 0.2]), from: tc)
                for index in entries.indices {
                    guard let key = entries[index].integerKey, names.indices.contains(key),
                        try tc.draw(.bool(probability: renameRate))
                    else { continue }
                    entries[index].key = encodedBytes(names[key])
                    try tc.event("a key under its name")
                }
                if entries.map(\.key) != written.entries.map(\.key) {
                    try tc.event("keys out of the encoder's order")
                }
                let bytes = ByteBuffer(bytes: mapBytes(entries))
                try tc.note("map: \(hex(bytes))")

                let second = try codableBytes(written.secondEdition)
                #expect(
                    try codableBytes(
                        decodedThroughCodable(SecondEdition.Record.self, from: bytes).get()
                    )
                        == second
                )
                #expect(
                    try codableBytes(
                        decodedThroughGeneratedCode(SecondEdition.Record.self, from: bytes).get()
                    )
                        == second
                )
                #expect(
                    try decodedThroughCodable(FirstEdition.Record.self, from: bytes).get()
                        == written.firstEdition
                )
                #expect(
                    try decodedThroughGeneratedCode(FirstEdition.Record.self, from: bytes).get()
                        == written.firstEdition
                )

                let generated = try encodedThroughGeneratedCode(written.secondEdition).get()
                #expect(Array(generated.readableBytesView) == second)
                let keys = [0] + (written.note.value == nil ? [] : [2]) + Array(3...11)
                #expect(try mapEntries(second).map(\.integerKey) == keys)
                let rereadByTheFirst = FirstEdition.Record(
                    id: written.id,
                    old: nil,
                    note: written.note.value
                )
                #expect(
                    try decodedThroughCodable(FirstEdition.Record.self, from: generated).get()
                        == rereadByTheFirst
                )
                #expect(
                    try decodedThroughGeneratedCode(FirstEdition.Record.self, from: generated).get()
                        == rereadByTheFirst
                )
            }
        }

        /// `#schema` takes a field's `default:` exactly when the runtime
        /// fits it to the field: a value of the field's kind, an integer
        /// standing for a floating number, a case name for an enum, a value
        /// of the scalar for an alias, that keeps the field's or the
        /// alias's rules, a `float`'s as the `Float` it is held as. Both
        /// refuse the rest for the same reason, and the default `#schema`
        /// serves is the value the runtime serves, of the same kind.
        ///
        /// Mutation check: the macro or the runtime taking a `float` default
        /// beyond `Float`'s range, or the macro checking a `float` default's
        /// bounds as the `Double` it was written as, fails here.
        @Test
        func theMacroFitsDefaultsAsTheRuntimeDoes() throws {
            try property(
                reaching: ["accepted", "refused: takes no default"],
                reachingAfter: [
                    "refused: no value of the kind": 1_000,
                    "refused: less than the minimum": 1_000,
                    "refused: more than the maximum": 1_000,
                    "refused: less than the minimum length": 1_000,
                    "refused: more than the maximum length": 1_000,
                    "refused: does not match the pattern": 1_000,
                    "accepted: an integer for a floating kind": 1_000,
                    "refused: beyond float": 1_000, "accepted: an enum case": 1_000,
                    "accepted: an alias's default": 1_000, "refused: an alias's rule": 1_000,
                    "accepted: a bound on the default": 1_000,
                ]
            ) { tc in
                let shape = try #draw(
                    .element(of: [
                        "scalar", "scalar", "scalar", "scalar", "alias", "alias", "enum", "enum",
                        "other", "named",
                    ]),
                    from: tc
                )
                var declaration = ""
                let fieldType: String
                let fitsTo: TypeSchema
                var rules: [DeclaredRule] = []
                let literal: DefaultLiteral
                var aliasName: String?
                switch shape {
                    case "scalar", "alias", "other":
                        // The kinds that take rules come up more often;
                        // now and then the case is a string, a floating
                        // kind meeting an integer, or a float meeting a
                        // number about its largest.
                        let focus = try #draw(
                            .element(of: [
                                "none", "none", "a string", "a string", "an integer",
                                "the largest float",
                            ]),
                            from: tc
                        )
                        let kind = try #draw(
                            shape == "other"
                                ? .element(of: DefaultedKind.others)
                                : focus == "an integer"
                                    ? .element(of: [
                                        DefaultedKind.scalars[2], DefaultedKind.scalars[3],
                                    ])
                                    : focus == "the largest float"
                                        ? .just(DefaultedKind.scalars[2])
                                        : focus == "a string"
                                            ? .just(DefaultedKind.scalars[4])
                                            : .oneOf(
                                                .element(of: DefaultedKind.scalars),
                                                .element(
                                                    of: DefaultedKind.scalars.filter {
                                                        !$0.takes.isEmpty
                                                    }
                                                )
                                            ),
                            from: tc
                        )
                        let ownKind = try #draw(.bool(probability: 0.75), from: tc)
                        literal = try #draw(
                            focus == "an integer"
                                ? DefaultLiteral.integers
                                : focus == "the largest float"
                                    ? DefaultLiteral.floatEdges
                                    : DefaultLiteral.literals(
                                        kind: ownKind || focus == "a string"
                                            ? kind.literalKind : "any"
                                    ),
                            from: tc
                        )
                        rules = try declaredRules(for: kind, around: literal.value, tc)
                        if declaredConstraints(rules, on: kind.schema).problem(
                            applyingTo: kind.schema
                        ) != nil {
                            rules = []
                        }
                        fitsTo = kind.schema
                        let constraints =
                            rules.isEmpty
                            ? "" : ", constraints: \(rules.map(\.source).joined(separator: ", "))"
                        if shape == "alias" {
                            aliasName = "Amount"
                            declaration = #"Alias("Amount", \#(kind.source)\#(constraints))"#
                            fieldType = #""Amount""#
                        } else {
                            fieldType = kind.source + constraints
                        }
                    case "enum":
                        declaration = #"Enum("Level") { Case("low"); Case("high") }"#
                        fieldType = #""Level""#
                        fitsTo = .enumeration(cases: [.init(name: "low"), .init(name: "high")])
                        literal = try #draw(
                            .oneOf(
                                Gen<String>.element(of: ["low", "high"]).map {
                                    DefaultLiteral(source: "\"\($0)\"", value: .string($0))
                                },
                                DefaultLiteral.literals(kind: "string"),
                                DefaultLiteral.literals(kind: "any")
                            ),
                            from: tc
                        )
                    default:
                        let structure = try #draw(.bool(), from: tc)
                        declaration =
                            structure
                            ? #"Type("Inner") { Field("x", .int) }"#
                            : #"Union("Pick") { Case("one") }"#
                        fieldType = structure ? #""Inner""# : #""Pick""#
                        fitsTo = structure ? .structure(fields: []) : .union(cases: [])
                        literal = try #draw(DefaultLiteral.literals(kind: "any"), from: tc)
                }
                let source = """
                    #schema("box") {
                        \(declaration)
                        Call("put") {
                            Access(.write)
                            Request {
                                Field("f", \(fieldType), default: \(literal.source))
                            }
                        }
                    }
                    """
                try tc.note(source)
                let constraints = rules.isEmpty ? nil : declaredConstraints(rules, on: fitsTo)
                let expected = literal.value.fitted(to: fitsTo, constraints: constraints)
                let context =
                    #"Call("put").Request: field "f""# + (aliasName.map { " of \($0)" } ?? "")
                    + ": "
                switch (expected, schemaExpansion(source)) {
                    case (.success(let value), .success(let expansion)):
                        try tc.event("accepted")
                        if case .integer = literal.value, case .floating = value {
                            try tc.event("accepted: an integer for a floating kind")
                        }
                        if case .enumeration = fitsTo { try tc.event("accepted: an enum case") }
                        if aliasName != nil { try tc.event("accepted: an alias's default") }
                        if let constraints,
                            [constraints.minimum, constraints.maximum].contains(where: {
                                $0.map { $0.doubleValue == literal.value.numberValue } ?? false
                            })
                        {
                            try tc.event("accepted: a bound on the default")
                        }
                        let served = expandedDefaults(expansion)
                        #expect(
                            !served.isEmpty && served.allSatisfy { sameDefault($0, value) },
                            "served \(served)"
                        )
                    case (.failure(let refusal), .failure(let message)):
                        let reason = refusalReason("\(refusal)")
                        try tc.event("refused: \(reason)")
                        if aliasName != nil, case .constraints = refusal {
                            try tc.event("refused: an alias's rule")
                        }
                        if message.contains("is beyond float") {
                            try tc.event("refused: beyond float")
                        }
                        #expect(message.hasPrefix(context), "\(message)")
                        #expect(refusalReason(message) == reason, "\(message), not \(refusal)")
                    case (.success(let value), .failure(let message)):
                        Issue.record("the runtime fits \(value), #schema refuses: \(message)")
                    case (.failure(let refusal), .success):
                        Issue.record("the runtime refuses (\(refusal)), #schema takes it")
                }
            }
        }

        /// A fields block's keys follow the rules `fieldKeys` documents: it
        /// refuses the first field, in declaration order, that takes a
        /// reserved name, pins a reserved key, or pins a key an earlier
        /// field pinned; else every field keeps its pin, and the unpinned
        /// ones take, in declaration order, the lowest keys that no field
        /// pins and no reservation holds.
        ///
        /// Mutation check: auto keys that take reserved keys fail here.
        @Test
        func fieldKeysFollowTheirRules() throws {
            try property(
                reaching: ["assigned"],
                reachingAfter: [
                    "refused: a reserved name": 1_000, "refused: a reserved key": 1_000,
                    "refused: a key pinned twice": 1_000,
                    "assigned: an auto key past a reserved one": 1_000,
                    "assigned: an auto key past a pinned one": 1_000,
                ]
            ) { tc in
                let names = Gen<String>.element(of: ["a", "b", "c", "old"])
                let pins = Gen<Int?>.optional(
                    .oneOf(.element(of: [0, 1, 2, 3, 5, .max]), .int(in: 0...Int.max))
                )
                let fields = try #draw(
                    .array(
                        of: Hegel.zip(pins, names).map { (pinnedKey: $0, name: $1) },
                        count: 0...6
                    ),
                    from: tc
                )
                let reservedKeys = try #draw(
                    Gen<[Int]>.array(of: .element(of: [0, 1, 2, 3, 5]), count: 0...3).map(Set.init),
                    from: tc
                )
                let reservedNames = try #draw(
                    Gen<[String]>.array(
                        of: .element(of: ["a", "b", "c", "old", "gone"]),
                        count: 0...1
                    ).map(Set.init),
                    from: tc
                )

                var conflict: FieldKeyConflict?
                var pinned: Set<Int> = []
                for field in fields where conflict == nil {
                    if reservedNames.contains(field.name) {
                        conflict = .reservedName(field.name)
                    } else if let pin = field.pinnedKey {
                        if reservedKeys.contains(pin) {
                            conflict = .reservedKey(pin, field: field.name)
                        } else if !pinned.insert(pin).inserted {
                            conflict = .duplicateKey(pin, field: field.name)
                        }
                    }
                }
                let result = fieldKeys(
                    for: fields,
                    reservedKeys: reservedKeys,
                    reservedNames: reservedNames
                )
                if let conflict {
                    let label =
                        switch conflict {
                            case .reservedName: "a reserved name"
                            case .reservedKey: "a reserved key"
                            case .duplicateKey: "a key pinned twice"
                        }
                    try tc.event("refused: \(label)")
                    #expect(result == .failure(conflict))
                    return
                }
                try tc.event("assigned")
                guard case .success(let keys) = result else {
                    Issue.record("refused \(result) with no rule broken")
                    return
                }
                #expect(keys.count == fields.count)
                #expect(Set(keys).count == keys.count, "a key taken twice: \(keys)")
                #expect(Set(keys).isDisjoint(with: reservedKeys), "a reserved key taken: \(keys)")
                for (field, key) in zip(fields, keys) where field.pinnedKey != nil {
                    #expect(
                        key == field.pinnedKey,
                        "\(field.name) pinned \(field.pinnedKey!), took \(key)"
                    )
                }
                let autoKeys = zip(fields, keys).filter { $0.0.pinnedKey == nil }.map(\.1)
                let free = (0...).lazy.filter { !pinned.contains($0) && !reservedKeys.contains($0) }
                #expect(autoKeys == Array(free.prefix(autoKeys.count)), "auto keys \(autoKeys)")
                if let last = autoKeys.last {
                    if reservedKeys.contains(where: { $0 < last }) {
                        try tc.event("assigned: an auto key past a reserved one")
                    }
                    if pinned.contains(where: { $0 < last }) {
                        try tc.event("assigned: an auto key past a pinned one")
                    }
                }
            }
        }

        /// Removing a field and reserving its key, and its name or not,
        /// leaves every other field's key where it was. A field added after
        /// the others takes neither the removed key nor any other field's;
        /// one that takes the removed name while it is reserved, or pins the
        /// removed key, is refused.
        ///
        /// Mutation check: auto keys that take reserved keys fail here.
        @Test
        func reservingARemovedFieldKeepsTheOtherKeys() throws {
            try property(
                reaching: ["a field added", "the removed key pinned", "a removed auto key"],
                reachingAfter: ["the removed name reused": 1_000, "a removed pinned key": 1_000]
            ) { tc in
                let count = try #draw(.int(in: 1...6), from: tc)
                let names = (0..<count).map { "field\($0)" }
                // Pins drawn for the case, a repeated one left unpinned.
                var pinned: Set<Int> = []
                var fields: [(pinnedKey: Int?, name: String)] = []
                for name in names {
                    var pin = try tc.draw(Gen<Int?>.optional(.int(in: 0...7)))
                    if let key = pin, !pinned.insert(key).inserted { pin = nil }
                    fields.append((pin, name))
                }
                let reserved = try #draw(
                    Gen<[Int]>.array(of: .int(in: 0...7), count: 0...2).map { Set($0) },
                    from: tc
                ).subtracting(pinned)
                let keys = try fieldKeys(for: fields, reservedKeys: reserved, reservedNames: [])
                    .get()

                let removed = try #draw(.int(in: 0...(count - 1)), from: tc)
                let reservesTheName = try #draw(.bool(), from: tc)
                try tc.event(
                    fields[removed].pinnedKey == nil ? "a removed auto key" : "a removed pinned key"
                )
                var remaining = fields
                remaining.remove(at: removed)
                var remainingKeys = keys
                remainingKeys.remove(at: removed)
                let reservedKeys = reserved.union([keys[removed]])
                let reservedNames: Set<String> = reservesTheName ? [fields[removed].name] : []
                #expect(
                    fieldKeys(
                        for: remaining,
                        reservedKeys: reservedKeys,
                        reservedNames: reservedNames
                    )
                        == .success(remainingKeys)
                )

                switch try #draw(.element(of: ["added", "name reused", "key pinned"]), from: tc) {
                    case "added":
                        try tc.event("a field added")
                        let added = fieldKeys(
                            for: remaining + [(nil, "added")],
                            reservedKeys: reservedKeys,
                            reservedNames: reservedNames
                        )
                        guard case .success(let addedKeys) = added else {
                            Issue.record("adding a field: \(added)")
                            return
                        }
                        #expect(Array(addedKeys.dropLast()) == remainingKeys)
                        #expect(
                            addedKeys.last.map { !keys.contains($0) && !reserved.contains($0) }
                                ?? false
                        )
                    case "name reused":
                        let reused = fieldKeys(
                            for: remaining + [(nil, fields[removed].name)],
                            reservedKeys: reservedKeys,
                            reservedNames: reservedNames
                        )
                        if reservesTheName {
                            try tc.event("the removed name reused")
                            #expect(reused == .failure(.reservedName(fields[removed].name)))
                        } else {
                            #expect(
                                (try? reused.get()).map { Array($0.dropLast()) == remainingKeys }
                                    ?? false
                            )
                        }
                    default:
                        try tc.event("the removed key pinned")
                        #expect(
                            fieldKeys(
                                for: remaining + [(keys[removed], "added")],
                                reservedKeys: reservedKeys,
                                reservedNames: reservedNames
                            )
                                == .failure(.reservedKey(keys[removed], field: "added"))
                        )
                }
            }
        }

        /// `#schema` keys a fields block with `Reserved` entries among its
        /// fields as the runtime's `fieldKeys` does, wherever the entries
        /// stand, or refuses it for the conflict `fieldKeys` reports.
        ///
        /// Mutation check: the macro's auto keys taking reserved keys, the
        /// macro taking a reserved name, or the runtime's auto keys taking
        /// reserved keys, fails here.
        @Test
        func theMacroReservesKeysAsTheRuntimeDoes() throws {
            try property(
                reaching: ["keyed", "refused"],
                reachingAfter: [
                    "refused: a reserved name": 1_000, "refused: a reserved key": 1_000,
                    "refused: a key pinned twice": 1_000,
                    "keyed: an auto key past a reserved one": 1_000,
                ]
            ) { tc in
                let pool = ["a", "b", "c", "d", "e"]
                let names = try FingerprintGenerators.shuffled(pool, tc).prefix(
                    try #draw(.int(in: 0...5), from: tc)
                )
                var fields: [(pinnedKey: Int?, name: String)] = []
                for name in names {
                    fields.append(
                        (try tc.draw(Gen<Int?>.optional(.element(of: [0, 1, 2, 7, .max]))), name)
                    )
                }
                let reservations = try #draw(
                    .array(
                        of: .array(
                            of: Gen<String>.oneOf(
                                Gen<Int>.element(of: [0, 1, 2, 3, 7]).map { "\($0)" },
                                Gen<Int>.element(of: [0, 1, 2]).map { "\($0)" },
                                Gen<String>.element(of: pool + ["old"]).map { "\"\($0)\"" }
                            ),
                            count: 1...3
                        ),
                        count: 0...2
                    ),
                    from: tc
                )
                var lines = fields.map { field in
                    field.pinnedKey.map { #"Field(\#($0), "\#(field.name)", .int)"# }
                        ?? #"Field("\#(field.name)", .int)"#
                }
                for reservation in reservations {
                    let at = try tc.draw(.int(in: 0...lines.count))
                    lines.insert("Reserved(\(reservation.joined(separator: ", ")))", at: at)
                }
                let entries = reservations.flatMap { $0 }
                let reservedKeys = Set(entries.compactMap { Int($0) })
                let reservedNames = Set(
                    entries.filter { $0.hasPrefix("\"") }.map { String($0.dropFirst().dropLast()) }
                )
                let source = """
                    #schema("box") {
                        Call("put") {
                            Access(.write)
                            Request {
                                \(lines.joined(separator: "\n                "))
                            }
                        }
                    }
                    """
                try tc.note(source)
                let expected = fieldKeys(
                    for: fields,
                    reservedKeys: reservedKeys,
                    reservedNames: reservedNames
                )
                switch (expected, schemaExpansion(source)) {
                    case (.success(let keys), .success(let expansion)):
                        try tc.event("keyed")
                        let autoKeys = zip(fields, keys).filter { $0.0.pinnedKey == nil }.map(\.1)
                        if let last = autoKeys.last, reservedKeys.contains(where: { $0 < last }) {
                            try tc.event("keyed: an auto key past a reserved one")
                        }
                        for (field, key) in zip(fields, keys) {
                            #expect(
                                expansion.contains(
                                    #"TypeSchema.Field(key: \#(key), name: "\#(field.name)""#
                                ),
                                "\(field.name) is not keyed \(key)"
                            )
                        }
                    case (.failure(let conflict), .failure(let message)):
                        try tc.event("refused")
                        switch conflict {
                            case .reservedName: try tc.event("refused: a reserved name")
                            case .reservedKey: try tc.event("refused: a reserved key")
                            case .duplicateKey: try tc.event("refused: a key pinned twice")
                        }
                        #expect(message.hasSuffix("\(conflict)"), "\(message), not \(conflict)")
                    case (.success(let keys), .failure(let message)):
                        Issue.record("the runtime keys \(keys), #schema refuses: \(message)")
                    case (.failure(let conflict), .success):
                        Issue.record("the runtime refuses (\(conflict)), #schema keys the block")
                }
            }
        }
    }

    extension TypeSchema.Default {
        /// The number this default is, if it is one.
        var numberValue: Double? {
            switch self {
                case .integer(let value): Double(value)
                case .floating(let value): value
                default: nil
            }
        }
    }

#endif
