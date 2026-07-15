import MMSchema
import Testing

@testable import MMServer

@Suite("Declarative ACL table")
struct ACLBuilderTests {
    @Test("flat entries assemble verbatim")
    func flatEntries() {
        let table = assembleACLTable(
            build {
                Entity("box", owner: 10, group: 20, mode: 0o750)
                Entity("box.item", owner: 11, group: 21, mode: 0o700)
            })
        #expect(table[entity("box")] == EntityACL(owner: 10, group: 20, mode: 0o750))
        #expect(table[entity("box.item")] == EntityACL(owner: 11, group: 21, mode: 0o700))
        #expect(table.count == 2)
    }

    @Test("children resolve relative paths and inherit owner/group")
    func nestingAndInheritance() {
        let table = assembleACLTable(
            build {
                Entity("journal", owner: 10, group: 20, mode: 0o750) {
                    Entity("notes")
                    Entity("system", owner: 0, group: 0, mode: 0o700)
                    Entity("deep.leaf", mode: 0o770)  // multi-segment relative path
                }
            })
        #expect(table[entity("journal")] == EntityACL(owner: 10, group: 20, mode: 0o750))
        // Inherited owner/group; mode defaults to the creation default.
        #expect(
            table[entity("journal.notes")]
                == EntityACL(owner: 10, group: 20, mode: EntityACL.defaultCreationMode))
        // Explicit always wins.
        #expect(table[entity("journal.system")] == EntityACL(owner: 0, group: 0, mode: 0o700))
        #expect(table[entity("journal.deep.leaf")] == EntityACL(owner: 10, group: 20, mode: 0o770))
        #expect(table.count == 4)
    }

    @Test("grandchildren inherit from the nearest ancestor that set owner/group")
    func deepInheritance() {
        let table = assembleACLTable(
            build {
                Entity("a", owner: 1, group: 2) {
                    Entity("b", owner: 3, group: 4) {
                        Entity("c")
                    }
                }
            })
        #expect(table[entity("a.b.c")]?.owner == 3)
        #expect(table[entity("a.b.c")]?.group == 4)
        #expect(table[entity("a")]?.mode == EntityACL.defaultCreationMode)
    }

    @Test("the mode default is the plan's creation default, 0o750")
    func modeDefault() {
        let table = assembleACLTable(build { Entity("box", owner: 1, group: 1) })
        #expect(table[entity("box")]?.mode == 0o750)
    }

    @Test("conditional entries compose")
    func conditionalEntries() {
        func table(withSystem: Bool) -> [EntityName: EntityACL] {
            assembleACLTable(
                build {
                    Entity("journal", owner: 1, group: 1)
                    if withSystem {
                        Entity("journal.system", owner: 0, group: 0, mode: 0o700)
                    }
                })
        }
        #expect(table(withSystem: true).count == 2)
        #expect(table(withSystem: false).count == 1)
    }

    @Test("the InMemoryACLProvider builder init authorizes like the dictionary init")
    func providerInit() async throws {
        let provider = InMemoryACLProvider {
            Entity("box", owner: 10, group: 20, mode: 0o750) {
                Entity("item")
            }
        }
        let acl = try await provider.acl(for: entity("box.item")).get()
        #expect(acl == EntityACL(owner: 10, group: 20, mode: EntityACL.defaultCreationMode))
        #expect(try await provider.acl(for: entity("box.missing")).get() == nil)
    }

    @Test("duplicate declarations are programmer error")
    func duplicates() async throws {
        await #expect(processExitsWith: .failure) {
            _ = assembleACLTable(
                build {
                    Entity("box", owner: 1, group: 1)
                    Entity("box", owner: 2, group: 2)
                })
        }
        // Also via nesting: "box" then relative child resolving to "box".
        await #expect(processExitsWith: .failure) {
            _ = assembleACLTable(
                build {
                    Entity("box", owner: 1, group: 1) {
                        Entity("item")
                    }
                    Entity("box.item", owner: 1, group: 1)
                })
        }
    }

    @Test("a top-level entity without owner/group is programmer error")
    func missingOwner() async throws {
        await #expect(processExitsWith: .failure) {
            _ = assembleACLTable(build { Entity("box") })
        }
    }

    @Test("an invalid path is programmer error")
    func invalidPath() async throws {
        await #expect(processExitsWith: .failure) {
            _ = assembleACLTable(build { Entity("Not A Path!", owner: 1, group: 1) })
        }
    }
}

/// Materializes an @ACLBuilder block outside the DSL entry points, for
/// direct table assertions.
private func build(@ACLBuilder _ entries: () -> [ACLEntry]) -> [ACLEntry] {
    entries()
}
