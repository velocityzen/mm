import MMTestSupport
import MMWire
import NIOCore
import NIOEmbedded
import Testing

@testable import MMClient

/// The client-side idle reaper: `MMIdleCloseHandler` behavior and the
/// pipeline assembly that installs it. The full reap/liveness behavior runs
/// over a real socket in `MMIntegrationTests` (`IdleStateHandler` measures
/// real monotonic time, so it cannot be driven by a fake test clock).
@Suite("Client idle reaping")
struct IdleTests {
    @Test("MMIdleCloseHandler closes the channel on an idle event")
    func idleEventCloses() throws {
        let channel = EmbeddedChannel(handler: MMIdleCloseHandler())
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/mm-test"), promise: nil)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.all)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive == false)
    }

    @Test("MMIdleCloseHandler forwards unrelated user events")
    func unrelatedEventsForwarded() throws {
        let channel = EmbeddedChannel(handler: MMIdleCloseHandler())
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/mm-test"), promise: nil)
        channel.embeddedEventLoop.run()
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive)
        _ = try? channel.finish()
    }

    @Test("the client installs the all-traffic idle reaper once the hello is done")
    func idlePipelineAssembly() async throws {
        // Assembled on the NIOAsyncTestingChannel harness, not EmbeddedChannel:
        // the NIOAsyncChannel wrapper's scoped teardown (executeThenClose)
        // parks work on the event loop, and EmbeddedEventLoop only runs when
        // driven by hand — the teardown would deadlock. The testing loop
        // executes it for real.
        let configuration = MMClientConfiguration(idleTimeout: .seconds(30))
        // No reaper during the hello: helloTimeout bounds that phase, so a
        // short idleTimeout never fails a connect to a slow server.
        let pending = try await connectPipeline(configuration: configuration)
        try await pending.loop.executeInContext {
            let sync = pending.channel.pipeline.syncOperations
            #expect(throws: (any Error).self) { try sync.handler(type: IdleStateHandler.self) }
            #expect(throws: (any Error).self) { try sync.handler(type: MMIdleCloseHandler.self) }
        }
        await discard(pending)
        _ = try await withRunningConnection(configuration: configuration) { client in
            try await client.loop.executeInContext {
                let sync = client.channel.pipeline.syncOperations
                // All-traffic idleness, not read-only: inbound stream items to
                // a server→client stream consumer must count as liveness.
                let idleState = try sync.handler(type: IdleStateHandler.self)
                #expect(idleState.allTimeout == .seconds(30))
                #expect(idleState.readTimeout == nil)
                #expect(idleState.writeTimeout == nil)
                #expect(throws: Never.self) { try sync.handler(type: MMIdleCloseHandler.self) }
            }
        }
        // Without idleTimeout, neither idle handler is installed.
        _ = try await withRunningConnection { client in
            try await client.loop.executeInContext {
                let sync = client.channel.pipeline.syncOperations
                #expect(throws: (any Error).self) { try sync.handler(type: IdleStateHandler.self) }
                #expect(throws: (any Error).self) { try sync.handler(type: MMIdleCloseHandler.self) }
            }
        }
    }
}
