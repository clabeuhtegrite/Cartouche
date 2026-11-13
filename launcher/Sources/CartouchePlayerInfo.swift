//
//  CartouchePlayerInfo.swift
//  Cartouche
//
//  What the player says of one of their games, on its sheet (Edit the
//  game's info, CartoucheGameInfoView): its name, its platform, its genre,
//  its summary and a cover of their own, from Photos or Files, over what
//  Cartouche has. Kept on this iPhone only, in Application Support/Cartouche/GameInfo:
//  info.json, and each cover as a JPEG file of its own, no larger than
//  Cartouche shows it and without the photo's metadata. Foundation and
//  ImageIO only, so that swift test checks it on a Mac
//  (launcher/Package.swift).
//

import Foundation
import ImageIO

/// What the player says of one of their games; nil where Cartouche finds
/// it by itself.
struct CartouchePlayerInfo: Codable, Hashable {
    var name: String? = nil
    /// switch or switch2.
    var platform: String? = nil
    /// One of Cartouche's genres (CartoucheCoverList.genres).
    var genre: String? = nil
    /// The file of the player's cover, in the store's folder.
    var cover: String? = nil
    /// What the player writes of the game, in place of IGDB's summary.
    var summary: String? = nil

    var isEmpty: Bool { name == nil && platform == nil && genre == nil && cover == nil && summary == nil }

    /// The info as Cartouche keeps it: a name without the spaces around it
    /// and at most `longestName` characters long, a platform and a genre
    /// Cartouche knows, a cover file named as the store names them, and a
    /// summary as Cartouche shows IGDB's (CartoucheCoverList.summary(_:));
    /// nil for what is not.
    var checked: CartouchePlayerInfo {
        var info = CartouchePlayerInfo()
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            info.name = String(name.prefix(Self.longestName))
        }
        info.platform = platform.flatMap { CartoucheGameWanted.platforms.contains($0) ? $0 : nil }
        info.genre = genre.flatMap { CartoucheCoverList.genres.contains($0) ? $0 : nil }
        info.cover = cover.flatMap { CartouchePlayerInfoStore.isCoverFile($0) ? $0 : nil }
        info.summary = summary.flatMap(CartoucheCoverList.summary)
        return info
    }

    /// The longest name the player may give a game, in characters.
    static let longestName = 128
}

/// The player's info about their games, by the key of each game (key(...)):
/// read once, written at each change.
final class CartouchePlayerInfoStore {
    /// The longest side of a cover kept, in pixels: more than a cover takes
    /// on the largest screen.
    static let coverSide = 1400

    let folder: URL
    private(set) var all: [String: CartouchePlayerInfo]

    private var file: URL { folder.appendingPathComponent("info.json") }

    init(folder: URL) {
        self.folder = folder
        all = Self.read(folder.appendingPathComponent("info.json"))
    }

    /// Where Cartouche keeps them.
    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartouche/GameInfo", isDirectory: true)
    }

    /// The key of a game of the player's: its title ID, which an installed
    /// copy and one in the games folder share, else its bundle ID, else
    /// what the catalogue calls it.
    static func key(titleId: String?, bundleId: String?, id: String) -> String {
        if let titleId, !titleId.isEmpty { return "title:" + titleId }
        if let bundleId, !bundleId.isEmpty { return "bundle:" + bundleId.lowercased() }
        return "entry:" + id
    }

    /// A cover's file name, as set(_:cover:for:) makes them: a UUID and .jpg.
    static func isCoverFile(_ name: String) -> Bool {
        guard name.hasSuffix(".jpg") else { return false }
        return UUID(uuidString: String(name.dropLast(4))) != nil
    }

    func info(for key: String) -> CartouchePlayerInfo? {
        all[key]
    }

    /// The file of INFO's cover, when there is one.
    func coverFile(of info: CartouchePlayerInfo?) -> URL? {
        guard let name = info?.cover, Self.isCoverFile(name) else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keeps INFO for the game of KEY. COVER, the JPEG of a new cover of
    /// the player's (jpeg(from:)), takes the place of the one INFO names;
    /// a cover no longer named goes. Nil or empty INFO and no COVER forget
    /// what the player said of the game.
    func set(_ info: CartouchePlayerInfo?, cover: Data? = nil, for key: String) throws {
        var kept = (info ?? CartouchePlayerInfo()).checked
        let old = all[key]?.cover
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let cover {
            let name = UUID().uuidString + ".jpg"
            try cover.write(to: folder.appendingPathComponent(name), options: .atomic)
            kept.cover = name
        }
        var changed = all
        changed[key] = kept.isEmpty ? nil : kept
        do {
            try write(changed)
        } catch {
            if let name = kept.cover, name != old { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
            throw error
        }
        all = changed
        if let old, old != kept.cover {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
    }

    private func write(_ info: [String: CartouchePlayerInfo]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Kept(games: info)).write(to: file, options: .atomic)
    }

    private struct Kept: Codable {
        var schema = 1
        var games: [String: CartouchePlayerInfo]
    }

    private static func read(_ file: URL) -> [String: CartouchePlayerInfo] {
        guard let data = try? Data(contentsOf: file), let kept = try? JSONDecoder().decode(Kept.self, from: data),
              kept.schema == 1 else { return [:] }
        return kept.games.mapValues(\.checked).filter { !$0.value.isEmpty }
    }

    /// DATA, an image in a format iOS reads (JPEG, PNG, HEIC…), as a JPEG
    /// the right way up whose longest side is at most SIDE pixels, without
    /// its metadata, such as where a photo was taken; nil when DATA is no
    /// image.
    static func jpeg(from data: Data, side: Int = coverSide) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
