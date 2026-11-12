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
    /// What the shared folder lets this account do, as the server said when
    /// Cartouche connected to it (MaximalAccess, MS-SMB2 2.2.10); 0 when it
    /// did not say.
    private let shareAccess: UInt32

    private init(client: SMBClient, shareAccess: UInt32) {
        self.client = client
        self.shareAccess = shareAccess
    }

    /// How long a request waits for the server's answer before Cartouche
    /// cuts the connection. One that stopped answering without closing,
    /// after the Wi-Fi changed or the NAS went down, would keep the request
    /// waiting for good; cut, it fails, and an install from the games folder
    /// connects again (CartoucheResumingSource). A request asks for 1 MiB at
    /// most (SMBSource.request), a fraction of a second on a home network.
    static let patience: UInt64 = 60_000_000_000

    static func connect(_ server: CartoucheStorageServer, password: String) async throws -> CartoucheSMB {
        let client = SMBClient(host: server.host, port: server.port ?? 445)
        let session = client.session
        try await open(client, of: server)
        do {
            _ = try await CartoucheDeadline.within(patience, cut: { session.disconnect() }) {
                try await client.login(username: server.username.isEmpty ? nil : server.username,
                                       password: password.isEmpty ? nil : password)
            }
        } catch {
            throw CartoucheStorageError(.signInFailed, CartoucheText.storageSignInFailed(server.host, error.localizedDescription), underlying: error)
        }
        var shareAccess: UInt32 = 0
        if !server.share.isEmpty {
            shareAccess = try await CartoucheDeadline.within(patience, cut: { session.disconnect() }) {
                try await client.connectShare(server.share).maximalAccess
            }
        }
        return CartoucheSMB(client: client, shareAccess: shareAccess)
    }

    /// Opens the connection to SERVER, before a word is said on it. A server
    /// that does not take it within the reach patience is out of reach from
    /// here, as a NAS at home is from elsewhere: it is offline, rather than
    /// refusing to sign in a minute later.
    private static func open(_ client: SMBClient, of server: CartoucheStorageServer) async throws {
        let session = client.session
        do {
            try await CartoucheDeadline.within(CartoucheStorageReach.patience, cut: { session.disconnect() }) {
                try await session.connect()
            }
        } catch {
            session.disconnect()
            NSLog("[Cartouche] no connection to the shared folder's server: %@", error.localizedDescription)
            throw CartoucheStorageOffline(server)
        }
    }

    /// FILE_WRITE_DATA, which is FILE_ADD_FILE for a folder,
    /// FILE_APPEND_DATA (FILE_ADD_SUBDIRECTORY), GENERIC_ALL, GENERIC_WRITE.
    private static let writing: UInt32 = 0x0000_0002 | 0x0000_0004 | 0x1000_0000 | 0x4000_0000
    /// STATUS_ACCESS_DENIED, STATUS_MEDIA_WRITE_PROTECTED.
    private static let refusals: Set<UInt32> = [0xC000_0022, 0xC000_00A2]

    var isReadOnly: Bool {
        shareAccess != 0 && shareAccess & Self.writing == 0
    }

    func canWrite(_ path: String) async throws -> Bool {
        if isReadOnly { return false }
        // The folder's own permissions: opening it to add a file and a
        // folder in it adds neither.
        let session = client.session
        do {
            let opened = try await session.create(
                desiredAccess: [.writeData, .appendData, .readAttributes, .synchronize],
                fileAttributes: [.directory],
                shareAccess: [.read, .write, .delete],
                createDisposition: .open,
                createOptions: [.directoryFile],
                name: Self.name(path)
            )
            _ = try? await session.close(fileId: opened.fileId)
            return true
        } catch let refused as ErrorResponse where Self.refusals.contains(refused.header.status) {
            return false
        }
    }

    /// PATH as SMB names it: from the shared folder's root, with "\"
    /// between folders.
    private static func name(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "\\")
    }

    /// The server's shared folders, for the player to pick one.
    static func shares(_ server: CartoucheStorageServer, password: String) async throws -> [String] {
        let client = SMBClient(host: server.host, port: server.port ?? 445)
        try await open(client, of: server)
        do {
            try await client.login(username: server.username.isEmpty ? nil : server.username,
                                   password: password.isEmpty ? nil : password)
        } catch {
            throw CartoucheStorageError(.signInFailed, CartoucheText.storageSignInFailed(server.host, error.localizedDescription), underlying: error)
        }
        defer { Task { _ = try? await client.logoff() } }
        return try await listShares(client)
            // Disk shares have type 0; special ones (IPC$, ADMIN$) a high bit.
            .filter { $0.type.rawValue & 0x0FFF_FFFF == 0 && !$0.type.contains(.special) && !$0.name.hasSuffix("$") }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// STATUS_PIPE_NOT_AVAILABLE, STATUS_PIPE_DISCONNECTED,
    /// STATUS_PIPE_BROKEN: the server hung up the pipe the list comes
    /// through.
    private static let hangUps: Set<UInt32> = [0xC000_00AC, 0xC000_00B0, 0xC000_014B]

    /// The list comes from the server's RPC services, through a pipe of its
    /// IPC$. Samba, since 4.16, starts them when a pipe is first opened, as
    /// on a NAS nobody used for a minute, since it stops them then, and it
    /// can hang up the pipe while they start: Samba 4.25 did, on a Mac, in
    /// the storage tests. Started, they answer: the list is asked again,
    /// twice at most, a second and then two seconds later.
    private static func listShares(_ client: SMBClient) async throws -> [Share] {
        var retries: UInt64 = 0
        while true {
            do {
                return try await client.listShares()
            } catch let hungUp as ErrorResponse where hangUps.contains(hungUp.header.status) && retries < 2 {
                retries += 1
                try await Task.sleep(nanoseconds: retries * 1_000_000_000)
            }
        }
    }

    func list(_ path: String) async throws -> [CartoucheRemoteItem] {
        try await client.listDirectory(path: path)
            .filter { $0.name != "." && $0.name != ".." && !$0.isHidden && !$0.name.hasPrefix(".") }
            .map { CartoucheRemoteItem(name: $0.name, isFolder: $0.isDirectory, size: $0.size, modified: $0.lastWriteTime) }
    }

    func open(_ path: String) async throws -> CartoucheByteSource {
        let reader = client.fileReader(path: path)
        let size = try await reader.fileSize
        return SMBSource(reader: reader, size: size, session: client.session)
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
            name: Self.name(partial)
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

    /// Says goodbye to the server, then closes the connection; a server
    /// that no longer answers gets a few seconds.
    func disconnect() async {
        let session = client.session
        _ = try? await CartoucheDeadline.within(Self.goodbye, cut: { session.disconnect() }) {
            try await client.logoff()
        }
    }

    private static let goodbye: UInt64 = 5_000_000_000
}

private final class SMBSource: CartoucheByteSource {
    /// The most one request asks for, though Samba would answer 8 MiB.
    /// SMBClient gathers an answer in copies that grow as it comes, each
    /// dropped for the next, and macOS takes the memory of copies of several
    /// MiB back long after they are dropped: on the Mac of the storage
    /// tests, an install of an IPA past 4 GiB, read in requests of 8 MiB,
    /// now and then grew by 300 to 560 MB, and by up to 115 MB with 4 MiB.
    /// With 1 MiB, it stayed within 6 MB, every time.
    static let request = 1 << 20

    let size: UInt64
    private let reader: FileReader
    private let session: Session

    init(reader: FileReader, size: UInt64, session: Session) {
        self.reader = reader
        self.size = size
        self.session = session
    }

    deinit {
        let reader = reader
        Task { try? await reader.close() }
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let wanted = Int(min(UInt64(count), size - offset))
        let session = session
        let most = min(Int(max(session.maxReadSize, 65_536)), Self.request)
        // The read's bytes in one buffer, made once, and one request at a
        // time, as FileReader sends them.
        var data = Data(capacity: wanted)
        while data.count < wanted {
            let length = UInt32(min(wanted - data.count, most))
            let at = offset + UInt64(data.count)
            let part = try await CartoucheDeadline.within(CartoucheSMB.patience, cut: { session.disconnect() }) {
                try await reader.read(offset: at, length: length)
            }
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
