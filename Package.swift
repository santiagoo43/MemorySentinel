// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MemorySentinel", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MemorySentinel", targets: ["MemorySentinel"]),
    .executable(name: "sentinel-diagnostics", targets: ["SentinelDiagnostics"]),
  ],
  targets: [
    .target(name: "CSystem", linkerSettings: [.linkedLibrary("proc"), .linkedLibrary("sqlite3")]),
    .target(name: "SentinelCore", dependencies: ["CSystem"]),
    .executableTarget(name: "MemorySentinel", dependencies: ["SentinelCore"]),
    .executableTarget(name: "SentinelDiagnostics", dependencies: ["SentinelCore", "CSystem"]),
    .executableTarget(
      name: "SentinelCoreTests", dependencies: ["SentinelCore"], path: "Tests/SentinelCoreTests"),
  ]
)
