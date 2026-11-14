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
//  game's Build button on the Mac does, and the Mac's builds, building,
//  waiting and done. Nothing shows away from the Mac, nor without one: a
//  Cartouche Builder too old to share its builds is told to update.
//

import SwiftUI

/// The player's Mac, as a game's sheet asks it its builds.
@MainActor
final class CartoucheMacBuildsWatch: ObservableObject {
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
    /// Whether the Mac answers, but its Cartouche Builder is too old to
    /// share its builds.
    @Published private(set) var isTooOld = false
    /// The game being asked for, until the Mac answers.
    @Published private(set) var asking: String?
    /// What the Mac answered the build asked for, when it did not take it.
    @Published private(set) var refusal: String?
    /// Whether the Mac's builds show, under the game's.
    @Published var showsAll = false

    private var remote: CartoucheMacRemote?
    private var loop: Task<Void, Never>?

    #if CARTOUCHE_GALLERY
    /// What the gallery shows in place of a Mac's answers: the Mac's name,
    /// its builds, and whether they show open; a build asked for waits its
    /// turn, or starts.
    static var gallery: (mac: String, builds: CartoucheBridgeBuilds, showsAll: Bool)?
    /// Whether the gallery's sheet opens on the game's build on the Mac
    /// (screen: sheet-mac): its section in the middle of the screen, or,
    /// with the Mac's builds open, down to their end.
    static var galleryScrolls = false
    #endif

    /// The Mac paired in Storage: that of the games folder, where its
    /// builds go, else the first.
    static func mac(in settings: CartoucheStorageSettings = .shared) -> CartoucheStorageServer? {
        if let games = settings.location(.games)?.server, games.kind == .mac { return games }
        return settings.servers.first { $0.kind == .mac && !($0.macID ?? "").isEmpty }
    }

    /// Asks the Mac its builds from now on, until stop: nothing without a
    /// Mac paired.
    func start() {
        #if CARTOUCHE_GALLERY
        // The gallery's Mac never answers on the network.
        if let gallery = Self.gallery {
            macName = gallery.mac
            builds = gallery.builds
            showsAll = gallery.showsAll
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

    /// Stops asking, and signs out of the Mac.
    func stop() {
        loop?.cancel()
        loop = nil
        let remote = self.remote
        self.remote = nil
        Task { await remote?.disconnect() }
    }

    /// Asks the Mac its builds, signing in first when needed: whether it
    /// answered.
    private func refresh() async -> Bool {
        guard let mac = Self.mac() else {
            builds = nil
            return false
        }
        macName = mac.name
        do {
            let remote = try await signedIn(mac)
            guard !isTooOld else {
                await signOut()
                builds = nil
                return true
            }
            let fresh = try await remote.client.builds()
            // Stopped meanwhile: the sheet is gone.
            guard loop != nil else { return true }
            builds = fresh
            return true
        } catch {
            await signOut()
            builds = nil
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
            isTooOld = try await signedIn.client.info().hasBuilds != true
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

    /// Asks the Mac to build the game TITLE_ID: its answer, the builds
    /// after it, shows at once.
    func build(_ titleId: String) {
        guard asking == nil else { return }
        refusal = nil
        #if CARTOUCHE_GALLERY
        if var gallery = Self.gallery {
            gallery.builds = Self.galleryBuild(titleId, in: gallery.builds)
            Self.gallery = gallery
            builds = gallery.builds
            return
        }
        #endif
        guard let remote else { return }
        asking = titleId
        Task {
            defer { asking = nil }
            do {
                builds = try await remote.client.build(titleId)
            } catch let error as CartoucheBridgeError where error.kind == .failed || error.kind == .notFound {
                // The Mac's own words: its tools not ready, an IPA being imported.
                refusal = CartoucheText.storageMacFailed(macName, error.message.isEmpty ? error.kind.rawValue : error.message)
            } catch {
                refusal = CartoucheText.storageMacLost(macName)
                await signOut()
            }
        }
    }

    #if CARTOUCHE_GALLERY
    /// BUILDS once the game TITLE_ID is asked for: after the games waiting,
    /// or building at once.
    private static func galleryBuild(_ titleId: String, in builds: CartoucheBridgeBuilds) -> CartoucheBridgeBuilds {
        var builds = builds
        guard let index = builds.games.firstIndex(where: { $0.id == titleId }) else { return builds }
        if builds.running {
            let turn = builds.waiting.count + 1
            builds.games[index].state = "queued"
            builds.games[index].turn = turn
        } else {
            builds.running = true
            builds.games[index].state = "building"
            builds.games[index].progress = 0
        }
        return builds
    }
    #endif
}

/// The game's build on the player's Mac, on its sheet: its line, the
/// button that asks for one, and the Mac's builds.
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
                if let why = build.why, build.action != nil {
                    note(why, systemImage: "info.circle")
                }
                if let refusal = watch.refusal {
                    note(refusal, systemImage: "exclamationmark.triangle.fill")
                }
                // A row that opens on the list below it, wherever it is
                // tapped, unlike a disclosure group's arrow.
                Button {
                    withAnimation { watch.showsAll.toggle() }
                } label: {
                    HStack {
                        Text(CartoucheText.macBuildsAll)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(watch.showsAll ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                if watch.showsAll {
                    CartoucheMacBuildsList(builds: builds)
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
        let asking = watch.asking == build.id
        return Button {
            watch.build(build.id)
        } label: {
            if asking {
                Label(CartoucheText.macBuildAsking, systemImage: "ellipsis.circle")
            } else {
                Label(Self.title(action), systemImage: Self.symbol(action))
            }
        }
        .disabled(!build.ready || watch.asking != nil)
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

/// The Mac's builds: those building, those waiting their turn, the next
/// first, and those done, the newest first.
@available(iOS 17.0, *)
struct CartoucheMacBuildsList: View {
    /// The last build done, the list's end, which the gallery's sheet
    /// scrolls to (screen: sheet-mac, work: mac-builds-all).
    static let end = "mac.builds.end"

    let builds: CartoucheBridgeBuilds

    var body: some View {
        let building = builds.building
        let waiting = builds.waiting
        let done = builds.done()
        if building.isEmpty, waiting.isEmpty, done.isEmpty {
            Text(CartoucheText.macBuildsNone)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if !building.isEmpty {
            heading(CartoucheText.macBuildsBuilding)
            ForEach(building, id: \.id) { game in
                row(game.name, detail: [game.progress.map(CartoucheMacBuildsSection.percent), game.step].compactMap { $0 }.joined(separator: " · "),
                    systemImage: "hammer.fill")
            }
        }
        if !waiting.isEmpty {
            heading(CartoucheText.macBuildsWaiting)
            ForEach(Array(waiting.enumerated()), id: \.element.id) { index, game in
                row("\(index + 1). \(game.name)", detail: nil, systemImage: "clock")
            }
        }
        if let last = done.last {
            heading(CartoucheText.macBuildsDone)
            ForEach(done.dropLast()) { item in
                doneRow(item)
            }
            // A row of its own: a list scrolls to a row by its own id, never
            // by one inside a ForEach's row.
            doneRow(last)
                .id(Self.end)
        }
    }

    private func doneRow(_ item: CartoucheBridgeBuilds.Done) -> some View {
        let when = CartoucheMacBuildsSection.when(item.date)
        return row(item.game.name, detail: item.failed ? CartoucheText.macBuildsFailed(when) : CartoucheText.macBuildsBuilt(when),
                   systemImage: item.failed ? "exclamationmark.triangle" : "checkmark.circle")
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ name: String, detail: String?, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(2)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}
