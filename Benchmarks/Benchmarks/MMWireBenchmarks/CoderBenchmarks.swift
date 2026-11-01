import Benchmark
import MMWire

/// The payload coders, on the generated types. The encoder builds a tree of
/// nodes before it writes, and the decoder indexes each map, so allocations
/// grow with the number of fields and records.
func coderBenchmarks() {
    coderBenchmarks("scalar", Inventory.CountRequest(value: 42))
    coderBenchmarks("item", Inventory.PutRequest(item: .sample(1)))
    coderBenchmarks(
        "itemList",
        Inventory.ListResponse(items: (0..<100).map(Inventory.Item.sample)),
        // A hundred records per operation: a hundred operations per measured
        // iteration keep a run as long as the single-record ones.
        configuration: .init(scalingFactor: .one)
    )
}

private func coderBenchmarks<Value: Codable & Equatable>(
    _ shape: String,
    _ value: Value,
    configuration: Benchmark.Configuration = Benchmark.defaultConfiguration
) {
    let buffer = encoded(value)
    precondition(try! MMPackDecoder().decode(Value.self, from: buffer).get() == value)

    Benchmark("MMPackEncoder.\(shape)", configuration: configuration) { benchmark in
        let encoder = MMPackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(encoder.encode(value))
        }
    }

    Benchmark("MMPackDecoder.\(shape)", configuration: configuration) { benchmark in
        let decoder = MMPackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(decoder.decode(Value.self, from: buffer))
        }
    }
}
