// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMWire
    import NIOCore
    import Testing

    // A copy of the catalog in MMWireTests' GeneratedCodingTests, whose example
    // tests run on every platform: test modules do not share sources. Keep the
    // two in step when adding a field shape.

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

    /// Every field shape the macros generate code for, plus the two they hand to
    /// `Codable` (maps and external types).
    enum Catalog: MethodNamespace {
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
            }
            Call("put") {
                Access { .write }
                Request {
                    Field("items", .array(.reference("Item")))
                    Field("conditions", .array(.optional(.reference("Condition"))))
                    Field("flag", .optional(.optional(.bool)))
                    Field("shipments", .optional(.array(.reference("Shipment"))))
                }
            }
        }
    }

    /// Catalog values from their whole domains: any string, integer, float
    /// (NaN and the infinities too), and sizes and depths Hegel chooses. On
    /// top, each generator draws often at the MessagePack header boundaries:
    /// strings and binaries of 31/32 and 255/256 bytes, collections of 15 to
    /// 17 elements, and integers at each format's edge.
    enum CatalogGenerators {
        /// A fixstr holds up to 31 bytes and a str8 up to 255.
        static let text: Gen<String> = .oneOf(
            .string(),
            .string(of: .ascii, count: 31...32),
            .string(of: .ascii, count: 255...256)
        )

        /// The edges of positive and negative fixints, and of the 8-, 16- and
        /// 32-bit formats.
        static let integer: Gen<Int> = .oneOf(
            .int(),
            .element(of: [127, 128, -32, -33, 255, 256, 65_535, 65_536, 1 << 32])
        )

        static let unsigned: Gen<UInt64> = .oneOf(
            .integer(),
            .element(of: [127, 128, 255, 256, 65_535, 65_536, 1 << 32])
        )

        /// A bin8 holds up to 255 bytes.
        static let bytes: Gen<MMBytes> = Gen<[UInt8]>.oneOf(.bytes(), .bytes(count: 255...256))
            .map { MMBytes($0) }

        static let condition: Gen<Catalog.Condition> = .allCases

        /// Any length, or 15 to 17 elements: a fixarray holds up to 15.
        static func list<Element>(of element: Gen<Element>) -> Gen<[Element]> {
            .oneOf(.array(of: element), .array(of: element, count: 15...17))
        }

        /// Any size, or 15 to 17 entries: a fixmap holds up to 15.
        static func map<Key: Hashable & SendableMetatype, Value>(
            keys: Gen<Key>,
            values: Gen<Value>
        ) -> Gen<[Key: Value]> {
            .oneOf(
                .dictionary(keys: keys, values: values),
                .dictionary(keys: keys, values: values, count: 15...17)
            )
        }

        static let date: Gen<MMDate> = Gen { tc in
            let year = try tc.draw(.int(in: 0...9999))
            let month = try tc.draw(.int(in: 1...12))
            let day = try tc.draw(.int(in: 1...MMDate.daysIn(month: month, year: year)))
            return try #require(MMDate(year: year, month: month, day: day))
        }

        /// Second 60 is a leap second, which the wire keeps.
        static let dateTime: Gen<MMDateTime> = Gen { tc in
            try #require(
                MMDateTime(
                    date: tc.draw(date),
                    hour: tc.draw(.int(in: 0...23)),
                    minute: tc.draw(.int(in: 0...59)),
                    second: tc.draw(.int(in: 0...60)),
                    nanosecond: tc.draw(.oneOf(.just(0), .int(in: 0...999_999_999)))
                )
            )
        }

        static let timestamp: Gen<MMTimestamp> = Gen { tc in
            try #require(
                MMTimestamp(
                    dateTime: tc.draw(dateTime),
                    offsetMinutes: tc.draw(.oneOf(.just(0), .int(in: -1080...1080)))
                )
            )
        }

        static let item: Gen<Catalog.Item> = Gen { tc in
            try Catalog.Item(
                sku: tc.draw(text),
                quantity: tc.draw(integer),
                stock: tc.draw(unsigned),
                price: tc.draw(.double()),
                weight: tc.draw(.float()),
                active: tc.draw(.bool()),
                condition: tc.draw(condition),
                tags: tc.draw(list(of: text)),
                note: tc.draw(.optional(text)),
                grid: tc.draw(list(of: list(of: Gen<Int?>.optional(integer)))),
                lookup: tc.draw(map(keys: text, values: integer)),
                serials: tc.draw(map(keys: unsigned, values: text)),
                released: tc.draw(date),
                updated: tc.draw(.optional(dateTime)),
                stamped: tc.draw(.optional(timestamp)),
                stamp: GeneratedCodingStamp(author: tc.draw(text), level: tc.draw(integer)),
                owner: Catalog.Item.Owner(name: tc.draw(text), since: tc.draw(.optional(date))),
                photo: tc.draw(bytes),
                thumbnail: tc.draw(.optional(bytes))
            )
        }

        /// Hegel's default nesting, up to 32 splits deep. Each split nests three
        /// containers (the case map, its fields map and the parts array), so
        /// the deepest request nests about 101: inside the decoder's default
        /// limit of 128, which the properties decode with.
        static let shipment: Gen<Catalog.Shipment> = .recursive(
            leaf: .oneOf(
                .just(.pending),
                .just(.unknown),
                Gen { tc in
                    try .shipped(
                        carrier: tc.draw(text),
                        tracking: tc.draw(.optional(bytes)),
                        condition: tc.draw(condition)
                    )
                }
            ),
            branch: { parts in
                Gen { tc in
                    try .split(
                        parts: tc.draw(Gen<[Catalog.Shipment]>.array(of: parts)),
                        box: .init(label: tc.draw(text))
                    )
                }
            }
        )

        static let putRequest: Gen<Catalog.PutRequest> = Gen { tc in
            try Catalog.PutRequest(
                items: tc.draw(list(of: item)),
                conditions: tc.draw(list(of: Gen<Catalog.Condition?>.optional(condition))),
                flag: tc.draw(Gen<Bool??>.optional(Gen<Bool?>.optional(.bool()))),
                shipments: tc.draw(.optional(list(of: shipment)))
            )
        }
    }

    // The two paths, named so each property says which one it takes: generic
    // code that only knows `Encodable`/`Decodable` cannot pick the generated
    // overloads.

    func encodedThroughCodable<T: Encodable>(_ value: T) -> Result<ByteBuffer, MMWireError> {
        MMPackEncoder().encode(value)
    }

    func encodedThroughGeneratedCode<T: MMPackEncodable>(
        _ value: T
    ) -> Result<ByteBuffer, MMWireError> {
        MMPackEncoder().encode(value)
    }

    func decodedThroughCodable<T: Decodable>(
        _ type: T.Type,
        from buffer: ByteBuffer,
        maxDepth: Int = 128
    ) -> Result<T, MMWireError> {
        MMPackDecoder(maxDepth: maxDepth).decode(type, from: buffer)
    }

    func decodedThroughGeneratedCode<T: MMPackDecodable>(
        _ type: T.Type,
        from buffer: ByteBuffer,
        maxDepth: Int = 128
    ) -> Result<T, MMWireError> {
        MMPackDecoder(maxDepth: maxDepth).decode(type, from: buffer)
    }

    /// The buffer's readable bytes in lowercase hex, for failure messages.
    func hex(_ buffer: ByteBuffer) -> String {
        let digits = Array("0123456789abcdef")
        return String(buffer.readableBytesView.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0xf)]] })
    }

#endif
