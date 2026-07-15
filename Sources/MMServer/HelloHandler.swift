import Logging
import MMWire
import Metrics
import NIOCore
import NIOPosix

/// The hello-negotiation math, factored out of the transport so it is a pure,
/// testable function. Both rules are fixed wire decisions:
/// version is **min-wins**, capabilities are the **bitwise intersection**.
enum HelloNegotiation {
    struct Negotiated: Sendable, Hashable {
        var protocolVersion: UInt8
        var capabilities: UInt32
    }

    static func negotiate(server: MMHello, client: MMHello) -> Negotiated {
        Negotiated(
            protocolVersion: min(server.protocolVersion, client.protocolVersion),
            capabilities: server.capabilities & client.capabilities
        )
    }
}

/// Server side of the connection preamble, as a thin channel handler above the
/// framing codec.
///
/// Responsibilities (and nothing more — no envelope or business logic):
///
/// - Writes the server's hello as the connection's **first outbound frame**,
///   at channel activation.
/// - Requires the peer's first frame to be a decodable hello: bad magic or an
///   undecodable/truncated hello is a protocol violation — counted and the
///   connection closed, the frame never forwarded.
/// - Forwards the *valid* hello frame (and everything after it) inbound, so
///   the connection task decodes the peer hello as its first read and runs
///   min-wins negotiation there. Fingerprint mismatch is deliberately **not**
///   checked anywhere server-side: it is a client-side discovery trigger,
///   never an error.
final class ServerHelloHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        /// Hello not yet received from the peer.
        case awaitingHello
        /// Hello validated and forwarded; the handler is now a pass-through.
        case established
        /// Protocol violation seen; the close is in flight and any frames
        /// racing it are swallowed.
        case violated
    }

    private var state: State = .awaitingHello
    private var helloSent = false
    private let serverHello: MMHello
    private let protocolViolations: Counter

    init(serverHello: MMHello, protocolViolations: Counter) {
        self.serverHello = serverHello
        self.protocolViolations = protocolViolations
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.sendServerHello(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.sendServerHello(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.state {
            case .established:
                context.fireChannelRead(data)
            case .violated:
                break
            case .awaitingHello:
                let frame = self.unwrapInboundIn(data)
                switch MMHello.decode(from: frame) {
                    case .success:
                        self.state = .established
                        context.fireChannelRead(data)
                    case .failure:
                        self.state = .violated
                        self.protocolViolations.increment()
                        context.close(promise: nil)
                }
        }
    }

    private func sendServerHello(context: ChannelHandlerContext) {
        guard !self.helloSent else { return }
        self.helloSent = true
        var buffer = context.channel.allocator.buffer(capacity: MMHello.encodedByteCount)
        self.serverHello.encode(into: &buffer)
        context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
    }
}

/// Closes the channel when `IdleStateHandler` reports idleness. Sits directly
/// after `IdleStateHandler` (before the frame decoder), so it also reaps
/// clients that connect and never complete the hello exchange.
final class IdleCloseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// Keeps per-child accept failures from killing the listener.
///
/// Darwin sometimes fails `fcntl(F_SETFL, O_NONBLOCK)` with `EINVAL` on a
/// freshly accepted socket whose peer already disconnected (swift-nio issues
/// #1030 / #1598), surfacing `NIOFcntlFailedError` on the **server** channel
/// pipeline. The accepted child is dead either way — but if that error
/// reaches the `NIOAsyncChannel` wrapper it fails the accept stream and takes
/// the whole listener down, so any peer that connects and instantly resets
/// could kill the server. This handler sits on the server channel (added via
/// `serverChannelInitializer`, ahead of NIO's own `AcceptBackoffHandler`,
/// which already absorbs `IOError`s the same way) and swallows exactly this
/// error: count, log, keep accepting. Everything else propagates and remains
/// fatal to `run()`.
final class AcceptErrorFilterHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    private let logger: Logger
    private let acceptFailures: Counter

    init(logger: Logger, acceptFailures: Counter) {
        self.logger = logger
        self.acceptFailures = acceptFailures
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if error is NIOFcntlFailedError {
            self.acceptFailures.increment()
            self.logger.debug(
                "accepted connection failed non-blocking setup",
                metadata: ["error": "\(error)"]
            )
            return
        }
        context.fireErrorCaught(error)
    }
}
