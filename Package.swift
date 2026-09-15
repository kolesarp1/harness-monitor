// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HarnessUsageCore"),
        .executableTarget(name: "HarnessUsage", dependencies: ["HarnessUsageCore"]),
        .testTarget(name: "HarnessUsageCoreTests", dependencies: ["HarnessUsageCore"]),
    ]
)
