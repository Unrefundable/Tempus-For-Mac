// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TempusKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SubsonicAPI", targets: ["SubsonicAPI"]),
        .library(name: "SecureStorage", targets: ["SecureStorage"]),
    ],
    targets: [
        .target(name: "SubsonicAPI"),
        .target(name: "SecureStorage"),
        .testTarget(name: "SecureStorageTests", dependencies: ["SecureStorage"]),
        .testTarget(
            name: "SubsonicAPITests",
            dependencies: ["SubsonicAPI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
