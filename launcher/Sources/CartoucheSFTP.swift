//
//  CartoucheSFTP.swift
//  Cartouche
//
//  What Cartouche needs to speak SFTP, version 3 (draft-ietf-secsh-filexfer-02,
//  which OpenSSH and NAS servers speak), without the network: the requests,
//  as bytes, and the server's answers, read from the bytes the SSH channel
//  carries. CartoucheStorageSFTP.swift holds the SSH connection.
//

import CryptoKit
import Foundation

enum CartoucheSFTP {
    /// What OPEN asks for (SSH_FXF_*).
    struct OpenFlags: OptionSet, Hashable {
        let rawValue: UInt32
        static let read = OpenFlags(rawValue: 0x01)
        static let write = OpenFlags(rawValue: 0x02)
        static let create = OpenFlags(rawValue: 0x08)
        static let truncate = OpenFlags(rawValue: 0x10)
    }

    /// The status codes Cartouche tells apart (SSH_FX_*).
    enum Status: UInt32 {
        case ok = 0
        case endOfFile = 1
        case noSuchFile = 2
        case permissionDenied = 3
        case failure = 4
        case badMessage = 5
        case noConnection = 6
        case connectionLost = 7
        case unsupported = 8
    }

    /// A file's or a folder's attributes, as far as the server gave them.
    struct Attributes: Hashable {
        var size: UInt64?
        var permissions: UInt32?
        var modified: Date?

        /// From the permissions' file type, when the server gave them.
        var isFolder: Bool? {
            permissions.map { $0 & 0o170000 == 0o040000 }
        }

        /// A link, which Cartouche shows not.
        var isLink: Bool {
            permissions.map { $0 & 0o170000 == 0o120000 } ?? false
        }
    }

    struct Entry: Hashable {
        let name: String
        /// As `ls -l` writes it; the file type, when the attributes miss it.
        let longName: String
        let attributes: Attributes

        var isFolder: Bool {
            attributes.isFolder ?? longName.hasPrefix("d")
        }
    }

    enum Response: Hashable {
        case version(UInt32)
        case status(id: UInt32, code: UInt32, message: String)
        case handle(id: UInt32, Data)
        case data(id: UInt32, Data)
        case name(id: UInt32, [Entry])
        case attributes(id: UInt32, Attributes)
        /// A packet Cartouche does not read, such as an extended reply.
        case other(type: UInt8, id: UInt32?)

        var id: UInt32? {
            switch self {
            case .version: return nil
            case let .status(id, _, _), let .handle(id, _), let .data(id, _), let .name(id, _), let .attributes(id, _):
                return id
            case let .other(_, id):
                return id
            }
        }
    }

    struct BadPacket: Error {}

    // MARK: Requests

    static func initialize() -> Data {
        var body = Writer()
        body.byte(1)
        body.uint32(3)
        return body.packet()
    }

    static func realPath(id: UInt32, _ path: String) -> Data {
        request(16, id) { $0.string(path) }
    }

    static func open(id: UInt32, _ path: String, flags: OpenFlags) -> Data {
        request(3, id) {
            $0.string(path)
            $0.uint32(flags.rawValue)
            $0.uint32(0) // no attributes
        }
    }

    static func close(id: UInt32, handle: Data) -> Data {
        request(4, id) { $0.bytes(handle) }
    }

    static func read(id: UInt32, handle: Data, offset: UInt64, count: UInt32) -> Data {
        request(5, id) {
            $0.bytes(handle)
            $0.uint64(offset)
            $0.uint32(count)
        }
    }

    static func write(id: UInt32, handle: Data, offset: UInt64, _ data: Data) -> Data {
        request(6, id) {
            $0.bytes(handle)
            $0.uint64(offset)
            $0.bytes(data)
        }
    }

    static func openFolder(id: UInt32, _ path: String) -> Data {
        request(11, id) { $0.string(path) }
    }

    static func readFolder(id: UInt32, handle: Data) -> Data {
        request(12, id) { $0.bytes(handle) }
    }

    static func remove(id: UInt32, _ path: String) -> Data {
        request(13, id) { $0.string(path) }
    }

    static func makeFolder(id: UInt32, _ path: String) -> Data {
        request(14, id) {
            $0.string(path)
            $0.uint32(0)
        }
    }

    static func removeFolder(id: UInt32, _ path: String) -> Data {
        request(15, id) { $0.string(path) }
    }

    static func stat(id: UInt32, _ path: String) -> Data {
        request(17, id) { $0.string(path) }
    }

    static func rename(id: UInt32, from: String, to: String) -> Data {
        request(18, id) {
            $0.string(from)
            $0.string(to)
        }
    }

    private static func request(_ type: UInt8, _ id: UInt32, _ fill: (inout Writer) -> Void) -> Data {
        var body = Writer()
        body.byte(type)
        body.uint32(id)
        fill(&body)
        return body.packet()
    }

    /// PATH, from the folder the server opens the account in ("" for that
    /// folder), as requests name it.
    static func path(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    // MARK: The server's key

    /// Whether two keys, as OpenSSH writes them ("ssh-ed25519 AAAA…
    /// comment"), are the same: their kind and their bytes.
    static func sameKey(_ first: String, _ second: String) -> Bool {
        let one = first.split(separator: " ").prefix(2)
        let two = second.split(separator: " ").prefix(2)
        return one.count == 2 && Array(one) == Array(two)
    }

    /// KEY's fingerprint as OpenSSH shows it: "SHA256:" and the base64 of
    /// the SHA-256 of its bytes, without "=".
    static func fingerprint(_ key: String) -> String? {
        let fields = key.split(separator: " ")
        guard fields.count >= 2, let bytes = Data(base64Encoded: String(fields[1])) else { return nil }
        let digest = Data(SHA256.hash(data: bytes)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    // MARK: Answers

    /// The packets of the bytes the channel carries, as they come.
    struct Reader {
        private var buffer = Data()

        init() {}

        mutating func append(_ data: Data) {
            buffer.append(data)
        }

        /// The next whole packet; nil until it has all come.
        mutating func next() throws -> Response? {
            guard buffer.count >= 4 else { return nil }
            var head = Parser(buffer.prefix(4))
            let length = Int(try head.uint32())
            guard length >= 1, length <= 4 << 20 else { throw BadPacket() }
            guard buffer.count >= 4 + length else { return nil }
            let start = buffer.startIndex + 4
            let packet = buffer.subdata(in: start ..< start + length)
            buffer = Data(buffer[(start + length)...])
            return try Self.response(packet)
        }

        static func response(_ packet: Data) throws -> Response {
            var parser = Parser(packet)
            let type = try parser.byte()
            if type == 2 {
                let version = try parser.uint32()
                return .version(version)
            }
            let id = try parser.uint32()
            switch type {
            case 101:
                let code = try parser.uint32()
                // Version 3 servers may leave the message out.
                var message = ""
                if !parser.isAtEnd {
                    message = try parser.string()
                }
                return .status(id: id, code: code, message: message)
            case 102:
                let handle = try parser.bytes()
                return .handle(id: id, handle)
            case 103:
                let data = try parser.bytes()
                return .data(id: id, data)
            case 104:
                let count = try parser.uint32()
                var entries: [Entry] = []
                for _ in 0 ..< count {
                    let name = try parser.string()
                    let longName = try parser.string()
                    let attributes = try parser.attributes()
                    entries.append(Entry(name: name, longName: longName, attributes: attributes))
                }
                return .name(id: id, entries)
            case 105:
                let attributes = try parser.attributes()
                return .attributes(id: id, attributes)
            default:
                return .other(type: type, id: id)
            }
        }
    }

    // MARK: Bytes

    struct Writer {
        private(set) var data = Data()

        mutating func byte(_ value: UInt8) {
            data.append(value)
        }

        mutating func uint32(_ value: UInt32) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }

        mutating func uint64(_ value: UInt64) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }

        mutating func bytes(_ value: Data) {
            uint32(UInt32(value.count))
            data.append(value)
        }

        mutating func string(_ value: String) {
            bytes(Data(value.utf8))
        }

        /// The body with its length before it.
        func packet() -> Data {
            var framed = Writer()
            framed.uint32(UInt32(data.count))
            return framed.data + data
        }
    }

    struct Parser {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var isAtEnd: Bool { offset >= data.endIndex }

        private mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, data.endIndex - offset >= count else { throw BadPacket() }
            let part = data.subdata(in: offset ..< offset + count)
            offset += count
            return part
        }

        mutating func byte() throws -> UInt8 {
            let part = try take(1)
            return part[part.startIndex]
        }

        mutating func uint32() throws -> UInt32 {
            var value: UInt32 = 0
            for byte in try take(4) {
                value = value << 8 | UInt32(byte)
            }
            return value
        }

        mutating func uint64() throws -> UInt64 {
            var value: UInt64 = 0
            for byte in try take(8) {
                value = value << 8 | UInt64(byte)
            }
            return value
        }

        mutating func bytes() throws -> Data {
            let count = try uint32()
            return try take(Int(count))
        }

        mutating func string() throws -> String {
            let bytes = try bytes()
            return String(decoding: bytes, as: UTF8.self)
        }

        mutating func attributes() throws -> Attributes {
            let flags = try uint32()
            var attributes = Attributes()
            if flags & 0x1 != 0 { attributes.size = try uint64() }
            if flags & 0x2 != 0 {
                _ = try uint32() // uid
                _ = try uint32() // gid
            }
            if flags & 0x4 != 0 { attributes.permissions = try uint32() }
            if flags & 0x8 != 0 {
                _ = try uint32() // atime
                let modified = try uint32()
                attributes.modified = Date(timeIntervalSince1970: TimeInterval(modified))
            }
            if flags & 0x8000_0000 != 0 {
                let count = try uint32()
                for _ in 0 ..< count {
                    _ = try bytes()
                    _ = try bytes()
                }
            }
            return attributes
        }
    }
}
