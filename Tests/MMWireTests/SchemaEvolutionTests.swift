import MMWire
import NIOCore
import Testing

private struct V1: Codable, Equatable {
    var id: Int
    var name: String

    enum CodingKeys: Int, CodingKey {
        case id = 1
        case name = 2
    }
}

private struct V2: Codable, Equatable {
    var id: Int
    var name: String
    var note: String?
    var tags: [String]?
    var attributes: [String: Int]?
    var blob: ByteBuffer?
    var sub: Sub?

    struct Sub: Codable, Equatable {
        var x: Int

        enum CodingKeys: Int, CodingKey {
            case x = 1
        }
    }

    enum CodingKeys: Int, CodingKey {
        case id = 1
        case name = 2
        case note = 3
        case tags = 4
        case attributes = 5
        case blob = 6
        case sub = 7
    }
}

/// Hand-built "V2 on the wire" payload whose unknown-to-V1 fields cover EVERY value
/// family — str, array, string-keyed map, bin, nested int-keyed map, and ext —
/// including the widths a newer peer plausibly sends that the fix-width families
/// miss: fixext4 (timestamp-shaped), str16, bin16, ext8, array16, and map16.
private func makeV2WirePayload() -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.writeMessagePackMapHeader(count: 14)
    buffer.writeMessagePackInt(1)  // id
    buffer.writeMessagePackInt(42)
    buffer.writeMessagePackInt(2)  // name
    buffer.writeMessagePackString("mm")
    buffer.writeMessagePackInt(3)  // note: str
    buffer.writeMessagePackString("extra note")
    buffer.writeMessagePackInt(4)  // tags: array
    buffer.writeMessagePackArrayHeader(count: 3)
    buffer.writeMessagePackString("x")
    buffer.writeMessagePackString("y")
    buffer.writeMessagePackString("z")
    buffer.writeMessagePackInt(5)  // attributes: string-keyed map
    buffer.writeMessagePackMapHeader(count: 1)
    buffer.writeMessagePackString("k")
    buffer.writeMessagePackInt(7)
    buffer.writeMessagePackInt(6)  // blob: bin
    buffer.writeMessagePackBinary(bytes: [1, 2, 3] as [UInt8])
    buffer.writeMessagePackInt(7)  // sub: nested int-keyed map (with further nesting inside)
    buffer.writeMessagePackMapHeader(count: 2)
    buffer.writeMessagePackInt(1)
    buffer.writeMessagePackInt(123)
    buffer.writeMessagePackInt(99)  // unknown even to Sub: nested map inside the nested map
    buffer.writeMessagePackMapHeader(count: 1)
    buffer.writeMessagePackInt(1)
    buffer.writeMessagePackArrayHeader(count: 2)
    buffer.writeMessagePackNil()
    buffer.writeMessagePackDouble(1.5)
    buffer.writeMessagePackInt(88)  // unknown to V1 and V2: ext
    buffer.writeMessagePackExt(type: -1, payload: mpBytes("0102030405060708"))
    buffer.writeMessagePackInt(89)  // unknown: fixext4 (msgpack timestamp shape)
    buffer.writeMessagePackExt(type: -1, payload: mpBytes("01020304"))
    buffer.writeMessagePackInt(90)  // unknown: str16
    buffer.writeMessagePackString(String(repeating: "u", count: 300))
    buffer.writeMessagePackInt(91)  // unknown: bin16
    buffer.writeMessagePackBinary(bytes: [UInt8](repeating: 0xcd, count: 300))
    buffer.writeMessagePackInt(92)  // unknown: ext8 (just past fixext16)
    buffer.writeMessagePackExt(
        type: 9, payload: ByteBuffer(bytes: [UInt8](repeating: 0x33, count: 17)))
    buffer.writeMessagePackInt(93)  // unknown: array16
    buffer.writeMessagePackArrayHeader(count: 16)
    for element in 0..<16 {
        buffer.writeMessagePackInt(Int64(element))
    }
    buffer.writeMessagePackInt(94)  // unknown: map16
    buffer.writeMessagePackMapHeader(count: 16)
    for entry in 0..<16 {
        buffer.writeMessagePackInt(Int64(entry))
        buffer.writeMessagePackNil()
    }
    return buffer
}

@Suite("Schema evolution")
struct SchemaEvolutionTests {
    @Test("V2 wire payload decodes as V1 by structurally skipping every unknown family")
    func v2DecodesAsV1() {
        let decoded = MMPackDecoder().decode(V1.self, from: makeV2WirePayload())
        #expect(decoded == .success(V1(id: 42, name: "mm")))
    }

    @Test("V2 wire payload decodes as V2, skipping fields unknown even to V2")
    func v2DecodesAsV2() {
        let decoded = MMPackDecoder().decode(V2.self, from: makeV2WirePayload())
        #expect(
            decoded
                == .success(
                    V2(
                        id: 42,
                        name: "mm",
                        note: "extra note",
                        tags: ["x", "y", "z"],
                        attributes: ["k": 7],
                        blob: ByteBuffer(bytes: [1, 2, 3]),
                        sub: V2.Sub(x: 123)
                    )
                )
        )
    }

    @Test("V1 bytes decode as V2 with nil new optionals")
    func v1DecodesAsV2() {
        let bytes = MMPackEncoder().encode(V1(id: 7, name: "old")).mpSuccess!
        let decoded = MMPackDecoder().decode(V2.self, from: bytes)
        #expect(
            decoded
                == .success(
                    V2(
                        id: 7,
                        name: "old",
                        note: nil,
                        tags: nil,
                        attributes: nil,
                        blob: nil,
                        sub: nil
                    )
                )
        )
    }

    @Test("unknown string keys are skipped alongside int keys")
    func unknownStringKeys() {
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 3)
        buffer.writeMessagePackString("debug")
        buffer.writeMessagePackMapHeader(count: 1)
        buffer.writeMessagePackString("trace")
        buffer.writeMessagePackBool(true)
        buffer.writeMessagePackInt(1)
        buffer.writeMessagePackInt(42)
        buffer.writeMessagePackInt(2)
        buffer.writeMessagePackString("mm")
        #expect(MMPackDecoder().decode(V1.self, from: buffer) == .success(V1(id: 42, name: "mm")))
    }

    @Test("decode of a missing non-optional key is a typed keyNotFound error")
    func missingNonOptionalKey() {
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 1)
        buffer.writeMessagePackInt(1)
        buffer.writeMessagePackInt(42)
        #expect(
            MMPackDecoder().decode(V1.self, from: buffer) == .failure(.keyNotFound(key: "2"))
        )
    }

    @Test("decodeIfPresent of a missing key is nil, of an explicit nil is nil")
    func missingOptionalKey() {
        struct Optionals: Codable, Equatable {
            var a: Int?
            var b: String?
            enum CodingKeys: Int, CodingKey {
                case a = 1
                case b = 2
            }
        }
        // Key 1 absent; key 2 explicitly nil.
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 1)
        buffer.writeMessagePackInt(2)
        buffer.writeMessagePackNil()
        #expect(
            MMPackDecoder().decode(Optionals.self, from: buffer)
                == .success(Optionals(a: nil, b: nil))
        )
    }
}
