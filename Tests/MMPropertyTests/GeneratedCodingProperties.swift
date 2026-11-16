// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOCore
    import Testing

    func bitwise(_ item: Catalog.Item) -> Bitwise<Catalog.Item> {
        var value = item
        value.price = 0
        value.weight = 0
        return Bitwise(
            value: value,
            floatBits: [item.price.bitPattern, UInt64(item.weight.bitPattern)]
        )
    }

    func bitwise(_ request: Catalog.PutRequest) -> Bitwise<Catalog.PutRequest> {
        let items = request.items.map(bitwise)
        var value = request
        value.items = items.map(\.value)
        return Bitwise(value: value, floatBits: items.flatMap(\.floatBits))
    }

    /// One change to a payload. Positions wrap around the payload's length
    /// at the time of the change, so any position applies to any payload.
    enum Mutation: Sendable {
        case replace(at: Int, with: UInt8)
        case insert(UInt8, at: Int)
        case remove(at: Int)
    }

    let replacement: Gen<Mutation> = Hegel.zip(.int(in: 0...Int.max), Gen<UInt8>.integer())
        .map { .replace(at: $0, with: $1) }

    /// Any number of replaced, inserted and removed bytes, at least one, or
    /// often one replaced byte: that keeps every length header right, so
    /// more of those payloads still decode.
    let mutations: Gen<[Mutation]> = .oneOf(
        .array(
            of: .oneOf(
                replacement,
                Hegel.zip(Gen<UInt8>.integer(), .int(in: 0...Int.max)).map { .insert($0, at: $1) },
                Gen<Int>.int(in: 0...Int.max).map { .remove(at: $0) }
            ),
            count: 1...Int.max
        ),
        replacement.map { [$0] }
    )

    func mutated(_ bytes: [UInt8], by mutations: [Mutation]) -> [UInt8] {
        var bytes = bytes
        for mutation in mutations {
            switch mutation {
                case .replace(let position, let byte):
                    guard !bytes.isEmpty else { continue }
                    bytes[position % bytes.count] = byte
                case .insert(let byte, let position):
                    bytes.insert(byte, at: position % (bytes.count + 1))
                case .remove(let position):
                    guard !bytes.isEmpty else { continue }
                    bytes.remove(at: position % bytes.count)
            }
        }
        return bytes
    }

    /// Any length shorter than `byteCount`, often the empty prefix, the
    /// longest one, or half.
    func prefixLengths(below byteCount: Int) -> Gen<Int> {
        .oneOf(
            .element(of: [0, byteCount - 1, byteCount / 2]),
            .int(in: 0...byteCount - 1)
        )
    }

    /// The smallest container nesting limit under which `bytes` skips as one
    /// MessagePack value, found by bisecting the limits up to the decoders'
    /// default of 128.
    func nestingDepth(of bytes: ByteBuffer) -> Int {
        var tooShallow = -1
        var deepEnough = 128
        while deepEnough - tooShallow > 1 {
            let middle = (tooShallow + deepEnough) / 2
            var reader = bytes
            if case .success = reader.skipMessagePackValue(maxDepth: middle) {
                deepEnough = middle
            } else {
                tooShallow = middle
            }
        }
        return deepEnough
    }

    /// Any nesting limit, often one below, at or above `depth`, and often
    /// anywhere below it, so a share of cases fails however deep the drawn
    /// values nest.
    func nestingLimits(around depth: Int) -> Gen<Int> {
        .oneOf(
            .element(of: [depth - 1, depth, depth + 1]),
            .int(in: 0...max(0, depth - 1)),
            .int(in: 0...128),
            .int()
        )
    }

    /// A decode's outcome as a constant label for the statistics report: the
    /// error's case without its values.
    func outcome<Value>(_ result: Result<Value, MMWireError>) -> String {
        switch result {
            case .success: "decoded"
            case .failure(let error):
                "failed with \(String(describing: error).prefix { $0 != "(" })"
        }
    }

    @Suite("Generated MessagePack code agrees with Codable", .hegel, .offTheCooperativePool)
    struct GeneratedCodingProperties {
        /// The generated code writes exactly the bytes Codable writes, for a
        /// whole request and for one item.
        ///
        /// Mutation-checked: generated code writing a `UInt64` as an `Int64`
        /// fails this once a value is above `Int64.max`.
        @Test
        func writesTheSameBytes() throws {
            try property(
                reaching: [
                    "a binary past bin8", "a collection past fixarray or fixmap",
                    "a string past fixstr", "a string past str8",
                ]
            ) { tc in
                let shape = try #draw(CatalogGenerators.shapes, from: tc)
                let generators = CatalogGenerators(shape)
                let request = try #draw(generators.putRequest, from: tc)
                try recordSizes(of: request, in: tc)
                #expect(encodedThroughGeneratedCode(request) == encodedThroughCodable(request))
                let item = try #draw(generators.item, from: tc)
                #expect(encodedThroughGeneratedCode(item) == encodedThroughCodable(item))
            }
        }

        /// An optional of a generated type is generated too: it writes
        /// Codable's bytes, and both paths read it back, absent or present.
        @Test
        func optionalPayloads() throws {
            try property(reaching: ["present"], reachingAfter: ["absent": 1_000]) { tc in
                let shape = try #draw(CatalogGenerators.shapes, from: tc)
                let item = try #draw(.optional(CatalogGenerators(shape).item), from: tc)
                try tc.event(item == nil ? "absent" : "present")
                #expect(encodedThroughGeneratedCode(item) == encodedThroughCodable(item))
                let bytes = try encodedThroughCodable(item).get()
                let expected = Result<_, MMWireError>.success(item.map(bitwise))
                #expect(
                    decodedThroughGeneratedCode(Catalog.Item?.self, from: bytes).map {
                        $0.map(bitwise)
                    }
                        == expected
                )
                #expect(
                    decodedThroughCodable(Catalog.Item?.self, from: bytes).map { $0.map(bitwise) }
                        == expected
                )
            }
        }

        /// Both paths read back what the generated code writes, float bits
        /// included.
        ///
        /// Mutation-checked: a fixarray header written for 16 elements fails
        /// this, and `optionalPayloads` too.
        @Test
        func decodesWhatItWrites() throws {
            try property(
                reaching: [
                    "a binary past bin8", "a collection past fixarray or fixmap",
                    "a string past fixstr", "a string past str8",
                ],
                reachingAfter: ["flag holds an absent optional": 1_000]
            ) { tc in
                let shape = try #draw(CatalogGenerators.shapes, from: tc)
                let request = try #draw(CatalogGenerators(shape).putRequest, from: tc)
                try recordSizes(of: request, in: tc)
                let bytes = try encodedThroughGeneratedCode(request).get()
                // An optional of an optional holding nil writes a plain nil, which
                // reads back as absent: Codable flattens it, and so does the
                // generated code.
                var expected = request
                if case .some(.none) = request.flag {
                    try tc.event("flag holds an absent optional")
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

        /// No path decodes a strict prefix of a request's bytes, and both fail
        /// on it with the same error.
        @Test
        func truncatedPayloadsFailTheSameWay() throws {
            try property(reaching: ["failed with truncated"]) { tc in
                let shape = try #draw(CatalogGenerators.shapes, from: tc)
                let request = try #draw(CatalogGenerators(shape).putRequest, from: tc)
                let bytes = try encodedThroughCodable(request).get()
                let length = try #draw(prefixLengths(below: bytes.readableBytes), from: tc)
                let prefix = try #require(bytes.getSlice(at: bytes.readerIndex, length: length))
                let generated = decodedThroughGeneratedCode(Catalog.PutRequest.self, from: prefix)
                let codable = decodedThroughCodable(Catalog.PutRequest.self, from: prefix)
                try tc.event(outcome(generated))
                #expect(generated.map(bitwise) == codable.map(bitwise), "\(hex(prefix))")
                if case .success = generated {
                    Issue.record(
                        "the generated code decoded \(length) of \(bytes.readableBytes) bytes"
                    )
                }
                if case .success = codable {
                    Issue.record("Codable decoded \(length) of \(bytes.readableBytes) bytes")
                }
            }
        }

        /// Both paths decode a request with any bytes replaced, inserted or
        /// removed to the same value, or fail on it with the same error.
        @Test
        func corruptedPayloadsDecodeOrFailTheSameWay() throws {
            try property(
                reachingAfter: [
                    "decoded": 1_000, "failed with invalidUTF8": 1_000,
                    "failed with keyNotFound": 1_000, "failed with truncated": 1_000,
                    "failed with typeMismatch": 1_000,
                ]
            ) { tc in
                let shape = try #draw(CatalogGenerators.shapes, from: tc)
                let request = try #draw(CatalogGenerators(shape).putRequest, from: tc)
                let bytes = try Array(encodedThroughCodable(request).get().readableBytesView)
                let changes = try #draw(mutations, from: tc)
                let corrupted = ByteBuffer(bytes: mutated(bytes, by: changes))
                let generated = decodedThroughGeneratedCode(
                    Catalog.PutRequest.self,
                    from: corrupted
                )
                try tc.event(outcome(generated))
                #expect(
                    generated.map(bitwise)
                        == decodedThroughCodable(Catalog.PutRequest.self, from: corrupted).map(
                            bitwise
                        ),
                    "\(hex(corrupted))"
                )
            }
        }

        /// Both paths decode a request with other bytes in a place where the
        /// generated code hands the value to `Codable` to the same value, or
        /// fail on it with the same error: a `DecodingError` names the same
        /// coding path. The place is an item's maps or external type, or a
        /// held shipment's map or the structure holding its external type,
        /// at any depth of splits. The bytes are most often what the
        /// place's `Decodable` refuses with a `DecodingError`, which
        /// `corruptedPayloadsDecodeOrFailTheSameWay` reaches in a few cases
        /// in a thousand. An item's serials refuse with an `MMWireError`
        /// instead: the coder reads their integer keys itself.
        ///
        /// Mutation check: `readField` leaving the coding path as it is or
        /// putting the key at its end; generated code reading a union
        /// case's fields without the union's `fields` key; or the generator
        /// reading a map, an external type, a structure, a reference, an
        /// array or an optional without `readField`, fails here.
        @Test
        func decodingErrorsNameTheSamePath() throws {
            try property(
                reaching: ["failed with decodingFailed"],
                reachingAfter: Dictionary(
                    uniqueKeysWithValues: (CodableSlot.allCases.map(\.rawValue) + [
                        "a held shipment under a split", "failed with keyNotFound",
                        "failed with typeMismatch",
                    ])
                    .map { ($0, 1_000) }
                )
            ) { tc in
                // Sizes Hegel chooses: boundary sizes pick header formats,
                // which name no path, and make the largest requests.
                let shipmentDepth = try #draw(Gen<Int>.element(of: [0, 3, 32]), from: tc)
                let generators = CatalogGenerators(
                    CatalogShape(boundaryRate: 0, shipmentDepth: shipmentDepth)
                )
                let request = try #draw(generators.putRequest, from: tc)
                // Half the time a slot whose `Decodable` can refuse with a
                // `DecodingError`: the others' coder refuses first.
                let slot = try #draw(
                    Gen<CodableSlot>.oneOf(.allCases, .element(of: [.duties, .customs, .stamp])),
                    from: tc
                )
                let replacement = try #draw(generators.slotBytes(for: slot), from: tc)
                let replaced = try generators.replacing(slot, in: request, with: replacement, tc)
                try tc.event(slot.rawValue)
                if replaced.underSplit {
                    try tc.event("a held shipment under a split")
                }
                let generated = decodedThroughGeneratedCode(
                    Catalog.PutRequest.self,
                    from: replaced.payload
                )
                try tc.event(outcome(generated))
                #expect(
                    generated.map(bitwise)
                        == decodedThroughCodable(Catalog.PutRequest.self, from: replaced.payload)
                        .map(bitwise),
                    "\(hex(replaced.payload))"
                )
            }
        }

        /// Under any container nesting limit, both paths decode a request to
        /// the same value or fail on it with the same error.
        ///
        /// Mutation-checked: the generated reader rejecting a map one level
        /// early fails this at the request's own depth. A guard one level
        /// too loose can't fail it: before reading a struct's fields, the
        /// generated code skips each value with the depth-checked skip,
        /// which rejects any container past the limit first.
        @Test
        func nestingLimitsFailTheSameWay() throws {
            try property(
                reaching: ["decoded", "failed with nestingTooDeep"],
                reachingAfter: [
                    "limit at the request's depth": 1_000,
                    "limit one below the request's depth": 1_000,
                ]
            ) { tc in
                let shape = try #draw(CatalogGenerators.shapes, from: tc)
                let request = try #draw(CatalogGenerators(shape).putRequest, from: tc)
                let bytes = try encodedThroughCodable(request).get()
                let depth = nestingDepth(of: bytes)
                let maxDepth = try #draw(nestingLimits(around: depth), from: tc)
                try tc.event("request nesting depth", value: Double(depth))
                if maxDepth == depth - 1 {
                    try tc.event("limit one below the request's depth")
                }
                if maxDepth == depth {
                    try tc.event("limit at the request's depth")
                }
                let generated = decodedThroughGeneratedCode(
                    Catalog.PutRequest.self,
                    from: bytes,
                    maxDepth: maxDepth
                )
                try tc.event(outcome(generated))
                #expect(
                    generated.map(bitwise)
                        == decodedThroughCodable(
                            Catalog.PutRequest.self,
                            from: bytes,
                            maxDepth: maxDepth
                        )
                        .map(bitwise),
                    "\(hex(bytes))"
                )
            }
        }
    }

#endif
