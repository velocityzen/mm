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
        .executable(name: "mm-example-daemon", targets: ["MMExampleDaemon"]),
        .executable(name: "mm-example-client", targets: ["MMExampleClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        // Compile-time only (the #schema macro plugin); never linked into products.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .target(
            name: "MMWire",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio")
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
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),
        .target(
            name: "MMExampleAPI",
            dependencies: ["MMSchema"],
            path: "Examples/API"
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
            name: "MMIntegrationTests",
            dependencies: [
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
