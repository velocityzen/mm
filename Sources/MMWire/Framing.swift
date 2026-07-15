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
        guard buffer.readableBytes >= 4 + Int(length) else {
            return .needMoreData
        }
        buffer.moveReaderIndex(forwardBy: 4)
        // Force-unwrap is safe: readableBytes was bounds-checked above.
        let payload = buffer.readSlice(length: Int(length))!
        context.fireChannelRead(self.wrapInboundOut(payload))
        return .continue
    }

    /// Policy for leftover partial-frame bytes at EOF: complete frames still buffered
    /// are drained and emitted; if any bytes then remain (a partial length prefix or a
    /// partial body) and EOF has been seen, the decoder throws `MMWireError.truncated`
    /// so the truncation is observable to the pipeline's error handling instead of
    /// being silently discarded. When called without EOF (handler removal), leftover
    /// bytes are not an error — they are handed back to the pipeline by
    /// `ByteToMessageHandler`'s removal machinery.
    public mutating func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        while true {
            let state = try self.decode(context: context, buffer: &buffer)
            if case .needMoreData = state { break }
        }
        if seenEOF && buffer.readableBytes > 0 {
            throw MMWireError.truncated
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
