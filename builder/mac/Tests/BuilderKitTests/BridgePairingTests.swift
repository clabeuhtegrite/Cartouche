//
//  BridgePairingTests.swift
//  BuilderKitTests
//
//  An iPhone pairing with the Mac (BridgeServer.swift), over a connection
//  in memory: the player allows it, and the Mac has it in its list before
//  it tells the iPhone it is paired, since Cartouche opens its first
//  session as soon as it hears so; that session then reaches the two
//  folders. The bridge's handshake itself is tested with Cartouche's
//  (launcher/Tests/CartoucheCoreTests/CartoucheBridgeTests.swift).
//

import CartoucheCore
import Foundation
import XCTest
@testable import BuilderKit

/// One end of a connection in memory; frames go to the other end, and
/// SENT sees each one this end sends, as it goes.
private final class Wire: CartoucheBridgeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    private var closed = false
    weak var other: Wire?
    var sent: ((Data) -> Void)?

    static func pair() -> (Wire, Wire) {
        let a = Wire(), b = Wire()
        a.other = b
        b.other = a
        return (a, b)
    }

    func sendFrame(_ data: Data) async throws {
        guard let other else { throw CartoucheBridgeError(.closed) }
        sent?(data)
        other.deliver(data)
    }

    private func deliver(_ data: Data) {
        lock.lock()
        if let waiting {
            self.waiting = nil
            lock.unlock()
            waiting.resume(returning: data)
        } else {
            frames.append(data)
            lock.unlock()
        }
    }

    func receiveFrame() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !frames.isEmpty {
                let frame = frames.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: CartoucheBridgeError(.closed))
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        shut()
        other?.shut()
    }

    private func shut() {
        lock.lock()
        closed = true
        let waiting = self.waiting
        self.waiting = nil
        lock.unlock()
        waiting?.resume(throwing: CartoucheBridgeError(.closed))
    }
}

/// The player at the Mac, who allows every iPhone and notes their names.
@MainActor
private final class Player: BridgeServerDelegate {
    var asked: [String] = []

    func bridgeServer(_ server: BridgeServer, allowPairing name: String, code: String) async -> Bool {
        asked.append(name)
        return true
    }

    func bridgeServerChanged(_ server: BridgeServer) {}
}

/// What the Mac's list held each time it said an iPhone was paired, from
/// the pairing's task.
private final class Listed: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool] = []

    func add(_ listed: Bool) {
        lock.lock()
        answers.append(listed)
        lock.unlock()
    }

    var all: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return answers
    }
}

final class BridgePairingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        for name in ["Jeux", "Saves"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    func testAnIPhoneIsInTheListBeforeItHearsItIsPaired() async throws {
        let server = BridgeServer(devices: BridgeDevices(url: folder.appendingPathComponent("bridge.json")), name: "Mac de test")
        server.roots = BridgeRoots(games: folder.appendingPathComponent("Jeux", isDirectory: true),
                                   saves: folder.appendingPathComponent("Saves", isDirectory: true))
        let player = Player()
        server.delegate = player
        let device = UUID().uuidString
        let listed = Listed()
        let (phone, mac) = Wire.pair()
        mac.sent = { @Sendable frame in
            // The Mac's answer to the pairing, in the clear: {"accepted": true, "proof": …}.
            guard let answer = try? JSONSerialization.jsonObject(with: frame) as? [String: Any], answer["accepted"] as? Bool == true else { return }
            listed.add(server.devices.key(of: device) != nil)
        }
        let pairing = Task { await server.open(mac) }
        let paired = try await CartoucheBridgeHandshake.pair(phone, device: device, name: "iPhone de test") { _ in }
        XCTAssertEqual(listed.all, [true], "the iPhone was in the Mac's list when the Mac said it was paired")
        XCTAssertEqual(server.devices.key(of: device), paired.key)
        XCTAssertEqual(server.devices.all.map(\.name), ["iPhone de test"])
        XCTAssertEqual(player.asked, ["iPhone de test"])
        XCTAssertEqual(paired.mac, server.devices.macID)

        // Its first session, at once, as Cartouche opens it to take the
        // Mac's folders for the games and the saves.
        let (phoneSide, macSide) = Wire.pair()
        let serving = Task { await server.open(macSide) }
        let channel = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: paired.key, mac: paired.mac)
        let client = CartoucheBridgeClient(channel: channel, address: nil)
        let top = try await client.list("")
        XCTAssertEqual(top.map(\.name), [CartoucheBridge.gamesFolder, CartoucheBridge.savesFolder])
        client.close()
        await serving.value
        await pairing.value
    }
}
