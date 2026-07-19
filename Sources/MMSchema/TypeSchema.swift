/// The wire shape of a value, as discovered by the ``of(_:)`` probe or declared via
/// ``SchemaDescribable``. This is what `server.schema` serves to clients.
///
/// ## Wire encoding (fixed)
///
/// A `TypeSchema` encodes as a map with integer keys:
///
/// - key **0**: the case tag, a `UInt8` —
///   0 `bool`, 1 `int`, 2 `uint`, 3 `float`, 4 `double`, 5 `string`,
///   6 `bytes`, 7 `optional`, 8 `array`, 9 `map`, 10 `structure`,
///   11 `enumeration`, 12 `reference`, 255 `unknown`.
/// - key **1**: first payload — the wrapped schema for `optional`, the element
///   schema for `array`, the key schema for `map`, the field list for
///   `structure`, the case list for `enumeration`, the qualified type name
///   (string) for `reference`.
/// - key **2**: second payload — the value schema for `map`.
///
/// ## Decoding never fails
///
/// A client that cannot decode the schema response cannot discover anything
/// else, so `init(from:)` maps *anything* unrecognized — an unknown tag, a
/// missing tag, a corrupt payload, even a non-map value — to ``unknown``
/// instead of throwing. New cases added in future protocol versions therefore
/// degrade to `.unknown` on old clients.
public indirect enum TypeSchema: Sendable, Hashable {
    case bool
    /// Any signed integer width (`Int`, `Int8`…`Int64`).
    case int
    /// Any unsigned integer width (`UInt`, `UInt8`…`UInt64`).
    case uint
    case float
    case double
    case string
    /// Raw binary (MessagePack `bin`). Never produced by the probe — types
    /// carrying raw bytes declare it via ``SchemaDescribable``.
    case bytes
    case optional(TypeSchema)
    case array(TypeSchema)
    case map(key: TypeSchema, value: TypeSchema)
    /// A struct: fields in **declaration order** (the order the type's decoder
    /// requested them).
    case structure(fields: [Field])
    /// A closed set of string-valued cases: the wire value is the case name as
    /// a MessagePack string (fixed decision). Renaming a case is a wire break;
    /// reordering is not. Decoders map unrecognized values to their local
    /// `unknown` case per the house wire-enum rule.
    case enumeration(cases: [EnumCase])
    /// A reference to a named type by its qualified name
    /// (`journal.Priority`, `common.LineMeta`). Names are **nominal** — part
    /// of the wire contract, hashed into the fingerprint — and resolve through
    /// the ``TypeDefinition`` table served alongside the method list.
    case reference(String)
    /// A shape this peer does not recognize (future case, cyclic recursion
    /// point, or corrupt input).
    case unknown

    /// One field of a ``TypeSchema/structure(fields:)``.
    public struct Field: Sendable, Hashable, Codable {
        /// The integer `CodingKey` rawValue, if the type uses integer keys
        /// (the wire convention); `nil` for string-keyed types.
        public var key: Int?
        /// The field's name (`CodingKey.stringValue`).
        public var name: String
        public var type: TypeSchema
        /// Human-readable documentation, served by discovery. Never part of
        /// the fingerprint or of compatibility comparisons.
        public var description: String?

        public init(key: Int?, name: String, type: TypeSchema, description: String? = nil) {
            self.key = key
            self.name = name
            self.type = type
            self.description = description
        }

        enum CodingKeys: Int, CodingKey {
            case key = 0
            case name = 1
            case type = 2
            case description = 3
        }
    }

    /// One case of a ``TypeSchema/enumeration(cases:)``. The name is the wire value.
    public struct EnumCase: Sendable, Hashable, Codable {
        public var name: String
        /// Human-readable documentation, served by discovery. Never part of
        /// the fingerprint or of compatibility comparisons.
        public var description: String?

        public init(name: String, description: String? = nil) {
            self.name = name
            self.description = description
        }

        enum CodingKeys: Int, CodingKey {
            case name = 0
            case description = 1
        }
    }
}

extension TypeSchema {
    /// The same shape with every description removed — the form the
    /// fingerprint hashes and `verify`/`SchemaDifference` compare, so doc
    /// edits never register as schema drift.
    public var strippingDescriptions: TypeSchema {
        self.rewritten(
            field: { Field(key: $0.key, name: $0.name, type: $0.type) },
            enumCase: { EnumCase(name: $0.name) }
        )
    }

    /// The one structure-preserving rebuild behind every rewriting walker
    /// (description stripping, reference qualification): children rebuild
    /// first, `field`/`enumCase` reshape structure members (each field's
    /// `type` already rewritten), then `node` rewrites the assembled node.
    func rewritten(
        node: (TypeSchema) -> TypeSchema = { $0 },
        field: (Field) -> Field = { $0 },
        enumCase: (EnumCase) -> EnumCase = { $0 }
    ) -> TypeSchema {
        let rebuilt: TypeSchema
        switch self {
            case .bool, .int, .uint, .float, .double, .string, .bytes, .reference, .unknown:
                rebuilt = self
            case .optional(let wrapped):
                rebuilt = .optional(wrapped.rewritten(node: node, field: field, enumCase: enumCase))
            case .array(let element):
                rebuilt = .array(element.rewritten(node: node, field: field, enumCase: enumCase))
            case .map(let key, let value):
                rebuilt = .map(
                    key: key.rewritten(node: node, field: field, enumCase: enumCase),
                    value: value.rewritten(node: node, field: field, enumCase: enumCase)
                )
            case .structure(let fields):
                rebuilt = .structure(
                    fields: fields.map { original in
                        field(
                            Field(
                                key: original.key,
                                name: original.name,
                                type: original.type.rewritten(
                                    node: node,
                                    field: field,
                                    enumCase: enumCase
                                ),
                                description: original.description
                            )
                        )
                    }
                )
            case .enumeration(let cases):
                rebuilt = .enumeration(cases: cases.map(enumCase))
        }
        return node(rebuilt)
    }
}

extension TypeSchema: SchemaDescribable {
    /// `TypeSchema` has a data-dependent decoder (it switches on the case tag),
    /// so it self-describes per the ``SchemaDescribable`` rule. The payload
    /// slots are `.unknown` by construction — the shape in those positions
    /// depends on the tag, which a static schema cannot express.
    public static var schema: TypeSchema {
        .structure(fields: [
            Field(key: 0, name: "tag", type: .uint),
            Field(key: 1, name: "first", type: .unknown),
            Field(key: 2, name: "second", type: .unknown),
        ])
    }
}

extension TypeSchema: Codable {
    enum WireKeys: Int, CodingKey {
        case tag = 0
        case first = 1
        case second = 2
    }

    /// The case tag — shared by the wire coder and the fingerprint's
    /// canonical encoding, so the number exists in exactly one table.
    var tag: UInt8 {
        switch self {
            case .bool: return 0
            case .int: return 1
            case .uint: return 2
            case .float: return 3
            case .double: return 4
            case .string: return 5
            case .bytes: return 6
            case .optional: return 7
            case .array: return 8
            case .map: return 9
            case .structure: return 10
            case .enumeration: return 11
            case .reference: return 12
            case .unknown: return 255
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: WireKeys.self)
        try container.encode(tag, forKey: .tag)
        switch self {
            case .bool, .int, .uint, .float, .double, .string, .bytes, .unknown:
                break
            case .optional(let wrapped):
                try container.encode(wrapped, forKey: .first)
            case .array(let element):
                try container.encode(element, forKey: .first)
            case .map(let key, let value):
                try container.encode(key, forKey: .first)
                try container.encode(value, forKey: .second)
            case .structure(let fields):
                try container.encode(fields, forKey: .first)
            case .enumeration(let cases):
                try container.encode(cases, forKey: .first)
            case .reference(let name):
                try container.encode(name, forKey: .first)
        }
    }

    /// Never actually throws; see the type documentation.
    public init(from decoder: any Decoder) throws {
        guard
            let container = try? decoder.container(keyedBy: WireKeys.self),
            let tag = try? container.decode(UInt8.self, forKey: .tag)
        else {
            self = .unknown
            return
        }
        switch tag {
            case 0: self = .bool
            case 1: self = .int
            case 2: self = .uint
            case 3: self = .float
            case 4: self = .double
            case 5: self = .string
            case 6: self = .bytes
            case 7:
                self =
                    (try? container.decode(TypeSchema.self, forKey: .first)).map(
                        TypeSchema.optional
                    ) ?? .unknown
            case 8:
                self =
                    (try? container.decode(TypeSchema.self, forKey: .first)).map(TypeSchema.array)
                    ?? .unknown
            case 9:
                if let key = try? container.decode(TypeSchema.self, forKey: .first),
                    let value = try? container.decode(TypeSchema.self, forKey: .second)
                {
                    self = .map(key: key, value: value)
                } else {
                    self = .unknown
                }
            case 10:
                self =
                    (try? container.decode([Field].self, forKey: .first)).map {
                        .structure(fields: $0)
                    } ?? .unknown
            case 11:
                self =
                    (try? container.decode([EnumCase].self, forKey: .first)).map {
                        .enumeration(cases: $0)
                    } ?? .unknown
            case 12:
                self =
                    (try? container.decode(String.self, forKey: .first)).map(TypeSchema.reference)
                    ?? .unknown
            default:
                self = .unknown
        }
    }
}
