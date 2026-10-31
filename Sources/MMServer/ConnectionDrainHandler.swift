import NIOCore

/// Ends a connection's requests for the graceful drain while its socket keeps
/// reading.
///
/// The drain must stop taking requests without closing the socket's input:
/// `shutdown(SHUT_RD)` on a Linux unix socket fails the peer's next write
/// with `EPIPE`, and a NIO peer that is not reading at that moment closes at
/// once, dropping every response the drain is about to flush. Darwin drops
/// the peer's bytes instead, so the drain only ever failed on Linux.
///
/// So the drain is a pipeline event instead (see ``begin(on:)``). It reaches
/// the frame decoder and the request stream as `ChannelEvent.inputClosed`,
/// exactly as an input close would: the decoder settles and the request loop
/// ends. From then on, everything the peer sends is read and discarded, so
/// its writes keep succeeding until the connection closes.
///
/// Sits after the idle handlers and before the frame decoder: what is
/// discarded is never decoded, and reads still count as liveness.
final class ConnectionDrainHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    /// The event that starts the drain, fired from the head of the pipeline.
    struct Begin: Sendable {}

    private var draining = false

    /// Starts the drain of the connection on `channel`. Callable from any
    /// thread; a second call is a no-op.
    static func begin(on channel: any Channel) {
        channel.eventLoop.execute {
            channel.pipeline.syncOperations.fireUserInboundEventTriggered(Begin())
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
            case is Begin:
                guard !self.draining else { return }
                self.draining = true
                context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                context.read()
            case ChannelEvent.inputClosed where self.draining:
                // The peer ended its side after the drain ended the requests.
                return
            default:
                context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !self.draining else { return }
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        guard !self.draining else {
            // The request stream's backpressure no longer applies: keep
            // emptying the socket.
            context.read()
            return
        }
        context.fireChannelReadComplete()
    }
}
