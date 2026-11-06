//
//  CartoucheCovers.swift
//  Cartouche
//
//  The games' official covers and artworks, from IGDB (igdb.com). The
//  catalogue has IGDB's image IDs only (covers.json, written by
//  catalog/tools/igdb_covers.py); Cartouche builds the images' addresses on
//  images.igdb.com, loads each image once and keeps it in its caches
//  folder, which iOS may empty: the image is loaded again then. Until an
//  image has loaded, and for a game IGDB has none for, the views show
//  Cartouche's own drawing.
//

import SwiftUI
import UIKit

/// A game's official cover and artwork on IGDB (covers.json).
struct CartoucheCover: Decodable, Hashable {
    let titleId: String
    /// IGDB's ID of the game.
    let igdb: Int
    /// The image ID of its cover, upright.
    let cover: String
    /// The image ID of an artwork, wide.
    let artwork: String?
}

/// Loads IGDB's images, once each while Cartouche runs, and keeps them on
/// disk.
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
        guard !id.isEmpty, id.count <= 40, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
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
        if let image, let cgImage = image.cgImage {
            memory.setObject(image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        } else if let image {
            memory.setObject(image, forKey: key as NSString)
        }
        return image
    }

    /// How many images are loading: the gallery waits for none before it
    /// says its screen has settled.
    var pending: Int { loading.count }
}

/// One of IGDB's images, filling its frame, over PLACEHOLDER until it has
/// loaded or when there is none.
@available(iOS 17.0, *)
struct CartoucheCoverImage<Placeholder: View>: View {
    let id: String?
    var kind: CartoucheCoverStore.Kind = .cover
    /// Where the image sits when it is taller than its frame, from 0 (its
    /// top shows) to 1 (its bottom shows). A cover's title is in its upper
    /// part, and its bottom often holds a rating.
    var anchor: CGFloat = 0.35
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { frame in
            ZStack {
                placeholder()
                if let image {
                    fitted(image, in: frame.size)
                        .transition(.opacity)
                }
            }
            .frame(width: frame.size.width, height: frame.size.height)
        }
        .clipped()
        .task(id: id) {
            guard let id else {
                image = nil
                return
            }
            let loaded = await CartoucheCoverStore.shared.image(id, kind: kind)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }

    /// IMAGE filling SIZE, cut at its sides or at its top and bottom.
    private func fitted(_ image: UIImage, in size: CGSize) -> some View {
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
