// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiquidPhotos",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "LiquidPhotos", targets: ["LiquidPhotos"]),
    ],
    targets: [
        .target(
            name: "LiquidPhotos",
            resources: [.process("Shaders")]
        ),
        .testTarget(name: "LiquidPhotosTests", dependencies: ["LiquidPhotos"]),
    ]
)
