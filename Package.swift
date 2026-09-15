// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HarnessUsageCore"),
        .executableTarget(name: "HarnessUsage", dependencies: ["HarnessUsageCore"]),
        .testTarget(name: "HarnessUsageCoreTests", dependencies: ["HarnessUsageCore"]),
        // Narrow macOS logic tests for callback sockets, login sequencing, and account presentation.
        // They use disposable ports/homes and injected seams; no browser or rendered UI is involved.
        .testTarget(name: "HarnessUsageTests", dependencies: ["HarnessUsage", "HarnessUsageCore"]),
    ]
)
