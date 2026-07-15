import MMSchema
import MMWire
import NIOCore

/// The per-call context handed to every handler invocation.
///
/// The connection-scoped parts are built once by the transport when a
/// connection completes its hello exchange and frozen for the connection's
/// lifetime: the kernel-attested `PeerIdentity`, the min-wins negotiated
/// protocol version, and a connection id for log metadata. Dispatch then
/// scopes a copy per call with the authorized target ``entity``.
public struct MMContext: Sendable {
    /// Kernel peer credentials, frozen at accept time. The only authorization
    /// input.
    public let peer: PeerIdentity
    /// The negotiated wire protocol version (min-wins from the hello).
    public let protocolVersion: UInt8
    /// Server-assigned connection id, for log metadata only.
    public let connectionID: UInt64
    /// The **already-authorized target** of the current call — the entity
    /// slot of the open envelope, after the traversal and target ACL checks
    /// passed. Handlers read it from here: the entity is envelope metadata,
    /// never part of a request payload. On a connection's base context
    /// (before dispatch scopes it) this is `EntityName.root`.
    public let entity: EntityName

    public init(
        peer: PeerIdentity,
        protocolVersion: UInt8,
        connectionID: UInt64,
        entity: EntityName = .root
    ) {
        self.peer = peer
        self.protocolVersion = protocolVersion
        self.connectionID = connectionID
        self.entity = entity
    }

    /// The per-call copy dispatch hands to handlers, carrying the authorized
    /// target.
    func scoped(to entity: EntityName) -> MMContext {
        MMContext(
            peer: self.peer,
            protocolVersion: self.protocolVersion,
            connectionID: self.connectionID,
            entity: entity
        )
    }
}
