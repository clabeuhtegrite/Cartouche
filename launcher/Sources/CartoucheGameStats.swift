//
//  CartoucheGameStats.swift
//  Cartouche
//
//  Each game's play time and size, on its sheet and under the game in
//  focus on the home: the time the game counted itself
//  (CartouchePlayTime.swift), the space it takes on this iPhone, measured
//  in the background once it may have changed (another install, or a game
//  played since), and the size of its IPA in the player's games folder.
//  Cartouche reads the times again whenever it comes back, and when a game
//  it shows in its own window pauses or ends.
//

import SwiftUI

@MainActor
final class CartoucheGameStats: ObservableObject {
    static let shared = CartoucheGameStats()

    /// The play time Cartouche read, kept on the iPhone.
    @Published private(set) var record = CartouchePlayTimeRecord()
    /// Each installed game's size, by bundle ID, as last measured.
    @Published private(set) var sizes: [String: Measure] = [:]

    struct Measure: Codable, Equatable {
        var size: CartoucheGameSize
        /// The bundle measured (CartoucheGameFolders.bundleKey).
        var bundleKey: String
        var measuredAt: Date
    }

    /// A game Cartouche shows in its own window paused, its console over
    /// it, or ended; the object is the game's LCAppModel.
    static let gameDidPause = Notification.Name("CartoucheGameDidPause")
    static let gameDidEnd = Notification.Name("CartoucheGameDidEnd")

    private let recordFile: URL
    private let sizesFile: URL
    /// The games to measure, one after the other.
    private var pending: [CartoucheGameFolders] = []
    private var measuring: String?
    private var observers: [NSObjectProtocol] = []
    #if CARTOUCHE_GALLERY
    private var shownForGallery = false
    #endif

    private init() {
        let manager = FileManager.default
        recordFile = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartouche/PlayTime.json")
        sizesFile = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartouche/GameSizes.json")
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: recordFile), let saved = try? decoder.decode(CartouchePlayTimeRecord.self, from: data) {
            record = saved
        }
        if let data = try? Data(contentsOf: sizesFile), let saved = try? decoder.decode([String: Measure].self, from: data) {
            sizes = saved
        }
        for name in [Self.gameDidPause, Self.gameDidEnd] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.object as? LCAppModel else { return }
                MainActor.assumeIsolated { self?.refreshSoon(app) }
            })
        }
    }

    /// The game's bundle ID as its IPA gave it, the same from one install
    /// to the next.
    static func bundleId(of app: LCAppModel) -> String? {
        (app.appInfo.info()?["LCOrignalBundleIdentifier"] as? String) ?? app.appInfo.bundleIdentifier()
    }

    /// Cartouche is back, maybe after a game: reads the play times of APPS,
    /// every installed app, again, and measures again the games that may
    /// have changed.
    func cameBack(_ apps: [LCAppModel]) {
        #if CARTOUCHE_GALLERY
        if shownForGallery { return }
        #endif
        let installed = Set(apps.compactMap { Self.bundleId(of: $0) })
        let kept = sizes.filter { installed.contains($0.key) }
        if kept.count != sizes.count {
            sizes = kept
            save(sizes, to: sizesFile)
        }
        refresh(apps)
    }

    /// Reads the play time of APPS again, and measures again those that
    /// may have changed.
    func refresh(_ apps: [LCAppModel]) {
        #if CARTOUCHE_GALLERY
        if shownForGallery { return }
        #endif
        var record = self.record
        var changed = false
        let found = apps.compactMap { CartoucheGameActions.shared.folders(of: $0) }
        for folders in found {
            for (name, time) in folders.playTimes() {
                changed = record.note(time, bundleId: folders.bundleId, titleId: folders.titleId, folder: name) || changed
            }
        }
        if changed {
            self.record = record
            save(record, to: recordFile)
        }
        for folders in found {
            measureIfNeeded(folders)
        }
    }

    /// The game writes its time in its own process as it leaves the front:
    /// read it a moment later.
    private func refreshSoon(_ app: LCAppModel) {
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            refresh([app])
        }
    }

    /// The game's play time on this iPhone, every data folder's together.
    func playTime(of entry: CartoucheEntry) -> CartouchePlayTime? {
        if let app = entry.app {
            let found = CartoucheCatalog.shared.gameTitle(of: app)
            return record.total(bundleId: Self.bundleId(of: app), titleId: found.flatMap { $0.isEmpty ? nil : $0 })
        }
        guard let stored = entry.stored else { return nil }
        return record.total(bundleId: stored.bundleId, titleId: stored.titleId)
    }

    /// The space the installed game takes on this iPhone, as last measured.
    func size(of app: LCAppModel) -> CartoucheGameSize? {
        Self.bundleId(of: app).flatMap { sizes[$0]?.size }
    }

    // MARK: Measuring

    /// Measures the game again when its bundle is another install, when it
    /// was played since, or a day later, since its caches change too.
    private func measureIfNeeded(_ folders: CartoucheGameFolders) {
        let id = folders.bundleId
        guard measuring != id, !pending.contains(where: { $0.bundleId == id }) else { return }
        if let measure = sizes[id], measure.bundleKey == folders.bundleKey {
            let lastPlayed = record.total(bundleId: id)?.lastPlayed ?? .distantPast
            if measure.measuredAt > lastPlayed, measure.measuredAt > Date().addingTimeInterval(-86_400) { return }
        }
        pending.append(folders)
        measureNext()
    }

    private func measureNext() {
        guard measuring == nil, !pending.isEmpty else { return }
        let folders = pending.removeFirst()
        measuring = folders.bundleId
        let key = folders.bundleKey
        // The bundle changes only with an install: measured once for it.
        let known = sizes[folders.bundleId].flatMap { $0.bundleKey == key ? $0.size.bundle : nil }
        Task {
            let start = Date()
            // Off the main thread: a game's bundle holds gigabytes, in
            // thousands of files.
            let size = await Task.detached(priority: .utility) { folders.measure(bundle: known) }.value
            sizes[folders.bundleId] = Measure(size: size, bundleKey: key, measuredAt: start)
            save(sizes, to: sizesFile)
            measuring = nil
            measureNext()
        }
    }

    private func save<Value: Encodable>(_ value: Value, to file: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    #if CARTOUCHE_GALLERY
    /// These sizes and play times, by bundle ID, for the launcher's gallery
    /// (launcher/Gallery).
    func showForGallery(sizes: [String: CartoucheGameSize], playTimes: [String: CartouchePlayTime]) {
        var record = CartouchePlayTimeRecord()
        for (bundleId, time) in playTimes {
            record.note(time, bundleId: bundleId, titleId: nil, folder: "gallery")
        }
        self.record = record
        self.sizes = sizes.mapValues { Measure(size: $0, bundleKey: "", measuredAt: Date()) }
        shownForGallery = true
    }
    #endif
}

/// A game's play time and size, on its sheet: the time counted on this
/// iPhone, the space the game takes here, and its IPA in the games folder.
@available(iOS 17.0, *)
struct CartoucheGameStatsSection: View {
    let entry: CartoucheEntry
    @ObservedObject private var stats = CartoucheGameStats.shared

    // Written out: before Swift 6.4 (SE-0502), the private state below made
    // the synthesized initializer private.
    init(entry: CartoucheEntry) {
        self.entry = entry
    }

    var body: some View {
        if entry.isOwned {
            Section(CartoucheText.statsTitle) {
                playTime
                if let app = entry.app {
                    onThisIPhone(app)
                        .task(id: entry.id) { stats.refresh([app]) }
                }
                if let stored = entry.stored {
                    LabeledContent(CartoucheText.statsStored(CartoucheStoredGames.shared.serverName ?? ""),
                                   value: CartoucheText.size(bytes: stored.size))
                }
            }
        }
    }

    @ViewBuilder
    private var playTime: some View {
        if let time = stats.playTime(of: entry) {
            LabeledContent {
                Text(CartoucheText.duration(seconds: time.seconds))
            } label: {
                Text(CartoucheText.statsPlayTime)
                if let detail = detail(time) {
                    Text(detail)
                }
            }
        } else if entry.app != nil {
            LabeledContent {
                Text(CartoucheText.statsNotCounted)
            } label: {
                Text(CartoucheText.statsPlayTime)
                Text(CartoucheText.statsCountedNext)
            }
        }
    }

    /// How many times the game was played, and when last.
    private func detail(_ time: CartouchePlayTime) -> String? {
        guard time.sessions > 0 else { return nil }
        let sessions = CartoucheText.statsSessions(time.sessions)
        guard let lastPlayed = time.lastPlayed else { return sessions }
        return CartoucheText.statsPlayTimeDetail(sessions, CartoucheText.lastPlayed(lastPlayed))
    }

    @ViewBuilder
    private func onThisIPhone(_ app: LCAppModel) -> some View {
        if let size = stats.size(of: app) {
            LabeledContent {
                Text(CartoucheText.size(bytes: size.total))
            } label: {
                Text(CartoucheText.onThisIPhone)
                Text(CartoucheText.statsSizeDetail(CartoucheText.size(bytes: size.bundle), CartoucheText.size(bytes: size.data)))
            }
        } else {
            LabeledContent(CartoucheText.onThisIPhone) {
                ProgressView()
            }
        }
    }
}

/// The play time and the size of the game in focus, on one line under its
/// name: on this iPhone, or in the games folder for a game only there.
@available(iOS 17.0, *)
struct CartoucheGameStatsLine: View {
    let entry: CartoucheEntry
    @ObservedObject private var stats = CartoucheGameStats.shared

    // Written out: before Swift 6.4 (SE-0502), the private state below made
    // the synthesized initializer private.
    init(entry: CartoucheEntry) {
        self.entry = entry
    }

    var body: some View {
        let time = stats.playTime(of: entry)
        let size: UInt64? = entry.app.map { stats.size(of: $0)?.total } ?? entry.stored?.size
        if time != nil || size != nil {
            HStack(spacing: 12) {
                if let time {
                    Label(CartoucheText.duration(seconds: time.seconds), systemImage: "clock")
                        .accessibilityLabel(Text(CartoucheText.statsPlayTime))
                        .accessibilityValue(Text(CartoucheText.duration(seconds: time.seconds)))
                }
                if let size {
                    Label(CartoucheText.size(bytes: size), systemImage: entry.app != nil ? "iphone" : "externaldrive")
                        .accessibilityLabel(Text(entry.app != nil ? CartoucheText.onThisIPhone
                                                    : CartoucheText.statsStored(CartoucheStoredGames.shared.serverName ?? "")))
                        .accessibilityValue(Text(CartoucheText.size(bytes: size)))
                }
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .labelStyle(CartoucheTightLabelStyle())
            .foregroundStyle(CartoucheTheme.secondaryText)
            .lineLimit(1)
        }
    }
}
