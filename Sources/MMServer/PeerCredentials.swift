import FP
import MMSchema
import NIOCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Why peer credentials could not be captured. Internal: a capture failure is
/// logged server-side and the connection is closed (fail closed) — no detail
/// ever reaches the wire.
enum PeerCredentialsError: Error, Sendable, Hashable {
    /// The channel does not expose `SocketOptionProvider` (not a POSIX socket
    /// channel).
    case unsupportedChannel
    /// A `getsockopt(2)` (or the event-loop hop around it) failed.
    case syscallFailed(description: String)
}

/// Kernel peer-credential capture for unix-domain connections, plus the pure
/// mapping/parsing functions it is built from (kept platform-independent so
/// both are unit-testable everywhere).
///
/// Identity is captured **once at accept** and frozen into
/// ``MMContext`` for the connection's lifetime, mirroring POSIX
/// process credentials: group-membership changes after accept do not affect
/// an existing connection.
enum PeerCredentials {
    // MARK: - Pure mapping (testable on any platform)

    /// Maps a Darwin `xucred`-shaped credential list onto ``PeerIdentity``.
    ///
    /// `LOCAL_PEERCRED` reports the peer's *effective* uid and its group list
    /// as up to 16 gids where **`cr_groups[0]` is the effective (primary) gid**
    /// and entries `1..<cr_ngroups` are the supplementary groups — that is the
    /// primary-vs-supplementary mapping used here. A defensively-handled empty
    /// group list (malformed kernel reply) maps the primary gid to `gid_t.max`,
    /// which — like ``PeerIdentity/anonymous`` — matches only the *other*
    /// permission class in practice.
    static func identity(uid: uid_t, groups: [gid_t], pid: pid_t) -> PeerIdentity {
        PeerIdentity(
            uid: uid,
            gid: groups.first ?? gid_t.max,
            supplementaryGroups: Array(groups.dropFirst()),
            pid: pid
        )
    }

    /// The peer's supplementary groups from a zero-filled `SO_PEERGROUPS`
    /// buffer.
    ///
    /// The kernel writes its `n` groups to the front of the buffer and
    /// reports `n` only through the option length, which NIO's
    /// `unsafeGetSocketOption` does not return; NIO zero-fills the buffer
    /// first. So everything up to the last nonzero slot is the list, and the
    /// zero tail is padding. A real gid 0 at the very end of the list cannot
    /// be told from padding and is dropped, which only ever denies access.
    /// The kernel keeps the list sorted, so outside user-namespace remapping
    /// a gid 0 comes first and is lost only when it is the peer's sole
    /// supplementary group.
    static func supplementaryGroups(fromPeerGroups slots: [gid_t]) -> [gid_t] {
        guard let last = slots.lastIndex(where: { $0 != 0 }) else {
            return []
        }
        return Array(slots[...last])
    }

    // MARK: - Capture at accept

    #if canImport(Darwin)
    /// Darwin capture path: `getsockopt(SOL_LOCAL, LOCAL_PEERCRED)` for the
    /// `xucred` (effective uid + up to 16 groups, first is the egid) and
    /// `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` for the peer pid, both read
    /// on the channel's event loop through NIO's `SocketOptionProvider`
    /// unsafe accessors.
    static func captureUnixPeer(
        channel: any Channel
    ) async -> Result<PeerIdentity, PeerCredentialsError> {
        await Result.fromOptional(
            channel as? any SocketOptionProvider,
            error: PeerCredentialsError.unsupportedChannel
        )
        .flatMapAsync { provider in
            await Result.fromAsync {
                let credentials: xucred = try await provider.unsafeGetSocketOption(
                    level: SocketOptionLevel(SOL_LOCAL),
                    name: SocketOptionName(LOCAL_PEERCRED)
                ).get()
                let pid: pid_t = try await provider.unsafeGetSocketOption(
                    level: SocketOptionLevel(SOL_LOCAL),
                    name: SocketOptionName(LOCAL_PEERPID)
                ).get()
                return Self.identity(fromXucred: credentials, pid: pid)
            }
            .mapError { .syscallFailed(description: String(describing: $0)) }
        }
    }

    /// Pulls the group list out of the fixed 16-slot `cr_groups` tuple and
    /// defers to the pure mapper. `cr_ngroups` is clamped into `0...16`
    /// defensively — the kernel never reports more, but this function
    /// refuses to read past the tuple regardless.
    static func identity(fromXucred credentials: xucred, pid: pid_t) -> PeerIdentity {
        let slotCount = 16  // xucred.cr_groups is a fixed gid_t[16]; Darwin has no XU_NGROUPS import.
        let count = min(max(Int(credentials.cr_ngroups), 0), slotCount)
        let groups = withUnsafeBytes(of: credentials.cr_groups) { raw -> [gid_t] in
            let gids = raw.bindMemory(to: gid_t.self)
            return (0..<count).map { gids[$0] }
        }
        return Self.identity(uid: credentials.cr_uid, groups: groups, pid: pid)
    }
    #elseif os(Linux)
    /// Layout-compatible mirror of Linux `struct ucred` from `<sys/socket.h>`
    /// (`{pid, uid, gid}` in declaration order). Declared locally because the
    /// type is guarded by `__USE_GNU` in the C headers and not exported by
    /// the Glibc/Musl Swift overlays; `unsafeGetSocketOption` only needs a
    /// value type whose size and layout match what the kernel writes.
    struct PeerUcred {
        var pid: pid_t
        var uid: uid_t
        var gid: gid_t
    }

    /// Room for the peer's supplementary groups. A peer in more groups makes
    /// `SO_PEERGROUPS` fail with `ERANGE`; it is then captured with no
    /// supplementary groups, which only ever denies access.
    typealias PeerGroups = InlineArray<256, gid_t>

    /// Linux capture path: `getsockopt(SOL_SOCKET, SO_PEERCRED)` for
    /// `ucred{pid, uid, gid}` and `getsockopt(SOL_SOCKET, SO_PEERGROUPS)`
    /// (Linux 4.13+) for the supplementary groups, both read on the event
    /// loop through NIO's `SocketOptionProvider` unsafe accessors. Both come
    /// from the credentials the kernel recorded when the peer connected, so
    /// they describe the same process and cannot race its exit or a pid
    /// reuse.
    static func captureUnixPeer(
        channel: any Channel
    ) async -> Result<PeerIdentity, PeerCredentialsError> {
        await Result.fromOptional(
            channel as? any SocketOptionProvider,
            error: PeerCredentialsError.unsupportedChannel
        )
        .flatMapAsync { provider in
            await Result.fromAsync {
                let credentials: PeerUcred = try await provider.unsafeGetSocketOption(
                    level: SocketOptionLevel(SOL_SOCKET),
                    name: SocketOptionName(SO_PEERCRED)
                ).get()
                let supplementary = try await Self.peerGroups(provider)
                return PeerIdentity(
                    uid: credentials.uid,
                    gid: credentials.gid,
                    supplementaryGroups: supplementary.filter { $0 != credentials.gid },
                    pid: credentials.pid
                )
            }
            .mapError { .syscallFailed(description: String(describing: $0)) }
        }
    }

    /// The peer's supplementary groups via `SO_PEERGROUPS`; none when they
    /// do not fit in ``PeerGroups`` (`ERANGE`).
    static func peerGroups(_ provider: any SocketOptionProvider) async throws -> [gid_t] {
        do {
            let slots: PeerGroups = try await provider.unsafeGetSocketOption(
                level: SocketOptionLevel(SOL_SOCKET),
                name: SocketOptionName(SO_PEERGROUPS)
            ).get()
            return Self.supplementaryGroups(fromPeerGroups: slots.indices.map { slots[$0] })
        } catch let error as IOError where error.errnoCode == ERANGE {
            return []
        }
    }
    #endif
}
