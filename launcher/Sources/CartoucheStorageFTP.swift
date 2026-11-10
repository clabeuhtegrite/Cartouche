//
//  CartoucheStorageFTP.swift
//  Cartouche
//
//  An FTP server of the player's, such as their NAS's, with their own
//  account on it: Cartouche's own client, on Network.framework, with
//  passive data connections (EPSV, else PASV) to the server it signed in
//  to. FTP sends the password as it is, so it is for the player's own
//  network. Paths are from the server's root, with "/" between folders.
//
//  The control connection takes one command at a time: listing and
//  folders share one, and each file read or written gets one of its own,
//  so that a copy under way leaves the rest free.
//

import Foundation
import Network

final class CartoucheFTP: CartoucheRemote {
    private let server: CartoucheStorageServer
    private let password: String
    private var session: FTPSession?
    private let lock = FTPLock()

    private init(server: CartoucheStorageServer, password: String, session: FTPSession) {
        self.server = server
        self.password = password
        self.session = session
    }

    deinit {
        if let session {
            Task { await session.quit() }
        }
    }

    /// Signs in to SERVER with the player's account.
    static func connect(_ server: CartoucheStorageServer, password: String) async throws -> CartoucheFTP {
        let session = try await FTPSession.open(server, password: password)
        return CartoucheFTP(server: server, password: password, session: session)
    }

    /// Runs WORK on the shared control connection, one at a time; signs in
    /// again, once, when the server dropped a connection left idle.
    private func shared<T>(_ work: (FTPSession) async throws -> T) async throws -> T {
        await lock.acquire()
        do {
            let value: T
            do {
                let live = try await liveSession()
                value = try await work(live)
            } catch let error where FTPSession.isDropped(error) {
                await session?.quit()
                session = nil
                let live = try await liveSession()
                value = try await work(live)
            }
            await lock.release()
            return value
        } catch {
            await lock.release()
            throw error
        }
    }

    private func liveSession() async throws -> FTPSession {
        if let session { return session }
        let fresh = try await FTPSession.open(server, password: password)
        session = fresh
        return fresh
    }

    private static func path(_ path: String) throws -> String {
        guard let command = CartoucheFTPPath.command(path.precomposedStringWithCanonicalMapping) else {
            throw CartoucheStorageError(CartoucheText.storageFTPBadName)
        }
        return command
    }

    // MARK: CartoucheRemote

    /// FTP says nothing of what an account may do before it tries.
    var isReadOnly: Bool { false }

    func list(_ path: String) async throws -> [CartoucheRemoteItem] {
        let folder = try Self.path(path)
        let entries = try await shared { (session: FTPSession) -> [CartoucheFTPEntry] in
            try await session.list(folder)
        }
        var items: [CartoucheRemoteItem] = []
        for entry in entries where !entry.name.hasPrefix(".") {
            items.append(CartoucheRemoteItem(name: entry.name, isFolder: entry.isFolder, size: entry.size, modified: entry.modified))
        }
        return items
    }

    func open(_ path: String) async throws -> CartoucheByteSource {
        let file = try Self.path(path)
        let size = try await shared { (session: FTPSession) -> UInt64 in
            try await session.size(file)
        }
        let reader = FTPReader(server: server, password: password, path: file)
        return CartoucheReadAhead(size: size) { offset, count in
            try await reader.read(at: offset, count: count)
        }
    }

    func create(_ path: String, size: UInt64?) async throws -> CartoucheRemoteUpload {
        let file = try Self.path(path)
        let session = try await FTPSession.open(server, password: password)
        do {
            let partial = file + ".partial"
            _ = try? await session.command("DELE " + partial)
            let data = try await session.transfer("STOR " + partial)
            return FTPUpload(session: session, data: data, partial: partial, path: file)
        } catch {
            await session.quit()
            throw error
        }
    }

    func makeFolder(_ path: String) async throws {
        let folder = try Self.path(path)
        try await shared { (session: FTPSession) in
            try await session.expect("MKD " + folder)
        }
    }

    func delete(_ path: String) async throws {
        let target = try Self.path(path)
        try await shared { (session: FTPSession) in
            let reply = try await session.command("DELE " + target)
            guard !reply.isDone else { return }
            // Not a file: a folder, emptied first.
            try await session.deleteFolder(target)
        }
    }

    func freeSpace() async throws -> UInt64? {
        nil
    }

    func canWrite(_ path: String) async throws -> Bool {
        // FTP cannot be asked: Cartouche writes an empty hidden file, which
        // no list shows, and removes it.
        let probe = try Self.path(CartoucheStoragePath.join(path, ".cartouche-write-check-" + UUID().uuidString))
        return try await shared { (session: FTPSession) -> Bool in
            let data: FTPSocket
            do {
                data = try await session.transfer("STOR " + probe)
            } catch let failure as FTPFailure where failure.isRefusal {
                return false
            }
            await data.finishSending()
            let done = try await session.reply()
            _ = try? await session.command("DELE " + probe)
            return done.isDone
        }
    }

    func disconnect() async {
        await lock.acquire()
        await session?.quit()
        session = nil
        await lock.release()
    }
}

// MARK: Reading and writing a file

/// A file read with a control connection of its own, signed in to when the
/// first part is asked: each part is a RETR from an offset (REST), whose
/// data connection Cartouche closes once it has the part.
private final class FTPReader {
    private let server: CartoucheStorageServer
    private let password: String
    private let path: String
    private var session: FTPSession?

    init(server: CartoucheStorageServer, password: String, path: String) {
        self.server = server
        self.password = password
        self.path = path
    }

    deinit {
        if let session {
            Task { await session.quit() }
        }
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        do {
            return try await readOnce(at: offset, count: count)
        } catch let error where FTPSession.isDropped(error) {
            await session?.quit()
            session = nil
            return try await readOnce(at: offset, count: count)
        }
    }

    private func readOnce(at offset: UInt64, count: Int) async throws -> Data {
        let session: FTPSession
        if let open = self.session {
            session = open
        } else {
            session = try await FTPSession.open(server, password: password)
            self.session = session
        }
        if offset > 0 {
            let reply = try await session.command("REST \(offset)")
            guard reply.code == 350 else { throw FTPFailure(reply: reply) }
        }
        let data = try await session.transfer("RETR " + path)
        let part: Data
        do {
            part = try await data.receive(count: count)
        } catch {
            data.close()
            throw error
        }
        data.close()
        // 226 when the file ended, 426 or 451 when Cartouche closed the data
        // connection first: either way, the part is there.
        _ = try await session.reply()
        return part
    }
}

/// A file being written, as "<name>.partial" until it is finished, so that
/// the file there, if any, stays until then.
private final class FTPUpload: CartoucheRemoteUpload {
    private let session: FTPSession
    private let data: FTPSocket
    private let partial: String
    private let path: String
    private var closed = false

    init(session: FTPSession, data: FTPSocket, partial: String, path: String) {
        self.session = session
        self.data = data
        self.partial = partial
        self.path = path
    }

    func write(_ bytes: Data) async throws {
        try await data.send(bytes)
    }

    func finish() async throws {
        if !closed {
            closed = true
            await data.finishSending()
            let reply = try await session.reply()
            guard reply.isDone else {
                await cleanUp()
                throw FTPFailure(reply: reply)
            }
        }
        do {
            _ = try? await session.command("DELE " + path)
            let from = try await session.command("RNFR " + partial)
            guard from.isIntermediate else { throw FTPFailure(reply: from) }
            try await session.expect("RNTO " + path)
        } catch {
            await cleanUp()
            throw error
        }
        await session.quit()
    }

    func cancel() async {
        if !closed {
            closed = true
            data.close()
            _ = try? await session.reply()
        }
        await cleanUp()
    }

    private func cleanUp() async {
        _ = try? await session.command("DELE " + partial)
        await session.quit()
    }
}

// MARK: The protocol

/// A reply that says the server did not do what Cartouche asked.
struct FTPFailure: LocalizedError {
    let reply: CartoucheFTPReply

    var errorDescription: String? {
        "\(reply.code) \(reply.text)"
    }

    /// The account may not: 550 (no access), 553 (name not allowed),
    /// 532 (an account is needed to store files), 450 (unavailable).
    var isRefusal: Bool {
        [450, 532, 550, 553].contains(reply.code)
    }
}

/// One signed-in control connection.
private final class FTPSession {
    private let host: String
    private let control: FTPSocket
    private var features: Set<String> = []
    private var noExtendedPassive = false

    private init(host: String, control: FTPSocket) {
        self.host = host
        self.control = control
    }

    static func open(_ server: CartoucheStorageServer, password: String) async throws -> FTPSession {
        let host = server.host.trimmingCharacters(in: .whitespaces)
        let user = server.username.trimmingCharacters(in: .whitespaces)
        // Only with the player's own account.
        guard !host.isEmpty, !user.isEmpty, !user.contains(where: \.isNewline), !password.contains(where: \.isNewline) else {
            throw CartoucheStorageError(CartoucheText.storageFTPAccountNeeded)
        }
        let control = FTPSocket(host: host, port: server.port ?? 21)
        let session = FTPSession(host: host, control: control)
        do {
            try await control.open()
            var welcome = try await session.reply()
            while welcome.isPreliminary { welcome = try await session.reply() }
            guard welcome.isDone else { throw FTPFailure(reply: welcome) }
            var signedIn = try await session.command("USER " + user)
            if signedIn.isIntermediate {
                signedIn = try await session.command("PASS " + password)
            }
            guard signedIn.isDone else { throw FTPFailure(reply: signedIn) }
        } catch {
            control.close()
            throw CartoucheStorageError(CartoucheText.storageSignInFailed(host, error.localizedDescription))
        }
        let features = try await session.command("FEAT")
        if features.isDone {
            for line in features.text.split(separator: "\n") {
                let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if let name = words.first {
                    session.features.insert(name.uppercased())
                }
            }
        }
        if session.features.contains("UTF8") {
            _ = try await session.command("OPTS UTF8 ON")
        }
        try await session.expect("TYPE I")
        return session
    }

    /// Whether ERROR says the control connection is gone, as after a while
    /// without commands: 421, or the connection closed.
    static func isDropped(_ error: Error) -> Bool {
        if let failure = error as? FTPFailure { return failure.reply.code == 421 }
        return error is FTPSocket.Closed || error is NWError
    }

    func reply() async throws -> CartoucheFTPReply {
        var lines: [String] = []
        while true {
            lines.append(try await control.receiveLine())
            if let parsed = CartoucheFTPReply.parse(lines) {
                return parsed.reply
            }
        }
    }

    func command(_ text: String) async throws -> CartoucheFTPReply {
        try await control.send(Data((text + "\r\n").utf8))
        return try await reply()
    }

    /// Runs TEXT, which must be done.
    func expect(_ text: String) async throws {
        let reply = try await command(text)
        guard reply.isDone else { throw FTPFailure(reply: reply) }
    }

    /// Opens a passive data connection, then runs TEXT, which uses it, and
    /// gives the connection once the server says the transfer started.
    func transfer(_ text: String) async throws -> FTPSocket {
        let data = try await openData()
        let reply: CartoucheFTPReply
        do {
            reply = try await command(text)
        } catch {
            data.close()
            throw error
        }
        guard reply.isPreliminary else {
            data.close()
            throw FTPFailure(reply: reply)
        }
        return data
    }

    private func openData() async throws -> FTPSocket {
        var port: Int?
        if !noExtendedPassive {
            port = CartoucheFTPPassive.extendedPort(try await command("EPSV"))
            if port == nil { noExtendedPassive = true }
        }
        if port == nil {
            let reply = try await command("PASV")
            port = CartoucheFTPPassive.port(reply)
            guard port != nil else { throw FTPFailure(reply: reply) }
        }
        let data = FTPSocket(host: host, port: port ?? 0)
        try await data.open()
        return data
    }

    /// The entries of the folder at PATH.
    func list(_ path: String) async throws -> [CartoucheFTPEntry] {
        // In the folder, so that LIST needs no path, which some servers
        // read as options.
        try await expect("CWD " + path)
        // MLSD when the server has it. FEAT names it MLST (RFC 3659, 7.8),
        // which says the server has both MLST and MLSD; a few name MLSD too.
        let machine = features.contains("MLST") || features.contains("MLSD")
        let data = try await transfer(machine ? "MLSD" : "LIST")
        let bytes: Data
        do {
            bytes = try await data.receiveAll()
        } catch {
            data.close()
            throw error
        }
        data.close()
        let done = try await reply()
        guard done.isDone else { throw FTPFailure(reply: done) }
        let text = String(decoding: bytes, as: UTF8.self)
        return machine ? CartoucheFTPListing.machine(text) : CartoucheFTPListing.list(text)
    }

    func size(_ path: String) async throws -> UInt64 {
        let reply = try await command("SIZE " + path)
        guard reply.code == 213, let size = UInt64(reply.text.trimmingCharacters(in: .whitespaces)) else {
            throw FTPFailure(reply: reply)
        }
        return size
    }

    /// Removes the folder at PATH and everything in it.
    func deleteFolder(_ path: String) async throws {
        for entry in try await list(path) {
            let inside = path == "/" ? "/" + entry.name : path + "/" + entry.name
            if entry.isFolder {
                try await deleteFolder(inside)
            } else {
                try await expect("DELE " + inside)
            }
        }
        try await expect("CWD /")
        try await expect("RMD " + path)
    }

    func quit() async {
        _ = try? await command("QUIT")
        control.close()
    }
}

/// Whether something happened already, from any thread.
private final class FTPOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// True the first time only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

/// One at a time on the shared control connection.
private actor FTPLock {
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func release() {
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// A TCP connection to the server, read as lines or bytes. A read that
/// waits more than a minute closes it.
private final class FTPSocket {
    struct Closed: LocalizedError {
        var errorDescription: String? { CartoucheText.storageFTPClosed }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Cartouche FTP")
    private var buffer = Data()
    private static let timeout: TimeInterval = 60

    init(host: String, port: Int) {
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    deinit {
        connection.cancel()
    }

    func open() async throws {
        let connection = connection
        let queue = queue
        let once = FTPOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                let failure: Error?
                switch state {
                case .ready: failure = nil
                case let .failed(error): failure = error
                case let .waiting(error): failure = error
                case .cancelled: failure = Closed()
                default: return
                }
                guard once.claim() else { return }
                if let failure {
                    connection.cancel()
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume()
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 20) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(throwing: Closed())
            }
        }
    }

    func send(_ data: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Tells the server the data ends, and closes.
    func finishSending() async {
        let connection = connection
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in continuation.resume() })
        }
        connection.cancel()
    }

    func close() {
        connection.cancel()
    }

    /// What came next, up to MOST bytes; empty once the server closed.
    private func receiveChunk(most: Int) async throws -> Data {
        let connection = connection
        let watchdog = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: most) { data, _, _, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// The next line of the control connection, without its line break.
    func receiveLine() async throws -> String {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex ..< end]
                if line.last == 0x0D { line = line.dropLast() }
                buffer = Data(buffer[buffer.index(after: end)...])
                return String(decoding: line, as: UTF8.self)
            }
            let more = try await receiveChunk(most: 64 << 10)
            guard !more.isEmpty else { throw Closed() }
            buffer.append(more)
        }
    }

    /// COUNT bytes of the data connection, fewer if it ends first.
    func receive(count: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let more = try await receiveChunk(most: min(count - data.count, 1 << 20))
            if more.isEmpty { break }
            data.append(more)
        }
        return data
    }

    /// Everything the data connection carries, up to 64 MiB.
    func receiveAll() async throws -> Data {
        var data = Data()
        while true {
            let more = try await receiveChunk(most: 1 << 20)
            if more.isEmpty { return data }
            data.append(more)
            if data.count > 64 << 20 { throw CartoucheStorageError(CartoucheText.storageFTPTooLong) }
        }
    }
}
