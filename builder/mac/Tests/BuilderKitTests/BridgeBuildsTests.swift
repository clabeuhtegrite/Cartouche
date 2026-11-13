//
//  BridgeBuildsTests.swift
//  BuilderKitTests
//
//  The builds a paired iPhone sees, and the build it asks for
//  (BridgeBuilds.swift, BridgeServer's BridgeBuildsSource): the library's
//  games, those building and those waiting their turn in their order, when
//  each was built and its last failure, cut; then over a session, the Mac's
//  info, its builds, a build asked for and the Mac's refusal in its own
//  words. What Cartouche makes of them is tested with Cartouche's
//  (launcher/Tests/CartoucheCoreTests/CartoucheBridgeBuildsTests.swift).
//

import CartoucheCore
import Foundation
import XCTest
@testable import BuilderKit

/// One end of a connection in memory; frames go to the other end.
private final class Pipe: CartoucheBridgeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    private var closed = false
    weak var other: Pipe?

    static func pair() -> (Pipe, Pipe) {
        let a = Pipe(), b = Pipe()
        a.other = b
        b.other = a
        return (a, b)
    }

    func sendFrame(_ data: Data) async throws {
        guard let other else { throw CartoucheBridgeError(.closed) }
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

/// The app, as a paired iPhone sees its builds: the games it was asked to
/// build, and the Mac's refusal, if it refuses.
@MainActor
private final class Builds: BridgeBuildsSource {
    var shared = CartoucheBridgeBuilds()
    var asked: [String] = []
    var refusal: CartoucheBridgeError?

    func bridgeBuilds() -> CartoucheBridgeBuilds { shared }

    func bridgeBuild(_ titleID: String) throws {
        if let refusal { throw refusal }
        asked.append(titleID)
        shared.running = true
        if let index = shared.games.firstIndex(where: { $0.id == titleID }) {
            shared.games[index].state = "building"
        }
    }
}

final class BridgeBuildsTests: XCTestCase {
    static let stage: (String?) -> String = { "Stage " + ($0 ?? "none") }

    func game(_ titleID: String, _ state: GameState, reasons: [String] = [], built: String? = nil, attempt: GameAttempt? = nil,
              kind: String = "nsp") -> Game {
        Game(titleID: titleID, name: "Game \(titleID)", kind: kind, state: state, reasons: reasons,
             build: built.map { GameBuild(commit: "7bddb8c1e2f3", builtAt: $0) }, attempt: attempt)
    }

    func testTheLibraryWithTheGamesBuildingAndWaiting() throws {
        var building = GameProgress(titleID: "A", name: "Game A", state: "building", stage: "shaders", frac: 0.2, overall: 0.4, eta: 300)
        building.reasons = ["changes"]
        let library = [
            game("A", .due, reasons: ["changes"], built: "2026-11-10T07:00:00+00:00"),
            game("B", .upToDate, built: "2026-11-12T07:00:00+00:00"),
            game("C", .due, reasons: ["new"]),
            game("D", .noSource, built: "2026-11-01T07:00:00+00:00", kind: "ipa"),
        ]
        let waiting = [
            GameProgress(titleID: "C", name: "Game C", state: "queued"),
            // Twice in the queue, and the game building: once, in its first place.
            GameProgress(titleID: "C", name: "Game C", state: "queued"),
            GameProgress(titleID: "A", name: "Game A", state: "queued"),
            GameProgress(titleID: "B", name: "Game B", state: "queued"),
            // Not in the library yet.
            GameProgress(titleID: "E", name: "Game E", state: "queued"),
        ]
        let shared = BridgeBuilds.shared(games: library, building: [building], waiting: waiting, running: true, ready: false,
                                         why: "Importing", stage: Self.stage)
        XCTAssertTrue(shared.running)
        XCTAssertFalse(shared.ready)
        XCTAssertEqual(shared.why, "Importing")
        XCTAssertEqual(shared.games.map(\.id), ["A", "B", "C", "D", "E"])
        let a = shared.games[0]
        XCTAssertEqual(a.state, "building")
        XCTAssertEqual(a.progress, 0.4)
        XCTAssertEqual(a.step, "Stage shaders")
        XCTAssertEqual(a.left, 300)
        XCTAssertEqual(a.reasons, ["changes"])
        XCTAssertEqual(a.builtDate, ISODate.parse("2026-11-10T07:00:00+00:00"))
        XCTAssertEqual(shared.games.map(\.turn), [nil, 2, 1, nil, 3])
        XCTAssertEqual(shared.waiting.map(\.id), ["C", "B", "E"])
        XCTAssertEqual(shared.games[3].state, "no_source")
        XCTAssertFalse(shared.games[3].buildable)
        XCTAssertTrue(shared.games[0].buildable)
        XCTAssertEqual(shared.games[4].name, "Game E")
        XCTAssertEqual(shared.games[4].state, "queued")

        // Ready: no reason why not.
        XCTAssertNil(BridgeBuilds.shared(games: library, building: [], waiting: [], running: false, ready: true, why: "stale",
                                         stage: Self.stage).why)
    }

    func testTheLastFailureAndItsWordsCut() throws {
        let long = String(repeating: "x", count: BridgeBuilds.errorLength + 50)
        let failedSince = game("A", .failed, built: "2026-11-10T07:00:00+00:00",
                               attempt: GameAttempt(commit: "7bddb8c1e2f3", at: "2026-11-11T07:00:00+00:00", result: "failed", error: long))
        let shared = BridgeBuilds.game(failedSince, building: nil, turn: nil, stage: Self.stage)
        XCTAssertEqual(shared.failedDate, ISODate.parse("2026-11-11T07:00:00+00:00"))
        XCTAssertEqual(shared.error?.count, BridgeBuilds.errorLength)
        XCTAssertEqual(shared.error?.last, "…")

        // A failure before the last build is over; a stop is no failure.
        let builtSince = game("A", .upToDate, built: "2026-11-12T07:00:00+00:00",
                              attempt: GameAttempt(commit: "7bddb8c1e2f3", at: "2026-11-11T07:00:00+00:00", result: "failed", error: "old"))
        XCTAssertNil(BridgeBuilds.game(builtSince, building: nil, turn: nil, stage: Self.stage).failed)
        let stopped = game("A", .upToDate, built: "2026-11-10T07:00:00+00:00",
                           attempt: GameAttempt(commit: "7bddb8c1e2f3", at: "2026-11-11T07:00:00+00:00", result: "stopped"))
        XCTAssertNil(BridgeBuilds.game(stopped, building: nil, turn: nil, stage: Self.stage).error)
        // Never built, failed.
        let never = game("A", .failed, attempt: GameAttempt(commit: "7bddb8c1e2f3", at: "2026-11-11T07:00:00+00:00", result: "failed"))
        XCTAssertNotNil(BridgeBuilds.game(never, building: nil, turn: nil, stage: Self.stage).failed)
    }

    func testTheLibraryReadWhileTheBatchHadTheGame() {
        // The batch no longer has it: as it was before.
        XCTAssertEqual(BridgeBuilds.game(game("A", .building), building: nil, turn: nil, stage: Self.stage).state, "due")
        XCTAssertEqual(BridgeBuilds.game(game("A", .queued, built: "2026-11-10T07:00:00+00:00"), building: nil, turn: nil,
                                         stage: Self.stage).state, "up_to_date")
    }

    func testAGameDueForItsMacAppAloneIsUpToDateToTheIPhone() {
        let macAlone = game("A", .due, reasons: ["mac_new"], built: "2026-11-10T07:00:00+00:00")
        XCTAssertTrue(BridgeBuilds.dueForMacAppAlone(macAlone))
        let shared = BridgeBuilds.game(macAlone, building: nil, turn: nil, stage: Self.stage)
        XCTAssertEqual(shared.state, "up_to_date")
        XCTAssertEqual(shared.reasons, [])
        XCTAssertFalse(BridgeBuilds.dueForMacAppAlone(game("A", .due, reasons: ["mac_new", "changes"])))
        XCTAssertFalse(BridgeBuilds.dueForMacAppAlone(game("A", .due)))
        XCTAssertFalse(BridgeBuilds.dueForMacAppAlone(game("A", .upToDate, reasons: ["mac_new"])))
    }

    // MARK: Over a session

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

    /// A session of a paired iPhone with SERVER: its client, and the task
    /// that serves it until it closes.
    private func session(_ server: BridgeServer) async throws -> (CartoucheBridgeClient, Task<Void, Never>) {
        let key = Data(repeating: 5, count: 32)
        let device = UUID().uuidString
        server.devices.add(id: device, name: "iPhone de test", key: key)
        let (phoneSide, macSide) = Pipe.pair()
        let serving = Task { await server.open(macSide) }
        let channel = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: key, mac: server.devices.macID)
        return (CartoucheBridgeClient(channel: channel, address: nil), serving)
    }

    private func server() -> BridgeServer {
        let server = BridgeServer(devices: BridgeDevices(url: folder.appendingPathComponent("bridge.json")), name: "Mac de test")
        server.roots = BridgeRoots(games: folder.appendingPathComponent("Jeux", isDirectory: true),
                                   saves: folder.appendingPathComponent("Saves", isDirectory: true))
        return server
    }

    func testAMacWithoutBuildsSaysSo() async throws {
        let server = server()
        let (client, serving) = try await session(server)
        let info = try await client.info()
        XCTAssertEqual(info.hasBuilds, false)
        do {
            _ = try await client.builds()
            XCTFail("builds from a Mac without any")
        } catch let error as CartoucheBridgeError {
            XCTAssertEqual(error.kind, .notFound)
        }
        // The session goes on.
        let top = try await client.list("")
        XCTAssertEqual(top.map(\.name), [CartoucheBridge.gamesFolder, CartoucheBridge.savesFolder])
        client.close()
        await serving.value
    }

    func testTheBuildsAndABuildAskedFor() async throws {
        let server = server()
        let builds = await MainActor.run { () -> Builds in
            let builds = Builds()
            builds.shared = CartoucheBridgeBuilds(games: [CartoucheBridgeBuilds.Game(id: "A", name: "Game A", state: "up_to_date")])
            return builds
        }
        server.builds = builds
        let (client, serving) = try await session(server)
        let hasBuilds = try await client.info().hasBuilds
        XCTAssertEqual(hasBuilds, true)
        let before = try await client.builds()
        XCTAssertFalse(before.running)
        XCTAssertEqual(before.games.map(\.state), ["up_to_date"])
        let after = try await client.build("A")
        XCTAssertTrue(after.running)
        XCTAssertEqual(after.games.map(\.state), ["building"])
        let asked = await MainActor.run { builds.asked }
        XCTAssertEqual(asked, ["A"])

        // Without a game, and refused by the Mac, in its words.
        do {
            _ = try await client.call(CartoucheBridgeRequest(.build))
            XCTFail("a build of no game")
        } catch let error as CartoucheBridgeError {
            XCTAssertEqual(error.kind, .notFound)
        }
        await MainActor.run { builds.refusal = CartoucheBridgeError(.failed, "The Mac is importing an IPA") }
        do {
            _ = try await client.build("A")
            XCTFail("a build the Mac refused")
        } catch let error as CartoucheBridgeError {
            XCTAssertEqual(error, CartoucheBridgeError(.failed, "The Mac is importing an IPA"))
        }
        let stillAsked = await MainActor.run { builds.asked }
        XCTAssertEqual(stillAsked, ["A"])
        client.close()
        await serving.value
    }
}
