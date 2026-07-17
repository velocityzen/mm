import ArgumentParser
import MMClient
import MMSchema
import Testing

@testable import MMCLI

/// End-to-end proofs against a real in-process server over a real unix
/// socket: the stream driver cores (line source injected — the public
/// entry points add only the SIGINT wiring, which stays manually verified),
/// discovery through `MMCLIRunner`, and the schema-driven raw-call path.
@Suite("Stream driver cores against a real server")
struct StreamDriverTests {
    @Test("followCore drains the element sequence and returns the terminal")
    func followHappyPath() async throws {
        try await withCLIServer { options in
            let summary = try await MMCLIRunner.invoke(options) { client in
                let handle = await client.call(
                    CLITestMethods.follow, on: cliTestEntity("box"), CLIFollowRequest(count: 5))
                return try await MMCLIStreamDriver.followCore(
                    handle, format: .json, method: "box.follow", entity: "box")
            }
            #expect(summary.count == 5)
        }
    }

    @Test("followCore surfaces an application-error terminal as ExitCode(1)")
    func followErrorTerminal() async throws {
        try await withCLIServer { options in
            await #expect(throws: ExitCode(1)) {
                _ = try await MMCLIRunner.invoke(options) { client in
                    let handle = await client.call(
                        CLITestMethods.followFailing,
                        on: cliTestEntity("box"),
                        CLIFollowRequest(count: 2)
                    )
                    return try await MMCLIStreamDriver.followCore(
                        handle, format: .json, method: "box.followFail", entity: "box")
                }
            }
            return ()
        }
    }

    @Test("feedCore sends every non-empty line, ENDs at EOF, returns the terminal")
    func feedHappyPath() async throws {
        try await withCLIServer { options in
            let (lines, continuation) = AsyncStream<String>.makeStream()
            continuation.yield("1")
            continuation.yield("")  // skipped
            continuation.yield("2")
            continuation.yield("3")
            continuation.finish()
            let summary = try await MMCLIRunner.invoke(options) { client in
                let handle = await client.call(
                    CLITestMethods.importItems, on: cliTestEntity("box"), CLIImportRequest())
                return try await MMCLIStreamDriver.feedCore(
                    handle,
                    lines: lines,
                    makeElement: { line in
                        guard let value = Int(line) else {
                            throw ValidationError("not a number: '\(line)'")
                        }
                        return CLIStreamItem(value: value)
                    },
                    method: "box.import",
                    entity: "box"
                )
            }
            #expect(summary.count == 3)
        }
    }

    @Test("feedCore propagates a makeElement ValidationError, not the cancelled terminal")
    func feedBadLine() async throws {
        try await withCLIServer { options in
            let (lines, continuation) = AsyncStream<String>.makeStream()
            continuation.yield("nope")
            await #expect(throws: ValidationError.self) {
                _ = try await MMCLIRunner.invoke(options) { client in
                    let handle = await client.call(
                        CLITestMethods.importItems, on: cliTestEntity("box"), CLIImportRequest())
                    return try await MMCLIStreamDriver.feedCore(
                        handle,
                        lines: lines,
                        makeElement: { line in
                            guard let value = Int(line) else {
                                throw ValidationError("not a number: '\(line)'")
                            }
                            return CLIStreamItem(value: value)
                        },
                        method: "box.import",
                        entity: "box"
                    )
                }
            }
            continuation.finish()
        }
    }

    @Test("feedCore's early terminal (denied) unparks a reader still waiting on lines")
    func feedEarlyTerminalUnparksReader() async throws {
        try await withCLIServer { options in
            // Never finished while the call runs: the reader stays parked on
            // its source, and only the driver's post-terminal cancellation
            // ends it. A hang here would trip the harness deadline.
            let (lines, holdOpen) = AsyncStream<String>.makeStream()
            await #expect(throws: ExitCode(77)) {
                _ = try await MMCLIRunner.invoke(options) { client in
                    let handle = await client.call(
                        CLITestMethods.importItems,
                        on: cliTestEntity("locked"),
                        CLIImportRequest()
                    )
                    return try await MMCLIStreamDriver.feedCore(
                        handle,
                        lines: lines,
                        makeElement: { _ in CLIStreamItem(value: 0) },
                        method: "box.import",
                        entity: "locked"
                    )
                }
            }
            holdOpen.finish()
        }
    }

    @Test("feedCore honors the stop-reading latch (the first-SIGINT seam) and still ENDs")
    func feedStopReadingLatch() async throws {
        try await withCLIServer { options in
            let stop = StreamStopFlag()
            stop.stop()  // as the first SIGINT would, before any line is read
            let (lines, continuation) = AsyncStream<String>.makeStream()
            continuation.yield("1")
            continuation.finish()
            let summary = try await MMCLIRunner.invoke(options) { client in
                let handle = await client.call(
                    CLITestMethods.importItems, on: cliTestEntity("box"), CLIImportRequest())
                return try await MMCLIStreamDriver.feedCore(
                    handle,
                    lines: lines,
                    makeElement: { _ in CLIStreamItem(value: 0) },
                    stopReading: stop,
                    method: "box.import",
                    entity: "box"
                )
            }
            #expect(summary.count == 0)  // nothing sent, but END went out and the terminal arrived
        }
    }

    @Test("duplexCore pumps lines outbound, drains the echo inbound, returns the shared terminal")
    func duplexHappyPath() async throws {
        try await withCLIServer { options in
            let (lines, continuation) = AsyncStream<String>.makeStream()
            continuation.yield("1")
            continuation.yield("")  // skipped
            continuation.yield("2")
            continuation.yield("3")
            continuation.finish()
            let summary = try await MMCLIRunner.invoke(options) { client in
                let handle = await client.call(
                    CLITestMethods.pipe, on: cliTestEntity("box"), CLIImportRequest())
                return try await MMCLIStreamDriver.duplexCore(
                    handle,
                    lines: lines,
                    makeElement: { line in
                        guard let value = Int(line) else {
                            throw ValidationError("not a number: '\(line)'")
                        }
                        return CLIStreamItem(value: value)
                    },
                    format: .json,
                    method: "box.pipe",
                    entity: "box"
                )
            }
            #expect(summary.count == 3)
        }
    }

    @Test("duplexCore propagates a makeElement ValidationError")
    func duplexBadLine() async throws {
        try await withCLIServer { options in
            let (lines, continuation) = AsyncStream<String>.makeStream()
            continuation.yield("wat")
            await #expect(throws: ValidationError.self) {
                _ = try await MMCLIRunner.invoke(options) { client in
                    let handle = await client.call(
                        CLITestMethods.pipe, on: cliTestEntity("box"), CLIImportRequest())
                    return try await MMCLIStreamDriver.duplexCore(
                        handle,
                        lines: lines,
                        makeElement: { line in
                            guard let value = Int(line) else {
                                throw ValidationError("not a number: '\(line)'")
                            }
                            return CLIStreamItem(value: value)
                        },
                        format: .json,
                        method: "box.pipe",
                        entity: "box"
                    )
                }
            }
            continuation.finish()
        }
    }
}

@Suite("Discovery and the raw-call path against a real server")
struct GenericCommandTests {
    @Test("discovery through MMCLIRunner serves signatures and stream shapes")
    func discoverFunctionLevel() async throws {
        try await withCLIServer { options in
            let schema = try await MMCLIRunner.invoke(options) { client in
                try MMCLIFailure.unwrap(
                    await client.discoverSchema(scope: .root),
                    method: "rpc.schema", entity: "")
            }
            #expect(schema.fingerprint != 0)
            let names = schema.methods.map(\.name)
            #expect(names.contains("echo.run"))
            #expect(names.contains("rpc.schema"))  // rpc prefix is traversable in the fixture
            let follow = schema.methods.first(where: { $0.name == "box.follow" })
            #expect(follow?.responseStream != nil)
            #expect(follow?.requestStream == nil)
            let pipe = schema.methods.first(where: { $0.name == "box.pipe" })
            #expect(pipe?.requestStream != nil)
            #expect(pipe?.responseStream != nil)
        }
    }

    @Test("the discover command runs end-to-end (parse → connect → emit)")
    func discoverCommandRuns() async throws {
        try await withCLIServer { options in
            guard let path = options.socket else {
                Issue.record("harness options carry no socket path")
                return
            }
            let command = try MMCLIDiscover.parse(["--socket", path])
            #expect(command.scope == "")
            try await command.run()
        }
    }

    @Test("the raw-call flow round-trips a dynamic request and response")
    func rawCallFunctionLevel() async throws {
        try await withCLIServer { options in
            let tree = try await MMCLIRunner.invoke(options) { client in
                let schema = try MMCLIFailure.unwrap(
                    await client.discoverSchema(scope: .root),
                    method: "rpc.schema", entity: "")
                guard let signature = schema.methods.first(where: { $0.name == "echo.run" })
                else {
                    throw CLITestFailure(description: "echo.run not discovered")
                }
                #expect(signature.requestStream == nil)
                #expect(signature.responseStream == nil)
                let json = try MMCLIDynamicTree.parse(jsonText: #"{"value": 7, "note": "hey"}"#)
                let request = try MMCLIDynamicRequest(
                    schema: signature.request, definitions: schema.types, json: json)
                let response = try MMCLIFailure.unwrap(
                    await MMCLIDynamicResponse.$schema.withValue(
                        (signature.response, schema.types)
                    ) {
                        await client.call(
                            Method<MMCLIDynamicRequest, MMCLIDynamicResponse>(
                                name: "echo.run", access: .read),
                            on: cliTestEntity("echo"),
                            request
                        )
                    },
                    method: "echo.run", entity: "echo")
                return response.tree
            }
            #expect(tree == .object([.init("value", .int(7)), .init("note", .string("hey"))]))
        }
    }

    @Test("the raw-call flow omits an absent optional on both directions")
    func rawCallOptionalAbsent() async throws {
        try await withCLIServer { options in
            let tree = try await MMCLIRunner.invoke(options) { client in
                let schema = try MMCLIFailure.unwrap(
                    await client.discoverSchema(scope: .root),
                    method: "rpc.schema", entity: "")
                guard let signature = schema.methods.first(where: { $0.name == "echo.run" })
                else {
                    throw CLITestFailure(description: "echo.run not discovered")
                }
                let json = try MMCLIDynamicTree.parse(jsonText: #"{"value": 9}"#)
                let request = try MMCLIDynamicRequest(
                    schema: signature.request, definitions: schema.types, json: json)
                let response = try MMCLIFailure.unwrap(
                    await MMCLIDynamicResponse.$schema.withValue(
                        (signature.response, schema.types)
                    ) {
                        await client.call(
                            Method<MMCLIDynamicRequest, MMCLIDynamicResponse>(
                                name: "echo.run", access: .read),
                            on: cliTestEntity("echo"),
                            request
                        )
                    },
                    method: "echo.run", entity: "echo")
                return response.tree
            }
            #expect(tree == .object([.init("value", .int(9))]))
        }
    }

    @Test("the call command runs end-to-end and refuses what it must")
    func rawCallCommandRuns() async throws {
        try await withCLIServer { options in
            guard let path = options.socket else {
                Issue.record("harness options carry no socket path")
                return
            }
            // Happy path: parse → discover → dynamic call → rendered JSON.
            let good = try MMCLIRawCall.parse([
                "--socket", path, "echo.run", "echo",
                "--params", #"{"value": 3, "note": "cli"}"#,
            ])
            try await good.run()

            // Unknown method: one stderr line, exit 64.
            let unknown = try MMCLIRawCall.parse(["--socket", path, "nope.method", "echo"])
            await #expect(throws: ExitCode(64)) { try await unknown.run() }

            // Streaming method: refused with a pointer to generated commands.
            let streaming = try MMCLIRawCall.parse(["--socket", path, "box.follow", "box"])
            await #expect(throws: ExitCode(64)) { try await streaming.run() }

            // Params that fail schema validation: a usage error, no call made.
            let invalid = try MMCLIRawCall.parse([
                "--socket", path, "echo.run", "echo",
                "--params", #"{"value": "not a number"}"#,
            ])
            await #expect(throws: ValidationError.self) { try await invalid.run() }
            return ()
        }
    }
}
