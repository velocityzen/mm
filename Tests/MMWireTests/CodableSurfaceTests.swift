import MMWire
import NIOCore
import Testing

/// Encodes `value`, optionally pins the exact wire bytes, and decodes it back.
private func expectRoundTrip<T: Codable & Equatable>(
    _ value: T,
    hex: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let encoded = MMPackEncoder().encode(value)
    guard let bytes = encoded.mpSuccess else {
        Issue.record("encode failed: \(encoded)", sourceLocation: sourceLocation)
        return
    }
    if let hex {
        #expect(mpHex(bytes) == hex, sourceLocation: sourceLocation)
    }
    #expect(
        MMPackDecoder().decode(T.self, from: bytes) == .success(value),
        sourceLocation: sourceLocation
    )
}

/// Arrays hand the coder every primitive width through the single-value path
/// (each element gets its own child coder), so these tests pin the
/// smallest-representation rule per width and prove exact value recovery.
@Suite("Unkeyed arrays of every primitive width")
struct PrimitiveArrayTests {
    @Test("signed integer arrays use the smallest representation and round trip")
    func signedArrays() {
        expectRoundTrip([Int8(-1), .min, .max], hex: "93ffd0807f")
        expectRoundTrip([Int16(-1000), 1000], hex: "92d1fc18cd03e8")
        expectRoundTrip([Int32(-100_000), 100_000], hex: "92d2fffe7960ce000186a0")
        expectRoundTrip([Int64.min, .max], hex: "92d38000000000000000cf7fffffffffffffff")
        expectRoundTrip([Int(-33), 128], hex: "92d0dfcc80")
    }

    @Test("unsigned integer arrays use the smallest representation and round trip")
    func unsignedArrays() {
        expectRoundTrip([UInt8(0), .max], hex: "9200ccff")
        expectRoundTrip([UInt16.max], hex: "91cdffff")
        expectRoundTrip([UInt32(4_000_000_000)], hex: "91ceee6b2800")
        expectRoundTrip([UInt64.max], hex: "91cfffffffffffffffff")
        expectRoundTrip([UInt(0), 300], hex: "9200cd012c")
    }

    @Test("bool, string, and float arrays round trip with pinned bytes")
    func boolStringFloatArrays() {
        expectRoundTrip([true, false], hex: "92c3c2")
        expectRoundTrip(["", "mm"], hex: "92a0a26d6d")
        expectRoundTrip([Float(1.5), -2.5], hex: "92ca3fc00000cac0200000")
        expectRoundTrip([Double(1.5)], hex: "91cb3ff8000000000000")
    }

    @Test("optional elements encode nil slots; nested arrays nest")
    func optionalAndNestedArrays() {
        expectRoundTrip([1, nil, 3] as [Int?], hex: "9301c003")
        expectRoundTrip([[1], [2, 3]], hex: "929101920203")
    }

    @Test("ByteBuffer elements take the bin fast path inside arrays")
    func byteBufferArray() {
        expectRoundTrip([mpBytes("dead"), mpBytes("")], hex: "92c402deadc400")
    }
}

// MARK: - Concrete-typed container-call fixtures

/// Calls every CONCRETE-typed method on the unkeyed containers. `Array`'s
/// synthesized conformance only ever uses the generic `encode<T>`/`decode<T>`
/// entry points, so the per-width overloads are reachable solely from
/// hand-written coders like this one. Also reads `count` mid-encode and encodes
/// it as the final element, so the container's element accounting is asserted
/// on the wire.
private struct UnkeyedParade: Equatable {
    var sawNil: Bool
    var flag: Bool
    var text: String
    var double: Double
    var float: Float
    var int: Int
    var int8: Int8
    var int16: Int16
    var int32: Int32
    var int64: Int64
    var uint: UInt
    var uint8: UInt8
    var uint16: UInt16
    var uint32: UInt32
    var uint64: UInt64
    var reportedCount: Int
}

extension UnkeyedParade: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.sawNil = try container.decodeNil()
        self.flag = try container.decode(Bool.self)
        self.text = try container.decode(String.self)
        self.double = try container.decode(Double.self)
        self.float = try container.decode(Float.self)
        self.int = try container.decode(Int.self)
        self.int8 = try container.decode(Int8.self)
        self.int16 = try container.decode(Int16.self)
        self.int32 = try container.decode(Int32.self)
        self.int64 = try container.decode(Int64.self)
        self.uint = try container.decode(UInt.self)
        self.uint8 = try container.decode(UInt8.self)
        self.uint16 = try container.decode(UInt16.self)
        self.uint32 = try container.decode(UInt32.self)
        self.uint64 = try container.decode(UInt64.self)
        self.reportedCount = try container.decode(Int.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encodeNil()
        try container.encode(self.flag)
        try container.encode(self.text)
        try container.encode(self.double)
        try container.encode(self.float)
        try container.encode(self.int)
        try container.encode(self.int8)
        try container.encode(self.int16)
        try container.encode(self.int32)
        try container.encode(self.int64)
        try container.encode(self.uint)
        try container.encode(self.uint8)
        try container.encode(self.uint16)
        try container.encode(self.uint32)
        try container.encode(self.uint64)
        let written = container.count
        try container.encode(written)
    }
}

/// Synthesized keyed coding for the widths no other fixture carries:
/// `Int16`, `UInt`, and `UInt32` fields go through the concrete keyed overloads.
private struct WidthFields: Codable, Equatable {
    var halfword: Int16
    var word: UInt
    var wide: UInt32

    enum CodingKeys: Int, CodingKey {
        case halfword = 1
        case word = 2
        case wide = 3
    }
}

/// Explicit `encodeNil(forKey:)` — synthesized coding never calls it (optionals
/// are simply omitted), so the key-then-nil wire shape needs a manual coder.
private struct ExplicitNilField: Equatable {
    var markerWasNil: Bool
}

extension ExplicitNilField: Codable {
    enum CodingKeys: Int, CodingKey {
        case marker = 1
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.markerWasNil = try container.decodeNil(forKey: .marker)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .marker)
    }
}

@Suite("Concrete-typed container calls")
struct ConcreteContainerCallTests {
    @Test("an unkeyed parade of every concrete width pins bytes and round trips")
    func unkeyedParade() {
        let parade = UnkeyedParade(
            sawNil: true,
            flag: true,
            text: "mm",
            double: 1.5,
            float: -2.5,
            int: 1,
            int8: -33,
            int16: -1000,
            int32: -100_000,
            int64: .min,
            uint: 128,
            uint8: 200,
            uint16: 50_000,
            uint32: 4_000_000_000,
            uint64: .max,
            reportedCount: 15
        )
        expectRoundTrip(
            parade,
            hex: "dc0010c0c3a26d6dcb3ff8000000000000cac020000001d0dfd1fc18d2fffe7960"
                + "d38000000000000000cc80ccc8cdc350ceee6b2800cfffffffffffffffff0f"
        )
    }

    @Test("Int16, UInt, and UInt32 struct fields travel through the concrete keyed overloads")
    func keyedWidthFields() {
        expectRoundTrip(
            WidthFields(halfword: -1000, word: 300, wide: 70_000),
            hex: "8301d1fc1802cd012c03ce00011170"
        )
    }

    @Test("encodeNil(forKey:) writes the key with an explicit nil value")
    func explicitKeyedNil() {
        expectRoundTrip(ExplicitNilField(markerWasNil: true), hex: "8101c0")
    }
}

// MARK: - Nested-container and super-coder fixtures

/// Builds its wire shape through `nestedContainer(keyedBy:forKey:)` and
/// `nestedUnkeyedContainer(forKey:)` instead of encoding child values.
private struct NestedViaKeyed: Equatable {
    var boxed: Int
    var items: [Int32]
}

extension NestedViaKeyed: Codable {
    enum CodingKeys: Int, CodingKey {
        case box = 1
        case items = 2
    }

    enum BoxKeys: Int, CodingKey {
        case value = 1
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let box = try container.nestedContainer(keyedBy: BoxKeys.self, forKey: .box)
        self.boxed = try box.decode(Int.self, forKey: .value)
        var list = try container.nestedUnkeyedContainer(forKey: .items)
        var items: [Int32] = []
        while !list.isAtEnd {
            items.append(try list.decode(Int32.self))
        }
        self.items = items
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var box = container.nestedContainer(keyedBy: BoxKeys.self, forKey: .box)
        try box.encode(self.boxed, forKey: .value)
        var list = container.nestedUnkeyedContainer(forKey: .items)
        for item in self.items {
            try list.encode(item)
        }
    }
}

/// Opens a nested keyed container and a nested unkeyed container mid-array,
/// with plain elements on both sides, so segment interleaving is observable.
private struct MidArrayNesting: Equatable {
    var head: Int
    var mapped: Int
    var listed: [Int]
}

extension MidArrayNesting: Codable {
    enum BoxKeys: Int, CodingKey {
        case value = 1
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.head = try container.decode(Int.self)
        let box = try container.nestedContainer(keyedBy: BoxKeys.self)
        self.mapped = try box.decode(Int.self, forKey: .value)
        var list = try container.nestedUnkeyedContainer()
        var listed: [Int] = []
        while !list.isAtEnd {
            listed.append(try list.decode(Int.self))
        }
        self.listed = listed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(self.head)
        var box = container.nestedContainer(keyedBy: BoxKeys.self)
        try box.encode(self.mapped, forKey: .value)
        var list = container.nestedUnkeyedContainer()
        for element in self.listed {
            try list.encode(element)
        }
    }
}

/// Class-inheritance fixtures for the SEPARATE-container pattern: the subclass
/// hands `super.encode(to:)` a `superEncoder()`, so the base's map nests under
/// the string key "super" instead of merging (contrast with `DerivedFixture`
/// in RoundTripTests, which shares one coder).
private class NestedSuperBase: Codable {
    var a: Int

    init(a: Int) {
        self.a = a
    }

    enum CodingKeys: Int, CodingKey {
        case a = 1
    }
}

private final class NestedSuperDerived: NestedSuperBase {
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

/// Routes its only value through `superEncoder(forKey:)` / `superDecoder(forKey:)`,
/// which must behave as a deferred single-value slot at that key.
private struct DeferredKeyedValue: Equatable {
    var payload: Int
}

extension DeferredKeyedValue: Codable {
    enum CodingKeys: Int, CodingKey {
        case payload = 3
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sub = try container.superDecoder(forKey: .payload)
        self.payload = try sub.singleValueContainer().decode(Int.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sub = container.superEncoder(forKey: .payload)
        var single = sub.singleValueContainer()
        try single.encode(self.payload)
    }
}

/// The unkeyed `superEncoder()` / `superDecoder()`: a deferred array slot.
private struct DeferredSlotValue: Equatable {
    var first: Int
    var second: Int
}

extension DeferredSlotValue: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.first = try container.decode(Int.self)
        let sub = try container.superDecoder()
        self.second = try sub.singleValueContainer().decode(Int.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(self.first)
        let sub = container.superEncoder()
        var single = sub.singleValueContainer()
        try single.encode(self.second)
    }
}

/// Requests a super encoder and never writes through it; the abandoned slot
/// must finalize as nil, not corrupt the map.
private struct AbandonedSuperSlot: Encodable {
    enum CodingKeys: Int, CodingKey {
        case slot = 1
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        _ = container.superEncoder(forKey: .slot)
    }
}

/// Demands a "super" entry that the wire map does not carry.
private struct WantsSuper: Decodable {
    enum CodingKeys: Int, CodingKey {
        case unused = 1
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.superDecoder()
    }
}

@Suite("Nested containers and super coders")
struct NestedAndSuperCoderTests {
    @Test("keyed nestedContainer and nestedUnkeyedContainer produce nested wire shapes")
    func keyedNestedContainers() {
        expectRoundTrip(NestedViaKeyed(boxed: 7, items: [10, -2]), hex: "820181010702920afe")
    }

    @Test("nested containers opened mid-array interleave with plain elements in order")
    func unkeyedNestedContainers() {
        expectRoundTrip(
            MidArrayNesting(head: 1, mapped: 2, listed: [3, 4]),
            hex: "9301810102920304"
        )
    }

    @Test("superEncoder() nests the base class map under the string key \"super\"")
    func classInheritanceViaSuperEncoder() {
        let encoded = MMPackEncoder().encode(NestedSuperDerived(a: 7, b: 9))
        // {2: 9, "super": {1: 7}} — the base map is a nested value, not merged.
        #expect(encoded.map(mpHex) == .success("820209a57375706572810107"))
        guard let bytes = encoded.mpSuccess else { return }
        let decoded = MMPackDecoder().decode(NestedSuperDerived.self, from: bytes)
        let instance = decoded.mpSuccess
        #expect(instance?.a == 7)
        #expect(instance?.b == 9)
    }

    @Test("superEncoder(forKey:) and superDecoder(forKey:) act as a deferred keyed slot")
    func deferredKeyedSlot() {
        expectRoundTrip(DeferredKeyedValue(payload: 42), hex: "81032a")
    }

    @Test("unkeyed superEncoder() and superDecoder() act as a deferred array slot")
    func deferredArraySlot() {
        expectRoundTrip(DeferredSlotValue(first: 5, second: 6), hex: "920506")
    }

    @Test("an abandoned super encoder finalizes its slot as nil")
    func abandonedSuperSlot() {
        #expect(MMPackEncoder().encode(AbandonedSuperSlot()).map(mpHex) == .success("8101c0"))
    }

    @Test("superDecoder() on a map without a \"super\" entry is keyNotFound")
    func missingSuperKey() {
        #expect(
            MMPackDecoder().decode(WantsSuper.self, from: mpBytes("80")).mpFailure
                == .keyNotFound(key: "super")
        )
    }
}

// MARK: - Single-value and pass-through fixtures

/// A wire enum shape: string of raw-value coding through a single-value
/// container, here with a `UInt32` raw value.
private enum WireStatus: UInt32, Codable, Equatable {
    case active = 7
    case retired = 900
}

/// Routes a `ByteBuffer` through an explicit single-value container on both
/// sides, exercising the coder's bin fast paths behind the generic entry points.
private struct BlobBox: Equatable {
    var blob: ByteBuffer
}

extension BlobBox: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.blob = try container.decode(ByteBuffer.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.blob)
    }
}

/// A transparent wrapper: single-value `encode<T>`/`decode<T>` with a struct
/// payload must pass straight through to the wrapped value's coding, adding
/// no wire bytes of its own.
private struct IndirectBox: Equatable {
    var inner: WidthFields
}

extension IndirectBox: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.inner = try container.decode(WidthFields.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.inner)
    }
}

/// Reads the coder introspection surfaces mid-flight: `userInfo` is documented
/// empty and the root coding path is empty.
private struct IntrospectingBox: Equatable {
    var value: Int
}

extension IntrospectingBox: Codable {
    init(from decoder: any Decoder) throws {
        #expect(decoder.userInfo.isEmpty)
        #expect(decoder.codingPath.isEmpty)
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(Int.self)
    }

    func encode(to encoder: any Encoder) throws {
        #expect(encoder.userInfo.isEmpty)
        var container = encoder.singleValueContainer()
        #expect(container.codingPath.isEmpty)
        try container.encode(self.value)
    }
}

/// Encodes and decodes nothing at all; the unfilled root slot must become nil.
private struct EmptyPayloadFixture: Codable, Equatable {
    init() {}

    init(from decoder: any Decoder) throws {}

    func encode(to encoder: any Encoder) throws {}
}

/// Encodes a non-emitting child at a key; the key must still get a value (nil).
private struct SilentChildHolder: Encodable {
    enum CodingKeys: Int, CodingKey {
        case child = 1
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EmptyPayloadFixture(), forKey: .child)
    }
}

@Suite("Single-value and pass-through coding")
struct SingleValueSurfaceTests {
    @Test("top-level scalars of the remaining widths pin bytes and round trip")
    func topLevelScalars() {
        expectRoundTrip(Int8(-5), hex: "fb")
        expectRoundTrip(Int16(-1000), hex: "d1fc18")
        expectRoundTrip(UInt(300), hex: "cd012c")
        expectRoundTrip(UInt32(70_000), hex: "ce00011170")
    }

    @Test("a UInt32 raw-value enum codes as its raw value")
    func rawValueEnum() {
        expectRoundTrip(WireStatus.retired, hex: "cd0384")
        #expect(MMPackDecoder().decode(WireStatus.self, from: mpBytes("07")) == .success(.active))
    }

    @Test("an explicit single-value container takes the ByteBuffer bin fast path")
    func singleValueByteBuffer() {
        expectRoundTrip(BlobBox(blob: mpBytes("deadbeef")), hex: "c404deadbeef")
    }

    @Test("a transparent single-value wrapper adds no wire bytes")
    func transparentWrapper() {
        expectRoundTrip(
            IndirectBox(inner: WidthFields(halfword: -1000, word: 300, wide: 70_000)),
            hex: "8301d1fc1802cd012c03ce00011170"
        )
    }

    @Test("userInfo is empty and the root coding path is empty on both coders")
    func introspectionSurfaces() {
        expectRoundTrip(IntrospectingBox(value: 11), hex: "0b")
    }

    @Test("a value that encodes nothing becomes nil at the root, at a key, and in a slot")
    func nonEmittingValue() {
        expectRoundTrip(EmptyPayloadFixture(), hex: "c0")
        #expect(MMPackEncoder().encode(SilentChildHolder()).map(mpHex) == .success("8101c0"))
        expectRoundTrip([EmptyPayloadFixture()], hex: "91c0")
    }
}

// MARK: - Error-surface fixtures

/// Deliberately NOT an `MMWireError`; the coder must wrap foreign errors into
/// its own typed failures.
private enum ForeignFailure: Error {
    case custom
}

private struct ThrowingEncodable: Encodable {
    func encode(to encoder: any Encoder) throws {
        throw ForeignFailure.custom
    }
}

private struct ThrowingDecodable: Decodable {
    init(from decoder: any Decoder) throws {
        throw ForeignFailure.custom
    }
}

/// Requests a keyed container so the top-level map (including its keys) must
/// be fully walked, without requiring any key to be present.
private struct KeyWalkProbe: Decodable, Equatable {
    var missing: Int?

    enum CodingKeys: Int, CodingKey {
        case missing = 9
    }
}

/// Reads one more element than the array carries.
private struct GreedyReader: Decodable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        _ = try container.decode(Int.self)
    }
}

/// Probes for nil where the array header promised an element the body lacks.
private struct NilPeeker: Decodable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        _ = try container.decodeNil()
    }
}

@Suite("Coder error surfaces")
struct CoderErrorSurfaceTests {
    @Test("a foreign error thrown while encoding maps to encodingFailed")
    func foreignEncodeError() {
        #expect(
            MMPackEncoder().encode(ThrowingEncodable())
                == .failure(.encodingFailed(description: "custom"))
        )
    }

    @Test("a foreign error thrown while decoding maps to decodingFailed")
    func foreignDecodeError() {
        #expect(
            MMPackDecoder().decode(ThrowingDecodable.self, from: mpBytes("c0")).mpFailure
                == .decodingFailed(description: "custom")
        )
    }

    @Test("decodeField wraps a foreign error from the value decode the same way")
    func foreignDecodeFieldError() {
        #expect(
            MMPackDecoder().decodeField(
                at: 1,
                as: ThrowingDecodable.self,
                fromMapPayload: mpBytes("810100")
            ).mpFailure == .decodingFailed(description: "custom")
        )
    }

    @Test("integer narrowing failures name the target type")
    func integerNarrowing() {
        // 300 fits the wire (uint16) but not the target width.
        #expect(
            MMPackDecoder().decode(UInt8.self, from: mpBytes("cd012c"))
                == .failure(.numberOutOfRange(target: "UInt8"))
        )
        #expect(
            MMPackDecoder().decode(Int8.self, from: mpBytes("cd012c"))
                == .failure(.numberOutOfRange(target: "Int8"))
        )
        // -1 can never narrow into an unsigned target.
        #expect(
            MMPackDecoder().decode(UInt.self, from: mpBytes("ff"))
                == .failure(.numberOutOfRange(target: "UInt"))
        )
    }

    @Test("a truncated integer body surfaces truncated, not out-of-range")
    func truncatedIntegerBody() {
        // uint8 header with no payload byte, unsigned and signed targets.
        #expect(MMPackDecoder().decode(UInt8.self, from: mpBytes("cc")) == .failure(.truncated))
        #expect(MMPackDecoder().decode(Int64.self, from: mpBytes("d3")) == .failure(.truncated))
    }

    @Test("a map key truncated mid-value is a truncated error")
    func truncatedMapKey() {
        // fixmap(1) whose key is a uint8 header with no payload byte...
        #expect(
            MMPackDecoder().decode(KeyWalkProbe.self, from: mpBytes("81cc"))
                == .failure(.truncated)
        )
        // ...and whose key is a fixstr(2) header with no payload bytes.
        #expect(
            MMPackDecoder().decode(KeyWalkProbe.self, from: mpBytes("81a2"))
                == .failure(.truncated)
        )
    }

    @Test("reading past the end of an unkeyed container is keyNotFound with the index")
    func unkeyedPastTheEnd() {
        #expect(
            MMPackDecoder().decode(GreedyReader.self, from: mpBytes("90")).mpFailure
                == .keyNotFound(key: "index 0")
        )
    }

    @Test("decodeNil against an array header lying about its count is truncated")
    func decodeNilOnLyingArrayCount() {
        // fixarray(1) with an empty body: not at end by count, no byte to peek.
        #expect(
            MMPackDecoder().decode(NilPeeker.self, from: mpBytes("91")).mpFailure
                == .truncated
        )
    }
}
