// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import Foundation
    import HegelTesting
    import MMCLI
    import MMSchema
    import Testing

    @Suite("Dynamic JSON properties", .hegel)
    struct DynamicJSONProperties {
        /// A canonical value rendered as JSON text, compact or pretty, parses
        /// and validates back to itself: bytes through base64, a whole double
        /// that parses as an integer back to a double, a uint past
        /// `Int64.max` back to a uint. A non-finite double renders as null,
        /// so it comes back null in an optional slot and is refused where
        /// null does not fit. Map members may come back in any order, since
        /// a JSON object has none; everything else comes back identical.
        ///
        /// `.unknown` slots stay out: `validated` passes them through as
        /// parsed, kinds and member order included, so they have no value to
        /// come back to.
        ///
        /// Mutation check: rendering a non-finite double as text, a double
        /// at `Float` precision, a uint as signed or a member name
        /// unescaped; or parsing without the boolean branch, the `UInt64`
        /// band or the negative-zero branch, or reading only an object's
        /// first member, fails here. A 100-case run catches most of them,
        /// and a 1,000-case run all of them: a non-finite double and a
        /// negative zero each turn up in only a few percent of cases.
        ///
        /// An enumeration case with a control character is recorded but not
        /// claimed: few test cases render an enumeration value of such a
        /// name, as one name in the pool has them. `stringsRenderAndParseBack`
        /// leans on every control character in a rendered string.
        @Test
        func renderedValuesParseAndValidateBack() throws {
            try property(
                reaching: [
                    "a field name beyond ASCII", "an optional field left out", "validated back",
                ],
                reachingAfter: [
                    "a bool": 1_000, "a date": 1_000, "a datetime": 1_000,
                    "a definition inside itself": 1_000, "a double": 1_000,
                    "a double parsed as a double": 1_000,
                    "a field name with a control character": 1_000,
                    "a field name with a quote or a backslash": 1_000, "a float": 1_000,
                    "a later enumeration case": 1_000, "a map keyed by integers": 1_000,
                    "a map keyed by unsigned integers": 1_000, "a negative map key": 1_000,
                    "a reference chain": 1_000, "a string": 1_000, "a timestamp": 1_000,
                    "a duration": 1_000, "a uuid": 1_000,
                    "a uint": 1_000, "a union case with fields": 1_000,
                    "a union case without fields": 1_000, "a value four levels deep": 1_000,
                    "an array with items": 1_000, "an empty array": 1_000, "an empty map": 1_000,
                    "an empty structure": 1_000, "an enumeration case beyond ASCII": 1_000,
                    "an int": 1_000,
                    "an optional field set to null": 1_000, "bytes": 1_000,
                    "null in an optional slot": 1_000, "the first enumeration case": 1_000,
                ]
            ) { tc in
                var policy = try #draw(
                    SchemaValueGenerators.policies(unknownSlots: false),
                    from: tc
                )
                policy.doublesInFloatSlots = try #draw(Gen<Bool>.bool(), from: tc)
                // A quarter of the cases are about maps, whose keys render as
                // text, a quarter about arrays, and a quarter about
                // references, chains and recursive definitions among them.
                let focus = try #draw(
                    Gen<SchemaValueFocus?>.element(of: [nil, .maps, .arrays, .references]),
                    from: tc
                )
                if let focus { policy.focus(on: focus) }
                let fitting = try #draw(SchemaValueGenerators.fitting(policy), from: tc)
                let pretty = try #draw(Gen<Bool>.bool(), from: tc)
                for label in reachLabels(of: fitting).sorted() {
                    try tc.event(label)
                }

                var rendering = JSONRendering(table: DefinitionTable(fitting.definitions))
                let expected = try rendering.expected(fitting.value, as: fitting.schema)
                for label in rendering.labels.sorted() {
                    try tc.event(label)
                }
                let text = MMCLIDynamicJSONText(fitting.value, pretty: pretty)
                let parsed: SchemaValue
                do {
                    parsed = try MMCLIDynamicTree.parse(jsonText: text)
                } catch {
                    Issue.record("the rendering \(text) does not parse: \(error)")
                    return
                }
                switch (
                    parsed.validated(against: fitting.schema, resolver: fitting.resolver),
                    expected
                ) {
                    case (.success(let back), .value(let value)):
                        try tc.event("validated back")
                        #expect(
                            identical(
                                try rendering.sortingMaps(back, as: fitting.schema),
                                try rendering.sortingMaps(value, as: fitting.schema)
                            ),
                            "\(fitting.value) rendered as \(text) and validated back as \(back)"
                        )
                    case (.failure, .null), (.failure, .refused):
                        try tc.event("refused: null where a number belongs")
                    case (.success(let back), .null), (.success(let back), .refused):
                        Issue.record(
                            "\(text) validated as \(back), though a non-finite double became null where null does not fit"
                        )
                    case (.failure(let error), .value):
                        Issue.record(
                            "\(text) parsed to \(parsed), which does not validate: \(error)"
                        )
                }
            }
        }

        /// Any string renders as a JSON string with no raw control character
        /// in it, which parses back to the same UTF-8, as a value and as an
        /// object key. The text leans on what JSON escapes or might trip on:
        /// every control character, a quote, a backslash, a slash, DEL, the
        /// line and paragraph separators, a byte order mark, a noncharacter,
        /// an astral emoji and a combining accent. A third of the strings
        /// start with what a parser might trim: a byte order mark either way
        /// round, whitespace or NUL.
        ///
        /// Mutation check: a quote left unescaped, control characters
        /// escaped only below 0x10, a `\u` escape one digit short, `\b` and
        /// `\f` swapped, or a leading U+FEFF dropped from a string or from a
        /// key (as `JSONSerialization` drops it), fails here at 100 cases.
        @Test
        func stringsRenderAndParseBack() throws {
            let awkward: [Unicode.Scalar] =
                (0..<0x20).compactMap { Unicode.Scalar($0) } + [
                    "\"", "\\", "/", "\u{7F}", "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{FFFF}",
                    "\u{1F600}", "e", "\u{301}",
                ]
            // What a parser might trim from the start of a string: a byte
            // order mark either way round, whitespace and NUL.
            let leading: [String] = ["\u{FEFF}", "\u{FFFE}", " ", "\t", "\u{0}"]
            try property(
                reaching: ["a control character"],
                reachingAfter: [
                    "a leading byte order mark": 1_000, "a quote or a backslash": 1_000,
                    "a scalar past the Basic Multilingual Plane": 1_000, "an empty string": 1_000,
                ]
            ) { tc in
                var text = try #draw(
                    Gen<String>.oneOf(
                        Gen<[Unicode.Scalar]>.array(of: .element(of: awkward), count: 0...8)
                            .map { String(String.UnicodeScalarView($0)) },
                        .string()
                    ),
                    from: tc
                )
                if try #draw(Gen<Bool>.bool(probability: 1.0 / 3), from: tc) {
                    text = try #draw(Gen<String>.element(of: leading), from: tc) + text
                }
                let scalars = text.unicodeScalars
                if text.isEmpty { try tc.event("an empty string") }
                if scalars.first == "\u{FEFF}" { try tc.event("a leading byte order mark") }
                if scalars.contains(where: { $0.value < 0x20 }) {
                    try tc.event("a control character")
                }
                if scalars.contains(where: { $0 == "\"" || $0 == "\\" }) {
                    try tc.event("a quote or a backslash")
                }
                if scalars.contains(where: { $0.value > 0xFFFF }) {
                    try tc.event("a scalar past the Basic Multilingual Plane")
                }
                let rendered = MMCLIDynamicJSONText(.string(text), pretty: false)
                #expect(
                    !rendered.unicodeScalars.contains { $0.value < 0x20 },
                    "\(text.debugDescription) rendered with a raw control character"
                )
                guard case .string(let back) = try MMCLIDynamicTree.parse(jsonText: rendered)
                else {
                    Issue.record("\(rendered) did not parse as a string")
                    return
                }
                #expect(
                    Array(back.utf8) == Array(text.utf8),
                    "\(text.debugDescription) came back as \(back.debugDescription)"
                )
                let keyed = MMCLIDynamicJSONText(
                    .object([SchemaValue.Member(text, .null)]),
                    pretty: false
                )
                guard case .object(let members) = try MMCLIDynamicTree.parse(jsonText: keyed),
                    members.count == 1
                else {
                    Issue.record("\(keyed) did not parse as an object with one member")
                    return
                }
                #expect(
                    Array(members[0].name.utf8) == Array(text.utf8),
                    "\(text.debugDescription) came back as the key \(members[0].name.debugDescription)"
                )
            }
        }

        /// Bytes render as standard padded base64, as Foundation writes it:
        /// any length, so each of the three padding cases.
        ///
        /// Mutation check: the URL-safe alphabet in place of `+` and `/`
        /// fails here at 100 cases, before the round trip above draws bytes
        /// that need either.
        @Test
        func bytesRenderAsStandardBase64() throws {
            try property(
                reaching: [
                    "length 0 past a multiple of three", "length 1 past a multiple of three",
                ],
                reachingAfter: ["length 2 past a multiple of three": 1_000]
            ) { tc in
                let bytes = try #draw(Gen<[UInt8]>.bytes(), from: tc)
                try tc.event("length \(bytes.count % 3) past a multiple of three")
                #expect(
                    MMCLIDynamicJSONText(.bytes(bytes), pretty: false)
                        == "\"" + Data(bytes).base64EncodedString() + "\""
                )
            }
        }
    }

    /// What validating the parsed JSON rendering of a canonical value gives:
    /// the value itself, null where a non-finite double became null, or a
    /// refusal where such a null lands in a slot null does not fit.
    enum RenderedOutcome {
        case value(SchemaValue)
        case null
        case refused
    }

    struct JSONRendering {
        let table: DefinitionTable
        var labels: Set<String> = []

        mutating func expected(_ value: SchemaValue, as schema: TypeSchema) throws
            -> RenderedOutcome
        {
            switch (try table.resolve(schema), value) {
                case (.optional, .null):
                    return .value(.null)
                case (.optional(let wrapped), _):
                    let outcome = try expected(value, as: wrapped)
                    guard case .null = outcome else { return outcome }
                    labels.insert("a non-finite double in an optional slot")
                    return .value(.null)
                case (.double, .double(let number)), (.float, .double(let number)):
                    guard number.isFinite else {
                        labels.insert("a non-finite double")
                        return .null
                    }
                    if number == 0, number.sign == .minus {
                        labels.insert("a negative zero")
                    } else if Int64(exactly: number) != nil {
                        labels.insert("a whole double, parsed as an int")
                    } else if UInt64(exactly: number) != nil {
                        labels.insert("a whole double, parsed as a uint")
                    } else {
                        labels.insert("a double parsed as a double")
                    }
                    return .value(value)
                case (.uint, .uint(let number)):
                    if number > UInt64(Int64.max) { labels.insert("a uint past Int64.max") }
                    return .value(value)
                case (.bytes, .bytes(let bytes)):
                    labels.insert("bytes, \(bytes.count % 3) past a multiple of three")
                    return .value(value)
                case (.string, .string(let text)):
                    label(text, as: "a string")
                    return .value(value)
                case (.enumeration, .string(let text)):
                    label(text, as: "an enumeration case")
                    return .value(value)
                case (.array(let element), .array(let items)):
                    var results: [SchemaValue] = []
                    for item in items {
                        guard case .value(let result) = try expected(item, as: element) else {
                            return .refused
                        }
                        results.append(result)
                    }
                    return .value(.array(results))
                case (.map(_, let valueSchema), .object(let members)):
                    var results: [SchemaValue.Member] = []
                    for member in members {
                        label(member.name, as: "a map key")
                        guard case .value(let result) = try expected(member.value, as: valueSchema)
                        else { return .refused }
                        results.append(SchemaValue.Member(member.name, result))
                    }
                    return .value(.object(results))
                case (.structure(let fields), .object(let members)):
                    var results: [SchemaValue.Member] = []
                    for member in members {
                        guard let field = fields.first(where: { $0.name == member.name }) else {
                            throw GeneratorFault(description: "no field '\(member.name)'")
                        }
                        label(member.name, as: "a field name")
                        guard case .value(let result) = try expected(member.value, as: field.type)
                        else { return .refused }
                        results.append(SchemaValue.Member(member.name, result))
                    }
                    return .value(.object(results))
                case (.union(let cases), .object(let members)):
                    guard
                        case .string(let name)? = members.first(where: { $0.name == "case" })?
                            .value,
                        let chosen = cases.first(where: { $0.name == name })
                    else {
                        throw GeneratorFault(description: "not a union value: \(value)")
                    }
                    var results: [SchemaValue.Member] = []
                    for member in members {
                        guard member.name == "fields" else {
                            results.append(member)
                            continue
                        }
                        guard
                            case .value(let result) = try expected(
                                member.value,
                                as: .structure(fields: chosen.fields)
                            )
                        else { return .refused }
                        results.append(SchemaValue.Member(member.name, result))
                    }
                    return .value(.object(results))
                default:
                    return .value(value)
            }
        }

        /// The value with every map's members in the order of their keys'
        /// UTF-8 bytes, so two values that differ only in map member order
        /// compare identical.
        func sortingMaps(_ value: SchemaValue, as schema: TypeSchema) throws -> SchemaValue {
            switch (try table.resolve(schema), value) {
                case (.optional, .null):
                    return value
                case (.optional(let wrapped), _):
                    return try sortingMaps(value, as: wrapped)
                case (.array(let element), .array(let items)):
                    return .array(try items.map { try sortingMaps($0, as: element) })
                case (.map(_, let valueSchema), .object(let members)):
                    return .object(
                        try members.map {
                            SchemaValue.Member($0.name, try sortingMaps($0.value, as: valueSchema))
                        }
                        .sorted {
                            Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8))
                        }
                    )
                case (.structure(let fields), .object(let members)):
                    return .object(
                        try members.map { member in
                            guard let field = fields.first(where: { $0.name == member.name }) else {
                                return member
                            }
                            return SchemaValue.Member(
                                member.name,
                                try sortingMaps(member.value, as: field.type)
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
                                try sortingMaps(member.value, as: .structure(fields: chosen.fields))
                            )
                        }
                    )
                default:
                    return value
            }
        }

        /// What a piece of text needs from the JSON string writer.
        mutating func label(_ text: String, as kind: String) {
            if text.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" }) {
                labels.insert("\(kind) with a quote or a backslash")
            }
            if text.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                labels.insert("\(kind) with a control character")
            }
            if text.unicodeScalars.contains(where: { $0.value > 0x7F }) {
                labels.insert("\(kind) beyond ASCII")
            }
        }
    }

#endif
