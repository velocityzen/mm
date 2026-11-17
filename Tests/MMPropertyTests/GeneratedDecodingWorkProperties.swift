// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    @testable import MMSchema
    @testable import MMWire
    import NIOCore
    import Testing

    /// Thrown by ``CountingReader`` once a decode has made more reads than
    /// its budget.
    struct ReadBudgetExceeded: Error {}

    /// A reader that counts the reads a decode makes through it, and fails
    /// every read past `budget`: a decode that would make many times more
    /// reads than its payload has bytes stops at the budget instead of
    /// running for minutes.
    struct CountingReader<Base: MMPackReader>: MMPackReader {
        var base: Base
        let budget: Int
        private(set) var reads = 0

        init(_ base: Base, budget: Int) {
            self.base = base
            self.budget = budget
        }

        private mutating func counting() throws {
            self.reads += 1
            if self.reads > self.budget {
                throw ReadBudgetExceeded()
            }
        }

        var position: Int { self.base.position }

        mutating func seek(to position: Int) {
            self.reads += 1
            self.base.seek(to: position)
        }

        mutating func seek(toRequiredField position: Int?, key: Int) throws {
            try self.counting()
            try self.base.seek(toRequiredField: position, key: key)
        }

        mutating func readNil() -> Bool {
            self.reads += 1
            return self.base.readNil()
        }

        mutating func readBool() throws -> Bool {
            try self.counting()
            return try self.base.readBool()
        }

        mutating func readInt() throws -> Int {
            try self.counting()
            return try self.base.readInt()
        }

        mutating func readUInt() throws -> UInt64 {
            try self.counting()
            return try self.base.readUInt()
        }

        mutating func readFloat() throws -> Float {
            try self.counting()
            return try self.base.readFloat()
        }

        mutating func readDouble() throws -> Double {
            try self.counting()
            return try self.base.readDouble()
        }

        mutating func readString() throws -> String {
            try self.counting()
            return try self.base.readString()
        }

        mutating func readBytes() throws -> MMBytes {
            try self.counting()
            return try self.base.readBytes()
        }

        mutating func readDate() throws -> MMDate {
            try self.counting()
            return try self.base.readDate()
        }

        mutating func readDateTime() throws -> MMDateTime {
            try self.counting()
            return try self.base.readDateTime()
        }

        mutating func readTimestamp() throws -> MMTimestamp {
            try self.counting()
            return try self.base.readTimestamp()
        }

        mutating func readDuration() throws -> MMDuration {
            try self.counting()
            return try self.base.readDuration()
        }

        mutating func readUUID() throws -> MMUUID {
            try self.counting()
            return try self.base.readUUID()
        }

        mutating func readArrayHeader(depth: Int) throws -> Int {
            try self.counting()
            return try self.base.readArrayHeader(depth: depth)
        }

        mutating func readMapHeader(depth: Int) throws -> Int {
            try self.counting()
            return try self.base.readMapHeader(depth: depth)
        }

        mutating func readMapKey(depth: Int) throws -> MMPackMapKey {
            try self.counting()
            return try self.base.readMapKey(depth: depth)
        }

        mutating func skipValue(depth: Int) throws {
            try self.counting()
            try self.base.skipValue(depth: depth)
        }

        mutating func readRawValue(depth: Int) throws -> MMPackRawValue {
            try self.counting()
            return try self.base.readRawValue(depth: depth)
        }

        mutating func readDecodable<Value: Decodable>(_ type: Value.Type, depth: Int) throws
            -> Value
        {
            try self.counting()
            return try self.base.readDecodable(type, depth: depth)
        }
    }

    /// A payload's maps after a drawn reshaping: entries in another order,
    /// a key repeated holding nil, and one value replaced by another of any
    /// family.
    struct PayloadReshaping {
        let tc: TestCase
        let reorderRate: Double
        let repeatRate: Double
        /// The pre-order index of the value to replace, if any.
        let replaced: Int?
        let replacement: PackValue
        private var index = 0
        /// How many maps hold the deepest map whose entries changed order.
        private(set) var deepestReorder: Int?
        /// How many maps hold the replaced value.
        private(set) var replacedUnder: Int?
        private(set) var repeatedKey = false

        init(
            _ tc: TestCase,
            reorderRate: Double,
            repeatRate: Double,
            replaced: Int?,
            replacement: PackValue
        ) {
            self.tc = tc
            self.reorderRate = reorderRate
            self.repeatRate = repeatRate
            self.replaced = replaced
            self.replacement = replacement
        }

        /// How many values `value` holds, itself included; map keys are not
        /// counted.
        static func count(_ value: PackValue) -> Int {
            switch value {
                case .array(let elements): 1 + elements.map(count).reduce(0, +)
                case .map(let entries): 1 + entries.map { count($0.value) }.reduce(0, +)
                default: 1
            }
        }

        /// `value`, held by `maps` maps, reshaped.
        mutating func reshaping(_ value: PackValue, under maps: Int) throws -> PackValue {
            let index = self.index
            self.index += 1
            if index == self.replaced {
                self.replacedUnder = maps
                // The values it held are not visited: keep the count in step.
                self.index += Self.count(value) - 1
                return self.replacement
            }
            switch value {
                case .array(let elements):
                    var reshaped: [PackValue] = []
                    for element in elements {
                        reshaped.append(try self.reshaping(element, under: maps))
                    }
                    return .array(reshaped)
                case .map(let entries):
                    var reshaped: [PackEntry] = []
                    for entry in entries {
                        reshaped.append(
                            PackEntry(
                                key: entry.key,
                                value: try self.reshaping(entry.value, under: maps + 1)
                            )
                        )
                    }
                    if reshaped.count >= 2, self.reorderRate > 0,
                        try self.tc.draw(Gen<Bool>.bool(probability: self.reorderRate))
                    {
                        let reordered = try FingerprintGenerators.shuffled(reshaped, self.tc)
                        if reordered != reshaped {
                            self.deepestReorder = max(self.deepestReorder ?? 0, maps)
                        }
                        reshaped = reordered
                    }
                    if !reshaped.isEmpty, self.repeatRate > 0,
                        try self.tc.draw(Gen<Bool>.bool(probability: self.repeatRate))
                    {
                        // The key again, holding nil: a copy of its value would
                        // copy the copies below it, doubling the payload at
                        // every level.
                        let repeated = reshaped[
                            try self.tc.draw(.int(in: 0...(reshaped.count - 1)))
                        ]
                        reshaped.insert(
                            PackEntry(key: repeated.key, value: .null),
                            at: try self.tc.draw(.int(in: 0...reshaped.count))
                        )
                        self.repeatedKey = true
                    }
                    return .map(reshaped)
                default:
                    return value
            }
        }
    }

    /// A value of one of the catalog's recursive types, often nested many
    /// levels deep, or a whole request.
    enum DecodingWorkPayload: Sendable {
        case shipment(Catalog.Shipment)
        case part(Catalog.Part)
        case request(Catalog.PutRequest)
    }

    enum DecodingWorkGenerators {
        /// How many more levels a drawn shipment or part is wrapped in: none,
        /// or enough to put it under a dozen maps or more. The nesting limit
        /// allows about forty.
        static let chains: Gen<Int> = .element(of: [0, 8, 30])

        static let replacements: Gen<PackValue> = .element(of: [
            .null, .integer(-1), .string(utf8: Array("x".utf8)), .map([]), .array([]), .bool(true),
        ])

        static func payloads(_ generators: CatalogGenerators) -> Gen<DecodingWorkPayload> {
            .oneOf(
                Gen { tc in
                    var shipment = try tc.draw(generators.shipment)
                    for _ in 0..<(try tc.draw(chains)) {
                        shipment = try tc.draw(holding(shipment, generators))
                    }
                    return .shipment(shipment)
                },
                Gen { tc in
                    var part = try tc.draw(generators.part)
                    for _ in 0..<(try tc.draw(chains)) {
                        part = try tc.draw(holding(part, generators))
                    }
                    return .part(part)
                },
                generators.putRequest.map(DecodingWorkPayload.request)
            )
        }

        /// A shipment holding `shipment`: in a split, reissued, or rerouted.
        static func holding(
            _ shipment: Catalog.Shipment,
            _ generators: CatalogGenerators
        ) -> Gen<Catalog.Shipment> {
            .oneOf(
                Gen { tc in
                    try .split(parts: [shipment], box: .init(label: tc.draw(generators.text)))
                },
                Gen { tc in
                    try .reissued(original: shipment, reason: tc.draw(.optional(generators.text)))
                },
                .just(.rerouted(via: .init(next: shipment)))
            )
        }

        /// A part holding `part`: as its spare, its assembly's base, or one
        /// of its assembly's parts.
        static func holding(_ part: Catalog.Part, _ generators: CatalogGenerators) -> Gen<
            Catalog.Part
        > {
            .oneOf(
                Gen { tc in
                    try Catalog.Part(
                        name: tc.draw(generators.text),
                        assembly: nil,
                        spare: .init(part: part)
                    )
                },
                Gen { tc in
                    try Catalog.Part(
                        name: tc.draw(generators.text),
                        assembly: .init(base: part, parts: []),
                        spare: .init(part: nil)
                    )
                },
                Gen { tc in
                    try Catalog.Part(
                        name: tc.draw(generators.text),
                        assembly: .init(
                            base: Catalog.Part(name: "", assembly: nil, spare: .init(part: nil)),
                            parts: [part]
                        ),
                        spare: .init(part: nil)
                    )
                }
            )
        }
    }

    @Suite("Generated decoding work", .hegel, .offTheCooperativePool)
    struct GeneratedDecodingWorkProperties {
        /// Generated decoding makes at most eight reads per payload byte,
        /// whatever order a payload's maps hold their entries in, a key
        /// repeated, or a value replaced at any depth: so a value nested in
        /// many maps that each take the walk-first path is read once, not
        /// once for each path of each map above it. And within that bound
        /// it decodes to what `Decodable` decodes, or fails with its error.
        ///
        /// Mutation check: the walk-first path reading a field again
        /// instead of taking what the in-order path noted fails here, at a
        /// payload a few levels deep.
        @Test
        func decodingReadsEachValueOnce() throws {
            try property(
                reaching: [
                    "a map in another order", "a repeated key", "a value replaced", "decoded",
                    "failed",
                ],
                reachingAfter: [
                    "a map in another order under 12 others": 1_000,
                    "a value replaced under 12 maps": 1_000,
                ]
            ) { tc in
                let shape = try #draw(CatalogGenerators.shapes, from: tc)
                let payload = try #draw(
                    DecodingWorkGenerators.payloads(CatalogGenerators(shape)),
                    from: tc
                )
                let encoded: ByteBuffer
                switch payload {
                    case .shipment(let shipment):
                        encoded = try encodedThroughGeneratedCode(shipment).get()
                    case .part(let part): encoded = try encodedThroughGeneratedCode(part).get()
                    case .request(let request):
                        encoded = try encodedThroughGeneratedCode(request).get()
                }
                var buffer = encoded
                let tree = try readPackValue(from: &buffer, maxDepth: 1_000).get()
                let reorderRate = try #draw(Gen<Double>.element(of: [0, 0.5, 1]), from: tc)
                let repeatRate = try #draw(Gen<Double>.element(of: [0, 0.1]), from: tc)
                let replaced = try #draw(
                    Gen<Int?>.optional(.int(in: 0...(PayloadReshaping.count(tree) - 1))),
                    from: tc
                )
                let replacement = try #draw(DecodingWorkGenerators.replacements, from: tc)
                var reshaping = PayloadReshaping(
                    tc,
                    reorderRate: reorderRate,
                    repeatRate: repeatRate,
                    replaced: replaced,
                    replacement: replacement
                )
                let reshaped = try reshaping.reshaping(tree, under: 0)
                if let maps = reshaping.deepestReorder {
                    try tc.event("a map in another order")
                    if maps >= 12 { try tc.event("a map in another order under 12 others") }
                }
                if let maps = reshaping.replacedUnder {
                    try tc.event("a value replaced")
                    if maps >= 12 { try tc.event("a value replaced under 12 maps") }
                }
                if reshaping.repeatedKey {
                    try tc.event("a repeated key")
                }
                var bytes = ByteBuffer()
                writePackValue(reshaped, into: &bytes)
                switch payload {
                    case .shipment: try checkReads(Catalog.Shipment.self, bytes, tc, same: ==)
                    case .part: try checkReads(Catalog.Part.self, bytes, tc, same: ==)
                    case .request:
                        try checkReads(Catalog.PutRequest.self, bytes, tc) {
                            $0.map(bitwise) == $1.map(bitwise)
                        }
                }
            }
        }

        /// Decodes `bytes` through `type`'s generated code with a budget of
        /// eight reads per byte, and checks that the decode stays in it and
        /// agrees with `Decodable` there.
        private func checkReads<T: MMPackDecodable>(
            _ type: T.Type,
            _ bytes: ByteBuffer,
            _ tc: TestCase,
            same: (Result<T, MMWireError>, Result<T, MMWireError>) -> Bool
        ) throws {
            let budget = 8 * bytes.readableBytes
            var reader = CountingReader(MPGeneratedReader(buffer: bytes, cap: 128), budget: budget)
            let generated = Result { try T(mmPack: &reader, depth: 0) }
            try tc.event(
                "reads per payload byte",
                value: Double(reader.reads) / Double(bytes.readableBytes)
            )
            let outcome = if case .success = generated { "decoded" } else { "failed" }
            try tc.event(outcome)
            #expect(
                reader.reads <= budget,
                "\(reader.reads) reads for \(bytes.readableBytes) bytes"
            )
            guard reader.reads <= budget else { return }
            let wireError = generated.mapError { error in
                error as? MMWireError ?? .decodingFailed(description: String(describing: error))
            }
            #expect(same(wireError, decodedThroughCodable(type, from: bytes)), "\(hex(bytes))")
        }
    }

#endif
