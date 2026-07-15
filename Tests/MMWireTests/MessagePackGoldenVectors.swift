import MMWire
import NIOCore
import Testing

/// A golden byte vector: expected bytes were derived by hand from the MessagePack
/// spec (https://github.com/msgpack/msgpack/blob/master/spec.md), never from the
/// encoder under test. Canonical vectors must encode to exactly `hex` and decode
/// back to `value`; non-canonical vectors only decode.
struct MPVector<Value: Sendable & Equatable>: Sendable, CustomTestStringConvertible {
    let hex: String
    let value: Value
    let note: String

    init(_ hex: String, _ value: Value, _ note: String) {
        self.hex = hex
        self.value = value
        self.note = note
    }

    var testDescription: String {
        hex.count > 40 ? "\(note) <\(hex.prefix(40))…>" : "\(note) <\(hex)>"
    }
}

// MARK: - Canonical vectors (encode must produce exactly these bytes; decode must return the value)

let signedIntVectors: [MPVector<Int64>] = [
    MPVector("00", 0, "positive fixint zero"),
    MPVector("01", 1, "positive fixint one"),
    MPVector("7f", 127, "positive fixint max 0x7f"),
    MPVector("cc80", 128, "uint8 boundary 0x80"),
    MPVector("ccff", 255, "uint8 max"),
    MPVector("cd0100", 256, "uint16 boundary 2^8"),
    MPVector("cdffff", 65535, "uint16 max"),
    MPVector("ce00010000", 65536, "uint32 boundary 2^16"),
    MPVector("ceffffffff", 4_294_967_295, "uint32 max"),
    MPVector("cf0000000100000000", 4_294_967_296, "uint64 boundary 2^32"),
    MPVector("cf7fffffffffffffff", Int64.max, "Int64.max"),
    MPVector("ff", -1, "negative fixint -1"),
    MPVector("e0", -32, "negative fixint min -32"),
    MPVector("d0df", -33, "int8 boundary -33"),
    MPVector("d080", -128, "int8 min"),
    MPVector("d1ff7f", -129, "int16 boundary -129"),
    MPVector("d18000", -32768, "int16 min"),
    MPVector("d2ffff7fff", -32769, "int32 boundary -32769"),
    MPVector("d280000000", -2_147_483_648, "int32 min"),
    MPVector("d3ffffffff7fffffff", -2_147_483_649, "int64 boundary -2^31-1"),
    MPVector("d38000000000000000", Int64.min, "Int64.min"),
]

let unsignedIntVectors: [MPVector<UInt64>] = [
    MPVector("00", 0, "positive fixint zero"),
    MPVector("7f", 127, "positive fixint max"),
    MPVector("cc80", 128, "uint8 boundary 2^7"),
    MPVector("ccff", 255, "uint8 max 2^8-1"),
    MPVector("cd0100", 256, "uint16 boundary 2^8"),
    MPVector("cdffff", 65535, "uint16 max 2^16-1"),
    MPVector("ce00010000", 65536, "uint32 boundary 2^16"),
    MPVector("ceffffffff", 4_294_967_295, "uint32 max 2^32-1"),
    MPVector("cf0000000100000000", 4_294_967_296, "uint64 boundary 2^32"),
    MPVector("cfffffffffffffffff", UInt64.max, "UInt64.max"),
]

let floatVectors: [MPVector<Float>] = [
    MPVector("ca00000000", 0.0, "float32 +0.0"),
    MPVector("ca80000000", -0.0, "float32 -0.0"),
    MPVector("ca3fc00000", 1.5, "float32 1.5"),
    MPVector("cac0000000", -2.0, "float32 -2.0"),
    MPVector("ca7f800000", .infinity, "float32 +inf"),
    MPVector("caff800000", -.infinity, "float32 -inf"),
    MPVector("ca3e200000", 0.15625, "float32 0.15625 (spec example)"),
    // NaN vectors work here because the tests compare bit patterns, never ==.
    MPVector("ca7fc00000", Float.nan, "float32 quiet NaN"),
]

let doubleVectors: [MPVector<Double>] = [
    MPVector("cb0000000000000000", 0.0, "float64 +0.0"),
    MPVector("cb8000000000000000", -0.0, "float64 -0.0"),
    MPVector("cb3ff0000000000000", 1.0, "float64 1.0"),
    MPVector("cb3ff8000000000000", 1.5, "float64 1.5"),
    MPVector("cb3ff199999999999a", 1.1, "float64 1.1 bit pattern"),
    MPVector("cbbfe0000000000000", -0.5, "float64 -0.5"),
    MPVector("cb7ff0000000000000", .infinity, "float64 +inf"),
    MPVector("cbfff0000000000000", -.infinity, "float64 -inf"),
    // NaN vectors work here because the tests compare bit patterns, never ==.
    MPVector("cb7ff8000000000000", Double.nan, "float64 quiet NaN"),
    MPVector(
        "cb7ff4000000000001",
        Double(bitPattern: 0x7ff4_0000_0000_0001),
        "float64 signaling NaN, payload bits preserved"
    ),
]

let stringVectors: [MPVector<String>] = [
    MPVector("a0", "", "empty fixstr"),
    MPVector("a161", "a", "one-byte fixstr"),
    MPVector("a3616263", "abc", "three-byte fixstr"),
    MPVector("a2c3a9", "é", "two-byte UTF-8 scalar"),
    MPVector("a4f09f9982", "🙂", "four-byte UTF-8 scalar"),
    MPVector(
        "bf" + String(repeating: "61", count: 31),
        String(repeating: "a", count: 31),
        "31-byte fixstr max"
    ),
    MPVector(
        "d920" + String(repeating: "61", count: 32),
        String(repeating: "a", count: 32),
        "32-byte str8 boundary"
    ),
]

let binVectors: [MPVector<[UInt8]>] = [
    MPVector("c400", [], "empty bin8"),
    MPVector("c401ff", [0xff], "one-byte bin8"),
    MPVector("c404deadbeef", [0xde, 0xad, 0xbe, 0xef], "four-byte bin8"),
]

let arrayVectors: [MPVector<[Int64]>] = [
    MPVector("90", [], "empty fixarray"),
    MPVector("9101", [1], "one-element fixarray"),
    MPVector("930102d0df", [1, 2, -33], "mixed-int fixarray"),
    MPVector(
        "9f" + String(repeating: "00", count: 15),
        [Int64](repeating: 0, count: 15),
        "15-element fixarray max"
    ),
    MPVector(
        "dc0010" + String(repeating: "00", count: 16),
        [Int64](repeating: 0, count: 16),
        "16-element array16 boundary"
    ),
]

let mapVectors: [MPVector<[Int: Int64]>] = [
    MPVector("80", [:], "empty fixmap"),
    MPVector("810101", [1: 1], "one-entry fixmap"),
    MPVector("81e07f", [-32: 127], "negative fixint key fixmap"),
    MPVector("81d0df2a", [-33: 42], "int8 key fixmap"),
]

let extVectors: [MPVector<MMPackExtValue>] = [
    MPVector("d405aa", MMPackExtValue(type: 5, payload: mpBytes("aa")), "fixext1"),
    MPVector("d505aabb", MMPackExtValue(type: 5, payload: mpBytes("aabb")), "fixext2"),
    MPVector(
        "d6ff01020304", MMPackExtValue(type: -1, payload: mpBytes("01020304")),
        "fixext4 negative type"),
    MPVector(
        "d7050102030405060708",
        MMPackExtValue(type: 5, payload: mpBytes("0102030405060708")),
        "fixext8"
    ),
    MPVector(
        "d805" + String(repeating: "ab", count: 16),
        MMPackExtValue(type: 5, payload: mpBytes(String(repeating: "ab", count: 16))),
        "fixext16"
    ),
    MPVector("c70005", MMPackExtValue(type: 5, payload: ByteBuffer()), "ext8 empty payload"),
    MPVector(
        "c70305aabbcc", MMPackExtValue(type: 5, payload: mpBytes("aabbcc")), "ext8 three bytes"),
    MPVector(
        "c71105" + String(repeating: "00", count: 17),
        MMPackExtValue(type: 5, payload: mpBytes(String(repeating: "00", count: 17))),
        "ext8 17 bytes (just past fixext16)"
    ),
]

// MARK: - Non-canonical vectors (decode only: value encoded wider than necessary,
// or across signedness)

let nonCanonicalSignedIntVectors: [MPVector<Int64>] = [
    MPVector("cc05", 5, "uint8 for fixint value"),
    MPVector("cd0005", 5, "uint16 for fixint value"),
    MPVector("ce00000005", 5, "uint32 for fixint value"),
    MPVector("cf0000000000000005", 5, "uint64 for fixint value"),
    MPVector("d005", 5, "int8 for positive fixint value"),
    MPVector("d10005", 5, "int16 for fixint value"),
    MPVector("d200000005", 5, "int32 for fixint value"),
    MPVector("d30000000000000005", 5, "int64 for fixint value"),
    MPVector("d0ff", -1, "int8 for negative fixint value"),
    MPVector("d1ffff", -1, "int16 for -1"),
    MPVector("d2ffffffff", -1, "int32 for -1"),
    MPVector("d3ffffffffffffffff", -1, "int64 for -1"),
    MPVector("cf7fffffffffffffff", Int64.max, "uint64 into signed target"),
]

let nonCanonicalUnsignedIntVectors: [MPVector<UInt64>] = [
    MPVector("d005", 5, "int8 into unsigned target"),
    MPVector("d10005", 5, "int16 into unsigned target"),
    MPVector("d200000005", 5, "int32 into unsigned target"),
    MPVector("d30000000000000005", 5, "int64 into unsigned target"),
    MPVector("cc05", 5, "uint8 for fixint value"),
]

let nonCanonicalStringVectors: [MPVector<String>] = [
    MPVector("d903616263", "abc", "str8 for fixstr-sized string"),
    MPVector("da0003616263", "abc", "str16 for fixstr-sized string"),
    MPVector("db00000003616263", "abc", "str32 for fixstr-sized string"),
]

let nonCanonicalBinVectors: [MPVector<[UInt8]>] = [
    MPVector("c50002dead", [0xde, 0xad], "bin16 for bin8-sized payload"),
    MPVector("c600000002dead", [0xde, 0xad], "bin32 for bin8-sized payload"),
    MPVector("a3616263", [0x61, 0x62, 0x63], "str payload into binary target"),
    MPVector("d903616263", [0x61, 0x62, 0x63], "str8 payload into binary target"),
]

let nonCanonicalArrayVectors: [MPVector<[Int64]>] = [
    MPVector("dc000101", [1], "array16 for one element"),
    MPVector("dd0000000101", [1], "array32 for one element"),
]

let nonCanonicalMapVectors: [MPVector<[Int: Int64]>] = [
    MPVector("de00010101", [1: 1], "map16 for one entry"),
    MPVector("df000000010101", [1: 1], "map32 for one entry"),
]

let nonCanonicalFloatVectors: [MPVector<Float>] = [
    MPVector("cb3ff8000000000000", 1.5, "float64 into Float when exactly representable"),
    MPVector("cb7ff0000000000000", .infinity, "float64 +inf into Float"),
    MPVector("cb8000000000000000", -0.0, "float64 -0.0 into Float"),
]

let nonCanonicalExtVectors: [MPVector<MMPackExtValue>] = [
    MPVector(
        "c70105aa", MMPackExtValue(type: 5, payload: mpBytes("aa")),
        "ext8 for fixext1-sized payload"),
    MPVector(
        "c8000205aabb",
        MMPackExtValue(type: 5, payload: mpBytes("aabb")),
        "ext16 for fixext2-sized payload"
    ),
    MPVector(
        "c90000000405aabbccdd",
        MMPackExtValue(type: 5, payload: mpBytes("aabbccdd")),
        "ext32 for fixext4-sized payload"
    ),
]
