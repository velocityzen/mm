import ArgumentParser
import MMCLI
import MMSchema
import MMTestSupport
import Testing

/// Calls with declared targets: the namespace's, a call's one entity, root
/// alone, and root with a pattern.
enum Shelves: MethodNamespace {
    #schema("shelves") {
        CLI(.enabled)
        Target("shelves.*")
        Call("list") {
            Access { .read }
        }
        Call("log") {
            Access { .read }
            Target("shelves.log")
        }
        Call("tree") {
            Access { .read }
            Target(.root)
        }
        Call("scan") {
            Access { .read }
            Target(.root, "tenants.*.shelves")
        }
    }
}

@Suite("Commands for calls with declared targets")
struct TargetCommandTests {
    @Test("the entity's help states the target and what omitting it means")
    func entityHelp() {
        // Help wraps at the terminal's width: read it as one line.
        func help(_ command: any ParsableCommand.Type) -> String {
            command.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        #expect(
            help(Shelves.ListCommand.self).contains("Target entity (dotted path) within shelves.*")
        )
        #expect(
            help(Shelves.LogCommand.self).contains("omit for shelves.log, the call's one target")
        )
        #expect(help(Shelves.TreeCommand.self).contains("Omit: the call targets the whole tree"))
        #expect(
            help(Shelves.ScanCommand.self).contains(
                "within tenants.*.shelves; omit for the whole tree"
            )
        )
    }

    @Test("completion offers the target's literal prefix")
    func entityCompletion() {
        let script = Shelves.ListCommand.completionScript(for: .fish)
        #expect(script.contains("-fka 'shelves.'"))
        #expect(!Shelves.TreeCommand.completionScript(for: .fish).contains("-fka"))
    }

    @Test("an entity outside the target is refused before connecting, naming the target")
    func refusedBeforeConnecting() async throws {
        // No server listens here: a refusal that tried to connect would
        // fail with the connect error instead.
        let command = try Shelves.ListCommand.parse([
            "--socket", "/nonexistent/shelves.sock", "books",
        ])
        await #expect {
            try await command.run()
        } throws: { error in
            "\(error)" == "entity 'books' is outside shelves.list's target shelves.*"
        }
    }

    @Test("the early check infers a sole entity and refuses what the target does not admit")
    func earlyCheck() throws {
        let log = try MMCLIFailure.entity(nil, method: "shelves.log", target: ["shelves.log"])
        #expect(log.argument == "shelves.log")
        #expect(try MMCLIFailure.entity("", method: "shelves.tree", target: [.root]).entity.isRoot)
        #expect {
            try MMCLIFailure.entity(nil, method: "shelves.list", target: ["shelves.*"])
        } throws: { error in
            "\(error)" == "shelves.list needs a target entity within shelves.*"
        }
        #expect {
            try MMCLIFailure.entity("shelves", method: "shelves.list", target: ["shelves.*"])
        } throws: { error in
            "\(error)" == "entity 'shelves' is outside shelves.list's target shelves.*"
        }
    }

    @Test("mm call checks the discovered target: a sole entity is inferred, another refused")
    func rawCallChecksTheTarget() async throws {
        try await withCLIServer { options in
            guard let path = options.socket else {
                Issue.record("harness options carry no socket path")
                return
            }
            let schema = try await MMCLIRunner.invoke(options) { client in
                try MMCLIFailure.unwrap(
                    await client.discoverSchema(scope: .root),
                    method: "server.schema",
                    entity: ""
                )
            }
            #expect(schema.methods.first { $0.name == "peek.run" }?.target == ["peek"])
            #expect(schema.methods.first { $0.name == "echo.run" }?.target == nil)

            let inferred = try MMCLIRawCall.parse([
                "--socket", path, "peek.run", "--params", #"{"value": 4}"#,
            ])
            try await inferred.run()
            let outside = try MMCLIRawCall.parse([
                "--socket", path, "peek.run", "box", "--params", #"{"value": 4}"#,
            ])
            await #expect(throws: ExitCode(64)) { try await outside.run() }
        }
    }
}
