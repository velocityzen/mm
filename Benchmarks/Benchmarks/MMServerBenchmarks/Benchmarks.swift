import Benchmark

// Run from the repository root:
//
//     swift package --package-path Benchmarks benchmark
//
// Only counters that come out the same on every run are measured, so CI can
// hold them to the thresholds saved in Benchmarks/Thresholds. Add
// `--metric wallClock` to time a run locally.
//
// `mallocFreeDelta` (allocations not freed by the end of the measurement) is
// the leak counter: package-benchmark's malloc interposer does not produce
// `memoryLeaked`.

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.mallocCountTotal, .mallocFreeDelta, .syscalls],
        // Each measured iteration runs its operation 1000 times
        // (`benchmark.scaledIterations`).
        scalingFactor: .kilo,
        maxDuration: .seconds(5),
        maxIterations: 100
    )

    routerBenchmarks()
}
