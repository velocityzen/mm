// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import NIOCore
    import Testing

    @testable import MMWire

    /// A key of a hand-written wire map: text, or an integer.
    enum WireMapKey: Sendable, Hashable, CustomStringConvertible {
        case text(String)
        case integer(Int64)

        var description: String {
            switch self {
                case .text(let text): "\"\(text)\""
                case .integer(let integer): "\(integer)"
            }
        }

        /// The key as `Codable` names a `[String: …]` entry.
        var stringValue: String {
            switch self {
                case .text(let text): text
                case .integer(let integer): String(integer)
            }
        }

        func write(to buffer: inout ByteBuffer) {
            switch self {
                case .text(let text): buffer.writeMessagePackString(text)
                case .integer(let integer): buffer.writeMessagePackInt(integer)
            }
        }
    }

    /// A value of a hand-written wire map. Only an integer decodes as an
    /// `Int`; each of the others fails with an error that tells it apart:
    /// text by its length's format byte, and an integer above `Int64.max` as
    /// out of range.
    enum WireMapValue: Sendable, CustomStringConvertible {
        case integer(Int64)
        case aboveInt64(UInt64)
        case text(length: Int)

        var description: String {
            switch self {
                case .integer(let integer): "\(integer)"
                case .aboveInt64(let integer): "\(integer)"
                case .text(let length): "text(length: \(length))"
            }
        }

        var isInteger: Bool {
            if case .integer = self { return true }
            return false
        }

        func write(to buffer: inout ByteBuffer) {
            switch self {
                case .integer(let integer): buffer.writeMessagePackInt(integer)
                case .aboveInt64(let integer): buffer.writeMessagePackUInt(integer)
                case .text(let length):
                    buffer.writeMessagePackString(String(repeating: "x", count: length))
            }
        }
    }

    /// One entry of a hand-written wire map.
    struct WireMapEntry: Sendable, CustomStringConvertible {
        let key: WireMapKey
        let value: WireMapValue

        var description: String { "\(self.key): \(self.value)" }
    }

    /// The map's bytes: its header, then each entry's key and value in order.
    func wireMap(_ entries: [WireMapEntry]) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeMessagePackMapHeader(count: entries.count)
        for entry in entries {
            entry.key.write(to: &buffer)
            entry.value.write(to: &buffer)
        }
        return buffer
    }

    /// One value's bytes on their own.
    func wireBytes(_ write: (inout ByteBuffer) -> Void) -> ByteBuffer {
        var buffer = ByteBuffer()
        write(&buffer)
        return buffer
    }

    /// The entries a decoder reads: each key's first occurrence, in wire
    /// order. A later entry under the same key is never read.
    func firstOccurrences(_ entries: [WireMapEntry]) -> [WireMapEntry] {
        var seen: Set<WireMapKey> = []
        return entries.filter { seen.insert($0.key).inserted }
    }

    /// A `[String: Int]` decoded from the entries one at a time, in wire
    /// order, the way `Codable` walks a keyed container's keys: the first
    /// value that fails to decode fails the map.
    func expectedStringKeyedMap(
        _ entries: [WireMapEntry]
    ) -> Result<[String: Int], MMWireError> {
        var dictionary: [String: Int] = [:]
        for entry in firstOccurrences(entries) {
            switch MMPackDecoder().decode(Int.self, from: wireBytes(entry.value.write)) {
                case .failure(let error): return .failure(error)
                case .success(let value): dictionary[entry.key.stringValue] = value
            }
        }
        return .success(dictionary)
    }

    /// A `[Catalog.Condition: Int]` decoded from the entries one at a time,
    /// in wire order: a key that fails to decode fails the map, a key that
    /// decodes to one already read keeps the first value without reading
    /// its own, and then the first value that fails to decode fails it.
    func expectedConditionKeyedMap(
        _ entries: [WireMapEntry]
    ) -> Result<[Catalog.Condition: Int], MMWireError> {
        var dictionary: [Catalog.Condition: Int] = [:]
        for entry in firstOccurrences(entries) {
            let key: Catalog.Condition
            switch MMPackDecoder().decode(Catalog.Condition.self, from: wireBytes(entry.key.write))
            {
                case .failure(let error): return .failure(error)
                case .success(let decoded): key = decoded
            }
            guard dictionary[key] == nil else { continue }
            switch MMPackDecoder().decode(Int.self, from: wireBytes(entry.value.write)) {
                case .failure(let error): return .failure(error)
                case .success(let value): dictionary[key] = value
            }
        }
        return .success(dictionary)
    }

    /// Past this many entries the decoder hashes a map's keys instead of
    /// searching them in order.
    let hashedMapLimit = MPMapIndex.linearSearchLimit

    /// Entry counts on both sides of ``hashedMapLimit``, and right at it,
    /// with hashed maps more often than not: the order of their keys is what
    /// a decode used to get wrong.
    let wireMapEntryCounts: Gen<Int> = .oneOf(
        .int(in: 0...(2 * hashedMapLimit + 6)),
        .element(of: [hashedMapLimit - 1, hashedMapLimit, hashedMapLimit + 1, hashedMapLimit + 2]),
        .int(in: (hashedMapLimit + 1)...(3 * hashedMapLimit))
    )

    /// How many keys a map draws from: a handful, so keys repeat, or many.
    let wireMapKeySpaces: Gen<Int> = .oneOf(.element(of: [1, 2, 3]), .int(in: 1...1_000))

    /// Values: integers across `Int64`, and with `badValues` a quarter of
    /// them text or an integer above `Int64.max`.
    func wireMapValues(badValues: Bool) -> Gen<WireMapValue> {
        let integers = Gen<Int64>.oneOf(.integer(), .element(of: [0, 1, -1, .min, .max]))
            .map { WireMapValue.integer($0) }
        guard badValues else { return integers }
        let others = Gen<WireMapValue>.oneOf(
            Gen<Int>.int(in: 0...33).map { WireMapValue.text(length: $0) },
            Gen<UInt64>.integer(in: UInt64(Int64.max) + 1...UInt64.max)
                .map { WireMapValue.aboveInt64($0) }
        )
        return .oneOf(integers, integers, integers, others)
    }

    /// Keys for a `[String: Int]`: integers, and text that never spells
    /// one. `Codable` gives a `[String: …]` key that spells an integer the
    /// integer as its `intValue`, so the map's integer key of that value
    /// would answer for it: a rule of its own, not this property's.
    func stringDictionaryKeys(keySpace: Int) -> Gen<WireMapKey> {
        let index = Gen<Int>.int(in: 0..<keySpace)
        return .oneOf(
            index.map { WireMapKey.text("k\($0)") },
            index.map { WireMapKey.integer(Int64($0)) },
            Gen<Int64>.integer().map { WireMapKey.integer($0) }
        )
    }

    /// Keys for a `[Catalog.Condition: Int]`: the cases' names and other
    /// text, which the generated enum reads as `unknown`, and with
    /// `integerKeys` integers, which it refuses.
    func conditionKeys(keySpace: Int, integerKeys: Bool) -> Gen<WireMapKey> {
        let index = Gen<Int>.int(in: 0..<keySpace)
        let text = Gen<WireMapKey>.oneOf(
            Gen<String>.element(of: ["new", "used", "unknown"]).map { WireMapKey.text($0) },
            index.map { WireMapKey.text("k\($0)") },
            Gen<String>.string(count: 0...8).map { WireMapKey.text($0) }
        )
        guard integerKeys else { return text }
        return .oneOf(text, text, index.map { WireMapKey.integer(Int64($0)) })
    }

    /// The labels for where a map's entries put the decoder, shared by both
    /// properties.
    func recordMapEvents(_ entries: [WireMapEntry], in tc: TestCase) throws {
        let read = firstOccurrences(entries)
        let hashed = entries.count > hashedMapLimit
        try tc.event(hashed ? "a map the decoder hashes" : "a map the decoder searches in order")
        if read.filter({ !$0.value.isInteger }).count >= 2 {
            try tc.event("two values that fail")
            if hashed { try tc.event("two values that fail, in a map the decoder hashes") }
        }
        if read.count < entries.count {
            try tc.event("a repeated key")
            let firstValues = Dictionary(read.map { ($0.key, $0.value) }) { first, _ in first }
            let shadowed = entries.contains { entry in
                !entry.value.isInteger && firstValues[entry.key]?.isInteger == true
            }
            if shadowed { try tc.event("a repeated key whose later value fails") }
        }
    }

    /// Mutation-checked: six mutants fail these properties every time. Four
    /// are in a hashed map: listing its keys in hash order, listing its
    /// integer keys before its text keys, and keeping the last value of a
    /// repeated text key or of a repeated integer key. The other two are
    /// in a map whose keys decode as values: keeping the last of the keys
    /// that decode alike, and decoding the value of a key it skips. The
    /// rest of the suite misses three of them, hash order among them.
    @Suite("A map's entries decode in wire order", .hegel)
    struct MapEntryOrderProperties {
        /// Decoding a wire map into a `[String: Int]` reads its keys in wire
        /// order, whatever its size: it fails with the first value, among
        /// each key's first occurrence, that fails to decode, and otherwise
        /// holds each key's first value.
        ///
        /// The explicit example is the map from the 2026-11-15 nightly run:
        /// past 32 entries the decoder listed a hashed map's keys in hash
        /// order, so which failing value it reported changed from run to
        /// run.
        @Test
        func stringKeyedMapsReadTheirEntriesInWireOrder() throws {
            let nightlyMap: [WireMapEntry] =
                (0..<26).map { WireMapEntry(key: .text("k\($0)"), value: .integer(Int64($0))) }
                + [
                    WireMapEntry(key: .text("k0"), value: .text(length: 12)),
                    WireMapEntry(key: .integer(256), value: .text(length: 0)),
                    WireMapEntry(key: .integer(127), value: .text(length: 4)),
                    WireMapEntry(key: .integer(4_294_967_296), value: .text(length: 6)),
                    WireMapEntry(key: .integer(-31_021_712), value: .text(length: 8)),
                    WireMapEntry(key: .integer(4_294_967_296), value: .integer(9)),
                    WireMapEntry(key: .text("k1"), value: .integer(1)),
                ]
            try property(
                examples: [
                    [
                        "keySpace": 26, "badValues": true, "count": nightlyMap.count,
                        "entries": nightlyMap,
                    ]
                ],
                reaching: [
                    "a map the decoder hashes", "a map the decoder searches in order",
                    "a repeated key", "decoded", "two values that fail",
                    "two values that fail, in a map the decoder hashes",
                ],
                reachingAfter: [
                    "a repeated key whose later value fails": 1_000,
                    "failed with numberOutOfRange": 1_000, "failed with typeMismatch": 1_000,
                ]
            ) { tc in
                let keySpace = try #draw(wireMapKeySpaces, from: tc)
                let badValues = try #draw(.bool(probability: 0.6), from: tc)
                let count = try #draw(wireMapEntryCounts, from: tc)
                let entries = try #draw(
                    .array(
                        of: Hegel.zip(
                            stringDictionaryKeys(keySpace: keySpace),
                            wireMapValues(badValues: badValues)
                        )
                        .map { WireMapEntry(key: $0.0, value: $0.1) },
                        count: count...count
                    ),
                    from: tc
                )
                try recordMapEvents(entries, in: tc)
                let decoded = MMPackDecoder().decode([String: Int].self, from: wireMap(entries))
                try tc.event(outcome(decoded))
                #expect(decoded == expectedStringKeyedMap(entries))
            }
        }

        /// Decoding a wire map into a dictionary whose keys decode as values
        /// (here a generated enum, which reads unknown text as `unknown`)
        /// reads its keys in wire order, whatever its size: the first key or
        /// value that fails to decode fails it, and keys that decode to the
        /// same key keep the value of the first one read.
        @Test
        func valueKeyedMapsReadTheirEntriesInWireOrder() throws {
            try property(
                reaching: [
                    "a map the decoder hashes", "a repeated key", "decoded",
                    "keys that decode to the same key", "two values that fail",
                    "two values that fail, in a map the decoder hashes",
                ],
                reachingAfter: [
                    "a key that fails": 1_000, "a map the decoder searches in order": 1_000,
                    "a repeated key whose later value fails": 1_000,
                    "failed with numberOutOfRange": 1_000, "failed with typeMismatch": 1_000,
                ]
            ) { tc in
                let keySpace = try #draw(wireMapKeySpaces, from: tc)
                let integerKeys = try #draw(.bool(probability: 0.25), from: tc)
                let badValues = try #draw(.bool(probability: 0.6), from: tc)
                let count = try #draw(wireMapEntryCounts, from: tc)
                let entries = try #draw(
                    .array(
                        of: Hegel.zip(
                            conditionKeys(keySpace: keySpace, integerKeys: integerKeys),
                            wireMapValues(badValues: badValues)
                        )
                        .map { WireMapEntry(key: $0.0, value: $0.1) },
                        count: count...count
                    ),
                    from: tc
                )
                try recordMapEvents(entries, in: tc)
                let keys = firstOccurrences(entries).map {
                    MMPackDecoder().decode(Catalog.Condition.self, from: wireBytes($0.key.write))
                }
                if keys.contains(where: { (try? $0.get()) == nil }) {
                    try tc.event("a key that fails")
                }
                let decodedKeys = keys.compactMap { try? $0.get() }
                if Set(decodedKeys).count < decodedKeys.count {
                    try tc.event("keys that decode to the same key")
                }
                let decoded = MMPackDecoder().decode(
                    [Catalog.Condition: Int].self,
                    from: wireMap(entries)
                )
                try tc.event(outcome(decoded))
                #expect(decoded == expectedConditionKeyedMap(entries))
            }
        }
    }

#endif
