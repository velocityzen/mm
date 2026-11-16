// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOCore
    import Testing

    /// A place in a request whose value the generated code hands to
    /// `Codable`: an item's two maps and its external type, and a held
    /// shipment's map and the structure holding its external type. A
    /// `DecodingError` from one names the coding path from the request
    /// down to it. The raw value is the place's reach label.
    enum CodableSlot: String, CaseIterable, Sendable {
        case lookup = "the lookup of an item"
        case serials = "the serials of an item"
        case stamp = "the stamp of an item"
        case duties = "the duties of a held shipment"
        case customs = "the customs of a held shipment"
    }

    /// A request's `Codable` bytes with the value in one slot replaced.
    struct ReplacedSlot {
        var payload: ByteBuffer
        /// Whether the slot is in a held shipment under a split.
        var underSplit: Bool
    }

    /// Text no generator makes, so a value holding it encodes to bytes found
    /// nowhere else in a request.
    let slotSentinel = "\u{FFFE}a value the generated code hands to Codable\u{FFFE}"

    func codableBytes<Value: Encodable>(_ value: Value) throws -> [UInt8] {
        try Array(encodedThroughCodable(value).get().readableBytesView)
    }

    /// Where `needle` occurs in `bytes`.
    func occurrences(of needle: [UInt8], in bytes: [UInt8]) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= bytes.count else { return [] }
        return (0...(bytes.count - needle.count)).compactMap { start in
            bytes[start..<(start + needle.count)].elementsEqual(needle)
                ? start..<(start + needle.count) : nil
        }
    }

    /// Visits a request's shipments depth first, counting held shipments and
    /// giving the one at `target` other duties.
    struct HeldShipments {
        let target: Int
        let duties: [Int: String]
        private(set) var seen = 0
        /// The target's customs, and whether it is under a split.
        private(set) var found: (customs: Catalog.Shipment.Customs, underSplit: Bool)?

        init(target: Int, duties: [Int: String]) {
            self.target = target
            self.duties = duties
        }

        /// How many held shipments `shipments` holds at any depth.
        static func count(in shipments: [Catalog.Shipment]) -> Int {
            var counting = HeldShipments(target: -1, duties: [:])
            _ = counting.visit(shipments, depth: 0)
            return counting.seen
        }

        mutating func visit(_ shipments: [Catalog.Shipment], depth: Int) -> [Catalog.Shipment] {
            shipments.map { shipment in
                switch shipment {
                    case .held(_, let customs):
                        defer { self.seen += 1 }
                        guard self.seen == self.target else { return shipment }
                        self.found = (customs, depth > 0)
                        return .held(duties: self.duties, customs: customs)
                    case .split(let parts, let box):
                        return .split(parts: self.visit(parts, depth: depth + 1), box: box)
                    default:
                        return shipment
                }
            }
        }
    }

    /// `Codable`'s bytes for a dictionary keyed by `UInt64`, before the
    /// coders carried it as a map: an array of alternating keys and values.
    struct CodablePairs: Encodable {
        let entries: [(key: UInt64, value: String)]

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            for entry in self.entries {
                try container.encode(entry.key)
                try container.encode(entry.value)
            }
        }
    }

    extension CatalogGenerators {
        /// Bytes to put in `slot`: most often what its `Decodable`, or the
        /// coder reading a map with unsigned keys, refuses, else anything on
        /// the menu. A map with unsigned keys refuses `Codable`'s array of
        /// keys and values, a negative key, and a key that is text, each
        /// with an `MMWireError`; a map with integer keys refuses a key that
        /// is not an integer, and a seal text naming no case, each with a
        /// `DecodingError`. The rest of the menu is null, an integer, text
        /// and empty containers, which the slots refuse with an
        /// `MMWireError`. A drawn dictionary's entries come in one order,
        /// so a replay draws the same bytes.
        func slotBytes(for slot: CodableSlot) -> Gen<[UInt8]> {
            let pairs: Gen<[UInt8]> = Gen { tc in
                let keys = try tc.draw(
                    Gen<[UInt64]>.array(of: Self.unsignedKey, count: 1...3)
                )
                return try codableBytes(
                    CodablePairs(entries: keys.map { (key: $0, value: slotSentinel) })
                )
            }
            let negativeKeys: Gen<[UInt8]> = Gen { tc in
                try Array(
                    encodedInOneOrder(
                        tc.draw(
                            Gen<[Int: String]>.dictionary(
                                keys: .int(in: Int.min...(-1)),
                                values: self.text,
                                count: 1...3
                            )
                        )
                    )
                    .readableBytesView
                )
            }
            let textKeys: Gen<[UInt8]> = Gen { tc in
                try Array(
                    encodedInOneOrder(
                        tc.draw(
                            Gen<[String: String]>.dictionary(
                                keys: self.text,
                                values: self.text,
                                count: 1...3
                            )
                        )
                    )
                    .readableBytesView
                )
            }
            let seal: Gen<[UInt8]> = Gen { tc in
                try codableBytes([0: tc.draw(self.text)] as [Int: String])
            }
            let plain: Gen<[UInt8]> = Gen { tc in
                switch try tc.draw(Gen<Int>.int(in: 0...4)) {
                    case 0: try codableBytes(Int?.none)
                    case 1: try codableBytes(tc.draw(Self.integer))
                    case 2: try codableBytes(tc.draw(self.text))
                    case 3: try codableBytes([Int]())
                    default: try codableBytes([String: Int]())
                }
            }
            let anything: Gen<[UInt8]> = .oneOf(pairs, textKeys, seal, plain)
            switch slot {
                case .serials: return .oneOf(pairs, negativeKeys, textKeys, anything)
                case .duties: return .oneOf(textKeys, textKeys, anything)
                case .customs: return .oneOf(seal, seal, anything)
                case .lookup, .stamp: return anything
            }
        }

        /// `request` encoded through `Codable` with its dictionaries in one
        /// order, and the value in `slot` replaced by `replacement`. An item
        /// slot is in one of the request's items, a held shipment slot in
        /// one of its held shipments at any depth; a request without one
        /// gets one. The slot is found by its bytes: it first takes a value
        /// holding `slotSentinel`, whose encoding occurs once.
        func replacing(
            _ slot: CodableSlot,
            in request: Catalog.PutRequest,
            with replacement: [UInt8],
            _ tc: TestCase
        ) throws -> ReplacedSlot {
            var request = request
            let marker: [UInt8]
            var underSplit = false
            var after: [UInt8] = []
            switch slot {
                case .lookup, .serials, .stamp:
                    if request.items.isEmpty {
                        request.items.append(try tc.draw(self.item))
                    }
                    let index = try tc.draw(Gen<Int>.int(in: 0...(request.items.count - 1)))
                    switch slot {
                        case .lookup:
                            request.items[index].lookup = [slotSentinel: 0]
                            marker = try codableBytes(request.items[index].lookup)
                        case .serials:
                            request.items[index].serials = [0: slotSentinel]
                            marker = try codableBytes(request.items[index].serials)
                        default:
                            request.items[index].stamp = GeneratedCodingStamp(
                                author: slotSentinel,
                                level: 0
                            )
                            marker = try codableBytes(request.items[index].stamp)
                    }
                case .duties, .customs:
                    var shipments = request.shipments ?? []
                    if HeldShipments.count(in: shipments) == 0 {
                        shipments.append(try tc.draw(self.held))
                    }
                    let count = HeldShipments.count(in: shipments)
                    var held = HeldShipments(
                        target: try tc.draw(Gen<Int>.int(in: 0...(count - 1))),
                        duties: [0: slotSentinel]
                    )
                    request.shipments = held.visit(shipments, depth: 0)
                    let found = try #require(held.found)
                    underSplit = found.underSplit
                    marker = try codableBytes(held.duties)
                    if slot == .customs {
                        // The customs follow the duties, under key 1.
                        after = try [1] + codableBytes(found.customs)
                    }
            }
            var bytes = try Array(encodedInOneOrder(request).readableBytesView)
            let marked = try #require(occurrences(of: marker, in: bytes).only)
            var range = marked
            if !after.isEmpty {
                let end = marked.upperBound + after.count
                try #require(
                    end <= bytes.count && bytes[marked.upperBound..<end].elementsEqual(after)
                )
                // The customs value, past its key.
                range = (marked.upperBound + 1)..<end
            }
            bytes.replaceSubrange(range, with: replacement)
            return ReplacedSlot(payload: ByteBuffer(bytes: bytes), underSplit: underSplit)
        }
    }

    extension Array {
        /// The one element, or nil when there are none or several.
        var only: Element? { self.count == 1 ? self[0] : nil }
    }

#endif
