//
//  BridgeServer.swift
//  Cartouche Builder
//
//  The bridge's Mac side: Cartouche on the iPhone finds the Mac over
//  Bonjour (_cartouche._tcp, named after the Mac) and reads and writes two
//  folders through it, Games (the games folder, on the Mac or on the NAS)
//  and Saves. An iPhone pairs once, the player comparing the six digits
//  both screens show (CartoucheBridge.swift); then each connection is a
//  session encrypted with its paired key. Nothing outside the two folders
//  can be reached, hidden files are never shown, an upload is written to a
//  hidden file and named only once complete, and a deleted file goes to the
//  Trash when its disk has one. The Mac stays awake while an iPhone is
//  connected.
//

import CartoucheCore
import Foundation
import Network

public struct BridgeRoots: Equatable, Sendable {
    public var games: URL?
    public var saves: URL?

    public init(games: URL? = nil, saves: URL? = nil) {
        self.games = games
        self.saves = saves
    }
}

@MainActor
public protocol BridgeServerDelegate: AnyObject {
    /// Whether the iPhone NAME may pair, the player checking that it shows CODE.
    func bridgeServer(_ server: BridgeServer, allowPairing name: String, code: String) async -> Bool
    /// The server's state, its sessions or its devices changed.
    func bridgeServerChanged(_ server: BridgeServer)
}

public final class BridgeServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    /// At most this many pairings asked in ten minutes.
    static let pairingsPerWindow = 5
    /// A session without a request for this long is closed.
    static let idleTimeout: TimeInterval = 15 * 60

    public let devices: BridgeDevices
    public weak var delegate: BridgeServerDelegate?

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.github.clabeuhtegrite.cartouche-builder.bridge")
    private var listener: NWListener?
    private var _state: State = .stopped
    private var _roots = BridgeRoots()
    private var _name: String
    private var sessions: [UUID: String] = [:]
    private var pairing = false
    private var pairingTimes: [Date] = []
    private var activity: NSObjectProtocol?
    private var generation = 0

    public init(devices: BridgeDevices, name: String) {
        self.devices = devices
        _name = name
    }

    // MARK: State

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public var roots: BridgeRoots {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _roots
        }
        set {
            lock.lock()
            _roots = newValue
            lock.unlock()
        }
    }

    public var name: String {
        lock.lock()
        defer { lock.unlock() }
        return _name
    }

    /// The paired devices connected now, by ID.
    public var connected: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(sessions.values)
    }

    private func set(_ state: State) {
        lock.lock()
        _state = state
        lock.unlock()
        changed()
    }

    private func changed() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.bridgeServerChanged(self)
        }
    }

    // MARK: Listening

    /// Starts listening on the bridge's port, or on another one when it is
    /// taken: Bonjour tells the iPhone which.
    public func start() {
        lock.lock()
        let running = listener != nil
        generation += 1
        let current = generation
        lock.unlock()
        guard !running else { return }
        set(.starting)
        listen(on: NWEndpoint.Port(rawValue: CartoucheBridge.port), generation: current)
    }

    private func listen(on port: NWEndpoint.Port?, generation current: Int) {
        let parameters = CartoucheBridgeConnection.parameters()
        parameters.allowLocalEndpointReuse = true
        let made: NWListener
        do {
            if let port {
                made = try NWListener(using: parameters, on: port)
            } else {
                made = try NWListener(using: parameters)
            }
        } catch {
            set(.failed(error.localizedDescription))
            return
        }
        var record = NWTXTRecord()
        record["id"] = devices.macID
        record["v"] = String(CartoucheBridge.version)
        made.service = NWListener.Service(name: name, type: CartoucheBridge.serviceType, domain: nil, txtRecord: record)
        made.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        made.stateUpdateHandler = { [weak self, weak made] state in
            guard let self, let made else { return }
            switch state {
            case .ready:
                self.set(.running(port: made.port?.rawValue ?? 0))
            case let .failed(error):
                made.cancel()
                self.lock.lock()
                let same = self.listener === made && self.generation == current
                if same { self.listener = nil }
                self.lock.unlock()
                guard same else { return }
                if port != nil, case let .posix(code) = error, code == .EADDRINUSE {
                    self.listen(on: nil, generation: current)
                } else {
                    self.set(.failed(error.localizedDescription))
                }
            default:
                break
            }
        }
        lock.lock()
        listener = made
        lock.unlock()
        made.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let current = listener
        listener = nil
        generation += 1
        lock.unlock()
        current?.cancel()
        set(.stopped)
    }

    /// Advertises the Mac under NAME from now on.
    public func rename(_ name: String) {
        lock.lock()
        let same = _name == name
        _name = name
        let current = listener
        lock.unlock()
        guard !same, let current else { return }
        var record = NWTXTRecord()
        record["id"] = devices.macID
        record["v"] = String(CartoucheBridge.version)
        current.service = NWListener.Service(name: name, type: CartoucheBridge.serviceType, domain: nil, txtRecord: record)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let transport = CartoucheBridgeConnection(connection, queue: queue)
        Task { [weak self] in
            guard let self else {
                transport.close()
                return
            }
            await self.open(transport)
        }
    }

    private func open(_ transport: CartoucheBridgeConnection) async {
        // A connection that does not finish its handshake in time is closed,
        // which ends the reads it waits on.
        let handshaking = Flag()
        handshaking.set()
        queue.asyncAfter(deadline: .now() + CartoucheBridge.pairingTimeout + 30) {
            if handshaking.isSet { transport.close() }
        }
        do {
            try await transport.start(timeout: 10)
            let opening = try await CartoucheBridgeHandshake.server(transport, mac: devices.macID, name: name,
                                                                     keyOf: { [devices] in devices.key(of: $0) },
                                                                     allow: { [weak self] name, code in
                                                                         await self?.askPairing(name: name, code: code) ?? false
                                                                     })
            handshaking.clear()
            switch opening {
            case let .session(channel):
                await serve(channel)
            case let .paired(device, name, key):
                devices.add(id: device, name: name, key: key)
                changed()
                transport.close()
            case .refused:
                transport.close()
            }
        } catch {
            handshaking.clear()
            transport.close()
        }
    }

    /// One pairing at a time, a few in ten minutes, each asked of the player.
    private func askPairing(name: String, code: String) async -> Bool {
        lock.lock()
        let now = Date()
        pairingTimes.removeAll { now.timeIntervalSince($0) > 600 }
        guard !pairing, pairingTimes.count < BridgeServer.pairingsPerWindow else {
            lock.unlock()
            return false
        }
        pairing = true
        pairingTimes.append(now)
        lock.unlock()
        defer {
            lock.lock()
            pairing = false
            lock.unlock()
        }
        guard let delegate = await MainActor.run(body: { self.delegate }) else { return false }
        return await delegate.bridgeServer(self, allowPairing: name, code: code)
    }

    private func serve(_ channel: CartoucheBridgeSecureChannel) async {
        let id = UUID()
        devices.seen(channel.peer)
        lock.lock()
        sessions[id] = channel.peer
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Cartouche on an iPhone reads or writes its games")
        }
        lock.unlock()
        changed()
        let session = Session(server: self, peer: channel.peer)
        let idle = Flag()
        watchIdle(idle, channel: channel)
        defer {
            session.discardUploads()
            channel.close()
            idle.clear()
            lock.lock()
            sessions[id] = nil
            if sessions.isEmpty, let current = activity {
                ProcessInfo.processInfo.endActivity(current)
                activity = nil
            }
            lock.unlock()
            changed()
        }
        while true {
            let received: (CartoucheBridgeRequest, Data)
            do {
                received = try await channel.receive(CartoucheBridgeRequest.self)
            } catch {
                return
            }
            let (request, body) = received
            idle.touch()
            // A device removed from the Mac's list is not served any more.
            guard devices.key(of: channel.peer) != nil else { return }
            let (response, data) = session.handle(request, body: body)
            do {
                try await channel.send(response, body: data)
            } catch {
                return
            }
        }
    }

    private func watchIdle(_ idle: Flag, channel: CartoucheBridgeSecureChannel) {
        idle.set()
        idle.touch()
        func check() {
            queue.asyncAfter(deadline: .now() + 60) {
                guard idle.isSet else { return }
                if Date().timeIntervalSince(idle.last) > BridgeServer.idleTimeout {
                    channel.close()
                } else {
                    check()
                }
            }
        }
        check()
    }
}

/// A flag and a time, shared with the timers of a connection.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var time = Date()

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var last: Date {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func clear() {
        lock.lock()
        value = false
        lock.unlock()
    }

    func touch() {
        lock.lock()
        time = Date()
        lock.unlock()
    }
}

// MARK: A session's requests

/// What one connected iPhone asks: its uploads under way, and the answers.
final class Session {
    struct Upload {
        var handle: FileHandle
        var partial: URL
        var final: URL
        var written: UInt64
    }

    weak var server: BridgeServer?
    let peer: String
    private var uploads: [String: Upload] = [:]

    init(server: BridgeServer, peer: String) {
        self.server = server
        self.peer = peer
    }

    func handle(_ request: CartoucheBridgeRequest, body: Data) -> (CartoucheBridgeResponse, Data) {
        do {
            return try answer(request, body: body)
        } catch let error as CartoucheBridgeError {
            return (.failure(error.kind, error.message), Data())
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return (.failure(.notFound, error.localizedDescription), Data())
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return (.failure(.exists, error.localizedDescription), Data())
        } catch let error as CocoaError where error.code == .fileWriteNoPermission || error.code == .fileReadNoPermission {
            return (.failure(.denied, error.localizedDescription), Data())
        } catch {
            return (.failure(.failed, error.localizedDescription), Data())
        }
    }

    private func answer(_ request: CartoucheBridgeRequest, body: Data) throws -> (CartoucheBridgeResponse, Data) {
        let manager = FileManager.default
        var response = CartoucheBridgeResponse()
        switch request.op {
        case .info:
            let roots = server?.roots ?? BridgeRoots()
            response.name = server?.name
            response.items = rootItems(roots)
            response.free = roots.games.flatMap(Session.free)
            response.readOnly = false
        case .list:
            let place = try resolve(request.path)
            guard let place else {
                response.items = rootItems(server?.roots ?? BridgeRoots())
                break
            }
            let entries = try manager.contentsOfDirectory(at: place.url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                                          options: [.skipsHiddenFiles])
            response.items = entries.compactMap(Session.item).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .stat:
            guard let place = try resolve(request.path) else {
                response.folder = true
                response.size = 0
                break
            }
            let values = try place.url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            response.folder = values.isDirectory ?? false
            response.size = UInt64(values.fileSize ?? 0)
            response.modified = values.contentModificationDate?.timeIntervalSince1970
        case .read:
            guard let place = try resolve(request.path) else { throw CartoucheBridgeError(.denied, "a folder") }
            let count = min(max(request.count ?? 0, 0), CartoucheBridge.maxRead)
            let handle = try FileHandle(forReadingFrom: place.url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let offset = request.offset ?? 0
            response.size = size
            guard offset < size, count > 0 else { return (response, Data()) }
            try handle.seek(toOffset: offset)
            return (response, try handle.read(upToCount: count) ?? Data())
        case .create:
            guard let place = try resolve(request.path), !place.isRoot else { throw CartoucheBridgeError(.denied, "a folder") }
            let folder = place.url.deletingLastPathComponent()
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if let size = request.size, let free = Session.free(folder), free < size + (64 << 20) {
                throw CartoucheBridgeError(.failed, tr("Not enough space on the Mac for this file.", "Pas assez de place sur le Mac pour ce fichier."))
            }
            let upload = UUID().uuidString
            let partial = folder.appendingPathComponent(".\(place.url.lastPathComponent).\(upload.prefix(8)).cartouche-upload")
            guard manager.createFile(atPath: partial.path, contents: nil) else { throw CartoucheBridgeError(.denied, folder.lastPathComponent) }
            let handle = try FileHandle(forWritingTo: partial)
            uploads[upload] = Upload(handle: handle, partial: partial, final: place.url, written: 0)
            response.upload = upload
        case .write:
            guard let key = request.upload, var upload = uploads[key] else { throw CartoucheBridgeError(.notFound, "upload") }
            try upload.handle.write(contentsOf: body)
            upload.written += UInt64(body.count)
            uploads[key] = upload
        case .finish:
            guard let key = request.upload, let upload = uploads.removeValue(forKey: key) else { throw CartoucheBridgeError(.notFound, "upload") }
            try upload.handle.synchronize()
            try upload.handle.close()
            if rename(upload.partial.path, upload.final.path) != 0 {
                let error = String(cString: strerror(errno))
                try? manager.removeItem(at: upload.partial)
                throw CartoucheBridgeError(.failed, error)
            }
            response.size = upload.written
        case .cancel:
            if let key = request.upload, let upload = uploads.removeValue(forKey: key) {
                try? upload.handle.close()
                try? manager.removeItem(at: upload.partial)
            }
        case .makeFolder:
            guard let place = try resolve(request.path) else { break }
            try manager.createDirectory(at: place.url, withIntermediateDirectories: true)
        case .delete:
            guard let place = try resolve(request.path), !place.isRoot else { throw CartoucheBridgeError(.denied, "a root") }
            guard manager.fileExists(atPath: place.url.path) else { throw CartoucheBridgeError(.notFound, place.url.lastPathComponent) }
            do {
                try manager.trashItem(at: place.url, resultingItemURL: nil)
            } catch {
                // A network share has no Trash.
                try manager.removeItem(at: place.url)
            }
        case .free:
            let roots = server?.roots ?? BridgeRoots()
            let place = try resolve(request.path)
            response.free = (place?.root ?? roots.games).flatMap(Session.free)
        case .canWrite:
            guard let place = try resolve(request.path) else {
                response.writable = false
                break
            }
            var folder = place.url
            var isFolder: ObjCBool = false
            if !manager.fileExists(atPath: folder.path, isDirectory: &isFolder) || !isFolder.boolValue {
                folder = folder.deletingLastPathComponent()
            }
            response.writable = manager.isWritableFile(atPath: folder.path)
        }
        return (response, Data())
    }

    func discardUploads() {
        for upload in uploads.values {
            try? upload.handle.close()
            try? FileManager.default.removeItem(at: upload.partial)
        }
        uploads.removeAll()
    }

    // MARK: Paths

    struct Place {
        var root: URL
        var url: URL
        var isRoot: Bool
    }

    /// The file or folder PATH names, "Games/…" or "Saves/…"; nil for the
    /// top, where the two are. Anything else, or outside them, is refused.
    func resolve(_ path: String?) throws -> Place? {
        guard let parts = CartoucheBridgePath.parts(path ?? "") else { throw CartoucheBridgeError(.denied, "path") }
        guard let first = parts.first else { return nil }
        let roots = server?.roots ?? BridgeRoots()
        let root: URL?
        switch first {
        case CartoucheBridge.gamesFolder: root = roots.games
        case CartoucheBridge.savesFolder: root = roots.saves
        default: throw CartoucheBridgeError(.notFound, first)
        }
        guard let root else { throw CartoucheBridgeError(.notFound, first) }
        var url = root
        for part in parts.dropFirst() {
            guard !part.hasPrefix("."), !part.contains("/") else { throw CartoucheBridgeError(.denied, part) }
            url.appendPathComponent(part)
        }
        // Nothing reached through a link that leads outside the folder.
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > root.pathComponents.count {
            existing.deleteLastPathComponent()
        }
        let resolved = existing.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw CartoucheBridgeError(.denied, "outside")
        }
        return Place(root: root, url: url, isRoot: parts.count == 1)
    }

    private func rootItems(_ roots: BridgeRoots) -> [CartoucheBridgeItem] {
        var items: [CartoucheBridgeItem] = []
        if roots.games != nil { items.append(CartoucheBridgeItem(name: CartoucheBridge.gamesFolder, folder: true, size: 0, modified: nil)) }
        if roots.saves != nil { items.append(CartoucheBridgeItem(name: CartoucheBridge.savesFolder, folder: true, size: 0, modified: nil)) }
        return items
    }

    static func item(_ url: URL) -> CartoucheBridgeItem? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
        let name = url.lastPathComponent
        if name.hasSuffix(".cartouche-upload") { return nil }
        return CartoucheBridgeItem(name: name, folder: values.isDirectory ?? false, size: UInt64(values.fileSize ?? 0),
                                   modified: values.contentModificationDate)
    }

    /// The free space of URL's disk, as the Finder counts it.
    static func free(_ url: URL) -> UInt64? {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return UInt64(capacity)
        }
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]), let capacity = values.volumeAvailableCapacity {
            return UInt64(max(0, capacity))
        }
        return nil
    }
}
