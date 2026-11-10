//
//  S3Tests.swift
//  CartoucheStorageTests
//
//  MinIO, as on a NAS: a private bucket, the player's keys, keys that can
//  only list and read it, and a region the requests must be signed for.
//

import Foundation
import XCTest
@testable import CartoucheStorage

final class S3Tests: StorageServerTests {
    override class var serverName: String? { "S3, MinIO" }

    private var s3: StorageServers.S3 { servers.s3 }

    /// The bucket as the player adds it in Cartouche: its address, its
    /// name, their access key ID and, when they give one, its region.
    private func server(accessKey: String, region: String?) -> CartoucheStorageServer {
        CartoucheStorageServer(kind: .s3, name: "MinIO", host: s3.address, username: accessKey, share: s3.bucket,
                               region: region)
    }

    override func connect() async throws -> CartoucheRemote {
        try await CartoucheS3.connect(server(accessKey: s3.accessKey, region: s3.region), secretKey: s3.secretKey)
    }

    override func connectWithAWrongPassword() async throws -> CartoucheRemote {
        try await CartoucheS3.connect(server(accessKey: s3.accessKey, region: s3.region), secretKey: "not-" + s3.secretKey)
    }

    override func readOnlyPlace() async throws -> (CartoucheRemote, String) {
        let remote = try await CartoucheS3.connect(server(accessKey: s3.readerAccessKey, region: s3.region),
                                                   secretKey: s3.readerSecretKey)
        return (remote, servers.games)
    }

    // Each read is a request of its own; a signed-out bucket sends none.
    override var signingOutCutsReads: Bool { false }

    func testNeedsTheKeys() async {
        let error = await thrownError {
            let remote = try await CartoucheS3.connect(self.server(accessKey: self.s3.accessKey, region: self.s3.region),
                                                       secretKey: "")
            await remote.disconnect()
        }
        XCTAssertEqual(error?.localizedDescription, CartoucheText.storageS3KeysNeeded)
    }

    func testRefusesKeysItDoesNotKnow() async {
        let error = await thrownError {
            let remote = try await CartoucheS3.connect(self.server(accessKey: "CARTOUCHEUNKNOWN", region: self.s3.region),
                                                       secretKey: self.s3.secretKey)
            await remote.disconnect()
        }
        XCTAssertNotNil(error, "signed in with keys MinIO does not know")
    }

    /// The player gave no region: Cartouche signs for us-east-1, MinIO says
    /// which region it is, and Cartouche signs for that one.
    func testSignsForTheRegionTheServerSays() async throws {
        let remote = track(try await CartoucheS3.connect(server(accessKey: s3.accessKey, region: nil), secretKey: s3.secretKey))
        let items = try await remote.list(servers.games)
        XCTAssertTrue(items.contains { $0.name == servers.smallName }, "\(items.map(\.name))")
        let folder = try await scratchFolder(remote)
        try await remote.write(Data("partie".utf8), to: CartoucheStoragePath.join(folder, "partie.txt"))
        let read = try await remote.read(CartoucheStoragePath.join(folder, "partie.txt"))
        XCTAssertEqual(read, Data("partie".utf8))
    }
}
