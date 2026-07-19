/// A schema-shaped value as plain data: the dynamic twin of the generated
/// payload structs, for tools that only learn the schema at runtime (raw CLI
/// calls, test fixtures, bridges).
///
/// A `SchemaValue` starts life *loose* — typically converted from parsed JSON,
/// where number kinds are approximate and object members arrive in whatever
/// order — and becomes *canonical* through
/// ``validated(against:resolver:path:)``: scalar kinds coerced exactly as the
/// schema demands, enum cases checked, references resolved, unknown members
/// rejected, members reordered to schema field order. Canonical values are
/// what the schema-driven wire coders (in MMCLI) encode.
public indirect enum SchemaValue: Sendable, Hashable {
    /// One member of an ``object(_:)`` — ordered, unlike a dictionary, so
    /// canonical values render deterministically.
    public struct Member: Sendable, Hashable {
        public let name: String
        public let value: SchemaValue

        public init(_ name: String, _ value: SchemaValue) {
            self.name = name
            self.value = value
        }
    }

    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case bytes([UInt8])
    case array([SchemaValue])
    case object([Member])
}

/// A validation failure with the dotted path that produced it
/// (`"meta.priority"`, `"lines[2]"`).
public struct SchemaValueError: Error, Sendable, Hashable, CustomStringConvertible {
    public let path: String
    public let problem: String

    public var description: String {
        self.path.isEmpty ? self.problem : "\(self.path): \(self.problem)"
    }
}

extension SchemaValue {
    /// Schema-directed canonicalization — validation and interpretation in
    /// one pass. The schema, not the input syntax, decides every kind: a
    /// JSON `3` satisfies `.double` as `3.0` and `.int` as `3`, a `3.5`
    /// never satisfies `.int`, `.bytes` takes a base64 string, and an
    /// `.unknown` slot passes through untouched. Missing non-optional
    /// structure fields, unknown member names, duplicate members, and
    /// out-of-range values all fail with the offending path.
    public func validated(
        against schema: TypeSchema,
        resolver: TypeResolver,
        path: String = ""
    ) -> Result<SchemaValue, SchemaValueError> {
        let resolved: TypeSchema
        switch resolver.resolve(schema) {
            case .success(let followed):
                resolved = followed
            case .failure(.unresolved(let name)):
                return .failure(
                    SchemaValueError(path: path, problem: "unresolved type reference '\(name)'")
                )
            case .failure(.cycle(let name)):
                return .failure(
                    SchemaValueError(path: path, problem: "cyclic type reference '\(name)'")
                )
        }
        switch resolved {
            case .optional(let wrapped):
                if case .null = self { return .success(.null) }
                return self.validated(against: wrapped, resolver: resolver, path: path)
            case .bool:
                guard case .bool = self else { return self.mismatch(path, expected: "bool") }
                return .success(self)
            case .int:
                guard let value = self.exactInt64 else {
                    return self.mismatch(path, expected: "integer")
                }
                return .success(.int(value))
            case .uint:
                guard let value = self.exactUInt64 else {
                    return self.mismatch(path, expected: "non-negative integer")
                }
                return .success(.uint(value))
            case .float, .double:
                guard let value = self.exactDouble else {
                    return self.mismatch(path, expected: "number")
                }
                return .success(.double(value))
            case .string:
                guard case .string = self else { return self.mismatch(path, expected: "string") }
                return .success(self)
            case .bytes:
                switch self {
                    case .bytes:
                        return .success(self)
                    case .string(let base64):
                        guard let decoded = SchemaValue.decodeBase64(base64) else {
                            return self.mismatch(path, expected: "base64 string")
                        }
                        return .success(.bytes(decoded))
                    default:
                        return self.mismatch(path, expected: "base64 string")
                }
            case .array(let element):
                guard case .array(let items) = self else {
                    return self.mismatch(path, expected: "array")
                }
                return items.enumerated()
                    .traverse { index, item in
                        item.validated(
                            against: element, resolver: resolver, path: "\(path)[\(index)]")
                    }
                    .map { .array($0) }
            case .map(let keySchema, let valueSchema):
                guard case .object(let members) = self else {
                    return self.mismatch(path, expected: "object (wire map)")
                }
                if let duplicate = firstDuplicate(members.map(\.name)) {
                    return .failure(
                        SchemaValueError(
                            path: Self.appending(duplicate, to: path), problem: "duplicate key")
                    )
                }
                return members
                    .traverse { member in
                        let memberPath = Self.appending(member.name, to: path)
                        return Self.validateMapKey(member.name, against: keySchema, path: memberPath)
                            .flatMap {
                                member.value.validated(
                                    against: valueSchema, resolver: resolver, path: memberPath)
                            }
                            .map { canonical in Member(member.name, canonical) }
                    }
                    .map { .object($0) }
            case .structure(let fields):
                guard case .object(let members) = self else {
                    return self.mismatch(path, expected: "object")
                }
                if let duplicate = firstDuplicate(members.map(\.name)) {
                    return .failure(
                        SchemaValueError(
                            path: Self.appending(duplicate, to: path), problem: "duplicate member")
                    )
                }
                if let unknown = members.first(where: { member in
                    !fields.contains(where: { $0.name == member.name })
                }) {
                    return .failure(
                        SchemaValueError(
                            path: Self.appending(unknown.name, to: path),
                            problem: "unknown member (schema declares no such field)"
                        )
                    )
                }
                let byName = Dictionary(
                    members.map { ($0.name, $0.value) },
                    uniquingKeysWith: { first, _ in first }
                )
                // Canonical order is schema field order; an absent optional
                // field simply drops out of the canonical object.
                return fields
                    .traverse { field -> Result<Member?, SchemaValueError> in
                        let fieldPath = Self.appending(field.name, to: path)
                        guard let provided = byName[field.name] else {
                            if case .optional = field.type { return .success(nil) }
                            return .failure(
                                SchemaValueError(path: fieldPath, problem: "missing required field")
                            )
                        }
                        return provided
                            .validated(against: field.type, resolver: resolver, path: fieldPath)
                            .map { canonical in Member(field.name, canonical) }
                    }
                    .map { .object($0.compactMap { $0 }) }
            case .enumeration(let cases):
                guard case .string(let raw) = self else {
                    return self.mismatch(path, expected: "enum case (string)")
                }
                guard cases.contains(where: { $0.name == raw }) else {
                    let known = cases.map(\.name).joined(separator: ", ")
                    return .failure(
                        SchemaValueError(
                            path: path,
                            problem: "'\(raw)' is not one of: \(known)"
                        )
                    )
                }
                return .success(self)
            case .reference:
                // Unreachable: resolve(_:) above never returns a reference.
                return .failure(
                    SchemaValueError(path: path, problem: "unresolvable reference")
                )
            case .unknown:
                return .success(self)
        }
    }

    private func mismatch(
        _ path: String,
        expected: String
    ) -> Result<SchemaValue, SchemaValueError> {
        .failure(SchemaValueError(path: path, problem: "expected \(expected), got \(self.kind)"))
    }

    /// One member/field path segment appended to a (possibly empty) parent path.
    private static func appending(_ name: String, to path: String) -> String {
        path.isEmpty ? name : "\(path).\(name)"
    }

    /// JSON keys are strings; integer-keyed wire maps take their keys as
    /// decimal text.
    private static func validateMapKey(
        _ name: String,
        against keySchema: TypeSchema,
        path: String
    ) -> Result<Void, SchemaValueError> {
        switch keySchema {
            case .string:
                return .success(())
            case .int, .uint:
                return Int64(name) != nil
                    ? .success(())
                    : .failure(SchemaValueError(path: path, problem: "key is not an integer"))
            default:
                return .failure(
                    SchemaValueError(
                        path: path, problem: "unsupported map key schema for dynamic values")
                )
        }
    }

    /// The value's own kind, for error messages and renderers.
    public var kind: String {
        switch self {
            case .null: return "null"
            case .bool: return "bool"
            case .int: return "integer"
            case .uint: return "integer"
            case .double: return "number"
            case .string: return "string"
            case .bytes: return "bytes"
            case .array: return "array"
            case .object: return "object"
        }
    }

    /// Exact-kind coercions: the schema decides the kind; the input may carry
    /// it in any numeric form that fits losslessly.
    var exactInt64: Int64? {
        switch self {
            case .int(let value): return value
            case .uint(let value): return Int64(exactly: value)
            case .double(let value): return Int64(exactly: value)
            default: return nil
        }
    }

    var exactUInt64: UInt64? {
        switch self {
            case .uint(let value): return value
            case .int(let value): return UInt64(exactly: value)
            case .double(let value): return UInt64(exactly: value)
            default: return nil
        }
    }

    var exactDouble: Double? {
        switch self {
            case .double(let value): return value
            case .int(let value): return Double(value)
            case .uint(let value): return Double(value)
            default: return nil
        }
    }
}

extension SchemaValue {
    /// Base64 without Foundation — MMSchema stays dependency-free. Public
    /// because it is part of the `.bytes` contract: ``validated(against:resolver:path:)``
    /// accepts base64 text for byte slots, and renderers emit it back.
    public static func decodeBase64(_ text: String) -> [UInt8]? {
        var values: [UInt8] = []
        values.reserveCapacity(text.utf8.count * 3 / 4)
        var buffer: UInt32 = 0
        var bits = 0
        var padding = 0
        for scalar in text.unicodeScalars {
            if scalar == "=" {
                padding += 1
                continue
            }
            guard padding == 0, let value = base64Value(scalar) else { return nil }
            buffer = (buffer << 6) | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                values.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        guard padding <= 2, (text.utf8.count % 4) == 0 || padding == 0 else { return nil }
        return values
    }

    public static func encodeBase64(_ bytes: [UInt8]) -> String {
        let alphabet = Array(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
        )
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index + 3 <= bytes.count {
            let chunk =
                (UInt32(bytes[index]) << 16) | (UInt32(bytes[index + 1]) << 8)
                | UInt32(bytes[index + 2])
            out.append(alphabet[Int((chunk >> 18) & 63)])
            out.append(alphabet[Int((chunk >> 12) & 63)])
            out.append(alphabet[Int((chunk >> 6) & 63)])
            out.append(alphabet[Int(chunk & 63)])
            index += 3
        }
        let remaining = bytes.count - index
        if remaining == 1 {
            let chunk = UInt32(bytes[index]) << 16
            out.append(alphabet[Int((chunk >> 18) & 63)])
            out.append(alphabet[Int((chunk >> 12) & 63)])
            out.append(contentsOf: [61, 61])  // "=="
        } else if remaining == 2 {
            let chunk = (UInt32(bytes[index]) << 16) | (UInt32(bytes[index + 1]) << 8)
            out.append(alphabet[Int((chunk >> 18) & 63)])
            out.append(alphabet[Int((chunk >> 12) & 63)])
            out.append(alphabet[Int((chunk >> 6) & 63)])
            out.append(61)  // "="
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func base64Value(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
            case "A"..."Z": return UInt8(scalar.value - 65)
            case "a"..."z": return UInt8(scalar.value - 97 + 26)
            case "0"..."9": return UInt8(scalar.value - 48 + 52)
            case "+": return 62
            case "/": return 63
            default: return nil
        }
    }
}
