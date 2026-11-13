//
//  CartoucheGameSheetView.swift
//  Cartouche
//
//  A game's sheet. On top, its cover, name and badges, and its main action:
//  Play for the player's own copy, with Game settings and, when the games
//  folder holds a newer build, Update beside it, or Resume, with Quit, for
//  the game paused behind the console; Install from the player's
//  games folder for a copy there; or Import my copy. Under them, its
//  description, the player's or IGDB's (CartoucheGameSummaryView), the time
//  the player played it and the space it takes (CartoucheGameStats), what
//  stops the game on this iPhone, if anything (what it needs folds into
//  one line when this iPhone has it all), its build on the player's Mac,
//  with the button that asks the Mac for one, once Cartouche reaches the
//  Mac and its Cartouche Builder knows the game (CartoucheMacBuildsView),
//  the copies of its saves, Edit
//  the game's info for the player's own game (CartoucheGameInfoView), with
//  what IGDB has of a game Cartouche does not know, after which the sheet
//  goes back to its top, where the name and cover show; the game's copy in
//  the games folder and Uninstall, the testers' results, and last, folded,
//  the technical details: the recommended settings, what nxnative's
//  profile says and which build is installed.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheGameSheetView: View {
    let entry: CartoucheEntry
    let memory: CartoucheMemoryReading?
    let onPlay: (LCAppModel) -> Void
    /// Opens the game's settings page.
    let onSettings: (LCAppModel) -> Void
    /// Opens Files. The view that presents the sheet holds the one file
    /// importer of its presentation: SwiftUI presents only one of several.
    let onImport: () -> Void
    /// Asks whether to uninstall the game, and whether its saves stay.
    let onUninstall: (LCAppModel) -> Void
    /// Installs the game's IPA from the player's games folder.
    var onInstallStored: (CartoucheStoredGame) -> Void = { _ in }
    /// Copies the installed game to the player's games folder.
    var onExport: (LCAppModel) -> Void = { _ in }
    /// Opens what the player says of their game: its name, platform, genre
    /// and cover.
    var onEditInfo: () -> Void = {}
    @ObservedObject private var actions = CartoucheGameActions.shared
    @ObservedObject private var keeping = CartoucheGameKeeping.shared
    @ObservedObject private var reach = CartoucheStorageReach.shared
    /// The player's Mac, asked its builds while the sheet shows.
    @StateObject private var macBuilds = CartoucheMacBuildsWatch()

    // Written out: the private state above would make the synthesized
    // initializer private.
    init(entry: CartoucheEntry, memory: CartoucheMemoryReading?, onPlay: @escaping (LCAppModel) -> Void,
         onSettings: @escaping (LCAppModel) -> Void, onImport: @escaping () -> Void,
         onUninstall: @escaping (LCAppModel) -> Void,
         onInstallStored: @escaping (CartoucheStoredGame) -> Void = { _ in },
         onExport: @escaping (LCAppModel) -> Void = { _ in },
         onEditInfo: @escaping () -> Void = {}) {
        self.entry = entry
        self.memory = memory
        self.onPlay = onPlay
        self.onSettings = onSettings
        self.onImport = onImport
        self.onUninstall = onUninstall
        self.onInstallStored = onInstallStored
        self.onExport = onExport
        self.onEditInfo = onEditInfo
    }

    /// The memory the game has here, where Play starts it: behind the
    /// console, iOS may give it more than Cartouche's own limit.
    private var gameLimitMiB: Int? {
        keeping.gameLimitMiB(ownLimitMiB: memory?.limitMiB)
    }

    private var fit: CartoucheFit? {
        entry.sheet.map { CartoucheFit.of($0, limitMiB: gameLimitMiB) }
    }

    private var serverName: String {
        CartoucheStoredGames.shared.serverName ?? ""
    }

    /// Whether the games folder's server does not answer from here.
    private var isGamesFolderOffline: Bool {
        guard let server = CartoucheStorageSettings.shared.location(.games)?.server else { return false }
        return reach.isOffline(server.id)
    }

    /// Whether the games folder is on a Google Drive whose sign-in Google
    /// ended: the player signs in again, rather than waits.
    private var isGamesFolderSignedOut: Bool {
        guard let server = CartoucheStorageSettings.shared.location(.games)?.server else { return false }
        return reach.isOffline(server.id) && CartoucheStorageOffline(server).isSignedOut
    }

    /// The header's row, which the sheet goes back to when what the player
    /// says of the game changes.
    private static let top = "top"

    /// The game's title IDs, as the player's Mac may know it: its regions',
    /// and those its copies say.
    private var macTitleIds: [String] {
        var seen = Set<String>()
        let ids = (entry.game?.titleIds ?? []) + [entry.titleId, entry.ownTitleId, entry.stored?.titleId].compactMap { $0 }
        return ids.filter { seen.insert($0.uppercased()).inserted }
    }

    var body: some View {
        ScrollViewReader { reader in
            List {
                Section {
                    header
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .id(Self.top)
                }

                if let summary = entry.summary {
                    Section {
                        CartoucheGameSummaryView(text: summary, isIGDBs: entry.player?.summary == nil)
                    }
                }

                CartoucheGameStatsSection(entry: entry)

                if let sheet = entry.sheet {
                    if let fit, !fit.reasons.isEmpty {
                        Section {
                            ForEach(fit.reasons, id: \.self) { reason in
                                Label(reason, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(fit.isPlayable ? Color.primary : Color.orange)
                            }
                        }
                    }
                    requirements(sheet)
                } else {
                    // nxnative refuses this GPU for every game, with a sheet or
                    // without.
                    if let fit = CartoucheFit.withoutSheet() {
                        Section {
                            ForEach(fit.reasons, id: \.self) { reason in
                                Label(reason, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.orange)
                            }
                        }
                    }
                    if entry.isOwned {
                        Section {
                            Text(CartoucheText.noSheetMessage)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                CartoucheMacBuildsSection(titleIds: macTitleIds, isOwned: entry.isOwned, watch: macBuilds)

                if let app = entry.app, let saves = actions.saves(of: app) {
                    CartoucheSavesSection(target: saves, isRunning: actions.isRunning(app))
                }

                if entry.isOwned {
                    infoSection
                }

                if let app = entry.app {
                    manageSection(app)
                }

                if let sheet = entry.sheet, !sheet.results.isEmpty {
                    results(sheet)
                }

                if hasDetails {
                    detailsSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(CartoucheStage(key: entry.tileKey, art: entry.backdrop))
            .onAppear { macBuilds.start() }
            .onDisappear { macBuilds.stop() }
            #if CARTOUCHE_GALLERY
            // The gallery's sheet on the game's build on the Mac, its
            // section's title in view (screen: sheet-mac).
            .task {
                guard CartoucheMacBuildsWatch.galleryScrolls else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                reader.scrollTo(CartoucheMacBuildsSection.anchor, anchor: UnitPoint(x: 0.5, y: 0.2))
            }
            #endif
            // What the player gave in Edit the game's info shows at once:
            // the sheet goes back to the game's name and cover.
            .onChange(of: entry.player) { _, _ in
                withAnimation { reader.scrollTo(Self.top, anchor: .top) }
            }
        }
        // The header names the game: the bar above it stays empty.
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                CartoucheGameCartridge(entry: entry, width: 104, isPaused: actions.isRunning(entry.app))
                    .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.name)
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .accessibilityAddTraits(.isHeader)
                    // For the player's own copy, the badge says whether it
                    // is ready, or what stops it; while the game runs
                    // behind the console, the line says it is paused.
                    let isRunning = actions.isRunning(entry.app)
                    CartoucheMetaLine(entry: entry, showsStatus: entry.app == nil || entry.sheet == nil || isRunning,
                                      isPaused: isRunning)
                    if entry.sheet != nil, !isRunning {
                        CartoucheFitBadge(fit: fit, owned: entry.app != nil)
                    }
                }
            }

            if let app = entry.app, actions.isRunning(app) {
                primaryButton(CartoucheText.resume, systemImage: "play.fill") { onPlay(app) }
                HStack(spacing: 10) {
                    secondaryButton(CartoucheText.gameSettings, systemImage: "slider.horizontal.3") { onSettings(app) }
                    secondaryButton(CartoucheText.quit, systemImage: "stop.circle") { actions.askToQuit() }
                }
                buildLine(CartoucheText.pausedDetail, systemImage: "pause.circle")
            } else if let app = entry.app {
                primaryButton(CartoucheText.play, systemImage: "play.fill") { onPlay(app) }
                HStack(spacing: 10) {
                    secondaryButton(CartoucheText.gameSettings, systemImage: "slider.horizontal.3") { onSettings(app) }
                    if let update = entry.update {
                        secondaryButton(CartoucheText.updateGame, systemImage: "arrow.down.circle.fill") { onInstallStored(update) }
                    }
                }
                if entry.update != nil, isGamesFolderOffline {
                    if isGamesFolderSignedOut {
                        buildLine(CartoucheText.statusUpdateSignedOut(serverName), systemImage: "person.crop.circle.badge.exclamationmark")
                    } else {
                        buildLine(CartoucheText.statusUpdateOffline(serverName), systemImage: "wifi.slash")
                    }
                }
                if let update = entry.update, let build = update.build {
                    buildLine(CartoucheText.buildNewer(serverName, CartoucheText.build(build, showsCommit: false)),
                              systemImage: "arrow.down.circle")
                    if let installed = installedBuild(of: app, showsCommit: false) {
                        buildLine(CartoucheText.buildHere(installed), systemImage: "iphone")
                    }
                }
            } else if let stored = entry.stored {
                primaryButton(CartoucheText.installFrom(serverName), systemImage: "arrow.down.circle.fill") { onInstallStored(stored) }
                secondaryButton(CartoucheText.importOtherCopy, systemImage: "square.and.arrow.down", action: onImport)
                if isGamesFolderOffline {
                    if isGamesFolderSignedOut {
                        buildLine(CartoucheText.statusStoredSignedOut(serverName), systemImage: "person.crop.circle.badge.exclamationmark")
                    } else {
                        buildLine(CartoucheText.statusStoredOffline(serverName), systemImage: "wifi.slash")
                    }
                }
            } else {
                primaryButton(CartoucheText.importCopy, systemImage: "square.and.arrow.down", action: onImport)
            }
        }
        .padding(.vertical, 8)
    }

    /// The sheet's main action, white on Cartouche's indigo: a list would
    /// otherwise tint its symbol with the accent colour.
    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .controlSize(.large)
        .cartouchePrimaryButton()
    }

    private func secondaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 26)
        }
        .controlSize(.regular)
        .cartoucheSecondaryButton()
    }

    private func buildLine(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(CartoucheTheme.secondaryText)
            .lineLimit(3)
    }

    /// Which build of the game is installed, in a few words: as the IPA
    /// Cartouche installed it from said, or, for a game installed before
    /// Cartouche kept that, its version, commit and install date.
    private func installedBuild(of app: LCAppModel, showsCommit: Bool = true) -> String? {
        if let recorded = CartoucheInstalledBuilds.shared.record(of: app) {
            return CartoucheText.build(recorded, showsCommit: showsCommit)
        }
        let build = CartoucheInstalledBuilds.installedBuild(of: app)
        let installedAt: Date? = app.appInfo.installationDate
        guard build.version != nil || build.commit != nil || installedAt != nil else { return nil }
        return CartoucheText.build(build, installedOn: installedAt, showsCommit: showsCommit)
    }

    // MARK: On this iPhone

    private struct Requirement: Hashable {
        let ok: Bool
        let title: String
        let detail: String
    }

    private func requirementList(_ sheet: CartoucheGameSheet) -> [Requirement] {
        var list = [Requirement(ok: CartoucheDevice.runsAtLeast(sheet.requirements.minimumIOS),
                                title: CartoucheText.iosRequirement(sheet.requirements.minimumIOS),
                                detail: CartoucheText.iosCurrent(CartoucheDevice.iOSVersion))]
        if sheet.requirements.bcTextureCompression || !CartoucheDevice.supportsBCTextureCompression {
            list.append(Requirement(ok: CartoucheDevice.supportsBCTextureCompression,
                                    title: CartoucheText.bcRequirement,
                                    detail: CartoucheDevice.supportsBCTextureCompression ? CartoucheText.gpuSupported : CartoucheText.gpuUnsupported))
        }
        if sheet.requirements.increasedMemoryLimit {
            let limit = memory.map { CartoucheText.memoryAmount(mebibytes: $0.limitMiB) } ?? "–"
            list.append(Requirement(ok: CartoucheDevice.hasIncreasedMemoryLimit,
                                    title: CartoucheText.imlRequirement,
                                    detail: CartoucheDevice.hasIncreasedMemoryLimit ? CartoucheText.imlActive(limit) : CartoucheText.imlInactive(limit)))
        }
        if let peak = sheet.peakMemoryMiB {
            let fits = gameLimitMiB.map { peak <= $0 } ?? true
            list.append(Requirement(ok: fits,
                                    title: CartoucheText.memoryRequirement,
                                    detail: CartoucheText.memoryNeeded(CartoucheText.memoryAmount(mebibytes: peak))))
        }
        return list
    }

    /// What the game needs against what this iPhone has: one line that
    /// opens on the details when it has it all, each need otherwise.
    @ViewBuilder
    private func requirements(_ sheet: CartoucheGameSheet) -> some View {
        let list = requirementList(sheet)
        if list.allSatisfy(\.ok) {
            Section {
                DisclosureGroup {
                    ForEach(list, id: \.self) { requirement in
                        row(requirement)
                    }
                } label: {
                    Label {
                        Text(CartoucheText.requirementsMet)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                    }
                }
            }
        } else {
            Section(CartoucheText.onThisIPhone) {
                ForEach(list, id: \.self) { requirement in
                    row(requirement)
                }
            }
        }
    }

    private func row(_ requirement: Requirement) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.title)
                Text(requirement.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: requirement.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(requirement.ok ? Color.green : Color.red)
        }
    }

    // MARK: The player's copy

    /// What the player says of their game; for a game Cartouche does not
    /// know, what IGDB has of it by its name, or that it has nothing yet.
    private var infoSection: some View {
        Section {
            Button(action: onEditInfo) {
                Label(CartoucheText.gameInfoEdit, systemImage: "square.and.pencil")
            }
        } footer: {
            if entry.isUnknown, entry.playerCover == nil {
                Text(entry.found.map { CartoucheText.gameInfoFound($0.name) } ?? CartoucheText.gameInfoNotFound)
            }
        }
    }

    /// Whether the game starts in Cartouche's place, for its own needs or
    /// because games behind the console run without Increased Memory Limit
    /// here, the game's copy in the games folder, or the button that copies
    /// it there, and Uninstall, last, in red.
    private func manageSection(_ app: LCAppModel) -> some View {
        Section {
            if keeping.keepsConsoleOpen, CartoucheGameKeeping.isAvailable,
               let bundleId = app.appInfo.bundleIdentifier() {
                if keeping.startsInPlace(bundleId: bundleId, ownLimitMiB: memory?.limitMiB) {
                    inPlaceNote(CartoucheText.startsInPlaceNote) {
                        keeping.startBehind(bundleId: bundleId)
                    }
                } else if keeping.sendsGamesInPlace(ownLimitMiB: memory?.limitMiB), let limit = keeping.limitMiB,
                          !keeping.fitsBehind(needsIML: entry.sheet?.requirements.increasedMemoryLimit ?? false,
                                              peakMiB: entry.sheet?.peakMemoryMiB, ownLimitMiB: memory?.limitMiB) {
                    inPlaceNote(CartoucheText.startsInPlaceWithoutIML(CartoucheText.memoryAmount(mebibytes: limit))) {
                        keeping.tryBehindAgain()
                    }
                }
            }
            if let stored = entry.stored {
                if entry.update == nil {
                    Label(CartoucheText.storedIn(serverName, stored.fileName), systemImage: "externaldrive.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } else if let server = CartoucheStorageSettings.shared.location(.games)?.server,
                      // A folder the player's account only reads takes no copy.
                      !CartoucheStorageSettings.shared.isReadOnly(.games) {
                Button {
                    onExport(app)
                } label: {
                    Label(CartoucheText.exportTo(server.name), systemImage: "externaldrive.fill.badge.plus")
                }
            }
            // Quit the game first.
            if !actions.isRunning(app) {
                Button(role: .destructive) {
                    onUninstall(app)
                } label: {
                    Label(CartoucheText.uninstall, systemImage: "trash")
                        .foregroundStyle(CartoucheTheme.danger)
                }
            }
        }
    }

    /// Why the game starts in Cartouche's place, and the button that tries
    /// behind the console again.
    private func inPlaceNote(_ text: String, tryAgain: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "rectangle.on.rectangle.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(CartoucheText.tryBehindAgain, action: tryAgain)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 2)
    }

    // MARK: Testers' results

    private func results(_ sheet: CartoucheGameSheet) -> some View {
        Section(CartoucheText.results) {
            ForEach(sheet.results.sorted { $0.date > $1.date }, id: \.self) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(CartoucheText.resultStatus(result.status))
                            .font(.headline)
                        Spacer()
                        Text(result.date)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(deviceName(result.device) + " · iOS " + result.iOS)
                        .font(.subheadline)
                    if let peak = result.peakMemoryMiB {
                        Text(CartoucheText.peak(CartoucheText.memoryAmount(mebibytes: peak)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(result.engine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(result.notes ?? [], id: \.self) { note in
                        Text(note)
                            .font(.footnote)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func deviceName(_ identifier: String) -> String {
        var name = identifier
        if let device = CartoucheCatalog.shared.device(identifier) {
            name += " (" + device.chip + ", " + CartoucheText.gigabytes(device.memoryGB) + ")"
        }
        if identifier == CartoucheDevice.modelIdentifier {
            name = CartoucheText.thisModel + " · " + name
        }
        return name
    }

    // MARK: Technical details

    private var recommended: CartoucheGameSheet.Recommended? {
        guard let recommended = entry.sheet?.recommended,
              recommended.resolution != nil || recommended.mode != nil else { return nil }
        return recommended
    }

    private var hasDetails: Bool {
        recommended != nil || entry.game != nil || entry.app != nil
    }

    /// What players rarely need, folded: the recommended settings, what
    /// nxnative's profile says about the game, and the build installed.
    private var detailsSection: some View {
        Section {
            DisclosureGroup(CartoucheText.sheetDetails) {
                if let recommended {
                    if let resolution = recommended.resolution {
                        LabeledContent(CartoucheText.resolution, value: resolution)
                    }
                    if let mode = recommended.mode {
                        LabeledContent(CartoucheText.mode, value: CartoucheText.modeName(mode))
                    }
                }
                if let game = entry.game {
                    nxnative(game)
                }
                if let app = entry.app, let installed = installedBuild(of: app) {
                    Label(CartoucheText.buildHere(installed), systemImage: "iphone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// What nxnative's profile says about the game.
    @ViewBuilder
    private func nxnative(_ game: CartoucheNxGame) -> some View {
        // The player's copy says nothing of where nxnative plays the game.
        let status: CartouchePlayStatus = {
            let status = CartouchePlayStatus.of(entry)
            return status == .ready || status == .update || status == .stored ? .iphone : status
        }()
        Label {
            Text(status.long)
        } icon: {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
        }
        LabeledContent(CartoucheText.sheetEngine, value: game.engine)
        LabeledContent(CartoucheText.sheetBuild, value: game.build)
        LabeledContent(CartoucheText.sheetSDK, value: game.sdk)
        LabeledContent(CartoucheText.sheetTitleID) {
            Text(verbatim: game.titleId)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
        ForEach(game.variants ?? [], id: \.self) { variant in
            LabeledContent(CartoucheText.region(variant.region)) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: variant.titleId)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Text(variant.build)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
