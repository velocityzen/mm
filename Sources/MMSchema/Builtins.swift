/// Shared descriptor types for the protocol's builtin methods. Handlers land
/// in MMServer (Phase 3); the descriptors live here so client-only processes
/// can call the builtins with full typing.

/// Request for `server.schema` — an empty payload: the discovery **scope** is
/// the call's envelope entity (a concrete entity narrows to its subtree;
/// root — the empty path — asks about the whole tree, filtered by the
/// caller's traversal rights server-side).
public struct SchemaRequest: Codable, Hashable, Sendable, SchemaDescribable {
    public init() {}

    public static var schema: TypeSchema { .structure(fields: []) }
}

/// One namespace visible in a discovery response: its prefix entity and its
/// doc-only description. Served only for namespaces that declared one.
public struct NamespaceSignature: Codable, Hashable, Sendable {
    /// The namespace prefix (`journal`), the same entity that scopes its
    /// methods.
    public var name: String
    /// Human-readable namespace documentation.
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }

    enum CodingKeys: Int, CodingKey {
        case name = 0
        case description = 1
    }
}

/// Response for `server.schema`.
public struct SchemaResponse: Codable, Hashable, Sendable {
    /// ``SchemaFingerprint`` of the *complete* method set the server exposes
    /// (not of the filtered `methods` list), so a client can compare it with
    /// the hello fingerprint.
    public var fingerprint: UInt64
    /// The signatures visible to the requesting peer.
    public var methods: [MethodSignature]
    /// The named-type definitions transitively referenced by `methods` —
    /// the resolution table for every ``TypeSchema/reference(_:)`` they
    /// contain. Empty from pre-types servers (the key is absent on the wire
    /// and decodes as `[]`).
    public var types: [TypeDefinition]
    /// The described namespaces among the visible methods' prefixes, sorted
    /// by name — doc-only, never fingerprinted. Empty from servers predating
    /// the key (absent on the wire, decodes as `[]`) and from namespaces
    /// that declared no description.
    public var namespaces: [NamespaceSignature]

    public init(
        fingerprint: UInt64,
        methods: [MethodSignature],
        types: [TypeDefinition] = [],
        namespaces: [NamespaceSignature] = []
    ) {
        self.fingerprint = fingerprint
        self.methods = methods
        self.types = types
        self.namespaces = namespaces
    }

    enum CodingKeys: Int, CodingKey {
        case fingerprint = 0
        case methods = 1
        case types = 2
        case namespaces = 3
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fingerprint = try container.decode(UInt64.self, forKey: .fingerprint)
        self.methods = try container.decode([MethodSignature].self, forKey: .methods)
        // Absent on older encodings; the wire-evolution contract, both keys.
        self.types = try container.decodeIfPresent([TypeDefinition].self, forKey: .types) ?? []
        self.namespaces =
            try container.decodeIfPresent([NamespaceSignature].self, forKey: .namespaces) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.fingerprint, forKey: .fingerprint)
        try container.encode(self.methods, forKey: .methods)
        try container.encode(self.types, forKey: .types)
        // Optional slot: absent when empty, like every optional wire key.
        if !self.namespaces.isEmpty {
            try container.encode(self.namespaces, forKey: .namespaces)
        }
    }
}

/// Request for `server.entity` — an empty payload: the stat **target** is the
/// call's envelope entity.
public struct StatRequest: Codable, Hashable, Sendable, SchemaDescribable {
    public init() {}

    public static var schema: TypeSchema { .structure(fields: []) }
}

/// Response for `server.entity`: the ten bytes of the entity's ACL. Plain
/// `UInt32` fields (not `uid_t`/`gid_t`) because this struct is a wire type.
public struct StatResponse: Codable, Hashable, Sendable {
    public var owner: UInt32
    public var group: UInt32
    public var mode: UInt16

    public init(owner: UInt32, group: UInt32, mode: UInt16) {
        self.owner = owner
        self.group = group
        self.mode = mode
    }

    enum CodingKeys: Int, CodingKey {
        case owner = 0
        case group = 1
        case mode = 2
    }
}

/// The builtin method namespace, auto-registered by every router.
public enum Builtins: MethodNamespace {
    /// Schema discovery. `.read`: discovering what methods exist under an
    /// entity is observing it.
    public static let schema = Method<SchemaRequest, SchemaResponse>(
        name: "server.schema",
        access: .read
    )

    /// ACL inspection. Access choice: `.read`. POSIX `stat(2)` needs only
    /// search (`x`) on the path — metadata is "free" once you can traverse —
    /// but our stat returns ownership information (uid/gid/mode), and peers
    /// that can merely traverse an entity should not learn who owns it. The
    /// x-on-every-ancestor traversal rule still applies on top, exactly as for
    /// every other method.
    public static let entity = Method<StatRequest, StatResponse>(
        name: "server.entity",
        access: .read
    )

    @SchemaBuilder public static var all: [AnyMethod] {
        Self.schema
        Self.entity
    }
}
