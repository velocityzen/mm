import ArgumentParser
import FP
import Foundation
import MMClient
import MMSchema

/// The runtime behind a `cli: .input` request field. The generated command
/// takes the field's value as its positional, or reads it from
/// `--input <path>` (`-` for stdin), and hands it to
/// ``run(_:source:connection:verifying:arguments:options:input:call:)``.
///
/// - With an ``Input(_:_:)`` entry for the command, its body gets the input
///   and the call and decides the work.
/// - Without one, a positional value makes one call, verbatim. An input makes
///   one call per line, in order, each line trimmed of surrounding
///   whitespace and blank lines skipped. Under ``OutputFormat/text``, each
///   call's output follows a `==> value <==` heading, blank-line separated,
///   the way `head(1)` heads several files. The JSON formats print each
///   call's output as is.
///
/// Either way, failures that belong to one value (exit 1 or 65) are reported
/// and the run goes on, and the command exits with the first one's code. Any
/// other failure ends the run. The first Ctrl-C ends the input: the work in
/// flight finishes (a stream winds down through its own driver) and the
/// command exits 130.
public enum MMCLIInputRunner {
    /// Opens the input, connects, and runs the command's ``Input(_:_:)``
    /// body, or the one-call-per-line default. `arguments` is the request the
    /// command's arguments describe, with the input field at `field` empty,
    /// and `options` its CLI options. `call` makes one call with a request.
    /// An unreadable input exits 66 before anything connects.
    public static func run<Command: MMCLIInputCommand>(
        _ command: Command.Type,
        source: MMCLIInputSource,
        connection: MMCLIOptions,
        verifying contract: SchemaDeclaration? = nil,
        arguments: Command.Request,
        options: Command.Options,
        input field: WritableKeyPath<Command.Request, String> & Sendable,
        call: @escaping @Sendable (MMClientConnection, Command.Request) async -> Result<Command.Response, MMCLIError>
    ) async throws {
        let format = connection.output
        let entry = MMCLIDefaults.current.inputs.entry(for: command)
        let withInput = source.open()
        let outcome = await withInput { input in
            let command = await Result.fromAsync {
                try await MMCLIRunner.invoke(connection, verifying: contract) { client in
                    let bound = MMCLIInputCall(arguments: arguments, input: field) { request in
                        await call(client, request)
                    }
                    return try await Self.interruptible(input) {
                        if let entry {
                            return await entry.run(input, bound, options, format)
                        }
                        return await Self.batch(source, input: input, call: bound, format: format)
                    }
                }
            }
            return .success(command)
        }
        switch outcome {
            case .failure(let error):
                throw Self.report(error)
            case .success(let command):
                if let code = try command.get() {
                    throw code
                }
        }
    }

    /// Prints each success and reports each failure, ending early on one
    /// that doesn't belong to a single value. Returns the exit code for the
    /// failures, if any.
    static func drain<Results: AsyncSequence, Output: Encodable, Failure: Error>(
        _ results: Results,
        format: OutputFormat
    ) async -> ExitCode? where Results.Element == Result<Output, Failure>, Results.Failure == Never {
        var firstFailure: ExitCode?
        for await result in results {
            guard let code = Self.settle(result, format: format) else { continue }
            guard Self.continues(after: code) else { return code }
            firstFailure = firstFailure ?? code
        }
        return firstFailure
    }

    /// The default without an ``Input(_:_:)`` entry; see the type's overview.
    static func batch<Request: Sendable, Response: Encodable & Sendable>(
        _ source: MMCLIInputSource,
        input: MMCLIInput,
        call: MMCLIInputCall<Request, Response>,
        format: OutputFormat
    ) async -> ExitCode? {
        guard case .value(let value) = source else {
            return await Self.drain(
                MMCLIInputBatch(lines: input.lines, call: call, format: format),
                format: format
            )
        }
        return Self.settle(await call(value), format: format)
    }

    /// Runs `body` with the first Ctrl-C ending `input`, as if at end of
    /// file. An interrupted run exits 130 unless it ended on a failure of its
    /// own.
    static func interruptible(
        _ input: MMCLIInput,
        _ body: @escaping @Sendable @concurrent () async -> ExitCode?
    ) async throws -> ExitCode? {
        let code = try await MMCLISignals.withGracefulSigint(onFirst: { input.interrupt() }, body)
        guard input.isInterrupted, code.map(Self.continues(after:)) ?? true else {
            return code
        }
        return ExitCode(130)
    }

    /// Failures that belong to one value rather than to the run.
    static func continues(after code: ExitCode) -> Bool {
        code.rawValue == 1 || code.rawValue == 65
    }

    /// Prints a success; reports a failure and returns its exit code.
    private static func settle<Output: Encodable, Failure: Error>(
        _ result: Result<Output, Failure>,
        format: OutputFormat
    ) -> ExitCode? {
        switch result {
            case .success(let output):
                MMCLIOutput.emit(output, format: format)
                return nil
            case .failure(let error):
                return Self.report(error)
        }
    }

    /// Writes the failure to stderr and returns its exit code: an
    /// ``MMCLIError``'s own, else 1.
    private static func report(_ error: any Error) -> ExitCode {
        MMCLIOutput.note(error.localizedDescription)
        return (error as? MMCLIError)?.exitCode ?? ExitCode(1)
    }
}

/// The default run over an input: one call per trimmed, non-blank line.
struct MMCLIInputBatch<Request: Sendable, Response: Sendable>: AsyncSequence, Sendable {
    typealias Element = Result<Response, MMCLIError>
    typealias Failure = Never

    let lines: MMCLIInputLines
    let call: MMCLIInputCall<Request, Response>
    let format: OutputFormat

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lines: self.lines.makeAsyncIterator(), call: self.call, format: self.format)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        typealias Failure = Never

        var lines: MMCLIInputLines.AsyncIterator
        let call: MMCLIInputCall<Request, Response>
        let format: OutputFormat
        var first = true

        mutating func next() async -> Result<Response, MMCLIError>? {
            while let line = await self.lines.next() {
                switch line.map({ $0.trimmingWhitespace() }) {
                    case .failure(let error):
                        return .failure(error)
                    case .success(let value) where value.isEmpty:
                        continue
                    case .success(let value):
                        self.heading(value)
                        return await self.call(value)
                }
            }
            return nil
        }

        private mutating func heading(_ value: String) {
            guard self.format == .text else { return }
            MMCLIOutput.emitText((self.first ? "" : "\n") + "==> \(value) <==")
            self.first = false
        }
    }
}

extension String {
    fileprivate func trimmingWhitespace() -> String {
        let scalars = unicodeScalars
        guard let start = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
            let end = scalars.lastIndex(where: { !$0.properties.isWhitespace })
        else { return "" }
        return String(scalars[start...end])
    }
}
