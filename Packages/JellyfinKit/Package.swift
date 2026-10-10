// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JellyfinKit",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "JellyfinKit", targets: ["JellyfinKit"])
    ],
    targets: [
        .target(name: "JellyfinKit"),
        .testTarget(name: "JellyfinKitTests", dependencies: ["JellyfinKit"]),
    ]
)
