#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The kernel-attested identity of a connected peer process, captured once at
/// accept time from `SO_PEERCRED` / `LOCAL_PEERCRED` and frozen for the life of
/// the connection.
///
/// `PeerIdentity` never travels on the wire — it is derived from the socket by
/// the server, not claimed by the client — so it is deliberately *not* `Codable`.
public struct PeerIdentity: Sendable, Hashable {
    /// Effective user id of the peer process.
    public let uid: uid_t
    /// Primary group id of the peer process.
    public let gid: gid_t
    /// Supplementary groups, frozen at accept time. Membership changes after
    /// accept do not affect an existing connection, mirroring POSIX process
    /// credentials.
    public let supplementaryGroups: [gid_t]
    /// Process id of the peer, for logging and diagnostics only — never an
    /// authorization input.
    public let pid: pid_t

    public init(uid: uid_t, gid: gid_t, supplementaryGroups: [gid_t], pid: pid_t) {
        self.uid = uid
        self.gid = gid
        self.supplementaryGroups = supplementaryGroups
        self.pid = pid
    }

    /// The identity assigned to peers with no kernel credentials (raw TCP in
    /// v1). `uid_t.max` / `gid_t.max` are not special-cased anywhere: because
    /// no real entity is owned by `uid_t.max` or grouped under `gid_t.max`,
    /// this identity matches only the *other* permission class in practice.
    /// If an ACL were deliberately created with owner `uid_t.max`, anonymous
    /// peers would receive its owner bits — do not do that.
    public static let anonymous = PeerIdentity(
        uid: uid_t.max,
        gid: gid_t.max,
        supplementaryGroups: [],
        pid: 0
    )
}
