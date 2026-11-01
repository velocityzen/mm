// swift-tools-version:6.4
// Standalone benchmark package: kept out of the library manifest so consumers
// of MatterInMotion never resolve or build the benchmark harness.

import PackageDescription

let package = Package(
    name: "MatterInMotionBenchmarks",
    // Matches the library's minimum.
    platforms: [.macOS(.v26)],
    dependencies: [
        // The name is set explicitly: SwiftPM otherwise takes it from the
        // checkout's directory name, which a git worktree names after itself.
        .package(name: "mm", path: ".."),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.82.0"),
        .package(url: "https://github.com/ordo-one/benchmark.git", from: "1.38.1"),
    ],
    targets: [
        .executableTarget(
            name: "MMWireBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "MMSchema", package: "mm"),
                .product(name: "MMWire", package: "mm"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Benchmarks/MMWireBenchmarks",
            swiftSettings: callerIsolation,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
        .executableTarget(
            name: "MMServerBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "MMSchema", package: "mm"),
                .product(name: "MMServer", package: "mm"),
                .product(name: "MMWire", package: "mm"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Benchmarks/MMServerBenchmarks",
            swiftSettings: callerIsolation,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

/// Like the library targets: async functions and closures run on the caller's
/// actor unless marked `@concurrent`.
var callerIsolation: [SwiftSetting] { [.enableUpcomingFeature("NonisolatedNonsendingByDefault")] }
