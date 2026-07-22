// swift-tools-version:6.0
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "MatterInMotion",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MMWire", targets: ["MMWire"]),
        .library(name: "MMSchema", targets: ["MMSchema"]),
        .library(name: "MMServer", targets: ["MMServer"]),
        .library(name: "MMClient", targets: ["MMClient"]),
        .library(name: "MMCLI", targets: ["MMCLI"]),
        .executable(name: "mm-example-daemon", targets: ["MMExampleDaemon"]),
        .executable(name: "mm-example-client", targets: ["MMExampleClient"]),
        .executable(name: "mm-example-cli", targets: ["MMExampleCLI"]),
    ],
    dependencies: [
        // 2.82 floor: ByteBuffer.peekInteger / peekMultipleIntegers.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.82.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // 2.11 floor: Timer.record(duration:).
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.11.0"),
        // 1.7.0 floor: generated commands use CommandConfiguration(aliases:).
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        // Compile-time only (the #schema macro plugin); never linked into products.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
        // Functional Result/Optional utilities (async map/match/tap).
        .package(url: "https://github.com/velocityzen/fp-swift.git", from: "3.0.0"),
        // Monadic acquire/use/release for resources with a lifecycle.
        .package(url: "https://github.com/velocityzen/fp-swift-bracket.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "MMWire",
            dependencies: [
                "MMSchema",
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .macro(
            name: "MMSchemaMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "MMSchema",
            dependencies: ["MMSchemaMacros"]
        ),
        .target(
            name: "MMServer",
            dependencies: [
                "MMWire",
                "MMSchema",
                .product(name: "FP", package: "fp-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),
        .target(
            name: "MMClient",
            dependencies: [
                "MMWire",
                "MMSchema",
                .product(name: "FP", package: "fp-swift"),
                .product(name: "FPBracket", package: "fp-swift-bracket"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),
        .target(
            name: "MMCLI",
            dependencies: [
                "MMClient",
                "MMSchema",
                "MMWire",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "MMExampleAPI",
            // ArgumentParser + MMCLI activate `#schema(cli: .enabled)` — the
            // documented tradeoff: the daemon transitively links both (inert).
            dependencies: [
                "MMSchema",
                "MMCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/API"
        ),
        .executableTarget(
            name: "MMExampleCLI",
            dependencies: [
                "MMExampleAPI",
                "MMSchema",
                "MMCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Examples/CLI"
        ),
        .executableTarget(
            name: "MMExampleDaemon",
            dependencies: [
                "MMExampleAPI",
                "MMSchema",
                "MMServer",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Examples/Daemon"
        ),
        .executableTarget(
            name: "MMExampleClient",
            dependencies: [
                "MMExampleAPI",
                "MMSchema",
                "MMClient",
                "MMWire",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Examples/Client"
        ),
        .target(
            name: "MMTestSupport",
            // Shared test harness (deadlines, temp sockets, ServiceGroup and
            // client run-loop choreography, wire fixtures). Lives under
            // Tests/, is depended on only by test targets, and ships in no
            // product.
            dependencies: [
                "MMWire",
                "MMSchema",
                "MMClient",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/MMTestSupport"
        ),
        .testTarget(
            name: "MMWireTests",
            dependencies: [
                "MMWire",
                "MMSchema",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "MMSchemaTests",
            dependencies: ["MMSchema"]
        ),
        .testTarget(
            name: "MMSchemaMacrosTests",
            dependencies: [
                "MMSchemaMacros",
                "MMSchema",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "MMServerTests",
            dependencies: [
                "MMTestSupport",
                "MMServer",
                "MMWire",
                "MMSchema",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),
        .testTarget(
            name: "MMClientTests",
            dependencies: [
                "MMTestSupport",
                "MMClient",
                "MMWire",
                "MMSchema",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "MMCLITests",
            dependencies: [
                "MMTestSupport",
                "MMCLI",
                "MMSchema",
                "MMClient",
                "MMServer",
                "MMWire",
                // The reserved-option pin test compares the macro's literal
                // list against MMCLIOptions's declared surface.
                "MMSchemaMacros",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "MMIntegrationTests",
            dependencies: [
                "MMTestSupport",
                "MMServer",
                "MMClient",
                "MMWire",
                "MMSchema",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
