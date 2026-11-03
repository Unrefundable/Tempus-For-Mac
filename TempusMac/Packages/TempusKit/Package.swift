// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TempusKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SubsonicAPI", targets: ["SubsonicAPI"]),
        .library(name: "SecureStorage", targets: ["SecureStorage"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Library", targets: ["Library"]),
        .library(name: "Playback", targets: ["Playback"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        // Patched for gapless MP3/AAC, redirects and pitch; see Vendor/AudioStreaming/TEMPUS-PATCHES.md.
        .package(path: "../../Vendor/AudioStreaming"),
    ],
    targets: [
        .target(name: "SubsonicAPI"),
        .target(name: "SecureStorage"),
        .target(
            name: "Persistence",
            dependencies: ["SubsonicAPI", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "Library", dependencies: ["SubsonicAPI", "Persistence"]),
        .target(
            name: "Playback",
            dependencies: ["SubsonicAPI", "Persistence", .product(name: "AudioStreaming", package: "AudioStreaming")]
        ),
        // Icons, colors and Inter come from upstream through scripts/import-tempus-assets.swift.
        .target(name: "DesignSystem", resources: [.process("Resources")]),
        .testTarget(name: "SecureStorageTests", dependencies: ["SecureStorage"]),
        .testTarget(
            name: "SubsonicAPITests",
            dependencies: ["SubsonicAPI"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "SubsonicAPI"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Persistence", "SubsonicAPI"]),
        .testTarget(name: "PlaybackTests", dependencies: ["Playback", "Persistence", "SubsonicAPI"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ]
)
