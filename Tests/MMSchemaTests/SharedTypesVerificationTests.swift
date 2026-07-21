import Testing

@testable import MMSchema

/// Shared `Types(...)` declarations in the client-side verification folds:
/// the fingerprint twin of the router's `sharedTypes:` registration, and the
/// reachability merge that keeps scoped diffs honest.
@Suite("Shared types in verification folds")
struct SharedTypesVerificationTests {
    /// A shared container: `Stamp` references `Priority` (transitive), and
    /// `Unused` is referenced by nothing.
    private let shared = Types("common") {
        Type("Stamp") {
            Field("author", .string)
            Field("priority", "Priority")
        }
        Enum("Priority") {
            Case("low")
            Case("high")
        }
        Type("Unused") {
            Field("x", .int)
        }
    }

    /// A contract whose one method references the shared `Stamp`.
    private let contract = Schema("desk") {
        Call("stamp") {
            Access { .write }
            Request {
                Field("stamp", "common.Stamp")
            }
            Response {
                Field("ok", .bool)
            }
        }
    }

    @Test("types(sharing:) merges referenced shared definitions, transitively — never unreferenced ones")
    func reachabilityMerge() {
        let merged = self.contract.types(sharing: [self.shared])
        let names = Set(merged.map(\.name))
        #expect(names.contains("common.Stamp"))
        #expect(names.contains("common.Priority"))
        #expect(!names.contains("common.Unused"))
        // Without sharing, only the contract's own types.
        #expect(self.contract.types(sharing: []) == self.contract.types)
    }

    @Test("expected(serving:sharedTypes:) folds the shared definitions — omitting them is a different value")
    func expectedFoldIncludesSharedTypes() throws {
        let withShared = try SchemaFingerprint.expected(
            serving: [self.contract], sharedTypes: [self.shared]
        ).get()
        let withoutShared = try SchemaFingerprint.expected(serving: [self.contract]).get()
        #expect(withShared != withoutShared)
        // The fold is canonical: declaration order never affects the value.
        let reordered = Types("common") {
            Type("Unused") { Field("x", .int) }
            Enum("Priority") {
                Case("low")
                Case("high")
            }
            Type("Stamp") {
                Field("author", .string)
                Field("priority", "Priority")
            }
        }
        let reorderedFold = try SchemaFingerprint.expected(
            serving: [self.contract], sharedTypes: [reordered]
        ).get()
        #expect(reorderedFold == withShared)
    }
}
