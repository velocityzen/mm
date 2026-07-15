import MMSchema
import NIOCore
import NIOPosix

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

    /// Extracts the supplementary group ids from the `Groups:` line of a
    /// Linux `/proc/<pid>/status` file.
    ///
    /// Parses defensively: the first line starting with `Groups:` wins,
    /// tokens are split on spaces/tabs, non-numeric or out-of-range tokens are
    /// skipped rather than failing, and a missing line yields the empty list
    /// (fewer groups can only ever *deny* access, so parse failures fail
    /// closed).
    static func supplementaryGroups(fromProcStatus text: Substring) -> [gid_t] {
        // Note "\r\n" is a single Character (grapheme cluster), so it must be
        // its own separator case — splitting on "\n" alone would not split
        // CRLF-terminated lines.
        let lines = text.split(
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        )
        for line in lines {
            guard line.hasPrefix("Groups:") else { continue }
            var groups: [gid_t] = []
            for token in line.dropFirst("Groups:".count)
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            {
                if let value = UInt32(token) {
                    groups.append(gid_t(value))
                }
            }
            return groups
        }
        return []
    }

    /// Reads a (seekless, procfs-style) file to EOF into memory, `hardCap`
    /// bounded. Returns nil — never a partial buffer — when EOF was not
    /// reached within the cap or a read failed.
    ///
    /// Truncation must be a hard failure here, not a shorter result: cutting
    /// a `Groups:` token mid-digits would fabricate a *different, valid* gid
    /// ("412345" truncated to "4123") and grant supplementary-group access
    /// the peer does not hold. Failing closed to "no data" only ever denies.
    ///
    /// Blocking — call on the thread pool only. Platform-independent so the
    /// boundary behavior is unit-testable everywhere.
    static func readToEnd(descriptor: CInt, hardCap: Int) -> [UInt8]? {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while bytes.count <= hardCap {
            let readCount = chunk.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if readCount > 0 {
                bytes.append(contentsOf: chunk[0..<readCount])
            } else if readCount == 0 {
                return bytes  // EOF within the cap: complete.
            } else if errno == EINTR {
                continue
            } else {
                return nil  // Read error: fail closed.
            }
        }
        return nil  // Cap exceeded before EOF: fail closed.
    }

    // MARK: - Capture at accept

    #if canImport(Darwin)
    /// Darwin capture path: `getsockopt(SOL_LOCAL, LOCAL_PEERCRED)` for the
    /// `xucred` (effective uid + up to 16 groups, first is the egid) and
    /// `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` for the peer pid, both read
    /// on the channel's event loop through NIO's `SocketOptionProvider`
    /// unsafe accessors. No file IO on this platform, so `threadPool` is
    /// unused here (the parameter exists for the shared cross-platform
    /// call site).
    static func captureUnixPeer(
        channel: any Channel,
        threadPool: NIOThreadPool
    ) async -> Result<PeerIdentity, PeerCredentialsError> {
        guard let provider = channel as? any SocketOptionProvider else {
            return .failure(.unsupportedChannel)
        }
        do {
            let credentials: xucred = try await provider.unsafeGetSocketOption(
                level: SocketOptionLevel(SOL_LOCAL),
                name: SocketOptionName(LOCAL_PEERCRED)
            ).get()
            let pid: pid_t = try await provider.unsafeGetSocketOption(
                level: SocketOptionLevel(SOL_LOCAL),
                name: SocketOptionName(LOCAL_PEERPID)
            ).get()
            return .success(Self.identity(fromXucred: credentials, pid: pid))
        } catch {
            return .failure(.syscallFailed(description: String(describing: error)))
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
    /// Linux capture path: `getsockopt(SOL_SOCKET, SO_PEERCRED)` for
    /// `ucred{pid, uid, gid}` (read on the event loop through NIO's
    /// `SocketOptionProvider` unsafe accessors), then one bounded read of
    /// `/proc/<pid>/status` on `NIOThreadPool.runIfActive` (it is file IO)
    /// for the supplementary `Groups:` line.
    ///
    /// TOCTOU caveat: the uid/gid in `ucred` are kernel-attested from the
    /// socket itself and race-free, but the pid → `/proc` lookup is not —
    /// the peer can exit between `SO_PEERCRED` and the `/proc` read, and
    /// the pid can be reused by an unrelated process, in which case the
    /// *supplementary* groups read here belong to the reusing process.
    /// The primary uid/gid (the strongest identity inputs) are never
    /// affected; a failed or empty `/proc` read yields no supplementary
    /// groups, which only ever denies access.
    static func captureUnixPeer(
        channel: any Channel,
        threadPool: NIOThreadPool
    ) async -> Result<PeerIdentity, PeerCredentialsError> {
        guard let provider = channel as? any SocketOptionProvider else {
            return .failure(.unsupportedChannel)
        }
        do {
            let credentials: ucred = try await provider.unsafeGetSocketOption(
                level: SocketOptionLevel(SOL_SOCKET),
                name: SocketOptionName(SO_PEERCRED)
            ).get()
            let primaryGid = credentials.gid
            let supplementary = try await threadPool.runIfActive {
                Self.readProcStatusSupplementaryGroups(pid: credentials.pid)
                    .filter { $0 != primaryGid }
            }
            return .success(
                PeerIdentity(
                    uid: credentials.uid,
                    gid: credentials.gid,
                    supplementaryGroups: supplementary,
                    pid: credentials.pid
                )
            )
        } catch {
            return .failure(.syscallFailed(description: String(describing: error)))
        }
    }

    /// Blocking, bounded read of `/proc/<pid>/status` — call on the thread
    /// pool only. Reads the whole file (never a truncated prefix — see
    /// ``readToEnd(descriptor:hardCap:)`` for why truncation must fail
    /// closed rather than parse) and fails closed to the empty list on
    /// any error. The 4 MiB cap is generous headroom: `NGROUPS_MAX` is
    /// 65536 on Linux, so the `Groups:` line alone can approach ~720 KiB
    /// in pathological group-membership setups.
    static func readProcStatusSupplementaryGroups(pid: pid_t) -> [gid_t] {
        let descriptor = open("/proc/\(pid)/status", O_RDONLY)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        guard
            let bytes = Self.readToEnd(descriptor: descriptor, hardCap: 4 * 1024 * 1024)
        else {
            return []
        }
        let text = String(decoding: bytes, as: UTF8.self)
        return Self.supplementaryGroups(fromProcStatus: text[...])
    }
    #endif
}
