#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Filesystem-style access control for one entity: an owning uid, an owning
/// gid, and nine mode bits `rwxrwxrwx` (owner << 6, group << 3, other) in the
/// low bits of a `UInt16`.
///
/// Authorization is **first-matching-class-wins**, preserved exactly from the
/// POSIX filesystem model: the peer is classified as owner, group, or other by
/// ``permissionClass(for:)``, and *only that class's bits* decide — even when
/// they deny access another class would have granted (mode `0o007` denies the
/// owner everything while granting everyone else `rwx`).
///
/// uid 0 is **not** special. There is no superuser override anywhere in this
/// library; administrative recovery uses the daemon's own uid.
public struct EntityACL: Sendable, Hashable {
    /// Owning user id.
    public var owner: uid_t
    /// Owning group id.
    public var group: gid_t
    /// Permission bits; only the low 9 bits are meaningful.
    public var mode: UInt16

    public init(owner: uid_t, group: gid_t, mode: UInt16) {
        self.owner = owner
        self.group = group
        self.mode = mode
    }

    /// The default mode for newly created entities: `rwxr-x---`. Servers may
    /// override this umask-style per instance.
    public static let defaultCreationMode: UInt16 = 0o750

    /// The three POSIX permission classes, in matching order.
    public enum PermissionClass: Sendable, Hashable {
        case owner
        case group
        case other
    }

    /// Classifies the peer: uid equality wins first, then primary-gid or
    /// supplementary-group membership, then other. Exposed separately from
    /// ``permitted(for:_:)`` so class selection is testable on its own.
    public func permissionClass(for peer: PeerIdentity) -> PermissionClass {
        if peer.uid == owner {
            return .owner
        }
        if peer.gid == group || peer.supplementaryGroups.contains(group) {
            return .group
        }
        return .other
    }

    /// The rwx bits granted to one permission class.
    public func bits(for permissionClass: PermissionClass) -> AccessMode {
        switch permissionClass {
        case .owner:
            return AccessMode(rawValue: UInt8((mode >> 6) & 0o7))
        case .group:
            return AccessMode(rawValue: UInt8((mode >> 3) & 0o7))
        case .other:
            return AccessMode(rawValue: UInt8(mode & 0o7))
        }
    }

    /// First-matching-class-wins permission check: the peer's class is selected
    /// once, and the requested bits must all be present in that class's bits.
    /// A pure denial in the matching class is final — later classes are never
    /// consulted.
    public func permitted(for peer: PeerIdentity, _ requested: AccessMode) -> Bool {
        requested.isSubset(of: bits(for: permissionClass(for: peer)))
    }
}

extension EntityACL: Codable {
    /// Integer keys per the wire convention: 0 = owner, 1 = group, 2 = mode.
    enum CodingKeys: Int, CodingKey {
        case owner = 0
        case group = 1
        case mode = 2
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.owner = try container.decode(UInt32.self, forKey: .owner)
        self.group = try container.decode(UInt32.self, forKey: .group)
        self.mode = try container.decode(UInt16.self, forKey: .mode)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(UInt32(owner), forKey: .owner)
        try container.encode(UInt32(group), forKey: .group)
        try container.encode(mode, forKey: .mode)
    }
}
