import Testing

@testable import MMSchema

// Fixture types are internal at file scope so `String(reflecting:)` yields the
// stable "MMSchemaTests.Name" form used in exact error assertions.

struct Point: Codable, Hashable {
    var x: Int
    var y: Double

    enum CodingKeys: Int, CodingKey {
        case x = 0
        case y = 1
    }
}

struct Blob: Codable {
    var name: String
    var point: Point
    var tags: [String]
    var note: String?
    var counts: [String: Int]

    enum CodingKeys: Int, CodingKey {
        case name = 0
        case point = 1
        case tags = 2
        case note = 3
        case counts = 4
    }
}

/// String-raw enum, no CaseIterable, no "" case: probeable for schema, not
/// instantiable.
enum Color: String, Codable {
    case red
    case green
}

/// Int-raw enum whose zero value is a case: instantiable from the probe's zero.
enum Level: Int, Codable {
    case zero = 0
    case one = 1
}

/// String-raw enum rescued as a field via CaseIterable.
enum Gear: String, Codable, CaseIterable {
    case fast
    case slow
}

struct WithEnums: Codable {
    var level: Level
    var gear: Gear
    var color: Color?

    enum CodingKeys: Int, CodingKey {
        case level = 0
        case gear = 1
        case color = 2
    }
}

/// Non-optional field of a non-instantiable enum: schema probing must fail
/// with a typed, actionable error.
struct HoldsColor: Codable {
    var color: Color
}

/// Associated-value enum: synthesized decoding branches on present keys, which
/// the probe cannot walk.
enum Payload: Codable {
    case number(Int)
    case text(String)
}

/// Proves the SchemaDescribable short-circuit: init(from:) is a landmine that
/// the probe must never step on.
struct SelfDescribed: Codable, SchemaDescribable {
    var raw: [UInt8]

    static var schema: TypeSchema { .bytes }

    init(raw: [UInt8]) {
        self.raw = raw
    }

    init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "probe must not run this")
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

struct HoldsDescribed: Codable {
    var blob: SelfDescribed?
}

/// Recursive class: the inner occurrence must map to .unknown, never hang.
final class Node: Codable {
    var value: Int
    var next: Node?

    init(value: Int, next: Node?) {
        self.value = value
        self.next = next
    }
}

/// Class hierarchy decoding through a *shared* decoder (`super.init(from:)`
/// with the same decoder): subclass and superclass fields merge into one
/// structure, matching the wire coder's shared-container behavior.
class SharedCoderBase: Codable {
    var a: Int

    init(a: Int) {
        self.a = a
    }

    enum CodingKeys: Int, CodingKey {
        case a = 1
    }
}

final class SharedCoderDerived: SharedCoderBase {
    var b: Int

    init(a: Int, b: Int) {
        self.b = b
        super.init(a: a)
    }

    enum CodingKeys: Int, CodingKey {
        case b = 2
    }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.b = try container.decode(Int.self, forKey: .b)
        try super.init(from: decoder)
    }

    override func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.b, forKey: .b)
        try super.encode(to: encoder)
    }
}

/// Class hierarchy decoding through `container.superDecoder()`: the wire form
/// nests the superclass under the "super" key, and the probe records that
/// position as a visible `.unknown` field rather than silently dropping it.
class SuperKeyBase: Codable {
    var a: Int

    init(a: Int) {
        self.a = a
    }

    enum CodingKeys: Int, CodingKey {
        case a = 1
    }
}

final class SuperKeyDerived: SuperKeyBase {
    var b: Int

    init(a: Int, b: Int) {
        self.b = b
        super.init(a: a)
    }

    enum CodingKeys: Int, CodingKey {
        case b = 2
    }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.b = try container.decode(Int.self, forKey: .b)
        try super.init(from: container.superDecoder())
    }

    override func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.b, forKey: .b)
        try super.encode(to: container.superEncoder())
    }
}

/// Counts init(from:) executions to make memoization observable. Only this
/// file's memoization test touches it.
struct MemoCounted: Codable {
    var value: Int

    nonisolated(unsafe) static var initRuns = 0

    init(from decoder: any Decoder) throws {
        Self.initRuns += 1
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try container.decode(Int.self, forKey: .value)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }

    enum CodingKeys: Int, CodingKey {
        case value = 0
    }
}

@Suite("SchemaProbe")
struct SchemaProbeTests {
    @Test("top-level primitives")
    func primitives() {
        #expect(TypeSchema.of(Int.self) == .success(.int))
        #expect(TypeSchema.of(UInt16.self) == .success(.uint))
        #expect(TypeSchema.of(String.self) == .success(.string))
        #expect(TypeSchema.of(Bool.self) == .success(.bool))
        #expect(TypeSchema.of(Double.self) == .success(.double))
        #expect(TypeSchema.of(Float.self) == .success(.float))
    }

    @Test("flat struct with integer keys")
    func flatStruct() {
        #expect(
            TypeSchema.of(Point.self)
                == .success(
                    .structure(fields: [
                        .init(key: 0, name: "x", type: .int),
                        .init(key: 1, name: "y", type: .double),
                    ])
                )
        )
    }

    @Test("nested struct, optional, array, and dictionary fields")
    func nestedShapes() {
        #expect(
            TypeSchema.of(Blob.self)
                == .success(
                    .structure(fields: [
                        .init(key: 0, name: "name", type: .string),
                        .init(
                            key: 1,
                            name: "point",
                            type: .structure(fields: [
                                .init(key: 0, name: "x", type: .int),
                                .init(key: 1, name: "y", type: .double),
                            ])
                        ),
                        .init(key: 2, name: "tags", type: .array(.string)),
                        .init(key: 3, name: "note", type: .optional(.string)),
                        .init(key: 4, name: "counts", type: .map(key: .string, value: .int)),
                    ])
                )
        )
    }

    @Test("top-level collections")
    func topLevelCollections() {
        #expect(TypeSchema.of([Int].self) == .success(.array(.int)))
        #expect(TypeSchema.of([[String]].self) == .success(.array(.array(.string))))
        #expect(TypeSchema.of([Int?].self) == .success(.array(.optional(.int))))
        #expect(TypeSchema.of(Int?.self) == .success(.optional(.int)))
        #expect(TypeSchema.of(Set<Int>.self) == .success(.array(.int)))
    }

    @Test("dictionary policy: any Decodable key/value probes as map")
    func dictionaryPolicy() {
        #expect(TypeSchema.of([String: Int].self) == .success(.map(key: .string, value: .int)))
        #expect(TypeSchema.of([Int: [String]].self) == .success(.map(key: .int, value: .array(.string))))
        #expect(TypeSchema.of([String: Point?].self).map { schema in
            schema == .map(
                key: .string,
                value: .optional(
                    .structure(fields: [
                        .init(key: 0, name: "x", type: .int),
                        .init(key: 1, name: "y", type: .double),
                    ])
                )
            )
        } == .success(true))
    }

    @Test("raw-representable enums probe as their raw primitive")
    func rawEnums() {
        #expect(TypeSchema.of(Color.self) == .success(.string))
        #expect(TypeSchema.of(Level.self) == .success(.int))
        #expect(TypeSchema.of(Gear.self) == .success(.string))
    }

    @Test("raw enums as fields: zero-raw case, CaseIterable rescue, optional")
    func enumFields() {
        #expect(
            TypeSchema.of(WithEnums.self)
                == .success(
                    .structure(fields: [
                        .init(key: 0, name: "level", type: .int),
                        .init(key: 1, name: "gear", type: .string),
                        .init(key: 2, name: "color", type: .optional(.string)),
                    ])
                )
        )
    }

    @Test("non-instantiable enum in a non-optional field is a typed error")
    func unconstructibleField() {
        #expect(TypeSchema.of(HoldsColor.self) == .failure(.unconstructibleType("MMSchemaTests.Color")))
    }

    @Test("associated-value enum fails the probe with a typed error")
    func associatedValueEnumFails() {
        #expect(TypeSchema.of(Payload.self) == .failure(.probeFailed("MMSchemaTests.Payload")))
    }

    @Test("SchemaDescribable short-circuits before init(from:) runs")
    func describableShortCircuit() {
        #expect(TypeSchema.of(SelfDescribed.self) == .success(.bytes))
        // And through an optional field of a containing struct.
        #expect(
            TypeSchema.of(HoldsDescribed.self)
                == .success(.structure(fields: [.init(key: nil, name: "blob", type: .optional(.bytes))]))
        )
    }

    @Test("EntityName self-describes as a string")
    func entityNameDescribes() {
        #expect(TypeSchema.of(EntityName.self) == .success(.string))
    }

    @Test("class hierarchy through a shared decoder merges superclass fields")
    func sharedCoderHierarchy() {
        #expect(
            TypeSchema.of(SharedCoderDerived.self)
                == .success(
                    .structure(fields: [
                        .init(key: 2, name: "b", type: .int),
                        .init(key: 1, name: "a", type: .int),
                    ])
                )
        )
    }

    @Test("class hierarchy through superDecoder records a visible unknown super field")
    func superDecoderHierarchy() {
        // The superclass shape cannot be attributed truthfully (its recordings
        // land in a detached probe), but the wire carries a "super" field — the
        // schema must show the position instead of silently omitting it.
        #expect(
            TypeSchema.of(SuperKeyDerived.self)
                == .success(
                    .structure(fields: [
                        .init(key: 2, name: "b", type: .int),
                        .init(key: nil, name: "super", type: .unknown),
                    ])
                )
        )
    }

    @Test("cycles map the recursive occurrence to unknown")
    func cycleSafety() {
        #expect(
            TypeSchema.of(Node.self)
                == .success(
                    .structure(fields: [
                        .init(key: nil, name: "value", type: .int),
                        .init(key: nil, name: "next", type: .optional(.unknown)),
                    ])
                )
        )
    }

    @Test("memoization: second call hits the cache")
    func memoization() {
        let expected: Result<TypeSchema, SchemaError> = .success(
            .structure(fields: [.init(key: 0, name: "value", type: .int)])
        )
        let first = TypeSchema.of(MemoCounted.self)
        let runsAfterFirst = MemoCounted.initRuns
        let second = TypeSchema.of(MemoCounted.self)
        #expect(first == expected)
        #expect(second == expected)
        #expect(runsAfterFirst == 1)
        #expect(MemoCounted.initRuns == runsAfterFirst)
    }

    @Test("builtin request types are empty payloads (target rides the envelope)")
    func builtinRequestShapes() {
        let expected: Result<TypeSchema, SchemaError> = .success(.structure(fields: []))
        #expect(TypeSchema.of(SchemaRequest.self) == expected)
        #expect(TypeSchema.of(StatRequest.self) == expected)
    }
}
