import Foundation

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
    /// today keep working).
    public static func render<T: Encodable>(
        _ value: T,
        format: OutputFormat
    ) throws -> String {
        let encoder = JSONEncoder()
        switch format {
            case .json, .raw:
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
/// standard input. The type is stateless — the underlying
/// `FileHandle.AsyncBytes` reader is only created inside
/// `makeAsyncIterator()`, on the consuming task — which is what makes it
/// legal to hand across the structured-concurrency boundaries in
/// `MMCLIStreamDriver`. Reading is fully async (never a blocking `readLine`
/// on a cooperative thread) and observes task cancellation, so a driver can
/// unpark a reader that is still waiting on the terminal's arrival.
struct MMCLIStandardInputLines: AsyncSequence, Sendable {
    typealias Element = String

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

        mutating func next() async throws -> String? {
            try await self.base.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: FileHandle.standardInput.bytes.lines.makeAsyncIterator())
    }
}
