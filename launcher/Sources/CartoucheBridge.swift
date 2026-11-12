//
//  CartoucheBridge.swift
//  Cartouche
//
//  The bridge between Cartouche and Cartouche Builder, the player's Mac
//  app: Cartouche finds the Mac on the Wi-Fi (Bonjour, _cartouche._tcp),
//  and reads and writes the two folders the Mac shares with it, its games
//  (the IPAs Cartouche Builder builds, on the Mac or on a NAS it reaches)
//  and the backups of the games' saves. Nothing else on the Mac is reached.
//
//  Pairing, once: the iPhone and the Mac agree on a key with X25519, the
//  iPhone committing to its half before it sees the Mac's, and both show
//  the same six digits, derived from the two halves. The player checks
//  that both screens show them and allows the iPhone on the Mac. A device
//  in between would make each side show other digits, and cannot choose
//  its halves to make them match (one chance in a million). The key both
//  keep never crosses the network. The Mac keeps it before it tells the
//  iPhone it is accepted: Cartouche signs in as soon as it hears so.
//
//  Each connection after that: a fresh X25519 exchange, proved on both
//  sides with the paired key (HMAC-SHA256), gives the connection its own
//  AES-GCM keys, one per direction, with a counter for nonce. Frames are a
//  4-byte big-endian length and their bytes; a message is a 4-byte header
//  length, a JSON header and its body, the bytes of a file read or written.
//
//  This file is shared: Cartouche compiles it with the launcher, Cartouche
//  Builder through the CartoucheCore package (launcher/Package.swift). It
//  needs only Foundation, CryptoKit and Network.
//

import CryptoKit
import Foundation
import Network

public enum CartoucheBridge {
    /// The Bonjour type the Mac advertises.
    public static let serviceType = "_cartouche._tcp"
    /// The port the Mac listens on when it is free (another one otherwise:
    /// Bonjour says which).
    public static let port: UInt16 = 47920
    public static let version = 1
    /// The largest frame either side accepts.
    public static let maxFrame = 24 << 20
    /// The most bytes one read asks for.
    public static let maxRead = 16 << 20
    /// The two folders the Mac shares, at the root of what Cartouche sees.
    public static let gamesFolder = "Games"
    public static let savesFolder = "Saves"
    /// How long the Mac waits for the player to allow a new iPhone.
    public static let pairingTimeout: TimeInterval = 120

    /// Six digits as both screens show them: "482 913".
    public static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}

public struct CartoucheBridgeError: LocalizedError, Equatable {
    public enum Kind: String, Codable {
        case closed, timeout, protocolError, notPaired, refused, busy, notFound, denied, exists, failed, notMac
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String = "") {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message.isEmpty ? "Cartouche Builder: \(kind.rawValue)" : message }
}

// MARK: Bytes

enum CartoucheBridgeBytes {
    static func random(_ count: Int) -> Data {
        var data = Data()
        while data.count < count {
            data.append(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        }
        return data.prefix(count)
    }

    static func uint32(_ value: Int) -> Data {
        let v = UInt32(value)
        return Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    static func uint32(_ data: Data) -> Int {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count == 4 else { return -1 }
        return Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    }

    /// PARTS, each with its length first, so that no two lists of parts give the same bytes.
    static func joined(_ parts: [Data]) -> Data {
        var data = Data()
        for part in parts {
            data.append(uint32(part.count))
            data.append(part)
        }
        return data
    }

    static func text(_ string: String) -> Data { Data(string.utf8) }

    static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
}

// MARK: Transport

/// Frames over a connection, one sent and one received at a time.
public protocol CartoucheBridgeTransport: AnyObject {
    func sendFrame(_ data: Data) async throws
    func receiveFrame() async throws -> Data
    func close()
}

/// Frames over a TCP connection of Network.framework. Its connection and
/// queue never change, and Network.framework's connection can be used from
/// any thread.
public final class CartoucheBridgeConnection: CartoucheBridgeTransport, @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue

    public init(_ connection: NWConnection, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.queue = queue ?? DispatchQueue(label: "Cartouche bridge connection")
    }

    /// TCP with keep-alive, for both sides.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 15
        tcp.keepaliveCount = 4
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }

    /// Connects to ENDPOINT, or fails after TIMEOUT.
    public static func open(_ endpoint: NWEndpoint, timeout: TimeInterval = 8) async throws -> CartoucheBridgeConnection {
        let connection = NWConnection(to: endpoint, using: parameters())
        let opened = CartoucheBridgeConnection(connection)
        try await opened.start(timeout: timeout)
        return opened
    }

    /// Starts the connection and waits until it is ready.
    public func start(timeout: TimeInterval) async throws {
        let once = CartoucheBridgeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case let .failed(error), let .waiting(error):
                    // Waiting: nothing listens at that address, or no route
                    // goes there. The iPhone looks for the Mac elsewhere
                    // rather than wait for the network to change.
                    if once.claim() { continuation.resume(throwing: CartoucheBridgeError(.closed, error.localizedDescription)) }
                    connection.cancel()
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CartoucheBridgeError(.closed)) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                if once.claim() {
                    connection.cancel()
                    continuation.resume(throwing: CartoucheBridgeError(.timeout))
                }
            }
        }
    }

    /// Where the connection reached: "192.168.1.100", without the interface.
    public var remoteAddress: String? {
        guard case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else { return nil }
        var text: String
        switch host {
        case let .ipv4(address): text = "\(address)"
        case let .ipv6(address): text = "\(address)"
        case let .name(name, _): text = name
        @unknown default: return nil
        }
        if let cut = text.firstIndex(of: "%") { text = String(text[..<cut]) }
        return text
    }

    /// The port the connection reached.
    public var remotePort: Int? {
        guard case let .hostPort(_, port)? = connection.currentPath?.remoteEndpoint else { return nil }
        return Int(port.rawValue)
    }

    public func sendFrame(_ data: Data) async throws {
        guard data.count <= CartoucheBridge.maxFrame else { throw CartoucheBridgeError(.protocolError, "frame too large") }
        var frame = CartoucheBridgeBytes.uint32(data.count)
        frame.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: CartoucheBridgeError(.closed, error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receiveFrame() async throws -> Data {
        let header = try await read(exactly: 4)
        let length = CartoucheBridgeBytes.uint32(header)
        guard length >= 0, length <= CartoucheBridge.maxFrame else { throw CartoucheBridgeError(.protocolError, "frame too large") }
        return length == 0 ? Data() : try await read(exactly: length)
    }

    private func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: CartoucheBridgeError(.closed, error.localizedDescription))
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CartoucheBridgeError(.closed))
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// Resumes a continuation once, whichever of its callers comes first.
final class CartoucheBridgeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// One request at a time on a connection: the next waits for the one before.
public actor CartoucheBridgeGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func enter() async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
    }

    public func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

// MARK: Messages

/// What the iPhone asks of the Mac.
public struct CartoucheBridgeRequest: Codable, Equatable {
    public enum Operation: String, Codable {
        case info, list, stat, read, create, write, finish, cancel, makeFolder, delete, free, canWrite
    }

    public var op: Operation
    public var path: String?
    public var offset: UInt64?
    public var count: Int?
    public var size: UInt64?
    public var upload: String?

    public init(_ op: Operation, path: String? = nil, offset: UInt64? = nil, count: Int? = nil, size: UInt64? = nil, upload: String? = nil) {
        self.op = op
        self.path = path
        self.offset = offset
        self.count = count
        self.size = size
        self.upload = upload
    }
}

/// A folder or a file the Mac lists.
public struct CartoucheBridgeItem: Codable, Hashable {
    public var name: String
    public var folder: Bool
    public var size: UInt64
    public var modified: Double?

    public init(name: String, folder: Bool, size: UInt64, modified: Date?) {
        self.name = name
        self.folder = folder
        self.size = size
        self.modified = modified?.timeIntervalSince1970
    }

    public var modifiedDate: Date? { modified.map { Date(timeIntervalSince1970: $0) } }
}

/// The Mac's answer.
public struct CartoucheBridgeResponse: Codable, Equatable {
    public var error: CartoucheBridgeError.Kind?
    public var message: String?
    public var items: [CartoucheBridgeItem]?
    public var size: UInt64?
    public var folder: Bool?
    public var modified: Double?
    public var free: UInt64?
    public var writable: Bool?
    public var upload: String?
    public var name: String?
    public var readOnly: Bool?

    public init() {}

    public static func failure(_ kind: CartoucheBridgeError.Kind, _ message: String) -> CartoucheBridgeResponse {
        var response = CartoucheBridgeResponse()
        response.error = kind
        response.message = message
        return response
    }
}

public enum CartoucheBridgeMessage {
    /// HEADER as JSON, then BODY.
    public static func encode<T: Encodable>(_ header: T, body: Data = Data()) throws -> Data {
        let json = try JSONEncoder().encode(header)
        var data = CartoucheBridgeBytes.uint32(json.count)
        data.append(json)
        data.append(body)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> (T, Data) {
        let length = CartoucheBridgeBytes.uint32(data)
        guard length >= 0, data.count >= 4 + length else { throw CartoucheBridgeError(.protocolError, "short message") }
        let start = data.startIndex
        let json = data.subdata(in: (start + 4)..<(start + 4 + length))
        let body = data.subdata(in: (start + 4 + length)..<data.endIndex)
        do {
            return (try JSONDecoder().decode(type, from: json), body)
        } catch {
            throw CartoucheBridgeError(.protocolError, "unreadable message")
        }
    }
}

// MARK: Handshakes

/// The first message of a connection, in the clear.
struct CartoucheBridgeHello: Codable {
    enum Purpose: String, Codable { case session, pair }
    var v: Int
    var purpose: Purpose
    /// The iPhone's ID for this Mac: the UUID of its storage server.
    var device: String
    var name: String?
    /// session: the iPhone's ephemeral X25519 key.
    var key: Data?
    var nonce: Data?
    /// pair: SHA-256 of the iPhone's key and nonce, revealed after the Mac's.
    var commitment: Data?
}

struct CartoucheBridgeWelcome: Codable {
    var v: Int
    var mac: String
    var name: String
    var key: Data?
    var nonce: Data?
    var proof: Data?
    var error: CartoucheBridgeError.Kind?
    var message: String?
}

struct CartoucheBridgeFinish: Codable {
    var proof: Data?
    var key: Data?
    var nonce: Data?
}

struct CartoucheBridgePaired: Codable {
    var accepted: Bool
    var proof: Data?
}

/// AES-GCM in one direction, the frame's number as its nonce.
struct CartoucheBridgeCipher {
    let key: SymmetricKey
    var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    private func nonce() throws -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        var value = counter
        for index in (4..<12).reversed() {
            bytes[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        return try AES.GCM.Nonce(data: Data(bytes))
    }

    mutating func seal(_ data: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, nonce: try nonce())
        counter += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ data: Data) throws -> Data {
        guard data.count >= 16 else { throw CartoucheBridgeError(.protocolError, "short frame") }
        let tagStart = data.endIndex - 16
        let box = try AES.GCM.SealedBox(nonce: try nonce(), ciphertext: data[data.startIndex..<tagStart], tag: data[tagStart..<data.endIndex])
        let opened: Data
        do {
            opened = try AES.GCM.open(box, using: key)
        } catch {
            throw CartoucheBridgeError(.protocolError, "frame not from the paired device")
        }
        counter += 1
        return opened
    }
}

/// A connection once both sides proved they hold the paired key: messages,
/// encrypted.
public final class CartoucheBridgeSecureChannel {
    public let transport: CartoucheBridgeTransport
    private var sending: CartoucheBridgeCipher
    private var receiving: CartoucheBridgeCipher
    /// The other side: the Mac's ID and name for the iPhone, the device's
    /// ID and name for the Mac.
    public let peer: String
    public let peerName: String

    init(transport: CartoucheBridgeTransport, send: SymmetricKey, receive: SymmetricKey, peer: String, peerName: String) {
        self.transport = transport
        sending = CartoucheBridgeCipher(key: send)
        receiving = CartoucheBridgeCipher(key: receive)
        self.peer = peer
        self.peerName = peerName
    }

    public func send<T: Encodable>(_ header: T, body: Data = Data()) async throws {
        let plain = try CartoucheBridgeMessage.encode(header, body: body)
        let frame = try sending.seal(plain)
        try await transport.sendFrame(frame)
    }

    public func receive<T: Decodable>(_ type: T.Type) async throws -> (T, Data) {
        let frame = try await transport.receiveFrame()
        let plain = try receiving.open(frame)
        return try CartoucheBridgeMessage.decode(type, from: plain)
    }

    public func close() {
        transport.close()
    }
}

/// The handshakes, for both sides.
public enum CartoucheBridgeHandshake {
    static let label = CartoucheBridgeBytes.text("cartouche-bridge-v1")

    static func sendPlain<T: Encodable>(_ value: T, on transport: CartoucheBridgeTransport) async throws {
        try await transport.sendFrame(try JSONEncoder().encode(value))
    }

    static func receivePlain<T: Decodable>(_ type: T.Type, on transport: CartoucheBridgeTransport) async throws -> T {
        let frame = try await transport.receiveFrame()
        do {
            return try JSONDecoder().decode(type, from: frame)
        } catch {
            throw CartoucheBridgeError(.protocolError, "unreadable handshake")
        }
    }

    static func sessionTranscript(device: String, clientKey: Data, clientNonce: Data, mac: String, serverKey: Data, serverNonce: Data) -> Data {
        Data(SHA256.hash(data: CartoucheBridgeBytes.joined([label, CartoucheBridgeBytes.text("session"), CartoucheBridgeBytes.text(device), clientKey, clientNonce,
                                                            CartoucheBridgeBytes.text(mac), serverKey, serverNonce])))
    }

    static func proof(_ role: String, transcript: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: CartoucheBridgeBytes.text(role) + transcript, using: key))
    }

    static func valid(_ proof: Data?, role: String, transcript: Data, key: SymmetricKey) -> Bool {
        guard let proof else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: CartoucheBridgeBytes.text(role) + transcript, using: key)
    }

    /// Each direction's key, from the connection's exchange and the paired key.
    static func directionKeys(shared: SharedSecret, paired: SymmetricKey, transcript: Data) -> (toMac: SymmetricKey, toDevice: SymmetricKey) {
        let both = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: CartoucheBridgeBytes.keyData(paired),
                                                 sharedInfo: label + transcript, outputByteCount: 64)
        let bytes = CartoucheBridgeBytes.keyData(both)
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }

    static func commitment(key: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: CartoucheBridgeBytes.joined([label, CartoucheBridgeBytes.text("commit"), key, nonce])))
    }

    /// The six digits both screens show.
    public static func code(deviceKey: Data, macKey: Data, deviceNonce: Data, macNonce: Data) -> String {
        let digest = Data(SHA256.hash(data: CartoucheBridgeBytes.joined([label, CartoucheBridgeBytes.text("code"), deviceKey, macKey, deviceNonce, macNonce])))
        let value = CartoucheBridgeBytes.uint32(digest) % 1_000_000
        return String(format: "%06ld", value)
    }

    static func pairedKey(shared: SharedSecret, device: String, mac: String, deviceNonce: Data, macNonce: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: deviceNonce + macNonce,
                                       sharedInfo: CartoucheBridgeBytes.joined([label, CartoucheBridgeBytes.text("paired"), CartoucheBridgeBytes.text(device), CartoucheBridgeBytes.text(mac)]),
                                       outputByteCount: 32)
    }

    // MARK: The iPhone's side

    /// Opens a session with the paired KEY; MAC, when known, must be the
    /// Mac's ID.
    public static func client(_ transport: CartoucheBridgeTransport, device: String, key: Data, mac expected: String?) async throws -> CartoucheBridgeSecureChannel {
        let paired = SymmetricKey(data: key)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = CartoucheBridgeBytes.random(32)
        let clientKey = ephemeral.publicKey.rawRepresentation
        try await sendPlain(CartoucheBridgeHello(v: CartoucheBridge.version, purpose: .session, device: device, key: clientKey, nonce: nonce), on: transport)
        let welcome = try await receivePlain(CartoucheBridgeWelcome.self, on: transport)
        // Another Mac at the address this one had says so before anything
        // else, even one that does not know this iPhone.
        if let expected, !expected.isEmpty, welcome.mac != expected { throw CartoucheBridgeError(.notMac, welcome.name) }
        if let error = welcome.error { throw CartoucheBridgeError(error, welcome.message ?? "") }
        guard let serverKey = welcome.key, let serverNonce = welcome.nonce, serverNonce.count == 32,
              let serverPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverKey) else {
            throw CartoucheBridgeError(.protocolError, "incomplete welcome")
        }
        let transcript = sessionTranscript(device: device, clientKey: clientKey, clientNonce: nonce, mac: welcome.mac, serverKey: serverKey, serverNonce: serverNonce)
        guard valid(welcome.proof, role: "mac", transcript: transcript, key: paired) else { throw CartoucheBridgeError(.notPaired) }
        try await sendPlain(CartoucheBridgeFinish(proof: proof("device", transcript: transcript, key: paired)), on: transport)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: serverPublic)
        let keys = directionKeys(shared: shared, paired: paired, transcript: transcript)
        return CartoucheBridgeSecureChannel(transport: transport, send: keys.toMac, receive: keys.toDevice, peer: welcome.mac, peerName: welcome.name)
    }

    /// Asks the Mac to pair: once both halves are known, CODE has the six
    /// digits to show while the player allows the iPhone on the Mac; then
    /// the paired key, the Mac's ID and its name.
    public static func pair(_ transport: CartoucheBridgeTransport, device: String, name: String,
                            code: @escaping (String) -> Void) async throws -> (key: Data, mac: String, name: String) {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = CartoucheBridgeBytes.random(32)
        let deviceKey = ephemeral.publicKey.rawRepresentation
        try await sendPlain(CartoucheBridgeHello(v: CartoucheBridge.version, purpose: .pair, device: device, name: name,
                                                 commitment: commitment(key: deviceKey, nonce: nonce)), on: transport)
        let welcome = try await receivePlain(CartoucheBridgeWelcome.self, on: transport)
        if let error = welcome.error { throw CartoucheBridgeError(error, welcome.message ?? "") }
        guard let macKey = welcome.key, let macNonce = welcome.nonce, macNonce.count == 32,
              let macPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey) else {
            throw CartoucheBridgeError(.protocolError, "incomplete welcome")
        }
        try await sendPlain(CartoucheBridgeFinish(key: deviceKey, nonce: nonce), on: transport)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: macPublic)
        let key = pairedKey(shared: shared, device: device, mac: welcome.mac, deviceNonce: nonce, macNonce: macNonce)
        code(self.code(deviceKey: deviceKey, macKey: macKey, deviceNonce: nonce, macNonce: macNonce))
        let answer = try await receivePlain(CartoucheBridgePaired.self, on: transport)
        guard answer.accepted else { throw CartoucheBridgeError(.refused) }
        guard let proof = answer.proof, HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: label + CartoucheBridgeBytes.text("accepted"), using: key) else {
            throw CartoucheBridgeError(.protocolError, "the Mac does not hold the same key")
        }
        return (CartoucheBridgeBytes.keyData(key), welcome.mac, welcome.name)
    }

    // MARK: The Mac's side

    /// What the Mac does with a new connection: a session of a paired
    /// device, or a pairing, the device kept already.
    public enum Opening {
        case session(CartoucheBridgeSecureChannel)
        case paired(device: String, name: String)
        case refused
    }

    /// Answers the first messages of a connection. KEY_OF gives a paired
    /// device's key; ALLOW asks the player, with the device's name and the
    /// code, whether a new one may pair (nil: no pairing now); KEEP keeps
    /// the device the player allowed, its ID, its name and its paired key,
    /// before the iPhone hears it is accepted: Cartouche signs in at once,
    /// and a Mac that did not know it yet would answer that it is not
    /// paired.
    public static func server(_ transport: CartoucheBridgeTransport, mac: String, name: String,
                              keyOf: (String) -> Data?,
                              allow: ((String, String) async -> Bool)?,
                              keep: (_ device: String, _ name: String, _ key: Data) async -> Void) async throws -> Opening {
        let hello = try await receivePlain(CartoucheBridgeHello.self, on: transport)
        guard hello.v == CartoucheBridge.version else {
            try await sendPlain(CartoucheBridgeWelcome(v: CartoucheBridge.version, mac: mac, name: name, error: .protocolError, message: "version \(hello.v)"), on: transport)
            return .refused
        }
        switch hello.purpose {
        case .session:
            guard let stored = keyOf(hello.device) else {
                try await sendPlain(CartoucheBridgeWelcome(v: CartoucheBridge.version, mac: mac, name: name, error: .notPaired), on: transport)
                return .refused
            }
            guard let clientKey = hello.key, let clientNonce = hello.nonce, clientNonce.count == 32,
                  let clientPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientKey) else {
                throw CartoucheBridgeError(.protocolError, "incomplete hello")
            }
            let paired = SymmetricKey(data: stored)
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let nonce = CartoucheBridgeBytes.random(32)
            let serverKey = ephemeral.publicKey.rawRepresentation
            let transcript = sessionTranscript(device: hello.device, clientKey: clientKey, clientNonce: clientNonce, mac: mac, serverKey: serverKey, serverNonce: nonce)
            try await sendPlain(CartoucheBridgeWelcome(v: CartoucheBridge.version, mac: mac, name: name, key: serverKey, nonce: nonce,
                                                       proof: proof("mac", transcript: transcript, key: paired)), on: transport)
            let finish = try await receivePlain(CartoucheBridgeFinish.self, on: transport)
            guard valid(finish.proof, role: "device", transcript: transcript, key: paired) else { return .refused }
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: clientPublic)
            let keys = directionKeys(shared: shared, paired: paired, transcript: transcript)
            return .session(CartoucheBridgeSecureChannel(transport: transport, send: keys.toDevice, receive: keys.toMac, peer: hello.device, peerName: hello.name ?? ""))
        case .pair:
            guard let allow else {
                try await sendPlain(CartoucheBridgeWelcome(v: CartoucheBridge.version, mac: mac, name: name, error: .busy), on: transport)
                return .refused
            }
            guard let commitment = hello.commitment, commitment.count == 32 else { throw CartoucheBridgeError(.protocolError, "no commitment") }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let nonce = CartoucheBridgeBytes.random(32)
            let macKey = ephemeral.publicKey.rawRepresentation
            try await sendPlain(CartoucheBridgeWelcome(v: CartoucheBridge.version, mac: mac, name: name, key: macKey, nonce: nonce), on: transport)
            let reveal = try await receivePlain(CartoucheBridgeFinish.self, on: transport)
            guard let deviceKey = reveal.key, let deviceNonce = reveal.nonce, deviceNonce.count == 32,
                  CartoucheBridgeHandshake.commitment(key: deviceKey, nonce: deviceNonce) == commitment,
                  let devicePublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: deviceKey) else {
                try? await sendPlain(CartoucheBridgePaired(accepted: false), on: transport)
                return .refused
            }
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: devicePublic)
            let key = pairedKey(shared: shared, device: hello.device, mac: mac, deviceNonce: deviceNonce, macNonce: nonce)
            let digits = code(deviceKey: deviceKey, macKey: macKey, deviceNonce: deviceNonce, macNonce: nonce)
            let trimmed = (hello.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceName = trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(60))
            guard await allow(deviceName, digits) else {
                try? await sendPlain(CartoucheBridgePaired(accepted: false), on: transport)
                return .refused
            }
            // Kept first: the iPhone opens its first session as soon as it
            // reads the answer.
            await keep(hello.device, deviceName, CartoucheBridgeBytes.keyData(key))
            let accepted = Data(HMAC<SHA256>.authenticationCode(for: label + CartoucheBridgeBytes.text("accepted"), using: key))
            try await sendPlain(CartoucheBridgePaired(accepted: true, proof: accepted), on: transport)
            return .paired(device: hello.device, name: deviceName)
        }
    }
}

// MARK: The iPhone's client

/// The Mac's two folders, signed in to: what Cartouche asks of them, one
/// request at a time.
public final class CartoucheBridgeClient {
    public let channel: CartoucheBridgeSecureChannel
    private let gate = CartoucheBridgeGate()
    /// The address and the port the connection reached, for the next time.
    public let address: String?
    public let port: Int?

    public init(channel: CartoucheBridgeSecureChannel, address: String?, port: Int? = nil) {
        self.channel = channel
        self.address = address
        self.port = port
    }

    public var macID: String { channel.peer }
    public var macName: String { channel.peerName }

    /// Connects to the Mac at ENDPOINT with the paired KEY.
    public static func connect(_ endpoint: NWEndpoint, device: String, key: Data, mac: String?, timeout: TimeInterval = 8) async throws -> CartoucheBridgeClient {
        let connection = try await CartoucheBridgeConnection.open(endpoint, timeout: timeout)
        do {
            let channel = try await CartoucheBridgeHandshake.client(connection, device: device, key: key, mac: mac)
            return CartoucheBridgeClient(channel: channel, address: connection.remoteAddress, port: connection.remotePort)
        } catch {
            connection.close()
            throw error
        }
    }

    /// Sends REQUEST with BODY and waits for the answer and its body. The
    /// gate is left once, whatever the answer: the next request goes only
    /// once this one is answered.
    public func call(_ request: CartoucheBridgeRequest, body: Data = Data()) async throws -> (CartoucheBridgeResponse, Data) {
        await gate.enter()
        let answer: (CartoucheBridgeResponse, Data)
        do {
            try await channel.send(request, body: body)
            answer = try await channel.receive(CartoucheBridgeResponse.self)
        } catch {
            await gate.leave()
            throw error
        }
        await gate.leave()
        if let error = answer.0.error { throw CartoucheBridgeError(error, answer.0.message ?? "") }
        return answer
    }

    public func info() async throws -> CartoucheBridgeResponse {
        try await call(CartoucheBridgeRequest(.info)).0
    }

    public func list(_ path: String) async throws -> [CartoucheBridgeItem] {
        try await call(CartoucheBridgeRequest(.list, path: path)).0.items ?? []
    }

    public func stat(_ path: String) async throws -> CartoucheBridgeResponse {
        try await call(CartoucheBridgeRequest(.stat, path: path)).0
    }

    public func read(_ path: String, at offset: UInt64, count: Int) async throws -> Data {
        var data = Data()
        var position = offset
        var left = count
        while left > 0 {
            let asked = min(left, CartoucheBridge.maxRead)
            let (_, body) = try await call(CartoucheBridgeRequest(.read, path: path, offset: position, count: asked))
            data.append(body)
            if body.count < asked { break }
            position += UInt64(body.count)
            left -= body.count
        }
        return data
    }

    public func create(_ path: String, size: UInt64?) async throws -> String {
        guard let upload = try await call(CartoucheBridgeRequest(.create, path: path, size: size)).0.upload else {
            throw CartoucheBridgeError(.protocolError, "no upload")
        }
        return upload
    }

    public func write(_ data: Data, upload: String) async throws {
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(start + CartoucheBridge.maxRead, data.endIndex)
            _ = try await call(CartoucheBridgeRequest(.write, upload: upload), body: data.subdata(in: start..<end))
            start = end
        }
    }

    public func finish(_ upload: String) async throws {
        _ = try await call(CartoucheBridgeRequest(.finish, upload: upload))
    }

    public func cancel(_ upload: String) async {
        _ = try? await call(CartoucheBridgeRequest(.cancel, upload: upload))
    }

    public func makeFolder(_ path: String) async throws {
        _ = try await call(CartoucheBridgeRequest(.makeFolder, path: path))
    }

    public func delete(_ path: String) async throws {
        _ = try await call(CartoucheBridgeRequest(.delete, path: path))
    }

    public func freeSpace() async throws -> UInt64? {
        try await call(CartoucheBridgeRequest(.free)).0.free
    }

    public func canWrite(_ path: String) async throws -> Bool {
        try await call(CartoucheBridgeRequest(.canWrite, path: path)).0.writable ?? false
    }

    public func close() {
        channel.close()
    }
}

// MARK: Paths

public enum CartoucheBridgePath {
    /// PATH's parts, checked: none empty, "." or "..", no NUL, no "/".
    public static func parts(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in parts where part == "." || part == ".." || part.contains("\0") || part.contains("\\") {
            return nil
        }
        return parts
    }
}
