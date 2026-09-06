// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .executable(name: "claude-bridge", targets: ["ClaudeBridgeApp"]),
        .executable(name: "claude-bridged", targets: ["claude-bridged"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "BridgeCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(name: "ClaudeBridgeApp", dependencies: ["BridgeCore"]),
        .executableTarget(name: "claude-bridged", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)
