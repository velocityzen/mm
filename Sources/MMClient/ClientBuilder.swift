import FPBracket
import Logging
import MMSchema
import MMWire
import NIOCore
import NIOPosix

/// The fully declarative client form: the endpoint and tunables, the schema
/// this build was compiled against, and logging, in one builder —
///
/// ```swift
/// let journal = MMClient {
///     Configuration(endpoint: .unix(path: socketPath), maxInFlightCalls: 32)
///     Schema(.complete([Journal.contract]))
///     Log(label: "mm.example.client")
/// }
/// ```
///
/// Exactly one `Configuration` is required; `Schema` and `Log` are optional
/// (at most one each). A schema declared both by `Schema` and inside a
/// prebuilt ``MMClientConfiguration`` is declared twice. Violations are
/// programmer error and fail when the value is built, like the server's.
public struct ClientPart {
    enum Kind {
        case configuration(endpoint: MMEndpoint, MMClientConfiguration)
        case schema(MMClientSchema)
        case logger(Logger)
    }

    let kind: Kind
}

// MARK: - Elements

/// The client's endpoint and tunables, as a builder element. Pass a prebuilt
/// ``MMClientConfiguration`` or use the mirrored parameter form.
public func Configuration(
    _ configuration: MMClientConfiguration,
    endpoint: MMEndpoint
) -> ClientPart {
    ClientPart(kind: .configuration(endpoint: endpoint, configuration))
}

/// Mirrors ``MMClientConfiguration/init(maxFrameLength:capabilities:schema:maxInFlightCalls:connectTimeout:helloTimeout:idleTimeout:)``,
/// with the endpoint first and the schema left to ``Schema(_:)``.
public func Configuration(
    endpoint: MMEndpoint,
    maxFrameLength: UInt32 = MMWireInfo.defaultMaxFrameLength,
    capabilities: UInt32 = 0,
    maxInFlightCalls: Int = 16,
    connectTimeout: TimeAmount? = nil,
    helloTimeout: TimeAmount? = .seconds(10),
    idleTimeout: TimeAmount? = nil
) -> ClientPart {
    ClientPart(
        kind: .configuration(
            endpoint: endpoint,
            MMClientConfiguration(
                maxFrameLength: maxFrameLength,
                capabilities: capabilities,
                maxInFlightCalls: maxInFlightCalls,
                connectTimeout: connectTimeout,
                helloTimeout: helloTimeout,
                idleTimeout: idleTimeout
            )))
}

/// The schema this build was compiled against:
/// ``MMClientSchema/complete(_:sharedTypes:)`` when the client knows the
/// server's whole composition, ``MMClientSchema/partial(_:sharedTypes:)``
/// for a slice. Optional; with it the connection verifies itself (see
/// ``MMClientConnection/verify()``).
public func Schema(_ schema: MMClientSchema) -> ClientPart {
    ClientPart(kind: .schema(schema))
}

/// The client's logger. Optional; defaults to `Logger(label: "mm.client")`.
public func Log(_ logger: Logger) -> ClientPart {
    ClientPart(kind: .logger(logger))
}

/// Label-and-level form: `Log(label: "mm.example.client", level: .debug)`.
public func Log(label: String = "mm.client", level: Logger.Level = .info) -> ClientPart {
    var logger = Logger(label: label)
    logger.logLevel = level
    return ClientPart(kind: .logger(logger))
}

// MARK: - Builder + assembly

@resultBuilder
public enum ClientBuilder: MMListBuilding {
    public typealias Element = ClientPart

    public static func buildExpression(_ part: ClientPart) -> [ClientPart] { [part] }
}

extension BracketAsync where R == MMClientConnection, E == MMClientError {
    /// Declares a client from declarative parts. See ``ClientPart`` for the
    /// element inventory and the exactly-once rules.
    public init(
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        @ClientBuilder _ content: sending () -> [ClientPart]
    ) {
        var declared: (endpoint: MMEndpoint, configuration: MMClientConfiguration)?
        var schema: MMClientSchema?
        var logger: Logger?
        for part in content() {
            switch part.kind {
                case .configuration(let endpoint, let configuration):
                    precondition(declared == nil, "MMClient declares Configuration twice")
                    declared = (endpoint, configuration)
                case .schema(let value):
                    precondition(schema == nil, "MMClient declares Schema twice")
                    schema = value
                case .logger(let value):
                    precondition(logger == nil, "MMClient declares Log twice")
                    logger = value
            }
        }
        guard var declared else {
            preconditionFailure(
                "MMClient declares no Configuration — the endpoint is not defaultable")
        }
        if let schema {
            precondition(
                declared.configuration.schema == nil,
                "MMClient declares its schema twice: in Schema and in Configuration"
            )
            declared.configuration.schema = schema
        }
        self.init(
            endpoint: declared.endpoint,
            configuration: declared.configuration,
            eventLoopGroup: eventLoopGroup,
            logger: logger ?? Logger(label: "mm.client")
        )
    }
}
