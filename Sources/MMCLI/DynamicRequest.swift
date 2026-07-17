import ArgumentParser
import MMSchema
import NIOCore

/// Schema-driven request encoding for the raw-call escape hatch
/// (`MMCLIRawCall`): `--params` JSON validated against a discovered
/// `TypeSchema` and encoded onto the wire with the same integer-keyed
/// MessagePack shape a generated type would produce.
///
/// The verified fact this file leans on: `MMPackEncoder` writes a keyed
/// container's `Int`-raw `CodingKey` via `intValue` (the faithful-int-key
/// rule), so a custom key with `intValue` set produces exactly the wire map a
/// generated `CodingKeys` enum would.

// MARK: - Coding key

/// The dynamic stand-in for a generated `Int`-raw `CodingKeys` case: carries
/// the wire integer as `intValue` and the field name as `stringValue`, which
/// satisfies both sides of the codec's faithful-int-key rule (field names are
/// not decimal numerals, so the int key is honored; string-keyed fields set
/// no `intValue` and travel as strings).
struct MMCLIDynamicCodingKey: CodingKey {
    let intValue: Int?
    let stringValue: String

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }

    /// A schema field's key: the wire integer (when the type is
    /// integer-keyed) plus the field name.
    init(field key: Int?, name: String) {
        self.intValue = key
        self.stringValue = name
    }
}

// MARK: - Request

/// A request payload assembled at runtime from `--params` JSON and the
/// server's discovered schema. Encode-only in spirit — the `Decodable` half
/// exists solely because `Method`'s generic parameters require full
/// `Codable`, and always throws (a client never decodes its own request).
///
/// `init` canonicalizes the loose JSON tree through
/// `SchemaValue.validated(against:resolver:path:)` — unknown field names,
/// missing required fields, scalar kind mismatches, enum typos, and
/// unresolvable references all surface as `ValidationError` with the
/// offending field path. `encode(to:)` is then a value-directed walk over the
/// canonical value zipped with the schema: kinds are already exact, so every
/// case is a plain pattern match — nil/absent optionals skipped, enums as
/// their case-name string, bytes as a MessagePack `bin` via the codec's
/// `ByteBuffer` fast path, integer-keyed containers via
/// `MMCLIDynamicCodingKey`.
public struct MMCLIDynamicRequest: Codable, Sendable {
    let schema: TypeSchema
    let canonical: SchemaValue
    let resolver: TypeResolver

    public init(
        schema: TypeSchema, definitions: [TypeDefinition], json: MMCLIDynamicTree
    ) throws {
        let resolver = TypeResolver(definitions)
        let resolved: TypeSchema
        switch resolver.resolve(schema) {
            case .success(let followed):
                resolved = followed
            case .failure(.unresolved(let name)):
                throw ValidationError("params: unresolved type reference '\(name)'")
            case .failure(.cycle(let name)):
                throw ValidationError("params: cyclic type reference '\(name)'")
        }
        guard case .structure = resolved else {
            throw ValidationError(
                "params: the request schema is not a structure (got \(Self.describe(resolved)))"
            )
        }
        let canonical: SchemaValue
        switch json.validated(against: resolved, resolver: resolver, path: "params") {
            case .success(let value):
                canonical = value
            case .failure(let error):
                throw ValidationError(error.description)
        }
        // `validated` passes `.unknown` slots through untouched, but a wire
        // encoder cannot invent a shape for them — refuse up front, as a
        // usage error, exactly where the old walker did.
        try Self.rejectUnknownSlots(canonical, schema: resolved, resolver: resolver, path: "params")
        self.schema = resolved
        self.canonical = canonical
        self.resolver = resolver
    }

    public func encode(to encoder: any Encoder) throws {
        try DynamicRequestNode(schema: self.schema, value: self.canonical, resolver: self.resolver)
            .encode(to: encoder)
    }

    /// Never used: requests travel client → server only. Present because
    /// `Method` requires `Codable` on both generic parameters.
    public init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "MMCLIDynamicRequest is encode-only"
            )
        )
    }

    /// Walks the canonical value alongside its schema and refuses any
    /// `.unknown` position the value actually occupies. Structure-mismatch
    /// cases silently return: `validated` already guaranteed the zip lines
    /// up, so they are unreachable.
    private static func rejectUnknownSlots(
        _ value: SchemaValue, schema: TypeSchema, resolver: TypeResolver, path: String
    ) throws {
        guard case .success(let resolved) = resolver.resolve(schema) else { return }
        switch resolved {
            case .unknown:
                throw ValidationError(
                    "\(path): the server's schema for this field is unknown; cannot encode it")
            case .optional(let wrapped):
                if case .null = value { return }
                try Self.rejectUnknownSlots(value, schema: wrapped, resolver: resolver, path: path)
            case .array(let element):
                guard case .array(let items) = value else { return }
                for (index, item) in items.enumerated() {
                    try Self.rejectUnknownSlots(
                        item, schema: element, resolver: resolver, path: "\(path)[\(index)]")
                }
            case .map(_, let valueSchema):
                guard case .object(let members) = value else { return }
                for member in members {
                    try Self.rejectUnknownSlots(
                        member.value, schema: valueSchema, resolver: resolver,
                        path: "\(path).\(member.name)")
                }
            case .structure(let fields):
                guard case .object(let members) = value else { return }
                for member in members {
                    guard let field = fields.first(where: { $0.name == member.name }) else {
                        continue
                    }
                    try Self.rejectUnknownSlots(
                        member.value, schema: field.type, resolver: resolver,
                        path: "\(path).\(member.name)")
                }
            default:
                return
        }
    }

    private static func describe(_ schema: TypeSchema) -> String {
        switch schema {
            case .bool: return "bool"
            case .int: return "int"
            case .uint: return "uint"
            case .float: return "float"
            case .double: return "double"
            case .string: return "string"
            case .bytes: return "bytes"
            case .optional: return "optional"
            case .array: return "array"
            case .map: return "map"
            case .structure: return "structure"
            case .enumeration: return "enumeration"
            case .reference(let name): return "reference(\(name))"
            case .unknown: return "unknown"
        }
    }
}

/// One canonical value position: pairs a schema shape with the value that
/// fills it, encodable through any `Encoder` (which is how nested structures,
/// arrays, and maps recurse through the codec's child encoders). Only ever
/// built from values `validated` accepted, so mismatches here are programmer
/// errors surfaced as `EncodingError`.
private struct DynamicRequestNode: Encodable {
    let schema: TypeSchema
    let value: SchemaValue
    let resolver: TypeResolver

    func encode(to encoder: any Encoder) throws {
        guard case .success(let resolved) = self.resolver.resolve(self.schema) else {
            throw self.invalid(encoder, expected: "a resolvable type reference")
        }
        switch resolved {
            case .optional(let wrapped):
                if case .null = self.value {
                    var single = encoder.singleValueContainer()
                    try single.encodeNil()
                    return
                }
                try DynamicRequestNode(
                    schema: wrapped, value: self.value, resolver: self.resolver
                ).encode(to: encoder)
            case .bool:
                guard case .bool(let flag) = self.value else {
                    throw self.invalid(encoder, expected: "bool")
                }
                var single = encoder.singleValueContainer()
                try single.encode(flag)
            case .int:
                guard case .int(let number) = self.value else {
                    throw self.invalid(encoder, expected: "integer")
                }
                var single = encoder.singleValueContainer()
                try single.encode(number)
            case .uint:
                guard case .uint(let number) = self.value else {
                    throw self.invalid(encoder, expected: "unsigned integer")
                }
                var single = encoder.singleValueContainer()
                try single.encode(number)
            case .float:
                guard case .double(let number) = self.value else {
                    throw self.invalid(encoder, expected: "number")
                }
                var single = encoder.singleValueContainer()
                try single.encode(Float(number))
            case .double:
                guard case .double(let number) = self.value else {
                    throw self.invalid(encoder, expected: "number")
                }
                var single = encoder.singleValueContainer()
                try single.encode(number)
            case .string, .enumeration:
                guard case .string(let text) = self.value else {
                    throw self.invalid(encoder, expected: "string")
                }
                var single = encoder.singleValueContainer()
                try single.encode(text)
            case .bytes:
                guard case .bytes(let bytes) = self.value else {
                    throw self.invalid(encoder, expected: "bytes")
                }
                var single = encoder.singleValueContainer()
                try single.encode(ByteBuffer(bytes: bytes))
            case .structure(let fields):
                guard case .object(let members) = self.value else {
                    throw self.invalid(encoder, expected: "object")
                }
                var container = encoder.container(keyedBy: MMCLIDynamicCodingKey.self)
                // Canonical members are a subset of the fields, in field
                // order; explicit-null optionals encode nothing, matching
                // what a generated type's encodeIfPresent would do.
                for member in members {
                    if case .null = member.value { continue }
                    guard let field = fields.first(where: { $0.name == member.name }) else {
                        throw self.invalid(encoder, expected: "a declared field")
                    }
                    try container.encode(
                        DynamicRequestNode(
                            schema: field.type, value: member.value, resolver: self.resolver),
                        forKey: MMCLIDynamicCodingKey(field: field.key, name: field.name)
                    )
                }
            case .array(let element):
                guard case .array(let items) = self.value else {
                    throw self.invalid(encoder, expected: "array")
                }
                var container = encoder.unkeyedContainer()
                for item in items {
                    try container.encode(
                        DynamicRequestNode(schema: element, value: item, resolver: self.resolver))
                }
            case .map(let keySchema, let valueSchema):
                guard case .object(let members) = self.value else {
                    throw self.invalid(encoder, expected: "object")
                }
                guard case .success(let resolvedKey) = self.resolver.resolve(keySchema) else {
                    throw self.invalid(encoder, expected: "a resolvable map key schema")
                }
                var container = encoder.container(keyedBy: MMCLIDynamicCodingKey.self)
                for member in members {
                    let key: MMCLIDynamicCodingKey
                    switch resolvedKey {
                        case .int, .uint:
                            guard let numeric = Int(member.name),
                                let intKey = MMCLIDynamicCodingKey(intValue: numeric)
                            else {
                                throw self.invalid(encoder, expected: "integer map key")
                            }
                            key = intKey
                        default:
                            guard let stringKey = MMCLIDynamicCodingKey(stringValue: member.name)
                            else {
                                throw self.invalid(encoder, expected: "map key")
                            }
                            key = stringKey
                    }
                    try container.encode(
                        DynamicRequestNode(
                            schema: valueSchema, value: member.value, resolver: self.resolver),
                        forKey: key
                    )
                }
            case .unknown, .reference:
                throw self.invalid(encoder, expected: "an encodable schema shape")
        }
    }

    /// Unreachable after `validated` plus the init-time unknown-slot check —
    /// kept honest as an `EncodingError` rather than a trap.
    private func invalid(_ encoder: any Encoder, expected: String) -> EncodingError {
        EncodingError.invalidValue(
            self.value,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription:
                    "dynamic request value does not match its validated schema (expected \(expected), got \(self.value.kindDescription))"
            )
        )
    }
}
