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
        return Bitwise(value: value, floatBits: [item.price.bitPattern, UInt64(item.weight.bitPattern)])
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

    /// Any number of replaced, inserted and removed bytes.
    let mutations: Gen<[Mutation]> = .array(
        of: .oneOf(
            Hegel.zip(.int(in: 0...Int.max), Gen<UInt8>.integer()).map { .replace(at: $0, with: $1) },
            Hegel.zip(Gen<UInt8>.integer(), .int(in: 0...Int.max)).map { .insert($0, at: $1) },
            Gen<Int>.int(in: 0...Int.max).map { .remove(at: $0) }
        ),
        count: 1...Int.max
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

    @Suite("Generated MessagePack code agrees with Codable", .hegel)
    struct GeneratedCodingProperties {
        @Test(.hegel(testCases: 300))
        func writesTheSameBytes() throws {
            try property { tc in
                let request = try #draw(CatalogGenerators.putRequest, from: tc)
                #expect(encodedThroughGeneratedCode(request) == encodedThroughCodable(request))
                let item = try #draw(CatalogGenerators.item, from: tc)
                #expect(encodedThroughGeneratedCode(item) == encodedThroughCodable(item))
            }
        }

        /// An optional of a generated type is generated too, with Codable's bytes.
        @Test(.hegel(testCases: 300))
        func optionalPayloads() throws {
            try property { tc in
                let item = try #draw(.optional(CatalogGenerators.item), from: tc)
                #expect(encodedThroughGeneratedCode(item) == encodedThroughCodable(item))
                let bytes = try encodedThroughCodable(item).get()
                let expected = Result<_, MMWireError>.success(item.map(bitwise))
                #expect(
                    decodedThroughGeneratedCode(Catalog.Item?.self, from: bytes).map { $0.map(bitwise) }
                        == expected
                )
                #expect(
                    decodedThroughCodable(Catalog.Item?.self, from: bytes).map { $0.map(bitwise) }
                        == expected
                )
            }
        }

        @Test(.hegel(testCases: 300))
        func decodesWhatItWrites() throws {
            try property { tc in
                let request = try #draw(CatalogGenerators.putRequest, from: tc)
                let bytes = try encodedThroughGeneratedCode(request).get()
                // An optional of an optional holding nil writes a plain nil, which
                // reads back as absent: Codable flattens it, and so does the
                // generated code.
                var expected = request
                if case .some(.none) = request.flag { expected.flag = nil }
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

        /// Decoding every prefix costs the square of the payload's size, and a
        /// request can run to hundreds of KB, so a case can take seconds: slow
        /// by design, not a slow generator.
        @Test(.hegel(testCases: 300, suppressHealthChecks: .tooSlow))
        func everyTruncationFailsTheSameWay() throws {
            try property { tc in
                let request = try #draw(CatalogGenerators.putRequest, from: tc)
                let bytes = try encodedThroughCodable(request).get()
                for length in 0..<bytes.readableBytes {
                    let prefix = try #require(bytes.getSlice(at: bytes.readerIndex, length: length))
                    #expect(
                        decodedThroughGeneratedCode(Catalog.PutRequest.self, from: prefix).map(bitwise)
                            == decodedThroughCodable(Catalog.PutRequest.self, from: prefix).map(bitwise),
                        "prefix of \(length) bytes: \(hex(prefix))"
                    )
                }
            }
        }

        @Test(.hegel(testCases: 1_000))
        func corruptedPayloadsDecodeOrFailTheSameWay() throws {
            try property { tc in
                let request = try #draw(CatalogGenerators.putRequest, from: tc)
                let bytes = try Array(encodedThroughCodable(request).get().readableBytesView)
                let changes = try #draw(mutations, from: tc)
                let corrupted = ByteBuffer(bytes: mutated(bytes, by: changes))
                #expect(
                    decodedThroughGeneratedCode(Catalog.PutRequest.self, from: corrupted).map(bitwise)
                        == decodedThroughCodable(Catalog.PutRequest.self, from: corrupted).map(bitwise),
                    "\(hex(corrupted))"
                )
            }
        }

        @Test(.hegel(testCases: 300))
        func nestingLimitsFailAtTheSameDepth() throws {
            try property { tc in
                let request = try #draw(CatalogGenerators.putRequest, from: tc)
                let bytes = try encodedThroughCodable(request).get()
                // Every limit up to the default, until both paths have decoded
                // within one and the next: past those, every limit reads the
                // same as the default.
                var decodedWithin: Int?
                for maxDepth in 0...128 {
                    let generated = decodedThroughGeneratedCode(
                        Catalog.PutRequest.self,
                        from: bytes,
                        maxDepth: maxDepth
                    )
                    let codable = decodedThroughCodable(
                        Catalog.PutRequest.self,
                        from: bytes,
                        maxDepth: maxDepth
                    )
                    #expect(
                        generated.map(bitwise) == codable.map(bitwise),
                        "maxDepth \(maxDepth): \(hex(bytes))"
                    )
                    if let decodedWithin, maxDepth > decodedWithin {
                        break
                    }
                    if case .success = generated, case .success = codable {
                        decodedWithin = maxDepth
                    }
                }
            }
        }
    }

#endif
