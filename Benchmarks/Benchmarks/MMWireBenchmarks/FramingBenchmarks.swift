import Benchmark
import MMWire
import NIOCore
import NIOEmbedded

/// The length-prefix framing, through the same NIO handlers a connection's
/// pipeline runs.
func framingBenchmarks() {
    let payload = try! MMEnvelope.request(
        msgid: 7,
        method: "inventory.put",
        entity: "store.aisle",
        params: encoded(Inventory.PutRequest(item: .sample(1)))
    ).encoded().get()

    Benchmark("MMFrameEncoder.encode") { benchmark in
        let encoder = MMFrameEncoder()
        var buffer = ByteBuffer()
        buffer.reserveCapacity(4 + payload.readableBytes)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            buffer.clear()
            try encoder.encode(data: payload, out: &buffer)
        }
        benchmark.stopMeasurement()
    }

    // Every frame arrives in one read, as when a peer pipelines calls.
    Benchmark("MMFrameDecoder.oneRead") { benchmark in
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(MMFrameDecoder()))
        let input = frames(of: payload, count: benchmark.scaledIterations.count)
        benchmark.startMeasurement()
        try channel.writeInbound(input)
        try readFrames(from: channel, expecting: benchmark.scaledIterations.count)
        benchmark.stopMeasurement()
        _ = try channel.finish()
    }

    // The same frames in 1 KiB reads that split them anywhere, as a socket
    // delivers a stream: the decoder holds partial frames between reads.
    Benchmark("MMFrameDecoder.splitReads") { benchmark in
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(MMFrameDecoder()))
        var input = frames(of: payload, count: benchmark.scaledIterations.count)
        var reads: [ByteBuffer] = []
        while input.readableBytes > 0 {
            reads.append(input.readSlice(length: min(1024, input.readableBytes))!)
        }
        benchmark.startMeasurement()
        for read in reads {
            try channel.writeInbound(read)
        }
        try readFrames(from: channel, expecting: benchmark.scaledIterations.count)
        benchmark.stopMeasurement()
        _ = try channel.finish()
    }
}

/// `count` copies of `payload`, each framed, in one buffer.
private func frames(of payload: ByteBuffer, count: Int) -> ByteBuffer {
    let encoder = MMFrameEncoder()
    var buffer = ByteBuffer()
    buffer.reserveCapacity(count * (4 + payload.readableBytes))
    for _ in 0..<count {
        try! encoder.encode(data: payload, out: &buffer)
    }
    return buffer
}

private func readFrames(from channel: EmbeddedChannel, expecting count: Int) throws {
    var read = 0
    while let frame = try channel.readInbound(as: ByteBuffer.self) {
        blackHole(frame)
        read += 1
    }
    precondition(read == count, "the decoder emitted \(read) of \(count) frames")
}
