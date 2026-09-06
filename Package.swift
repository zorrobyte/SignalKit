// swift-tools-version: 5.9
// Build with Xcode 26.5 or newer: HealthTypeCatalog references identifiers from the
// iOS 26 SDK. Deployment stays iOS 17. Language mode is Swift 5; CI also proves a
// warning-free Swift 6 strict-concurrency build.
import PackageDescription

let package = Package(
    name: "SignalKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DurableSync", targets: ["DurableSync"]),
        .library(name: "ActivityTracking", targets: ["ActivityTracking"]),
        .library(name: "HealthSync", targets: ["HealthSync"]),
    ],
    targets: [
        .target(name: "DurableSync"),
        .target(name: "ActivityTracking", dependencies: ["DurableSync"]),
        .target(name: "HealthSync", dependencies: ["DurableSync"]),
        .target(name: "SignalKitExamples", dependencies: ["ActivityTracking", "HealthSync", "DurableSync"], path: "Examples"),
        .testTarget(name: "ExampleTests", dependencies: ["SignalKitExamples"]),
        .testTarget(name: "DurableSyncTests", dependencies: ["DurableSync"]),
        .testTarget(name: "ActivityTrackingTests", dependencies: ["ActivityTracking"]),
        .testTarget(name: "HealthSyncTests", dependencies: ["HealthSync"]),
    ]
)
