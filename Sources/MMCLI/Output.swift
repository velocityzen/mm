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
    /// formats never consult either. An optional renders as what it holds,
    /// so an optional response takes its wrapped type's entry; nil renders
    /// as `null`.
    public static func render<T: Encodable>(
        _ value: T,
        format: OutputFormat
    ) throws -> String {
        if let wrapped = Self.unwrapped(value) {
            return try Self.render(wrapped, format: format)
        }
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
    ///
    /// With ``ProgramStatusReporting(app:_:)``, the value's ``On(_:_:)``
    /// entry reports it to the terminal too.
    public static func emit<T: Encodable>(_ value: T, format: OutputFormat) {
        do {
            let rendered = try Self.render(value, format: format)
            Self.write(rendered + "\n", to: .standardOutput)
        } catch {
            Self.note("output encoding failed: \(error)")
        }
        Self.reportStatus(value)
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
        Self.reportStatus(value)
    }

    /// Writes already-rendered output to stdout as one line. The raw-call
    /// escape hatch renders its own JSON text (schema-ordered keys, exact
    /// integer kinds — see `MMCLIDynamicJSONText`); every typed result still
    /// goes through ``emit(_:format:)``.
    public static func emitText(_ rendered: String) {
        Self.write(rendered + "\n", to: .standardOutput)
    }

    /// Writes a one-line diagnostic to stderr. Results go to stdout via
    /// ``emit(_:format:)``; everything meant for humans goes here. The last
    /// one is the reason a failed command's `error` record gives.
    public static func note(_ message: String) {
        Self.write(message + "\n", to: .standardError)
        MMCLIStatusSession.current?.diagnose(message)
    }

    /// The single write seam. A failed write (e.g. a closed pipe downstream)
    /// is ignored: there is nowhere left to report it.
    private static func write(_ text: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// Sends the report `value`'s ``On(_:_:)`` entry makes of it. An
    /// optional reports as what it holds, so an optional response takes its
    /// wrapped type's entry; nil reports nothing.
    private static func reportStatus<T>(_ value: T) {
        if let wrapped = Self.unwrapped(value) {
            return Self.reportStatus(wrapped)
        }
        MMCLIDefaults.current.programStatus?.report(value)
    }

    /// What `value` holds when it is an optional that holds something.
    private static func unwrapped<T>(_ value: T) -> (any Encodable)? {
        (value as? any OptionalOutput)?.wrappedOutput
    }
}

/// `Optional` seen through to what it holds, for the output entry points.
private protocol OptionalOutput {
    var wrappedOutput: (any Encodable)? { get }
}

extension Optional: OptionalOutput where Wrapped: Encodable {
    fileprivate var wrappedOutput: (any Encodable)? { self.map { $0 } }
}
