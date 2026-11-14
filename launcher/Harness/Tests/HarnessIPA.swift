//
//  HarnessIPA.swift
//  CartoucheHarnessTests
//
//  Test IPAs, made here as nxnative and zip make real ones, never from a
//  real game: a game's bundle as nxnative builds it (an arm64 executable
//  built with the iOS SDK, its Info.plist with nxnative's keys, dm/ with
//  its settings, romfs.img, or romfs.id for a game built with its files
//  apart, the image then beside the IPA), an app that is no game, and IPAs
//  damaged the ways a player's can be: cut short by a copy that stopped, a
//  file whose bytes changed, no Payload, no app, no Info.plist. The zip
//  archives are written here byte for byte, deflated or stored, in Zip64
//  as large IPAs are, with nothing of Cartouche's own zip code.
//

import Compression
import Foundation
import XCTest
@testable import CartoucheHarness

/// A game as nxnative builds it, and what makes its IPA.
struct HarnessGame {
    /// One of the catalogue's games, by its title ID, in capitals.
    var titleId: String
    var name: String
    var version = "1.0.0"
    /// nxnative's commit, in the Info.plist (DMCommit).
    var commit = "844bf1a5ea8f6c3e2d9b0a7f1e4c5d6b7a8f9e0d"
    /// The language the IPA was built with (DMLanguage), and the game's own.
    var language = "ja"
    /// The languages of its settings screen, the first its default.
    var languages = ["ja", "fr", "en"]
    var orientations = ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
    /// Its ways on an iPad (UISupportedInterfaceOrientations~ipad): every
    /// way since nxnative's e2fadf2 (4 November 2026), with a layout for an
    /// upright screen; none before, as here unless set.
    var orientationsOnIPad: [String]?
    /// The SDK nxnative built it with: iOS 26.0.
    var sdk: UInt32 = 0x001A_0000
    var encrypted = false
    /// The size of romfs.img, the game's files.
    var romfsBytes = 192 << 10
    /// What the game's files are made from, the title ID unless set: another
    /// seed gives another image of the same size, with another index.
    var romfsSeed: String?
    /// Built with its game files apart (nxnative's --romfs separate, or
    /// DM_COPY_ROMFS=NO), as players build the big games: its app holds
    /// romfs.id, which names the image, and no romfs.img, which the player
    /// keeps beside the IPA.
    var romfsApart = false
    /// The bundle identifier, org.nxnative.<title ID> unless set.
    var bundleIdentifierOverride: String?

    var bundleIdentifier: String { bundleIdentifierOverride ?? "org.nxnative." + titleId.lowercased() }
    /// romfs.img, the image of the game's files (dm/host/romfs_image.h).
    var romfsImage: Data { HarnessRomFS.image(bytes: romfsBytes, seed: romfsSeed ?? titleId) }

    /// nxnative names the app after the game.
    var bundleName: String { name.filter { $0.isLetter || $0.isNumber } + ".app" }
    var executable: String { name.filter { $0.isLetter || $0.isNumber } }

    /// A game of the catalogue that has no sheet: one that plays behind
    /// the console, whatever the limit measured there.
    static func plain(_ index: Int = 0) -> HarnessGame {
        let game = HarnessCatalog.gamesWithoutSheet[index]
        return HarnessGame(titleId: game.titleId, name: game.name)
    }

    /// The game's Info.plist, with the keys nxnative's build_ipa.sh gives it.
    var infoPlist: [String: Any] {
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": executable,
            "CFBundleName": executable,
            "CFBundleDisplayName": name,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "MinimumOSVersion": "17.0",
            "UIDeviceFamily": [1],
            "UIRequiresFullScreen": true,
            "UIStatusBarHidden": true,
            "UISupportedInterfaceOrientations": orientations,
            "UIApplicationSupportsIndirectInputEvents": true,
            "GCSupportsControllerUserInteraction": true,
            "DMLanguage": language,
            "DMTitleID": titleId,
            "DMCommit": commit,
            "DTPlatformName": "iphoneos",
            "DTSDKName": "iphoneos26.0",
        ]
        if let orientationsOnIPad { info["UISupportedInterfaceOrientations~ipad"] = orientationsOnIPad }
        return info
    }

    /// dm/launcher.json: nxnative's settings screen, its language first.
    var launcherJSON: Data {
        let settings: [[String: Any]] = [
            [
                "env": "DM_LANG", "kind": "choice", "label": "Language", "note": "The game's language.",
                "default": languages.first ?? language, "section": "Game",
                "options": languages.map { [$0, Locale(identifier: "en").localizedString(forLanguageCode: $0) ?? $0] },
            ],
            [
                "env": "DM_RES_SCALE", "kind": "range", "label": "Render scale", "note": "", "default": "1.00",
                "section": "Graphics", "min": 0.5, "max": 2.0, "step": 0.25,
                "base": ["docked": [1920, 1080], "handheld": [1280, 720]],
            ],
            [
                "env": "DM_VSYNC", "kind": "toggle", "label": "VSync", "note": "", "default": "1", "section": "Graphics",
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: ["settings": settings], options: [.sortedKeys])) ?? Data()
    }

    /// The game's bundle, file by file, from the Payload folder, the same
    /// bytes each time: its Info.plist is in XML, whose keys come sorted,
    /// where a binary one would list them in the order of the dictionary,
    /// which changes from one dictionary to the next.
    var files: [HarnessZip.Entry] {
        let app = "Payload/" + bundleName + "/"
        let plist = HarnessIPA.plist(infoPlist)
        let romfs: HarnessZip.Entry = romfsApart
            ? .file(app + "romfs.id", Data(HarnessRomFS.identityLine(of: romfsImage, title: titleId, version: version).utf8))
            : .file(app + "romfs.img", romfsImage)
        return [
            .folder("Payload/"),
            .folder(app),
            .file(app + "Info.plist", plist),
            .file(app + executable, HarnessMachOFile.executable(sdk: sdk, encrypted: encrypted), mode: 0o755),
            .file(app + "PkgInfo", Data("APPL????".utf8)),
            .folder(app + "dm/"),
            .file(app + "dm/launcher.json", launcherJSON),
            .file(app + "dm/settings.tsv", Data("DM_LANG\tchoice\tLanguage\n".utf8)),
            romfs,
            .folder(app + "Frameworks/"),
            .folder(app + "Frameworks/MoltenVK.framework/"),
            .file(app + "Frameworks/MoltenVK.framework/MoltenVK", HarnessMachOFile.library(), mode: 0o755),
            .file(app + "Frameworks/MoltenVK.framework/Info.plist", HarnessIPA.plist([
                "CFBundleIdentifier": "com.moltenvk.MoltenVK", "CFBundleExecutable": "MoltenVK",
                "CFBundlePackageType": "FMWK",
            ])),
        ]
    }
}

/// The catalogue Cartouche ships (CartoucheCatalog/ in the app), as the
/// tests pick their games from it.
enum HarnessCatalog {
    struct Game {
        let titleId: String
        let name: String
    }

    private static var folder: URL { Bundle.main.bundleURL.appendingPathComponent("CartoucheCatalog", isDirectory: true) }

    /// nxnative's games, as nxnative.json lists them.
    static let games: [Game] = {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("nxnative.json")),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let games = document["games"] as? [[String: Any]] else { return [] }
        return games.compactMap { game in
            guard let titleId = game["titleId"] as? String, let name = game["name"] as? String else { return nil }
            return Game(titleId: titleId, name: name)
        }
    }()

    /// The title IDs of the games testers wrote a sheet for (games/).
    static let sheets: Set<String> = {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("games"),
                                                                  includingPropertiesForKeys: nil)) ?? []
        return Set(files.map { $0.deletingPathExtension().lastPathComponent.uppercased() })
    }()

    /// A game that starts in Cartouche's place once a game behind the
    /// console had less than Cartouche, with the limit there, BEHINDMIB,
    /// that sends it there by the launcher's own rule
    /// (CartoucheGamePlace.startsBehind): the first sheet, read as the
    /// launcher reads it (CartoucheCatalog), that says its game needs
    /// Increased Memory Limit or gives the peak testers measured, with
    /// 6,144 MiB behind the console, as on an iPhone of 12 GB, or else its
    /// peak, which leaves it none of its room there. Sheets change as
    /// testers measure: Mario Kart World's 5,499 MiB is still too close to
    /// 6,144, and a lower peak would start behind the console there.
    static func gameNeedingMoreMemory() -> (game: Game, behindMiB: Int)? {
        let ownMiB = CartoucheMemoryReading.now()?.limitMiB
        for sheet in CartoucheCatalog.shared.sheets {
            let needsIML = sheet.requirements.increasedMemoryLimit
            let peak = sheet.peakMemoryMiB
            guard needsIML || peak != nil else { continue }
            // Above the 512 MiB a reading behind the console has in use.
            for behindMiB in [6_144] + [peak].compactMap({ $0 }) where behindMiB > 512
                && !CartoucheGamePlace.startsBehind(needsIML: needsIML, peakMiB: peak, behindMiB: behindMiB,
                                                    ownMiB: ownMiB) {
                return (Game(titleId: sheet.titleId, name: sheet.name), behindMiB)
            }
        }
        return nil
    }

    /// Games without a sheet, whose names are plain enough to name a bundle.
    static let gamesWithoutSheet: [Game] = games.filter { game in
        !sheets.contains(game.titleId.uppercased()) && game.name.contains(where: \.isLetter)
    }
}

/// IPAs, written into a folder of the test's.
enum HarnessIPA {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HarnessIPAs", isDirectory: true)
    }

    static func plist(_ value: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)) ?? Data()
    }

    /// Writes an IPA of ENTRIES under NAME, and returns where it is.
    @discardableResult
    static func write(_ entries: [HarnessZip.Entry], named name: String, zip64: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try HarnessZip(zip64: zip64).archive(entries).write(to: url)
        return url
    }

    /// GAME's IPA, as a player keeps it.
    static func game(_ game: HarnessGame, named name: String? = nil, zip64: Bool = true) throws -> URL {
        try write(game.files, named: name ?? "\(game.name) [\(game.titleId)].ipa", zip64: zip64)
    }

    /// GAME built with its game files apart, as a player keeps it: its IPA
    /// in FOLDER, named as Cartouche names one, and the image of its files
    /// beside it under the name IMAGE, or none; IMAGEDATA in place of the
    /// game's own image. Returns the IPA.
    @discardableResult
    static func gameApart(_ game: HarnessGame, in folder: URL, image: String? = "romfs.img",
                          imageData: Data? = nil) throws -> URL {
        var game = game
        game.romfsApart = true
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ipa = folder.appendingPathComponent("\(game.name) [\(game.titleId)].ipa")
        try HarnessZip().archive(game.files).write(to: ipa)
        if let image {
            try (imageData ?? game.romfsImage).write(to: folder.appendingPathComponent(image))
        }
        return ipa
    }

    /// An app that is not a game: a notes app.
    static func app(bundleIdentifier: String = "com.example.harness.notes", name: String = "Harness Notes") throws -> URL {
        let bundle = "Payload/Notes.app/"
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": "Notes", "CFBundleName": "Notes",
            "CFBundleDisplayName": name, "CFBundleShortVersionString": "2.4", "CFBundleVersion": "24",
            "CFBundlePackageType": "APPL", "MinimumOSVersion": "16.0",
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["harnessnotes"]]],
        ]
        return try write([
            .folder("Payload/"), .folder(bundle),
            .file(bundle + "Info.plist", plist(info)),
            .file(bundle + "Notes", HarnessMachOFile.executable(sdk: 0x0012_0000), mode: 0o755),
            .file(bundle + "Assets.car", Data(repeating: 0x41, count: 4096)),
        ], named: "Harness Notes.ipa", zip64: false)
    }

    // MARK: Damaged IPAs

    /// The IPA at URL, cut after FRACTION of its bytes, as a copy that
    /// stopped leaves it.
    static func cut(_ url: URL, keeping fraction: Double, named name: String) throws -> URL {
        let data = try Data(contentsOf: url)
        let cut = folder.appendingPathComponent(name)
        try data.prefix(Int(Double(data.count) * fraction)).write(to: cut)
        return cut
    }

    /// The IPA at URL, cut in the middle of the data of the file NAMED, as
    /// a copy that stopped there leaves it.
    static func cut(_ url: URL, inside named: String, named name: String) throws -> URL {
        let data = try Data(contentsOf: url)
        guard let found = data.range(of: Data(("/" + named).utf8)) else {
            throw HarnessZip.Failure("\(named) is not in \(url.lastPathComponent)")
        }
        let cut = folder.appendingPathComponent(name)
        // Past its local header and its extra fields, into its data.
        try data.prefix(found.upperBound + 400).write(to: cut)
        return cut
    }

    /// GAME's IPA with one byte changed in the middle of the file NAMED as
    /// the IPA keeps it, stored or deflated by METHOD, its CRC left as it
    /// was: a copy that went wrong.
    static func damaged(_ game: HarnessGame, in named: String, named name: String,
                        method: HarnessZip.Method = .store) throws -> URL {
        var entries = game.files
        guard let index = entries.firstIndex(where: { $0.name.hasSuffix("/" + named) }) else {
            throw HarnessZip.Failure("\(named) is not in the game")
        }
        entries[index].method = method
        entries[index].damage = true
        return try write(entries, named: name)
    }

    /// Bytes that are no zip archive at all.
    static func notAZip(named name: String = "Not An Archive.ipa") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
        return url
    }
}

// MARK: Zip

/// A zip archive written byte for byte as Info-ZIP's zip writes one
/// (APPNOTE.TXT): local headers, data, the central directory, its end,
/// with Zip64 records when asked, as for an IPA of more than 4 GiB, and
/// each entry's time in an extended timestamp.
struct HarnessZip {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    enum Method { case store, deflate }

    struct Entry {
        var name: String
        var data: Data
        var method: Method
        var mode: UInt16
        var kind: Kind
        var date = Date(timeIntervalSince1970: 1_762_430_400)
        /// One byte of its data changes once its CRC is computed.
        var damage = false

        enum Kind { case file, folder, link }

        static func file(_ name: String, _ data: Data, mode: UInt16 = 0o644, method: Method = .deflate) -> Entry {
            Entry(name: name, data: data, method: data.isEmpty ? .store : method, mode: mode, kind: .file)
        }

        static func folder(_ name: String) -> Entry {
            Entry(name: name, data: Data(), method: .store, mode: 0o755, kind: .folder)
        }

        static func link(_ name: String, to target: String) -> Entry {
            Entry(name: name, data: Data(target.utf8), method: .store, mode: 0o755, kind: .link)
        }
    }

    var zip64 = true

    func archive(_ entries: [Entry]) throws -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt64(out.count)
            var stored = entry.data
            var method: UInt16 = 0
            if entry.method == .deflate, let deflated = Self.deflate(entry.data) {
                stored = deflated
                method = 8
            }
            let crc = HarnessCRC32.checksum(entry.data)
            if entry.damage, !stored.isEmpty {
                let middle = stored.startIndex + stored.count / 2
                stored[middle] ^= 0x5A
            }
            let size = UInt64(entry.data.count)
            let packed = UInt64(stored.count)
            let (time, day) = Self.dosTime(entry.date)
            let name = Data(entry.name.utf8)
            let stamp = UInt32(clamping: Int(entry.date.timeIntervalSince1970))
            let needed: UInt16 = zip64 ? 45 : (method == 8 ? 20 : 10)

            var localExtra = Data()
            localExtra.le16(0x5455); localExtra.le16(5); localExtra.append(0x01); localExtra.le32(stamp)
            if zip64 {
                localExtra.le16(0x0001); localExtra.le16(16); localExtra.le64(size); localExtra.le64(packed)
            }
            out.le32(0x0403_4B50)
            out.le16(needed)
            out.le16(0x0800)
            out.le16(method)
            out.le16(time); out.le16(day)
            out.le32(crc)
            out.le32(zip64 ? 0xFFFF_FFFF : UInt32(packed))
            out.le32(zip64 ? 0xFFFF_FFFF : UInt32(size))
            out.le16(UInt16(name.count)); out.le16(UInt16(localExtra.count))
            out.append(name); out.append(localExtra)
            out.append(stored)

            var centralExtra = Data()
            centralExtra.le16(0x5455); centralExtra.le16(5); centralExtra.append(0x01); centralExtra.le32(stamp)
            if zip64 {
                centralExtra.le16(0x0001); centralExtra.le16(24)
                centralExtra.le64(size); centralExtra.le64(packed); centralExtra.le64(offset)
            }
            let type: UInt32
            switch entry.kind {
            case .file: type = 0o100000
            case .folder: type = 0o040000
            case .link: type = 0o120000
            }
            central.le32(0x0201_4B50)
            central.le16(0x031E) // Unix, zip 3.0
            central.le16(needed)
            central.le16(0x0800)
            central.le16(method)
            central.le16(time); central.le16(day)
            central.le32(crc)
            central.le32(zip64 ? 0xFFFF_FFFF : UInt32(packed))
            central.le32(zip64 ? 0xFFFF_FFFF : UInt32(size))
            central.le16(UInt16(name.count)); central.le16(UInt16(centralExtra.count)); central.le16(0)
            central.le16(0); central.le16(0)
            central.le32(((type | UInt32(entry.mode)) << 16) | (entry.kind == .folder ? 0x10 : 0))
            central.le32(zip64 ? 0xFFFF_FFFF : UInt32(offset))
            central.append(name); central.append(centralExtra)
        }
        let centralOffset = UInt64(out.count)
        out.append(central)
        let count = UInt64(entries.count)
        if zip64 {
            let record = UInt64(out.count)
            out.le32(0x0606_4B50); out.le64(44)
            out.le16(0x031E); out.le16(45)
            out.le32(0); out.le32(0)
            out.le64(count); out.le64(count)
            out.le64(UInt64(central.count)); out.le64(centralOffset)
            out.le32(0x0706_4B50); out.le32(0); out.le64(record); out.le32(1)
        }
        out.le32(0x0605_4B50)
        out.le16(0); out.le16(0)
        out.le16(zip64 ? 0xFFFF : UInt16(count)); out.le16(zip64 ? 0xFFFF : UInt16(count))
        out.le32(zip64 ? 0xFFFF_FFFF : UInt32(central.count))
        out.le32(zip64 ? 0xFFFF_FFFF : UInt32(centralOffset))
        out.le16(0)
        return out
    }

    /// Raw DEFLATE (RFC 1951), as zip keeps it, or nil when it would not
    /// be smaller.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 16 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        return output.prefix(written)
    }

    /// MS-DOS time and date, in local time.
    static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let second: Int = parts.second ?? 0
        let year: Int = Swift.max((parts.year ?? 1980) - 1980, 0)
        let month: Int = parts.month ?? 1
        let dayOfMonth: Int = parts.day ?? 1
        let time = UInt16(hour << 11) | UInt16(minute << 5) | UInt16(second / 2)
        let day = UInt16(year << 9) | UInt16(month << 5) | UInt16(dayOfMonth)
        return (time, day)
    }
}

enum HarnessCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func le16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func le32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func le64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: Mach-O

/// Executables as Xcode builds them for an iPhone, as far as LiveContainer
/// reads them: a 64-bit ARM Mach-O header, the SDK it was built with
/// (LC_BUILD_VERSION), and, for an app from the App Store that was not
/// decrypted, its encryption (LC_ENCRYPTION_INFO_64).
enum HarnessMachOFile {
    static func executable(sdk: UInt32, minimumOS: UInt32 = 0x0011_0000, encrypted: Bool = false) -> Data {
        image(fileType: 2, sdk: sdk, minimumOS: minimumOS, encrypted: encrypted)
    }

    static func library() -> Data {
        image(fileType: 6, sdk: 0x001A_0000, minimumOS: 0x0011_0000, encrypted: false)
    }

    private static func image(fileType: UInt32, sdk: UInt32, minimumOS: UInt32, encrypted: Bool) -> Data {
        var commands = Data()
        commands.le32(0x32); commands.le32(24)
        commands.le32(2) // iOS
        commands.le32(minimumOS); commands.le32(sdk); commands.le32(0)
        var count: UInt32 = 1
        if encrypted {
            commands.le32(0x2C); commands.le32(24)
            commands.le32(0x4000); commands.le32(0x4000); commands.le32(1); commands.le32(0)
            count += 1
        }
        var data = Data()
        data.le32(0xFEED_FACF)
        data.le32(0x0100_000C) // CPU_TYPE_ARM64
        data.le32(0)
        data.le32(fileType)
        data.le32(count)
        data.le32(UInt32(commands.count))
        data.le32(0x0020_0085) // MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE
        data.le32(0)
        data.append(commands)
        // Code that compresses as code does, rather than zeros.
        var state: UInt32 = 0x1234_5678 ^ sdk
        while data.count < 48 << 10 {
            state = state &* 1_664_525 &+ 1_013_904_223
            data.le32(0xD503_201F ^ (state & 0x0000_FFE0))
        }
        return data
    }
}

// MARK: romfs.img

/// The game's files as nxnative packs them into romfs.img
/// (dm/host/romfs_image.h): a header of 32 bytes (DMROMFS1, where the
/// index starts, its size, how many entries it has), the files, then the
/// index, 24 bytes an entry, which SEED changes as the files do.
enum HarnessRomFS {
    static func image(bytes: Int, seed: String) -> Data {
        let entries = 8
        let indexSize = entries * 24
        let filesSize = Swift.max(bytes - 32 - indexSize, entries)
        var data = Data("DMROMFS1".utf8)
        data.le64(UInt64(32 + filesSize))
        data.le64(UInt64(indexSize))
        data.le64(UInt64(entries))
        var state: UInt32 = seed.utf8.reduce(5381) { ($0 &* 33) &+ UInt32($1) }
        let tag = UInt64(state)
        var files = Data(count: filesSize)
        files.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for index in 0..<bytes.count {
                // Half text, half noise: game files compress some.
                if index % 64 < 32 {
                    bytes[index] = UInt8(65 + index % 26)
                } else {
                    state = state &* 1_103_515_245 &+ 12_345
                    bytes[index] = UInt8(truncatingIfNeeded: state >> 16)
                }
            }
        }
        data.append(files)
        let share = filesSize / entries
        for entry in 0..<entries {
            data.le64(UInt64(32 + entry * share))
            data.le64(UInt64(share))
            data.le64((UInt64(entry) &* 0x9E37_79B9_7F4A_7C15) ^ tag)
        }
        return data
    }

    /// romfs.id for IMAGE, as nxnative writes it in the app of a game built
    /// with its files apart (dm/host/romfs_identity.h): its size, and
    /// FNV-1a 64 over the little-endian 64-bit words of its header and
    /// index, the last completed with zeros, in 16 hex digits.
    static func identityLine(of image: Data, title: String, version: String) -> String {
        var indexAt = 0
        for shift in 0..<8 {
            indexAt |= Int(image[image.startIndex + 8 + shift]) << (8 * shift)
        }
        var hashed = [UInt8](image.prefix(32)) + [UInt8](image.suffix(from: image.startIndex + indexAt))
        while hashed.count % 8 != 0 { hashed.append(0) }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for at in stride(from: 0, to: hashed.count, by: 8) {
            var word: UInt64 = 0
            for shift in 0..<8 {
                word |= UInt64(hashed[at + shift]) << UInt64(8 * shift)
            }
            hash = (hash ^ word) &* 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        let index = String(repeating: "0", count: 16 - hex.count) + hex
        return "DMROMFSID1 title=\(title) version=\(version) build=harness size=\(image.count) index=\(index)\n"
    }
}

// MARK: What the tests read of an installed game

extension XCTestCase {
    /// Whether the file at URL holds DATA, as the game's IPA has it: the
    /// same bytes, or, for its Info.plist, the same property list, which
    /// LiveContainer writes again in binary as a new copy of the game takes
    /// the place of the installed one (setDoUseLCBundleId).
    func installedFile(_ url: URL, holds data: Data) -> Bool {
        guard let found = try? Data(contentsOf: url) else { return false }
        if found == data { return true }
        guard url.lastPathComponent == "Info.plist",
              let installed = try? PropertyListSerialization.propertyList(from: found, format: nil) as? NSDictionary,
              let original = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
        else { return false }
        return installed.isEqual(original)
    }

    /// The files of the folder at URL, by their path in it, folders ending
    /// with "/".
    func listing(of url: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [String] = []
        let root = url.standardizedFileURL.path
        while let item = walker.nextObject() as? URL {
            let path = String(item.standardizedFileURL.path.dropFirst(root.count + 1))
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            found.append(isFolder ? path + "/" : path)
        }
        return found.sorted()
    }
}
