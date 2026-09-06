// swift-tools-version: 5.9
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
