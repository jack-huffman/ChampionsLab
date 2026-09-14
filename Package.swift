// swift-tools-version: 5.9
//  ChampionsLab — a Pokémon Champions team-building and battle-analysis app.
//
//  One library holds the model, the engine and the interface; the executable
//  is a single file that shows its scene; the tests import the library with
//  @testable. The tools under Tools/ compile the library's sources directly,
//  since they need internal access and are not tests.

import PackageDescription

let package = Package(
    name: "ChampionsLab",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ChampionsLabApp", targets: ["ChampionsLabApp"]),
        .library(name: "ChampionsLab", targets: ["ChampionsLab"]),
    ],
    targets: [
        .target(
            name: "ChampionsLab",
            path: "Sources/ChampionsLab"
        ),
        .executableTarget(
            name: "ChampionsLabApp",
            dependencies: ["ChampionsLab"],
            path: "Sources/ChampionsLabApp"
        ),
        .testTarget(
            name: "ChampionsLabTests",
            dependencies: ["ChampionsLab"],
            path: "Tests/ChampionsLabTests"
        ),
    ]
)
