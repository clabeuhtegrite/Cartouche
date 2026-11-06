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

    init(name: String, identifier: String, folder: String, icon: UIImage?) {
        self.name = name
        self.identifier = identifier
        self.folder = folder
        self.icon = icon
    }

    var relativeBundlePath: String? { folder }
    func displayName() -> String? { name }
    func bundleIdentifier() -> String? { identifier }
    func info() -> NSMutableDictionary? { nil }
    func bundlePath() -> String? { nil }
    func iconIsDarkIcon(_ isDark: Bool) -> UIImage? { icon }
}

final class LCAppModel: ObservableObject, Identifiable {
    let appInfo: LCAppInfo

    init(appInfo: LCAppInfo) {
        self.appInfo = appInfo
    }
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
    static func openSideStore() {}
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
