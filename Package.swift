// swift-tools-version:6.4
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "MatterInMotion",
    platforms: [
        .macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27),
    ],
    products: [
        .library(name: "MMWire", targets: ["MMWire"]),
        .library(name: "MMSchema", targets: ["MMSchema"]),
        .library(name: "MMServer", targets: ["MMServer"]),
        .library(name: "MMClient", targets: ["MMClient"]),
        .library(name: "MMCLI", targets: ["MMCLI"]),
        .library(name: "MMContractLock", targets: ["MMContractLock"]),
        .plugin(name: "MMCLIGeneratorPlugin", targets: ["MMCLIGeneratorPlugin"]),
        .executable(name: "mm-example-daemon", targets: ["MMExampleDaemon"]),
        .executable(name: "mm-example-client", targets: ["MMExampleClient"]),
        .executable(name: "mm-example-cli", targets: ["MMExampleCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.82.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
        .package(url: "https://github.com/velocityzen/fp-swift.git", from: "4.9.0"),
        .package(url: "https://github.com/velocityzen/fp-swift-bracket.git", from: "3.0.3"),
        .package(url: "https://github.com/velocityzen/fp-swift-pipe.git", from: "2.5.2"),
        .package(url: "https://github.com/velocityzen/fp-swift-service.git", from: "0.2.3"),
        .package(url: "https://github.com/velocityzen/ProgramStatus.git", from: "0.4.1"),
        // Property-based tests. Test targets only, so the package's users
        // never fetch it.
        .package(url: "https://github.com/velocityzen/hegel-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "MMWire",
            dependencies: [
                "MMSchema",
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: callerIsolation
        ),
        .target(
            name: "MMSchemaCodeGenerator",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .macro(
            name: "MMSchemaMacros",
            dependencies: [
                "MMSchemaCodeGenerator",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "MMSchema",
            dependencies: ["MMSchemaMacros"],
            swiftSettings: callerIsolation
        ),
        .target(
            name: "MMServer",
            dependencies: [
                "MMWire",
                "MMSchema",
                .product(name: "FP", package: "fp-swift"),
                .product(name: "FPBracket", package: "fp-swift-bracket"),
                .product(name: "FPService", package: "fp-swift-service"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "ProgramStatus", package: "ProgramStatus"),
            ],
            swiftSettings: callerIsolation
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
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ],
            swiftSettings: callerIsolation
        ),
        .target(
            name: "MMCLI",
            dependencies: [
                "MMClient",
                "MMSchema",
                "MMWire",
                .product(name: "FP", package: "fp-swift"),
                .product(name: "FPBracket", package: "fp-swift-bracket"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ProcessSignals", package: "fp-swift-service"),
                .product(name: "ProgramStatus", package: "ProgramStatus"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: callerIsolation
        ),
        // A test helper: Foundation's JSON and file access stay out of the
        // runtime libraries.
        .target(
            name: "MMContractLock",
            dependencies: ["MMSchema", "MMClient"],
            swiftSettings: callerIsolation
        ),
        .executableTarget(
            name: "MMCLIGenerator",
            dependencies: [
                "MMSchemaCodeGenerator",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .plugin(
            name: "MMCLIGeneratorPlugin",
            capability: .buildTool(),
            dependencies: ["MMCLIGenerator"]
        ),
        .target(
            name: "MMExampleAPI",
            dependencies: ["MMSchema"],
            path: "Examples/API"
        ),
        .executableTarget(
            name: "MMExampleCLI",
            dependencies: [
                "MMExampleAPI",
                "MMSchema",
                "MMCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FPPipe", package: "fp-swift-pipe"),
                .product(name: "ProgramStatus", package: "ProgramStatus"),
            ],
            path: "Examples/CLI",
            plugins: ["MMCLIGeneratorPlugin"]
        ),
        .executableTarget(
            name: "MMExampleDaemon",
            dependencies: [
                "MMExampleAPI",
                "MMSchema",
                "MMServer",
                .product(name: "FPBracket", package: "fp-swift-bracket"),
                .product(name: "FPService", package: "fp-swift-service"),
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
            dependencies: [
                "MMWire",
                "MMSchema",
                "MMClient",
                .product(name: "NIOCore", package: "swift-nio"),
                "MMServer",
                .product(name: "FPBracket", package: "fp-swift-bracket"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
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
                "MMSchemaCodeGenerator",
                "MMSchema",
                "MMCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
                .product(name: "ProgramStatus", package: "ProgramStatus"),
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FPPipe", package: "fp-swift-pipe"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ProgramStatus", package: "ProgramStatus"),
            ],
            plugins: ["MMCLIGeneratorPlugin"]
        ),
        .testTarget(
            name: "MMContractLockTests",
            dependencies: ["MMContractLock", "MMClient", "MMSchema", "MMExampleAPI"],
            // The example contract's lock, which the tests read and write as
            // a file, not as a resource.
            exclude: ["Locks"]
        ),
        // Hegel's engine is built for macOS and Linux only, so on the other
        // platforms this target is empty: every file is behind
        // `#if os(macOS) || os(Linux)`.
        .testTarget(
            name: "MMPropertyTests",
            dependencies: [
                "MMCLI",
                "MMWire",
                "MMSchema",
                // `isValidLowerIdentifierPath`, the macros' namespace check,
                // and `#schema` expansions of drawn contracts.
                "MMSchemaCodeGenerator",
                "MMServer",
                "MMClient",
                "MMContractLock",
                "MMTestSupport",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(
                    name: "HegelTesting",
                    package: "hegel-swift",
                    condition: .when(platforms: [.macOS, .linux])
                ),
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
                .product(name: "FPBracket", package: "fp-swift-bracket"),
                .product(name: "FPService", package: "fp-swift-service"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

/// The library targets' async functions and closures run on the caller's
/// actor unless marked `@concurrent`, matching the fp-swift packages.
var callerIsolation: [SwiftSetting] { [.enableUpcomingFeature("NonisolatedNonsendingByDefault")] }
