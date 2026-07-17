import Testing

@testable import MMCLI

/// Shaped like a macro-generated struct: Int-raw CodingKeys whose
/// `stringValue`s are the case names, so JSONEncoder prints named keys.
private struct Fixture: Encodable {
    var count: Int
    var line: String

    enum CodingKeys: Int, CodingKey {
        case count = 0
        case line = 1
    }
}

@Suite("MMCLIOutput: rendering")
struct OutputTests {
    @Test("json renders compact, sorted, named keys")
    func compactJSON() throws {
        let rendered = try MMCLIOutput.render(
            Fixture(count: 2, line: "hi"), format: .json)
        #expect(rendered == #"{"count":2,"line":"hi"}"#)
    }

    @Test("json-pretty renders multi-line with named keys")
    func prettyJSON() throws {
        let rendered = try MMCLIOutput.render(
            Fixture(count: 2, line: "hi"), format: .jsonPretty)
        #expect(rendered.contains("\n"))
        #expect(rendered.contains(#""count" : 2"#))
        #expect(rendered.contains(#""line" : "hi""#))
    }

    @Test("raw currently renders identically to json")
    func rawMatchesJSON() throws {
        let fixture = Fixture(count: 5, line: "x")
        let raw = try MMCLIOutput.render(fixture, format: .raw)
        let json = try MMCLIOutput.render(fixture, format: .json)
        #expect(raw == json)
    }
}
