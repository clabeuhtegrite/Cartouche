//
//  StorageServers.swift
//  CartoucheStorageTests
//
//  The servers servers.sh started, as its servers.json says, and the test
//  IPAs it put on each, as make_ipas.py's fixtures.json says.
//

import CryptoKit
import Darwin
import Foundation
import XCTest

/// servers.json: where each server is, its accounts, and what the games
/// folder holds on each.
struct StorageServers: Decodable {
    struct Account: Decodable {
        let host: String
        let port: Int
        let user: String
        let password: String
    }

    struct SMB: Decodable {
        let account: Account
        /// The shared folder the account writes, the one it can only read,
        /// and the one guests read.
        let share: String
        let readOnlyShare: String
        let guestShare: String
        /// Where the shared folder is on this Mac.
        let sharePath: String
    }

    struct S3: Decodable {
        /// As the player types it: http://127.0.0.1:9000.
        let address: String
        let bucket: String
        /// The server's region, which it expects requests to be signed for.
        let region: String
        let accessKey: String
        let secretKey: String
        /// Keys that can list and read the bucket, and nothing else.
        let readerAccessKey: String
        let readerSecretKey: String
    }

    struct FTP: Decodable {
        let account: Account
        /// An account that can only read.
        let reader: String
        let readerPassword: String
        /// Whether the server lists folders with MLSD.
        let mlsd: Bool
        /// Its root on this Mac, and its log, which has every command.
        let rootPath: String
        let log: String
    }

    struct SFTP: Decodable {
        let account: Account
        /// The server's key, as OpenSSH writes it.
        let hostKey: String
        /// Another key, which a server Cartouche does not know would show.
        let otherKey: String
        /// The account's home, where the server opens it, on this Mac, and
        /// the server's log.
        let home: String
        let log: String
    }

    /// In every server's root: the games folder, with the test IPAs, a
    /// folder of older ones and a hidden file; and a folder the player's
    /// account can only read, with the small IPA.
    let games: String
    let readOnlyFolder: String
    let smallName: String
    let bigName: String?
    let olderFolder: String
    let hiddenName: String
    let fixtures: String

    let smb: SMB
    let s3: S3
    let ftp: FTP
    let ftpList: FTP
    let sftp: SFTP

    static let shared: StorageServers? = {
        guard let path = ProcessInfo.processInfo.environment["CARTOUCHE_STORAGE_SERVERS"], !path.isEmpty else {
            return nil
        }
        do {
            return try JSONDecoder().decode(StorageServers.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            fatalError("cannot read \(path): \(error)")
        }
    }()
}

/// fixtures.json: what each test IPA holds.
struct StorageFixtures: Decodable {
    struct Entry: Decodable {
        let name: String
        let size: UInt64
        let method: Int
        let offset: UInt64
    }

    struct File: Decodable {
        let size: UInt64?
        let sha256: String?
        let mode: UInt32?
        let link: String?
        let folder: Bool?
    }

    struct Fixture: Decodable {
        /// The IPA, and the app's folder it was packed from, on this Mac.
        let ipa: String
        let app: String
        /// Payload/<name>.app
        let bundle: String
        let size: UInt64
        let sha256: String?
        let info: [String: String]
        let entries: [Entry]
        /// By path in the app's folder.
        let files: [String: File]
    }

    let small: Fixture
    let big: Fixture?

    static func load(_ servers: StorageServers) throws -> StorageFixtures {
        try JSONDecoder().decode(StorageFixtures.self, from: Data(contentsOf: URL(fileURLWithPath: servers.fixtures)))
    }
}

// MARK: Helpers

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256(file url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Bytes that do not deflate.
func noise(_ count: Int, seed: UInt64) -> Data {
    var state = seed
    var data = Data(count: count)
    data.withUnsafeMutableBytes { raw in
        for index in 0 ..< count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            raw[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
    }
    return data
}

/// The memory the system counts against the process, as iOS does before it
/// closes an app that takes too much.
func physicalFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}

/// The highest footprint while it runs, read every 50 ms.
final class FootprintWatch {
    private let queue = DispatchQueue(label: "Footprint watch")
    private let timer: DispatchSourceTimer
    private var highest: Int64 = 0
    let start = physicalFootprint()

    init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.highest = max(self.highest, physicalFootprint())
        }
        timer.resume()
    }

    /// How far above its start the footprint went.
    func stop() -> Int64 {
        timer.cancel()
        return queue.sync { max(highest, physicalFootprint()) - start }
    }
}

/// The error BODY throws, or nil when it throws none.
func thrownError(_ body: () async throws -> Void) async -> Error? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

func megabytes(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_000_000)
}

/// The size of the file at PATH: where a log is, before a test reads what
/// it adds.
func fileSize(_ path: String) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
}

/// What the log at PATH has past MARK.
func logged(in path: String, since mark: UInt64) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seek(toOffset: mark)
    return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
}

/// The room left on the disk that holds PATH, as statfs says, as a server
/// on this Mac counts it.
func statfsFreeSpace(_ path: String) -> UInt64? {
    var info = statfs()
    guard statfs(path, &info) == 0 else { return nil }
    return UInt64(info.f_bavail) * UInt64(info.f_bsize)
}
