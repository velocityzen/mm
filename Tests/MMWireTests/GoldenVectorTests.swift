import MMWire
import NIOCore
import Testing

@Suite("Golden vectors: canonical encode and decode")
struct GoldenVectorTests {
    @Test("nil, true, false")
    func nilAndBool() {
        var buffer = ByteBuffer()
        buffer.writeMessagePackNil()
        #expect(mpHex(buffer) == "c0")
        buffer.clear()
        buffer.writeMessagePackBool(false)
        #expect(mpHex(buffer) == "c2")
        buffer.clear()
        buffer.writeMessagePackBool(true)
        #expect(mpHex(buffer) == "c3")

        var nilBytes = mpBytes("c0")
        #expect(nilBytes.readMessagePackNil().mpSuccess != nil)
        var trueBytes = mpBytes("c3")
        #expect(trueBytes.readMessagePackBool() == .success(true))
        var falseBytes = mpBytes("c2")
        #expect(falseBytes.readMessagePackBool() == .success(false))

        #expect(MMPackEncoder().encode(true).map(mpHex) == .success("c3"))
        #expect(MMPackDecoder().decode(Bool.self, from: mpBytes("c2")) == .success(false))
        #expect(MMPackEncoder().encode(Optional<Int>.none).map(mpHex) == .success("c0"))
        #expect(MMPackDecoder().decode(Int?.self, from: mpBytes("c0")) == .success(nil))
    }

    @Test("signed integers", arguments: signedIntVectors)
    func signedInts(vector: MPVector<Int64>) {
        var buffer = ByteBuffer()
        buffer.writeMessagePackInt(vector.value)
        #expect(mpHex(buffer) == vector.hex)
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackInt() == .success(vector.value))
        #expect(bytes.readableBytes == 0)

        #expect(MMPackEncoder().encode(vector.value).map(mpHex) == .success(vector.hex))
        #expect(
            MMPackDecoder().decode(Int64.self, from: mpBytes(vector.hex)) == .success(vector.value))
    }

    @Test("unsigned integers", arguments: unsignedIntVectors)
    func unsignedInts(vector: MPVector<UInt64>) {
        var buffer = ByteBuffer()
        buffer.writeMessagePackUInt(vector.value)
        #expect(mpHex(buffer) == vector.hex)
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackUInt() == .success(vector.value))

        #expect(MMPackEncoder().encode(vector.value).map(mpHex) == .success(vector.hex))
        #expect(
            MMPackDecoder().decode(UInt64.self, from: mpBytes(vector.hex)) == .success(vector.value)
        )
    }

    @Test("float32 bit patterns", arguments: floatVectors)
    func floats(vector: MPVector<Float>) {
        var buffer = ByteBuffer()
        buffer.writeMessagePackFloat(vector.value)
        #expect(mpHex(buffer) == vector.hex)
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackFloat().mpSuccess?.bitPattern == vector.value.bitPattern)

        #expect(MMPackEncoder().encode(vector.value).map(mpHex) == .success(vector.hex))
        let decoded = MMPackDecoder().decode(Float.self, from: mpBytes(vector.hex))
        #expect(decoded.mpSuccess?.bitPattern == vector.value.bitPattern)
    }

    @Test("float64 bit patterns", arguments: doubleVectors)
    func doubles(vector: MPVector<Double>) {
        var buffer = ByteBuffer()
        buffer.writeMessagePackDouble(vector.value)
        #expect(mpHex(buffer) == vector.hex)
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackDouble().mpSuccess?.bitPattern == vector.value.bitPattern)

        #expect(MMPackEncoder().encode(vector.value).map(mpHex) == .success(vector.hex))
        let decoded = MMPackDecoder().decode(Double.self, from: mpBytes(vector.hex))
        #expect(decoded.mpSuccess?.bitPattern == vector.value.bitPattern)
    }

    @Test("strings including multi-byte UTF-8", arguments: stringVectors)
    func strings(vector: MPVector<String>) {
        var buffer = ByteBuffer()
        buffer.writeMessagePackString(vector.value)
        #expect(mpHex(buffer) == vector.hex)
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackString() == .success(vector.value))

        #expect(MMPackEncoder().encode(vector.value).map(mpHex) == .success(vector.hex))
        #expect(
            MMPackDecoder().decode(String.self, from: mpBytes(vector.hex)) == .success(vector.value)
        )
    }

    @Test("bin payloads", arguments: binVectors)
    func bins(vector: MPVector<[UInt8]>) {
        var buffer = ByteBuffer()
        buffer.writeMessagePackBinary(bytes: vector.value)
        #expect(mpHex(buffer) == vector.hex)
        var bytes = mpBytes(vector.hex)
        let slice = bytes.readMessagePackBinary()
        #expect(slice.mpSuccess.map { Array($0.readableBytesView) } == vector.value)

        // Codable path: ByteBuffer encodes as bin, decodes as a zero-copy slice.
        #expect(
            MMPackEncoder().encode(ByteBuffer(bytes: vector.value)).map(mpHex)
                == .success(vector.hex))
        let decoded = MMPackDecoder().decode(ByteBuffer.self, from: mpBytes(vector.hex))
        #expect(decoded == .success(ByteBuffer(bytes: vector.value)))
    }

    @Test("arrays", arguments: arrayVectors)
    func arrays(vector: MPVector<[Int64]>) {
        var buffer = ByteBuffer()
        buffer.writeMessagePackArrayHeader(count: vector.value.count)
        for element in vector.value {
            buffer.writeMessagePackInt(element)
        }
        #expect(mpHex(buffer) == vector.hex)

        #expect(MMPackEncoder().encode(vector.value).map(mpHex) == .success(vector.hex))
        #expect(
            MMPackDecoder().decode([Int64].self, from: mpBytes(vector.hex))
                == .success(vector.value))
    }

    @Test("maps with integer keys", arguments: mapVectors)
    func maps(vector: MPVector<[Int: Int64]>) {
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: vector.value.count)
        for (key, value) in vector.value.sorted(by: { $0.key < $1.key }) {
            buffer.writeMessagePackInt(Int64(key))
            buffer.writeMessagePackInt(value)
        }
        #expect(mpHex(buffer) == vector.hex)

        // Dictionary encode order is nondeterministic, so byte-compare only 0/1-entry maps.
        if vector.value.count <= 1 {
            #expect(MMPackEncoder().encode(vector.value).map(mpHex) == .success(vector.hex))
        }
        #expect(
            MMPackDecoder().decode([Int: Int64].self, from: mpBytes(vector.hex))
                == .success(vector.value))
    }

    @Test("ext families pass through", arguments: extVectors)
    func exts(vector: MPVector<MMPackExtValue>) {
        var buffer = ByteBuffer()
        buffer.writeMessagePackExt(type: vector.value.type, payload: vector.value.payload)
        #expect(mpHex(buffer) == vector.hex)
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackExt() == .success(vector.value))
        #expect(bytes.readableBytes == 0)
    }

    @Test("struct with integer CodingKeys encodes as int-keyed fixmap")
    func intKeyedStruct() {
        struct V1: Codable, Equatable {
            var id: Int
            var name: String
            enum CodingKeys: Int, CodingKey {
                case id = 1
                case name = 2
            }
        }
        let encoded = MMPackEncoder().encode(V1(id: 42, name: "mm"))
        #expect(encoded.map(mpHex) == .success("82012a02a26d6d"))
        #expect(
            MMPackDecoder().decode(V1.self, from: mpBytes("82012a02a26d6d"))
                == .success(V1(id: 42, name: "mm")))
    }

    @Test("struct without intValue keys falls back to string keys")
    func stringKeyedStruct() {
        struct Plain: Codable, Equatable {
            var a: Int
        }
        let encoded = MMPackEncoder().encode(Plain(a: 1))
        #expect(encoded.map(mpHex) == .success("81a16101"))
        #expect(
            MMPackDecoder().decode(Plain.self, from: mpBytes("81a16101")) == .success(Plain(a: 1)))
    }

    @Test("map keys use the smallest integer representation")
    func widekeyStruct() {
        struct Wide: Codable, Equatable {
            var v: Bool
            enum CodingKeys: Int, CodingKey {
                case v = 200
            }
        }
        let encoded = MMPackEncoder().encode(Wide(v: true))
        #expect(encoded.map(mpHex) == .success("81ccc8c3"))
        #expect(
            MMPackDecoder().decode(Wide.self, from: mpBytes("81ccc8c3")) == .success(Wide(v: true)))
    }
}

@Suite("Golden vectors: length boundaries")
struct LengthBoundaryTests {
    @Test("str8/str16/str32 length boundaries")
    func stringBoundaries() {
        let cases: [(count: Int, header: String)] = [
            (31, "bf"), (32, "d920"),
            (255, "d9ff"), (256, "da0100"),
            (65535, "daffff"), (65536, "db00010000"),
        ]
        for testCase in cases {
            let value = String(repeating: "a", count: testCase.count)
            let expected = testCase.header + String(repeating: "61", count: testCase.count)
            var buffer = ByteBuffer()
            buffer.writeMessagePackString(value)
            #expect(mpHex(buffer) == expected, "writer, count \(testCase.count)")
            #expect(
                MMPackEncoder().encode(value).map(mpHex) == .success(expected),
                "encoder, count \(testCase.count)")
            #expect(
                MMPackDecoder().decode(String.self, from: mpBytes(expected)) == .success(value),
                "decoder, count \(testCase.count)"
            )
        }
    }

    @Test("bin8/bin16/bin32 length boundaries")
    func binBoundaries() {
        let cases: [(count: Int, header: String)] = [
            (0, "c400"),
            (255, "c4ff"), (256, "c50100"),
            (65535, "c5ffff"), (65536, "c600010000"),
        ]
        for testCase in cases {
            let payload = [UInt8](repeating: 0, count: testCase.count)
            let expected = testCase.header + String(repeating: "00", count: testCase.count)
            var buffer = ByteBuffer()
            buffer.writeMessagePackBinary(bytes: payload)
            #expect(mpHex(buffer) == expected, "writer, count \(testCase.count)")
            #expect(
                MMPackEncoder().encode(ByteBuffer(bytes: payload)).map(mpHex) == .success(expected),
                "encoder, count \(testCase.count)"
            )
            let decoded = MMPackDecoder().decode(ByteBuffer.self, from: mpBytes(expected))
            #expect(
                decoded == .success(ByteBuffer(bytes: payload)), "decoder, count \(testCase.count)")
        }
    }

    @Test("array16/array32 length boundaries")
    func arrayBoundaries() {
        let cases: [(count: Int, header: String)] = [
            (15, "9f"), (16, "dc0010"),
            (65535, "dcffff"), (65536, "dd00010000"),
        ]
        for testCase in cases {
            let value = [Int64](repeating: 0, count: testCase.count)
            let expected = testCase.header + String(repeating: "00", count: testCase.count)
            #expect(
                MMPackEncoder().encode(value).map(mpHex) == .success(expected),
                "encoder, count \(testCase.count)")
            #expect(
                MMPackDecoder().decode([Int64].self, from: mpBytes(expected)) == .success(value),
                "decoder, count \(testCase.count)"
            )
        }
    }

    @Test("map16/map32 length boundaries")
    func mapBoundaries() {
        let cases: [(count: Int, header: String)] = [
            (15, "8f"), (16, "de0010"), (65535, "deffff"), (65536, "df00010000"),
        ]
        for testCase in cases {
            var expected = testCase.header
            var buffer = ByteBuffer()
            buffer.writeMessagePackMapHeader(count: testCase.count)
            for key in 0..<testCase.count {
                expected += specUIntHex(key) + "00"
                buffer.writeMessagePackInt(Int64(key))
                buffer.writeMessagePackInt(0)
            }
            #expect(mpHex(buffer) == expected, "writer, count \(testCase.count)")
            let value = Dictionary(
                uniqueKeysWithValues: (0..<testCase.count).map { ($0, Int64(0)) })
            #expect(
                MMPackDecoder().decode([Int: Int64].self, from: mpBytes(expected))
                    == .success(value),
                "decoder, count \(testCase.count)"
            )
        }
    }

    @Test("ext8/ext16/ext32 length boundaries")
    func extBoundaries() {
        let cases: [(count: Int, header: String)] = [
            (0, "c700"), (3, "c703"), (255, "c7ff"),
            (256, "c80100"), (65535, "c8ffff"), (65536, "c900010000"),
        ]
        for testCase in cases {
            let payload = ByteBuffer(bytes: [UInt8](repeating: 0, count: testCase.count))
            let expected = testCase.header + "05" + String(repeating: "00", count: testCase.count)
            var buffer = ByteBuffer()
            buffer.writeMessagePackExt(type: 5, payload: payload)
            #expect(mpHex(buffer) == expected, "writer, count \(testCase.count)")
            var bytes = mpBytes(expected)
            #expect(
                bytes.readMessagePackExt() == .success(MMPackExtValue(type: 5, payload: payload)),
                "reader, count \(testCase.count)"
            )
        }
    }
}

@Suite("Non-canonical vectors decode (never re-encode)")
struct NonCanonicalVectorTests {
    @Test("wide and cross-signed integers into Int64", arguments: nonCanonicalSignedIntVectors)
    func signedInts(vector: MPVector<Int64>) {
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackInt() == .success(vector.value))
        #expect(
            MMPackDecoder().decode(Int64.self, from: mpBytes(vector.hex)) == .success(vector.value))
    }

    @Test("signed formats into UInt64 when non-negative", arguments: nonCanonicalUnsignedIntVectors)
    func unsignedInts(vector: MPVector<UInt64>) {
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackUInt() == .success(vector.value))
        #expect(
            MMPackDecoder().decode(UInt64.self, from: mpBytes(vector.hex)) == .success(vector.value)
        )
    }

    @Test("cross-signedness into narrow targets")
    func narrowTargets() {
        // uint8-encoded 5 into Int8; positive int64 into UInt8; fixint into UInt8.
        #expect(MMPackDecoder().decode(Int8.self, from: mpBytes("cc05")) == .success(5))
        #expect(
            MMPackDecoder().decode(UInt8.self, from: mpBytes("d30000000000000005")) == .success(5))
        #expect(MMPackDecoder().decode(UInt8.self, from: mpBytes("05")) == .success(5))
        #expect(MMPackDecoder().decode(Int16.self, from: mpBytes("ccff")) == .success(255))
    }

    @Test("out-of-range integers are typed errors")
    func outOfRange() {
        #expect(
            MMPackDecoder().decode(Int8.self, from: mpBytes("cd0100"))
                == .failure(.numberOutOfRange(target: "Int8"))
        )
        #expect(
            MMPackDecoder().decode(UInt64.self, from: mpBytes("ff"))
                == .failure(.numberOutOfRange(target: "UInt64"))
        )
        #expect(
            MMPackDecoder().decode(Int64.self, from: mpBytes("cfffffffffffffffff"))
                == .failure(.numberOutOfRange(target: "Int64"))
        )
    }

    @Test("wide strings", arguments: nonCanonicalStringVectors)
    func strings(vector: MPVector<String>) {
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackString() == .success(vector.value))
        #expect(
            MMPackDecoder().decode(String.self, from: mpBytes(vector.hex)) == .success(vector.value)
        )
    }

    @Test("wide bins and str-as-binary", arguments: nonCanonicalBinVectors)
    func bins(vector: MPVector<[UInt8]>) {
        var bytes = mpBytes(vector.hex)
        #expect(
            bytes.readMessagePackBinary().mpSuccess.map { Array($0.readableBytesView) }
                == vector.value)
        let decoded = MMPackDecoder().decode(ByteBuffer.self, from: mpBytes(vector.hex))
        #expect(decoded == .success(ByteBuffer(bytes: vector.value)))
    }

    @Test("wide arrays", arguments: nonCanonicalArrayVectors)
    func arrays(vector: MPVector<[Int64]>) {
        #expect(
            MMPackDecoder().decode([Int64].self, from: mpBytes(vector.hex))
                == .success(vector.value))
    }

    @Test("wide maps", arguments: nonCanonicalMapVectors)
    func maps(vector: MPVector<[Int: Int64]>) {
        #expect(
            MMPackDecoder().decode([Int: Int64].self, from: mpBytes(vector.hex))
                == .success(vector.value))
    }

    @Test("float64 into Float when exactly representable", arguments: nonCanonicalFloatVectors)
    func floats(vector: MPVector<Float>) {
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackFloat().mpSuccess?.bitPattern == vector.value.bitPattern)
        let decoded = MMPackDecoder().decode(Float.self, from: mpBytes(vector.hex))
        #expect(decoded.mpSuccess?.bitPattern == vector.value.bitPattern)
    }

    @Test("float64 not representable as Float is a typed error")
    func inexactFloat() {
        // 1.1 is not exactly representable in float32.
        #expect(
            MMPackDecoder().decode(Float.self, from: mpBytes("cb3ff199999999999a"))
                == .failure(.numberOutOfRange(target: "Float"))
        )
    }

    @Test("float64 NaN narrows to a Float NaN instead of failing representability")
    func nanIntoFloat() {
        // Exercises the dedicated isNaN branch in readMessagePackFloat:
        // Float(exactly: Double.nan) is nil, so without it every wire float64 NaN
        // into a Float target would misreport as numberOutOfRange.
        var reader = mpBytes("cb7ff8000000000000")
        #expect(reader.readMessagePackFloat().mpSuccess?.isNaN == true)
        #expect(reader.readableBytes == 0)
        #expect(
            MMPackDecoder().decode(Float.self, from: mpBytes("cb7ff8000000000000")).mpSuccess?.isNaN
                == true
        )
        // A signaling NaN's payload bits are canonicalized by the Float conversion;
        // only NaN-ness is guaranteed for the Float target. (The Double target
        // preserves the payload bit-exactly — pinned in doubleVectors.)
        #expect(
            MMPackDecoder().decode(Float.self, from: mpBytes("cb7ff4000000000001")).mpSuccess?.isNaN
                == true
        )
        // Codable round trips preserve the quiet-NaN bit patterns exactly.
        let encodedFloat = MMPackEncoder().encode(Float.nan).mpSuccess!
        #expect(
            MMPackDecoder().decode(Float.self, from: encodedFloat).mpSuccess?.bitPattern
                == Float.nan.bitPattern
        )
        let encodedDouble = MMPackEncoder().encode(Double.nan).mpSuccess!
        #expect(
            MMPackDecoder().decode(Double.self, from: encodedDouble).mpSuccess?.bitPattern
                == Double.nan.bitPattern
        )
    }

    @Test("wide exts", arguments: nonCanonicalExtVectors)
    func exts(vector: MPVector<MMPackExtValue>) {
        var bytes = mpBytes(vector.hex)
        #expect(bytes.readMessagePackExt() == .success(vector.value))
    }
}
