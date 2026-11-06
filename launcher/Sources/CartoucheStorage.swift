//
//  CartoucheStorage.swift
//  Cartouche
//
//  The player's own storage, off the iPhone: the servers they sign in to
//  in Cartouche and the folders of theirs that iOS lets it keep, and the two
//  places Cartouche uses there, kept apart: one for the games' IPAs, one for
//  the backups of their saves.
//
//  Cartouche reaches only what the player signs in to with their own
//  account, or a folder they picked: there is no address to paste, no link
//  to follow, no public bucket. It is where the player keeps their own
//  copies, never a way to download games.
//
//  The servers and places are in Cartouche's preferences; each server's
//  password or secret key is in the keychain, never in the preferences.
//

import Combine
import Foundation
import Security

/// A server or a folder of the player's.
struct CartoucheStorageServer: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// A shared folder of a Mac, a PC or a NAS (SMB 2 and 3).
        case smb
        /// A folder of the iPhone, of iCloud Drive or of a disk, picked once.
        case folder

        var id: String { rawValue }
    }

    var id = UUID()
    var kind: Kind
    /// What the player calls it.
    var name: String
    /// SMB: the server's name or address.
    var host: String = ""
    var port: Int?
    var username: String = ""
    /// SMB: the shared folder.
    var share: String = ""
    /// A picked folder: iOS's bookmark of it.
    var bookmark: Data?
}

/// A folder on one of the player's servers.
struct CartoucheStoragePlace: Codable, Hashable {
    var server: UUID
    /// From the server's root, folders joined by "/"; "" for the root.
    var path: String
}

enum CartoucheStorageRole: String, CaseIterable, Identifiable {
    /// The games' IPAs.
    case games
    /// The backups of the games' saves.
    case saves

    var id: String { rawValue }
}

struct CartoucheStorageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

// MARK: Servers and places

final class CartoucheStorageSettings: ObservableObject {
    static let shared = CartoucheStorageSettings()

    @Published private(set) var servers: [CartoucheStorageServer] = []
    @Published private(set) var places: [CartoucheStorageRole: CartoucheStoragePlace] = [:]

    private let defaults: UserDefaults
    private static let serversKey = "Cartouche.storage.servers"
    private static let keychainService = "Cartouche storage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Self.serversKey),
           let servers = try? decoder.decode([CartoucheStorageServer].self, from: data) {
            self.servers = servers
        }
        for role in CartoucheStorageRole.allCases {
            if let data = defaults.data(forKey: Self.placeKey(role)),
               let place = try? decoder.decode(CartoucheStoragePlace.self, from: data),
               servers.contains(where: { $0.id == place.server }) {
                places[role] = place
            }
        }
    }

    private static func placeKey(_ role: CartoucheStorageRole) -> String {
        "Cartouche.storage.\(role.rawValue)"
    }

    func server(_ id: UUID) -> CartoucheStorageServer? {
        servers.first { $0.id == id }
    }

    func place(_ role: CartoucheStorageRole) -> CartoucheStoragePlace? {
        places[role]
    }

    /// The server of ROLE's place, with that place.
    func location(_ role: CartoucheStorageRole) -> (server: CartoucheStorageServer, path: String)? {
        guard let place = places[role], let server = self.server(place.server) else { return nil }
        return (server, place.path)
    }

    /// Adds SERVER, or changes it; a SECRET of nil keeps the one it has.
    func save(_ server: CartoucheStorageServer, secret: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if let secret {
            Self.storeSecret(secret, for: server.id)
        }
        persist()
    }

    func remove(_ server: CartoucheStorageServer) {
        servers.removeAll { $0.id == server.id }
        for (role, place) in places where place.server == server.id {
            places[role] = nil
        }
        Self.storeSecret(nil, for: server.id)
        persist()
    }

    func setPlace(_ place: CartoucheStoragePlace?, for role: CartoucheStorageRole) {
        places[role] = place
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(servers), forKey: Self.serversKey)
        for role in CartoucheStorageRole.allCases {
            if let place = places[role] {
                defaults.set(try? encoder.encode(place), forKey: Self.placeKey(role))
            } else {
                defaults.removeObject(forKey: Self.placeKey(role))
            }
        }
    }

    // MARK: Keychain

    func secret(of server: CartoucheStorageServer) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: server.id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func storeSecret(_ secret: String?, for id: UUID) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(item as CFDictionary)
        guard let secret, !secret.isEmpty else { return }
        var added = item
        added[kSecValueData as String] = Data(secret.utf8)
        // Readable after the first unlock, so that a backup after a game
        // can reach the server while the iPhone is locked.
        added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(added as CFDictionary, nil)
    }
}

// MARK: Reaching a server

/// A folder or a file on the player's storage.
struct CartoucheRemoteItem: Hashable {
    let name: String
    let isFolder: Bool
    let size: UInt64
    let modified: Date?
}

/// One of the player's servers, signed in to.
protocol CartoucheRemote: AnyObject {
    /// The folders and files in PATH, without hidden ones.
    func list(_ path: String) async throws -> [CartoucheRemoteItem]
    /// The file at PATH, to read.
    func open(_ path: String) async throws -> CartoucheByteSource
    /// A new file at PATH, which replaces the one there, if any, only once
    /// it is finished. SIZE, when known, lets some servers take it in one go.
    func create(_ path: String, size: UInt64?) async throws -> CartoucheRemoteUpload
    func makeFolder(_ path: String) async throws
    func delete(_ path: String) async throws
    /// The room left, when the server says.
    func freeSpace() async throws -> UInt64?
    func disconnect() async
}

/// A file being written to the player's storage.
protocol CartoucheRemoteUpload: CartoucheByteSink {
    /// Puts the file in place.
    func finish() async throws
    /// Gives it up, and removes what was written.
    func cancel() async
}

extension CartoucheRemote {
    /// Makes PATH and the folders above it that are missing.
    func makeFolders(_ path: String) async throws {
        var made = ""
        for part in path.split(separator: "/") {
            made = CartoucheStoragePath.join(made, String(part))
            let parent = CartoucheStoragePath.parent(made)
            let items = try await list(parent)
            if !items.contains(where: { $0.isFolder && $0.name == String(part) }) {
                try await makeFolder(made)
            }
        }
    }

    /// Writes DATA to PATH.
    func write(_ data: Data, to path: String) async throws {
        let upload = try await create(path, size: UInt64(data.count))
        do {
            try await upload.write(data)
            try await upload.finish()
        } catch {
            await upload.cancel()
            throw error
        }
    }

    /// The whole file at PATH, for a small one.
    func read(_ path: String, limit: Int = 16 << 20) async throws -> Data {
        let source = try await open(path)
        guard source.size <= UInt64(limit) else {
            throw CartoucheStorageError(CartoucheText.storageTooLarge(CartoucheStoragePath.name(path)))
        }
        return try await source.read(at: 0, count: Int(source.size))
    }
}

enum CartoucheStorage {
    /// Whether this build reaches shared folders over SMB.
    static var hasSMB: Bool {
        #if canImport(SMBClient)
        return true
        #else
        return false
        #endif
    }

    /// Signs in to SERVER.
    static func connect(_ server: CartoucheStorageServer,
                        settings: CartoucheStorageSettings = .shared) async throws -> CartoucheRemote {
        let secret = settings.secret(of: server) ?? ""
        switch server.kind {
        case .smb:
            #if canImport(SMBClient)
            return try await CartoucheSMB.connect(server, password: secret)
            #else
            throw CartoucheStorageError("SMB is not in this build")
            #endif
        case .folder:
            return try CartoucheFolder(server)
        }
    }
}

enum CartoucheStoragePath {
    /// PARTS joined by "/", without empty ones or slashes at the ends.
    static func join(_ parts: String...) -> String {
        parts.flatMap { $0.split(separator: "/").map(String.init) }.joined(separator: "/")
    }

    static func parent(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    /// TEXT as a file name every server takes: without / \ : * ? " < > |
    /// or control characters, nor a dot or a space at its ends.
    static func fileName(_ text: String) -> String {
        let refused = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = String(text.unicodeScalars.map { refused.contains($0) ? " " : Character($0) })
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Game" : String(cleaned.prefix(120))
    }
}
