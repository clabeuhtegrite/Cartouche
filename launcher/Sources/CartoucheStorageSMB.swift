//
//  CartoucheStorageSMB.swift
//  Cartouche
//
//  A shared folder of a Mac, a PC or a NAS, over SMB 2 or 3, with the
//  player's account on it: SMBClient (github.com/kishikawakatsumi/SMBClient,
//  MIT), which Cartouche builds as a package of its own (app/SMBClient).
//  Paths are from the shared folder's root, with "/" between folders.
//

#if canImport(SMBClient)
import Foundation
import SMBClient

final class CartoucheSMB: CartoucheRemote {
    private let client: SMBClient

    private init(client: SMBClient) {
        self.client = client
    }

    static func connect(_ server: CartoucheStorageServer, password: String) async throws -> CartoucheSMB {
        let client = SMBClient(host: server.host, port: server.port ?? 445)
        do {
            try await client.login(username: server.username.isEmpty ? nil : server.username,
                                   password: password.isEmpty ? nil : password)
        } catch {
            throw CartoucheStorageError(CartoucheText.storageSignInFailed(server.host, error.localizedDescription))
        }
        if !server.share.isEmpty {
            try await client.connectShare(server.share)
        }
        return CartoucheSMB(client: client)
    }

    /// The server's shared folders, for the player to pick one.
    static func shares(_ server: CartoucheStorageServer, password: String) async throws -> [String] {
        let client = SMBClient(host: server.host, port: server.port ?? 445)
        do {
            try await client.login(username: server.username.isEmpty ? nil : server.username,
                                   password: password.isEmpty ? nil : password)
        } catch {
            throw CartoucheStorageError(CartoucheText.storageSignInFailed(server.host, error.localizedDescription))
        }
        defer { Task { _ = try? await client.logoff() } }
        return try await client.listShares()
            // Disk shares have type 0; special ones (IPC$, ADMIN$) a high bit.
            .filter { $0.type.rawValue & 0x0FFF_FFFF == 0 && !$0.type.contains(.special) && !$0.name.hasSuffix("$") }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func list(_ path: String) async throws -> [CartoucheRemoteItem] {
        try await client.listDirectory(path: path)
            .filter { $0.name != "." && $0.name != ".." && !$0.isHidden && !$0.name.hasPrefix(".") }
            .map { CartoucheRemoteItem(name: $0.name, isFolder: $0.isDirectory, size: $0.size, modified: $0.lastWriteTime) }
    }

    func open(_ path: String) async throws -> CartoucheByteSource {
        let reader = client.fileReader(path: path)
        let size = try await reader.fileSize
        return SMBSource(reader: reader, size: size)
    }

    func create(_ path: String, size: UInt64?) async throws -> CartoucheRemoteUpload {
        let partial = path + ".partial"
        if try await client.existFile(path: partial) {
            try await client.deleteFile(path: partial)
        }
        let session = client.session
        let created = try await session.create(
            desiredAccess: [.readData, .writeData, .appendData, .readAttributes, .delete],
            fileAttributes: [.archive, .normal],
            shareAccess: [.read],
            createDisposition: .overwriteIf,
            createOptions: [.nonDirectoryFile],
            name: partial.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "/", with: "\\")
        )
        return SMBUpload(client: client, fileId: created.fileId, partial: partial, path: path)
    }

    func makeFolder(_ path: String) async throws {
        try await client.createDirectory(path: path)
    }

    func delete(_ path: String) async throws {
        if try await client.existDirectory(path: path) {
            try await client.deleteDirectory(path: path)
        } else {
            try await client.deleteFile(path: path)
        }
    }

    func freeSpace() async throws -> UInt64? {
        try await client.availableSpace()
    }

    func disconnect() async {
        _ = try? await client.logoff()
    }
}

private final class SMBSource: CartoucheByteSource {
    let size: UInt64
    private let reader: FileReader

    init(reader: FileReader, size: UInt64) {
        self.reader = reader
        self.size = size
    }

    deinit {
        let reader = reader
        Task { try? await reader.close() }
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        var data = Data()
        // FileReader reads at most 4 GiB at once.
        while data.count < count {
            let wanted = UInt32(min(count - data.count, Int(UInt32.max)))
            let part = try await reader.read(offset: offset + UInt64(data.count), length: wanted)
            if part.isEmpty { break }
            data.append(part)
        }
        return data
    }
}

private final class SMBUpload: CartoucheRemoteUpload {
    private let client: SMBClient
    private let fileId: Data
    private let partial: String
    private let path: String
    private var offset: UInt64 = 0
    private var closed = false

    init(client: SMBClient, fileId: Data, partial: String, path: String) {
        self.client = client
        self.fileId = fileId
        self.partial = partial
        self.path = path
    }

    func write(_ data: Data) async throws {
        let session = client.session
        let most = Int(max(session.maxWriteSize, 65_536))
        var at = data.startIndex
        while at < data.endIndex {
            let end = min(at + most, data.endIndex)
            try await session.write(data: data.subdata(in: at ..< end), fileId: fileId, offset: offset)
            offset += UInt64(end - at)
            at = end
        }
    }

    func finish() async throws {
        if !closed {
            closed = true
            _ = try await client.session.flush(fileId: fileId)
            try await client.session.close(fileId: fileId)
        }
        if try await client.existFile(path: path) {
            try await client.deleteFile(path: path)
        }
        try await client.move(from: partial, to: path)
    }

    func cancel() async {
        if !closed {
            closed = true
            _ = try? await client.session.close(fileId: fileId)
        }
        try? await client.deleteFile(path: partial)
    }
}
#endif
