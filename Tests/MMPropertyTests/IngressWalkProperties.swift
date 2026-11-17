// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMCLI
    import MMSchema
    import MMWire
    import NIOCore
    import Testing

    @Suite("The ingress walk", .hegel, .offTheCooperativePool)
    struct IngressWalkProperties {
        /// The walk ingress runs over params that did not decode finds
        /// nothing wrong with the bytes of a value that fits the schema, and
        /// in the bytes of one whose root field `n` holds a bool (a string
        /// where a bool belongs) and whose other fields fit, it names field
        /// `n` and the kinds it expected and found:
        /// `expected unsigned integer, got bool`.
        @Test
        func theWalkNamesTheFirstFieldThatDoesNotFit() throws {
            try property(
                reaching: ["fits", "one field holds the wrong kind"],
                reachingAfter: [
                    "a later field holds the wrong kind": 1_000,
                    "an optional field holds the wrong kind": 1_000,
                    "a field of a named type holds the wrong kind": 1_000,
                    "expected bool": 1_000,
                    "expected integer": 1_000,
                    "expected unsigned integer": 1_000,
                    "expected float": 1_000,
                    "expected string": 1_000,
                    "expected bytes": 1_000,
                    "expected array": 1_000,
                    "expected map": 1_000,
                    "expected date": 1_000,
                    "expected datetime": 1_000,
                    "expected timestamp": 1_000,
                    "expected duration": 1_000,
                ]
            ) { tc in
                let policy = try #draw(SchemaValueGenerators.policies(unknownSlots: false), from: tc)
                let fitting = try #draw(SchemaValueGenerators.fitting(policy), from: tc)
                var definitions = fitting.definitions
                // A request's root is a structure.
                var schema = fitting.schema
                var value = fitting.value
                if case .structure = try DefinitionTable(definitions).resolve(schema) {
                } else {
                    schema = .structure(fields: [TypeSchema.Field(key: nil, name: "value", type: schema)])
                    value = .object([SchemaValue.Member("value", value)])
                }
                guard case .structure(var fields) = try DefinitionTable(definitions).resolve(schema),
                    case .object(var members) = value
                else { throw GeneratorFault(description: "the root is not a structure") }
                // One or two more fields, mostly of one kind drawn for the
                // case and sometimes optional or of a named type, among the
                // drawn ones: every kind is often the one corrupted.
                let focus = try #draw(.element(of: extraKinds), from: tc)
                var extras: [Int] = []
                for extra in 0..<(try #draw(.int(in: 1...2), from: tc)) {
                    let name = "extra \(extra)"
                    guard !fields.contains(where: { $0.name == name }) else { continue }
                    var type = try #draw(.bool(probability: 0.8), from: tc) ? focus : try #draw(.element(of: extraKinds), from: tc)
                    if try #draw(.bool(probability: 0.3), from: tc) {
                        definitions.append(TypeDefinition(name: "walk.Extra\(extra)", schema: type))
                        type = .reference("walk.Extra\(extra)")
                    }
                    if try #draw(.bool(probability: 0.25), from: tc) { type = .optional(type) }
                    let position = try #draw(.int(in: 0...fields.count), from: tc)
                    fields.insert(TypeSchema.Field(key: nil, name: name, type: type), at: position)
                    extras = extras.map { $0 >= position ? $0 + 1 : $0 } + [position]
                }
                let table = DefinitionTable(definitions)
                let values = ValueDrawing(policy: policy, table: table)
                for index in extras {
                    members.append(SchemaValue.Member(fields[index].name, try values.value(tc, for: fields[index].type, depth: 0)))
                }
                schema = .structure(fields: fields)
                value = .object(members)
                let resolver = TypeResolver(definitions)

                let fits = try encoded(schema, value, definitions: definitions)
                try tc.event("fits")
                #expect(MMPackDecoder().firstProblem(in: fits, against: schema, resolver: resolver) == nil)

                let present = fields.indices.filter { index in
                    members.contains { $0.name == fields[index].name }
                }
                guard try #draw(.bool(probability: 0.85), from: tc) else { return }
                let corrupted =
                    try #draw(.bool(probability: 0.8), from: tc)
                    ? try #draw(.element(of: extras), from: tc) : try #draw(.element(of: present), from: tc)
                let field = fields[corrupted]
                let expected = try expectedKind(field.type, table)
                let wrong: (schema: TypeSchema, value: SchemaValue, name: String) =
                    expected == "bool" ? (.string, .string("x"), "string") : (.bool, .bool(true), "bool")
                var wrongFields = fields
                wrongFields[corrupted].type = wrong.schema
                let wrongMembers = members.map { member in
                    member.name == field.name ? SchemaValue.Member(member.name, wrong.value) : member
                }
                try tc.event("one field holds the wrong kind")
                try tc.event("expected \(expected)")
                if present.first != corrupted { try tc.event("a later field holds the wrong kind") }
                if case .optional = field.type { try tc.event("an optional field holds the wrong kind") }
                if try table.resolve(field.type) != field.type {
                    try tc.event("a field of a named type holds the wrong kind")
                }
                let bytes = try encoded(.structure(fields: wrongFields), .object(wrongMembers), definitions: definitions)
                #expect(
                    MMPackDecoder().firstProblem(in: bytes, against: schema, resolver: resolver)
                        == SchemaValueError(path: field.name, problem: "expected \(expected), got \(wrong.name)"))
            }
        }
    }

    /// The kinds of the fields added: every scalar kind, an enumeration
    /// among them, an array and a map.
    private let extraKinds: [TypeSchema] = [
        .bool, .int, .uint, .float, .double, .string, .bytes, .date, .datetime, .timestamp,
        .duration,
        .enumeration(cases: [TypeSchema.EnumCase(name: "on"), TypeSchema.EnumCase(name: "off")]),
        .array(.int), .map(key: .string, value: .int),
    ]

    /// The bytes the CLI's dynamic request writes for `value`.
    private func encoded(
        _ schema: TypeSchema, _ value: SchemaValue, definitions: [TypeDefinition]
    ) throws -> ByteBuffer {
        let request = try MMCLIDynamicRequest(schema: schema, definitions: definitions, json: value)
        return try MMPackEncoder().encode(request).get()
    }

    /// The kind the walk expects of a value of `schema`, named as its
    /// problems name it: optionals and named types looked through, a
    /// structure and a union read as a map, an enumeration as a string.
    private func expectedKind(_ schema: TypeSchema, _ table: DefinitionTable) throws -> String {
        switch try table.resolve(schema) {
            case .optional(let wrapped): try expectedKind(wrapped, table)
            case .bool: "bool"
            case .int: "integer"
            case .uint: "unsigned integer"
            case .float, .double: "float"
            case .string, .enumeration: "string"
            case .bytes: "bytes"
            case .date: "date"
            case .datetime: "datetime"
            case .timestamp: "timestamp"
            case .duration: "duration"
            case .array: "array"
            case .map, .structure, .union: "map"
            case .reference, .unknown:
                throw GeneratorFault(description: "no kind to expect of \(schema)")
        }
    }

#endif
