/// Where a server listens and a client connects. Switched on **only** in
/// transport bootstrap code (`MMService`, `MMClientConnection.connect`) —
/// everything above the transport is endpoint-agnostic.
///
/// Lives in `MMWire` so both `MMServer` and `MMClient` can share it without the
/// client linking the server module. It is pure value data: no NIO types.
///
/// ## Identity per endpoint kind
///
/// - `unix`: the kernel attests the peer's uid/gid at accept
///   (`LOCAL_PEERCRED` on Darwin, `SO_PEERCRED` on Linux); the socket file's
///   permissions are the outer authorization boundary.
/// - `tcp`: v1 has no peer identity over TCP — every peer is
///   `PeerIdentity.anonymous` and only ACL *other* bits decide access. Raw TCP
///   is for trusted networks; the documented remote path is SSH unix-socket
///   forwarding, which preserves peer credentials end to end.
/// - `fd`: the client trusts the descriptor it was given; the server side,
///   which adopted it through `MMServiceHandle.adopt`, uses the identity its
///   host attested at adoption.
public enum MMEndpoint: Sendable, Hashable {
    /// A unix domain socket at `path`. The path must fit `sockaddr_un.sun_path`
    /// (103 bytes on Darwin, 107 on Linux).
    case unix(path: String)
    /// A TCP endpoint. For servers, port 0 binds an ephemeral port, reported
    /// as the address the server's bracket yields. `TCP_NODELAY` is always
    /// set on accepted and connected TCP channels.
    case tcp(host: String, port: Int)
    /// An already-connected stream socket, by its file descriptor: one end of
    /// a `socketpair(2)`, or a descriptor a parent process passed down. **Client only**: the
    /// connection adopts the descriptor, owns it from then on, and closes it
    /// with the connection; there is no connect step and no peer identity
    /// check — whoever holds the other end is the server. Servers take
    /// connected sockets through `MMServiceHandle.adopt` instead, and refuse
    /// this endpoint at bind.
    case fd(CInt)
}
