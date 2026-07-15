import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMClient

@Suite("Connection death: pending calls, state sequence, run() result")
struct DeathTests {
    @Test("closing with pending calls resumes every one exactly once with connectionClosed")
    func pendingCallsFailOnClose() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0))
        )
        let connection = try await establish(harness).get()
        let states = connection.stateUpdates()

        let (callResults, runResult) = try await withThrowingTaskGroup(
            of: Outcome.self,
            returning: ([Result<BoxResponse, MMCallError>], Result<Void, MMClientError>).self
        ) { group in
            group.addTask { .run(await connection.run()) }
            group.addTask {
                .call(
                    await connection.call(
                        ClientTestMethods.boxGet, on: entity("box"), boxRequest(1)))
            }
            group.addTask {
                .call(
                    await connection.call(
                        ClientTestMethods.boxGet, on: entity("box"), boxRequest(2)))
            }
            // Both requests are on the wire (callers parked on the map)...
            _ = try await connection_readFrame(harness)
            _ = try await connection_readFrame(harness)
            // ...then the transport dies underneath them.
            try await harness.channel.close().get()
            var calls: [Result<BoxResponse, MMCallError>] = []
            var run: Result<Void, MMClientError>?
            for try await outcome in group {
                switch outcome {
                    case .call(let result): calls.append(result)
                    case .run(let result): run = result
                }
            }
            return (calls, try #require(run))
        }

        // Every pending call resumed (exactly once — a double resume would
        // trap the CheckedContinuation) with the close failure.
        #expect(callResults.count == 2)
        for result in callResults {
            #expect(result == .failure(.connectionClosed))
        }
        // run() returned: a peer-initiated close is a clean end of stream.
        #expect(failure(runResult) == nil)
        // The state sequence yielded the terminal state and finished. The
        // drain is deadline-bounded: it terminates only because finish()
        // finishes the stream — exactly the behavior under test.
        let observed = try await withDeadline { () -> [ClientState] in
            var seen: [ClientState] = []
            for await state in states {
                seen.append(state)
            }
            return seen
        }
        #expect(observed.last == .closed(reason: nil))
        #expect(connection.state == .closed(reason: nil))
        // Calls after death fail fast.
        let late = await connection.call(ClientTestMethods.boxGet, on: entity("box"), boxRequest(3))
        #expect(late == .failure(.connectionClosed))
    }

    @Test("an undecodable envelope is a protocol violation: loop stops, pending calls fail")
    func envelopeGarbageIsFatal() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0))
        )
        let connection = try await establish(harness).get()

        let (callResult, runResult) = try await withThrowingTaskGroup(
            of: Outcome.self,
            returning: (Result<BoxResponse, MMCallError>, Result<Void, MMClientError>).self
        ) { group in
            group.addTask { .run(await connection.run()) }
            group.addTask {
                .call(
                    await connection.call(
                        ClientTestMethods.boxGet, on: entity("box"), boxRequest(1)))
            }
            _ = try await connection_readFrame(harness)
            // 0xc1 is the reserved MessagePack byte: never a valid envelope.
            try await harness.channel.writeInbound(framed([0xc1]))
            var call: Result<BoxResponse, MMCallError>?
            var run: Result<Void, MMClientError>?
            for try await outcome in group {
                switch outcome {
                    case .call(let result): call = result
                    case .run(let result): run = result
                }
            }
            return (try #require(call), try #require(run))
        }

        #expect(callResult == .failure(.connectionClosed))
        guard case .failure(.protocolViolation) = runResult else {
            Issue.record("expected protocolViolation, got \(runResult)")
            return
        }
        guard case .closed(.some(.protocolViolation)) = connection.state else {
            Issue.record("expected closed(protocolViolation), got \(connection.state)")
            return
        }
    }

    @Test("run() may only be started once")
    func secondRunIsRejected() async throws {
        let (second, first) = try await withRunningConnection { client in
            await client.connection.run()
        }
        #expect(failure(second) == .alreadyRunning)
        #expect(failure(first) == nil)
    }

    @Test("a state stream subscribed after death yields the terminal state and finishes")
    func lateSubscriberSeesTerminalState() async throws {
        let (_, _) = try await withRunningConnection { _ in }
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0))
        )
        let connection = try await establish(harness).get()
        await connection.close()
        // Deadline-bounded: the loop ends only if the late-subscriber path
        // finishes the stream, which is the behavior under test.
        let observed = try await withDeadline { () -> [ClientState] in
            var seen: [ClientState] = []
            for await state in connection.stateUpdates() {
                seen.append(state)
            }
            return seen
        }
        #expect(observed == [.closed(reason: nil)])
    }

    @Test("an oversized inbound frame is a transport death, not a clean close")
    func oversizedInboundFrameIsTransportDeath() async throws {
        // Distinct from the protocolViolation path: the frame decoder throws
        // before accumulation, the inbound stream fails, run() returns
        // .failure(.transport), and pending calls fail with .transport —
        // pinning finish()'s reason mapping for decoder-level deaths.
        let configuration = MMClientConfiguration(maxFrameLength: 64)
        let harness = try await connectPipeline(configuration: configuration)
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0))
        )
        let connection = try await establish(harness, configuration: configuration).get()

        let (callResult, runResult) = try await withThrowingTaskGroup(
            of: Outcome.self,
            returning: (Result<BoxResponse, MMCallError>, Result<Void, MMClientError>).self
        ) { group in
            group.addTask { .run(await connection.run()) }
            group.addTask {
                .call(
                    await connection.call(
                        ClientTestMethods.boxGet, on: entity("box"), boxRequest(1)))
            }
            _ = try await connection_readFrame(harness)
            // A length prefix claiming far more than the 64-byte cap; the
            // decoder rejects it before accumulating a single payload byte.
            // The decoder's throw fires errorCaught down the pipeline (which
            // is what fails the inbound stream — the behavior under test) and
            // the testing channel additionally surfaces it from writeInbound;
            // that harness-side rethrow is incidental, so tolerate it here
            // and pin the real effects (call, run(), state) below.
            var oversized = ByteBuffer()
            oversized.writeInteger(UInt32(1_000_000), endianness: .little)
            _ = try? await harness.channel.writeInbound(oversized)
            var call: Result<BoxResponse, MMCallError>?
            var run: Result<Void, MMClientError>?
            for try await outcome in group {
                switch outcome {
                    case .call(let result): call = result
                    case .run(let result): run = result
                }
            }
            return (try #require(call), try #require(run))
        }

        guard case .failure(.transport) = callResult else {
            Issue.record("expected the pending call to fail .transport, got \(callResult)")
            return
        }
        guard case .failure(.transport) = runResult else {
            Issue.record("expected run() to return .transport, got \(runResult)")
            return
        }
        guard case .closed(.some(.transport)) = connection.state else {
            Issue.record("expected closed(transport), got \(connection.state)")
            return
        }
    }

    @Test("close() before run() fails a call parked on the writer slot")
    func closeBeforeRunFailsParkedCall() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0))
        )
        let connection = try await establish(harness).get()
        let result = NIOLockedValueBox<Result<BoxResponse, MMCallError>?>(nil)
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    // run() never starts: the call reserves a msgid and parks
                    // in awaitWriter.
                    let reply = await connection.call(
                        ClientTestMethods.boxGet, on: entity("box"), boxRequest(1))
                    result.withLockedValue { $0 = reply }
                }
                // Bias the interleaving toward the parked state; either
                // ordering must resolve the call (never park forever), which
                // the surrounding deadline enforces.
                for _ in 0..<20 { await Task.yield() }
                await connection.close()
                await group.waitForAll()
            }
        }
        #expect(result.withLockedValue { $0 } == .failure(.connectionClosed))
        // A subsequent run() on the closed-before-run connection is a clean end.
        #expect(failure(await connection.run()) == nil)
    }
}

private enum Outcome: Sendable {
    case call(Result<BoxResponse, MMCallError>)
    case run(Result<Void, MMClientError>)
}

private func connection_readFrame(_ harness: PendingHarness) async throws -> ByteBuffer {
    try await withDeadline {
        try await harness.channel.waitForOutboundWrite(as: ByteBuffer.self)
    }
}
