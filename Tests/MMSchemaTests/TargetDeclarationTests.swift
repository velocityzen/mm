import Testing

@testable import MMSchema

/// A namespace whose calls declare their targets: the namespace's `Target`
/// is every call's default, and `put` declares its own, out of order and
/// with a pattern doubled.
private enum Crate: MethodNamespace {
    #schema("crate") {
        Target("crate.*")
        Call("get") {
            Access(.read)
        }
        Call("put") {
            Access(.write)
            Target("crate.inbox", .root, "crate.inbox")
        }
    }
}

@Suite("Declared targets")
struct TargetDeclarationTests {
    @Test("the namespace's Target is every call's default, and a call's own replaces it")
    func namespaceDefaultAndOverride() throws {
        #expect(Crate.get.target == ["crate.*"])
        #expect(Crate.put.target == [.root, "crate.inbox"])
        #expect(try Crate.get.signature().get().target == ["crate.*"])
        #expect(try Crate.put.probedSignature().get().target == [.root, "crate.inbox"])
    }

    @Test("the re-emitted contract states each call's target and verifies clean")
    func contractFidelity() throws {
        #expect(Crate.contract.signatures.map(\.target) == [["crate.*"], [.root, "crate.inbox"]])
        #expect(try Crate.contract.verify(against: Crate.self).get().isEmpty)
    }

    @Test("the runtime DSL states targets as #schema does")
    func runtimeDeclaration() throws {
        let contract = Schema("crate") {
            Target("crate.*")
            Call("get") {
                Access { .read }
            }
            Call("put") {
                Access { .write }
                Target("crate.inbox", .root, "crate.inbox")
            }
        }
        #expect(contract == Crate.contract)
    }

    @Test("verify reports a target that differs from the contract's")
    func targetDrift() throws {
        let contract = Schema("crate") {
            Call("get") {
                Access { .read }
                Target("crate.notes")
            }
            Call("put") {
                Access { .write }
            }
        }
        #expect(
            try contract.verify(against: Crate.self).get() == [
                "crate.get: target is crate.*, contract says crate.notes",
                "crate.put: target is (root), crate.inbox, contract says undeclared",
            ]
        )
    }

    @Test("a target changes the fingerprint, and one restated in another order does not")
    func targetFingerprint() throws {
        let declared = try Crate.put.signature().get()
        var undeclared = declared
        undeclared.target = nil
        var restated = declared
        restated.target = ["crate.inbox", .root]
        #expect(SchemaFingerprint.compute([declared]) != SchemaFingerprint.compute([undeclared]))
        #expect(SchemaFingerprint.compute([declared]) == SchemaFingerprint.compute([restated]))
    }
}

@Suite("EntityPattern grammar")
struct EntityPatternTests {
    @Test("a pattern reads from its text and names the first rule it breaks")
    func parsing() {
        #expect(EntityPattern.parse("") == .success(.root))
        #expect(EntityPattern.parse("*") == .success(.all))
        #expect(
            EntityPattern.parse("tenants.*.journal.*").map(\.text)
                == .success("tenants.*.journal.*")
        )
        #expect(
            EntityPattern.parse("a..b") == .failure(.invalidEntityPattern("a..b", .emptySegment))
        )
        #expect(
            EntityPattern.parse("journal.")
                == .failure(.invalidEntityPattern("journal.", .emptySegment))
        )
        #expect(
            EntityPattern.parse("jour*")
                == .failure(.invalidEntityPattern("jour*", .partialWildcard))
        )
        #expect(
            EntityPattern.parse("**") == .failure(.invalidEntityPattern("**", .partialWildcard))
        )
        #expect(
            EntityPattern.parse("Journal")
                == .failure(.invalidEntityPattern("Journal", .invalidCharacter))
        )
    }

    @Test("one pattern falls within another when every entity it matches, the other matches")
    func containment() {
        let within: [(EntityPattern, EntityPattern)] = [
            ("journal.notes", "journal.*"),
            ("journal.a.*", "journal.*"),
            ("journal.*", "*"),
            ("tenants.acme.journal", "tenants.*.journal"),
            ("tenants.*.journal.*", "tenants.*"),
            (.root, .root),
        ]
        let outside: [(EntityPattern, EntityPattern)] = [
            ("journal", "journal.*"),
            ("journal.*", "journal.notes"),
            ("*", "journal.*"),
            ("tenants.*.journal", "tenants.acme.journal"),
            ("journal.*", "journal.*.*"),
            (.root, .all),
            ("journal", .root),
        ]
        for (pattern, outer) in within {
            #expect(pattern.isWithin(outer), "\(pattern) within \(outer)")
        }
        for (pattern, outer) in outside {
            #expect(!pattern.isWithin(outer), "\(pattern) outside \(outer)")
        }
        #expect(
            EntityPattern.firstOutside(["journal.notes", "journal", "x"], ["journal.*"])
                == "journal"
        )
        #expect(
            EntityPattern.firstOutside(["journal", "journal.notes"], ["journal", "journal.*"])
                == nil
        )
    }

    @Test("the literal prefix and the sole entity a target names")
    func prefixAndSoleEntity() throws {
        #expect(EntityPattern("journal.*").literalPrefix == "journal.")
        #expect(EntityPattern("tenants.*.journal").literalPrefix == "tenants.")
        #expect(EntityPattern("system.log").literalPrefix == "system.log")
        #expect(EntityPattern("*.log").literalPrefix == "")
        #expect(EntityPattern.root.literalPrefix == "")
        #expect(
            EntityPattern.soleEntity(of: ["system.log"])
                == (try EntityName.parse("system.log").get())
        )
        #expect(EntityPattern.soleEntity(of: ["system.*"]) == nil)
        #expect(EntityPattern.soleEntity(of: ["system.log", "system.audit"]) == nil)
        #expect(EntityPattern.listed([.root, "journal.*"]) == "(root), journal.*")
    }
}
