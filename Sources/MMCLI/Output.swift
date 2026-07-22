import Foundation

#if !canImport(Darwin)
import NIOCore
import NIOPosix
import Synchronization
#endif

/// The one place MMCLI touches stdout/stderr (and, via
/// `MMCLIStandardInputLines`, stdin). Rendering is pure
/// (``render(_:format:)`` returns a `String` so tests pin exact output); the
/// write path is deliberately thin. No other file in this module performs IO
/// — auditable by grepping for `FileHandle`.
///
/// Rendering leans on two verified facts about macro-generated types: wire
/// enums are `String`-raw (they encode as their case names), and generated
/// structs' `Int`-raw `CodingKeys` carry case-name `stringValue`s — so
/// `JSONEncoder` prints named keys, not integers.
public struct MMCLIOutput: Sendable {
    /// Renders a value in the given format, without a trailing newline.
    /// `sortedKeys` keeps output deterministic and diff-friendly.
    /// ``OutputFormat/raw`` currently renders as compact JSON (a dedicated
    /// raw renderer is a later phase; the flag exists so scripts written
    /// today keep working). ``OutputFormat/text`` renders through the first
    /// of: the tool's per-type ``Format(_:_:)`` entry (bound in
    /// ``MMCLIDefaults/formatters``); the type's own
    /// `CustomStringConvertible` conformance — the Swift-native way to give
    /// a generated response or element its text form, no registry needed
    /// (`extension Journal.ReadResponse: CustomStringConvertible { ... }`);
    /// else compact JSON. Stream elements and terminals alike; the `json`
    /// formats never consult either.
    public static func render<T: Encodable>(
        _ value: T,
        format: OutputFormat
    ) throws -> String {
        if format == .text {
            if let rendered = MMCLIDefaults.current.formatters.render(value) {
                return rendered
            }
            if let convertible = value as? any CustomStringConvertible {
                return convertible.description
            }
        }
        let encoder = JSONEncoder()
        switch format {
            case .json, .raw, .text:
                encoder.outputFormatting = [.sortedKeys]
            case .jsonPretty:
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        }
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    /// Renders the value and writes it to stdout as one line. An encoding
    /// failure (effectively unreachable for the generated wire types, which
    /// contain no non-finite floats) is reported on stderr instead of
    /// producing partial stdout output.
    public static func emit<T: Encodable>(_ value: T, format: OutputFormat) {
        do {
            let rendered = try Self.render(value, format: format)
            Self.write(rendered + "\n", to: .standardOutput)
        } catch {
            Self.note("output encoding failed: \(error)")
        }
    }

    /// Writes already-rendered output to stdout as one line. The raw-call
    /// escape hatch renders its own JSON text (schema-ordered keys, exact
    /// integer kinds — see `MMCLIDynamicJSONText`); every typed result still
    /// goes through ``emit(_:format:)``.
    public static func emitText(_ rendered: String) {
        Self.write(rendered + "\n", to: .standardOutput)
    }

    /// Writes a one-line diagnostic to stderr. Results go to stdout via
    /// ``emit(_:format:)``; everything meant for humans goes here.
    public static func note(_ message: String) {
        Self.write(message + "\n", to: .standardError)
    }

    /// The single write seam. A failed write (e.g. a closed pipe downstream)
    /// is ignored: there is nowhere left to report it.
    private static func write(_ text: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(text.utf8))
    }
}

/// The stdin seam for streaming commands: a `Sendable` line sequence over
/// standard input. The type is stateless — the underlying reader is only
/// created inside `makeAsyncIterator()`, on the consuming task — which is
/// what makes it legal to hand across the structured-concurrency boundaries
/// in `MMCLIStreamDriver`. Reading is fully async (never a blocking
/// `readLine` on a cooperative thread) and observes task cancellation, so a
/// driver can unpark a reader that is still waiting on the terminal's
/// arrival.
///
/// On Darwin the reader is `FileHandle.AsyncBytes.lines`. corelibs-foundation
/// has neither `AsyncBytes` nor `AsyncLineSequence`, so on Linux each line is
/// one blocking `readLine` on NIO's singleton blocking thread pool, and the
/// await races task cancellation: a cancelled consumer resumes with `nil`
/// immediately (the pool thread finishes its read and the line is discarded —
/// the driver is abandoning the stream anyway). Pull-per-line keeps the
/// Darwin path's demand semantics: stdin is never slurped ahead of the
/// credit-gated sender.
struct MMCLIStandardInputLines: AsyncSequence, Sendable {
    typealias Element = String

    #if canImport(Darwin)
    struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

        mutating func next() async throws -> String? {
            try await self.base.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: FileHandle.standardInput.bytes.lines.makeAsyncIterator())
    }
    #else
    /// A resume-once cell: the first of {pool result, cancellation} resumes
    /// the parked read; an outcome that arrives before the continuation parks
    /// is cached and replayed at park time.
    private final class LineCell: Sendable {
        private enum State {
            /// Nothing has happened yet.
            case initial
            /// The consumer is parked awaiting the first outcome.
            case parked(CheckedContinuation<String?, Never>)
            /// An outcome arrived before the consumer parked.
            case pending(String?)
            /// Resumed; late outcomes are dropped.
            case done
        }

        private let state = Mutex(State.initial)

        func park(_ continuation: CheckedContinuation<String?, Never>) {
            let immediate: String?? = self.state.withLock { current -> String?? in
                switch current {
                    case .initial:
                        current = .parked(continuation)
                        return .none
                    case .pending(let value):
                        current = .done
                        return .some(value)
                    case .parked, .done:
                        preconditionFailure("stdin line cell parked twice")
                }
            }
            if let immediate { continuation.resume(returning: immediate) }
        }

        func resume(with value: String?) {
            let parked: CheckedContinuation<String?, Never>? = self.state.withLock { current in
                switch current {
                    case .initial:
                        current = .pending(value)
                        return nil
                    case .parked(let continuation):
                        current = .done
                        return continuation
                    case .pending, .done:
                        // The second of {pool result, cancellation}: dropped.
                        return nil
                }
            }
            parked?.resume(returning: value)
        }
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        mutating func next() async throws -> String? {
            guard !Task.isCancelled else { return nil }
            let cell = LineCell()
            NIOThreadPool.singleton.runIfActive(
                eventLoop: NIOSingletons.posixEventLoopGroup.any()
            ) {
                readLine(strippingNewline: true)
            }.whenComplete { result in
                cell.resume(with: (try? result.get()) ?? nil)
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    cell.park(continuation)
                }
            } onCancel: {
                cell.resume(with: nil)
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }
    #endif
}
