import ArgumentParser

/// A generated command with a `cli: .input` request field. It reads that
/// field's values from an ``MMCLIInput``, and an ``Input(_:_:)`` entry in the
/// tool's ``MMCLI(_:)`` block decides what the command does with them.
public protocol MMCLIInputCommand: AsyncParsableCommand {
    /// The call's request: the command's parsed arguments.
    associatedtype Request: Codable & Sendable
    /// The command's CLI options, declared in the call's `CLI(...) { ... }`
    /// block: parsed options that never reach the server. Generated commands
    /// nest an `Options` group, empty when the call declares none.
    associatedtype Options: Sendable
    /// What one call returns: the call's terminal response.
    associatedtype Response: Codable & Sendable
}

/// The call of an input command, on the command's target entity and
/// connection. Call it with a whole request, or with just the input field's
/// value, which takes every other field from the command's arguments. A
/// server-stream call prints its elements as they arrive, then returns its
/// terminal.
public struct MMCLIInputCall<Request: Sendable, Response: Sendable>: Sendable {
    /// The command's parsed arguments, the input field empty.
    let arguments: Request
    private let field: WritableKeyPath<Request, String> & Sendable
    private let perform: @Sendable (Request) async -> Result<Response, MMCLIError>

    /// A call that takes the fields it isn't given from `arguments`, and sets
    /// the value it is given at `field`. Tests use it to drive an `Input`
    /// body without a server.
    public init(
        arguments: Request,
        input field: WritableKeyPath<Request, String> & Sendable,
        _ perform: @escaping @Sendable (Request) async -> Result<Response, MMCLIError>
    ) {
        self.arguments = arguments
        self.field = field
        self.perform = perform
    }

    /// Calls with `request` as it is.
    public func callAsFunction(_ request: Request) async -> Result<Response, MMCLIError> {
        await self.perform(request)
    }

    /// Calls with the command's arguments and the input field set to `value`.
    public func callAsFunction(_ value: String) async -> Result<Response, MMCLIError> {
        var request = self.arguments
        request[keyPath: self.field] = value
        return await self.perform(request)
    }
}

/// One ``Input(_:_:)`` entry: a command's body, with its types erased so the
/// tool's entries share one table.
public struct MMCLIInputEntry: Sendable {
    let key: ObjectIdentifier
    /// Runs the body with the input, the call, and the options.
    let run: @Sendable (MMCLIInput, any Sendable, any Sendable, OutputFormat) async -> ExitCode?
}

/// The tool's ``Input(_:_:)`` entries, by command type.
public struct MMCLIInputs: Sendable, ExpressibleByArrayLiteral {
    var entries: [ObjectIdentifier: MMCLIInputEntry]

    public init() {
        self.entries = [:]
    }

    public init(arrayLiteral elements: MMCLIInputEntry...) {
        self.init(entries: elements)
    }

    init(entries: [MMCLIInputEntry]) {
        self.entries = Dictionary(
            entries.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in
                preconditionFailure("MMCLI declares Input(...) twice for one command")
            }
        )
    }

    func entry<Command: MMCLIInputCommand>(for command: Command.Type) -> MMCLIInputEntry? {
        self.entries[ObjectIdentifier(command)]
    }
}

/// Declares what an input command does with its input. Without an entry the
/// command makes one call per non-blank line (see ``MMCLIInputRunner``).
///
/// `body` gets the input as bytes (and `lines`), the command's parsed
/// arguments as the request (the input field empty), and the call. Parse
/// the input with the arguments, then call with a value (`append(line)`) or
/// a whole request (`append(request)`). For the call's CLI options too,
/// use the overload whose body also takes `options`. `body` returns the results as an
/// `AsyncSequence` of `Result`s. An FPPipe `Pipe` is one. The command prints
/// each success with
/// ``MMCLIOutput/emit(_:format:)`` and reports each failure on stderr.
/// A failure that belongs to one value (an application error, exit 1;
/// malformed data, exit 65; any error that isn't an ``MMCLIError``, exit 1)
/// lets the rest go on. Any other failure, such as a denial or a lost
/// connection, ends the run. The command then exits with the first failure's
/// code. The first Ctrl-C ends the input, so the run finishes the work in
/// flight and exits 130.
///
/// ```swift
/// Input(Search.RootCommand.self) { input, arguments, search in
///     Pipe<Search.RootResponse, MMCLIError> {
///         FromResult(input.lines)
///         Filter { (query: String) in !query.isEmpty && !query.hasPrefix("#") }
///         Map { (query: String) in Search.RootRequest(query: query, limit: arguments.limit) }
///         AsyncFlatMapKeepOrder(concurrency: 4) { (request: Search.RootRequest) in await search(request) }
///     }
/// }
/// ```
public func Input<
    Command: MMCLIInputCommand,
    Output: Encodable & Sendable,
    Failure: Error,
    Results: AsyncSequence & Sendable
>(
    _ command: Command.Type,
    _ body:
        @escaping @Sendable (
            MMCLIInput, Command.Request, MMCLIInputCall<Command.Request, Command.Response>
        ) -> Results
) -> MMCLIInputEntry where Results.Element == Result<Output, Failure>, Results.Failure == Never {
    Input(command) { input, arguments, _, call in body(input, arguments, call) }
}

/// ``Input(_:_:)-(_,(MMCLIInput,_,MMCLIInputCall<_,_>)->_)`` for a body that
/// also reads the call's CLI options (`CLI(...) { Field(...) }`): options parsed from the command line
/// that never reach the server, such as a delimiter to split lines with.
///
/// ```swift
/// Input(Journal.AppendCommand.self) { input, arguments, options, append in
///     Pipe<Journal.AppendResponse, MMCLIError> {
///         FromResult(input.lines)
///         Map { (line: String) in line.hasPrefix(options.urgentPrefix) ? urgent(line, arguments) : line }
///         ...
///     }
/// }
/// ```
public func Input<
    Command: MMCLIInputCommand,
    Output: Encodable & Sendable,
    Failure: Error,
    Results: AsyncSequence & Sendable
>(
    _ command: Command.Type,
    _ body:
        @escaping @Sendable (
            MMCLIInput, Command.Request, Command.Options, MMCLIInputCall<Command.Request, Command.Response>
        ) -> Results
) -> MMCLIInputEntry where Results.Element == Result<Output, Failure>, Results.Failure == Never {
    MMCLIInputEntry(key: ObjectIdentifier(command)) { input, call, options, format in
        guard let call = call as? MMCLIInputCall<Command.Request, Command.Response>,
            let options = options as? Command.Options
        else {
            preconditionFailure("Input(\(Command.self)) got another command's call")
        }
        return await MMCLIInputRunner.drain(body(input, call.arguments, options, call), format: format)
    }
}
