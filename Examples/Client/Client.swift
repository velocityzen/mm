import Logging
import MMClient
import MMExampleAPI
import MMSchema

/// A CLI walking the full client story against the example daemon — one
/// pattern per function, so each reads as a self-contained recipe:
///
/// - ``verify(_:)`` — automatic schema verification (resolved by the connection)
/// - ``discover(_:)`` — discovery, the contract check, and the schema diff
/// - ``append(_:to:)`` / ``read(_:from:)`` — unary calls
/// - ``follow(_:journal:)`` — a server → client stream (drain, STOP, terminal)
/// - ``importLines(_:into:)`` — a client → server stream (send, END, terminal)
/// - ``sync(_:into:)`` — duplex: both directions streaming on one call
/// - ``appendDenied(_:to:)`` — an authorization denial
///
/// Every step is multiplexed over ONE bracketed connection.
///
/// Start `swift run mm-example-daemon` first, then:
///
/// ```
/// swift run mm-example-client [socket-path]      # default /tmp/mm-example.sock
/// ```
///
/// (`print` here is the program's output — this is a CLI. Diagnostics still go
/// through swift-log to stderr.)
@main
struct ExampleClient {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        var logger = Logger(label: "mm.example.client")
        logger.logLevel = .warning

        let socketPath = CommandLine.arguments.dropFirst().first ?? "/tmp/mm-example.sock"
        let notes = try EntityName.parse("journal.notes").get()
        let system = try EntityName.parse("journal.system").get()

        // The whole lifecycle is one bracket: acquire connects AND starts the
        // inbound loop, dispose closes AND joins it — one connection, every
        // pattern below multiplexed over it. The schema expectation is
        // contracts, never a typed-in fingerprint: this client ships with the
        // daemon, so it declares the complete composition and the connection
        // verifies itself automatically.
        let outcome = await MMClientConnection.with(
            .unix(path: socketPath),
            configuration: MMClientConfiguration(
                schema: .complete([Journal.contract])
            ),
            logger: logger
        ) { connection in
            let hello = connection.server
            print("connected to \(socketPath)")
            print("  protocol version: \(hello.protocolVersion)")
            print("  server schema fingerprint: 0x\(String(hello.fingerprint, radix: 16))")

            await verify(connection)
            await discover(connection)
            await append(connection, to: notes)
            await follow(connection, journal: notes)
            await importLines(connection, into: notes)
            await sync(connection, into: notes)
            await read(connection, from: notes)
            await appendDenied(connection, to: system)
            // No close, no join: the bracket's dispose does both on the way
            // out — that is the acquire/release contract.
        }

        if case .failure(let error) = outcome {
            print("cannot connect to \(socketPath): \(error)")
            print("start the daemon first: swift run mm-example-daemon")
            return
        }
        print("\nclosed cleanly")
    }

    // MARK: - Schema verification

    /// **Pattern: automatic schema verification.** The connection resolves
    /// this itself — `.ok` straight from the hello when the complete
    /// expectation matches, a scoped discovery diff otherwise. `verify()` is
    /// replay-once: awaitable any number of times, resolved exactly once.
    /// Informational, never a disconnect.
    private static func verify(_ connection: MMClientConnection) async {
        switch await connection.verify() {
            case .success(.ok):
                print("  schema: ok — the hello proves this build's exact composition")
            case .success(.partial):
                print("  schema: composition changed, but every contract we use is in sync")
            case .success(.difference(let differences)):
                print("  schema: DIFFERS — \(differences.count) namespace(s) drifted")
            case .failure(let reason):
                print("  schema: verification unavailable (\(reason))")
        }
    }

    // MARK: - Discovery

    /// **Pattern: discovery.** What can THIS peer (this uid, over this
    /// socket) actually reach? The list is filtered by traversal rights; the
    /// fingerprint covers the server's complete method set. The local
    /// contract is then held to it twice: a macro-fidelity check of the
    /// generated Codable types, and a `SchemaDifference` diff against what
    /// the server actually serves.
    private static func discover(_ connection: MMClientConnection) async {
        switch await connection.discoverSchema() {
            case .failure(let error):
                print("discovery failed: \(error)")
            case .success(let schema):
                print("\ndiscovered \(schema.methods.count) reachable methods:")
                for method in schema.methods {
                    var line =
                        "  \(method.name)  (needs \(method.access) on its target)"
                    // Descriptions ride the discovery response — the contract
                    // documents itself to peers.
                    if let text = method.description { line += " — \(text)" }
                    print(line)
                }
                if !schema.types.isEmpty {
                    print("named types reachable through those methods:")
                    for type in schema.types {
                        var line = "  \(type.name)"
                        if case .enumeration(let cases) = type.schema {
                            line += " (enum: \(cases.map(\.name).joined(separator: ", ")))"
                        }
                        if let text = type.description { line += " — \(text)" }
                        print(line)
                    }
                }
                // The declared contract (see JournalAPI.swift) is this build's
                // side of the comparison: first verify the Codable types honor
                // it — unary calls AND stream element shapes — then diff it
                // against what the server actually serves.
                switch journalContract.verify(against: Journal.self) {
                    case .success(let contractBreaks) where contractBreaks.isEmpty:
                        print("contract check: Codable types match the declared schema")
                    case .success(let contractBreaks):
                        print("contract check FAILED:")
                        for line in contractBreaks { print("  \(line)") }
                    case .failure(let error):
                        print("contract probe failed: \(error)")
                }
                // SchemaDifference renders itself ("in sync", or the non-empty
                // buckets) — log it directly, no bucket iteration needed. The
                // declaration form diffs signatures AND named types.
                let difference = SchemaDifference(local: journalContract, remote: schema)
                print("schema difference vs this build: \(difference)")
        }
    }

    // MARK: - Unary calls

    /// **Pattern: a unary call.** One request, one typed response —
    /// `Result<AppendResponse, MMCallError>`, no throws on the data path.
    /// The target entity (`on:`) rides the open envelope, never the payload;
    /// the generated `LineMeta`/`Priority` types come straight from the
    /// `Type`/`Enum` declarations in the contract.
    private static func append(_ connection: MMClientConnection, to journal: EntityName) async {
        print("\nappend to \(journal.rawValue) (unary call):")
        switch await connection.call(
            Journal.append,
            on: journal,
            AppendRequest(
                line: "hello from the example client",
                meta: LineMeta(author: "example-client", priority: .urgent)
            )
        ) {
            case .success(let response):
                print("  ok — journal now has \(response.count) line(s)")
            case .failure(let error):
                print("  failed: \(error)")
        }
    }

    /// **Pattern: a unary call, reading back.** Everything the walkthrough
    /// appended: the unary append, the follow producer's two, the import's
    /// three, and the sync's two.
    private static func read(_ connection: MMClientConnection, from journal: EntityName) async {
        switch await connection.call(Journal.read, on: journal, ReadRequest()) {
            case .success(let response):
                print("\nread \(journal.rawValue): \(response.lines)")
            case .failure(let error):
                print("\nread failed: \(error)")
        }
    }

    // MARK: - Server → client streaming

    /// **Pattern: a streaming response.** Two roles, two scopes — as in real
    /// life, where the follower is usually another process entirely:
    ///
    /// - the **consumer** only listens: it iterates the handle's element
    ///   sequence (iterating grants credit all the way back to the socket)
    ///   and decides for itself when to STOP — here, once it has seen the
    ///   line it was waiting for;
    /// - the **producer** only writes: plain unary appends that know nothing
    ///   about any follower.
    ///
    /// `withStream(_:each:_:)` packages the split: `each` runs in a
    /// structured sibling per the head-of-line rule, the trailing closure is
    /// the main flow, and the join is built in — it returns only after the
    /// sequence ended, so the terminal read below is ordered after every
    /// delivered line. STOP is graceful and advisory; the daemon's handler
    /// observes it promptly even on a quiet journal (it watches
    /// `sink.stopRequested()`), which is what ends the sequence with no
    /// further coordination.
    private static func follow(_ connection: MMClientConnection, journal: EntityName) async {
        print("\nfollow \(journal.rawValue) (server -> client stream):")
        let follow = await connection.call(Journal.follow, on: journal, FollowRequest())

        await withStream(follow, each: { event in
            // The consumer, stopping on its own criterion — here, once the
            // line it was waiting for arrives.
            print("  follow delivered: \"\(event.line)\" (count \(event.count))")
            if event.line == "second change" {
                await follow.stop()
            }
        }) {
            // The producer. (In-process caveat: the follow open is
            // fire-and-forget by protocol design, so in principle an append
            // can race the handler's follower registration; each append is a
            // full round-trip while registration is the handler's first
            // statement, so in practice the follower is long registered. A
            // real follower is a separate process that neither knows nor
            // cares what was appended before it subscribed.)
            print("append twice to \(journal.rawValue) (each drives a change to the follower):")
            for line in ["first change", "second change"] {
                if case .failure(let error) = await connection.call(
                    Journal.append, on: journal, AppendRequest(line: line, meta: nil)
                ) {
                    print("  append failed: \(error)")
                }
            }
        }
        switch await follow.result() {
            case .success(let summary):
                print("follow terminal: delivered \(summary.delivered) change(s) before STOP")
            case .failure(let error):
                print("follow ended with error: \(error)")
        }
    }

    // MARK: - Client → server streaming

    /// **Pattern: a streaming request.** Send elements through the
    /// credit-gated writer (`send` surfaces `.peerStopped` / `.callEnded` as
    /// typed outcomes, not errors), `finish()` to END the request direction,
    /// then await the terminal.
    private static func importLines(
        _ connection: MMClientConnection, into journal: EntityName
    ) async {
        print("\nimport into \(journal.rawValue) (client -> server stream):")
        let importCall = await connection.call(Journal.import, on: journal, ImportRequest())
        for line in ["imported line one", "imported line two", "imported line three"] {
            switch await importCall.send(ImportLine(line: line)) {
                case .sent:
                    continue
                case .peerStopped:
                    print("  server asked us to stop early")
                case .callEnded, .connectionClosed:
                    print("  import call ended before we finished sending")
            }
        }
        await importCall.finish()
        switch await importCall.result() {
            case .success(let summary):
                print(
                    "  import terminal: imported \(summary.imported), journal total \(summary.total)"
                )
            case .failure(let error):
                print("  import ended with error: \(error)")
        }
    }

    // MARK: - Duplex streaming

    /// **Pattern: duplex streaming.** One call, both directions live: the
    /// `outbound` half streams request elements up while the `inbound` half
    /// streams responses back, each with its own credit window, sharing one
    /// terminal. The same `withStream(_:each:_:)` shape as `follow` —
    /// consume inbound in the sibling, drive outbound in the body (send,
    /// then END) — and because it returns only after the inbound sequence
    /// ended, the terminal read below is ordered after every echoed line.
    private static func sync(_ connection: MMClientConnection, into journal: EntityName) async {
        print("\nsync into \(journal.rawValue) (duplex stream: lines up, changes back):")
        let sync = await connection.call(Journal.sync, on: journal, SyncRequest())
        await withStream(sync.inbound, each: { event in
            print("  change echoed back: \"\(event.line)\" (count \(event.count))")
        }) {
            for line in ["synced line one", "synced line two"] {
                switch await sync.outbound.send(SyncLine(line: line)) {
                    case .sent:
                        continue
                    case .peerStopped:
                        print("  server asked us to stop early")
                    case .callEnded, .connectionClosed:
                        print("  sync call ended before we finished sending")
                }
            }
            await sync.outbound.finish()
        }
        switch await sync.inbound.result() {
            case .success(let summary):
                print("  sync terminal: synced \(summary.synced), journal total \(summary.total)")
            case .failure(let error):
                print("  sync ended with error: \(error)")
        }
    }

    // MARK: - Authorization

    /// **Pattern: an authorization denial.** journal.system is root-owned
    /// 0o700. This process classifies as "other" (first matching class wins)
    /// and other has no bits — the router denies before ever decoding the
    /// full request payload: the entity is call metadata, not payload.
    private static func appendDenied(
        _ connection: MMClientConnection, to journal: EntityName
    ) async {
        print("\nappend to \(journal.rawValue) (root-owned, mode 0o700):")
        switch await connection.call(
            Journal.append,
            on: journal,
            AppendRequest(line: "should never land", meta: nil)
        ) {
            case .failure(.denied):
                print("  denied — exactly as the ACL intends")
            case .success:
                print(
                    "  UNEXPECTED success (is this daemon running as your uid with a modified ACL table?)"
                )
            case .failure(let other):
                print("  failed differently: \(other)")
        }
    }
}
