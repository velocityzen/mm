// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMWire
    import NIOCore
    import Testing

    /// One entry of a MessagePack map, kept as bytes: its key's encoding and
    /// its value's.
    struct MapEntry: Sendable {
        var key: [UInt8]
        var value: [UInt8]

        /// The entry's integer key; nil for a key of any other kind.
        var integerKey: Int? {
            try? MMPackDecoder().decode(Int.self, from: ByteBuffer(bytes: self.key)).get()
        }

        /// The entry's string key; nil for a key of any other kind.
        var stringKey: String? {
            try? MMPackDecoder().decode(String.self, from: ByteBuffer(bytes: self.key)).get()
        }
    }

    /// The fields of a generated struct as its map holds them: each one's
    /// integer key and name, in declaration order, and whether it is
    /// optional.
    struct FieldLayout: Sendable {
        struct Field: Sendable {
            var key: Int
            var name: String
            var optional: Bool
        }

        var fields: [Field]

        /// The fields named `names`, in declaration order, with the keys
        /// `key` finds for them.
        init(_ names: [String], optional: Set<String>, key: (String) -> Int?) {
            self.fields = names.map { name in
                guard let key = key(name) else { preconditionFailure("no coding key \(name)") }
                return Field(key: key, name: name, optional: optional.contains(name))
            }
        }

        func name(forKey key: Int) -> String? {
            self.fields.first { $0.key == key }?.name
        }

        /// Whether `entry`'s key names one of the fields, under its integer
        /// key or its name.
        func names(_ entry: MapEntry) -> Bool {
            self.fieldKey(entry) != nil
        }

        /// The integer key of the field `entry`'s key names, under its
        /// integer key or its name; nil when it names no field.
        func fieldKey(_ entry: MapEntry) -> Int? {
            if let key = entry.integerKey { return self.name(forKey: key) == nil ? nil : key }
            if let name = entry.stringKey { return self.fields.first { $0.name == name }?.key }
            return nil
        }

        /// Whether `entries` come the way the encoder writes them: each field
        /// under its integer key, in declaration order, absent optionals
        /// left out, then only keys that name no field. The generated decode
        /// reads those maps where the fields sit, and sends any other map
        /// back to `Decodable`'s path.
        func inEncoderOrder(_ entries: [MapEntry]) -> Bool {
            var next = 0
            for field in self.fields {
                if next < entries.count, entries[next].integerKey == field.key {
                    next += 1
                } else if !field.optional {
                    return false
                }
            }
            return !entries[next...].contains(where: self.names)
        }
    }

    /// A key that names no field: an integer, a string, or a key of a kind
    /// that can never name one.
    enum UnknownKey: Sendable {
        case integer(Int)
        case string(String)
        case unusable([UInt8])
    }

    /// One change to a map's entries. Positions wrap around the number of
    /// entries at the time of the change, so any position applies to any
    /// map.
    enum EntryChange: Sendable {
        /// Moves the entry at the first position to the second.
        case move(Int, to: Int)
        /// Leaves the entry out.
        case drop(Int)
        /// Writes the entry under its field's name instead of its integer
        /// key.
        case rename(Int)
        /// Writes the entry again at the second position, under the same
        /// key: with the other value's bytes for the field the key names,
        /// when it has them and `otherValue` says so, else with the same
        /// bytes.
        case duplicate(Int, at: Int, otherValue: Bool)
        /// Puts in an entry under a key that names no field.
        case unknown(UnknownKey, value: [UInt8], at: Int)
    }

    /// What a map holds once changed: `changes` made in order, then
    /// entries under keys that name no field put after every other, as a
    /// newer version of the type might write fields this one lacks.
    struct MapChanges: Sendable {
        var changes: [EntryChange]
        var trailing: [UnknownEntry]

        struct UnknownEntry: Sendable {
            var key: UnknownKey
            var value: [UInt8]
        }

        /// Any number of changes and of trailing entries, each often none.
        static let all: Gen<MapChanges> = Hegel.zip(
            entryChanges,
            .oneOf(
                .just([]),
                .array(
                    of: Hegel.zip(unknownKeys, unknownValues).map {
                        UnknownEntry(key: $0, value: $1)
                    },
                    count: 1...3
                )
            )
        )
        .map { MapChanges(changes: $0, trailing: $1) }
    }

    /// Keys that can never name a field: nil, a bool, a float, an array, and
    /// an unsigned integer past `Int64.max`.
    let unusableKeys: [[UInt8]] = [
        [0xc0], [0xc3], [0xca, 0x3f, 0x80, 0x00, 0x00], [0x91, 0x01],
        [0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
    ]

    /// The encoding of any integer, any string, any binary up to bin8's
    /// limit, or a nil, an empty array, an empty map, or a map of one entry:
    /// the values unknown keys carry.
    let unknownValues: Gen<[UInt8]> = .oneOf(
        Gen<Int>.int().map { encodedBytes($0) },
        Gen<String>.string().map { encodedBytes($0) },
        Gen<[UInt8]>.array(of: .integer(), count: 0...255).map { [0xc4, UInt8($0.count)] + $0 },
        .element(of: [[0xc0], [0x90], [0x80], [0x81, 0x00, 0x01]])
    )

    let unknownKeys: Gen<UnknownKey> = .oneOf(
        Gen<Int>.int().map { .integer($0) },
        Gen<String>.string().map { .string($0) },
        Gen<[UInt8]>.element(of: unusableKeys).map { .unusable($0) }
    )

    let position: Gen<Int> = .int(in: 0...Int.max)

    let entryChange: Gen<EntryChange> = .oneOf(
        Hegel.zip(position, position).map { .move($0, to: $1) },
        position.map { .drop($0) },
        position.map { .rename($0) },
        Hegel.zip(position, position, .bool()).map {
            .duplicate($0, at: $1, otherValue: $2)
        },
        Hegel.zip(unknownKeys, unknownValues, position).map {
            .unknown($0, value: $1, at: $2)
        }
    )

    /// No changes half the time. Otherwise any number of changes, or any
    /// number and then an entry repeated with the other value's bytes,
    /// last so that no change drops or renames it: among five kinds of
    /// change, a repeat carrying another value came up in as few as 1 case
    /// in 100.
    let entryChanges: Gen<[EntryChange]> = .oneOf(
        .just([]),
        .oneOf(
            .array(of: entryChange, count: 1...8),
            Hegel.zip(.array(of: entryChange, count: 0...7), position, position).map {
                $0 + [.duplicate($1, at: $2, otherValue: true)]
            }
        )
    )

    func encodedBytes<Value: Encodable>(_ value: Value) -> [UInt8] {
        (try? MMPackEncoder().encode(value).get()).map { Array($0.readableBytesView) } ?? []
    }

    /// The entries of the MessagePack map `bytes` starts with.
    func mapEntries(_ bytes: [UInt8]) throws -> [MapEntry] {
        var reader = ByteBuffer(bytes: bytes)
        let header = reader.readInteger(as: UInt8.self)
        let format = try #require(header)
        let count: Int
        switch format {
            case 0x80...0x8f:
                count = Int(format & 0x0f)
            case 0xde:
                let count16 = reader.readInteger(as: UInt16.self)
                count = Int(try #require(count16))
            case 0xdf:
                let count32 = reader.readInteger(as: UInt32.self)
                count = Int(try #require(count32))
            default:
                throw MMWireError.typeMismatch(expected: "map", format: format)
        }
        return try (0..<count).map { _ in
            MapEntry(key: try nextValue(&reader), value: try nextValue(&reader))
        }
    }

    /// The elements of the MessagePack array `bytes` starts with, each as
    /// bytes.
    func arrayElements(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var reader = ByteBuffer(bytes: bytes)
        let header = reader.readInteger(as: UInt8.self)
        let format = try #require(header)
        let count: Int
        switch format {
            case 0x90...0x9f:
                count = Int(format & 0x0f)
            case 0xdc:
                let count16 = reader.readInteger(as: UInt16.self)
                count = Int(try #require(count16))
            case 0xdd:
                let count32 = reader.readInteger(as: UInt32.self)
                count = Int(try #require(count32))
            default:
                throw MMWireError.typeMismatch(expected: "array", format: format)
        }
        return try (0..<count).map { _ in try nextValue(&reader) }
    }

    /// A MessagePack array of `elements`.
    func arrayBytes(_ elements: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] =
            elements.count < 16
            ? [0x90 | UInt8(elements.count)]
            : [0xdc, UInt8(elements.count >> 8), UInt8(elements.count & 0xff)]
        for element in elements {
            bytes += element
        }
        return bytes
    }

    /// The bytes of the MessagePack value `reader` is at; reads past it.
    func nextValue(_ reader: inout ByteBuffer) throws -> [UInt8] {
        var skipped = reader
        try skipped.skipMessagePackValue(maxDepth: 128).get()
        let bytes = reader.readBytes(length: skipped.readerIndex - reader.readerIndex)
        return try #require(bytes)
    }

    /// A MessagePack map of `entries`.
    func mapBytes(_ entries: [MapEntry]) -> [UInt8] {
        var bytes: [UInt8] =
            entries.count < 16
            ? [0x80 | UInt8(entries.count)]
            : [0xde, UInt8(entries.count >> 8), UInt8(entries.count & 0xff)]
        for entry in entries {
            bytes += entry.key + entry.value
        }
        return bytes
    }

    /// `entries` with `changes` made, in order. `others` are the entries
    /// of another value of the same type, whose bytes a duplicate can
    /// carry.
    func changed(
        _ entries: [MapEntry],
        by changes: [EntryChange],
        others: [MapEntry],
        layout: FieldLayout
    ) -> [MapEntry] {
        var entries = entries
        for change in changes {
            switch change {
                case .move(let from, let to):
                    guard !entries.isEmpty else { continue }
                    let entry = entries.remove(at: from % entries.count)
                    entries.insert(entry, at: to % (entries.count + 1))
                case .drop(let at):
                    guard !entries.isEmpty else { continue }
                    entries.remove(at: at % entries.count)
                case .rename(let at):
                    guard !entries.isEmpty else { continue }
                    let index = at % entries.count
                    if let key = entries[index].integerKey, let name = layout.name(forKey: key) {
                        entries[index].key = encodedBytes(name)
                    }
                case .duplicate(let from, let at, let otherValue):
                    guard !entries.isEmpty else { continue }
                    var entry = entries[from % entries.count]
                    // The other value's entries are the encoder's, under
                    // integer keys, so a field under its name finds its
                    // bytes by the field.
                    if otherValue, let field = layout.fieldKey(entry),
                        let other = others.first(where: { layout.fieldKey($0) == field })
                    {
                        entry.value = other.value
                    }
                    entries.insert(entry, at: at % (entries.count + 1))
                case .unknown(let key, let value, let at):
                    entries.insert(
                        MapEntry(key: unknownKeyBytes(key, layout), value: value),
                        at: at % (entries.count + 1)
                    )
            }
        }
        return entries
    }

    /// `entries` with `changes` made.
    func changed(
        _ entries: [MapEntry],
        by changes: MapChanges,
        others: [MapEntry],
        layout: FieldLayout
    ) -> [MapEntry] {
        changed(entries, by: changes.changes, others: others, layout: layout)
            + changes.trailing.map {
                MapEntry(key: unknownKeyBytes($0.key, layout), value: $0.value)
            }
    }

    /// The encoding of `key`, changed where it would name one of `layout`'s
    /// fields.
    func unknownKeyBytes(_ key: UnknownKey, _ layout: FieldLayout) -> [UInt8] {
        switch key {
            case .integer(let integer):
                // Field keys are never negative.
                return encodedBytes(layout.name(forKey: integer) == nil ? integer : -1 - integer)
            case .string(let string):
                let named = layout.fields.contains { $0.name == string }
                return encodedBytes(named ? string + " unknown" : string)
            case .unusable(let bytes):
                return bytes
        }
    }

    /// Records what the changed map holds, for the statistics report.
    func recordShape(
        of entries: [MapEntry],
        _ layout: FieldLayout,
        prefix: String,
        in tc: TestCase
    ) throws {
        let inOrder = layout.inEncoderOrder(entries)
        try tc.event(
            inOrder ? "\(prefix) keys in the encoder's order" : "\(prefix) keys out of order"
        )
        if inOrder, entries.contains(where: { !layout.names($0) }) {
            try tc.event("\(prefix) keys in the encoder's order, and keys naming no field")
        }
        let integerKeys = entries.compactMap(\.integerKey)
        if Set(integerKeys).count < integerKeys.count {
            try tc.event("\(prefix) a repeated key")
        }
        let valuesByKey = Dictionary(grouping: entries.filter { $0.integerKey != nil }) {
            $0.integerKey
        }
        if valuesByKey.values.contains(where: { Set($0.map(\.value)).count > 1 }) {
            try tc.event("\(prefix) a repeated key with another value")
        }
        let valuesByName = Dictionary(
            grouping: entries.filter { $0.stringKey != nil && layout.names($0) }
        ) {
            $0.stringKey
        }
        if valuesByName.values.contains(where: { Set($0.map(\.value)).count > 1 }) {
            try tc.event("\(prefix) a field's name repeated with another value")
        }
        if entries.contains(where: {
            $0.stringKey.map { name in layout.fields.contains { $0.name == name } } ?? false
        }) {
            try tc.event("\(prefix) a field under its name")
        }
        if entries.contains(where: { !layout.names($0) }) {
            try tc.event("\(prefix) a key naming no field")
        }
        for field in layout.fields where !field.optional {
            if !entries.contains(where: { $0.integerKey == field.key || $0.stringKey == field.name }
            ) {
                try tc.event("\(prefix) a required field missing")
            }
        }
    }

    @Suite("Generated decoding of rearranged maps", .hegel, .offTheCooperativePool)
    struct GeneratedFieldOrderProperties {
        static let itemLayout = FieldLayout(
            [
                "sku", "quantity", "stock", "price", "weight", "active", "condition", "tags",
                "note", "grid", "lookup", "serials", "released", "updated", "stamped", "stamp",
                "owner", "photo", "thumbnail",
            ],
            optional: ["note", "updated", "stamped", "thumbnail"],
            key: { Catalog.Item.CodingKeys(stringValue: $0)?.rawValue }
        )

        static let ownerLayout = FieldLayout(
            ["name", "since"],
            optional: ["since"],
            key: { Catalog.Item.Owner.CodingKeys(stringValue: $0)?.rawValue }
        )

        static let shippedLayout = FieldLayout(
            ["carrier", "tracking", "condition"],
            optional: ["tracking"],
            key: { Catalog.Shipment.ShippedCodingKeys(stringValue: $0)?.rawValue }
        )

        /// An item's map, and its owner's inside it, with entries moved,
        /// dropped, written under their field's name, repeated with another
        /// item's value, and put in under keys that name no field: a request
        /// holding it ahead of another item decodes through the generated
        /// code to the value `Codable` decodes it to, or fails with the same
        /// error. The generated code reads a map whose keys come in the
        /// encoder's order where its fields sit, and sends any other map
        /// back to `Decodable`'s path; this pins that both paths read the
        /// same values, a field's first occurrence under its integer key,
        /// else under its name, and leave the reader just past the map,
        /// where the next item starts.
        ///
        /// Mutation check, three runs each, on the generator's first path:
        /// keys naming a field skipped once the fields are read, a required
        /// field read under whatever key comes, an optional field read
        /// under whatever key comes, no rewind before `Decodable`'s path,
        /// the values of unknown keys left unread, and a map read one entry
        /// short each fail here every time. The agreement properties miss
        /// three of them and the unit tests four. The optional field read
        /// under any key needs unknown keys carrying binaries, and the
        /// unread values need the item inside an array. A first path that
        /// throws its own errors instead of handing them to `Decodable`'s
        /// path passes here, where every value is valid; the corrupted and
        /// truncated payload properties fail it.
        ///
        /// A repeated key's or a repeated name's last occurrence read by the
        /// generated code, and a repeated key's last read by `Codable`'s
        /// decoder, each fail here and in the union property below in three
        /// runs of three. The repeated name's passed both until a repeat
        /// under a field's name carried another value's bytes.
        @Test
        func rearrangedItemsDecodeAsCodableDecodesThem() throws {
            try property(
                reaching: [
                    "item keys in the encoder's order", "item keys out of order",
                    "item keys in the encoder's order, and keys naming no field",
                    "item a repeated key", "item a repeated key with another value",
                    "item a field under its name",
                    "item a key naming no field", "item a required field missing",
                    "owner keys out of order", "decoded", "decoded with keys out of order",
                    "failed with keyNotFound",
                ]
            ) { tc in
                let generators = CatalogGenerators(try #draw(CatalogGenerators.shapes, from: tc))
                let item = try #draw(generators.item, from: tc)
                let other = try #draw(generators.item, from: tc)
                let changes = try #draw(MapChanges.all, from: tc)
                let ownerChanges = try #draw(MapChanges.all, from: tc)

                let ownerKey = encodedBytes(Catalog.Item.CodingKeys.owner.rawValue)
                let others = try mapEntries(encodedBytes(other))
                var entries = try mapEntries(encodedBytes(item))
                for index in entries.indices where entries[index].key == ownerKey {
                    let owner = changed(
                        try mapEntries(entries[index].value),
                        by: ownerChanges,
                        others: try mapEntries(encodedBytes(other.owner)),
                        layout: Self.ownerLayout
                    )
                    try recordShape(of: owner, Self.ownerLayout, prefix: "owner", in: tc)
                    entries[index].value = mapBytes(owner)
                }
                entries = changed(entries, by: changes, others: others, layout: Self.itemLayout)
                try recordShape(of: entries, Self.itemLayout, prefix: "item", in: tc)

                // The request's items: the changed item, then the other.
                let request = Catalog.PutRequest(
                    items: [item, other],
                    conditions: [],
                    flag: nil,
                    shipments: nil
                )
                let itemsKey = encodedBytes(Catalog.PutRequest.CodingKeys.items.rawValue)
                var requestEntries = try mapEntries(encodedBytes(request))
                for index in requestEntries.indices where requestEntries[index].key == itemsKey {
                    var items = try arrayElements(requestEntries[index].value)
                    items[0] = mapBytes(entries)
                    requestEntries[index].value = arrayBytes(items)
                }

                let bytes = ByteBuffer(bytes: mapBytes(requestEntries))
                let generated = decodedThroughGeneratedCode(Catalog.PutRequest.self, from: bytes)
                try tc.event(outcome(generated))
                if case .success = generated, !Self.itemLayout.inEncoderOrder(entries) {
                    try tc.event("decoded with keys out of order")
                }
                #expect(
                    generated.map(bitwise)
                        == decodedThroughCodable(Catalog.PutRequest.self, from: bytes).map(bitwise),
                    "\(hex(bytes))"
                )
            }
        }

        /// The same for the fields of a union case, which the generated
        /// code reads with the same two paths: a shipped shipment's fields
        /// map, rearranged, decodes to what `Codable` decodes it to, or
        /// fails with the same error.
        @Test
        func rearrangedUnionFieldsDecodeAsCodableDecodesThem() throws {
            try property(
                reaching: [
                    "fields keys in the encoder's order", "fields keys out of order",
                    "fields keys in the encoder's order, and keys naming no field",
                    "fields a repeated key", "fields a repeated key with another value",
                    "fields a field under its name",
                    "fields a key naming no field", "fields a required field missing",
                    "decoded", "decoded with keys out of order", "failed with keyNotFound",
                ],
                reachingAfter: ["fields a field's name repeated with another value": 1_000]
            ) { tc in
                let generators = CatalogGenerators(try #draw(CatalogGenerators.shapes, from: tc))
                let carrier = try #draw(generators.text, from: tc)
                let tracking = try #draw(Gen<MMBytes?>.optional(generators.bytes), from: tc)
                let condition = try #draw(CatalogGenerators.condition, from: tc)
                let shipment = Catalog.Shipment.shipped(
                    carrier: carrier,
                    tracking: tracking,
                    condition: condition
                )
                // The shipment whose bytes a repeated entry carries holds
                // another value in every field: a value the two shared
                // would repeat the entry's own bytes, as a repeat without
                // another value already does.
                var otherCarrier = try #draw(generators.text, from: tc)
                if otherCarrier == carrier { otherCarrier += "+" }
                var otherTracking = try #draw(generators.bytes, from: tc)
                if otherTracking == tracking { otherTracking = MMBytes(otherTracking.bytes + [0]) }
                var otherCondition = try #draw(CatalogGenerators.condition, from: tc)
                if otherCondition == condition { otherCondition = condition == .new ? .used : .new }
                let other = Catalog.Shipment.shipped(
                    carrier: otherCarrier,
                    tracking: otherTracking,
                    condition: otherCondition
                )
                let changes = try #draw(MapChanges.all, from: tc)

                // The union's own map: the case under 0, its fields under 1.
                let fieldsKey = encodedBytes(1)
                let othersMap = try mapEntries(encodedBytes(other))
                let others = try mapEntries(
                    try #require(othersMap.first { $0.key == fieldsKey }).value
                )
                var entries = try mapEntries(encodedBytes(shipment))
                var fields: [MapEntry] = []
                for index in entries.indices where entries[index].key == fieldsKey {
                    fields = changed(
                        try mapEntries(entries[index].value),
                        by: changes,
                        others: others,
                        layout: Self.shippedLayout
                    )
                    entries[index].value = mapBytes(fields)
                }
                try recordShape(of: fields, Self.shippedLayout, prefix: "fields", in: tc)

                let bytes = ByteBuffer(bytes: mapBytes(entries))
                let generated = decodedThroughGeneratedCode(Catalog.Shipment.self, from: bytes)
                try tc.event(outcome(generated))
                if case .success = generated, !Self.shippedLayout.inEncoderOrder(fields) {
                    try tc.event("decoded with keys out of order")
                }
                #expect(
                    generated == decodedThroughCodable(Catalog.Shipment.self, from: bytes),
                    "\(hex(bytes))"
                )
            }
        }
    }

#endif
