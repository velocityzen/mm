import NIOCore

/// Decodes `[u32 LE length][payload]` frames into payload `ByteBuffer` slices.
///
/// The length prefix counts payload bytes only. The length is checked against
/// `maxFrameLength` as soon as the 4-byte prefix is readable — before waiting for
/// (or consuming) any body bytes — and an oversized claim throws
/// `MMWireError.frameTooLarge` from `decode`. Throwing from a `ByteToMessageDecoder`
/// is the sanctioned NIO seam for a fatal protocol violation: `ByteToMessageHandler`
/// fires the error down the pipeline, which fails the connection.
///
/// Zero-length frames are legal and emit an empty slice. Payloads are emitted as
/// slices of the accumulation buffer (copy-on-write, no copy).
///
/// This handler is framing only: it has zero knowledge of the envelope or hello
/// layers above it.
public struct MMFrameDecoder: ByteToMessageDecoder, Sendable {
    public typealias InboundOut = ByteBuffer

    /// Maximum accepted payload length in bytes. Default 16 MiB.
    public let maxFrameLength: UInt32

    public init(maxFrameLength: UInt32 = MMWireInfo.defaultMaxFrameLength) {
        self.maxFrameLength = maxFrameLength
    }

    public mutating func decode(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        guard
            let length = buffer.getInteger(
                at: buffer.readerIndex,
                endianness: .little,
                as: UInt32.self
            )
        else {
            return .needMoreData
        }
        guard length <= self.maxFrameLength else {
            throw MMWireError.frameTooLarge(length: length, limit: self.maxFrameLength)
        }
        // The cap was checked on the peeked prefix above, so nil here can
        // only mean the body has not fully arrived.
        guard
            let payload = buffer.readLengthPrefixedSlice(endianness: .little, as: UInt32.self)
        else {
            return .needMoreData
        }
        context.fireChannelRead(self.wrapInboundOut(payload))
        return .continue
    }

    /// Policy for leftover partial-frame bytes: complete frames still buffered are
    /// drained and emitted first. What happens to the bytes that then remain (a
    /// partial length prefix or a partial body) depends on why the decoder is done:
    ///
    /// - At EOF the frame can never complete, so the decoder throws
    ///   `MMWireError.truncated`: the truncation reaches the pipeline's error
    ///   handling instead of being silently discarded.
    /// - On removal from the pipeline (no EOF) the bytes belong to whatever reads
    ///   the stream next, as in a protocol upgrade, so the decoder passes them on
    ///   down the pipeline as one raw, unframed read. `ByteToMessageHandler` does
    ///   not do this itself: on removal it only calls `decodeLast`.
    public mutating func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        while true {
            let state = try self.decode(context: context, buffer: &buffer)
            if case .needMoreData = state { break }
        }
        guard buffer.readableBytes > 0 else {
            return .needMoreData
        }
        if seenEOF {
            throw MMWireError.truncated
        }
        if let leftover = buffer.readSlice(length: buffer.readableBytes) {
            context.fireChannelRead(self.wrapInboundOut(leftover))
        }
        return .needMoreData
    }
}

/// Encodes payload `ByteBuffer`s into `[u32 LE length][payload]` frames.
///
/// Payloads longer than `maxFrameLength` are rejected with
/// `MMWireError.frameTooLarge` (thrown at the NIO seam, failing the write's promise).
/// Because `maxFrameLength` is a `UInt32`, this same check rejects any payload whose
/// length cannot be represented in the `u32` prefix.
///
/// This handler is framing only: it has zero knowledge of the envelope or hello
/// layers above it.
public struct MMFrameEncoder: MessageToByteEncoder, Sendable {
    public typealias OutboundIn = ByteBuffer

    /// Maximum accepted payload length in bytes. Default 16 MiB.
    public let maxFrameLength: UInt32

    public init(maxFrameLength: UInt32 = MMWireInfo.defaultMaxFrameLength) {
        self.maxFrameLength = maxFrameLength
    }

    public func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
        let byteCount = data.readableBytes
        guard byteCount <= Int(self.maxFrameLength) else {
            throw MMWireError.frameTooLarge(
                length: UInt32(clamping: byteCount),
                limit: self.maxFrameLength
            )
        }
        out.writeInteger(UInt32(byteCount), endianness: .little)
        out.writeImmutableBuffer(data)
    }

    /// `payload` as a frame, with the bytes and the failure of
    /// ``encode(data:out:)``. A payload whose length prefix already sits in
    /// the four bytes before its reader index, as
    /// ``MMEnvelope/encoded(allocator:maxDepth:)`` leaves it, comes back in
    /// its own storage with the reader index moved back over the prefix.
    /// Any other payload is copied behind a new prefix.
    public func frame(
        _ payload: ByteBuffer,
        allocator: ByteBufferAllocator
    ) throws -> ByteBuffer {
        let byteCount = payload.readableBytes
        if byteCount <= Int(self.maxFrameLength), payload.readerIndex >= 4 {
            var framed = payload
            framed.moveReaderIndex(to: payload.readerIndex - 4)
            let prefix = framed.getInteger(
                at: framed.readerIndex,
                endianness: .little,
                as: UInt32.self
            )
            if prefix == UInt32(byteCount) {
                return framed
            }
        }
        var out = allocator.buffer(capacity: 4 + byteCount)
        try self.encode(data: payload, out: &out)
        return out
    }
}

/// Frames outbound payloads as `[u32 LE length][payload]`, the frames of
/// `MessageToByteHandler(MMFrameEncoder(...))`, through
/// ``MMFrameEncoder/frame(_:allocator:)``: a payload that already carries
/// its length prefix, as an envelope from
/// ``MMEnvelope/encoded(allocator:maxDepth:)`` does, is written without a
/// copy.
///
/// Failures are `MessageToByteHandler`'s: a payload longer than
/// `maxFrameLength` fails its write with `MMWireError.frameTooLarge` and
/// fires the error down the pipeline, and so does every write after it.
/// Once the handler is removed, writes are dropped.
public final class MMFrameEncodingHandler: ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let encoder: MMFrameEncoder
    private var failure: (any Error)?
    private var removed = false

    public init(maxFrameLength: UInt32 = MMWireInfo.defaultMaxFrameLength) {
        self.encoder = MMFrameEncoder(maxFrameLength: maxFrameLength)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.removed = true
    }

    public func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        guard !self.removed else { return }
        if let failure = self.failure {
            promise?.fail(failure)
            context.fireErrorCaught(failure)
            return
        }
        do {
            let frame = try self.encoder.frame(
                Self.unwrapOutboundIn(data),
                allocator: context.channel.allocator
            )
            context.write(Self.wrapOutboundOut(frame), promise: promise)
        } catch {
            self.failure = error
            promise?.fail(error)
            context.fireErrorCaught(error)
        }
    }
}

@available(*, unavailable)
extension MMFrameEncodingHandler: Sendable {}
