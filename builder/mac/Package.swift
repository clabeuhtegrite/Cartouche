// swift-tools-version: 6.0
//
// Cartouche Builder's Mac app: the player's games with their covers, what
// nxnative improved and the rebuilds it calls for, the builds as they run,
// what the builder keeps on the Mac, and the bridge that shares the games
// with Cartouche on the iPhone. The builder's engine (../cartouche_builder,
// Python) does the work; the app runs its JSON commands and follows its
// batches.
//
//     swift build -c release --package-path builder/mac
//     builder/mac/bundle.sh "$HOME/Applications"     # the .app, signed ad hoc
//     swift test --package-path builder/mac

import PackageDescription

let package = Package(
    name: "CartoucheBuilder",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "CartoucheBuilder", targets: ["CartoucheBuilder"]),
    ],
    dependencies: [
        // The bridge to Cartouche (launcher/Sources/CartoucheBridge.swift).
        .package(path: "../../launcher"),
    ],
    targets: [
        .target(
            name: "BuilderKit",
            dependencies: [.product(name: "CartoucheCore", package: "launcher")],
            path: "Sources/BuilderKit"
        ),
        .executableTarget(
            name: "CartoucheBuilder",
            dependencies: ["BuilderKit", .product(name: "CartoucheCore", package: "launcher")],
            path: "Sources/CartoucheBuilder"
        ),
        // The fixtures are the engine's answers, read from their folder
        // (builder/tests/test_app_contract.py writes them).
        .testTarget(
            name: "BuilderKitTests",
            dependencies: ["BuilderKit", .product(name: "CartoucheCore", package: "launcher")],
            path: "Tests/BuilderKitTests",
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
