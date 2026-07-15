import Logging
import MMWire
import Metrics
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing

@testable import MMServer

@Suite("Idle handling and pipeline assembly")
struct PipelineTests {
    @Test("IdleCloseHandler closes the channel on an idle event")
    func idleEventCloses() throws {
        let channel = EmbeddedChannel(handler: IdleCloseHandler())
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/mm-test"), promise: nil)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.read)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive == false)
    }

    @Test("IdleCloseHandler forwards unrelated user events")
    func unrelatedEventsForwarded() throws {
        let channel = EmbeddedChannel(handler: IdleCloseHandler())
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/mm-test"), promise: nil)
        channel.embeddedEventLoop.run()
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive)
        _ = try? channel.finish()
    }

    @Test("child pipeline contains idle timeout, framing codec, and hello handler")
    func childPipelineAssembly() throws {
        let channel = EmbeddedChannel()
        _ = try MMService.configureChildPipeline(
            channel: channel,
            maxFrameLength: 1024,
            idleTimeout: .seconds(30),
            serverHello: MMHello(protocolVersion: 1, schemaFingerprint: 0, capabilities: 0),
            protocolViolations: Counter(label: "test_protocol_violations")
        )
        let sync = channel.pipeline.syncOperations
        // All-traffic idleness, not read-only: outbound stream items pushed to
        // a server→client stream consumer must count as liveness.
        let idleState = try sync.handler(type: IdleStateHandler.self)
        #expect(idleState.allTimeout == .seconds(30))
        #expect(idleState.readTimeout == nil)
        #expect(idleState.writeTimeout == nil)
        #expect(throws: Never.self) { try sync.handler(type: IdleCloseHandler.self) }
        #expect(throws: Never.self) {
            try sync.handler(type: ByteToMessageHandler<MMFrameDecoder>.self)
        }
        #expect(throws: Never.self) {
            try sync.handler(type: MessageToByteHandler<MMFrameEncoder>.self)
        }
        #expect(throws: Never.self) { try sync.handler(type: ServerHelloHandler.self) }
        _ = try? channel.finish()
    }

}

@Suite("Accept-error filtering on the listener")
struct AcceptErrorFilterTests {
    private func makeChannel(counterLabel: String) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel(
            handler: AcceptErrorFilterHandler(
                logger: Logger(label: "mm.test"),
                acceptFailures: Counter(label: counterLabel)
            )
        )
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/mm-test"), promise: nil)
        channel.embeddedEventLoop.run()
        return channel
    }

    @Test("NIOFcntlFailedError is swallowed: nothing propagates, the listener stays up")
    func fcntlFailureSwallowed() throws {
        let channel = try self.makeChannel(counterLabel: "test_accept_failures_swallow")
        // NIOPosix does not export an initializer for NIOFcntlFailedError (an
        // empty public struct), so the real value is materialized with a
        // zero-byte bit-cast — the test must pin the actual wire type the
        // handler filters on, not a stand-in.
        let error = unsafeBitCast((), to: NIOFcntlFailedError.self)
        channel.pipeline.fireErrorCaught(error)
        channel.embeddedEventLoop.run()
        #expect(throws: Never.self) { try channel.throwIfErrorCaught() }
        #expect(channel.isActive)
        _ = try? channel.finish()
    }

    @Test("every other error propagates and remains fatal to the accept stream")
    func otherErrorsPropagate() throws {
        struct UnrelatedError: Error {}
        let channel = try self.makeChannel(counterLabel: "test_accept_failures_propagate")
        channel.pipeline.fireErrorCaught(UnrelatedError())
        channel.embeddedEventLoop.run()
        #expect(throws: UnrelatedError.self) { try channel.throwIfErrorCaught() }
        _ = try? channel.finish()
    }
}

@Suite("Server configuration")
struct ServerConfigurationTests {
    @Test("defaults are the documented hardening values")
    func defaults() {
        let configuration = MMServerConfiguration(endpoint: .unix(path: "/tmp/mm.sock"))
        #expect(configuration.maxFrameLength == MMWireInfo.defaultMaxFrameLength)
        #expect(configuration.maxFrameLength == 16 * 1024 * 1024)
        #expect(configuration.maxConnections == 128)
        #expect(configuration.maxInFlightRequestsPerConnection == 16)
        #expect(configuration.idleTimeout == .seconds(120))
        #expect(configuration.unixSocketMode == 0o660)
        #expect(configuration.capabilities == 0)
    }

    @Test("every field is overridable")
    func overrides() {
        let configuration = MMServerConfiguration(
            endpoint: .tcp(host: "127.0.0.1", port: 0),
            maxFrameLength: 4096,
            maxConnections: 2,
            maxInFlightRequestsPerConnection: 1,
            idleTimeout: .milliseconds(250),
            unixSocketMode: 0o600,
            capabilities: 3
        )
        #expect(configuration.endpoint == .tcp(host: "127.0.0.1", port: 0))
        #expect(configuration.maxFrameLength == 4096)
        #expect(configuration.maxConnections == 2)
        #expect(configuration.maxInFlightRequestsPerConnection == 1)
        #expect(configuration.idleTimeout == .milliseconds(250))
        #expect(configuration.unixSocketMode == 0o600)
        #expect(configuration.capabilities == 3)
    }
}
