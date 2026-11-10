//
//  CartoucheResumingSource.swift
//  Cartouche
//
//  A file of the player's storage that a failed read does not end: Cartouche
//  connects to the server again, opens the file again and reads on from
//  where it stopped. A game's IPA takes minutes to come over Wi-Fi, and in
//  that time the network can drop for a moment, a NAS can restart, or iOS
//  can take the connection of a Cartouche that left the screen; the install
//  then goes on instead of failing.
//
//  CartoucheDeadline gives a request that waits for an answer a time limit,
//  for a connection that stopped answering without closing: its read would
//  otherwise wait for good, with nothing that fails and so nothing to retry.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

final class CartoucheResumingSource: CartoucheByteSource {
    /// A connection to the server with the file open on it, and how to close
    /// that connection.
    struct Opened {
        let source: CartoucheByteSource
        let close: () async -> Void
    }

    /// The file at another size once opened again: another file took its
    /// place on the server, and the archive cannot go on from where it was.
    struct Changed: LocalizedError {
        let size: UInt64
        let now: UInt64
        var errorDescription: String? { "the file changed on the server while Cartouche read it (\(size) bytes, now \(now))" }
    }

    /// The connection did not come back within the pauses: why the last
    /// attempt failed.
    struct Lost: LocalizedError {
        let attempts: Int
        let last: Error
        var errorDescription: String? { last.localizedDescription }
    }

    /// The pauses before each new attempt after a failed read, in
    /// nanoseconds: three minutes in all, time for the Wi-Fi to come back or
    /// for a NAS to restart.
    static let defaultPauses: [UInt64] = ([1, 2, 4, 8, 15, 30, 30, 30, 30, 30] as [UInt64]).map { $0 * 1_000_000_000 }

    let size: UInt64
    /// How many times the file was opened again.
    private(set) var reopened = 0
    /// Told before each pause: the attempt that follows it, from 1, and why
    /// the last one failed. Called on the reading task.
    var onRetry: ((Int, Error) -> Void)?
    /// Told when a read succeeds again after failing. Called on the reading
    /// task.
    var onResumed: (() -> Void)?

    private let reopen: () async throws -> Opened
    private let pauses: [UInt64]
    private var opened: Opened?

    private init(size: UInt64, first: Opened, pauses: [UInt64], reopen: @escaping () async throws -> Opened) {
        self.size = size
        opened = first
        self.pauses = pauses
        self.reopen = reopen
    }

    /// The file CONNECT connects to and opens, opened a first time: a
    /// failure there ends at once, since nothing was read yet.
    static func open(pauses: [UInt64] = defaultPauses,
                     _ connect: @escaping () async throws -> Opened) async throws -> CartoucheResumingSource {
        let first = try await connect()
        return CartoucheResumingSource(size: first.source.size, first: first, pauses: pauses, reopen: connect)
    }

    func read(at offset: UInt64, count: Int) async throws -> Data {
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                let data = try await connected().read(at: offset, count: count)
                if failures > 0 { onResumed?() }
                return data
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                // The connection is given up, whatever failed on it.
                drop()
                if error is Changed { throw error }
                guard failures < pauses.count else { throw Lost(attempts: failures, last: error) }
                failures += 1
                onRetry?(failures, error)
                try await Task.sleep(nanoseconds: pauses[failures - 1])
            }
        }
    }

    /// Closes the connection, once the file is read.
    func close() async {
        let closing = opened
        opened = nil
        await closing?.close()
    }

    private func connected() async throws -> CartoucheByteSource {
        if let opened { return opened.source }
        let again = try await reopen()
        guard again.source.size == size else {
            Task { await again.close() }
            throw Changed(size: size, now: again.source.size)
        }
        opened = again
        reopened += 1
        return again.source
    }

    /// Lets the connection go without waiting: one that stopped answering
    /// could keep a polite goodbye waiting for good.
    private func drop() {
        guard let closing = opened else { return }
        opened = nil
        Task { await closing.close() }
    }
}

/// A time limit for a request that waits for the server's answer.
enum CartoucheDeadline {
    /// The server did not answer in time.
    struct Passed: LocalizedError {
        let seconds: UInt64
        var errorDescription: String? { "the server did not answer for \(seconds) seconds" }
    }

    /// BODY's result, unless it takes longer than NANOSECONDS: CUT then
    /// closes the connection BODY waits on, which makes BODY fail, and this
    /// throws Passed. CUT must close it at once, without a word to the
    /// server, since the server no longer answers.
    static func within<T>(_ nanoseconds: UInt64, cut: @escaping () -> Void,
                          _ body: () async throws -> T) async throws -> T {
        let passed = CartoucheFlag()
        let timer = Task {
            try await Task.sleep(nanoseconds: nanoseconds)
            passed.raise()
            cut()
        }
        defer { timer.cancel() }
        do {
            return try await body()
        } catch {
            if passed.isRaised { throw Passed(seconds: nanoseconds / 1_000_000_000) }
            throw error
        }
    }
}

/// A flag that one thread raises and another reads.
final class CartoucheFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}
