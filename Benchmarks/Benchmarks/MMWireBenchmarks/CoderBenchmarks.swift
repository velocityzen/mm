import Benchmark
import MMSchema
import MMWire

/// The payload coders, on the generated types: through their `Codable`
/// conformances, through the MessagePack code the schema macro generated for
/// them (the `generated` benchmarks), which the router takes, and through that
/// code found by a check on each call (the `checkingForGeneratedCode`
/// benchmarks), which the client's unary calls take.
func coderBenchmarks() {
    let item = Inventory.PutRequest(item: .sample(1))
    let itemList = Inventory.ListResponse(items: (0..<100).map(Inventory.Item.sample))
    // A hundred records per operation: a hundred operations per measured
    // iteration keep a run as long as the single-record ones.
    let listConfiguration = Benchmark.Configuration(scalingFactor: .one)
    coderBenchmarks("scalar", Inventory.CountRequest(value: 42))
    coderBenchmarks("item", item)
    coderBenchmarks("itemList", itemList, configuration: listConfiguration)
    generatedCoderBenchmarks("scalar", Inventory.CountRequest(value: 42))
    generatedCoderBenchmarks("item", item)
    generatedCoderBenchmarks("itemList", itemList, configuration: listConfiguration)
    checkingCoderBenchmarks("scalar", Inventory.CountRequest(value: 42))
    checkingCoderBenchmarks("item", item)
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

/// Generic over the generated conformances, so the coders' overloads for
/// generated code are the ones called.
private func generatedCoderBenchmarks<Value: MMPackCodable & Equatable>(
    _ shape: String,
    _ value: Value,
    configuration: Benchmark.Configuration = Benchmark.defaultConfiguration
) {
    let buffer = encoded(value)
    precondition(try! MMPackEncoder().encode(value).get() == buffer)
    precondition(try! MMPackDecoder().decode(Value.self, from: buffer).get() == value)

    Benchmark("MMPackEncoder.generated.\(shape)", configuration: configuration) { benchmark in
        let encoder = MMPackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(encoder.encode(value))
        }
    }

    Benchmark("MMPackDecoder.generated.\(shape)", configuration: configuration) { benchmark in
        let decoder = MMPackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(decoder.decode(Value.self, from: buffer))
        }
    }
}

/// Generic over `Codable` only, as the client's calls are, so each call has to
/// check for the generated code.
private func checkingCoderBenchmarks<Value: Codable & Sendable & Equatable>(
    _ shape: String,
    _ value: Value,
    configuration: Benchmark.Configuration = Benchmark.defaultConfiguration
) {
    let buffer = encoded(value)
    precondition(try! MMPackEncoder().encodeCheckingForGeneratedCode(value).get() == buffer)
    precondition(
        try! MMPackDecoder().decodeCheckingForGeneratedCode(Value.self, from: buffer).get()
            == value
    )

    Benchmark(
        "MMPackEncoder.checkingForGeneratedCode.\(shape)",
        configuration: configuration
    ) { benchmark in
        let encoder = MMPackEncoder()
        for _ in benchmark.scaledIterations {
            blackHole(encoder.encodeCheckingForGeneratedCode(value))
        }
    }

    Benchmark(
        "MMPackDecoder.checkingForGeneratedCode.\(shape)",
        configuration: configuration
    ) { benchmark in
        let decoder = MMPackDecoder()
        for _ in benchmark.scaledIterations {
            blackHole(decoder.decodeCheckingForGeneratedCode(Value.self, from: buffer))
        }
    }
}
