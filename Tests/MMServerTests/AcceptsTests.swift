import MMSchema
import Testing

@testable import MMServer

/// The ``Accepts`` pattern grammar, pinned shape by shape. Wiring into the
/// router's authorize step is covered by the integration suite
/// (`routeEntityScoping`); this suite is about matching semantics alone.
@Suite("Accepts pattern grammar")
struct AcceptsTests {
    private func entity(_ raw: String) -> EntityName {
        try! EntityName.parse(raw).get()
    }

    @Test("exact pattern admits exactly itself")
    func exactPattern() {
        let accepts = Accepts("box.item")
        #expect(accepts.admits(entity("box.item")))
        #expect(!accepts.admits(entity("box")))
        #expect(!accepts.admits(entity("box.item.part")))
        #expect(!accepts.admits(entity("box.other")))
        #expect(!accepts.admitsRoot)
    }

    @Test("trailing .* admits strict descendants at any depth, not the prefix")
    func trailingDescendants() {
        let accepts = Accepts("journal.*")
        #expect(accepts.admits(entity("journal.notes")))
        #expect(accepts.admits(entity("journal.a.b.c")))
        #expect(!accepts.admits(entity("journal")))
        #expect(!accepts.admits(entity("journalx.notes")))
    }

    @Test("a * segment matches exactly one segment")
    func oneSegmentWildcard() {
        let accepts = Accepts("tenants.*.journal")
        #expect(accepts.admits(entity("tenants.acme.journal")))
        #expect(!accepts.admits(entity("tenants.a.b.journal")))
        #expect(!accepts.admits(entity("tenants.journal")))
        #expect(!accepts.admits(entity("tenants.acme.journal.notes")))
    }

    @Test("segment wildcards compose with the trailing form")
    func wildcardWithDescendants() {
        let accepts = Accepts("tenants.*.journal.*")
        #expect(accepts.admits(entity("tenants.acme.journal.notes")))
        #expect(accepts.admits(entity("tenants.acme.journal.a.b")))
        #expect(!accepts.admits(entity("tenants.acme.journal")))
        #expect(!accepts.admits(entity("tenants.acme.ledger.notes")))
    }

    @Test("bare * is the degenerate trailing form: any non-root entity, never root")
    func allPattern() {
        let star = Accepts("*")
        let all = Accepts(.all)
        for candidate in ["a", "a.b", "deep.nested.path"] {
            #expect(star.admits(entity(candidate)))
            #expect(all.admits(entity(candidate)))
        }
        #expect(!star.admitsRoot)
        #expect(!all.admitsRoot)
    }

    @Test(".root admits root-targeted dispatches and nothing else")
    func rootPattern() {
        let accepts = Accepts(.root)
        #expect(accepts.admitsRoot)
        #expect(!accepts.admits(entity("a")))
        let combined = Accepts(.root, .all)
        #expect(combined.admitsRoot)
        #expect(combined.admits(entity("a.b")))
    }

    @Test("patterns compose: any match admits")
    func patternUnion() {
        let accepts = Accepts("box", "box.*", "tenants.*.journal")
        #expect(accepts.admits(entity("box")))
        #expect(accepts.admits(entity("box.item")))
        #expect(accepts.admits(entity("tenants.acme.journal")))
        #expect(!accepts.admits(entity("tenants.acme.ledger")))
    }
}
