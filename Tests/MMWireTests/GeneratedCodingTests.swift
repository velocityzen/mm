import MMSchema
import MMWire
import NIOCore
import Testing

/// A hand-written external type with no generated code: generated code writes
/// and reads it through its `Codable` conformance.
struct GeneratedCodingStamp: Codable, Hashable, Sendable, SchemaDescribable {
    var author: String
    var level: Int

    init(author: String, level: Int) {
        self.author = author
        self.level = level
    }

    static var schema: TypeSchema {
        .structure(fields: [
            .init(key: 0, name: "author", type: .string),
            .init(key: 1, name: "level", type: .int),
        ])
    }

    enum CodingKeys: Int, CodingKey {
        case author = 0
        case level = 1
    }
}

/// An external type with MessagePack code of its own, which records the path
/// that decoded it: the bytes are the same either way.
struct GeneratedCodingMarker: Codable, Hashable, Sendable, SchemaDescribable, MMPackCodable {
    var decodedByGeneratedCode: Bool

    init(decodedByGeneratedCode: Bool) {
        self.decodedByGeneratedCode = decodedByGeneratedCode
    }

    init(from decoder: any Decoder) throws {
        _ = try decoder.singleValueContainer().decode(Bool.self)
        self.decodedByGeneratedCode = false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(true)
    }

    init<Reader: MMPackReader>(mmPack reader: inout Reader, depth: Int) throws {
        _ = try reader.readBool()
        self.decodedByGeneratedCode = true
    }

    func encode<Writer: MMPackWriter>(mmPack writer: inout Writer) throws {
        writer.writeBool(true)
    }

    static var schema: TypeSchema { .bool }
}

/// Every field shape the macros generate code for, plus the two they hand to
/// `Codable` (maps and external types).
private enum Catalog: MethodNamespace {
    #schema("catalog") {
        Enum("Condition") {
            Case("new")
            Case("used")
        }
        Type("Item") {
            Field("sku", .string)
            Field("quantity", .int)
            Field("stock", .uint)
            Field("price", .double)
            Field("weight", .float)
            Field("active", .bool)
            Field("condition", "Condition")
            Field("tags", .array(.string))
            Field(20, "note", .optional(.string))
            Field("grid", .array(.array(.optional(.int))))
            Field("lookup", .map(key: .string, value: .int))
            Field("serials", .map(key: .uint, value: .string))
            Field("released", .date)
            Field("updated", .optional(.datetime))
            Field("stamped", .optional(.timestamp))
            Field("stamp", GeneratedCodingStamp.self)
            Field("owner") {
                Field("name", .string)
                Field("since", .optional(.date))
            }
        }
        Call("put") {
            Access { .write }
            Request {
                Field("items", .array(.reference("Item")))
                Field("conditions", .array(.optional(.reference("Condition"))))
                Field("flag", .optional(.optional(.bool)))
            }
        }
        Call("relay") {
            Access { .write }
            Request {
                Field("marker", GeneratedCodingMarker.self)
                Field("blank") {}
            }
        }
    }
}

// The two paths, named so each test says which one it takes: generic code
// that only knows `Encodable`/`Decodable` cannot pick the generated overloads.

private func encodedThroughCodable<T: Encodable>(_ value: T) -> Result<ByteBuffer, MMWireError> {
    MMPackEncoder().encode(value)
}

private func encodedThroughGeneratedCode<T: MMPackEncodable>(
    _ value: T
) -> Result<ByteBuffer, MMWireError> {
    MMPackEncoder().encode(value)
}

private func decodedThroughCodable<T: Decodable>(
    _ type: T.Type,
    from buffer: ByteBuffer,
    maxDepth: Int = 128
) -> Result<T, MMWireError> {
    MMPackDecoder(maxDepth: maxDepth).decode(type, from: buffer)
}

private func decodedThroughGeneratedCode<T: MMPackDecodable>(
    _ type: T.Type,
    from buffer: ByteBuffer,
    maxDepth: Int = 128
) -> Result<T, MMWireError> {
    MMPackDecoder(maxDepth: maxDepth).decode(type, from: buffer)
}

/// Seeded sample values covering each shape's edges: empty and long strings
/// (fixstr, str8, str16), negative and widest integers, empty and 16+
/// element arrays and maps (the 16-bit headers), both kinds of optional.
private struct Samples {
    var random: SplitMix64

    init(seed: UInt64) {
        self.random = SplitMix64(seed: seed)
    }

    mutating func chance() -> Bool {
        Bool.random(using: &self.random)
    }

    mutating func count(upTo limit: Int) -> Int {
        Int.random(in: 0...limit, using: &self.random)
    }

    mutating func string() -> String {
        let lengths = [0, 1, 5, 31, 32, 255, 256]
        let length = lengths.randomElement(using: &self.random)!
        let alphabet = Array("abcxyz-é漢🙂")
        return String((0..<length).map { _ in alphabet.randomElement(using: &self.random)! })
    }

    mutating func int() -> Int {
        let edges = [0, 1, -1, 127, 128, -32, -33, 255, 65_536, .min, .max]
        return self.chance()
            ? edges.randomElement(using: &self.random)!
            : Int.random(in: .min ... .max, using: &self.random)
    }

    mutating func uint() -> UInt64 {
        let edges: [UInt64] = [0, 127, 128, 255, 65_535, 1 << 32, .max]
        return self.chance()
            ? edges.randomElement(using: &self.random)!
            : UInt64.random(in: 0 ... .max, using: &self.random)
    }

    mutating func double() -> Double {
        let edges = [0.0, -0.0, 1.5, -2.25, .infinity, -.infinity, .greatestFiniteMagnitude]
        return edges.randomElement(using: &self.random)!
    }

    mutating func float() -> Float {
        let edges: [Float] = [0, -0.0, 3.5, -1.25, .infinity, .leastNonzeroMagnitude]
        return edges.randomElement(using: &self.random)!
    }

    mutating func optional<Value>(_ make: (inout Samples) -> Value) -> Value? {
        self.chance() ? make(&self) : nil
    }

    mutating func array<Value>(upTo limit: Int, _ make: (inout Samples) -> Value) -> [Value] {
        (0..<self.count(upTo: limit)).map { _ in make(&self) }
    }

    mutating func item() -> Catalog.Item {
        let released = [MMDate("2026-07-22")!, MMDate("1970-01-01")!, MMDate("0001-12-31")!]
        let updated = [MMDateTime("2026-07-22T14:30:00")!, MMDateTime("2026-07-22T14:30:00.5")!]
        let stamped = [
            MMTimestamp("2026-07-22T14:30:00Z")!, MMTimestamp("2026-07-22T14:30:00-04:00")!,
        ]
        return Catalog.Item(
            sku: self.string(),
            quantity: self.int(),
            stock: self.uint(),
            price: self.double(),
            weight: self.float(),
            active: self.chance(),
            condition: self.chance() ? .new : .used,
            tags: self.array(upTo: 18) { $0.string() },
            note: self.optional { $0.string() },
            grid: self.array(upTo: 3) { samples in
                samples.array(upTo: 17) { samples in samples.optional { $0.int() } }
            },
            lookup: Dictionary(
                self.array(upTo: 17) { ($0.string(), $0.int()) },
                uniquingKeysWith: { first, _ in first }
            ),
            serials: Dictionary(
                self.array(upTo: 3) { ($0.uint(), $0.string()) },
                uniquingKeysWith: { first, _ in first }
            ),
            released: released.randomElement(using: &self.random)!,
            updated: self.optional { $0.chance() ? updated[0] : updated[1] },
            stamped: self.optional { $0.chance() ? stamped[0] : stamped[1] },
            stamp: GeneratedCodingStamp(author: self.string(), level: self.int()),
            owner: Catalog.Item.Owner(
                name: self.string(),
                since: self.optional { _ in released[0] }
            )
        )
    }

    mutating func putRequest() -> Catalog.PutRequest {
        Catalog.PutRequest(
            items: self.array(upTo: 3) { $0.item() },
            conditions: self.array(upTo: 17) { samples in
                samples.optional { $0.chance() ? .new : .used }
            },
            flag: self.optional { samples in samples.optional { $0.chance() } }
        )
    }
}

/// The result with each float replaced by its bit pattern, so a corrupted
/// float that reads as NaN still compares equal to itself.
private func bitwise(
    _ result: Result<Catalog.PutRequest, MMWireError>
) -> Result<Catalog.PutRequest, MMWireError> {
    result.map { request in
        var copy = request
        copy.items = request.items.map { item in
            var copy = item
            copy.price = Double(item.price.bitPattern)
            copy.weight = Float(item.weight.bitPattern)
            return copy
        }
        return copy
    }
}

@Suite("Generated MessagePack code agrees with Codable")
struct GeneratedCodingTests {
    @Test("writes the same bytes as the Codable path")
    func sameBytes() throws {
        var samples = Samples(seed: 0x6D6D_7061_636B)
        for _ in 0..<300 {
            let request = samples.putRequest()
            #expect(encodedThroughGeneratedCode(request) == encodedThroughCodable(request))
            let item = samples.item()
            #expect(encodedThroughGeneratedCode(item) == encodedThroughCodable(item))
        }
        #expect(
            encodedThroughGeneratedCode(Catalog.Condition.unknown)
                == .success(mpBytes("a7756e6b6e6f776e"))
        )
        #expect(encodedThroughGeneratedCode(Catalog.RelayResponse()) == .success(mpBytes("80")))
    }

    @Test("decodes what it writes, as the Codable path does")
    func roundTrip() throws {
        var samples = Samples(seed: 0x726F_756E_64)
        for _ in 0..<300 {
            let request = samples.putRequest()
            let bytes = try encodedThroughGeneratedCode(request).get()
            // An optional of an optional holding nil writes a plain nil, which
            // reads back as absent: Codable flattens it, and so does the
            // generated code.
            var expected = request
            if case .some(.none) = request.flag { expected.flag = nil }
            #expect(
                decodedThroughGeneratedCode(Catalog.PutRequest.self, from: bytes)
                    == .success(expected)
            )
            #expect(
                decodedThroughCodable(Catalog.PutRequest.self, from: bytes) == .success(expected)
            )
        }
    }

    @Test("every truncation fails the same way")
    func truncations() throws {
        var samples = Samples(seed: 0x7472_756E_63)
        // Every prefix decodes, so a few payloads cover thousands of cuts.
        for _ in 0..<4 {
            let bytes = try encodedThroughCodable(samples.putRequest()).get()
            for length in 0..<bytes.readableBytes {
                let prefix = bytes.getSlice(at: bytes.readerIndex, length: length)!
                #expect(
                    decodedThroughGeneratedCode(Catalog.PutRequest.self, from: prefix)
                        == decodedThroughCodable(Catalog.PutRequest.self, from: prefix),
                    "prefix of \(length) bytes: \(mpHex(prefix))"
                )
            }
        }
    }

    @Test("corrupted payloads decode, or fail, the same way")
    func corruptions() throws {
        var samples = Samples(seed: 0x636F_7272_7570)
        var random = SplitMix64(seed: 0x6D75_7461_7465)
        for _ in 0..<2000 {
            var bytes = Array(
                try encodedThroughCodable(samples.putRequest()).get().readableBytesView
            )
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                let index = Int.random(in: 0..<bytes.count, using: &random)
                bytes[index] = UInt8.random(in: 0...255, using: &random)
            }
            let corrupted = ByteBuffer(bytes: bytes)
            #expect(
                bitwise(decodedThroughGeneratedCode(Catalog.PutRequest.self, from: corrupted))
                    == bitwise(decodedThroughCodable(Catalog.PutRequest.self, from: corrupted)),
                "\(mpHex(corrupted))"
            )
        }
    }

    @Test("nesting limits fail at the same depth")
    func nestingLimits() throws {
        var samples = Samples(seed: 0x6465_7074_68)
        for _ in 0..<20 {
            let bytes = try encodedThroughCodable(samples.putRequest()).get()
            for maxDepth in 0...6 {
                let generated = decodedThroughGeneratedCode(
                    Catalog.PutRequest.self,
                    from: bytes,
                    maxDepth: maxDepth
                )
                let codable = decodedThroughCodable(
                    Catalog.PutRequest.self,
                    from: bytes,
                    maxDepth: maxDepth
                )
                #expect(generated == codable, "maxDepth \(maxDepth): \(mpHex(bytes))")
            }
        }
    }

    @Test("keys: first occurrence wins, the integer key before the name, unknown keys skipped")
    func keyRules() {
        let payloads = [
            // {"name": "by name"}: the name stands in for a missing integer key.
            "81a46e616d65a76279206e616d65",
            // {"name": "by name", 0: "by key"}: the integer key wins, wherever it sits.
            "82a46e616d65a76279206e616d6500a66279206b6579",
            // {0: "first", 0: "second"} and the same by name: the first wins.
            "8200a5666972737400a67365636f6e64",
            "82a46e616d65a56669727374a46e616d65a67365636f6e64",
            // {7: [nil], UInt64.max: 1, []: 2, "Name": 3, 0: "kept"}: unknown
            // and unusable keys are skipped, after a structural check.
            "850791c0cfffffffffffffffff019002a44e616d650300a46b657074",
            // {1: true}: the required field is missing.
            "8101c3",
            // The right key with the wrong type, or nil.
            "810005",
            "8100c0",
            "80",
            // {0: "ada", 1: true} and {0: "ada", 1: nil}: the optional's type.
            "8200a361646101c3",
            "8200a361646101c0",
        ].map(mpBytes)
        for payload in payloads {
            #expect(
                decodedThroughGeneratedCode(Catalog.Item.Owner.self, from: payload)
                    == decodedThroughCodable(Catalog.Item.Owner.self, from: payload),
                "\(mpHex(payload))"
            )
        }
        #expect(
            decodedThroughGeneratedCode(Catalog.Item.Owner.self, from: payloads[4])
                == .success(Catalog.Item.Owner(name: "kept", since: nil))
        )
        #expect(
            decodedThroughGeneratedCode(Catalog.Item.Owner.self, from: payloads[5])
                == .failure(.keyNotFound(key: "0"))
        )
    }

    @Test("optionals: absent or nil is nil, an optional inside a present optional stays apart")
    func optionals() {
        let payloads = [
            // conditions [nil, "new"], flag nil.
            "8300900192c0a36e657702c0",
            // flag true: an optional of an optional, present and not nil.
            "830090019002c3",
            // flag absent.
            "8200900190",
            // conditions ["old!"]: an unrecognized case decodes to unknown.
            "8200900191a46f6c6421",
            // flag of the wrong type; items missing.
            "83009001900291c3",
            "810190",
        ].map(mpBytes)
        for payload in payloads {
            #expect(
                decodedThroughGeneratedCode(Catalog.PutRequest.self, from: payload)
                    == decodedThroughCodable(Catalog.PutRequest.self, from: payload),
                "\(mpHex(payload))"
            )
        }
        #expect(
            decodedThroughGeneratedCode(Catalog.PutRequest.self, from: payloads[1]).mpSuccess?.flag
                == .some(.some(true))
        )
    }

    @Test("a struct with no fields steps over one value")
    func emptyStruct() throws {
        for payload in ["80", "c0", "93010203", "81a178c3"] {
            #expect(
                decodedThroughGeneratedCode(Catalog.PutResponse.self, from: mpBytes(payload))
                    == .success(.init())
            )
        }
        // Not one value. The Codable path reads nothing at all for a struct
        // with no fields, so it accepts this too; the envelope only ever
        // hands the coders one checked value.
        #expect(
            decodedThroughGeneratedCode(Catalog.PutResponse.self, from: ByteBuffer()).mpFailure
                != nil
        )
        // A field: {0: true, 1: [1, 2]}, {0: true, 1: {"x": [nil]}}, {0: true}.
        // The marker beside it records its path, so only the field is compared.
        for payload in ["8200c301920102", "8200c30181a17891c0", "8100c3"].map(mpBytes) {
            #expect(
                decodedThroughGeneratedCode(Catalog.RelayRequest.self, from: payload).map(\.blank)
                    == decodedThroughCodable(Catalog.RelayRequest.self, from: payload).map(\.blank),
                "\(mpHex(payload))"
            )
        }
    }

    @Test("external types use their generated code when they have some")
    func externalTypes() throws {
        let bytes = try encodedThroughCodable(
            Catalog.RelayRequest(
                marker: .init(decodedByGeneratedCode: false),
                blank: .init()
            )
        ).get()
        #expect(mpHex(bytes) == "8200c30180")
        let generated = try decodedThroughGeneratedCode(Catalog.RelayRequest.self, from: bytes)
            .get()
        #expect(generated.marker.decodedByGeneratedCode)
        let codable = try decodedThroughCodable(Catalog.RelayRequest.self, from: bytes).get()
        #expect(!codable.marker.decodedByGeneratedCode)
    }

    @Test("resolved coders take the generated code exactly when the type has it")
    func resolvedCoders() throws {
        let bytes = mpBytes("c3")
        let resolved = MMPackDecoder().decoding(GeneratedCodingMarker.self)
        #expect(try resolved(bytes).get().decodedByGeneratedCode)
        let encode = MMPackEncoder().encoding(GeneratedCodingMarker.self)
        #expect(encode(.init(decodedByGeneratedCode: false)) == .success(bytes))

        let stamp = GeneratedCodingStamp(author: "ada", level: 3)
        let stampBytes = try encodedThroughCodable(stamp).get()
        #expect(MMPackEncoder().encoding(GeneratedCodingStamp.self)(stamp) == .success(stampBytes))
        #expect(MMPackDecoder().decoding(GeneratedCodingStamp.self)(stampBytes) == .success(stamp))
        #expect(
            MMPackDecoder(maxDepth: 0).decoding(Catalog.Item.Owner.self)(mpBytes("80"))
                == .failure(.nestingTooDeep(limit: 0))
        )
    }
}
