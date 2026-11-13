import Logging
import MMSchema
import MMTestSupport
import MMWire
import Metrics
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMServer

/// A recording ``WriterFunnel``: captures every envelope the runtime sends so
/// the tests can assert terminals, items, and grants without a real channel.
final class RecordingFunnel: WriterFunnel {
    private let sent = NIOLockedValueBox<[MMEnvelope]>([])
    func send(_ envelope: MMEnvelope) async -> Result<Void, ServerError> {
        self.sent.withLockedValue { $0.append(envelope) }
        return .success(())
    }
    var envelopes: [MMEnvelope] { self.sent.withLockedValue { $0 } }
    /// The error code of the terminal for `msgid`, if a terminal was sent.
    func terminalCode(msgid: UInt32) -> Int?? {
        for envelope in self.envelopes {
            if case .response(let id, let error, _) = envelope, id == msgid {
                return Optional(error?.code)
            }
        }
        return nil
    }
    var items: [(msgid: UInt32, seq: UInt32)] {
        self.envelopes.compactMap {
            if case .item(let id, let seq, _) = $0 { return (id, seq) } else { return nil }
        }
    }
}

// MARK: - Fixtures

private struct StreamReq: Codable, Sendable {
    var entity: EntityName
    enum CodingKeys: Int, CodingKey { case entity = 0 }
}

private struct Ack: Codable, Sendable {
    var count: Int
    enum CodingKeys: Int, CodingKey { case count = 0 }
}

private func openParams(_ raw: String = "e") -> ByteBuffer {
    try! MMPackEncoder().encode(StreamReq(entity: entity(raw))).get()
}

private func makeRuntime(
    funnel: RecordingFunnel,
    maxStreams: Int = 8,
    factory: CapturingMetricsFactory = CapturingMetricsFactory()
) -> StreamRuntime {
    StreamRuntime(
        writer: funnel,
        metrics: MMStreamMetrics(factory: factory),
        maxConcurrentStreams: maxStreams,
        logger: Logger(label: "test")
    )
}

private func runInGroup(_ plan: StreamRuntime.OpenPlan) async {
    await withDiscardingTaskGroup { group in
        group.addTask { await plan.run() }
    }
}

extension StreamRuntime {
    /// Test convenience: `openStream` with the shared dropped-frames counter,
    /// so the many call sites stay terse.
    func openStream(
        msgid: UInt32,
        route: Route,
        params: ByteBuffer,
        context: MMContext
    ) async -> OpenPlan? {
        await self.openStream(
            msgid: msgid, route: route, params: params, context: context,
            framesDropped: droppedCounter()
        )
    }
}

@Suite("Stream runtime: opens, terminals, caps, termination")
struct StreamRuntimeTests {
    // MARK: - Server stream: elements then terminal

    @Test("a server-stream handler's items and terminal reach the writer, seq from 0")
    func serverStreamHappyPath() async {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let route = Handle(
            ServerStreamMethod<StreamReq, Int, Ack>(name: "s.watch", access: .read)
        ) { _, sink, _ in
            for value in 0..<3 {
                #expect(await sink.send(value) == .sent)
            }
            return .success(Ack(count: 3))
        }
        let context = makeContext()
        guard
            let plan = await runtime.openStream(
                msgid: 10, route: route, params: openParams(), context: context
            )
        else {
            Issue.record("open should be accepted")
            return
        }
        await runInGroup(plan)

        #expect(funnel.items.filter { $0.msgid == 10 }.map(\.seq) == [0, 1, 2])
        // Graceful terminal: nil error.
        #expect(funnel.terminalCode(msgid: 10) == .some(.none))
    }

    @Test("a server stream past the initial window parks until a routed credit frame")
    func responseCreditFlowThroughRuntime() async throws {
        let funnel = RecordingFunnel()
        let factory = CapturingMetricsFactory()
        let runtime = makeRuntime(funnel: funnel, factory: factory)
        let sentNine = AsyncRelease()
        let route = Handle(
            ServerStreamMethod<StreamReq, Int, Ack>(name: "s.push", access: .read)
        ) { _, sink, _ in
            // 8 fit the initial window; the 9th parks until a client grant.
            for value in 0..<9 {
                #expect(await sink.send(value) == .sent)
            }
            await sentNine.release()
            return .success(Ack(count: 9))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 60, route: route, params: openParams(), context: makeContext()
            )
        else {
            Issue.record("open accepted")
            return
        }
        try await withDeadline {
            await withDiscardingTaskGroup { group in
                group.addTask { await plan.run() }
                group.addTask {
                    // The 9th send stalls only after the window's 8 were written.
                    await factory.reached(StreamCounter.creditStalls, 1)
                    #expect(funnel.items.filter { $0.msgid == 60 }.count == 8)
                    // Grant 1 credit: the parked 9th send proceeds.
                    await runtime.route(
                        .credit(msgid: 60, credits: 1), framesDropped: droppedCounter())
                    await sentNine.wait()
                }
            }
        }
        #expect(funnel.items.filter { $0.msgid == 60 }.map(\.seq) == Array(UInt32(0)..<9))
        #expect(funnel.terminalCode(msgid: 60) == .some(.none))
    }

    // MARK: - Cap enforcement

    @Test("an open past the stream cap gets an immediate code-4 terminal and no state")
    func streamCapEnforced() async {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel, maxStreams: 1)
        // A handler that blocks until we let it finish, to hold the one slot.
        let release = AsyncRelease()
        let route = Handle(
            ServerStreamMethod<StreamReq, Int, Ack>(name: "s.hold", access: .read)
        ) { _, _, _ in
            await release.wait()
            return .success(Ack(count: 0))
        }
        let context = makeContext()

        guard
            let plan1 = await runtime.openStream(
                msgid: 1, route: route, params: openParams(), context: context
            )
        else {
            Issue.record("first open should be accepted")
            return
        }
        // Second open while the first holds the only slot: rejected with code-4.
        let plan2 = await runtime.openStream(
            msgid: 2, route: route, params: openParams(), context: context
        )
        #expect(plan2 == nil)
        #expect(funnel.terminalCode(msgid: 2) == .some(.some(MMErrorCode.tooManyInFlight.code)))

        // Let the first finish; its terminal is graceful.
        await withDiscardingTaskGroup { group in
            group.addTask { await plan1.run() }
            group.addTask { await release.release() }
        }
        #expect(funnel.terminalCode(msgid: 1) == .some(.none))
    }

    // MARK: - Malformed open

    @Test("an open whose params fail to decode gets a malformed-params terminal, no stream")
    func malformedOpen() async {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let route = Handle(
            ServerStreamMethod<StreamReq, Int, Ack>(name: "s.watch", access: .read)
        ) { _, _, _ in .success(Ack(count: 0)) }
        // A params slice that is not a StreamReq map.
        let badParams = try! MMPackEncoder().encode([1, 2, 3]).get()
        let plan = await runtime.openStream(
            msgid: 5, route: route, params: badParams, context: makeContext()
        )
        #expect(plan == nil)
        #expect(funnel.terminalCode(msgid: 5) == .some(.some(MMErrorCode.malformedParams.code)))
    }

    // MARK: - Client END (graceful request-stream finish)

    @Test("client items then END: the handler sees each element then a clean end")
    func clientEndGraceful() async {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let route = Handle(
            ClientStreamMethod<StreamReq, Int, Ack>(name: "c.count", access: .write)
        ) { _, elements, _ in
            var sum = 0
            for await value in elements { sum += value }  // normal end = client END
            return .success(Ack(count: sum))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 70, route: route, params: openParams(), context: makeContext()
            )
        else {
            Issue.record("open accepted")
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
            group.addTask {
                for (seq, value) in [(UInt32(0), 3), (1, 4), (2, 5)] {
                    let item = try! MMPackEncoder().encode(value).get()
                    await runtime.route(
                        .item(msgid: 70, seq: seq, item: item), framesDropped: droppedCounter()
                    )
                }
                await runtime.route(.end(msgid: 70), framesDropped: droppedCounter())
            }
        }
        // Graceful terminal carrying the summed Ack.
        #expect(funnel.terminalCode(msgid: 70) == .some(.none))
        // Decode the terminal result to confirm the sum (3+4+5 = 12).
        let terminal = funnel.envelopes.last {
            if case .response(70, _, _) = $0 { return true } else { return false }
        }
        if case .response(_, _, .some(let result)) = terminal {
            let ack = try! MMPackDecoder().decode(Ack.self, from: result).get()
            #expect(ack.count == 12)
        } else {
            Issue.record("expected a result-bearing terminal")
        }
    }

    // MARK: - Inbound watermark credit grant (gap coverage)

    @Test("a request stream whose window fills then drains emits a watermark credit grant")
    func inboundWatermarkGrant() async throws {
        let funnel = RecordingFunnel()
        let factory = CapturingMetricsFactory()
        let runtime = makeRuntime(funnel: funnel, factory: factory)
        let release = AsyncRelease()
        let route = Handle(
            ClientStreamMethod<StreamReq, Int, Ack>(name: "c.grant", access: .write)
        ) { _, elements, _ in
            // Park before consuming so the caller can fill the window to the
            // high watermark first; then drain everything.
            await release.wait()
            var count = 0
            for await _ in elements { count += 1 }
            return .success(Ack(count: count))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 71, route: route, params: openParams(), context: makeContext()
            )
        else {
            Issue.record("open accepted")
            return
        }
        try await withDeadline {
            await withDiscardingTaskGroup { group in
                group.addTask { await plan.run() }
                group.addTask {
                    // Fill the initial window (8 items) while the handler is parked.
                    for seq in UInt32(0)..<8 {
                        let item = try! MMPackEncoder().encode(Int(seq)).get()
                        await runtime.route(
                            .item(msgid: 71, seq: seq, item: item), framesDropped: droppedCounter()
                        )
                    }
                    // Release: the handler drains all 8; the source grants credit
                    // back as it crosses the low watermark.
                    await release.release()
                    // End only once the pump has taken a grant to write.
                    await factory.reached(StreamCounter.creditGrantsOut, 1)
                    // End the request stream so the handler returns.
                    await runtime.route(.end(msgid: 71), framesDropped: droppedCounter())
                }
            }
        }
        // At least one additive credit grant reached the writer, and no grant
        // ever exceeds the initial window.
        let grants: [UInt32] = funnel.envelopes.compactMap {
            if case .credit(71, let credits) = $0 { return credits } else { return nil }
        }
        #expect(!grants.isEmpty)
        #expect(grants.allSatisfy { $0 > 0 && $0 <= MMStreamFlowControl.initialWindow })
        // The graceful terminal carries the full consumed count.
        #expect(funnel.terminalCode(msgid: 71) == .some(.none))
    }

    // MARK: - Client STOP on a response stream → .peerStopped

    @Test("client STOP on a server stream surfaces as .peerStopped to the handler")
    func clientStopPeerStopped() async throws {
        let funnel = RecordingFunnel()
        let factory = CapturingMetricsFactory()
        let runtime = makeRuntime(funnel: funnel, factory: factory)
        let sawStop = AsyncFlag()
        let route = Handle(
            ServerStreamMethod<StreamReq, Int, Ack>(name: "s.tick", access: .read)
        ) { _, sink, _ in
            var sent = 0
            while true {
                let outcome = await sink.send(sent)
                if outcome == .peerStopped {
                    await sawStop.set()
                    break
                }
                if outcome == .callEnded { break }
                sent += 1
            }
            return .success(Ack(count: sent))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 80, route: route, params: openParams(), context: makeContext()
            )
        else {
            Issue.record("open accepted")
            return
        }
        try await withDeadline {
            await withDiscardingTaskGroup { group in
                group.addTask { await plan.run() }
                group.addTask {
                    // STOP the handler while it is parked past its window.
                    await factory.reached(StreamCounter.creditStalls, 1)
                    await runtime.route(.stop(msgid: 80, code: 0), framesDropped: droppedCounter())
                    await sawStop.wait()
                }
            }
        }
        #expect(funnel.terminalCode(msgid: 80) == .some(.none))
    }

    // MARK: - Client CANCEL → code-7

    @Test("client CANCEL cancels the handler and the runtime sends a code-7 terminal")
    func cancelSendsCodeSeven() async {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let started = AsyncRelease()
        let route = Handle(
            ClientStreamMethod<StreamReq, Int, Ack>(name: "c.import", access: .write)
        ) { _, elements, _ in
            await started.release()
            // Consume until cancelled/ended; a cooperative point every loop.
            var count = 0
            for await _ in elements {
                count += 1
                if Task.isCancelled { break }
            }
            return .success(Ack(count: count))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 20, route: route, params: openParams(), context: makeContext()
            )
        else {
            Issue.record("open accepted")
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
            group.addTask {
                await started.wait()
                // Now CANCEL: runtime cancels the handler and sends code-7.
                await runtime.route(.cancel(msgid: 20), framesDropped: droppedCounter())
            }
        }
        // The runtime's code-7 terminal is the one on the wire; the handler's
        // own (later, discarded) terminal never reaches the writer.
        #expect(funnel.terminalCode(msgid: 20) == .some(.some(MMErrorCode.cancelled.code)))
        let terminals = funnel.envelopes.filter {
            if case .response(20, _, _) = $0 { return true } else { return false }
        }
        #expect(terminals.count == 1)  // exactly one terminal
    }

    // MARK: - Seq-gap violation → code-6

    @Test("an out-of-order request item yields a code-6 terminal exactly once")
    func seqGapCodeSix() async {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let route = Handle(
            ClientStreamMethod<StreamReq, Int, Ack>(name: "c.import", access: .write)
        ) { _, elements, _ in
            var count = 0
            for await _ in elements { count += 1 }
            return .success(Ack(count: count))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 30, route: route, params: openParams(), context: makeContext()
            )
        else {
            Issue.record("open accepted")
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
            group.addTask {
                let item = try! MMPackEncoder().encode(1).get()
                // seq 0 fine, then a gap to seq 2 → violation.
                await runtime.route(
                    .item(msgid: 30, seq: 0, item: item), framesDropped: droppedCounter())
                await runtime.route(
                    .item(msgid: 30, seq: 2, item: item), framesDropped: droppedCounter())
            }
        }
        #expect(funnel.terminalCode(msgid: 30) == .some(.some(MMErrorCode.streamViolation.code)))
        let terminals = funnel.envelopes.filter {
            if case .response(30, _, _) = $0 { return true } else { return false }
        }
        #expect(terminals.count == 1)
    }

    // MARK: - Decode-failure violation → code-6, exactly once

    @Test(
        "a well-framed request item whose payload fails to decode yields exactly one code-6 terminal"
    )
    func decodeFailureSingleTerminal() async {
        // Regression: the `.deliver` decision leaves the entry live to advance
        // seq/credit. When the element fails to decode, the runtime must retire
        // the entry before sending code-6 — otherwise the handler's graceful
        // return would fire a SECOND terminal for the same msgid.
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let route = Handle(
            ClientStreamMethod<StreamReq, Int, Ack>(name: "c.import", access: .write)
        ) { _, elements, _ in
            var count = 0
            for await _ in elements { count += 1 }
            return .success(Ack(count: count))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 31, route: route, params: openParams(), context: makeContext()
            )
        else {
            Issue.record("open accepted")
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
            group.addTask {
                // A well-framed MessagePack string at seq 0: passes seq/credit,
                // but fails to decode as the declared Int element type.
                let badItem = try! MMPackEncoder().encode("not an int").get()
                await runtime.route(
                    .item(msgid: 31, seq: 0, item: badItem), framesDropped: droppedCounter()
                )
            }
        }
        // Exactly one terminal, and it is the code-6 violation.
        #expect(funnel.terminalCode(msgid: 31) == .some(.some(MMErrorCode.streamViolation.code)))
        let terminals = funnel.envelopes.filter {
            if case .response(31, _, _) = $0 { return true } else { return false }
        }
        #expect(terminals.count == 1)
    }

    // MARK: - Reused stream msgid → no second terminal

    @Test("a second open on a live stream msgid is dropped, never a second terminal")
    func reusedStreamMsgidNoDoubleTerminal() async {
        // Regression: a reopen on a msgid whose original stream is still live
        // must be dropped-and-counted — the original call still owns the single
        // terminal for that msgid. A rejection terminal here would put two
        // terminals on the wire for one msgid.
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let release = AsyncRelease()
        let route = Handle(
            ServerStreamMethod<StreamReq, Int, Ack>(name: "s.hold", access: .read)
        ) { _, _, _ in
            await release.wait()
            return .success(Ack(count: 0))
        }
        let context = makeContext()
        guard
            let plan = await runtime.openStream(
                msgid: 7, route: route, params: openParams(), context: context
            )
        else {
            Issue.record("first open accepted")
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
            group.addTask {
                // Reopen on the same live msgid: no plan, no terminal.
                let plan2 = await runtime.openStream(
                    msgid: 7, route: route, params: openParams(), context: context
                )
                #expect(plan2 == nil)
                // The original stream is still live and holds its (only) terminal.
                await release.release()
            }
        }
        // Exactly one terminal on the wire for msgid 7 — the original stream's
        // graceful terminal. The reopen produced none.
        let terminals = funnel.envelopes.filter {
            if case .response(7, _, _) = $0 { return true } else { return false }
        }
        #expect(terminals.count == 1)
        #expect(funnel.terminalCode(msgid: 7) == .some(.none))
    }

    // MARK: - Msgid reused after its terminal

    @Test("a msgid reused after a CANCEL is not retired by the cancelled handler")
    func cancelledHandlerLeavesReusedMsgidAlone() async {
        // The code-7 terminal answers the first call, so the client may reuse
        // its msgid at once, while the cancelled handler is still running.
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let firstStarted = AsyncRelease()
        let firstRelease = AsyncRelease()
        let secondStarted = AsyncRelease()
        let secondRelease = AsyncRelease()
        let first = Handle(
            ServerStreamMethod<StreamReq, Int, Ack>(name: "s.first", access: .read)
        ) { _, _, _ in
            await firstStarted.release()
            // Not cancellation-aware: it returns after the reuse below.
            await firstRelease.wait()
            return .success(Ack(count: 1))
        }
        let second = Handle(
            ServerStreamMethod<StreamReq, Int, Ack>(name: "s.second", access: .read)
        ) { _, _, _ in
            await secondStarted.release()
            await secondRelease.wait()
            return .success(Ack(count: 2))
        }
        let context = makeContext()
        guard
            let firstPlan = await runtime.openStream(
                msgid: 9, route: first, params: openParams(), context: context
            )
        else {
            Issue.record("first open accepted")
            return
        }
        let firstRun = Task { await firstPlan.run() }
        await firstStarted.wait()
        await runtime.route(.cancel(msgid: 9), framesDropped: droppedCounter())

        guard
            let secondPlan = await runtime.openStream(
                msgid: 9, route: second, params: openParams(), context: context
            )
        else {
            Issue.record("a msgid whose call was answered can be reused")
            await firstRelease.release()
            await firstRun.value
            return
        }
        let secondRun = Task { await secondPlan.run() }
        await secondStarted.wait()
        await firstRelease.release()
        await firstRun.value
        await secondRelease.release()
        await secondRun.value

        // One terminal per call: the first call's code-7, then the second
        // call's own result.
        let terminals: [(error: MMError?, result: ByteBuffer?)] = funnel.envelopes.compactMap {
            if case .response(9, let error, let result) = $0 { return (error, result) }
            return nil
        }
        #expect(terminals.count == 2)
        #expect(terminals.first?.error?.code == MMErrorCode.cancelled.code)
        let secondResult = terminals.dropFirst().first?.result.flatMap {
            try? MMPackDecoder().decode(Ack.self, from: $0).get()
        }
        #expect(secondResult?.count == 2)
    }

    // MARK: - Unary-msgid guard

    @Test("a stream frame on a live unary msgid is a code-6 and suppresses the unary terminal")
    func unaryMisaddressSuppresses() async throws {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let call = try #require(runtime.registerUnary(msgid: 40))
        let item = try! MMPackEncoder().encode(1).get()
        await runtime.route(.item(msgid: 40, seq: 0, item: item), framesDropped: droppedCounter())
        // Code-6 sent.
        #expect(funnel.terminalCode(msgid: 40) == .some(.some(MMErrorCode.streamViolation.code)))
        // The unary handler's own terminal is now suppressed.
        #expect(!runtime.shouldSendUnaryTerminal(msgid: 40, call: call))
    }

    @Test("more stream frames on a live unary msgid still send one code-6")
    func unaryMisaddressAnswersOnce() async throws {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let call = try #require(runtime.registerUnary(msgid: 41))
        let item = try! MMPackEncoder().encode(1).get()
        await runtime.route(.end(msgid: 41), framesDropped: droppedCounter())
        await runtime.route(.end(msgid: 41), framesDropped: droppedCounter())
        await runtime.route(.item(msgid: 41, seq: 0, item: item), framesDropped: droppedCounter())
        let terminals = funnel.envelopes.filter {
            if case .response(41, _, _) = $0 { return true } else { return false }
        }
        #expect(terminals.count == 1)
        #expect(funnel.terminalCode(msgid: 41) == .some(.some(MMErrorCode.streamViolation.code)))
        // The code-6 answered the call: the client may reuse msgid 41 before the
        // first handler returns, and the two calls keep apart.
        let reuse = try #require(runtime.registerUnary(msgid: 41))
        #expect(!runtime.shouldSendUnaryTerminal(msgid: 41, call: call))
        #expect(runtime.shouldSendUnaryTerminal(msgid: 41, call: reuse))
    }

    @Test("stream frames for unknown msgids drop and count, never terminate")
    func unknownMsgidDrops() async {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let counter = droppedCounter()
        let item = try! MMPackEncoder().encode(1).get()
        await runtime.route(.item(msgid: 999, seq: 0, item: item), framesDropped: counter)
        await runtime.route(.credit(msgid: 999, credits: 4), framesDropped: counter)
        await runtime.route(.end(msgid: 999), framesDropped: counter)
        await runtime.route(.stop(msgid: 999, code: 0), framesDropped: counter)
        await runtime.route(.cancel(msgid: 999), framesDropped: counter)
        #expect(funnel.envelopes.isEmpty)  // no terminals, no items
    }

    // MARK: - Graceful drain

    @Test("drain cancels handlers and flushes their terminals before close")
    func drainFlushesTerminals() async {
        let funnel = RecordingFunnel()
        let runtime = makeRuntime(funnel: funnel)
        let started = AsyncRelease()
        let route = Handle(
            ServerStreamMethod<StreamReq, Int, Ack>(name: "s.follow", access: .read)
        ) { _, sink, _ in
            await started.release()
            // Stream forever until cancelled/ended.
            while true {
                if Task.isCancelled { break }
                if await sink.send(0) == .callEnded { break }
            }
            return .success(Ack(count: 0))
        }
        guard
            let plan = await runtime.openStream(
                msgid: 50, route: route, params: openParams(), context: makeContext()
            )
        else {
            Issue.record("open accepted")
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await plan.run() }
            group.addTask {
                await started.wait()
                runtime.drain()  // graceful shutdown
            }
        }
        // The handler unwound and its terminal flushed (graceful, nil error).
        #expect(funnel.terminalCode(msgid: 50) == .some(.none))
    }
}

// MARK: - Cancel-race latch (ConcreteStreamControl)

@Suite("ConcreteStreamControl cancel latch")
struct ConcreteStreamControlCancelTests {
    @Test("a cancel that arrives before attachCancel is latched and fired on attach")
    func cancelBeforeAttachIsLatched() {
        // Regression: openStream registers the entry BEFORE the child task
        // installs the cancel hook. A CANCEL routed in that window calls
        // cancelHandler() while the hook is nil; without a latch the cancel is
        // lost. The latch must fire the hook the moment attachCancel installs it.
        let control = ConcreteStreamControl<NeverElement, NeverElement>(
            requestSource: nil, responseSink: nil
        )
        let fired = NIOLockedValueBox(0)
        // CANCEL races ahead of attachCancel: no hook yet, latch it.
        control.cancelHandler()
        #expect(fired.withLockedValue { $0 } == 0)  // nothing fired yet
        // The child task now installs the hook: the latched cancel fires at once.
        control.attachCancel { fired.withLockedValue { $0 += 1 } }
        #expect(fired.withLockedValue { $0 } == 1)
    }

    @Test("the normal ordering (attach then cancel) fires exactly once, no double-fire")
    func attachThenCancelFiresOnce() {
        let control = ConcreteStreamControl<NeverElement, NeverElement>(
            requestSource: nil, responseSink: nil
        )
        let fired = NIOLockedValueBox(0)
        control.attachCancel { fired.withLockedValue { $0 += 1 } }
        #expect(fired.withLockedValue { $0 } == 0)  // not fired on attach
        control.cancelHandler()
        #expect(fired.withLockedValue { $0 } == 1)
    }
}

// MARK: - Test helpers

/// A one-shot release gate: `wait()` suspends until `release()`.
actor AsyncRelease {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func release() {
        guard !self.released else { return }
        self.released = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        if self.released { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }
}

/// A one-shot flag: `set()` marks it, `wait()` suspends until set. Same shape as
/// ``AsyncRelease`` with intention-revealing names for the STOP tests.
actor AsyncFlag {
    private var flagged = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func set() {
        guard !self.flagged else { return }
        self.flagged = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        if self.flagged { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }
}

private func droppedCounter() -> Counter {
    Counter(label: "mm_test_stream_frames_dropped_total")
}
