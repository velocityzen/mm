import Logging
import MMSchema
import MMTestSupport
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ServiceLifecycle
import Testing

@testable import MMClient
@testable import MMServer

/// End-to-end tests driving the real `MMService` through the real
/// `MMClientConnection` over a temp-dir unix socket — the typed twin of the
/// raw-frame suite in `ServerIntegrationTests`. The raw suite validates the
/// server against the wire spec with hand-built bytes; this one validates that
/// the two library halves actually compose.
@Suite("MMClient against MMServer over a real temp-dir unix socket")
struct ClientIntegrationTests {
    @Test("the bracket surfaces a connection that did not survive the scope")
    func bracketSurfacesLoopDeath() async throws {
        try await withTempSocketPath { path in
            // A raw misbehaving server: a valid hello, then — upon the
            // client's first frame — one undecodable frame. The client's
            // loop dies of .protocolViolation; dispose must surface it as
            // the bracket's failure. Bound BEFORE the client connects so
            // the connect cannot race the listener.
            let listener = try await ServerBootstrap(
                group: MultiThreadedEventLoopGroup.singleton
            )
            .bind(unixDomainSocketPath: path) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel)
                }
            }
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask {
                    try await listener.executeThenClose { inbound in
                        for try await accepted in inbound {
                            try await accepted.executeThenClose { input, output in
                                var frame = ByteBuffer()
                                var hello = try MMHello(
                                    protocolVersion: 1, schemaFingerprint: 0, capabilities: 0
                                ).encode().get()
                                frame.writeInteger(
                                    UInt32(hello.readableBytes), endianness: .little)
                                frame.writeBuffer(&hello)
                                try await output.write(frame)
                                for try await _ in input {
                                    // Framed 0x81 (a fixmap header) is not an
                                    // envelope: decode fails connection-fatally.
                                    var garbage = ByteBuffer()
                                    garbage.writeInteger(UInt32(1), endianness: .little)
                                    garbage.writeInteger(UInt8(0x81))
                                    try await output.write(garbage)
                                    break
                                }
                            }
                            return
                        }
                    }
                }
                let outcome = try await withDeadline {
                    await MMClientConnection.with(.unix(path: path)) { connection in
                        // The call can only end via the death (the raw server
                        // never dispatches); its failure stays in the body value.
                        await connection.call(
                            TestMethods.echo, on: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 1))
                    }
                }
                // Tear the fake server down before asserting so no failure
                // path can park on the accept loop.
                tasks.cancelAll()
                try? await tasks.waitForAll()
                guard case .failure(.protocolViolation) = outcome else {
                    Issue.record("expected .failure(.protocolViolation), got \(outcome)")
                    return
                }
            }
        }
    }

    @Test("open() brackets a LIVE connection: calls work inside, closed and joined after")
    func openBracketLifecycle() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let withConnection = MMClientConnection.open(.unix(path: path))
                let outcome = await withConnection { connection in
                    // A round-trip inside the scope proves the bracket-owned
                    // loop is live (no loop, no response routing).
                    let reply = await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 3))
                    #expect(reply == .success(EchoResponse(value: 3)))
                    return .success(connection)
                }
                guard case .success(let connection) = outcome else {
                    Issue.record("bracket must succeed, got \(outcome)")
                    return
                }
                // Dispose closed AND joined: post-return the state is
                // deterministically .closed (clean — a local close).
                #expect(connection.state == .closed(reason: nil))
            }
        }
    }

    @Test("the with-bracket owns the whole lifecycle: connect, run, body, close, join")
    func bracketRoundTrip() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let outcome = await MMClientConnection.with(.unix(path: path)) { connection in
                    await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 7))
                }
                #expect(outcome == .success(.success(EchoResponse(value: 7))))
            }
        }
        // Connect failure is the bracket's own failure channel; the body
        // never runs.
        let refused = await MMClientConnection.with(
            .unix(path: "/nonexistent/mm-bracket.sock")
        ) { _ in
            Issue.record("body must not run when connect fails")
            return false
        }
        guard case .failure(.transport) = refused else {
            Issue.record("expected .failure(.transport), got \(refused)")
            return
        }
    }

    @Test("Accepts patterns: subtree and exact-entity routes deny out-of-scope targets")
    func routeEntityScoping() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (results, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> [Result<EchoResponse, MMCallError>] in
                    [
                        // Accepts("box", "box.*") admits the descendants AND
                        // the explicitly listed prefix entity itself.
                        await connection.call(
                            TestMethods.scopedEcho, on: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 1)),
                        await connection.call(
                            TestMethods.scopedEcho, on: entity("box"),
                            EchoRequest(entity: entity("box"), value: 2)),
                        // `echo` is in the ACL and readable by this peer —
                        // only the route's Accepts denies it.
                        await connection.call(
                            TestMethods.scopedEcho, on: entity("echo"),
                            EchoRequest(entity: entity("echo"), value: 3)),
                        // Accepts("box.item") admits exactly that entity...
                        await connection.call(
                            TestMethods.scopedExact, on: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 4)),
                        // ...and not its parent, even though the parent is in
                        // the same subtree and ACL-readable.
                        await connection.call(
                            TestMethods.scopedExact, on: entity("box"),
                            EchoRequest(entity: entity("box"), value: 5)),
                        // Entity inference: an entity-less call (on: omitted →
                        // root) on the single-entity route targets box.item —
                        // authorized as if spelled out.
                        await connection.call(
                            TestMethods.scopedExact,
                            EchoRequest(entity: entity("box.item"), value: 6)),
                        // A wider vocabulary infers nothing: entity-less is
                        // denied like any unaccepted target.
                        await connection.call(
                            TestMethods.scopedEcho,
                            EchoRequest(entity: entity("box.item"), value: 7)),
                    ]
                }
                #expect(results[0] == .success(EchoResponse(value: 1)))
                #expect(results[1] == .success(EchoResponse(value: 2)))
                #expect(results[2] == .failure(.denied))
                #expect(results[3] == .success(EchoResponse(value: 4)))
                #expect(results[4] == .failure(.denied))
                #expect(results[5] == .success(EchoResponse(value: 6)))
                #expect(results[6] == .failure(.denied))
                if case .failure(let error) = runResult {
                    Issue.record("run() must end cleanly, got \(error)")
                }
            }
        }
    }

    @Test("calendar and clock values round-trip the wire exactly")
    func dateKindsRoundTrip() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let payload = WhenPayload(
                    day: MMDate(year: 2026, month: 2, day: 29)
                        ?? MMDate(year: 2026, month: 2, day: 28)!,
                    slot: MMDateTime(
                        date: MMDate(year: 2026, month: 7, day: 21)!,
                        hour: 14, minute: 30, second: 0, nanosecond: 250_000_000)!,
                    created: MMTimestamp(
                        dateTime: MMDateTime(
                            date: MMDate(year: 2026, month: 7, day: 21)!,
                            hour: 12, minute: 0, second: 0)!,
                        offsetMinutes: -570)!,
                    remind: nil
                )
                let (reply, runResult) = try await withConnectedClient(unixPath: path) {
                    connection in
                    // Entity inference on the single-entity route: the echo
                    // proves encode → wire → decode is byte-faithful for all
                    // three kinds, fraction and negative offset included.
                    await connection.call(TestMethods.when, payload)
                }
                #expect(reply == .success(payload))
                if case .failure(let error) = runResult {
                    Issue.record("run() must end cleanly, got \(error)")
                }
            }
        }
    }

    @Test("a typed call round-trips: encode, authorize, dispatch, decode")
    func typedEchoRoundTrip() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (reply, runResult) = try await withConnectedClient(unixPath: path) {
                    connection in
                    await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 42))
                }
                #expect(reply == .success(EchoResponse(value: 42)))
                if case .failure(let error) = runResult {
                    Issue.record("run() must end cleanly, got \(error)")
                }
            }
        }
    }

    @Test("concurrent calls multiplex on one connection; each response reaches its caller")
    func concurrentCallsMultiplex() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                _ = try await withConnectedClient(unixPath: path) { connection in
                    try await withThrowingTaskGroup(of: Void.self) { calls in
                        for value in 1...TestServer.burstConcurrency {
                            calls.addTask {
                                let reply = await connection.call(
                                    TestMethods.burst, on: entity("box.item"),
                                    EchoRequest(entity: entity("box.item"), value: value)
                                )
                                #expect(reply == .success(EchoResponse(value: value)))
                            }
                        }
                        // All 8 handlers parked: every request is in flight
                        // simultaneously, so their responses race the funnel.
                        _ = try await withDeadline { try await server.burstStarted.wait() }
                        server.burstGate.fire(())
                        try await calls.waitForAll()
                    }
                }
            }
        }
    }

    @Test("authorization and application failures surface as their typed call errors")
    func errorMapping() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                _ = try await withConnectedClient(unixPath: path) { connection in
                    // box.locked: we are the owner and the owner class denies
                    // (mode 0o077) — first-matching-class-wins, so .denied.
                    let denied = await connection.call(
                        TestMethods.echo, on: entity("box.locked"),
                        EchoRequest(entity: entity("box.locked"), value: 1))
                    #expect(denied == .failure(.denied))
                    // nope.method is registered nowhere.
                    let unknown = await connection.call(
                        TestMethods.unregistered, on: entity("box.item"),
                        TargetRequest(entity: entity("box.item"), ))
                    #expect(unknown == .failure(.unknownMethod))
                    // fail.run answers a fixed application error: code >= 64
                    // reaches the caller verbatim, payload intact.
                    let remote = await connection.call(
                        TestMethods.fail, on: entity("box.item"),
                        TargetRequest(entity: entity("box.item"), ))
                    #expect(remote == .failure(.remote(applicationErrorObject())))
                }
            }
        }
    }

    @Test("the typed client connects over TCP: anonymous peer reaches other-class grants")
    func typedClientOverTCP() async throws {
        let server = makeTestServer(
            configuration: .init(endpoint: .tcp(host: "127.0.0.1", port: 0))
        )
        try await withRunningServer(server) { _ in
            let address = try await withDeadline { try await server.bound.wait() }
            let port = try #require(address.port)
            let (replies, runResult) = try await withConnectedClient(
                to: .tcp(host: "127.0.0.1", port: port)
            ) {
                connection -> (Result<PingResponse, MMCallError>, Result<EchoResponse, MMCallError>)
                in
                // The other-class x grant is callable for the anonymous TCP
                // peer; owner-class-only entities deny it.
                let ping = await connection.call(
                    TestMethods.ping, on: entity("pub.thing"),
                    TargetRequest(entity: entity("pub.thing"), ))
                let denied = await connection.call(
                    TestMethods.echo, on: entity("box.item"),
                    EchoRequest(entity: entity("box.item"), value: 1))
                return (ping, denied)
            }
            #expect(replies.0 == .success(PingResponse(ok: true)))
            #expect(replies.1 == .failure(.denied))
            if case .failure(let error) = runResult {
                Issue.record("run() must end cleanly over TCP, got \(error)")
            }
        }
    }

    @Test("client idleTimeout reaps a silent connection: the pending call fails connectionClosed")
    func clientIdleReapsSilentConnection() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (outcome, runResult) = try await withConnectedClient(
                    unixPath: path,
                    configuration: .init(idleTimeout: .milliseconds(200))
                ) { connection in
                    // slow.wait parks server-side, so after the request write
                    // the wire is silent in both directions: the client's
                    // reaper closes the connection (real time — the test only
                    // waits for it, so load affects duration, not outcome).
                    let reply = await connection.call(
                        TestMethods.slow, on: entity("box.item"),
                        TargetRequest(entity: entity("box.item"), ))
                    // A local reaper close is a clean end, per the
                    // configuration contract.
                    #expect(connection.state == .closed(reason: nil))
                    return reply
                }
                // Release the parked handler so the server drain never waits.
                server.slowGate.fire(())
                #expect(outcome == .failure(.connectionClosed))
                if case .failure(let error) = runResult {
                    Issue.record("run() must end cleanly on idle reap, got \(error)")
                }
            }
        }
    }

    @Test("a call failing .connectionClosed never observes a still-connected state")
    func closeFailureObservesClosedState() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                // The tight window: close() then an immediate call, so the
                // call's write races run()'s teardown. Whichever way it
                // lands, a .connectionClosed outcome must imply an
                // already-closed state — the finish() state-before-resume
                // invariant. (The write-failure path used to answer
                // .connectionClosed directly, losing exactly this race on
                // loaded CI runners; the loop widens the window.)
                for _ in 0..<25 {
                    _ = try await withConnectedClient(unixPath: path) { connection in
                        await connection.close()
                        let outcome = await connection.call(
                            TestMethods.echo, on: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 1))
                        #expect(outcome == .failure(.connectionClosed))
                        #expect(connection.state == .closed(reason: nil))
                    }
                }
            }
        }
    }

    @Test("graceful server shutdown completes the in-flight call, then the client closes cleanly")
    func gracefulShutdownCompletesInFlightCall() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { group in
                _ = try await withConnectedClient(unixPath: path) { connection in
                    try await withThrowingTaskGroup(of: Void.self) { calls in
                        calls.addTask {
                            let reply = await connection.call(
                                TestMethods.slow, on: entity("box.item"),
                                TargetRequest(entity: entity("box.item"), ))
                            #expect(reply == .success(EchoResponse(value: 99)))
                        }
                        _ = try await withDeadline { try await server.slowStarted.wait() }
                        // Drain begins with the call still parked server-side.
                        await group.triggerGracefulShutdown()
                        server.slowGate.fire(())
                        try await calls.waitForAll()
                        // The server drained and closed; the client observes it
                        // as a clean close, not an error.
                        let terminal = try await withDeadline { () -> ClientState? in
                            var states = connection.stateUpdates().makeAsyncIterator()
                            while let state = await states.next() {
                                if case .closed = state { return state }
                            }
                            return nil
                        }
                        #expect(terminal == .closed(reason: nil))
                    }
                }
            }
        }
    }

    @Test("abrupt server death fails every pending call exactly once")
    func abruptServerDeathFailsPendingCalls() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            let stopServer = Signal<Void>()
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask {
                    // The server's task tree, killed by cancellation on signal:
                    // SIGINT-equivalent — no drain, connections torn down.
                    try? await withDeadline(seconds: 60) {
                        await withThrowingTaskGroup(of: Void.self) { serverGroup in
                            serverGroup.addTask { try await server.service.run() }
                            serverGroup.addTask {
                                try await stopServer.wait()
                                throw DeadlineExceeded()  // any throw cancels run()
                            }
                            _ = try? await serverGroup.next()
                            serverGroup.cancelAll()
                        }
                    }
                }
                _ = try await withDeadline { try await server.bound.wait() }
                let (callResult, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> Result<EchoResponse, MMCallError> in
                    try await withThrowingTaskGroup(
                        of: Result<EchoResponse, MMCallError>.self
                    ) { calls in
                        calls.addTask {
                            await connection.call(
                                TestMethods.slow, on: entity("box.item"),
                                TargetRequest(entity: entity("box.item"), ))
                        }
                        _ = try await withDeadline { try await server.slowStarted.wait() }
                        stopServer.fire(())
                        guard let result = try await calls.next() else {
                            throw DeadlineExceeded()
                        }
                        return result
                    }
                }
                // Exactly-once is structural (the continuation resumes once or
                // the harness deadline fires); the failure is a death, not a
                // response. EOF surfaces as connectionClosed, an RST as
                // transport — both are honest deaths.
                switch callResult {
                    case .failure(.connectionClosed), .failure(.transport):
                        break
                    default:
                        Issue.record("pending call must fail on server death, got \(callResult)")
                }
                _ = runResult  // clean or transport — the loop must have returned either way
                tasks.cancelAll()
                try? await tasks.waitForAll()
            }
        }
    }

    @Test("cancelling a gated call abandons its msgid; the late response is dropped harmlessly")
    func cancellationAbandonsGatedCall() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                _ = try await withConnectedClient(unixPath: path) { connection in
                    let result = NIOLockedValueBox<Result<EchoResponse, MMCallError>?>(nil)
                    try await withThrowingTaskGroup(of: Void.self) { calls in
                        calls.addTask {
                            let reply = await connection.call(
                                TestMethods.slow, on: entity("box.item"),
                                TargetRequest(entity: entity("box.item"), ))
                            result.withLockedValue { $0 = reply }
                        }
                        _ = try await withDeadline { try await server.slowStarted.wait() }
                        calls.cancelAll()
                        try await calls.waitForAll()
                    }
                    #expect(result.withLockedValue { $0 } == .failure(.cancelled))
                    // Release the handler: its late response hits an abandoned
                    // msgid and is dropped. The connection must stay healthy
                    // and must not misdeliver it to the next call.
                    server.slowGate.fire(())
                    let echo = await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 8))
                    #expect(echo == .success(EchoResponse(value: 8)))
                }
            }
        }
    }

    @Test(
        "discovery returns the traversal-filtered list, the unfiltered fingerprint, and feeds SchemaDifference"
    )
    func discoveryEndToEnd() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                // First connection: no expectation — fingerprintMatched is nil.
                let (schema, _) = try await withConnectedClient(unixPath: path) { connection in
                    #expect(connection.server.fingerprintMatched == nil)
                    return try await connection.discoverSchema().get()
                }
                // Filtered by OUR traversal rights (see fixtureACLs); the
                // fingerprint covers the complete, unfiltered method set. The
                // S3 streaming fixtures live under "box" (owner 0o700), so they
                // are traversable-and-visible to us alongside echo/pub.
                #expect(
                    schema.methods.map(\.name) == [
                        "box.follow", "box.followEndPark", "box.followFail",
                        "box.followGated", "box.followQuiet", "box.followStoppable", "box.import",
                        "box.importGated", "box.importStop", "box.pipe",
                        "echo.run", "pub.ping",
                    ]
                )
                #expect(schema.fingerprint == server.service.router.fingerprint)

                // Reconnect expecting the right fingerprint, then a wrong one.
                _ = try await withConnectedClient(
                    unixPath: path,
                    configuration: .init(
                        schema: MMClientSchema(
                            contracts: [], serverFingerprint: schema.fingerprint))
                ) { connection in
                    #expect(connection.server.fingerprintMatched == true)
                }
                _ = try await withConnectedClient(
                    unixPath: path,
                    configuration: .init(
                        schema: MMClientSchema(
                            contracts: [], serverFingerprint: schema.fingerprint &+ 1))
                ) { connection in
                    #expect(connection.server.fingerprintMatched == false)
                    #expect(connection.server.fingerprint == schema.fingerprint)
                    // The mismatch triggers discovery; the diff pinpoints how
                    // this build's view skews from what the server serves.
                    let remote = try await connection.discoverSchema().get()
                    let localEcho = try Method<EchoRequest, EchoResponse>(
                        name: "echo.run", access: .read  // server declares .write
                    ).signature().get()
                    let localPing = try Method<EchoRequest, PingResponse>(
                        name: "pub.ping", access: .execute  // request shape differs
                    ).signature().get()
                    let localGone = try TestMethods.unregistered.signature().get()
                    let diff = SchemaDifference(
                        local: [localEcho, localPing, localGone], remote: remote)
                    #expect(diff.missingMethods.map(\.name) == ["nope.method"])
                    #expect(diff.accessChanged.map(\.local.name) == ["echo.run"])
                    #expect(diff.signatureChanged.map(\.local.name) == ["pub.ping"])
                    // Remote-only: every S3 streaming method the local view does
                    // not declare (the diff surfaces them so a stale client sees
                    // what the server gained).
                    #expect(
                        diff.remoteOnly.map(\.name) == [
                            "box.follow", "box.followEndPark", "box.followFail",
                            "box.followGated", "box.followQuiet", "box.followStoppable", "box.import",
                            "box.importGated", "box.importStop", "box.pipe",
                        ]
                    )
                }
            }
        }
    }

    @Test("the ServiceGroup adapter runs the loop and drains cleanly on graceful shutdown")
    func serviceGroupLifecycle() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let connection = try await MMClientConnection.connect(
                    to: .unix(path: path),
                    configuration: .init(),
                    logger: quietClientLogger()
                ).get()
                let clientGroup = ServiceGroup(
                    configuration: .init(
                        services: [
                            .init(service: MMClientConnectionService(connection: connection))
                        ],
                        logger: Logger(label: "mm.test.client-group")
                    )
                )
                try await withThrowingTaskGroup(of: Void.self) { tasks in
                    tasks.addTask {
                        try await withDeadline(seconds: 30) { try await clientGroup.run() }
                    }
                    // Calls park until the group starts the loop, then flow.
                    let reply = await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 5))
                    #expect(reply == .success(EchoResponse(value: 5)))
                    await clientGroup.triggerGracefulShutdown()
                    try await tasks.waitForAll()
                }
                #expect(connection.state == .closed(reason: nil))
            }
        }
    }
}
