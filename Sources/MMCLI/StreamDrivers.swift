import FP
import MMClient

/// The streaming glue between a generated CLI command and a live stream
/// handle: each driver runs one call to its terminal, wiring stdin/stdout to
/// the handle's element surfaces and Ctrl-C to the protocol's graceful STOP /
/// END / CANCEL controls (via ``MMCLISignals/withGracefulSigint(onFirst:onSecond:_:)``).
///
/// The public entry points own only the SIGINT wiring; the actual piping
/// lives in internal `*Stdio` functions whose line *source* is injectable, so
/// tests drive them with in-memory sequences against a real server while the
/// SIGINT flow itself stays a thin, manually-verified wrapper.
///
/// Per the stream-handle contract (StreamHandles.swift): element sequences are
/// iterated from a task that awaits no other traffic on the connection,
/// `result()` resolves exactly once, and `stop()` is advisory — the call still
/// runs to its terminal, which is unwrapped through
/// ``MMCLIFailure/unwrap(_:method:entity:)``.
public enum MMCLIStreamDriver {
    // MARK: - Inbound (server stream)

    /// Server-stream driver: emits each element via
    /// ``MMCLIOutput/emit(_:format:)``, then returns the unwrapped terminal.
    /// First SIGINT: graceful `handle.stop()`, keep draining (items in flight
    /// still arrive); second SIGINT: `handle.cancel()`.
    public static func inbound<Element: Codable & Sendable, Response: Codable & Sendable>(
        _ handle: InboundStreamHandle<Element, Never, Response>,
        format: OutputFormat, method: String, entity: String
    ) async throws -> Response {
        try await MMCLISignals.withGracefulSigint(
            onFirst: { await handle.stop() },
            onSecond: { await handle.cancel() }
        ) {
            try await Self.inboundStdio(
                handle,
                format: format,
                method: method,
                entity: entity
            )
        }
    }

    /// ``inbound(_:format:method:entity:)`` with the terminal as a `Result`
    /// rather than a thrown exit, for an input command's call: one failed
    /// call need not end the run (see ``MMCLIInputRunner``).
    public static func inboundResult<Element: Codable & Sendable, Response: Codable & Sendable>(
        _ handle: InboundStreamHandle<Element, Never, Response>,
        format: OutputFormat
    ) async -> Result<Response, MMCallError> {
        await Result.fromAsync {
            try await MMCLISignals.withGracefulSigint(
                onFirst: { await handle.stop() },
                onSecond: { await handle.cancel() }
            ) {
                await Self.drainInbound(handle, format: format)
            }
        }
        // The signal watcher fails only when its group is cancelled.
        .mapError { _ in MMCallError.cancelled }
        .flatMap { $0 }
    }

    /// The signal-free body of ``inbound(_:format:method:entity:)``: drain the
    /// element sequence to stdout, then unwrap the terminal.
    static func inboundStdio<Element: Codable & Sendable, Response: Codable & Sendable>(
        _ handle: InboundStreamHandle<Element, Never, Response>,
        format: OutputFormat, method: String, entity: String
    ) async throws -> Response {
        try MMCLIFailure.unwrap(await Self.drainInbound(handle, format: format), method: method, entity: entity)
    }

    /// Drains the element sequence to stdout, then returns the terminal.
    private static func drainInbound<Element: Codable & Sendable, Response: Codable & Sendable>(
        _ handle: InboundStreamHandle<Element, Never, Response>,
        format: OutputFormat
    ) async -> Result<Response, MMCallError> {
        var first = true
        for await element in handle {
            MMCLIOutput.emitStreamElement(element, format: format, first: first)
            first = false
        }
        return await handle.result()
    }

    // MARK: - Outbound (client stream)

    /// Client-stream driver: reads stdin's ``MMCLIInput/lines`` (pulled one
    /// chunk at a time on NIO's blocking pool, never on a cooperative thread),
    /// skips empty lines, maps each through `makeElement` (which throws
    /// `ValidationError` for bad input), and sends through the credit-gated
    /// handle. A stdin read failure (exit 74) or an over-long line (65)
    /// abandons the call. On `.peerStopped` it stops
    /// reading; on `.callEnded`/`.connectionClosed` it stops and lets
    /// `result()` surface the error; on stdin EOF it calls `finish()`. First
    /// SIGINT: `finish()` (graceful END — the terminal still arrives; the
    /// pipe's next send sees `.callEnded` and stops reading); second:
    /// `cancel()`.
    public static func outbound<Element: Codable & Sendable, Response: Codable & Sendable>(
        _ handle: OutboundStreamHandle<Element, Never, Response>,
        makeElement: @Sendable @escaping (String) throws -> Element,
        method: String, entity: String
    ) async throws -> Response {
        try await MMCLISignals.withGracefulSigint(
            onFirst: { await handle.finish() },
            onSecond: { await handle.cancel() }
        ) {
            try await Self.outboundStdio(
                handle,
                lines: MMCLIInput.standardInput.lines,
                makeElement: makeElement,
                method: method,
                entity: entity
            )
        }
    }

    /// The signal-free body of ``outbound(_:makeElement:method:entity:)``. The
    /// reader runs as a structured child while this task awaits the terminal,
    /// so an early terminal (denial, remote failure, connection death) is
    /// never stuck behind a reader still parked on its line source: once the
    /// terminal resolves, the group cancels the reader and the cancellation
    /// ends the line sequence.
    static func outboundStdio<
        Element: Codable & Sendable,
        Response: Codable & Sendable,
        Lines: AsyncSequence & Sendable
    >(
        _ handle: OutboundStreamHandle<Element, Never, Response>,
        lines: Lines,
        makeElement: @Sendable @escaping (String) throws -> Element,
        method: String,
        entity: String
    ) async throws -> Response where Lines.Element == Result<String, MMCLIError>, Lines.Failure == Never {
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask {
                try await Self.pipe(
                    input: lines,
                    map: makeElement,
                    output: handle
                )
            }
            let result = await handle.result()
            // The terminal is in; a reader still parked on its source has
            // nothing left to contribute.
            tasks.cancelAll()
            // Propagates the pipe's ValidationError (bad line) ahead of the
            // .cancelled terminal that its handle.cancel() produced.
            try await tasks.waitForAll()
            return try MMCLIFailure.unwrap(result, method: method, entity: entity)
        }
    }

    // MARK: - Bidirectional

    /// Bidirectional driver: one child task pipes stdin → outbound (same
    /// rules as ``outbound(_:makeElement:method:entity:)``), the other drains
    /// inbound → ``MMCLIOutput/emit(_:format:)``; the shared terminal is
    /// returned. First SIGINT: `inbound.stop()` + `outbound.finish()`;
    /// second: cancel.
    public static func bidirectional<
        RequestElement: Codable & Sendable,
        ResponseElement: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ handle: BidirectionalStreamHandle<RequestElement, ResponseElement, Response>,
        makeElement: @Sendable @escaping (String) throws -> RequestElement,
        format: OutputFormat,
        method: String,
        entity: String
    ) async throws -> Response {
        try await MMCLISignals.withGracefulSigint(
            onFirst: {
                await handle.inbound.stop()
                await handle.outbound.finish()
            },
            onSecond: { await handle.inbound.cancel() }
        ) {
            try await Self.bidirectionalStdio(
                handle,
                lines: MMCLIInput.standardInput.lines,
                makeElement: makeElement,
                format: format,
                method: method,
                entity: entity
            )
        }
    }

    /// The signal-free body of ``bidirectional(_:makeElement:format:method:entity:)``.
    /// The outbound pipe is the child task; *this* task drains the inbound
    /// sequence (two tasks, per the handle's head-of-line contract) — draining
    /// inline guarantees every buffered element is emitted before the group
    /// is cancelled, which a drain-as-child racing `result()` would not.
    static func bidirectionalStdio<
        RequestElement: Codable & Sendable,
        ResponseElement: Codable & Sendable,
        Response: Codable & Sendable,
        Lines: AsyncSequence & Sendable
    >(
        _ handle: BidirectionalStreamHandle<RequestElement, ResponseElement, Response>,
        lines: Lines,
        makeElement: @Sendable @escaping (String) throws -> RequestElement,
        format: OutputFormat,
        method: String,
        entity: String
    ) async throws -> Response where Lines.Element == Result<String, MMCLIError>, Lines.Failure == Never {
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            let outbound = handle.outbound
            tasks.addTask {
                try await Self.pipe(
                    input: lines,
                    map: makeElement,
                    output: outbound
                )
            }
            var first = true
            for await element in handle.inbound {
                MMCLIOutput.emitStreamElement(element, format: format, first: first)
                first = false
            }
            let result = await handle.inbound.result()
            tasks.cancelAll()
            try await tasks.waitForAll()
            return try MMCLIFailure.unwrap(result, method: method, entity: entity)
        }
    }

    // MARK: - Shared stdin pipe

    /// The shared line → element pipe behind `outbound` and the request half
    /// of `bidirectional`. Empty lines are skipped. `.peerStopped` ends
    /// reading gracefully; `.callEnded` (also what a send sees after the
    /// first SIGINT's `finish()`) and `.connectionClosed` end reading and
    /// leave the diagnosis to the caller's `result()`. Every normal exit —
    /// including EOF and a cancellation that arrives after the terminal,
    /// which ends the lines — sends END via `finish()` (idempotent). A `map`
    /// throw, or a failed line (reported on stderr, thrown as its exit code),
    /// abandons the call via `cancel()` so the terminal resolves promptly,
    /// then rethrows.
    private static func pipe<
        Element: Codable & Sendable,
        InboundElement: Codable & Sendable,
        Response: Codable & Sendable,
        Lines: AsyncSequence & Sendable
    >(
        input: Lines,
        map: (String) throws -> Element,
        output: OutboundStreamHandle<Element, InboundElement, Response>
    ) async throws where Lines.Element == Result<String, MMCLIError>, Lines.Failure == Never {
        do {
            for await line in input {
                let text = try Self.unwrap(line)
                if text.isEmpty {
                    continue
                }

                let element = try map(text)
                guard await output.send(element) == .sent else {
                    break
                }
            }
            await output.finish()
        } catch {
            await output.cancel()
            throw error
        }
    }

    /// A line, or its failure reported on stderr and thrown as its exit code.
    private static func unwrap(_ line: Result<String, MMCLIError>) throws -> String {
        switch line {
            case .success(let text):
                return text
            case .failure(let error):
                MMCLIOutput.note(error.localizedDescription)
                throw error.exitCode
        }
    }
}
