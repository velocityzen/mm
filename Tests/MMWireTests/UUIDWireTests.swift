import Foundation
import MMSchema
import MMWire
import NIOCore
import Testing

/// The wire specification's uuid kind (section 8.3): a `bin` holding the 16
/// bytes in RFC 9562's order, and lowercase hyphenated text in JSON.
@Suite("Wire uuid kind")
struct UUIDWireTests {
    /// Identifiers with their bytes: RFC 9562's version 1, 4 and 7
    /// examples, and the Nil and Max UUIDs.
    static let vectors: [(text: String, hex: String)] = [
        ("f81d4fae-7dec-11d0-a765-00a0c91e6bf6", "f81d4fae7dec11d0a76500a0c91e6bf6"),
        ("919108f7-52d1-4320-9bac-f847db4148a8", "919108f752d143209bacf847db4148a8"),
        ("017f22e2-79b0-7cc3-98c4-dc0c0c07398f", "017f22e279b07cc398c4dc0c0c07398f"),
        ("00000000-0000-0000-0000-000000000000", "00000000000000000000000000000000"),
        ("ffffffff-ffff-ffff-ffff-ffffffffffff", "ffffffffffffffffffffffffffffffff"),
    ]

    @Test("each vector parses, renders, encodes and decodes as the specification says")
    func vectorsRoundTrip() throws {
        for (text, hex) in Self.vectors {
            let value = try #require(MMUUID(text))
            #expect(value.description == text)
            #expect(MMUUID(text.uppercased()) == value)
            #expect(value.bytes == Array(mpBytes(hex).readableBytesView), "\(text)")
            // On the wire: a bin of 16 bytes, then the bytes.
            #expect(MMPackEncoder().encode(value).map(mpHex) == .success("c410" + hex), "\(text)")
            #expect(
                MMPackDecoder().decode(MMUUID.self, from: mpBytes("c410" + hex)) == .success(value)
            )
        }
    }

    @Test("a bin of any length but 16 is refused")
    func otherLengthsAreRefused() {
        for hex in [
            "c400", "c40f" + String(repeating: "ab", count: 15),
            "c411" + String(repeating: "ab", count: 17),
        ] {
            #expect(
                MMPackDecoder().decode(MMUUID.self, from: mpBytes(hex)).mpFailure != nil,
                "\(hex)"
            )
        }
    }

    @Test("text forms other than the hyphenated one are refused")
    func otherTextFormsAreRefused() {
        for text in [
            "f81d4fae7dec11d0a76500a0c91e6bf6",
            "{f81d4fae-7dec-11d0-a765-00a0c91e6bf6}",
            "urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
            "f81d4fae-7dec-11d0-a765-00a0c91e6bf",
            "g81d4fae-7dec-11d0-a765-00a0c91e6bf6",
            " f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        ] {
            #expect(MMUUID(text) == nil, "\(text)")
        }
    }

    @Test("JSON carries a uuid as its lowercase text")
    func jsonText() throws {
        let value = try #require(MMUUID("F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"))
        let json = try JSONEncoder().encode([value])
        #expect(
            String(decoding: json, as: UTF8.self) == #"["f81d4fae-7dec-11d0-a765-00a0c91e6bf6"]"#
        )
        #expect(try JSONDecoder().decode([MMUUID].self, from: json) == [value])
    }

    @Test("a random identifier is version 4 with RFC 9562's variant")
    func randomIsVersionFour() {
        let bytes = MMUUID.random().bytes
        #expect(bytes[6] >> 4 == 4)
        #expect(bytes[8] >> 6 == 0b10)
    }

    @Test("Foundation's UUID converts both ways with the same bytes")
    func foundationInterop() throws {
        let foundation = try #require(UUID(uuidString: "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"))
        let value = MMUUID(foundation)
        #expect(value.description == "f81d4fae-7dec-11d0-a765-00a0c91e6bf6")
        #expect(value.uuid == foundation)
    }
}
