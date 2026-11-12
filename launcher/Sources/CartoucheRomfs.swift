//
//  CartoucheRomfs.swift
//  Cartouche
//
//  A game nxnative built with its game files apart (--romfs separate, or
//  DM_COPY_ROMFS=NO), as players do for the big ones: its IPA holds the
//  app without them, with one line, <App>/romfs.id, that names the image
//  they come in, romfs.img, which players keep beside the IPA. nxnative's
//  own way to put that image on the iPhone needs a Mac and a cable
//  (scripts/push_romfs.sh, into the game's Documents). Cartouche finds it
//  beside the IPA in the games folder, in any letter case (nxnative's
//  extraction writes it as RomFS.img, and a copy through the Finder or
//  Files keeps that name), and installs the two together: the image goes
//  inside the game's app, where a game built whole carries it, and where
//  nxnative reads it too (dm/ios/Sources/main.m, romfs_locate). A new
//  build of the game keeps the image the installed one holds, when it is
//  still the one it needs, so that gigabytes are not copied again.
//
//  The image is the right one when its size and the hash of its header and
//  index match romfs.id (dm/host/romfs_identity.h), as nxnative and
//  Cartouche Builder check it (builder/cartouche_builder/romfs.py): a few
//  megabytes read, never the game's data, so that an image of 20 GB on a
//  NAS is checked in a moment.
//

import Foundation

/// An image of a game's files, as romfs.id names it: its size and the hash
/// of its header and index decide; the game's title ID and version only
/// name it.
struct CartoucheRomfsIdentity: Codable, Hashable, Sendable {
    let size: UInt64
    /// FNV-1a 64 over the image's header and index, in 16 lowercase hex
    /// digits, as romfs.id writes it.
    let index: String
    var title: String?
    var version: String?

    init(size: UInt64, index: UInt64, title: String? = nil, version: String? = nil) {
        self.size = size
        let hex = String(index, radix: 16)
        self.index = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        self.title = title
        self.version = version
    }

    /// romfs.id's line, "DMROMFSID1 title=<title ID> version=<text>
    /// build=<text> size=<bytes> index=<16 hex digits>"; nil without its
    /// first word, a size and an index.
    init?(line text: String) {
        // By Character: "\r\n" is one, a newline that is neither "\n" nor
        // "\r", so a line ending with it is cut on isNewline.
        let line = text.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first ?? ""
        let words = line.split(whereSeparator: \.isWhitespace)
        guard line.hasPrefix("DMROMFSID1"), words.first == "DMROMFSID1" else { return nil }
        var size: UInt64?
        var index: UInt64?
        var title: String?
        var version: String?
        for word in words.dropFirst() {
            guard let equals = word.firstIndex(of: "=") else { continue }
            let value = word[word.index(after: equals)...]
            switch word[..<equals] {
            case "size":
                guard let number = UInt64(value) else { return nil }
                size = number
            case "index":
                guard let number = UInt64(value, radix: 16) else { return nil }
                index = number
            case "title":
                title = value.isEmpty ? nil : String(value)
            case "version":
                version = value.isEmpty ? nil : String(value)
            default:
                continue
            }
        }
        guard let size, let index else { return nil }
        self.init(size: size, index: index, title: title, version: version)
    }

    /// Whether IMAGE, as read from a file, is the image this one names.
    func isMet(by image: CartoucheRomfsIdentity) -> Bool {
        size == image.size && index == image.index
    }
}

/// An image of a game's files in the games folder.
struct CartoucheRomfsImage: Hashable, Sendable {
    /// Its path on the games folder's server, and the folder it is in.
    let path: String
    let folder: String
    let size: UInt64
}

/// An IPA of the games folder built without its game files: the folder it
/// is in, and the size of the image it needs.
struct CartoucheRomfsNeed: Hashable, Sendable {
    let path: String
    let folder: String
    let size: UInt64
}

enum CartoucheRomfs {
    /// How much is read at once: the index of a large game takes a few.
    static let chunk = 8 << 20

    /// Where a game built whole carries its image, in its app.
    static let bundledName = "romfs.img"

    /// Whether NAME is an image of a game's files: romfs.img in any letter
    /// case, as nxnative reads it in Documents, or a name ending so, as
    /// "Zelda.romfs.img"; never a hidden file, as the "._" a drive that is
    /// not a Mac's keeps beside each file.
    static func isImageName(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.lowercased().hasSuffix("romfs.img")
    }

    // MARK: The IPA

    /// The app's folder in an IPA, "Payload/<name>.app/", from its
    /// Info.plist entry.
    static func appFolder(in entries: [CartoucheZipEntry]) -> String? {
        for entry in entries {
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"), parts[2] == "Info.plist" {
                return "Payload/\(parts[1])/"
            }
        }
        return nil
    }

    /// The romfs.id entry of an IPA whose app holds no game files; nil for
    /// one that holds them, as an image or a folder, or that says nothing of
    /// them.
    static func identityEntry(in entries: [CartoucheZipEntry]) -> CartoucheZipEntry? {
        guard let app = appFolder(in: entries) else { return nil }
        var identity: CartoucheZipEntry?
        for entry in entries where entry.name.hasPrefix(app) {
            let inside = entry.name.dropFirst(app.count)
            if inside == bundledName || inside == "romfs" || inside.hasPrefix("romfs/") { return nil }
            if inside == "romfs.id" { identity = entry }
        }
        return identity
    }

    /// The image an IPA built without its game files needs, from its
    /// romfs.id; nil for an IPA that holds them. Throws when romfs.id cannot
    /// be read.
    static func neededIdentity(ofIPA source: CartoucheByteSource, entries: [CartoucheZipEntry]) async throws -> CartoucheRomfsIdentity? {
        guard let entry = identityEntry(in: entries) else { return nil }
        let data = try await CartoucheZip.data(of: entry, in: source, limit: 4096)
        guard let text = String(data: data, encoding: .utf8), let identity = CartoucheRomfsIdentity(line: text) else {
            throw CartoucheZipError("\(entry.name) cannot be read")
        }
        return identity
    }

    // MARK: The image

    /// What the image in SOURCE is: its size and the hash of its header and
    /// index, as nxnative computes them (romfs_id_of_image); nil for a file
    /// that is no complete image (DMROMFS1), as one cut off on its way.
    static func identity(ofImage source: CartoucheByteSource) async throws -> CartoucheRomfsIdentity? {
        let size = source.size
        guard size >= 32 else { return nil }
        let header = try await source.read(at: 0, count: 32)
        guard header.count == 32, header.prefix(8) == Data("DMROMFS1".utf8) else { return nil }
        let indexAt = littleEndian(header, at: 8)
        let indexSize = littleEndian(header, at: 16)
        // As many entries as the index holds, of 24 bytes each at least.
        let count = littleEndian(header, at: 24)
        guard indexAt >= 32, indexAt <= size, indexSize == size - indexAt,
              count > 0, count <= 0xFFFF_FFFF, count <= indexSize / 24 else { return nil }
        var hash = CartoucheWordHash()
        hash.mix(header)
        var at = indexAt
        while at < size {
            try Task.checkCancellation()
            let block = try await source.read(at: at, count: Int(min(UInt64(chunk), size - at)))
            guard !block.isEmpty else { return nil }
            hash.mix(block)
            at += UInt64(block.count)
        }
        return CartoucheRomfsIdentity(size: size, index: hash.finish())
    }

    /// Copies the image in SOURCE to the file at URL, in large reads, as the
    /// storage serves best, then checks the copy against NEEDED. PROGRESS
    /// counts the bytes written; cancelling the task stops it.
    static func copy(_ source: CartoucheByteSource, to url: URL, needed: CartoucheRomfsIdentity,
                     progress: Progress? = nil) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url)
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CartoucheZipError("cannot write \(url.lastPathComponent)")
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            progress?.totalUnitCount = Int64(clamping: source.size)
            var at: UInt64 = 0
            while at < source.size {
                try Task.checkCancellation()
                let block = try await source.read(at: at, count: Int(min(UInt64(chunk), source.size - at)))
                guard !block.isEmpty else { throw CartoucheZipError("\(url.lastPathComponent) ended early") }
                // Each block goes at once, so that a large image does not
                // keep them all in memory (FileHandle.cartoucheRead).
                try autoreleasepool { try handle.write(contentsOf: block) }
                at += UInt64(block.count)
                progress?.completedUnitCount = Int64(clamping: at)
            }
            try handle.synchronize()
            let copied = try CartoucheFileSource(url)
            guard let identity = try await identity(ofImage: copied), needed.isMet(by: identity) else {
                throw CartoucheZipError("\(url.lastPathComponent) is not whole once copied")
            }
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    /// The image in a game's app or Documents folder, in any letter case,
    /// romfs.img itself first, as nxnative looks for it.
    static func image(in folder: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let found = names.filter { !$0.hasPrefix(".") && $0.lowercased() == bundledName }
            .sorted { a, b in a == bundledName || (b != bundledName && a < b) }
        return found.first.map { folder.appendingPathComponent($0) }
    }

    // MARK: The games folder

    /// Which image of the games folder each IPA built without its game
    /// files takes: one of the size it needs in its own folder, else one of
    /// that size elsewhere in the games folder, "romfs.img" itself before
    /// another name. An image may serve two IPAs of the same game. LOOSE:
    /// the images no IPA takes, by path.
    static func pair(_ needs: [CartoucheRomfsNeed], with images: [CartoucheRomfsImage])
        -> (taken: [String: CartoucheRomfsImage], loose: [CartoucheRomfsImage]) {
        let ordered = images.sorted { a, b in
            let aExact = name(of: a.path) == bundledName
            let bExact = name(of: b.path) == bundledName
            if aExact != bExact { return aExact }
            return a.path < b.path
        }
        var taken: [String: CartoucheRomfsImage] = [:]
        var used = Set<String>()
        for need in needs {
            let fits = ordered.filter { $0.size == need.size }
            guard let image = fits.first(where: { $0.folder == need.folder }) ?? fits.first else { continue }
            taken[need.path] = image
            used.insert(image.path)
        }
        return (taken, ordered.filter { !used.contains($0.path) })
    }

    /// The last part of a path on the player's server.
    private static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func littleEndian(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in data[data.startIndex + offset ..< data.startIndex + offset + 8].reversed() {
            value = value << 8 | UInt64(byte)
        }
        return value
    }
}

/// FNV-1a 64 over little-endian 64-bit words, the last one completed with
/// zeros, as romfs_identity.h hashes an image's header and index: fed in
/// blocks of any size.
struct CartoucheWordHash {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325
    /// The bytes of a word not whole yet.
    private var carry: [UInt8] = []

    mutating func mix(_ data: Data) {
        var start = data.startIndex
        if !carry.isEmpty {
            let taken = min(8 - carry.count, data.count)
            carry += data[start ..< start + taken]
            start += taken
            guard carry.count == 8 else { return }
            mixWord(carry[...])
            carry.removeAll(keepingCapacity: true)
        }
        let whole = (data.endIndex - start) / 8 * 8
        data[start ..< start + whole].withUnsafeBytes { bytes in
            var at = 0
            while at < whole {
                var word: UInt64 = 0
                for shift in stride(from: 7, through: 0, by: -1) {
                    word = word << 8 | UInt64(bytes[at + shift])
                }
                value = (value ^ word) &* 0x0000_0100_0000_01B3
                at += 8
            }
        }
        carry += data[(start + whole)...]
    }

    /// The hash, once the last word is completed with zeros.
    mutating func finish() -> UInt64 {
        if !carry.isEmpty {
            carry += [UInt8](repeating: 0, count: 8 - carry.count)
            mixWord(carry[...])
            carry.removeAll()
        }
        return value
    }

    private mutating func mixWord(_ bytes: ArraySlice<UInt8>) {
        var word: UInt64 = 0
        for byte in bytes.reversed() {
            word = word << 8 | UInt64(byte)
        }
        value = (value ^ word) &* 0x0000_0100_0000_01B3
    }
}
