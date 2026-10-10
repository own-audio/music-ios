// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JellyfinKit",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "JellyfinKit", targets: ["JellyfinKit"])
    ],
    dependencies: [
        .package(path: "../ServerSupport")
    ],
    targets: [
        // Re-exports ServerSupport's cache and offline switch, which its client takes.
        .target(name: "JellyfinKit", dependencies: ["ServerSupport"]),
        .testTarget(name: "JellyfinKitTests", dependencies: ["JellyfinKit"]),
    ]
)
