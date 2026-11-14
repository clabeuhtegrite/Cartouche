//
//  ConsoleGames.swift
//  Cartouche on the Mac
//
//  The games on this Mac as the console's screens know a game of the
//  iPhone's, LiveContainer's LCAppModel: here, an app nxnative built for
//  the Mac (dm/mac), which the app gives the console as its URL. Its
//  Info.plist, in its Contents, says its name and its bundle ID,
//  org.nxnative.<title ID in lowercase> unless the build was given
//  another, from which the catalogue knows the game, as on the iPhone.
//

import AppKit
import Foundation

/// A game's app, read from its bundle.
final class LCAppInfo {
    /// The app on this Mac.
    let url: URL
    /// Its Info.plist.
    private let plist: [String: Any]
    /// When the app came to this Mac: its folder's creation.
    var installationDate: Date?
    private var loadedIcon: NSImage??

    init(url: URL) {
        self.url = url.standardizedFileURL
        plist = (NSDictionary(contentsOf: self.url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]) ?? [:]
        installationDate = (try? self.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// The key the console knows the app by, as LiveContainer's folder of
    /// the app on the iPhone: its path, the same until it moves.
    var relativeBundlePath: String? { url.path }

    func displayName() -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = plist[key] as? String, !name.isEmpty { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    func bundleIdentifier() -> String? { plist["CFBundleIdentifier"] as? String }

    /// LiveContainer's own settings for the app, which a Mac has none of.
    func info() -> NSMutableDictionary? { nil }

    /// The folder that holds the app's Info.plist, as the bundle of an
    /// iPhone's app does: its Contents.
    func bundlePath() -> String? { url.appendingPathComponent("Contents", isDirectory: true).path }

    /// The app's own icon, when it has one; nil for the console's drawing
    /// otherwise, rather than the Mac's icon of any app.
    func iconIsDarkIcon(_ isDark: Bool) -> NSImage? {
        if let loadedIcon { return loadedIcon }
        var icon: NSImage?
        let name = (plist["CFBundleIconFile"] as? String) ?? (plist["CFBundleIconName"] as? String)
        if let name, !name.isEmpty {
            let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
            let file = name.hasSuffix(".icns") ? name : name + ".icns"
            icon = NSImage(contentsOf: resources.appendingPathComponent(file))
        }
        loadedIcon = .some(icon)
        return icon
    }
}

/// A game on this Mac, as the console's screens show it.
final class LCAppModel: ObservableObject, Identifiable, Hashable {
    let appInfo: LCAppInfo

    init(appInfo: LCAppInfo) {
        self.appInfo = appInfo
    }

    var displayName: String { appInfo.displayName() ?? "?" }

    static func == (lhs: LCAppModel, rhs: LCAppModel) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The iPhone's tabs, which the home's dock leads to: on the Mac, System
/// alone, the console's own page.
enum LCTabIdentifier: Hashable {
    case games
    case system
}
