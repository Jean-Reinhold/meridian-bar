// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeridianBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The single sanctioned third-party dependency (okf/03, okf/06):
        // update plumbing is exactly the code you don't hand-roll.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
    ],
    targets: [
        .executableTarget(
            name: "MeridianBar",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/MeridianBar",
            linkerSettings: [
                // Sparkle.framework is bundled into Contents/Frameworks by
                // `make app`; tests resolve it from the SPM artifact rpath.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "MeridianBarTests",
            dependencies: ["MeridianBar"],
            path: "Tests/MeridianBarTests"
        ),
    ]
)
