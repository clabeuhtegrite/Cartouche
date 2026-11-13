//
//  CartoucheResumingSourceTests.swift
//  CartoucheCoreTests
//
//  The source that reads on after its connection drops
//  (Sources/CartoucheResumingSource.swift), against a server in memory whose
//  connections drop, are refused, stop answering or find another file, as
//  a game's IPA can while it comes from the player's NAS over Wi-Fi.
//

import Foundation
import XCTest
@testable import CartoucheCore

/// A server that holds one file, and whose connections fail as a test
/// plans it. Its connections are read on one task and closed on others.
final class FlakyServer: @unchecked Sendable {
    struct Dropped: Error {}
    struct Refused: Error {}

    enum Outcome {
        case serve, drop, silence
    }

    let data: Data
    /// A read that waits longer is cut, as the SMB source does; nil: none.
    let patience: UInt64?

    private let lock = NSLock()
    private var planned: [Outcome] = []
    private var refusals = 0
    private var nextSize: UInt64
    private var opened = 0
    private var closed = 0
    private var servedOffsets: [UInt64] = []
    private var failedOffsets: [UInt64] = []

    init(_ data: Data, patience: UInt64? = nil) {
        self.data = data
        self.patience = patience
        nextSize = UInt64(data.count)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// What the next reads do, in order, whichever connection they come
    /// on; reads past the plan are served.
    func plan(_ outcomes: [Outcome]) { locked { planned = outcomes } }
    /// The next COUNT connections are refused.
    func refuse(_ count: Int) { locked { refusals = count } }
    /// The size the next connections give the file, as another file there.
    func replaceFile(size: UInt64) { locked { nextSize = size } }

    var opens: Int { locked { opened } }
    var closes: Int { locked { closed } }
    /// The offsets of the reads served and of those that failed, in order.
    var served: [UInt64] { locked { servedOffsets } }
    var failed: [UInt64] { locked { failedOffsets } }

    func open() async throws -> CartoucheResumingSource.Opened {
        let size = locked { () -> UInt64? in
            opened += 1
            guard refusals == 0 else {
                refusals -= 1
                return nil
            }
            return nextSize
        }
        guard let size else { throw Refused() }
        let connection = FlakyConnection(server: self, size: size)
        return CartoucheResumingSource.Opened(source: connection, close: { [self] in
            connection.cut()
            locked { closed += 1 }
        })
    }

    fileprivate func next(at offset: UInt64) -> Outcome {
        locked { () -> Outcome in
            let outcome: Outcome = planned.isEmpty ? .serve : planned.removeFirst()
            if outcome == .serve {
                servedOffsets.append(offset)
            } else {
                failedOffsets.append(offset)
            }
            return outcome
        }
    }
}

private final class FlakyConnection: CartoucheByteSource, @unchecked Sendable {
    let size: UInt64
    private let server: FlakyServer
    private let lock = NSLock()
    private var isCut = false
    private var waiting: CheckedContinuation<Data, Error>?

    init(server: FlakyServer, size: UInt64) {
        self.server = server
        self.size = size
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        switch server.next(at: offset) {
        case .drop:
            cut()
            throw FlakyServer.Dropped()
        case .silence:
            guard let patience = server.patience else { throw FlakyServer.Dropped() }
            return try await CartoucheDeadline.within(patience, cut: { self.cut() }) {
                try await self.waitForTheCut()
            }
        case .serve:
            if locked({ isCut }) { throw FlakyServer.Dropped() }
            let start = Int(min(offset, UInt64(server.data.count)))
            let end = Int(min(offset + UInt64(count), UInt64(server.data.count)))
            return server.data.subdata(in: start ..< end)
        }
    }

    /// A server that stopped answering: nothing comes until the connection
    /// is cut.
    private func waitForTheCut() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let cutAlready = locked { () -> Bool in
                if isCut { return true }
                waiting = continuation
                return false
            }
            if cutAlready { continuation.resume(throwing: FlakyServer.Dropped()) }
        }
    }

    func cut() {
        let pending = locked { () -> CheckedContinuation<Data, Error>? in
            isCut = true
            let pending = waiting
            waiting = nil
            return pending
        }
        pending?.resume(throwing: FlakyServer.Dropped())
    }
}

final class CartoucheResumingSourceTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CartoucheResumingSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Bytes that take VALUES values: 16 deflate to about half, 256 do not
    /// deflate at all, as most of a game's data.
    private func noise(_ count: Int, values: Int = 256, seed: UInt64) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            for index in 0 ..< count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw[index] = UInt8(truncatingIfNeeded: (state >> 33) % UInt64(values))
            }
        }
        return data
    }

    /// An IPA of three reads or more, with a deflated romfs.img across
    /// them, as nxnative packs one; and its files.
    private func makeArchive() async throws -> (Data, [String: Data]) {
        let files: [(String, Data)] = [
            ("Payload/Game.app/Info.plist", Data(String(repeating: "<key>CFBundleIdentifier</key>\n", count: 40).utf8)),
            ("Payload/Game.app/romfs.img", noise(2 * CartoucheSequentialReader.chunk + (6 << 20), values: 16, seed: 11)),
            ("Payload/Game.app/main", noise(8 << 20, seed: 12)),
        ]
        let sink = MemorySink()
        let writer = CartoucheZipWriter(sink: sink)
        try await writer.addFolder("Payload/")
        try await writer.addFolder("Payload/Game.app/")
        for (name, data) in files {
            try await writer.addData(name, data)
        }
        try await writer.finish()
        XCTAssertGreaterThan(sink.data.count, 2 * CartoucheSequentialReader.chunk)
        return (sink.data, Dictionary(uniqueKeysWithValues: files))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 500 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    func testAnInstallReadsOnWhereTheConnectionDropped() async throws {
        let (archive, files) = try await makeArchive()
        let server = FlakyServer(archive)
        let source = try await CartoucheResumingSource.open(pauses: [0, 0, 0]) { try await server.open() }
        var retries: [Int] = []
        var resumed = 0
        source.onRetry = { attempt, error in
            XCTAssertTrue(error is FlakyServer.Dropped, "\(error)")
            retries.append(attempt)
        }
        source.onResumed = { resumed += 1 }
        let entries = try await CartoucheZip.entries(of: source)
        XCTAssertEqual(entries.first { $0.name.hasSuffix("romfs.img") }?.method, 8)

        // Twice in a row at the second read, with romfs.img half inflated,
        // then once at the third.
        server.plan([.serve, .drop, .drop, .serve, .drop])
        let before = server.served.count
        let into = folder.appendingPathComponent("out")
        let progress = Progress()
        try await CartoucheZip.extract(source, entries: entries, into: into, progress: progress)

        for (name, data) in files {
            XCTAssertEqual(try Data(contentsOf: into.appendingPathComponent(name)), data, name)
        }
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        XCTAssertEqual(retries, [1, 2, 1])
        XCTAssertEqual(resumed, 2)
        XCTAssertEqual(source.reopened, 3)
        XCTAssertEqual(server.opens, 4)
        // Each failed read was read again, from where it was, and the
        // archive was read once, in order.
        let chunk = UInt64(CartoucheSequentialReader.chunk)
        let first = try XCTUnwrap(entries.filter { !$0.isDirectory }.map(\.localHeaderOffset).min())
        XCTAssertEqual(server.failed, [first + chunk, first + chunk, first + 2 * chunk])
        let reads = server.served.count - before
        XCTAssertGreaterThanOrEqual(reads, 3)
        XCTAssertEqual(Array(server.served[before...]), (0 ..< UInt64(reads)).map { first + $0 * chunk })
        // The dropped connections are closed, without being waited for.
        try await waitUntil { server.closes == 3 }
        await source.close()
        XCTAssertEqual(server.closes, 4)
    }

    func testAConnectionThatStopsAnsweringIsCutAndMadeAgain() async throws {
        let data = noise(3 << 20, seed: 5)
        let server = FlakyServer(data, patience: 50_000_000)
        let source = try await CartoucheResumingSource.open(pauses: [0, 0]) { try await server.open() }
        var why: [Error] = []
        source.onRetry = { _, error in why.append(error) }
        server.plan([.silence])
        let started = Date()
        let read = try await source.read(at: 1_000, count: 5_000)
        XCTAssertEqual(read, data.subdata(in: 1_000 ..< 6_000))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(why.count, 1)
        XCTAssertTrue(why.first is CartoucheDeadline.Passed, "\(why)")
        XCTAssertEqual(source.reopened, 1)
    }

    func testGivesUpOnceThePausesRunOut() async throws {
        let server = FlakyServer(noise(10_000, seed: 1))
        let source = try await CartoucheResumingSource.open(pauses: [0, 0, 0]) { try await server.open() }
        var retries: [Int] = []
        source.onRetry = { attempt, _ in retries.append(attempt) }
        server.plan(Array(repeating: .drop, count: 10))
        do {
            _ = try await source.read(at: 0, count: 100)
            XCTFail("a read went on with no connection")
        } catch let lost as CartoucheResumingSource.Lost {
            XCTAssertEqual(lost.attempts, 3)
            XCTAssertTrue(lost.last is FlakyServer.Dropped, "\(lost.last)")
        }
        XCTAssertEqual(retries, [1, 2, 3])
        XCTAssertEqual(server.opens, 4)
    }

    func testRefusedConnectionsCountAsAttempts() async throws {
        let data = noise(4_096, seed: 2)
        let server = FlakyServer(data)
        let source = try await CartoucheResumingSource.open(pauses: [0, 0, 0]) { try await server.open() }
        var why: [Error] = []
        source.onRetry = { _, error in why.append(error) }
        server.plan([.drop])
        server.refuse(2)
        let read = try await source.read(at: 100, count: 50)
        XCTAssertEqual(read, data.subdata(in: 100 ..< 150))
        XCTAssertEqual(why.count, 3)
        XCTAssertTrue(why[0] is FlakyServer.Dropped)
        XCTAssertTrue(why[1] is FlakyServer.Refused)
        XCTAssertTrue(why[2] is FlakyServer.Refused)
        XCTAssertEqual(server.opens, 4)
        XCTAssertEqual(source.reopened, 1)
    }

    func testTheFirstConnectionIsNotRetried() async throws {
        let server = FlakyServer(noise(100, seed: 3))
        server.refuse(1)
        do {
            _ = try await CartoucheResumingSource.open(pauses: [0, 0]) { try await server.open() }
            XCTFail("a refused connection was taken")
        } catch is FlakyServer.Refused {}
        XCTAssertEqual(server.opens, 1)
    }

    func testAnotherFileInItsPlaceStopsTheRead() async throws {
        let server = FlakyServer(noise(4_096, seed: 4))
        let source = try await CartoucheResumingSource.open(pauses: [0, 0, 0]) { try await server.open() }
        server.plan([.drop])
        server.replaceFile(size: 2_048)
        do {
            _ = try await source.read(at: 0, count: 100)
            XCTFail("a read went on in another file")
        } catch let changed as CartoucheResumingSource.Changed {
            XCTAssertEqual(changed.size, 4_096)
            XCTAssertEqual(changed.now, 2_048)
        }
        XCTAssertEqual(server.opens, 2)
        try await waitUntil { server.closes == 2 }
    }

    func testCancellingEndsThePause() async throws {
        let server = FlakyServer(noise(1_000, seed: 6))
        let source = try await CartoucheResumingSource.open(pauses: [60_000_000_000]) { try await server.open() }
        server.plan([.drop])
        let reading = Task { try await source.read(at: 0, count: 10) }
        try await waitUntil { server.failed.count == 1 }
        let cancelled = Date()
        reading.cancel()
        do {
            _ = try await reading.value
            XCTFail("a cancelled read went on")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        XCTAssertEqual(server.opens, 1)
    }

    func testADeadlineLetsATimelyAnswerThrough() async throws {
        let cut = CartoucheFlag()
        let answer = try await CartoucheDeadline.within(60_000_000, cut: { cut.raise() }) { 42 }
        XCTAssertEqual(answer, 42)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(cut.isRaised)
    }

    func testADeadlinePassesOnTheFailureOfItsBody() async throws {
        do {
            _ = try await CartoucheDeadline.within(60_000_000_000, cut: {}) { () async throws -> Int in
                throw FlakyServer.Refused()
            }
            XCTFail("a failure was lost")
        } catch is FlakyServer.Refused {}
    }

    // MARK: One request at a time (CartoucheRequestQueue)

    /// Requests made at the same moment on one connection, as an SMB
    /// connection's can be: never two under way at once.
    func testRequestsMadeAtOnceRunOneAtATime() async throws {
        let queue = CartoucheRequestQueue()
        let turns = Turns()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 64 {
                group.addTask {
                    try await queue.run {
                        turns.begin("\(index)")
                        // A request waits for the server's answer.
                        try await Task.sleep(nanoseconds: 1_000_000)
                        turns.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(turns.order.count, 64)
        XCTAssertEqual(turns.most, 1, "requests were under way at the same time")
    }

    /// The close of a file that SMBSource's deinit queues, while a request
    /// is under way, comes before the request made just after it, though
    /// the deinit does not wait for it: the connection could not remove or
    /// replace a file still open on it.
    func testTheCloseADeinitQueuesComesBeforeTheNextRequest() async throws {
        let queue = CartoucheRequestQueue()
        let turns = Turns()
        let reading = Task {
            try await queue.run {
                turns.begin("read")
                try await Task.sleep(nanoseconds: 50_000_000)
                turns.end()
            }
        }
        try await waitUntil { turns.order == ["read"] }
        queue.queue {
            turns.begin("close")
            try await Task.sleep(nanoseconds: 20_000_000)
            turns.end()
        }
        try await queue.run {
            turns.begin("list")
            turns.end()
        }
        try await reading.value
        XCTAssertEqual(turns.order, ["read", "close", "list"])
        XCTAssertEqual(turns.most, 1)
    }

    /// A request that fails ends its turn too, as one whose connection
    /// was cut does, and so does a queued one.
    func testAFailedRequestLetsTheNextOneThrough() async throws {
        let queue = CartoucheRequestQueue()
        do {
            try await queue.run { throw FlakyServer.Dropped() }
            XCTFail("a failure was lost")
        } catch is FlakyServer.Dropped {}
        queue.queue { throw FlakyServer.Dropped() }
        // Waited for a few seconds at most: a turn that a failure kept
        // would keep this request waiting for good.
        let answered = CartoucheFlag()
        let next = Task {
            if try await queue.run({ 42 }) == 42 { answered.raise() }
        }
        try await waitUntil { answered.isRaised }
        next.cancel()
    }
}

/// What the requests of a test did, in the order they started, and how
/// many were under way at once, at most.
private final class Turns: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var mostRunning = 0
    private var started: [String] = []

    func begin(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        running += 1
        mostRunning = max(mostRunning, running)
        started.append(name)
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        running -= 1
    }

    var most: Int {
        lock.lock()
        defer { lock.unlock() }
        return mostRunning
    }

    var order: [String] {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}
