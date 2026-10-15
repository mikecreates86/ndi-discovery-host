// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NDIDiscoveryHost",
    platforms: [.macOS(.v13)],
    targets: [
        // Foundation only: supervisor, health check, logging, stray cleanup. No UI.
        .target(name: "NDIHostCore"),
        // Menu bar UI. Thin layer over the core.
        .executableTarget(name: "NDIDiscoveryHost", dependencies: ["NDIHostCore"]),
        .testTarget(name: "NDIHostCoreTests", dependencies: ["NDIHostCore"]),
    ]
)
