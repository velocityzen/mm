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

/// A hand-written external type whose `Decodable` refuses some values: a raw
/// value naming no case fails with a `DecodingError`, which carries the
/// coding path down to it.
enum GeneratedCodingSeal: String, CaseIterable, Codable, Hashable, Sendable, SchemaDescribable {
    case intact
    case broken

    static var schema: TypeSchema {
        .enumeration(cases: [.init(name: "intact"), .init(name: "broken")])
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
/// `Codable` (maps and external types). MMPropertyTests keeps a copy of this
/// catalog (without the relay call) for its generated values: keep the two in
/// step when adding a field shape.
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
            Field("photo", .bytes)
            Field("thumbnail", .optional(.bytes))
        }
        Union("Shipment") {
            Case("pending")
            Case("shipped") {
                Field("carrier", .string)
                Field(3, "tracking", .optional(.bytes))
                Field("condition", "Condition")
            }
            Case("split") {
                Field("parts", .array(.reference("Shipment")))
                Field("box") {
                    Field("label", .string)
                }
            }
            Case("held") {
                Field("duties", .map(key: .int, value: .string))
                Field("customs") {
                    Field("seal", GeneratedCodingSeal.self)
                }
            }
            Case("reissued") {
                Field("original", "Shipment")
                Field("reason", .optional(.string))
            }
            Case("rerouted") {
                Field("via") {
                    Field("next", .optional(.reference("Shipment")))
                }
            }
        }
        Type("Part") {
            Field("name", .string)
            Field("assembly", .optional(.reference("Assembly")))
            Field("spare") {
                Field("part", .optional(.reference("Part")))
            }
        }
        Type("Assembly") {
            Field("base", "Part")
            Field("parts", .array(.reference("Part")))
        }
        Call("put") {
            Access { .write }
            Request {
                Field("items", .array(.reference("Item")))
                Field("conditions", .array(.optional(.reference("Condition"))))
                Field("flag", .optional(.optional(.bool)))
                Field("shipments", .optional(.array(.reference("Shipment"))))
                Field("assemblies", .optional(.array(.reference("Assembly"))))
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

@Suite("Generated MessagePack code agrees with Codable")
struct GeneratedCodingTests {
    // Generated values are compared with the Codable path in MMPropertyTests'
    // GeneratedCodingProperties, which runs on macOS and Linux. The fixed
    // payloads here run on every platform.

    @Test("an unknown enum value, an empty response and an absent optional have fixed bytes")
    func fixedBytes() {
        #expect(
            encodedThroughGeneratedCode(Catalog.Condition.unknown("worn"))
                == .success(mpBytes("a4776f726e"))
        )
        #expect(encodedThroughGeneratedCode(Catalog.RelayResponse()) == .success(mpBytes("80")))
        #expect(encodedThroughGeneratedCode(Catalog.Item?.none) == .success(mpBytes("c0")))
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

    @Test("unions: tag before fields, keys by integer or name, unknown cases keep tag and fields")
    func unionRules() {
        #expect(
            encodedThroughGeneratedCode(Catalog.Shipment.pending)
                == .success(mpBytes("8100a770656e64696e67"))
        )
        #expect(
            encodedThroughGeneratedCode(Catalog.Shipment.unknown(tag: "lost", fields: nil))
                == .success(mpBytes("8100a46c6f7374"))
        )
        #expect(
            encodedThroughGeneratedCode(
                Catalog.Shipment.unknown(tag: "lost", fields: MMPackRawValue([0x81, 0x00, 0xc3]))
            )
                == .success(mpBytes("8200a46c6f7374" + "01" + "8100c3"))
        )
        #expect(
            encodedThroughGeneratedCode(Catalog.Shipment.split(parts: [], box: .init(label: "")))
                == .success(mpBytes("8200a573706c6974018200900181" + "00a0"))
        )
        let payloads = [
            // {0: "pending"}, and by name: {"case": "pending"}.
            "8100a770656e64696e67",
            "81a463617365a770656e64696e67",
            // A field-less case ignores a fields map.
            "8200a770656e64696e670180",
            // {0: "returned"}: an unrecognized case decodes to unknown.
            "8100a872657475726e6564",
            // {0: "shipped", 1: {0: "ups", 1: "new"}}, then by name, then with
            // the optional present, then the first occurrence of the tag wins.
            "8200a77368697070656401820" + "0a3757073" + "01a36e6577",
            "82a463617365a773686970706564a66669656c647382" + "00a3757073" + "01a36e6577",
            "8200a77368697070656401830" + "0a3757073" + "01a36e6577" + "03c40101",
            "8300a77368697070656400a770656e64696e670182" + "00a3757073" + "01a36e6577",
            // A case with fields and no fields map; a fields map of the wrong
            // type; a field of the wrong type; a missing tag; a non-string tag.
            "8100a773686970706564",
            "8200a77368697070656401c3",
            "8200a77368697070656401820005" + "01a36e6577",
            "8101" + "80",
            "810005",
            "c3",
            // {0: "returned", 1: {0: "ups"}}, then by name, then with a nil
            // fields value: an unrecognized case keeps its fields' bytes.
            "8200a872657475726e656401" + "8100a3757073",
            "82a463617365a872657475726e6564a66669656c6473" + "8100a3757073",
            "8200a872657475726e656401c0",
        ].map(mpBytes)
        for payload in payloads {
            #expect(
                decodedThroughGeneratedCode(Catalog.Shipment.self, from: payload)
                    == decodedThroughCodable(Catalog.Shipment.self, from: payload),
                "\(mpHex(payload))"
            )
        }
        #expect(
            decodedThroughGeneratedCode(Catalog.Shipment.self, from: payloads[1])
                == .success(.pending)
        )
        #expect(
            decodedThroughGeneratedCode(Catalog.Shipment.self, from: payloads[3])
                == .success(.unknown(tag: "returned", fields: nil))
        )
        let returned = Catalog.Shipment.unknown(
            tag: "returned",
            fields: MMPackRawValue([0x81, 0x00, 0xa3, 0x75, 0x70, 0x73])
        )
        #expect(
            decodedThroughGeneratedCode(Catalog.Shipment.self, from: payloads[14])
                == .success(returned)
        )
        #expect(
            decodedThroughGeneratedCode(Catalog.Shipment.self, from: payloads[15])
                == .success(returned)
        )
        #expect(encodedThroughGeneratedCode(returned) == .success(payloads[14]))
        #expect(
            decodedThroughGeneratedCode(Catalog.Shipment.self, from: payloads[16])
                == .success(.unknown(tag: "returned", fields: MMPackRawValue([0xc0])))
        )
        #expect(
            decodedThroughGeneratedCode(Catalog.Shipment.self, from: payloads[6])
                == .success(.shipped(carrier: "ups", tracking: [1], condition: .new))
        )
        #expect(
            decodedThroughGeneratedCode(Catalog.Shipment.self, from: payloads[8])
                == .failure(.keyNotFound(key: "1"))
        )
    }

    @Test("a DecodingError from a map or an external type names the same coding path")
    func decodingErrorPaths() {
        let held = [
            // {0: "held", 1: {0: {"x": "a"}, 1: {0: "intact"}}}: a duties key
            // that is not an integer, refused at fields, duties, "x".
            "8200a468656c64" + "0182" + "0081a178a161" + "018100a6696e74616374",
            // {0: "held", 1: {0: {}, 1: {0: "x"}}}: a seal naming no case,
            // refused at fields, customs, seal.
            "8200a468656c64" + "0182" + "0080" + "018100a178",
        ]
        for shipment in held {
            // Alone, and under a split's parts:
            // {0: "split", 1: {0: [shipment], 1: {0: "b"}}}.
            let split = "8200a573706c6974" + "0182" + "0091" + shipment + "018100a162"
            for payload in [shipment, split].map(mpBytes) {
                let generated = decodedThroughGeneratedCode(Catalog.Shipment.self, from: payload)
                #expect(generated == decodedThroughCodable(Catalog.Shipment.self, from: payload))
                #expect(isDecodingFailed(generated), "\(generated)")
            }
            // Under a request's shipments: {0: [], 1: [], 3: [shipment]}.
            let request = mpBytes("8300900190" + "0391" + shipment)
            let generated = decodedThroughGeneratedCode(Catalog.PutRequest.self, from: request)
            #expect(generated == decodedThroughCodable(Catalog.PutRequest.self, from: request))
            #expect(isDecodingFailed(generated), "\(generated)")
        }
    }

    private func isDecodingFailed<T>(_ result: Result<T, MMWireError>) -> Bool {
        if case .failure(.decodingFailed) = result { true } else { false }
    }

    @Test("bytes: a bin on the wire; a str reads as its UTF-8 bytes")
    func bytesWire() {
        #expect(MMPackEncoder().encode(MMBytes([1, 2])) == .success(mpBytes("c4020102")))
        #expect(
            MMPackDecoder().decode(MMBytes.self, from: mpBytes("c4020102")) == .success([1, 2])
        )
        #expect(
            MMPackDecoder().decode(MMBytes.self, from: mpBytes("a26869")) == .success([0x68, 0x69])
        )
        #expect(MMPackDecoder().decode(MMBytes.self, from: mpBytes("05")).mpFailure != nil)
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
