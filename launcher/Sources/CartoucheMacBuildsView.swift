//
//  CartoucheMacBuildsView.swift
//  Cartouche
//
//  A game's builds on the player's Mac, on its sheet. While the sheet
//  shows, Cartouche signs in to the Mac paired in Storage and asks
//  Cartouche Builder its builds (CartoucheBridgeBuilds), every few seconds
//  while it builds. When the Mac knows the game, from the player's dump or
//  its IPA, the sheet shows where its build is (building, waiting its turn,
//  up to date, improved by nxnative, failed), the button that asks the Mac
//  to build it, at once or after the games of the batch running, as the
//  game's Build button on the Mac does, the one that stops its build or
//  takes it out of the queue, and the way to all the Mac's builds
//  (CartoucheMacBuildsPage.swift), which System opens too. Nothing shows
//  away from the Mac, nor without one: a Cartouche Builder too old to share
//  its builds is told to update.
//

import SwiftUI

/// The player's Mac, as a game's sheet and the page of its builds ask it
/// its builds, and what they ask of them.
@MainActor
final class CartoucheMacBuildsWatch: ObservableObject {
    /// What is asked of the Mac, until it answers.
    enum Ask: Equatable {
        case build(String)
        case due
        case stop(String)
        case stopAll
        case follow(String, Bool)
        case nightly(CartoucheBridgeBuilds.Nightly)
    }

    /// How often the Mac is asked, in seconds: while it builds, the
    /// progress moves.
    static let whileBuilding: UInt64 = 2
    static let whileIdle: UInt64 = 10
    /// How long Cartouche waits before it tries a Mac that did not answer
    /// again, in seconds.
    static let afterFailure: UInt64 = 30

    /// The Mac's builds while it answers; nil before, and when it does not.
    @Published private(set) var builds: CartoucheBridgeBuilds?
    /// The Mac's name in Cartouche.
    @Published private(set) var macName = ""
    /// Whether the Mac answered the last time it was asked; nil before.
    @Published private(set) var reached: Bool?
    /// Whether the Mac answers, but its Cartouche Builder is too old to
    /// share its builds.
    @Published private(set) var isTooOld = false
    /// Whether the Mac takes the rest of what its window does: Build what is
    /// due, Stop, Remove from the queue, Stop all, Follow, the nightly
    /// build. A Mac a little older only shows its builds and builds a game.
    @Published private(set) var canControl = false
    /// What is being asked, until the Mac answers.
    @Published private(set) var asking: Ask?
    /// What the Mac answered the last thing asked, when it did not do it.
    @Published private(set) var refusal: String?
    /// The nightly build as the player just set it, until the Mac has it.
    @Published private(set) var pendingNightly: CartoucheBridgeBuilds.Nightly?

    /// How long the nightly build waits before it is asked of the Mac, in
    /// nanoseconds: a time picked on the wheel is asked once it stops.
    static let nightlyPause: UInt64 = 600_000_000

    private var remote: CartoucheMacRemote?
    private var loop: Task<Void, Never>?
    private var nightlySend: Task<Void, Never>?
    /// The screens showing the Mac's builds: a game's sheet, and the page
    /// it opens; the Mac is asked while one shows.
    private var viewers = 0

    #if CARTOUCHE_GALLERY
    /// What the gallery shows in place of a Mac's answers: the Mac's name
    /// and its builds; what is asked of them, the gallery's Mac does at
    /// once (galleryAnswer).
    static var gallery: (mac: String, builds: CartoucheBridgeBuilds)?
    /// Whether the gallery's sheet opens on the game's build on the Mac
    /// (screen: sheet-mac), its section in the middle of the screen.
    static var galleryScrolls = false
    #endif

    /// The Mac paired in Storage: that of the games folder, where its
    /// builds go, else the first.
    static func mac(in settings: CartoucheStorageSettings = .shared) -> CartoucheStorageServer? {
        if let games = settings.location(.games)?.server, games.kind == .mac { return games }
        return settings.servers.first { $0.kind == .mac && !($0.macID ?? "").isEmpty }
    }

    /// Asks the Mac its builds from now on, until every screen that started
    /// it stops it: nothing without a Mac paired.
    func start() {
        viewers += 1
        // What the Mac refused before the screens went: no longer news.
        if viewers == 1 { refusal = nil }
        #if CARTOUCHE_GALLERY
        // The gallery's Mac never answers on the network.
        if let gallery = Self.gallery {
            macName = gallery.mac
            builds = gallery.builds
            reached = true
            canControl = true
        }
        return
        #else
        guard loop == nil, Self.mac() != nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let answered = await self.refresh()
                // A Cartouche Builder too old to share its builds: told once.
                if self.isTooOld { return }
                let seconds = !answered ? Self.afterFailure : self.builds?.running == true ? Self.whileBuilding : Self.whileIdle
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
        #endif
    }

    /// Stops asking once no screen shows the Mac's builds, and signs out of
    /// the Mac: after the nightly build just set, if the Mac was not asked
    /// it yet.
    func stop() {
        viewers = max(viewers - 1, 0)
        guard viewers == 0 else { return }
        loop?.cancel()
        loop = nil
        let remote = self.remote
        self.remote = nil
        let nightly = nightlySend == nil ? nil : pendingNightly
        nightlySend?.cancel()
        nightlySend = nil
        pendingNightly = nil
        Task {
            if let nightly { _ = try? await remote?.client.setNightly(nightly) }
            await remote?.disconnect()
        }
    }

    /// Asks the Mac its builds, signing in first when needed: whether it
    /// answered.
    private func refresh() async -> Bool {
        guard let mac = Self.mac() else {
            builds = nil
            reached = false
            return false
        }
        macName = mac.name
        do {
            let remote = try await signedIn(mac)
            guard !isTooOld else {
                await signOut()
                builds = nil
                reached = true
                return true
            }
            let fresh = try await remote.client.builds()
            // Stopped meanwhile: the sheet is gone.
            guard loop != nil else { return true }
            builds = fresh
            reached = true
            return true
        } catch {
            await signOut()
            builds = nil
            reached = false
            return false
        }
    }

    /// The Mac signed in to, with whether it shares its builds; a Mac found
    /// offline a moment ago is left alone.
    private func signedIn(_ mac: CartoucheStorageServer) async throws -> CartoucheMacRemote {
        if let remote { return remote }
        guard !CartoucheStorageReach.shared.isSettledOffline(mac.id) else { throw CartoucheStorageOffline(mac) }
        guard let signedIn = try await CartoucheStorage.connect(mac) as? CartoucheMacRemote else {
            throw CartoucheStorageOffline(mac)
        }
        do {
            let info = try await signedIn.client.info()
            isTooOld = info.hasBuilds != true
            canControl = info.hasBuildsControl == true
        } catch {
            await signedIn.disconnect()
            throw error
        }
        guard loop != nil else {
            await signedIn.disconnect()
            throw CancellationError()
        }
        remote = signedIn
        return signedIn
    }

    private func signOut() async {
        let remote = self.remote
        self.remote = nil
        await remote?.disconnect()
    }

    /// Asks the Mac to build the game TITLE_ID, at once or after the games
    /// of the batch running.
    func build(_ titleId: String) {
        perform(.build(titleId)) { try await $0.build(titleId) }
    }

    /// Asks the Mac to build what is due, at once or after the games of the
    /// batch running.
    func buildDue() {
        perform(.due) { try await $0.buildDue() }
    }

    /// Asks the Mac to stop the build of the game TITLE_ID, or to take it
    /// out of the queue.
    func stopBuild(_ titleId: String) {
        perform(.stop(titleId)) { try await $0.stop(titleId) }
    }

    /// Asks the Mac to stop the game building and every game waiting.
    func stopAll() {
        perform(.stopAll) { try await $0.stopAll() }
    }

    /// Asks the Mac to follow the game TITLE_ID, or not.
    func follow(_ titleId: String, _ followed: Bool) {
        perform(.follow(titleId, followed)) { try await $0.follow(titleId, followed) }
    }

    /// The nightly build the page shows: as the player just set it, else as
    /// the Mac has it.
    var nightly: CartoucheBridgeBuilds.Nightly? { pendingNightly ?? builds?.nightly }

    /// Asks the Mac to build what is due every night at its time, or not,
    /// once the player has stopped changing it for a moment; it shows as
    /// set meanwhile.
    func setNightly(_ nightly: CartoucheBridgeBuilds.Nightly) {
        pendingNightly = nightly
        nightlySend?.cancel()
        nightlySend = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nightlyPause)
            // Something else asked meanwhile: once the Mac has answered it.
            while self?.asking != nil, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.nightlySend = nil
            self.perform(.nightly(nightly)) { try await $0.setNightly(nightly) }
        }
    }

    /// Asks the Mac ASK, by CALL: its answer, the builds after it, shows at
    /// once; when the Mac does not do it, why, in its words.
    private func perform(_ ask: Ask, _ call: @escaping (CartoucheBridgeClient) async throws -> CartoucheBridgeBuilds) {
        guard asking == nil else { return }
        refusal = nil
        #if CARTOUCHE_GALLERY
        if var gallery = Self.gallery {
            gallery.builds = Self.galleryAnswer(ask, in: gallery.builds)
            Self.gallery = gallery
            builds = gallery.builds
            settled(ask)
            return
        }
        #endif
        guard let remote else {
            settled(ask)
            return
        }
        asking = ask
        Task {
            defer {
                asking = nil
                settled(ask)
            }
            do {
                builds = try await call(remote.client)
            } catch let error as CartoucheBridgeError where error.kind == .failed || error.kind == .notFound {
                // The Mac's own words: its tools not ready, an IPA being imported.
                refusal = CartoucheText.storageMacFailed(macName, error.message.isEmpty ? error.kind.rawValue : error.message)
            } catch {
                refusal = CartoucheText.storageMacLost(macName)
                await signOut()
            }
        }
    }

    /// ASK answered, or not asked: the nightly build shows as the Mac has
    /// it.
    private func settled(_ ask: Ask) {
        if case let .nightly(asked) = ask, pendingNightly == asked { pendingNightly = nil }
    }

    #if CARTOUCHE_GALLERY
    /// BUILDS once the gallery's Mac does ASK, as a Mac would: a game asked
    /// for waits after the games waiting, or builds at once; a game stopped
    /// leaves the batch, which goes on with the next.
    static func galleryAnswer(_ ask: Ask, in builds: CartoucheBridgeBuilds) -> CartoucheBridgeBuilds {
        var builds = builds
        func add(_ index: Int) {
            if builds.running {
                builds.games[index].state = "queued"
                builds.games[index].turn = builds.waiting.count + 1
            } else {
                builds.running = true
                builds.games[index].state = "building"
                builds.games[index].progress = 0
            }
            builds.games[index].stoppable = true
        }
        func takeOut(_ index: Int) {
            let game = builds.games[index]
            builds.games[index].state = game.reasons.isEmpty && game.built != nil ? "up_to_date" : "due"
            builds.games[index].progress = nil
            builds.games[index].step = nil
            builds.games[index].left = nil
            builds.games[index].turn = nil
            builds.games[index].stoppable = nil
        }
        /// The batch once a game left it: the next game builds, and those
        /// after it move up; with none, the batch ends.
        func goOn() {
            let waiting = builds.waiting.map(\.id)
            if builds.building.isEmpty, let next = waiting.first, let index = builds.games.firstIndex(where: { $0.id == next }) {
                builds.games[index].state = "building"
                builds.games[index].progress = 0
                builds.games[index].turn = nil
            }
            for (turn, id) in builds.waiting.map(\.id).enumerated() {
                if let index = builds.games.firstIndex(where: { $0.id == id }) { builds.games[index].turn = turn + 1 }
            }
            builds.running = !builds.building.isEmpty || !builds.waiting.isEmpty
        }
        switch ask {
        case let .build(titleId):
            if let index = builds.games.firstIndex(where: { $0.id == titleId }) { add(index) }
        case .due:
            for index in builds.games.indices where builds.games[index].state == "due" { add(index) }
        case let .stop(titleId):
            if let index = builds.games.firstIndex(where: { $0.id == titleId }) {
                takeOut(index)
                goOn()
            }
        case .stopAll:
            for index in builds.games.indices where ["building", "queued"].contains(builds.games[index].state) { takeOut(index) }
            builds.running = false
        case let .follow(titleId, followed):
            if let index = builds.games.firstIndex(where: { $0.id == titleId }) {
                builds.games[index].followed = followed
                if !followed, ["due", "up_to_date"].contains(builds.games[index].state) {
                    builds.games[index].state = "not_followed"
                } else if followed, builds.games[index].state == "not_followed" {
                    builds.games[index].state = builds.games[index].built == nil ? "due" : "up_to_date"
                }
            }
        case let .nightly(nightly):
            builds.nightly = nightly
        }
        builds.due = builds.games.filter { $0.state == "due" }.count
        return builds
    }
    #endif
}

/// The game's build on the player's Mac, on its sheet: its line, the
/// button that asks for one, the one that stops it, and the way to all the
/// Mac's builds.
@available(iOS 17.0, *)
struct CartoucheMacBuildsSection: View {
    /// The game's title IDs: its regions', and its copy's.
    let titleIds: [String]
    /// Whether the player has the game: a Mac too old to share its builds
    /// is told only then.
    let isOwned: Bool
    @ObservedObject var watch: CartoucheMacBuildsWatch

    /// The game's line, which the gallery's sheet opens on.
    static let anchor = "mac.builds"

    var body: some View {
        if let builds = watch.builds, let build = CartoucheMacBuild.of(titleIds, in: builds) {
            Section {
                status(build)
                    .id(Self.anchor)
                if let action = build.action {
                    button(action, build: build)
                }
                if let halt = build.halt {
                    button(halt, build: build)
                } else if build.stopping {
                    Label(CartoucheText.macBuildStopping, systemImage: "stop.circle")
                        .foregroundStyle(.secondary)
                }
                if let why = build.why, build.action != nil {
                    note(why, systemImage: "info.circle")
                }
                if let refusal = watch.refusal {
                    note(refusal, systemImage: "exclamationmark.triangle.fill")
                }
                // The Mac's builds in full, as System opens them: those
                // building, waiting and failed, its games and its nightly
                // build.
                NavigationLink {
                    CartoucheMacBuildsPage(watch: watch)
                } label: {
                    Text(CartoucheText.macBuildsAll)
                }
            } header: {
                Text(CartoucheText.macBuildsTitle(watch.macName))
            } footer: {
                Text(CartoucheText.macBuildsFooter)
            }
        } else if watch.isTooOld, isOwned {
            Section {
                note(CartoucheText.macBuildsTooOld(watch.macName), systemImage: "arrow.up.circle")
            }
        }
    }

    // MARK: The game's line

    @ViewBuilder
    private func status(_ build: CartoucheMacBuild) -> some View {
        switch build.status {
        case let .building(progress, step, left):
            VStack(alignment: .leading, spacing: 6) {
                Label(progress.map { CartoucheText.macBuildBuilding(Self.percent($0)) } ?? CartoucheText.macBuildBuildingNow,
                      systemImage: "hammer.fill")
                ProgressView(value: progress ?? 0)
                    .tint(CartoucheTheme.indigo)
                let detail = [step, left.map { CartoucheText.macBuildLeft(CartoucheText.duration(seconds: $0)) }]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        case let .waiting(turn):
            Label(Self.waiting(turn), systemImage: "clock.fill")
        case .new:
            Label(CartoucheText.macBuildNew, systemImage: "hammer")
        case .improved:
            Label(CartoucheText.macBuildImproved, systemImage: "sparkles")
        case let .upToDate(built):
            Label(built.map { CartoucheText.macBuildUpToDateBuilt(Self.when($0)) } ?? CartoucheText.macBuildUpToDate,
                  systemImage: "checkmark.circle.fill")
        case let .failed(at, error):
            VStack(alignment: .leading, spacing: 4) {
                Label(at.map { CartoucheText.macBuildFailedOn(Self.when($0)) } ?? CartoucheText.macBuildFailed,
                      systemImage: "exclamationmark.triangle.fill")
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
        case .notFollowed:
            Label(CartoucheText.macBuildNotFollowed, systemImage: "pause.circle")
        case .noProfile:
            Label(CartoucheText.macBuildNoProfile, systemImage: "questionmark.circle")
        case .ipaOnly:
            Label(CartoucheText.macBuildIPAOnly, systemImage: "shippingbox")
        }
    }

    private func button(_ action: CartoucheMacBuild.Action, build: CartoucheMacBuild) -> some View {
        Button {
            watch.build(build.id)
        } label: {
            if watch.asking == .build(build.id) {
                Label(CartoucheText.macBuildAsking, systemImage: "ellipsis.circle")
            } else {
                Label(Self.title(action), systemImage: Self.symbol(action))
            }
        }
        .disabled(!build.ready || watch.asking != nil)
    }

    /// Stop its build, or Remove from the queue.
    private func button(_ halt: CartoucheMacBuild.Halt, build: CartoucheMacBuild) -> some View {
        Button(role: halt == .stop ? .destructive : nil) {
            watch.stopBuild(build.id)
        } label: {
            if watch.asking == .stop(build.id) {
                Label(CartoucheText.macBuildAsking, systemImage: "ellipsis.circle")
            } else {
                Label(Self.title(halt), systemImage: Self.symbol(halt))
            }
        }
        .disabled(watch.asking != nil)
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    static func title(_ action: CartoucheMacBuild.Action) -> String {
        switch action {
        case .build: return CartoucheText.macBuildActionBuild
        case .rebuild: return CartoucheText.macBuildActionRebuild
        case .buildAgain: return CartoucheText.macBuildActionAgain
        case .addToQueue: return CartoucheText.macBuildActionQueue
        }
    }

    static func symbol(_ action: CartoucheMacBuild.Action) -> String {
        switch action {
        case .build: return "hammer.fill"
        case .rebuild: return "sparkles"
        case .buildAgain: return "arrow.clockwise"
        case .addToQueue: return "text.badge.plus"
        }
    }

    static func title(_ halt: CartoucheMacBuild.Halt) -> String {
        switch halt {
        case .stop: return CartoucheText.macBuildStop
        case .remove: return CartoucheText.macBuildRemove
        }
    }

    static func symbol(_ halt: CartoucheMacBuild.Halt) -> String {
        switch halt {
        case .stop: return "stop.fill"
        case .remove: return "minus.circle"
        }
    }

    static func waiting(_ turn: Int?) -> String {
        guard let turn else { return CartoucheText.macBuildWaiting }
        switch turn {
        case ...1: return CartoucheText.macBuildNext
        case 2: return CartoucheText.macBuildWaitingOne
        default: return CartoucheText.macBuildWaitingAfter(turn - 1)
        }
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// When a build ended: "2 hours ago", "yesterday".
    static func when(_ date: Date) -> String {
        min(date, Date()).formatted(.relative(presentation: .named))
    }
}
