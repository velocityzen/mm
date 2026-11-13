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
}
