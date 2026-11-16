// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMWire
    import NIOCore
    import Testing

    // Codable writes a dictionary's entries in the dictionary's hash order,
    // and Swift seeds each hash table with its storage address. So two
    // dictionaries built from the same draws can list their entries in
    // different orders, and a replay of a case's choices can encode a request
    // to differently ordered bytes. A property that corrupts or cuts those
    // bytes then changes other bytes on the replay, and a failure it finds
    // won't shrink or replay reliably (MM-101). These helpers put every
    // dictionary's entries in one order: sorted by their keys' bytes.

    /// A request's `Codable` bytes with every dictionary's entries sorted by
    /// their keys' bytes: each item's lookup and serials, and each held
    /// shipment's duties, at any depth of splits. Everything else keeps its
    /// bytes and its place: a struct's or a union's fields come in
    /// declaration order on every run, and an undeclared case's fields are
    /// bytes the request holds, which the generator writes in one order.
    func encodedInOneOrder(_ request: Catalog.PutRequest) throws -> ByteBuffer {
        var copy = try DictionarySortingCopy(encodedThroughCodable(request).get())
        try copy.request()
        try #require(copy.input.readableBytes == 0)
        return copy.output
    }

    /// A dictionary's `Codable` bytes with its entries sorted by their keys'
    /// bytes.
    func encodedInOneOrder<Key: Encodable & Hashable, Value: Encodable>(
        _ dictionary: [Key: Value]
    ) throws -> ByteBuffer {
        try withEntriesSorted(encodedThroughCodable(dictionary).get())
    }

    /// A map's bytes with its entries sorted by their keys' bytes, or any
    /// other value's bytes as they are.
    func withEntriesSorted(_ bytes: ByteBuffer) throws -> ByteBuffer {
        var copy = DictionarySortingCopy(bytes)
        try copy.dictionary()
        try #require(copy.input.readableBytes == 0)
        return copy.output
    }

    /// Whether `format` starts a map: a fixmap, a map16 or a map32.
    func isMapFormat(_ format: UInt8) -> Bool {
        (0x80...0x8f).contains(format) || format == 0xde || format == 0xdf
    }

    /// Copies a request's bytes value by value, sorting each dictionary's
    /// entries on the way.
    private struct DictionarySortingCopy {
        var input: ByteBuffer
        var output = ByteBuffer()

        init(_ input: ByteBuffer) {
            self.input = input
        }

        /// Reads with `read`, copies the bytes it read, and returns what it
        /// read.
        mutating func copy<Value>(
            _ read: (inout ByteBuffer) -> Result<Value, MMWireError>
        ) throws -> Value {
            var probe = self.input
            let value = try read(&probe).get()
            let read = self.input.readSlice(length: probe.readerIndex - self.input.readerIndex)
            var bytes = try #require(read)
            self.output.writeBuffer(&bytes)
            return value
        }

        /// Copies one value as it is.
        mutating func value() throws {
            var value = try self.input.readMessagePackRawValueSlice().get()
            self.output.writeBuffer(&value)
        }

        /// Copies a nil as it is, and hands anything else to `wrapped`.
        mutating func optional(_ wrapped: (inout Self) throws -> Void) throws {
            guard self.input.peekMessagePackFormat() != 0xc0 else {
                return try self.value()
            }
            try wrapped(&self)
        }

        mutating func array(_ element: (inout Self) throws -> Void) throws {
            let count = try self.copy { $0.readMessagePackArrayHeader() }
            for _ in 0..<count {
                try element(&self)
            }
        }

        /// Copies a struct's map, handing each field's value to `field` with
        /// the field's key.
        mutating func structure(_ field: (inout Self, Int) throws -> Void) throws {
            let count = try self.copy { $0.readMessagePackMapHeader() }
            for _ in 0..<count {
                let key = try self.copy { $0.readMessagePackInt() }
                try field(&self, Int(key))
            }
        }

        /// Copies a dictionary's map with its entries sorted by their keys'
        /// bytes. Anything else in a dictionary's place, which a property
        /// may have put there, is copied as it is.
        mutating func dictionary() throws {
            guard let format = self.input.peekMessagePackFormat(), isMapFormat(format) else {
                return try self.value()
            }
            let count = try self.copy { $0.readMessagePackMapHeader() }
            var entries: [(key: ByteBuffer, value: ByteBuffer)] = []
            for _ in 0..<count {
                let key = try self.input.readMessagePackRawValueSlice().get()
                let value = try self.input.readMessagePackRawValueSlice().get()
                entries.append((key, value))
            }
            entries.sort {
                $0.key.readableBytesView.lexicographicallyPrecedes($1.key.readableBytesView)
            }
            for var entry in entries {
                self.output.writeBuffer(&entry.key)
                self.output.writeBuffer(&entry.value)
            }
        }

        mutating func request() throws {
            typealias Keys = Catalog.PutRequest.CodingKeys
            try self.structure { copy, key in
                switch key {
                    case Keys.items.rawValue:
                        try copy.array { try $0.item() }
                    case Keys.shipments.rawValue:
                        try copy.optional { try $0.array { try $0.shipment() } }
                    default:
                        try copy.value()
                }
            }
        }

        mutating func item() throws {
            typealias Keys = Catalog.Item.CodingKeys
            try self.structure { copy, key in
                switch key {
                    case Keys.lookup.rawValue, Keys.serials.rawValue:
                        try copy.dictionary()
                    default:
                        try copy.value()
                }
            }
        }

        /// A union writes its case's name under `case`, then the case's
        /// fields under `fields`.
        mutating func shipment() throws {
            typealias Keys = Catalog.Shipment.CodingKeys
            var caseName: String?
            try self.structure { copy, key in
                switch (key, caseName) {
                    case (Keys.`case`.rawValue, _):
                        caseName = try copy.copy { $0.readMessagePackString() }
                    case (Keys.fields.rawValue, "held"):
                        try copy.structure { copy, key in
                            if key == Catalog.Shipment.HeldCodingKeys.duties.rawValue {
                                try copy.dictionary()
                            } else {
                                try copy.value()
                            }
                        }
                    case (Keys.fields.rawValue, "split"):
                        try copy.structure { copy, key in
                            if key == Catalog.Shipment.SplitCodingKeys.parts.rawValue {
                                try copy.array { try $0.shipment() }
                            } else {
                                try copy.value()
                            }
                        }
                    default:
                        try copy.value()
                }
            }
        }
    }

    /// Where a request holds a dictionary. The raw value is the reach label
    /// for a dictionary there that a rebuild put in another order.
    enum DictionaryPlace: String, CaseIterable, Sendable {
        case lookup = "a lookup in another order"
        case serials = "serials in another order"
        case duties = "duties in another order"
        case dutiesUnderSplit = "duties under a split in another order"
    }

    /// Rebuilds every dictionary of a request in another hash table, and
    /// records the places where that changed a dictionary's order. It also
    /// collects the fields of the request's undeclared cases, which are
    /// bytes, not dictionaries.
    struct DictionaryRebuild {
        private(set) var reordered: Set<DictionaryPlace> = []
        private(set) var undeclaredFields: [MMPackRawValue] = []

        mutating func request(_ request: Catalog.PutRequest) -> Catalog.PutRequest {
            var request = request
            request.items = request.items.map { item in
                var item = item
                item.lookup = self.rebuilt(item.lookup, at: .lookup)
                item.serials = self.rebuilt(item.serials, at: .serials)
                return item
            }
            request.shipments = request.shipments.map { self.shipments($0, depth: 0) }
            return request
        }

        mutating func shipments(
            _ shipments: [Catalog.Shipment],
            depth: Int
        ) -> [Catalog.Shipment] {
            shipments.map { shipment in
                switch shipment {
                    case .held(let duties, let customs):
                        let place: DictionaryPlace = depth > 0 ? .dutiesUnderSplit : .duties
                        return .held(duties: self.rebuilt(duties, at: place), customs: customs)
                    case .split(let parts, let box):
                        return .split(parts: self.shipments(parts, depth: depth + 1), box: box)
                    case .unknown(_, let fields?):
                        self.undeclaredFields.append(fields)
                        return shipment
                    default:
                        return shipment
                }
            }
        }

        /// `dictionary`'s entries inserted in reverse order into a table with
        /// four times the room. A table's order follows its size and its
        /// seed, so the copy most often lists the entries in another order.
        mutating func rebuilt<Key: Hashable, Value>(
            _ dictionary: [Key: Value],
            at place: DictionaryPlace
        ) -> [Key: Value] {
            var copy: [Key: Value] = [:]
            copy.reserveCapacity(4 * dictionary.count + 4)
            for (key, value) in dictionary.reversed() {
                copy[key] = value
            }
            if !copy.keys.elementsEqual(dictionary.keys) {
                self.reordered.insert(place)
            }
            return copy
        }
    }

    @Suite("A request's dictionaries encode in one order", .hegel, .offTheCooperativePool)
    struct CatalogDictionaryOrderProperties {
        /// Two requests that differ only in their dictionaries' hash tables
        /// encode in one order to the same bytes, as many as `Codable`
        /// writes, and both paths decode those bytes to the request. The
        /// fields of an undeclared case, which the request holds as bytes,
        /// already list their entries in one order.
        ///
        /// Mutation-checked: six mutants fail this every time in 1,000
        /// cases. Five leave an order in place: not sorting at all; not
        /// sorting an item's serials, a held shipment's duties, or the
        /// shipments under a split; and the generator writing an undeclared
        /// case's fields in hash order. The sixth drops a dictionary's last
        /// entry.
        @Test
        func dictionariesEncodeInOneOrder() throws {
            try property(
                reaching: ["a lookup in another order", "serials in another order"],
                reachingAfter: [
                    "an undeclared case's fields with two entries or more": 1_000,
                    "duties in another order": 1_000,
                    "duties under a split in another order": 1_000,
                ]
            ) { tc in
                let shape = try #draw(CatalogGenerators.shapes, from: tc)
                let request = try #draw(CatalogGenerators(shape).putRequest, from: tc)
                var rebuild = DictionaryRebuild()
                let rebuilt = rebuild.request(request)
                for place in DictionaryPlace.allCases where rebuild.reordered.contains(place) {
                    try tc.event(place.rawValue)
                }
                for fields in rebuild.undeclaredFields {
                    let fieldBytes = ByteBuffer(bytes: fields.bytes)
                    var header = fieldBytes
                    if case .success(let count) = header.readMessagePackMapHeader(), count >= 2 {
                        try tc.event("an undeclared case's fields with two entries or more")
                    }
                    #expect(try withEntriesSorted(fieldBytes) == fieldBytes, "\(hex(fieldBytes))")
                }
                let bytes = try encodedInOneOrder(request)
                #expect(try encodedInOneOrder(rebuilt) == bytes)
                #expect(
                    try bytes.readableBytes == encodedThroughCodable(request).get().readableBytes
                )
                // An optional of an optional holding nil writes a plain nil,
                // which reads back as absent.
                var expected = request
                if case .some(.none) = request.flag {
                    expected.flag = nil
                }
                #expect(
                    decodedThroughGeneratedCode(Catalog.PutRequest.self, from: bytes).map(bitwise)
                        == .success(bitwise(expected))
                )
                #expect(
                    decodedThroughCodable(Catalog.PutRequest.self, from: bytes).map(bitwise)
                        == .success(bitwise(expected))
                )
            }
        }
    }

#endif
