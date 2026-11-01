import Benchmark
import MMWire
import NIOCore

/// Every frame on a connection is one envelope, so these run once per call
/// (request and response) and once per stream element (item).
func envelopeBenchmarks() {
    let envelopes: [(kind: String, envelope: MMEnvelope)] = [
        (
            "request",
            .request(
                msgid: 7,
                method: "inventory.put",
                entity: "store.aisle",
                params: encoded(Inventory.PutRequest(item: .sample(1)))
            )
        ),
        (
            "response",
            .response(msgid: 7, error: nil, result: encoded(Inventory.PutResponse(count: 42)))
        ),
        ("item", .item(msgid: 7, seq: 3, item: encoded(Inventory.Item.sample(1)))),
    ]

    for (kind, envelope) in envelopes {
        let frame = try! envelope.encoded().get()
        precondition(try! MMEnvelope.decode(from: frame).get() == envelope)

        // Encoding first validates each raw slot (params, result, item) with a
        // structural walk, so the cost grows with the payload.
        Benchmark("MMEnvelope.encode.\(kind)") { benchmark in
            var buffer = ByteBuffer()
            buffer.reserveCapacity(frame.readableBytes)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                buffer.clear()
                blackHole(envelope.encode(into: &buffer))
            }
            benchmark.stopMeasurement()
        }

        Benchmark("MMEnvelope.decode.\(kind)") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(MMEnvelope.decode(from: frame))
            }
        }
    }
}
