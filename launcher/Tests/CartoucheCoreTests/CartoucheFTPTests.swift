import XCTest
@testable import CartoucheCore

final class CartoucheFTPTests: XCTestCase {
    func testOneLineReply() throws {
        let parsed = try XCTUnwrap(CartoucheFTPReply.parse(["220 NAS FTP server ready.", "extra"]))
        XCTAssertEqual(parsed.reply, CartoucheFTPReply(code: 220, text: "NAS FTP server ready."))
        XCTAssertEqual(parsed.lines, 1)
        XCTAssertTrue(parsed.reply.isDone)
    }

    func testMultilineReply() throws {
        let lines = ["211-Features:", " MLSD", " SIZE", " UTF8", "211 End"]
        XCTAssertNil(CartoucheFTPReply.parse(Array(lines.prefix(4))))
        let parsed = try XCTUnwrap(CartoucheFTPReply.parse(lines))
        XCTAssertEqual(parsed.reply.code, 211)
        XCTAssertEqual(parsed.reply.text, "Features:\nMLSD\nSIZE\nUTF8\nEnd")
        XCTAssertEqual(parsed.lines, 5)
        // The reply ends at the first line with its code and a space.
        let inner = try XCTUnwrap(CartoucheFTPReply.parse(["230-Welcome", "230 is not the end-", "230 Logged in."]))
        XCTAssertEqual(inner.lines, 2)
    }

    func testReplyKinds() {
        XCTAssertTrue(CartoucheFTPReply(code: 150, text: "").isPreliminary)
        XCTAssertTrue(CartoucheFTPReply(code: 331, text: "").isIntermediate)
        XCTAssertFalse(CartoucheFTPReply(code: 550, text: "").isDone)
        XCTAssertNil(CartoucheFTPReply.parse(["hello"]))
        XCTAssertNil(CartoucheFTPReply.parse([]))
    }

    func testPassivePorts() {
        XCTAssertEqual(CartoucheFTPPassive.extendedPort(CartoucheFTPReply(code: 229, text: "Entering Extended Passive Mode (|||6446|)")), 6446)
        XCTAssertNil(CartoucheFTPPassive.extendedPort(CartoucheFTPReply(code: 500, text: "EPSV not understood")))
        XCTAssertNil(CartoucheFTPPassive.extendedPort(CartoucheFTPReply(code: 229, text: "(|||99999|)")))
        XCTAssertEqual(CartoucheFTPPassive.port(CartoucheFTPReply(code: 227, text: "Entering Passive Mode (192,168,1,2,195,149).")), 195 * 256 + 149)
        XCTAssertEqual(CartoucheFTPPassive.port(CartoucheFTPReply(code: 227, text: "Entering Passive Mode 10,0,0,5,4,1")), 1025)
        XCTAssertNil(CartoucheFTPPassive.port(CartoucheFTPReply(code: 227, text: "Entering Passive Mode (1,2,3)")))
    }

    func testMachineListing() {
        let text = """
        type=cdir;modify=20261106194300; .
        type=pdir;modify=20261106194300; ..
        type=dir;modify=20261106194300;perm=flcdmpe; Anciens jeux\r
        type=file;size=5368709120;modify=20261106194312;perm=adfrw; Mario Kart World [0400C3F00006E000].ipa\r
        type=OS.unix=slink:/x;modify=20261106194312; lien
        """
        let entries = CartoucheFTPListing.machine(text)
        XCTAssertEqual(entries, [
            CartoucheFTPEntry(name: "Anciens jeux", isFolder: true, size: 0, modified: Date(timeIntervalSince1970: 1_793_994_180)),
            CartoucheFTPEntry(name: "Mario Kart World [0400C3F00006E000].ipa", isFolder: false, size: 5_368_709_120,
                              modified: Date(timeIntervalSince1970: 1_793_994_192)),
        ])
    }

    func testUnixListing() {
        let text = """
        total 12
        drwxr-xr-x    2 ad       staff        4096 Nov  6 19:43 Anciens jeux
        -rw-r--r--    1 ad       staff  5368709120 Nov  6 19:43 Mario Kart World.ipa
        lrwxrwxrwx    1 ad       staff           9 Nov  6 19:43 lien -> /volume1
        drwxr-xr-x    2 ad       staff        4096 Nov  6 19:43 .
        """
        XCTAssertEqual(CartoucheFTPListing.list(text), [
            CartoucheFTPEntry(name: "Anciens jeux", isFolder: true, size: 0, modified: nil),
            CartoucheFTPEntry(name: "Mario Kart World.ipa", isFolder: false, size: 5_368_709_120, modified: nil),
        ])
    }

    func testWindowsListing() {
        let text = "11-06-26  07:43PM       <DIR>          Anciens jeux\r\n11-06-26  07:43PM           1048576 Zelda.ipa\r\n"
        XCTAssertEqual(CartoucheFTPListing.list(text), [
            CartoucheFTPEntry(name: "Anciens jeux", isFolder: true, size: 0, modified: nil),
            CartoucheFTPEntry(name: "Zelda.ipa", isFolder: false, size: 1_048_576, modified: nil),
        ])
    }

    func testCommandPaths() {
        XCTAssertEqual(CartoucheFTPPath.command(""), "/")
        XCTAssertEqual(CartoucheFTPPath.command("Jeux/Switch/"), "/Jeux/Switch")
        XCTAssertNil(CartoucheFTPPath.command("Jeux\r\nDELE x"))
    }
}
