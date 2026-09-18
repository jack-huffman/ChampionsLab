// swift-tools-version: 6.0
//  ChampionsLab — a Pokémon Champions team-building and battle-analysis app.
//
//  One library holds the model, the engine and the interface; the executable
//  is a single file that shows its scene; the tests import the library with
//  @testable. The tools under Tools/ compile the library's sources directly,
//  since they need internal access and are not tests.
//
//  Swift 6 language mode, which is the point of the Rulebook: the compiler
//  checks that the engine touches no shared mutable state, rather than the
//  author promising it. Anything that has to be shared across threads goes
//  through `Memo`, which owns a lock, or is explicitly marked unsafe with a
//  reason beside it.

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
            path: "Sources/ChampionsLab",
            // -enable-testing in release as well as debug, so the snapshot
            // tool can reach the app's internals with @testable and still be
            // built optimised: unoptimised it renders forty-two screens in
            // nine minutes, optimised in a fraction of that, and the shots
            // are the slowest thing about changing a screen.
            swiftSettings: [.swiftLanguageMode(.v6),
                            .unsafeFlags(["-enable-testing"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "ChampionsLabApp",
            dependencies: ["ChampionsLab"],
            path: "Sources/ChampionsLabApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The snapshot tool as a target rather than a from-scratch swiftc of
        // every source: the same incremental build everything else gets.
        .executableTarget(
            name: "Snapshot",
            dependencies: ["ChampionsLab"],
            path: "Tools/snapshot",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ChampionsLabTests",
            dependencies: ["ChampionsLab"],
            path: "Tests/ChampionsLabTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
