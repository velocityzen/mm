import Testing

@testable import MMSchemaMacros

/// The macro restates `EntityName.parse`'s grammar (it cannot call the
/// runtime); this case table mirrors the rules in
/// Sources/MMSchema/EntityName.swift so a grammar change on either side
/// fails here.
@Suite("Macro namespace grammar mirrors EntityName")
struct NamespaceGrammarTests {
    @Test("accepts exactly what EntityName accepts (minus root)")
    func accepted() {
        for path in [
            "journal", "box.item", "a-b.c_d", "9lives", "-lead", "a.b.c",
            "_x", "x-", "0",
        ] {
            #expect(isValidLowerIdentifierPath(path), "should accept \(path)")
        }
    }

    @Test("rejects what EntityName rejects, plus the root path")
    func rejected() {
        for path in [
            "", ".", "a..b", ".a", "a.", "A", "Journal", "café", "a b",
            "a/b", "ä",
        ] {
            #expect(!isValidLowerIdentifierPath(path), "should reject \(path)")
        }
    }
}
