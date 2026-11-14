import Benchmark
import MMWire
import NIOCore
import NIOEmbedded

/// The encode and decode stages of `Payload`'s messages, each on its own.
/// Encode is the sender's work for one message: the payload through its
/// generated MessagePack code, its envelope, and its frame header. Decode is
/// the receiver's: the frame through the connection's frame decoder, its
/// envelope, and the payload. A two-way operation counts both of a call's
/// messages, its request and its response.
func stageBenchmarks<Payload: ThroughputPayload>(_ payload: Payload.Type) {
    let frames = ThroughputFrames(payload)
    let sample = Payload.sample
    let method = Payload.echo.name

    Benchmark("OneWay.encode.\(Payload.shape)") { benchmark in
        var writer = MessageWriter()
        benchmark.startMeasurement()
        for seq in benchmark.scaledIterations {
            let item = try MMPackEncoder().encode(sample).get()
            try writer.write(.item(msgid: 1, seq: UInt32(seq), item: item))
        }
        benchmark.stopMeasurement()
    }

    Benchmark("TwoWay.encode.\(Payload.shape)") { benchmark in
        var writer = MessageWriter()
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let params = try MMPackEncoder().encode(sample).get()
            try writer.write(
                .request(msgid: 1, method: method, entity: throughputEntity, params: params)
            )
            let result = try MMPackEncoder().encode(sample).get()
            try writer.write(.response(msgid: 1, error: nil, result: result))
        }
        benchmark.stopMeasurement()
    }

    Benchmark("OneWay.decode.\(Payload.shape)") { benchmark in
        let count = benchmark.scaledIterations.count
        let input = repeated([frames.item], count: count)
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(MMFrameDecoder()))
        benchmark.startMeasurement()
        let decoded = try readPayloads(Payload.self, from: channel, input: input)
        benchmark.stopMeasurement()
        precondition(decoded == count, "decoded \(decoded) of \(count) elements")
        _ = try channel.finish()
    }

    Benchmark("TwoWay.decode.\(Payload.shape)") { benchmark in
        let count = benchmark.scaledIterations.count
        let input = repeated([frames.request, frames.response], count: count)
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(MMFrameDecoder()))
        benchmark.startMeasurement()
        let decoded = try readPayloads(Payload.self, from: channel, input: input)
        benchmark.stopMeasurement()
        precondition(decoded == 2 * count, "decoded \(decoded) of \(2 * count) messages")
        _ = try channel.finish()
    }
}

/// Writes envelopes the way a connection sends them: each one encoded, then
/// framed, into buffers reused from message to message.
private struct MessageWriter {
    private let frameEncoder = MMFrameEncoder()
    private var envelope = ByteBuffer()
    private var frame = ByteBuffer()

    mutating func write(_ message: MMEnvelope) throws {
        self.envelope.clear()
        try message.encode(into: &self.envelope).get()
        self.frame.clear()
        try self.frameEncoder.encode(data: self.envelope, out: &self.frame)
        blackHole(self.frame)
    }
}

/// `frames`, `count` times over, in one buffer: as many messages as a peer
/// that pipelines them sends in one read.
private func repeated(_ frames: [ByteBuffer], count: Int) -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.reserveCapacity(count * frames.reduce(0) { $0 + $1.readableBytes })
    for _ in 0..<count {
        for frame in frames {
            buffer.writeImmutableBuffer(frame)
        }
    }
    return buffer
}

/// Feeds `input` to the frame decoder on `channel`, then decodes each frame's
/// envelope and its payload slot as `Payload`. Returns how many it decoded.
private func readPayloads<Payload: ThroughputPayload>(
    _ payload: Payload.Type,
    from channel: EmbeddedChannel,
    input: ByteBuffer
) throws -> Int {
    let decoder = MMPackDecoder()
    try channel.writeInbound(input)
    var decoded = 0
    while let frame = try channel.readInbound(as: ByteBuffer.self) {
        switch try MMEnvelope.decode(from: frame).get() {
            case .item(_, _, let item):
                blackHole(try decoder.decode(Payload.self, from: item).get())
            case .request(_, _, _, let params):
                blackHole(try decoder.decode(Payload.self, from: params).get())
            case .response(_, nil, let result?):
                blackHole(try decoder.decode(Payload.self, from: result).get())
            default:
                preconditionFailure("a frame that carries no \(Payload.self)")
        }
        decoded += 1
    }
    return decoded
}
