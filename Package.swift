// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeridianBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MeridianBar", path: "Sources/MeridianBar"),
        .testTarget(
            name: "MeridianBarTests",
            dependencies: ["MeridianBar"],
            path: "Tests/MeridianBarTests"
        ),
    ]
)
