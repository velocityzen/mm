// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMWire
    import NIOCore
    import Testing

    /// A nested Codable fixture exercising integer-keyed maps, string-keyed maps,
    /// optionals, arrays, dictionaries, multi-byte UTF-8, floats (including -0.0 and
    /// infinities), the full integer range, and zero-copy ByteBuffer payloads.
    struct Fixture: Codable, Equatable {
        var flag: Bool
        var tiny: Int8
        var medium: Int32
        var big: Int64
        var unsigned: UInt64
        var smallUnsigned: UInt16
        var double: Double
        var float: Float
        var text: String
        var maybeText: String?
        var ints: [Int]
        var doubles: [Double]
        var stringMap: [String: Int32]
        var intMap: [Int: String]
        var blob: ByteBuffer
        var nested: Nested
        var maybeNested: Nested?

        struct Nested: Codable, Equatable {
            var values: [Double]
            var label: String?
            var inner: Inner?

            struct Inner: Codable, Equatable {
                var a: Int
                var b: [UInt16]

                enum CodingKeys: Int, CodingKey {
                    case a = 1
                    case b = 2
                }
            }

            enum CodingKeys: Int, CodingKey {
                case values = 1
                case label = 2
                case inner = 3
            }
        }

        enum CodingKeys: Int, CodingKey {
            case flag = 1
            case tiny = 2
            case medium = 3
            case big = 4
            case unsigned = 5
            case smallUnsigned = 6
            case double = 7
            case float = 8
            case text = 9
            case maybeText = 10
            case ints = 11
            case doubles = 12
            case stringMap = 13
            case intMap = 14
            case blob = 15
            case nested = 16
            case maybeNested = 17
        }
    }

    enum WireGen {
        /// Any double but NaN, which is never equal to itself.
        static let double: Gen<Double> = .double(allowNaN: false)

        /// A string-keyed dictionary's key. A key that reads as an integer may
        /// travel as an integer key, and only its canonical form may (`"5"`,
        /// never `"05"` or `"+5"`), so integer-looking keys are drawn often.
        static let key: Gen<String> = .oneOf(
            .string(),
            Gen<Int>.int().map { String($0) },
            .string(of: .characters("+-0123456789"), count: 1...4)
        )

        static let inner: Gen<Fixture.Nested.Inner> = Gen { tc in
            try Fixture.Nested.Inner(
                a: tc.draw(.int()),
                b: tc.draw(.array(of: Gen<UInt16>.integer()))
            )
        }

        static let nested: Gen<Fixture.Nested> = Gen { tc in
            try Fixture.Nested(
                values: tc.draw(.array(of: double)),
                label: tc.draw(.optional(Gen<String>.string())),
                inner: tc.draw(.optional(inner))
            )
        }

        static let fixture: Gen<Fixture> = Gen { tc in
            try Fixture(
                flag: tc.draw(.bool()),
                tiny: tc.draw(Gen<Int8>.integer()),
                medium: tc.draw(Gen<Int32>.integer()),
                big: tc.draw(Gen<Int64>.integer()),
                unsigned: tc.draw(Gen<UInt64>.integer()),
                smallUnsigned: tc.draw(Gen<UInt16>.integer()),
                double: tc.draw(double),
                float: tc.draw(.float(allowNaN: false)),
                text: tc.draw(.string()),
                maybeText: tc.draw(.optional(Gen<String>.string())),
                ints: tc.draw(.array(of: .int())),
                doubles: tc.draw(.array(of: double)),
                stringMap: tc.draw(.dictionary(keys: key, values: Gen<Int32>.integer())),
                intMap: tc.draw(.dictionary(keys: .int(), values: .string())),
                blob: ByteBuffer(bytes: tc.draw(.bytes())),
                nested: tc.draw(nested),
                maybeNested: tc.draw(.optional(nested))
            )
        }

        static let hello: Gen<MMHello> = Hegel.zip(
            Gen<UInt8>.integer(),
            Gen<UInt64>.integer(),
            Gen<UInt32>.integer()
        )
        .map { MMHello(protocolVersion: $0, schemaFingerprint: $1, capabilities: $2) }
    }

    @Suite("Wire round-trip properties", .hegel)
    struct WireRoundTripProperties {
        @Test(.hegel(testCases: 500))
        func fixtureRoundTrips() throws {
            try property { tc in
                let fixture = try #draw(WireGen.fixture, from: tc)
                let encoded = try MMPackEncoder().encode(fixture).get()
                #expect(MMPackDecoder().decode(Fixture.self, from: encoded) == .success(fixture))
            }
        }

        @Test
        func fixtureArraysRoundTrip() throws {
            try property { tc in
                let fixtures = try #draw(.array(of: WireGen.fixture), from: tc)
                let encoded = try MMPackEncoder().encode(fixtures).get()
                #expect(MMPackDecoder().decode([Fixture].self, from: encoded) == .success(fixtures))
            }
        }

        @Test
        func helloRoundTrips() throws {
            try property { tc in
                let hello = try #draw(WireGen.hello, from: tc)
                let encoded = try hello.encode().get()
                #expect(encoded.readableBytes == MMHello.encodedByteCount)
                #expect(MMHello.decode(from: encoded) == .success(hello))
            }
        }
    }

#endif
