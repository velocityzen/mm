import MMTestSupport
import MMWire
import NIOConcurrencyHelpers
import NIOCore
import Testing

@testable import MMClient

@Suite("Client hello exchange")
struct HelloTests {
    @Test("client hello is the first frame and its bytes are exact (defaults)")
    func clientHelloBytesDefault() async throws {
        let harness = try await connectPipeline()
        // Captured before any inbound was written: the client speaks first.
        // Frame: u32 LE length 15, magic "MM", version 1, fingerprint 0 (no
        // expectation), capabilities 0.
        let expected: [UInt8] = [
            0x0f, 0x00, 0x00, 0x00,
            0x4d, 0x4d,
            0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        #expect(allBytes(harness.clientHelloFrame) == expected)
        await discard(harness)
    }

    @Test("client hello carries the expected fingerprint and capabilities little-endian")
    func clientHelloBytesConfigured() async throws {
        let configuration = MMClientConfiguration(
            capabilities: 0x0000_0105,
            schema: MMClientSchema(
                contracts: [], serverFingerprint: 0x0123_4567_89AB_CDEF)
        )
        let harness = try await connectPipeline(configuration: configuration)
        let expected: [UInt8] = [
            0x0f, 0x00, 0x00, 0x00,
            0x4d, 0x4d,
            0x01,
            0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
            0x05, 0x01, 0x00, 0x00,
        ]
        #expect(allBytes(harness.clientHelloFrame) == expected)
        await discard(harness)
    }

    @Test("version negotiation is min-wins")
    func minWinsNegotiation() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 7, schemaFingerprint: 0, capabilities: 0))
        )
        let connection = try await establish(harness).get()
        #expect(connection.server.protocolVersion == MMWireInfo.protocolVersion)
        await connection.close()
    }

    @Test("negotiate: equal versions stay, capabilities intersect")
    func negotiateMath() {
        let info = try! MMClientConnection.negotiate(
            serverHello: MMHello(
                protocolVersion: 1,
                schemaFingerprint: 9,
                capabilities: 0b1100
            ),
            configuration: MMClientConfiguration(capabilities: 0b0110)
        ).get()
        #expect(info.protocolVersion == 1)
        #expect(info.fingerprint == 9)
        #expect(info.capabilities == 0b0100)
    }

    @Test("server hello with bad magic fails with badHello and closes")
    func badMagicIsBadHello() async throws {
        let harness = try await connectPipeline()
        var bogus = try MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0)
            .encode().get()
        bogus.setInteger(UInt8(ascii: "X"), at: 0)
        try await harness.channel.writeInbound(framed(bogus))
        let outcome = await establish(harness)
        #expect(failure(outcome) == .badHello)
        try await withDeadline { try await harness.channel.closeFuture.get() }
    }

    @Test("undecodable (truncated) server hello fails with badHello")
    func truncatedHelloIsBadHello() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(framed([0x4d, 0x4d, 0x01]))
        let outcome = await establish(harness)
        #expect(failure(outcome) == .badHello)
        try await withDeadline { try await harness.channel.closeFuture.get() }
    }

    @Test("connection closed before the server hello is a transport error, not badHello")
    func closedBeforeHelloIsTransport() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.close().get()
        let outcome = await establish(harness)
        #expect(
            failure(outcome)
                == .transport(description: "connection closed before server hello")
        )
    }

    @Test("fingerprint mismatch sets fingerprintMatched false and does NOT close")
    func fingerprintMismatchIsNotFatal() async throws {
        let configuration = MMClientConfiguration(
            schema: MMClientSchema(
                contracts: [], serverFingerprint: 0xAAAA))
        let harness = try await connectPipeline(configuration: configuration)
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0xBBBB, capabilities: 0))
        )
        let connection = try await establish(harness, configuration: configuration).get()
        #expect(connection.server.fingerprintMatched == false)
        #expect(connection.server.fingerprint == 0xBBBB)
        // Mismatch triggers discovery, never disconnection: still connected.
        #expect(harness.channel.isActive)
        #expect(connection.state == .connected)
        await connection.close()
    }

    @Test("matching fingerprint sets fingerprintMatched true")
    func fingerprintMatch() async throws {
        let configuration = MMClientConfiguration(
            schema: MMClientSchema(
                contracts: [], serverFingerprint: 0xAAAA))
        let harness = try await connectPipeline(configuration: configuration)
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0xAAAA, capabilities: 0))
        )
        let connection = try await establish(harness, configuration: configuration).get()
        #expect(connection.server.fingerprintMatched == true)
        await connection.close()
    }

    @Test("no expected schema means no comparison: fingerprintMatched is nil")
    func fingerprintNotCompared() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 1, schemaFingerprint: 0xBBBB, capabilities: 0))
        )
        let connection = try await establish(harness).get()
        #expect(connection.server.fingerprintMatched == nil)
        #expect(connection.server.fingerprint == 0xBBBB)
        await connection.close()
    }

    @Test("a server that never sends its hello is reaped by the hello deadline")
    func helloTimeoutBoundsEstablish() async throws {
        // The peer accepts the connection but never writes: with no bound
        // this would park connect() forever. The default helloTimeout closes
        // the channel, failing establish with the closed-before-hello error.
        let configuration = MMClientConfiguration(helloTimeout: .milliseconds(100))
        let harness = try await connectPipeline(configuration: configuration)
        let result = NIOLockedValueBox<Result<MMClientConnection, MMClientError>?>(nil)
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let outcome = await establish(harness, configuration: configuration)
                    result.withLockedValue { $0 = outcome }
                }
                group.addTask {
                    // Pump fake time until establish resolves; the deadline is
                    // scheduled on the channel loop inside establish, so keep
                    // advancing (bounded by the surrounding withDeadline).
                    while result.withLockedValue({ $0 }) == nil {
                        await harness.loop.advanceTime(by: .milliseconds(200))
                        await Task.yield()
                    }
                }
                await group.waitForAll()
            }
        }
        let outcome = try #require(result.withLockedValue { $0 })
        #expect(
            failure(outcome)
                == .transport(description: "connection closed before server hello")
        )
        try await withDeadline { try await harness.channel.closeFuture.get() }
    }

    @Test("cancelling connect() while awaiting the hello closes the channel and returns")
    func cancellationBreaksHelloAwait() async throws {
        // EventLoopFuture.get() is not cancellation-aware on its own: the
        // cancellation handler must close the channel so the hello promise
        // fails and establish returns instead of hanging its task group.
        let harness = try await connectPipeline()
        let result = NIOLockedValueBox<Result<MMClientConnection, MMClientError>?>(nil)
        try await withDeadline {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let outcome = await establish(harness)
                    result.withLockedValue { $0 = outcome }
                }
                // Let establish reach the suspended hello await, then cancel.
                for _ in 0..<20 { await Task.yield() }
                group.cancelAll()
                await group.waitForAll()
            }
        }
        let outcome = try #require(result.withLockedValue { $0 })
        #expect(
            failure(outcome)
                == .transport(description: "connection closed before server hello")
        )
        try await withDeadline { try await harness.channel.closeFuture.get() }
    }

    @Test("server advertising version 0 is versionUnsupported")
    func versionZeroUnsupported() async throws {
        let harness = try await connectPipeline()
        try await harness.channel.writeInbound(
            helloFrame(MMHello(protocolVersion: 0, schemaFingerprint: 0, capabilities: 0))
        )
        let outcome = await establish(harness)
        #expect(failure(outcome) == .versionUnsupported(serverVersion: 0))
    }
}
