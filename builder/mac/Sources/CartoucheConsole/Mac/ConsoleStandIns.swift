//
//  ConsoleStandIns.swift
//  Cartouche on the Mac
//
//  What the console's screens (Shared/) ask of the iPhone's Cartouche, as
//  a Mac answers: its game actions (CartoucheGameActions.swift, which
//  installs and starts games with LiveContainer), the game running, its
//  setup (a certificate and a pairing file), its Apple ID, its first
//  game's guide, the game behind the console, the iPhone's model, memory
//  limit, signature and its renewals, how a game fits it, and the journal
//  of its reports.
//  A Mac plays the games nxnative built for it, each in its own app: the
//  console has nothing to set up, no limit of memory from iOS, no signature
//  that expires, nothing behind it. Each stand-in keeps the names and the
//  calls of the iPhone's, so that the screens are the same files.
//

import AppKit
import Foundation
import Metal
import SwiftUI

// MARK: The game actions

/// What the console does with a game: the app it is in does it (Play
/// starts the game's own app, Quit asks it to end), and says which game
/// runs (CartoucheMacConsole).
@MainActor
final class CartoucheGameActions: ObservableObject {
    static let shared = CartoucheGameActions()

    /// The game running, started from this Mac.
    @Published var running: CartoucheRunningGame?
    /// What the app does when the console asks it.
    var onQuit: (LCAppModel) -> Void = { _ in }

    /// Whether APP is the game running.
    func isRunning(_ app: LCAppModel?) -> Bool {
        guard let app, let running else { return false }
        return running.app === app
    }

    /// The running game ends: its app is asked to quit, as its own Quit
    /// does, so that the game saves as it ends.
    func askToQuit() {
        guard let running else { return }
        onQuit(running.app)
    }

    /// Where nxnative's apps keep each game's data on this Mac, by its title
    /// ID (dm/mac/launcher.c in nxnative).
    var dataRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/nxnative", isDirectory: true)

    /// The game's saves on this Mac come with the Mac's saves page; until
    /// then, the sheet has no saves section.
    func saves(of app: LCAppModel) -> CartoucheSaveTarget? { nil }

    /// The game's app and its data folder, for its size and its play time
    /// (CartoucheGameStats). Nil for an app that is not an nxnative game.
    func folders(of app: LCAppModel) -> CartoucheGameFolders? {
        guard let found = CartoucheCatalog.shared.gameTitle(of: app), let contents = app.appInfo.bundlePath(),
              let bundleId = CartoucheGameStats.bundleId(of: app) else { return nil }
        let titleId = found.isEmpty ? nil : found
        var data: [String: URL] = [:]
        if let titleId {
            let folder = dataRoot.appendingPathComponent(titleId.uppercased(), isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) { data[titleId.uppercased()] = folder }
        }
        // The app's Contents, which hold all of it and its Info.plist.
        return CartoucheGameFolders(bundleId: bundleId, titleId: titleId,
                                    bundle: URL(fileURLWithPath: contents, isDirectory: true), data: data)
    }
}

/// The game running, in its own app.
struct CartoucheRunningGame: Equatable {
    let app: LCAppModel
    let started: Date
    /// Its app is the Mac's active app.
    var isInFront: Bool

    var name: String { app.displayName }

    static func == (lhs: CartoucheRunningGame, rhs: CartoucheRunningGame) -> Bool {
        lhs.app === rhs.app && lhs.started == rhs.started && lhs.isInFront == rhs.isInFront
    }
}

/// Where a game runs: on the Mac, always in its own app, never behind the
/// console, and with all the Mac's memory.
@MainActor
final class CartoucheGameKeeping: ObservableObject {
    static let shared = CartoucheGameKeeping()

    static var isAvailable: Bool { false }

    @Published var keepsConsoleOpen = false
    @Published private(set) var limitMiB: Int?

    func startsInPlace(bundleId: String?, ownLimitMiB: Int?) -> Bool { false }
    func gameLimitMiB(ownLimitMiB: Int?) -> Int? { ownLimitMiB }
    func startBehind(bundleId: String) {}
    func sendsGamesInPlace(ownLimitMiB: Int?) -> Bool { false }
    func tryBehindAgain() {}
    func fitsBehind(needsIML: Bool, peakMiB: Int?, limitMiB limit: Int? = nil, ownLimitMiB: Int?) -> Bool { true }
}

// MARK: Setup, sign-in and the first game's guide

/// A Mac plays the games it built: no certificate, pairing file or Apple ID
/// to set up first.
@MainActor
final class CartoucheSetup: ObservableObject {
    static let shared = CartoucheSetup()

    var canPlay: Bool { true }
    var needsSetup: Bool { false }
    var bannerIcon: String { "checkmark.circle.fill" }
    var bannerTitle: String { "" }

    func refresh() {}
    func bannerDetail(signingInAgain: Bool, registeringDevice: Bool = false) -> String { "" }
}

/// No Apple ID signs in on the Mac.
@MainActor
final class CartoucheAccount: ObservableObject {
    static let shared = CartoucheAccount()

    typealias Phase = CartoucheSignInPhase

    @Published private(set) var phase: Phase?
    @Published private(set) var isAutomatic = false
}

/// The first game's guide is the iPhone's: the home has no card for it on
/// the Mac, whose games come from its Builder.
@MainActor
final class CartoucheGuide: ObservableObject {
    static let shared = CartoucheGuide()

    struct Progress: Equatable {}

    func progress(_ entries: CartoucheCatalog.Entries) -> Progress { Progress() }
    func showsCard(_ progress: Progress) -> Bool { false }
}

struct CartoucheGuideCard: View {
    let progress: CartoucheGuide.Progress
    let action: () -> Void

    var body: some View { EmptyView() }
}

// MARK: This Mac

/// What this Mac gives a game, under the iPhone's names.
enum CartoucheDevice {
    /// The model identifier, such as "Mac16,13".
    static let modelIdentifier: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }()

    /// macOS's version, where the iPhone says iOS's.
    static var iOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        return text
    }

    /// A game's sheet names the iOS it needs, which a game built for the
    /// Mac does not run on.
    static func runsAtLeast(_ minimum: String) -> Bool { true }

    static let supportsBCTextureCompression: Bool = MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression ?? false

    /// Increased Memory Limit is iOS's: a Mac's app has its memory without it.
    static let hasIncreasedMemoryLimit = true
}

/// The memory iOS lets an app use: a Mac sets no such limit.
struct CartoucheMemoryReading {
    let footprintBytes: UInt64
    let availableBytes: UInt64

    var limitBytes: UInt64 { footprintBytes + availableBytes }
    var limitMiB: Int { Int(limitBytes / 1_048_576) }
    var footprintMiB: Int { Int(footprintBytes / 1_048_576) }
    var availableMiB: Int { Int(availableBytes / 1_048_576) }

    static func now() -> CartoucheMemoryReading? { nil }
}

/// A signature that expires is the iPhone's: the Mac's app has none.
struct CartoucheSignature {
    let expirationDate: Date?
    let teamName: String?

    var daysLeft: Int? { nil }

    static func current() -> CartoucheSignature {
        CartoucheSignature(expirationDate: nil, teamName: nil)
    }
}

/// Cartouche renews its signature on the iPhone, by itself in its last
/// days (CartoucheRenewal.swift): the Mac's app has none to renew, so no
/// renewal is ever under way.
@MainActor
final class CartoucheRenewals: ObservableObject {
    static let shared = CartoucheRenewals()

    var isRenewing: Bool { false }
}

/// How a game fits this Mac. The testers' results are the iPhones': a
/// game nxnative built for this Mac has nobody's report here yet.
enum CartoucheFit: Hashable {
    case recommended
    case untested
    case notRecommended([String])
    case unsupported([String])

    var reasons: [String] {
        switch self {
        case .recommended, .untested: return []
        case .notRecommended(let reasons), .unsupported(let reasons): return reasons
        }
    }

    var title: String {
        switch self {
        case .recommended: return CartoucheText.fitRecommended
        case .untested: return CartoucheText.fitUntested
        case .notRecommended: return CartoucheText.fitNotRecommended
        case .unsupported: return CartoucheText.fitUnsupported
        }
    }

    var isPlayable: Bool {
        switch self {
        case .recommended, .untested: return true
        case .notRecommended, .unsupported: return false
        }
    }

    static func of(_ sheet: CartoucheGameSheet, limitMiB: Int?) -> CartoucheFit { .untested }

    static func withoutSheet() -> CartoucheFit? { nil }
}

// MARK: Reports

/// The journal the console's steps are noted in, and the reports of what
/// went wrong, as the iPhone's CartoucheReporting.swift makes them: kept
/// in memory on the Mac, whose reports come with its own page.
@MainActor
enum CartoucheReports {
    private static let journalLines = CartoucheJournal(file: nil)
    static let journalShown = 40

    static func note(_ text: String) {
        journalLines.note(redaction().redact(text))
    }

    static func journal(last count: Int) -> [String] {
        journalLines.last(count)
    }

    static func make(_ origin: CartoucheReport.Origin, _ title: String, message: String, error: Error? = nil,
                     step: String? = nil, fraction: Double? = nil, stage: String? = nil, seconds: Double? = nil,
                     failure: CartoucheFailure? = nil, facts: [CartoucheReport.Fact] = [],
                     inBackground: Bool = false) -> CartoucheReport {
        let failure = failure ?? error.map { CartoucheFailure.of($0, stage: stage, fraction: fraction, seconds: seconds) }
        let described = error.map { CartoucheReport.describe($0) }
        note("Problem (" + origin.rawValue + "): " + title + ": " + message + (described.map { " [" + $0 + "]" } ?? "")
             + (failure.map { " {" + $0.summary + "}" } ?? ""))
        return CartoucheReport(origin: origin, title: title, message: message, step: step, fraction: fraction,
                               error: described, failure: failure, facts: facts, environment: environment(),
                               journal: journal(last: journalShown))
    }

    /// The report's text, redacted, to copy.
    static func text(of report: CartoucheReport) -> String {
        report.text(redactedBy: redaction())
    }

    /// Puts the report's text on the pasteboard.
    static func copy(_ report: CartoucheReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(of: report), forType: .string)
        note("Report copied: " + report.title)
    }

    /// "the games folder, on SMB": where a step reads or writes, without a name.
    static func place(_ role: CartoucheStorageRole) -> String {
        guard let server = CartoucheStorageSettings.shared.location(role)?.server else { return "no \(role.rawValue) folder" }
        return "the \(role.rawValue) folder, on \(kindName(server.kind))"
    }

    static func kindName(_ kind: CartoucheStorageServer.Kind) -> String {
        switch kind {
        case .smb: return "SMB"
        case .folder: return "a folder"
        case .s3: return "S3"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .mac: return "Cartouche Builder on a Mac"
        case .drive: return "Google Drive"
        }
    }

    /// This Mac and this Cartouche, now.
    static func environment() -> CartoucheReport.Environment {
        let info = Bundle.main.infoDictionary ?? [:]
        let cartouche = info["CFBundleShortVersionString"] as? String ?? "?"
        let model = CartoucheDevice.modelIdentifier.isEmpty ? "?" : CartoucheDevice.modelIdentifier
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let language = (Bundle.main.preferredLocalizations.first ?? "?") + " (" + (Locale.preferredLanguages.first ?? "?") + ")"
        return CartoucheReport.Environment(cartouche: cartouche, basedOn: nil, system: "macOS " + CartoucheDevice.iOSVersion,
                                           device: "\(model) (\(memory) GB)", language: language, facts: [])
    }

    /// What the player's settings name, which a report never holds: their
    /// servers' addresses, the names of their places, their shared folders
    /// and buckets, the paths of their folders and their user names.
    static func redaction() -> CartoucheRedaction {
        let settings = CartoucheStorageSettings.shared
        var redaction = CartoucheRedaction()
        for server in settings.servers {
            redaction.servers.append(server.host)
            redaction.names.append(server.name)
            redaction.names.append(server.share)
            redaction.accounts.append(server.username)
        }
        redaction.paths = CartoucheStorageRole.allCases.compactMap { settings.place($0)?.path }
        return redaction
    }
}

// MARK: Saves

/// A game's saves on its sheet come with the Mac's saves page.
struct CartoucheSavesSection: View {
    let target: CartoucheSaveTarget
    let isRunning: Bool

    var body: some View { EmptyView() }
}
