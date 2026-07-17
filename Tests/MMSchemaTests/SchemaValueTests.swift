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
