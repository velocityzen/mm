import MMWire
import NIOCore
import Testing

/// Payload shaped like a future request map: entity at reserved key 0, plus other fields.
private func makeRequestPayload() -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.writeMessagePackMapHeader(count: 4)
    buffer.writeMessagePackInt(0)
    buffer.writeMessagePackString("journal.append")
    buffer.writeMessagePackInt(1)
    buffer.writeMessagePackInt(42)
    buffer.writeMessagePackInt(2)
    buffer.writeMessagePackMapHeader(count: 1)
    buffer.writeMessagePackInt(1)
    buffer.writeMessagePackString("nested")
    buffer.writeMessagePackInt(3)
    buffer.writeMessagePackArrayHeader(count: 2)
    buffer.writeMessagePackInt(1)
    buffer.writeMessagePackInt(2)
    return buffer
}

@Suite("Partial field access (decodeField)")
struct DecodeFieldTests {
    @Test("decodes exactly the requested top-level key")
    func presentKeys() {
        let payload = makeRequestPayload()
        #expect(
            MMPackDecoder().decodeField(at: 0, as: String.self, fromMapPayload: payload)
                == .success("journal.append")
        )
        #expect(
            MMPackDecoder().decodeField(at: 1, as: Int.self, fromMapPayload: payload)
                == .success(42))
        #expect(
            MMPackDecoder().decodeField(at: 3, as: [Int].self, fromMapPayload: payload)
                == .success([1, 2])
        )
        struct Nested: Codable, Equatable {
            var v: String
            enum CodingKeys: Int, CodingKey { case v = 1 }
        }
        #expect(
            MMPackDecoder().decodeField(at: 2, as: Nested.self, fromMapPayload: payload)
                == .success(Nested(v: "nested"))
        )
    }

    @Test("absent key is nil, not an error")
    func absentKey() {
        #expect(
            MMPackDecoder().decodeField(
                at: 9, as: String.self, fromMapPayload: makeRequestPayload())
                == .success(nil)
        )
    }

    @Test("only the top-level map is indexed, never nested maps")
    func topLevelOnly() {
        // The nested map at key 2 contains key 7; asking for 7 must return nil.
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 1)
        buffer.writeMessagePackInt(2)
        buffer.writeMessagePackMapHeader(count: 1)
        buffer.writeMessagePackInt(7)
        buffer.writeMessagePackString("hidden")
        #expect(
            MMPackDecoder().decodeField(at: 7, as: String.self, fromMapPayload: buffer)
                == .success(nil)
        )
    }

    @Test("first occurrence of a duplicate key wins")
    func duplicateKey() {
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 2)
        buffer.writeMessagePackInt(0)
        buffer.writeMessagePackString("first")
        buffer.writeMessagePackInt(0)
        buffer.writeMessagePackString("second")
        #expect(
            MMPackDecoder().decodeField(at: 0, as: String.self, fromMapPayload: buffer)
                == .success("first")
        )
    }

    @Test("string keys are passed over while scanning for the int key")
    func stringKeysSkipped() {
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 2)
        buffer.writeMessagePackString("method")
        buffer.writeMessagePackString("noise")
        buffer.writeMessagePackInt(0)
        buffer.writeMessagePackString("wanted")
        #expect(
            MMPackDecoder().decodeField(at: 0, as: String.self, fromMapPayload: buffer)
                == .success("wanted")
        )
    }

    @Test("wrong value type at the key is a typed error")
    func wrongType() {
        #expect(
            MMPackDecoder().decodeField(
                at: 1, as: String.self, fromMapPayload: makeRequestPayload())
                == .failure(.typeMismatch(expected: "str", format: 0x2a))
        )
    }

    @Test("non-map payload is a typed error")
    func nonMapPayload() {
        #expect(
            MMPackDecoder().decodeField(at: 0, as: String.self, fromMapPayload: mpBytes("93010203"))
                == .failure(.typeMismatch(expected: "map", format: 0x93))
        )
    }

    @Test("truncated payload is a truncated error")
    func truncatedPayload() {
        let payload = makeRequestPayload()
        // Cut inside the value of key 3 (the trailing array) while scanning for a later key.
        let prefix = payload.getSlice(at: payload.readerIndex, length: payload.readableBytes - 1)!
        #expect(
            MMPackDecoder().decodeField(at: 9, as: String.self, fromMapPayload: prefix)
                == .failure(.truncated)
        )
    }

    @Test("ByteBuffer field decodes as a zero-copy slice")
    func byteBufferField() {
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: 1)
        buffer.writeMessagePackInt(4)
        buffer.writeMessagePackBinary(bytes: [9, 8, 7] as [UInt8])
        #expect(
            MMPackDecoder().decodeField(at: 4, as: ByteBuffer.self, fromMapPayload: buffer)
                == .success(ByteBuffer(bytes: [9, 8, 7]))
        )
    }

    @Test("decoded ByteBuffer shares the parent buffer's storage (zero-copy, not equal-bytes)")
    func zeroCopySliceStorageIdentity() {
        // ByteBuffer's == compares readable bytes, so an implementation that
        // copied the payload would pass every value-equality test. Prove slicing
        // by pointer identity: the decoded payload's base address must sit at the
        // payload's exact offset inside the parent's storage.
        // Layout: fixmap(1) + key(1) + bin8 header(2) = payload at offset 4.
        var parent = ByteBuffer()
        parent.writeMessagePackMapHeader(count: 1)
        parent.writeMessagePackInt(4)
        parent.writeMessagePackBinary(bytes: [9, 8, 7] as [UInt8])
        let parentBase = parent.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress) }

        let viaField = MMPackDecoder()
            .decodeField(at: 4, as: ByteBuffer.self, fromMapPayload: parent)
            .mpSuccess
            .flatMap { $0 }
        let viaFieldBase = viaField.flatMap { slice in
            slice.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress) }
        }
        #expect(viaFieldBase == parentBase + 4)

        struct BufferField: Codable, Equatable {
            var v: ByteBuffer
            enum CodingKeys: Int, CodingKey {
                case v = 1
            }
        }
        var structParent = ByteBuffer()
        structParent.writeMessagePackMapHeader(count: 1)
        structParent.writeMessagePackInt(1)
        structParent.writeMessagePackBinary(bytes: [9, 8, 7] as [UInt8])
        let structBase = structParent.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress) }
        let viaStruct = MMPackDecoder().decode(BufferField.self, from: structParent).mpSuccess
        let viaStructBase = viaStruct.flatMap { decoded in
            decoded.v.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress) }
        }
        #expect(viaStructBase == structBase + 4)
    }
}
