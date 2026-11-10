//
//  OfflineTests.swift
//  CartoucheStorageTests
//
//  A server out of reach, as a NAS at home is from anywhere else: an
//  address that never answers, or a port of this Mac no server listens on.
//  Cartouche says the server is offline within its patience, a few
//  seconds, instead of waiting for TCP to give up over a minute later, on
//  every protocol; and it tells when the server answers again. No server
//  of servers.sh is needed: these run with or without them.
//

import Foundation
import Network
import XCTest
@testable import CartoucheStorage

final class OfflineTests: XCTestCase {
    /// TEST-NET-1 (RFC 5737), which no network routes: a connection to it
    /// gets no answer, as a NAS's address does away from its network.
    private static let nowhere = "192.0.2.1"
    /// What the error may take past the patience to come back.
    private static let slack: TimeInterval = 4

    private var patience: TimeInterval {
        Double(CartoucheStorageReach.patience) / 1_000_000_000
    }

    /// A server as the player adds it, on HOST.
    private func server(_ kind: CartoucheStorageServer.Kind, host: String, port: Int? = nil) -> CartoucheStorageServer {
        CartoucheStorageServer(kind: kind, name: "NAS", host: host, port: port, username: "joueur",
                               share: kind == .s3 ? "cartouche" : "Partage")
    }

    /// Signs in as CONNECT does, which must throw CartoucheStorageOffline
    /// within LIMIT seconds.
    private func expectOffline(_ what: String, within limit: TimeInterval,
                               _ connect: () async throws -> CartoucheRemote) async {
        let started = Date()
        let error = await thrownError {
            let remote = try await connect()
            await remote.disconnect()
        }
        let waited = Date().timeIntervalSince(started)
        XCTAssertTrue(error is CartoucheStorageOffline, "\(what): \(error.map { String(describing: $0) } ?? "signed in")")
        XCTAssertLessThan(waited, limit, "\(what) took \(Int(waited)) s to say the server is offline")
        print("\(what): \(error?.localizedDescription ?? "signed in"), in \(String(format: "%.1f", waited)) s")
    }

    // MARK: An address that never answers

    func testSaysASharedFolderOutOfReachIsOffline() async {
        await expectOffline("SMB", within: patience + Self.slack) {
            try await CartoucheSMB.connect(self.server(.smb, host: Self.nowhere), password: "mot de passe")
        }
        await expectOffline("SMB's shared folders", within: patience + Self.slack) {
            _ = try await CartoucheSMB.shares(self.server(.smb, host: Self.nowhere), password: "mot de passe")
            throw CartoucheStorageError("listed the shared folders of an address that never answers")
        }
    }

    func testSaysABucketOutOfReachIsOffline() async {
        await expectOffline("S3", within: patience + Self.slack) {
            try await CartoucheS3.connect(self.server(.s3, host: "http://\(Self.nowhere):9000"), secretKey: "clé secrète")
        }
    }

    func testSaysAnFTPServerOutOfReachIsOffline() async {
        await expectOffline("FTP", within: patience + Self.slack) {
            try await CartoucheFTP.connect(self.server(.ftp, host: Self.nowhere), password: "mot de passe")
        }
    }

    func testSaysAnSFTPServerOutOfReachIsOffline() async {
        await expectOffline("SFTP", within: patience + Self.slack) {
            try await CartoucheSFTPServer.connect(self.server(.sftp, host: Self.nowhere), password: "mot de passe",
                                                  knownKey: nil)
        }
    }

    // MARK: A port nobody listens on

    /// Refused at once, as by a NAS whose service is off, or by another
    /// device at its address on another network: offline at once too.
    func testSaysAServerThatRefusesTheConnectionIsOffline() async throws {
        let port = try await closedPort()
        let quickly = Self.slack
        await expectOffline("SMB, refused", within: quickly) {
            try await CartoucheSMB.connect(self.server(.smb, host: "127.0.0.1", port: port), password: "mot de passe")
        }
        await expectOffline("S3, refused", within: quickly) {
            try await CartoucheS3.connect(self.server(.s3, host: "http://127.0.0.1:\(port)"), secretKey: "clé secrète")
        }
        await expectOffline("FTP, refused", within: quickly) {
            try await CartoucheFTP.connect(self.server(.ftp, host: "127.0.0.1", port: port), password: "mot de passe")
        }
        await expectOffline("SFTP, refused", within: quickly) {
            try await CartoucheSFTPServer.connect(self.server(.sftp, host: "127.0.0.1", port: port),
                                                  password: "mot de passe", knownKey: nil)
        }
    }

    // MARK: Knowing when it answers again

    func testKnocksWithoutAWord() async throws {
        let listener = try await Listener.start()
        let answered = await CartoucheStorageReach.knock(host: "127.0.0.1", port: listener.port)
        XCTAssertTrue(answered, "a server of this Mac did not take the connection")
        await listener.stop()

        let started = Date()
        let nobody = await CartoucheStorageReach.knock(host: Self.nowhere, port: 445)
        XCTAssertFalse(nobody, "\(Self.nowhere) took a connection")
        XCTAssertLessThan(Date().timeIntervalSince(started), patience + Self.slack)
    }

    /// As when the iPhone is back home: the server tried again answers, and
    /// Cartouche says it is back, once; gone again, it is offline again.
    @MainActor
    func testTellsWhenAServerAnswersAgain() async throws {
        let suite = "CartoucheStorageTests-" + UUID().uuidString
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let reach = CartoucheStorageReach(settings: CartoucheStorageSettings(defaults: UserDefaults(suiteName: suite) ?? .standard))
        let listener = try await Listener.start()
        let nas = server(.smb, host: "127.0.0.1", port: listener.port)
        var back: [UUID] = []
        let watching = reach.cameBack.sink { back.append($0) }
        defer { watching.cancel() }

        reach.noteOffline(nas)
        XCTAssertTrue(reach.isOffline(nas.id))
        XCTAssertTrue(reach.isSettledOffline(nas.id), "found offline a moment ago, from the same network")

        let answers = await reach.tryAgain(nas)
        XCTAssertTrue(answers)
        XCTAssertFalse(reach.isOffline(nas.id))
        XCTAssertEqual(back, [nas.id])
        // Already back: nothing to tell.
        reach.noteAnswered(nas)
        XCTAssertEqual(back, [nas.id])

        await listener.stop()
        let gone = await reach.tryAgain(nas)
        XCTAssertFalse(gone)
        XCTAssertTrue(reach.isOffline(nas.id))
    }

    /// What every part of Cartouche signs in with keeps what it found.
    @MainActor
    func testKeepsWhatASignInFound() async throws {
        let suite = "CartoucheStorageTests-" + UUID().uuidString
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = CartoucheStorageSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        let port = try await closedPort()
        let nas = server(.smb, host: "127.0.0.1", port: port)
        let error = await thrownError {
            let remote = try await CartoucheStorage.connect(nas, settings: settings)
            await remote.disconnect()
        }
        XCTAssertTrue(error is CartoucheStorageOffline, String(describing: error))
        XCTAssertTrue(CartoucheStorageReach.shared.isOffline(nas.id))
    }

    // MARK: Ports of this Mac

    /// A port of this Mac no server listens on: one a listener had, once
    /// it has let it go.
    private func closedPort() async throws -> Int {
        let listener = try await Listener.start()
        await listener.stop()
        return listener.port
    }
}

/// A server of this Mac, on 127.0.0.1, that takes connections and closes
/// them without a word.
private final class Listener {
    private let listener: NWListener
    let port: Int

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> Listener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.cancel()
        }
        let once = CartoucheOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case let .failed(error):
                    if once.claim() { continuation.resume(throwing: error) }
                case let .waiting(error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw POSIXError(.EADDRNOTAVAIL)
        }
        return Listener(listener: listener, port: Int(port))
    }

    /// Stops taking connections, and waits until the port is let go.
    func stop() async {
        let listener = listener
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { continuation.resume() }
            }
            listener.cancel()
        }
    }
}
