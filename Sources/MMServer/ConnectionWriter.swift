import FP
import MMWire
import Metrics
import NIOCore

/// The connection's single outbound funnel, abstracted so the stream runtime
/// and its wire seams depend on a protocol rather than the concrete
/// ``ConnectionWriter`` — the production conformer wraps the
/// `NIOAsyncChannelOutboundWriter`, and tests inject a recorder. Every stream
/// frame (terminals, items, ENDs, STOPs, credit grants) routes through one of
/// these, so writes never interleave.
protocol WriterFunnel: Sendable {
    /// Encodes and writes one envelope. Returns `.connectionClosed` once the
    /// channel is gone (or `.encodingFailed` on a bad raw slot).
    func send(_ envelope: MMEnvelope) async -> Result<Void, ServerError>
}

/// The single outbound funnel for one connection: every frame the server sends
/// after the hello — handler responses, `tooManyInFlight` rejections, and
/// stream frames — goes through this actor.
///
/// ## Why an actor over the `NIOAsyncChannel` outbound writer
///
/// Actor isolation serializes envelope writes (concurrent handler tasks can
/// never interleave partially), and `NIOAsyncChannelOutboundWriter.write`
/// suspends while the channel is unwritable, so the socket's backpressure
/// propagates to every producer. Nothing here buffers unboundedly: each
/// producer is suspended *inside* its own `send` call until the channel
/// accepts the frame, and the number of concurrent producers is itself
/// bounded by the per-connection in-flight cap.
actor ConnectionWriter: WriterFunnel {
    private let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private let framesOut: Counter
    private var closed = false

    init(outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>, framesOut: Counter) {
        self.outbound = outbound
        self.framesOut = framesOut
    }

    /// Encodes and writes one envelope. Encode failure never touches the
    /// channel; a write failure marks the writer closed so later sends
    /// short-circuit with `.connectionClosed`.
    func send(_ envelope: MMEnvelope) async -> Result<Void, ServerError> {
        guard !self.closed else {
            return .failure(.connectionClosed)
        }

        return await envelope.encoded()
            .mapError { ServerError.encodingFailed($0) }
            .flatMapAsync { @Sendable buffer in await self.write(buffer) }
    }

    /// Seam adapter: the writer's untyped throw collapses to the coarse
    /// transport case — the channel is gone either way, and the closed latch
    /// makes every later send short-circuit.
    private func write(_ buffer: ByteBuffer) async -> Result<Void, ServerError> {
        await Result.fromAsync { @Sendable in try await self.outbound.write(buffer) }
            .tap { self.framesOut.increment() }
            .tapError { _ in self.closed = true }
            .mapError { _ in ServerError.connectionClosed }
    }
}
