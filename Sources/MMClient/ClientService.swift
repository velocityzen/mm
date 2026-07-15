import ServiceLifecycle

/// swift-service-lifecycle adapter for ``MMClientConnection``: drop one in a
/// `ServiceGroup` and the connection's inbound loop runs as a managed service.
///
/// ```swift
/// let connection = try await MMClientConnection.connect(to: endpoint).get()
/// let group = ServiceGroup(configuration: .init(
///     services: [.init(service: MMClientConnectionService(connection: connection))],
///     gracefulShutdownSignals: [.sigterm],
///     cancellationSignals: [.sigint],
///     logger: logger
/// ))
/// try await group.run()
/// ```
///
/// An adapter (rather than direct `Service` conformance on the actor) because
/// `Service.run() async throws` and the connection's typed
/// `run() async -> Result<Void, MMClientError>` cannot share a name; this
/// wrapper is the one seam where the `Result` converts to a throw.
///
/// On graceful shutdown the connection is closed immediately — pending calls
/// fail with `MMCallError.connectionClosed`. There is no call drain in v1: an
/// application that wants in-flight calls answered stops issuing calls and
/// awaits them *before* triggering shutdown.
public struct MMClientConnectionService: Service {
    public let connection: MMClientConnection

    public init(connection: MMClientConnection) {
        self.connection = connection
    }

    public func run() async throws {
        try await withGracefulShutdownHandler {
            try await self.connection.run().get()
        } onGracefulShutdown: {
            // Synchronous handler: signal via the raw channel; the running
            // loop observes the close, fails pending calls, and returns.
            self.connection.channel.channel.close(promise: nil)
        }
    }
}
