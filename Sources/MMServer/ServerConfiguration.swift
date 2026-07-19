import MMWire
import NIOCore

/// Tunables for one `MMService`. Everything here is bounded on purpose:
/// frame size, connection count, in-flight requests, and idle time are all
/// capped so no peer can grow server memory without limit.
public struct MMServerConfiguration: Sendable {
    /// Where to listen.
    public var endpoint: MMEndpoint

    /// Maximum accepted frame payload length in bytes, enforced by
    /// `MMFrameDecoder` *before* accumulation. A peer claiming a larger frame
    /// has its connection failed immediately. Default 16 MiB.
    public var maxFrameLength: UInt32

    /// Maximum concurrently open connections. Enforced at accept: over the
    /// cap, the new connection is closed immediately (no busy frame — see
    /// `MMService` for the rationale) and a rejection is counted.
    public var maxConnections: Int

    /// Maximum requests a single connection may have running concurrently.
    /// A request arriving with the cap reached is answered immediately with
    /// `MMErrorCode.tooManyInFlight`. Requests are never queued beyond the cap.
    public var maxInFlightRequestsPerConnection: Int

    /// Maximum concurrently open streams on one connection, counted separately
    /// from ``maxInFlightRequestsPerConnection`` (a stream open does not consume
    /// a unary in-flight slot, and vice versa). A stream open past this cap is
    /// answered immediately with `MMErrorCode.tooManyInFlight` (code 4) and
    /// registers no state — the terminal retires the msgid at once. Per-stream
    /// buffering is separately bounded by the credit window (initial 8 items per
    /// direction), so this cap bounds the *number* of streams while the window
    /// bounds each one's memory. Default 8.
    public var maxConcurrentStreamsPerConnection: Int

    /// Traffic-idle timeout, monotonic (`TimeAmount`, backed by
    /// `NIODeadline`). A connection with no traffic in *either* direction for
    /// this long is closed — including clients that connect and never
    /// complete the hello exchange. Outbound activity counts as liveness on
    /// purpose: a consumer of a server→client stream legitimately sends nothing
    /// while the server pushes items to it, and must not be reaped mid-stream.
    public var idleTimeout: TimeAmount

    /// File mode `chmod(2)`ed onto the unix socket **between `bind(2)` and
    /// `listen(2)`**, so no connection can ever be accepted under a more
    /// permissive default mode.
    ///
    /// The socket file's permissions are the authorization boundary for who
    /// can talk to the server at all — everything past connect is decided by
    /// per-entity ACLs, but connect itself is decided here. The default
    /// `0o660` (owner and group read/write) supports the common
    /// same-user-or-service-group deployment; deployments must still set this
    /// (and the socket directory's ownership) deliberately rather than rely on
    /// the default. Use `0o600` for strictly single-user daemons. Ignored for
    /// TCP endpoints.
    public var unixSocketMode: UInt16

    /// Capability bitset advertised in the server hello. v1 defines no
    /// capability bits and always sends 0; the negotiated set is the bitwise
    /// intersection with the peer's.
    public var capabilities: UInt32

    /// The creation defaults, single-sourced for this initializer and the
    /// server builder's mirrored `Configuration(...)` form.
    public static let defaultMaxConnections = 128
    public static let defaultMaxInFlightRequestsPerConnection = 16
    public static let defaultMaxConcurrentStreamsPerConnection = 8
    public static let defaultIdleTimeout = TimeAmount.seconds(120)
    public static let defaultUnixSocketMode: UInt16 = 0o660

    public init(
        endpoint: MMEndpoint,
        maxFrameLength: UInt32 = MMWireInfo.defaultMaxFrameLength,
        maxConnections: Int = Self.defaultMaxConnections,
        maxInFlightRequestsPerConnection: Int = Self.defaultMaxInFlightRequestsPerConnection,
        maxConcurrentStreamsPerConnection: Int = Self.defaultMaxConcurrentStreamsPerConnection,
        idleTimeout: TimeAmount = Self.defaultIdleTimeout,
        unixSocketMode: UInt16 = Self.defaultUnixSocketMode,
        capabilities: UInt32 = 0
    ) {
        precondition(maxConnections > 0, "maxConnections must be positive")
        precondition(
            maxInFlightRequestsPerConnection > 0,
            "maxInFlightRequestsPerConnection must be positive"
        )
        precondition(
            maxConcurrentStreamsPerConnection > 0,
            "maxConcurrentStreamsPerConnection must be positive"
        )
        self.endpoint = endpoint
        self.maxFrameLength = maxFrameLength
        self.maxConnections = maxConnections
        self.maxInFlightRequestsPerConnection = maxInFlightRequestsPerConnection
        self.maxConcurrentStreamsPerConnection = maxConcurrentStreamsPerConnection
        self.idleTimeout = idleTimeout
        self.unixSocketMode = unixSocketMode
        self.capabilities = capabilities
    }
}
