import Logging
import MMSchema
import MMTestSupport
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import ServiceLifecycle
import Testing

@testable import MMClient
@testable import MMServer

/// S4 client-side streaming, exercised end to end over a real temp-dir unix
/// socket through the **real typed `MMClientConnection`** against the **real
/// `MMService`** — the typed twin of the raw-frame `StreamingServerTests`.
/// The raw suite drove the server with hand-built kind-1..6 frames; this suite
/// drives it with the typed stream handles (`InboundStreamHandle`,
/// `OutboundStreamHandle`, `BidirectionalStreamHandle`) and pins the full termination
/// matrix as the API user observes it — element sequences, `send` outcomes, and
/// the awaitable terminal `Result`.
///
/// Harness discipline (shared with the rest of the file): every await is bounded
/// by a `withDeadline`/`Signal`, gates are opened on pass and fail, no sleeps
/// stand in for synchronization, and `withConnectedClient` runs the client's
/// inbound loop as a structured child and joins it (asserting a clean or honest
/// `runResult`) on the way out.
@Suite("MMClient streaming against MMServer over a real temp-dir unix socket")
struct StreamingClientTests {
    /// `box` grants r/w/x to the owning (test) peer — the target every fixture
    /// stream authorizes against.
    static let box = entity("box")

    // Row 1 --------------------------------------------------------------

    @Test("server streaming happy path: 20 elements in order, then a graceful summary terminal")
    func serverStreamHappyPath() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (outcome, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> ([Int], Result<StreamSummary, MMCallError>) in
                    let handle = await connection.call(
                        TestMethods.follow, on: Self.box, FollowRequest(entity: Self.box, count: 20)
                    )
                    // Iterating grants credit invisibly; the API user only sees
                    // elements, never a credit frame.
                    var received: [Int] = []
                    for await item in handle {
                        received.append(item.value)
                    }
                    let terminal = await handle.result()
                    return (received, terminal)
                }
                #expect(outcome.0 == Array(0..<20))
                #expect(outcome.1 == .success(StreamSummary(count: 20)))
                expectCleanRun(runResult)
            }
        }
    }

    // Row 2 --------------------------------------------------------------

    @Test(
        "backpressure e2e (anti-head-of-line): a stalled stream consumer does not block 8 sibling unary calls"
    )
    func backpressureDoesNotBlockSiblings() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (received: [Int], terminal: Result<StreamSummary, MMCallError>) in
                    let handle = await connection.call(
                        TestMethods.follow, on: Self.box, FollowRequest(entity: Self.box, count: 20)
                    )
                    // A gate the test opens to release the stalled consumer, and a
                    // signal fired once the consumer has drained its first 3
                    // elements and is provably parked at the gate.
                    let resume = Signal<Void>()
                    let stalled = Signal<Void>()
                    let collected = NIOLockedValueBox<[Int]>([])

                    return try await withThrowingTaskGroup(
                        of: Void.self
                    ) { group -> (received: [Int], terminal: Result<StreamSummary, MMCallError>) in
                        // The stalled consumer: take 3, then wait on the gate
                        // BEFORE consuming more — the server, having granted only
                        // the initial window and seen only 3 drained (< the
                        // 8-item grant batch), parks at zero credit and cannot
                        // send item 8. Item delivery is capped at the window.
                        group.addTask {
                            var seen: [Int] = []
                            var iterator = handle.makeAsyncIterator()
                            for _ in 0..<3 {
                                guard let item = await iterator.next() else { break }
                                seen.append(item.value)
                            }
                            collected.withLockedValue { $0 = seen }
                            stalled.fire(())
                            _ = try? await resume.wait()
                            // Resume draining: consuming the rest of the window
                            // crosses the grant batch, credit flows, the server
                            // unparks and streams to completion.
                            while let item = await iterator.next() {
                                seen.append(item.value)
                            }
                            collected.withLockedValue { $0 = seen }
                        }

                        // The consumer is stalled at the gate.
                        _ = try await withDeadline { try await stalled.wait() }

                        // 8 concurrent unary echo calls on the SAME connection
                        // each complete promptly despite the stalled stream — the
                        // proof that a lagging stream consumer starves only itself.
                        try await withThrowingTaskGroup(of: Void.self) { echoes in
                            for value in 1...8 {
                                echoes.addTask {
                                    let reply = await connection.call(
                                        TestMethods.echo, on: entity("box.item"),
                                        EchoRequest(entity: entity("box.item"), value: value)
                                    )
                                    #expect(reply == .success(EchoResponse(value: value)))
                                }
                            }
                            try await echoes.waitForAll()
                        }

                        // Release the consumer → the stream runs to completion.
                        resume.fire(())
                        try await group.waitForAll()
                        let terminal = await handle.result()
                        return (collected.withLockedValue { $0 }, terminal)
                    }
                }
                // The consumer drained all 20 in order; the terminal is the
                // graceful summary — proving the window stall never lost data.
                #expect(result.received == Array(0..<20))
                #expect(result.terminal == .success(StreamSummary(count: 20)))
                expectCleanRun(runResult)
            }
        }
    }

    // Row 3 --------------------------------------------------------------

    @Test("client streaming: send 6 elements, finish(), then a count-6 terminal")
    func clientStreamHappyPath() async throws {
        // The within-window happy path (6 ≤ 8): the typed `send`/END/terminal
        // round-trip with no grant needed. The suspend/resume-past-the-window half
        // of matrix row 3 is proven separately by
        // `clientStreamPastWindowSuspendsAndResumes` (row 3b), which streams >8
        // items and relies on the server's request-stream credit grant.
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (
                        outcomes: [MMClient.StreamSendOutcome],
                        terminal: Result<StreamSummary, MMCallError>
                    ) in
                    let handle = await connection.call(
                        TestMethods.importItems, on: Self.box,
                        ImportRequest(entity: Self.box, stopAfter: 0)
                    )
                    // Six elements ride the implicit initial window with no grant
                    // needed; each `send` is accepted. `finish()` sends END, which
                    // ends the handler's request sequence and yields the terminal.
                    var outcomes: [MMClient.StreamSendOutcome] = []
                    for value in 0..<6 {
                        outcomes.append(await handle.send(StreamItem(value: value)))
                    }
                    await handle.finish()
                    let terminal = await handle.result()
                    return (outcomes, terminal)
                }
                #expect(result.outcomes == Array(repeating: .sent, count: 6))
                #expect(result.terminal == .success(StreamSummary(count: 6)))
                expectCleanRun(runResult)
            }
        }
    }

    // Row 3b -------------------------------------------------------------

    @Test(
        "client streaming past the window: the send gate suspends on the 9th and resumes on a server grant"
    )
    func clientStreamPastWindowSuspendsAndResumes() async throws {
        // The suspend/resume half of matrix row 3, now provable end to end: a
        // conforming client streams MORE than the initial window (8) of request
        // items to the fast `importItems` handler (which drains each item as it
        // arrives). The 9th send exhausts the window and the outbound gate
        // suspends; the server, as its handler consumes, grants request-stream
        // credit over the wire (a kind-2 frame) on the consumption edge, which
        // resumes the parked send. Every send therefore returns `.sent`, and the
        // terminal counts all N — no deadlock.
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (
                        outcomes: [MMClient.StreamSendOutcome],
                        terminal: Result<StreamSummary, MMCallError>
                    ) in
                    let handle = await connection.call(
                        TestMethods.importItems, on: Self.box,
                        ImportRequest(entity: Self.box, stopAfter: 0)
                    )
                    // 20 > the initial window of 8: sends 9..<20 can only land if
                    // the server grants request credit as the handler drains.
                    var outcomes: [MMClient.StreamSendOutcome] = []
                    for value in 0..<20 {
                        outcomes.append(await handle.send(StreamItem(value: value)))
                    }
                    await handle.finish()
                    let terminal = await handle.result()
                    return (outcomes, terminal)
                }
                #expect(result.outcomes == Array(repeating: .sent, count: 20))
                #expect(result.terminal == .success(StreamSummary(count: 20)))
                expectCleanRun(runResult)
            }
        }
    }

    // Row 4 --------------------------------------------------------------

    @Test("bidirectional: pipe N elements while consuming the echoes; both directions end cleanly")
    func bidiPipeBothDirections() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (echoed: [Int], terminal: Result<StreamSummary, MMCallError>) in
                    let handle = await connection.call(
                        TestMethods.pipe, on: Self.box,
                        ImportRequest(entity: Self.box, stopAfter: 0)
                    )
                    // Stream past the initial request-stream window (8): both the
                    // request-direction grants (server → client, on the handler's
                    // consumption edge) and the response-direction grants (client →
                    // server, as this consumer drains) must flow for a >8 bidirectional to
                    // complete without deadlock. 12 exercises both grant paths at
                    // once — request items in, echoed response items out, END,
                    // terminal.
                    let n = 12
                    let received = NIOLockedValueBox<[Int]>([])
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        // Consumer: drain every echoed response element.
                        group.addTask {
                            var seen: [Int] = []
                            for await item in handle.inbound {
                                seen.append(item.value)
                            }
                            received.withLockedValue { $0 = seen }
                        }
                        // Producer: send n request elements, then END.
                        group.addTask {
                            for value in 0..<n {
                                let outcome = await handle.outbound.send(
                                    StreamItem(value: value * 10))
                                #expect(outcome == .sent)
                            }
                            await handle.outbound.finish()
                        }
                        try await group.waitForAll()
                    }
                    let terminal = await handle.inbound.result()
                    return (received.withLockedValue { $0 }, terminal)
                }
                // Order is preserved per direction: the echo of value*10, in order.
                #expect(result.echoed == (0..<12).map { $0 * 10 })
                #expect(result.terminal == .success(StreamSummary(count: 12)))
                expectCleanRun(runResult)
            }
        }
    }

    // Row 5 --------------------------------------------------------------

    @Test(
        "graceful client STOP: take 5, stop(); terminal is .success; the connection stays healthy")
    func clientStopGraceful() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (
                        taken: [Int], terminal: Result<StreamSummary, MMCallError>,
                        followUp: Result<EchoResponse, MMCallError>
                    ) in
                    let handle = await connection.call(
                        TestMethods.follow, on: Self.box,
                        FollowRequest(entity: Self.box, count: 1000)
                    )
                    var taken: [Int] = []
                    var iterator = handle.makeAsyncIterator()
                    for _ in 0..<5 {
                        guard let item = await iterator.next() else { break }
                        taken.append(item.value)
                    }
                    // Ask the server to wrap up (advisory, graceful). The call
                    // still runs to its terminal; the server ends on .peerStopped.
                    await handle.stop()
                    let terminal = await handle.result()
                    // The connection is unharmed: a fresh unary call is served.
                    let followUp = await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 5))
                    return (taken, terminal, followUp)
                }
                #expect(result.taken == Array(0..<5))
                // The server ended gracefully on STOP: a nil-error terminal.
                #expect(result.terminal.isSuccess)
                #expect(result.followUp == .success(EchoResponse(value: 5)))
                expectCleanRun(runResult)
            }
        }
    }

    // Row 6 --------------------------------------------------------------

    @Test(
        "server STOP: the import-stop fixture stops after the first item; send() returns .peerStopped; the call still terminates"
    )
    func serverStopSurfacesPeerStopped() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (
                        outcomes: [MMClient.StreamSendOutcome],
                        terminal: Result<StreamSummary, MMCallError>
                    ) in
                    // `stopAfter: 1` STOPs after the very first item, well within
                    // the initial window (8), so the follow-up sends observe the
                    // server STOP promptly rather than stalling on a credit grant.
                    let handle = await connection.call(
                        TestMethods.importStopping, on: Self.box,
                        ImportRequest(entity: Self.box, stopAfter: 1)
                    )
                    // First send: accepted (`.sent`). The server consumes it and
                    // issues its server-initiated STOP, then fires `importStopSent`.
                    var outcomes: [MMClient.StreamSendOutcome] = [
                        await handle.send(StreamItem(value: 0))
                    ]
                    // Bound the STOP's arrival on the signal (the server reports the
                    // kind-5 STOP is on the wire), THEN erect a deterministic
                    // ordering barrier: a unary echo on the SAME connection. The
                    // STOP frame was funnelled before `importStopSent` fired, so it
                    // precedes the echo response on the wire; the client's inbound
                    // loop processes frames strictly in order, so by the time the
                    // echo response resolves, the STOP has already flipped the send
                    // gate. The next `send` therefore returns `.peerStopped`
                    // deterministically — no scheduler race, no timing.
                    _ = try await withDeadline { try await server.importStopSent.wait() }
                    let barrier = await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 1))
                    #expect(barrier == .success(EchoResponse(value: 1)))
                    outcomes.append(await handle.send(StreamItem(value: 1)))
                    // Wrap up and finish; the call still runs to its terminal.
                    await handle.finish()
                    let terminal = await handle.result()
                    return (outcomes, terminal)
                }
                // The typed outcome sequence: one or more `.sent`, terminating in
                // exactly one `.peerStopped` (the graceful server-STOP signal); the
                // element that drew `.peerStopped` was not sent.
                #expect(result.outcomes.last == .peerStopped)
                #expect(result.outcomes.dropLast().allSatisfy { $0 == .sent })
                #expect(result.outcomes.contains(.sent))
                // The call still terminates gracefully with the count the handler
                // consumed (it keeps consuming past STOP until END).
                #expect(result.terminal.isSuccess)
                expectCleanRun(runResult)
            }
        }
    }

    // Row 7 --------------------------------------------------------------

    @Test(
        "CANCEL via a cancelled consuming task resolves every surface .cancelled; the handler observes it"
    )
    func cancelViaConsumingTask() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (
                        terminal: Result<StreamSummary, MMCallError>,
                        followUp: Result<EchoResponse, MMCallError>
                    ) in
                    // followGated parks on its gate between items and observes
                    // cancellation cooperatively (fires followCancelled). We never
                    // open the gate. The consuming task is cancelled first — its
                    // bare task-cancellation ends the element sequence (a local
                    // stop of reading, no wire frame, per the handle contract) —
                    // and then, from this live (uncancelled) scope, the whole call
                    // is abandoned with an explicit `cancel()` (kind-6 CANCEL). The
                    // escalation runs from a live task because a CANCEL sent from a
                    // cancelled task would find the outbound write itself cancelled.
                    let handle = await connection.call(
                        TestMethods.followGated, on: Self.box,
                        FollowRequest(entity: Self.box, count: 1000)
                    )
                    let consumedUnderCancel = NIOLockedValueBox<Bool>(false)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await _ in handle {}
                            // The element sequence ended because the task was
                            // cancelled (the gate never opened, so no element ever
                            // ended it): the consuming task's local stop of reading.
                            consumedUnderCancel.withLockedValue { $0 = Task.isCancelled }
                        }
                        _ = try await withDeadline { try await server.followStarted.wait() }
                        group.cancelAll()
                        try await group.waitForAll()
                    }
                    #expect(consumedUnderCancel.withLockedValue { $0 })
                    // Escalate the cancelled read into a whole-call CANCEL.
                    await handle.cancel()
                    // The server handler observes cooperative cancellation.
                    _ = try await withDeadline { try await server.followCancelled.wait() }
                    // Every surface resolves .cancelled locally; the server's
                    // code-7 terminal is consumed silently to retire the msgid.
                    let terminal = await handle.result()
                    // The connection survives: a fresh unary call works.
                    let followUp = await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 7))
                    return (terminal, followUp)
                }
                #expect(result.terminal == .failure(.cancelled))
                #expect(result.followUp == .success(EchoResponse(value: 7)))
                expectCleanRun(runResult)
            }
        }
    }

    @Test(
        "CANCEL via an explicit cancel() resolves every surface .cancelled exactly once; the handler observes it"
    )
    func cancelViaExplicitCall() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (
                        terminals: [Result<StreamSummary, MMCallError>], elementCount: Int,
                        followUp: Result<EchoResponse, MMCallError>
                    ) in
                    let handle = await connection.call(
                        TestMethods.followGated, on: Self.box,
                        FollowRequest(entity: Self.box, count: 1000)
                    )
                    _ = try await withDeadline { try await server.followStarted.wait() }
                    // Explicit cancel of the whole call.
                    await handle.cancel()
                    _ = try await withDeadline { try await server.followCancelled.wait() }
                    // Every surface resolves .cancelled: the element sequence ends
                    // and result() resolves .cancelled — and it resolves the SAME
                    // way no matter how many times it is awaited (exactly once).
                    var elementCount = 0
                    for await _ in handle { elementCount += 1 }
                    let terminals = [
                        await handle.result(), await handle.result(), await handle.result(),
                    ]
                    let followUp = await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 8))
                    return (terminals, elementCount, followUp)
                }
                #expect(
                    result.terminals
                        == Array(
                            repeating: Result<StreamSummary, MMCallError>.failure(.cancelled),
                            count: 3))
                #expect(result.followUp == .success(EchoResponse(value: 8)))
                expectCleanRun(runResult)
            }
        }
    }

    // Row 8 --------------------------------------------------------------

    @Test(
        "error terminal mid-stream: elements end, terminal is the mapped .failure, the connection stays healthy"
    )
    func errorTerminalMidStream() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (
                        received: [Int], terminal: Result<StreamSummary, MMCallError>,
                        followUp: Result<EchoResponse, MMCallError>
                    ) in
                    // `box.followFail` streams `count` items then returns an
                    // application error terminal (code >= 64, payload intact).
                    let handle = await connection.call(
                        TestMethods.followFailing, on: Self.box,
                        FollowRequest(entity: Self.box, count: 3)
                    )
                    var received: [Int] = []
                    for await item in handle { received.append(item.value) }
                    let terminal = await handle.result()
                    // The connection is unharmed by a per-call error terminal.
                    let followUp = await connection.call(
                        TestMethods.echo, on: entity("box.item"),
                        EchoRequest(entity: entity("box.item"), value: 9))
                    return (received, terminal, followUp)
                }
                // The 3 elements arrive first; then the sequence ends and the
                // terminal is the mapped application failure, preserved verbatim.
                #expect(result.received == Array(0..<3))
                #expect(result.terminal == .failure(.remote(applicationErrorObject())))
                #expect(result.followUp == .success(EchoResponse(value: 9)))
                expectCleanRun(runResult)
            }
        }
    }

    // Row 9 --------------------------------------------------------------

    @Test(
        "connection death mid-stream: elements end, terminal resolves .transport/.connectionClosed exactly once"
    )
    func connectionDeathMidStream() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            let stopServer = Signal<Void>()
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                // The server's task tree, killed by cancellation on the stop
                // signal — the SIGINT-equivalent hard-death pattern (no drain).
                tasks.addTask {
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

                let (terminals, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> [Result<StreamSummary, MMCallError>] in
                    // A gated follow that is provably open and streaming its first
                    // window; we then kill the server abruptly under it.
                    let handle = await connection.call(
                        TestMethods.follow, on: Self.box,
                        FollowRequest(entity: Self.box, count: 100_000)
                    )
                    var iterator = handle.makeAsyncIterator()
                    // Drain the initial window so the stream is provably live.
                    for _ in 0..<8 { _ = await iterator.next() }
                    // Kill the server; the socket dies under the live stream.
                    stopServer.fire(())
                    // The element sequence ends and the terminal resolves the
                    // death — and resolves the same way every time it is awaited
                    // (exactly once, cached).
                    while await iterator.next() != nil {}
                    return [await handle.result(), await handle.result()]
                }
                for terminal in terminals {
                    switch terminal {
                        case .failure(.connectionClosed), .failure(.transport):
                            break
                        default:
                            Issue.record("stream terminal must resolve a death, got \(terminal)")
                    }
                }
                // Both awaits saw the identical cached outcome.
                #expect(terminals[0] == terminals[1])
                _ = runResult  // clean or transport — the loop returned either way
                tasks.cancelAll()
                try? await tasks.waitForAll()
            }
        }
    }

    // Row 10 -------------------------------------------------------------

    @Test(
        "msgid wrap: a live stream held across the u32 wrap; new calls allocate around it and both complete"
    )
    func msgidWrapWithLiveStream() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                let (result, runResult) = try await withConnectedClient(unixPath: path) {
                    connection -> (
                        held: Result<StreamSummary, MMCallError>,
                        wrapped: [Result<EchoResponse, MMCallError>]
                    ) in
                    // Seed the allocator near the top of the u32 range so a wrap
                    // is reachable without 2^32 calls. The next id handed out is
                    // UInt32.max; the one after wraps to 0, then 1, ...
                    connection._seedNextMsgid(UInt32.max)

                    // Open a gated server stream and hold it live across the wrap.
                    // It claims msgid UInt32.max and, parked on its gate before any
                    // item, stays live in the table (never retired) while the new
                    // calls below allocate — so allocation must SKIP it. `count` is
                    // 1 (≤ the response window) so that when the gate finally opens
                    // the handler emits its single item and terminates without
                    // needing this test to consume/grant response credit (which it
                    // deliberately never does — the point is to hold the id live).
                    let held = await connection.call(
                        TestMethods.followGated, on: Self.box,
                        FollowRequest(entity: Self.box, count: 1)
                    )
                    _ = try await withDeadline { try await server.followStarted.wait() }

                    // Re-seed the allocator to UInt32.max *while the stream holds
                    // that id*: the very next allocation lands on the live id and
                    // must skip it (wrapping to 0) rather than collide — the
                    // skip-live-ids wrap policy exercised head-on. New unary calls
                    // then allocate 0, 1, 2, 3 around the held stream, each still
                    // round-tripping to its own caller.
                    connection._seedNextMsgid(UInt32.max)
                    var wrapped: [Result<EchoResponse, MMCallError>] = []
                    for value in 1...4 {
                        wrapped.append(
                            await connection.call(
                                TestMethods.echo, on: entity("box.item"),
                                EchoRequest(entity: entity("box.item"), value: value)
                            )
                        )
                    }

                    // Release the held stream and let it finish.
                    server.followGate.fire(())
                    let terminal = await held.result()
                    return (terminal, wrapped)
                }
                // Both surfaces completed: the held stream terminated gracefully
                // and every wrapped unary call reached its caller unmisdelivered.
                #expect(result.held.isSuccess)
                #expect(result.wrapped == (1...4).map { .success(EchoResponse(value: $0)) })
                expectCleanRun(runResult)
            }
        }
    }

    // Row 12 -------------------------------------------------------------

    @Test(
        "contract check: the streaming fixtures verify(against:) clean and discoverSchema surfaces stream fields"
    )
    func streamingContractAndDiscovery() async throws {
        // The declaration-side contract: the streaming fixtures declared with
        // RequestStream / ResponseStream parts verify clean against the probed
        // descriptors (the two-sided contract the daemon runs at boot).
        #expect(
            try StreamFixtureContract.declaration.verify(against: StreamFixtures.self).get().isEmpty
        )

        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                _ = try await withConnectedClient(unixPath: path) { connection in
                    let remote = try await connection.discoverSchema().get()
                    let byName = Dictionary(
                        remote.methods.map { ($0.name, $0) },
                        uniquingKeysWith: { first, _ in first })

                    // A server-streaming method: responseStream present, request
                    // stream absent — the stream fields survived end to end.
                    let follow = try #require(byName["box.follow"])
                    #expect(follow.responseStream != nil)
                    #expect(follow.requestStream == nil)

                    // A client-streaming method: the mirror image.
                    let importItems = try #require(byName["box.import"])
                    #expect(importItems.requestStream != nil)
                    #expect(importItems.responseStream == nil)

                    // A bidirectional method: both stream directions present.
                    let pipe = try #require(byName["box.pipe"])
                    #expect(pipe.requestStream != nil)
                    #expect(pipe.responseStream != nil)

                    // A unary method carries neither.
                    let echo = try #require(byName["echo.run"])
                    #expect(echo.requestStream == nil)
                    #expect(echo.responseStream == nil)

                    // The discovered stream signatures equal the locally probed
                    // ones — the fingerprint-bearing shapes agree over the wire.
                    let localFollow = try TestMethods.follow.signature().get()
                    #expect(follow.responseStream == localFollow.responseStream)
                    let localPipe = try TestMethods.pipe.signature().get()
                    #expect(pipe.requestStream == localPipe.requestStream)
                    #expect(pipe.responseStream == localPipe.responseStream)
                }
            }
        }
    }

}

// MARK: - Row 12 contract fixtures

/// The streaming fixtures as a ``MethodNamespace`` — the probed side of the
/// row-12 two-sided contract. Mirrors the wire names/types the server actually
/// serves (``TestMethods``), so the declaration below can `verify(against:)` it.
enum StreamFixtures: MethodNamespace {
    static let follow = TestMethods.follow
    static let importItems = TestMethods.importItems
    static let pipe = TestMethods.pipe

    @SchemaBuilder static var all: [AnyMethod] {
        follow
        importItems
        pipe
    }
}

/// The declared side of the row-12 contract: `Call` parts with
/// ``RequestStream`` / ``ResponseStream`` that must match ``StreamFixtures``'s
/// probed descriptors exactly (the daemon's boot-time `verify(against:)`).
enum StreamFixtureContract {
    static let declaration = Schema("box") {
        Call("follow") {
            Access { .read }
            Request {
                Field("entity", .string)
                Field("count", .int)
            }
            ResponseStream { Field("value", .int) }
            Response { Field("count", .int) }
        }
        Call("import") {
            Access { .write }
            Request {
                Field("entity", .string)
                Field("stopAfter", .int)
            }
            RequestStream { Field("value", .int) }
            Response { Field("count", .int) }
        }
        Call("pipe") {
            Access { .write }
            Request {
                Field("entity", .string)
                Field("stopAfter", .int)
            }
            RequestStream { Field("value", .int) }
            ResponseStream { Field("value", .int) }
            Response { Field("count", .int) }
        }
    }
}

// MARK: - Result convenience

extension Result {
    /// Whether this is `.success`, for terminals whose exact success value is
    /// not pinned (a graceful STOP/END whose count depends on in-flight timing).
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Asserts the client's inbound loop ended cleanly (or on an honest transport
/// death) rather than a protocol violation — the S4 discipline that a
/// well-behaved server never trips the client's connection-fatal path.
private func expectCleanRun(_ runResult: Result<Void, MMClientError>) {
    switch runResult {
        case .success:
            break
        case .failure(.transport):
            break  // an honest death (e.g. RST) is acceptable where the test kills the peer
        case .failure(let error):
            Issue.record("run() must end cleanly, got \(error)")
    }
}
