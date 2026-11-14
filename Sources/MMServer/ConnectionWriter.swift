import FP
import MMWire
import Metrics
import NIOCore
import Synchronization

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
/// stream frames — goes through it.
///
/// ## Batched writes
///
/// Frames go through a ``BatchingFrameWriter``: a handler that finds nobody
/// writing writes its frame and every frame other handlers queue meanwhile,
/// a batch to one `write(contentsOf:)`, so frames never interleave and the
/// outbound writer's lock and the hop to the event loop are paid once per
/// batch, not once per frame. A handler that finds a write at work queues
/// its frame and returns. Only the writing handler waits on the channel's
/// backpressure; what the others queue is bounded by the per-connection
/// in-flight cap and the streams' credit.
///
/// The connection runs ``standBy()`` beside its request loop, for the
/// frames a cancelled handler leaves mid-write, and ends it with
/// ``finish()`` once every handler has returned.
final class ConnectionWriter: WriterFunnel {
    private let frames: BatchingFrameWriter
    private let framesOut: Counter
    private let closed = Atomic(false)

    init(outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>, framesOut: Counter) {
        self.frames = BatchingFrameWriter(outbound: outbound)
        self.framesOut = framesOut
    }

    /// Writes the frames a cancelled handler leaves mid-write, for the
    /// connection's lifetime; see ``BatchingFrameWriter/standBy()``.
    func standBy() async {
        await self.frames.standBy()
    }

    /// Ends ``standBy()``.
    func finish() {
        self.frames.finish()
    }

    /// Encodes and writes one envelope. Encode failure never touches the
    /// channel; a write failure marks the writer closed so later sends
    /// short-circuit with `.connectionClosed` — unless the sender was
    /// cancelled, which fails only that send.
    func send(_ envelope: MMEnvelope) async -> Result<Void, ServerError> {
        guard !self.closed.load(ordering: .relaxed) else {
            return .failure(.connectionClosed)
        }

        return await envelope.encoded()
            .mapError { ServerError.encodingFailed($0) }
            .flatMapAsync { buffer in await self.write(buffer) }
    }

    /// The batching writer's two failures: a cancelled sender fails only
    /// its own send, and the channel is fine; any other failure means the
    /// channel is gone, and the closed latch makes every later send
    /// short-circuit.
    private func write(_ buffer: ByteBuffer) async -> Result<Void, ServerError> {
        switch await self.frames.write(buffer) {
            case .success:
                self.framesOut.increment()
                return .success(())
            case .failure(.cancelled):
                return .failure(.cancelled)
            case .failure(.channelClosed):
                self.closed.store(true, ordering: .relaxed)
                return .failure(.connectionClosed)
        }
    }
}
