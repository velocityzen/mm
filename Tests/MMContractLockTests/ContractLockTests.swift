import Foundation
import MMClient
import MMContractLock
import MMExampleAPI
import MMSchema
import Testing

@Suite("Contract lock: a committed contract a test holds the current one to")
struct ContractLockTests {
    /// A journal whose `append` request is `line` then `count`, unpinned.
    static func journal(
        _ request: [TypeSchema.Field]? = nil,
        extraCall: Bool = false
    ) -> SchemaDeclaration {
        SchemaDeclaration(
            namespace: "journal",
            signatures: [
                MethodSignature(
                    name: "journal.append",
                    access: .write,
                    request: .structure(
                        fields: request ?? [
                            TypeSchema.Field(key: 0, name: "line", type: .string),
                            TypeSchema.Field(key: 1, name: "count", type: .int),
                        ]
                    ),
                    response: .structure(fields: [])
                )
            ]
                + (extraCall
                    ? [
                        MethodSignature(
                            name: "journal.read",
                            access: .read,
                            request: .structure(fields: []),
                            response: .structure(fields: [])
                        )
                    ] : [])
        )
    }

    /// A fresh directory for one test's lock, removed after it.
    func withLockFile(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-contract-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("locks/journal.json").path)
    }

    func contents(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }

    @Test("a missing lock is written and fails the check once")
    func missingLock() throws {
        try withLockFile { path in
            let lock = ContractLock([Self.journal()])
            let first = lock.check(lockFileAt: path)
            #expect(first.outcome == .created)
            #expect(!first.passed)
            let written = try contents(path)
            #expect(written == lock.text)
            let second = lock.check(lockFileAt: path)
            #expect(second.outcome == .unchanged)
            #expect(second.passed)
        }
    }

    @Test("an unpinned field inserted mid-struct renumbers the fields after it and breaks")
    func renumberingBreaks() throws {
        try withLockFile { path in
            let locked = ContractLock([Self.journal()])
            _ = locked.check(lockFileAt: path)
            // `note` inserted before `count`, unpinned: `count` moves to
            // key 2, and `note`, a string, now holds key 1.
            let current = ContractLock([
                Self.journal([
                    TypeSchema.Field(key: 0, name: "line", type: .string),
                    TypeSchema.Field(key: 1, name: "note", type: .string),
                    TypeSchema.Field(key: 2, name: "count", type: .int),
                ])
            ])
            let check = current.check(lockFileAt: path)
            guard case .breaking = check.outcome else {
                Issue.record("expected a break, found \(check)")
                return
            }
            #expect(!check.passed)
            #expect(
                check.breaks.contains("journal.append request.note: read as string, written as int")
            )
            let written = try contents(path)
            #expect(written == locked.text)
            #expect(check.description.contains("To accept the break, delete the lock"))
        }
    }

    @Test("a compatible change passes and moves the lock to the current contract")
    func compatibleChangeMovesTheLock() throws {
        try withLockFile { path in
            _ = ContractLock([Self.journal()]).check(lockFileAt: path)
            let current = ContractLock([
                Self.journal(
                    [
                        TypeSchema.Field(key: 0, name: "line", type: .string),
                        TypeSchema.Field(key: 1, name: "count", type: .int),
                        TypeSchema.Field(key: 2, name: "note", type: .optional(.string)),
                    ],
                    extraCall: true
                )
            ])
            let check = current.check(lockFileAt: path)
            guard case .compatible(let difference) = check.outcome else {
                Issue.record("expected a compatible change, found \(check)")
                return
            }
            #expect(check.passed)
            #expect(difference.remoteOnly.map(\.name) == ["journal.read"])
            let written = try contents(path)
            #expect(written == current.text)
        }
    }

    @Test("deleting the lock accepts a break")
    func deletingAcceptsABreak() throws {
        try withLockFile { path in
            _ = ContractLock([Self.journal(extraCall: true)]).check(lockFileAt: path)
            let current = ContractLock([Self.journal()])
            #expect(
                current.check(lockFileAt: path).breaks == [
                    "journal.read: no longer in the contract"
                ]
            )
            try FileManager.default.removeItem(atPath: path)
            #expect(current.check(lockFileAt: path).outcome == .created)
            #expect(current.check(lockFileAt: path).outcome == .unchanged)
        }
    }

    @Test("a lock edited by hand is damaged, and the check leaves it")
    func damagedLock() throws {
        try withLockFile { path in
            let lock = ContractLock([Self.journal()])
            _ = lock.check(lockFileAt: path)
            let edited = try contents(path).replacingOccurrences(of: "\"int\"", with: "\"uint\"")
            try Data(edited.utf8).write(to: URL(fileURLWithPath: path))
            guard case .failed(.damaged) = lock.check(lockFileAt: path).outcome else {
                Issue.record("expected a damaged lock")
                return
            }
            let written = try contents(path)
            #expect(written == edited)
        }
    }

    @Test("text that is not a lock, or a lock in another format, is refused")
    func notALock() {
        for text in ["", "not json", "{}", "[]", "{\"format\": \"1\"}"] {
            guard case .failure(.malformed) = ContractLock.parse(text) else {
                Issue.record("read \(text) as a lock")
                continue
            }
        }
        #expect(
            ContractLock.parse("{\"format\": 2, \"anything\": true}")
                == .failure(.unsupportedFormat(2))
        )
        let lock = ContractLock([Self.journal()])
        for (from, to) in [
            ("\"string\"", "\"text\""), ("\"-w-\"", "\"-W-\""), ("\"0x", "\"1x"),
        ] {
            guard
                case .failure(.malformed) = ContractLock.parse(
                    lock.text.replacingOccurrences(of: from, with: to)
                )
            else {
                Issue.record("read a lock with \(from) written as \(to)")
                continue
            }
        }
    }

    @Test("the file form names each bound's and default's kind, so 5.0 stays floating")
    func taggedNumbers() throws {
        let lock = ContractLock(methods: [
            MethodSignature(
                name: "shelf.look",
                access: [.read, .execute],
                request: .structure(fields: [
                    TypeSchema.Field(
                        key: 0,
                        name: "ratio",
                        type: .double,
                        constraints: TypeSchema.Constraints(
                            minimum: .floating(5),
                            maximum: .integer(9)
                        ),
                        defaultValue: .floating(6)
                    ),
                    TypeSchema.Field(
                        key: 1,
                        name: "wait",
                        type: .optional(.duration),
                        defaultValue: .duration(try #require(MMDuration("PT30S")))
                    ),
                ]),
                response: .structure(fields: [])
            )
        ])
        #expect(lock.text.contains("\"floating\" : 5"))
        #expect(ContractLock.parse(lock.text) == .success(lock))
    }

    /// The example in ``ContractLock/text``'s documentation, written out
    /// whole.
    @Test("a lock's file form is the documented one")
    func documentedText() {
        let lock = ContractLock(
            methods: [
                MethodSignature(
                    name: "journal.append",
                    access: .write,
                    request: .structure(fields: [
                        TypeSchema.Field(key: 0, name: "line", type: .string)
                    ]),
                    response: .reference("journal.Count")
                )
            ],
            types: [TypeDefinition(name: "journal.Count", schema: .int)]
        )
        #expect(
            lock.text == """
                {
                  "fingerprint" : "0x13898f76182373e5",
                  "format" : 1,
                  "methods" : [
                    {
                      "access" : "-w-",
                      "name" : "journal.append",
                      "request" : {
                        "structure" : [
                          {
                            "key" : 0,
                            "name" : "line",
                            "type" : "string"
                          }
                        ]
                      },
                      "response" : {
                        "reference" : "journal.Count"
                      }
                    }
                  ],
                  "types" : [
                    {
                      "name" : "journal.Count",
                      "schema" : "int"
                    }
                  ]
                }

                """
        )
        #expect(lock.text.contains(String(format: "\"0x%016llx\"", lock.fingerprint)))
    }

    @Test("descriptions, declaration order, and types no method reaches leave the lock as it is")
    func lockHoldsOnlyTheServedContract() {
        let shared = TypeNamespaceDeclaration(
            namespace: "common",
            types: [
                TypeDefinition(name: "common.Meta", schema: .structure(fields: [])),
                TypeDefinition(name: "common.Unused", schema: .string),
            ]
        )
        func contract(described: Bool) -> SchemaDeclaration {
            let calls = [
                MethodSignature(
                    name: "journal.b",
                    access: .read,
                    request: .structure(fields: []),
                    response: .reference("journal.Entry"),
                    description: described ? "reads" : nil
                ),
                MethodSignature(
                    name: "journal.a",
                    access: .write,
                    request: .structure(fields: []),
                    response: .structure(fields: [])
                ),
            ]
            return SchemaDeclaration(
                namespace: "journal",
                signatures: described ? calls.reversed() : calls,
                types: [
                    TypeDefinition(
                        name: "journal.Entry",
                        schema: .structure(fields: [
                            TypeSchema.Field(
                                key: 0,
                                name: "meta",
                                type: .reference("common.Meta"),
                                description: described ? "about the entry" : nil
                            )
                        ])
                    ),
                    TypeDefinition(name: "journal.Unused", schema: .int),
                ]
            )
        }
        let plain = ContractLock([contract(described: false)], sharedTypes: [shared])
        #expect(plain.methods.map(\.name) == ["journal.a", "journal.b"])
        #expect(plain.types.map(\.name) == ["common.Meta", "journal.Entry"])
        #expect(ContractLock([contract(described: true)], sharedTypes: [shared]).text == plain.text)
    }

    #if os(macOS) || os(Linux)
        /// The example API's contract, held to the lock committed beside
        /// this file. A failure here is a change to the example contract: a
        /// compatible one moves the lock, to be committed with it.
        @Test("the example journal keeps its committed contract")
        func exampleContractKeepsItsLock() {
            let check = ContractLock.check([journalContract], lockFile: "Locks/journal.json")
            #expect(check.passed, "\(check)")
        }
    #endif
}
