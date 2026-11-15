import NIOCore
import NIOEmbedded
import Testing

@testable import MMWire

/// `MMIdleCloseHandler`, the idle reaper both sides install after NIOCore's
/// `IdleStateHandler`. That each side's pipeline installs it is checked in
/// `MMClientTests` and `MMServerTests`; the reaping itself runs over a real
/// socket in `MMIntegrationTests`.
@Suite("MMIdleCloseHandler")
struct IdleCloseHandlerTests {
    @Test("closes the channel on a read, write or all-traffic idle event")
    func idleEventCloses() throws {
        let events: [IdleStateHandler.IdleStateEvent] = [.read, .write, .all]
        for event in events {
            let channel = EmbeddedChannel(handler: MMIdleCloseHandler())
            channel.connect(to: try SocketAddress(unixDomainSocketPath: "/mm-test"), promise: nil)
            channel.embeddedEventLoop.run()
            #expect(channel.isActive)
            channel.pipeline.fireUserInboundEventTriggered(event)
            channel.embeddedEventLoop.run()
            #expect(channel.isActive == false, "\(event)")
        }
    }

    @Test("forwards unrelated user events")
    func unrelatedEventsForwarded() throws {
        let channel = EmbeddedChannel(handler: MMIdleCloseHandler())
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/mm-test"), promise: nil)
        channel.embeddedEventLoop.run()
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        channel.embeddedEventLoop.run()
        #expect(channel.isActive)
        _ = try? channel.finish()
    }
}
