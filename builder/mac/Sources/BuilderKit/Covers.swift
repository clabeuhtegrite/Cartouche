//
//  Covers.swift
//  Cartouche Builder
//
//  A game's cover, as Cartouche shows it: IGDB's, found by the game's title
//  ID in the covers list (catalog/covers.json, the copy in the app, then the
//  one the live-covers branch keeps up to date), downloaded once into the
//  app's cache. A game IGDB has no cover for shows the icon the build took
//  out of it, or its initials.
//

import AppKit
import Foundation

public enum CoverSource {
    public static let liveList = URL(string: "https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/refs/heads/live-covers/covers.json")!

    public static func image(_ cover: String) -> URL? {
        URL(string: "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/\(cover).jpg")
    }

    public static var cache: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("io.github.clabeuhtegrite.cartouche-builder", isDirectory: true)
    }

    /// Title ID → IGDB cover ID, from a covers.json.
    public static func parse(_ data: Data) -> [String: String] {
        struct List: Decodable {
            struct Entry: Decodable {
                var titleId: String
                var cover: String?
            }
            var covers: [Entry]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return [:] }
        var found: [String: String] = [:]
        for entry in list.covers {
            if let cover = entry.cover, !cover.isEmpty, cover.allSatisfy({ $0.isLetter || $0.isNumber }) {
                found[entry.titleId.uppercased()] = cover
            }
        }
        return found
    }
}

/// The covers the app has shown, kept in memory, loaded once each.
@MainActor
public final class CoverStore: ObservableObject {
    public static let shared = CoverStore()

    @Published public private(set) var images: [String: NSImage] = [:]
    private var list: [String: String] = [:]
    private var listLoaded = false
    private var loading: Set<String> = []
    private var missing: Set<String> = []

    public init() {}

    public func image(_ titleID: String) -> NSImage? {
        images[titleID.uppercased()]
    }

    /// Loads the cover of TITLE_ID, or ICON (the build's icon of the game).
    public func load(_ titleID: String, icon: String? = nil) async {
        let key = titleID.uppercased()
        if images[key] != nil || loading.contains(key) || missing.contains(key) { return }
        loading.insert(key)
        defer { loading.remove(key) }
        await loadList()
        if let cover = list[key], let data = await CoverStore.fetch(cover), let image = NSImage(data: data) {
            images[key] = image
            return
        }
        if let icon, !icon.isEmpty, let image = NSImage(contentsOfFile: icon) {
            images[key] = image
            return
        }
        missing.insert(key)
    }

    /// Forgets the games that had no cover, to look again.
    public func retry() {
        missing.removeAll()
    }

    private func loadList() async {
        if listLoaded { return }
        listLoaded = true
        if let bundled = Bundle.main.url(forResource: "covers", withExtension: "json"), let data = try? Data(contentsOf: bundled) {
            list = CoverSource.parse(data)
        }
        if let data = await CoverStore.liveList() {
            list.merge(CoverSource.parse(data)) { _, live in live }
        }
    }

    /// The live list, from the cache when it is less than a day old.
    nonisolated static func liveList() async -> Data? {
        let file = CoverSource.cache.appendingPathComponent("covers.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 86400,
           let data = try? Data(contentsOf: file) {
            return data
        }
        var request = URLRequest(url: CoverSource.liveList)
        request.timeoutInterval = 20
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200, !CoverSource.parse(data).isEmpty {
            try? FileManager.default.createDirectory(at: CoverSource.cache, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        }
        return try? Data(contentsOf: file)
    }

    /// The image of COVER, from the cache or IGDB.
    nonisolated static func fetch(_ cover: String) async -> Data? {
        let folder = CoverSource.cache.appendingPathComponent("covers", isDirectory: true)
        let file = folder.appendingPathComponent("\(cover).jpg")
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        guard let url = CoverSource.image(cover) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}
