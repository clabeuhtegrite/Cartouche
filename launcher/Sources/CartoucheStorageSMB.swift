//
//  CartoucheStorageSMB.swift
//  Cartouche
//
//  A shared folder of a Mac, a PC or a NAS, over SMB 2 or 3, with the
//  player's account on it: SMBClient (github.com/kishikawakatsumi/SMBClient,
//  MIT), which Cartouche builds as a package of its own (app/SMBClient).
//  Paths are from the shared folder's root, with "/" between folders.
//

import Foundation

/// Why an SMB server did not sign the player in, in Cartouche's words, by
/// the status it answered the sign-in with (an NTSTATUS, MS-ERREF 2.3.1).
/// SMBClient's own words are "Logon Failure" for a user name or a password
/// refused, which told a player nothing of what to do, and "Unknown error"
/// for an account the server holds back, as Samba answers for one turned
/// off, locked, or whose password must change. These are the statuses
/// CartoucheFailure counts as the player's credentials refused
/// (storageCredentials). Outside of SMBClient, for the gallery to show them.
enum CartoucheSMBRefusal {
    /// STATUS_LOGON_FAILURE, STATUS_NO_SUCH_USER, STATUS_WRONG_PASSWORD.
    static let nameOrPassword: Set<UInt32> = [0xC000_006D, 0xC000_0064, 0xC000_006A]
    /// STATUS_ACCOUNT_LOCKED_OUT: after too many wrong passwords, as Windows
    /// 11 does after ten, for ten minutes.
    static let lockedOut: UInt32 = 0xC000_0234
    /// STATUS_ACCOUNT_DISABLED, STATUS_ACCOUNT_EXPIRED,
    /// STATUS_PASSWORD_EXPIRED, STATUS_PASSWORD_MUST_CHANGE,
    /// STATUS_ACCOUNT_RESTRICTION (on Windows, an account without a
    /// password, which signs in only at the PC itself),
    /// STATUS_INVALID_LOGON_HOURS, STATUS_INVALID_WORKSTATION.
    static let heldBack: Set<UInt32> = [0xC000_0072, 0xC000_0193, 0xC000_0071, 0xC000_0224,
                                        0xC000_006E, 0xC000_006F, 0xC000_0070]

    /// The words for STATUS, or nil when the server did not refuse the
    /// account. GUEST: the player gave no user name, to sign in as a guest.
    static func reason(_ status: UInt32, guest: Bool) -> String? {
        if nameOrPassword.contains(status) {
            return guest ? CartoucheText.storageSMBNoGuests : CartoucheText.storageSMBRefused
        }
        if status == lockedOut {
            return CartoucheText.storageSMBLocked
        }
        if heldBack.contains(status) {
            return CartoucheText.storageSMBHeldBack
        }
        return nil
    }
}

#if canImport(SMBClient)
import SMBClient

final class CartoucheSMB: CartoucheRemote {
    private let client: SMBClient
    /// What the shared folder lets this account do, as the server said when
    /// Cartouche connected to it (MaximalAccess, MS-SMB2 2.2.10); 0 when it
    /// did not say.
    private let shareAccess: UInt32
    /// Every request on this connection, its files' and its copies' too,
    /// one at a time, in the order they were made. SMBClient gives each
    /// request the connection's next number (its MessageId, MS-SMB2
    /// 3.2.4.1.3) as the request is made, from a counter that nothing
    /// guards: two requests made at the same moment could take the same
    /// number, and the server then hangs up on the connection. Samba says
    /// "bad message_id" in its log, and the request still waiting for its
    /// answer fails, with "disconnected" or ENODATA, as two tests of the
    /// storage did on 12 and 13 November: each time on the request made
    /// just as a file read to its end was let go, whose close its deinit
    /// sent at the same moment.
    private let requests = CartoucheRequestQueue()

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
            throw signInFailed(server, error)
        }
        var shareAccess: UInt32 = 0
        if !server.share.isEmpty {
            shareAccess = try await CartoucheDeadline.within(patience, cut: { session.disconnect() }) {
                try await client.connectShare(server.share).maximalAccess
            }
        }
        return CartoucheSMB(client: client, shareAccess: shareAccess)
    }

    /// SERVER did not sign the player in, with ERROR: the account refused in
    /// Cartouche's words (CartoucheSMBRefusal), anything else in SMBClient's.
    static func signInFailed(_ server: CartoucheStorageServer, _ error: Error) -> CartoucheStorageError {
        let refusal = (error as? ErrorResponse).flatMap {
            CartoucheSMBRefusal.reason($0.header.status, guest: server.username.isEmpty)
        }
        return CartoucheStorageError(.signInFailed, CartoucheText.storageSignInFailed(server.host, refusal ?? error.localizedDescription),
                                     underlying: error)
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
            let opened = try await requests.run {
                try await session.create(
                    desiredAccess: [.writeData, .appendData, .readAttributes, .synchronize],
                    fileAttributes: [.directory],
                    shareAccess: [.read, .write, .delete],
                    createDisposition: .open,
                    createOptions: [.directoryFile],
                    name: Self.name(path)
                )
            }
            _ = try? await requests.run { try await session.close(fileId: opened.fileId) }
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
            throw signInFailed(server, error)
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
        try await requests.run { try await client.listDirectory(path: path) }
            .filter { $0.name != "." && $0.name != ".." && !$0.isHidden && !$0.name.hasPrefix(".") }
            .map { CartoucheRemoteItem(name: $0.name, isFolder: $0.isDirectory, size: $0.size, modified: $0.lastWriteTime) }
    }

    func open(_ path: String) async throws -> CartoucheByteSource {
        let reader = client.fileReader(path: path)
        let size = try await requests.run { try await reader.fileSize }
        return SMBSource(reader: reader, size: size, session: client.session, requests: requests)
    }

    func create(_ path: String, size: UInt64?) async throws -> CartoucheRemoteUpload {
        let partial = path + ".partial"
        if try await requests.run({ try await client.existFile(path: partial) }) {
            try await requests.run { try await client.deleteFile(path: partial) }
        }
        let session = client.session
        let created = try await requests.run {
            try await session.create(
                desiredAccess: [.readData, .writeData, .appendData, .readAttributes, .delete],
                fileAttributes: [.archive, .normal],
                shareAccess: [.read],
                createDisposition: .overwriteIf,
                createOptions: [.nonDirectoryFile],
                name: Self.name(partial)
            )
        }
        return SMBUpload(client: client, fileId: created.fileId, partial: partial, path: path, requests: requests)
    }

    func makeFolder(_ path: String) async throws {
        try await requests.run { try await client.createDirectory(path: path) }
    }

    func delete(_ path: String) async throws {
        if try await requests.run({ try await client.existDirectory(path: path) }) {
            try await requests.run { try await client.deleteDirectory(path: path) }
        } else {
            try await requests.run { try await client.deleteFile(path: path) }
        }
    }

    func freeSpace() async throws -> UInt64? {
        try await requests.run { try await client.availableSpace() }
    }

    /// Says goodbye to the server once the requests made before have
    /// ended, then closes the connection; a server that no longer answers
    /// gets a few seconds, waiting for those requests included.
    func disconnect() async {
        let session = client.session
        _ = try? await CartoucheDeadline.within(Self.goodbye, cut: { session.disconnect() }) {
            try await requests.run { try await client.logoff() }
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
    /// now and then took 286 to 560 MB more than at its start, and up to
    /// 115 MB more with 4 MiB. With 1 MiB, it took what the install itself
    /// holds, 37 MB at most, and nothing more as it went.
    static let request = 1 << 20

    let size: UInt64
    private let reader: FileReader
    private let session: Session
    private let requests: CartoucheRequestQueue

    init(reader: FileReader, size: UInt64, session: Session, requests: CartoucheRequestQueue) {
        self.reader = reader
        self.size = size
        self.session = session
        self.requests = requests
    }

    /// Closes the file in its turn, before any request made on the
    /// connection after this source was let go: the next one is often made
    /// at the same moment, and the connection could not remove or replace
    /// the file while it is still open on it.
    deinit {
        let reader = reader
        requests.queue { try await reader.close() }
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
            // Its patience counts the wait for its turn: a request before it
            // that gets no answer leaves this one waiting too.
            let part = try await CartoucheDeadline.within(CartoucheSMB.patience, cut: { session.disconnect() }) {
                try await requests.run { try await reader.read(offset: at, length: length) }
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
    private let requests: CartoucheRequestQueue
    private var offset: UInt64 = 0
    private var closed = false

    init(client: SMBClient, fileId: Data, partial: String, path: String, requests: CartoucheRequestQueue) {
        self.client = client
        self.fileId = fileId
        self.partial = partial
        self.path = path
        self.requests = requests
    }

    func write(_ data: Data) async throws {
        let session = client.session
        let most = Int(max(session.maxWriteSize, 65_536))
        var at = data.startIndex
        while at < data.endIndex {
            let end = min(at + most, data.endIndex)
            try await requests.run { try await session.write(data: data.subdata(in: at ..< end), fileId: fileId, offset: offset) }
            offset += UInt64(end - at)
            at = end
        }
    }

    func finish() async throws {
        if !closed {
            closed = true
            try await requests.run { try await client.session.flush(fileId: fileId) }
            try await requests.run { try await client.session.close(fileId: fileId) }
        }
        if try await requests.run({ try await client.existFile(path: path) }) {
            try await requests.run { try await client.deleteFile(path: path) }
        }
        try await requests.run { try await client.move(from: partial, to: path) }
    }

    func cancel() async {
        if !closed {
            closed = true
            _ = try? await requests.run { try await client.session.close(fileId: fileId) }
        }
        _ = try? await requests.run { try await client.deleteFile(path: partial) }
    }
}
#endif
