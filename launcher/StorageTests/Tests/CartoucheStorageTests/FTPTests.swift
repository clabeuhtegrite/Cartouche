//
//  FTPTests.swift
//  CartoucheStorageTests
//
//  pyftpdlib, as a NAS's FTP server: the player's account, which can only
//  read one of its folders, and an account that can only read. FTPTests
//  runs on a server that lists folders with MLSD (RFC 3659), FTPListTests
//  on one that has only LIST, as vsftpd and others.
//

import Foundation
import XCTest
@testable import CartoucheStorage

class FTPTests: StorageServerTests {
    override class var serverName: String? { "FTP, pyftpdlib" }

    var ftp: StorageServers.FTP { servers.ftp }

    /// The server as the player adds it in Cartouche.
    private func server(user: String? = nil) -> CartoucheStorageServer {
        CartoucheStorageServer(kind: .ftp, name: "pyftpdlib", host: ftp.account.host, port: ftp.account.port,
                               username: user ?? ftp.account.user)
    }

    override func connect() async throws -> CartoucheRemote {
        try await CartoucheFTP.connect(server(), password: ftp.account.password)
    }

    override func connectWithAWrongPassword() async throws -> CartoucheRemote {
        try await CartoucheFTP.connect(server(), password: "not-" + ftp.account.password)
    }

    override func readOnlyPlace() async throws -> (CartoucheRemote, String) {
        let remote = try await CartoucheFTP.connect(server(user: ftp.reader), password: ftp.readerPassword)
        return (remote, servers.games)
    }

    override var rootPath: String? { ftp.rootPath }

    // A file is read on a control connection of its own, which signing out
    // leaves.
    override var signingOutCutsReads: Bool { false }

    func testNeedsAUserName() async {
        let error = await thrownError {
            let remote = try await CartoucheFTP.connect(self.server(user: ""), password: self.ftp.account.password)
            await remote.disconnect()
        }
        XCTAssertEqual(error?.localizedDescription, CartoucheText.storageFTPAccountNeeded)
    }

    func testKnowsAFolderItCannotWrite() async throws {
        let remote = try await signIn()
        let canWrite = try await remote.canWrite(servers.readOnlyFolder)
        XCTAssertFalse(canWrite)
        let installed = try await install(CartoucheStoragePath.join(servers.readOnlyFolder, servers.smallName), from: remote)
        try checkInstalled(installed, fixtures.small)
    }

    /// MLSD, which gives each file's size and time as they are, when the
    /// server has it; LIST otherwise.
    func testListsWithTheServersOwnCommand() async throws {
        let remote = try await signIn()
        let mark = fileSize(ftp.log)
        _ = try await remote.list(servers.games)
        let log = try logged(in: ftp.log, since: mark)
        if ftp.mlsd {
            XCTAssertTrue(log.contains("<- MLSD"), "listed without MLSD, which the server has:\n\(log)")
        } else {
            XCTAssertTrue(log.contains("<- LIST"), "did not list with LIST:\n\(log)")
            XCTAssertFalse(log.contains("<- MLSD"), "asked for MLSD, which the server does not have:\n\(log)")
        }
    }
}

final class FTPListTests: FTPTests {
    override class var serverName: String? { "FTP without MLSD, pyftpdlib" }

    override var ftp: StorageServers.FTP { servers.ftpList }

    // LIST gives times as `ls -l` writes them, which Cartouche does not keep.
    override var listsTimes: Bool { false }

    override func testInstallsAndCopiesAGameLargerThan4GiB() async throws {
        // FTPTests reads and writes it as here: only the listing differs,
        // and testListsTheGamesFolder reads its size from LIST.
        throw XCTSkip("the same transfers as FTPTests")
    }
}
