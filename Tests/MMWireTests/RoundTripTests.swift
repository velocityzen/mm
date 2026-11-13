import MMWire
import NIOCore
import Testing

@Suite("Round trips")
struct RoundTripTests {
    @Test("round trip preserves float bit patterns for -0.0")
    func negativeZeroBits() {
        let encoded = MMPackEncoder().encode(-0.0).mpSuccess!
        let decoded = MMPackDecoder().decode(Double.self, from: encoded).mpSuccess!
        #expect(decoded.bitPattern == (-0.0).bitPattern)
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
