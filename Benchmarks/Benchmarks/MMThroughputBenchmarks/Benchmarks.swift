import Benchmark

// Run from the repository root:
//
//     swift package --disable-sandbox --package-path Benchmarks benchmark \
//         --target MMThroughputBenchmarks
//
// `--disable-sandbox` because the wire and total benchmarks bind Unix
// sockets, which SwiftPM's sandbox around a plugin command refuses.
//
// Messages per second, and the time they take, for each payload in
// Payloads.swift:
//
// - `OneWay` messages are stream elements: no message answers another.
// - A `TwoWay` operation is one call: a request and the response it answers.
//
// Each direction is measured stage by stage, then whole:
//
// - `encode`: the payload, its envelope and its frame header, as the sender
//   writes them.
// - `wire`: the framed bytes crossing a Unix socket between two NIO channels,
//   with nothing encoded or decoded.
// - `decode`: the frame, the envelope and the payload, as the receiver reads
//   them.
// - `total`: an MMClient and an MMService on one Unix socket, through the
//   public API: the stages above plus the router, flow control and the
//   connections' tasks.
//
// These are timings, so they vary with the machine and its load: CI's
// threshold check skips this target.

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.throughput, .wallClock],
        // Each measured iteration moves 1000 messages
        // (`benchmark.scaledIterations`).
        scalingFactor: .kilo,
        maxDuration: .seconds(3),
        maxIterations: 50
    )

    throughputBenchmarks(Throughput.Scalar.self)
    throughputBenchmarks(Throughput.Record.self)
    throughputBenchmarks(Throughput.Listing.self)
}

/// Every stage of `Payload`'s one-way and two-way messages, then their totals.
private func throughputBenchmarks<Payload: ThroughputPayload>(_ payload: Payload.Type) {
    stageBenchmarks(payload)
    wireBenchmarks(payload)
    totalBenchmarks(payload)
}
