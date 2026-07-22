import ArgumentParser
import MMClient
import MMWire
import NIOCore

/// How rendered results reach stdout. See ``MMCLIOutput``.
public enum OutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
    /// Compact JSON, one value per line. The default.
    case json
    /// Pretty-printed JSON for humans.
    case jsonPretty = "json-pretty"
    /// Reserved for a future raw renderer; currently identical to ``json``
    /// (documented on ``MMCLIOutput/emit(_:format:)``).
    case raw
    /// Human-readable, resolved per value type: a ``Format(_:_:)``
    /// declaration, else the type's own `CustomStringConvertible`
    /// conformance, else compact JSON. Stream elements and terminals alike.
    case text
}

/// The shared connection options every generated command embeds via
/// `@OptionGroup`: where the daemon listens, connection tunables, and the
/// output format.
///
/// Exactly one of `--socket` / `--tcp` must be given — unless the tool
/// declared a default endpoint (``Endpoint(_:)`` in its ``MMCLI`` block), in
/// which case both may be omitted and the default applies (explicit flags
/// always win).
/// ``validate()`` enforces that plus the shape of every parsed value, so the
/// computed ``endpoint`` and ``clientConfiguration`` are only read after a
/// successful parse.
public struct MMCLIOptions: ParsableArguments, Sendable {
    @Option(help: ArgumentHelp("Unix domain socket path of the daemon.", valueName: "path"))
    public var socket: String?

    @Option(help: ArgumentHelp("TCP endpoint of the daemon.", valueName: "host:port"))
    public var tcp: String?

    @Option(help: ArgumentHelp("Transport connect timeout in seconds.", valueName: "seconds"))
    public var connectTimeout: Double?

    @Option(help: ArgumentHelp("Hello-exchange timeout in seconds.", valueName: "seconds"))
    public var helloTimeout: Double?

    @Option(
        name: .customLong("output"),
        help: ArgumentHelp(
            "Output format for results written to stdout (default: json, or the tool's bound default)."
        )
    )
    var outputFlag: OutputFormat?

    /// The effective output format: the explicit `--output` flag, else the
    /// tool's bound default (``MMCLIDefaults/output``), else `json`.
    public var output: OutputFormat {
        self.outputFlag ?? MMCLIDefaults.current.output ?? .json
    }

    @Flag(
        name: .customLong("no-verify"),
        help: "Skip automatic schema verification for this invocation."
    )
    public var noVerify: Bool = false

    /// The long option names this type declares — update in lockstep with the
    /// property wrappers above. `SchemaContractMacro.reservedLongOptionNames`
    /// restates this list (the macro cannot import MMCLI);
    /// ReservedOptionsPinTests keeps the two in agreement.
    public static let declaredLongOptionNames: Set<String> = [
        "socket",
        "tcp",
        "connect-timeout",
        "hello-timeout",
        "output",
        "no-verify",
    ]

    public init() {}

    public mutating func validate() throws {
        switch (self.socket, self.tcp) {
            case (nil, nil):
                if MMCLIDefaults.current.endpoint == nil {
                    throw ValidationError("one of --socket or --tcp is required")
                }
            case (.some, .some):
                throw ValidationError("--socket and --tcp are mutually exclusive; give one")
            case (.some(let path), nil):
                if path.isEmpty {
                    throw ValidationError("--socket path must not be empty")
                }
            case (nil, .some(let address)):
                if Self.parseTCP(address) == nil {
                    throw ValidationError(
                        "--tcp expects <host:port> with a non-empty host and a port in 1...65535, got '\(address)'"
                    )
                }
        }
        if let seconds = self.connectTimeout, Self.timeAmount(fromSeconds: seconds) == nil {
            throw ValidationError("--connect-timeout must be a positive number of seconds")
        }
        if let seconds = self.helloTimeout, Self.timeAmount(fromSeconds: seconds) == nil {
            throw ValidationError("--hello-timeout must be a positive number of seconds")
        }
    }

    /// The endpoint the options describe. Only meaningful after a successful
    /// parse (`ParsableArguments` runs ``validate()`` as part of parsing);
    /// reading it on unvalidated options is a programmer error.
    public var endpoint: MMEndpoint {
        if let path = self.socket {
            return .unix(path: path)
        }
        if let address = self.tcp, let parsed = Self.parseTCP(address) {
            return .tcp(host: parsed.host, port: Int(parsed.port))
        }
        if let bound = MMCLIDefaults.current.endpoint {
            return bound
        }
        preconditionFailure("MMCLIOptions.endpoint read before validate() passed")
    }

    /// The client configuration the options describe. Unset options keep the
    /// `MMClientConfiguration` defaults (notably the 10-second hello
    /// timeout). Only meaningful after a successful parse, like ``endpoint``.
    public var clientConfiguration: MMClientConfiguration {
        var configuration = MMClientConfiguration()
        if let seconds = self.connectTimeout {
            configuration.connectTimeout = Self.timeAmount(fromSeconds: seconds)
        }
        if let seconds = self.helloTimeout {
            configuration.helloTimeout = Self.timeAmount(fromSeconds: seconds)
        }
        return configuration
    }

    /// Splits `host:port` on the **last** colon: host non-empty, port in
    /// 1...65535. `nil` when the string has neither shape.
    static func parseTCP(_ address: String) -> (host: String, port: UInt16)? {
        guard let lastColon = address.lastIndex(of: ":") else {
            return nil
        }

        let host = String(address[..<lastColon])
        let portText = String(address[address.index(after: lastColon)...])
        guard !host.isEmpty, let port = UInt16(portText), port > 0 else {
            return nil
        }

        return (host: host, port: port)
    }

    /// Converts positive, finite seconds to a monotonic `TimeAmount`; `nil`
    /// for zero, negatives, NaN, infinities, and values whose nanosecond form
    /// would overflow `Int64` (all rejected by ``validate()``).
    static func timeAmount(fromSeconds seconds: Double) -> TimeAmount? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds <= Double(Int64.max) else { return nil }
        return .nanoseconds(Int64(nanoseconds))
    }
}

extension MMEndpoint {
    /// Human form for CLI diagnostics: the socket path, or `host:port`.
    var cliDescription: String {
        switch self {
            case .unix(let path):
                return path
            case .tcp(let host, let port):
                return "\(host):\(port)"
        }
    }
}
