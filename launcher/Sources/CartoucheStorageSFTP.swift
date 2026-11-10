//
//  CartoucheStorageSFTP.swift
//  Cartouche
//
//  An SFTP server of the player's, such as their NAS's or their Mac's, with
//  their account on it: an SSH connection with Apple's swift-nio-ssh
//  (Apache 2.0, linked by app/patches/livecontainer/0007), and Cartouche's
//  own SFTP on it (CartoucheSFTP.swift). The server's key is kept when the
//  player saves the server, and a connection to a server whose key is
//  another stops before the password is sent. Paths are from the folder
//  the server opens the account in, with "/" between folders.
//
//  SFTP takes many requests at once on one channel, each with its id:
//  reads and writes go in 32 KiB requests, many at a time.
//

#if canImport(NIOSSH)
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

final class CartoucheSFTPServer: CartoucheRemote {
    private let connection: SFTPConnection
    /// The server's key, as OpenSSH writes it.
    let hostKey: String

    private init(connection: SFTPConnection, hostKey: String) {
        self.connection = connection
        self.hostKey = hostKey
    }

    /// Signs in to SERVER with the player's account. The server must show
    /// KNOWNKEY, when Cartouche has one; otherwise its key is taken, and
    /// hostKey says which it is.
    static func connect(_ server: CartoucheStorageServer, password: String, knownKey: String?) async throws -> CartoucheSFTPServer {
        let host = server.host.trimmingCharacters(in: .whitespaces)
        let user = server.username.trimmingCharacters(in: .whitespaces)
        // Only with the player's own account.
        guard !host.isEmpty, !user.isEmpty else {
            throw CartoucheStorageError(CartoucheText.storageFTPAccountNeeded)
        }
        let check = HostKeyCheck(expected: knownKey)
        do {
            let connection = try await SFTPConnection.open(host: host, port: server.port ?? 22,
                                                           user: user, password: password, check: check)
            guard let key = check.seen else {
                connection.close()
                throw CartoucheStorageError(CartoucheText.storageSFTPNoKey)
            }
            return CartoucheSFTPServer(connection: connection, hostKey: key)
        } catch let error as CartoucheStorageError {
            throw error
        } catch {
            // The key refused closes the connection, whatever error comes.
            if check.changed {
                throw CartoucheStorageError(CartoucheText.storageSFTPKeyChanged(host))
            }
            throw CartoucheStorageError(CartoucheText.storageSignInFailed(host, Self.reason(error)))
        }
    }

    private static func reason(_ error: Error) -> String {
        if error is NIOSSHError || error is PasswordOffer.Refused {
            return CartoucheText.storageSFTPRefused
        }
        return error.localizedDescription
    }

    // MARK: CartoucheRemote

    /// SFTP says nothing of what an account may do before it tries.
    var isReadOnly: Bool { false }

    func list(_ path: String) async throws -> [CartoucheRemoteItem] {
        var items: [CartoucheRemoteItem] = []
        for entry in try await connection.list(CartoucheSFTP.path(path)) {
            guard entry.name != ".", entry.name != "..", !entry.name.hasPrefix("."), !entry.attributes.isLink else { continue }
            let folder = entry.isFolder
            items.append(CartoucheRemoteItem(name: entry.name, isFolder: folder,
                                             size: folder ? 0 : entry.attributes.size ?? 0,
                                             modified: entry.attributes.modified))
        }
        return items
    }

    func open(_ path: String) async throws -> CartoucheByteSource {
        let file = CartoucheSFTP.path(path)
        let attributes = try await connection.stat(file)
        guard let size = attributes.size else {
            throw CartoucheStorageError(CartoucheText.storageSFTPBadAnswer)
        }
        let handle = try await connection.open(file, flags: .read)
        let opened = SFTPOpenFile(connection: connection, handle: handle)
        return CartoucheReadAhead(size: size) { offset, count in
            try await opened.read(at: offset, count: count)
        }
    }

    func create(_ path: String, size: UInt64?) async throws -> CartoucheRemoteUpload {
        let file = CartoucheSFTP.path(path)
        let partial = file + ".partial"
        let handle = try await connection.open(partial, flags: [.write, .create, .truncate])
        return SFTPUpload(connection: connection, handle: handle, partial: partial, path: file)
    }

    func makeFolder(_ path: String) async throws {
        try await connection.expectOK(CartoucheSFTP.makeFolder(id:_:), CartoucheSFTP.path(path))
    }

    func delete(_ path: String) async throws {
        let target = CartoucheSFTP.path(path)
        guard target != "." else { return }
        do {
            try await connection.expectOK(CartoucheSFTP.remove(id:_:), target)
        } catch let failure as SFTPFailure where failure.code != CartoucheSFTP.Status.noSuchFile.rawValue {
            // Not a file: a folder, emptied first.
            try await deleteFolder(target)
        }
    }

    private func deleteFolder(_ path: String) async throws {
        for entry in try await connection.list(path) where entry.name != "." && entry.name != ".." {
            let inside = path + "/" + entry.name
            if entry.isFolder && !entry.attributes.isLink {
                try await deleteFolder(inside)
            } else {
                try await connection.expectOK(CartoucheSFTP.remove(id:_:), inside)
            }
        }
        try await connection.expectOK(CartoucheSFTP.removeFolder(id:_:), path)
    }

    func freeSpace() async throws -> UInt64? {
        nil
    }

    func canWrite(_ path: String) async throws -> Bool {
        // SFTP cannot be asked: Cartouche makes an empty hidden file, which
        // no list shows, and removes it.
        let probe = CartoucheSFTP.path(CartoucheStoragePath.join(path, ".cartouche-write-check-" + UUID().uuidString))
        let handle: Data
        do {
            handle = try await connection.open(probe, flags: [.write, .create, .truncate])
        } catch let failure as SFTPFailure where failure.code == CartoucheSFTP.Status.permissionDenied.rawValue {
            return false
        }
        await connection.closeHandle(handle)
        try? await connection.expectOK(CartoucheSFTP.remove(id:_:), probe)
        return true
    }

    func disconnect() async {
        connection.close()
    }
}

/// What the server answered instead of what Cartouche asked.
struct SFTPFailure: LocalizedError {
    let code: UInt32
    let message: String

    var errorDescription: String? {
        message.isEmpty ? CartoucheText.storageSFTPFailure(Int(code)) : message
    }
}

// MARK: Files

private final class SFTPOpenFile {
    private let connection: SFTPConnection
    private let handle: Data

    init(connection: SFTPConnection, handle: Data) {
        self.connection = connection
        self.handle = handle
    }

    deinit {
        let connection = connection
        let handle = handle
        Task { await connection.closeHandle(handle) }
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        try await connection.read(handle, at: offset, count: count)
    }
}

/// A file being written, as "<name>.partial" until it is finished, so that
/// the file there, if any, stays until then.
private final class SFTPUpload: CartoucheRemoteUpload {
    private let connection: SFTPConnection
    private let handle: Data
    private let partial: String
    private let path: String
    private var offset: UInt64 = 0
    private var closed = false

    init(connection: SFTPConnection, handle: Data, partial: String, path: String) {
        self.connection = connection
        self.handle = handle
        self.partial = partial
        self.path = path
    }

    func write(_ data: Data) async throws {
        try await connection.write(handle, at: offset, data)
        offset += UInt64(data.count)
    }

    func finish() async throws {
        if !closed {
            closed = true
            try await connection.expectOK(CartoucheSFTP.close(id:handle:), handle)
        }
        // Version 3's RENAME does not replace a file.
        try? await connection.expectOK(CartoucheSFTP.remove(id:_:), path)
        try await connection.rename(partial, to: path)
    }

    func cancel() async {
        if !closed {
            closed = true
            await connection.closeHandle(handle)
        }
        try? await connection.expectOK(CartoucheSFTP.remove(id:_:), partial)
    }
}

// MARK: The connection

/// The server's key: the one Cartouche keeps, when it has one, or the first
/// it sees.
private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct Changed: Error {}

    private let expected: String?
    private let lock = NSLock()
    private var shown: String?

    init(expected: String?) {
        self.expected = expected
    }

    var seen: String? {
        lock.lock()
        defer { lock.unlock() }
        return shown
    }

    /// Whether the server showed another key than the one kept.
    var changed: Bool {
        guard let expected, let seen else { return false }
        return !CartoucheSFTP.sameKey(expected, seen)
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let text = String(openSSHPublicKey: hostKey)
        lock.lock()
        shown = text
        lock.unlock()
        if let expected, !CartoucheSFTP.sameKey(expected, text) {
            validationCompletePromise.fail(Changed())
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

/// The player's password, offered once.
private final class PasswordOffer: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    /// The server refused the password, or wants another way to sign in.
    struct Refused: Error {}

    private let user: String
    private let password: String
    private let lock = NSLock()
    private var offered = false
    private var gaveUp = false

    init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    /// Whether the server refused what Cartouche had to offer.
    var refused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gaveUp
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        lock.lock()
        let first = !offered
        offered = true
        let offering = first && availableMethods.contains(.password)
        if !offering { gaveUp = true }
        lock.unlock()
        guard offering else {
            // Nothing else to offer: the server refuses the account. Failing
            // closes the connection at once (CloseOnError); offering nothing
            // would leave NIOSSH waiting until the server gives up, two
            // minutes on OpenSSH (LoginGraceTime).
            nextChallengePromise.fail(Refused())
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: user, serviceName: "", offer: .password(.init(password: password))
        ))
    }
}

/// Closes the connection on an error, which fails the requests waiting.
private final class CloseOnError: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// The SFTP channel: the answers it reads go to the requests waiting for
/// them, by id.
private final class SFTPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    struct Closed: LocalizedError {
        var errorDescription: String? { CartoucheText.storageSFTPClosed }
    }

    private let lock = NSLock()
    private var reader = CartoucheSFTP.Reader()
    private var waiting: [UInt32: CheckedContinuation<CartoucheSFTP.Response, Error>] = [:]
    private var version: CheckedContinuation<UInt32, Error>?
    private var subsystem: CheckedContinuation<Void, Error>?
    private var isClosed = false

    /// Waits for ID's answer; fails at once when the channel is closed.
    func expect(_ id: UInt32, _ continuation: CheckedContinuation<CartoucheSFTP.Response, Error>) {
        lock.lock()
        if isClosed {
            lock.unlock()
            continuation.resume(throwing: Closed())
            return
        }
        waiting[id] = continuation
        lock.unlock()
    }

    func fail(_ id: UInt32, _ error: Error) {
        lock.lock()
        let continuation = waiting.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func expectVersion(_ continuation: CheckedContinuation<UInt32, Error>) {
        lock.lock()
        version = continuation
        lock.unlock()
    }

    func expectSubsystem(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        subsystem = continuation
        lock.unlock()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case let .byteBuffer(buffer) = message.data else { return }
        var answers: [CartoucheSFTP.Response] = []
        var broken = false
        lock.lock()
        reader.append(Data(buffer.readableBytesView))
        do {
            while let answer = try reader.next() {
                answers.append(answer)
            }
        } catch {
            broken = true
        }
        lock.unlock()
        for answer in answers {
            deliver(answer)
        }
        if broken {
            context.close(promise: nil)
        }
    }

    private func deliver(_ answer: CartoucheSFTP.Response) {
        lock.lock()
        if case let .version(number) = answer {
            let continuation = version
            version = nil
            lock.unlock()
            continuation?.resume(returning: number)
            return
        }
        let continuation = answer.id.flatMap { waiting.removeValue(forKey: $0) }
        lock.unlock()
        continuation?.resume(returning: answer)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        let result: Result<Void, Error>?
        switch event {
        case is ChannelSuccessEvent: result = .success(())
        case is ChannelFailureEvent: result = .failure(CartoucheStorageError(CartoucheText.storageSFTPNoSubsystem))
        default: result = nil
        }
        guard let result else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        lock.lock()
        let continuation = subsystem
        subsystem = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        isClosed = true
        let all = Array(waiting.values)
        waiting = [:]
        let version = self.version
        self.version = nil
        let subsystem = self.subsystem
        self.subsystem = nil
        lock.unlock()
        for continuation in all { continuation.resume(throwing: Closed()) }
        version?.resume(throwing: Closed())
        subsystem?.resume(throwing: Closed())
        context.fireChannelInactive()
    }
}

/// One SSH connection, with its SFTP channel.
private final class SFTPConnection: @unchecked Sendable {
    private let parent: Channel
    private let channel: Channel
    private let handler: SFTPChannelHandler
    private let lock = NSLock()
    private var lastID: UInt32 = 0
    /// What one READ or WRITE carries, which every server takes.
    private static let piece = 32 << 10
    /// How many of them are under way at once.
    private static let inFlight = 16

    private init(parent: Channel, channel: Channel, handler: SFTPChannelHandler) {
        self.parent = parent
        self.channel = channel
        self.handler = handler
    }

    /// Once the remote and its open files are gone.
    deinit {
        close()
    }

    static func open(host: String, port: Int, user: String, password: String, check: HostKeyCheck) async throws -> SFTPConnection {
        let offer = PasswordOffer(user: user, password: password)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(20))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: offer, serverAuthDelegate: check)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(CloseOnError())
                }
            }
        let parent = try await bootstrap.connect(host: host, port: port).get()
        let handler = SFTPChannelHandler()
        do {
            let channel = try await parent.eventLoop.flatSubmit { () -> EventLoopFuture<Channel> in
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                do {
                    let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(promise, channelType: .session) { child, _ in
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(handler)
                        }
                    }
                } catch {
                    promise.fail(error)
                }
                return promise.futureResult
            }.get()
            let connection = SFTPConnection(parent: parent, channel: channel, handler: handler)
            try await connection.start()
            return connection
        } catch {
            parent.close(promise: nil)
            // The connection closed because the password was refused: say
            // that, not how the channel ended.
            if offer.refused { throw PasswordOffer.Refused() }
            throw error
        }
    }

    /// Asks for the SFTP subsystem, then says which version Cartouche speaks.
    private func start() async throws {
        let request = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            handler.expectSubsystem(continuation)
            channel.triggerUserOutboundEvent(request).whenFailure { error in
                self.handler.channelInactiveFailure(error)
            }
        }
        let version = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt32, Error>) in
            handler.expectVersion(continuation)
            send(CartoucheSFTP.initialize())
        }
        guard version >= 3 else { throw CartoucheStorageError(CartoucheText.storageSFTPBadAnswer) }
    }

    func close() {
        channel.close(promise: nil)
        parent.close(promise: nil)
    }

    private func nextID() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        lastID &+= 1
        return lastID
    }

    private func send(_ bytes: Data) {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    /// Sends the request MAKE writes with a new id, and gives its answer.
    func request(_ make: (UInt32) -> Data) async throws -> CartoucheSFTP.Response {
        let id = nextID()
        let bytes = make(id)
        return try await withCheckedThrowingContinuation { continuation in
            handler.expect(id, continuation)
            var buffer = channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).whenFailure { error in
                self.handler.fail(id, error)
            }
        }
    }

    private static func check(_ answer: CartoucheSFTP.Response) throws {
        guard case let .status(_, code, message) = answer else {
            throw CartoucheStorageError(CartoucheText.storageSFTPBadAnswer)
        }
        guard code == CartoucheSFTP.Status.ok.rawValue else {
            throw SFTPFailure(code: code, message: message)
        }
    }

    private static func handle(_ answer: CartoucheSFTP.Response) throws -> Data {
        if case let .handle(_, handle) = answer { return handle }
        try check(answer)
        throw CartoucheStorageError(CartoucheText.storageSFTPBadAnswer)
    }

    /// Runs MAKE on PATH, which must answer OK.
    func expectOK(_ make: @escaping (UInt32, String) -> Data, _ path: String) async throws {
        let answer = try await request { make($0, path) }
        try Self.check(answer)
    }

    func expectOK(_ make: @escaping (UInt32, Data) -> Data, _ handle: Data) async throws {
        let answer = try await request { make($0, handle) }
        try Self.check(answer)
    }

    func closeHandle(_ handle: Data) async {
        _ = try? await request { CartoucheSFTP.close(id: $0, handle: handle) }
    }

    func rename(_ from: String, to: String) async throws {
        let answer = try await request { CartoucheSFTP.rename(id: $0, from: from, to: to) }
        try Self.check(answer)
    }

    func stat(_ path: String) async throws -> CartoucheSFTP.Attributes {
        let answer = try await request { CartoucheSFTP.stat(id: $0, path) }
        if case let .attributes(_, attributes) = answer { return attributes }
        try Self.check(answer)
        throw CartoucheStorageError(CartoucheText.storageSFTPBadAnswer)
    }

    func open(_ path: String, flags: CartoucheSFTP.OpenFlags) async throws -> Data {
        let answer = try await request { CartoucheSFTP.open(id: $0, path, flags: flags) }
        return try Self.handle(answer)
    }

    /// The entries of the folder at PATH.
    func list(_ path: String) async throws -> [CartoucheSFTP.Entry] {
        let opened = try await request { CartoucheSFTP.openFolder(id: $0, path) }
        let handle = try Self.handle(opened)
        var entries: [CartoucheSFTP.Entry] = []
        do {
            while true {
                let answer = try await request { CartoucheSFTP.readFolder(id: $0, handle: handle) }
                if case let .name(_, more) = answer {
                    entries += more
                    continue
                }
                if case let .status(_, code, _) = answer, code == CartoucheSFTP.Status.endOfFile.rawValue {
                    break
                }
                try Self.check(answer)
                break
            }
        } catch {
            await closeHandle(handle)
            throw error
        }
        await closeHandle(handle)
        return entries
    }

    /// COUNT bytes of the file HANDLE from OFFSET, fewer if it ends first.
    func read(_ handle: Data, at offset: UInt64, count: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let start = offset + UInt64(data.count)
            let wanted = count - data.count
            let pieces = try await readPieces(handle, at: start, count: min(wanted, Self.piece * Self.inFlight))
            var ended = false
            for (asked, piece) in pieces {
                data.append(piece)
                if piece.count < asked {
                    // The file ended, or the server gave less: what follows
                    // is asked again from there.
                    ended = piece.isEmpty
                    break
                }
            }
            if ended { break }
        }
        return data
    }

    /// The pieces of [OFFSET, OFFSET + COUNT), asked at once, in order, each
    /// with the size asked.
    private func readPieces(_ handle: Data, at offset: UInt64, count: Int) async throws -> [(Int, Data)] {
        try await withThrowingTaskGroup(of: (Int, Int, Data).self) { group in
            var index = 0
            var at = 0
            while at < count {
                let asked = min(Self.piece, count - at)
                let position = offset + UInt64(at)
                let number = index
                group.addTask {
                    let answer = try await self.request {
                        CartoucheSFTP.read(id: $0, handle: handle, offset: position, count: UInt32(asked))
                    }
                    switch answer {
                    case let .data(_, bytes):
                        return (number, asked, bytes)
                    case let .status(_, code, _) where code == CartoucheSFTP.Status.endOfFile.rawValue:
                        return (number, asked, Data())
                    default:
                        try Self.check(answer)
                        throw CartoucheStorageError(CartoucheText.storageSFTPBadAnswer)
                    }
                }
                index += 1
                at += asked
            }
            var pieces = [(Int, Data)](repeating: (0, Data()), count: index)
            for try await (number, asked, bytes) in group {
                pieces[number] = (asked, bytes)
            }
            return pieces
        }
    }

    /// Writes DATA to the file HANDLE at OFFSET, many pieces at once.
    func write(_ handle: Data, at offset: UInt64, _ data: Data) async throws {
        var at = 0
        while at < data.count {
            let end = min(data.count, at + Self.piece * Self.inFlight)
            try await withThrowingTaskGroup(of: Void.self) { group in
                var piece = at
                while piece < end {
                    let stop = min(end, piece + Self.piece)
                    let bytes = data.subdata(in: data.startIndex + piece ..< data.startIndex + stop)
                    let position = offset + UInt64(piece)
                    group.addTask {
                        let answer = try await self.request {
                            CartoucheSFTP.write(id: $0, handle: handle, offset: position, bytes)
                        }
                        try Self.check(answer)
                    }
                    piece = stop
                }
                try await group.waitForAll()
            }
            at = end
        }
    }
}

private extension SFTPChannelHandler {
    /// The subsystem request could not even be sent.
    func channelInactiveFailure(_ error: Error) {
        lock.lock()
        let continuation = subsystem
        subsystem = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
#endif
