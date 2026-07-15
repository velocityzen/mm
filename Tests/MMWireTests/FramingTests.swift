import NIOCore
import NIOEmbedded
import Testing

@testable import MMWire

/// Builds `[u32 LE length][payload]` wire bytes for a payload given as hex.
private func frame(_ payloadHex: String) -> ByteBuffer {
    let payload = mpBytes(payloadHex)
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt32(payload.readableBytes), endianness: .little)
    buffer.writeImmutableBuffer(payload)
    return buffer
}

private func decoderChannel(
    maxFrameLength: UInt32 = MMWireInfo.defaultMaxFrameLength
) -> EmbeddedChannel {
    EmbeddedChannel(handler: ByteToMessageHandler(MMFrameDecoder(maxFrameLength: maxFrameLength)))
}

@Suite("MMFrameDecoder")
struct FrameDecoderTests {
    @Test("default cap is 16 MiB on decoder, encoder, and the shared constant")
    func defaultCap() {
        #expect(MMWireInfo.defaultMaxFrameLength == 16_777_216)
        #expect(MMFrameDecoder().maxFrameLength == 16 * 1024 * 1024)
        #expect(MMFrameEncoder().maxFrameLength == 16 * 1024 * 1024)
    }

    @Test("frames decode identically for every split point of the input")
    func everySplitBoundary() throws {
        let payloadHexes = ["", "2a", "a470696e67", "0102030405060708"]
        var wire = ByteBuffer()
        for hex in payloadHexes { wire.writeImmutableBuffer(frame(hex)) }
        for splitPoint in 0...wire.readableBytes {
            let channel = decoderChannel()
            var remainder = wire
            let head = remainder.readSlice(length: splitPoint)!
            try channel.writeInbound(head)
            try channel.writeInbound(remainder)
            for hex in payloadHexes {
                let decoded = try channel.readInbound(as: ByteBuffer.self)
                #expect(decoded.map(mpHex) == hex, "split at \(splitPoint)")
            }
            #expect(try channel.readInbound(as: ByteBuffer.self) == nil, "split at \(splitPoint)")
            #expect(try channel.finish().isClean)
        }
    }

    @Test("byte-by-byte delivery yields the same frames")
    func dripFeed() throws {
        let payloadHexes = ["", "00", "deadbeefcafe"]
        var wire = ByteBuffer()
        for hex in payloadHexes { wire.writeImmutableBuffer(frame(hex)) }
        let channel = decoderChannel()
        while let byte = wire.readSlice(length: 1) {
            try channel.writeInbound(byte)
        }
        for hex in payloadHexes {
            #expect(try channel.readInbound(as: ByteBuffer.self).map(mpHex) == hex)
        }
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        #expect(try channel.finish().isClean)
    }

    @Test("multiple frames coalesced into one buffer all emit")
    func coalescedFrames() throws {
        var wire = ByteBuffer()
        wire.writeImmutableBuffer(frame("01"))
        wire.writeImmutableBuffer(frame(""))
        wire.writeImmutableBuffer(frame("a1786e"))
        let channel = decoderChannel()
        try channel.writeInbound(wire)
        #expect(try channel.readInbound(as: ByteBuffer.self).map(mpHex) == "01")
        #expect(try channel.readInbound(as: ByteBuffer.self).map(mpHex) == "")
        #expect(try channel.readInbound(as: ByteBuffer.self).map(mpHex) == "a1786e")
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        #expect(try channel.finish().isClean)
    }

    @Test("zero-length frame is legal and emits an empty slice")
    func zeroLengthFrame() throws {
        let channel = decoderChannel()
        try channel.writeInbound(frame(""))
        let decoded = try channel.readInbound(as: ByteBuffer.self)
        #expect(decoded != nil)
        #expect(decoded?.readableBytes == 0)
        #expect(try channel.finish().isClean)
    }

    @Test("length exactly at the cap decodes")
    func lengthExactlyAtCap() throws {
        let channel = decoderChannel(maxFrameLength: 8)
        try channel.writeInbound(frame("0102030405060708"))
        #expect(try channel.readInbound(as: ByteBuffer.self).map(mpHex) == "0102030405060708")
        #expect(try channel.finish().isClean)
    }

    @Test("length one over the cap fails the connection before any body bytes arrive")
    func lengthOverCapFailsBeforeBody() throws {
        let channel = decoderChannel(maxFrameLength: 8)
        var prefixOnly = ByteBuffer()
        prefixOnly.writeInteger(UInt32(9), endianness: .little)
        // No body bytes were ever written: the error must come from the prefix alone.
        #expect(throws: MMWireError.frameTooLarge(length: 9, limit: 8)) {
            try channel.writeInbound(prefixOnly)
        }
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }

    @Test("oversized claim with body attached emits no frame")
    func lengthOverCapWithBody() throws {
        let channel = decoderChannel(maxFrameLength: 4)
        var wire = ByteBuffer()
        wire.writeInteger(UInt32(5), endianness: .little)
        wire.writeBytes([1, 2, 3, 4, 5])
        #expect(throws: MMWireError.frameTooLarge(length: 5, limit: 4)) {
            try channel.writeInbound(wire)
        }
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }

    @Test("truncated final frame body at EOF fails with truncated")
    func truncatedBodyAtEOF() throws {
        let channel = decoderChannel()
        var wire = ByteBuffer()
        wire.writeInteger(UInt32(4), endianness: .little)
        wire.writeBytes([0x01, 0x02])
        try channel.writeInbound(wire)
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        #expect(throws: MMWireError.truncated) { try channel.finish() }
    }

    @Test("partial length prefix at EOF fails with truncated")
    func truncatedPrefixAtEOF() throws {
        let channel = decoderChannel()
        var wire = ByteBuffer()
        wire.writeBytes([0x04, 0x00])
        try channel.writeInbound(wire)
        #expect(throws: MMWireError.truncated) { try channel.finish() }
    }

    @Test("complete frames before a truncated tail are still delivered")
    func completeFramesBeforeTruncatedTail() throws {
        let channel = decoderChannel()
        var wire = frame("2a")
        wire.writeInteger(UInt32(8), endianness: .little)
        wire.writeBytes([0xff])
        try channel.writeInbound(wire)
        #expect(try channel.readInbound(as: ByteBuffer.self).map(mpHex) == "2a")
        #expect(throws: MMWireError.truncated) { try channel.finish() }
    }

    @Test("EOF exactly on a frame boundary finishes clean")
    func cleanEOFOnBoundary() throws {
        let channel = decoderChannel()
        try channel.writeInbound(frame("0102"))
        #expect(try channel.readInbound(as: ByteBuffer.self).map(mpHex) == "0102")
        #expect(try channel.finish().isClean)
    }
}

@Suite("MMFrameEncoder")
struct FrameEncoderTests {
    @Test("golden bytes: little-endian length prefix, payload verbatim")
    func encoderGoldenBytes() throws {
        let channel = EmbeddedChannel(handler: MessageToByteHandler(MMFrameEncoder()))
        try channel.writeOutbound(mpBytes("2a"))
        #expect(try channel.readOutbound(as: ByteBuffer.self).map(mpHex) == "010000002a")
        try channel.writeOutbound(ByteBuffer())
        #expect(try channel.readOutbound(as: ByteBuffer.self).map(mpHex) == "00000000")
        #expect(try channel.finish().isClean)
    }

    @Test("payload exactly at the cap encodes")
    func payloadAtCap() throws {
        let channel = EmbeddedChannel(
            handler: MessageToByteHandler(MMFrameEncoder(maxFrameLength: 4))
        )
        try channel.writeOutbound(mpBytes("01020304"))
        #expect(try channel.readOutbound(as: ByteBuffer.self).map(mpHex) == "0400000001020304")
        #expect(try channel.finish().isClean)
    }

    @Test("payload over the cap is rejected with frameTooLarge")
    func payloadOverCap() throws {
        let channel = EmbeddedChannel(
            handler: MessageToByteHandler(MMFrameEncoder(maxFrameLength: 4))
        )
        #expect(throws: MMWireError.frameTooLarge(length: 5, limit: 4)) {
            try channel.writeOutbound(mpBytes("0102030405"))
        }
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }

    @Test("encoder to decoder round trip through one pipeline")
    func roundTripThroughPipeline() throws {
        let channel = EmbeddedChannel(handlers: [
            MessageToByteHandler(MMFrameEncoder()),
            ByteToMessageHandler(MMFrameDecoder()),
        ])
        let payloadHexes = ["", "2a", "940101a470696e6790", String(repeating: "ab", count: 1000)]
        for hex in payloadHexes {
            try channel.writeOutbound(mpBytes(hex))
            let framedBytes = try channel.readOutbound(as: ByteBuffer.self)
            #expect(framedBytes != nil)
            try channel.writeInbound(framedBytes!)
            #expect(try channel.readInbound(as: ByteBuffer.self).map(mpHex) == hex)
        }
        #expect(try channel.finish().isClean)
    }
}
