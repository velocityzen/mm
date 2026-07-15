import MMWire

/// Typed error for the MMServer layer, per the house convention of one error
/// enum per layer. Inner wire errors are wrapped as a case payload, never
/// leaked raw across the layer boundary.
///
/// This is the error surface of the connection's outbound writer seam. It never
/// travels on the wire — wire errors are `MMErrorObject` values.
public enum ServerError: Error, Sendable, Hashable {
    /// Encoding an outbound envelope failed. Wraps the wire error so callers
    /// can log the cause without re-deriving it.
    case encodingFailed(MMWireError)
    /// The connection backing this context is closed; the envelope was not
    /// delivered.
    case connectionClosed
    /// The transport failed in a way that is not branch-worthy. Coarse by
    /// design: infrastructure failures are for logs, not for `switch`.
    case transport(description: String)
}

/// The error surface of ``EntityACLProvider`` implementations.
///
/// Deliberately a single opaque description rather than a taxonomy: the router
/// treats *every* provider failure identically — log it, answer the peer with
/// `internalError`, and never expose provider detail on the wire — so a richer
/// shape would never be switched on.
public struct ACLProviderError: Error, Sendable, Hashable {
    /// Human-readable failure description, for server-side logs only.
    public var description: String

    public init(description: String) {
        self.description = description
    }
}
