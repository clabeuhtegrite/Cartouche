// swift-tools-version: 5.9
//
// The launcher's parts that need neither LiveContainer nor UIKit, built and
// tested on their own on a Mac, as the App workflow does before it builds
// Cartouche:
//
//     swift test --package-path launcher
//
// The app compiles the same files from Sources/ with the rest of the
// launcher (app/scripts/prepare.sh); only those listed here are built.

import PackageDescription

let package = Package(
    name: "CartoucheCore",
    platforms: [.macOS(.v13), .iOS(.v15)],
    targets: [
        .target(
            name: "CartoucheCore",
            path: "Sources",
            exclude: ["Cartouche.xcstrings"],
            sources: ["CartoucheCoverList.swift", "CartoucheFTP.swift", "CartoucheGameBuild.swift", "CartoucheRelease.swift", "CartoucheResumingSource.swift", "CartoucheS3.swift", "CartoucheSFTP.swift", "CartoucheSignInMessage.swift", "CartoucheZip.swift"]
        ),
        .testTarget(
            name: "CartoucheCoreTests",
            dependencies: ["CartoucheCore"],
            path: "Tests/CartoucheCoreTests"
        ),
    ]
)
