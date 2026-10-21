// swift-tools-version:6.4
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
        .library(name: "MMClientService", targets: ["MMClientService"]),
        .library(name: "MMCLI", targets: ["MMCLI"]),
        .plugin(name: "MMCLIGeneratorPlugin", targets: ["MMCLIGeneratorPlugin"]),
        .executable(name: "mm-example-daemon", targets: ["MMExampleDaemon"]),
        .executable(name: "mm-example-client", targets: ["MMExampleClient"]),
        .executable(name: "mm-example-cli", targets: ["MMExampleCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.82.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
        .package(url: "https://github.com/velocityzen/fp-swift.git", from: "3.0.0"),
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
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),
        .target(
            name: "MMClientService",
            dependencies: [
                "MMClient",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .target(
            name: "MMCLI",
            dependencies: [
                "MMClient",
                "MMSchema",
                "MMWire",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
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
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            plugins: ["MMCLIGeneratorPlugin"]
        ),
        .testTarget(
            name: "MMIntegrationTests",
            dependencies: [
                "MMTestSupport",
                "MMServer",
                "MMClient",
                "MMClientService",
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
