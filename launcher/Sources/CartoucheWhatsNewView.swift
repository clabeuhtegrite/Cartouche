//
//  CartoucheWhatsNewView.swift
//  Cartouche
//
//  What's new, over the console, as Cartouche opens after an update, however
//  it came (CartoucheWhatsNewRecord): the release notes of the version
//  installed, in the player's language when they are written in it, until
//  the player closes them with Continue, or with A or B on a controller,
//  whose D-pad scrolls them. Nothing on a first install. And the System
//  page's What's new, where the player reads again the notes of the last
//  versions Cartouche carries (CartoucheReleaseNotes.swift).
//

import SwiftUI

/// The release notes Cartouche carries, and those over the console.
@available(iOS 17.0, *)
@MainActor
final class CartoucheWhatsNew: ObservableObject {
    static let shared = CartoucheWhatsNew()

    /// The notes over the console, newest first: none once the player has
    /// closed them.
    @Published private(set) var shown: [CartoucheReleaseNotes] = []

    /// The most versions the System page lists, as many as the source keeps
    /// (app/releases/README.md).
    static let listed = 10

    /// The notes of every version Cartouche carries, newest first, in the
    /// language of its own words when they are written in it: the build
    /// puts them in the app (app/scripts/package.sh). iOS starts Cartouche
    /// again when the player changes their language. On an iPad, they call
    /// it the iPad, as Cartouche's own words do (CartoucheText.s).
    static let carried = CartoucheReleaseNotes.all(
        in: Bundle.main.bundleURL.appendingPathComponent("CartoucheReleases", isDirectory: true),
        language: CartoucheText.bundle.preferredLocalizations.first)
        .map { CartoucheDevice.isPad ? $0.applying(CartoucheDeviceWords.onIPad) : $0 }

    private let record = CartoucheWhatsNewRecord(defaults: .standard)

    /// As the console is made, and before CartoucheUpdates takes the update
    /// it started off the preferences: what an older Cartouche left there
    /// tells an update from a first install (CartoucheWhatsNewRecord).
    private init() {
        #if CARTOUCHE_GALLERY
        // The gallery's screenshots show it only when their scenario asks;
        // its UI tests open as Cartouche does (GalleryTesting.swift).
        guard GalleryTest.isOn else { return }
        #endif
        decide()
    }

    private func decide() {
        shown = record.notesToShow(running: CartoucheUpdates.runningVersion, among: Self.carried)
        if !shown.isEmpty {
            CartoucheReports.note("What's new shown: " + shown.map(\.version).joined(separator: ", "))
        }
    }

    var isShowing: Bool { !shown.isEmpty }

    /// Whether the notes of VERSION are over the console.
    func shows(_ version: String) -> Bool {
        shown.contains { CartoucheVersion.isSame($0.version, version) }
    }

    /// The player closed them: they do not show again for this version.
    func close() {
        record.noteSeen(CartoucheUpdates.runningVersion)
        shown = []
    }

    #if CARTOUCHE_GALLERY
    /// NOTES over the console, as after an update to the first of them.
    func showForGallery(_ notes: [CartoucheReleaseNotes]) {
        shown = notes
    }

    /// What Cartouche shows as it opens, from what the scenario left in the
    /// preferences, for a screenshot (GalleryApp.swift).
    func decideForGallery() {
        decide()
    }
    #endif
}

/// What's new, over the console: a card with the newest version's title and
/// summary, its items under them, then those of the versions before it,
/// when the update went over several.
@available(iOS 17.0, *)
struct CartoucheWhatsNewView: View {
    @ObservedObject var whatsNew: CartoucheWhatsNew
    @ObservedObject private var gamepad = CartoucheGamepad.shared
    @Environment(\.verticalSizeClass) private var heightClass
    /// The line the controller's D-pad scrolled to.
    @State private var scrolled = 0

    /// A line under the title: an item, or the name and summary of each
    /// version before the newest.
    private enum Line {
        case version(String)
        case summary(String)
        case item(CartoucheReleaseNotes.Item)
    }

    private var lines: [Line] {
        var lines: [Line] = []
        for (index, notes) in whatsNew.shown.enumerated() {
            if index > 0 {
                lines.append(.version(notes.version))
                if !notes.summary.isEmpty { lines.append(.summary(notes.summary)) }
            }
            lines += notes.items.map(Line.item)
        }
        return lines
    }

    var body: some View {
        let allLines = self.lines
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            if let newest = whatsNew.shown.first {
                card(newest, lines: allLines)
            }
        }
        .accessibilityElement(children: .contain)
        .onReceive(CartoucheGamepad.shared.inputs) { input in
            switch input {
            case .a, .b: whatsNew.close()
            case .up: scrolled = max(scrolled - 1, 0)
            case .down: scrolled = min(scrolled + 1, max(allLines.count - 1, 0))
            default: break
            }
        }
    }

    @ViewBuilder
    private func card(_ newest: CartoucheReleaseNotes, lines: [Line]) -> some View {
        if heightClass == .compact {
            // Sideways: the title on the left, the notes beside it.
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    header(newest, alignment: .leading)
                    Spacer(minLength: 0)
                    continueButton
                }
                .frame(maxWidth: 280)
                if !lines.isEmpty { notes(lines) }
            }
            .padding(22)
            .frame(maxWidth: 780)
            .cartoucheGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding(12)
        } else {
            VStack(spacing: 18) {
                header(newest, alignment: .center)
                if !lines.isEmpty { notes(lines) }
                continueButton
            }
            .padding(28)
            .frame(maxWidth: 440)
            .cartoucheGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .padding(24)
        }
    }

    private func header(_ newest: CartoucheReleaseNotes, alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 64, height: 64)
                .background(
                    LinearGradient(colors: [CartoucheTheme.indigo, CartoucheTheme.pink],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: alignment, spacing: 6) {
                Text(CartoucheText.whatsNewTitle(newest.version))
                    .font(.system(.title3, design: .rounded, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !newest.summary.isEmpty {
                    Text(newest.summary)
                        .font(.subheadline)
                        .foregroundStyle(CartoucheTheme.secondaryText)
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    /// The lines as they are when they fit, scrolled otherwise.
    private func notes(_ lines: [Line]) -> some View {
        ViewThatFits(in: .vertical) {
            list(lines)
            ScrollViewReader { proxy in
                ScrollView {
                    list(lines)
                }
                .scrollIndicatorsFlash(onAppear: true)
                // No taller than that on a large screen.
                .frame(maxHeight: 560)
                .onChange(of: scrolled) { _, line in
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(line, anchor: .top) }
                }
            }
        }
    }

    private func list(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                row(line)
                    .id(index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        switch line {
        case .version(let version):
            Text(verbatim: "Cartouche " + version)
                .font(.headline)
                .foregroundStyle(Color.white)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        case .summary(let summary):
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(CartoucheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let item):
            CartoucheReleaseNoteItem(item: item)
        }
    }

    private var continueButton: some View {
        Button {
            whatsNew.close()
        } label: {
            HStack(spacing: 8) {
                if gamepad.isConnected {
                    Image(systemName: gamepad.symbol(for: .a))
                }
                Text(CartoucheText.whatsNewContinue)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .controlSize(.large)
        .cartouchePrimaryButton()
    }
}

/// An item of a version's notes, its topic in bold, such as "Games:".
@available(iOS 17.0, *)
struct CartoucheReleaseNoteItem: View {
    let item: CartoucheReleaseNotes.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "•")
                .foregroundStyle(CartoucheTheme.pink)
                .accessibilityHidden(true)
            Text(Self.text(item))
                .foregroundStyle(CartoucheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    static func text(_ item: CartoucheReleaseNotes.Item) -> AttributedString {
        var text = AttributedString(item.text)
        if let topic = item.topic {
            var lead = AttributedString(topic + " ")
            lead.inlinePresentationIntent = .stronglyEmphasized
            lead.foregroundColor = Color.white
            text = lead + text
        }
        return text
    }
}

/// The System page's What's new: the notes of the last versions Cartouche
/// carries, newest first, this version's at the top.
@available(iOS 17.0, *)
struct CartoucheReleaseNotesView: View {
    let notes: [CartoucheReleaseNotes]

    var body: some View {
        List {
            ForEach(notes) { version in
                Section {
                    if !version.summary.isEmpty {
                        Text(version.summary)
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(Array(version.items.enumerated()), id: \.offset) { _, item in
                        CartoucheReleaseNoteItem(item: item)
                    }
                } header: {
                    Text(verbatim: "Cartouche " + version.version)
                }
            }
        }
        .cartoucheStageBackground()
        .navigationTitle(CartoucheText.releaseNotesTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
