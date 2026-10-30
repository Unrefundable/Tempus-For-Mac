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
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "SubsonicAPI"),
        .target(name: "SecureStorage"),
        .target(
            name: "Persistence",
            dependencies: ["SubsonicAPI", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "Library", dependencies: ["SubsonicAPI", "Persistence"]),
        .testTarget(name: "SecureStorageTests", dependencies: ["SecureStorage"]),
        .testTarget(
            name: "SubsonicAPITests",
            dependencies: ["SubsonicAPI"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "SubsonicAPI"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Persistence", "SubsonicAPI"]),
    ]
)
