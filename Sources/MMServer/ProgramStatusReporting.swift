import NIOCore
import ProgramStatus

/// Turns on [Program Status Protocol](https://github.com/velocityzen/ProgramStatus)
/// reporting (OSC 7501) for the server, as `app`: a stable identifier of 1 to
/// 32 characters of `[A-Za-z0-9_.+-]`, such as the daemon's name. Optional, at
/// most once.
///
/// The server's lifecycle becomes a record on the controlling terminal, so a
/// daemon running in a terminal tab shows its state there, and the terminal
/// can notify when it fails:
///
/// - `idle` "Listening on /tmp/journal.sock" once every endpoint is bound;
/// - `error` with the reason when an endpoint cannot be bound;
/// - `working` "Draining connections" when the drain starts;
/// - `idle` "Stopped" once it has drained, or `error` when an accept loop
///   failed.
///
/// A daemon started without a terminal (launchd, systemd, CI) has nothing to
/// report to, and reports nothing.
///
/// ```swift
/// MMService {
///     Configuration(endpoint: .unix(path: socketPath))
///     ACLProvider(provider)
///     ProgramStatusReporting(app: "journald")
///     For(Journal.self) { JournalHandlers(store: store) }
/// }
/// ```
public func ProgramStatusReporting(app: String) -> ServerPart {
    ProgramStatusReporting(ProgramStatusReporter(app: app))
}

/// ``ProgramStatusReporting(app:)`` with a reporter of your own, to write
/// somewhere other than the controlling terminal or to end sequences with BEL.
public func ProgramStatusReporting(_ reporter: ProgramStatusReporter) -> ServerPart {
    ServerPart(kind: .programStatus(ServerProgramStatus(reporter: reporter)))
}

/// Where the server's lifecycle reports go, and what they say.
package struct ServerProgramStatus: Sendable {
    let send: @Sendable (StatusReport) -> Void

    init(reporter: ProgramStatusReporter) {
        let reporter = Self.validated(reporter)
        self.init(send: { reporter.send($0) })
    }

    /// Reports to `send`; tests collect the reports here.
    package init(send: @escaping @Sendable (StatusReport) -> Void) {
        self.send = send
    }

    /// Sends one report with its message on one line: a path or an error
    /// description may hold a control character the protocol refuses.
    func report(_ report: StatusReport) {
        self.send(
            StatusReport(
                state: report.state,
                id: report.id,
                app: report.app,
                title: report.title,
                message: report.message.map(StatusText.singleLine)
            )
        )
    }

    /// The reporter, when its `app` is one the protocol accepts. Every report
    /// carries it, so an invalid one would silently drop them all: it stops
    /// the daemon at startup instead.
    static func validated(_ reporter: ProgramStatusReporter) -> ProgramStatusReporter {
        if case .failure(let error) = StatusEncoder.encode(.idle(app: reporter.app)) {
            preconditionFailure("ProgramStatusReporting: \(error.localizedDescription)")
        }
        return reporter
    }
}

extension ServerProgramStatus {
    /// Every endpoint is bound and accepting.
    static func listening(on endpoints: [MMEndpoint], boundAt addresses: [SocketAddress])
        -> StatusReport
    {
        let described = zip(endpoints, addresses).map { endpoint, address in
            switch endpoint {
                case .unix(let path):
                    path
                // An ephemeral port (0) is reported as the one bound.
                case .tcp(let host, let port):
                    "\(host):\(address.port ?? port)"
                // Refused at bind; never reaches a started server.
                case .fd(let descriptor):
                    "fd \(descriptor)"
            }
        }
        guard !described.isEmpty else {
            return .idle("Serving adopted sockets")
        }
        return .idle("Listening on \(described.joined(separator: ", "))")
    }

    static let draining = StatusReport.working("Draining connections")

    static let stopped = StatusReport.idle("Stopped")

    static func failed(_ error: MMServiceError) -> StatusReport {
        switch error {
            case .socketPathInUse(let path):
                .error("Another server is listening on \(path)")
            case .socketPathOccupied(let path):
                .error("Something that is not a socket is at \(path)")
            case .invalidSocketPath(let path):
                .error("Invalid socket path \(path)")
            case .io(let description):
                .error(description)
        }
    }
}
