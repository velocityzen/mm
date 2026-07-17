import ArgumentParser
import Foundation
import MMSchema

/// The JSON edge of the raw-call escape hatch: `--params` text becomes a
/// *loose* `SchemaValue` (kinds approximate, member order arbitrary), and a
/// canonical tree renders back to deterministic JSON text.
///
/// The dynamic tree type itself now lives in MMSchema as `SchemaValue` —
/// schema-directed validation (`SchemaValue.validated(against:resolver:path:)`)
/// canonicalizes the loose parse, so the CLI keeps only the two edges: text
/// in, text out.
public typealias MMCLIDynamicTree = SchemaValue

extension MMCLIDynamicTree {
    /// Parses JSON text into a loose tree via `JSONSerialization`.
    ///
    /// Looseness is fine because validation is schema-directed: the schema,
    /// not the input syntax, decides every kind downstream. Two properties
    /// still matter here:
    ///
    /// - Booleans must not collapse into numbers. `JSONSerialization` yields
    ///   `NSNumber` for both, so booleans are detected via
    ///   `CFGetTypeID(number) == CFBooleanGetTypeID()` — the toll-free-bridged
    ///   `CFBoolean` check that works on both Darwin and corelibs-foundation
    ///   (where `objCType`-based sniffing is unreliable).
    /// - Number kinds are best-effort exact: `Int64(exactly:)` first, then
    ///   `UInt64(exactly:)` for the positive overflow band, else double.
    ///   A whole-valued float literal (`1e3`) therefore parses as an integer;
    ///   `validated` turns it back into `1000.0` wherever the schema says
    ///   double.
    ///
    /// Dictionaries lose member order (Foundation's domain); `validated`
    /// canonicalizes objects to schema field order, so ordering only stays
    /// arbitrary for `.unknown`-slot objects, which render in whatever order
    /// Foundation yielded. Malformed input is a usage error, thrown as
    /// swift-argument-parser's `ValidationError`.
    public static func parse(jsonText: String) throws -> MMCLIDynamicTree {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: Data(jsonText.utf8), options: [.fragmentsAllowed])
        } catch {
            let detail =
                ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String)
                ?? String(describing: error)
            throw ValidationError(detail)
        }
        return try Self.fromFoundation(object)
    }

    private static func fromFoundation(_ object: Any) throws -> MMCLIDynamicTree {
        switch object {
            case is NSNull:
                return .null
            case let number as NSNumber:
                if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                    return .bool(number.boolValue)
                }
                if let value = Int64(exactly: number) { return .int(value) }
                if let value = UInt64(exactly: number) { return .uint(value) }
                return .double(number.doubleValue)
            case let text as String:
                return .string(text)
            case let items as [Any]:
                return .array(try items.map(Self.fromFoundation))
            case let entries as [String: Any]:
                return .object(
                    try entries.map { Member($0.key, try Self.fromFoundation($0.value)) })
            default:
                // Unreachable for JSONSerialization output; kept honest.
                throw ValidationError("unsupported JSON value")
        }
    }

    /// The one-word kind used in encoder diagnostics (the validation-side
    /// twin lives inside MMSchema's `SchemaValueError` messages).
    var kindDescription: String {
        switch self {
            case .null: return "null"
            case .bool: return "bool"
            case .int, .uint: return "integer"
            case .double: return "number"
            case .string: return "string"
            case .bytes: return "bytes"
            case .array: return "array"
            case .object: return "object"
        }
    }
}

// MARK: - JSON text rendering

/// Renders a tree as JSON text — small, ordered (members print in
/// `SchemaValue.Member` order; no `JSONSerialization`/`JSONEncoder` key
/// reordering), with correct string escaping. `pretty` indents with two
/// spaces. Non-finite doubles (which JSON cannot express) render as `null`;
/// `.bytes` renders as a base64 string, matching how a bytes response slot
/// travels in JSON.
public func MMCLIDynamicJSONText(_ tree: MMCLIDynamicTree, pretty: Bool) -> String {
    var out = ""
    appendJSON(tree, pretty: pretty, indent: 0, into: &out)
    return out
}

private func appendJSON(
    _ tree: MMCLIDynamicTree, pretty: Bool, indent: Int, into out: inout String
) {
    switch tree {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .int(let value):
            out += String(value)
        case .uint(let value):
            out += String(value)
        case .double(let value):
            out += value.isFinite ? "\(value)" : "null"
        case .string(let value):
            appendJSONString(value, into: &out)
        case .bytes(let bytes):
            appendJSONString(Data(bytes).base64EncodedString(), into: &out)
        case .array(let items):
            guard !items.isEmpty else {
                out += "[]"
                return
            }
            out += "["
            for (offset, item) in items.enumerated() {
                if offset > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                appendJSON(item, pretty: pretty, indent: indent + 1, into: &out)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case .object(let members):
            guard !members.isEmpty else {
                out += "{}"
                return
            }
            out += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                appendJSONString(member.name, into: &out)
                out += pretty ? ": " : ":"
                appendJSON(member.value, pretty: pretty, indent: indent + 1, into: &out)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
    }
}

private func appendJSONString(_ string: String, into out: inout String) {
    out.append("\"")
    for scalar in string.unicodeScalars {
        switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            case "\u{08}":
                out += "\\b"
            case "\u{0C}":
                out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
        }
    }
    out.append("\"")
}
