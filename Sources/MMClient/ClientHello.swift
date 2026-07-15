import MMWire
import NIOCore

/// Internal failure carried by the hello promise; translated to
/// ``MMClientError`` at the `connect` seam.
enum HelloFailure: Error {
    /// The server's first frame did not decode as a hello.
    case badHello
    /// The connection closed (or was torn down) before a server hello arrived.
    case closedBeforeHello

    var clientError: MMClientError {
        switch self {
            case .badHello:
                return .badHello
            case .closedBeforeHello:
                return .transport(description: "connection closed before server hello")
        }
    }
}

/// Client side of the connection preamble, as a thin channel handler above the
/// framing codec — the mirror of the server's `ServerHelloHandler`.
///
/// Responsibilities (and nothing more — no envelope or business logic):
///
/// - Writes the client's hello as the connection's **first outbound frame**,
///   at channel activation (the client does not wait for the server's hello;
///   both sides send eagerly, per the wire contract).
/// - Requires the server's first frame to be a decodable hello. A valid hello
///   completes `helloPromise` and is **not** forwarded inbound — `connect`
///   consumes it from the promise, so the envelope loop never sees it. Bad
///   magic or an undecodable hello fails the promise with
///   ``HelloFailure/badHello`` and closes the connection.
/// - Forwards everything after the hello unchanged.
///
/// The promise is completed exactly once on every path (valid hello, bad
/// hello, close-before-hello, pipeline error, handler removal), guarded by
/// `helloCompleted`.
final class ClientHelloHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case awaitingHello
        case established
        case failed
    }

    private var state: State = .awaitingHello
    private var helloSent = false
    private var helloCompleted = false
    private let clientHello: MMHello
    private let helloPromise: EventLoopPromise<MMHello>

    init(clientHello: MMHello, helloPromise: EventLoopPromise<MMHello>) {
        self.clientHello = clientHello
        self.helloPromise = helloPromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.sendClientHello(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.sendClientHello(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.state {
            case .established:
                context.fireChannelRead(data)
            case .failed:
                break
            case .awaitingHello:
                let frame = self.unwrapInboundIn(data)
                switch MMHello.decode(from: frame) {
                    case .success(let serverHello):
                        self.state = .established
                        self.completeHello(with: .success(serverHello))
                    case .failure:
                        self.state = .failed
                        self.completeHello(with: .failure(HelloFailure.badHello))
                        context.close(promise: nil)
                }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.completeHello(with: .failure(HelloFailure.closedBeforeHello))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.completeHello(with: .failure(HelloFailure.closedBeforeHello))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.completeHello(with: .failure(error))
        context.fireErrorCaught(error)
    }

    private func sendClientHello(context: ChannelHandlerContext) {
        guard !self.helloSent else { return }
        self.helloSent = true
        var buffer = context.channel.allocator.buffer(capacity: MMHello.encodedByteCount)
        self.clientHello.encode(into: &buffer)
        context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
    }

    private func completeHello(with result: Result<MMHello, any Error>) {
        guard !self.helloCompleted else { return }
        self.helloCompleted = true
        self.helloPromise.completeWith(result)
    }
}

/// Closes the channel when `IdleStateHandler` reports idleness. Client-side
/// twin of the server's idle reaper; installed only when
/// ``MMClientConfiguration/idleTimeout`` is set.
final class ClientIdleCloseHandler: ChannelInboundHandler {
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
