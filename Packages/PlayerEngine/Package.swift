// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "player-engine",
    // macOS only so `swift test` runs on the host without a simulator.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // What an app imports to play music. It re-exports PlayerCore.
        .library(name: "MusicEngine", targets: ["MusicEngine"]),
        // The parts every kind of player shares: Now Playing, sleep timer, resume points, the
        // file cache. A spoken-word engine (audiobooks, podcasts) will build on it too.
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
    ],
    targets: [
        .target(name: "PlayerCore"),
        .target(name: "MusicEngine", dependencies: ["PlayerCore"]),
        .testTarget(
            name: "PlayerEngineTests",
            dependencies: ["MusicEngine", "PlayerCore"],
            // Short synthesized tones, so the decoder is tested against real audio bytes.
            resources: [.copy("Fixtures")]
        ),
    ]
)
