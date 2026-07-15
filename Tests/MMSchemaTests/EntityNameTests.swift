import Foundation
import Testing

@testable import MMSchema

@Suite("EntityName")
struct EntityNameTests {
    @Test(
        "valid names parse",
        arguments: [
            "a", "a.b", "journal.append_log", "a-b.c_d", "a1.b2.c3", "x0", "_private.thing", "-",
            "0",
        ]
    )
    func validNames(_ string: String) {
        let parsed = EntityName.parse(string)
        #expect(parsed == .success(EntityName(validated: string)))
        #expect(parsed.map(\.rawValue) == .success(string))
    }

    @Test(
        "empty segments rejected",
        arguments: [".a", "a.", "a..b", ".", "..", "a.b..c"]
    )
    func emptySegments(_ string: String) {
        #expect(EntityName.parse(string) == .failure(.invalidEntityName(string, .emptySegment)))
    }

    @Test(
        "invalid characters rejected",
        arguments: ["A.b", "a.B", "a b", "café", "a/b", "a.b!", "ПРИВЕТ", "a\tb", "j:urnal"]
    )
    func invalidCharacters(_ string: String) {
        #expect(EntityName.parse(string) == .failure(.invalidEntityName(string, .invalidCharacter)))
    }

    @Test("empty string parses to root")
    func emptyIsRoot() {
        #expect(EntityName.parse("") == .success(.root))
    }

    @Test("segments")
    func segments() {
        #expect(EntityName(validated: "a.b.c").segments == ["a", "b", "c"])
        #expect(EntityName(validated: "solo").segments == ["solo"])
        #expect(EntityName.root.segments == [])
    }

    @Test("ancestors are proper prefixes, outermost first")
    func ancestorsOrder() {
        let name = EntityName(validated: "a.b.c")
        #expect(name.ancestors == [EntityName(validated: "a"), EntityName(validated: "a.b")])
        #expect(EntityName(validated: "solo").ancestors == [])
    }

    @Test("parent chain")
    func parent() {
        #expect(EntityName(validated: "a.b.c").parent == EntityName(validated: "a.b"))
        #expect(EntityName(validated: "a").parent == .root)
        #expect(EntityName.root.parent == nil)
    }

    @Test("isDescendant boundaries")
    func isDescendant() {
        let abc = EntityName(validated: "a.b.c")
        #expect(abc.isDescendant(of: EntityName(validated: "a.b")))
        #expect(abc.isDescendant(of: EntityName(validated: "a")))
        // Never a descendant of itself.
        #expect(!abc.isDescendant(of: abc))
        // Dot-boundary, not string-prefix: "jour" is not an ancestor of "journal".
        #expect(!EntityName(validated: "journal").isDescendant(of: EntityName(validated: "jour")))
        // And "a.bc" is not a descendant of "a.b".
        #expect(!EntityName(validated: "a.bc").isDescendant(of: EntityName(validated: "a.b")))
        // Nor the reverse.
        #expect(!EntityName(validated: "a.b").isDescendant(of: EntityName(validated: "a.bc")))
    }

    @Test("root semantics")
    func rootSemantics() {
        #expect(EntityName.root.isRoot)
        #expect(EntityName.root.rawValue == "")
        #expect(EntityName.root.ancestors == [])
        #expect(EntityName.root.parent == nil)
        // Everything non-root descends from root; root descends from nothing.
        #expect(EntityName(validated: "a").isDescendant(of: .root))
        #expect(EntityName(validated: "a.b.c").isDescendant(of: .root))
        #expect(!EntityName.root.isDescendant(of: .root))
        #expect(!EntityName.root.isDescendant(of: EntityName(validated: "a")))
    }

    @Test("Codable round trip as a plain string")
    func codableRoundTrip() throws {
        let name = EntityName(validated: "journal.entries")
        let data = try JSONEncoder().encode(name)
        #expect(String(data: data, encoding: .utf8) == "\"journal.entries\"")
        let decoded = try JSONDecoder().decode(EntityName.self, from: data)
        #expect(decoded == name)
    }

    @Test("root encodes as the empty string and round trips")
    func rootCodable() throws {
        let data = try JSONEncoder().encode(EntityName.root)
        #expect(String(data: data, encoding: .utf8) == "\"\"")
        let decoded = try JSONDecoder().decode(EntityName.self, from: data)
        #expect(decoded == .root)
    }

    @Test("invalid string fails decode")
    func invalidDecodeFails() throws {
        let data = Data("\"not..valid\"".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(EntityName.self, from: data)
        }
    }
}
