// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "AIUsage", targets: ["AIUsage"])
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "AIUsage", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ],
    swiftLanguageModes: [.v6]
)
