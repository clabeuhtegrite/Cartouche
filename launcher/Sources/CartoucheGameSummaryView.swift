//
//  CartoucheGameSummaryView.swift
//  Cartouche
//
//  A game's description on its sheet: what the player wrote of it (Edit
//  the game's info), else IGDB's summary of it, which is in English. Its
//  first lines, and the rest when the player asks. When Cartouche speaks
//  another language, the iPhone translates IGDB's summary itself, with
//  Apple's Translation, from iOS 18: at once when it has both languages,
//  else when the player taps Translate, which first offers to download
//  them. The original stays a tap away. Nothing leaves the iPhone for it.
//

import SwiftUI
import Translation

@available(iOS 17.0, *)
struct CartoucheGameSummaryView: View {
    /// What the sheet shows.
    let text: String
    /// Whether it is IGDB's, in English, rather than the player's.
    let isIGDBs: Bool

    var body: some View {
        if #available(iOS 18.0, *) {
            if isIGDBs, let target = Self.language {
                CartoucheTranslatedSummary(text: text, target: target)
            } else {
                CartoucheSummaryLines(text: text, credit: isIGDBs ? CartoucheText.summaryCredit : nil) {}
            }
        } else {
            CartoucheSummaryLines(text: text, credit: isIGDBs ? CartoucheText.summaryCredit : nil) {}
        }
    }

    /// The language of IGDB's summaries.
    static let english = Locale.Language(identifier: "en")

    /// Cartouche's language, as its words are, when it is not English: the
    /// one the iPhone translates IGDB's summaries into.
    static var language: Locale.Language? {
        let language = CartoucheText.bundle.preferredLocalizations.first ?? "en"
        return language == "Base" || language.hasPrefix("en") ? nil : Locale.Language(identifier: language)
    }
}

/// A description's lines, folded to `foldedLines` until the player asks for
/// the rest, what the player can do with them, and where they come from.
@available(iOS 17.0, *)
private struct CartoucheSummaryLines<Actions: View>: View {
    let text: String
    let credit: String?
    let actions: Actions

    /// The lines shown until the player asks for the rest.
    static var foldedLines: Int { 4 }

    @State private var isUnfolded = false
    @State private var foldedHeight: CGFloat = 0
    @State private var wholeHeight: CGFloat = 0

    // Written out: the private state above would make the synthesized
    // initializer private.
    init(text: String, credit: String?, @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.credit = credit
        self.actions = actions()
    }

    /// Whether the folded lines leave some of it out.
    private var folds: Bool { wholeHeight > foldedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(isUnfolded ? nil : Self.foldedLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    // All of it, unseen: whether the folded lines hold it.
                    Text(text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wholeHeight = $0 }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if !isUnfolded { foldedHeight = height }
                }
            HStack(spacing: 20) {
                if folds || isUnfolded {
                    Button(isUnfolded ? CartoucheText.summaryLess : CartoucheText.summaryMore) {
                        withAnimation(.easeInOut(duration: 0.2)) { isUnfolded.toggle() }
                    }
                }
                actions
            }
            // Each button on its own: a row of a list is otherwise one
            // button for all of them.
            .buttonStyle(.borderless)
            .font(.footnote.weight(.semibold))
            if let credit {
                Text(credit)
                    .font(.caption2)
                    .foregroundStyle(CartoucheTheme.secondaryText)
            }
        }
        .padding(.vertical, 4)
        // Another game's description starts folded.
        .onChange(of: text) { _, _ in isUnfolded = false }
    }
}

/// IGDB's summary in Cartouche's language, as the iPhone translates it.
@available(iOS 18.0, *)
private struct CartoucheTranslatedSummary: View {
    let text: String
    /// Cartouche's language.
    let target: Locale.Language

    /// A translation, with the text it was made from.
    private struct Translated: Equatable {
        let source: String
        let text: String
    }

    @State private var configuration: TranslationSession.Configuration?
    @State private var translated: Translated?
    /// Whether the iPhone can translate it once it has the languages, which
    /// Translate offers to download.
    @State private var canTranslate = false
    @State private var showsOriginal = false

    // Written out: the private state above would make the synthesized
    // initializer private.
    init(text: String, target: Locale.Language) {
        self.text = text
        self.target = target
    }

    /// The translation of the text shown, once there is one.
    private var translation: String? {
        guard let translated, translated.source == text else { return nil }
        return translated.text
    }

    var body: some View {
        let showsTranslation = translation != nil && !showsOriginal
        CartoucheSummaryLines(text: showsTranslation ? translation ?? text : text,
                              credit: showsTranslation ? CartoucheText.summaryTranslatedCredit : CartoucheText.summaryCredit) {
            if translation != nil {
                Button(showsOriginal ? CartoucheText.summaryShowTranslation : CartoucheText.summaryShowOriginal) {
                    showsOriginal.toggle()
                }
            } else if canTranslate {
                Button(CartoucheText.summaryTranslate) { translate() }
            }
        }
        // Translated at once when the iPhone has both languages; otherwise
        // Translate offers to download them.
        .task(id: text) {
            showsOriginal = false
            canTranslate = false
            switch await LanguageAvailability().status(from: CartoucheGameSummaryView.english, to: target) {
            case .installed:
                translate()
            case .supported:
                canTranslate = true
            default:
                break
            }
        }
        .translationTask(configuration) { session in
            let source = text
            do {
                let response = try await session.translate(source)
                translated = Translated(source: source, text: response.targetText)
            } catch {
                // Not downloaded, or not translated: the original stays, and
                // Translate with it.
                canTranslate = true
            }
        }
    }

    /// Asks the iPhone for the translation, again if it was asked before.
    private func translate() {
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: CartoucheGameSummaryView.english, target: target)
        } else {
            configuration?.invalidate()
        }
    }
}
