import MMWire
import NIOCore
import Testing

/// A nested Codable fixture exercising integer-keyed maps, string-keyed maps,
/// optionals, arrays, dictionaries, multi-byte UTF-8, floats (including -0.0 and
/// infinities), the full integer range, and zero-copy ByteBuffer payloads.
struct Fixture: Codable, Equatable {
    var flag: Bool
    var tiny: Int8
    var medium: Int32
    var big: Int64
    var unsigned: UInt64
    var smallUnsigned: UInt16
    var double: Double
    var float: Float
    var text: String
    var maybeText: String?
    var ints: [Int]
    var doubles: [Double]
    var stringMap: [String: Int32]
    var intMap: [Int: String]
    var blob: ByteBuffer
    var nested: Nested
    var maybeNested: Nested?

    struct Nested: Codable, Equatable {
        var values: [Double]
        var label: String?
        var inner: Inner?

        struct Inner: Codable, Equatable {
            var a: Int
            var b: [UInt16]

            enum CodingKeys: Int, CodingKey {
                case a = 1
                case b = 2
            }
        }

        enum CodingKeys: Int, CodingKey {
            case values = 1
            case label = 2
            case inner = 3
        }
    }

    enum CodingKeys: Int, CodingKey {
        case flag = 1
        case tiny = 2
        case medium = 3
        case big = 4
        case unsigned = 5
        case smallUnsigned = 6
        case double = 7
        case float = 8
        case text = 9
        case maybeText = 10
        case ints = 11
        case doubles = 12
        case stringMap = 13
        case intMap = 14
        case blob = 15
        case nested = 16
        case maybeNested = 17
    }
}

private let stringPool: [String] = [
    "", "a", "hello", "héllo wörld", "日本語のテキスト", "🙂🎉🚀", "key.path", "42",
    String(repeating: "x", count: 40), "line\nbreak\t tab",
]

private let doublePool: [Double] = [
    0.0, -0.0, 1.5, -1.5, .infinity, -.infinity, 1.1,
    .greatestFiniteMagnitude, .leastNonzeroMagnitude, .pi,
]

private let int64Pool: [Int64] = [
    0, 1, -1, 127, 128, -32, -33, 255, 256, 65535, 65536,
    4_294_967_295, 4_294_967_296, .max, .min,
]

private func randomString(using rng: inout SplitMix64) -> String {
    if Bool.random(using: &rng) {
        return stringPool.randomElement(using: &rng)!
    }
    let length = Int.random(in: 0...40, using: &rng)
    let scalars = "abcdefghijklmnopqrstuvwxyz0123456789éß語🙂"
    return String((0..<length).map { _ in scalars.randomElement(using: &rng)! })
}

private func randomDouble(using rng: inout SplitMix64) -> Double {
    if Bool.random(using: &rng) {
        return doublePool.randomElement(using: &rng)!
    }
    return Double.random(in: -1e12...1e12, using: &rng)
}

private func randomInt64(using rng: inout SplitMix64) -> Int64 {
    if Bool.random(using: &rng) {
        return int64Pool.randomElement(using: &rng)!
    }
    return Int64(bitPattern: rng.next())
}

private func randomNested(using rng: inout SplitMix64) -> Fixture.Nested {
    Fixture.Nested(
        values: (0..<Int.random(in: 0...8, using: &rng)).map { _ in randomDouble(using: &rng) },
        label: Bool.random(using: &rng) ? randomString(using: &rng) : nil,
        inner: Bool.random(using: &rng)
            ? Fixture.Nested.Inner(
                a: Int(truncatingIfNeeded: randomInt64(using: &rng)),
                b: (0..<Int.random(in: 0...6, using: &rng)).map { _ in
                    UInt16.random(in: .min ... .max, using: &rng)
                }
            )
            : nil
    )
}

private func randomFixture(using rng: inout SplitMix64) -> Fixture {
    var stringMap: [String: Int32] = [:]
    for _ in 0..<Int.random(in: 0...6, using: &rng) {
        stringMap[randomString(using: &rng)] = Int32.random(in: .min ... .max, using: &rng)
    }
    var intMap: [Int: String] = [:]
    for _ in 0..<Int.random(in: 0...6, using: &rng) {
        intMap[Int.random(in: -100_000...100_000, using: &rng)] = randomString(using: &rng)
    }
    let blobLength = Int.random(in: 0...48, using: &rng)
    return Fixture(
        flag: Bool.random(using: &rng),
        tiny: Int8.random(in: .min ... .max, using: &rng),
        medium: Int32.random(in: .min ... .max, using: &rng),
        big: randomInt64(using: &rng),
        unsigned: rng.next(),
        smallUnsigned: UInt16.random(in: .min ... .max, using: &rng),
        double: randomDouble(using: &rng),
        float: Float.random(in: -1e6...1e6, using: &rng),
        text: randomString(using: &rng),
        maybeText: Bool.random(using: &rng) ? randomString(using: &rng) : nil,
        ints: (0..<Int.random(in: 0...12, using: &rng)).map { _ in
            Int(truncatingIfNeeded: randomInt64(using: &rng))
        },
        doubles: (0..<Int.random(in: 0...8, using: &rng)).map { _ in randomDouble(using: &rng) },
        stringMap: stringMap,
        intMap: intMap,
        blob: ByteBuffer(
            bytes: (0..<blobLength).map { _ in UInt8.random(in: .min ... .max, using: &rng) }),
        nested: randomNested(using: &rng),
        maybeNested: Bool.random(using: &rng) ? randomNested(using: &rng) : nil
    )
}

@Suite("Round-trip property tests (seeded SplitMix64)")
struct RoundTripTests {
    @Test("random nested fixtures encode-decode to the original", arguments: 0..<300)
    func fixtureRoundTrip(iteration: Int) {
        var rng = SplitMix64(seed: 0x6D6D_5F77_6972_6531 &+ UInt64(iteration))
        let fixture = randomFixture(using: &rng)
        let encoded = MMPackEncoder().encode(fixture)
        guard let bytes = encoded.mpSuccess else {
            Issue.record("encode failed: \(encoded)")
            return
        }
        let decoded = MMPackDecoder().decode(Fixture.self, from: bytes)
        #expect(decoded == .success(fixture))
    }

    @Test("round trip preserves float bit patterns for -0.0")
    func negativeZeroBits() {
        let encoded = MMPackEncoder().encode(-0.0).mpSuccess!
        let decoded = MMPackDecoder().decode(Double.self, from: encoded).mpSuccess!
        #expect(decoded.bitPattern == (-0.0).bitPattern)
    }

    @Test("top-level arrays of fixtures round trip")
    func arrayOfFixtures() {
        var rng = SplitMix64(seed: 0xDEAD_BEEF_0000_0001)
        let fixtures = (0..<5).map { _ in randomFixture(using: &rng) }
        let encoded = MMPackEncoder().encode(fixtures).mpSuccess!
        #expect(MMPackDecoder().decode([Fixture].self, from: encoded) == .success(fixtures))
    }

    @Test("deeply nested arrays round trip within the depth cap")
    func nestedArraysWithinCap() {
        let value = [[[[[[[[[[Int64.max]]]]]]]]]]
        let encoded = MMPackEncoder().encode(value).mpSuccess!
        #expect(mpHex(encoded) == String(repeating: "91", count: 10) + "cf7fffffffffffffff")
        #expect(
            MMPackDecoder().decode([[[[[[[[[[Int64]]]]]]]]]].self, from: encoded) == .success(value)
        )
    }

    @Test("string-keyed dictionaries with numeric-string keys round trip")
    func numericStringKeys() {
        // _DictionaryCodingKey gives "5" an intValue, so it travels as an int key
        // and must come back as the string "5".
        let value: [String: Int32] = ["5": 1, "alpha": 2, "": 3]
        let encoded = MMPackEncoder().encode(value).mpSuccess!
        #expect(MMPackDecoder().decode([String: Int32].self, from: encoded) == .success(value))
    }

    @Test("non-canonical numeric-string keys stay strings and never collide")
    func nonCanonicalNumericStringKeys() {
        // Int("05") == Int("5") == 5, so writing every int-parseable key as its
        // int would rewrite "05" to "5" and emit a duplicate-key map for this
        // dictionary. Only the canonical "5" may travel as an int key.
        let colliding: [String: Int32] = ["5": 1, "05": 2]
        let encoded = MMPackEncoder().encode(colliding).mpSuccess!
        #expect(MMPackDecoder().decode([String: Int32].self, from: encoded) == .success(colliding))

        let signed: [String: Int32] = ["+5": 9]
        let signedEncoded = MMPackEncoder().encode(signed).mpSuccess!
        // "+5" must round-trip exactly — pinned bytes: fixmap, fixstr "+5", 9.
        #expect(mpHex(signedEncoded) == "81a22b3509")
        #expect(
            MMPackDecoder().decode([String: Int32].self, from: signedEncoded) == .success(signed))
    }

    @Test("class inheritance through a shared encoder and decoder round trips")
    func classInheritanceSharedCoder() {
        // The encoder deliberately returns the same container for repeated keyed
        // requests (the standard `super.encode(to: encoder)` pattern); the decoder
        // must mirror that by serving repeated keyed requests from one map index.
        let encoded = MMPackEncoder().encode(DerivedFixture(a: 7, b: 9))
        // One merged map: {2: 9, 1: 7} in request order (b first, then super's a).
        #expect(encoded.map(mpHex) == .success("8202090107"))
        let decoded = MMPackDecoder().decode(DerivedFixture.self, from: encoded.mpSuccess!)
        let instance = decoded.mpSuccess
        #expect(instance?.a == 7)
        #expect(instance?.b == 9)
    }
}

/// Class-inheritance fixtures for the shared-coder pattern: the subclass encodes
/// its keys, then calls `super.encode(to:)` / `super.init(from:)` with the same
/// coder, merging both key sets into one integer-keyed map.
private class BaseFixture: Codable {
    var a: Int

    init(a: Int) {
        self.a = a
    }

    enum CodingKeys: Int, CodingKey {
        case a = 1
    }
}

private final class DerivedFixture: BaseFixture {
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
