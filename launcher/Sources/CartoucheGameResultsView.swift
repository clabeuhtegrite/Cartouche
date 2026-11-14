//
//  CartoucheGameResultsView.swift
//  Cartouche
//
//  The testers' results on a game's sheet, the newest first, in Cartouche's
//  language: each one's status and day, the model and its iOS, the memory
//  peak, the engine and the notes. Of a result Cartouche's game
//  measurements made, Cartouche says the engine and the note itself
//  (CartoucheMeasuredNote.swift), of iPhones or of iPads. What testers
//  wrote, in English, the iPhone translates, as it does IGDB's summaries
//  (CartoucheGameSummaryView.swift), with Apple's Translation, from iOS 18:
//  at once when it has both languages, else when the player taps Translate,
//  which first offers to download them; once, as each translation is kept
//  (CartoucheTranslations.swift). The originals stay a tap away. Nothing
//  leaves the iPhone for it.
//

import SwiftUI
import Translation

/// The testers' results of a game's sheet.
@available(iOS 17.0, *)
struct CartoucheGameResultsSection: View {
    let results: [CartoucheGameSheet.Result]

    /// The results as the sheet lists them, the newest first.
    static func ordered(_ results: [CartoucheGameSheet.Result]) -> [CartoucheGameSheet.Result] {
        results.sorted { $0.date > $1.date }
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            if let target = CartoucheGameSummaryView.language {
                CartoucheTranslatedResults(results: results, target: target)
            } else {
                untranslated
            }
        } else {
            untranslated
        }
    }

    /// In English, or before iOS 18: what testers wrote, as they wrote it.
    private var untranslated: some View {
        Section(CartoucheText.results) {
            CartoucheResultRows(results: results, translations: [:])
        }
    }
}

extension CartoucheText {
    /// The words of a result Cartouche's game measurements made
    /// (CartoucheTextResults.swift), with the iPhone's numbers and dates.
    /// Here rather than in CartoucheText.swift, which packages without
    /// CartoucheTextResults.swift build too (launcher/StorageTests).
    static var measuredWords: CartoucheMeasuredWords {
        CartoucheMeasuredWords(text: { key, english in s(key, english) }, locale: Locale.current)
    }
}

extension CartoucheGameSheet.Result {
    /// Its engine and notes as the sheet shows them, in WORDS
    /// (CartoucheMeasuredNote.lines).
    func lines(words: CartoucheMeasuredWords) -> (engine: CartoucheResultLine, notes: [CartoucheResultLine]) {
        CartoucheMeasuredNote.lines(device: device, engine: engine, notes: notes ?? [], measured: measured, words: words)
    }
}

/// Each result, with what testers wrote in Cartouche's language where
/// TRANSLATIONS has it.
@available(iOS 17.0, *)
private struct CartoucheResultRows: View {
    let results: [CartoucheGameSheet.Result]
    /// What testers wrote, translated, by what they wrote.
    let translations: [String: String]

    var body: some View {
        let words = CartoucheText.measuredWords
        ForEach(CartoucheGameResultsSection.ordered(results), id: \.self) { result in
            let lines = result.lines(words: words)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(CartoucheText.resultStatus(result.status))
                        .font(.headline)
                    Spacer()
                    Text(CartoucheMeasuredNote.day(result.date, locale: words.locale))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(Self.deviceName(result.device) + " · iOS " + result.iOS)
                    .font(.subheadline)
                if let peak = result.peakMemoryMiB {
                    Text(CartoucheText.peak(CartoucheText.memoryAmount(mebibytes: peak)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(shown(lines.engine))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(Array(lines.notes.enumerated()), id: \.offset) { _, note in
                    Text(shown(note))
                        .font(.footnote)
                }
            }
            .padding(.vertical, 2)
            // What the sheet scrolls to, to show the results.
            .id(result)
        }
    }

    private func shown(_ line: CartoucheResultLine) -> String {
        switch line {
        case .said(let text): return text
        case .written(let text): return translations[text] ?? text
        }
    }

    /// The model, with its chip and memory when the catalogue has them, said
    /// to be this one's when it is.
    private static func deviceName(_ identifier: String) -> String {
        var name = identifier
        if let device = CartoucheCatalog.shared.device(identifier) {
            name += " (" + device.chip + ", " + CartoucheText.gigabytes(device.memoryGB) + ")"
        }
        if identifier == CartoucheDevice.modelIdentifier {
            name = CartoucheText.thisModel + " · " + name
        }
        return name
    }
}

/// The results, with what testers wrote in Cartouche's language, as the
/// iPhone translates it, once.
@available(iOS 18.0, *)
private struct CartoucheTranslatedResults: View {
    let results: [CartoucheGameSheet.Result]
    /// Cartouche's language.
    let target: Locale.Language
    /// Cartouche's language, as its translations are kept.
    private let language: String
    /// What testers wrote, each text once.
    private let written: [String]

    @State private var configuration: TranslationSession.Configuration?
    /// The translations of what testers wrote, by what they translate.
    @State private var translations: [String: String]
    /// Whether the iPhone can translate it once it has the languages, which
    /// Translate offers to download.
    @State private var canTranslate = false
    @State private var showsOriginal = false

    // Written out: the private state above would make the synthesized
    // initializer private.
    init(results: [CartoucheGameSheet.Result], target: Locale.Language) {
        self.results = results
        self.target = target
        language = target.minimalIdentifier
        written = Self.writtenTexts(in: results)
        // Translated before: shown as the sheet opens.
        _translations = State(initialValue: Self.kept(written, into: language))
    }

    /// What testers wrote in RESULTS, each text once.
    private static func writtenTexts(in results: [CartoucheGameSheet.Result]) -> [String] {
        let words = CartoucheText.measuredWords
        var seen: Set<String> = []
        return results.flatMap { result -> [String] in
            let lines = result.lines(words: words)
            return ([lines.engine] + lines.notes).compactMap { line -> String? in
                guard case .written(let text) = line else { return nil }
                return text
            }
        }
        .filter { seen.insert($0).inserted }
    }

    /// The translations of TEXTS into LANGUAGE the iPhone made before, for
    /// this sheet or another.
    private static func kept(_ texts: [String], into language: String) -> [String: String] {
        var kept: [String: String] = [:]
        for text in texts {
            kept[text] = CartoucheTranslations.shared.translation(of: text, into: language)
        }
        return kept
    }

    /// What testers wrote that the iPhone has not translated yet.
    private var untranslated: [String] {
        written.filter { translations[$0] == nil }
    }

    var body: some View {
        Section {
            CartoucheResultRows(results: results, translations: showsOriginal ? [:] : translations)
        } header: {
            Text(CartoucheText.results)
                // Translated at once when the iPhone has both languages;
                // otherwise Translate offers to download them. Translated
                // before, they are not asked again.
                .task(id: written) {
                    showsOriginal = false
                    canTranslate = false
                    translations = Self.kept(written, into: language)
                    guard !untranslated.isEmpty else { return }
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
                    let texts = untranslated
                    guard !texts.isEmpty else { return }
                    do {
                        let responses = try await session.translations(from: texts.map { TranslationSession.Request(sourceText: $0) })
                        for response in responses {
                            translations[response.sourceText] = response.targetText
                            CartoucheTranslations.shared.keep(response.targetText, of: response.sourceText, into: language)
                        }
                    } catch {
                        // Not downloaded, or not translated: the originals
                        // stay, and Translate with them.
                        canTranslate = true
                    }
                }
        } footer: {
            footer
        }
    }

    /// Where the translations come from, with the originals a tap away; or
    /// Translate, when the iPhone has yet to download the languages.
    @ViewBuilder
    private var footer: some View {
        if !translations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !showsOriginal {
                    Text(CartoucheText.resultsTranslated)
                }
                Button(showsOriginal ? CartoucheText.summaryShowTranslation : CartoucheText.summaryShowOriginal) {
                    showsOriginal.toggle()
                }
                .font(.footnote.weight(.semibold))
            }
        } else if canTranslate {
            Button(CartoucheText.summaryTranslate) { translate() }
                .font(.footnote.weight(.semibold))
        }
    }

    /// Asks the iPhone for the translations, again if it was asked before.
    private func translate() {
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: CartoucheGameSummaryView.english, target: target)
        } else {
            configuration?.invalidate()
        }
    }
}
