import XCTest
@testable import CartoucheCore

final class CartoucheSFTPTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }

    /// A packet of TYPE and ID with BODY after them, framed.
    private func packet(_ type: UInt8, id: UInt32?, _ fill: (inout CartoucheSFTP.Writer) -> Void = { _ in }) -> Data {
        var body = CartoucheSFTP.Writer()
        body.byte(type)
        if let id { body.uint32(id) }
        fill(&body)
        return body.packet()
    }

    func testRequests() {
        XCTAssertEqual(hex(CartoucheSFTP.initialize()), "000000050100000003")
        // STAT 7 "a": length 10, type 17, id 7, "a".
        XCTAssertEqual(hex(CartoucheSFTP.stat(id: 7, "a")), "0000000a1100000007" + "0000000161")
        let read = CartoucheSFTP.read(id: 2, handle: Data([0xAB]), offset: 0x1_0000_0000, count: 32768)
        XCTAssertEqual(hex(read), "00000016" + "05" + "00000002" + "00000001ab" + "0000000100000000" + "00008000")
        let open = CartoucheSFTP.open(id: 1, "x", flags: [.write, .create, .truncate])
        XCTAssertEqual(hex(open), "00000012" + "03" + "00000001" + "0000000178" + "0000001a" + "00000000")
        let rename = CartoucheSFTP.rename(id: 3, from: "a", to: "b")
        XCTAssertEqual(hex(rename), "0000000f" + "12" + "00000003" + "0000000161" + "0000000162")
    }

    func testPaths() {
        XCTAssertEqual(CartoucheSFTP.path(""), ".")
        XCTAssertEqual(CartoucheSFTP.path("/"), ".")
        XCTAssertEqual(CartoucheSFTP.path("/Jeux//Switch/"), "Jeux/Switch")
    }

    func testVersionAndStatus() throws {
        var reader = CartoucheSFTP.Reader()
        reader.append(packet(2, id: 3))
        reader.append(packet(101, id: 9) {
            $0.uint32(2)
            $0.string("No such file")
            $0.string("en")
        })
        // A version 3 server may leave the message out.
        reader.append(packet(101, id: 10) { $0.uint32(0) })
        XCTAssertEqual(try reader.next(), .version(3))
        XCTAssertEqual(try reader.next(), .status(id: 9, code: 2, message: "No such file"))
        XCTAssertEqual(try reader.next(), .status(id: 10, code: 0, message: ""))
        XCTAssertNil(try reader.next())
    }

    func testPacketsSplitAcrossReads() throws {
        let whole = packet(103, id: 4) { $0.bytes(Data(repeating: 0x5A, count: 1000)) }
        var reader = CartoucheSFTP.Reader()
        reader.append(whole.prefix(3))
        XCTAssertNil(try reader.next())
        reader.append(whole.dropFirst(3).prefix(500))
        XCTAssertNil(try reader.next())
        reader.append(whole.dropFirst(503) + packet(102, id: 5) { $0.bytes(Data([1, 2, 3, 4])) })
        XCTAssertEqual(try reader.next(), .data(id: 4, Data(repeating: 0x5A, count: 1000)))
        XCTAssertEqual(try reader.next(), .handle(id: 5, Data([1, 2, 3, 4])))
        XCTAssertNil(try reader.next())
    }

    func testNamesAndAttributes() throws {
        let names = packet(104, id: 6) {
            $0.uint32(2)
            $0.string("Jeux")
            $0.string("drwxr-xr-x    2 ad staff 4096 Nov  6 19:43 Jeux")
            $0.uint32(0x1 | 0x2 | 0x4 | 0x8)
            $0.uint64(4096)
            $0.uint32(501)
            $0.uint32(20)
            $0.uint32(0o040755)
            $0.uint32(1_700_000_000)
            $0.uint32(1_762_458_180)
            $0.string("save.bin")
            $0.string("-rw-r--r--    1 ad staff 12 Nov  6 19:43 save.bin")
            // Size and an extended attribute only: the type comes from the long name.
            $0.uint32(0x1 | 0x8000_0000)
            $0.uint64(12)
            $0.uint32(1)
            $0.string("x@example")
            $0.string("y")
        }
        var reader = CartoucheSFTP.Reader()
        reader.append(names)
        guard case let .name(id, entries) = try reader.next() else { return XCTFail("no names") }
        XCTAssertEqual(id, 6)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Jeux")
        XCTAssertTrue(entries[0].isFolder)
        XCTAssertEqual(entries[0].attributes.size, 4096)
        XCTAssertEqual(entries[0].attributes.modified, Date(timeIntervalSince1970: 1_762_458_180))
        XCTAssertEqual(entries[1].name, "save.bin")
        XCTAssertFalse(entries[1].isFolder)
        XCTAssertNil(entries[1].attributes.permissions)
        XCTAssertEqual(entries[1].attributes.size, 12)

        let link = packet(105, id: 7) {
            $0.uint32(0x4)
            $0.uint32(0o120777)
        }
        reader.append(link)
        guard case let .attributes(_, attributes) = try reader.next() else { return XCTFail("no attributes") }
        XCTAssertTrue(attributes.isLink)
        XCTAssertEqual(attributes.isFolder, false)
    }

    func testBadPackets() {
        var empty = CartoucheSFTP.Reader()
        empty.append(bytes("00000000"))
        XCTAssertThrowsError(try empty.next())
        var huge = CartoucheSFTP.Reader()
        huge.append(bytes("7fffffff00"))
        XCTAssertThrowsError(try huge.next())
        // A string longer than its packet.
        var short = CartoucheSFTP.Reader()
        short.append(bytes("0000000a" + "66" + "00000001" + "000000ff" + "00"))
        XCTAssertThrowsError(try short.next())
        // A packet Cartouche does not read is passed on with its id.
        var other = CartoucheSFTP.Reader()
        other.append(packet(201, id: 8) { $0.string("x") })
        XCTAssertEqual(try other.next(), .other(type: 201, id: 8))
    }

    func testKeys() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        XCTAssertEqual(CartoucheSFTP.fingerprint(key + " nas"), "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
        XCTAssertNil(CartoucheSFTP.fingerprint("ssh-ed25519"))
        XCTAssertTrue(CartoucheSFTP.sameKey(key, key + " nas"))
        XCTAssertFalse(CartoucheSFTP.sameKey(key, "ecdsa-sha2-nistp256 " + key.split(separator: " ")[1]))
        XCTAssertFalse(CartoucheSFTP.sameKey("", ""))
    }
}
