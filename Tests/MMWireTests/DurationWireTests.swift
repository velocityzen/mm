import Foundation
import MMSchema
import MMWire
import NIOCore
import Testing

/// The duration article's test vectors (MMWire.docc/Duration.md, section 6),
/// through the reference implementation and the MessagePack coders, which
/// carry a duration as `bin` around its binary form.
@Suite("Wire duration kind: the article's vectors")
struct DurationWireTests {
    /// The article's canonical encodings, each with its canonical text.
    static let canonical: [(text: String, hex: String)] = [
        ("PT0S", "00"),
        ("PT1S", "0101"),
        ("PT1H30M", "021518"),
        ("-PT0.5S", "9001f4"),
        ("PT0.000001S", "20000001"),
        ("PT1M0.000000001S", "313c00000001"),
        ("PT25H1M1.0005S", "23015fcd0001f4"),
        ("PT0.000000000000000001S", "400000000000000001"),
        (
            "PT47261439850130342H8M51.687303715884105727S",
            "4909392ee8e921d5d0730989cb168e13ffff"
        ),
        (
            "-PT47261439850130342H8M51.687303715884105728S",
            "c909392ee8e921d5d0730989cb168e140000"
        ),
    ]

    /// The article's refused encodings, each with the failure it names.
    static let refused: [(hex: String, failure: MMDurationDecodeFailure)] = [
        ("", .empty),
        ("0a", .reservedBits),
        ("50", .reservedBits),
        ("0201", .truncated),
        ("010100", .trailingBytes),
        ("020001", .nonCanonical),
        ("110103e8", .fractionOutOfRange),
        ("100000", .nonCanonical),
        ("2007a120", .nonCanonical),
        ("80", .nonCanonical),
        ("4909392ee8e921d5d0730989cb168e140000", .outOfRange),
    ]

    @Test("each canonical vector parses, renders, encodes and decodes as the article says")
    func canonicalVectors() throws {
        for (text, hex) in Self.canonical {
            let value = try MMDuration.parse(text).get()
            #expect(value.description == text)
            #expect(value.encoded() == Array(mpBytes(hex).readableBytesView), "\(text)")
            #expect(MMDuration.decode(Array(mpBytes(hex).readableBytesView)) == .success(value))
            // On the wire: a bin of the encoding's length, then the encoding.
            let wire = String(format: "c4%02x", hex.count / 2) + hex
            #expect(MMPackEncoder().encode(value).map(mpHex) == .success(wire), "\(text)")
            #expect(MMPackDecoder().decode(MMDuration.self, from: mpBytes(wire)) == .success(value))
        }
    }

    @Test("each refused vector fails with the failure the article names")
    func refusedVectors() {
        for (hex, failure) in Self.refused {
            let bytes = Array(mpBytes(hex).readableBytesView)
            #expect(MMDuration.decode(bytes) == .failure(failure), "\(hex)")
            let wire = String(format: "c4%02x", bytes.count) + hex
            #expect(
                MMPackDecoder().decode(MMDuration.self, from: mpBytes(wire)).mpFailure != nil,
                "\(hex)"
            )
        }
    }

    @Test("JSON carries a duration as its canonical text")
    func jsonText() throws {
        let value = try MMDuration.parse("P1DT0.25S").get()
        let json = try JSONEncoder().encode([value])
        #expect(String(decoding: json, as: UTF8.self) == #"["PT24H0.25S"]"#)
        #expect(try JSONDecoder().decode([MMDuration].self, from: json) == [value])
    }
}
