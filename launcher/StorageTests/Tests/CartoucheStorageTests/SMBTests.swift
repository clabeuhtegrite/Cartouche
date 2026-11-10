//
//  SMBTests.swift
//  CartoucheStorageTests
//
//  Samba, as a NAS shares its folders: the player's account on its shared
//  folder, a shared folder the account can only read, one for guests, and a
//  folder of the first whose permissions let the account only read.
//

import Foundation
import XCTest
@testable import CartoucheStorage

final class SMBTests: StorageServerTests {
    override class var serverName: String? { "SMB, Samba" }

    private var smb: StorageServers.SMB { servers.smb }

    /// The server as the player adds it in Cartouche.
    private func server(share: String, user: String? = nil) -> CartoucheStorageServer {
        CartoucheStorageServer(kind: .smb, name: "Samba", host: smb.account.host, port: smb.account.port,
                               username: user ?? smb.account.user, share: share)
    }

    override func connect() async throws -> CartoucheRemote {
        try await CartoucheSMB.connect(server(share: smb.share), password: smb.account.password)
    }

    override func connectWithAWrongPassword() async throws -> CartoucheRemote {
        try await CartoucheSMB.connect(server(share: smb.share), password: "not-" + smb.account.password)
    }

    override func readOnlyPlace() async throws -> (CartoucheRemote, String) {
        let remote = try await CartoucheSMB.connect(server(share: smb.readOnlyShare), password: smb.account.password)
        return (remote, servers.games)
    }

    override var rootPath: String? { smb.sharePath }

    /// The shared folders the player picks from when they add the server.
    /// The only test here that opens a pipe on the server: Samba starts its
    /// RPC services for it, as a NAS nobody used for a minute does, and
    /// Cartouche asks again if Samba hangs up the pipe meanwhile.
    func testListsTheSharedFolders() async throws {
        let shares = try await CartoucheSMB.shares(server(share: ""), password: smb.account.password)
        XCTAssertEqual(Set(shares), [smb.share, smb.readOnlyShare, smb.guestShare])
    }

    /// As the server says when Cartouche connects: no saves are offered
    /// there, and no game is copied there.
    func testSaysASharedFolderIsReadOnly() async throws {
        let readOnly = track(try await CartoucheSMB.connect(server(share: smb.readOnlyShare), password: smb.account.password))
        XCTAssertTrue(readOnly.isReadOnly, "Samba lets the account write to \(smb.readOnlyShare), Cartouche reads")
        let shared = try await signIn()
        XCTAssertFalse(shared.isReadOnly)
    }

    func testKnowsAFolderItCannotWrite() async throws {
        let remote = try await signIn()
        let canWrite = try await remote.canWrite(servers.readOnlyFolder)
        XCTAssertFalse(canWrite)
        let installed = try await install(CartoucheStoragePath.join(servers.readOnlyFolder, servers.smallName), from: remote)
        try checkInstalled(installed, fixtures.small)
    }

    /// Without an account, as Cartouche signs in when the player gives none.
    func testSignsInAsAGuest() async throws {
        let guest = track(try await CartoucheSMB.connect(server(share: smb.guestShare, user: ""), password: ""))
        let items = try await guest.list(servers.games)
        XCTAssertEqual(items.map(\.name), [servers.smallName])
        let canWrite = try await guest.canWrite(servers.games)
        XCTAssertFalse(canWrite)
        let installed = try await install(CartoucheStoragePath.join(servers.games, servers.smallName), from: guest)
        try checkInstalled(installed, fixtures.small)
    }

    /// What Copy to checks before it writes a game there.
    func testSaysHowMuchRoomIsLeft() async throws {
        let remote = try await signIn()
        let said = try await remote.freeSpace()
        let free = try XCTUnwrap(said)
        let local = try XCTUnwrap(statfsFreeSpace(smb.sharePath))
        // The same disk, give or take what was written meanwhile.
        let difference = free > local ? free - local : local - free
        XCTAssertLessThan(difference, 4 << 30, "Samba says \(free) bytes are left, the Mac \(local)")
    }
}
