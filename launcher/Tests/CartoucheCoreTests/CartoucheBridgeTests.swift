//
//  CartoucheBridgeTests.swift
//  CartoucheCoreTests
//
//  The bridge between Cartouche and Cartouche Builder
//  (Sources/CartoucheBridge.swift), over a connection in memory: pairing
//  with the code both sides show, a session with the paired key, the
//  messages it carries, and what a device in between, or one that never
//  paired, gets.
//

import CryptoKit
import Foundation
import XCTest
@testable import CartoucheCore

/// One end of a connection in memory; frames go to the other end.
final class MemoryTransport: CartoucheBridgeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    private var closed = false
    weak var other: MemoryTransport?
    /// What the other end receives instead of what is sent, for a device in between.
    var tamper: ((Data) -> Data)?

    static func pair() -> (MemoryTransport, MemoryTransport) {
        let a = MemoryTransport(), b = MemoryTransport()
        a.other = b
        b.other = a
        return (a, b)
    }

    func sendFrame(_ data: Data) async throws {
        guard let other else { throw CartoucheBridgeError(.closed) }
        other.deliver(tamper?(data) ?? data)
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

    /// The frames that arrived and wait to be received.
    var queued: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    func close() {
        lock.lock()
        closed = true
        let waiting = self.waiting
        self.waiting = nil
        lock.unlock()
        waiting?.resume(throwing: CartoucheBridgeError(.closed))
        other?.closeFromOther()
    }

    private func closeFromOther() {
        lock.lock()
        let waiting = self.waiting
        self.waiting = nil
        closed = true
        lock.unlock()
        waiting?.resume(throwing: CartoucheBridgeError(.closed))
    }
}

final class CartoucheBridgeTests: XCTestCase {
    let mac = UUID().uuidString
    let device = UUID().uuidString

    /// Pairs DEVICE with the Mac, the player answering ALLOW: the iPhone's
    /// result, the Mac's, and the codes each showed.
    func pairing(allow: Bool) async throws -> (phone: Result<(key: Data, mac: String, name: String), Error>, mac: CartoucheBridgeHandshake.Opening, shown: [String]) {
        let (phone, macSide) = MemoryTransport.pair()
        let codes = CodeBox()
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Ad's Mac", keyOf: { _ in nil }) { name, code in
            XCTAssertEqual(name, "Ad's iPhone")
            codes.add(code)
            return allow
        }
        let result: Result<(key: Data, mac: String, name: String), Error>
        do {
            result = .success(try await CartoucheBridgeHandshake.pair(phone, device: device, name: "Ad's iPhone") { codes.add($0) })
        } catch {
            result = .failure(error)
        }
        return (result, try await opening, codes.all)
    }

    func testPairingThenASession() async throws {
        let paired = try await pairing(allow: true)
        let phone = try paired.phone.get()
        guard case let .paired(device, name, key) = paired.mac else { return XCTFail("not paired: \(paired.mac)") }
        XCTAssertEqual(device, self.device)
        XCTAssertEqual(name, "Ad's iPhone")
        XCTAssertEqual(key, phone.key)
        XCTAssertEqual(phone.mac, mac)
        XCTAssertEqual(phone.name, "Ad's Mac")
        XCTAssertEqual(paired.shown.count, 2)
        XCTAssertEqual(paired.shown[0], paired.shown[1])
        XCTAssertEqual(paired.shown[0].count, 6)
        XCTAssertEqual(CartoucheBridge.spaced("482913"), "482 913")

        // A session with that key, and a request and its answer.
        let (phoneSide, macSide) = MemoryTransport.pair()
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Ad's Mac", keyOf: { $0 == self.device ? key : nil }, allow: nil)
        let client = try await CartoucheBridgeHandshake.client(phoneSide, device: self.device, key: phone.key, mac: mac)
        guard case let .session(server) = try await opening else { return XCTFail("no session") }
        XCTAssertEqual(server.peer, self.device)
        let body = Data((0..<100_000).map { UInt8($0 % 251) })
        let answering = Task { () throws -> (CartoucheBridgeRequest, Data) in
            let (request, data) = try await server.receive(CartoucheBridgeRequest.self)
            var response = CartoucheBridgeResponse()
            response.size = 123
            try await server.send(response, body: body)
            return (request, data)
        }
        try await client.send(CartoucheBridgeRequest(.read, path: "Games/Game.ipa", offset: 8, count: 100_000))
        let (response, data) = try await client.receive(CartoucheBridgeResponse.self)
        let (request, sent) = try await answering.value
        XCTAssertEqual(request, CartoucheBridgeRequest(.read, path: "Games/Game.ipa", offset: 8, count: 100_000))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(response.size, 123)
        XCTAssertEqual(data, body)
    }

    func testRefusedOnTheMac() async throws {
        let paired = try await pairing(allow: false)
        XCTAssertThrowsError(try paired.phone.get()) { error in
            XCTAssertEqual((error as? CartoucheBridgeError)?.kind, .refused)
        }
        guard case .refused = paired.mac else { return XCTFail("paired anyway") }
    }

    func testAnUnpairedDeviceGetsNoSession() async throws {
        let (phoneSide, macSide) = MemoryTransport.pair()
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Mac", keyOf: { _ in nil }, allow: nil)
        do {
            _ = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: Data(repeating: 1, count: 32), mac: nil)
            XCTFail("a session without pairing")
        } catch {
            XCTAssertEqual((error as? CartoucheBridgeError)?.kind, .notPaired)
        }
        guard case .refused = try await opening else { return XCTFail("a session without pairing") }
    }

    func testAnotherKeyGetsNoSession() async throws {
        let (phoneSide, macSide) = MemoryTransport.pair()
        let stored = Data(repeating: 7, count: 32)
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Mac", keyOf: { _ in stored }, allow: nil)
        do {
            _ = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: Data(repeating: 8, count: 32), mac: mac)
            XCTFail("a session with another key")
        } catch {
            XCTAssertEqual((error as? CartoucheBridgeError)?.kind, .notPaired)
        }
        macSide.close()
        _ = try? await opening
    }

    func testTheWrongMacIsRefused() async throws {
        let (phoneSide, macSide) = MemoryTransport.pair()
        let key = Data(repeating: 3, count: 32)
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: "another", name: "Other Mac", keyOf: { _ in key }, allow: nil)
        do {
            _ = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: key, mac: mac)
            XCTFail("another Mac")
        } catch {
            XCTAssertEqual((error as? CartoucheBridgeError)?.kind, .notMac)
        }
        phoneSide.close()
        _ = try? await opening
    }

    func testAnotherMacThatDoesNotKnowThisIPhoneSaysItIsAnotherMac() async throws {
        // At the address the paired Mac had: the iPhone looks for its Mac
        // on the network instead of asking to pair again.
        let (phoneSide, macSide) = MemoryTransport.pair()
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: "another", name: "Other Mac", keyOf: { _ in nil }, allow: nil)
        do {
            _ = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: Data(repeating: 3, count: 32), mac: mac)
            XCTFail("another Mac")
        } catch {
            XCTAssertEqual((error as? CartoucheBridgeError)?.kind, .notMac)
        }
        guard case .refused = try await opening else { return XCTFail("a session on another Mac") }
    }

    func testAFrameChangedOnTheWayIsRefused() async throws {
        let key = Data(repeating: 5, count: 32)
        let (phoneSide, macSide) = MemoryTransport.pair()
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Mac", keyOf: { _ in key }, allow: nil)
        let client = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: key, mac: mac)
        guard case let .session(server) = try await opening else { return XCTFail("no session") }
        phoneSide.tamper = { frame in
            var changed = frame
            changed[changed.startIndex + 5] ^= 0x01
            return changed
        }
        try await client.send(CartoucheBridgeRequest(.info))
        do {
            _ = try await server.receive(CartoucheBridgeRequest.self)
            XCTFail("a changed frame was read")
        } catch {
            XCTAssertEqual((error as? CartoucheBridgeError)?.kind, .protocolError)
        }
    }

    func testADeviceInBetweenMakesTheCodesDiffer() async throws {
        // Each side pairs with the device in between: it cannot choose its
        // halves to make the two codes the same.
        let (phone, middleToPhone) = MemoryTransport.pair()
        let (middleToMac, macSide) = MemoryTransport.pair()
        let codes = CodeBox()
        async let macOpening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Mac", keyOf: { _ in nil }) { _, code in
            codes.add("mac:" + code)
            return false
        }
        async let middleWithPhone = CartoucheBridgeHandshake.server(middleToPhone, mac: mac, name: "Mac", keyOf: { _ in nil }) { _, _ in false }
        async let middleWithMac = try? CartoucheBridgeHandshake.pair(middleToMac, device: device, name: "iPhone") { _ in }
        _ = try? await CartoucheBridgeHandshake.pair(phone, device: device, name: "iPhone") { codes.add("phone:" + $0) }
        _ = try? await macOpening
        _ = try? await middleWithPhone
        _ = await middleWithMac
        let shown = codes.all
        let phoneCode = shown.first { $0.hasPrefix("phone:") }?.dropFirst(6)
        let macCode = shown.first { $0.hasPrefix("mac:") }?.dropFirst(4)
        XCTAssertNotNil(phoneCode)
        XCTAssertNotNil(macCode)
        XCTAssertNotEqual(phoneCode, macCode)
    }

    func testAnErrorLetsTheRequestsWaitingThroughOneAtATime() async throws {
        let key = Data(repeating: 7, count: 32)
        let (phoneSide, macSide) = MemoryTransport.pair()
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Mac", keyOf: { _ in key }, allow: nil)
        let channel = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: key, mac: mac)
        guard case let .session(server) = try await opening else { return XCTFail("no session") }
        let client = CartoucheBridgeClient(channel: channel, address: nil)
        // The Mac answers each request after a while, the first one it gets
        // with an error, and notes a request that came before it answered
        // the one before it: two requests at once on the session.
        let overlaps = CodeBox()
        let serving = Task { () throws -> Void in
            for index in 0..<3 {
                let (request, _) = try await server.receive(CartoucheBridgeRequest.self)
                try await Task.sleep(nanoseconds: 150_000_000)
                let path = request.path ?? ""
                if macSide.queued > 0 {
                    overlaps.add(path)
                    return
                }
                var response = index == 0 ? CartoucheBridgeResponse.failure(.notFound, path) : CartoucheBridgeResponse()
                response.name = path
                try await server.send(response)
            }
        }
        let paths = ["Games/A.ipa", "Games/B.ipa", "Games/C.ipa"]
        let calls = paths.map { path in
            Task { () -> String? in try? await client.stat(path).name }
        }
        try await serving.value
        guard overlaps.all.isEmpty else {
            phoneSide.close()
            return XCTFail("two requests at once after an error: \(overlaps.all)")
        }
        var answers: [String?] = []
        for call in calls {
            answers.append(await call.value)
        }
        XCTAssertEqual(answers.filter { $0 == nil }.count, 1, "the one the Mac refused")
        for (path, answer) in zip(paths, answers) where answer != nil {
            XCTAssertEqual(answer, path, "each answer to its own request")
        }
    }

    func testPaths() {
        XCTAssertEqual(CartoucheBridgePath.parts("Games/Mario Kart World [0400C3F00006E000].ipa"), ["Games", "Mario Kart World [0400C3F00006E000].ipa"])
        XCTAssertEqual(CartoucheBridgePath.parts(""), [])
        XCTAssertNil(CartoucheBridgePath.parts("Games/../../etc/passwd"))
        XCTAssertNil(CartoucheBridgePath.parts("Saves/./x"))
    }

    func testMessages() throws {
        let data = try CartoucheBridgeMessage.encode(CartoucheBridgeRequest(.list, path: "Saves"), body: Data([1, 2, 3]))
        let (request, body) = try CartoucheBridgeMessage.decode(CartoucheBridgeRequest.self, from: data)
        XCTAssertEqual(request.op, .list)
        XCTAssertEqual(request.path, "Saves")
        XCTAssertEqual(body, Data([1, 2, 3]))
        XCTAssertThrowsError(try CartoucheBridgeMessage.decode(CartoucheBridgeRequest.self, from: Data([0, 0, 1, 0])))
    }
}

/// The codes the two sides showed, from their tasks.
final class CodeBox: @unchecked Sendable {
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
