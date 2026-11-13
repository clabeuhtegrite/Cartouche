//
//  MacPlay.swift
//  BuilderKit
//
//  A game's app for this Mac, as nxnative packs it, and what the builder
//  needs to start it and to know how it ended (nxnative's docs/frontends.md,
//  "Starting a game"): its title ID and names in its Info.plist; the
//  environment of a start, which skips nxnative's settings window, turns
//  nxnative's own cloud saves off while the builder keeps the saves, and
//  gives the Home button's prompt and the players' prompt the player's
//  language; the cloud saves folder the player may have chosen in that
//  window; and how the game ended, from the launcher's last line in its log.
//  Platform-independent: Foundation only. Starting the app and following it
//  is MacGames.swift's.
//

import Foundation

/// A game's app for this Mac.
public struct MacGameApp: Hashable, Sendable {
    public let url: URL
    public let titleID: String
    /// The name it shows: its copies' folder is named after it, as
    /// Cartouche names it after its IPA's.
    public let name: String
    /// Its preferences domain: its saved choices and nxnative's cloud saves
    /// folder are kept there.
    public let bundleID: String

    public init(url: URL, titleID: String, name: String, bundleID: String? = nil) {
        self.url = url.standardizedFileURL
        self.titleID = titleID.uppercased()
        self.name = name
        self.bundleID = bundleID ?? "org.nxnative." + titleID.uppercased()
    }

    /// The app at URL, as its Info.plist says it; nil for an app that is no
    /// game of nxnative's (no DMTitleID).
    public init?(url: URL) {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let id = info["DMTitleID"] as? String, MacSavesFolder.isTitleID(id) else { return nil }
        let names = [info["CFBundleDisplayName"], info["CFBundleName"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
        let name = names.first ?? url.deletingPathExtension().lastPathComponent
        self.init(url: url, titleID: id, name: name, bundleID: (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    public var saveGame: MacSaveGame { MacSaveGame(titleID: titleID, name: name) }
}

/// How a game ended, as its launcher says it in the last line of the log
/// of its start: the launcher runs the game's host as a child and exits
/// with its exit code (0 for a quit, 70 after macOS revoked the game's GPU
/// work, 134 for an abort), or 128 + the signal that stopped it.
public enum MacGameEnding: String, Codable, Sendable {
    /// The player quit: ⌘Q, the Home prompt, its window closed.
    case quit
    /// macOS stopped running the game's GPU work.
    case gpu
    /// Another exit code, or a crash's signal.
    case crashed
    /// Stopped from outside: a logout, Activity Monitor, a terminal.
    case stopped
    /// No game ran (nxnative's window was closed without playing), or the
    /// log is another start's, or says it in words the builder does not
    /// know: nxnative treats its log as diagnostics, not as an interface,
    /// and a line it words otherwise makes the ending unknown, never wrong.
    case unknown

    static let exited = "launcher: the host exited with "
    static let signalled = "launcher: the host stopped on signal "

    /// The ending its launcher wrote in LOG, a start's log written since
    /// STARTED, and the launcher's exit code; unknown, with none, for a log
    /// of an earlier start or one that does not say.
    public static func read(log: URL, since started: Date? = nil) -> (ending: MacGameEnding, exit: Int?) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: log.path)
        if let started, let modified = attributes?[.modificationDate] as? Date, modified < started.addingTimeInterval(-2) {
            return (.unknown, nil)
        }
        guard let handle = try? FileHandle(forReadingFrom: log) else { return (.unknown, nil) }
        defer { try? handle.close() }
        // Its last lines: a game's log can be long, what ends it is short.
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 16384 ? end - 16384 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// The ending the last launcher line of TEXT says.
    public static func parse(_ text: String) -> (ending: MacGameEnding, exit: Int?) {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(exited), let code = Int(line.dropFirst(exited.count).trimmingCharacters(in: .whitespaces)) {
                switch code {
                case 0: return (.quit, 0)
                case 70: return (.gpu, 70)
                default: return (.crashed, code)
                }
            }
            if line.hasPrefix(signalled), let signal = Int(line.dropFirst(signalled.count).trimmingCharacters(in: .whitespaces)) {
                // SIGHUP, SIGINT, SIGKILL, SIGTERM: someone stopped it.
                return ([1, 2, 9, 15].contains(signal) ? .stopped : .crashed, 128 + signal)
            }
        }
        return (.unknown, nil)
    }
}

/// The environment the builder starts a game with, over the player's own
/// (nxnative's docs/frontends.md, "Starting a game"). Only what is for this
/// start: what the player chose is in the app's saved choices, which a
/// start from the Finder or the Dock reads too.
public enum MacPlayEnvironment {
    /// The prompts' texts in the builder's LANGUAGE ("fr"), none for
    /// English, nxnative's own: the Home button's quit prompt for the game
    /// NAME, and the prompt that waits for more players, five lines each.
    public static func texts(game name: String, language: String) -> [String: String] {
        guard language == "fr" else { return [:] }
        return [
            "DM_HOME_QUIT_TEXT": [
                "Maintenez pour quitter",
                "Quitter \(name) ?",
                "La progression non sauvegardée sera perdue.",
                "Quitter",
                "Annuler",
            ].joined(separator: "\n"),
            "DM_CTRL_PROMPT_TEXT": [
                "{min} joueurs attendus",
                "Appuyez sur un bouton de chaque manette pour la faire rejoindre.",
                "Joueurs : {joined} sur {min}",
                "Terminé",
                "Annuler",
            ].joined(separator: "\n"),
        ]
    }

    /// The environment of a start of APP: KEEPS_SAVES, the builder keeps its
    /// saves in step with the iPhone's, so nxnative's own cloud saves stay
    /// off for this start, never two syncs on one save; DOCUMENTS, the
    /// game's folder when it is not nxnative's own, for the tests (its
    /// saves are DOCUMENTS/save and save_device: nxnative adds _device).
    public static func make(app: MacGameApp, keepsSaves: Bool, language: String, documents: URL? = nil) -> [String: String] {
        var environment = texts(game: app.name, language: language)
        if keepsSaves {
            environment["DM_SAVE_SYNC"] = "0"
        }
        if let documents {
            environment["DM_SAVE"] = documents.appendingPathComponent("save", isDirectory: true).path
        }
        return environment
    }

    /// The arguments of a start: none for one that shows nxnative's
    /// settings window (SETTINGS), --no-launcher to start the game at once.
    public static func arguments(settings: Bool) -> [String] {
        settings ? [] : ["--no-launcher"]
    }
}

/// nxnative's own cloud saves: a folder the player chose in a game's
/// settings window (cloudSaves.folder in the app's preferences), or wrote
/// in its env.txt (DM_SAVE_SYNC), syncs its save at each start and quit.
/// The builder then leaves that game's saves to it.
public enum MacCloudSaves {
    /// The folder nxnative's cloud saves of APP go through, nil when they
    /// are off: from its preferences, read by PREFERENCE (key, domain), or
    /// the player's env.txt in DOCUMENTS, which wins over them.
    public static func folder(of app: MacGameApp, documents: URL, preference: (String, String) -> String?) -> String? {
        if let line = environmentFileValue(documents.appendingPathComponent("env.txt")) {
            // Set, even empty, it is the one nxnative reads: "" and "0" are off.
            return line.isEmpty || line == "0" ? nil : line
        }
        guard let folder = preference("cloudSaves.folder", app.bundleID)?.trimmingCharacters(in: .whitespaces),
              !folder.isEmpty, folder != "0" else { return nil }
        return folder
    }

    /// The value env.txt at URL gives DM_SAVE_SYNC, read as nxnative's
    /// launcher reads it (dm/mac/launcher.c env_file): the first line that
    /// sets it wins; nil when none does.
    static func environmentFileValue(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equal = line.firstIndex(of: "="), equal != line.startIndex,
                  line[..<equal].trimmingCharacters(in: .whitespaces) == "DM_SAVE_SYNC" else { continue }
            return String(line[line.index(after: equal)...])
        }
        return nil
    }
}
