// swift-tools-version: 5.9
//
// Cartouche's storage, the code the app runs to reach the player's servers,
// built on its own and run against real ones on a throwaway Mac: Samba,
// MinIO, pyftpdlib and OpenSSH, which servers.sh starts there (README.md):
//
//     launcher/StorageTests/servers.sh start /tmp/cartouche-servers
//     CARTOUCHE_STORAGE_SERVERS=/tmp/cartouche-servers/servers.json \
//         swift test --package-path launcher/StorageTests
//
// Sources/CartoucheStorage links the launcher's own files (../../Sources),
// and SMBClient and swift-nio-ssh are pinned as the app pins them: the
// submodule app/SMBClient, and Package.resolved, which matches the one of
// app/patches/livecontainer/0007 (app/tests/test_storage_tests.py). Without
// CARTOUCHE_STORAGE_SERVERS, every test is skipped but OfflineTests,
// MacBridgeTests and SMBRefusalTests, which need no server.

import PackageDescription

let package = Package(
    name: "CartoucheStorageTests",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../app/SMBClient"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
    ],
    targets: [
        .target(
            name: "CartoucheStorage",
            dependencies: [
                .product(name: "SMBClient", package: "SMBClient"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/CartoucheStorage"
        ),
        .testTarget(
            name: "CartoucheStorageTests",
            dependencies: [
                "CartoucheStorage",
                // SMBClient's errors, which SMBRefusalTests makes as a
                // server's answers.
                .product(name: "SMBClient", package: "SMBClient"),
            ],
            path: "Tests/CartoucheStorageTests"
        ),
    ]
)
