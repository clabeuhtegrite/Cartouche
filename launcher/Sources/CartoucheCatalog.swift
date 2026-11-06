//
//  CartoucheCatalog.swift
//  Cartouche
//
//  The games Cartouche supports, from the compatibility sheets the app
//  carries (CartoucheCatalog/ in the app, catalog/ in the Cartouche
//  repository), and the player's own copies among LiveContainer's apps.
//  A sheet never says where to get a game.
//

import Foundation

struct CartoucheGameSheet: Decodable, Hashable {
    struct Requirements: Decodable, Hashable {
        let minimumIOS: String
        let bcTextureCompression: Bool
        let increasedMemoryLimit: Bool
        let peakMemoryMiB: Int?
    }

    struct Recommended: Decodable, Hashable {
        let resolution: String?
        let mode: String?
    }

    struct Result: Decodable, Hashable {
        let device: String
        let iOS: String
        let date: String
        let engine: String
        let status: String
        let peakMemoryMiB: Int?
        let notes: [String]?
    }

    let titleId: String
    let name: String
    let platform: String
    let requirements: Requirements
    let recommended: Recommended?
    let results: [Result]

    /// The highest memory peak measured, the sheet's own or a result's.
    var peakMemoryMiB: Int? {
        ([requirements.peakMemoryMiB] + results.map(\.peakMemoryMiB)).compactMap { $0 }.max()
    }
}

struct CartoucheDeviceProfile: Decodable, Hashable {
    struct Measurement: Decodable, Hashable {
        let date: String
        let iOS: String
        let increasedMemoryLimit: Bool
        let appMemoryLimitMiB: Int
    }

    let identifier: String
    let chip: String
    let memoryGB: Int
    let measurements: [Measurement]
}

/// A game in the catalogue: a supported game, the player's copy of one, or
/// the player's copy of an nxnative game that has no sheet yet.
struct CartoucheEntry: Identifiable, Hashable {
    let id: String
    let sheet: CartoucheGameSheet?
    let app: LCAppModel?

    var name: String {
        if let sheet { return sheet.name }
        return app?.appInfo.displayName() ?? ""
    }

    /// What tells the designed tiles apart: the title ID, or the app's folder.
    var tileKey: String { sheet?.titleId ?? id }

    static func == (lhs: CartoucheEntry, rhs: CartoucheEntry) -> Bool {
        lhs.id == rhs.id && lhs.app === rhs.app
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class CartoucheCatalog {
    static let shared = CartoucheCatalog()

    let sheets: [CartoucheGameSheet]
    let devices: [CartoucheDeviceProfile]

    /// The title ID each app's folder was found to hold, or "" for an
    /// nxnative game without one, so that every Info.plist is read once.
    private var appTitles: [String: String] = [:]
    private var otherApps: Set<String> = []

    private init() {
        let folder = Bundle.main.bundleURL.appendingPathComponent("CartoucheCatalog", isDirectory: true)
        let decoder = JSONDecoder()
        var sheets: [CartoucheGameSheet] = []
        let gameFiles = (try? FileManager.default.contentsOfDirectory(
            at: folder.appendingPathComponent("games", isDirectory: true),
            includingPropertiesForKeys: nil)) ?? []
        for file in gameFiles where file.pathExtension == "json" {
            do {
                sheets.append(try decoder.decode(CartoucheGameSheet.self, from: Data(contentsOf: file)))
            } catch {
                NSLog("[Cartouche] cannot read the sheet %@: %@", file.lastPathComponent, String(describing: error))
            }
        }
        self.sheets = sheets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        struct DeviceList: Decodable { let devices: [CartoucheDeviceProfile] }
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("devices.json"))
            self.devices = try decoder.decode(DeviceList.self, from: data).devices
        } catch {
            NSLog("[Cartouche] cannot read the device profiles: %@", String(describing: error))
            self.devices = []
        }
    }

    func device(_ identifier: String) -> CartoucheDeviceProfile? {
        devices.first { $0.identifier == identifier }
    }

    func sheet(titleId: String) -> CartoucheGameSheet? {
        sheets.first { $0.titleId == titleId }
    }

    struct Entries {
        /// The player's games, with a sheet or not, by name.
        var owned: [CartoucheEntry] = []
        /// The other supported games, by name.
        var others: [CartoucheEntry] = []

        func entry(id: String?) -> CartoucheEntry? {
            guard let id else { return nil }
            return owned.first { $0.id == id } ?? others.first { $0.id == id }
        }
    }

    /// The catalogue for these apps: each of the player's nxnative games
    /// with its sheet if there is one, then every other supported game.
    func entries(for apps: [LCAppModel]) -> Entries {
        var result = Entries()
        var ownedTitles = Set<String>()
        for app in apps {
            guard let titleId = gameTitle(of: app) else { continue }
            let match = titleId.isEmpty ? sheetMatchingName(of: app) : self.sheet(titleId: titleId)
            if let match { ownedTitles.insert(match.titleId) }
            let folder = app.appInfo.relativeBundlePath ?? app.appInfo.bundleIdentifier() ?? ""
            result.owned.append(CartoucheEntry(id: "app:" + folder, sheet: match, app: app))
        }
        result.owned.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.others = sheets
            .filter { !ownedTitles.contains($0.titleId) }
            .map { CartoucheEntry(id: "game:" + $0.titleId, sheet: $0, app: nil) }
        return result
    }

    /// The title ID of an nxnative game, "" for an nxnative game whose title
    /// ID is unknown, or nil for any other app.
    ///
    /// nxnative names its iOS apps org.nxnative.<title ID in lowercase>
    /// (dm/ios/tools/build_ipa.sh) unless the build was given another
    /// identifier, and writes DMLanguage into their Info.plist.
    func gameTitle(of app: LCAppModel) -> String? {
        let folder = app.appInfo.relativeBundlePath ?? ""
        if let known = appTitles[folder] { return known }
        if otherApps.contains(folder) { return nil }

        let original = app.appInfo.info()?["LCOrignalBundleIdentifier"] as? String
        let bundleId = (original ?? app.appInfo.bundleIdentifier() ?? "").lowercased()
        let prefix = "org.nxnative."
        if bundleId.hasPrefix(prefix) {
            let candidate = bundleId.dropFirst(prefix.count).prefix(16)
            if candidate.count == 16, candidate.allSatisfy(\.isHexDigit) {
                appTitles[folder] = candidate.uppercased()
                return appTitles[folder]
            }
        }

        let infoPlist = (app.appInfo.bundlePath() as NSString?)?.appendingPathComponent("Info.plist")
        if let infoPlist, let info = NSDictionary(contentsOfFile: infoPlist), info["DMLanguage"] != nil {
            appTitles[folder] = ""
            return ""
        }
        otherApps.insert(folder)
        return nil
    }

    /// An nxnative build with another bundle identifier keeps the game's
    /// name as its display name.
    private func sheetMatchingName(of app: LCAppModel) -> CartoucheGameSheet? {
        let name = Self.comparable(app.appInfo.displayName() ?? "")
        guard !name.isEmpty else { return nil }
        return sheets.first { Self.comparable($0.name) == name }
    }

    private static func comparable(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
