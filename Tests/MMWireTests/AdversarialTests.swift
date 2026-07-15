import MMWire
import NIOCore
import Testing

/// Requests a keyed container (forcing a full structural walk of the top-level map)
/// without requiring any key to be present.
private struct Probe: Decodable, Equatable {
    var absent: Int?

    enum CodingKeys: Int, CodingKey {
        case absent = 1_000_000
    }
}

/// Recursively opens unkeyed containers, one per nesting level.
private struct DeepBox: Decodable {
    var levels: Int

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if container.isAtEnd {
            self.levels = 1
        } else if try container.decodeNil() {
            self.levels = 1
        } else {
            let inner = try container.decode(DeepBox.self)
            self.levels = inner.levels + 1
        }
    }
}

/// A complex value whose fields put EVERY format byte the structural skip
/// dispatches on onto the skip path: nil/bool, all integer widths, both float
/// widths, every str/bin/ext/array/map width, and nested containers. The 32-bit
/// widths use non-canonical raw bytes with small payloads (the canonical writers
/// never emit them for small values) so the truncation loop stays cheap.
private func makeComplexValue() -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.writeMessagePackMapHeader(count: 30)
    buffer.writeMessagePackInt(1)
    buffer.writeMessagePackString("hello world")  // fixstr
    buffer.writeMessagePackInt(2)
    buffer.writeMessagePackArrayHeader(count: 3)  // fixarray
    buffer.writeMessagePackInt(1)  // positive fixint
    buffer.writeMessagePackInt(-1000)  // int16
    buffer.writeMessagePackInt(4_294_967_296)  // uint64
    buffer.writeMessagePackInt(3)
    buffer.writeMessagePackMapHeader(count: 1)  // fixmap
    buffer.writeMessagePackInt(1)
    buffer.writeMessagePackMapHeader(count: 1)
    buffer.writeMessagePackInt(2)
    buffer.writeMessagePackBool(true)
    buffer.writeMessagePackInt(4)
    buffer.writeMessagePackBinary(bytes: [0xde, 0xad, 0xbe, 0xef, 0x00] as [UInt8])  // bin8
    buffer.writeMessagePackInt(5)
    buffer.writeMessagePackExt(type: 7, payload: mpBytes("0102030405060708"))  // fixext8
    buffer.writeMessagePackInt(6)
    buffer.writeMessagePackDouble(1.1)  // float64
    buffer.writeMessagePackInt(7)
    buffer.writeMessagePackUInt(.max)  // uint64
    buffer.writeMessagePackInt(8)
    buffer.writeMessagePackInt(.min)  // int64
    buffer.writeMessagePackInt(9)
    buffer.writeMessagePackString(String(repeating: "s", count: 40))  // str8
    buffer.writeMessagePackInt(10)
    buffer.writeMessagePackFloat(1.5)  // float32
    buffer.writeMessagePackInt(11)
    buffer.writeMessagePackUInt(200)  // uint8
    buffer.writeMessagePackInt(12)
    buffer.writeMessagePackInt(-100)  // int8
    buffer.writeMessagePackInt(13)
    buffer.writeMessagePackUInt(50_000)  // uint16
    buffer.writeMessagePackInt(14)
    buffer.writeMessagePackUInt(4_000_000_000)  // uint32
    buffer.writeMessagePackInt(15)
    buffer.writeMessagePackInt(-100_000)  // int32
    buffer.writeMessagePackInt(16)
    buffer.writeMessagePackString(String(repeating: "t", count: 300))  // str16
    buffer.writeMessagePackInt(17)
    buffer.writeMessagePackBinary(bytes: [UInt8](repeating: 0xab, count: 300))  // bin16
    buffer.writeMessagePackInt(18)
    buffer.writeMessagePackExt(type: 1, payload: mpBytes("aa"))  // fixext1
    buffer.writeMessagePackInt(19)
    buffer.writeMessagePackExt(type: 2, payload: mpBytes("aabb"))  // fixext2
    buffer.writeMessagePackInt(20)
    buffer.writeMessagePackExt(type: -1, payload: mpBytes("01020304"))  // fixext4
    buffer.writeMessagePackInt(21)
    buffer.writeMessagePackExt(
        type: 3,
        payload: ByteBuffer(bytes: [UInt8](repeating: 0x11, count: 16))
    )  // fixext16
    buffer.writeMessagePackInt(22)
    buffer.writeMessagePackExt(
        type: 4,
        payload: ByteBuffer(bytes: [UInt8](repeating: 0x22, count: 17))
    )  // ext8
    buffer.writeMessagePackInt(23)
    buffer.writeMessagePackArrayHeader(count: 16)  // array16
    for element in 0..<16 {
        buffer.writeMessagePackInt(Int64(element))
    }
    buffer.writeMessagePackInt(24)
    buffer.writeMessagePackMapHeader(count: 16)  // map16
    for entry in 0..<16 {
        buffer.writeMessagePackInt(Int64(entry))
        buffer.writeMessagePackNil()
    }
    buffer.writeMessagePackInt(25)
    buffer.writeBytes(mpBytes("db00000003616263").readableBytesView)  // str32 "abc"
    buffer.writeMessagePackInt(26)
    buffer.writeBytes(mpBytes("c600000002dead").readableBytesView)  // bin32, 2 bytes
    buffer.writeMessagePackInt(27)
    buffer.writeBytes(mpBytes("c8000205aabb").readableBytesView)  // ext16, 2 bytes
    buffer.writeMessagePackInt(28)
    buffer.writeBytes(mpBytes("c90000000405aabbccdd").readableBytesView)  // ext32, 4 bytes
    buffer.writeMessagePackInt(29)
    buffer.writeBytes(mpBytes("dd0000000101").readableBytesView)  // array32, 1 element
    buffer.writeMessagePackInt(30)
    buffer.writeBytes(mpBytes("df000000010101").readableBytesView)  // map32, 1 entry
    return buffer
}

/// `depth` nested arrays, innermost element nil: [[[...nil...]]].
private func makeDeepValue(depth: Int) -> ByteBuffer {
    var buffer = ByteBuffer()
    for _ in 0..<depth {
        buffer.writeMessagePackArrayHeader(count: 1)
    }
    buffer.writeMessagePackNil()
    return buffer
}

@Suite("Adversarial input")
struct AdversarialTests {
    @Test("truncation at every byte position of a complex value is a truncated error")
    func truncationEverywhere() {
        let complete = makeComplexValue()
        let total = complete.readableBytes
        for length in 0..<total {
            let prefix = complete.getSlice(at: complete.readerIndex, length: length)!
            var skipCursor = prefix
            #expect(
                skipCursor.skipMessagePackValue().mpFailure == .truncated,
                "skip at prefix length \(length)"
            )
            #expect(skipCursor.readerIndex == prefix.readerIndex, "skip restores the reader index")
            #expect(
                MMPackDecoder().decode(Probe.self, from: prefix) == .failure(.truncated),
                "decode at prefix length \(length)"
            )
        }
        // The complete value skips and decodes fine.
        var full = complete
        #expect(full.skipMessagePackValue().mpSuccess != nil)
        #expect(full.readableBytes == 0)
        #expect(MMPackDecoder().decode(Probe.self, from: complete) == .success(Probe(absent: nil)))
    }

    @Test("nesting beyond the default cap fails, at the cap succeeds")
    func nestingCap() {
        var atCap = makeDeepValue(depth: 128)
        #expect(atCap.skipMessagePackValue().mpSuccess != nil)

        var beyondCap = makeDeepValue(depth: 129)
        #expect(beyondCap.skipMessagePackValue().mpFailure == .nestingTooDeep(limit: 128))

        var wayBeyond = makeDeepValue(depth: 500)
        #expect(wayBeyond.skipMessagePackValue().mpFailure == .nestingTooDeep(limit: 128))

        #expect(
            MMPackDecoder().decode(DeepBox.self, from: makeDeepValue(depth: 500)).mpFailure
                == .nestingTooDeep(limit: 128)
        )
        let okay = MMPackDecoder().decode(DeepBox.self, from: makeDeepValue(depth: 100))
        #expect(okay.mpSuccess?.levels == 100)
    }

    @Test("configurable depth cap applies to decode and skip")
    func configurableCap() {
        let decoder = MMPackDecoder(maxDepth: 4)
        #expect(decoder.decode(DeepBox.self, from: makeDeepValue(depth: 4)).mpSuccess?.levels == 4)
        #expect(
            decoder.decode(DeepBox.self, from: makeDeepValue(depth: 5)).mpFailure
                == .nestingTooDeep(limit: 4)
        )
        var deep = makeDeepValue(depth: 5)
        #expect(deep.skipMessagePackValue(maxDepth: 4).mpFailure == .nestingTooDeep(limit: 4))
    }

    @Test("a too-deep value hiding under an unknown key still trips the cap")
    func deepUnknownValue() {
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 1)
        buffer.writeMessagePackInt(99)
        buffer.writeImmutableBuffer(makeDeepValue(depth: 500))
        #expect(
            MMPackDecoder().decode(Probe.self, from: buffer).mpFailure
                == .nestingTooDeep(limit: 128)
        )
    }

    @Test("duplicate map keys: first occurrence wins")
    func duplicateKeys() {
        struct Named: Codable, Equatable {
            var name: String
            enum CodingKeys: Int, CodingKey {
                case name = 1
            }
        }
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 2)
        buffer.writeMessagePackInt(1)
        buffer.writeMessagePackString("first")
        buffer.writeMessagePackInt(1)
        buffer.writeMessagePackString("second")
        #expect(MMPackDecoder().decode(Named.self, from: buffer) == .success(Named(name: "first")))
    }

    @Test("invalid UTF-8 into String errors; into ByteBuffer slices fine")
    func invalidUTF8() {
        let bytes = mpBytes("a2fffe")  // fixstr claiming 2 bytes of invalid UTF-8
        #expect(MMPackDecoder().decode(String.self, from: bytes) == .failure(.invalidUTF8))
        var reader = bytes
        #expect(reader.readMessagePackString() == .failure(.invalidUTF8))
        #expect(MMPackDecoder().decode(ByteBuffer.self, from: bytes) == .success(mpBytes("fffe")))

        // Overlong encoding (0xc0 0x80 for NUL) and a UTF-16 surrogate (0xed 0xa0 0x80).
        #expect(
            MMPackDecoder().decode(String.self, from: mpBytes("a2c080")) == .failure(.invalidUTF8))
        #expect(
            MMPackDecoder().decode(String.self, from: mpBytes("a3eda080")) == .failure(.invalidUTF8)
        )

        // A struct field with invalid UTF-8: String field fails, ByteBuffer field succeeds.
        struct StringField: Codable, Equatable {
            var v: String
            enum CodingKeys: Int, CodingKey { case v = 1 }
        }
        struct BufferField: Codable, Equatable {
            var v: ByteBuffer
            enum CodingKeys: Int, CodingKey { case v = 1 }
        }
        var mapBuffer = ByteBuffer()
        mapBuffer.writeMessagePackMapHeader(count: 1)
        mapBuffer.writeMessagePackInt(1)
        mapBuffer.writeBytes(mpBytes("a2fffe").readableBytesView)
        #expect(MMPackDecoder().decode(StringField.self, from: mapBuffer) == .failure(.invalidUTF8))
        #expect(
            MMPackDecoder().decode(BufferField.self, from: mapBuffer)
                == .success(BufferField(v: mpBytes("fffe")))
        )
    }

    @Test("type mismatches are typed errors, not crashes")
    func typeMismatches() {
        #expect(
            MMPackDecoder().decode(String.self, from: mpBytes("2a"))
                == .failure(.typeMismatch(expected: "str", format: 0x2a))
        )
        #expect(
            MMPackDecoder().decode(Bool.self, from: mpBytes("c0"))
                == .failure(.typeMismatch(expected: "bool", format: 0xc0))
        )
        #expect(
            MMPackDecoder().decode([Int].self, from: mpBytes("81c0c0"))
                == .failure(.typeMismatch(expected: "array", format: 0x81))
        )
        #expect(
            MMPackDecoder().decode([Int: Int].self, from: mpBytes("90"))
                == .failure(.typeMismatch(expected: "map", format: 0x90))
        )
        #expect(
            MMPackDecoder().decode(Double.self, from: mpBytes("01"))
                == .failure(.typeMismatch(expected: "float", format: 0x01))
        )
    }

    @Test("the reserved 0xc1 byte is an invalidFormat error")
    func reservedByte() {
        var skipCursor = mpBytes("c1")
        #expect(skipCursor.skipMessagePackValue().mpFailure == .invalidFormat(byte: 0xc1))
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 1)
        buffer.writeMessagePackInt(99)
        buffer.writeInteger(UInt8(0xc1))
        #expect(
            MMPackDecoder().decode(Probe.self, from: buffer) == .failure(.invalidFormat(byte: 0xc1))
        )
    }

    @Test("a map count lying about its size cannot hang or over-allocate")
    func lyingMapCount() {
        // map32 claims 2^32 - 1 entries with a 1-byte body.
        var buffer = mpBytes("dfffffffff01")
        #expect(buffer.skipMessagePackValue().mpFailure == .truncated)
        #expect(
            MMPackDecoder().decode(Probe.self, from: mpBytes("dfffffffff01"))
                == .failure(.truncated))
        // array32 claims 2^32 - 1 elements.
        #expect(
            MMPackDecoder().decode([Int].self, from: mpBytes("ddffffffff01"))
                == .failure(.truncated))
    }

    @Test("unusable map keys (bool, huge uint64, invalid-UTF-8 string) are skipped")
    func unusableKeys() {
        struct Named: Codable, Equatable {
            var name: String
            enum CodingKeys: Int, CodingKey { case name = 1 }
        }
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 4)
        buffer.writeMessagePackBool(true)  // bool key
        buffer.writeMessagePackString("ignored")
        buffer.writeMessagePackUInt(.max)  // uint64 key beyond Int64.max
        buffer.writeMessagePackString("ignored")
        buffer.writeBytes(mpBytes("a2fffe").readableBytesView)  // invalid-UTF-8 string key
        buffer.writeMessagePackString("ignored")
        buffer.writeMessagePackInt(1)
        buffer.writeMessagePackString("kept")
        #expect(MMPackDecoder().decode(Named.self, from: buffer) == .success(Named(name: "kept")))
    }
}

/// Always fails to encode; simulates a child `Encodable` whose failure the
/// enclosing type swallows (`try?`) — legal under the `Codable` contract.
private struct Bomb: Encodable {
    func encode(to encoder: any Encoder) throws {
        throw MMWireError.encodingFailed(description: "boom")
    }
}

/// Fails only after opening a nested container and writing a field, so rollback
/// must also discard a flushed tail segment and a partial child container.
private struct LateBomb: Encodable {
    enum CodingKeys: Int, CodingKey {
        case x = 1
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .x)
        throw MMWireError.encodingFailed(description: "late boom")
    }
}

/// A container must never be finalized with a count that includes a key or slot
/// whose value was not fully written: `.success` output that the module's own
/// structural walker rejects would violate the typed-failure posture.
@Suite("Encoder rollback on child-encode failure")
struct EncoderRollbackTests {
    private static func expectSingleCompleteValue(_ encoded: Result<ByteBuffer, MMWireError>) {
        var walker = encoded.mpSuccess ?? ByteBuffer()
        #expect(walker.skipMessagePackValue().mpSuccess != nil)
        #expect(walker.readableBytes == 0)
    }

    @Test("a swallowed keyed child failure rolls the key back")
    func keyedSwallowedFailure() {
        struct Swallower: Encodable {
            enum CodingKeys: Int, CodingKey {
                case a = 1
                case b = 2
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try? container.encode(Bomb(), forKey: .a)
                try container.encode(7, forKey: .b)
            }
        }
        let encoded = MMPackEncoder().encode(Swallower())
        #expect(encoded.map(mpHex) == .success("810207"))
        Self.expectSingleCompleteValue(encoded)
    }

    @Test("a swallowed failure after partial nested output rolls everything back")
    func keyedSwallowedLateFailure() {
        struct Swallower: Encodable {
            enum CodingKeys: Int, CodingKey {
                case a = 1
                case b = 2
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try? container.encode(LateBomb(), forKey: .a)
                try container.encode(7, forKey: .b)
            }
        }
        let encoded = MMPackEncoder().encode(Swallower())
        #expect(encoded.map(mpHex) == .success("810207"))
        Self.expectSingleCompleteValue(encoded)
    }

    @Test("a swallowed unkeyed child failure rolls the slot back")
    func unkeyedSwallowedFailure() {
        struct Swallower: Encodable {
            func encode(to encoder: any Encoder) throws {
                var container = encoder.unkeyedContainer()
                try container.encode(1)
                try? container.encode(Bomb())
                try? container.encode(LateBomb())
                try container.encode(2)
            }
        }
        let encoded = MMPackEncoder().encode(Swallower())
        #expect(encoded.map(mpHex) == .success("920102"))
        Self.expectSingleCompleteValue(encoded)
    }

    @Test("an unswallowed child failure still fails the whole encode, typed")
    func propagatedFailure() {
        struct Outer: Encodable {
            enum CodingKeys: Int, CodingKey {
                case a = 1
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(Bomb(), forKey: .a)
            }
        }
        #expect(
            MMPackEncoder().encode(Outer())
                == .failure(.encodingFailed(description: "boom"))
        )
    }
}
