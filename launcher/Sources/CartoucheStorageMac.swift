//
//  CartoucheStorageMac.swift
//  Cartouche
//
//  The player's Mac as storage, through Cartouche Builder's bridge
//  (CartoucheBridge.swift): Cartouche finds the Mac on the Wi-Fi with
//  Bonjour, pairs with it once, the player checking that both screens show
//  the same six digits, and then reads and writes the two folders the Mac
//  shares, Games and Saves, as it would a shared folder. The Mac's Games
//  folder is where Cartouche Builder puts the games it builds, on the Mac
//  or on the NAS it reaches.
//
//  The Mac is known by its ID in Cartouche Builder. Cartouche first tries
//  the address it last reached the Mac at, which also answers through the
//  player's VPN, where Bonjour does not go; then it looks for that ID on
//  the network, so a new address from the router changes nothing.
//
//  The paired key is the server's secret in the keychain, in base64. The
//  iPhone's ID for the Mac is the server's own UUID: two Macs cannot tell
//  they serve the same iPhone.
//

import Combine
import Foundation
import Network

/// A Mac with Cartouche Builder on this network, as Bonjour lists it.
struct CartoucheNearbyMac: Identifiable, Hashable {
    /// The Mac's name.
    let name: String
    /// Its ID in Cartouche Builder, from its Bonjour record.
    let macID: String?
    let endpoint: NWEndpoint

    var id: String { macID ?? name }
}

/// The Macs whose Cartouche Builder shares with Cartouche on this network
/// (_cartouche._tcp).
final class CartoucheMacBrowser: ObservableObject {
    @Published private(set) var found: [CartoucheNearbyMac] = []
    /// Whether iOS keeps Cartouche from looking: it may not reach the local
    /// network (Settings › Privacy & Security › Local Network).
    @Published private(set) var refused = false
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "Cartouche Mac browser")

    #if CARTOUCHE_GALLERY
    /// What the launcher's gallery (launcher/Gallery) shows in place of
    /// Bonjour's answers: the Macs nearby, and whether iOS refuses Cartouche
    /// the local network.
    static var gallery: (found: [CartoucheNearbyMac], refused: Bool)?
    #endif

    func start() {
        #if CARTOUCHE_GALLERY
        if let gallery = Self.gallery {
            found = gallery.found
            refused = gallery.refused
            return
        }
        #endif
        guard browser == nil else { return }
        let browser = NWBrowser(for: Self.descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = CartoucheMacBrowser.macs(in: results)
            DispatchQueue.main.async { self?.found = macs }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let refused = CartoucheMacBrowser.isRefused(state)
            DispatchQueue.main.async { self?.refused = refused }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    static var descriptor: NWBrowser.Descriptor {
        .bonjourWithTXTRecord(type: CartoucheBridge.serviceType, domain: nil)
    }

    static func macs(in results: Set<NWBrowser.Result>) -> [CartoucheNearbyMac] {
        results.compactMap { result -> CartoucheNearbyMac? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            var macID: String?
            if case let .bonjour(record) = result.metadata, let id = record["id"], !id.isEmpty {
                macID = id
            }
            return CartoucheNearbyMac(name: name, macID: macID, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether STATE says iOS does not let Cartouche browse: the player
    /// refused it the local network (kDNSServiceErr_PolicyDenied), or the
    /// app does not declare the bridge's Bonjour type (kDNSServiceErr_NoAuth).
    static func isRefused(_ state: NWBrowser.State) -> Bool {
        let error: NWError
        switch state {
        case let .waiting(waiting): error = waiting
        case let .failed(failed): error = failed
        default: return false
        }
        guard case let .dns(code) = error else { return false }
        return code == -65570 || code == -65555
    }

    /// Where the Mac whose ID is MAC_ID is on this network, once Bonjour
    /// finds it within TIMEOUT, in seconds; nil when it does not.
    static func find(_ macID: String, timeout: TimeInterval) async -> NWEndpoint? {
        let browser = NWBrowser(for: descriptor, using: .tcp)
        let queue = DispatchQueue(label: "Cartouche Mac lookup")
        let once = CartoucheBridgeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<NWEndpoint?, Never>) in
            browser.browseResultsChangedHandler = { results, _ in
                guard let mac = CartoucheMacBrowser.macs(in: results).first(where: { $0.macID == macID }), once.claim() else { return }
                browser.cancel()
                continuation.resume(returning: mac.endpoint)
            }
            browser.stateUpdateHandler = { state in
                guard case .failed = state, once.claim() else { return }
                browser.cancel()
                continuation.resume(returning: nil)
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                browser.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}

// MARK: Signing in

enum CartoucheMacStorage {
    /// How long the address the Mac was last reached at has to answer, in
    /// seconds, before Cartouche looks for the Mac on the network.
    static let lastAddressPatience: TimeInterval = 3
    /// How long Bonjour has to find the Mac, in seconds.
    static let lookupPatience: TimeInterval = 4

    /// The iPhone's ID for the Mac of SERVER.
    static func deviceID(of server: CartoucheStorageServer) -> String {
        server.id.uuidString.lowercased()
    }

    /// The paired key SECRET holds, base64; nil for anything else.
    static func pairedKey(_ secret: String) -> Data? {
        guard let key = Data(base64Encoded: secret), key.count == 32 else { return nil }
        return key
    }

    /// Where SERVER's Mac was last reached; nil before it was.
    static func lastEndpoint(of server: CartoucheStorageServer) -> NWEndpoint? {
        let host = server.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(clamping: server.port ?? Int(CartoucheBridge.port))) else {
            return nil
        }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    /// Signs in to the Mac of SERVER with the paired key, SECRET.
    static func connect(_ server: CartoucheStorageServer, secret: String,
                        settings: CartoucheStorageSettings) async throws -> CartoucheRemote {
        guard let key = pairedKey(secret), let macID = server.macID, !macID.isEmpty else {
            throw explained(CartoucheBridgeError(.notPaired), mac: server.name, path: "")
        }
        let device = deviceID(of: server)
        // Where it was last: the Mac rarely moves, and Bonjour does not
        // cross a VPN.
        if let endpoint = lastEndpoint(of: server) {
            do {
                let client = try await CartoucheBridgeClient.connect(endpoint, device: device, key: key, mac: macID,
                                                                    timeout: lastAddressPatience)
                return await remember(client, server: server, settings: settings)
            } catch let error as CartoucheBridgeError where [.notPaired, .protocolError].contains(error.kind) {
                // The Mac itself answered: it forgot this iPhone, or speaks
                // another version of the bridge.
                throw explained(error, mac: server.name, path: "")
            } catch {
                // Not there any more, or another Mac in its place.
            }
        }
        guard let endpoint = await CartoucheMacBrowser.find(macID, timeout: lookupPatience) else {
            // Away from home, or Cartouche Builder closed: offline, which
            // makes no report (CartoucheStorageReach).
            throw CartoucheStorageOffline(server)
        }
        do {
            let client = try await CartoucheBridgeClient.connect(endpoint, device: device, key: key, mac: macID)
            return await remember(client, server: server, settings: settings)
        } catch let error as CartoucheBridgeError {
            throw explained(error, mac: server.name, path: "")
        }
    }

    /// Whether the Mac of SERVER answers from here, at its last address or
    /// found by Bonjour, without signing in: how Cartouche tries it again
    /// once it was offline.
    static func answers(_ server: CartoucheStorageServer) async -> Bool {
        if let address = CartoucheStorageReach.address(of: server),
           await CartoucheStorageReach.knock(host: address.host, port: address.port,
                                             patience: UInt64(lastAddressPatience * 1_000_000_000)) {
            return true
        }
        guard let macID = server.macID, !macID.isEmpty else { return false }
        return await CartoucheMacBrowser.find(macID, timeout: lookupPatience) != nil
    }

    /// CLIENT as SERVER's remote, keeping the address it reached the Mac at
    /// for the next time.
    private static func remember(_ client: CartoucheBridgeClient, server: CartoucheStorageServer,
                                 settings: CartoucheStorageSettings) async -> CartoucheRemote {
        if let address = usable(client.address), address != server.host || client.port != server.port {
            await MainActor.run {
                // As the player has it now, unless they removed it meanwhile.
                guard var moved = settings.server(server.id) else { return }
                moved.host = address
                moved.port = client.port
                settings.save(moved, secret: nil)
            }
        }
        return CartoucheMacRemote(client, mac: server.name)
    }

    /// ADDRESS, unless it is an IPv6 address of the link only, which
    /// cannot be reached again without its interface.
    static func usable(_ address: String?) -> String? {
        guard let address, !address.isEmpty, !address.lowercased().hasPrefix("fe80:") else { return nil }
        return address
    }

    // MARK: Pairing

    /// Pairs this iPhone, named DEVICE_NAME, with the Mac at ENDPOINT, for
    /// SERVER: CODE gets the six digits both screens show, while the player
    /// allows the iPhone on the Mac. Gives SERVER to save, with the Mac's
    /// ID, name and address, and the paired key, base64, its secret.
    /// Cancelling the task closes the connection.
    static func pair(_ server: CartoucheStorageServer, at endpoint: NWEndpoint, name: String, deviceName: String,
                     code: @escaping @Sendable (String) -> Void) async throws -> (server: CartoucheStorageServer, secret: String) {
        let connection: CartoucheBridgeConnection
        do {
            connection = try await CartoucheBridgeConnection.open(endpoint, timeout: 8)
        } catch let error as CartoucheBridgeError {
            throw explained(error, mac: name, path: "")
        }
        defer { connection.close() }
        do {
            let paired = try await withTaskCancellationHandler {
                try await CartoucheBridgeHandshake.pair(connection, device: deviceID(of: server), name: deviceName, code: code)
            } onCancel: {
                connection.close()
            }
            try Task.checkCancellation()
            var made = server
            made.kind = .mac
            made.macID = paired.mac
            if made.name.trimmingCharacters(in: .whitespaces).isEmpty {
                made.name = paired.name.isEmpty ? name : paired.name
            }
            made.host = usable(connection.remoteAddress) ?? ""
            made.port = connection.remotePort
            return (made, paired.key.base64EncodedString())
        } catch let error as CartoucheBridgeError {
            if Task.isCancelled { throw CancellationError() }
            throw explained(error, mac: name, path: "")
        }
    }

    // MARK: What the Mac answers, in the player's words

    /// ERROR, from the Mac called MAC about PATH, as the player reads it;
    /// a report keeps its kind as its domain, "CartoucheBridge.notFound".
    static func explained(_ error: CartoucheBridgeError, mac: String, path: String) -> Error {
        let item = CartoucheStoragePath.name(path)
        let words: String
        switch error.kind {
        case .notFound: words = CartoucheText.storageMacNotFound(item.isEmpty ? mac : item)
        case .denied: words = CartoucheText.storageMacDenied(item.isEmpty ? mac : item)
        case .exists: words = CartoucheText.storageMacExists(item)
        case .closed, .timeout: words = CartoucheText.storageMacLost(mac)
        case .notPaired: words = CartoucheText.storageMacNotPaired(mac)
        case .refused: words = CartoucheText.storageMacRefused(mac)
        case .busy: words = CartoucheText.storageMacBusy(mac)
        case .protocolError: words = CartoucheText.storageMacUpdate
        case .notMac: words = CartoucheText.storageMacOffline(mac)
        case .failed: words = CartoucheText.storageMacFailed(mac, error.message)
        }
        return NSError(domain: "CartoucheBridge." + error.kind.rawValue, code: 0,
                       userInfo: [NSLocalizedDescriptionKey: words])
    }

    /// WORK, with what the Mac called MAC answers about PATH in the
    /// player's words.
    static func bridged<T>(_ mac: String, _ path: String, _ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as CartoucheBridgeError {
            throw explained(error, mac: mac, path: path)
        }
    }
}

// MARK: The Mac's two folders

/// The Mac's Games and Saves folders, signed in to through the bridge,
/// one request at a time.
final class CartoucheMacRemote: CartoucheRemote {
    let client: CartoucheBridgeClient
    /// The Mac's name in Cartouche, for what it answers.
    private let mac: String

    init(_ client: CartoucheBridgeClient, mac: String) {
        self.client = client
        self.mac = mac
    }

    /// The Mac says folder by folder where Cartouche may write (canWrite).
    var isReadOnly: Bool { false }

    func list(_ path: String) async throws -> [CartoucheRemoteItem] {
        let items = try await CartoucheMacStorage.bridged(mac, path) { try await client.list(path) }
        return items.map { CartoucheRemoteItem(name: $0.name, isFolder: $0.folder, size: $0.size, modified: $0.modifiedDate) }
    }

    func open(_ path: String) async throws -> CartoucheByteSource {
        let found = try await CartoucheMacStorage.bridged(mac, path) { try await client.stat(path) }
        if found.folder == true {
            throw CartoucheMacStorage.explained(CartoucheBridgeError(.notFound), mac: mac, path: path)
        }
        let client = self.client
        let mac = self.mac
        return CartoucheReadAhead(size: found.size ?? 0) { offset, count in
            try await CartoucheMacStorage.bridged(mac, path) { try await client.read(path, at: offset, count: count) }
        }
    }

    func create(_ path: String, size: UInt64?) async throws -> CartoucheRemoteUpload {
        let upload = try await CartoucheMacStorage.bridged(mac, path) { try await client.create(path, size: size) }
        return CartoucheMacUpload(client: client, upload: upload, mac: mac, path: path)
    }

    func makeFolder(_ path: String) async throws {
        try await CartoucheMacStorage.bridged(mac, path) { try await client.makeFolder(path) }
    }

    func delete(_ path: String) async throws {
        try await CartoucheMacStorage.bridged(mac, path) { try await client.delete(path) }
    }

    func freeSpace() async throws -> UInt64? {
        try await CartoucheMacStorage.bridged(mac, "") { try await client.freeSpace() }
    }

    func canWrite(_ path: String) async throws -> Bool {
        try await CartoucheMacStorage.bridged(mac, path) { try await client.canWrite(path) }
    }

    func disconnect() async {
        client.close()
    }
}

/// A file being written on the Mac, which names it only once it is
/// finished: until then the file there, if any, stays as it was.
private final class CartoucheMacUpload: CartoucheRemoteUpload {
    private let client: CartoucheBridgeClient
    private let upload: String
    private let mac: String
    private let path: String

    init(client: CartoucheBridgeClient, upload: String, mac: String, path: String) {
        self.client = client
        self.upload = upload
        self.mac = mac
        self.path = path
    }

    func write(_ data: Data) async throws {
        try await CartoucheMacStorage.bridged(mac, path) { try await client.write(data, upload: upload) }
    }

    func finish() async throws {
        try await CartoucheMacStorage.bridged(mac, path) { try await client.finish(upload) }
    }

    func cancel() async {
        await client.cancel(upload)
    }
}
