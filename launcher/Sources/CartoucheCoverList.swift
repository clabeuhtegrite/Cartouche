//
//  CartoucheCoverList.swift
//  Cartouche
//
//  The games' covers as covers.json lists them: IGDB's game and image IDs,
//  never an address (catalog/README.md). Cartouche carries the list of its
//  catalog as it was when it was built (CartoucheCatalog/covers.json), and
//  reads a newer one every day, which the Live covers workflow keeps on the
//  branch live-covers (CartoucheCoversURL in its Info.plist, from
//  app/config.env): the covers of the games nxnative added since, and of
//  those IGDB had none for yet. Foundation only, so that swift test checks
//  it on a Mac (launcher/Package.swift).
//

import Foundation

/// A game's official cover and artwork on IGDB, and its genre there
/// (covers.json).
struct CartoucheCover: Decodable, Hashable {
    let titleId: String
    /// IGDB's ID of the game.
    let igdb: Int
    /// The image ID of its cover, upright.
    let cover: String
    /// The image ID of an artwork, wide.
    let artwork: String?
    /// One of Cartouche's genres (CartoucheCoverList.genres), from IGDB's,
    /// for a game whose nxnative profile says none. Lists before November
    /// 2026 have none.
    var genre: String? = nil
}

/// Reading a covers.json, and putting a newer list over the one the app
/// carries.
enum CartoucheCoverList {
    /// The most a covers.json may weigh: about forty times what it does with
    /// nxnative's 146 games.
    static let maximumSize = 1 << 20

    /// Cartouche's genres, those of nxnative's profiles (CartoucheText.genre).
    static let genres: Set<String> = ["action", "adventure", "rpg", "puzzle", "strategy", "simulation", "racing", "sports",
                                      "board", "card", "family", "music"]

    /// The covers DATA lists, by title ID, or nil unless it is a covers.json:
    /// schema 1, from IGDB. A cover that is not as catalog/schema/covers.schema.json
    /// has it is left out, such as one whose image ID is anything but letters
    /// and digits, and so are an artwork that is not and a genre Cartouche
    /// does not know; the first cover of a title ID counts.
    static func covers(in data: Data) -> [String: CartoucheCover]? {
        guard data.count <= maximumSize, let list = try? JSONDecoder().decode(List.self, from: data),
              list.schema == 1, list.source == "IGDB" else { return nil }
        var covers: [String: CartoucheCover] = [:]
        for record in list.covers {
            guard let cover = record.cover, covers[cover.titleId] == nil, isTitleId(cover.titleId), cover.igdb > 0,
                  isImageId(cover.cover) else { continue }
            let artwork = cover.artwork.flatMap { isImageId($0) ? $0 : nil }
            let genre = cover.genre.flatMap { genres.contains($0) ? $0 : nil }
            covers[cover.titleId] = CartoucheCover(titleId: cover.titleId, igdb: cover.igdb, cover: cover.cover, artwork: artwork,
                                                   genre: genre)
        }
        return covers
    }

    /// NEWER's covers over CARRIED's: a game keeps the cover the app carries
    /// when the newer list has none for it.
    static func merged(_ carried: [String: CartoucheCover], with newer: [String: CartoucheCover]) -> [String: CartoucheCover] {
        carried.merging(newer) { _, newer in newer }
    }

    /// An IGDB image ID: one to forty letters and digits, since it goes into
    /// a file name and an address.
    static func isImageId(_ id: String) -> Bool {
        (1 ... 40).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
        }
    }

    /// A title ID: sixteen hexadecimal digits, in capitals.
    static func isTitleId(_ id: String) -> Bool {
        id.utf8.count == 16 && id.utf8.allSatisfy { byte in (48 ... 57).contains(byte) || (65 ... 70).contains(byte) }
    }

    private struct List: Decodable {
        let schema: Int
        let source: String
        let covers: [Record]
    }

    /// One cover of the list, or nil when it does not read as one, so that
    /// the others still count.
    private struct Record: Decodable {
        let cover: CartoucheCover?

        init(from decoder: Decoder) throws {
            cover = try? CartoucheCover(from: decoder)
        }
    }
}

/// The newer covers: Cartouche reads them from CartoucheCoversURL when it
/// opens and when it comes back, once those it read last are six hours old,
/// and keeps them in its caches for the next time it opens, offline
/// included. A list that cannot be read, or is not a covers.json, changes
/// nothing, and Cartouche tries again an hour later.
@MainActor
final class CartoucheLiveCovers {
    static let shared = CartoucheLiveCovers(
        url: (Bundle.main.object(forInfoDictionaryKey: "CartoucheCoversURL") as? String).flatMap(URL.init(string:)),
        file: CartoucheLiveCovers.defaultFile)

    /// How long the covers read stay fresh: the workflow runs once a day.
    static let freshness: TimeInterval = 6 * 3600
    /// How long Cartouche waits after a read that failed.
    static let retryDelay: TimeInterval = 3600

    typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let url: URL?
    private let file: URL
    private let load: Load
    private var lastTry: Date?
    private var reading: Task<Void, Never>?

    /// Reads URL, an https address, and keeps what it read in FILE. LOAD
    /// stands in for URLSession in the tests.
    init(url: URL?, file: URL, load: @escaping Load = { try await URLSession.shared.data(for: $0) }) {
        self.url = url?.scheme == "https" ? url : nil
        self.file = file
        self.load = load
    }

    /// Where Cartouche keeps the covers it read: in its caches, which iOS
    /// may empty, as it does the images.
    nonisolated static var defaultFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartouche/LiveCovers.json")
    }

    /// The covers kept in FILE the last time, by title ID; none when there
    /// is no such file.
    nonisolated static func kept(at file: URL) -> [String: CartoucheCover] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return CartoucheCoverList.covers(in: data) ?? [:]
    }

    /// Reads the covers, unless those kept are fresh, a read is under way or
    /// one failed less than an hour ago; keeps them and gives them to SHOW.
    /// Returns the read, for the tests to wait for.
    @discardableResult
    func refreshIfDue(now: Date = Date(), show: @escaping @MainActor ([String: CartoucheCover]) -> Void) -> Task<Void, Never>? {
        guard let url, reading == nil else { return nil }
        if let lastTry, now.timeIntervalSince(lastTry) < Self.retryDelay { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        if let kept = attributes?[.modificationDate] as? Date, kept <= now, now.timeIntervalSince(kept) < Self.freshness {
            return nil
        }
        lastTry = now
        let file = file
        let load = load
        let task = Task {
            defer { self.reading = nil }
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            guard let answer = try? await load(request), (answer.1 as? HTTPURLResponse)?.statusCode == 200,
                  let covers = CartoucheCoverList.covers(in: answer.0) else { return }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try answer.0.write(to: file, options: .atomic)
            } catch {
                NSLog("[Cartouche] cannot keep the covers: %@", String(describing: error))
            }
            self.lastTry = nil
            show(covers)
        }
        reading = task
        return task
    }
}
