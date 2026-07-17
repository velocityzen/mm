import MMSchema
import NIOCore

/// Schema-driven response decoding for the raw-call escape hatch: bytes off
/// the wire decoded against a schema discovered at runtime, into a canonical
/// `SchemaValue` tree keyed by field names.
///
/// The two verified facts this file leans on:
///
/// - `MMPackDecoder`'s keyed container indexes map entries and serves random
///   access **by key** (each lookup hands out a fresh slice), so a failed
///   typed decode attempt for one key never corrupts the buffer — which is
///   what makes the ordered `.unknown` fallback tries safe.
/// - Encode/decode of a call run on the **caller's** task
///   (`ClientConnection.performCall`/`resolve` are nonisolated), so a
///   `@TaskLocal` bound around `client.call(...)` propagates into
///   ``MMCLIDynamicResponse/init(from:)``.
public struct MMCLIDynamicResponse: Codable, Sendable {
    /// The response schema plus the definitions table its references resolve
    /// through. Must be bound while the call decodes — `Decodable.init(from:)`
    /// takes no context, so the schema rides a task-local.
    @TaskLocal public static var schema: (TypeSchema, [TypeDefinition])?

    /// The decoded value, keyed by field **names** (not wire integers), in
    /// schema declaration order. Absent or nil optional fields are omitted;
    /// bytes fields carry their raw bytes (`.bytes`), which render as base64.
    public let tree: MMCLIDynamicTree

    public init(from decoder: any Decoder) throws {
        guard let (schema, definitions) = Self.schema else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "MMCLIDynamicResponse requires MMCLIDynamicResponse.schema to be bound on the calling task"
                )
            )
        }
        self.tree = try Self.decodeValue(
            schema, resolver: TypeResolver(definitions), from: decoder)
    }

    /// Never used: responses travel server → client only. Present because
    /// `Method` requires `Codable` on both generic parameters.
    public func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(
            self.tree,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "MMCLIDynamicResponse is decode-only"
            )
        )
    }

    // MARK: Decoding walkers

    /// Decodes one value position from its own decoder (the root, a
    /// `superDecoder(forKey:)` slice, or an unkeyed element slice).
    static func decodeValue(
        _ schema: TypeSchema,
        resolver: TypeResolver,
        from decoder: any Decoder
    ) throws -> MMCLIDynamicTree {
        let resolved = try Self.resolveOrRephrase(
            schema, resolver: resolver, codingPath: decoder.codingPath)
        switch resolved {
            case .bool:
                return .bool(try decoder.singleValueContainer().decode(Bool.self))
            case .int:
                return .int(try decoder.singleValueContainer().decode(Int64.self))
            case .uint:
                return .uint(try decoder.singleValueContainer().decode(UInt64.self))
            case .float:
                return .double(Double(try decoder.singleValueContainer().decode(Float.self)))
            case .double:
                return .double(try decoder.singleValueContainer().decode(Double.self))
            case .string, .enumeration:
                return .string(try decoder.singleValueContainer().decode(String.self))
            case .bytes:
                return .bytes(
                    Self.rawBytes(try decoder.singleValueContainer().decode(ByteBuffer.self)))
            case .optional(let wrapped):
                if try decoder.singleValueContainer().decodeNil() { return .null }
                return try Self.decodeValue(wrapped, resolver: resolver, from: decoder)
            case .structure(let fields):
                let container = try decoder.container(keyedBy: MMCLIDynamicCodingKey.self)
                var members: [SchemaValue.Member] = []
                members.reserveCapacity(fields.count)
                for field in fields {
                    let key = MMCLIDynamicCodingKey(field: field.key, name: field.name)
                    let fieldSchema = try Self.resolveOrRephrase(
                        field.type, resolver: resolver,
                        codingPath: container.codingPath + [key])
                    if case .optional(let wrapped) = fieldSchema {
                        // decodeIfPresent semantics: absent and explicit-nil
                        // optionals are both omitted from the tree.
                        guard container.contains(key),
                            try container.decodeNil(forKey: key) == false
                        else { continue }
                        members.append(
                            SchemaValue.Member(
                                field.name,
                                try Self.decodeField(
                                    wrapped, resolver: resolver, in: container, forKey: key)
                            ))
                    } else {
                        members.append(
                            SchemaValue.Member(
                                field.name,
                                try Self.decodeField(
                                    fieldSchema, resolver: resolver, in: container, forKey: key)
                            ))
                    }
                }
                return .object(members)
            case .array(let element):
                var container = try decoder.unkeyedContainer()
                let resolvedElement = try Self.resolveOrRephrase(
                    element, resolver: resolver, codingPath: container.codingPath)
                var items: [MMCLIDynamicTree] = []
                while !container.isAtEnd {
                    items.append(
                        try Self.decodeElement(
                            resolvedElement, resolver: resolver, from: &container))
                }
                return .array(items)
            case .map(_, let valueSchema):
                let container = try decoder.container(keyedBy: MMCLIDynamicCodingKey.self)
                let resolvedValue = try Self.resolveOrRephrase(
                    valueSchema, resolver: resolver, codingPath: container.codingPath)
                // Deterministic order for an unordered wire map: integer keys
                // numerically, then string keys lexicographically.
                let keys = container.allKeys.sorted { left, right in
                    switch (left.intValue, right.intValue) {
                        case (.some(let a), .some(let b)):
                            return a < b
                        case (.some, .none):
                            return true
                        case (.none, .some):
                            return false
                        case (.none, .none):
                            return left.stringValue < right.stringValue
                    }
                }
                var members: [SchemaValue.Member] = []
                members.reserveCapacity(keys.count)
                for key in keys {
                    members.append(
                        SchemaValue.Member(
                            key.stringValue,
                            try Self.decodeField(
                                resolvedValue, resolver: resolver, in: container, forKey: key)
                        ))
                }
                return .object(members)
            case .unknown:
                return Self.decodeUnknown(from: decoder)
            case .reference:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "unresolvable type reference"
                    )
                )
        }
    }

    /// Decodes one keyed slot. Scalars go through the container's typed
    /// accessors; shaped values recurse through a fresh `superDecoder(forKey:)`
    /// slice. `.unknown` slots try, in order, String → Int64 → UInt64 → Bool
    /// → Double, else `.null` — safe because keyed access is by key and a
    /// failed attempt reads a throwaway slice.
    static func decodeField(
        _ schema: TypeSchema,
        resolver: TypeResolver,
        in container: KeyedDecodingContainer<MMCLIDynamicCodingKey>,
        forKey key: MMCLIDynamicCodingKey
    ) throws -> MMCLIDynamicTree {
        let resolved = try Self.resolveOrRephrase(
            schema, resolver: resolver, codingPath: container.codingPath + [key])
        switch resolved {
            case .bool:
                return .bool(try container.decode(Bool.self, forKey: key))
            case .int:
                return .int(try container.decode(Int64.self, forKey: key))
            case .uint:
                return .uint(try container.decode(UInt64.self, forKey: key))
            case .float:
                return .double(Double(try container.decode(Float.self, forKey: key)))
            case .double:
                return .double(try container.decode(Double.self, forKey: key))
            case .string, .enumeration:
                return .string(try container.decode(String.self, forKey: key))
            case .bytes:
                return .bytes(Self.rawBytes(try container.decode(ByteBuffer.self, forKey: key)))
            case .optional(let wrapped):
                guard container.contains(key), try container.decodeNil(forKey: key) == false
                else { return .null }
                return try Self.decodeField(wrapped, resolver: resolver, in: container, forKey: key)
            case .unknown:
                guard container.contains(key) else { return .null }
                if let value = try? container.decode(String.self, forKey: key) {
                    return .string(value)
                }
                if let value = try? container.decode(Int64.self, forKey: key) {
                    return .int(value)
                }
                if let value = try? container.decode(UInt64.self, forKey: key) {
                    return .uint(value)
                }
                if let value = try? container.decode(Bool.self, forKey: key) {
                    return .bool(value)
                }
                if let value = try? container.decode(Double.self, forKey: key) {
                    return .double(value)
                }
                return .null
            case .structure, .array, .map:
                return try Self.decodeValue(
                    resolved, resolver: resolver,
                    from: container.superDecoder(forKey: key))
            case .reference:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath + [key],
                        debugDescription: "unresolvable type reference"
                    )
                )
        }
    }

    /// Decodes one array element. The codec's unkeyed reads rewind on
    /// failure (and only advance the element cursor on success), so the
    /// `.unknown` ordered tries are safe here too; a shape none of them
    /// recognizes is consumed via `superDecoder()` and yields `.null`.
    static func decodeElement(
        _ resolved: TypeSchema,
        resolver: TypeResolver,
        from container: inout UnkeyedDecodingContainer
    ) throws -> MMCLIDynamicTree {
        switch resolved {
            case .bool:
                return .bool(try container.decode(Bool.self))
            case .int:
                return .int(try container.decode(Int64.self))
            case .uint:
                return .uint(try container.decode(UInt64.self))
            case .float:
                return .double(Double(try container.decode(Float.self)))
            case .double:
                return .double(try container.decode(Double.self))
            case .string, .enumeration:
                return .string(try container.decode(String.self))
            case .bytes:
                return .bytes(Self.rawBytes(try container.decode(ByteBuffer.self)))
            case .optional(let wrapped):
                if try container.decodeNil() { return .null }
                let resolvedWrapped = try Self.resolveOrRephrase(
                    wrapped, resolver: resolver, codingPath: container.codingPath)
                return try Self.decodeElement(
                    resolvedWrapped, resolver: resolver, from: &container)
            case .unknown:
                if let value = try? container.decode(String.self) { return .string(value) }
                if let value = try? container.decode(Int64.self) { return .int(value) }
                if let value = try? container.decode(UInt64.self) { return .uint(value) }
                if let value = try? container.decode(Bool.self) { return .bool(value) }
                if let value = try? container.decode(Double.self) { return .double(value) }
                _ = try container.superDecoder()  // consume the unrecognized element
                return .null
            case .structure, .array, .map:
                return try Self.decodeValue(
                    resolved, resolver: resolver, from: container.superDecoder())
            case .reference:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "unresolvable type reference"
                    )
                )
        }
    }

    private static func resolveOrRephrase(
        _ schema: TypeSchema,
        resolver: TypeResolver,
        codingPath: [any CodingKey]
    ) throws -> TypeSchema {
        switch resolver.resolve(schema) {
            case .success(let resolved):
                return resolved
            case .failure(let failure):
                let message: String
                switch failure {
                    case .unresolved(let name):
                        message = "unresolved type reference '\(name)'"
                    case .cycle(let name):
                        message = "cyclic type reference '\(name)'"
                }
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: codingPath, debugDescription: message)
                )
        }
    }

    /// A root-level `.unknown` (the whole response shape is unrecognized):
    /// the same ordered tries against the decoder's single-value view.
    private static func decodeUnknown(from decoder: any Decoder) -> MMCLIDynamicTree {
        guard let single = try? decoder.singleValueContainer() else { return .null }
        if let value = try? single.decode(String.self) { return .string(value) }
        if let value = try? single.decode(Int64.self) { return .int(value) }
        if let value = try? single.decode(UInt64.self) { return .uint(value) }
        if let value = try? single.decode(Bool.self) { return .bool(value) }
        if let value = try? single.decode(Double.self) { return .double(value) }
        return .null
    }

    private static func rawBytes(_ buffer: ByteBuffer) -> [UInt8] {
        var copy = buffer
        return copy.readBytes(length: copy.readableBytes) ?? []
    }
}
