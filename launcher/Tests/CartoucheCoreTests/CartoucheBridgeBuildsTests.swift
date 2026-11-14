//
//  CartoucheBridgeBuildsTests.swift
//  CartoucheCoreTests
//
//  Cartouche Builder's builds, as the Mac shares them with a paired iPhone
//  (Sources/CartoucheBridgeBuilds.swift): what a Mac a little older or
//  newer sends, the builds now, waiting, done and failed, what is due and
//  the nightly build, a game's line on its sheet, the button that asks the
//  Mac to build it and the one that stops its build, and both over a
//  session in memory, after info says the Mac shares them; then the rest of
//  what the Mac's window does, asked of a Mac whose info says it takes it.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheBridgeBuildsTests: XCTestCase {
    typealias Game = CartoucheBridgeBuilds.Game

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3_600

    // MARK: What the Mac sends

    func testWhatAMacLeavesOutTakesItsDefault() throws {
        let json = #"{"games": [{"id": "0400C3F00006E000", "progress": "half", "turn": "next", "later": 1}], "later": true}"#
        let builds = try JSONDecoder().decode(CartoucheBridgeBuilds.self, from: Data(json.utf8))
        XCTAssertFalse(builds.running)
        XCTAssertTrue(builds.ready)
        XCTAssertNil(builds.why)
        let game = try XCTUnwrap(builds.games.first)
        XCTAssertEqual(game.name, "0400C3F00006E000")
        XCTAssertEqual(game.state, "")
        XCTAssertEqual(game.reasons, [])
        XCTAssertNil(game.progress)
        XCTAssertNil(game.turn)
        XCTAssertTrue(game.buildable)

        XCTAssertNil(game.followed)
        XCTAssertNil(game.stoppable)
        XCTAssertNil(game.stopping)
        XCTAssertNil(builds.due)
        XCTAssertNil(builds.nightly)

        let empty = try JSONDecoder().decode(CartoucheBridgeBuilds.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, CartoucheBridgeBuilds())

        // A nightly build with what is missing or wrong at its default, and
        // its time within a day.
        let nightly = try JSONDecoder().decode(CartoucheBridgeBuilds.self, from: Data(#"{"nightly": {"hour": 27, "minute": "late"}}"#.utf8))
        XCTAssertEqual(nightly.nightly, CartoucheBridgeBuilds.Nightly(on: false, hour: 23, minute: 30))
        XCTAssertEqual(CartoucheBridgeBuilds.Nightly(on: true, hour: -1, minute: 75), CartoucheBridgeBuilds.Nightly(on: true, hour: 0, minute: 59))
    }

    func testTheBuildsGoThereAndBack() throws {
        let builds = CartoucheBridgeBuilds(running: true, ready: false, why: "Importing", games: [
            Game(id: "A", name: "Alpha", state: "building", reasons: ["changes"], progress: 0.5, step: "Packing the IPA", left: 90,
                 followed: true, stoppable: false, stopping: true),
            Game(id: "B", name: "Beta", state: "failed", built: now.addingTimeInterval(-2 * hour), failed: now, error: "No SDK", buildable: false),
        ], due: 3, nightly: CartoucheBridgeBuilds.Nightly(on: true, hour: 4, minute: 15))
        let back = try JSONDecoder().decode(CartoucheBridgeBuilds.self, from: JSONEncoder().encode(builds))
        XCTAssertEqual(back, builds)
        XCTAssertEqual(back.games[1].failedDate, now)
        XCTAssertEqual(back.games[1].builtDate, now.addingTimeInterval(-2 * hour))
    }

    func testBuildingWaitingAndDone() {
        let builds = CartoucheBridgeBuilds(running: true, games: [
            Game(id: "A", name: "Alpha", state: "queued", turn: 2, built: now.addingTimeInterval(-hour)),
            Game(id: "B", name: "Beta", state: "building", built: now),
            Game(id: "C", name: "Gamma", state: "queued", turn: 1),
            Game(id: "D", name: "Delta", state: "up_to_date", built: now.addingTimeInterval(-3 * hour)),
            // Failed after its last build.
            Game(id: "E", name: "Epsilon", state: "failed", built: now.addingTimeInterval(-5 * hour), failed: now.addingTimeInterval(-hour)),
            // Built after its last failure.
            Game(id: "F", name: "Zeta", state: "up_to_date", built: now.addingTimeInterval(-2 * hour), failed: now.addingTimeInterval(-4 * hour)),
            // Never built.
            Game(id: "G", name: "Eta", state: "due", reasons: ["new"]),
        ])
        XCTAssertEqual(builds.building.map(\.id), ["B"])
        XCTAssertEqual(builds.waiting.map(\.id), ["C", "A"])
        let done = builds.done()
        XCTAssertEqual(done.map(\.id), ["E", "F", "D"])
        XCTAssertEqual(done.map(\.failed), [true, false, false])
        XCTAssertEqual(done[0].date, now.addingTimeInterval(-hour))
        XCTAssertEqual(builds.done(limit: 1).map(\.id), ["E"])
        XCTAssertEqual(builds.failures.map(\.id), ["E"])
        // By name, as the Mac's library has them.
        XCTAssertEqual(builds.library.map(\.name), ["Alpha", "Beta", "Delta", "Epsilon", "Eta", "Gamma", "Zeta"])
        // What is due, counted by the Mac, or else by the games due.
        XCTAssertEqual(builds.dueCount, 1)
        var counted = builds
        counted.due = 4
        XCTAssertEqual(counted.dueCount, 4)
    }

    // MARK: A game's sheet

    func build(_ game: Game, running: Bool = false, ready: Bool = true, why: String? = nil) -> CartoucheMacBuild {
        CartoucheMacBuild(game, running: running, ready: ready, why: why)
    }

    func testAGameBuildingOrWaitingHasNothingToAsk() {
        let building = build(Game(id: "A", name: "Alpha", state: "building", progress: 1.4, step: "Packing the IPA", left: 30), running: true)
        XCTAssertEqual(building.status, .building(progress: 1, step: "Packing the IPA", left: 30))
        XCTAssertNil(building.action)
        let waiting = build(Game(id: "A", name: "Alpha", state: "queued", turn: 2), running: true)
        XCTAssertEqual(waiting.status, .waiting(turn: 2))
        XCTAssertNil(waiting.action)
        // A Mac that does not say it can stop them: nothing to stop.
        XCTAssertNil(building.halt)
        XCTAssertNil(waiting.halt)
        XCTAssertFalse(building.stopping)
        XCTAssertNil(building.followed)
    }

    func testAGameBuildingStopsAndAGameWaitingLeavesTheQueue() {
        let building = build(Game(id: "A", name: "Alpha", state: "building", followed: true, stoppable: true, stopping: false), running: true)
        XCTAssertEqual(building.halt, .stop)
        XCTAssertEqual(building.followed, true)
        let stopping = build(Game(id: "A", name: "Alpha", state: "building", stoppable: false, stopping: true), running: true)
        XCTAssertNil(stopping.halt)
        XCTAssertTrue(stopping.stopping)
        let waiting = build(Game(id: "A", name: "Alpha", state: "queued", turn: 1, stoppable: true), running: true)
        XCTAssertEqual(waiting.halt, .remove)
        // The batch starting: its games stop only all together.
        XCTAssertNil(build(Game(id: "A", name: "Alpha", state: "queued", turn: 1, stoppable: false), running: true).halt)
        // Neither building nor waiting: nothing to stop, whatever the Mac says.
        let upToDate = build(Game(id: "A", name: "Alpha", state: "up_to_date", built: now, followed: false, stoppable: true))
        XCTAssertNil(upToDate.halt)
        XCTAssertEqual(upToDate.followed, false)
    }

    func testEachStateItsLineAndItsButton() {
        let built = now.addingTimeInterval(-hour)
        let new = build(Game(id: "A", name: "Alpha", state: "due", reasons: ["new"]))
        XCTAssertEqual(new.status, .new)
        XCTAssertEqual(new.action, .build)

        let improved = build(Game(id: "A", name: "Alpha", state: "due", reasons: ["changes"], built: built))
        XCTAssertEqual(improved.status, .improved(built: built))
        XCTAssertEqual(improved.action, .rebuild)

        let upToDate = build(Game(id: "A", name: "Alpha", state: "up_to_date", built: built))
        XCTAssertEqual(upToDate.status, .upToDate(built: built))
        XCTAssertEqual(upToDate.action, .buildAgain)

        let failed = build(Game(id: "A", name: "Alpha", state: "failed", built: built, failed: now, error: "No SDK"))
        XCTAssertEqual(failed.status, .failed(at: now, error: "No SDK"))
        XCTAssertEqual(failed.action, .buildAgain)

        // Up to date in the library, but its last attempt failed since.
        let failedSince = build(Game(id: "A", name: "Alpha", state: "up_to_date", built: built, failed: now, error: "Stopped"))
        XCTAssertEqual(failedSince.status, .failed(at: now, error: "Stopped"))

        // Never built, its first attempt failed.
        let neverBuilt = build(Game(id: "A", name: "Alpha", state: "due", reasons: ["new"], failed: now, error: "No SDK"))
        XCTAssertEqual(neverBuilt.status, .failed(at: now, error: "No SDK"))
        XCTAssertEqual(neverBuilt.action, .build)

        let notFollowed = build(Game(id: "A", name: "Alpha", state: "not_followed", built: built))
        XCTAssertEqual(notFollowed.status, .notFollowed(built: built))
        XCTAssertEqual(notFollowed.action, .buildAgain)

        let noProfile = build(Game(id: "A", name: "Alpha", state: "no_profile"))
        XCTAssertEqual(noProfile.status, .noProfile)
        XCTAssertEqual(noProfile.action, .build)

        // Its IPA alone on the Mac: nothing to build it from.
        let ipaOnly = build(Game(id: "A", name: "Alpha", state: "no_source", built: built, buildable: false))
        XCTAssertEqual(ipaOnly.status, .ipaOnly(built: built))
        XCTAssertNil(ipaOnly.action)
        XCTAssertNil(build(Game(id: "A", name: "Alpha", state: "up_to_date", built: built, buildable: false)).action)

        // A state of a newer Mac: as the library's own, up to date.
        XCTAssertEqual(build(Game(id: "A", name: "Alpha", state: "later", built: built)).status, .upToDate(built: built))
    }

    func testABatchRunningTakesTheGameAfterIt() {
        for game in [Game(id: "A", name: "Alpha", state: "due", reasons: ["new"]),
                     Game(id: "A", name: "Alpha", state: "due", reasons: ["changes"], built: now),
                     Game(id: "A", name: "Alpha", state: "up_to_date", built: now)] {
            XCTAssertEqual(build(game, running: true).action, .addToQueue, game.state)
        }
    }

    func testWhyTheMacTakesNoBuildOnlyWhenItTakesNone() {
        let game = Game(id: "A", name: "Alpha", state: "up_to_date", built: now)
        let refused = build(game, ready: false, why: "The Mac is importing an IPA")
        XCTAssertFalse(refused.ready)
        XCTAssertEqual(refused.why, "The Mac is importing an IPA")
        XCTAssertEqual(refused.action, .buildAgain)
        XCTAssertNil(build(game, ready: true, why: "stale").why)
    }

    func testTheGameIsFoundByAnyOfItsTitleIDs() {
        let builds = CartoucheBridgeBuilds(running: true, ready: false, why: "Tools", games: [
            Game(id: "0100A1B00C2D0000", name: "Japan", state: "up_to_date", built: now),
            Game(id: "01006bb00c6f0000", name: "Link", state: "queued", turn: 1),
        ])
        let found = CartoucheMacBuild.of(["01006BB00C6F2000", "01006BB00C6F0000"], in: builds)
        XCTAssertEqual(found?.id, "01006bb00c6f0000")
        XCTAssertEqual(found?.name, "Link")
        XCTAssertEqual(found?.status, .waiting(turn: 1))
        XCTAssertEqual(found?.why, "Tools")
        XCTAssertNil(CartoucheMacBuild.of(["0400C3F00006E000"], in: builds))
        XCTAssertNil(CartoucheMacBuild.of([], in: builds))
    }

    // MARK: Over the bridge

    func testTheBuildsAndABuildOverASession() async throws {
        let key = Data(repeating: 9, count: 32)
        let mac = UUID().uuidString, device = UUID().uuidString
        let (phoneSide, macSide) = MemoryTransport.pair()
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Mac", keyOf: { _ in key }, allow: nil,
                                                            keep: CartoucheBridgeTests.keepsNothing)
        let channel = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: key, mac: mac)
        guard case let .session(server) = try await opening else { return XCTFail("no session") }
        let client = CartoucheBridgeClient(channel: channel, address: nil)
        let before = CartoucheBridgeBuilds(running: false, games: [Game(id: "A", name: "Alpha", state: "up_to_date", built: now)])
        let after = CartoucheBridgeBuilds(running: true, games: [Game(id: "A", name: "Alpha", state: "building", built: now)])
        let serving = Task { () throws -> [CartoucheBridgeRequest] in
            var requests: [CartoucheBridgeRequest] = []
            for _ in 0..<3 {
                let (request, _) = try await server.receive(CartoucheBridgeRequest.self)
                requests.append(request)
                var response = CartoucheBridgeResponse()
                switch request.op {
                case .info: response.hasBuilds = true
                case .builds: response.builds = before
                case .build: response.builds = after
                default: response = .failure(.notFound, "op")
                }
                try await server.send(response)
            }
            return requests
        }
        let hasBuilds = try await client.info().hasBuilds
        XCTAssertEqual(hasBuilds, true)
        let builds = try await client.builds()
        XCTAssertEqual(builds, before)
        let built = try await client.build("A")
        XCTAssertEqual(built, after)
        let requests = try await serving.value
        XCTAssertEqual(requests.map(\.op), [.info, .builds, .build])
        XCTAssertEqual(requests[2].game, "A")
        XCTAssertNil(requests[1].game)
    }

    func testTheRestOfTheMacsWindowOverASession() async throws {
        let key = Data(repeating: 9, count: 32)
        let mac = UUID().uuidString, device = UUID().uuidString
        let (phoneSide, macSide) = MemoryTransport.pair()
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Mac", keyOf: { _ in key }, allow: nil,
                                                            keep: CartoucheBridgeTests.keepsNothing)
        let channel = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: key, mac: mac)
        guard case let .session(server) = try await opening else { return XCTFail("no session") }
        let client = CartoucheBridgeClient(channel: channel, address: nil)
        let nightly = CartoucheBridgeBuilds.Nightly(on: true, hour: 4, minute: 15)
        let serving = Task { () throws -> [CartoucheBridgeRequest] in
            var requests: [CartoucheBridgeRequest] = []
            for _ in 0..<6 {
                let (request, _) = try await server.receive(CartoucheBridgeRequest.self)
                requests.append(request)
                var response = CartoucheBridgeResponse()
                if request.op == .info {
                    response.hasBuilds = true
                    response.hasBuildsControl = true
                } else {
                    // What was asked, in the builds' answer: the op as why.
                    response.builds = CartoucheBridgeBuilds(why: request.op.rawValue, nightly: request.nightly)
                }
                try await server.send(response)
            }
            return requests
        }
        let info = try await client.info()
        XCTAssertEqual(info.hasBuildsControl, true)
        let due = try await client.buildDue()
        XCTAssertEqual(due.why, "buildDue")
        let stopped = try await client.stop("A")
        XCTAssertEqual(stopped.why, "stop")
        let all = try await client.stopAll()
        XCTAssertEqual(all.why, "stopAll")
        let followed = try await client.follow("B", false)
        XCTAssertEqual(followed.why, "follow")
        let night = try await client.setNightly(nightly)
        XCTAssertEqual(night.nightly, nightly)
        let requests = try await serving.value
        XCTAssertEqual(requests.map(\.op), [.info, .buildDue, .stop, .stopAll, .follow, .nightly])
        XCTAssertEqual(requests.map(\.game), [nil, nil, "A", nil, "B", nil])
        XCTAssertEqual(requests[4].followed, false)
        XCTAssertEqual(requests[5].nightly, nightly)
        XCTAssertTrue(requests.dropFirst().allSatisfy(\.op.isBuilds))
        XCTAssertFalse(CartoucheBridgeRequest.Operation.list.isBuilds)
    }

    func testAnAnswerWithoutBuildsIsAnError() async throws {
        let key = Data(repeating: 9, count: 32)
        let mac = UUID().uuidString, device = UUID().uuidString
        let (phoneSide, macSide) = MemoryTransport.pair()
        async let opening = CartoucheBridgeHandshake.server(macSide, mac: mac, name: "Mac", keyOf: { _ in key }, allow: nil,
                                                            keep: CartoucheBridgeTests.keepsNothing)
        let channel = try await CartoucheBridgeHandshake.client(phoneSide, device: device, key: key, mac: mac)
        guard case let .session(server) = try await opening else { return XCTFail("no session") }
        let client = CartoucheBridgeClient(channel: channel, address: nil)
        let serving = Task { () throws -> Void in
            _ = try await server.receive(CartoucheBridgeRequest.self)
            try await server.send(CartoucheBridgeResponse())
            _ = try await server.receive(CartoucheBridgeRequest.self)
            try await server.send(CartoucheBridgeResponse.failure(.failed, "The Mac is importing an IPA"))
        }
        do {
            _ = try await client.builds()
            XCTFail("builds without any")
        } catch let error as CartoucheBridgeError {
            XCTAssertEqual(error.kind, .protocolError)
        }
        do {
            _ = try await client.build("A")
            XCTFail("a build the Mac refused")
        } catch let error as CartoucheBridgeError {
            XCTAssertEqual(error.kind, .failed)
            XCTAssertEqual(error.message, "The Mac is importing an IPA")
        }
        try await serving.value
    }
}
