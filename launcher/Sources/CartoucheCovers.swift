//
//  CartoucheCovers.swift
//  Cartouche
//
//  The games' official covers and artworks, from IGDB (igdb.com). The
//  catalogue has IGDB's image IDs only (covers.json, written by
//  catalog/tools/igdb_covers.py, and the newer list Cartouche reads every
//  day: CartoucheCoverList); Cartouche builds the images' addresses on
//  images.igdb.com, loads each image once and keeps it in its caches
//  folder, which iOS may empty: the image is loaded again then. Until an
//  image has loaded, and for a game IGDB has none for, the views show
//  Cartouche's own drawing. A game Cartouche does not know has IGDB's
//  images by its name (CartoucheGameLookup), and the player's own cover,
//  from Photos or Files, goes over any (CartouchePlayerInfo).
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// An image of a game: one of IGDB's, or a file of the player's.
enum CartoucheArt: Hashable, Sendable {
    case igdb(String, CartoucheCoverStore.Kind)
    case file(URL)
}

extension CartoucheEntry {
    /// The game's cover: the player's own, else IGDB's, by the game's title
    /// ID or, for a game Cartouche does not know, by its name.
    var coverArt: CartoucheArt? {
        if let playerCover { return .file(playerCover) }
        if let id = cover?.cover ?? found?.cover { return .igdb(id, .cover) }
        return nil
    }

    /// What the stage shows behind the game, faintly: the player's cover,
    /// else IGDB's artwork, else its cover.
    var backdrop: CartoucheArt? {
        if let playerCover { return .file(playerCover) }
        if let id = cover?.artwork ?? found?.artwork { return .igdb(id, .artwork) }
        return coverArt
    }
}

/// Loads IGDB's images, once each while Cartouche runs, and keeps them on
/// disk; reads the player's own.
actor CartoucheCoverStore {
    static let shared = CartoucheCoverStore()

    enum Kind: String, Sendable {
        /// 528 x 748 pixels.
        case cover = "t_cover_big_2x"
        /// 889 x 500 pixels, enough for a background.
        case artwork = "t_screenshot_big"
    }

    private let memory = NSCache<NSString, UIImage>()
    private var loading: [String: Task<UIImage?, Never>] = [:]
    private let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Cartouche/Covers", isDirectory: true)
    }()

    init() {
        // What the decoded images may take in memory: about 30 covers.
        memory.totalCostLimit = 48 << 20
    }

    /// The image, from memory, from disk or from IGDB; nil when it cannot be
    /// had, such as offline before it was ever loaded.
    func image(_ id: String, kind: Kind) async -> UIImage? {
        // An IGDB image ID is letters and digits: nothing else goes into a
        // file name or an address.
        guard CartoucheCoverList.isImageId(id) else { return nil }
        let key = "\(kind.rawValue)-\(id)"
        if let image = memory.object(forKey: key as NSString) { return image }
        if let task = loading[key] { return await task.value }
        let file = folder.appendingPathComponent(key + ".jpg")
        let folder = folder
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                return await image.byPreparingForDisplay() ?? image
            }
            guard let url = URL(string: "https://images.igdb.com/igdb/image/upload/\(kind.rawValue)/\(id).jpg") else {
                return nil
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
                    return nil
                }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                return await image.byPreparingForDisplay() ?? image
            } catch {
                return nil
            }
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        remember(image, as: key)
        return image
    }

    /// The image of ART, from IGDB or from the player's file.
    func image(_ art: CartoucheArt) async -> UIImage? {
        switch art {
        case .igdb(let id, let kind):
            return await image(id, kind: kind)
        case .file(let url):
            return await image(file: url)
        }
    }

    /// The image in FILE, a cover of the player's: each file holds one
    /// cover only, a new cover going to a new file.
    func image(file: URL) async -> UIImage? {
        let key = "file-" + file.path
        if let image = memory.object(forKey: key as NSString) { return image }
        if let task = loading[key] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        remember(image, as: key)
        return image
    }

    private func remember(_ image: UIImage?, as key: String) {
        if let image, let cgImage = image.cgImage {
            memory.setObject(image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        } else if let image {
            memory.setObject(image, forKey: key as NSString)
        }
    }

    /// How many images are loading: the gallery waits for none before it
    /// says its screen has settled.
    var pending: Int { loading.count }
}

/// A game's image, IGDB's or the player's, filling its frame or whole in
/// it, over PLACEHOLDER until it has loaded or when there is none.
@available(iOS 17.0, *)
struct CartoucheCoverImage<Placeholder: View>: View {
    let art: CartoucheArt?
    /// Where the image sits when it is taller than its frame, from 0 (its
    /// top shows) to 1 (its bottom shows). A cover's title is in its upper
    /// part, and its bottom often holds a rating.
    var anchor: CGFloat = 0.35
    /// The whole image, as large as its frame allows, over a blurred copy of
    /// itself that fills the rest: a cover is never cut.
    var whole = false
    let placeholder: () -> Placeholder
    @State private var image: UIImage?

    // Written out: the private state above would make the synthesized
    // initializer private.
    init(art: CartoucheArt?, anchor: CGFloat = 0.35, whole: Bool = false,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.art = art
        self.anchor = anchor
        self.whole = whole
        self.placeholder = placeholder
    }

    var body: some View {
        GeometryReader { frame in
            ZStack {
                placeholder()
                if let image {
                    shown(image, in: frame.size)
                        .transition(.opacity)
                }
            }
            .frame(width: frame.size.width, height: frame.size.height)
        }
        .clipped()
        .task(id: art) {
            guard let art else {
                image = nil
                return
            }
            let loaded = await CartoucheCoverStore.shared.image(art)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }

    @ViewBuilder
    private func shown(_ image: UIImage, in size: CGSize) -> some View {
        if whole {
            ZStack {
                filling(image, in: size)
                    .blur(radius: max(size.width, size.height) * 0.05, opaque: true)
                    .overlay(Color.black.opacity(0.22))
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
            }
        } else {
            filling(image, in: size)
        }
    }

    /// IMAGE filling SIZE, cut at its sides or at its top and bottom.
    private func filling(_ image: UIImage, in size: CGSize) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let wide = size.height > 0 && aspect > size.width / size.height
        let width = wide ? size.height * aspect : size.width
        let height = wide ? size.height : size.width / aspect
        return Image(uiImage: image)
            .resizable()
            .frame(width: width, height: height)
            .offset(x: (size.width - width) / 2, y: (size.height - height) * anchor)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
