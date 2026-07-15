/// Shared descriptor types for the protocol's builtin methods. Handlers land
/// in MMServer (Phase 3); the descriptors live here so client-only processes
/// can call the builtins with full typing.

/// Request for `rpc.schema` — an empty payload: the discovery **scope** is
/// the call's envelope entity (a concrete entity narrows to its subtree;
/// root — the empty path — asks about the whole tree, filtered by the
/// caller's traversal rights server-side).
public struct SchemaRequest: Codable, Hashable, Sendable, SchemaDescribable {
    public init() {}

    public static var schema: TypeSchema { .structure(fields: []) }
}

/// Response for `rpc.schema`.
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

    public init(fingerprint: UInt64, methods: [MethodSignature], types: [TypeDefinition] = []) {
        self.fingerprint = fingerprint
        self.methods = methods
        self.types = types
    }

    enum CodingKeys: Int, CodingKey {
        case fingerprint = 0
        case methods = 1
        case types = 2
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fingerprint = try container.decode(UInt64.self, forKey: .fingerprint)
        self.methods = try container.decode([MethodSignature].self, forKey: .methods)
        // Absent on pre-types encodings; the wire-evolution contract.
        self.types = try container.decodeIfPresent([TypeDefinition].self, forKey: .types) ?? []
    }
}

/// Request for `entity.stat` — an empty payload: the stat **target** is the
/// call's envelope entity.
public struct StatRequest: Codable, Hashable, Sendable, SchemaDescribable {
    public init() {}

    public static var schema: TypeSchema { .structure(fields: []) }
}

/// Response for `entity.stat`: the ten bytes of the entity's ACL. Plain
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
        name: "rpc.schema",
        access: .read
    )

    /// ACL inspection. Access choice: `.read`. POSIX `stat(2)` needs only
    /// search (`x`) on the path — metadata is "free" once you can traverse —
    /// but our stat returns ownership information (uid/gid/mode), and peers
    /// that can merely traverse an entity should not learn who owns it. The
    /// x-on-every-ancestor traversal rule still applies on top, exactly as for
    /// every other method.
    public static let stat = Method<StatRequest, StatResponse>(
        name: "entity.stat",
        access: .read
    )

    @SchemaBuilder public static var all: [AnyMethod] {
        Self.schema
        Self.stat
    }
}
