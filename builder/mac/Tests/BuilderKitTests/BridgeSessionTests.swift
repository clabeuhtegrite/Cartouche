//
//  BridgeSessionTests.swift
//  BuilderKitTests
//
//  What the Mac answers a paired iPhone over the bridge (BridgeServer.swift's
//  Session): the games folder and the saves folder at the top, files read
//  a piece at a time, uploads that only appear once finished, nothing
//  reached outside the two folders, and none of the games' apps for this
//  Mac, which the games folder keeps beside their IPAs. The bridge's own protocol is tested with
//  Cartouche's (launcher/Tests/CartoucheCoreTests/CartoucheBridgeTests.swift).
//

import CartoucheCore
import Foundation
import XCTest
@testable import BuilderKit

final class BridgeSessionTests: XCTestCase {
    private var folder: URL!
    private var games: URL!
    private var saves: URL!
    private var server: BridgeServer!
    private var session: Session!

    override func setUpWithError() throws {
        let manager = FileManager.default
        folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        games = folder.appendingPathComponent("Jeux", isDirectory: true)
        saves = folder.appendingPathComponent("Saves", isDirectory: true)
        try manager.createDirectory(at: games, withIntermediateDirectories: true)
        try manager.createDirectory(at: saves, withIntermediateDirectories: true)
        try Data("IPA bytes 0123456789".utf8).write(to: games.appendingPathComponent("Mario Kart World [0400C3F00006E000].ipa"))
        try Data("hidden".utf8).write(to: games.appendingPathComponent(".DS_Store"))
        try Data("secret".utf8).write(to: folder.appendingPathComponent("prod.keys"))
        server = BridgeServer(devices: BridgeDevices(url: folder.appendingPathComponent("bridge.json")), name: "Mac de test")
        server.roots = BridgeRoots(games: games, saves: saves)
        session = Session(server: server, peer: "iphone")
    }

    override func tearDownWithError() throws {
        session.discardUploads()
        try? FileManager.default.removeItem(at: folder)
    }

    private func ask(_ request: CartoucheBridgeRequest, body: Data = Data()) -> (CartoucheBridgeResponse, Data) {
        session.handle(request, body: body)
    }

    func testTheTopHasTheGamesAndTheSaves() {
        let (info, _) = ask(CartoucheBridgeRequest(.info))
        XCTAssertNil(info.error)
        XCTAssertEqual(info.name, "Mac de test")
        XCTAssertEqual(info.items?.map(\.name), [CartoucheBridge.gamesFolder, CartoucheBridge.savesFolder])
        XCTAssertEqual(info.readOnly, false)
        XCTAssertNotNil(info.free)

        let (top, _) = ask(CartoucheBridgeRequest(.list, path: ""))
        XCTAssertEqual(top.items?.map(\.name), ["Games", "Saves"])
        let (list, _) = ask(CartoucheBridgeRequest(.list, path: "Games"))
        XCTAssertEqual(list.items?.map(\.name), ["Mario Kart World [0400C3F00006E000].ipa"], "no hidden file")
        XCTAssertEqual(list.items?.first?.size, 20)
        XCTAssertEqual(list.items?.first?.folder, false)
    }

    func testAFileIsReadAPieceAtATime() {
        let path = "Games/Mario Kart World [0400C3F00006E000].ipa"
        let (stat, _) = ask(CartoucheBridgeRequest(.stat, path: path))
        XCTAssertEqual(stat.size, 20)
        XCTAssertEqual(stat.folder, false)
        let (read, body) = ask(CartoucheBridgeRequest(.read, path: path, offset: 4, count: 5))
        XCTAssertNil(read.error)
        XCTAssertEqual(read.size, 20)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "bytes")
        let (end, nothing) = ask(CartoucheBridgeRequest(.read, path: path, offset: 20, count: 5))
        XCTAssertNil(end.error)
        XCTAssertTrue(nothing.isEmpty)
        let (missing, _) = ask(CartoucheBridgeRequest(.read, path: "Games/Nothing.ipa", offset: 0, count: 5))
        XCTAssertEqual(missing.error, .notFound)
    }

    func testAnUploadAppearsOnlyOnceFinished() throws {
        let (created, _) = ask(CartoucheBridgeRequest(.create, path: "Saves/0400C3F00006E000/save.zip", size: 11))
        let upload = try XCTUnwrap(created.upload)
        XCTAssertNil(ask(CartoucheBridgeRequest(.write, upload: upload), body: Data("hello ".utf8)).0.error)
        XCTAssertNil(ask(CartoucheBridgeRequest(.write, upload: upload), body: Data("world".utf8)).0.error)
        let final = saves.appendingPathComponent("0400C3F00006E000/save.zip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        let (listed, _) = ask(CartoucheBridgeRequest(.list, path: "Saves/0400C3F00006E000"))
        XCTAssertEqual(listed.items ?? [], [], "an upload under way is not listed")
        let (finished, _) = ask(CartoucheBridgeRequest(.finish, upload: upload))
        XCTAssertNil(finished.error)
        XCTAssertEqual(finished.size, 11)
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "hello world")
        XCTAssertEqual(ask(CartoucheBridgeRequest(.finish, upload: upload)).0.error, .notFound)

        let (again, _) = ask(CartoucheBridgeRequest(.create, path: "Saves/0400C3F00006E000/other.zip", size: 3))
        let cancelled = try XCTUnwrap(again.upload)
        _ = ask(CartoucheBridgeRequest(.write, upload: cancelled), body: Data("abc".utf8))
        _ = ask(CartoucheBridgeRequest(.cancel, upload: cancelled))
        let left = try FileManager.default.contentsOfDirectory(atPath: final.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["save.zip"])
    }

    func testNothingOutsideTheTwoFolders() throws {
        for path in ["Games/../prod.keys", "Saves/./x", "Games/.DS_Store", "Games\\..\\prod.keys"] {
            let (answer, _) = ask(CartoucheBridgeRequest(.read, path: path, offset: 0, count: 10))
            XCTAssertEqual(answer.error, .denied, path)
        }
        let (other, _) = ask(CartoucheBridgeRequest(.list, path: "Users"))
        XCTAssertEqual(other.error, .notFound)

        // A link inside the games folder that leads outside it.
        try FileManager.default.createSymbolicLink(at: games.appendingPathComponent("outside"), withDestinationURL: folder)
        let (link, _) = ask(CartoucheBridgeRequest(.read, path: "Games/outside/prod.keys", offset: 0, count: 10))
        XCTAssertEqual(link.error, .denied)
        let (linkList, _) = ask(CartoucheBridgeRequest(.list, path: "Games/outside"))
        XCTAssertEqual(linkList.error, .denied)

        XCTAssertEqual(ask(CartoucheBridgeRequest(.delete, path: "Games")).0.error, .denied)
        XCTAssertEqual(ask(CartoucheBridgeRequest(.create, path: "Games", size: 1)).0.error, .denied)
    }

    /// The games' apps for this Mac, kept beside their IPAs when the games
    /// folder is on the Mac's own disk: the iPhone neither sees them nor
    /// reaches into them, where it would look for games as in a folder of
    /// the player's. A folder of the player's is still listed.
    func testAGamesAppForThisMacIsNeitherShownNorReached() throws {
        let contents = games.appendingPathComponent("Mario Kart World.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.createDirectory(at: games.appendingPathComponent("Plus tard", isDirectory: true), withIntermediateDirectories: true)

        let (list, _) = ask(CartoucheBridgeRequest(.list, path: "Games"))
        XCTAssertNil(list.error)
        XCTAssertEqual(list.items?.map(\.name), ["Mario Kart World [0400C3F00006E000].ipa", "Plus tard"])
        for path in ["Games/Mario Kart World.app", "Games/Mario Kart World.app/Contents", "Games/Mario Kart World.APP/Contents/Info.plist"] {
            XCTAssertEqual(ask(CartoucheBridgeRequest(.list, path: path)).0.error, .denied, path)
            XCTAssertEqual(ask(CartoucheBridgeRequest(.stat, path: path)).0.error, .denied, path)
            XCTAssertEqual(ask(CartoucheBridgeRequest(.read, path: path, offset: 0, count: 5)).0.error, .denied, path)
            XCTAssertEqual(ask(CartoucheBridgeRequest(.delete, path: path)).0.error, .denied, path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Info.plist").path))
    }

    func testFoldersAndWhatCanBeWritten() {
        XCTAssertNil(ask(CartoucheBridgeRequest(.makeFolder, path: "Saves/0100000000010000/slot 1")).0.error)
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: saves.appendingPathComponent("0100000000010000/slot 1").path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
        XCTAssertEqual(ask(CartoucheBridgeRequest(.canWrite, path: "Games/New.ipa")).0.writable, true)
        XCTAssertEqual(ask(CartoucheBridgeRequest(.canWrite, path: "")).0.writable, false)
        XCTAssertNotNil(ask(CartoucheBridgeRequest(.free, path: "Saves")).0.free)

        server.roots = BridgeRoots(games: games, saves: nil)
        XCTAssertEqual(ask(CartoucheBridgeRequest(.list, path: "")).0.items?.map(\.name), ["Games"])
        XCTAssertEqual(ask(CartoucheBridgeRequest(.list, path: "Saves")).0.error, .notFound)
    }
}
