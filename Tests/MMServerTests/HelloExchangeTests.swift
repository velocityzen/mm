import MMTestSupport
import MMWire
import Metrics
import NIOCore
import NIOEmbedded
import Testing

@testable import MMServer

@Suite("Hello exchange handler")
struct HelloExchangeTests {
    private static func makeHello() -> MMHello {
        MMHello(
            protocolVersion: 1,
            schemaFingerprint: 0x0123_4567_89AB_CDEF,
            capabilities: 0
        )
    }

    private func makeConnectedChannel(
        withFrameEncoder: Bool = false,
        hello: MMHello = Self.makeHello()
    ) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        if withFrameEncoder {
            try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(MMFrameEncoder()))
        }
        try channel.pipeline.syncOperations.addHandler(
            ServerHelloHandler(
                serverHello: hello,
                protocolViolations: Counter(label: "test_protocol_violations")
            )
        )
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/mm-test"), promise: nil)
        channel.embeddedEventLoop.run()
        return channel
    }

    @Test("server hello is written at activation, framed, byte-exact")
    func serverHelloBytesExact() throws {
        let channel = try makeConnectedChannel(withFrameEncoder: true)
        let frame = try channel.readOutbound(as: ByteBuffer.self)
        let bytes = frame.map { Array($0.readableBytesView) }
        #expect(
            bytes == [
                0x0F, 0x00, 0x00, 0x00,  // u32 LE length = 15, payload only
                0x4D, 0x4D,  // magic "MM"
                0x01,  // protocol version 1
                0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,  // fingerprint LE
                0x00, 0x00, 0x00, 0x00,  // capabilities LE
            ]
        )
        // Exactly one frame — the hello is written once even though both
        // handlerAdded and channelActive can observe an active channel.
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
        _ = try? channel.finish()
    }

    @Test("bad magic in the first frame closes the connection, nothing forwarded")
    func badMagicCloses() throws {
        let channel = try makeConnectedChannel()
        var garbage = ByteBuffer()
        garbage.writeBytes([UInt8](repeating: 0x58, count: MMHello.encodedByteCount))  // "XX…"
        try channel.writeInbound(garbage)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive == false)
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
    }

    @Test("an undecodable (truncated) hello closes the connection")
    func truncatedHelloCloses() throws {
        let channel = try makeConnectedChannel()
        var short = ByteBuffer()
        short.writeBytes([0x4D, 0x4D, 0x01])  // right magic, truncated body
        try channel.writeInbound(short)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive == false)
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
    }

    @Test("a valid hello is forwarded, then the handler becomes a pass-through")
    func validHelloForwarded() throws {
        let channel = try makeConnectedChannel()
        var helloFrame = ByteBuffer()
        MMHello(protocolVersion: 1, schemaFingerprint: 42, capabilities: 7)
            .encode(into: &helloFrame)
        try channel.writeInbound(helloFrame)
        let forwarded = try channel.readInbound(as: ByteBuffer.self)
        #expect(forwarded == helloFrame)
        #expect(channel.isActive)

        var next = ByteBuffer()
        next.writeBytes([0x01, 0x02, 0x03])  // arbitrary post-hello frame
        try channel.writeInbound(next)
        #expect(try channel.readInbound(as: ByteBuffer.self) == next)
        #expect(channel.isActive)
        _ = try? channel.finish()
    }

    @Test("version negotiation is min-wins in both directions")
    func versionNegotiationMinWins() {
        let server = MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0)
        #expect(
            HelloNegotiation.negotiate(
                server: server,
                client: MMHello(protocolVersion: 0, schemaFingerprint: 0, capabilities: 0)
            ).protocolVersion == 0
        )
        #expect(
            HelloNegotiation.negotiate(
                server: server,
                client: MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0)
            ).protocolVersion == 1
        )
        #expect(
            HelloNegotiation.negotiate(
                server: server,
                client: MMHello(protocolVersion: 9, schemaFingerprint: 0, capabilities: 0)
            ).protocolVersion == 1
        )
    }

    @Test("capabilities negotiate to the bitwise intersection")
    func capabilitiesIntersect() {
        let server = MMHello(
            protocolVersion: 1,
            schemaFingerprint: 0,
            capabilities: 0b1010_1010
        )
        let client = MMHello(
            protocolVersion: 1,
            schemaFingerprint: 0,
            capabilities: 0b1100_0110
        )
        let negotiated = HelloNegotiation.negotiate(server: server, client: client)
        #expect(negotiated.capabilities == 0b1000_0010)
    }

    @Test("fingerprint mismatch does not affect the exchange")
    func fingerprintMismatchIsNotAnError() throws {
        let channel = try makeConnectedChannel()
        var helloFrame = ByteBuffer()
        MMHello(protocolVersion: 1, schemaFingerprint: 0xDEAD_BEEF, capabilities: 0)
            .encode(into: &helloFrame)
        try channel.writeInbound(helloFrame)
        #expect(try channel.readInbound(as: ByteBuffer.self) == helloFrame)
        #expect(channel.isActive)
        _ = try? channel.finish()
    }
}
