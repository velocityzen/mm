import ArgumentParser
import FPPipe
import MMClient
import Synchronization
import Testing

@testable import MMCLI

/// The request of `EchoInputCommand`: the input field `line`, and `scale`,
/// an argument a body can parse lines with.
struct EchoLine: Codable, Sendable {
    var line: String
    var scale: Int
}

/// The CLI options of `EchoInputCommand`: a setting only the body reads.
struct EchoOptions: Sendable {
    var multiplier: Int
}

/// An input command over `echo.run`, standing in for a generated one.
struct EchoInputCommand: MMCLIInputCommand {
    typealias Request = EchoLine
    typealias Options = EchoOptions
    typealias Response = CLIEchoResponse

    init() {}

    func run() async throws {}
}

/// `MMCLIInputRunner.run` end to end: the input bracket, the connection, an
/// `Input(...)` body or the default, and the exit code.
@Suite("Input commands against a live server")
struct InputRunTests {
    @Test("an Input body built as a Pipe decides the work: filter, concurrency, order")
    func pipeBody() async throws {
        let echoed = Echoed()
        let entry = Input(EchoInputCommand.self) { input, _, echo in
            Pipe<CLIEchoResponse, MMCLIError> {
                FromResult(input.lines)
                Filter { (line: String) in !line.isEmpty && !line.hasPrefix("#") }
                AsyncFlatMapKeepOrder(concurrency: 4) { (line: String) in await echo(line) }
                Tap { (response: CLIEchoResponse) in echoed.add(response.value) }
            }
        }
        try await withTemporaryFile("1\n# skipped\n\n2\n3\n4\n5") { path in
            try await withCLIServer { options in
                try await withCLI(MMCLIDefaults(inputs: [entry])) {
                    try await run(.file(path: path), connection: options)
                }
            }
        }
        #expect(echoed.values == [1, 2, 3, 4, 5])
    }

    @Test("a body parses the input with the arguments and calls with whole requests")
    func argumentsParseInput() async throws {
        let echoed = Echoed()
        let entry = Input(EchoInputCommand.self) { input, arguments, echo in
            Pipe<CLIEchoResponse, MMCLIError> {
                FromResult(input.lines)
                CompactMap { (line: String) in Int(line) }
                Map { (number: Int) in EchoLine(line: String(number * arguments.scale), scale: arguments.scale) }
                AsyncFlatMap { (request: EchoLine) in await echo(request) }
                Tap { (response: CLIEchoResponse) in echoed.add(response.value) }
            }
        }
        try await withCLIServer { options in
            try await withCLI(MMCLIDefaults(inputs: [entry])) {
                try await run(.value("1\nskip\n2\n3"), arguments: EchoLine(line: "", scale: 10), connection: options)
            }
        }
        #expect(echoed.values == [10, 20, 30])
    }

    @Test("a body reads the CLI options, which never reach the server")
    func optionsParseInput() async throws {
        let echoed = Echoed()
        let entry = Input(EchoInputCommand.self) { input, _, options, echo in
            Pipe<CLIEchoResponse, MMCLIError> {
                FromResult(input.lines)
                CompactMap { (line: String) in Int(line) }
                AsyncFlatMap { (number: Int) in await echo(String(number * options.multiplier)) }
                Tap { (response: CLIEchoResponse) in echoed.add(response.value) }
            }
        }
        try await withCLIServer { options in
            try await withCLI(MMCLIDefaults(inputs: [entry])) {
                try await run(.value("1\n2\n3"), options: EchoOptions(multiplier: 3), connection: options)
            }
        }
        #expect(echoed.values == [3, 6, 9])
    }

    @Test("a body's own error is reported and the run exits 1")
    func bodyFailure() async throws {
        struct Rejected: Error {}
        let entry = Input(EchoInputCommand.self) { input, _, _ in
            input.lines.map { (line: Result<String, MMCLIError>) -> Result<String, Rejected> in
                switch line {
                    case .success("bad"), .failure: return .failure(Rejected())
                    case .success(let text): return .success(text)
                }
            }
        }
        try await withCLIServer { options in
            await withCLI(MMCLIDefaults(inputs: [entry])) {
                await #expect(throws: ExitCode(1)) {
                    try await run(.value("ok\nbad\nok"), connection: options)
                }
            }
        }
    }

    @Test("without an Input body, a file runs one call per line, other fields from the arguments")
    func defaultRun() async throws {
        let seen = Seen()
        try await withTemporaryFile("1\n2\n\n3\n") { path in
            try await withCLIServer { options in
                try await run(.file(path: path), arguments: EchoLine(line: "", scale: 7), connection: options) {
                    seen.add("\($0.line)x\($0.scale)")
                }
            }
        }
        #expect(seen.values == ["1x7", "2x7", "3x7"])
    }

    @Test("a denial ends the run at once with 77")
    func denied() async throws {
        let seen = Seen()
        try await withCLIServer { options in
            await #expect(throws: ExitCode(77)) {
                try await run(.value("1\n2"), on: "locked", connection: options) { seen.add($0.line) }
            }
        }
        // A command-line value is one verbatim call.
        #expect(seen.values == ["1\n2"])
    }

    @Test("an unreadable --input exits 66 before connecting")
    func unreadable() async throws {
        let connection = try MMCLIOptions.parse(["--socket", "/nonexistent/mm.sock"])
        await #expect(throws: ExitCode(66)) {
            try await run(.file(path: "/nonexistent/input.txt"), connection: connection)
        }
    }
}

/// Runs `EchoInputCommand`: each call is `echo.run` on `entity`, with the
/// request's line as the integer value, after `observe` sees the request.
private func run(
    _ source: MMCLIInputSource,
    arguments: EchoLine = EchoLine(line: "", scale: 1),
    options: EchoOptions = EchoOptions(multiplier: 1),
    on entity: String = "echo",
    connection: MMCLIOptions,
    observe: @escaping @Sendable (EchoLine) -> Void = { _ in }
) async throws {
    try await MMCLIInputRunner.run(
        EchoInputCommand.self, source: source, connection: connection,
        arguments: arguments, options: options, input: \.line
    ) { client, request in
        observe(request)
        return await client.call(
            CLITestMethods.echo, on: cliTestEntity(entity), CLIEchoRequest(value: Int(request.line) ?? -1)
        )
        .mapError { .call($0, method: "echo.run", entity: entity) }
    }
}

/// The values echoed back, across the pipe's concurrent stages.
private final class Echoed: Sendable {
    private let storage = Mutex<[Int]>([])

    var values: [Int] { self.storage.withLock { $0 } }

    func add(_ value: Int) { self.storage.withLock { $0.append(value) } }
}
