import Foundation
import Testing

@testable import MMSchema

/// A `#schema` expansion declaring errors of every kind. `Type("Case")` and
/// the generated `Error` enum share names with DSL functions, so the
/// re-emitted contract compiles only with its callees module-qualified.
private enum Till: MethodNamespace {
    #schema("till") {
        Errors {
            Case("closed", exitCode: 10, description: "The till is closed")
            Case("audit", exitCode: 11) {
                Field("auditor", .string)
                Field("until", .optional(.int))
            }
        }
        Error("Empty", exitCode: 12)
        Error("Short", exitCode: 13, description: "Not enough change") {
            Field("missing", .int)
        }
        Type("Case") {
            Field("label", .string)
        }
        Enum("Coin") {
            Case("penny")
            Case("dime")
        }
        Call("take") {
            Access { .write }
            Request {
                Field("coin", "Coin")
            }
            Errors {
                Case(.reference("Empty"))
                Case(.reference("Short"))
                Case("jammed", .reference("Case"), exitCode: 14)
            }
        }
        Call("count") {
            Access { .read }
        }
    }
}

/// The same call with no errors, other errors, and the same errors: the
/// implementations `Teller.contract` is verified against.
private enum Teller: MethodNamespace {
    #schema("teller") {
        Call("pay") {
            Access { .write }
            Errors {
                Case("broke", exitCode: 10)
            }
        }
    }
}

private enum PlainTeller: MethodNamespace {
    #schema("teller") {
        Call("pay") {
            Access { .write }
        }
    }
}

private enum OtherTeller: MethodNamespace {
    #schema("teller") {
        Call("pay") {
            Access { .write }
            Errors {
                Case("closed", exitCode: 10)
            }
        }
    }
}

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decoded<Value: Decodable>(_ type: Value.Type, _ text: String) throws -> Value {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}

@Suite("Declared errors: the runtime DSL")
struct ErrorDeclarationTests {
    static let journal = Schema("journal") {
        Errors {
            Case("retired", exitCode: 10, description: "The journal is retired")
        }
        Error("Full", exitCode: 12, description: "No room left") {
            Field("capacity", .int)
        }
        Enum("Kind") {
            Case("line")
        }
        Type("Conflict") {
            Field("existing", .string)
            Field("kind", "Kind")
        }
        Call("append") {
            Access { .write }
            Errors {
                Case(.reference("Full"))
                Case("conflict", .reference("Conflict"), exitCode: 11)
                Case("tooLong", exitCode: 13) {
                    Field(3, "limit", .int)
                    Field("kind", .optional(.reference("Kind")))
                }
            }
        }
        Call("read") {
            Access { .read }
        }
    }

    @Test("a call serves the namespace's errors, then its own, resolved and keyed")
    func flattened() {
        let retired = TypeSchema.UnionCase(
            name: "retired",
            fields: [],
            description: "The journal is retired"
        )
        let append = Self.journal.signatures.first { $0.name == "journal.append" }
        #expect(
            append?.errors
                == .union(cases: [
                    retired,
                    .init(
                        name: "full",
                        fields: [.init(key: 0, name: "capacity", type: .int)],
                        description: "No room left"
                    ),
                    .init(
                        name: "conflict",
                        fields: [
                            .init(key: 0, name: "existing", type: .string),
                            .init(key: 1, name: "kind", type: .reference("journal.Kind")),
                        ]
                    ),
                    .init(
                        name: "tooLong",
                        fields: [
                            .init(key: 3, name: "limit", type: .int),
                            .init(
                                key: 0,
                                name: "kind",
                                type: .optional(.reference("journal.Kind"))
                            ),
                        ]
                    ),
                ])
        )
        let read = Self.journal.signatures.first { $0.name == "journal.read" }
        #expect(read?.errors == .union(cases: [retired]))
    }

    @Test("named errors stay out of the type table")
    func typeTable() {
        #expect(Self.journal.types.map(\.name) == ["journal.Kind", "journal.Conflict"])
    }

    @Test("a block without errors serves none")
    func noErrors() {
        let schema = Schema("box") {
            Call("ping") { Access { .read } }
        }
        #expect(schema.signatures.map(\.errors) == [nil])
    }

    @Test(
        "a named error's case lowers its leading capitals",
        arguments: [
            ("Full", "full"), ("URLTooLong", "urlTooLong"), ("IO", "io"), ("X", "x"),
            ("ABc", "aBc"), ("Retired2", "retired2"), ("_Hidden", "_Hidden"),
        ]
    )
    func caseNames(name: String, expected: String) {
        #expect(errorCaseName(forNamedError: name) == expected)
    }

    #if os(macOS) || os(Linux) || os(Windows)
        @Test("an exit code outside 2...63 is programmer error")
        func exitCodeOutOfRange() async {
            await #expect(processExitsWith: .failure) {
                _ = Errors { Case("late", exitCode: 64) }
            }
            await #expect(processExitsWith: .failure) {
                _ = Errors { Case("fine", exitCode: 1) }
            }
        }

        @Test("\"unknown\" is reserved, as a case and as a named error's case")
        func unknownReserved() async {
            await #expect(processExitsWith: .failure) {
                _ = Errors { Case("unknown", exitCode: 10) }
            }
            await #expect(processExitsWith: .failure) {
                _ = Schema("box") {
                    Error("Unknown", exitCode: 10)
                    Call("ping") {
                        Access { .read }
                        Errors { Case(.reference("Unknown")) }
                    }
                }
            }
        }

        @Test("a call error may not reuse a namespace error's name or exit code")
        func namespaceClash() async {
            await #expect(processExitsWith: .failure) {
                _ = Schema("box") {
                    Errors { Case("busy", exitCode: 10) }
                    Call("ping") {
                        Access { .read }
                        Errors { Case("busy", exitCode: 11) }
                    }
                }
            }
            await #expect(processExitsWith: .failure) {
                _ = Schema("box") {
                    Errors { Case("busy", exitCode: 10) }
                    Call("ping") {
                        Access { .read }
                        Errors { Case("late", exitCode: 10) }
                    }
                }
            }
        }

        @Test("a reference must name a Type or Error of the block")
        func unresolvedReference() async {
            await #expect(processExitsWith: .failure) {
                _ = Schema("box") {
                    Call("ping") {
                        Access { .read }
                        Errors { Case(.reference("Missing")) }
                    }
                }
            }
            await #expect(processExitsWith: .failure) {
                _ = Schema("box") {
                    Enum("Kind") { Case("a") }
                    Call("ping") {
                        Access { .read }
                        Errors { Case("odd", .reference("Kind"), exitCode: 10) }
                    }
                }
            }
        }

        @Test("one namespace Errors block, one per call, no duplicate cases")
        func duplicates() async {
            await #expect(processExitsWith: .failure) {
                _ = Schema("box") {
                    Errors { Case("a", exitCode: 10) }
                    Errors { Case("b", exitCode: 11) }
                    Call("ping") { Access { .read } }
                }
            }
            await #expect(processExitsWith: .failure) {
                _ = Schema("box") {
                    Call("ping") {
                        Access { .read }
                        Errors {
                            Case("a", exitCode: 10)
                            Case("a", exitCode: 11)
                        }
                    }
                }
            }
            await #expect(processExitsWith: .failure) {
                _ = Schema("box") {
                    Error("Full", exitCode: 10)
                    Type("Full") { Field("x", .int) }
                    Call("ping") { Access { .read } }
                }
            }
        }
    #endif
}

@Suite("Declared errors: what #schema generates")
struct GeneratedErrorTests {
    @Test("the contract verifies clean against the generated types")
    func contractFidelity() throws {
        let breaks = try Till.contract.verify(against: Till.self).get()
        for line in breaks { Issue.record("mismatch: \(line)") }
        #expect(breaks == [])
    }

    @Test("each enum's declaredErrors is what the signature serves")
    func declaredErrors() throws {
        #expect(Till.TakeError.declaredErrors == (try Till.take.signature().get().errors))
        #expect(Till.CountError.declaredErrors == (try Till.count.signature().get().errors))
        #expect(Till.Error.declaredErrors == (try Till.count.signature().get().errors))
        guard case .union(let cases) = Till.TakeError.declaredErrors else {
            Issue.record("TakeError's errors are not a union")
            return
        }
        #expect(cases.map(\.name) == ["closed", "audit", "empty", "short", "jammed"])
    }

    @Test("a namespace error lifts into each call's enum")
    func lifting() {
        #expect(Till.TakeError(Till.Error.closed) == .closed)
        #expect(
            Till.TakeError(Till.Error.audit(auditor: "ada", until: 3))
                == .audit(auditor: "ada", until: 3)
        )
        #expect(Till.TakeError(Till.Error.unknown("later")) == .unknown("later"))
        #expect(Till.CountError(Till.Error.closed) == .closed)
    }

    @Test("every case round-trips its union form, and a field-less case leaves key 1 out")
    func codable() throws {
        let values: [Till.TakeError] = [
            .closed,
            .audit(auditor: "ada", until: nil),
            .audit(auditor: "ada", until: 3),
            .empty(Till.Empty()),
            .short(Till.Short(missing: 2)),
            .jammed(Till.Case(label: "stuck")),
            .unknown("later"),
        ]
        for value in values {
            #expect(try decoded(Till.TakeError.self, try json(value)) == value)
        }
        #expect(try json(Till.TakeError.closed) == #"{"case":"closed"}"#)
        #expect(try json(Till.TakeError.empty(Till.Empty())) == #"{"case":"empty"}"#)
        #expect(
            try json(Till.TakeError.audit(auditor: "ada", until: nil))
                == #"{"case":"audit","fields":{"auditor":"ada"}}"#
        )
        #expect(
            try json(Till.TakeError.short(Till.Short(missing: 2)))
                == #"{"case":"short","fields":{"missing":2}}"#
        )
    }

    @Test("a case this build does not know decodes to unknown, keeping its name")
    func unknownCase() throws {
        let value = try decoded(Till.TakeError.self, #"{"case":"melted","fields":{"heat":9}}"#)
        #expect(value == .unknown("melted"))
        #expect(value.caseName == "melted")
        #expect(try decoded(Till.CountError.self, #"{"case":"empty"}"#) == .unknown("empty"))
    }

    @Test("a named error is a Swift error of its own")
    func namedErrorIsAnError() {
        let error: any Swift.Error = Till.Short(missing: 1)
        #expect(error as? Till.Short == Till.Short(missing: 1))
        #expect(Till.TakeError.short(Till.Short(missing: 1)).caseName == "short")
    }

    @Test("verify reports errors declared, implemented, or different")
    func verifyMismatches() throws {
        #expect(
            try Teller.contract.verify(against: PlainTeller.self).get()
                == ["teller.pay: errors declared but not implemented"]
        )
        #expect(
            try PlainTeller.contract.verify(against: Teller.self).get()
                == ["teller.pay: errors implemented but not in the contract"]
        )
        #expect(
            try Teller.contract.verify(against: OtherTeller.self).get()
                == ["teller.pay: errors diverge from the contract"]
        )
    }

    @Test("errors are part of the fingerprint")
    func fingerprint() {
        #expect(Teller.contract.fingerprint() != PlainTeller.contract.fingerprint())
        #expect(Teller.contract.fingerprint() != OtherTeller.contract.fingerprint())
    }
}
