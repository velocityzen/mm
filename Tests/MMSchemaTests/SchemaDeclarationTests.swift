import Testing

@testable import MMSchema

// MARK: - Codable fixtures a declaration is verified against

private struct NoteRequest: Codable, Hashable, Sendable {
    var line: String

    enum CodingKeys: Int, CodingKey {
        case line = 0
    }
}

private struct NoteResponse: Codable, Hashable, Sendable {
    var count: Int

    enum CodingKeys: Int, CodingKey {
        case count = 0
    }
}

/// An empty request payload — the target rides the envelope. Empty structs
/// self-describe (a property-less decoder is unprobeable).
private struct ListRequest: Codable, Hashable, Sendable, SchemaDescribable {
    static var schema: TypeSchema { .structure(fields: []) }
}

private struct ListResponse: Codable, Hashable, Sendable {
    var lines: [String]

    enum CodingKeys: Int, CodingKey {
        case lines = 0
    }
}

private enum Notes: MethodNamespace {
    static let add = Method<NoteRequest, NoteResponse>(name: "notes.add", access: .write)
    static let list = Method<ListRequest, ListResponse>(name: "notes.list", access: .read)

    @SchemaBuilder static var all: [AnyMethod] {
        add
        list
    }
}

private let notesContract = Schema("notes") {
    Call("add") {
        Access { .write }
        Request {
            Field("line", .string)
        }
        Response {
            Field("count", .int)
        }
    }
    Call("list") {
        Access { .read }
        Response {
            Field("lines", .array(.string))
        }
    }
}

@Suite("SchemaDeclaration: the declarative contract DSL")
struct SchemaDeclarationTests {
    @Test("a declaration produces full wire names in declaration order")
    func names() {
        #expect(notesContract.namespace == "notes")
        #expect(notesContract.signatures.map(\.name) == ["notes.add", "notes.list"])
        #expect(notesContract.signatures.map(\.access) == [.write, .read])
    }

    @Test("request fields key from 0 — the entity is envelope metadata, not payload")
    func requestKeysFromZero() {
        let request = notesContract.signatures[0].request
        let expected = TypeSchema.structure(fields: [
            .init(key: 0, name: "line", type: .string)
        ])
        #expect(request == expected)
    }

    @Test("omitting Request or Response declares an empty payload")
    func omittedBlocks() {
        let request = notesContract.signatures[1].request
        #expect(request == .structure(fields: []))
        let bare = Schema("notes") {
            Call("touch") {
                Access { .write }
            }
        }
        #expect(bare.signatures[0].request == .structure(fields: []))
        #expect(bare.signatures[0].response == .structure(fields: []))
    }

    @Test("the declared contract matches the Codable implementation exactly")
    func contractHolds() throws {
        #expect(try notesContract.verify(against: Notes.self).get().isEmpty)
    }

    @Test("the declaration's signatures equal the probed signatures, so fingerprints agree")
    func fingerprintAgreement() throws {
        let probed = try Notes.all.map { try $0.signature().get() }
        #expect(
            notesContract.signatures.sorted(by: { $0.name < $1.name })
                == probed.sorted(by: { $0.name < $1.name }))
        #expect(notesContract.fingerprint() == SchemaFingerprint.compute(probed))
    }

    @Test("verify reports access divergence")
    func accessDivergence() throws {
        let skewed = Schema("notes") {
            Call("add") {
                Access { .read }  // implementation says .write
                Request { Field("line", .string) }
                Response { Field("count", .int) }
            }
            Call("list") {
                Access { .read }
                Response { Field("lines", .array(.string)) }
            }
        }
        let breaks = try skewed.verify(against: Notes.all).get()
        #expect(breaks.count == 1)
        #expect(breaks[0].contains("notes.add"))
        #expect(breaks[0].contains("access"))
    }

    @Test("verify reports shape divergence, missing, and extra methods")
    func structuralDivergence() throws {
        let skewed = Schema("notes") {
            Call("add") {
                Access { .write }
                Request { Field("line", .int) }  // implementation says .string
                Response { Field("count", .int) }
            }
            Call("purge") {  // not implemented
                Access { .write }
            }
        }
        let breaks = try skewed.verify(against: Notes.all).get()
        #expect(breaks.contains { $0.contains("notes.add") && $0.contains("request") })
        #expect(breaks.contains { $0.contains("notes.purge") && $0.contains("not implemented") })
        #expect(breaks.contains { $0.contains("notes.list") && $0.contains("not in the contract") })
    }

    @Test("pinned keys are honored and auto keys skip them")
    func pinnedKeys() {
        let shape = Fields {
            Field("first", .string)  // auto 0
            Field(3, "pinned", .bool)  // pinned 3
            Field("second", .int)  // auto 1
            Field("third", .double)  // auto 2
            Field("fourth", .uint)  // auto: 3 taken, becomes 4
        }
        guard case .structure(let fields) = shape else {
            Issue.record("Fields must build a structure")
            return
        }
        #expect(fields.map(\.key) == [0, 3, 1, 2, 4])
    }

    @Test("nested structures via block sugar and array composition")
    func nesting() {
        let shape = Fields {
            Field("owner") {
                Field("uid", .uint)
                Field("gid", .uint)
            }
            Field(
                "entries",
                .array(
                    Fields {
                        Field("line", .string)
                        Field("count", .int)
                    }))
            Field("note", .optional(.string))
        }
        let expected = TypeSchema.structure(fields: [
            .init(
                key: 0, name: "owner",
                type: .structure(fields: [
                    .init(key: 0, name: "uid", type: .uint),
                    .init(key: 1, name: "gid", type: .uint),
                ])),
            .init(
                key: 1, name: "entries",
                type: .array(
                    .structure(fields: [
                        .init(key: 0, name: "line", type: .string),
                        .init(key: 1, name: "count", type: .int),
                    ]))),
            .init(key: 2, name: "note", type: .optional(.string)),
        ])
        #expect(shape == expected)
    }

    @Test("conditional declaration: buildOptional and buildEither compose methods")
    func conditionalMethods() {
        func contract(withPurge: Bool) -> SchemaDeclaration {
            Schema("notes") {
                Call("add") {
                    Access { .write }
                    Request { Field("line", .string) }
                    Response { Field("count", .int) }
                }
                if withPurge {
                    Call("purge") {
                        Access { .write }
                    }
                }
            }
        }
        #expect(contract(withPurge: true).signatures.map(\.name) == ["notes.add", "notes.purge"])
        #expect(contract(withPurge: false).signatures.map(\.name) == ["notes.add"])
    }

    @Test("an explicit empty Request {} equals an omitted one")
    func explicitEmptyRequest() {
        let explicit = Schema("notes") {
            Call("touch") {
                Access { .write }
                Request {}
                Response {}
            }
        }
        let omitted = Schema("notes") {
            Call("touch") {
                Access { .write }
            }
        }
        #expect(explicit == omitted)
        #expect(explicit.fingerprint() == omitted.fingerprint())
    }

    @Test("duplicate method declarations are programmer error")
    func duplicateMethod() async throws {
        await #expect(processExitsWith: .failure) {
            _ = Schema("notes") {
                Call("add") {
                    Access { .write }
                }
                Call("add") {
                    Access { .read }
                }
            }
        }
    }

    @Test("a method without Access is programmer error — policy is never defaulted")
    func missingAccess() async throws {
        await #expect(processExitsWith: .failure) {
            _ = Schema("notes") {
                Call("add") {
                    Request { Field("line", .string) }
                }
            }
        }
    }

    @Test("request key 0 is an ordinary field key — nothing is reserved")
    func requestKeyZeroPinnable() {
        // The entity rides the open envelope, so request fields start at 0
        // like every other part; pinning 0 is legal.
        let contract = Schema("notes") {
            Call("add") {
                Access { .write }
                Request {
                    Field(0, "line", .string)
                    Field("note", .optional(.string))
                }
            }
        }
        #expect(
            contract.signatures[0].request
                == .structure(fields: [
                    .init(key: 0, name: "line", type: .string),
                    .init(key: 1, name: "note", type: .optional(.string)),
                ])
        )
    }
}
