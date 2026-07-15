import Logging

/// Task-local log context for the transport, plus the `Logger.MetadataProvider`
/// that surfaces it.
///
/// The server binds ``connectionID`` around each connection's task tree (the
/// per-connection child task in the accept loop), so a host that bootstraps
/// swift-log with ``metadataProvider`` — or merges it into its own provider —
/// gets the connection id on *every* log line emitted under that connection,
/// including lines from application handler bodies using their own loggers,
/// which the library's per-connection logger metadata cannot reach.
///
/// ```swift
/// LoggingSystem.bootstrap(metadataProvider: MMLogContext.metadataProvider) {
///     StreamLogHandler.standardError(label: $0)
/// }
/// ```
///
/// The library's own log lines carry the explicit `"connection"` metadata key
/// regardless, so nothing is lost when a host does not install the provider.
public enum MMLogContext {
    /// The current connection's server-assigned id, bound by the transport for
    /// the duration of the connection's task tree; nil outside a connection.
    @TaskLocal public static var connectionID: UInt64?

    /// Emits `["connection": <id>]` when a connection id is bound, and nothing
    /// otherwise.
    public static let metadataProvider = Logger.MetadataProvider {
        guard let connectionID = Self.connectionID else { return [:] }
        return ["connection": "\(connectionID)"]
    }
}
