//
//  CartoucheStorageReach.swift
//  Cartouche
//
//  Whether the player's servers answer from where the iPhone is. A NAS at
//  home is out of reach away from home, or off the player's VPN: the first
//  connection to it gets no answer at all, and nothing fails until TCP
//  gives up, over a minute later. Cartouche gives that connection a few
//  seconds (patience), says the server is offline, and tries it again by
//  itself, a moment after each change of the iPhone's network and every
//  minute while Cartouche is in front. Meanwhile the games installed play
//  as ever, the games folder shows its last list, and the copies of the
//  saves wait; once the server answers again, the games folder is read
//  again and the saves waiting are copied (CartoucheGamesView).
//
//  Being offline is not a problem: no report is made of it, and nothing is
//  counted as an error.
//

import Combine
import Foundation
import Network

/// The server took no connection, within the patience or at all: it is
/// out of reach from the network the iPhone is on.
struct CartoucheStorageOffline: LocalizedError {
    /// The server's name in Cartouche, or its address before it has one.
    let name: String

    init(_ server: CartoucheStorageServer) {
        let name = server.name.trimmingCharacters(in: .whitespaces)
        self.name = name.isEmpty ? server.host.trimmingCharacters(in: .whitespaces) : name
    }

    var errorDescription: String? { CartoucheText.storageOffline(name) }
}

@MainActor
final class CartoucheStorageReach: ObservableObject {
    static let shared = CartoucheStorageReach()

    /// How long the first connection to a server waits to be taken, in
    /// nanoseconds. A server of the player's network takes it in a few
    /// milliseconds, one through their VPN in well under a second.
    nonisolated static var patience: UInt64 { 6_000_000_000 }
    /// How long a server found offline stays so, from the same network, for
    /// what Cartouche does by itself each time it comes back: the copies
    /// of the saves and the reading of the games folder leave it alone
    /// instead of waiting for it again.
    nonisolated static var settled: TimeInterval { 60 }
    /// How often the servers in use that are offline are tried again while
    /// Cartouche is in front, in nanoseconds.
    nonisolated static var recheck: UInt64 { 60_000_000_000 }
    /// How long the network stays the same before Cartouche tries the
    /// servers in use again, in nanoseconds: the iPhone goes through a few
    /// networks in a second as it changes from one to another.
    nonisolated static var networkSettles: UInt64 { 2_000_000_000 }

    /// A server that does not answer from here.
    struct Absence: Equatable {
        /// When it stopped answering.
        let since: Date
        /// When it was last tried.
        var tried: Date
        /// The network the iPhone was on then.
        var network: String
    }

    /// The servers that do not answer from here, by ID.
    @Published private(set) var absences: [UUID: Absence] = [:]
    /// The servers being tried again.
    @Published private(set) var trying: Set<UUID> = []
    /// Each server that answers again, as soon as it does.
    let cameBack = PassthroughSubject<UUID, Never>()

    private let settings: CartoucheStorageSettings
    private var monitor: NWPathMonitor?
    /// The iPhone's network as Network.framework describes it: its
    /// interfaces and what they reach.
    private var network = ""
    private var networkChange: Task<Void, Never>?
    private var rechecks: Task<Void, Never>?
    private var isInFront = true

    init(settings: CartoucheStorageSettings = .shared) {
        self.settings = settings
    }

    /// Whether SERVER does not answer from here, as Cartouche last found.
    func isOffline(_ server: UUID) -> Bool {
        absences[server] != nil
    }

    /// Whether SERVER was found offline a moment ago, from the network the
    /// iPhone is still on.
    func isSettledOffline(_ server: UUID) -> Bool {
        guard let absence = absences[server] else { return false }
        return absence.network == network && Date().timeIntervalSince(absence.tried) < Self.settled
    }

    /// The servers of the games folder and of the saves folder, once each:
    /// not a folder of the iPhone, which is always there.
    var serversInUse: [CartoucheStorageServer] {
        var seen = Set<UUID>()
        return CartoucheStorageRole.allCases.compactMap { settings.location($0)?.server }
            .filter { $0.kind != .folder && seen.insert($0.id).inserted }
    }

    /// The servers in use that do not answer from here.
    var offlineInUse: [CartoucheStorageServer] {
        serversInUse.filter { isOffline($0.id) }
    }

    // MARK: What the connections found

    /// SERVER took no connection.
    func noteOffline(_ server: CartoucheStorageServer) {
        let now = Date()
        if var absence = absences[server.id] {
            absence.tried = now
            absence.network = network
            absences[server.id] = absence
        } else {
            absences[server.id] = Absence(since: now, tried: now, network: network)
            CartoucheReports.note("Storage: " + server.name + " is offline from this network")
        }
        startRechecks()
    }

    /// SERVER took a connection: if it was offline, it is back.
    func noteAnswered(_ server: CartoucheStorageServer) {
        guard absences.removeValue(forKey: server.id) != nil else { return }
        CartoucheReports.note("Storage: " + server.name + " answers again")
        cameBack.send(server.id)
    }

    // MARK: Trying again

    /// Watches the iPhone's network, from the first call on: each time it
    /// changes, the servers in use are tried again once it has settled.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let network = String(describing: path)
            Task { @MainActor in self?.networkChanged(to: network) }
        }
        monitor.start(queue: DispatchQueue(label: "Cartouche network"))
    }

    /// Whether Cartouche is in front: the servers offline are tried again
    /// every minute only then.
    func setInFront(_ inFront: Bool) {
        isInFront = inFront
    }

    /// Tries SERVER again, as the player asks or as the network changes:
    /// whether it takes a connection now, which is kept.
    @discardableResult
    func tryAgain(_ server: CartoucheStorageServer) async -> Bool {
        guard !trying.contains(server.id) else { return !isOffline(server.id) }
        trying.insert(server.id)
        let answers = await Self.answers(server)
        trying.remove(server.id)
        if answers {
            noteAnswered(server)
        } else {
            noteOffline(server)
        }
        return answers
    }

    /// Tries the servers in use again, all at once.
    func tryInUse() async {
        let servers = serversInUse
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { _ = await self.tryAgain(server) }
            }
        }
    }

    private func networkChanged(to network: String) {
        guard network != self.network else { return }
        let first = self.network.isEmpty
        self.network = network
        if first {
            // What was found before the network was known was found on it.
            for (id, var absence) in absences where absence.network.isEmpty {
                absence.network = network
                absences[id] = absence
            }
            return
        }
        networkChange?.cancel()
        networkChange = Task {
            try? await Task.sleep(nanoseconds: CartoucheStorageReach.networkSettles)
            guard !Task.isCancelled else { return }
            await tryInUse()
        }
    }

    /// Tries the servers in use that are offline again every minute, while
    /// Cartouche is in front, until none is.
    private func startRechecks() {
        guard rechecks == nil else { return }
        rechecks = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: CartoucheStorageReach.recheck)
                guard let self else { return }
                let offline = self.offlineInUse
                if offline.isEmpty {
                    self.rechecks = nil
                    return
                }
                guard self.isInFront else { continue }
                for server in offline {
                    await self.tryAgain(server)
                }
            }
        }
    }

    // MARK: Knocking

    /// Whether SERVER takes a connection within the patience, on the port
    /// Cartouche reaches it on: a connection made, then closed at once,
    /// without a word to the server. A folder of the iPhone is always
    /// there, and only the request itself tells for a server reached
    /// through a proxy.
    nonisolated static func answers(_ server: CartoucheStorageServer) async -> Bool {
        guard let address = address(of: server) else { return true }
        if server.kind == .s3 && usesProxy { return true }
        return await knock(host: address.host, port: address.port)
    }

    /// Where Cartouche connects to reach SERVER; nil for a folder of the
    /// iPhone, and for an S3 address Cartouche cannot use.
    nonisolated static func address(of server: CartoucheStorageServer) -> (host: String, port: Int)? {
        let host = server.host.trimmingCharacters(in: .whitespaces)
        switch server.kind {
        case .folder:
            return nil
        case .smb:
            return (host, server.port ?? 445)
        case .ftp:
            return (host, server.port ?? 21)
        case .sftp:
            return (host, server.port ?? 22)
        case .s3:
            guard let bucket = try? CartoucheS3.target(of: server) else { return nil }
            let endpoint = bucket.endpoint
            return (bucket.isVirtualHosted ? bucket.name + "." + endpoint.host : endpoint.host,
                    endpoint.port ?? (endpoint.secure ? 443 : 80))
        }
    }

    /// Whether HOST takes a TCP connection on PORT within PATIENCE, in
    /// nanoseconds; the connection is closed at once.
    nonisolated static func knock(host: String, port: Int, patience: UInt64 = CartoucheStorageReach.patience) async -> Bool {
        guard !host.isEmpty, (1 ... 65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "Cartouche knock")
        let once = CartoucheOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.stateUpdateHandler = { state in
                let answered: Bool
                switch state {
                case .ready: answered = true
                // Waiting: no network that reaches it, or refused.
                case .waiting, .failed, .cancelled: answered = false
                default: return
                }
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: answered)
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: patience))) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    /// Whether this iPhone sends HTTP through a proxy, as a company's Wi-Fi
    /// can ask: a server it reaches through the proxy may take no direct
    /// connection.
    nonisolated static var usesProxy: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        return ["HTTPEnable", "HTTPSEnable", "ProxyAutoConfigEnable"].contains { (settings[$0] as? NSNumber)?.boolValue == true }
    }

    #if CARTOUCHE_GALLERY
    /// SERVERS offline, for the launcher's gallery (launcher/Gallery).
    func showOfflineForGallery(_ servers: [UUID]) {
        let since = Date().addingTimeInterval(-20 * 60)
        for id in servers {
            absences[id] = Absence(since: since, tried: Date(), network: network)
        }
    }
    #endif
}

/// Something that happens once, from whichever thread comes first.
final class CartoucheOnce: @unchecked Sendable {
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
