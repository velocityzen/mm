import ArgumentParser
import Logging
import MMClient
import MMSchema
import MMServer
import MMTestSupport
import Testing

@testable import MMCLI

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Android)
    import Android
#endif

/// A contract declaring every kind of error: a namespace error, a named
/// error listed by reference, a case carrying a `Type`, and a case with
/// inline fields, on calls of all four shapes.
enum Vault: MethodNamespace {
    #schema("vault") {
        CLI(.enabled)
        Errors {
            Case("sealed", exitCode: 10, description: "The vault is sealed")
        }
        Error("Full", exitCode: 12, description: "The vault holds as much as it can") {
            Field("capacity", .int)
        }
        Type("Conflict") {
            Field("existing", .string)
        }
        Call("put") {
            Access { .write }
            Request {
                Field("key", .string, cli: .argument)
            }
            Response {
                Field("count", .int)
            }
            Errors {
                Case(.reference("Full"))
                Case("conflict", .reference("Conflict"), exitCode: 11)
                Case("tooLong", exitCode: 13) {
                    Field("limit", .int)
                    Field("hint", .optional(.string))
                }
            }
        }
        Call("list") {
            Access { .read }
            ResponseStream {
                Field("key", .string)
            }
            Response {
                Field("count", .int)
            }
        }
        Call("load") {
            Access { .write }
            RequestStream {
                Field("key", .string)
            }
            Response {
                Field("count", .int)
            }
            Errors {
                Case(.reference("Full"))
            }
        }
        Call("sync") {
            Access { .write }
            RequestStream {
                Field("key", .string)
            }
            ResponseStream {
                Field("key", .string)
            }
            Errors {
                Case(.reference("Full"))
            }
        }
        Call("note") {
            Access { .write }
            Request {
                Field("text", .string, cli: .input)
            }
            Errors {
                Case("tooLong", exitCode: 13) {
                    Field("limit", .int)
                }
            }
        }
    }
}

/// The same namespace as an older build sees it: `put` does not know
/// `tooLong` yet.
enum OldVault: MethodNamespace {
    #schema("vault") {
        Errors {
            Case("sealed", exitCode: 10, description: "The vault is sealed")
        }
        Error("Full", exitCode: 12, description: "The vault holds as much as it can") {
            Field("capacity", .int)
        }
        Call("put") {
            Access { .write }
            Request {
                Field("key", .string)
            }
            Response {
                Field("count", .int)
            }
            Errors {
                Case(.reference("Full"))
            }
        }
    }
}

/// Boots a server for `Vault` whose calls fail with the error their request
/// names: `put` with the case its key spells, the streams after echoing
/// what they got.
private func withVaultServer<T: Sendable>(
    _ body: @escaping @Sendable (MMCLIOptions) async throws -> T
) async throws -> T {
    try await withTempSocketPath(prefix: "mm-vault-") { path in
        let acls: [EntityName: EntityACL] = [
            cliTestEntity("vault"): EntityACL(owner: getuid(), group: getgid(), mode: 0o700),
            cliTestEntity("locked"): EntityACL(owner: getuid(), group: getgid(), mode: 0o000),
            cliTestEntity("server"): EntityACL(owner: getuid(), group: getgid(), mode: 0o700),
        ]
        var logger = Logger(label: "mm.declarederrors.server")
        logger.logLevel = .warning
        let service = ServerRuntime(
            configuration: MMServerConfiguration(endpoint: .unix(path: path)),
            namespaces: [Vault.self],
            aclProvider: InMemoryACLProvider(acls),
            logger: logger
        ) {
            Handle(Vault.put) { request, _ in
                switch request.key {
                    case "sealed": .failure(.init(Vault.Error.sealed))
                    case "full": .failure(.full(Vault.Full(capacity: 3)))
                    case "conflict": .failure(.conflict(Vault.Conflict(existing: "old")))
                    case "tooLong": .failure(.tooLong(limit: 5, hint: "shorter"))
                    default: .success(Vault.PutResponse(count: 1))
                }
            }
            Handle(Vault.list) { _, sink, _ in
                _ = await sink.send(Vault.ListResponseItem(key: "first"))
                return .failure(.sealed)
            }
            Handle(Vault.load) { _, elements, _ in
                var count = 0
                for await _ in elements { count += 1 }
                return .failure(.full(Vault.Full(capacity: count)))
            }
            Handle(Vault.sync) { _, elements, sink, _ in
                var count = 0
                for await element in elements {
                    _ = await sink.send(Vault.SyncResponseItem(key: element.key))
                    count += 1
                }
                return .failure(.full(Vault.Full(capacity: count)))
            }
            Handle(Vault.note) { request, _ in
                .failure(.tooLong(limit: request.text.count - 1))
            }
        }
        return try await withListeningServer(service) { _ in
            let options = try MMCLIOptions.parse(["--socket", path])
            return try await withDeadline(seconds: 30) { try await body(options) }
        }
    }
}

@Suite("Declared errors: generated types, the wire, and the CLI")
struct DeclaredErrorTests {
    @Test("the contract verifies clean and each signature serves the flattened errors")
    func contract() throws {
        let breaks = try Vault.contract.verify(against: Vault.self).get()
        for line in breaks { Issue.record("mismatch: \(line)") }
        #expect(breaks == [])
        let sealed = TypeSchema.UnionCase(
            name: "sealed",
            fields: [],
            description: "The vault is sealed"
        )
        let full = TypeSchema.UnionCase(
            name: "full",
            fields: [.init(key: 0, name: "capacity", type: .int)],
            description: "The vault holds as much as it can"
        )
        #expect(
            try Vault.put.signature().get().errors
                == .union(cases: [
                    sealed, full,
                    .init(
                        name: "conflict",
                        fields: [.init(key: 0, name: "existing", type: .string)]
                    ),
                    .init(
                        name: "tooLong",
                        fields: [
                            .init(key: 0, name: "limit", type: .int),
                            .init(key: 1, name: "hint", type: .optional(.string)),
                        ]
                    ),
                ])
        )
        #expect(try Vault.list.signature().get().errors == .union(cases: [sealed]))
        #expect(try Vault.load.signature().get().errors == .union(cases: [sealed, full]))
        #expect(Vault.PutError.declaredErrors == (try Vault.put.signature().get().errors))
    }

    @Test("each case exits with the code its contract pins; an unknown case exits 1")
    func exitCodes() {
        #expect(Vault.PutError.sealed.exitCode == 10)
        #expect(Vault.PutError.conflict(Vault.Conflict(existing: "x")).exitCode == 11)
        #expect(Vault.PutError.full(Vault.Full(capacity: 1)).exitCode == 12)
        #expect(Vault.PutError.tooLong(limit: 1, hint: nil).exitCode == 13)
        #expect(Vault.PutError.unknown("later").exitCode == 1)
    }

    @Test("a declared error's line is its case, its description and its fields")
    func messages() {
        #expect(
            MMCLIFailure.message(for: Vault.PutError.full(Vault.Full(capacity: 3)))
                == #"full: The vault holds as much as it can {"capacity":3}"#
        )
        #expect(MMCLIFailure.message(for: Vault.PutError.sealed) == "sealed: The vault is sealed")
        #expect(
            MMCLIFailure.message(for: Vault.PutError.tooLong(limit: 5, hint: nil))
                == #"tooLong {"limit":5}"#
        )
        #expect(
            MMCLIFailure.message(for: Vault.PutError.tooLong(limit: 5, hint: "cut"))
                == #"tooLong {"hint":"cut","limit":5}"#
        )
        #expect(MMCLIFailure.message(for: Vault.PutError.unknown("later")) == "later")
    }

    @Test("unwrap throws the pinned exit code, or the protocol failure's")
    func unwrap() {
        #expect(throws: ExitCode(11)) {
            try MMCLIFailure.unwrap(
                Result<Int, MMDeclaredCallError<Vault.PutError>>.failure(
                    .declared(.conflict(Vault.Conflict(existing: "x")))
                ),
                method: "vault.put",
                entity: "vault"
            )
        }
        #expect(throws: ExitCode(77)) {
            try MMCLIFailure.unwrap(
                Result<Int, MMDeclaredCallError<Vault.PutError>>.failure(.undeclared(.denied)),
                method: "vault.put",
                entity: "vault"
            )
        }
        let undeclared = MMDeclaredCallError<Vault.PutError>.undeclared(.denied)
        #expect(
            undeclared.message(method: "vault.put", entity: "locked")
                == "denied: vault.put on locked"
        )
    }

    @Test("an input command reports a declared error with its pinned code")
    func inputCommandError() {
        let declared = MMCLIError.declaredCall(
            MMDeclaredCallError<Vault.NoteError>.declared(.tooLong(limit: 4)),
            method: "vault.note",
            entity: "vault"
        )
        #expect(declared.exitCode == ExitCode(13))
        #expect(declared.errorDescription == #"tooLong {"limit":4}"#)
        let undeclared = MMCLIError.declaredCall(
            MMDeclaredCallError<Vault.NoteError>.undeclared(.denied),
            method: "vault.note",
            entity: "locked"
        )
        #expect(undeclared.exitCode == ExitCode(77))
        #expect(undeclared.errorDescription == "denied: vault.note on locked")
    }

    @Test("every declared case crosses the wire typed; a denial stays undeclared")
    func unary() async throws {
        let vault = cliTestEntity("vault")
        let results = try await withVaultServer { options in
            try await MMCLIRunner.invoke(options) { client in
                var results: [Result<Vault.PutResponse, MMDeclaredCallError<Vault.PutError>>] = []
                for key in ["sealed", "full", "conflict", "tooLong", "fine"] {
                    results.append(
                        await client.call(Vault.put, on: vault, Vault.PutRequest(key: key))
                    )
                }
                results.append(
                    await client.call(
                        Vault.put,
                        on: cliTestEntity("locked"),
                        Vault.PutRequest(key: "fine")
                    )
                )
                return results
            }
        }
        #expect(
            results == [
                .failure(.declared(.sealed)),
                .failure(.declared(.full(Vault.Full(capacity: 3)))),
                .failure(.declared(.conflict(Vault.Conflict(existing: "old")))),
                .failure(.declared(.tooLong(limit: 5, hint: "shorter"))),
                .success(Vault.PutResponse(count: 1)),
                .failure(.undeclared(.denied)),
            ]
        )
    }

    @Test("a case an older build does not know arrives as unknown, keeping its name")
    func unknownCase() async throws {
        let result = try await withVaultServer { options in
            try await MMCLIRunner.invoke(options) { client in
                await client.call(
                    OldVault.put,
                    on: cliTestEntity("vault"),
                    OldVault.PutRequest(key: "tooLong")
                )
            }
        }
        #expect(result == .failure(.declared(.unknown("tooLong"))))
        guard case .failure(.declared(let error)) = result else { return }
        #expect(error.caseName == "tooLong")
    }

    @Test("the three stream shapes end with their declared error")
    func streams() async throws {
        let vault = cliTestEntity("vault")
        let (listed, listResult, loadResult, synced, syncResult) = try await withVaultServer {
            options in
            try await MMCLIRunner.invoke(options) { client in
                let list = await client.call(Vault.list, on: vault, Vault.ListRequest())
                var listed: [String] = []
                for await item in list { listed.append(item.key) }
                let listResult = await list.result()

                let load = await client.call(Vault.load, on: vault, Vault.LoadRequest())
                for key in ["a", "b"] { _ = await load.send(Vault.LoadRequestItem(key: key)) }
                await load.finish()
                let loadResult = await load.result()

                let sync = await client.call(Vault.sync, on: vault, Vault.SyncRequest())
                _ = await sync.outbound.send(Vault.SyncRequestItem(key: "x"))
                await sync.outbound.finish()
                var synced: [String] = []
                for await item in sync.inbound { synced.append(item.key) }
                let syncResult = await sync.inbound.result()
                return (listed, listResult, loadResult, synced, syncResult)
            }
        }
        #expect(listed == ["first"])
        #expect(listResult == .failure(.declared(.sealed)))
        #expect(loadResult == .failure(.declared(.full(Vault.Full(capacity: 2)))))
        #expect(synced == ["x"])
        #expect(syncResult == .failure(.declared(.full(Vault.Full(capacity: 1)))))
    }
}
