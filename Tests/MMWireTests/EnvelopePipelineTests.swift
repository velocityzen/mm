import NIOCore
import NIOEmbedded
import Testing

@testable import MMWire

/// The S1 exit criterion made literal: one canonical envelope per kind 0–6,
/// carried through a real `EmbeddedChannel` frame pipeline — split at every
/// byte and coalesced into one buffer — then decoded and re-encoded to the
/// exact pinned bytes. Hex is hand-derived from the MessagePack spec, never
/// from the encoder under test.
@Suite("Envelope kinds 0–6 through the frame pipeline")
struct EnvelopePipelineTests {
    /// (kind, payload hex) — canonical vectors, one per kind.
    static let vectors: [(kind: String, hex: String)] = [
        ("0 terminal", "940005c0c3"),  // [0, 5, nil, true]
        ("1 open", "950101a470696e67a3626f7890"),  // [1, 1, "ping", []]
        ("2 credit", "93020108"),  // [2, 1, 8]
        ("3 item", "94030100a178"),  // [3, 1, 0, "x"]
        ("4 END", "93040100"),  // [4, 1, 0]
        ("5 STOP", "93050100"),  // [5, 1, 0]
        ("6 CANCEL", "920601"),  // [6, 1]
    ]

    private func framed(_ payload: ByteBuffer) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(payload.readableBytes), endianness: .little)
        buffer.writeImmutableBuffer(payload)
        return buffer
    }

    @Test("each kind survives byte-by-byte delivery and re-encodes to its pinned bytes")
    func splitDelivery() throws {
        for vector in Self.vectors {
            let channel = EmbeddedChannel(handlers: [ByteToMessageHandler(MMFrameDecoder())])
            let frame = framed(mpBytes(vector.hex))
            for byte in frame.readableBytesView {
                try channel.writeInbound(ByteBuffer(bytes: [byte]))
            }
            let payload = try channel.readInbound(as: ByteBuffer.self)
            #expect(payload.map(mpHex) == vector.hex, "kind \(vector.kind)")
            let envelope = try #require(payload.map { MMEnvelope.decode(from: $0) })
            let reencoded = try envelope.get().encoded().get()
            #expect(mpHex(reencoded) == vector.hex, "kind \(vector.kind) re-encode")
            #expect(try channel.finish().isClean)
        }
    }

    @Test("all kinds coalesced into one buffer emerge as distinct frames in order")
    func coalescedDelivery() throws {
        let channel = EmbeddedChannel(handlers: [ByteToMessageHandler(MMFrameDecoder())])
        var everything = ByteBuffer()
        for vector in Self.vectors {
            everything.writeImmutableBuffer(framed(mpBytes(vector.hex)))
        }
        try channel.writeInbound(everything)
        for vector in Self.vectors {
            let payload = try channel.readInbound(as: ByteBuffer.self)
            #expect(payload.map(mpHex) == vector.hex, "kind \(vector.kind)")
            if let payload {
                let decoded = MMEnvelope.decode(from: payload)
                #expect((try? decoded.get()) != nil, "kind \(vector.kind) must decode")
            }
        }
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
        #expect(try channel.finish().isClean)
    }
}

/// Review-driven hardening vectors for the u32 slots and tag edge cases.
@Suite("Envelope u32 slots and tag hardening")
struct EnvelopeHardeningTests {
    @Test("kind 0 msgid boundaries: 0 and UInt32.max")
    func terminalMsgidBoundaries() throws {
        // [0, 0, nil, true]
        let zero = try MMEnvelope.decode(from: mpBytes("940000c0c3")).get()
        #expect(zero == .response(msgid: 0, error: nil, result: mpBytes("c3")))
        // [0, 4294967295, nil, true]
        let max = try MMEnvelope.decode(from: mpBytes("9400ceffffffffc0c3")).get()
        #expect(max == .response(msgid: UInt32.max, error: nil, result: mpBytes("c3")))
    }

    @Test("negative values in u32 slots are numberOutOfRange, never crashes")
    func negativeU32Slots() {
        let cases: [(String, String)] = [
            ("9400ffc0c3", "terminal msgid -1"),  // [0, -1, nil, true]
            ("940301ffa178", "item seq -1"),  // [3, 1, -1, "x"]
            ("930201ff", "credit credits -1"),  // [2, 1, -1]
            ("930501ff", "stop code -1"),  // [5, 1, -1]
        ]
        for (hex, label) in cases {
            // Negatives die at the unsigned read stage: target is UInt64.
            let result = MMEnvelope.decode(from: mpBytes(hex))
            #expect(
                result == .failure(.numberOutOfRange(target: "UInt64")), Comment(rawValue: label))
        }
    }

    @Test("wrong-type values in u32 slots are typed failures, never crashes")
    func wrongTypeU32Slots() {
        // [2, 1, "x"] — credits slot is a string
        let credit = MMEnvelope.decode(from: mpBytes("930201a178"))
        guard case .failure(.typeMismatch) = credit else {
            Issue.record("string credits must be typeMismatch, got \(credit)")
            return
        }
        // [3, "x", 0, "y"] — msgid slot is a string
        let item = MMEnvelope.decode(from: mpBytes("9403a17800a179"))
        guard case .failure(.typeMismatch) = item else {
            Issue.record("string msgid must be typeMismatch, got \(item)")
            return
        }
    }

    @Test("a tag wider than Int64 is unknownEnvelope, per the spec")
    func oversizedTag() {
        // [18446744073709551615, 1] — uint64 max as the kind tag
        let result = MMEnvelope.decode(from: mpBytes("92cfffffffffffffffff01"))
        #expect(result == .failure(.unknownEnvelope))
    }

    @Test("the tolerated fifth element of an open frame still honors the depth cap")
    func reservedElementDepthCap() {
        // [1, 1, "m", "", [], <129 nested arrays>] — arity 6; the skipped
        // reserved element exceeds the default depth cap and must fail loudly,
        // not hang.
        var hex = "960101a16da090"
        hex += String(repeating: "91", count: 129)
        hex += "90"
        let result = MMEnvelope.decode(from: mpBytes(hex))
        #expect(result == .failure(.nestingTooDeep(limit: 128)))
        // The same shape within the cap decodes fine and ignores the extra.
        var okHex = "960101a16da090"
        okHex += String(repeating: "91", count: 100)
        okHex += "90"
        let tolerated = MMEnvelope.decode(from: mpBytes(okHex))
        #expect(
            tolerated
                == .success(.request(msgid: 1, method: "m", entity: "", params: mpBytes("90"))))
    }
}
