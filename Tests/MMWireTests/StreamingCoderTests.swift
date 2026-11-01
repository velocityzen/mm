import MMWire
import NIOCore
import Testing

/// An integer key for fixtures that write computed keys.
private struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { String(self.intValue ?? 0) }

    init(_ value: Int) {
        self.intValue = value
    }

    init?(intValue: Int) {
        self.intValue = intValue
    }

    init?(stringValue: String) {
        nil
    }
}

private enum PairKeys: Int, CodingKey {
    case a = 1
    case b = 2
}

/// A map of `count` entries, keys `0..<count` in order, each holding 0.
private struct CountedMap: Encodable {
    let count: Int

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: IndexKey.self)
        for key in 0..<self.count {
            try container.encode(Int64(0), forKey: IndexKey(key))
        }
    }
}

/// Widens a nested array's header, then fails.
private struct WidenThenFail: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        var nested = container.nestedUnkeyedContainer()
        for _ in 0..<16 {
            try nested.encode(1)
        }
        try container.encode(2)
        throw MMWireError.encodingFailed(description: "after widening")
    }
}

/// Writes into a nested container after its parent wrote its next entry.
private struct LateNestedWrite: Encodable {
    let swallowsError: Bool

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: PairKeys.self)
        var nested = container.nestedContainer(keyedBy: PairKeys.self, forKey: .a)
        try container.encode(1, forKey: .b)
        if self.swallowsError {
            try? nested.encode(2, forKey: .a)
        } else {
            try nested.encode(2, forKey: .a)
        }
    }
}

/// Writes through a super encoder after its container wrote its next entry.
private struct LateSuperWrite: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: PairKeys.self)
        let deferred = container.superEncoder(forKey: .a)
        try container.encode(1, forKey: .b)
        var single = deferred.singleValueContainer()
        try single.encode(2)
    }
}

/// Opens a container from a nested container that is no longer open; the
/// request itself cannot throw, so only the encode's result reports it.
private struct LateNestedOpen: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        var nested = container.nestedUnkeyedContainer()
        try container.encode(1)
        _ = nested.nestedContainer(keyedBy: PairKeys.self)
    }
}

/// Encodes the coding path its encoder reports; decodes it back alongside the
/// path its decoder reports.
private struct PathRecorder: Codable, Equatable {
    var encodedPath: [Int] = []
    var decodedPath: [Int] = []

    init() {}

    init(path: [Int]) {
        self.encodedPath = path
        self.decodedPath = path
    }

    init(from decoder: any Decoder) throws {
        self.decodedPath = decoder.codingPath.compactMap(\.intValue)
        self.encodedPath = try decoder.singleValueContainer().decode([Int].self)
    }

    func encode(to encoder: any Encoder) throws {
        var single = encoder.singleValueContainer()
        try single.encode(encoder.codingPath.compactMap(\.intValue))
    }
}

/// Places recorders at a key, in an array under a key, and in a map inside that array.
private struct PathTree: Codable, Equatable {
    var atKey = PathRecorder()
    var inArray = PathRecorder()
    var inNestedMap = PathRecorder()

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: PairKeys.self)
        self.atKey = try container.decode(PathRecorder.self, forKey: .a)
        var list = try container.nestedUnkeyedContainer(forKey: .b)
        #expect(list.codingPath.compactMap(\.intValue) == [2])
        self.inArray = try list.decode(PathRecorder.self)
        let deeper = try list.nestedContainer(keyedBy: PairKeys.self)
        self.inNestedMap = try deeper.decode(PathRecorder.self, forKey: .a)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: PairKeys.self)
        try container.encode(self.atKey, forKey: .a)
        var list = container.nestedUnkeyedContainer(forKey: .b)
        #expect(list.codingPath.compactMap(\.intValue) == [2])
        try list.encode(self.inArray)
        var deeper = list.nestedContainer(keyedBy: PairKeys.self)
        try deeper.encode(self.inNestedMap, forKey: .a)
    }
}

private struct PairValue: Decodable, Equatable {
    var a: Int
    var b: Int

    enum CodingKeys: Int, CodingKey {
        case a = 1
        case b = 2
    }
}

/// Holds two nested containers at once and reads them interleaved, with a
/// whole value decoded in between: decoding, unlike encoding, has no order.
private struct InterleavedNested: Decodable, Equatable {
    var pair: PairValue
    var first: Int
    var second: Int
    var listed: [Int]

    init(pair: PairValue, first: Int, second: Int, listed: [Int]) {
        self.pair = pair
        self.first = first
        self.second = second
        self.listed = listed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: PairKeys.self)
        let map = try container.nestedContainer(keyedBy: PairKeys.self, forKey: .a)
        var list = try container.nestedUnkeyedContainer(forKey: .b)
        let head = try list.decode(Int.self)
        self.pair = try container.decode(PairValue.self, forKey: .a)
        self.first = try map.decode(Int.self, forKey: .a)
        let tail = try list.decode(Int.self)
        self.second = try map.decode(Int.self, forKey: .b)
        self.listed = [head, tail]
    }
}

/// Where `Escaper` leaves the container it should not keep.
private final class EscapedContainer: @unchecked Sendable {
    var container: KeyedDecodingContainer<PairKeys>?

    @TaskLocal static var current: EscapedContainer?
}

private struct Escaper: Decodable {
    init(from decoder: any Decoder) throws {
        EscapedContainer.current?.container = try decoder.container(keyedBy: PairKeys.self)
    }
}

/// Reads through a container that outlived its value, after a sibling value
/// reused the decode's storage.
private struct ReadsEscapedContainer: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: PairKeys.self)
        _ = try container.decode(Escaper.self, forKey: .a)
        _ = try container.decode(PairValue.self, forKey: .b)
        _ = try EscapedContainer.current?.container?.decode(Int.self, forKey: .a)
    }
}

private func isOutOfOrder(_ result: Result<ByteBuffer, MMWireError>) -> Bool {
    guard case .encodingFailed = result.mpFailure else { return false }
    return true
}

/// The encoder writes containers straight into the output buffer and patches
/// each header when the container closes.
@Suite("Streaming coders")
struct StreamingCoderTests {
    @Test("map headers widen in place at the map16 and map32 boundaries")
    func mapHeaderBoundaries() {
        for count in [15, 16, 65535, 65536] {
            var expected = ByteBuffer()
            expected.writeMessagePackMapHeader(count: count)
            for key in 0..<count {
                expected.writeMessagePackInt(Int64(key))
                expected.writeMessagePackInt(0)
            }
            #expect(
                MMPackEncoder().encode(CountedMap(count: count)) == .success(expected),
                "count \(count)"
            )
        }
    }

    @Test("containers nested in a widened container keep their bytes when it moves")
    func nestedInWidenedContainer() {
        let rows: [[Int64]] = (0..<17).map { row in
            (0..<(row.isMultiple(of: 3) ? 16 : row)).map(Int64.init)
        }
        var expected = ByteBuffer()
        expected.writeMessagePackArrayHeader(count: rows.count)
        for row in rows {
            expected.writeMessagePackArrayHeader(count: row.count)
            for element in row {
                expected.writeMessagePackInt(element)
            }
        }
        #expect(MMPackEncoder().encode(rows) == .success(expected))

        let maps = (0..<17).map { CountedMap(count: $0.isMultiple(of: 2) ? 16 : $0) }
        expected.clear()
        expected.writeMessagePackArrayHeader(count: maps.count)
        for map in maps {
            expected.writeMessagePackMapHeader(count: map.count)
            for key in 0..<map.count {
                expected.writeMessagePackInt(Int64(key))
                expected.writeMessagePackInt(0)
            }
        }
        #expect(MMPackEncoder().encode(maps) == .success(expected))
    }

    @Test("appending widens headers behind consumed and existing bytes")
    func appendBehindExistingBytes() {
        var buffer = ByteBuffer(bytes: [0xaa, 0xbb, 0xcc])
        buffer.moveReaderIndex(forwardBy: 1)
        let value = [Int64](repeating: 7, count: 16)
        #expect(MMPackEncoder().encode(value, into: &buffer).mpSuccess != nil)
        #expect(mpHex(buffer) == "bbcc" + "dc0010" + String(repeating: "07", count: 16))
    }

    @Test("a failed append leaves the buffer as it was, ready for the next value")
    func failedAppend() {
        var buffer = ByteBuffer(bytes: [0xaa, 0xbb])
        let result = MMPackEncoder().encode(WidenThenFail(), into: &buffer)
        #expect(result.mpFailure == .encodingFailed(description: "after widening"))
        #expect(mpHex(buffer) == "aabb")
        #expect(MMPackEncoder().encode(Int64(1), into: &buffer).mpSuccess != nil)
        #expect(mpHex(buffer) == "aabb01")
    }

    @Test("writing to a nested container after its parent moved on fails the encode")
    func lateNestedWrite() {
        #expect(isOutOfOrder(MMPackEncoder().encode(LateNestedWrite(swallowsError: false))))
        // Swallowing the error cannot turn the misuse into output.
        #expect(isOutOfOrder(MMPackEncoder().encode(LateNestedWrite(swallowsError: true))))
    }

    @Test("writing through a super encoder after its container moved on fails the encode")
    func lateSuperWrite() {
        #expect(isOutOfOrder(MMPackEncoder().encode(LateSuperWrite())))
    }

    @Test("opening a container from a closed container fails the encode")
    func lateNestedOpen() {
        #expect(isOutOfOrder(MMPackEncoder().encode(LateNestedOpen())))
    }

    @Test("nested decoding containers stay usable together, around a decoded value")
    func interleavedNestedDecoding() {
        let decoded = MMPackDecoder().decode(
            InterleavedNested.self,
            from: mpBytes("82" + "01" + "82010a0214" + "02" + "921e28")
        )
        let expected = InterleavedNested(
            pair: PairValue(a: 10, b: 20),
            first: 10,
            second: 20,
            listed: [30, 40]
        )
        #expect(decoded == .success(expected))
    }

    @Test("a container used after its value finished decoding fails, never misreads")
    func escapedDecodingContainer() {
        let payload = mpBytes("82" + "01" + "8101" + "05" + "02" + "820106" + "0207")
        let result = EscapedContainer.$current.withValue(EscapedContainer()) {
            MMPackDecoder().decode(ReadsEscapedContainer.self, from: payload)
        }
        guard case .decodingFailed = result.mpFailure else {
            Issue.record("expected decodingFailed, got \(result)")
            return
        }
    }

    @Test("the first occurrence of a duplicate key wins in small and large maps")
    func duplicateKeysInEitherIndex() {
        for fillerCount in [0, 40] {
            var buffer = ByteBuffer()
            buffer.writeMessagePackMapHeader(count: fillerCount + 2)
            buffer.writeMessagePackInt(1)
            buffer.writeMessagePackString("first")
            var expected = [1: "first"]
            for filler in 100..<(100 + fillerCount) {
                buffer.writeMessagePackInt(Int64(filler))
                buffer.writeMessagePackString("filler")
                expected[filler] = "filler"
            }
            buffer.writeMessagePackInt(1)
            buffer.writeMessagePackString("second")
            #expect(
                MMPackDecoder().decode([Int: String].self, from: buffer) == .success(expected),
                "\(fillerCount) fillers"
            )
        }
    }

    @Test("coding paths list the keys above a value, not array positions, on both coders")
    func codingPaths() throws {
        let encoded = try MMPackEncoder().encode(PathTree()).get()
        let decoded = try MMPackDecoder().decode(PathTree.self, from: encoded).get()
        #expect(decoded.atKey == PathRecorder(path: [1]))
        #expect(decoded.inArray == PathRecorder(path: [2]))
        #expect(decoded.inNestedMap == PathRecorder(path: [2, 1]))
    }
}
