import Benchmark
import NIOCore
import NIOPosix

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The wire stage of `Payload`'s messages: their frames crossing a Unix socket
/// between two NIO channels, with nothing encoded or decoded on either side.
///
/// One-way, the client writes and flushes each element's frame, as a
/// connection sends each message, and the server counts the bytes until all
/// of them have arrived. Two-way, the client sends a request frame, the
/// server answers each whole request with a response frame, and the client
/// sends the next request once the response has arrived: one call in flight,
/// as a caller that awaits each call.
func wireBenchmarks<Payload: ThroughputPayload>(_ payload: Payload.Type) {
    let frames = ThroughputFrames(payload)

    Benchmark("OneWay.wire.\(Payload.shape)") { benchmark in
        let count = benchmark.scaledIterations.count
        let group = MultiThreadedEventLoopGroup.singleton
        let arrived = group.next().makePromise(of: Void.self)
        let expected = count * frames.item.readableBytes
        let (server, client) = try await connectedChannels(
            server: { ByteCounter(expecting: expected, arrived: arrived) },
            client: nil
        )
        let frame = frames.item
        benchmark.startMeasurement()
        client.eventLoop.execute {
            for _ in 0..<count {
                client.writeAndFlush(frame, promise: nil)
            }
        }
        try await arrived.futureResult.get()
        benchmark.stopMeasurement()
        try await client.close()
        try await server.close()
    }

    Benchmark("TwoWay.wire.\(Payload.shape)") { benchmark in
        let count = benchmark.scaledIterations.count
        let group = MultiThreadedEventLoopGroup.singleton
        let answered = group.next().makePromise(of: Void.self)
        let request = frames.request
        let response = frames.response
        let (server, client) = try await connectedChannels(
            server: { Responder(request: request, response: response) },
            client: { Caller(request: request, response: response, calls: count, done: answered) }
        )
        benchmark.startMeasurement()
        client.writeAndFlush(request, promise: nil)
        try await answered.futureResult.get()
        benchmark.stopMeasurement()
        try await client.close()
        try await server.close()
    }
}

/// A server channel listening on a Unix socket, and a client channel connected
/// to it, each with its handler. `server` makes the handler of the one
/// connection the server accepts.
private func connectedChannels(
    server serverHandler: @escaping @Sendable () -> any ChannelHandler,
    client clientHandler: (@Sendable () -> any ChannelHandler)?
) async throws -> (server: any Channel, client: any Channel) {
    let path = socketPath("wire")
    let group = MultiThreadedEventLoopGroup.singleton
    let server = try await ServerBootstrap(group: group)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(serverHandler())
            }
        }
        .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true)
        .get()
    let client = try await ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                if let clientHandler {
                    try channel.pipeline.syncOperations.addHandler(clientHandler())
                }
            }
        }
        .connect(unixDomainSocketPath: path)
        .get()
    return (server, client)
}

/// A Unix socket path for this process's `kind` of benchmark connection, in
/// the temporary directory (`TMPDIR`, else `/tmp`).
func socketPath(_ kind: String) -> String {
    var directory = getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp"
    if !directory.hasSuffix("/") {
        directory += "/"
    }
    return "\(directory)mm-throughput-\(kind)-\(getpid()).sock"
}

/// Counts the bytes that arrive, and succeeds `arrived` once all are in.
private final class ByteCounter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var remaining: Int
    private let arrived: EventLoopPromise<Void>

    init(expecting byteCount: Int, arrived: EventLoopPromise<Void>) {
        self.remaining = byteCount
        self.arrived = arrived
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.remaining -= self.unwrapInboundIn(data).readableBytes
        if self.remaining == 0 {
            self.arrived.succeed()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.arrived.fail(ChannelError.eof)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.arrived.fail(error)
    }
}

/// The server side of a two-way wire run: answers each whole request frame
/// with a response frame.
private final class Responder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let requestSize: Int
    private let response: ByteBuffer
    private var pending = 0

    init(request: ByteBuffer, response: ByteBuffer) {
        self.requestSize = request.readableBytes
        self.response = response
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.pending += self.unwrapInboundIn(data).readableBytes
        while self.pending >= self.requestSize {
            self.pending -= self.requestSize
            context.writeAndFlush(self.wrapOutboundOut(self.response), promise: nil)
        }
    }
}

/// The client side of a two-way wire run: sends the next request once the
/// last one's response has arrived whole, until `calls` have been answered.
/// The benchmark sends the first request.
private final class Caller: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: ByteBuffer
    private let responseSize: Int
    private var remaining: Int
    private var pending = 0
    private let done: EventLoopPromise<Void>

    init(request: ByteBuffer, response: ByteBuffer, calls: Int, done: EventLoopPromise<Void>) {
        self.request = request
        self.responseSize = response.readableBytes
        self.remaining = calls
        self.done = done
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.pending += self.unwrapInboundIn(data).readableBytes
        while self.pending >= self.responseSize {
            self.pending -= self.responseSize
            self.remaining -= 1
            if self.remaining == 0 {
                self.done.succeed()
            } else {
                context.writeAndFlush(self.wrapOutboundOut(self.request), promise: nil)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.done.fail(ChannelError.eof)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.done.fail(error)
    }
}
