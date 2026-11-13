// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMCLI
    import MMSchema
    import MMWire
    import Testing

    @Suite("Dynamic coding properties", .hegel)
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
            try property { tc in
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
                    if case .string = keySchema {
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
