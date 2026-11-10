//
//  GalleryStubs.swift
//  CartoucheGallery
//
//  LiveContainer's types and calls the launcher uses, as the gallery stands
//  them in: the player's games are the scenario's, the certificate and the
//  pairing file are there once its setup is done, and the built-in
//  SideStore's last renewal leaves six days.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The scenario's state, read by the stand-ins below.
enum GalleryState {
    static var setupDone = false
    /// iOS no longer accepts the certificate (work: certificate).
    static var certificateRefused = false

    static let documents: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gallery", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let appGroup: URL = {
        let url = documents.appendingPathComponent("AppGroup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

final class LCAppInfo {
    private let name: String
    private let identifier: String
    private let folder: String
    private let icon: UIImage?
    /// The app's Info.plist, when the scenario gives it one.
    var infoPlist: NSMutableDictionary?
    var installationDate: Date?

    init(name: String, identifier: String, folder: String, icon: UIImage?) {
        self.name = name
        self.identifier = identifier
        self.folder = folder
        self.icon = icon
    }

    var relativeBundlePath: String? { folder }
    func displayName() -> String? { name }
    func bundleIdentifier() -> String? { identifier }
    func info() -> NSMutableDictionary? { infoPlist }
    func bundlePath() -> String? { nil }
    func iconIsDarkIcon(_ isDark: Bool) -> UIImage? { icon }
}

final class LCAppModel: ObservableObject, Identifiable, Equatable {
    let appInfo: LCAppInfo

    init(appInfo: LCAppInfo) {
        self.appInfo = appInfo
    }

    var displayName: String { appInfo.displayName() ?? "?" }

    static func == (lhs: LCAppModel, rhs: LCAppModel) -> Bool { lhs === rhs }
}

/// CartoucheGameActions.swift, which installs, starts, uninstalls and copies
/// games with LiveContainer and opens their preferences, as the gallery
/// stands it in: nothing happens, a scenario can show a step in progress,
/// and every game has the settings of GallerySettings, kept in memory.
@MainActor
final class CartoucheGameActions: ObservableObject {
    static let shared = CartoucheGameActions()

    @Published var work: CartoucheGameWork?
    @Published var notice: CartoucheGameNotice?
    @Published var installed: LCAppModel?
    /// The game paused behind the console (work: paused).
    @Published var running: CartoucheRunningGame?
    @Published var switching: CartoucheGameSwitch?
    @Published var quitQuestion: CartoucheRunningGame?

    nonisolated static func takes(_ url: URL) -> Bool { false }
    func install(_ url: URL) {}
    func install(stored game: CartoucheStoredGame) {}
    func play(_ app: LCAppModel, showingSettings: Bool = false) {}
    func resumeRunningGame() {}
    func askToQuit() { quitQuestion = running }
    func quitRunningGame() { quitQuestion = nil }
    func confirmSwitch(_ change: CartoucheGameSwitch) { switching = nil }

    /// APP runs behind the console, paused there, since a quarter of an hour.
    func showRunningForGallery(_ app: LCAppModel) {
        // On screen first, then paused as the player comes back to the
        // console, which puts the game in focus on the home.
        running = CartoucheRunningGame(app: app, dataFolder: "gallery", started: Date().addingTimeInterval(-15 * 60),
                                       isInFront: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            self.running?.isInFront = false
        }
    }
    func uninstall(_ app: LCAppModel, erasingData: Bool) {}
    func export(_ app: LCAppModel, titleId: String?, then next: (() -> Void)? = nil) {}
    /// A game's saves live in its LiveContainer data folder, which the
    /// gallery has none of.
    func saves(of app: LCAppModel) -> CartoucheSaveTarget? { nil }
    func copySaves(of apps: [LCAppModel]) {}

    func settings(for app: LCAppModel, tileKey: String) -> CartoucheGameSettingsModel {
        CartoucheGameSettingsModel(name: app.displayName, tileKey: tileKey,
                                   settings: CartoucheGameSetting.rows(in: Data(GallerySettings.list.utf8)) ?? [],
                                   fixed: [:], choices: GallerySettings.choices)
    }
}

/// A settings list as nxnative writes one into a game (dm/launcher.json,
/// from its settings.tsv), for a game played in handheld mode, and a
/// player's choice: a lower render scale.
enum GallerySettings {
    static let choices = GalleryChoices(["launcher.DM_RENDER_SCALE": "0.85"])

    static let list = """
    {"schema": 1, "settings": [
      {"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "60",
       "options": [["30", "30 fps"], ["60", "60 fps"]], "level": "basic"},
      {"env": "DM_RENDER_SCALE", "kind": "range", "section": "Game", "label": "Render scale", "note": "", "default": "1.0",
       "min": 0.5, "max": 1.0, "step": 0.05, "base": {"docked": [1920, 1080], "handheld": [1280, 720]}, "level": "basic"},
      {"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "0",
       "options": [["1", "Docked"], ["0", "Handheld"]], "level": "basic"},
      {"env": "DM_PRESENT_UPSCALE", "kind": "choice", "section": "Game", "label": "Upscaling",
       "note": "Uses more GPU time and can increase heat.", "default": "off", "options": [["off", "Standard"], ["metalfx", "MetalFX"]]},
      {"env": "DM_LANG", "kind": "choice", "section": "Game", "label": "Game language", "note": "", "default": "fr",
       "options": [["en-US", "American English"], ["en-GB", "British English"], ["ja", "Japanese"], ["fr", "French"],
                   ["de", "German"], ["es", "Spanish"], ["it", "Italian"], ["fr-CA", "Canadian French"]], "level": "basic"},
      {"env": "DM_PICTURE_FIT", "kind": "choice", "section": "Game", "label": "Picture",
       "note": "Fill crops the game's 16:9 picture to cover the screen. Health bars, subtitles or maps near the edges can be cut off. A full-screen picture without cropping needs a patch for each game.",
       "default": "fit", "options": [["fit", "Fit"], ["fill", "Fill"]]},
      {"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Frame-rate counter", "note": "", "default": "0"},
      {"env": "DM_TOUCH_HAPTICS", "kind": "toggle", "section": "Controls", "label": "Touch feedback", "note": "", "default": "1"},
      {"env": "DM_RUMBLE", "kind": "toggle", "section": "Controls", "label": "Game rumble", "note": "", "default": "1", "level": "basic"},
      {"env": "DM_RUMBLE_GAIN", "kind": "range", "section": "Controls", "label": "Rumble strength", "note": "", "default": "1.0",
       "min": 0, "max": 3, "step": 0.1, "needs": "DM_RUMBLE=1"},
      {"env": "DM_RUMBLE_MIN", "kind": "range", "section": "Controls", "label": "Rumble cutoff", "note": "", "default": "0",
       "min": 0, "max": 0.9, "step": 0.05},
      {"env": "DM_PRESENT_SNAP", "kind": "toggle", "section": "Performance", "label": "Frame buffering",
       "note": "Up to one frame more display latency.", "default": "1"},
      {"env": "DM_PSO_MTL4", "kind": "toggle", "section": "Performance", "label": "Metal 4 pipelines",
       "note": "Keeps a pipeline archive; uses more memory.", "default": "1"},
      {"env": "DM_PSO_PREBUILD", "kind": "toggle", "section": "Performance", "label": "Pipeline prebuild",
       "note": "The first start waits a few minutes for it, once.", "default": "1", "needs": "DM_PSO_MTL4=1"},
      {"env": "DM_NVN_ENC_THREAD", "kind": "toggle", "section": "Performance", "label": "Encode thread", "note": "", "default": "1"},
      {"env": "DM_FPS_HOLD", "kind": "toggle", "section": "Performance", "label": "Hold frames when late", "note": "", "default": "on",
       "on": "on", "off": "off"},
      {"env": "DM_METAL_HUD", "kind": "toggle", "section": "Performance", "label": "Performance HUD", "note": "", "default": "0"}
    ]}
    """
}

/// A game's preferences, in memory.
final class GalleryChoices: CartoucheGameChoices {
    private var values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    func string(forKey key: String) -> String? { values[key] as? String }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

public enum LCTabIdentifier: Hashable {
    case games
    case sources
    case apps
    case system
    case tweaks
    case settings

    static var initial: LCTabIdentifier { .games }
}

final class SharedModel: ObservableObject {
    @Published var selectedTab: LCTabIdentifier = .games
    @Published var deepLink: URL?
    @Published var apps: [LCAppModel] = []
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa")!
}

enum LCUtils {
    static func certificateData() -> Data? { GalleryState.setupDone ? Data([0x30]) : nil }
    static func getCertTeamId(withKeyData data: Data, password: String) -> String? { nil }
    static var appGroupUserDefault: UserDefaults { .standard }
    static func validateJITLessSetup(completionHandler: @escaping (Bool, Error?) -> Void) {
        DispatchQueue.main.async { completionHandler(!GalleryState.certificateRefused, nil) }
    }
}

enum LCSharedUtils {
    static func certificatePassword() -> String? { GalleryState.setupDone ? "" : nil }
    static func appGroupPath() -> URL? { GalleryState.appGroup }
}

struct LCPath {
    static var docPath: URL { GalleryState.documents }
}

/// The icon of a game the player imported. The gallery draws one from the
/// game's initials, never the game's own art.
enum GalleryIcon {
    static func make(name: String, key: String, side: CGFloat = 512) -> UIImage {
        let colors = CartoucheTheme.colors(for: key)
        let words = name.split { !$0.isLetter && !$0.isNumber }
            .filter { !["the", "of", "and"].contains($0.lowercased()) }
        let initials = String(words.prefix(3).compactMap(\.first)).uppercased()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: space,
                                      colors: [UIColor(colors.light).cgColor, UIColor(colors.dark).cgColor] as CFArray,
                                      locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            UIColor.white.withAlphaComponent(0.18).setFill()
            UIBezierPath(ovalIn: CGRect(x: side * 0.45, y: -side * 0.2, width: side * 0.9, height: side * 0.9)).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let font = UIFont.systemFont(ofSize: side * (initials.count > 2 ? 0.26 : 0.34), weight: .black)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
            ]
            let height = font.lineHeight
            (initials as NSString).draw(in: CGRect(x: 0, y: (side - height) / 2, width: side, height: height),
                                        withAttributes: attributes)
        }
    }
}
