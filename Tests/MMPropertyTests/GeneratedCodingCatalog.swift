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

    /// A hand-written external type whose `Decodable` refuses some values: a
    /// raw value naming no case fails with a `DecodingError`, which carries
    /// the coding path down to it.
    enum GeneratedCodingSeal: String, CaseIterable, Codable, Hashable, Sendable,
        SchemaDescribable
    {
        case intact
        case broken

        static var schema: TypeSchema {
            .enumeration(cases: [.init(name: "intact"), .init(name: "broken")])
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
                Case("held") {
                    Field("duties", .map(key: .int, value: .string))
                    Field("customs") {
                        Field("seal", GeneratedCodingSeal.self)
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

    /// One test case's policy for the catalog generators. Properties draw it
    /// first, so that cases differ in kind and not only in values.
    struct CatalogShape: Sendable {
        /// How often a string, binary or collection takes a size at a
        /// MessagePack header boundary instead of one Hegel chooses. At 0,
        /// Hegel sizes everything. A high rate stacks boundary-sized
        /// collections inside each other, which makes the largest requests.
        var boundaryRate: Double
        /// How deep shipments may split. Each split nests three containers
        /// (the case map, its fields map and the parts array), so 32 splits
        /// nest about 101: inside the decoders' default limit of 128.
        var shipmentDepth: Int
    }

    /// Catalog values from their whole domains: any string, integer, float
    /// (NaN and the infinities too), and sizes and depths Hegel chooses.
    /// Integers draw often at each format's edge. At the shape's boundary
    /// rate, strings and binaries take 31/32 and 255/256 bytes and
    /// collections 15 to 17 elements.
    struct CatalogGenerators: Sendable {
        let shape: CatalogShape

        init(_ shape: CatalogShape) {
            self.shape = shape
        }

        /// Hegel shrinks toward the first entries: sizes it chooses, and
        /// shipments with no splits.
        static let shapes: Gen<CatalogShape> = Hegel.zip(
            Gen<Double>.element(of: [0, 0.1, 0.5]),
            Gen<Int>.element(of: [0, 3, 32])
        )
        .map { CatalogShape(boundaryRate: $0, shipmentDepth: $1) }

        /// `anySize`, or `boundarySize` at the shape's boundary rate.
        func sometimes<Value>(_ boundarySize: Gen<Value>, otherwise anySize: Gen<Value>) -> Gen<
            Value
        > {
            guard self.shape.boundaryRate > 0 else {
                return anySize
            }
            return Gen<Bool>.bool(probability: self.shape.boundaryRate)
                .flatMap { $0 ? boundarySize : anySize }
        }

        /// A fixstr holds up to 31 bytes and a str8 up to 255.
        var text: Gen<String> {
            self.sometimes(
                .oneOf(.string(of: .ascii, count: 31...32), .string(of: .ascii, count: 255...256)),
                otherwise: .string()
            )
        }

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

        /// An unsigned wire map key goes up to `Int64.max`, the range of a
        /// map key, and no further.
        static let unsignedKey: Gen<UInt64> = .oneOf(
            .integer(in: 0...UInt64(Int64.max)),
            .element(of: [0, 127, 128, 255, 256, 65_535, 65_536, 1 << 32, UInt64(Int64.max)])
        )

        /// A bin8 holds up to 255 bytes.
        var bytes: Gen<MMBytes> {
            self.sometimes(.bytes(count: 255...256), otherwise: Gen<[UInt8]>.bytes()).map {
                MMBytes($0)
            }
        }

        /// The declared cases, and values the contract does not declare,
        /// which a newer peer sends and `unknown` keeps.
        static let condition: Gen<Catalog.Condition> = .oneOf(
            .allCases,
            .allCases,
            Gen<String>.string().map { Catalog.Condition(rawValue: $0) ?? .unknown($0) }
        )

        /// A fixarray holds up to 15 elements.
        func list<Element>(of element: Gen<Element>) -> Gen<[Element]> {
            self.sometimes(.array(of: element, count: 15...17), otherwise: .array(of: element))
        }

        /// A fixmap holds up to 15 entries.
        func map<Key: Hashable & SendableMetatype, Value>(
            keys: Gen<Key>,
            values: Gen<Value>
        ) -> Gen<[Key: Value]> {
            self.sometimes(
                .dictionary(keys: keys, values: values, count: 15...17),
                otherwise: .dictionary(keys: keys, values: values)
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

        var item: Gen<Catalog.Item> {
            Gen { tc in
                try Catalog.Item(
                    sku: tc.draw(self.text),
                    quantity: tc.draw(Self.integer),
                    stock: tc.draw(Self.unsigned),
                    price: tc.draw(.double()),
                    weight: tc.draw(.float()),
                    active: tc.draw(.bool()),
                    condition: tc.draw(Self.condition),
                    tags: tc.draw(self.list(of: self.text)),
                    note: tc.draw(.optional(self.text)),
                    grid: tc.draw(self.list(of: self.list(of: Gen<Int?>.optional(Self.integer)))),
                    lookup: tc.draw(self.map(keys: self.text, values: Self.integer)),
                    serials: tc.draw(self.map(keys: Self.unsignedKey, values: self.text)),
                    released: tc.draw(Self.date),
                    updated: tc.draw(.optional(Self.dateTime)),
                    stamped: tc.draw(.optional(Self.timestamp)),
                    stamp: GeneratedCodingStamp(
                        author: tc.draw(self.text),
                        level: tc.draw(Self.integer)
                    ),
                    owner: Catalog.Item.Owner(
                        name: tc.draw(self.text),
                        since: tc.draw(.optional(Self.date))
                    ),
                    photo: tc.draw(self.bytes),
                    thumbnail: tc.draw(.optional(self.bytes))
                )
            }
        }

        var shipment: Gen<Catalog.Shipment> {
            .recursive(
                maxDepth: self.shape.shipmentDepth,
                leaf: .oneOf(
                    .just(.pending),
                    self.undeclaredShipment,
                    Gen { tc in
                        try .shipped(
                            carrier: tc.draw(self.text),
                            tracking: tc.draw(.optional(self.bytes)),
                            condition: tc.draw(Self.condition)
                        )
                    },
                    self.held
                ),
                branch: { parts in
                    Gen { tc in
                        try .split(
                            parts: tc.draw(Gen<[Catalog.Shipment]>.array(of: parts)),
                            box: .init(label: tc.draw(self.text))
                        )
                    }
                }
            )
        }

        /// A case the contract does not declare, as a newer peer sends it:
        /// its name never a declared one, and no fields or a fields map.
        var undeclaredShipment: Gen<Catalog.Shipment> {
            Gen { tc in
                let name = try tc.draw(self.text)
                let tag =
                    ["pending", "shipped", "split", "held"].contains(name) ? name + "+" : name
                // In one order, so a replay draws the same bytes.
                let fields = try tc.draw(.optional(self.map(keys: Self.integer, values: self.text)))
                    .map { try MMPackRawValue(encodedInOneOrder($0).readableBytesView) }
                return .unknown(tag: tag, fields: fields)
            }
        }

        /// A held shipment: duties under any integer keys, and either seal.
        var held: Gen<Catalog.Shipment> {
            Gen { tc in
                try .held(
                    duties: tc.draw(self.map(keys: Self.integer, values: self.text)),
                    customs: .init(seal: tc.draw(.allCases))
                )
            }
        }

        var putRequest: Gen<Catalog.PutRequest> {
            Gen { tc in
                try Catalog.PutRequest(
                    items: tc.draw(self.list(of: self.item)),
                    conditions: tc.draw(
                        self.list(of: Gen<Catalog.Condition?>.optional(Self.condition))
                    ),
                    flag: tc.draw(Gen<Bool??>.optional(Gen<Bool?>.optional(.bool()))),
                    shipments: tc.draw(.optional(self.list(of: self.shipment)))
                )
            }
        }
    }

    /// The sizes in a request that decide which MessagePack formats encode
    /// it: every string's UTF-8 byte count, every binary's byte count, every
    /// collection's element count, and how deep its shipments split.
    struct CatalogSizes {
        var strings: [Int] = []
        var binaries: [Int] = []
        var collections: [Int] = []
        var shipmentDepth = 0

        init(_ request: Catalog.PutRequest) {
            self.collections += [request.items.count, request.conditions.count]
            for item in request.items {
                self.add(item)
            }
            if let shipments = request.shipments {
                self.collections.append(shipments.count)
                for shipment in shipments {
                    self.add(shipment, depth: 0)
                }
            }
        }

        private mutating func add(_ item: Catalog.Item) {
            self.strings += [item.sku, item.stamp.author, item.owner.name].map(\.utf8.count)
            self.strings += item.tags.map(\.utf8.count) + (item.note.map { [$0.utf8.count] } ?? [])
            self.strings +=
                item.lookup.keys.map(\.utf8.count) + item.serials.values.map(\.utf8.count)
            self.binaries +=
                [item.photo.bytes.count] + (item.thumbnail.map { [$0.bytes.count] } ?? [])
            self.collections += [
                item.tags.count, item.grid.count, item.lookup.count, item.serials.count,
            ]
            self.collections += item.grid.map(\.count)
        }

        private mutating func add(_ shipment: Catalog.Shipment, depth: Int) {
            switch shipment {
                case .shipped(let carrier, let tracking, _):
                    self.strings.append(carrier.utf8.count)
                    self.binaries += tracking.map { [$0.bytes.count] } ?? []
                case .split(let parts, let box):
                    self.shipmentDepth = max(self.shipmentDepth, depth + 1)
                    self.strings.append(box.label.utf8.count)
                    self.collections.append(parts.count)
                    for part in parts {
                        self.add(part, depth: depth + 1)
                    }
                case .held(let duties, _):
                    self.strings += duties.values.map(\.utf8.count)
                    self.collections.append(duties.count)
                default:
                    break
            }
        }
    }

    /// Records which MessagePack size formats the request reaches, for the
    /// statistics report (`HEGEL_STATISTICS=1`).
    func recordSizes(of request: Catalog.PutRequest, in tc: TestCase) throws {
        let sizes = CatalogSizes(request)
        if sizes.collections.contains(where: { $0 >= 16 }) {
            try tc.event("a collection past fixarray or fixmap")
        }
        if sizes.strings.contains(where: { $0 >= 32 }) {
            try tc.event("a string past fixstr")
        }
        if sizes.strings.contains(where: { $0 >= 256 }) {
            try tc.event("a string past str8")
        }
        if sizes.binaries.contains(where: { $0 >= 256 }) {
            try tc.event("a binary past bin8")
        }
        try tc.event("shipment split depth", value: Double(sizes.shipmentDepth))
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
        return String(
            buffer.readableBytesView.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0xf)]] }
        )
    }

#endif
