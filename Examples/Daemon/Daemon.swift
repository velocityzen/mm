import FPService
import Logging
import MMExampleAPI
import MMSchema
import MMServer

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// A minimal but complete matter-in-motion daemon: entities with ACLs, a
/// router built from the shared `Journal` namespace, correlated streaming for
/// `journal.follow` (server → client) and `journal.import` (client → server),
/// and lifecycle owned by fp-swift-service: the server is a bracket, and the
/// first SIGTERM or SIGINT drains it gracefully and removes the socket; a
/// second one cancels the drain.
///
/// Run it, then talk to it with `swift run mm-example-client`:
///
/// ```
/// swift run mm-example-daemon [socket-path]      # default /tmp/mm-example.sock
/// ```
@main
struct ExampleDaemon {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger: Logger = {
            var logger = Logger(label: "mm.example.daemon")
            logger.logLevel = .info
            return logger
        }()

        let socketPath = CommandLine.arguments.dropFirst().first ?? "/tmp/mm-example.sock"

        // Declaration-first: the daemon holds ITSELF to the declared contract
        // (`journalContract`, JournalAPI.swift) before accepting a connection.
        // The client verifies the same contract on its side; here the server
        // proves the Codable types its handlers use actually match it — now
        // over the stream methods too (request/response AND stream element
        // shapes) — so a drift is a boot-time failure rather than a wire
        // surprise a client discovers later. (`For(Journal.self)` below is
        // the other half — it cross-checks that every declared method has a
        // handler.)
        switch journalContract.verify(against: Journal.self) {
            case .failure(let error):
                logger.critical("schema probe failed", metadata: ["error": "\(error)"])
                return
            case .success(let breaks) where !breaks.isEmpty:
                for line in breaks {
                    logger.critical("contract violation", metadata: ["detail": "\(line)"])
                }
                return
            case .success:
                logger.info("contract verified", metadata: ["namespace": "journal"])
        }

        let uid = getuid()
        let gid = getgid()
        let store = JournalStore()

        // The whole server, declaratively: configuration, authorization,
        // logging, and the handlers.
        //
        // The ACL table is the entity tree itself: children take their path
        // relative to the parent (`"notes"` under `"journal"` is
        // `journal.notes`), inherit the parent's owner/group unless
        // overridden, and default their mode to 0o750 (the creation default).
        // The example keys ownership to the uid/gid this daemon runs as, so
        // the local user's client is the "owner"; `journal.system` is
        // root-owned 0o700 — everyone else is denied, including via the
        // first-matching-class-wins rule. A dynamic authority (SQLite etc.)
        // would pass a provider instance instead: `ACLProvider(provider)`.
        //
        // `For(Journal.self)` both groups the routes and turns on the startup
        // cross-check — a Journal method without a handler in the block is a
        // daemon-startup precondition failure, never a runtime unknown-method
        // surprise. The handlers themselves live in JournalHandlers.swift as
        // a reusable group; the builtins (server.schema, server.entity) register
        // automatically.
        let service = MMService {
            Configuration(endpoint: .unix(path: socketPath))
            ACLProvider {
                Entity("journal", owner: uid, group: gid, mode: 0o750) {
                    Entity("notes")
                    Entity("system", owner: 0, group: 0, mode: 0o700)
                }
                // The builtins' method-name prefixes: granting r-x here makes
                // server.schema and server.entity visible in filtered discovery
                // (discovery lists a method only when the peer can traverse
                // its name-prefix entity — no record means fail-closed, so
                // without these the builtins stay callable but undiscoverable).
                Entity("server", owner: uid, group: gid, mode: 0o550)
            }
            Log(logger)
            For(Journal.self) {
                JournalHandlers(store: store)
            }
        }

        logger.info(
            "starting example daemon",
            metadata: ["socket": "\(socketPath)", "owner-uid": "\(uid)"]
        )

        // `service` is the server as a bracket: acquire binds and starts
        // accepting, dispose drains and removes the socket. A daemon with
        // more resources composes them into one bracket (`BracketAsyncDo`):
        // they start in order once the socket listens, and stop in reverse.
        // The bracket's resource is the bound addresses; the default body
        // below just waits for a shutdown signal.
        let daemon = Service(
            service,
            shutdownSignals: [SIGTERM, SIGINT],
            shutdownTimeout: .seconds(30)
        )

        switch await daemon() {
            case .success(let outcome):
                logger.info("example daemon stopped", metadata: ["outcome": "\(outcome)"])
            case .failure(let error):
                logger.critical("example daemon failed", metadata: ["error": "\(error)"])
                throw error
        }
    }
}
