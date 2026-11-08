// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "MacWright",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.1"),
    ],
    targets: [
        // Pure logic + the HTTP/MCP host: unit-testable without permissions.
        .target(
            name: "MacWrightCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu-bar app and the event/screen/AX tools.
        .executableTarget(
            name: "MacWright",
            dependencies: ["MacWrightCore", .product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Permission check, run inside a terminal: does the app hosting it (and so any agent there)
        // hold the permissions that would let it skip MacWright's lock?
        .executableTarget(
            name: "macwright-check",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Test runner: YAML/JSON step files run against the MCP server (no permissions of its own).
        .target(
            name: "MacWrightRunnerCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk"), .product(name: "Yams", package: "Yams")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "macwright-run",
            dependencies: ["MacWrightRunnerCore", .product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacWrightRunnerTests",
            dependencies: ["MacWrightRunnerCore", .product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacWrightCoreTests",
            dependencies: ["MacWrightCore", .product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
