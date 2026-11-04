import ArgumentParser
import MMClient
import ProgramStatus
import Synchronization
import Testing

@testable import MMCLI

/// The reports a command sends, in order.
private final class ReportLog: Sendable {
    private let storage = Mutex<[StatusReport]>([])

    var reports: [StatusReport] { self.storage.withLock { $0 } }

    func defaults(_ statuses: [MMCLIStatusEntry] = []) -> MMCLIDefaults {
        MMCLIDefaults(
            programStatus: MMCLIProgramStatus(
                send: { report in self.storage.withLock { $0.append(report) } },
                statuses: statuses
            )
        )
    }
}

private func echo(
    on entity: String,
    _ options: MMCLIOptions
) async throws -> CLIEchoResponse {
    try await MMCLIRunner.invoke(options, method: "echo.run", entity: entity) { client in
        try MMCLIFailure.unwrap(
            await client.call(
                CLITestMethods.echo,
                on: cliTestEntity(entity),
                CLIEchoRequest(value: 1)
            ),
            method: "echo.run",
            entity: entity
        )
    }
}

@Suite("Program status: a command's record on the terminal")
struct ProgramStatusTests {
    @Test("a call that succeeds reports working, then done, naming the call")
    func success() async throws {
        let log = ReportLog()
        try await withCLIServer { options in
            try await withCLI(log.defaults()) {
                _ = try await echo(on: "echo", options)
            }
        }
        #expect(log.reports == [.working("echo.run on echo"), .done("echo.run on echo")])
    }

    @Test("a call that fails reports error with the line written to stderr")
    func failure() async throws {
        let log = ReportLog()
        try await withCLIServer { options in
            await withCLI(log.defaults()) {
                await #expect(throws: ExitCode(77)) {
                    _ = try await echo(on: "locked", options)
                }
            }
        }
        #expect(
            log.reports == [.working("echo.run on locked"), .error("denied: echo.run on locked")]
        )
    }

    @Test("a daemon that is not running reports error with the connect hint")
    func connectFailure() async throws {
        let log = ReportLog()
        let options = try MMCLIOptions.parse(["--socket", "/nonexistent/mm.sock"])
        _ = await withCLI(log.defaults()) {
            await #expect(throws: ExitCode(69)) {
                _ = try await echo(on: "echo", options)
            }
        }
        let reports = log.reports
        #expect(reports.first == .working("echo.run on echo"))
        #expect(reports.count == 2)
        #expect(reports.last?.state == .error)
        #expect(reports.last?.message?.hasPrefix("connect failed: ") == true)
    }

    @Test("each element a stream delivers reports through its Status entry")
    func streamElements() async throws {
        let log = ReportLog()
        let entry = On(CLIStreamItem.self) { item in .done("item \(item.value)", title: "box") }
        try await withCLIServer { options in
            try await withCLI(log.defaults([entry])) {
                let summary = try await MMCLIRunner.invoke(
                    options,
                    method: "box.follow",
                    entity: "box"
                ) {
                    client in
                    let handle = await client.call(
                        CLITestMethods.follow,
                        on: cliTestEntity("box"),
                        CLIFollowRequest(count: 3)
                    )
                    return try await MMCLIStreamDriver.inboundStdio(
                        handle,
                        format: .json,
                        method: "box.follow",
                        entity: "box"
                    )
                }
                #expect(summary.count == 3)
            }
        }
        #expect(
            log.reports == [
                .working("box.follow on box"),
                .done("item 0", title: "box"),
                .done("item 1", title: "box"),
                .done("item 2", title: "box"),
                .done("box.follow on box"),
            ]
        )
    }

    @Test("a Status entry that returns nil leaves the record as it is")
    func skippedElements() async throws {
        let log = ReportLog()
        let entry = On { (item: CLIStreamItem) in
            item.value.isMultiple(of: 2) ? nil : .working("odd \(item.value)")
        }
        try await withCLIServer { options in
            try await withCLI(log.defaults([entry])) {
                _ = try await MMCLIRunner.invoke(options) { client in
                    let handle = await client.call(
                        CLITestMethods.follow,
                        on: cliTestEntity("box"),
                        CLIFollowRequest(count: 4)
                    )
                    return try await MMCLIStreamDriver.inboundStdio(
                        handle,
                        format: .json,
                        method: "box.follow",
                        entity: "box"
                    )
                }
            }
        }
        #expect(log.reports == [.working(), .working("odd 1"), .working("odd 3"), .done()])
    }

    @Test("an input run that ends on a failure reports error, not done")
    func inputFailure() async throws {
        let log = ReportLog()
        try await withCLIServer { options in
            await withCLI(log.defaults()) {
                await #expect(throws: ExitCode(77)) {
                    try await MMCLIInputRunner.run(
                        EchoInputCommand.self,
                        source: .value("1"),
                        connection: options,
                        method: "echo.run",
                        entity: "locked",
                        arguments: EchoLine(line: "", scale: 1),
                        options: EchoOptions(multiplier: 1),
                        input: \.line
                    ) { client, request in
                        await client.call(
                            CLITestMethods.echo,
                            on: cliTestEntity("locked"),
                            CLIEchoRequest(value: Int(request.line) ?? -1)
                        )
                        .mapError { .call($0, method: "echo.run", entity: "locked") }
                    }
                }
            }
        }
        #expect(
            log.reports == [.working("echo.run on locked"), .error("denied: echo.run on locked")]
        )
    }

    @Test("an input that is not a terminal never reports blocked")
    func notATerminal() throws {
        let log = ReportLog()
        let session = MMCLIStatusSession(try #require(log.defaults().programStatus), activity: nil)
        session.awaitLines(from: MMCLIInput(text: "one\ntwo"))
        #expect(log.reports.isEmpty)
    }

    @Test("without ProgramStatusReporting nothing is reported and nothing changes")
    func off() async throws {
        try await withCLIServer { options in
            let response = try await echo(on: "echo", options)
            #expect(response.value == 1)
        }
    }
}

@Suite("Program status: how a command's end reads")
struct ProgramStatusEndTests {
    struct Ending: Sendable, CustomTestStringConvertible {
        let name: String
        let outcome: Result<Void, any Error>
        let interrupted: Bool
        let diagnostic: String?
        let expected: StatusReport

        var testDescription: String { self.name }
    }

    static let endings: [Ending] = [
        Ending(
            name: "success is done",
            outcome: .success(()),
            interrupted: false,
            diagnostic: nil,
            expected: .done("call on x")
        ),
        Ending(
            name: "success after Ctrl-C is idle",
            outcome: .success(()),
            interrupted: true,
            diagnostic: nil,
            expected: .idle("call on x")
        ),
        Ending(
            name: "exit 130 is idle",
            outcome: .failure(ExitCode(130)),
            interrupted: true,
            diagnostic: "cancelled",
            expected: .idle("call on x")
        ),
        Ending(
            name: "cancellation is idle",
            outcome: .failure(CancellationError()),
            interrupted: false,
            diagnostic: nil,
            expected: .idle("call on x")
        ),
        Ending(
            name: "exit 0 is done",
            outcome: .failure(ExitCode(0)),
            interrupted: false,
            diagnostic: nil,
            expected: .done("call on x")
        ),
        Ending(
            name: "a failure carries its stderr line",
            outcome: .failure(ExitCode(77)),
            interrupted: false,
            diagnostic: "denied: call on x",
            expected: .error("denied: call on x")
        ),
        Ending(
            name: "a failure after Ctrl-C is still an error",
            outcome: .failure(ExitCode(1)),
            interrupted: true,
            diagnostic: "error 3: boom",
            expected: .error("error 3: boom")
        ),
        Ending(
            name: "a silent failure names the call",
            outcome: .failure(ExitCode(70)),
            interrupted: false,
            diagnostic: nil,
            expected: .error("call on x")
        ),
        Ending(
            name: "any other error describes itself",
            outcome: .failure(ValidationError("bad line")),
            interrupted: false,
            diagnostic: nil,
            expected: .error("bad line")
        ),
    ]

    @Test("the record a finished command leaves", arguments: ProgramStatusEndTests.endings)
    func ending(_ ending: Ending) {
        let report = MMCLIStatusSession.report(
            for: ending.outcome,
            interrupted: ending.interrupted,
            diagnostic: ending.diagnostic,
            activity: "call on x"
        )
        #expect(report == ending.expected)
    }

    @Test("a call is named by method and entity, or the method alone")
    func activity() {
        #expect(
            MMCLIStatusSession.activity(method: "journal.read", entity: "journal.notes")
                == "journal.read on journal.notes"
        )
        #expect(MMCLIStatusSession.activity(method: "search", entity: "") == "search")
        #expect(MMCLIStatusSession.activity(method: nil, entity: "journal.notes") == nil)
    }
}

@Suite("Program status: reports fitted to the protocol")
struct ProgramStatusFitTests {
    @Test("control characters collapse onto one line")
    func singleLine() {
        #expect(
            MMCLIProgramStatus.fitted("remote failed:\n\tdisk full\n", bytes: 2048)
                == "remote failed: disk full"
        )
        #expect(MMCLIProgramStatus.fitted("\n\t ", bytes: 2048) == nil)
    }

    @Test("long text is cut to the byte limit with an ellipsis, never mid-character")
    func cut() throws {
        let text = String(repeating: "é", count: 2000)  // 4000 bytes
        let fitted = try #require(MMCLIProgramStatus.fitted(text, bytes: 2048))
        #expect(fitted.utf8.count <= 2048)
        #expect(fitted.hasSuffix("…"))
        #expect(fitted.dropLast().allSatisfy { $0 == "é" })
        // An exact fit is kept whole.
        let exact = String(repeating: "a", count: 2048)
        #expect(MMCLIProgramStatus.fitted(exact, bytes: 2048) == exact)
    }

    @Test("a fitted report always encodes")
    func encodes() throws {
        let report = MMCLIProgramStatus.fitted(
            .error(
                String(repeating: "line\n", count: 1000),
                title: String(repeating: "t", count: 500)
            )
        )
        #expect(report.title?.utf8.count ?? 0 <= MMCLIProgramStatus.titleBytes)
        #expect(throws: Never.self) { try StatusEncoder.encode(report).get() }
    }
}

@Suite("Program status: the MMCLI declaration")
struct ProgramStatusDeclarationTests {
    @Test("the Status entries in the block are keyed by type, the last one winning")
    func assembled() async {
        let skipped = true
        let defaults = await MMCLI {
            ProgramStatusReporting(app: "tool") {
                On(CLIStreamItem.self) { .done("first \($0.value)") }
                On { (summary: CLIStreamSummary) in .done("\(summary.count)") }
                if !skipped {
                    On(CLIEchoResponse.self) { .done("\($0.value)") }
                }
                On(CLIStreamItem.self) { .done("last \($0.value)") }
            }
        } run: {
            MMCLIDefaults.current
        }
        let statuses = defaults.programStatus?.statuses ?? [:]
        #expect(statuses.count == 2)
        #expect(
            statuses[ObjectIdentifier(CLIStreamItem.self)]?(CLIStreamItem(value: 7))
                == .done("last 7")
        )
    }

    @Test("a block-less ProgramStatusReporting reports the lifecycle only")
    func withoutEntries() async {
        let defaults = await MMCLI {
            ProgramStatusReporting(app: "tool")
        } run: {
            MMCLIDefaults.current
        }
        #expect(defaults.programStatus?.statuses.isEmpty == true)
    }

    // Exit tests run their body in a child process; Swift Testing has them
    // on macOS, Linux and Windows only.
    #if os(macOS) || os(Linux) || os(Windows)
    @Test("an app outside the protocol's charset is programmer error")
    func invalidApp() async {
        await #expect(processExitsWith: .failure) {
            _ = ProgramStatusReporting(app: "my tool")
        }
    }

    @Test("declaring ProgramStatusReporting twice is programmer error")
    func duplicate() async {
        await #expect(processExitsWith: .failure) {
            await MMCLI {
                ProgramStatusReporting(app: "one")
                ProgramStatusReporting(app: "two")
            } run: {
            }
        }
    }
    #endif
}
