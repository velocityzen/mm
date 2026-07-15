import MMWire
import NIOCore

/// Tunables for one ``MMClientConnection``. Everything here is bounded on
/// purpose: frame size and in-flight calls are capped so a misbehaving server
/// (or application) cannot grow client memory without limit.
public struct MMClientConfiguration: Sendable {
    /// Maximum accepted frame payload length in bytes, enforced by
    /// `MMFrameDecoder` *before* accumulation (and mirrored on the encoder, so
    /// an oversized outbound payload fails locally instead of corrupting the
    /// stream). Default 16 MiB.
    public var maxFrameLength: UInt32

    /// Capability bitset advertised in the client hello. v1 defines no
    /// capability bits and always sends 0; the negotiated set is the bitwise
    /// intersection with the server's.
    public var capabilities: UInt32

    /// The schema fingerprint this client was compiled against, or `nil` to
    /// skip comparison entirely.
    ///
    /// When set, it is carried in the client hello's fingerprint slot and
    /// compared against the server hello: the verdict lands in
    /// ``HelloInfo/fingerprintMatched`` — a mismatch is **never** a disconnect
    /// (fixed wire decision; it is the trigger for schema discovery, which is
    /// part B). When `nil`, the hello carries `0` in the fingerprint slot,
    /// meaning "no expectation" — servers never act on the client's
    /// fingerprint, so the value is informational either way.
    public var expectedFingerprint: UInt64?

    /// Maximum calls this connection may have awaiting responses at once.
    /// A call started with the cap reached fails immediately with
    /// `MMCallError.tooManyInFlight` — calls are never queued beyond the cap.
    /// Default 16, matching the server's per-connection default.
    public var maxInFlightCalls: Int

    /// TCP connect timeout handed to the bootstrap, monotonic (`TimeAmount`).
    /// `nil` uses NIO's default. Covers the transport connect only, not the
    /// hello exchange (bound by ``helloTimeout``).
    public var connectTimeout: TimeAmount?

    /// Bound on the hello exchange, monotonic (`TimeAmount`, scheduled on the
    /// channel's event loop). If the server's hello has not arrived within
    /// this window after the transport connect, the channel is closed and
    /// `connect` fails with `.transport` ("connection closed before server
    /// hello"). Default 10 seconds. `nil` disables the bound — not
    /// recommended: a server that accepts the socket but never writes would
    /// park `connect` until the peer acts (task cancellation still closes the
    /// channel either way).
    public var helloTimeout: TimeAmount?

    /// Traffic-idle timeout, monotonic (`TimeAmount`, backed by
    /// `NIODeadline`); `nil` (the default) disables idle reaping. A connection
    /// with no traffic in *either* direction for this long is closed — pending
    /// calls fail with `MMCallError.connectionClosed`. Inbound stream items
    /// count as liveness, so a consumer of a server→client stream is not
    /// reaped mid-stream.
    public var idleTimeout: TimeAmount?

    public init(
        maxFrameLength: UInt32 = MMWireInfo.defaultMaxFrameLength,
        capabilities: UInt32 = 0,
        expectedFingerprint: UInt64? = nil,
        maxInFlightCalls: Int = 16,
        connectTimeout: TimeAmount? = nil,
        helloTimeout: TimeAmount? = .seconds(10),
        idleTimeout: TimeAmount? = nil
    ) {
        precondition(maxInFlightCalls > 0, "maxInFlightCalls must be positive")
        self.maxFrameLength = maxFrameLength
        self.capabilities = capabilities
        self.expectedFingerprint = expectedFingerprint
        self.maxInFlightCalls = maxInFlightCalls
        self.connectTimeout = connectTimeout
        self.helloTimeout = helloTimeout
        self.idleTimeout = idleTimeout
    }

    /// The hello this configuration sends as the connection's first frame.
    var clientHello: MMHello {
        MMHello(
            protocolVersion: MMWireInfo.protocolVersion,
            schemaFingerprint: self.expectedFingerprint ?? 0,
            capabilities: self.capabilities
        )
    }
}
