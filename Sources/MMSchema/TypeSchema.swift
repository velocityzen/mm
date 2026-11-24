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
///   11 `enumeration`, 12 `reference`, 13 `date`, 14 `datetime`,
///   15 `timestamp`, 16 `union`, 17 `duration`, 18 `uuid`, 255 `unknown`.
/// - key **1**: first payload — the wrapped schema for `optional`, the element
///   schema for `array`, the key schema for `map`, the field list for
///   `structure`, the case list for `enumeration` and `union`, the qualified
///   type name (string) for `reference`.
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
    /// Raw binary (MessagePack `bin`) — ``MMBytes`` in generated code.
    case bytes
    /// A calendar date — ``MMDate``, an ISO `YYYY-MM-DD` string on the wire.
    case date
    /// A wall-clock datetime with no zone — ``MMDateTime``,
    /// `YYYY-MM-DDTHH:MM:SS[.fff]` on the wire.
    case datetime
    /// An absolute instant — ``MMTimestamp``, a datetime with UTC offset
    /// (`...Z` or `...±HH:MM`) on the wire.
    case timestamp
    /// A span of elapsed time — ``MMDuration``, exact to the attosecond: on
    /// the wire, `bin` holding the duration encoding.
    case duration
    /// A universally unique identifier — ``MMUUID``: on the wire, `bin`
    /// holding its 16 bytes.
    case uuid
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
    /// A tagged union: exactly one of the cases, each carrying its own fields.
    /// The wire value is a map — key **0** the case name (a string, fixed
    /// decision), key **1** the case's fields as a structure keyed from 0,
    /// left out when the case declares none. Like ``enumeration(cases:)``,
    /// renaming a case is a wire break and reordering is not, and decoders
    /// map unrecognized case names to their local `unknown` case.
    case union(cases: [UnionCase])
    /// A reference to a named type by its qualified name
    /// (`journal.Priority`, `common.LineMeta`). Names are **nominal** — part
    /// of the wire contract, hashed into the fingerprint — and resolve through
    /// the ``TypeDefinition`` table served alongside the method list.
    case reference(String)
    /// A shape this peer does not recognize (future case, cyclic recursion
    /// point, or corrupt input).
    case unknown

    /// One field of a ``TypeSchema/structure(fields:)``.
    public struct Field: Sendable, Hashable {
        /// The integer `CodingKey` rawValue, if the type uses integer keys
        /// (the wire convention); `nil` for string-keyed types.
        public var key: Int?
        /// The field's name (`CodingKey.stringValue`).
        public var name: String
        public var type: TypeSchema
        /// Human-readable documentation, served by discovery. Never part of
        /// the fingerprint or of compatibility comparisons.
        public var description: String?
        /// The rules the field's value keeps beyond its shape, applied after
        /// an optional is unwrapped; nil when it declares none. Part of the
        /// contract: served by discovery and hashed into the fingerprint.
        public var constraints: Constraints?
        /// The value the field holds when its key is absent or nil; nil when
        /// it declares none. A field with a default has an optional
        /// ``type``. Part of the contract: served by discovery and hashed
        /// into the fingerprint.
        public var defaultValue: Default?
        /// Why the field is deprecated, or nil when it is not. Documentation,
        /// like ``description``: served by discovery, never hashed or
        /// compared.
        public var deprecation: String?

        public init(
            key: Int?,
            name: String,
            type: TypeSchema,
            description: String? = nil,
            constraints: Constraints? = nil,
            defaultValue: Default? = nil,
            deprecation: String? = nil
        ) {
            self.key = key
            self.name = name
            self.type = type
            self.description = description
            self.constraints = constraints
            self.defaultValue = defaultValue
            self.deprecation = deprecation
        }

        /// The integer the field travels under on the wire, or nil when it
        /// travels under its ``name``: its ``key``, unless the name reads as
        /// another integer. See ``wireKey(_:name:)``.
        package var wireKey: Int? {
            self.key.flatMap { Self.wireKey($0, name: self.name) }
        }

        /// The faithful-int-key rule, stated once for MMWire's encoder and
        /// decoder and for the compatibility judge: a `CodingKey`'s integer
        /// `key` stands in for it only when its canonical decimal form is
        /// the key's `name` (dictionary keys like "5", whose
        /// `_DictionaryCodingKey` derives the integer via `Int(name)`), or
        /// when the name is not itself numeric (a struct's `CodingKeys`,
        /// whose name is the property's). A numeric name that is not the
        /// key's canonical form ("05" or "+5" for 5, "0" for 2) travels as
        /// that name: honoring the integer would rewrite a dictionary key on
        /// the round trip, and could collide with a distinct integer key.
        ///
        /// Checked cheapest first: a property name fails to parse at its
        /// first character, so only a numeric name pays for formatting the
        /// key.
        @inlinable
        package static func wireKey(_ key: Int, name: String) -> Int? {
            guard let parsed = Int(name) else { return key }
            return parsed == key && String(key) == name ? key : nil
        }

        enum CodingKeys: Int, CodingKey {
            case key = 0
            case name = 1
            case type = 2
            case description = 3
            case constraints = 4
            case defaultValue = 5
            case deprecation = 6
        }
    }

    /// One case of a ``TypeSchema/union(cases:)``. The name is the wire tag;
    /// the fields are the case's own structure, keyed independently of every
    /// other case.
    public struct UnionCase: Sendable, Hashable, Codable {
        public var name: String
        public var fields: [Field]
        /// Human-readable documentation, served by discovery. Never part of
        /// the fingerprint or of compatibility comparisons.
        public var description: String?
        /// Why the case is deprecated, or nil when it is not. Documentation,
        /// like ``description``.
        public var deprecation: String?

        public init(
            name: String,
            fields: [Field] = [],
            description: String? = nil,
            deprecation: String? = nil
        ) {
            self.name = name
            self.fields = fields
            self.description = description
            self.deprecation = deprecation
        }

        enum CodingKeys: Int, CodingKey {
            case name = 0
            case fields = 1
            case description = 2
            case deprecation = 3
        }
    }

    /// One case of a ``TypeSchema/enumeration(cases:)``. The name is the wire value.
    public struct EnumCase: Sendable, Hashable, Codable {
        public var name: String
        /// Human-readable documentation, served by discovery. Never part of
        /// the fingerprint or of compatibility comparisons.
        public var description: String?
        /// Why the case is deprecated, or nil when it is not. Documentation,
        /// like ``description``.
        public var deprecation: String?

        public init(name: String, description: String? = nil, deprecation: String? = nil) {
            self.name = name
            self.description = description
            self.deprecation = deprecation
        }

        enum CodingKeys: Int, CodingKey {
            case name = 0
            case description = 1
            case deprecation = 2
        }
    }
}

extension TypeSchema {
    /// The same shape with every description and deprecation removed — the
    /// form the fingerprint hashes and `verify`/`SchemaDifference` compare,
    /// so doc edits never register as schema drift.
    public var strippingDescriptions: TypeSchema {
        self.rewritten(
            field: {
                Field(
                    key: $0.key,
                    name: $0.name,
                    type: $0.type,
                    constraints: $0.constraints,
                    defaultValue: $0.defaultValue
                )
            },
            enumCase: { EnumCase(name: $0.name) },
            unionCase: { UnionCase(name: $0.name, fields: $0.fields) }
        )
    }

    /// The same shape with every field constraint and default removed: what
    /// a decoder probe can see, since constraints are checked after decoding
    /// and a default is filled in where the decoder reads an optional.
    public var strippingConstraints: TypeSchema {
        self.rewritten(field: {
            Field(
                key: $0.key,
                name: $0.name,
                type: $0.type,
                description: $0.description,
                deprecation: $0.deprecation
            )
        })
    }

    /// The one structure-preserving rebuild behind every rewriting walker
    /// (description stripping, reference qualification): children rebuild
    /// first, `field`/`enumCase`/`unionCase` reshape members (each field's
    /// `type` already rewritten), then `node` rewrites the assembled node.
    func rewritten(
        node: (TypeSchema) -> TypeSchema = { $0 },
        field: (Field) -> Field = { $0 },
        enumCase: (EnumCase) -> EnumCase = { $0 },
        unionCase: (UnionCase) -> UnionCase = { $0 }
    ) -> TypeSchema {
        func child(_ schema: TypeSchema) -> TypeSchema {
            schema.rewritten(node: node, field: field, enumCase: enumCase, unionCase: unionCase)
        }
        func member(_ original: Field) -> Field {
            field(
                Field(
                    key: original.key,
                    name: original.name,
                    type: child(original.type),
                    description: original.description,
                    constraints: original.constraints,
                    defaultValue: original.defaultValue,
                    deprecation: original.deprecation
                )
            )
        }
        let rebuilt: TypeSchema
        switch self {
            case .bool, .int, .uint, .float, .double, .string, .bytes,
                .date, .datetime, .timestamp, .duration, .uuid, .reference, .unknown:
                rebuilt = self
            case .optional(let wrapped):
                rebuilt = .optional(child(wrapped))
            case .array(let element):
                rebuilt = .array(child(element))
            case .map(let key, let value):
                rebuilt = .map(key: child(key), value: child(value))
            case .structure(let fields):
                rebuilt = .structure(fields: fields.map(member))
            case .enumeration(let cases):
                rebuilt = .enumeration(cases: cases.map(enumCase))
            case .union(let cases):
                rebuilt = .union(
                    cases: cases.map { original in
                        unionCase(
                            UnionCase(
                                name: original.name,
                                fields: original.fields.map(member),
                                description: original.description,
                                deprecation: original.deprecation
                            )
                        )
                    }
                )
        }
        return node(rebuilt)
    }
}

extension TypeSchema {
    /// An optional Swift type: its described schema, wrapped. The
    /// cross-schema form inside a type expression
    /// (`Field("meta", .optional(Other.Name.self))`).
    public static func optional(_ type: (some SchemaDescribable).Type) -> TypeSchema {
        .optional(type.schema)
    }

    /// An array of a Swift type (`Field("tags", .array(Other.Name.self))`).
    public static func array(_ type: (some SchemaDescribable).Type) -> TypeSchema {
        .array(type.schema)
    }
}

extension TypeSchema.Field: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.key, forKey: .key)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.type, forKey: .type)
        try container.encodeIfPresent(self.description, forKey: .description)
        try container.encodeIfPresent(self.constraints, forKey: .constraints)
        try container.encodeIfPresent(self.defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(self.deprecation, forKey: .deprecation)
    }

    /// A default or deprecation this peer cannot read decodes as absent,
    /// like a key it does not know. A `duration` field's default travels as
    /// text, so the field's kind reads it as a duration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeSchema.self, forKey: .type)
        var defaultValue =
            (try? container.decodeIfPresent(TypeSchema.Default.self, forKey: .defaultValue))
            ?? nil
        var kind = type
        while case .optional(let wrapped) = kind { kind = wrapped }
        if case .duration = kind, case .string(let text)? = defaultValue,
            case .success(let duration) = MMDuration.parse(text)
        {
            defaultValue = .duration(duration)
        }
        self.init(
            key: try container.decodeIfPresent(Int.self, forKey: .key),
            name: try container.decode(String.self, forKey: .name),
            type: type,
            description: try container.decodeIfPresent(String.self, forKey: .description),
            constraints: try container.decodeIfPresent(
                TypeSchema.Constraints.self,
                forKey: .constraints
            ),
            defaultValue: defaultValue,
            deprecation: (try? container.decodeIfPresent(String.self, forKey: .deprecation))
                ?? nil
        )
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
            case .date: return 13
            case .datetime: return 14
            case .timestamp: return 15
            case .union: return 16
            case .duration: return 17
            case .uuid: return 18
            case .unknown: return 255
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: WireKeys.self)
        try container.encode(tag, forKey: .tag)
        switch self {
            case .bool, .int, .uint, .float, .double, .string, .bytes,
                .date, .datetime, .timestamp, .duration, .uuid, .unknown:
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
            case .union(let cases):
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
            case 13: self = .date
            case 14: self = .datetime
            case 15: self = .timestamp
            case 16:
                self =
                    (try? container.decode([UnionCase].self, forKey: .first)).map {
                        .union(cases: $0)
                    } ?? .unknown
            case 17: self = .duration
            case 18: self = .uuid
            default:
                self = .unknown
        }
    }
}
