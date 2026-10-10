// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SubsonicKit",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SubsonicKit", targets: ["SubsonicKit"])
    ],
    dependencies: [
        .package(path: "../ServerSupport")
    ],
    targets: [
        // Re-exports ServerSupport's cache and offline switch, which its client takes.
        .target(name: "SubsonicKit", dependencies: ["ServerSupport"]),
        .testTarget(name: "SubsonicKitTests", dependencies: ["SubsonicKit"]),
    ]
)
