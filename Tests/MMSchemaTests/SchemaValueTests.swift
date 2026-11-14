import MMSchema
import Testing

private let definitions = [
    TypeDefinition(
        name: "ledger.Kind",
        schema: .enumeration(cases: [
            .init(name: "credit"), .init(name: "debit"),
        ])),
    TypeDefinition(
        name: "ledger.Meta",
        schema: .structure(fields: [
            .init(key: 0, name: "note", type: .string)
        ])),
    TypeDefinition(name: "ledger.Alias", schema: .reference("ledger.Meta")),
    TypeDefinition(name: "ledger.Account", schema: .uint),
    TypeDefinition(name: "loop.A", schema: .reference("loop.B")),
    TypeDefinition(name: "loop.B", schema: .reference("loop.A")),
]
private let resolver = TypeResolver(definitions)

private func expectFailure(
    _ result: Result<SchemaValue, SchemaValueError>, path: String,
    _ comment: Comment? = nil
) {
    switch result {
        case .success:
            Issue.record(comment ?? "expected a validation failure at \(path)")
        case .failure(let error):
            #expect(error.path == path, comment)
    }
}

@Suite("SchemaValue: schema-directed canonicalization")
struct SchemaValueTests {
    @Test("the schema decides scalar kinds; lossless coercions pass")
    func scalarCoercions() throws {
        #expect(try SchemaValue.double(3).validated(against: .int, resolver: resolver).get() == .int(3))
        #expect(try SchemaValue.int(3).validated(against: .double, resolver: resolver).get() == .double(3))
        #expect(try SchemaValue.int(3).validated(against: .uint, resolver: resolver).get() == .uint(3))
        #expect(try SchemaValue.uint(3).validated(against: .int, resolver: resolver).get() == .int(3))
        #expect(try SchemaValue.int(7).validated(against: .float, resolver: resolver).get() == .double(7))
    }

    @Test("lossy coercions fail with the offending path")
    func lossyCoercions() {
        expectFailure(SchemaValue.double(3.5).validated(against: .int, resolver: resolver), path: "")
        expectFailure(SchemaValue.int(-1).validated(against: .uint, resolver: resolver), path: "")
        expectFailure(SchemaValue.bool(true).validated(against: .int, resolver: resolver), path: "")
        expectFailure(SchemaValue.int(1).validated(against: .bool, resolver: resolver), path: "")
    }

    @Test("structures canonicalize to schema field order and reject strangers")
    func structureCanonicalization() throws {
        let schema = TypeSchema.structure(fields: [
            .init(key: 0, name: "line", type: .string),
            .init(key: 1, name: "count", type: .optional(.int)),
            .init(key: 2, name: "kind", type: .reference("ledger.Kind")),
        ])
        // Members arrive out of order; canonical result follows the schema.
        let loose = SchemaValue.object([
            .init("kind", .string("credit")),
            .init("line", .string("hi")),
        ])
        let canonical = try loose.validated(against: schema, resolver: resolver).get()
        #expect(
            canonical
                == .object([
                    .init("line", .string("hi")),
                    .init("kind", .string("credit")),
                ]))

        expectFailure(
            SchemaValue.object([.init("line", .string("x")), .init("stranger", .int(1))])
                .validated(against: schema, resolver: resolver),
            path: "stranger")
        expectFailure(
            SchemaValue.object([.init("kind", .string("credit"))])
                .validated(against: schema, resolver: resolver),
            path: "line", "missing required field carries the field path")
        // Optional fields may be absent or null; required may not be null.
        _ = try SchemaValue.object([
            .init("line", .string("x")), .init("count", .null),
            .init("kind", .string("debit")),
        ]).validated(against: schema, resolver: resolver).get()
        expectFailure(
            SchemaValue.object([.init("line", .null), .init("kind", .string("credit"))])
                .validated(against: schema, resolver: resolver),
            path: "line")
    }

    @Test("enumerations accept declared cases and name the alternatives")
    func enumerations() throws {
        let schema = TypeSchema.reference("ledger.Kind")
        _ = try SchemaValue.string("debit").validated(against: schema, resolver: resolver).get()
        switch SchemaValue.string("unknown").validated(against: schema, resolver: resolver) {
            case .success:
                Issue.record("undeclared case accepted")
            case .failure(let error):
                #expect(error.problem.contains("credit"))
                #expect(error.problem.contains("debit"))
        }
    }

    @Test("reference chains resolve; unresolved and cyclic names fail with the path")
    func references() throws {
        let viaAlias = try SchemaValue.object([.init("note", .string("n"))])
            .validated(against: .reference("ledger.Alias"), resolver: resolver).get()
        #expect(viaAlias == .object([.init("note", .string("n"))]))
        expectFailure(
            SchemaValue.int(1).validated(against: .reference("no.Such"), resolver: resolver),
            path: "")
        expectFailure(
            SchemaValue.int(1).validated(against: .reference("loop.A"), resolver: resolver),
            path: "")
    }

    @Test("arrays validate per element with indexed paths")
    func arrays() {
        expectFailure(
            SchemaValue.array([.int(1), .string("x")])
                .validated(against: .array(.int), resolver: resolver),
            path: "[1]")
    }

    @Test("wire maps take integer keys as decimal text")
    func maps() throws {
        let schema = TypeSchema.map(key: .int, value: .string)
        _ = try SchemaValue.object([.init("3", .string("x"))])
            .validated(against: schema, resolver: resolver).get()
        expectFailure(
            SchemaValue.object([.init("three", .string("x"))])
                .validated(against: schema, resolver: resolver),
            path: "three")
    }

    @Test("an integer-keyed map refuses two spellings of one key")
    func repeatedIntegerKeys() {
        for spelling in ["05", "+5", "005"] {
            expectFailure(
                SchemaValue.object([.init("5", .string("x")), .init(spelling, .string("y"))])
                    .validated(against: .map(key: .int, value: .string), resolver: resolver),
                path: spelling)
        }
        expectFailure(
            SchemaValue.object([.init("7", .bool(false)), .init("07", .bool(true))])
                .validated(against: .map(key: .uint, value: .bool), resolver: resolver),
            path: "07")
        expectFailure(
            SchemaValue.object([.init("-1", .bool(false)), .init("-01", .bool(true))])
                .validated(against: .map(key: .int, value: .bool), resolver: resolver),
            path: "-01")
        expectFailure(
            SchemaValue.object([.init("0", .bool(false)), .init("-0", .bool(true))])
                .validated(against: .map(key: .int, value: .bool), resolver: resolver),
            path: "-0")
        // A string-keyed map keeps them apart: they are distinct wire keys.
        #expect(
            throws: Never.self,
            "string keys that spell one number are distinct"
        ) {
            try SchemaValue.object([.init("5", .string("x")), .init("05", .string("y"))])
                .validated(against: .map(key: .string, value: .string), resolver: resolver).get()
        }
    }

    @Test("an unsigned-keyed map refuses a negative key, and no map takes a key past 64 bits")
    func integerKeyRange() throws {
        let unsigned = TypeSchema.map(key: .uint, value: .bool)
        let signed = TypeSchema.map(key: .int, value: .bool)
        for key in ["0", "-0", "+0", "9223372036854775807"] {
            _ = try SchemaValue.object([.init(key, .bool(true))])
                .validated(against: unsigned, resolver: resolver).get()
        }
        let negative = "key is negative, and the map's keys are unsigned"
        let outOfRange = "key is out of range: a wire map key is a 64-bit signed integer"
        let refused: [(TypeSchema, String, String)] = [
            (unsigned, "-1", negative),
            (unsigned, "-9223372036854775808", negative),
            (unsigned, "9223372036854775808", outOfRange),
            (unsigned, "18446744073709551615", outOfRange),
            (signed, "-9223372036854775809", outOfRange),
            (signed, "+9223372036854775808", outOfRange),
            (signed, "1.0", "key is not an integer"),
        ]
        for (schema, key, problem) in refused {
            switch SchemaValue.object([.init(key, .bool(true))])
                .validated(against: schema, resolver: resolver)
            {
                case .success:
                    Issue.record("the map took the key \(key)")
                case .failure(let error):
                    #expect(error.path == key && error.problem == problem)
            }
        }
        // A refused key is no repeat: the first spelling of -1 is refused
        // for its sign, not the second as the same integer.
        expectFailure(
            SchemaValue.object([.init("-1", .bool(false)), .init("-01", .bool(true))])
                .validated(against: unsigned, resolver: resolver),
            path: "-1"
        )
    }

    @Test("a map's key schema resolves: a reference takes the keys of what it names")
    func referenceKeys() throws {
        // A reference to .uint takes unsigned integer keys, under .uint's rules.
        let accounts = TypeSchema.map(key: .reference("ledger.Account"), value: .bool)
        _ = try SchemaValue.object([.init("7", .bool(true))])
            .validated(against: accounts, resolver: resolver).get()
        let refused: [(TypeSchema, String, String)] = [
            (accounts, "-1", "key is negative, and the map's keys are unsigned"),
            (accounts, "x", "key is not an integer"),
            (
                .map(key: .reference("ledger.Kind"), value: .bool), "refund",
                "key is not one of: credit, debit"
            ),
            (
                .map(key: .reference("ledger.Meta"), value: .bool), "note",
                "unsupported map key schema for dynamic values: a structure can't be a map key"
            ),
            (
                .map(key: .bool, value: .bool), "true",
                "unsupported map key schema for dynamic values: a bool can't be a map key"
            ),
            (
                .map(key: .unknown, value: .bool), "x",
                "unsupported map key schema for dynamic values: an unknown shape can't be a map key"
            ),
        ]
        for (schema, key, problem) in refused {
            switch SchemaValue.object([.init(key, .bool(true))])
                .validated(against: schema, resolver: resolver)
            {
                case .success:
                    Issue.record("the map took the key \(key)")
                case .failure(let error):
                    #expect(error.path == key && error.problem == problem)
            }
        }
        expectFailure(
            SchemaValue.object([.init("7", .bool(false)), .init("07", .bool(true))])
                .validated(against: accounts, resolver: resolver),
            path: "07"
        )
        // A reference to an enumeration takes its case names.
        let kinds = SchemaValue.object([.init("credit", .bool(true)), .init("debit", .bool(false))])
        #expect(
            try kinds.validated(
                against: .map(key: .reference("ledger.Kind"), value: .bool),
                resolver: resolver
            ).get() == kinds
        )
        // A key schema that resolves to nothing fails at the map.
        switch SchemaValue.object([]).validated(
            against: .map(key: .reference("ledger.Missing"), value: .bool),
            resolver: resolver
        )
        {
            case .success:
                Issue.record("the map took an unresolved key schema")
            case .failure(let error):
                #expect(
                    error.path == ""
                        && error.problem == "unresolved type reference 'ledger.Missing'"
                )
        }
    }

    @Test("bytes take base64 strings; bad base64 fails")
    func bytes() throws {
        let canonical = try SchemaValue.string("aGk=").validated(against: .bytes, resolver: resolver).get()
        #expect(canonical == .bytes([0x68, 0x69]))
        expectFailure(SchemaValue.string("###").validated(against: .bytes, resolver: resolver), path: "")
    }

    @Test("base64 round trips including padding edges")
    func base64RoundTrip() {
        for bytes in [[], [0x00], [0xFF, 0x00], [1, 2, 3], [1, 2, 3, 4]] as [[UInt8]] {
            let text = SchemaValue.encodeBase64(bytes)
            #expect(SchemaValue.decodeBase64(text) == bytes, "bytes: \(bytes)")
        }
        #expect(SchemaValue.decodeBase64("aGVsbG8=") == Array("hello".utf8))
    }

    @Test("unknown slots pass through untouched")
    func unknownPassthrough() throws {
        let value = SchemaValue.object([.init("anything", .double(1.5))])
        #expect(try value.validated(against: .unknown, resolver: resolver).get() == value)
    }
}
