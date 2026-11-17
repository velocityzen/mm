// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import MMWire
    import NIOCore
    import Testing

    #if canImport(Foundation)
        import Foundation
    #endif

    /// The identifier's 16 bytes, read from its halves by the platform's
    /// own byte order conversion.
    func modelUUIDBytes(_ value: MMUUID) -> [UInt8] {
        withUnsafeBytes(of: value.high.bigEndian, Array.init)
            + withUnsafeBytes(of: value.low.bigEndian, Array.init)
    }

    /// The canonical text RFC 9562 gives: the 32 lowercase hexadecimal
    /// digits of the value in groups of 8, 4, 4, 4 and 12.
    func canonicalUUIDText(_ value: MMUUID) -> String {
        let digits = [value.high, value.low].map { half in
            let text = String(half, radix: 16)
            return String(repeating: "0", count: 16 - text.count) + text
        }.joined()
        var groups: [Substring] = []
        var rest = Substring(digits)
        for length in [8, 4, 4, 4, 12] {
            groups.append(rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        return groups.joined(separator: "-")
    }

    /// What the grammar says text parses to: the value its digits spell
    /// when it is 8-4-4-4-12 hexadecimal digits in either case joined by
    /// hyphens, and nothing for every other text.
    func modelUUID(_ text: String) -> MMUUID? {
        let grammar =
            /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
        // Scalar by scalar, as the parser reads bytes: a combining mark is
        // a character of its own, never part of a digit's.
        guard text.wholeMatch(of: grammar.matchingSemantics(.unicodeScalar)) != nil else {
            return nil
        }
        let digits = text.filter { $0 != "-" }
        guard
            let high = UInt64(digits.prefix(16), radix: 16),
            let low = UInt64(digits.suffix(16), radix: 16)
        else { return nil }
        return MMUUID(high: high, low: low)
    }

    /// One way to make text that may break the grammar. Some breaks can
    /// leave grammatical text (a digit replaced by another digit), so the
    /// model, not the break, says what parses.
    enum UUIDTextBreak: String, CaseIterable, Sendable {
        case upperCase = "upper case"
        case mixedCase = "mixed case"
        case digitReplaced = "a digit replaced"
        case hyphenReplaced = "a hyphen replaced"
        case hyphenMoved = "a hyphen moved"
        case characterDropped = "a character dropped"
        case characterAdded = "a character added"
        case noHyphens = "no hyphens"
        case braces = "braces"
        case urnPrefix = "a URN prefix"
        case combiningMark = "a combining mark"
        case surroundingSpace = "surrounding space"
        case nearTheGrammar = "near the grammar"
        case anyText = "any text"
    }

    struct UUIDText: Sendable, CustomStringConvertible {
        var text: String
        var textBreak: UUIDTextBreak?
        var description: String { text.debugDescription }
    }

    /// Bytes for the MessagePack decoder, with what they should decode to.
    struct UUIDWireInput: Sendable, CustomStringConvertible {
        var kind: String
        var bytes: [UInt8]
        var expected: MMUUID?
        var description: String { "\(kind): \(bytes)" }
    }

    /// Two identifiers to compare, and how the second was made.
    struct UUIDPair: Sendable {
        var kind: String
        var first: MMUUID
        var second: MMUUID
    }

    /// A random number generator that hands out drawn values in turn.
    struct ScriptedRandomNumberGenerator: RandomNumberGenerator {
        var values: [UInt64]
        var index = 0

        mutating func next() -> UInt64 {
            defer { index += 1 }
            return values[index % values.count]
        }
    }

    enum UUIDGenerators {
        /// Half an identifier: any 64 bits, or one from a menu of edges (no
        /// bits, all bits, the top bit, the version nibble's place, the
        /// variant's two bits), or a single bit set.
        static let halves: Gen<UInt64> = .oneOf(
            .integer(),
            .element(of: [
                0, 1, .max, .max - 1, 1 << 63, (1 << 63) - 1, 0xF000, 0x4000,
                0xC000_0000_0000_0000, 0x8000_0000_0000_0000,
            ]),
            Gen<Int>.integer(in: 0...63).map { 1 << $0 }
        )

        /// Any identifier, the Nil and the Max UUID often.
        static let uuids: Gen<MMUUID> = .oneOf(
            Hegel.zip(halves, halves).map { MMUUID(high: $0, low: $1) },
            Hegel.zip(halves, halves).map { MMUUID(high: $0, low: $1) },
            .element(of: [MMUUID.zero, MMUUID(high: .max, low: .max)])
        )

        /// The offsets of the hyphens in the text form.
        static let hyphenOffsets = [8, 13, 18, 23]

        /// Characters to put in a digit's place: the edges of each digit
        /// range and their neighbors outside it, and characters a parser
        /// might take for a digit.
        static let digitReplacements: [Character] = [
            "0", "9", "a", "f", "A", "F", "/", ":", "@", "G", "`", "g", "z", " ", "-", "é",
            "٣", "０", "\u{0}",
        ]

        /// Characters to put in a hyphen's place.
        static let hyphenReplacements: [Character] = ["0", "a", "_", " ", "–", "−", "+"]

        /// Canonical text, or canonical text with one break.
        static let texts: Gen<UUIDText> = Gen { tc in
            let value = try tc.draw(uuids)
            var characters = Array(value.description)
            let textBreak = try tc.draw(
                Gen<UUIDTextBreak?>.element(of: [nil] + UUIDTextBreak.allCases)
            )
            switch textBreak {
                case nil:
                    break
                case .upperCase:
                    characters = Array(value.description.uppercased())
                case .mixedCase:
                    for index in characters.indices {
                        if try tc.draw(Gen<Bool>.bool()) {
                            characters[index] = Character(characters[index].uppercased())
                        }
                    }
                case .digitReplaced:
                    let offsets = (0..<36).filter { !hyphenOffsets.contains($0) }
                    let offset = try tc.draw(Gen<Int>.element(of: offsets))
                    characters[offset] = try tc.draw(Gen<Character>.element(of: digitReplacements))
                case .hyphenReplaced:
                    let offset = try tc.draw(Gen<Int>.element(of: hyphenOffsets))
                    characters[offset] = try tc.draw(Gen<Character>.element(of: hyphenReplacements))
                case .hyphenMoved:
                    let offset = try tc.draw(Gen<Int>.element(of: hyphenOffsets))
                    let neighbor = offset + (try tc.draw(Gen<Int>.element(of: [-1, 1])))
                    characters.swapAt(offset, neighbor)
                case .characterDropped:
                    characters.remove(at: try tc.draw(Gen<Int>.integer(in: 0...35)))
                case .characterAdded:
                    characters.insert(
                        try tc.draw(Gen<Character>.element(of: ["0", "f", "F", "-", " "])),
                        at: try tc.draw(Gen<Int>.integer(in: 0...36))
                    )
                case .noHyphens:
                    characters.removeAll { $0 == "-" }
                case .braces:
                    characters = ["{"] + characters + ["}"]
                case .urnPrefix:
                    characters = Array("urn:uuid:") + characters
                case .combiningMark:
                    let offset = try tc.draw(Gen<Int>.integer(in: 1...36))
                    let text =
                        String(characters[..<offset]) + "\u{0301}"
                        + String(characters[offset...])
                    return UUIDText(text: text, textBreak: textBreak)
                case .surroundingSpace:
                    let space = try tc.draw(Gen<[Character]>.element(of: [[" "], ["\n"], ["\t"]]))
                    characters =
                        try tc.draw(Gen<Bool>.bool())
                        ? space + characters : characters + space
                case .nearTheGrammar:
                    let text = try tc.draw(Gen<String>.matching("[0-9a-fA-F-]{34,38}"))
                    return UUIDText(text: text, textBreak: textBreak)
                case .anyText:
                    let text = try tc.draw(Gen<String>.string(count: 0...40))
                    return UUIDText(text: text, textBreak: textBreak)
            }
            return UUIDText(text: String(characters), textBreak: textBreak)
        }

        /// Byte counts around 16, often 16 itself.
        static let byteCounts: Gen<Int> = .oneOf(
            .element(of: [0, 1, 8, 15, 16, 17, 32]),
            .integer(in: 0...40),
            .element(of: [16])
        )

        /// Two identifiers: the same one twice, one and a copy with one
        /// byte changed, or two drawn apart, in either order. The same one
        /// comes up a fifth of the time, so both orders come up often.
        static let pairs: Gen<UUIDPair> = Gen { tc in
            let one = try tc.draw(uuids)
            let kinds = ["the same", "one byte apart", "one byte apart", "apart", "apart"]
            let kind = try tc.draw(Gen<String>.element(of: kinds))
            var other = one
            switch kind {
                case "one byte apart":
                    var bytes = one.bytes
                    let index = try tc.draw(Gen<Int>.integer(in: 0...15))
                    bytes[index] = try tc.draw(
                        Gen<UInt8>.oneOf(
                            .integer(),
                            .element(of: [bytes[index] &+ 1, bytes[index] &- 1])
                        )
                    )
                    other = MMUUID(bytes: bytes)!
                case "apart":
                    other = try tc.draw(uuids)
                default:
                    break
            }
            let swapped = try tc.draw(Gen<Bool>.bool())
            return UUIDPair(
                kind: kind,
                first: swapped ? other : one,
                second: swapped ? one : other
            )
        }

        /// The wire form, the same 16 bytes under another bin or str
        /// header, payloads of other lengths, a payload cut short, the text
        /// form, and values of other types.
        static let wireInputs: Gen<UUIDWireInput> = .oneOf(
            uuids.map {
                UUIDWireInput(kind: "the wire form", bytes: [0xC4, 16] + $0.bytes, expected: $0)
            },
            Hegel.zip(
                uuids,
                Gen<[UInt8]>.element(of: [
                    [0xC5, 0, 16], [0xC6, 0, 0, 0, 16], [0xD9, 16], [0xB0],
                ])
            )
            .map { value, header in
                UUIDWireInput(kind: "another header", bytes: header + value.bytes, expected: value)
            },
            Gen { tc in
                let count = try tc.draw(byteCounts)
                let payload = try tc.draw(Gen<[UInt8]>.bytes(count: count...count))
                return UUIDWireInput(
                    kind: count == 16 ? "a payload of 16 bytes" : "a payload of another length",
                    bytes: [0xC4, UInt8(count)] + payload,
                    expected: MMUUID(bytes: payload)
                )
            },
            Gen { tc in
                let value = try tc.draw(uuids)
                let kept = try tc.draw(Gen<Int>.integer(in: 0...15))
                return UUIDWireInput(
                    kind: "a payload cut short",
                    bytes: [0xC4, 16] + value.bytes.prefix(kept),
                    expected: nil
                )
            },
            uuids.map {
                UUIDWireInput(
                    kind: "the text form",
                    bytes: [0xD9, 36] + Array($0.description.utf8),
                    expected: nil
                )
            },
            Gen<[UInt8]>.element(of: [[0xC0], [0x10], [0xC3], [0x90], [0x80], [0xCF]])
                .map { UUIDWireInput(kind: "another type", bytes: $0, expected: nil) }
        )

        /// Values for a random number generator to hand out: any, or all
        /// bits clear or set, so the masks over the version and the
        /// variant show.
        static let randomValues: Gen<[UInt64]> = .oneOf(
            Gen<[UInt64]>.array(of: halves, count: 2...2),
            .element(of: [[0, 0], [.max, .max]])
        )
    }

    @Suite("UUID properties", .hegel, .offTheCooperativePool)
    struct UUIDProperties {
        /// Every identifier renders as its canonical text and parses back to
        /// itself.
        ///
        /// Mutation check: rendering upper-case digits fails here.
        @Test
        func everyUUIDRoundTripsThroughText() throws {
            try property(
                reachingAfter: ["the Max UUID": 1_000, "the Nil UUID": 1_000]
            ) { tc in
                let value = try #draw(UUIDGenerators.uuids, from: tc)
                if value == .zero { try tc.event("the Nil UUID") }
                if value == MMUUID(high: .max, low: .max) { try tc.event("the Max UUID") }
                #expect(value.description == canonicalUUIDText(value))
                #expect(MMUUID(value.description) == value)
            }
        }

        /// Text parses exactly as the grammar reads it: the value its
        /// digits spell, in either case, when it is 8-4-4-4-12 hexadecimal
        /// digits joined by hyphens, and nothing otherwise.
        ///
        /// Mutation check: a parser that takes any character in a hyphen's
        /// place fails here at 100 cases; one that takes `G` for a digit,
        /// at 1,000.
        @Test
        func parsingFollowsTheGrammar() throws {
            try property(
                reaching: ["refused"],
                reachingAfter: [
                    "a URN prefix": 1_000, "a character added": 1_000,
                    "a character dropped": 1_000, "a combining mark": 1_000,
                    "a digit replaced": 1_000, "a hyphen moved": 1_000,
                    "a hyphen replaced": 1_000, "any text": 1_000, "braces": 1_000,
                    "canonical": 1_000, "mixed case": 1_000, "near the grammar": 1_000,
                    "no hyphens": 1_000, "parsed": 1_000, "surrounding space": 1_000,
                    "upper case": 1_000,
                ]
            ) { tc in
                let text = try #draw(UUIDGenerators.texts, from: tc)
                try tc.event(text.textBreak?.rawValue ?? "canonical")
                let parsed = MMUUID(text.text)
                try tc.event(parsed == nil ? "refused" : "parsed")
                #expect(parsed == modelUUID(text.text), "\(text)")
            }
        }

        /// Every identifier's bytes are its halves in network byte order,
        /// and make the same identifier again.
        ///
        /// Mutation check: writing the halves little-endian fails here.
        @Test
        func everyUUIDRoundTripsThroughBytes() throws {
            try property { tc in
                let value = try #draw(UUIDGenerators.uuids, from: tc)
                #expect(value.bytes == modelUUIDBytes(value))
                #expect(MMUUID(bytes: value.bytes) == value)
            }
        }

        /// Bytes make an identifier exactly when there are 16 of them, and
        /// it gives the same bytes back.
        ///
        /// Mutation check: taking the first 16 of a longer run fails here.
        @Test
        func bytesMakeAnIdentifierOnlyWhenThereAreSixteen() throws {
            try property(reaching: ["16 bytes", "another count"]) { tc in
                let count = try #draw(UUIDGenerators.byteCounts, from: tc)
                let bytes = try #draw(Gen<[UInt8]>.bytes(count: count...count), from: tc)
                try tc.event(count == 16 ? "16 bytes" : "another count")
                let value = MMUUID(bytes: bytes)
                #expect((value != nil) == (bytes.count == 16))
                if let value { #expect(value.bytes == bytes) }
            }
        }

        /// Identifiers order as their bytes do and as their canonical text
        /// does, and are equal exactly when their bytes are.
        ///
        /// Mutation check: comparing the low half first fails here.
        @Test
        func orderFollowsTheBytesAndTheText() throws {
            try property(
                reaching: ["greater", "less"],
                reachingAfter: [
                    "apart": 1_000, "equal": 1_000, "one byte apart": 1_000,
                    "the same high half": 1_000, "the same": 1_000,
                ]
            ) { tc in
                let pair = try #draw(UUIDGenerators.pairs, from: tc)
                let first = pair.first
                let second = pair.second
                try tc.event(pair.kind)
                if first == second {
                    try tc.event("equal")
                } else {
                    try tc.event(first < second ? "less" : "greater")
                    if first.high == second.high { try tc.event("the same high half") }
                }
                #expect((first < second) == first.bytes.lexicographicallyPrecedes(second.bytes))
                #expect((first < second) == (first.description < second.description))
                #expect((first == second) == (first.bytes == second.bytes))
            }
        }

        /// The MessagePack coder writes an identifier as `bin` holding its
        /// 16 bytes, alone or inside a container, and reads one from a bin
        /// or str payload of exactly 16 bytes and nothing else.
        ///
        /// Mutation check: a decoder that takes the first 16 bytes of a
        /// longer payload, or an encoder that writes the halves
        /// little-endian, fails here.
        @Test
        func theWireFormIsTheSixteenBytes() throws {
            try property(
                reaching: ["decoded", "refused"],
                reachingAfter: [
                    "a payload cut short": 1_000, "a payload of 16 bytes": 1_000,
                    "a payload of another length": 1_000, "another header": 1_000,
                    "another type": 1_000, "the text form": 1_000, "the wire form": 1_000,
                ]
            ) { tc in
                let value = try #draw(UUIDGenerators.uuids, from: tc)
                let encoded = MMPackEncoder().encode(value).map { Array($0.readableBytesView) }
                #expect(encoded == .success([0xC4, 16] + modelUUIDBytes(value)))
                let inArray = MMPackEncoder().encode([value]).map { Array($0.readableBytesView) }
                #expect(inArray == .success([0x91, 0xC4, 16] + modelUUIDBytes(value)))

                let input = try #draw(UUIDGenerators.wireInputs, from: tc)
                try tc.event(input.kind)
                let decoded = MMPackDecoder().decode(
                    MMUUID.self,
                    from: ByteBuffer(bytes: input.bytes)
                )
                switch decoded {
                    case .success(let read):
                        try tc.event("decoded")
                        #expect(read == input.expected, "\(input)")
                    case .failure(let error):
                        try tc.event("refused")
                        #expect(input.expected == nil, "\(input) failed with \(error)")
                }
            }
        }

        /// A random identifier is version 4 with RFC 9562's variant, and
        /// keeps every other bit the random source gave.
        ///
        /// Mutation check: leaving the variant unset, or dropping a random
        /// bit beside the version, fails here.
        @Test
        func randomIdentifiersAreVersionFour() throws {
            try property(
                reachingAfter: ["all bits set": 1_000, "no bits set": 1_000]
            ) { tc in
                let values = try #draw(UUIDGenerators.randomValues, from: tc)
                if values == [0, 0] { try tc.event("no bits set") }
                if values == [.max, .max] { try tc.event("all bits set") }
                var generator = ScriptedRandomNumberGenerator(values: values)
                let value = MMUUID.random(using: &generator)
                let bytes = value.bytes
                #expect(bytes[6] >> 4 == 4)
                #expect(bytes[8] >> 6 == 0b10)
                #expect(value.high & ~0xF000 == values[0] & ~0xF000)
                #expect(value.low << 2 == values[1] << 2)
            }
        }

        #if canImport(Foundation)
            /// An identifier converts to Foundation's `UUID` and back with
            /// the same bytes, and Foundation spells it as the canonical
            /// text in upper case.
            ///
            /// Mutation check: reversing the bytes on the way to `UUID`
            /// fails here.
            @Test
            func foundationUUIDsKeepTheBytes() throws {
                try property { tc in
                    let value = try #draw(UUIDGenerators.uuids, from: tc)
                    let foundation = value.uuid
                    #expect(MMUUID(foundation) == value)
                    #expect(foundation.uuidString == canonicalUUIDText(value).uppercased())
                    #expect(UUID(uuidString: value.description) == foundation)
                }
            }
        #endif
    }

#endif
