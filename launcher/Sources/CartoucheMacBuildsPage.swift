//
//  CartoucheMacBuildsPage.swift
//  Cartouche
//
//  The builds of the player's Mac, in full, which System opens under
//  Storage, and a game's sheet too (All the Mac's builds). While the page
//  shows, Cartouche asks Cartouche Builder its builds
//  (CartoucheMacBuildsWatch): the Mac, building or not, and why it takes no
//  build when it does not; Build what is due, as the Mac's own button, and
//  Stop all; the game building, with its step and Stop its build; the games
//  waiting their turn, each of which can leave the queue; the builds that
//  failed, and why; every game of the Mac, where it is, with its build,
//  Stop or Remove, and Follow; and the nightly build, on or off, and its
//  time. The Mac's folders, its tools and an IPA's import stay on the Mac.
//  A Mac whose app is a little older shows its builds and builds a game,
//  and says to update its app for the rest.
//

import SwiftUI

@available(iOS 17.0, *)
struct CartoucheMacBuildsPage: View {
    @ObservedObject var watch: CartoucheMacBuildsWatch

    /// The nightly build's first row, which the gallery's page scrolls to
    /// (category: nightly), the Mac's games above it.
    static let nightlyRow = "mac.builds.nightly"

    #if CARTOUCHE_GALLERY
    /// The row the gallery's page opens on, by its id; nil, the top.
    static var openingRow: String?
    #endif

    var body: some View {
        ScrollViewReader { reader in
            List {
                macSection
                if let builds = watch.builds {
                    if watch.canControl {
                        dueSection(builds)
                    }
                    building(builds)
                    waiting(builds)
                    failures(builds)
                    games(builds)
                    if watch.canControl, let nightly = watch.nightly {
                        nightlySection(nightly)
                    }
                }
            }
            .cartoucheStageBackground()
            .navigationTitle(CartoucheText.macBuildsPage)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { watch.start() }
            .onDisappear { watch.stop() }
            #if CARTOUCHE_GALLERY
            // Twice, as the sheet does: the first scroll lays out the rows
            // the list had only guessed the heights of.
            .task {
                guard let row = Self.openingRow else { return }
                for _ in 0..<2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    reader.scrollTo(row, anchor: .bottom)
                }
            }
            #endif
        }
    }

    // MARK: The Mac

    private var macSection: some View {
        Section {
            LabeledContent {
                Text(macState)
                    .lineLimit(1)
            } label: {
                Label(watch.macName, systemImage: "laptopcomputer")
                    .lineLimit(2)
            }
            if watch.isTooOld {
                note(CartoucheText.macBuildsTooOld(watch.macName), systemImage: "arrow.up.circle")
            } else if watch.reached == false {
                note(CartoucheText.storageMacOffline(watch.macName), systemImage: "wifi.slash")
            } else if let builds = watch.builds {
                if !builds.ready, let why = builds.why {
                    note(why, systemImage: "info.circle")
                }
                if !watch.canControl {
                    note(CartoucheText.macBuildsControlTooOld(watch.macName), systemImage: "arrow.up.circle")
                }
            }
            if let refusal = watch.refusal {
                note(refusal, systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Where the Mac is, in a word or two.
    private var macState: String {
        if watch.isTooOld { return CartoucheText.macBuildsToUpdate }
        guard let builds = watch.builds else {
            return watch.reached == false ? CartoucheText.macBuildsNotAnswering : CartoucheText.macBuildsReaching
        }
        if builds.running || !builds.building.isEmpty { return CartoucheText.macBuildsBuilding }
        return builds.ready ? CartoucheText.macBuildsIdle : CartoucheText.macBuildsNotReady
    }

    // MARK: What is due, and Stop all

    private func dueSection(_ builds: CartoucheBridgeBuilds) -> some View {
        let due = builds.dueCount
        return Section {
            Button {
                watch.buildDue()
            } label: {
                if watch.asking == .due {
                    Label(CartoucheText.macBuildAsking, systemImage: "ellipsis.circle")
                } else if builds.running {
                    Label(CartoucheText.macBuildsAddDue, systemImage: "text.badge.plus")
                } else {
                    Label(CartoucheText.macBuildsDue, systemImage: "sparkles")
                }
            }
            .disabled(!builds.ready || due == 0 || watch.asking != nil)
            // With one game alone building, its own Stop does it.
            if builds.running, builds.building.count + builds.waiting.count != 1 || builds.building.isEmpty {
                Button(role: .destructive) {
                    watch.stopAll()
                } label: {
                    if watch.asking == .stopAll {
                        Label(CartoucheText.macBuildAsking, systemImage: "ellipsis.circle")
                    } else {
                        Label(CartoucheText.macBuildsStopAll, systemImage: "stop.fill")
                    }
                }
                .disabled(watch.asking != nil)
            }
        } footer: {
            Text(due == 0 ? CartoucheText.macBuildsDueNone : due == 1 ? CartoucheText.macBuildsDueOne : CartoucheText.macBuildsDueMany(due))
        }
    }

    // MARK: Building, waiting, failed

    @ViewBuilder
    private func building(_ builds: CartoucheBridgeBuilds) -> some View {
        let building = builds.building
        if !building.isEmpty {
            Section(CartoucheText.macBuildsBuilding) {
                ForEach(building, id: \.id) { game in
                    let build = Self.build(game, in: builds)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.name)
                            .font(.headline)
                            .lineLimit(2)
                        ProgressView(value: min(max(game.progress ?? 0, 0), 1))
                            .tint(CartoucheTheme.indigo)
                        let detail = [game.progress.map(CartoucheMacBuildsSection.percent), game.step,
                                      game.left.map { CartoucheText.macBuildLeft(CartoucheText.duration(seconds: $0)) }]
                            .compactMap { $0 }.filter { !$0.isEmpty }
                        if !detail.isEmpty {
                            Text(detail.joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    if build.halt == .stop {
                        Button(role: .destructive) {
                            watch.stopBuild(game.id)
                        } label: {
                            if watch.asking == .stop(game.id) {
                                Label(CartoucheText.macBuildAsking, systemImage: "ellipsis.circle")
                            } else {
                                Label(CartoucheText.macBuildStop, systemImage: "stop.fill")
                            }
                        }
                        .disabled(watch.asking != nil)
                    } else if build.stopping {
                        Label(CartoucheText.macBuildStopping, systemImage: "stop.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func waiting(_ builds: CartoucheBridgeBuilds) -> some View {
        let waiting = builds.waiting
        if !waiting.isEmpty {
            Section(CartoucheText.macBuildsWaiting) {
                ForEach(Array(waiting.enumerated()), id: \.element.id) { index, game in
                    HStack(spacing: 12) {
                        Text(verbatim: "\(index + 1). \(game.name)")
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        if Self.build(game, in: builds).halt == .remove {
                            Button {
                                watch.stopBuild(game.id)
                            } label: {
                                if watch.asking == .stop(game.id) {
                                    ProgressView()
                                } else {
                                    Text(CartoucheText.macBuildsRemoveShort)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(watch.asking != nil)
                            .accessibilityLabel(CartoucheText.macBuildsRemove(game.name))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func failures(_ builds: CartoucheBridgeBuilds) -> some View {
        let failures = builds.failures
        if !failures.isEmpty {
            Section(CartoucheText.macBuildsFailures) {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.game.name)
                            .lineLimit(2)
                        Label(CartoucheText.macBuildsFailed(CartoucheMacBuildsSection.when(failure.date)),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        if let error = failure.game.error, !error.isEmpty {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Every game of the Mac

    private func games(_ builds: CartoucheBridgeBuilds) -> some View {
        Section {
            ForEach(builds.library, id: \.id) { game in
                gameRow(Self.build(game, in: builds))
            }
        } header: {
            Text(CartoucheText.macBuildsGames)
        } footer: {
            Text(CartoucheText.macBuildsGamesFooter)
        }
    }

    private func gameRow(_ build: CartoucheMacBuild) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(build.name)
                    .lineLimit(2)
                Label(Self.line(build), systemImage: Self.symbol(build.status))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if watch.asking.map({ Self.concerns($0, build.id) }) == true {
                ProgressView()
            } else if build.action != nil || build.halt != nil || (watch.canControl && build.followed != nil) {
                Menu {
                    gameActions(build)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(watch.asking != nil)
                .accessibilityLabel(CartoucheText.macBuildsGameActions(build.name))
            }
        }
    }

    /// What the game's menu does: build it, stop its build or take it out
    /// of the queue, follow it or not.
    @ViewBuilder
    private func gameActions(_ build: CartoucheMacBuild) -> some View {
        if let action = build.action {
            Button {
                watch.build(build.id)
            } label: {
                Label(CartoucheMacBuildsSection.title(action), systemImage: CartoucheMacBuildsSection.symbol(action))
            }
            .disabled(!build.ready)
        }
        if let halt = build.halt {
            Button(role: halt == .stop ? .destructive : nil) {
                watch.stopBuild(build.id)
            } label: {
                Label(CartoucheMacBuildsSection.title(halt), systemImage: CartoucheMacBuildsSection.symbol(halt))
            }
        }
        if watch.canControl, let followed = build.followed {
            Button {
                watch.follow(build.id, !followed)
            } label: {
                Label(followed ? CartoucheText.macBuildUnfollow : CartoucheText.macBuildFollow,
                      systemImage: followed ? "bell.slash" : "bell")
            }
        }
    }

    // MARK: Every night

    private func nightlySection(_ nightly: CartoucheBridgeBuilds.Nightly) -> some View {
        let time = Calendar.current.date(bySettingHour: nightly.hour, minute: nightly.minute, second: 0, of: Date()) ?? Date()
        return Section {
            Toggle(isOn: Binding(get: { nightly.on }, set: { on in
                watch.setNightly(CartoucheBridgeBuilds.Nightly(on: on, hour: nightly.hour, minute: nightly.minute))
            })) {
                Label(CartoucheText.macBuildsNightly, systemImage: "moon.stars.fill")
            }
            .id(Self.nightlyRow)
            DatePicker(selection: Binding(get: { time }, set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                watch.setNightly(CartoucheBridgeBuilds.Nightly(on: nightly.on, hour: parts.hour ?? nightly.hour,
                                                               minute: parts.minute ?? nightly.minute))
            }), displayedComponents: .hourAndMinute) {
                Label(CartoucheText.macBuildsNightlyTime, systemImage: "clock")
            }
            .disabled(!nightly.on)
        } footer: {
            if nightly.on {
                Text(CartoucheText.macBuildsNightlyFooter(time.formatted(date: .omitted, time: .shortened)))
            }
        }
    }

    // MARK: Lines

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// GAME as its sheet has it, with the batch's and the Mac's state.
    static func build(_ game: CartoucheBridgeBuilds.Game, in builds: CartoucheBridgeBuilds) -> CartoucheMacBuild {
        CartoucheMacBuild(game, running: builds.running, ready: builds.ready, why: builds.why)
    }

    /// Whether ASK is about the game TITLE_ID.
    static func concerns(_ ask: CartoucheMacBuildsWatch.Ask, _ titleId: String) -> Bool {
        switch ask {
        case let .build(id), let .stop(id), let .follow(id, _): return id == titleId
        case .due, .stopAll, .nightly: return false
        }
    }

    /// A game's line in the Mac's games: where it is, in a few words.
    static func line(_ build: CartoucheMacBuild) -> String {
        switch build.status {
        case let .building(progress, _, _):
            if build.stopping { return CartoucheText.macBuildStopping }
            return progress.map { CartoucheText.macGameBuilding(CartoucheMacBuildsSection.percent($0)) } ?? CartoucheText.macBuildsBuilding
        case .waiting:
            return CartoucheText.macGameWaiting
        case .new:
            return CartoucheText.macGameNew
        case .improved:
            return CartoucheText.macGameImproved
        case let .upToDate(built):
            return built.map { CartoucheText.macGameUpToDateBuilt(CartoucheMacBuildsSection.when($0)) } ?? CartoucheText.macGameUpToDate
        case let .failed(at, _):
            return at.map { CartoucheText.macBuildsFailed(CartoucheMacBuildsSection.when($0)) } ?? CartoucheText.macGameFailed
        case .notFollowed:
            return CartoucheText.macGameNotFollowed
        case .noProfile:
            return CartoucheText.macGameNoProfile
        case .ipaOnly:
            return CartoucheText.macGameIPAOnly
        }
    }

    static func symbol(_ status: CartoucheMacBuild.Status) -> String {
        switch status {
        case .building: return "hammer.fill"
        case .waiting: return "clock"
        case .new: return "hammer"
        case .improved: return "sparkles"
        case .upToDate: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .notFollowed: return "bell.slash"
        case .noProfile: return "questionmark.circle"
        case .ipaOnly: return "shippingbox"
        }
    }
}
