import NIOCore
import NIOEmbedded
import Testing

@testable import MMServer

/// The graceful drain of one connection: the requests end as if the input
/// closed, but the socket's input never closes, and the socket keeps reading.
@Suite("Connection drain")
struct ConnectionDrainTests {
    @Test("the drain ends the requests like an input close, without closing the socket's input")
    func drainEndsRequests() throws {
        let (channel, head, tail) = try Self.makeChannel()
        let readsBefore = head.reads
        ConnectionDrainHandler.begin(on: channel)
        channel.embeddedEventLoop.run()
        #expect(tail.inputCloses == 1)
        // A shut-down input fails the peer's next write on Linux.
        #expect(head.closes.isEmpty)
        #expect(head.reads > readsBefore)
        _ = try? channel.finish()
    }

    @Test("what arrives during the drain is discarded, and the socket keeps reading")
    func drainDiscardsAndKeepsReading() throws {
        let (channel, head, tail) = try Self.makeChannel()
        ConnectionDrainHandler.begin(on: channel)
        channel.embeddedEventLoop.run()
        let readsBefore = head.reads
        try channel.writeInbound(ByteBuffer(bytes: [1, 2, 3]))
        #expect(tail.reads.isEmpty)
        #expect(head.reads > readsBefore)
        // The peer's own end of input, and a second drain, end nothing twice.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        ConnectionDrainHandler.begin(on: channel)
        channel.embeddedEventLoop.run()
        #expect(tail.inputCloses == 1)
        #expect(head.closes.isEmpty)
        _ = try? channel.finish()
    }

    @Test("before the drain, reads and events pass through")
    func passesThroughBeforeDrain() throws {
        let (channel, _, tail) = try Self.makeChannel()
        try channel.writeInbound(ByteBuffer(bytes: [1, 2, 3]))
        #expect(tail.reads == [ByteBuffer(bytes: [1, 2, 3])])
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        #expect(tail.inputCloses == 1)
        _ = try? channel.finish()
    }

    /// An active channel: the head recorder, the drain handler, the tail
    /// recorder.
    private static func makeChannel() throws -> (EmbeddedChannel, HeadRecorder, TailRecorder) {
        let head = HeadRecorder()
        let tail = TailRecorder()
        let channel = EmbeddedChannel(handlers: [head, ConnectionDrainHandler(), tail])
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/mm-test"), promise: nil)
        channel.embeddedEventLoop.run()
        return (channel, head, tail)
    }
}

/// Records the reads and closes that reach the head of the pipeline.
private final class HeadRecorder: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer

    private(set) var reads = 0
    private(set) var closes: [CloseMode] = []

    func read(context: ChannelHandlerContext) {
        self.reads += 1
        context.read()
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.closes.append(mode)
        context.close(mode: mode, promise: promise)
    }
}

/// Records what the drain handler passes on.
private final class TailRecorder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private(set) var reads: [ByteBuffer] = []
    private(set) var inputCloses = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.reads.append(self.unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            self.inputCloses += 1
        }
    }
}
