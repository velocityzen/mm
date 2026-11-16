import Foundation
import MMSchema
import MMWire
import Testing

/// Named scalars through their generated MessagePack code.
private enum Tally: TypeNamespace {
    #schemaTypes("tally") {
        Alias("Name", .string, constraints: .nonEmpty)
        Alias("Score", .int, constraints: .range(0...10))
        Alias("Ratio", .float)
        Alias("Seen", .bool)
        Alias("Blob", .bytes, constraints: .length(...4))
        Alias("Day", .date)
        Type("Entry") {
            Field("name", .reference("Name"))
            Field("scores", .array(.reference("Score")))
            Field("ratio", .optional(.reference("Ratio")))
        }
    }
}

@Suite("Named scalars in MessagePack")
struct AliasPackTests {
    @Test("a named scalar is written as its bare scalar and read back")
    func bareScalar() throws {
        let score: Tally.Score = 7
        #expect(try MMPackEncoder().encode(score).get() == MMPackEncoder().encode(7).get())
        let packed = try MMPackEncoder().encode(Tally.Name("ann")).get()
        #expect(packed == (try MMPackEncoder().encode("ann").get()))
        #expect(try MMPackDecoder().decode(Tally.Name.self, from: packed).get() == "ann")
        let blob = Tally.Blob(MMBytes([1, 2]))
        let packedBlob = try MMPackEncoder().encode(blob).get()
        #expect(try MMPackDecoder().decode(Tally.Blob.self, from: packedBlob).get() == blob)
        let day = Tally.Day(MMDate(year: 2026, month: 11, day: 15)!)
        let packedDay = try MMPackEncoder().encode(day).get()
        #expect(try MMPackDecoder().decode(Tally.Day.self, from: packedDay).get() == day)
    }

    @Test("a structure of named scalars is coded as one of their scalars")
    func structureOfAliases() throws {
        let entry = Tally.Entry(name: "ann", scores: [1, 2], ratio: 0.5)
        let packed = try MMPackEncoder().encode(entry).get()
        #expect(try MMPackDecoder().decode(Tally.Entry.self, from: packed).get() == entry)
        let viaCodable = try MMPackDecoder().decoding(Tally.Entry.self)(packed).get()
        #expect(viaCodable == entry)
        #expect(
            Tally.Entry(name: "ann", scores: [1, 11], ratio: nil).constraintViolation(at: "")
                == SchemaValueError(path: "scores[1]", problem: "is 11, more than the maximum 10"))
    }

    @Test("the generated types honor the re-emitted contract")
    func contractFidelity() throws {
        #expect(Tally.contract.verify(against: Tally.self) == [])
    }
}

@Suite("Constraints on the wire and in the fingerprint")
struct ConstraintWireTests {
    /// A field as a peer from before constraints reads it: keys 0 to 3.
    struct OlderField: Codable, Equatable {
        var key: Int?
        var name: String
        var type: TypeSchema
        var description: String?

        enum CodingKeys: Int, CodingKey {
            case key = 0
            case name = 1
            case type = 2
            case description = 3
        }
    }

    /// A definition as a peer from before constraints reads it: keys 0 to 2.
    struct OlderDefinition: Codable, Equatable {
        var name: String
        var schema: TypeSchema
        var description: String?

        enum CodingKeys: Int, CodingKey {
            case name = 0
            case schema = 1
            case description = 2
        }
    }

    static let constraints = TypeSchema.Constraints(
        minimum: .integer(-3), maximum: .floating(2.5), minimumLength: 0, maximumLength: 9,
        pattern: "a+")

    @Test("a field's and a definition's constraints round-trip through MessagePack and JSON")
    func roundTrip() throws {
        let field = TypeSchema.Field(key: 2, name: "n", type: .int, constraints: Self.constraints)
        let definition = TypeDefinition(name: "a.B", schema: .string, constraints: Self.constraints)
        let packedField = try MMPackEncoder().encode(field).get()
        #expect(try MMPackDecoder().decode(TypeSchema.Field.self, from: packedField).get() == field)
        let packedDefinition = try MMPackEncoder().encode(definition).get()
        #expect(try MMPackDecoder().decode(TypeDefinition.self, from: packedDefinition).get() == definition)
        let json = try JSONEncoder().encode(definition)
        #expect(try JSONDecoder().decode(TypeDefinition.self, from: json) == definition)
    }

    @Test("an older peer reads a constrained field and definition, skipping the constraints")
    func olderPeer() throws {
        let field = TypeSchema.Field(key: 2, name: "n", type: .int, constraints: Self.constraints)
        let packedField = try MMPackEncoder().encode(field).get()
        #expect(
            try MMPackDecoder().decode(OlderField.self, from: packedField).get()
                == OlderField(key: 2, name: "n", type: .int))
        let definition = TypeDefinition(name: "a.B", schema: .string, constraints: Self.constraints)
        let packedDefinition = try MMPackEncoder().encode(definition).get()
        #expect(
            try MMPackDecoder().decode(OlderDefinition.self, from: packedDefinition).get()
                == OlderDefinition(name: "a.B", schema: .string))
    }

    @Test("an unconstrained field or definition is coded as it was before constraints")
    func unconstrainedBytesUnchanged() throws {
        let field = TypeSchema.Field(key: 2, name: "n", type: .int)
        #expect(
            try MMPackEncoder().encode(field).get()
                == MMPackEncoder().encode(OlderField(key: 2, name: "n", type: .int)).get())
        let definition = TypeDefinition(name: "a.B", schema: .string)
        #expect(
            try MMPackEncoder().encode(definition).get()
                == MMPackEncoder().encode(OlderDefinition(name: "a.B", schema: .string)).get())
    }

    @Test("a rule a peer cannot read decodes as absent, not as a failure")
    func unreadableRules() throws {
        let json = #"{"minimum":"x","maximum":-4,"minimumLength":-1,"maximumLength":"y","pattern":7}"#
        let decoded = try JSONDecoder().decode(
            TypeSchema.Constraints.self, from: Data(json.utf8))
        #expect(decoded == TypeSchema.Constraints(maximum: .integer(-4)))
    }

    static func signature(_ constraints: TypeSchema.Constraints?) -> MethodSignature {
        MethodSignature(
            name: "a.put",
            access: .write,
            request: .structure(fields: [
                .init(key: 0, name: "n", type: .int, constraints: constraints)
            ]),
            response: .structure(fields: [])
        )
    }

    @Test("constraints are hashed: editing one changes the fingerprint")
    func fingerprintEdits() {
        let none = SchemaFingerprint.compute([Self.signature(nil)], types: [])
        let empty = SchemaFingerprint.compute([Self.signature(TypeSchema.Constraints())], types: [])
        let low = SchemaFingerprint.compute(
            [Self.signature(TypeSchema.Constraints(minimum: .integer(1)))], types: [])
        let lowFloating = SchemaFingerprint.compute(
            [Self.signature(TypeSchema.Constraints(minimum: .floating(1)))], types: [])
        let high = SchemaFingerprint.compute(
            [Self.signature(TypeSchema.Constraints(maximum: .integer(1)))], types: [])
        // Constraints with no rule are no constraints.
        #expect(empty == none)
        #expect(Set([none, low, lowFloating, high]).count == 4)
        let plain = TypeDefinition(name: "a.B", schema: .string)
        let constrained = TypeDefinition(
            name: "a.B", schema: .string, constraints: TypeSchema.Constraints(pattern: "b"))
        #expect(
            SchemaFingerprint.compute([], types: [plain])
                != SchemaFingerprint.compute([], types: [constrained]))
        #expect(
            SchemaFingerprint.compute([], types: [plain])
                == SchemaFingerprint.compute(
                    [], types: [TypeDefinition(name: "a.B", schema: .string, constraints: .init())]))
    }

    @Test("the constrained conformance vector of the wire spec")
    func conformanceVector() {
        let signature = MethodSignature(
            name: "shelf.put",
            access: .write,
            request: .structure(fields: [
                .init(
                    key: 0, name: "slug", type: .reference("shelf.Slug")),
                .init(
                    key: 1, name: "limit", type: .optional(.int),
                    constraints: TypeSchema.Constraints(minimum: .integer(1), maximum: .integer(1000))),
                .init(
                    key: 2, name: "ratio", type: .double,
                    constraints: TypeSchema.Constraints(minimum: .floating(0), maximum: .floating(1))),
            ]),
            response: .structure(fields: [])
        )
        let slug = TypeDefinition(
            name: "shelf.Slug", schema: .string,
            constraints: TypeSchema.Constraints(
                minimumLength: 1, maximumLength: 8, pattern: "[a-z0-9-]+"))
        #expect(SchemaFingerprint.compute([signature], types: [slug]) == 0x5cfed00a_36d1f62b)
    }
}

