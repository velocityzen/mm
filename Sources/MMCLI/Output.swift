import Foundation

/// The one place MMCLI writes stdout/stderr. Rendering is pure
/// (``render(_:format:)`` returns a `String` so tests pin exact output); the
/// write path is deliberately thin. The only other IO in this module is the
/// `Input` folder, which reads files and stdin (``MMCLIInput``) for input
/// commands and streaming commands alike.
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
    /// of: the tool's per-type ``Format(_:_:)-(_,(T)->String)`` entry (bound
    /// in ``MMCLIDefaults/formatters``); the type's own
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

    /// Renders one element of a stream. Above the first one, under
    /// ``OutputFormat/text``, goes its formatter's header, if it has one (see
    /// ``Format(_:header:_:)``).
    public static func renderStreamElement<T: Encodable>(
        _ value: T,
        format: OutputFormat,
        first: Bool
    ) throws -> String {
        let rendered = try Self.render(value, format: format)
        guard first,
            format == .text,
            let header = MMCLIDefaults.current.formatters.header(for: T.self)
        else {
            return rendered
        }

        return header + "\n" + rendered
    }

    /// ``emit(_:format:)`` for one element of a stream, with its header above
    /// the first (see ``renderStreamElement(_:format:first:)``).
    public static func emitStreamElement<T: Encodable>(_ value: T, format: OutputFormat, first: Bool) {
        do {
            let rendered = try Self.renderStreamElement(value, format: format, first: first)
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
