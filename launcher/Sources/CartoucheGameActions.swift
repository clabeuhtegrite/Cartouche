//
//  CartoucheGameActions.swift
//  Cartouche
//
//  What Cartouche does with a game, on its own screens: install the
//  player's IPA, start the game, open its settings, uninstall it. Each step
//  is the one LiveContainer's Apps tab takes (LCAppListView.installIpaFile,
//  LCAppModel.runApp, the container's Preferences page,
//  LCAppBannerViewController.uninstall), without its questions:
//
//  - an IPA comes from the Files picker, read in place, or from the player's
//    games folder (CartoucheStoredGames), unpacked as it arrives, so that
//    the iPhone never holds the IPA and the game at once;
//  - on an iPhone whose GPU nxnative refuses, the A16's and older, the
//    console asks first whether to install the game anyway: it would stop
//    there before its first image;
//  - the IPA of a game already installed replaces it in place, with its
//    settings and saves, as LiveContainer's Replace does;
//  - an IPA nxnative built without its game files comes with their image,
//    the romfs.img beside it in the games folder, copied into the game's
//    app after it; a new build of the game keeps the image the installed
//    one holds, when it needs the same (CartoucheRomfs);
//  - an installed game can be copied to the games folder as an IPA, before
//    it is uninstalled for one;
//  - an install or a copy goes on once the player leaves Cartouche, for the
//    half-minute iOS gives any app and, from iOS 26, until it is over, with
//    how far it has gone in a Live Activity whose stop button stops it
//    (CartoucheContinuedWork);
//  - an uninstalled game leaves its data folder, saves inside, unless the
//    player erases them too, and the game's next install takes it back;
//  - Play starts the game at once. nxnative shows its settings screen
//    before a game unless Documents/env.txt holds DM_LAUNCHER=0 (main.m,
//    Launcher.swift), which Play writes there; the game then applies the
//    choices saved in its preferences, which the game's settings page in
//    Cartouche writes (CartoucheGameSettings.swift). Start on nxnative's
//    screen takes the line out, so that the screen shows.
//  - The game runs behind the console, in a process of its own, so that
//    the Home button brings the player back to Cartouche without ending it
//    (CartoucheGameHost); one game at a time, and Quit ends it. A game that
//    needs more memory than it gets there starts in Cartouche's place, as
//    LiveContainer's Run does (CartoucheGameKeeping), and so does a game
//    that iOS stopped there within seconds, its process without Increased
//    Memory Limit, at once.
//
//  Each step goes into Cartouche's journal, and a step that fails tells the
//  player why with a report they can copy (CartoucheReporting.swift).
//

import Combine
import SwiftUI
import UIKit

/// Why an IPA could not be installed, as LiveContainer's Apps tab says it,
/// with its kind for the measurements.
struct CartoucheInstallError: LocalizedError, CartoucheDescribedError {
    enum Kind: String {
        case notAnIPA, noAppBundle, infoPlistUnreadable, appUnreadable, gameRunning
        /// An IPA that ends early, or whose file changed since it was packed,
        /// which LiveContainer's unpacker returns 2 for (livecontainer/0011).
        case damagedIPA
        /// An IPA built without its game files, whose image Cartouche did not
        /// find, or found another than the one it was built with.
        case gameFilesMissing, gameFilesMismatch
    }

    let kind: Kind
    var message: String?

    init(_ kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }

    var errorDescription: String? {
        if let message { return message }
        switch kind {
        case .notAnIPA: return "lc.appList.urlFileIsNotIpaError".loc
        case .damagedIPA: return CartoucheText.installDamagedIPA
        case .noAppBundle: return "lc.appList.bundleNotFondError".loc
        case .infoPlistUnreadable: return "lc.appList.infoPlistCannotReadError".loc
        case .appUnreadable: return "lc.appList.appInfoInitError".loc
        case .gameRunning, .gameFilesMissing, .gameFilesMismatch: return nil
        }
    }

    var failureKind: String { kind.rawValue }
    var failureCause: CartoucheFailure.Cause {
        switch kind {
        case .gameRunning: return .gameRunning
        case .gameFilesMissing, .gameFilesMismatch: return .fileMissing
        case .damagedIPA: return .fileUnreadable
        default: return .notAnApp
        }
    }
    var underlyingError: Error? { nil }
}

/// The image of its game files an install brings, for an IPA nxnative built
/// without them (CartoucheRomfs): none for an IPA that holds them, or when
/// the game's Documents holds the image.
struct CartoucheGameFiles {
    /// The image the installed copy of the game holds in its app, which
    /// goes over to the new one.
    var kept: URL?
    /// The image copied into the app after the IPA, and the one it must be.
    var copied: (source: CartoucheByteSource, needed: CartoucheRomfsIdentity)?

    var copiedSize: UInt64 { copied?.source.size ?? 0 }
}

@MainActor
final class CartoucheGameActions: ObservableObject {
    static let shared = CartoucheGameActions()

    /// What Cartouche is doing with a game, shown over the console and
    /// noted in the journal.
    @Published private(set) var work: CartoucheGameWork? {
        didSet {
            if oldValue == nil { workFailed = false }
            CartoucheReports.noteWork(from: oldValue, to: work, failed: workFailed)
            if let work { CartoucheContinuedWork.shared.update(work) }
        }
    }
    /// Why the last step failed, or what the player should know of it.
    @Published var notice: CartoucheGameNotice?
    /// The game the last import installed: the console shows it.
    @Published var installed: LCAppModel?
    /// The game running behind the console.
    @Published private(set) var running: CartoucheRunningGame?
    /// Another game the player asked for while one runs: the console asks
    /// before it quits the one that runs.
    @Published var switching: CartoucheGameSwitch?
    /// The running game the player asked to quit: the console asks first.
    @Published var quitQuestion: CartoucheRunningGame?
    /// The installs the console asks about first, on an iPhone whose GPU
    /// nxnative refuses (CartoucheInstallQuestions).
    @Published private var installQuestions = CartoucheInstallQuestions<CartoucheInstallQuestion>()
    /// The one on screen: whether to install the game anyway.
    var installQuestion: CartoucheInstallQuestion? { installQuestions.asked }

    /// What a report on the step under way says of it, such as its sizes.
    private var facts: [CartoucheReport.Fact] = []
    /// Whether the step under way failed, which its report noted.
    private var workFailed = false

    private var progressObservation: NSKeyValueObservation?
    private var signing: AnyCancellable?
    /// The time iOS gives a step that is on its way when the player leaves
    /// Cartouche.
    private var background: UIBackgroundTaskIdentifier = .invalid
    /// The install or the copy under way, which a stop from outside
    /// Cartouche cancels (CartoucheContinuedWork).
    private var transfer: Task<Void, Never>?
    /// Whether an install or a copy is on its way, which keeps the iPhone
    /// from locking until it is over (beginTransfer).
    var isTransferring: Bool { transfer != nil }
    /// Whether the player, or iOS, stopped it from outside Cartouche.
    private var stopped = false
    /// The game to start once the running one has ended.
    private var pendingStart: (app: LCAppModel, showingSettings: Bool)?
    /// The running game opened on nxnative's settings screen.
    private var runningShowsSettings = false

    /// Whether a file another app opened Cartouche with is an app to
    /// install: Cartouche installs it itself instead of the Apps tab
    /// (CartouchePairing.openedFile).
    nonisolated static func takes(_ url: URL) -> Bool {
        url.isFileURL && ["ipa", "tipa"].contains(url.pathExtension.lowercased())
    }

    // MARK: Install

    /// Whether the install of QUESTION's file or game starts now: nxnative
    /// refuses a GPU that cannot read BC-compressed textures, the A16's and
    /// older, for every game, which stops before its first image
    /// (dm/ios/Sources/main.m), so on such a GPU the console asks first,
    /// unless the player ANSWERED Install anyway. A question it takes the
    /// place of goes unanswered, as Cancel leaves it
    /// (CartoucheInstallQuestions).
    private func startsNow(_ question: CartoucheInstallQuestion, answered: Bool) -> Bool {
        let (starts, dropped) = installQuestions.install(
            question, readsBCTextures: CartoucheDevice.supportsBCTextureCompression, answered: answered)
        if let dropped { dropInstall(dropped) }
        if !starts {
            CartoucheReports.note(question.name + ": asked before its install, this iPhone's GPU cannot read BC-compressed textures")
        }
        return starts
    }

    /// The player's answer: the game installs all the same.
    func installAnyway(_ question: CartoucheInstallQuestion) {
        installQuestions.close(question)
        CartoucheReports.note(question.name + ": installs all the same")
        switch question.source {
        case .file(let url): install(url, asked: true)
        case .stored(let game): install(stored: game, asked: true)
        }
    }

    /// The player's answer: no install. The copy of a file another app
    /// opened Cartouche with goes, as after an install.
    func dropInstall(_ question: CartoucheInstallQuestion) {
        installQuestions.close(question)
        CartoucheReports.note(question.name + ": not installed")
        if case .file(let url) = question.source { Self.removeIfInbox(url) }
    }

    /// The question's alert closed: the question leaves the screen, which
    /// its buttons answer.
    func closeInstallQuestion() {
        if let asked = installQuestions.asked { installQuestions.close(asked) }
    }

    /// Installs the IPA the player picked or opened Cartouche with, read in
    /// place: a game's IPA is too large to copy first, so the access the
    /// picker granted stays open until the end. ASKED: the player said to
    /// install it on an iPhone whose GPU nxnative refuses.
    func install(_ url: URL, asked: Bool = false) {
        guard work == nil, startsNow(CartoucheInstallQuestion(source: .file(url)), answered: asked) else { return }
        facts = [.init("IPA", url.lastPathComponent), .init("From", "a file on this iPhone")]
        let model = DataManager.shared.model
        guard model.multiLCStatus != 2 else {
            fail(.install, CartoucheText.installFailed, message: "lc.appList.manageInPrimaryTip".loc, cause: .notPrimary)
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        // Over the console at once, as the picker goes, and checked off the
        // main thread: a file on a USB drive, a server in Files or iCloud
        // Drive takes a moment to answer, and so does iOS to say how much
        // room it can make.
        work = CartoucheGameWork(kind: .installing, name: url.deletingPathExtension().lastPathComponent,
                                 step: CartoucheText.installChecking, fraction: nil, stage: "checking")
        Task {
            guard let size = await Self.readableSize(of: url) else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                fail(.install, CartoucheText.installFailed, message: "lc.appList.ipaAccessError".loc, cause: .fileUnreadable)
                work = nil
                return
            }
            facts.insert(.init("IPA size", CartoucheReport.bytes(size)), at: 1)
            // An IPA built without its game files takes their image from
            // beside it, when Cartouche may read its folder.
            let gameFiles: CartoucheGameFiles
            do {
                gameFiles = try await planLocalGameFiles(ofIPA: url, model: model)
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                fail(.install, CartoucheText.installFailed, error: error)
                work = nil
                return
            }
            // Unpacking writes about as much as the IPA holds, and the image
            // of its game files as much as it is.
            let needed = size + Int64(clamping: gameFiles.copiedSize) + 512 * 1_048_576
            if let free = await Self.freeSpace(), free < needed {
                if accessing { url.stopAccessingSecurityScopedResource() }
                facts.append(.init("Needed", CartoucheReport.bytes(needed)))
                fail(.install, CartoucheText.installFailed,
                     message: CartoucheText.installNoSpace(needed: CartoucheText.storageAmount(bytes: needed),
                                                           free: CartoucheText.storageAmount(bytes: free)), cause: .noSpace)
                work = nil
                return
            }
            installChecked(url, size: size, accessing: accessing, into: model, gameFiles: gameFiles)
        }
    }

    /// Unpacks the IPA at URL, checked, and installs the game it holds, with
    /// the image of its game files GAMEFILES brings, if it needs one.
    private func installChecked(_ url: URL, size: Int64, accessing: Bool, into model: SharedModel, gameFiles: CartoucheGameFiles) {
        if var unpacking = work {
            unpacking.step = CartoucheText.installUnpacking
            unpacking.fraction = 0
            unpacking.stage = "unpacking"
            work = unpacking
        }
        beginTransfer()
        transfer = Task {
            do {
                let builtAt = await Self.builtAt(ofIPA: url)
                let (app, warning) = try await installUnpacked(into: model, builtAt: builtAt,
                                                               keeping: gameFiles.kept) { folder, whole in
                    // The IPA's part of the progress, and the image's.
                    let (progress, copying) = Self.split(whole, ipa: UInt64(clamping: size), gameFiles: gameFiles.copiedSize)
                    // A stop from outside Cartouche cancels the unpacking,
                    // which ends between two blocks of a file (LiveContainer
                    // patch 0009).
                    let unpacked = await withTaskCancellationHandler {
                        await Self.unpack(url.path, into: folder.path, progress)
                    } onCancel: {
                        progress.cancel()
                    }
                    try Task.checkCancellation()
                    guard unpacked == 0 else {
                        throw CartoucheInstallError(unpacked == 2 ? .damagedIPA : .notAnIPA)
                    }
                    if let copied = gameFiles.copied, let copying {
                        try await copyGameFiles(copied, into: folder, progress: copying)
                    }
                }
                await fetchSaves(of: app)
                finishInstall(app, warning: warning)
            } catch {
                if stopped {
                    tellStopped()
                } else {
                    fail(.install, CartoucheText.installFailed, error: error)
                }
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
            Self.removeIfInbox(url)
            endTransfer()
        }
    }

    /// Installs a game from the player's games folder, read where it sits:
    /// each file is unpacked as it arrives, so that the iPhone needs room for
    /// the game only, not for its IPA too. A connection that drops on the
    /// way, or stops answering, is made again, and the install reads on
    /// from where it stopped (CartoucheResumingSource). ASKED, as above.
    func install(stored game: CartoucheStoredGame, asked: Bool = false) {
        guard work == nil, let location = CartoucheStorageSettings.shared.location(.games),
              startsNow(CartoucheInstallQuestion(source: .stored(game)), answered: asked) else { return }
        facts = [.init("IPA", game.fileName), .init("IPA size", CartoucheReport.bytes(Int64(clamping: game.size))),
                 .init("From", CartoucheReports.place(.games))] + Self.buildFacts(game.build)
        let model = DataManager.shared.model
        guard model.multiLCStatus != 2 else {
            fail(.install, CartoucheText.installFailed, message: "lc.appList.manageInPrimaryTip".loc, cause: .notPrimary)
            return
        }
        let server = location.server
        let step = CartoucheText.installFromStorageStep(server.name)
        work = CartoucheGameWork(kind: .installing, name: game.name, step: step, fraction: nil, stage: "reading",
                                 place: server.name)
        beginTransfer()
        transfer = Task {
            var file: CartoucheResumingSource?
            var image: CartoucheResumingSource?
            do {
                let source = try await Self.openStored(game.path, on: server)
                file = source
                source.onRetry = { @Sendable _, _ in
                    Task { @MainActor in
                        CartoucheGameActions.shared.work?.step = CartoucheText.installFromStorageRetry(server.name)
                        CartoucheGameActions.shared.work?.stage = "reconnecting"
                    }
                }
                source.onResumed = { @Sendable in
                    Task { @MainActor in
                        CartoucheGameActions.shared.work?.step = step
                        CartoucheGameActions.shared.work?.stage = "reading"
                    }
                }
                let entries = try await CartoucheZip.entries(of: source)
                // An IPA built without its game files: their image comes from
                // the games folder too, unless the installed copy of the game
                // holds it already.
                let gameFiles = try await planGameFiles(ofIPA: source, entries: entries, model: model) { needed in
                    // The image the last read of the games folder found for
                    // it, else one put beside it since.
                    var path = game.gameFilesPath
                    if path == nil { path = await Self.storedImage(beside: game.path, size: needed.size, on: server) }
                    guard let path else { return nil }
                    let opened = try await Self.openStored(path, on: server)
                    image = opened
                    return opened
                }
                image?.onRetry = source.onRetry
                image?.onResumed = { @Sendable in
                    Task { @MainActor in
                        CartoucheGameActions.shared.work?.step = CartoucheText.installGameFiles
                        CartoucheGameActions.shared.work?.stage = "gameFiles"
                    }
                }
                let needed = Int64(clamping: entries.reduce(UInt64(0)) { $0 + $1.size } + gameFiles.copiedSize) + 512 * 1_048_576
                if let free = await Self.freeSpace(), free < needed {
                    throw CartoucheStorageError(.noSpaceHere, CartoucheText.installFromStorageNoSpace(
                        needed: CartoucheText.storageAmount(bytes: needed), free: CartoucheText.storageAmount(bytes: free)))
                }
                work?.fraction = 0
                work?.stage = "unpacking"
                let builtAt = CartoucheStoredGames.infoPlistEntry(in: entries)?.modified
                let (app, warning) = try await installUnpacked(into: model, builtAt: builtAt,
                                                               keeping: gameFiles.kept) { folder, whole in
                    // The IPA's part of the progress, and the image's.
                    let (progress, copying) = Self.split(whole, ipa: entries.reduce(UInt64(0)) { $0 + $1.size },
                                                         gameFiles: gameFiles.copiedSize)
                    try await CartoucheZip.extract(source, entries: entries, into: folder, progress: progress)
                    if let copied = gameFiles.copied, let copying {
                        // The IPA is read: its connection goes before the
                        // image's work.
                        await source.close()
                        try await copyGameFiles(copied, into: folder, progress: copying)
                    }
                }
                await fetchSaves(of: app)
                finishInstall(app, warning: warning)
            } catch let lost as CartoucheResumingSource.Lost where !stopped {
                facts.append(.init("Connection", "lost after \(lost.attempts) failed attempts, "
                                       + "the file opened again \(file?.reopened ?? 0) times before"))
                fail(.install, CartoucheText.installFailed,
                     message: CartoucheText.installFromStorageLost(server.name, lost.localizedDescription), error: lost.last)
            } catch let offline as CartoucheStorageOffline where !stopped {
                tellOffline(offline)
            } catch {
                if stopped {
                    tellStopped()
                } else {
                    if let reopened = file?.reopened, reopened > 0 {
                        facts.append(.init("Connection", "the file opened again \(reopened) times"))
                    }
                    fail(.install, CartoucheText.installFailed, error: error)
                }
            }
            endTransfer()
            // Last: a server that stopped answering keeps a goodbye waiting
            // a few seconds (CartoucheSMB.disconnect).
            await file?.close()
            await image?.close()
        }
    }

    /// The file at PATH of the games folder on SERVER, read where it sits,
    /// and opened again when its connection drops (CartoucheResumingSource).
    nonisolated private static func openStored(_ path: String,
                                               on server: CartoucheStorageServer) async throws -> CartoucheResumingSource {
        try await CartoucheResumingSource.open {
            // The server as the settings hold it now: an SFTP server keeps
            // the key it gave the first time.
            let current = await MainActor.run { CartoucheStorageSettings.shared.server(server.id) } ?? server
            let remote = try await CartoucheStorage.connect(current)
            do {
                let opened = try await remote.open(path)
                return CartoucheResumingSource.Opened(source: opened, close: { await remote.disconnect() })
            } catch {
                await remote.disconnect()
                throw error
            }
        }
    }

    /// An image of game files of SIZE in the folder of the IPA at PATH on
    /// SERVER, as the games folder pairs them (CartoucheRomfs.pair).
    nonisolated private static func storedImage(beside path: String, size: UInt64,
                                                on server: CartoucheStorageServer) async -> String? {
        let current = await MainActor.run { CartoucheStorageSettings.shared.server(server.id) } ?? server
        guard let remote = try? await CartoucheStorage.connect(current) else { return nil }
        let folder = CartoucheStoragePath.parent(path)
        let items = (try? await remote.list(folder)) ?? []
        await remote.disconnect()
        let images = items.filter { !$0.isFolder && CartoucheRomfs.isImageName($0.name) }.map { item in
            CartoucheRomfsImage(path: CartoucheStoragePath.join(folder, item.name), folder: folder, size: item.size)
        }
        let need = CartoucheRomfsNeed(path: path, folder: folder, size: size)
        return CartoucheRomfs.pair([need], with: images).taken[path]?.path
    }

    // MARK: Game files apart

    /// What an IPA built without its game files needs of them, and where
    /// they come from (CartoucheRomfs.plan): nothing, for an IPA that holds
    /// them; the image the installed copy of the game holds in its app, when
    /// it is the one this build needs; nothing again when the game's
    /// Documents holds that one, where nxnative looks first; else the image
    /// IMAGE opens, once checked. Throws, saying what to do, when none is
    /// the one.
    private func planGameFiles(ofIPA source: CartoucheByteSource, entries: [CartoucheZipEntry], model: SharedModel,
                               image: (CartoucheRomfsIdentity) async throws -> CartoucheByteSource?) async throws -> CartoucheGameFiles {
        guard let needed = try await CartoucheRomfs.neededIdentity(ofIPA: source, entries: entries) else { return .init() }
        let name = work?.name ?? ""
        facts.append(.init("Game files", "apart from the IPA, \(CartoucheReport.bytes(Int64(clamping: needed.size)))"))
        let bundleId = (try? await CartoucheStoredGames.infoPlist(of: source, entries: entries))?.info["CFBundleIdentifier"] as? String
        let installed = bundleId.flatMap { id in model.apps.first { $0.appInfo.bundleIdentifier() == id } }
        var app: URL?
        if let bundle = installed?.appInfo.bundlePath() {
            app = URL(fileURLWithPath: bundle, isDirectory: true)
        }
        // Where nxnative reads them before the app: in the Documents of the
        // data folder the game starts with, or of the one an uninstalled
        // copy left, which it takes back.
        let container = installed.flatMap { $0.uiSelectedContainer ?? $0.uiContainers.first }
            ?? bundleId.flatMap { Self.leftData(of: $0, model: model) }
        let documents = container?.containerURL.appendingPathComponent("Documents", isDirectory: true)
        do {
            switch try await CartoucheRomfs.plan(needed, installed: app, documents: documents, opening: image) {
            case .installed(let kept):
                facts.append(.init("Game files from", "the installed copy"))
                return CartoucheGameFiles(kept: kept)
            case .documents:
                facts.append(.init("Game files from", "the game's Documents"))
                return .init()
            case .copied(let opened):
                facts.append(.init("Game files from", "beside the IPA"))
                return CartoucheGameFiles(copied: (source: opened, needed: needed))
            }
        } catch CartoucheGameFilesProblem.missing {
            throw CartoucheInstallError(.gameFilesMissing, message: CartoucheText.installGameFilesMissing(name))
        } catch CartoucheGameFilesProblem.mismatch(let size) {
            facts.append(.init("Game files found", CartoucheReport.bytes(Int64(clamping: size))))
            throw CartoucheInstallError(.gameFilesMismatch, message: CartoucheText.installGameFilesMismatch(name))
        }
    }

    /// What the IPA at URL, picked in Files or opened from another app,
    /// needs of its game files: their image from beside it, when Cartouche
    /// may read the folder it is in, as one of its own. Another file than an
    /// IPA needs nothing here: unpacking it says what it is.
    private func planLocalGameFiles(ofIPA url: URL, model: SharedModel) async throws -> CartoucheGameFiles {
        guard let source = try? CartoucheFileSource(url), let entries = try? await CartoucheZip.entries(of: source) else {
            return .init()
        }
        do {
            return try await planGameFiles(ofIPA: source, entries: entries, model: model) { needed in
                guard let beside = CartoucheRomfs.image(beside: url, size: needed.size) else { return nil }
                return try CartoucheFileSource(beside)
            }
        } catch let error as CartoucheInstallError where error.kind == .gameFilesMissing {
            throw CartoucheInstallError(.gameFilesMissing, message: CartoucheText.installGameFilesApart(work?.name ?? ""))
        }
    }

    /// Copies the image of the game's files into the app the IPA unpacked
    /// into FOLDER, where nxnative reads it, and where a game built whole
    /// carries it.
    private func copyGameFiles(_ copied: (source: CartoucheByteSource, needed: CartoucheRomfsIdentity), into folder: URL,
                               progress: Progress) async throws {
        let payload = folder.appendingPathComponent("Payload", isDirectory: true)
        guard let bundle = try FileManager.default.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }) else {
            throw CartoucheInstallError(.noAppBundle)
        }
        work?.step = CartoucheText.installGameFiles
        work?.stage = "gameFiles"
        let into = payload.appendingPathComponent(bundle, isDirectory: true).appendingPathComponent(CartoucheRomfs.bundledName)
        // A stop from outside Cartouche ends it between two blocks.
        try await CartoucheRomfs.copy(copied.source, to: into, needed: copied.needed, progress: progress)
    }

    /// PROGRESS in two parts, as long as what each writes: the IPA's
    /// unpacking, then the copy of the image of its game files, if one
    /// comes.
    nonisolated private static func split(_ progress: Progress, ipa: UInt64, gameFiles: UInt64) -> (Progress, Progress?) {
        guard gameFiles > 0 else { return (progress, nil) }
        progress.totalUnitCount = 1000
        let share = Int64(1000 * (Double(ipa) / Double(ipa + gameFiles)))
        return (Progress(totalUnitCount: 1, parent: progress, pendingUnitCount: share),
                Progress(totalUnitCount: 1, parent: progress, pendingUnitCount: 1000 - share))
    }

    /// An install or a copy is on its way: iOS goes on with it once the
    /// player leaves Cartouche, for half a minute or, from iOS 26, until it
    /// is over, with how far it has gone on the Lock Screen and in the
    /// Dynamic Island (CartoucheContinuedWork).
    private func beginTransfer() {
        stopped = false
        // A large game takes minutes: the iPhone must not lock meanwhile
        // while Cartouche is in front, which would pause it.
        UIApplication.shared.isIdleTimerDisabled = true
        beginBackground()
        guard let work else { return }
        CartoucheContinuedWork.shared.begin(work, outside: { outside in
            CartoucheGameActions.shared.work?.outside = outside
        }, stop: {
            CartoucheGameActions.shared.stopFromOutside()
        })
    }

    /// The install or the copy is over, whether it went through or not.
    private func endTransfer() {
        progressObservation = nil
        transfer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        CartoucheContinuedWork.shared.end(success: !workFailed)
        endBackground()
        work = nil
    }

    /// The player stopped the install or the copy from the Live Activity,
    /// or iOS did, while Cartouche was in the background: it stops, unless
    /// the game is in place already, once it is being signed, and its
    /// install finishes.
    private func stopFromOutside() {
        guard let work, transfer != nil, !stopped else { return }
        self.work?.outside = false
        if Self.finishing.contains(work.stage) {
            CartoucheReports.note(work.title + ": the game is in place already, and its install goes on")
            return
        }
        stopped = true
        transfer?.cancel()
    }

    /// The stages of an install where the game is in place already: it is
    /// signed, then its saves come.
    private static let finishing: Set<String> = ["signing", "savesSync"]

    /// The half-minute iOS gives a step on its way when the player leaves
    /// Cartouche, so that a short absence does not pause it.
    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Cartouche game") {
            // iOS calls this on the main thread, as the time runs out, and
            // stops Cartouche unless the task ends before it returns.
            MainActor.assumeIsolated { CartoucheGameActions.shared.endBackground() }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private func finishInstall(_ app: LCAppModel, warning: String?) {
        installed = app
        if let warning {
            // Installed, but not signed: the game would not start.
            fail(.install, CartoucheText.installSignWarning, message: warning, cause: .notSigned)
        } else if CartoucheCatalog.shared.entries(for: [app]).owned.isEmpty {
            notice = CartoucheGameNotice(title: CartoucheText.installDone, message: CartoucheText.installNotAGame(app.displayName))
        }
    }

    /// Unpacks an IPA with UNPACK into a folder of Cartouche's, then installs
    /// the app it holds, and notes which build of the game it is, BUILTAT
    /// being when the IPA was built (CartoucheInstalledBuilds). KEEPING: the
    /// image of the game's files in the installed copy's app, which goes
    /// over to the new one.
    private func installUnpacked(into model: SharedModel, builtAt: Date?, keeping kept: URL? = nil,
                                 unpack: (URL, Progress) async throws -> Void) async throws -> (LCAppModel, String?) {
        let fileManager = FileManager.default
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        let relay = CartoucheProgressRelay()
        // Called on the thread that unpacks or signs.
        progressObservation = progress.observe(\.fractionCompleted) { @Sendable progress, _ in
            let fraction = progress.fractionCompleted
            guard relay.changed(fraction) else { return }
            Task { @MainActor in
                CartoucheGameActions.shared.work?.fraction = fraction
            }
        }

        // Its own folder, apart from the one the Apps tab unpacks into.
        let folder = fileManager.temporaryDirectory.appendingPathComponent("CartoucheInstall", isDirectory: true)
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        let unpacking = Progress.discreteProgress(totalUnitCount: 100)
        progress.addChild(unpacking, withPendingUnitCount: 80)
        try await unpack(folder, unpacking)
        let payload = folder.appendingPathComponent("Payload", isDirectory: true)
        // An IPA holds its app in Payload: a zip without that folder holds
        // no app either, rather than a folder iOS says it cannot find.
        guard let bundleName = (try? fileManager.contentsOfDirectory(atPath: payload.path))?.first(where: { $0.hasSuffix(".app") }) else {
            throw CartoucheInstallError(.noAppBundle)
        }
        let unpacked = payload.appendingPathComponent(bundleName)
        // LCAppInfo reads an Info.plist it cannot read as an empty one, and
        // calls its app "Unknown": the app's own must give its identifier.
        guard let plist = NSDictionary(contentsOf: unpacked.appendingPathComponent("Info.plist")),
              (plist["CFBundleIdentifier"] as? String)?.isEmpty == false,
              let newInfo = LCAppInfo(bundlePath: unpacked.path), let bundleId = newInfo.bundleIdentifier() else {
            throw CartoucheInstallError(.infoPlistUnreadable)
        }
        work?.name = newInfo.displayName() ?? work?.name ?? ""

        // The same game installed already: this copy takes its place.
        let previous = model.apps.first { $0.appInfo.bundleIdentifier() == bundleId }
        if let previous, previous === running?.app {
            throw CartoucheInstallError(.gameRunning, message: CartoucheText.quitFirst(previous.displayName))
        }
        // Moved, not copied: the image is as large as the game, and the
        // installed copy goes next.
        if let kept {
            try CartoucheRomfs.keep(kept, in: unpacked)
        }
        var relativePath = "\(bundleId.sanitizeNonACSII()).app"
        var destination = LCPath.bundlePath.appendingPathComponent(relativePath)
        if let previous, let previousPath = previous.appInfo.relativeBundlePath {
            relativePath = previousPath
            destination = (previous.uiIsShared ? LCPath.lcGroupBundlePath : LCPath.bundlePath).appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
        } else if fileManager.fileExists(atPath: destination.path)
                    || model.hiddenApps.contains(where: { $0.appInfo.bundleIdentifier() == bundleId }) {
            // A folder of that name that no app of the list uses, or a
            // hidden copy: a folder of its own, as the Apps tab makes.
            relativePath = "\(bundleId)_\(Int(CFAbsoluteTimeGetCurrent())).app"
            destination = LCPath.bundlePath.appendingPathComponent(relativePath)
        }
        try fileManager.moveItem(at: unpacked, to: destination)
        guard let info = LCAppInfo(bundlePath: destination.path) else {
            throw CartoucheInstallError(.appUnreadable)
        }
        info.relativeBundlePath = relativePath

        work?.step = CartoucheText.installSigning
        work?.stage = "signing"
        if previous?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
            info.dontSign = true
        }
        var signError: String?
        var signSuccess = false
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            info.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                continuation.resume()
            }, progressHandler: { signProgress in
                if let signProgress {
                    progress.addChild(signProgress, withPendingUnitCount: 20)
                }
            }, forceSign: false)
        }
        // Installed even if signing failed, as the Apps tab leaves it.
        var warning: String?
        if let signError {
            warning = signSuccess ? "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)" : signError.loc
        }

        if let previous {
            Self.carry(previous.appInfo, to: info)
        } else {
            info.spoofSDKVersion = true
            // The saves an uninstalled copy of this game left.
            if let left = Self.leftData(of: bundleId, model: model) {
                info.containers = [left]
                info.dataUUID = left.folderName
            }
        }
        info.installationDate = Date.now

        // No delegate: Play gives runApp Cartouche's own while the game starts.
        let app = LCAppModel(appInfo: info)
        var build = CartoucheInstalledBuilds.installedBuild(of: app)
        build.builtAt = builtAt
        CartoucheInstalledBuilds.shared.record(build, bundleId: bundleId)
        if let previous {
            model.apps.removeAll { $0 == previous }
        } else if let schemes = info.urlSchemes(), schemes.count > 0 {
            UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes").addObjects(from: schemes as! [Any])
        }
        model.apps.append(app)
        return (app, warning)
    }

    /// The settings of the copy an IPA replaces, as the Apps tab carries
    /// them over.
    private static func carry(_ old: LCAppInfo, to info: LCAppInfo) {
        info.autoSaveDisabled = true
        info.isLocked = old.isLocked
        info.isHidden = old.isHidden
        info.isJITNeeded = old.isJITNeeded
        info.isShared = old.isShared
        info.spoofSDKVersion = old.spoofSDKVersion
        info.doSymlinkInbox = old.doSymlinkInbox
        info.containerInfo = old.containerInfo
        info.tweakFolder = old.tweakFolder
        info.selectedLanguage = old.selectedLanguage
        info.dataUUID = old.dataUUID
        info.orientationLock = old.orientationLock
        info.dontInjectTweakLoader = old.dontInjectTweakLoader
        info.hideLiveContainer = old.hideLiveContainer
        info.dontLoadTweakLoader = old.dontLoadTweakLoader
        info.doUseLCBundleId = old.doUseLCBundleId
        info.fixFilePickerNew = old.fixFilePickerNew
        info.fixLocalNotification = old.fixLocalNotification
        info.lastLaunched = old.lastLaunched
        info.jitLaunchScriptJs = old.jitLaunchScriptJs
        info.multitaskSpecified = old.multitaskSpecified
        info.classicMode = old.classicMode
        info.autoSaveDisabled = false
        info.save()
    }

    /// The data folder an uninstalled copy of the game left: the newest one
    /// made for this bundle ID that no installed app uses.
    private static func leftData(of bundleId: String, model: SharedModel) -> LCContainer? {
        let used = Set((model.apps + model.hiddenApps).flatMap { $0.uiContainers.map(\.folderName) })
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: LCPath.dataPath, includingPropertiesForKeys: keys,
                                                                       options: .skipsHiddenFiles) else { return nil }
        var found: (folder: String, name: String, date: Date)?
        for folder in folders where !used.contains(folder.lastPathComponent) {
            guard let plist = NSDictionary(contentsOf: folder.appendingPathComponent("LCContainerInfo.plist")) as? [String: Any],
                  plist["appIdentifier"] as? String == bundleId else { continue }
            let date = (try? folder.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if found == nil || date > found!.date {
                found = (folder.lastPathComponent, plist["name"] as? String ?? folder.lastPathComponent, date)
            }
        }
        guard let found else { return nil }
        return LCContainer(folderName: found.folder, name: found.name, isShared: false)
    }

    nonisolated private static func unpack(_ path: String, into destination: String, _ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }

    /// When the IPA at URL was built: the time of its Info.plist in it.
    nonisolated private static func builtAt(ofIPA url: URL) async -> Date? {
        guard let source = try? CartoucheFileSource(url), let entries = try? await CartoucheZip.entries(of: source) else { return nil }
        return CartoucheStoredGames.infoPlistEntry(in: entries)?.modified
    }

    /// The room this iPhone has for a game, off the main thread: iOS counts
    /// what it could free for it, which takes it a moment.
    nonisolated private static func freeSpace() async -> Int64? {
        let values = try? LCPath.docPath.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The size of the IPA at URL, if Cartouche can read it, off the main
    /// thread: the file may be on a USB drive, a server in Files or iCloud
    /// Drive.
    nonisolated private static func readableSize(of url: URL) async -> Int64? {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// The copy iOS makes in Documents/Inbox of a file opened from another
    /// app goes once installed, as the Apps tab deletes it.
    private static func removeIfInbox(_ url: URL) {
        let inbox = LCPath.docPath.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        if url.deletingLastPathComponent().standardizedFileURL == inbox {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Copy to the games folder

    /// Copies the game, as Cartouche installed it, to the player's games
    /// folder as an IPA, "<game> [<title ID>].ipa", which the library lists
    /// and Cartouche installs again. What LiveContainer added for this
    /// iPhone stays out: its record of the install, the signature and the
    /// provisioning profile, which names the iPhone; the next install signs
    /// the game again. THEN runs once the copy is in place.
    func export(_ app: LCAppModel, titleId: String?, then next: (() -> Void)? = nil) {
        guard work == nil, let bundlePath = app.appInfo.bundlePath(),
              let location = CartoucheStorageSettings.shared.location(.games) else { return }
        let bundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let name = CartoucheStoredGame.fileName(game: app.displayName, titleId: titleId)
        let path = CartoucheStoragePath.join(location.path, name)
        // The copy's Info.plist keeps the time the game's IPA gave it, which
        // says when the game was built (CartoucheGameBuild).
        let build = CartoucheInstalledBuilds.shared.build(of: app)
        let builtAt = build.builtAt
        facts = [.init("To", CartoucheReports.place(.games))] + Self.buildFacts(build)
        work = CartoucheGameWork(kind: .exporting, name: app.displayName,
                                 step: CartoucheText.exportStep(location.server.name), fraction: 0, stage: "exporting",
                                 place: location.server.name)
        beginTransfer()
        transfer = Task {
            var remote: CartoucheRemote?
            var copied = false
            do {
                let connected = try await CartoucheStorage.connect(location.server)
                remote = connected
                if await CartoucheStorageSettings.shared.checkAccess(connected, server: location.server.id,
                                                                     path: location.path) == false {
                    throw CartoucheStorageError(.readOnly, CartoucheText.exportReadOnly(location.server.name))
                }
                var items = try await Self.exportedItems(of: bundle)
                let infoPlist = "Payload/\(bundle.lastPathComponent)/Info.plist"
                if let builtAt, let index = items.firstIndex(where: { $0.name == infoPlist }) {
                    let item = items[index]
                    items[index] = CartoucheExportedItem(name: item.name, url: item.url, kind: item.kind, size: item.size,
                                                         mode: item.mode, date: builtAt)
                }
                let total = items.reduce(UInt64(0)) { $0 + $1.size }
                facts.append(.init("IPA size", CartoucheReport.bytes(Int64(clamping: total))))
                if let free = try? await connected.freeSpace(), free < total + 64 << 20 {
                    throw CartoucheStorageError(.noSpaceThere, CartoucheText.exportNoSpace(
                        needed: CartoucheText.storageAmount(bytes: Int64(clamping: total)),
                        server: location.server.name,
                        free: CartoucheText.storageAmount(bytes: Int64(clamping: free))))
                }
                let upload = try await connected.create(path, size: nil)
                do {
                    try await Self.writeIPA(items, to: upload, total: total)
                    try await upload.finish()
                } catch {
                    // Out of the stopped copy's task, whose cancellation
                    // would leave what it wrote there.
                    await Task { await upload.cancel() }.value
                    throw error
                }
                copied = true
            } catch let offline as CartoucheStorageOffline where !stopped {
                tellOffline(offline)
            } catch {
                if stopped {
                    tellStopped()
                } else {
                    fail(.export, CartoucheText.exportFailed, error: error)
                }
            }
            await remote?.disconnect()
            let wasStopped = stopped
            endTransfer()
            if copied {
                await CartoucheStoredGames.shared.reload()
                // A stop as the copy ended stops what came next too.
                if !wasStopped { next?() }
            }
        }
    }

    /// What LiveContainer writes into a bundle for this iPhone: left out of
    /// a copy.
    nonisolated static func isLeftOut(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/")
        guard let last = parts.last else { return false }
        if parts.contains("_CodeSignature") { return true }
        if parts.count == 1, last == "LCAppInfo.plist" || last == "embedded.mobileprovision" { return true }
        return last.hasSuffix("_LiveContainerPatchBackUp")
    }

    /// The bundle's folders, files and links under Payload/<bundle>/, in a
    /// steady order, without what isLeftOut names. Links stay links.
    nonisolated static func exportedItems(of bundle: URL) async throws -> [CartoucheExportedItem] {
        let top = "Payload/" + bundle.lastPathComponent
        guard let root = status(of: bundle), root.type == S_IFDIR,
              let walker = FileManager.default.enumerator(atPath: bundle.path) else {
            throw CartoucheStorageError(.gameUnreadable, CartoucheText.exportUnreadable)
        }
        var items = [CartoucheExportedItem(name: top + "/", url: bundle, kind: .folder, size: 0, mode: root.mode, date: root.date)]
        while let relative = walker.nextObject() as? String {
            try Task.checkCancellation()
            if isLeftOut(relative) {
                walker.skipDescendants()
                continue
            }
            let url = bundle.appendingPathComponent(relative)
            guard let found = status(of: url) else { throw CartoucheStorageError(.gameUnreadable, CartoucheText.exportUnreadable) }
            let name = top + "/" + relative
            switch found.type {
            case S_IFDIR:
                items.append(CartoucheExportedItem(name: name + "/", url: url, kind: .folder, size: 0, mode: found.mode, date: found.date))
            case S_IFLNK:
                items.append(CartoucheExportedItem(name: name, url: url, kind: .link, size: 0, mode: found.mode, date: found.date))
            case S_IFREG:
                items.append(CartoucheExportedItem(name: name, url: url, kind: .file, size: found.size, mode: found.mode, date: found.date))
            default:
                continue
            }
        }
        return items.sorted { $0.name < $1.name }
    }

    /// The type, permissions, size and date of the item at URL itself, a
    /// link's own and not its target's.
    nonisolated private static func status(of url: URL) -> (type: mode_t, mode: UInt32, size: UInt64, date: Date)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return (info.st_mode & S_IFMT, UInt32(info.st_mode & 0o7777), UInt64(max(info.st_size, 0)), date)
    }

    /// Writes ITEMS to UPLOAD as a zip, off the main thread, and shows how
    /// far it is.
    nonisolated private static func writeIPA(_ items: [CartoucheExportedItem], to upload: CartoucheRemoteUpload,
                                             total: UInt64) async throws {
        let writer = CartoucheZipWriter(sink: upload)
        let relay = CartoucheProgressRelay()
        var done: UInt64 = 0
        let report: (UInt64) -> Void = { added in
            done += added
            let fraction = total == 0 ? 1 : Double(done) / Double(total)
            guard relay.changed(fraction) else { return }
            Task { @MainActor in
                CartoucheGameActions.shared.work?.fraction = fraction
            }
        }
        for item in items {
            try Task.checkCancellation()
            switch item.kind {
            case .folder:
                try await writer.addFolder(item.name, mode: item.mode, date: item.date)
            case .link:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.url.path)
                try await writer.addSymlink(item.name, target: target, date: item.date)
            case .file:
                try await writer.addFile(item.name, from: item.url, mode: item.mode, date: item.date, after: report)
            }
        }
        try await writer.finish()
    }

    // MARK: Play

    /// Starts the game, signed for this iPhone first if it needs to be,
    /// behind the console or in Cartouche's place. With showingSettings,
    /// nxnative shows its settings screen before the game. The game that
    /// runs behind the console comes back to the screen instead; another
    /// game takes its place once the player has said so.
    func play(_ app: LCAppModel, showingSettings: Bool = false) {
        if let running {
            if running.app === app && !showingSettings {
                resumeRunningGame()
            } else {
                switching = CartoucheGameSwitch(running: running, next: app, showingSettings: showingSettings)
            }
            return
        }
        guard work == nil, !app.isAppRunning else { return }
        facts = Self.buildFacts(CartoucheInstalledBuilds.shared.build(of: app))
            + [.init("nxnative's settings screen", showingSettings ? "shown" : "skipped")]
        work = CartoucheGameWork(kind: .starting, name: app.displayName,
                                 step: showingSettings ? CartoucheText.startSettings : CartoucheText.startSoon, fraction: nil,
                                 stage: "preparing")
        signing = app.$signProgress
            .combineLatest(app.$isSigningInProgress)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                let (fraction, inProgress) = value
                guard inProgress else { return }
                self?.work?.step = CartoucheText.installSigning
                self?.work?.stage = "signing"
                self?.work?.fraction = fraction
            }
        Task {
            let delegate = app.delegate
            do {
                // Starting the game closes Cartouche: the syncs of saves
                // under way finish first, then the newest saves come, as
                // when another iPhone played the game since.
                let backups = CartoucheSaveBackups.shared
                if backups.isSyncing {
                    work?.step = CartoucheText.savesFinishing
                    work?.stage = "savesFinishing"
                }
                await backups.finish()
                await fetchSaves(of: app)
                work?.step = showingSettings ? CartoucheText.startSettings : CartoucheText.startSoon
                work?.stage = "starting"
                try Self.prepareStart(of: app, showingSettings: showingSettings)
                if #available(iOS 18.0, *), try await startBehindConsole(app, showingSettings: showingSettings) {
                    signing = nil
                    work = nil
                    return
                }
                // The questions runApp may ask come to Cartouche.
                app.delegate = self
                if let container = Self.dataFolder(of: app) {
                    NotificationCenter.default.post(name: .cartoucheGameStarts, object: app, userInfo: [
                        "dataFolder": container.folderName, "started": Date(), "behind": false,
                    ])
                }
                try await app.runApp(multitask: false, forceJIT: false)
            } catch let error where error.localizedDescription == "lc.signer.latestCertificateInvalidErr".loc {
                // iOS refused the certificate LiveContainer signed the game
                // with: Cartouche has SideStore fetch the one that works.
                CartoucheSetup.shared.certificateRefusedAtStart()
                fail(.start, CartoucheText.startFailed, message: CartoucheImportedSigning.isSelected ? CartoucheText.signingRefused : CartoucheText.startCertificateRefused, error: error)
            } catch {
                fail(.start, CartoucheText.startFailed, error: error)
            }
            // Still here: the game did not start.
            app.delegate = delegate
            signing = nil
            work = nil
        }
    }

    /// Starts the game behind the console, if it plays there: true once it
    /// runs. False when it starts in Cartouche's place instead, as before:
    /// the player turned it off, the game needs more memory than it gets
    /// there, or it did not start there.
    @available(iOS 18.0, *)
    private func startBehindConsole(_ app: LCAppModel, showingSettings: Bool) async throws -> Bool {
        guard startsBehindConsole(app), let bundle = app.appInfo.relativeBundlePath,
              let container = Self.dataFolder(of: app) else { return false }
        // What runApp does first: it signs the game and its tweaks.
        try await app.signApp(force: false)
        let started = Date()
        running = CartoucheRunningGame(app: app, dataFolder: container.folderName, started: started, isInFront: true)
        runningShowsSettings = showingSettings
        NotificationCenter.default.post(name: .cartoucheGameStarts, object: app, userInfo: [
            "dataFolder": container.folderName, "started": started, "behind": true,
        ])
        do {
            try await CartoucheGameHost.shared.start(app, bundle: bundle, dataFolder: container.folderName)
        } catch {
            running = nil
            NSLog("[Cartouche] %@ did not start behind the console, it starts in Cartouche's place: %@",
                  app.displayName, String(describing: error))
            return false
        }
        app.appInfo.lastLaunched = Date()
        return true
    }

    @available(iOS 18.0, *)
    private func startsBehindConsole(_ app: LCAppModel) -> Bool {
        let keeping = CartoucheGameKeeping.shared
        let info = app.appInfo
        guard keeping.keepsConsoleOpen, CartoucheGameKeeping.isAvailable,
              // LiveContainer runs these only in its own place.
              info.defaultClassicMode == 0, !info.isJITNeeded, !info.is32bit,
              !keeping.startsInPlace(bundleId: info.bundleIdentifier(),
                                     ownLimitMiB: CartoucheMemoryReading.now()?.limitMiB) else { return false }
        return fitsBehindConsole(app, limitMiB: nil)
    }

    /// Whether the game starts behind the console, by its sheet, with the
    /// limit measured there: unless it needs more, and Cartouche's place
    /// has more.
    private func fitsBehindConsole(_ app: LCAppModel, limitMiB: Int?) -> Bool {
        let needs = sheetNeeds(of: app)
        return CartoucheGameKeeping.shared.fitsBehind(needsIML: needs.iml, peakMiB: needs.peakMiB, limitMiB: limitMiB,
                                                      ownLimitMiB: CartoucheMemoryReading.now()?.limitMiB)
    }

    /// What the game's sheet says it needs: Increased Memory Limit, and its
    /// peak; nothing for a game without a sheet.
    private func sheetNeeds(of app: LCAppModel) -> (iml: Bool, peakMiB: Int?) {
        let sheet = CartoucheCatalog.shared.entries(for: [app]).owned.first?.sheet
        return (sheet?.requirements.increasedMemoryLimit ?? false, sheet?.peakMemoryMiB)
    }

    // MARK: The game behind the console

    /// The game behind the console, on screen again, where it was.
    func resumeRunningGame() {
        if #available(iOS 18.0, *) {
            CartoucheGameHost.shared.showGame()
        }
    }

    /// The console asks whether to quit the running game.
    func askToQuit() {
        quitQuestion = running
    }

    func quitRunningGame() {
        quitQuestion = nil
        if #available(iOS 18.0, *) {
            CartoucheGameHost.shared.quit()
        }
    }

    /// The player said so: the running game quits, and the other starts
    /// once it has.
    func confirmSwitch(_ change: CartoucheGameSwitch) {
        switching = nil
        pendingStart = (change.next, change.showingSettings)
        quitRunningGame()
    }

    /// The running game went behind the console, paused, or came back.
    func gameDidMove(inFront: Bool) {
        guard let current = running else { return }
        running?.isInFront = inFront
        if !inFront {
            NotificationCenter.default.post(name: .cartoucheGameDidPause, object: current.app)
        }
    }

    /// The first reading of the running game's memory: the limit iOS set
    /// behind the console, and whether the game's process has Increased
    /// Memory Limit. A game that needs more starts again in Cartouche's
    /// place at once, before the player is into it, when that place has
    /// more: from then on, for its own needs; for the capability missing
    /// there, with every game whose peak does not fit there
    /// (CartoucheGamePlace.afterMeasure).
    func gameMeasured(_ app: LCAppModel, reading: CartoucheGameMemoryReading) {
        let keeping = CartoucheGameKeeping.shared
        keeping.measured(reading)
        guard running?.app === app, pendingStart == nil, let bundleId = app.appInfo.bundleIdentifier() else { return }
        let needs = sheetNeeds(of: app)
        let after = CartoucheGamePlace.afterMeasure(limitMiB: reading.limitMiB, needsIML: needs.iml, peakMiB: needs.peakMiB,
                                                    behindLacksIML: keeping.behindLacksIML,
                                                    ownMiB: CartoucheMemoryReading.now()?.limitMiB)
        guard case .startsAgainInPlace(let fromNowOn) = after else { return }
        NSLog("[Cartouche] %@ needs more memory than the %lld MiB it has behind the console%@: it starts in Cartouche's place",
              app.displayName, reading.limitMiB, keeping.behindLacksIML ? ", without Increased Memory Limit" : "")
        if fromNowOn {
            keeping.startInPlace(bundleId: bundleId)
        }
        pendingStart = (app, runningShowsSettings)
        quitRunningGame()
    }

    /// The running game has ended: the player quit it, or iOS stopped it,
    /// and then the console says so. A game iOS stopped close to its memory
    /// limit starts in Cartouche's place from then on, when that place has
    /// more; otherwise it stays behind the console, where it has as much.
    /// One that iOS stopped before its first measurement, on screen, its
    /// process without Increased Memory Limit, starts again in Cartouche's
    /// place at once, as gameMeasured would have started it: Donkey Kong
    /// Bananza lasted two seconds there (CartoucheGamePlace.afterStop).
    func gameDidEnd(_ app: LCAppModel, quit: Bool, wasInFront: Bool, reading: CartoucheGameMemoryReading?) {
        guard let ended = running, ended.app === app else { return }
        running = nil
        quitQuestion = nil
        switching = nil
        let keeping = CartoucheGameKeeping.shared
        // The last reading of a game that ended early is its only one.
        if let reading { keeping.measured(reading) }
        var info: [String: Any] = ["quit": quit, "dataFolder": ended.dataFolder, "started": ended.started]
        if let reading { info["reading"] = reading }
        NotificationCenter.default.post(name: .cartoucheGameDidEnd, object: app, userInfo: info)
        if !quit {
            let title = CartoucheText.gameStoppedTitle(app.displayName)
            let needs = sheetNeeds(of: app)
            let after = CartoucheGamePlace.afterStop(limitMiB: reading?.limitMiB, nearLimit: reading?.wasNearLimit ?? false,
                                                     wasInFront: wasInFront, startPending: pendingStart != nil,
                                                     needsIML: needs.iml, peakMiB: needs.peakMiB,
                                                     behindLacksIML: keeping.behindLacksIML,
                                                     ownMiB: CartoucheMemoryReading.now()?.limitMiB)
            let limit = CartoucheText.memoryAmount(mebibytes: reading?.limitMiB ?? 0)
            let stopped = CartoucheGameNotice(title: title,
                                              message: wasInFront ? CartoucheText.gameStopped : CartoucheText.gameStoppedPaused)
            switch after {
            case .startsAgainInPlace:
                NSLog("[Cartouche] %@ ended behind the console, with %lld MiB and without Increased Memory Limit: it starts again in Cartouche's place",
                      app.displayName, reading?.limitMiB ?? 0)
                pendingStart = (app, runningShowsSettings)
            case .staysBehind:
                notice = CartoucheGameNotice(title: title, message: CartoucheText.gameStoppedMemoryBehind(limit))
            case .startsInPlaceFromNowOn:
                if let bundleId = app.appInfo.bundleIdentifier() {
                    keeping.startInPlace(bundleId: bundleId)
                    notice = CartoucheGameNotice(title: title, message: CartoucheText.gameStoppedMemory(limit))
                } else {
                    notice = stopped
                }
            case .stopped:
                notice = stopped
            }
        }
        copySaves(of: [app])
        if let next = pendingStart {
            pendingStart = nil
            // Once LiveContainer has let go of the game's data folder.
            Task { play(next.app, showingSettings: next.showingSettings) }
        }
    }

    /// nxnative's switch for its settings screen, in the data folder the
    /// game starts with, and the game's language.
    private static func prepareStart(of app: LCAppModel, showingSettings: Bool) throws {
        let container = dataFolder(of: app)
        // Only an nxnative game reads it.
        guard let bundle = app.appInfo.bundlePath(),
              FileManager.default.fileExists(atPath: (bundle as NSString).appendingPathComponent("dm")),
              let container else { return }
        try CartoucheStartSwitch.write(showingSettings: showingSettings, home: container.containerURL)
        chooseLanguage(of: app, bundle: URL(fileURLWithPath: bundle, isDirectory: true), container: container)
    }

    /// The language the game starts in: the first of the iPhone's that the
    /// game has, unless the player chose one (CartoucheGameLanguage), saved
    /// where nxnative keeps the player's choice, so that its screen shows
    /// it too. A game of one language has nothing to choose.
    private static func chooseLanguage(of app: LCAppModel, bundle: URL, container: LCContainer) {
        guard let row = CartoucheGameSetting.rows(inBundle: bundle)?.first(where: { $0.env == CartoucheGameLanguage.variable }),
              row.kind == "choice",
              CartoucheGameSetting.fixedValues(home: container.containerURL, bundle: bundle)[row.env] == nil,
              let domain = app.appInfo.bundleIdentifier(),
              let choices = CartoucheGamePreferences(domain: domain, home: guestHome(of: container)) else { return }
        let preferred = Locale.preferredLanguages
        let offered = row.optionValues
        let record = CartoucheGameLanguage.beforeStart(choices.languageRecord, preferred: preferred, offered: offered,
                                                      gameDefault: row.def)
        choices.keepLanguage(record)
        let language = CartoucheGameLanguage.language(of: record, offered: offered, gameDefault: row.def)
        let source: String
        if record.source == .player {
            source = "the player's choice"
        } else if CartoucheGameLanguage.best(for: preferred, among: offered) == nil {
            source = "its own, as it has none of the iPhone's"
        } else {
            source = "the iPhone's"
        }
        CartoucheReports.note(app.displayName + ": starts in " + language + ", " + source)
    }

    /// The data folder runApp starts the game with, made as runApp makes it
    /// on a first start.
    private static func dataFolder(of app: LCAppModel) -> LCContainer? {
        if app.uiContainers.isEmpty, let bundleId = app.appInfo.bundleIdentifier() {
            let name = NSUUID().uuidString
            let container = LCContainer(folderName: name, name: name, isShared: app.uiIsShared)
            app.uiContainers.append(container)
            if app.uiSelectedContainer == nil {
                app.uiSelectedContainer = container
            }
            app.appInfo.containers = app.uiContainers
            container.makeLCContainerInfoPlist(appIdentifier: bundleId,
                                               keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
            app.appInfo.dataUUID = name
            app.uiDefaultDataFolder = name
        }
        return app.uiSelectedContainer ?? app.uiContainers.first
    }

    /// The game's home, letter for letter as LiveContainer sets HOME for it
    /// (LCBootstrap.m), so that its preferences are the ones cfprefsd hands
    /// the game.
    private static func guestHome(of container: LCContainer) -> URL {
        if container.storageBookMark == nil, !container.isShared, let home = getenv("LC_HOME_PATH") {
            return URL(fileURLWithPath: String(cString: home) + "/Documents/Data/Application/" + container.folderName,
                       isDirectory: true)
        }
        return container.containerURL
    }

    // MARK: Saves

    /// Where the game keeps its saves: the Documents of the data folder it
    /// starts with. Nil for an app that is not an nxnative game, or a game
    /// that has no data folder yet: one installed while no saves folder was
    /// chosen, which never started.
    func saves(of app: LCAppModel) -> CartoucheSaveTarget? {
        let catalog = CartoucheCatalog.shared
        guard let found = catalog.gameTitle(of: app), let bundleId = app.appInfo.bundleIdentifier(),
              let container = app.uiSelectedContainer ?? app.uiContainers.first else { return nil }
        let titleId = found.isEmpty ? catalog.titleId(matchingName: app.displayName) : found
        return CartoucheSaveTarget(key: bundleId + "|" + container.folderName, name: app.displayName, titleId: titleId,
                                   documents: container.containerURL.appendingPathComponent("Documents", isDirectory: true))
    }

    /// Where an nxnative game writes its logs, in the data folder it plays
    /// with, for Share the log on its sheet (CartoucheGameLogView); nil for
    /// any other app, or a game that has no data folder yet.
    func logs(of app: LCAppModel) -> CartoucheGameLogFolder? {
        let catalog = CartoucheCatalog.shared
        guard let found = catalog.gameTitle(of: app),
              let container = app.uiSelectedContainer ?? app.uiContainers.first else { return nil }
        let titleId = found.isEmpty ? catalog.titleId(matchingName: app.displayName) : found
        let build = CartoucheInstalledBuilds.shared.record(of: app) ?? CartoucheInstalledBuilds.installedBuild(of: app)
        return CartoucheGameLogFolder(game: app.displayName, titleId: titleId, build: build,
                                      documents: container.containerURL.appendingPathComponent("Documents", isDirectory: true))
    }

    /// Sends the saves of the nxnative games among APPS that changed since
    /// they were last in step with the player's saves folder, if they chose
    /// one (CartoucheSaveBackups).
    func copySaves(of apps: [LCAppModel]) {
        let backups = CartoucheSaveBackups.shared
        guard backups.isOn, work == nil else { return }
        // The game behind the console may be writing its saves: they go
        // once it has ended.
        backups.copyChanged(apps.filter { $0 !== running?.app }.compactMap { saves(of: $0) })
    }

    /// Syncs the game's saves with the player's saves folder, if they chose
    /// one, the newest copy coming when it is the one to play: when the game
    /// is installed, as after Cartouche was installed again, and before it
    /// starts, as when another iPhone played it since. The game gets its
    /// data folder for it, as on its first start. A server offline from
    /// here is left alone: the game plays with the saves it has. What did
    /// not go through shows on the game's sheet.
    private func fetchSaves(of app: LCAppModel) async {
        let backups = CartoucheSaveBackups.shared
        guard backups.isOn, CartoucheCatalog.shared.gameTitle(of: app) != nil,
              let location = CartoucheStorageSettings.shared.location(.saves),
              !CartoucheStorageReach.shared.isOffline(location.server.id) else { return }
        _ = Self.dataFolder(of: app)
        guard let target = saves(of: app) else { return }
        work?.step = CartoucheText.savesSyncing(location.server.name)
        work?.stage = "savesSync"
        work?.fraction = nil
        await backups.sync(target)
    }

    // MARK: Size and play time

    /// The game's bundle and its data folders in Cartouche, for its size and
    /// its play time (CartoucheGameStats): not the folders the player picked
    /// elsewhere, which LiveContainer's storage page leaves out too. Nil for
    /// an app that is not an nxnative game.
    func folders(of app: LCAppModel) -> CartoucheGameFolders? {
        guard let found = CartoucheCatalog.shared.gameTitle(of: app), let bundlePath = app.appInfo.bundlePath(),
              let bundleId = CartoucheGameStats.bundleId(of: app) else { return nil }
        var data: [String: URL] = [:]
        for container in app.uiContainers where container.storageBookMark == nil {
            data[container.folderName] = container.containerURL
        }
        return CartoucheGameFolders(bundleId: bundleId, titleId: found.isEmpty ? nil : found,
                                    bundle: URL(fileURLWithPath: bundlePath, isDirectory: true), data: data)
    }

    // MARK: Settings

    /// The game's settings page: the rows of its dm/launcher.json, and the
    /// choices in the game's own preferences, in the data folder it starts
    /// with (made now if the game never started).
    func settings(for app: LCAppModel, tileKey: String) -> CartoucheGameSettingsModel {
        let bundle = app.appInfo.bundlePath().map { URL(fileURLWithPath: $0, isDirectory: true) }
        let container = Self.dataFolder(of: app)
        var choices: CartoucheGameChoices?
        // The game's domain: LiveContainer gives the game its own bundle ID,
        // the original one when the game borrows LiveContainer's.
        if let container, let domain = app.appInfo.bundleIdentifier() {
            choices = CartoucheGamePreferences(domain: domain, home: Self.guestHome(of: container))
        }
        return CartoucheGameSettingsModel(
            name: app.displayName,
            tileKey: tileKey,
            settings: bundle.flatMap { CartoucheGameSetting.rows(inBundle: $0) } ?? [],
            fixed: bundle.map { CartoucheGameSetting.fixedValues(home: container?.containerURL, bundle: $0) } ?? [:],
            choices: choices)
    }

    // MARK: Uninstall

    /// Removes the game. Its data folder stays, with the saves, unless
    /// erasingData: then it goes too, as LiveContainer deletes it. What the
    /// game makes again at each start goes either way.
    func uninstall(_ app: LCAppModel, erasingData: Bool) {
        guard work == nil, let bundlePath = app.appInfo.bundlePath() else { return }
        if app === running?.app {
            notice = CartoucheGameNotice(title: CartoucheText.uninstallFailed, message: CartoucheText.quitFirst(app.displayName))
            return
        }
        let model = DataManager.shared.model
        // Folders the player picked elsewhere are theirs: never deleted.
        let folders = app.uiContainers.filter { $0.storageBookMark == nil }.map { container in
            (name: container.folderName,
             url: (container.isShared ? LCPath.lcGroupDataPath : LCPath.dataPath).appendingPathComponent(container.folderName))
        }
        facts = [.init("Saves", erasingData ? "erased too" : "kept")]
        work = CartoucheGameWork(kind: .uninstalling, name: app.displayName, step: CartoucheText.uninstallStep, fraction: nil,
                                 stage: "removing")
        Task {
            do {
                try await Self.remove(bundlePath: bundlePath, folders: folders.map(\.url), erasingData: erasingData)
                model.apps.removeAll { $0 == app }
                model.hiddenApps.removeAll { $0 == app }
                if erasingData {
                    for folder in folders {
                        LCUtils.removeAppKeychain(dataUUID: folder.name)
                        model.appDataFolderNames.removeAll { $0 == folder.name }
                    }
                }
            } catch {
                fail(.uninstall, CartoucheText.uninstallFailed, error: error)
            }
            work = nil
        }
    }

    // MARK: Reports

    /// Tells the player that the step could not start, since the server it
    /// needs is offline from here: without a report, since nothing went
    /// wrong in Cartouche (CartoucheStorageReach).
    private func tellOffline(_ offline: CartoucheStorageOffline) {
        CartoucheReports.note((work.map { $0.title + ": " } ?? "") + "not started, the server is offline from this network")
        workFailed = true
        notice = CartoucheGameNotice(title: offline.title, message: offline.localizedDescription)
    }

    /// Tells the player that the install or the copy stopped from outside
    /// Cartouche: without a report, since nothing went wrong in Cartouche.
    private func tellStopped() {
        guard let work else { return }
        workFailed = true
        notice = CartoucheGameNotice(title: work.kind == .exporting ? CartoucheText.exportStopped : CartoucheText.installStopped,
                                     message: CartoucheText.workStoppedOutside)
    }

    /// Tells the player that the step failed, with the report they can copy:
    /// TITLE, and MESSAGE, or else ERROR's, as they read it. CAUSE says why
    /// when ERROR does not, nor any of LiveContainer's own errors it may be.
    private func fail(_ origin: CartoucheReport.Origin, _ title: String, message: String? = nil, error: Error? = nil,
                      cause: CartoucheFailure.Cause? = nil) {
        let message = message ?? error?.localizedDescription ?? ""
        let stage = work.map(\.stage).flatMap { $0.isEmpty ? nil : $0 }
        let seconds = work.map { Date().timeIntervalSince($0.started) }
        var failure: CartoucheFailure?
        if let cause {
            failure = CartoucheFailure(cause, stage: stage, fraction: work?.fraction, seconds: seconds)
        } else if let error, let known = Self.liveContainerErrors.first(where: { error.localizedDescription == $0.key.loc }) {
            failure = CartoucheFailure(known.cause, stage: stage, fraction: work?.fraction, seconds: seconds,
                                       details: ["kind": .text(known.kind)])
        }
        let report = CartoucheReports.make(origin, title, message: message, error: error,
                                           step: work.map { $0.title + ": " + $0.step }, fraction: work?.fraction,
                                           stage: stage, seconds: seconds, failure: failure, facts: facts)
        workFailed = true
        notice = CartoucheGameNotice(title: title, message: message, report: report)
    }

    /// LiveContainer's errors are their text alone, in the player's
    /// language: those Cartouche tells apart, by the key of their text.
    private static let liveContainerErrors: [(key: String, kind: String, cause: CartoucheFailure.Cause)] = [
        ("lc.signer.latestCertificateInvalidErr", "latestCertificateInvalid", .certificate),
        ("lc.signer.noCertificateFoundErr", "noCertificateFound", .certificate),
        ("lc.signer.crashDuringSignErr", "crashDuringSign", .notSigned),
    ]

    /// "Game build: 1.0.0, nxnative 844bf1a5ea8f, built 2026-11-06 19:12:40 +0100".
    private static func buildFacts(_ build: CartoucheGameBuild?) -> [CartoucheReport.Fact] {
        guard let build else { return [] }
        var parts: [String] = []
        if let version = build.version { parts.append(version) }
        if let commit = build.shortCommit { parts.append("nxnative " + commit + (build.isDirty ? "+dirty" : "")) }
        if let builtAt = build.builtAt { parts.append("built " + CartoucheReport.timestamp(builtAt)) }
        return parts.isEmpty ? [] : [.init("Game build", parts.joined(separator: ", "))]
    }

    /// Off the main thread: a game's bundle holds gigabytes.
    nonisolated private static func remove(bundlePath: String, folders: [URL], erasingData: Bool) async throws {
        let fileManager = FileManager.default
        try fileManager.removeItem(atPath: bundlePath)
        for folder in folders {
            if erasingData {
                try fileManager.removeItem(at: folder)
            } else {
                // The guest's memory files and caches; Documents keeps the saves.
                for leftover in ["tmp", "Library/Caches", "Documents/temp"] {
                    try? fileManager.removeItem(at: folder.appendingPathComponent(leftover))
                }
            }
        }
    }
}

// MARK: Questions from runApp

extension CartoucheGameActions: LCAppModelDelegate {
    nonisolated func closeNavigationView() {}

    nonisolated func changeAppVisibility(app: LCAppModel) {}

    // Play never asks for JIT (forceJIT: false): nxnative games run without.
    nonisolated func jitLaunch(appName: String, classicMode: UInt) async {}

    nonisolated func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {}

    nonisolated func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async {}

    /// An app runs in a window of its own: the player pressed Play, so it
    /// closes, as the Apps tab's Continue does.
    nonisolated func showRunWhenMultitaskAlert() async -> Bool? { true }
}

/// A folder, file or link of an installed game's bundle, as it goes into the
/// IPA Cartouche copies to the games folder.
struct CartoucheExportedItem: Hashable {
    enum Kind: Hashable { case folder, file, link }

    /// Its path in the IPA; a folder's ends with "/".
    let name: String
    let url: URL
    let kind: Kind
    let size: UInt64
    let mode: UInt32
    let date: Date
}

/// nxnative's switch for its settings screen, in a game's Documents/env.txt
/// (main.m reads it before the game starts). Cartouche keeps every other
/// line of the file.
enum CartoucheStartSwitch {
    static let key = "DM_LAUNCHER"
    static let note = "# Cartouche: Play starts the game at once; Game settings shows the settings screen first."

    static func write(showingSettings: Bool, home: URL) throws {
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let file = documents.appendingPathComponent("env.txt")
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = old.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix(key + "=") && trimmed != note
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        if !showingSettings {
            lines += [note, key + "=0"]
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        guard text != old else { return }
        if text.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// A game's preferences, opened as LiveContainer's own Preferences page for
/// a data folder opens them (LCAppPreferenceView.swift): the game's domain
/// in its data folder, through cfprefsd, where the game's standard defaults
/// point (LiveContainer's NSUserDefaults.m). Going through cfprefsd as the
/// game does, neither side reads a stale copy.
final class CartoucheGamePreferences: CartoucheGameChoices {
    private let defaults: UserDefaults

    init?(domain: String, home: URL) {
        // cfprefsd writes the game's file there; the game makes it at its
        // first start.
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Preferences", isDirectory: true),
                                                 withIntermediateDirectories: true)
        guard let defaults = UserDefaults()._init(withSuiteName: domain, container: home) else { return nil }
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.object(forKey: key) as? String
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        // Play quits Cartouche for the game at once: the change reaches
        // cfprefsd first.
        defaults.synchronize()
    }
}

/// Lets a progress through to the screen once per thousandth: unpacking
/// reports every block it writes, from another thread.
final class CartoucheProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func changed(_ fraction: Double) -> Bool {
        let step = Int(fraction * 1000)
        lock.lock()
        defer { lock.unlock() }
        guard step != last else { return false }
        last = step
        return true
    }
}
