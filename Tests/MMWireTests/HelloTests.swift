import NIOCore
import Testing

@testable import MMWire

@Suite("MMHello")
struct HelloTests {
    /// version 1, fingerprint 0x0123456789abcdef, capabilities 0xdeadbeef.
    private static let pinnedVector = "4d4d01efcdab8967452301efbeadde"
    private static let pinnedHello = MMHello(
        protocolVersion: 1,
        schemaFingerprint: 0x0123_4567_89ab_cdef,
        capabilities: 0xdead_beef
    )

    @Test("byte order pinned: little-endian fields behind MM magic")
    func pinnedVector() {
        // 0x0123456789abcdef LE → ef cd ab 89 67 45 23 01; 0xdeadbeef LE → ef be ad de.
        #expect(Self.pinnedHello.encode().mpSuccess.map(mpHex) == Self.pinnedVector)
        #expect(MMHello.decode(from: mpBytes(Self.pinnedVector)) == .success(Self.pinnedHello))
    }

    @Test("all-zero fields pinned")
    func zeroVector() {
        let hello = MMHello(protocolVersion: 0, schemaFingerprint: 0, capabilities: 0)
        let vector = "4d4d" + String(repeating: "00", count: 13)
        #expect(hello.encode().mpSuccess.map(mpHex) == vector)
        #expect(MMHello.decode(from: mpBytes(vector)) == .success(hello))
    }

    @Test("encoded size is exactly 15 bytes")
    func encodedSize() {
        #expect(MMHello.encodedByteCount == 15)
        #expect(Self.pinnedHello.encode().mpSuccess?.readableBytes == 15)
    }

    @Test("round trips over seeded random values")
    func randomRoundTrips() {
        var rng = SplitMix64(seed: 0x4d4d)
        for _ in 0..<100 {
            let hello = MMHello(
                protocolVersion: UInt8.random(in: .min ... .max, using: &rng),
                schemaFingerprint: UInt64.random(in: .min ... .max, using: &rng),
                capabilities: UInt32.random(in: .min ... .max, using: &rng)
            )
            #expect(MMHello.decode(from: hello.encode().mpSuccess!) == .success(hello))
        }
    }

    @Test("bad magic in either byte is badMagic")
    func badMagic() {
        #expect(
            MMHello.decode(from: mpBytes("4e4d01efcdab8967452301efbeadde"))
                == .failure(.badMagic)
        )
        #expect(
            MMHello.decode(from: mpBytes("4d4e01efcdab8967452301efbeadde"))
                == .failure(.badMagic)
        )
        // Magic is checked as soon as both bytes are present, even on a short buffer.
        #expect(MMHello.decode(from: mpBytes("4e4e")) == .failure(.badMagic))
    }

    @Test("short buffers are truncated")
    func shortBuffers() {
        #expect(MMHello.decode(from: ByteBuffer()) == .failure(.truncated))
        #expect(MMHello.decode(from: mpBytes("4d")) == .failure(.truncated))
        #expect(MMHello.decode(from: mpBytes("4d4d")) == .failure(.truncated))
        #expect(MMHello.decode(from: mpBytes("4d4d01")) == .failure(.truncated))
        // 14 bytes: one short of the fixed layout.
        #expect(
            MMHello.decode(from: mpBytes("4d4d01efcdab8967452301efbead"))
                == .failure(.truncated)
        )
    }

    @Test("trailing extra bytes are tolerated and ignored")
    func trailingBytesTolerated() {
        let padded = Self.pinnedVector + "ff00ff"
        #expect(MMHello.decode(from: mpBytes(padded)) == .success(Self.pinnedHello))
    }

    @Test("decode does not consume the buffer")
    func decodeIsNonConsuming() {
        let buffer = mpBytes(Self.pinnedVector)
        let before = buffer.readerIndex
        _ = MMHello.decode(from: buffer)
        #expect(buffer.readerIndex == before)
    }
}
