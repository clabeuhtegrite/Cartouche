//
//  MacBridgeTests.swift
//  CartoucheStorageTests
//
//  The player's Mac through Cartouche Builder's bridge, as the app reaches
//  it (CartoucheStorageMac.swift): the test plays the Mac on 127.0.0.1,
//  with the bridge's own handshake (CartoucheBridge.swift) and its two
//  folders, Games and Saves, in memory. Pairing and its six digits, a
//  pairing refused, signing in at the last address, and at once after
//  pairing with a Mac slow to write the pairing down, a Mac that forgot
//  this iPhone, another Mac at its address, a Mac gone, then files listed,
//  read, written, given up and removed. It needs no server, so it always
//  runs.
//  Bonjour needs a real network: the Mac's side of it is in builder/mac's
//  tests (BridgeSessionTests), its words in Cartouche's.
//

import Foundation
import Network
import XCTest
@testable import CartoucheStorage

/// A Mac with Cartouche Builder, played by the test.
final class FakeMac: @unchecked Sendable {
    enum Entry: Equatable {
        case folder
        case file(Data)
    }

    let macID: String
    let name: String
    private let lock = NSLock()
    private var allowing = true
    private var writing: TimeInterval = 0
    private var keys: [String: Data] = [:]
    private var codes: [String] = []
    private var entries: [String: Entry] = ["Games": .folder, "Saves": .folder]
    private var uploads: [String: (path: String, data: Data)] = [:]
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Fake Mac")
    private(set) var port = 0

    init(name: String = "Mac de test") {
        macID = UUID().uuidString
        self.name = name
    }

    /// Listens on 127.0.0.1, on a port of its own.
    func start() async throws {
        let parameters = CartoucheBridgeConnection.parameters()
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let transport = CartoucheBridgeConnection(connection, queue: self.queue)
            Task { await self.serve(transport) }
        }
        let once = CartoucheBridgeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case let .failed(error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = Int(listener.port?.rawValue ?? 0)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: What the test sets and reads

    func allow(_ allowing: Bool) {
        lock.lock()
        self.allowing = allowing
        lock.unlock()
    }

    /// Takes SECONDS to write a pairing down, as Cartouche Builder writing
    /// bridge.json on a busy disk.
    func slowToWrite(_ seconds: TimeInterval) {
        lock.lock()
        writing = seconds
        lock.unlock()
    }

    /// The iPhones paired with it.
    var paired: [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys.keys.sorted()
    }

    /// The codes it showed, in order.
    var shownCodes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return codes
    }

    /// Forgets DEVICE, as the player removing the iPhone on the Mac.
    func forget(_ device: String) {
        lock.lock()
        keys[device] = nil
        lock.unlock()
    }

    func entry(_ path: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }

    // MARK: The bridge

    private func key(of device: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return keys[device]
    }

    private func asked(code: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        codes.append(code)
        return allowing
    }

    private var writingTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return writing
    }

    private func keep(_ key: Data, of device: String) {
        lock.lock()
        keys[device] = key
        lock.unlock()
    }

    /// Writes the pairing down, in the time it takes.
    private func write(_ key: Data, of device: String) async {
        let wait = writingTime
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        keep(key, of: device)
    }

    private func serve(_ transport: CartoucheBridgeConnection) async {
        do {
            try await transport.start(timeout: 5)
            let opening = try await CartoucheBridgeHandshake.server(transport, mac: macID, name: name,
                                                                     keyOf: { [weak self] in self?.key(of: $0) },
                                                                     allow: { [weak self] _, code in self?.asked(code: code) ?? false },
                                                                     keep: { [weak self] device, _, key in await self?.write(key, of: device) })
            switch opening {
            case let .session(channel):
                while let (request, body) = try? await channel.receive(CartoucheBridgeRequest.self) {
                    let (response, data) = answer(request, body: body)
                    guard (try? await channel.send(response, body: data)) != nil else { break }
                }
                channel.close()
            case .paired, .refused:
                transport.close()
            }
        } catch {
            transport.close()
        }
    }

    private static func parent(_ path: String) -> String {
        CartoucheStoragePath.parent(path)
    }

    /// What Cartouche Builder answers, from the folders in memory.
    func answer(_ request: CartoucheBridgeRequest, body: Data) -> (CartoucheBridgeResponse, Data) {
        lock.lock()
        defer { lock.unlock() }
        let path = request.path ?? ""
        var response = CartoucheBridgeResponse()
        switch request.op {
        case .info:
            response.name = name
            response.readOnly = false
        case .list:
            guard path.isEmpty || entries[path] == .folder else { return (.failure(.notFound, path), Data()) }
            response.items = entries.filter { Self.parent($0.key) == path }
                .map { item -> CartoucheBridgeItem in
                    if case let .file(data) = item.value {
                        return CartoucheBridgeItem(name: CartoucheStoragePath.name(item.key), folder: false, size: UInt64(data.count), modified: nil)
                    }
                    return CartoucheBridgeItem(name: CartoucheStoragePath.name(item.key), folder: true, size: 0, modified: nil)
                }
                .sorted { $0.name < $1.name }
        case .stat:
            switch entries[path] {
            case .folder?: response.folder = true
            case let .file(data)?:
                response.folder = false
                response.size = UInt64(data.count)
            case nil: return (.failure(.notFound, path), Data())
            }
        case .read:
            guard case let .file(data)? = entries[path] else { return (.failure(.notFound, path), Data()) }
            let start = Int(min(request.offset ?? 0, UInt64(data.count)))
            let end = min(start + min(request.count ?? 0, CartoucheBridge.maxRead), data.count)
            response.size = UInt64(data.count)
            return (response, data.subdata(in: start ..< end))
        case .create:
            guard !Self.parent(path).isEmpty, entries[Self.parent(path)] == .folder else { return (.failure(.denied, path), Data()) }
            let upload = UUID().uuidString
            uploads[upload] = (path, Data())
            response.upload = upload
        case .write:
            guard let upload = request.upload, uploads[upload] != nil else { return (.failure(.notFound, "upload"), Data()) }
            uploads[upload]?.data.append(body)
        case .finish:
            guard let upload = request.upload, let done = uploads.removeValue(forKey: upload) else { return (.failure(.notFound, "upload"), Data()) }
            entries[done.path] = .file(done.data)
            response.size = UInt64(done.data.count)
        case .cancel:
            if let upload = request.upload { uploads[upload] = nil }
        case .makeFolder:
            guard entries[Self.parent(path)] == .folder || Self.parent(path).isEmpty, !path.isEmpty else { return (.failure(.denied, path), Data()) }
            guard entries[path] == nil else { return (.failure(.exists, path), Data()) }
            entries[path] = .folder
        case .delete:
            guard Self.parent(path) != "", entries[path] != nil else { return (.failure(.denied, path), Data()) }
            entries = entries.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        case .free:
            response.free = 1 << 40
        case .canWrite:
            response.writable = !path.isEmpty && entries[path] == .folder
        case .builds, .build:
            // A Mac without builds to show, whose info does not say it has some.
            return (.failure(.notFound, "builds"), Data())
        }
        return (response, Data())
    }
}

/// The digits the iPhone showed, from the pairing's task.
private final class ShownCodes: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [String] = []

    func add(_ code: String) {
        lock.lock()
        codes.append(code)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return codes
    }
}

final class MacBridgeTests: XCTestCase {
    private var mac: FakeMac!

    override func setUp() async throws {
        mac = FakeMac()
        try await mac.start()
    }

    override func tearDown() async throws {
        mac.stop()
    }

    private func endpoint(_ port: Int) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
    }

    /// Settings of their own, which keep nothing: the servers here are
    /// never saved, so the keychain is left alone.
    private func settings() -> CartoucheStorageSettings {
        CartoucheStorageSettings(defaults: UserDefaults(suiteName: "MacBridgeTests." + UUID().uuidString)!)
    }

    /// Pairs as the Storage page does once the player chose the Mac, and
    /// checks that both screens showed the same digits.
    private func pair() async throws -> (server: CartoucheStorageServer, secret: String) {
        let shown = ShownCodes()
        let paired = try await CartoucheMacStorage.pair(CartoucheStorageServer(kind: .mac, name: ""), at: endpoint(mac.port),
                                                        name: "Mac de test", deviceName: "iPhone de test") { shown.add($0) }
        XCTAssertEqual(shown.all.count, 1)
        XCTAssertEqual(shown.all.first?.count, 6)
        XCTAssertEqual(shown.all, mac.shownCodes, "both screens show the same digits")
        return paired
    }

    private func signIn() async throws -> CartoucheRemote {
        let (server, secret) = try await pair()
        return try await CartoucheMacStorage.connect(server, secret: secret, settings: settings())
    }

    func testPairsOnceThenSignsInAtTheLastAddress() async throws {
        let (server, secret) = try await pair()
        XCTAssertEqual(server.kind, .mac)
        XCTAssertEqual(server.macID, mac.macID)
        XCTAssertEqual(server.name, "Mac de test")
        XCTAssertEqual(server.host, "127.0.0.1")
        XCTAssertEqual(server.port, mac.port)
        XCTAssertNotNil(CartoucheMacStorage.pairedKey(secret))
        XCTAssertEqual(mac.paired, [CartoucheMacStorage.deviceID(of: server)])

        let started = Date()
        let remote = try await CartoucheMacStorage.connect(server, secret: secret, settings: settings())
        XCTAssertLessThan(Date().timeIntervalSince(started), CartoucheMacStorage.lastAddressPatience,
                          "at the last address, without looking for the Mac")
        let top = try await remote.list("")
        XCTAssertEqual(top.map(\.name), ["Games", "Saves"])
        XCTAssertTrue(top.allSatisfy(\.isFolder))
        XCTAssertFalse(remote.isReadOnly)
        await remote.disconnect()
        let answers = await CartoucheStorageReach.answers(server)
        XCTAssertTrue(answers, "it takes a connection at its last address")
    }

    func testAPairingTheMacRefusesSaysSo() async throws {
        mac.allow(false)
        let shown = ShownCodes()
        do {
            _ = try await CartoucheMacStorage.pair(CartoucheStorageServer(kind: .mac, name: ""), at: endpoint(mac.port),
                                                   name: "Mac de test", deviceName: "iPhone de test") { shown.add($0) }
            XCTFail("paired anyway")
        } catch {
            XCTAssertEqual((error as NSError).domain, "CartoucheBridge.refused")
            XCTAssertEqual(error.localizedDescription, CartoucheText.storageMacRefused("Mac de test"))
        }
        XCTAssertEqual(shown.all.count, 1, "the digits showed while the Mac asked")
        XCTAssertEqual(mac.paired, [])
    }

    func testSignsInAtOnceAfterPairingWithAMacSlowToWriteItDown() async throws {
        // Cartouche signs in as soon as the Mac says the iPhone is paired,
        // to take its folders for the games and the saves: the Mac has
        // written the pairing down by then, however long that takes it.
        mac.slowToWrite(0.5)
        let (server, secret) = try await pair()
        XCTAssertEqual(mac.paired, [CartoucheMacStorage.deviceID(of: server)])
        let remote = try await CartoucheMacStorage.connect(server, secret: secret, settings: settings())
        let top = try await remote.list("")
        XCTAssertEqual(top.map(\.name), ["Games", "Saves"])
        await remote.disconnect()
    }

    func testAMacThatForgotThisIPhoneAsksToPairAgain() async throws {
        let (server, secret) = try await pair()
        mac.forget(CartoucheMacStorage.deviceID(of: server))
        do {
            _ = try await CartoucheMacStorage.connect(server, secret: secret, settings: settings())
            XCTFail("signed in to a Mac that forgot this iPhone")
        } catch {
            XCTAssertEqual((error as NSError).domain, "CartoucheBridge.notPaired")
            XCTAssertEqual(error.localizedDescription, CartoucheText.storageMacNotPaired(server.name))
        }
    }

    func testAnotherMacAtTheLastAddressIsNotSignedInTo() async throws {
        let (server, secret) = try await pair()
        let other = FakeMac(name: "Autre Mac")
        try await other.start()
        defer { other.stop() }
        var moved = server
        moved.port = other.port
        // Nor does Bonjour find this one: it is offline, not unpaired.
        do {
            _ = try await CartoucheMacStorage.connect(moved, secret: secret, settings: settings())
            XCTFail("signed in to another Mac")
        } catch {
            XCTAssertTrue(error is CartoucheStorageOffline, String(describing: error))
            XCTAssertEqual(error.localizedDescription, CartoucheText.storageMacOffline(server.name))
        }
        XCTAssertEqual(other.paired, [])
    }

    func testAMacGoneIsOfflineWithinItsPatience() async throws {
        let (server, secret) = try await pair()
        mac.stop()
        let started = Date()
        do {
            _ = try await CartoucheMacStorage.connect(server, secret: secret, settings: settings())
            XCTFail("signed in to a Mac that is gone")
        } catch {
            // Offline, as a NAS away from home: no report, tried again.
            XCTAssertTrue(error is CartoucheStorageOffline, String(describing: error))
            XCTAssertEqual(error.localizedDescription, CartoucheText.storageMacOffline(server.name))
        }
        // Nothing listens there: the last address fails at once, then
        // Bonjour has its few seconds.
        XCTAssertLessThan(Date().timeIntervalSince(started), CartoucheMacStorage.lookupPatience + 2)
        let answers = await CartoucheStorageReach.answers(server)
        XCTAssertFalse(answers)
    }

    func testAMacAwayFromHomeIsOfflineWithinItsPatience() async throws {
        // Its last address never answers (TEST-NET-1, RFC 5737), as the
        // player's home seen from anywhere else.
        var server = CartoucheStorageServer(kind: .mac, name: "Mac de test", host: "192.0.2.1", port: Int(CartoucheBridge.port))
        server.macID = UUID().uuidString
        let secret = Data(repeating: 9, count: 32).base64EncodedString()
        let started = Date()
        do {
            _ = try await CartoucheMacStorage.connect(server, secret: secret, settings: settings())
            XCTFail("signed in to an address that never answers")
        } catch {
            XCTAssertTrue(error is CartoucheStorageOffline, String(describing: error))
            XCTAssertEqual(error.localizedDescription, CartoucheText.storageMacOffline("Mac de test"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started),
                          CartoucheMacStorage.lastAddressPatience + CartoucheMacStorage.lookupPatience + 2)
    }

    func testAnIPAAndSavesGoBothWays() async throws {
        let remote = try await signIn()
        // More than a read ahead (4 MiB), and not a whole number of them.
        var ipa = Data(count: (9 << 20) + 12345)
        for index in stride(from: 0, to: ipa.count, by: 4093) {
            ipa[index] = UInt8(truncatingIfNeeded: index / 4093)
        }
        let path = "Games/Test [0100000000010000].ipa"
        try await remote.write(ipa, to: path)
        XCTAssertEqual(mac.entry(path), .file(ipa))
        let listed = try await remote.list("Games")
        XCTAssertEqual(listed.map(\.name), ["Test [0100000000010000].ipa"])
        XCTAssertEqual(listed.first?.size, UInt64(ipa.count))
        XCTAssertEqual(listed.first?.isFolder, false)

        let source = try await remote.open(path)
        XCTAssertEqual(source.size, UInt64(ipa.count))
        let middle = try await source.read(at: 5 << 20, count: 1000)
        XCTAssertEqual(middle, ipa.subdata(in: (5 << 20) ..< (5 << 20) + 1000))
        let end = try await source.read(at: UInt64(ipa.count - 10), count: 100)
        XCTAssertEqual(end, ipa.suffix(10))
        let whole = try await source.read(at: 0, count: ipa.count)
        XCTAssertEqual(whole, ipa)

        try await remote.makeFolders("Saves/0100000000010000")
        try await remote.write(Data("save".utf8), to: "Saves/0100000000010000/1.zip")
        let save = try await remote.read("Saves/0100000000010000/1.zip")
        XCTAssertEqual(save, Data("save".utf8))
        // A copy given up leaves nothing.
        let upload = try await remote.create("Saves/0100000000010000/2.zip", size: 3)
        try await upload.write(Data("abc".utf8))
        await upload.cancel()
        let copies = try await remote.list("Saves/0100000000010000")
        XCTAssertEqual(copies.map(\.name), ["1.zip"])
        try await remote.delete("Saves/0100000000010000/1.zip")
        let left = try await remote.list("Saves/0100000000010000")
        XCTAssertEqual(left, [])

        let canWriteSaves = try await remote.canWrite("Saves")
        XCTAssertTrue(canWriteSaves)
        let canWriteTop = try await remote.canWrite("")
        XCTAssertFalse(canWriteTop)
        let free = try await remote.freeSpace()
        XCTAssertEqual(free, 1 << 40)
        await remote.disconnect()
    }

    func testWhatTheMacSaysIsInThePlayersWords() async throws {
        let remote = try await signIn()
        do {
            _ = try await remote.open("Games/Nothing.ipa")
            XCTFail("a file that is not there")
        } catch {
            // Its kind stays for the report.
            XCTAssertEqual((error as NSError).domain, "CartoucheBridge.notFound")
            XCTAssertEqual(error.localizedDescription, CartoucheText.storageMacNotFound("Nothing.ipa"))
        }
        do {
            try await remote.makeFolder("Games")
            XCTFail("a folder made twice")
        } catch {
            XCTAssertEqual(error.localizedDescription, CartoucheText.storageMacExists("Games"))
        }
        do {
            _ = try await remote.open("Games")
            XCTFail("a folder opened as a file")
        } catch {
            XCTAssertEqual((error as NSError).domain, "CartoucheBridge.notFound")
        }
        await remote.disconnect()
    }
}
