//
//  SFTPTests.swift
//  CartoucheStorageTests
//
//  OpenSSH, as on a NAS or a Mac with Remote Login: the player's account,
//  its home, a folder there it can only read, and the server's key, which
//  Cartouche keeps and checks before it sends the password.
//

import Foundation
import XCTest
@testable import CartoucheStorage

final class SFTPTests: StorageServerTests {
    override class var serverName: String? { "SFTP, OpenSSH" }

    private var sftp: StorageServers.SFTP { servers.sftp }

    /// The server as the player adds it in Cartouche.
    private func server() -> CartoucheStorageServer {
        CartoucheStorageServer(kind: .sftp, name: "OpenSSH", host: sftp.account.host, port: sftp.account.port,
                               username: sftp.account.user)
    }

    override func connect() async throws -> CartoucheRemote {
        try await CartoucheSFTPServer.connect(server(), password: sftp.account.password, knownKey: sftp.hostKey)
    }

    override func connectWithAWrongPassword() async throws -> CartoucheRemote {
        try await CartoucheSFTPServer.connect(server(), password: "not-" + sftp.account.password, knownKey: sftp.hostKey)
    }

    override func readOnlyPlace() async throws -> (CartoucheRemote, String) {
        (try await connect(), servers.readOnlyFolder)
    }

    override var rootPath: String? { sftp.home }

    /// When the player adds the server: Cartouche takes the key it shows,
    /// and keeps it.
    func testTakesTheServersKeyTheFirstTime() async throws {
        let remote = try await CartoucheSFTPServer.connect(server(), password: sftp.account.password, knownKey: nil)
        track(remote)
        XCTAssertTrue(CartoucheSFTP.sameKey(remote.hostKey, sftp.hostKey), "the server showed \(remote.hostKey)")
        let items = try await remote.list("")
        XCTAssertTrue(items.contains { $0.name == servers.games && $0.isFolder }, "\(items.map(\.name))")
    }

    /// Another key than the one kept: Cartouche stops before the password.
    func testRefusesAnotherKeyWithoutSendingThePassword() async throws {
        let mark = fileSize(sftp.log)
        let error = await thrownError {
            let remote = try await CartoucheSFTPServer.connect(self.server(), password: self.sftp.account.password,
                                                               knownKey: self.sftp.otherKey)
            await remote.disconnect()
        }
        XCTAssertEqual(error?.localizedDescription, CartoucheText.storageSFTPKeyChanged(sftp.account.host))
        // What sshd logged of the connection, once it saw it close.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let log = try logged(in: sftp.log, since: mark)
        XCTAssertFalse(log.contains("password for"), "the server was sent a password:\n\(log)")
    }
}
