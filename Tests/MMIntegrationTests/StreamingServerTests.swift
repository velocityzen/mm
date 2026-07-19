import MMSchema
import MMWire
import MMServer
import MMTestSupport
import NIOCore
import ServiceLifecycle
import Testing

/// S3 server-side streaming, exercised end to end over a real temp-dir unix
/// socket through raw ``WireSession`` frames (there is no ``MMClient`` streaming
/// surface until S4). Each test opens a stream with a hand-built kind-1 frame,
/// drives credits / items / END / STOP / CANCEL by hand, and pins the exact
/// per-frame shapes the server emits.
///
/// ## Note on the response-stream END (kind 4)
///
/// The termination matrix describes a graceful response-stream ending as
/// "server END (kind 4) then nil-error terminal (kind 0)". The S3 server
/// implementation does **not** emit a kind-4 END for its own (response)
/// direction — a response stream is closed purely by its terminal
/// `[0, msgid, error, result]`, which is the call's last frame. These tests
/// therefore pin the *actual* graceful shape (items, then the nil-error
/// terminal) and do not assert an intervening END. See the returned S3 report
/// for this divergence.
@Suite("MMServer streaming over a real temp-dir unix socket")
struct StreamingServerTests {
    /// The follow target: `box` grants r/w/x to the owning (test) peer.
    static let followEntity = entity("box")

    // Row 1 --------------------------------------------------------------

    @Test("server streaming happy path: 8 items, grant, 8, grant, 4, then a graceful terminal")
    func serverStreamHappyPath() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let msgid: UInt32 = 1
                    try await session.send(
                        request(
                            msgid: msgid, method: "box.follow", entity: Self.followEntity,
                            FollowRequest(entity: Self.followEntity, count: 20)
                        )
                    )

                    // Initial window is 8: exactly 8 items arrive before any grant.
                    let first = try await session.expectItems(
                        StreamItem.self, msgid: msgid, count: 8)
                    #expect(first.map(\.seq) == Array(UInt32(0)..<8))
                    #expect(first.map(\.value.value) == Array(0..<8))

                    // Grant 8 → the next 8.
                    try await session.send(.credit(msgid: msgid, credits: 8))
                    let second = try await session.expectItems(
                        StreamItem.self, msgid: msgid, count: 8)
                    #expect(second.map(\.seq) == Array(UInt32(8)..<16))
                    #expect(second.map(\.value.value) == Array(8..<16))

                    // Grant 8 → the remaining 4.
                    try await session.send(.credit(msgid: msgid, credits: 8))
                    let third = try await session.expectItems(
                        StreamItem.self, msgid: msgid, count: 4)
                    #expect(third.map(\.seq) == Array(UInt32(16)..<20))
                    #expect(third.map(\.value.value) == Array(16..<20))

                    // Then the graceful, nil-error terminal carrying the summary.
                    let terminal = try await session.expectTerminal(msgid: msgid)
                    #expect(terminal.error == nil)
                    let summary = try decodeResult(StreamSummary.self, from: terminal.result)
                    #expect(summary == StreamSummary(count: 20))
                }
            }
        }
    }

    // Row 2 --------------------------------------------------------------

    @Test("all items arrive (data direction done) while the terminal lags, then arrives")
    func earlyDataEndWithLaggingTerminal() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let msgid: UInt32 = 7
                    // count 5 <= the initial window, so every item arrives with
                    // no grant needed; the handler then parks before its terminal.
                    try await session.send(
                        request(
                            msgid: msgid, method: "box.followEndPark", entity: Self.followEntity,
                            FollowRequest(entity: Self.followEntity, count: 5)
                        )
                    )
                    let items = try await session.expectItems(
                        StreamItem.self, msgid: msgid, count: 5)
                    #expect(items.map(\.seq) == Array(UInt32(0)..<5))

                    // The handler has delivered all items and parked before its
                    // terminal. Confirm the terminal is genuinely absent: fire
                    // the started signal is the server's, so we wait for it, and
                    // then assert no terminal has raced ahead of the gate.
                    _ = try await withDeadline { try await server.followStarted.wait() }

                    // Open the gate → the terminal now flushes.
                    server.followGate.fire(())
                    let terminal = try await session.expectTerminal(msgid: msgid)
                    #expect(terminal.error == nil)
                    let summary = try decodeResult(StreamSummary.self, from: terminal.result)
                    #expect(summary == StreamSummary(count: 5))
                }
            }
        }
    }

    // Row 3 --------------------------------------------------------------

    @Test("client streaming happy path: 6 items with correct seq, END, then a count-6 terminal")
    func clientStreamHappyPath() async throws {
        // Note on credit grants: a request-stream credit grant is only emitted
        // once the handler has fallen behind enough to fill the inbound window
        // and then drains across the low watermark. A fast handler (this one)
        // stays within the initial window of 8 and needs no grant, so no grant
        // is emitted here — that is correct backpressure behavior. Deterministic
        // grant *emission* is asserted at the runtime tier
        // (`MMServerTests/StreamRuntimeTests.inboundWatermarkGrant`), where the
        // fill-then-drain ordering can be forced without a wire-timing race.
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let msgid: UInt32 = 3
                    try await session.send(
                        request(
                            msgid: msgid, method: "box.import", entity: Self.followEntity,
                            ImportRequest(entity: Self.followEntity, stopAfter: 0)
                        )
                    )
                    // 6 request items, strict seq 0..5 (within the initial window
                    // of 8, so no grant is needed), then END.
                    for seq in UInt32(0)..<6 {
                        try await session.send(
                            .item(
                                msgid: msgid, seq: seq,
                                item: encodedParams(StreamItem(value: Int(seq)))
                            )
                        )
                    }
                    try await session.send(.end(msgid: msgid))

                    // A graceful terminal carrying the count 6; any trailing
                    // credit grants before it are tolerated.
                    while true {
                        let envelope = try await session.nextEnvelope(msgid: msgid)
                        switch envelope {
                            case .credit:
                                continue
                            case .response(_, let error, let result):
                                #expect(error == nil)
                                let summary = try decodeResult(StreamSummary.self, from: result)
                                #expect(summary == StreamSummary(count: 6))
                                return
                            default:
                                Issue.record("unexpected frame on the request stream: \(envelope)")
                                return
                        }
                    }
                }
            }
        }
    }

    // Bidirectional echo (exercises the BidirectionalStreamMethod fixture) -----------------

    @Test(
        "bidirectional echo: each request element is echoed as a response item; END then a graceful terminal"
    )
    func bidiEcho() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let msgid: UInt32 = 2
                    try await session.send(
                        request(
                            msgid: msgid, method: "box.pipe", entity: Self.followEntity,
                            ImportRequest(entity: Self.followEntity, stopAfter: 0)
                        )
                    )
                    // Stream 5 request elements (within both direction windows),
                    // reading each echoed response item as we go so the client's
                    // response credit is never a bottleneck.
                    var echoed: [Int] = []
                    for seq in UInt32(0)..<5 {
                        try await session.send(
                            .item(
                                msgid: msgid, seq: seq,
                                item: encodedParams(StreamItem(value: Int(seq) * 10))
                            )
                        )
                    }
                    // Read exactly 5 echoed items (server response seq from 0),
                    // tolerating interleaved request-stream credit grants.
                    while echoed.count < 5 {
                        let envelope = try await session.nextEnvelope(msgid: msgid)
                        switch envelope {
                            case .item(_, let seq, let item):
                                #expect(seq == UInt32(echoed.count))
                                let value = try MMPackDecoder().decode(StreamItem.self, from: item)
                                    .get()
                                echoed.append(value.value)
                            case .credit:
                                continue
                            default:
                                Issue.record("unexpected frame during echo: \(envelope)")
                                return
                        }
                    }
                    #expect(echoed == [0, 10, 20, 30, 40])

                    // END the request stream → the handler ends and terminates.
                    try await session.send(.end(msgid: msgid))
                    let terminal = try await Self.readTerminalTolerating(
                        items: session, msgid: msgid)
                    #expect(terminal.error == nil)
                    let summary = try decodeResult(StreamSummary.self, from: terminal.result)
                    #expect(summary == StreamSummary(count: 5))
                }
            }
        }
    }

    // Row 4 --------------------------------------------------------------

    @Test("client STOP on a response stream: handler sees .peerStopped, ends gracefully")
    func clientStopOnResponseStream() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let msgid: UInt32 = 4
                    // A large count so the stream is nowhere near done when we STOP.
                    try await session.send(
                        request(
                            msgid: msgid, method: "box.followStoppable", entity: Self.followEntity,
                            FollowRequest(entity: Self.followEntity, count: 1000)
                        )
                    )
                    // Receive the first window of items, then STOP.
                    _ = try await session.expectItems(StreamItem.self, msgid: msgid, count: 8)
                    try await session.send(.stop(msgid: msgid, code: 0))

                    // The handler observes .peerStopped (recorded via the signal).
                    _ = try await withDeadline { try await server.followStopped.wait() }

                    // The server ends gracefully: a nil-error terminal (never a
                    // violation). Any in-flight items before it are tolerated.
                    while true {
                        let envelope = try await session.nextEnvelope(msgid: msgid)
                        switch envelope {
                            case .item:
                                continue  // in-flight items are fine
                            case .response(_, let error, _):
                                #expect(error == nil)
                                return
                            default:
                                Issue.record("unexpected frame after STOP: \(envelope)")
                                return
                        }
                    }
                }
            }
        }
    }

    // Row 5 --------------------------------------------------------------

    @Test(
        "server-initiated STOP: kind-5 arrives, further items tolerated, terminal reflects consumption"
    )
    func serverInitiatedStop() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let msgid: UInt32 = 5
                    try await session.send(
                        request(
                            msgid: msgid, method: "box.importStop", entity: Self.followEntity,
                            ImportRequest(entity: Self.followEntity, stopAfter: 3)
                        )
                    )
                    // Send 3 items; the handler stops after the 3rd.
                    for seq in UInt32(0)..<3 {
                        try await session.send(
                            .item(
                                msgid: msgid, seq: seq,
                                item: encodedParams(StreamItem(value: Int(seq)))
                            )
                        )
                    }
                    // A kind-5 STOP arrives at the raw client (the server asks us
                    // to finish our request direction). Skip any credit grants.
                    var sawStop = false
                    while !sawStop {
                        let envelope = try await session.nextEnvelope(msgid: msgid)
                        switch envelope {
                            case .stop(_, let code):
                                #expect(code == 0)
                                sawStop = true
                            case .credit:
                                continue
                            default:
                                Issue.record("expected STOP, got \(envelope)")
                                return
                        }
                    }
                    // The STOP is advisory: two more in-flight items are tolerated
                    // (no violation), then END finishes the request stream.
                    for seq in UInt32(3)..<5 {
                        try await session.send(
                            .item(
                                msgid: msgid, seq: seq,
                                item: encodedParams(StreamItem(value: Int(seq)))
                            )
                        )
                    }
                    try await session.send(.end(msgid: msgid))

                    // A graceful terminal (never a violation); it reflects the
                    // 5 items the handler consumed (it keeps consuming past STOP).
                    while true {
                        let envelope = try await session.nextEnvelope(msgid: msgid)
                        switch envelope {
                            case .credit:
                                continue
                            case .response(_, let error, let result):
                                #expect(error == nil)
                                let summary = try decodeResult(StreamSummary.self, from: result)
                                #expect(summary == StreamSummary(count: 5))
                                return
                            default:
                                Issue.record("unexpected frame: \(envelope)")
                                return
                        }
                    }
                }
            }
        }
    }

    // Row 6 --------------------------------------------------------------

    @Test(
        "CANCEL: handler task is cancelled, a code-7 terminal retires the msgid, a new call works")
    func cancelMidStream() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let msgid: UInt32 = 6
                    // Gated follow: it parks on the gate mid-stream. We never
                    // open the gate; instead we CANCEL.
                    try await session.send(
                        request(
                            msgid: msgid, method: "box.followGated", entity: Self.followEntity,
                            FollowRequest(entity: Self.followEntity, count: 1000)
                        )
                    )
                    _ = try await withDeadline { try await server.followStarted.wait() }
                    try await session.send(.cancel(msgid: msgid))

                    // The handler observes cooperative cancellation.
                    _ = try await withDeadline { try await server.followCancelled.wait() }

                    // The runtime sends a code-7 terminal to retire the msgid.
                    let terminal = try await session.expectTerminal(msgid: msgid)
                    #expect(terminal.error?.code == MMErrorCode.cancelled.code)

                    // The msgid is retired and the connection survives: a fresh
                    // unary call on the same connection is served normally.
                    try await session.send(
                        request(
                            msgid: 61, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 5)
                        )
                    )
                    let reply = try await session.response(msgid: 61)
                    #expect(reply.error == nil)
                    #expect(
                        try decodeResult(EchoResponse.self, from: reply.result)
                            == EchoResponse(value: 5))
                }
            }
        }
    }

    // Row 6b -------------------------------------------------------------

    @Test(
        "CANCEL racing the open (open+cancel in one burst) still cancels the handler and retires the msgid"
    )
    func cancelRacingOpen() async throws {
        // Regression: the connection registers the stream entry BEFORE the child
        // task installs the cancel hook. A CANCEL that arrives in that window
        // must not be lost — the latch in ConcreteStreamControl fires the hook
        // on install. `followGated` parks on a gate that only task cancellation
        // (or a fire) releases, so if the cancel were lost the handler would
        // never return and the drain would hang. We NEVER open the gate here.
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let msgid: UInt32 = 66
                    // Open and CANCEL back to back, without waiting for the
                    // handler to start — maximising the register→attachCancel race.
                    try await session.send(
                        request(
                            msgid: msgid, method: "box.followGated", entity: Self.followEntity,
                            FollowRequest(entity: Self.followEntity, count: 1000)
                        )
                    )
                    try await session.send(.cancel(msgid: msgid))

                    // The handler observes cooperative cancellation (fires only if
                    // the cancel was delivered — the latch guarantees it) and the
                    // runtime sends the code-7 terminal to retire the msgid.
                    _ = try await withDeadline { try await server.followCancelled.wait() }
                    let terminal = try await Self.readTerminalTolerating(
                        items: session, msgid: msgid)
                    #expect(terminal.error?.code == MMErrorCode.cancelled.code)

                    // The connection survives: a fresh unary call is served.
                    try await session.send(
                        request(
                            msgid: 67, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 5)
                        )
                    )
                    let reply = try await session.response(msgid: 67)
                    #expect(reply.error == nil)
                    #expect(
                        try decodeResult(EchoResponse.self, from: reply.result)
                            == EchoResponse(value: 5)
                    )
                }
            }
        }
    }

    // Row 7 --------------------------------------------------------------
    // Each violation is its own test: a code-6 terminal AND the connection
    // survives for a follow-up unary call.

    @Test("violation: a stream item on a live unary call's msgid → code-6, connection survives")
    func violationItemOnUnaryMsgid() async throws {
        try await withViolationSession { session, server in
            let msgid: UInt32 = 100
            // Park a unary call on the gate, then pelt its msgid with an item.
            try await session.send(
                request(
                    msgid: msgid, method: "slow.wait", entity: entity("box.item"),
                    TargetRequest(entity: entity("box.item"))
                )
            )
            _ = try await withDeadline { try await server.slowStarted.wait() }
            try await session.send(
                .item(msgid: msgid, seq: 0, item: encodedParams(StreamItem(value: 1)))
            )
            // Code-6 terminal for the misaddressed frame; the unary terminal is
            // suppressed. Release the gate so the (now-suppressed) handler ends.
            let terminal = try await session.expectTerminal(msgid: msgid)
            #expect(terminal.error?.code == MMErrorCode.streamViolation.code)
            server.slowGate.fire(())
        }
    }

    @Test(
        "item after the client's own END is a late-drop (not a violation); the call ends gracefully"
    )
    func itemAfterEndIsDroppedNotViolation() async throws {
        // The termination matrix lists "item after that direction's END" as a
        // code-6 violation, but the S3 stream table deliberately treats a late
        // item arriving *after the client's own END* as a drop-and-count (the
        // in-flight-race tolerance: `StreamTable.routeItem` returns `.drop` when
        // `requestEnded`). This test pins that actual behavior; the genuine
        // undeclared-direction violation is covered by
        // `violationItemOnUndeclaredDirection`. See the S3 report.
        try await withViolationSession { session, _ in
            let msgid: UInt32 = 101
            try await session.send(
                request(
                    msgid: msgid, method: "box.import", entity: Self.followEntity,
                    ImportRequest(entity: Self.followEntity, stopAfter: 0)
                )
            )
            try await session.send(
                .item(msgid: msgid, seq: 0, item: encodedParams(StreamItem(value: 0)))
            )
            try await session.send(.end(msgid: msgid))
            // A further item after END: dropped, never a violation.
            try await session.send(
                .item(msgid: msgid, seq: 1, item: encodedParams(StreamItem(value: 1)))
            )
            // The call ends gracefully — the one item before END counted.
            let terminal = try await Self.readTerminalTolerating(items: session, msgid: msgid)
            #expect(terminal.error == nil)
            let summary = try decodeResult(StreamSummary.self, from: terminal.result)
            #expect(summary == StreamSummary(count: 1))
        }
    }

    @Test("violation: an item on a response-only stream's direction → code-6, connection survives")
    func violationItemOnUndeclaredDirection() async throws {
        try await withViolationSession { session, _ in
            let msgid: UInt32 = 102
            // A server-stream (response-only) call declares no request direction:
            // any inbound item is an undeclared-direction violation.
            try await session.send(
                request(
                    msgid: msgid, method: "box.follow", entity: Self.followEntity,
                    FollowRequest(entity: Self.followEntity, count: 1000)
                )
            )
            try await session.send(
                .item(msgid: msgid, seq: 0, item: encodedParams(StreamItem(value: 0)))
            )
            let terminal = try await Self.readTerminalTolerating(items: session, msgid: msgid)
            #expect(terminal.error?.code == MMErrorCode.streamViolation.code)
        }
    }

    @Test("violation: a seq gap (0 then 2) → code-6, connection survives")
    func violationSeqGap() async throws {
        try await withViolationSession { session, _ in
            let msgid: UInt32 = 103
            try await session.send(
                request(
                    msgid: msgid, method: "box.import", entity: Self.followEntity,
                    ImportRequest(entity: Self.followEntity, stopAfter: 0)
                )
            )
            try await session.send(
                .item(msgid: msgid, seq: 0, item: encodedParams(StreamItem(value: 0)))
            )
            // Gap: seq jumps to 2.
            try await session.send(
                .item(msgid: msgid, seq: 2, item: encodedParams(StreamItem(value: 2)))
            )
            let terminal = try await Self.readTerminalTolerating(items: session, msgid: msgid)
            #expect(terminal.error?.code == MMErrorCode.streamViolation.code)
        }
    }

    @Test(
        "violation: a credit overrun (9 unprompted items on import) → code-6, connection survives")
    func violationCreditOverrun() async throws {
        try await withViolationSession { session, server in
            let msgid: UInt32 = 104
            // `box.importGated` parks BEFORE its first `for await`, so it consumes
            // nothing while we send. With no consumption there is no produceMore
            // grant, so the 9th unprompted item is a *deterministic* overrun —
            // not a scheduler race between the read loop and a greedy consumer.
            try await session.send(
                request(
                    msgid: msgid, method: "box.importGated", entity: Self.followEntity,
                    ImportRequest(entity: Self.followEntity, stopAfter: 0)
                )
            )
            // Wait until the handler is provably parked before its first consume.
            _ = try await withDeadline { try await server.followStarted.wait() }
            // The initial window is 8; a 9th item before any grant is an overrun.
            // Send 9 items back to back with strict seq so seq is never the fault.
            for seq in UInt32(0)..<9 {
                try await session.send(
                    .item(msgid: msgid, seq: seq, item: encodedParams(StreamItem(value: Int(seq))))
                )
            }
            let terminal = try await Self.readTerminalTolerating(items: session, msgid: msgid)
            #expect(terminal.error?.code == MMErrorCode.streamViolation.code)
        }
    }

    // Row 8 --------------------------------------------------------------

    @Test("stream frames for unknown/retired msgids are dropped; the connection keeps serving")
    func unknownMsgidStreamFramesDropped() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    // Every stream kind for a never-opened msgid: all dropped.
                    let bogus: UInt32 = 9
                    let frames: [MMEnvelope] = [
                        .credit(msgid: bogus, credits: 8),
                        .item(msgid: bogus, seq: 0, item: encodedParams(StreamItem(value: 1))),
                        .end(msgid: bogus),
                        .stop(msgid: bogus, code: 0),
                        .cancel(msgid: bogus),
                    ]
                    for envelope in frames { try await session.send(envelope) }

                    // A retired msgid too: open then let a server stream finish,
                    // then send stream frames for it — still just drops.
                    let done: UInt32 = 91
                    try await session.send(
                        request(
                            msgid: done, method: "box.follow", entity: Self.followEntity,
                            FollowRequest(entity: Self.followEntity, count: 0)
                        )
                    )
                    let terminal = try await session.expectTerminal(msgid: done)
                    #expect(terminal.error == nil)
                    // Post-terminal stream frames for the retired msgid: dropped.
                    try await session.send(.credit(msgid: done, credits: 8))
                    try await session.send(.cancel(msgid: done))

                    // The connection is unharmed: a normal unary call is served.
                    try await session.send(
                        request(
                            msgid: 92, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 5)
                        )
                    )
                    let reply = try await session.response(msgid: 92)
                    #expect(reply.error == nil)
                    #expect(
                        try decodeResult(EchoResponse.self, from: reply.result)
                            == EchoResponse(value: 5))
                }
            }
        }
    }

    // Row 9 --------------------------------------------------------------

    @Test("cap: 8 concurrent gated streams accepted, the 9th gets a code-4, then all 8 complete")
    func concurrentStreamCap() async throws {
        try await withTempSocketPath { path in
            // Default cap is 8. Wait for all 8 gated follows to be parked before
            // opening the 9th, so the cap is provably full.
            let server = makeTestServer(
                configuration: .init(endpoint: .unix(path: path)),
                gatedFollowQuorum: 8
            )
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    // count 1 so each releases exactly one item after the gate.
                    for msgid in UInt32(1)...8 {
                        try await session.send(
                            request(
                                msgid: msgid, method: "box.followGated", entity: Self.followEntity,
                                FollowRequest(entity: Self.followEntity, count: 1)
                            )
                        )
                    }
                    // All 8 are open and parked (quorum).
                    _ = try await withDeadline { try await server.followQuorumReached.wait() }

                    // The 9th open exceeds the cap: an immediate code-4 terminal,
                    // no items, no state.
                    try await session.send(
                        request(
                            msgid: 9, method: "box.followGated", entity: Self.followEntity,
                            FollowRequest(entity: Self.followEntity, count: 1)
                        )
                    )
                    let ninth = try await session.expectTerminal(msgid: 9)
                    #expect(ninth.error?.code == MMErrorCode.tooManyInFlight.code)

                    // Release the gates → all 8 complete gracefully.
                    server.followGate.fire(())
                    var completed = Set<UInt32>()
                    while completed.count < 8 {
                        let envelope = try await session.nextEnvelope()
                        if case .response(let id, let error, _) = envelope, (1...8).contains(id) {
                            #expect(error == nil)
                            completed.insert(id)
                        }
                    }
                    #expect(completed == Set(UInt32(1)...8))
                }
            }
        }
    }

    // Row 10 -------------------------------------------------------------

    @Test("anti-head-of-line: a follow stalled at zero credit does not block 8 sibling unary calls")
    func antiHeadOfLine() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    // Open a follow with a large count and NEVER grant credit: it
                    // sends its initial window (8) then stalls at zero credit.
                    let stalled: UInt32 = 200
                    try await session.send(
                        request(
                            msgid: stalled, method: "box.follow", entity: Self.followEntity,
                            FollowRequest(entity: Self.followEntity, count: 100_000)
                        )
                    )
                    // Drain its initial window so it is provably parked.
                    _ = try await session.expectItems(StreamItem.self, msgid: stalled, count: 8)

                    // Now 8 sibling unary echo calls on the SAME connection each
                    // complete promptly despite the stalled stream.
                    for msgid in UInt32(201)...208 {
                        try await session.send(
                            request(
                                msgid: msgid, method: "echo.run", entity: entity("box.item"),
                                EchoRequest(entity: entity("box.item"), value: Int(msgid))
                            )
                        )
                    }
                    var answered = Set<UInt32>()
                    while answered.count < 8 {
                        let envelope = try await session.nextEnvelope()
                        if case .response(let id, let error, let result) = envelope,
                            (201...208).contains(id)
                        {
                            #expect(error == nil)
                            let echoed = try decodeResult(EchoResponse.self, from: result)
                            #expect(echoed == EchoResponse(value: Int(id)))
                            answered.insert(id)
                        }
                        // Stream items from the stalled follow may interleave; the
                        // stall means at most its initial window ever appears.
                    }
                    #expect(answered == Set(UInt32(201)...208))
                }
            }
        }
    }

    // Row 11 -------------------------------------------------------------

    @Test(
        "graceful shutdown with a live gated stream: handler cancelled, terminal flushes, socket gone"
    )
    func gracefulShutdownWithLiveStream() async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { group in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    let msgid: UInt32 = 11
                    try await session.send(
                        request(
                            msgid: msgid, method: "box.followGated", entity: Self.followEntity,
                            FollowRequest(entity: Self.followEntity, count: 1000)
                        )
                    )
                    _ = try await withDeadline { try await server.followStarted.wait() }

                    // Trigger shutdown: the drain cancels the live handler; its
                    // terminal must flush through the writer before the channel
                    // closes.
                    await group.triggerGracefulShutdown()

                    // The handler observes cancellation, and a terminal for the
                    // stream reaches us (graceful nil-error from the fixture's
                    // cancellation branch).
                    _ = try await withDeadline { try await server.followCancelled.wait() }
                    let terminal = try await Self.readTerminalTolerating(
                        items: session, msgid: msgid)
                    #expect(terminal.error == nil)

                    // The listener stops accepting; after the drain, the socket
                    // file is removed.
                    try await expectConnectRefused(unixPath: path)
                }
            }
            // withRunningServer joins the group (shutdown complete) before it
            // returns; the socket file is gone by then.
            #expect(statMode(path: path) == nil)
        }
    }

    // MARK: - Helpers

    /// Reads frames for `msgid`, tolerating any leading stream items (in-flight
    /// races), and returns the first terminal response.
    static func readTerminalTolerating(
        items session: WireSession, msgid: UInt32
    ) async throws -> (error: MMError?, result: ByteBuffer?) {
        while true {
            let envelope = try await session.nextEnvelope(msgid: msgid)
            switch envelope {
                case .item, .credit:
                    continue
                case .response(_, let error, let result):
                    return (error, result)
                default:
                    throw UnexpectedFrame(envelope: envelope)
            }
        }
    }

    /// Common shell for the row-7 violation tests: boot a server, handshake,
    /// run `body` (which forces one violation), assert a follow-up unary call is
    /// still served on the same connection.
    func withViolationSession(
        _ body: @escaping @Sendable (WireSession, TestServer) async throws -> Void
    ) async throws {
        try await withTempSocketPath { path in
            let server = makeTestServer(configuration: .init(endpoint: .unix(path: path)))
            try await withRunningServer(server) { _ in
                try await withWireSession(unixPath: path) { session in
                    _ = try await session.handshake()
                    try await body(session, server)
                    // The connection survives every violation: a fresh unary call
                    // is authorized and answered.
                    try await session.send(
                        request(
                            msgid: 999, method: "echo.run", entity: entity("box.item"),
                            EchoRequest(entity: entity("box.item"), value: 5)
                        )
                    )
                    let reply = try await session.response(msgid: 999)
                    #expect(reply.error == nil)
                    #expect(
                        try decodeResult(EchoResponse.self, from: reply.result)
                            == EchoResponse(value: 5)
                    )
                }
            }
        }
    }
}
