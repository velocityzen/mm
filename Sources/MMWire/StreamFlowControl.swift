import NIOCore

/// Credit-based flow-control spec constants (§4.2), known to both sides and
/// never sent as frames — one home, so the server's stream sources and the
/// client's send gate cannot disagree about the pre-grant burst. Grant
/// *batching* policy is deliberately local to each side (the server grants
/// per half-window, the client per full window); only the constants the wire
/// contract fixes live here.
package enum MMStreamFlowControl {
    /// Initial per-direction credit: items either side may send before the
    /// first grant arrives.
    package static let initialWindow: UInt32 = 8
    /// Low watermark for inbound producers: a consumer drain below this
    /// resumes production. 1 keeps a nearly-empty buffer flowing.
    package static let lowWatermark = 1
}

/// Closes the channel when NIOCore's `IdleStateHandler` reports idleness.
/// Installed directly after `IdleStateHandler` on both sides (before the
/// frame decoder), so it also reaps peers that connect and never complete the
/// hello exchange.
package final class MMIdleCloseHandler: ChannelInboundHandler {
    package typealias InboundIn = ByteBuffer
    package typealias InboundOut = ByteBuffer

    package init() {}

    package func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}
