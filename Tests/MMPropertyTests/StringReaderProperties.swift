// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOCore
    import Testing

    /// The ways bytes stop being well-formed UTF-8, as the statistics report
    /// names them.
    enum UTF8Flaw: String, CaseIterable {
        case strayContinuationByte = "a stray continuation byte"
        case overlongForm = "an overlong form"
        case surrogate = "a surrogate"
        case scalarPastTheLast = "a scalar past U+10FFFF"
        case byteFromF5ToFF = "a byte from F5 to FF"
        case truncatedSequence = "a truncated sequence"
    }

    /// The first way `bytes` stop being well-formed UTF-8, read by the
    /// Unicode Standard's table 3-7 of well-formed byte sequences, or `nil`
    /// when they are well-formed throughout. Written from the table alone, so
    /// it shares no code with the standard library's validation.
    func firstUTF8Flaw(in bytes: [UInt8]) -> UTF8Flaw? {
        var index = 0
        func isContinuation(at offset: Int) -> Bool {
            index + offset < bytes.count && (0x80...0xbf).contains(bytes[index + offset])
        }
        while index < bytes.count {
            let length: Int
            // The second byte's narrower range, after a lead byte that has
            // one, and what a continuation byte outside it is.
            var second: ClosedRange<UInt8> = 0x80...0xbf
            var outside = UTF8Flaw.truncatedSequence
            switch bytes[index] {
                case 0x00...0x7f:
                    index += 1
                    continue
                case 0x80...0xbf: return .strayContinuationByte
                case 0xc0...0xc1: return .overlongForm
                case 0xc2...0xdf: length = 2
                case 0xe0:
                    length = 3
                    (second, outside) = (0xa0...0xbf, .overlongForm)
                case 0xed:
                    length = 3
                    (second, outside) = (0x80...0x9f, .surrogate)
                case 0xe1...0xef: length = 3
                case 0xf0:
                    length = 4
                    (second, outside) = (0x90...0xbf, .overlongForm)
                case 0xf1...0xf3: length = 4
                case 0xf4:
                    length = 4
                    (second, outside) = (0x80...0x8f, .scalarPastTheLast)
                default: return .byteFromF5ToFF
            }
            guard isContinuation(at: 1) else { return .truncatedSequence }
            guard second.contains(bytes[index + 1]) else { return outside }
            for offset in 2..<length where !isContinuation(at: offset) {
                return .truncatedSequence
            }
            index += length
        }
        return nil
    }

    /// UTF-8 payloads joined from pieces: well-formed scalars, often at an
    /// encoding length's edge or beside the surrogates, and every kind of
    /// ill-formed sequence. Pieces run into each other, so a truncated
    /// sequence followed by continuation bytes can be well-formed again: the
    /// oracle reads the joined bytes, never the pieces.
    enum UTF8Generators {
        /// The scalars on either side of each encoding length's edge and of
        /// the surrogates.
        static let scalarEdges = [
            0x00, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xfffd, 0xffff, 0x1_0000, 0x10_ffff,
        ]

        /// Any Unicode scalar value, often at an edge.
        static let scalars: Gen<Int> = .oneOf(
            .element(of: scalarEdges),
            Gen<Int>.int(in: 0...(0x10_ffff - 0x800)).map { $0 < 0xd800 ? $0 : $0 + 0x800 }
        )

        /// The fewest UTF-8 bytes that hold `value`.
        static func shortestLength(_ value: Int) -> Int {
            switch value {
                case ..<0x80: 1
                case ..<0x800: 2
                case ..<0x1_0000: 3
                default: 4
            }
        }

        /// `value` laid out in `length` bytes of UTF-8's bit pattern, whether
        /// or not `length` is the fewest that hold it.
        static func encoded(_ value: Int, length: Int) -> [UInt8] {
            guard length > 1 else { return [UInt8(value)] }
            let lead = UInt8(truncatingIfNeeded: (0xff00 >> length) | (value >> (6 * (length - 1))))
            let continuations = (0..<length - 1).reversed().map {
                UInt8(0x80 | (value >> (6 * $0)) & 0x3f)
            }
            return [lead] + continuations
        }

        /// One well-formed scalar, or a run of them.
        static let wellFormedPieces: Gen<[UInt8]> = .oneOf(
            scalars.map { encoded($0, length: shortestLength($0)) },
            Gen<String>.string().map { Array($0.utf8) }
        )

        /// A value in `range`, often one of its ends.
        static func values(in range: ClosedRange<Int>) -> Gen<Int> {
            .oneOf(.element(of: [range.lowerBound, range.upperBound]), .int(in: range))
        }

        /// One ill-formed sequence of each kind table 3-7 rules out.
        static let illFormedPieces: Gen<[UInt8]> = .oneOf(
            // A scalar in more bytes than it needs.
            Gen<Int>.int(in: 2...4).flatMap { length in
                values(in: 0...[2: 0x7f, 3: 0x7ff, 4: 0xffff][length, default: 0])
                    .map { encoded($0, length: length) }
            },
            values(in: 0xd800...0xdfff).map { encoded($0, length: 3) },
            // Past U+10FFFF: led by F4, then by F5 to F7.
            values(in: 0x11_0000...0x13_ffff).map { encoded($0, length: 4) },
            values(in: 0x14_0000...0x1f_ffff).map { encoded($0, length: 4) },
            values(in: 0xf8...0xff).map { [UInt8($0)] },
            values(in: 0x80...0xbf).map { [UInt8($0)] },
            // A scalar of two or more bytes missing its last ones.
            values(in: 0x80...0x10_ffff).flatMap { value in
                let bytes = encoded(value, length: shortestLength(value))
                return values(in: 1...bytes.count - 1).map { Array(bytes.dropLast($0)) }
            },
            Gen<[UInt8]>.bytes(count: 1...1)
        )

        /// Well-formed pieces alone, one ill-formed piece among them,
        /// well-formed and ill-formed pieces mixed, or any bytes.
        static let payloads: Gen<[UInt8]> = .oneOf(
            Gen<[[UInt8]]>.array(of: wellFormedPieces).map { $0.flatMap { $0 } },
            Hegel.zip(
                Gen<[[UInt8]]>.array(of: wellFormedPieces),
                illFormedPieces,
                Gen<[[UInt8]]>.array(of: wellFormedPieces)
            )
            .map { before, flawed, after in before.flatMap { $0 } + flawed + after.flatMap { $0 } },
            Gen<[[UInt8]]>.array(of: .oneOf(wellFormedPieces, illFormedPieces))
                .map { $0.flatMap { $0 } },
            .bytes()
        )
    }

    /// The name of a str header's format.
    func stringHeaderName(_ header: [UInt8]) -> String {
        switch header.first {
            case 0xd9: "a str8 header"
            case 0xda: "a str16 header"
            case 0xdb: "a str32 header"
            default: "a fixstr header"
        }
    }

    @Suite("String reader properties", .hegel, .offTheCooperativePool)
    struct StringReaderProperties {
        /// `readMessagePackString` reads a string exactly when its payload is
        /// well-formed UTF-8 by the Unicode Standard's table 3-7. Then the
        /// string holds exactly the payload's bytes, and the reader index
        /// moves past them and no further. Otherwise it fails with
        /// `invalidUTF8` and the reader index stays where it was. The value
        /// sits after bytes already read and before more bytes, as it does
        /// inside a larger message.
        ///
        /// Mutation-checked: a reader that repairs bytes instead of refusing
        /// them fails this, and so does one that lets any single kind of
        /// error through (surrogates, overlong forms, bytes that can't encode
        /// a scalar, truncated scalars, stray continuation bytes), one that
        /// skips the payload's last byte, one that copies the string from the
        /// buffer's start, and one that leaves the reader index past the
        /// header on a refusal. The unit tests miss the truncated-scalar and
        /// stray-continuation mutants.
        @Test
        func stringsAreReadExactlyWhenTheyAreUTF8() throws {
            try property(
                reaching: [
                    "well-formed", "a stray continuation byte", "a str8 header", "a str16 header",
                    "a str32 header",
                ],
                reachingAfter: [
                    "a byte from F5 to FF": 1_000, "a fixstr header": 1_000,
                    "a scalar past U+10FFFF": 1_000, "a surrogate": 1_000,
                    "a truncated sequence": 1_000, "an overlong form": 1_000,
                    "well-formed with a four-byte scalar": 1_000,
                ]
            ) { tc in
                let payload = try #draw(UTF8Generators.payloads, from: tc)
                let header = try #draw(
                    PackGenerators.headers(
                        count: payload.count,
                        fix: (0xa0, 32),
                        eightBit: 0xd9,
                        sixteenBit: 0xda,
                        thirtyTwoBit: 0xdb
                    ),
                    from: tc
                )
                let alreadyRead = try #draw(Gen<[UInt8]>.bytes(), from: tc)
                let bytesAfter = try #draw(Gen<[UInt8]>.bytes(), from: tc)
                let flaw = firstUTF8Flaw(in: payload)
                try tc.event(flaw?.rawValue ?? "well-formed")
                try tc.event(stringHeaderName(header))
                if flaw == nil, payload.contains(where: { $0 >= 0xf0 }) {
                    try tc.event("well-formed with a four-byte scalar")
                }
                var reader = buffer(after: alreadyRead, holding: header + payload + bytesAfter)
                let start = reader.readerIndex
                switch (reader.readMessagePackString(), flaw) {
                    case (.success(let string), nil):
                        #expect(Array(string.utf8) == payload)
                        #expect(reader.readerIndex == start + header.count + payload.count)
                    case (.failure(let error), let flaw?):
                        #expect(error == .invalidUTF8, "\(flaw.rawValue)")
                        #expect(reader.readerIndex == start, "\(flaw.rawValue)")
                    case (.success, let flaw?):
                        Issue.record("read a string with \(flaw.rawValue)")
                    case (.failure(let error), nil):
                        Issue.record("failed with \(error) on well-formed UTF-8")
                }
            }
        }
    }

#endif
