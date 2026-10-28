import FPBracket
import Logging
import MMWire
import NIOCore
import NIOPosix

/// The client, as a scoped resource (fp-swift-bracket's `BracketAsync`):
/// acquire connects, exchanges hellos, and starts the inbound loop; dispose
/// closes the connection and joins the loop. The resource is the live
/// ``MMClientConnection``.
///
/// Declare it with the builder, then call it like any bracket — the body is
/// where the calls go:
///
/// ```swift
/// let journal = MMClient {
///     Configuration(endpoint: .unix(path: socketPath))
///     Schema(.complete([Journal.contract]))
/// }
/// let outcome = await journal { connection in
///     if case .failure(let error) = await connection.call(Journal.append, on: notes, request) {
///         logger.warning("journal.append failed: \(error)")  // the connection is still up
///     }
///     return .success(())
/// }
/// ```
///
/// Daemons compose it with their other resources and run the result with
/// their lifecycle (fp-swift-service, for example):
///
/// ```swift
/// let withDaemon = BracketAsyncDo<DaemonError>()
///     .bind { withStore().mapError(DaemonError.store) }
///     .bind { _ in journal.mapError(DaemonError.client) }
/// ```
///
/// The bracket returns `.failure` when connect failed — the body never ran —
/// or when the connection did not survive the scope (a transport error or
/// protocol violation while the body ran). A clean EOF or the bracket's own
/// close releases successfully. Per-call failures stay in the body's value.
/// Dispose does not drain: in-flight calls fail with `.connectionClosed`, so
/// a body that wants its responses awaits them before returning.
///
/// The value is a reusable recipe: each run connects afresh. One connection
/// multiplexes many calls, so run it once per unit of work (a daemon's
/// lifetime, a tool run), never once per call.
public typealias MMClient = BracketAsync<MMClientConnection, MMClientError>

extension BracketAsync where R == MMClientConnection, E == MMClientError {
    /// Declares a client from explicit parameters; the builder form
    /// (``ClientPart``) declares the same client.
    ///
    /// - Parameters:
    ///   - endpoint: The server's socket path or TCP address.
    ///   - configuration: Tunables and the expected schema.
    ///   - eventLoopGroup: NIO event loops; defaults to the process singleton.
    ///   - logger: Base logger; the connection id rides in metadata.
    public init(
        endpoint: MMEndpoint,
        configuration: MMClientConfiguration = MMClientConfiguration(),
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger = Logger(label: "mm.client")
    ) {
        self = MMClientConnection.open(
            endpoint,
            configuration: configuration,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
    }
}
