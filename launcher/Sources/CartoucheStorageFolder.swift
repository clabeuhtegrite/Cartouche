//
//  CartoucheStorageFolder.swift
//  Cartouche
//
//  A folder the player picked once in the Files picker: on the iPhone, on
//  iCloud Drive, on a disk plugged into it, or in another app's storage.
//  iOS lets Cartouche keep a bookmark of it and reach it again after a
//  restart. A file iCloud Drive has not downloaded is fetched as a whole
//  before Cartouche can read it.
//

import Foundation

final class CartoucheFolder: CartoucheRemote {
    private let root: URL
    private let accessing: Bool

    init(_ server: CartoucheStorageServer) throws {
        guard let bookmark = server.bookmark else { throw CartoucheStorageError(.folderGone, CartoucheText.storageFolderGone) }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw CartoucheStorageError(.folderGone, CartoucheText.storageFolderGone)
        }
        root = url
        accessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if accessing { root.stopAccessingSecurityScopedResource() }
    }

    /// A bookmark of the folder the player just picked.
    static func bookmark(of url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func url(_ path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    /// Runs BODY on the file at PATH as the file's coordinator allows,
    /// which has iCloud Drive download it first.
    private func coordinated<T>(reading path: String, _ body: (URL) throws -> T) throws -> T {
        var failure: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url(path), options: [], error: &failure) { url in
            result = Result { try body(url) }
        }
        if let failure { throw failure }
        guard let result else { throw CartoucheStorageError(.folderGone, CartoucheText.storageFolderGone) }
        return try result.get()
    }

    func list(_ path: String) async throws -> [CartoucheRemoteItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let found = try FileManager.default.contentsOfDirectory(at: url(path), includingPropertiesForKeys: keys,
                                                                options: [.skipsHiddenFiles])
        return found.compactMap { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            var name = item.lastPathComponent
            // An older iCloud Drive lists a file it has not downloaded as
            // ".name.icloud".
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            return CartoucheRemoteItem(name: name, isFolder: values?.isDirectory ?? false,
                                       size: UInt64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
        }
    }

    /// Whether the file at PATH is on this iPhone already, not only listed
    /// by iCloud Drive.
    func isDownloaded(_ path: String) -> Bool {
        let values = try? url(path).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return true }
        return values?.ubiquitousItemDownloadingStatus == .current
    }

    func open(_ path: String) async throws -> CartoucheByteSource {
        try coordinated(reading: path) { try CartoucheFileSource($0) }
    }

    func create(_ path: String, size: UInt64?) async throws -> CartoucheRemoteUpload {
        let partial = url(path + ".partial")
        try? FileManager.default.removeItem(at: partial)
        return try FolderUpload(partial: partial, target: url(path))
    }

    func makeFolder(_ path: String) async throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    func delete(_ path: String) async throws {
        var failure: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url(path), options: .forDeleting, error: &failure) { url in
            do { try FileManager.default.removeItem(at: url) } catch { thrown = error }
        }
        if let error = failure ?? thrown { throw error }
    }

    func freeSpace() async throws -> UInt64? {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
    }

    var isReadOnly: Bool { false }

    func canWrite(_ path: String) async throws -> Bool {
        FileManager.default.isWritableFile(atPath: url(path).path)
    }

    func disconnect() async {}
}

private final class FolderUpload: CartoucheRemoteUpload {
    private let partial: URL
    private let target: URL
    private let sink: CartoucheFileSink

    init(partial: URL, target: URL) throws {
        self.partial = partial
        self.target = target
        sink = try CartoucheFileSink(partial)
    }

    func write(_ data: Data) async throws {
        try await sink.write(data)
    }

    func finish() async throws {
        try sink.close()
        var failure: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forReplacing, error: &failure) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
                } else {
                    try FileManager.default.moveItem(at: partial, to: url)
                }
            } catch {
                thrown = error
            }
        }
        if let error = failure ?? thrown { throw error }
    }

    func cancel() async {
        try? sink.close()
        try? FileManager.default.removeItem(at: partial)
    }
}
