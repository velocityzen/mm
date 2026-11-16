import MMSchema
import MMWire
import NIOCore
import Testing

/// Every schema-evolution form `#schema` generates: wire defaults on scalar,
/// enum, alias and union-case fields, reserved keys and names, and
/// deprecations at every level.
enum Evolving: MethodNamespace {
    #schema("evolving") {
        Enum("Level") {
            Case("low")
            Case("high")
            Case("legacy", deprecated: "use high")
        }
        Alias("Ratio", .double, constraints: .range(0...1))
        Type("Settings", deprecated: "use Options") {
            Field("limit", .int, constraints: .range(1...100), default: 50)
            Reserved(1, "verbose")
            Field("level", "Level", default: "low")
            Field("ratio", "Ratio", default: 1)
            Field("name", .string, deprecated: "use title", default: "untitled")
            Field("title", .optional(.string))
            Field("score", .float, default: 0.5)
            Field("on", .bool, default: true)
            Field("count", .uint, default: 7)
        }
        Union("Choice") {
            Case("count") { Field("n", .uint, default: 3) }
            Case("none", deprecated: "")
        }
        Call("list", deprecated: "use search") {
            Access { .read }
            Request {
                Field("limit", .int, default: 20)
                Field("choice", "Choice")
            }
            Response {
                Field("settings", "Settings")
            }
        }
    }
}

private func decodedThroughCodable<T: Decodable>(
    _ type: T.Type,
    from buffer: ByteBuffer
) -> Result<T, MMWireError> {
    MMPackDecoder().decode(type, from: buffer)
}

private func decodedThroughGeneratedCode<T: MMPackDecodable>(
    _ type: T.Type,
    from buffer: ByteBuffer
) -> Result<T, MMWireError> {
    MMPackDecoder().decode(type, from: buffer)
}

private func encodedThroughCodable<T: Encodable>(_ value: T) -> Result<ByteBuffer, MMWireError> {
    MMPackEncoder().encode(value)
}

private func encodedThroughGeneratedCode<T: MMPackEncodable>(
    _ value: T
) -> Result<ByteBuffer, MMWireError> {
    MMPackEncoder().encode(value)
}

@Suite("Wire defaults, reserved keys and deprecations")
struct WireDefaultTests {
    @Test("the generated types honor the re-emitted contract")
    func fidelity() {
        #expect(Evolving.contract.verify(against: Evolving.self) == .success([]))
    }

    @Test("an absent key reads the default on both paths")
    func absentKeys() throws {
        let expected = Evolving.Settings(title: nil)
        #expect(
            try decodedThroughCodable(Evolving.Settings.self, from: mpBytes("80")).get() == expected
        )
        #expect(
            try decodedThroughGeneratedCode(Evolving.Settings.self, from: mpBytes("80")).get()
                == expected
        )
        #expect(expected.limit == 50)
        #expect(expected.level == .low)
        #expect(expected.ratio == 1)
        #expect(expected.score == 0.5)
        #expect(expected.on)
        #expect(expected.count == 7)
        #expect(expected == Evolving.Settings(name: "untitled", title: nil))
    }

    @Test("a nil reads the default on both paths")
    func nilValues() throws {
        // {0: nil, 4: nil}: limit and name.
        let bytes = mpBytes("8200c004c0")
        let expected = Evolving.Settings(title: nil)
        #expect(try decodedThroughCodable(Evolving.Settings.self, from: bytes).get() == expected)
        #expect(
            try decodedThroughGeneratedCode(Evolving.Settings.self, from: bytes).get() == expected
        )
    }

    @Test("a union case's field reads its default on both paths")
    func unionCaseDefault() throws {
        // {0: "count", 1: {}}.
        let bytes = mpBytes("8200a5636f756e740180")
        #expect(try decodedThroughCodable(Evolving.Choice.self, from: bytes).get() == .count(n: 3))
        #expect(
            try decodedThroughGeneratedCode(Evolving.Choice.self, from: bytes).get() == .count(n: 3)
        )
    }

    @Test("a defaulted field is always written, under keys that skip the reserved one")
    func writes() throws {
        let value = Evolving.Settings(limit: 9, title: "t")
        let codable = try encodedThroughCodable(value).get()
        #expect(try encodedThroughGeneratedCode(value).get() == codable)
        // Eight fields, so a fixmap of 8, and key 1 never appears.
        #expect(mpHex(codable).hasPrefix("880009"))
        #expect(try decodedThroughCodable(Evolving.Settings.self, from: codable).get() == value)
        #expect(
            try decodedThroughGeneratedCode(Evolving.Settings.self, from: codable).get() == value
        )
    }

    @Test("discovery serves the defaults and deprecations")
    func discovery() throws {
        let settings = try #require(Evolving.types.first { $0.name == "evolving.Settings" })
        #expect(settings.deprecation == "use Options")
        guard case .structure(let fields) = settings.schema else {
            Issue.record("Settings is not a structure")
            return
        }
        #expect(fields.map(\.key) == [0, 2, 3, 4, 5, 6, 7, 8])
        #expect(fields[0].type == .optional(.int))
        #expect(fields[0].defaultValue == .integer(50))
        #expect(fields[1].type == .optional(.reference("evolving.Level")))
        #expect(fields[1].defaultValue == .string("low"))
        #expect(fields[2].defaultValue == .floating(1))
        #expect(fields[3].deprecation == "use title")
        #expect(fields[4].defaultValue == nil)
        #expect(fields[5].defaultValue == .floating(0.5))
        #expect(fields[6].defaultValue == .bool(true))
        #expect(fields[7].defaultValue == .integer(7))

        let level = try #require(Evolving.types.first { $0.name == "evolving.Level" })
        #expect(
            level.schema
                == .enumeration(cases: [
                    .init(name: "low"), .init(name: "high"),
                    .init(name: "legacy", deprecation: "use high"),
                ])
        )
        let choice = try #require(Evolving.types.first { $0.name == "evolving.Choice" })
        guard case .union(let cases) = choice.schema else {
            Issue.record("Choice is not a union")
            return
        }
        #expect(cases.map(\.deprecation) == [nil, ""])
        #expect(try Evolving.list.signature().get().deprecation == "use search")
    }

    @Test("the defaulted set of the wire spec's conformance vectors")
    func conformanceVector() {
        let signature = MethodSignature(
            name: "shelf.list",
            access: .read,
            request: .structure(fields: [
                .init(
                    key: 0,
                    name: "limit",
                    type: .optional(.int),
                    constraints: TypeSchema.Constraints(
                        minimum: .integer(1),
                        maximum: .integer(100)
                    ),
                    defaultValue: .integer(50)
                ),
                .init(
                    key: 1,
                    name: "ratio",
                    type: .optional(.double),
                    defaultValue: .floating(0.5)
                ),
                .init(key: 2, name: "on", type: .optional(.bool), defaultValue: .bool(true)),
                .init(
                    key: 3,
                    name: "shelf",
                    type: .optional(.reference("shelf.Shelf")),
                    defaultValue: .string("top")
                ),
            ]),
            response: .structure(fields: [.init(key: 0, name: "count", type: .uint)])
        )
        let shelf = TypeDefinition(
            name: "shelf.Shelf",
            schema: .enumeration(cases: [.init(name: "top"), .init(name: "attic")])
        )
        #expect(SchemaFingerprint.compute([signature], types: [shelf]) == 0xa46a57e6_975801ba)
    }

    @Test("a deprecation is documentation: the fingerprint and comparisons ignore it")
    func deprecationIsDocumentation() {
        let stripped = Evolving.contract.signatures.map(\.strippingDescriptions)
        #expect(stripped.allSatisfy { $0.deprecation == nil })
        #expect(
            SchemaFingerprint.compute(
                Evolving.contract.signatures,
                types: Evolving.contract.types
            )
                == SchemaFingerprint.compute(
                    stripped,
                    types: Evolving.contract.types.map(\.strippingDescriptions)
                )
        )
    }
}
