/// What the hello exchange established about the server, exposed as
/// ``MMClientConnection/server`` after `connect` returns and fixed for the
/// connection's lifetime.
public struct ServerInfo: Sendable, Hashable {
    /// Min-wins negotiated protocol version in effect on this connection.
    /// Always >= 1 on a live connection.
    public let protocolVersion: UInt8
    /// The schema fingerprint the server advertised, verbatim.
    public let fingerprint: UInt64
    /// `nil` when ``MMClientConfiguration/schema`` carried no whole-server
    /// expectation (none configured, or a partial slice); otherwise whether
    /// the server's fingerprint matched the expectation folded from this
    /// build's contracts. `false` is a discovery trigger, never a failure.
    public let fingerprintMatched: Bool?
    /// Bitwise intersection of both sides' capability bitsets. 0 in v1.
    public let capabilities: UInt32

    public init(
        protocolVersion: UInt8,
        fingerprint: UInt64,
        fingerprintMatched: Bool?,
        capabilities: UInt32
    ) {
        self.protocolVersion = protocolVersion
        self.fingerprint = fingerprint
        self.fingerprintMatched = fingerprintMatched
        self.capabilities = capabilities
    }
}
