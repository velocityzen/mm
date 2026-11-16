// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMCLI
    import MMSchema
    import MMWire
    import Testing

    /// A Swift peer's maps, one for each kind of wire map key a schema
    /// describes: unsigned and signed integers, and a generated enum's
    /// cases, whose key schema is a reference to the enum.
    struct KeyedMaps: Codable, Equatable, Sendable {
        var unsigned: [UInt64: String]
        var signed: [Int64: Bool]
        var conditions: [Catalog.Condition: UInt64]

        /// What the probe makes of `KeyedMaps`.
        static let schema = TypeSchema.structure(fields: [
            .init(key: nil, name: "unsigned", type: .map(key: .uint, value: .string)),
            .init(key: nil, name: "signed", type: .map(key: .int, value: .bool)),
            .init(
                key: nil,
                name: "conditions",
                type: .map(key: .reference("catalog.Condition"), value: .uint)
            ),
        ])

        /// The maps as the CLI renders them: each key as text, integer keys
        /// in numeric order and case names in string order, as the response
        /// decoder sorts them.
        var rendered: SchemaValue {
            .object([
                .init(
                    "unsigned",
                    .object(
                        self.unsigned.sorted { $0.key < $1.key }
                            .map { .init(String($0.key), .string($0.value)) }
                    )
                ),
                .init(
                    "signed",
                    .object(
                        self.signed.sorted { $0.key < $1.key }
                            .map { .init(String($0.key), .bool($0.value)) }
                    )
                ),
                .init(
                    "conditions",
                    .object(
                        self.conditions.map { (name: $0.key.rawValue, value: $0.value) }
                            .sorted { $0.name < $1.name }
                            .map { .init($0.name, .uint($0.value)) }
                    )
                ),
            ])
        }
    }

    enum MapKeyGenerators {
        /// Signed keys over all of `Int64`, with its edges and the fixint
        /// edges.
        static let signedKeys: Gen<Int64> = .oneOf(
            .integer(),
            .element(of: [.min, -33, -32, -1, 0, 127, 128, .max])
        )

        /// An unsigned key past `Int64.max`, which no wire map key holds.
        static let pastRange: Gen<UInt64> = .oneOf(
            .integer(in: (UInt64(Int64.max) + 1)...UInt64.max),
            .element(of: [UInt64(Int64.max) + 1, .max])
        )

        /// Most often the cases a schema declares, sometimes names it does
        /// not, which a Swift peer keeps in `unknown`.
        static let conditions: Gen<Catalog.Condition> = .oneOf(
            .element(of: [.new, .used]),
            .element(of: [.new, .used, .unknown("unknown"), .unknown("worn")])
        )

        /// A few entries, or more than the 32 a decoder searches in order:
        /// past that it hashes the map's keys.
        static func entries<Key: Hashable & SendableMetatype, Value>(
            keys: Gen<Key>,
            values: Gen<Value>
        ) -> Gen<[Key: Value]> {
            .oneOf(
                .dictionary(keys: keys, values: values, count: 0...4),
                .dictionary(keys: keys, values: values, count: 0...4),
                .dictionary(keys: keys, values: values, count: 33...34)
            )
        }

        static let keyedMaps: Gen<KeyedMaps> = Gen { tc in
            KeyedMaps(
                unsigned: try tc.draw(
                    entries(keys: CatalogGenerators.unsignedKey, values: .string(of: .ascii))
                ),
                signed: try tc.draw(entries(keys: signedKeys, values: .bool())),
                conditions: try tc.draw(
                    .dictionary(keys: conditions, values: CatalogGenerators.unsigned, count: 0...3)
                )
            )
        }
    }

    @Suite("Map key properties", .hegel, .offTheCooperativePool)
    struct MapKeyProperties {
        /// A dictionary keyed by integers or by a generated enum reads the
        /// same on a Swift peer and on the CLI's dynamic side, both ways.
        /// The Swift coder writes it as a wire map, which the CLI's response
        /// decoder reads under the probed schema, whose enum key schema is a
        /// reference; the CLI's request, built from that rendering, decodes
        /// on the Swift side to the dictionary itself. An unsigned key past
        /// `Int64.max`, which no wire map key holds, fails the Swift encode
        /// and `validated` alike. A Swift peer's `unknown` enum key is no
        /// case name, so the CLI refuses to send it.
        ///
        /// Mutation check: the coders carrying an integer or enum key
        /// type's dictionary as `Codable`'s array of keys and values, either
        /// one alone or both; the encoder letting a key past `Int64.max`
        /// wrap around; or `validated` checking a referenced key schema
        /// without resolving it, or taking any text as an enumeration key,
        /// fails here.
        @Test
        func dictionariesReadTheSameOnBothSides() throws {
            #expect(try TypeSchema.of(KeyedMaps.self).get() == KeyedMaps.schema)
            let resolver = TypeResolver(Catalog.types)
            try property(
                reaching: [
                    "a condition key", "a key at Int64.max", "a key at Int64.min",
                    "a map the decoder hashes", "a negative key", "an empty map",
                    "sent by the CLI and read in Swift", "sent from Swift and read by the CLI",
                ],
                reachingAfter: [
                    "an unknown condition key, which the CLI refuses": 1_000,
                    "an unsigned key past Int64.max, refused on both sides": 1_000,
                ]
            ) { tc in
                let maps = try #draw(MapKeyGenerators.keyedMaps, from: tc)
                if maps.unsigned.keys.contains(UInt64(Int64.max))
                    || maps.signed.keys.contains(.max)
                {
                    try tc.event("a key at Int64.max")
                }
                if maps.signed.keys.contains(.min) {
                    try tc.event("a key at Int64.min")
                }
                if maps.signed.keys.contains(where: { $0 < 0 }) {
                    try tc.event("a negative key")
                }
                if maps.unsigned.count > 32 || maps.signed.count > 32 {
                    try tc.event("a map the decoder hashes")
                }
                if !maps.conditions.isEmpty {
                    try tc.event("a condition key")
                }
                if maps.unsigned.isEmpty || maps.signed.isEmpty || maps.conditions.isEmpty {
                    try tc.event("an empty map")
                }

                if try #draw(Gen<Bool>.bool(probability: 0.15), from: tc) {
                    try tc.event("an unsigned key past Int64.max, refused on both sides")
                    let past = try #draw(MapKeyGenerators.pastRange, from: tc)
                    var outOfRange = maps
                    outOfRange.unsigned[past] = ""
                    #expect(
                        throws: MMWireError.numberOutOfRange(target: "Int64"),
                        "a Swift peer sent the key \(past)"
                    ) {
                        try MMPackEncoder().encode(outOfRange).get()
                    }
                    switch outOfRange.rendered.validated(
                        against: KeyedMaps.schema,
                        resolver: resolver
                    ) {
                        case .success:
                            Issue.record("validated took the key \(past)")
                        case .failure(let error):
                            #expect(
                                error.path == "unsigned.\(past)"
                                    && error.problem == KeyReading.outOfRange,
                                "validated refused \(past) as \(error)"
                            )
                    }
                    return
                }

                try tc.event("sent from Swift and read by the CLI")
                let bytes = try MMPackEncoder().encode(maps).get()
                let response = try MMCLIDynamicResponse.$schema.withValue(
                    (KeyedMaps.schema, Catalog.types)
                ) {
                    try MMPackDecoder().decode(MMCLIDynamicResponse.self, from: bytes).get()
                }
                #expect(
                    identical(response.tree, maps.rendered),
                    "\(maps) was read by the CLI as \(response.tree)"
                )

                let request = Result {
                    try MMCLIDynamicRequest(
                        schema: KeyedMaps.schema,
                        definitions: Catalog.types,
                        json: maps.rendered
                    )
                }
                let undeclared = maps.conditions.keys.filter {
                    Catalog.Condition.allCases.contains($0) == false
                }
                .map(\.rawValue).sorted()
                if let firstUndeclared = undeclared.first {
                    try tc.event("an unknown condition key, which the CLI refuses")
                    #expect(throws: (any Error).self, "the CLI sent \(maps)") {
                        try request.get()
                    }
                    switch maps.rendered.validated(against: KeyedMaps.schema, resolver: resolver) {
                        case .success:
                            Issue.record("validated took the key \(firstUndeclared)")
                        case .failure(let error):
                            #expect(
                                error.path == "conditions.\(firstUndeclared)"
                                    && error.problem == "key is not one of: new, used",
                                "validated refused \(maps) as \(error)"
                            )
                    }
                    return
                }
                try tc.event("sent by the CLI and read in Swift")
                let sent = try MMPackDecoder()
                    .decode(
                        KeyedMaps.self,
                        from: try MMPackEncoder().encode(try request.get()).get()
                    )
                    .get()
                #expect(sent == maps, "the CLI sent \(maps) as \(sent)")
            }
        }
    }

#endif
