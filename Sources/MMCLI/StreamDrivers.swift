import MMClient
import Synchronization

/// The streaming glue between a generated CLI command and a live stream
/// handle: each driver runs one call to its terminal, wiring stdin/stdout to
/// the handle's element surfaces and Ctrl-C to the protocol's graceful STOP /
/// END / CANCEL controls (via ``MMCLISignals/withGracefulSigint(onFirst:onSecond:_:)``).
///
/// The public entry points own only the SIGINT wiring; the actual pumping
/// lives in internal `*Core` functions whose line *source* is injectable, so
/// tests drive them with in-memory sequences against a real server while the
/// SIGINT flow itself stays a thin, manually-verified wrapper.
///
/// Per the stream-handle contract (StreamHandles.swift): element sequences are
/// iterated from a task that awaits no other traffic on the connection,
/// `result()` resolves exactly once, and `stop()` is advisory — the call still
/// runs to its terminal, which is unwrapped through
/// ``MMCLIFailure/unwrap(_:method:entity:)``.
public enum MMCLIStreamDriver {
    /// Server-stream driver: emits each element via
    /// ``MMCLIOutput/emit(_:format:)``, then returns the unwrapped terminal.
    /// First SIGINT: graceful `handle.stop()`, keep draining (items in flight
    /// still arrive); second SIGINT: `handle.cancel()`.
    public static func follow<Element: Codable & Sendable, Response: Codable & Sendable>(
        _ handle: InboundStreamHandle<Element, Never, Response>,
        format: OutputFormat, method: String, entity: String
    ) async throws -> Response {
        try await MMCLISignals.withGracefulSigint(
            onFirst: { await handle.stop() },
            onSecond: { await handle.cancel() }
        ) {
            try await Self.followCore(handle, format: format, method: method, entity: entity)
        }
    }

    /// Client-stream driver: reads stdin line by line (async — see
    /// `MMCLIStandardInputLines`; never a blocking `readLine` on a
    /// cooperative thread), skips empty lines, maps each through
    /// `makeElement` (which throws `ValidationError` for bad input), and
    /// sends through the credit-gated handle. On `.peerStopped` it stops
    /// reading; on `.callEnded`/`.connectionClosed` it stops and lets
    /// `result()` surface the error; on stdin EOF it calls `finish()`. First
    /// SIGINT: stop reading + `finish()` (graceful END — the terminal still
    /// arrives); second: `cancel()`.
    public static func feed<Element: Codable & Sendable, Response: Codable & Sendable>(
        _ handle: OutboundStreamHandle<Element, Never, Response>,
        makeElement: @Sendable @escaping (String) throws -> Element,
        method: String, entity: String
    ) async throws -> Response {
        let stopReading = StreamStopFlag()
        return try await MMCLISignals.withGracefulSigint(
            onFirst: {
                stopReading.stop()
                await handle.finish()
            },
            onSecond: { await handle.cancel() }
        ) {
            try await Self.feedCore(
                handle,
                lines: MMCLIStandardInputLines(),
                makeElement: makeElement,
                stopReading: stopReading,
                method: method,
                entity: entity
            )
        }
    }

    /// Bidirectional driver: one child task pumps stdin → outbound (same
    /// rules as ``feed(_:makeElement:method:entity:)``), the other drains
    /// inbound → ``MMCLIOutput/emit(_:format:)``; the shared terminal is
    /// returned. First SIGINT: `inbound.stop()` + `outbound.finish()`;
    /// second: cancel.
    public static func duplex<
        RequestElement: Codable & Sendable,
        ResponseElement: Codable & Sendable,
        Response: Codable & Sendable
    >(
        _ handle: BidirectionalStreamHandle<RequestElement, ResponseElement, Response>,
        makeElement: @Sendable @escaping (String) throws -> RequestElement,
        format: OutputFormat, method: String, entity: String
    ) async throws -> Response {
        let stopReading = StreamStopFlag()
        return try await MMCLISignals.withGracefulSigint(
            onFirst: {
                stopReading.stop()
                await handle.inbound.stop()
                await handle.outbound.finish()
            },
            onSecond: { await handle.inbound.cancel() }
        ) {
            try await Self.duplexCore(
                handle,
                lines: MMCLIStandardInputLines(),
                makeElement: makeElement,
                stopReading: stopReading,
                format: format,
                method: method,
                entity: entity
            )
        }
    }

    // MARK: - Testable cores (no SIGINT wiring, injectable line source)

    /// The signal-free body of ``follow(_:format:method:entity:)``: drain the
    /// element sequence to stdout, then unwrap the terminal.
    static func followCore<Element: Codable & Sendable, Response: Codable & Sendable>(
        _ handle: InboundStreamHandle<Element, Never, Response>,
        format: OutputFormat, method: String, entity: String
    ) async throws -> Response {
        for await element in handle {
            MMCLIOutput.emit(element, format: format)
        }
        return try MMCLIFailure.unwrap(await handle.result(), method: method, entity: entity)
    }

    /// The signal-free body of ``feed(_:makeElement:method:entity:)``. The
    /// reader runs as a structured child while this task awaits the terminal,
    /// so an early terminal (denial, remote failure, connection death) is
    /// never stuck behind a reader still parked on its line source: once the
    /// terminal resolves, the group cancels the reader and the cancellation
    /// ends the line sequence.
    static func feedCore<
        Element: Codable & Sendable,
        Response: Codable & Sendable,
        Lines: AsyncSequence & Sendable
    >(
        _ handle: OutboundStreamHandle<Element, Never, Response>,
        lines: Lines,
        makeElement: @Sendable @escaping (String) throws -> Element,
        stopReading: StreamStopFlag = StreamStopFlag(),
        method: String,
        entity: String
    ) async throws -> Response where Lines.Element == String {
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask {
                try await Self.pump(
                    lines: lines,
                    makeElement: makeElement,
                    stopReading: stopReading,
                    send: { await handle.send($0) },
                    finish: { await handle.finish() },
                    cancel: { await handle.cancel() }
                )
            }
            let result = await handle.result()
            // The terminal is in; a reader still parked on its source has
            // nothing left to contribute.
            tasks.cancelAll()
            // Propagates the pump's ValidationError (bad line) ahead of the
            // .cancelled terminal that its handle.cancel() produced.
            try await tasks.waitForAll()
            return try MMCLIFailure.unwrap(result, method: method, entity: entity)
        }
    }

    /// The signal-free body of ``duplex(_:makeElement:format:method:entity:)``.
    /// The outbound pump is the child task; *this* task drains the inbound
    /// sequence (two tasks, per the handle's head-of-line contract) — draining
    /// inline guarantees every buffered element is emitted before the group
    /// is cancelled, which a drain-as-child racing `result()` would not.
    static func duplexCore<
        RequestElement: Codable & Sendable,
        ResponseElement: Codable & Sendable,
        Response: Codable & Sendable,
        Lines: AsyncSequence & Sendable
    >(
        _ handle: BidirectionalStreamHandle<RequestElement, ResponseElement, Response>,
        lines: Lines,
        makeElement: @Sendable @escaping (String) throws -> RequestElement,
        stopReading: StreamStopFlag = StreamStopFlag(),
        format: OutputFormat,
        method: String,
        entity: String
    ) async throws -> Response where Lines.Element == String {
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            let outbound = handle.outbound
            tasks.addTask {
                try await Self.pump(
                    lines: lines,
                    makeElement: makeElement,
                    stopReading: stopReading,
                    send: { await outbound.send($0) },
                    finish: { await outbound.finish() },
                    cancel: { await outbound.cancel() }
                )
            }
            for await element in handle.inbound {
                MMCLIOutput.emit(element, format: format)
            }
            let result = await handle.inbound.result()
            tasks.cancelAll()
            try await tasks.waitForAll()
            return try MMCLIFailure.unwrap(result, method: method, entity: entity)
        }
    }

    /// The shared line → element pump for the outbound half of `feed` and
    /// `duplex`. Empty lines are skipped; `stopReading` (flipped by the first
    /// SIGINT) is checked per line. `.peerStopped` ends reading gracefully;
    /// `.callEnded`/`.connectionClosed` end reading and leave the diagnosis
    /// to the caller's `result()`. Every normal exit — including EOF and a
    /// cancellation that arrives after the terminal — sends END via `finish`
    /// (idempotent). A `makeElement` throw (or a failing source) abandons the
    /// call via `cancel` so the terminal resolves promptly, then rethrows.
    private static func pump<Element: Sendable, Lines: AsyncSequence & Sendable>(
        lines: Lines,
        makeElement: (String) throws -> Element,
        stopReading: StreamStopFlag,
        send: (Element) async -> StreamSendOutcome,
        finish: () async -> Void,
        cancel: () async -> Void
    ) async throws where Lines.Element == String {
        do {
            reading: for try await line in lines {
                if stopReading.isStopped { break }
                if line.isEmpty { continue }
                let element = try makeElement(line)
                switch await send(element) {
                    case .sent:
                        continue
                    case .peerStopped, .callEnded, .connectionClosed:
                        break reading
                }
            }
            await finish()
        } catch is CancellationError {
            // The driver cancelled a reader still parked on its source after
            // the terminal arrived; finishing then is a harmless no-op.
            await finish()
        } catch {
            await cancel()
            throw error
        }
    }
}

/// A one-way "stop reading stdin" latch, flipped by the first SIGINT and
/// polled by the pump between lines. A plain mutex-guarded Bool: the flag
/// must be settable from the signal watcher without suspending the pump.
final class StreamStopFlag: Sendable {
    private let stopped = Mutex(false)

    func stop() {
        self.stopped.withLock { $0 = true }
    }

    var isStopped: Bool {
        self.stopped.withLock { $0 }
    }
}
