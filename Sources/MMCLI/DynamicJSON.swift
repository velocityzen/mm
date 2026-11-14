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
    /// Parses JSON text into a loose tree via `JSONDecoder`.
    ///
    /// Looseness is fine because validation is schema-directed: the schema,
    /// not the input syntax, decides every kind downstream. Three properties
    /// still matter here:
    ///
    /// - Booleans stay booleans: `JSONDecoder` decodes a `Bool` only from
    ///   `true` or `false`, never from a number.
    /// - Number kinds are best-effort exact: `Int64` first, then `UInt64`
    ///   for the positive overflow band, else double. A whole-valued float
    ///   literal (`1e3`) therefore parses as an integer; `validated` turns
    ///   it back into `1000.0` wherever the schema says double. A negative
    ///   zero (`-0`, `-0.0`) stays a double, keeping its sign. A number too
    ///   large for a double (`1e400`) is refused, and one too small for it
    ///   (`1e-400`) parses as 0.
    /// - Strings and object keys keep every character, a leading U+FEFF
    ///   included, which `JSONSerialization` drops on Darwin.
    ///
    /// Object member order is not kept; `validated` canonicalizes objects to
    /// schema field order, so ordering only stays arbitrary for
    /// `.unknown`-slot objects, which render in whatever order the decoder
    /// yielded. Malformed input is a usage error, thrown as
    /// swift-argument-parser's `ValidationError`.
    public static func parse(jsonText: String) throws -> MMCLIDynamicTree {
        do {
            return try JSONDecoder().decode(JSONTree.self, from: Data(jsonText.utf8)).tree
        } catch let error as DecodingError {
            throw ValidationError(Self.reason(error))
        }
    }

    /// Why JSON text did not parse: the parser's own message, which names
    /// the line and column, or the path of a number too large for a double.
    private static func reason(_ error: DecodingError) -> String {
        guard case .dataCorrupted(let context) = error else {
            return String(describing: error)
        }
        guard let underlying = context.underlyingError else {
            return context.debugDescription
        }
        return ((underlying as NSError).userInfo[NSDebugDescriptionErrorKey] as? String)
            ?? String(describing: underlying)
    }
}

/// One JSON value as a loose tree, decoded by trying each JSON kind in
/// turn: an object, an array, then null, a boolean, a number and a string.
private struct JSONTree: Decodable {
    let tree: MMCLIDynamicTree

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        if let object = try? decoder.container(keyedBy: Key.self) {
            tree = .object(
                try object.allKeys.map { key in
                    SchemaValue.Member(
                        key.stringValue,
                        try object.decode(JSONTree.self, forKey: key).tree
                    )
                }
            )
            return
        }
        if var items = try? decoder.unkeyedContainer() {
            var trees: [MMCLIDynamicTree] = []
            while !items.isAtEnd {
                trees.append(try items.decode(JSONTree.self).tree)
            }
            tree = .array(trees)
            return
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            tree = .null
        } else if let flag = try? value.decode(Bool.self) {
            tree = .bool(flag)
        } else if let number = try? value.decode(Double.self), number == 0, number.sign == .minus {
            // `Int64` takes a negative zero as 0, which would drop its sign.
            tree = .double(number)
        } else if let number = try? value.decode(Int64.self) {
            tree = .int(number)
        } else if let number = try? value.decode(UInt64.self) {
            tree = .uint(number)
        } else if let number = try? value.decode(Double.self) {
            tree = .double(number)
        } else if let text = try? value.decode(String.self) {
            tree = .string(text)
        } else {
            // Not null, a boolean or a string, and no double or integer
            // holds it: a number too large for a double.
            let at = Self.pathText(value.codingPath)
            throw DecodingError.dataCorruptedError(
                in: value,
                debugDescription: at.isEmpty
                    ? "Number is too large for a double."
                    : "Number at \(at) is too large for a double."
            )
        }
    }

    /// A coding path written the way validation writes one: `a.b[1]`.
    private static func pathText(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("") { path, key in
            if let index = key.intValue { return "\(path)[\(index)]" }
            return path.isEmpty ? key.stringValue : "\(path).\(key.stringValue)"
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
            appendJSONString(SchemaValue.encodeBase64(bytes), into: &out)
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
