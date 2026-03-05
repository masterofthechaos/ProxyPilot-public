// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProxyPilotCLI",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../ProxyPilotCore"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "proxypilot",
            dependencies: [
                "ProxyPilotCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources"
        ),
    ]
)
