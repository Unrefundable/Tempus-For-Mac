// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TempusKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SubsonicAPI", targets: ["SubsonicAPI"]),
    ],
    targets: [
        .target(name: "SubsonicAPI"),
        .testTarget(name: "SubsonicAPITests", dependencies: ["SubsonicAPI"]),
    ]
)
