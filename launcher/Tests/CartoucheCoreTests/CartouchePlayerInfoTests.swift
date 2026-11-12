//
//  CartouchePlayerInfoTests.swift
//  CartoucheCoreTests
//
//  What the player says of their games (Sources/CartouchePlayerInfo.swift):
//  kept by game, read again at the next start, a new cover in place of the
//  old one, forgotten when the player goes back to Cartouche's, and a
//  cover made from their image no larger than Cartouche shows it.
//

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CartoucheCore

final class CartouchePlayerInfoTests: XCTestCase {
    /// A folder of its own, removed after the test.
    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("GameInfo", isDirectory: true)
    }

    /// An image of WIDTH x HEIGHT pixels, in the format of TYPE.
    private func image(width: Int, height: Int, type: String = "public.png") throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.31, green: 0.27, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let picture = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func size(of jpeg: Data) throws -> (type: String, width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (CGImageSourceGetType(source) as String? ?? "",
                properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    func testAGameIsKeptByItsTitleIdElseItsBundleId() {
        XCTAssertEqual(CartouchePlayerInfoStore.key(titleId: "0100C0FFEE0A0000", bundleId: "org.nxnative.0100c0ffee0a0000",
                                                    id: "app:A.app"), "title:0100C0FFEE0A0000")
        XCTAssertEqual(CartouchePlayerInfoStore.key(titleId: nil, bundleId: "Com.Example.Game", id: "app:A.app"),
                       "bundle:com.example.game")
        XCTAssertEqual(CartouchePlayerInfoStore.key(titleId: nil, bundleId: nil, id: "stored:/Jeux/A.ipa"), "entry:stored:/Jeux/A.ipa")
    }

    func testWhatThePlayerSaysIsKeptAndReadAgain() throws {
        let folder = folder()
        let store = CartouchePlayerInfoStore(folder: folder)
        XCTAssertNil(store.info(for: "title:0100C0FFEE0A0000"))
        try store.set(CartouchePlayerInfo(name: "  Unravel Two ", platform: "switch", genre: "puzzle"), for: "title:0100C0FFEE0A0000")
        XCTAssertEqual(store.info(for: "title:0100C0FFEE0A0000"),
                       CartouchePlayerInfo(name: "Unravel Two", platform: "switch", genre: "puzzle"))
        // At the next start.
        let again = CartouchePlayerInfoStore(folder: folder)
        XCTAssertEqual(again.all, ["title:0100C0FFEE0A0000": CartouchePlayerInfo(name: "Unravel Two", platform: "switch", genre: "puzzle")])

        // A summary of the player's own, without the spaces around it.
        var written = CartouchePlayerInfo(name: "Unravel Two")
        written.summary = "\n  Two Yarnys, tied together.\u{0007} \n"
        try again.set(written, for: "title:0100C0FFEE0A0000")
        XCTAssertEqual(CartouchePlayerInfoStore(folder: folder).info(for: "title:0100C0FFEE0A0000")?.summary,
                       "Two Yarnys, tied together.")

        // What Cartouche does not know is left out, and nothing left
        // forgets the game.
        var blank = CartouchePlayerInfo(name: " ", platform: "wii", genre: "indie")
        blank.summary = " \n "
        try again.set(blank, for: "title:0100C0FFEE0A0000")
        XCTAssertNil(again.info(for: "title:0100C0FFEE0A0000"))
        XCTAssertEqual(CartouchePlayerInfoStore(folder: folder).all, [:])
    }

    func testANewCoverTakesThePlaceOfTheOldOne() throws {
        let folder = folder()
        let store = CartouchePlayerInfoStore(folder: folder)
        let key = "bundle:com.example.game"
        let first = try XCTUnwrap(CartouchePlayerInfoStore.jpeg(from: image(width: 600, height: 880)))
        try store.set(CartouchePlayerInfo(name: "My Game"), cover: first, for: key)
        let firstFile = try XCTUnwrap(store.coverFile(of: store.info(for: key)))
        XCTAssertEqual(try Data(contentsOf: firstFile), first)
        XCTAssertTrue(CartouchePlayerInfoStore.isCoverFile(firstFile.lastPathComponent))

        // The name changes, the cover stays.
        var info = try XCTUnwrap(store.info(for: key))
        info.name = "My Own Game"
        try store.set(info, for: key)
        XCTAssertEqual(store.coverFile(of: store.info(for: key)), firstFile)

        // A new cover: a new file, the old one goes.
        let second = try XCTUnwrap(CartouchePlayerInfoStore.jpeg(from: image(width: 300, height: 440)))
        try store.set(store.info(for: key), cover: second, for: key)
        let secondFile = try XCTUnwrap(store.coverFile(of: store.info(for: key)))
        XCTAssertNotEqual(secondFile, firstFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertEqual(store.info(for: key)?.name, "My Own Game")

        // Back to Cartouche's cover: the file goes too.
        info = try XCTUnwrap(store.info(for: key))
        info.cover = nil
        try store.set(info, for: key)
        XCTAssertNil(store.coverFile(of: store.info(for: key)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondFile.path))
        XCTAssertEqual(store.info(for: key), CartouchePlayerInfo(name: "My Own Game"))
    }

    func testOnlyACoverFileOfTheStoresIsRead() throws {
        let folder = folder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let odd = """
        {"schema": 1, "games": {
          "title:0100C0FFEE0A0000": {"name": "Unravel Two", "cover": "../../Documents/secret.jpg"},
          "title:0100BEEF00AB0000": {"cover": "cover.png"}
        }}
        """
        try Data(odd.utf8).write(to: folder.appendingPathComponent("info.json"))
        let store = CartouchePlayerInfoStore(folder: folder)
        XCTAssertEqual(store.all, ["title:0100C0FFEE0A0000": CartouchePlayerInfo(name: "Unravel Two")])
        XCTAssertNil(store.coverFile(of: CartouchePlayerInfo(cover: "../../Documents/secret.jpg")))
        // A name of its own, missing: no file.
        XCTAssertNil(store.coverFile(of: CartouchePlayerInfo(cover: UUID().uuidString + ".jpg")))
        XCTAssertFalse(CartouchePlayerInfoStore.isCoverFile("cover.jpg"))
    }

    func testACoverIsAJPEGNoLargerThanCartoucheShowsIt() throws {
        let large = try size(of: XCTUnwrap(CartouchePlayerInfoStore.jpeg(from: image(width: 3000, height: 4000))))
        XCTAssertEqual(large.type, "public.jpeg")
        XCTAssertEqual(max(large.width, large.height), CartouchePlayerInfoStore.coverSide)
        XCTAssertEqual(large.width, 1050)
        // A small one keeps its size.
        let small = try size(of: XCTUnwrap(CartouchePlayerInfoStore.jpeg(from: image(width: 400, height: 600, type: "public.jpeg"))))
        XCTAssertEqual([small.width, small.height], [400, 600])
        XCTAssertNil(CartouchePlayerInfoStore.jpeg(from: Data("not an image".utf8)))
    }
}
