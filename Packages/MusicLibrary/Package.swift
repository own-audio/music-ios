// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicLibrary",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MusicLibrary", targets: ["MusicLibrary"])
    ],
    dependencies: [
        .package(path: "../ServerSupport"),
        .package(path: "../SubsonicKit"),
        .package(path: "../JellyfinKit"),
        .package(path: "../OwnAudioKit"),
    ],
    targets: [
        // The app's view of any server: one set of models, one interface, an adapter per kind.
        .target(name: "MusicLibrary", dependencies: ["ServerSupport", "SubsonicKit", "JellyfinKit", "OwnAudioKit"]),
        .testTarget(name: "MusicLibraryTests", dependencies: ["MusicLibrary"]),
    ]
)
