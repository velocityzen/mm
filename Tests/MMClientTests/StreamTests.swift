import MMSchema
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMClient

/// S4 client streaming, driven over a `NIOAsyncTestingChannel` by hand-built raw
/// frames (like `CallTests`): open a stream with the typed `call` overload, then
/// feed inbound items / credits / END / STOP / terminal and read the outbound
/// items / credits / END / STOP / CANCEL the client emits. Exact typed-`Result`
/// assertions throughout.
@Suite("Client streaming: inbound, outbound, bidirectional, termination matrix")
struct StreamTests {

    // MARK: - Server streaming (inbound)

    @Test("server stream: elements arrive in order, terminal is .success, msgid opened")
    func serverStreamHappyPath() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.follow, on: entity("box"), boxRequest(1))
            // The opening request reaches the wire.
            let (msgid, method, _) = try await client.readRequestFrame()
            #expect(method == "box.follow")

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var got: [Int] = []
                    for await element in handle {
                        got.append(element.value)
                    }
                    #expect(got == [10, 11, 12])
                    #expect(await handle.result() == .success(StreamSummary(count: 3)))
                }
                // Three items (within the initial window of 8, no grant needed),
                // then a graceful terminal carrying the summary.
                for (seq, value) in [(UInt32(0), 10), (1, 11), (2, 12)] {
                    try await client.channel.writeInbound(
                        itemFrame(msgid: msgid, seq: seq, value: value))
                }
                try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 3))
                try await group.waitForAll()
            }
        }
    }

    @Test("server stream: draining a full window grants exactly one batch of credit back")
    func inboundCreditGrantWatermarkBatched() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.follow, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var got: [Int] = []
                    for await element in handle {
                        got.append(element.value)
                    }
                    #expect(got.count == 9)
                    _ = await handle.result()
                }
                // Send exactly the initial window (8) then one more item: the 9th
                // consumed element crosses the grant watermark, so the client
                // emits exactly one credit(8) frame.
                for seq in UInt32(0)..<9 {
                    try await client.channel.writeInbound(
                        itemFrame(msgid: msgid, seq: seq, value: Int(seq)))
                }
                // The client grants credit as its consumer drains the 8th item.
                var granted: UInt32 = 0
                while granted == 0 {
                    let envelope = try await readOutboundEnvelope(client)
                    if case .credit(let id, let credits) = envelope {
                        #expect(id == msgid)
                        granted = credits
                    }
                }
                #expect(granted == StreamCredit.initialWindow)
                // Then finish the call so the consuming task ends.
                try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 9))
                try await group.waitForAll()
            }
        }
    }

    @Test("server stream: a seq gap is a connection-fatal protocol violation; the terminal fails")
    func inboundSeqGapIsFatal() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0)))
        let connection = try await establish(harness).get()
        let client = ConnectedClient(
            loop: harness.loop, channel: harness.channel, connection: connection)

        let runResult = NIOLockedValueBox<Result<Void, MMClientError>?>(nil)
        let terminalResult = NIOLockedValueBox<Result<StreamSummary, MMCallError>?>(nil)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let r = await connection.run()
                runResult.withLockedValue { $0 = r }
            }
            let handle = await connection.call(
                ClientTestMethods.follow, on: entity("box"), boxRequest(1))
            let (streamMsgid, _, _) = try await client.readRequestFrame()
            group.addTask {
                let r = await handle.result()
                terminalResult.withLockedValue { $0 = r }
            }
            // seq 0 then a gap to seq 2 → server protocol violation, fatal.
            try await client.channel.writeInbound(itemFrame(msgid: streamMsgid, seq: 0, value: 0))
            try await client.channel.writeInbound(itemFrame(msgid: streamMsgid, seq: 2, value: 2))
            try await group.waitForAll()
        }

        guard case .some(.failure(.protocolViolation)) = runResult.withLockedValue({ $0 }) else {
            Issue.record(
                "expected run() protocolViolation, got \(String(describing: runResult.withLockedValue { $0 }))"
            )
            return
        }
        // The live stream's terminal fails on the connection death.
        #expect(terminalResult.withLockedValue { $0 } == .failure(.connectionClosed))
        guard case .closed(.some(.protocolViolation)) = connection.state else {
            Issue.record("expected closed(protocolViolation), got \(connection.state)")
            return
        }
    }

    @Test("server stream: an error terminal maps code 6 to .streamViolation, code 7 to .cancelled")
    func inboundErrorTerminalMapping() async throws {
        for (code, expected): (Int, MMCallError) in [
            (6, .streamViolation(MMErrorObject(code: 6, message: "v"))),
            (7, .cancelled),
        ] {
            _ = try await withRunningConnection { client in
                let handle = await client.connection.call(
                    ClientTestMethods.follow, on: entity("box"), boxRequest(1))
                let (msgid, _, _) = try await client.readRequestFrame()
                let terminal = try MMEnvelope.response(
                    msgid: msgid, error: MMErrorObject(code: code, message: "v"), result: nil
                ).encoded().get()
                try await client.channel.writeInbound(framed(terminal))
                // The element sequence finishes (empty), the terminal is the mapped failure.
                for await _ in handle {}
                #expect(await handle.result() == .failure(expected))
            }
        }
    }

    @Test("server stream: a lagging consumer parks the inbound loop until it drains")
    func inboundBackpressureParksLoop() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.follow, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            // Fill past the high watermark (initial window = 8) so the producer
            // buffer fills and the inbound loop parks before reading further.
            // The consumer has not started iterating, so nothing drains.
            for seq in UInt32(0)..<10 {
                try await client.channel.writeInbound(
                    itemFrame(msgid: msgid, seq: seq, value: Int(seq)))
            }
            // The loop parks deterministically once the buffer is full.
            try await withDeadline {
                while !handle._isInboundParked { await Task.yield() }
            }

            // Draining the consumer unparks the loop; every item is delivered and
            // the terminal resolves — proof the park released, not wedged.
            try await withThrowingTaskGroup(of: Void.self) { group in
                let drained = NIOLockedValueBox(0)
                group.addTask {
                    for await _ in handle {
                        drained.withLockedValue { $0 += 1 }
                    }
                }
                try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 10))
                try await group.waitForAll()
                #expect(drained.withLockedValue { $0 } == 10)
                #expect(await handle.result() == .success(StreamSummary(count: 10)))
            }
        }
    }

    @Test(
        "server stream: explicit cancel() from the consuming task sends CANCEL and resolves .cancelled"
    )
    func explicitCancelFromConsumer() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.follow, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            let started = NIOLockedValueBox(false)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in handle {
                        started.withLockedValue { $0 = true }
                        // Explicit cancel maps task cancellation to a CANCEL frame.
                        await handle.cancel()
                    }
                }
                // Feed one item so the consumer enters its body and cancels.
                _ = try? await client.channel.writeInbound(
                    itemFrame(msgid: msgid, seq: 0, value: 1))
                await group.waitForAll()
            }
            #expect(started.withLockedValue { $0 })
            // A CANCEL frame went out.
            let cancel = try await readOutboundEnvelope(client)
            guard case .cancel(let id) = cancel else {
                Issue.record("expected CANCEL, got \(cancel)")
                return
            }
            #expect(id == msgid)
            #expect(await handle.result() == .failure(.cancelled))
        }
    }

    // MARK: - Client streaming (outbound)

    @Test("client stream: 8 sends pass on the initial window, the 9th parks until a grant")
    func outboundCreditGating() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.importer, on: entity("box"), boxRequest(1))
            let (msgid, method, _) = try await client.readRequestFrame()
            #expect(method == "box.import")

            // The first 8 sends each reach the wire (initial window).
            try await withThrowingTaskGroup(of: Void.self) { group in
                let ninthParked = NIOLockedValueBox(false)
                let ninthOutcome = NIOLockedValueBox<StreamSendOutcome?>(nil)
                group.addTask {
                    for value in 0..<8 {
                        #expect(await handle.send(StreamElement(value: value)) == .sent)
                    }
                    // The 9th has no credit: it parks. It resolves only after a grant.
                    ninthParked.withLockedValue { $0 = true }
                    let outcome = await handle.send(StreamElement(value: 8))
                    ninthOutcome.withLockedValue { $0 = outcome }
                }
                // Read 8 outbound items with strict seq.
                for expected in UInt32(0)..<8 {
                    let envelope = try await readOutboundEnvelope(client)
                    guard case .item(let id, let seq, _) = envelope else {
                        Issue.record("expected item, got \(envelope)")
                        return
                    }
                    #expect(id == msgid)
                    #expect(seq == expected)
                }
                // The sender is now parked on the 9th (no 9th item on the wire yet).
                // Grant 8 → the 9th send completes and its item appears.
                try await client.channel.writeInbound(creditFrame(msgid: msgid, credits: 8))
                let ninth = try await readOutboundEnvelope(client)
                guard case .item(_, let seq, _) = ninth else {
                    Issue.record("expected the 9th item, got \(ninth)")
                    return
                }
                #expect(seq == 8)
                try await group.waitForAll()
                #expect(ninthParked.withLockedValue { $0 })
                #expect(ninthOutcome.withLockedValue { $0 } == .sent)
            }
            // Terminate so the call retires cleanly.
            try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 9))
            #expect(await handle.result() == .success(StreamSummary(count: 9)))
        }
    }

    @Test("client stream: the single sender-park slot is reused across successive parks")
    func outboundSenderParkSlotReuse() async throws {
        // The one `senderParked` slot must be cleanly cleared and reusable: a
        // sender that parks, is granted, and completes must be able to park again
        // on the next window exhaustion. This pins the single-slot lifecycle the
        // concurrent-send precondition relies on (one sender at a time).
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.importer, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // 16 sends: the window is 8, so this parks on the 9th and
                    // again on the 17th... here we exercise two park/grant cycles.
                    for value in 0..<16 {
                        #expect(await handle.send(StreamElement(value: value)) == .sent)
                    }
                }
                // Drain the first window (8 items).
                for expected in UInt32(0)..<8 {
                    let envelope = try await readOutboundEnvelope(client)
                    guard case .item(_, let seq, _) = envelope, seq == expected else {
                        Issue.record("expected item \(expected), got \(envelope)")
                        return
                    }
                }
                // The sender parks on the 9th; grant 8 → items 8..<16 flow, parking
                // again mid-way and releasing on the next grant.
                try await withDeadline {
                    while !handle._isSenderParked { await Task.yield() }
                }
                try await client.channel.writeInbound(creditFrame(msgid: msgid, credits: 8))
                for expected in UInt32(8)..<16 {
                    let envelope = try await readOutboundEnvelope(client)
                    guard case .item(_, let seq, _) = envelope, seq == expected else {
                        Issue.record("expected item \(expected), got \(envelope)")
                        return
                    }
                }
                try await group.waitForAll()
            }
            try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 16))
            #expect(await handle.result() == .success(StreamSummary(count: 16)))
        }
    }

    @Test("client stream: finish() sends END exactly once; later sends return .callEnded")
    func outboundFinishIdempotence() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.importer, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            #expect(await handle.send(StreamElement(value: 1)) == .sent)
            let item = try await readOutboundEnvelope(client)
            guard case .item = item else {
                Issue.record("expected item, got \(item)")
                return
            }

            await handle.finish()
            let end = try await readOutboundEnvelope(client)
            guard case .end(let id) = end else {
                Issue.record("expected END, got \(end)")
                return
            }
            #expect(id == msgid)

            // A second finish() is a no-op (no second END): sending after END
            // returns .callEnded.
            await handle.finish()
            #expect(await handle.send(StreamElement(value: 2)) == .callEnded)

            try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 1))
            #expect(await handle.result() == .success(StreamSummary(count: 1)))
        }
    }

    @Test("client stream: server STOP makes subsequent sends return .peerStopped")
    func outboundServerStop() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.importer, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            #expect(await handle.send(StreamElement(value: 1)) == .sent)
            _ = try await readOutboundEnvelope(client)

            // Server STOP (kind 5) for our request direction.
            try await client.channel.writeInbound(stopFrame(msgid: msgid))
            // Deterministic: keep sending until the stop is observed (the loop
            // processes the STOP frame; the next send reflects it).
            var outcome: StreamSendOutcome = .sent
            while outcome == .sent {
                outcome = await handle.send(StreamElement(value: 9))
                if outcome == .sent {
                    // Drain the item it produced so the channel does not back up.
                    _ = try await readOutboundEnvelope(client)
                }
            }
            #expect(outcome == .peerStopped)
            // Every subsequent send is also .peerStopped.
            #expect(await handle.send(StreamElement(value: 10)) == .peerStopped)

            try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 1))
            #expect(await handle.result() == .success(StreamSummary(count: 1)))
        }
    }

    // MARK: - STOP / CANCEL from the client

    @Test("server stream: stop() sends a graceful STOP frame; the call still runs to its terminal")
    func inboundClientStop() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.follow, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            await handle.stop()
            let stop = try await readOutboundEnvelope(client)
            guard case .stop(let id, let code) = stop else {
                Issue.record("expected STOP, got \(stop)")
                return
            }
            #expect(id == msgid)
            #expect(code == 0)

            // The call continues to its terminal (STOP is advisory).
            try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 0))
            for await _ in handle {}
            #expect(await handle.result() == .success(StreamSummary(count: 0)))
        }
    }

    @Test(
        "server stream: cancel() sends CANCEL, resolves .cancelled, and drops the server's code-7")
    func clientCancel() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.follow, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            await handle.cancel()
            // A CANCEL frame reaches the wire.
            let cancel = try await readOutboundEnvelope(client)
            guard case .cancel(let id) = cancel else {
                Issue.record("expected CANCEL, got \(cancel)")
                return
            }
            #expect(id == msgid)
            // Every surface resolves .cancelled locally.
            for await _ in handle {}
            #expect(await handle.result() == .failure(.cancelled))

            // The server's code-7 terminal for the (now retired) msgid drops —
            // it does not overwrite the cancelled terminal, and the connection
            // survives for a fresh unary call.
            let code7 = try MMEnvelope.response(
                msgid: msgid, error: MMErrorObject(code: 7, message: "cancelled"), result: nil
            ).encoded().get()
            try await client.channel.writeInbound(framed(code7))
            #expect(await handle.result() == .failure(.cancelled))

            async let reply = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(2))
            let (nextMsgid, _, _) = try await client.readRequestFrame()
            try await client.channel.writeInbound(
                responseFrame(msgid: nextMsgid, result: BoxResponse(value: 102)))
            #expect(await reply == .success(BoxResponse(value: 102)))
        }
    }

    // MARK: - Terminal exactly-once under races

    @Test("terminal is delivered to concurrent result() awaiters exactly once, same value")
    func terminalReplayToConcurrentAwaiters() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.follow, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            // Three concurrent awaiters plus one after resolution: all resolve
            // to the same value, each exactly once (a double-resume would trap).
            try await withThrowingTaskGroup(of: Result<StreamSummary, MMCallError>.self) { group in
                for _ in 0..<3 { group.addTask { await handle.result() } }
                // Let them register, then resolve.
                for _ in 0..<10 { await Task.yield() }
                try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 5))
                var results: [Result<StreamSummary, MMCallError>] = []
                for try await r in group { results.append(r) }
                // A late awaiter reads the cached value.
                results.append(await handle.result())
                #expect(results.allSatisfy { $0 == .success(StreamSummary(count: 5)) })
                #expect(results.count == 4)
            }
        }
    }

    @Test("connection death fails a live stream's terminal, exactly like a unary call")
    func deathFailsStreamTerminal() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0)))
        let connection = try await establish(harness).get()
        let client = ConnectedClient(
            loop: harness.loop, channel: harness.channel, connection: connection)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = await connection.run() }
            let handle = await connection.call(
                ClientTestMethods.follow, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()
            _ = msgid
            let terminal = NIOLockedValueBox<Result<StreamSummary, MMCallError>?>(nil)
            let sequenceEnded = NIOLockedValueBox(false)
            group.addTask {
                for await _ in handle {}
                sequenceEnded.withLockedValue { $0 = true }
            }
            group.addTask {
                let r = await handle.result()
                terminal.withLockedValue { $0 = r }
            }
            // The transport dies underneath the live stream.
            try await harness.channel.close().get()
            try await group.waitForAll()
            #expect(terminal.withLockedValue { $0 } == .failure(.connectionClosed))
            #expect(sequenceEnded.withLockedValue { $0 })
        }
    }

    @Test(
        "client stream: a send parked at zero credit on connection death returns .connectionClosed")
    func parkedSendOnDeathReportsConnectionClosed() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0)))
        let connection = try await establish(harness).get()
        let client = ConnectedClient(
            loop: harness.loop, channel: harness.channel, connection: connection)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = await connection.run() }
            let handle = await connection.call(
                ClientTestMethods.importer, on: entity("box"), boxRequest(1))
            let (_, _, _) = try await client.readRequestFrame()

            // Spend the whole initial window, then park the 9th send at zero
            // credit (the server never grants).
            let ninth = NIOLockedValueBox<StreamSendOutcome?>(nil)
            group.addTask {
                for value in 0..<8 {
                    #expect(await handle.send(StreamElement(value: value)) == .sent)
                }
                let outcome = await handle.send(StreamElement(value: 8))
                ninth.withLockedValue { $0 = outcome }
            }
            // Drain the 8 window items so the channel does not back up.
            for _ in UInt32(0)..<8 {
                _ = try await readOutboundEnvelope(client)
            }
            // The 9th send is now parked at zero credit.
            try await withDeadline {
                while !handle._isSenderParked { await Task.yield() }
            }
            // The transport dies under the parked sender: the outcome must be
            // .connectionClosed (the element was never sent), matching an
            // in-flight send and the termination matrix — NOT the graceful
            // .callEnded.
            try await harness.channel.close().get()
            try await group.waitForAll()
            #expect(ninth.withLockedValue { $0 } == .connectionClosed)
            // The terminal resolves the death too.
            #expect(await handle.result() == .failure(.connectionClosed))
        }
    }

    @Test("client stream: cancelling a send parked at zero credit resolves promptly, never spins")
    func cancelledParkedSendResolves() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.importer, on: entity("box"), boxRequest(1))
            let (_, _, _) = try await client.readRequestFrame()

            let outcome = NIOLockedValueBox<StreamSendOutcome?>(nil)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for value in 0..<8 {
                        _ = await handle.send(StreamElement(value: value))
                    }
                    // The 9th parks at zero credit; its task is cancelled below.
                    let last = await handle.send(StreamElement(value: 8))
                    outcome.withLockedValue { $0 = last }
                }
                // Drain the window so the sender reaches the parked 9th.
                for _ in UInt32(0)..<8 {
                    _ = try? await readOutboundEnvelope(client)
                }
                try? await withDeadline {
                    while !handle._isSenderParked { await Task.yield() }
                }
                // Cancel the sending task. Before the fix this hot-spun forever;
                // now the gate observes senderParkCancelled and returns
                // deterministically. The withDeadline in withRunningConnection's
                // body bounds a regression to a failed test, not a hang.
                group.cancelAll()
                await group.waitForAll()
            }
            // The parked send resolved (a spin would have hung the test) with a
            // graceful outcome, not left dangling.
            #expect(outcome.withLockedValue { $0 } == .callEnded)
        }
    }

    // MARK: - Live-unary lifecycle-frame violation policy

    @Test("stream END / credit / STOP for a live UNARY msgid is a connection-fatal violation")
    func lifecycleFrameOnUnaryMsgidIsFatal() async throws {
        // Each stream-lifecycle kind addressed to a live unary call's msgid is a
        // server protocol violation — the same policy as a stream item on a unary
        // msgid — so all four flavors are classified consistently.
        for makeFrame in [
            endFrame, { msgid in stopFrame(msgid: msgid) },
            { msgid in creditFrame(msgid: msgid, credits: 8) },
        ] {
            let harness = try await connectPipeline()
            try await harness.channel.writeInbound(
                helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0)))
            let connection = try await establish(harness).get()
            let client = ConnectedClient(
                loop: harness.loop, channel: harness.channel, connection: connection)

            let runResult = NIOLockedValueBox<Result<Void, MMClientError>?>(nil)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let r = await connection.run()
                    runResult.withLockedValue { $0 = r }
                }
                // A live unary call: its msgid is reserved/waiting, never a stream.
                let replyBox = NIOLockedValueBox<Result<BoxResponse, MMCallError>?>(nil)
                group.addTask {
                    let r = await connection.call(
                        ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
                    replyBox.withLockedValue { $0 = r }
                }
                let (unaryMsgid, _, _) = try await client.readRequestFrame()
                // A stream-lifecycle frame for that live unary msgid: fatal.
                try await client.channel.writeInbound(makeFrame(unaryMsgid))
                try await group.waitForAll()
                // The pending unary call fails on the connection death.
                #expect(replyBox.withLockedValue { $0 } == .failure(.connectionClosed))
            }
            guard case .some(.failure(.protocolViolation)) = runResult.withLockedValue({ $0 })
            else {
                Issue.record(
                    "expected run() protocolViolation, got \(String(describing: runResult.withLockedValue { $0 }))"
                )
                return
            }
            guard case .closed(.some(.protocolViolation)) = connection.state else {
                Issue.record("expected closed(protocolViolation), got \(connection.state)")
                return
            }
        }
    }

    // MARK: - Drop policy

    @Test("stream frames for unknown/retired msgids are dropped; the connection keeps serving")
    func unknownMsgidStreamFramesDropped() async throws {
        _ = try await withRunningConnection { client in
            // Every stream kind for a never-opened msgid: all dropped, non-fatal.
            let bogus: UInt32 = 4242
            try await client.channel.writeInbound(creditFrame(msgid: bogus, credits: 8))
            try await client.channel.writeInbound(itemFrame(msgid: bogus, seq: 0, value: 1))
            try await client.channel.writeInbound(endFrame(msgid: bogus))
            try await client.channel.writeInbound(stopFrame(msgid: bogus))
            // A stray inbound CANCEL for an unknown msgid: dropped, non-fatal.
            try await client.channel.writeInbound(
                framed(try MMEnvelope.cancel(msgid: bogus).encoded().get()))

            // The connection is unharmed: a unary call still round-trips.
            async let reply = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()
            try await client.channel.writeInbound(
                responseFrame(msgid: msgid, result: BoxResponse(value: 101)))
            #expect(await reply == .success(BoxResponse(value: 101)))
            #expect(client.connection.state == .connected)
        }
    }

    @Test("bidirectional: request elements go out, response elements come in, one shared terminal")
    func bidiEcho() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.pipe, on: entity("box"), boxRequest(1))
            let (msgid, method, _) = try await client.readRequestFrame()
            #expect(method == "box.pipe")

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Drain inbound response elements.
                group.addTask {
                    var got: [Int] = []
                    for await element in handle.inbound {
                        got.append(element.value)
                    }
                    #expect(got == [100, 200])
                }
                // Send two request elements, then finish.
                group.addTask {
                    #expect(await handle.outbound.send(StreamElement(value: 1)) == .sent)
                    #expect(await handle.outbound.send(StreamElement(value: 2)) == .sent)
                    await handle.outbound.finish()
                }
                // Read the two outbound items and the END.
                var outItems = 0
                var sawEnd = false
                while !sawEnd {
                    let envelope = try await readOutboundEnvelope(client)
                    switch envelope {
                        case .item: outItems += 1
                        case .end: sawEnd = true
                        default: Issue.record("unexpected outbound frame: \(envelope)")
                    }
                }
                #expect(outItems == 2)
                // Echo two response items then a terminal.
                try await client.channel.writeInbound(itemFrame(msgid: msgid, seq: 0, value: 100))
                try await client.channel.writeInbound(itemFrame(msgid: msgid, seq: 1, value: 200))
                try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 2))
                try await group.waitForAll()
            }
            // Both halves share the one terminal.
            #expect(await handle.inbound.result() == .success(StreamSummary(count: 2)))
            #expect(await handle.outbound.result() == .success(StreamSummary(count: 2)))
        }
    }

    @Test(
        "bidirectional: inbound.cancel() sends CANCEL, resolves BOTH halves .cancelled, drops the code-7"
    )
    func bidiInboundCancelResolvesBothHalves() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.pipe, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            // Cancel from the inbound half. A kind-6 CANCEL reaches the wire and
            // BOTH halves' shared terminal resolves .cancelled.
            await handle.inbound.cancel()
            let cancel = try await readOutboundEnvelope(client)
            guard case .cancel(let id) = cancel else {
                Issue.record("expected CANCEL, got \(cancel)")
                return
            }
            #expect(id == msgid)
            #expect(await handle.inbound.result() == .failure(.cancelled))
            #expect(await handle.outbound.result() == .failure(.cancelled))
            // A subsequent send on the outbound half is over.
            #expect(await handle.outbound.send(StreamElement(value: 1)) == .callEnded)

            // The server's code-7 terminal for the retired msgid drops without
            // disturbing the connection.
            let code7 = try MMEnvelope.response(
                msgid: msgid, error: MMErrorObject(code: 7, message: "cancelled"), result: nil
            ).encoded().get()
            try await client.channel.writeInbound(framed(code7))
            #expect(await handle.inbound.result() == .failure(.cancelled))

            // The connection survives for a fresh unary call.
            async let reply = client.connection.call(
                ClientTestMethods.boxGet, on: entity("box"), boxRequest(2))
            let (nextMsgid, _, _) = try await client.readRequestFrame()
            try await client.channel.writeInbound(
                responseFrame(msgid: nextMsgid, result: BoxResponse(value: 202)))
            #expect(await reply == .success(BoxResponse(value: 202)))
        }
    }

    @Test("bidirectional: outbound.cancel() and inbound.stop() reach the wire from their halves")
    func bidiOutboundCancelAndInboundStop() async throws {
        // outbound.cancel(): CANCEL out, both halves .cancelled.
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.pipe, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()
            await handle.outbound.cancel()
            let cancel = try await readOutboundEnvelope(client)
            guard case .cancel(let id) = cancel, id == msgid else {
                Issue.record("expected CANCEL for \(msgid), got \(cancel)")
                return
            }
            #expect(await handle.inbound.result() == .failure(.cancelled))
            #expect(await handle.outbound.result() == .failure(.cancelled))
        }
        // inbound.stop(): a graceful STOP out; the call still runs to its terminal.
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.pipe, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()
            await handle.inbound.stop()
            let stop = try await readOutboundEnvelope(client)
            guard case .stop(let id, let code) = stop, id == msgid, code == 0 else {
                Issue.record("expected STOP for \(msgid), got \(stop)")
                return
            }
            try await client.channel.writeInbound(summaryTerminalFrame(msgid: msgid, count: 0))
            #expect(await handle.inbound.result() == .success(StreamSummary(count: 0)))
        }
    }

    @Test(
        "client stream: outbound.cancel() sends CANCEL, resolves .cancelled, later send is .callEnded"
    )
    func outboundHandleCancel() async throws {
        _ = try await withRunningConnection { client in
            let handle = await client.connection.call(
                ClientTestMethods.importer, on: entity("box"), boxRequest(1))
            let (msgid, _, _) = try await client.readRequestFrame()

            await handle.cancel()
            let cancel = try await readOutboundEnvelope(client)
            guard case .cancel(let id) = cancel, id == msgid else {
                Issue.record("expected CANCEL for \(msgid), got \(cancel)")
                return
            }
            #expect(await handle.result() == .failure(.cancelled))
            #expect(await handle.send(StreamElement(value: 1)) == .callEnded)
        }
    }
}
