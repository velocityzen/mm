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
                    Field(
                        "tier",
                        .optional(
                            .enumeration(cases: [
                                .init(name: "gold"),
                                .init(name: "silver", deprecation: "Folded into gold"),
                            ])
                        )
                    )
                }
                Field("photo", .bytes)
                Field("thumbnail", .optional(.bytes))
                Field("lead", .duration)
                Field("grace", .optional(.duration))
                Field("lot", .uuid)
                Field("supplier", .optional(.uuid))
                Field(
                    "finish",
                    .enumeration(cases: [
                        .init(name: "matte"),
                        .init(name: "gloss", description: "Polished to shine"),
                    ])
                )
                Field(
                    "coats",
                    .array(
                        .optional(
                            .enumeration(cases: [.init(name: "primer"), .init(name: "clear")])
                        )
                    )
                )
                Field(
                    "rooms",
                    .map(
                        key: .string,
                        value: .enumeration(cases: [.init(name: "kitchen"), .init(name: "hall")])
                    )
                )
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
                Case("recalled") {
                    Field(
                        "reason",
                        .enumeration(cases: [.init(name: "damaged"), .init(name: "unwanted")])
                    )
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
        /// How deep shipments may nest: split, reissued or rerouted. Each
        /// level nests at most three containers (the case map, its fields
        /// map, and a split's parts array or a reroute's via), so 32 levels
        /// nest about 101: inside the decoders' default limit of 128.
        var shipmentDepth: Int
        /// How deep parts may hold parts. Each level nests at most three
        /// containers (the part's map, its assembly's map and the
        /// assembly's parts array), so 32 levels nest about 101.
        var partDepth: Int
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
        /// shipments and parts that hold no others.
        static let shapes: Gen<CatalogShape> = Hegel.zip(
            Gen<Double>.element(of: [0, 0.1, 0.5]),
            depths,
            depths
        )
        .map { CatalogShape(boundaryRate: $0, shipmentDepth: $1, partDepth: $2) }

        /// The depths recursive values nest to: none, a few, and as deep as
        /// the decoders' default nesting limit allows.
        static let depths: Gen<Int> = .element(of: [0, 3, 32])

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

        /// A wire enum's declared cases, and values the contract does not
        /// declare, which a newer peer sends and `unknown` keeps.
        static func wireEnum<Value: CaseIterable & RawRepresentable & Sendable>(
            unknown: @escaping @Sendable (String) -> Value
        ) -> Gen<Value> where Value.RawValue == String {
            .oneOf(
                .allCases,
                .allCases,
                Gen<String>.string().map { Value(rawValue: $0) ?? unknown($0) }
            )
        }

        static let condition = wireEnum(unknown: Catalog.Condition.unknown)

        // The enums the catalog's inline enumerations generate.
        static let tier = wireEnum(unknown: Catalog.Item.Owner.Tier.unknown)
        static let finish = wireEnum(unknown: Catalog.Item.Finish.unknown)
        static let coat = wireEnum(unknown: Catalog.Item.Coats.unknown)
        static let room = wireEnum(unknown: Catalog.Item.Rooms.unknown)
        static let reason = wireEnum(unknown: Catalog.Shipment.Reason.unknown)

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
                        since: tc.draw(.optional(Self.date)),
                        tier: tc.draw(.optional(Self.tier))
                    ),
                    photo: tc.draw(self.bytes),
                    thumbnail: tc.draw(.optional(self.bytes)),
                    lead: tc.draw(DurationGenerators.durations),
                    grace: tc.draw(.optional(DurationGenerators.durations)),
                    lot: tc.draw(UUIDGenerators.uuids),
                    supplier: tc.draw(.optional(UUIDGenerators.uuids)),
                    finish: tc.draw(Self.finish),
                    coats: tc.draw(self.list(of: Gen<Catalog.Item.Coats?>.optional(Self.coat))),
                    rooms: tc.draw(self.map(keys: self.text, values: Self.room))
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
                    self.held,
                    Gen { tc in try .recalled(reason: tc.draw(Self.reason)) }
                ),
                branch: { shipment in
                    .oneOf(
                        Gen { tc in
                            try .split(
                                parts: tc.draw(Gen<[Catalog.Shipment]>.array(of: shipment)),
                                box: .init(label: tc.draw(self.text))
                            )
                        },
                        // The union's own type, held directly and through
                        // an optional in a nested structure.
                        Gen { tc in
                            try .reissued(
                                original: tc.draw(shipment),
                                reason: tc.draw(.optional(self.text))
                            )
                        },
                        Gen { tc in
                            try .rerouted(via: .init(next: tc.draw(.optional(shipment))))
                        }
                    )
                }
            )
        }

        /// Parts holding parts: through an optional assembly, which holds
        /// its base part and any number of others, and through an optional
        /// in a nested structure, the spare. A part ends in at most eight
        /// parts that hold none, so a request's arrays of assemblies of
        /// parts stay cheap; a chain of spares still nests as deep as the
        /// shape allows.
        var part: Gen<Catalog.Part> {
            .recursive(
                maxDepth: self.shape.partDepth,
                maxLeaves: 8,
                leaf: Gen { tc in
                    try Catalog.Part(
                        name: tc.draw(self.text),
                        assembly: nil,
                        spare: .init(part: nil)
                    )
                },
                branch: { part in
                    Gen { tc in
                        try Catalog.Part(
                            name: tc.draw(self.text),
                            assembly: tc.draw(.optional(Self.assembly(of: part))),
                            spare: .init(part: tc.draw(.optional(part)))
                        )
                    }
                }
            )
        }

        var assembly: Gen<Catalog.Assembly> {
            Self.assembly(of: self.part)
        }

        static func assembly(of part: Gen<Catalog.Part>) -> Gen<Catalog.Assembly> {
            Gen { tc in
                try Catalog.Assembly(base: tc.draw(part), parts: tc.draw(.array(of: part)))
            }
        }

        /// A case the contract does not declare, as a newer peer sends it:
        /// its name never a declared one, and no fields or a fields map.
        var undeclaredShipment: Gen<Catalog.Shipment> {
            Gen { tc in
                let name = try tc.draw(self.text)
                let tag =
                    ["pending", "shipped", "split", "held", "reissued", "rerouted", "recalled"]
                        .contains(name)
                    ? name + "+" : name
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
                    shipments: tc.draw(.optional(self.list(of: self.shipment))),
                    assemblies: tc.draw(.optional(self.list(of: self.assembly)))
                )
            }
        }
    }

    /// The sizes in a request that decide which MessagePack formats encode
    /// it: every string's UTF-8 byte count, every binary's byte count, every
    /// collection's element count, how deep its shipments and parts nest,
    /// and which recursive fields it holds.
    struct CatalogSizes {
        var strings: [Int] = []
        var binaries: [Int] = []
        var collections: [Int] = []
        var shipmentDepth = 0
        var partDepth = 0
        var holdsReissuedShipment = false
        var holdsReroutedShipmentWithNext = false
        var holdsPartWithAssembly = false
        var holdsPartWithSpare = false
        var holdsRecalledShipment = false
        /// Whether an inline enumeration's enum holds a value the contract
        /// does not declare.
        var holdsUndeclaredInlineValue = false

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
            if let assemblies = request.assemblies {
                self.collections.append(assemblies.count)
                for assembly in assemblies {
                    self.add(assembly, depth: 0)
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
                item.coats.count, item.rooms.count,
            ]
            self.collections += item.grid.map(\.count)
            self.strings += item.rooms.keys.map(\.utf8.count)
            if !Catalog.Item.Finish.allCases.contains(item.finish)
                || item.coats.contains(where: {
                    $0.map { !Catalog.Item.Coats.allCases.contains($0) } ?? false
                })
                || item.rooms.values.contains(where: { !Catalog.Item.Rooms.allCases.contains($0) })
                || item.owner.tier.map({ !Catalog.Item.Owner.Tier.allCases.contains($0) }) ?? false
            {
                self.holdsUndeclaredInlineValue = true
            }
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
                case .reissued(let original, let reason):
                    self.holdsReissuedShipment = true
                    self.shipmentDepth = max(self.shipmentDepth, depth + 1)
                    self.strings += reason.map { [$0.utf8.count] } ?? []
                    self.add(original, depth: depth + 1)
                case .rerouted(let via):
                    self.shipmentDepth = max(self.shipmentDepth, depth + 1)
                    if let next = via.next {
                        self.holdsReroutedShipmentWithNext = true
                        self.add(next, depth: depth + 1)
                    }
                case .recalled(let reason):
                    self.holdsRecalledShipment = true
                    if !Catalog.Shipment.Reason.allCases.contains(reason) {
                        self.holdsUndeclaredInlineValue = true
                    }
                default:
                    break
            }
        }

        private mutating func add(_ assembly: Catalog.Assembly, depth: Int) {
            self.add(assembly.base, depth: depth)
            self.collections.append(assembly.parts.count)
            for part in assembly.parts {
                self.add(part, depth: depth)
            }
        }

        private mutating func add(_ part: Catalog.Part, depth: Int) {
            self.strings.append(part.name.utf8.count)
            if let assembly = part.assembly {
                self.holdsPartWithAssembly = true
                self.partDepth = max(self.partDepth, depth + 1)
                self.add(assembly, depth: depth + 1)
            }
            if let spare = part.spare.part {
                self.holdsPartWithSpare = true
                self.partDepth = max(self.partDepth, depth + 1)
                self.add(spare, depth: depth + 1)
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
        if sizes.holdsReissuedShipment {
            try tc.event("a reissued shipment")
        }
        if sizes.holdsReroutedShipmentWithNext {
            try tc.event("a rerouted shipment holding the next")
        }
        if sizes.holdsPartWithAssembly {
            try tc.event("a part holding an assembly")
        }
        if sizes.holdsPartWithSpare {
            try tc.event("a part holding a spare")
        }
        if sizes.holdsRecalledShipment {
            try tc.event("a recalled shipment")
        }
        if sizes.holdsUndeclaredInlineValue {
            try tc.event("an inline enumeration value the contract does not declare")
        }
        try tc.event("shipment nesting depth", value: Double(sizes.shipmentDepth))
        try tc.event("part nesting depth", value: Double(sizes.partDepth))
    }

    /// The events `recordSizes` records for the catalog's recursive types.
    let recursiveShapeEvents = [
        "a reissued shipment", "a rerouted shipment holding the next",
        "a part holding an assembly", "a part holding a spare",
    ]

    /// The events `recordSizes` records for the catalog's inline
    /// enumerations: a value of their enums that the contract does not
    /// declare, which `unknown` keeps, and the union case whose field holds
    /// one, the rarer, claimed once 1,000 cases have passed.
    let inlineEnumerationEvents = ["an inline enumeration value the contract does not declare"]
    let inlineEnumerationEventsAfter = ["a recalled shipment": 1_000]

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
