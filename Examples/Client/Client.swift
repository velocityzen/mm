import Logging
import MMClient
import MMExampleAPI
import MMSchema
import MMWire
import Synchronization

/// A CLI walking the full client story against the example daemon: connect and
/// negotiate the hello, discover the schema and diff it against this build,
/// follow a journal over a correlated server → client stream, make typed unary
/// calls, import lines over a client → server stream, and demonstrate an
/// authorization denial — then close cleanly.
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

        // Connect: transport bootstrap + hello exchange. The connection is
        // inert until run() consumes the inbound stream, so the host owns the
        // loop as a structured child — never a free-floating Task.
        // The schema expectation is contracts, never a typed-in fingerprint:
        // this client ships with the daemon, so it declares the complete
        // composition and the connection verifies itself automatically.
        let connection: MMClientConnection
        switch await MMClientConnection.connect(
            to: .unix(path: socketPath),
            configuration: MMClientConfiguration(
                schema: .complete([Journal.contract])
            ),
            logger: logger
        ) {
            case .failure(let error):
                print("cannot connect to \(socketPath): \(error)")
                print("start the daemon first: swift run mm-example-daemon")
                return
            case .success(let connected):
                connection = connected
        }

        let hello = connection.server
        print("connected to \(socketPath)")
        print("  protocol version: \(hello.protocolVersion)")
        print("  server schema fingerprint: 0x\(String(hello.fingerprint, radix: 16))")

        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { _ = await connection.run() }

            // 0. Automatic schema verification: resolved by the connection
            // itself — .ok straight from the hello when the complete
            // expectation matches, a scoped diff otherwise. Informational,
            // never a disconnect.
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

            // 1. Discovery: what can THIS peer (this uid, over this socket)
            // actually reach? The list is filtered by traversal rights; the
            // fingerprint covers the server's complete method set.
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
                    let contractBreaks = try journalContract.verify(against: Journal.self).get()
                    if contractBreaks.isEmpty {
                        print("contract check: Codable types match the declared schema")
                    } else {
                        print("contract check FAILED:")
                        for line in contractBreaks { print("  \(line)") }
                    }
                    // SchemaDifference renders itself ("in sync", or the non-empty
                    // buckets) — log it directly, no bucket iteration needed. The
                    // declaration form diffs signatures AND named types.
                    let difference = SchemaDifference(local: journalContract, remote: schema)
                    print("schema difference vs this build: \(difference)")
            }

            // 2. Follow journal.notes over a correlated server → client stream,
            // then trigger a change with a unary append. A background task
            // drains the follow element sequence (its consumption grants credit
            // all the way to the socket); iterating it from its own task keeps
            // the append below off the same backpressured path. The follow
            // handle's terminal is a FollowSummary the daemon returns once we
            // STOP.
            print("\nfollow journal.notes (server -> client stream):")
            let follow = await connection.call(Journal.follow, on: notes, FollowRequest())

            // A buffered stream stands in for a hand-rolled latch: the
            // drainer yields every change; the main flow takes the first
            // (`.bufferingOldest(1)` = first value wins), and `finish()`
            // tells a parked waiter no value is coming.
            let (changes, changesContinuation) = AsyncStream<ChangeEvent>.makeStream(
                bufferingPolicy: .bufferingOldest(1)
            )
            
            tasks.addTask {
                for await event in follow {
                    changesContinuation.yield(event)
                }
                changesContinuation.finish()
            }

            print("append to journal.notes (drives a change into the follow stream):")
            switch await connection.call(
                Journal.append,
                on: notes,
                AppendRequest(
                    line: "hello from the example client",
                    // The generated LineMeta/Priority types come straight from
                    // the Enum/Type declarations in the contract.
                    meta: LineMeta(author: "example-client", priority: .urgent)
                )
            ) {
                case .success(let response):
                    print("  ok — journal now has \(response.count) line(s)")
                case .failure(let error):
                    print("  failed: \(error)")
            }

            // Bounded wait, not an unbounded park: the follow open carries no
            // server acknowledgment (fire-and-forget by protocol design), so
            // the append above can race the follow handler's registration on
            // the server — lose that race and this event was broadcast to
            // nobody. The deadline turns a rare lost race (or a failed
            // append) into an honest message instead of a hung process.
            if let event = await firstValue(of: changes, upTo: .seconds(2)) {
                print(
                    "  follow delivered a change: \(event.entity) -> \"\(event.line)\" (count \(event.count))"
                )
            } else {
                print("  no change delivered (append raced the follow registration, or failed)")
            }

            // Graceful STOP: ask the server to finish its response stream. STOP
            // is advisory — the call still runs to its terminal (which carries
            // the delivered count), and it is observed by the follow handler on
            // its next send. Frames are ordered on the connection, so this STOP
            // is processed server-side before the import below; the change
            // events the import drives therefore find the follower already
            // stopped and are not delivered — the terminal reports one change,
            // the one delivered before STOP.
            await follow.stop()

            // 3. Import a batch over a client → server stream: send a few lines
            // through the credit-gated writer, finish() to send END, then await
            // the ImportSummary terminal. These appends also broadcast to the
            // (now-stopped) follower, which is what wakes the follow handler to
            // observe the STOP and wind down.
            print("\nimport into journal.notes (client -> server stream):")
            let importCall = await connection.call(Journal.import, on: notes, ImportRequest())
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

            // The follow terminal, now that the import's appends have woken the
            // handler to observe the STOP.
            switch await follow.result() {
                case .success(let summary):
                    print("follow terminal: delivered \(summary.delivered) change(s) before STOP")
                case .failure(let error):
                    print("follow ended with error: \(error)")
            }

            // 4. Read back everything that landed (the first append plus the
            // three imported lines).
            switch await connection.call(Journal.read, on: notes, ReadRequest()) {
                case .success(let response):
                    print("\nread journal.notes: \(response.lines)")
                case .failure(let error):
                    print("read failed: \(error)")
            }

            // 5. Authorization: journal.system is root-owned 0o700. This
            // process classifies as "other" (first matching class wins) and
            // other has no bits — the router denies before ever decoding the
            // full request payload.
            print("\nappend to journal.system (root-owned, mode 0o700):")
            switch await connection.call(
                Journal.append,
                on: system,
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

            await connection.close()
            try await tasks.waitForAll()
        }
        print("\nclosed cleanly")
    }
}

/// The first element of a stream, bounded by a deadline — `nil` when the
/// stream ends empty, the deadline passes, or the surrounding task is
/// cancelled. The deadline matters here for the same reason it always does in
/// production: the value may *silently never come* (see the call site), and a
/// bounded wait with an honest miss beats an unbounded park.
private func firstValue<Value: Sendable>(
    of stream: AsyncStream<Value>, upTo duration: Duration
) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask { await stream.first(where: { _ in true }) }
        group.addTask {
            try? await Task.sleep(for: duration)
            return nil
        }
        // Whichever finishes first wins; cancelling the group promptly ends
        // the other (AsyncStream iteration finishes on cancellation).
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
