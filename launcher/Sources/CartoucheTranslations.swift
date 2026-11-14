//
//  CartoucheTranslations.swift
//  Cartouche
//
//  The translations the iPhone made of IGDB's summaries
//  (CartoucheGameSummaryView.swift), kept, so that it makes each one once:
//  translating one takes the iPhone a few seconds, which a game's sheet
//  waited each time it opened. Each is kept for the text it was made from
//  and the language it went into, in memory and in a file of Cartouche's
//  caches, so that it outlives Cartouche too; iOS may empty that folder when
//  the iPhone needs room, and the iPhone then translates again. The latest
//  `limit` are kept. Foundation only, so that swift test checks it on a Mac
//  (launcher/Package.swift).
//

import Foundation

/// A translation of a summary, as Cartouche keeps it.
struct CartoucheTranslation: Codable, Equatable {
    /// The language it is in, as Locale.Language's minimal identifier
    /// gives it: fr.
    let language: String
    /// The text translated: IGDB's summary.
    let text: String
    /// The iPhone's translation of it.
    let translation: String

    /// The translation, or nil unless it is as Cartouche keeps one: a
    /// language, a text and a translation, none too long.
    static func checked(_ kept: CartoucheTranslation) -> CartoucheTranslation? {
        let isLanguage = kept.language.utf16.count <= 35
            && kept.language.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
        guard isLanguage, !kept.language.isEmpty,
              CartoucheTranslation.holds(kept.text), CartoucheTranslation.holds(kept.translation) else {
            return nil
        }
        return kept
    }

    /// Whether TEXT is some words, and not too many.
    private static func holds(_ text: String) -> Bool {
        text.utf16.count <= CartoucheTranslations.longest && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct CartoucheTranslationFile: Codable {
    var schema = 1
    /// The oldest made first.
    var translations: [CartoucheTranslation]
}

/// The iPhone's translations of the games' summaries, by text and language,
/// kept in a file of Cartouche's caches.
final class CartoucheTranslations: @unchecked Sendable {
    static let shared = CartoucheTranslations(file: CartoucheTranslations.defaultFile)

    /// The most translations kept, the oldest made going first: one for each
    /// game whose sheet showed IGDB's summary, in each language Cartouche
    /// spoke then.
    static let limit = 200
    /// The longest text and translation kept, in UTF-16 code units: a
    /// summary is 2,000 characters at most (CartoucheCoverList.summary(_:)),
    /// and its translation may take more.
    static let longest = 8_000

    private let file: URL
    private let limit: Int
    /// Guards what follows: a sheet reads the translations on the main
    /// thread, and keeps one from the task the iPhone translates in.
    private let lock = NSLock()
    private var translations: [Key: String] = [:]
    /// The keys of the translations, the oldest made first.
    private var order: [Key] = []

    private struct Key: Hashable {
        let language: String
        let text: String
    }

    /// Keeps the translations in FILE, at most LIMIT of them, starting with
    /// those kept there before.
    init(file: URL, limit: Int = CartoucheTranslations.limit) {
        self.file = file
        self.limit = max(limit, 1)
        for kept in Self.kept(at: file) {
            add(kept)
        }
    }

    /// Where Cartouche keeps them: its caches, which iOS does not back up and
    /// may empty.
    static var defaultFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartouche/SummaryTranslations.json")
    }

    /// The translations kept in FILE, the oldest made first; none when there
    /// is no such file, or it is not as Cartouche writes it.
    static func kept(at file: URL) -> [CartoucheTranslation] {
        guard let data = try? Data(contentsOf: file),
              let kept = try? JSONDecoder().decode(CartoucheTranslationFile.self, from: data), kept.schema == 1 else {
            return []
        }
        return kept.translations.compactMap(CartoucheTranslation.checked)
    }

    /// The iPhone's translation of TEXT into LANGUAGE, if it made one.
    func translation(of text: String, into language: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return translations[Key(language: language, text: text)]
    }

    /// Keeps TRANSLATION, the iPhone's of TEXT into LANGUAGE, and writes the
    /// file again.
    func keep(_ translation: String, of text: String, into language: String) {
        guard let kept = CartoucheTranslation.checked(CartoucheTranslation(language: language, text: text,
                                                                           translation: translation)) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard translations[Key(language: language, text: text)] != translation else { return }
        add(kept)
        save()
    }

    /// Adds KEPT as the latest made, in place of the one of its text and
    /// language, and lets the oldest go beyond the limit. The lock is held,
    /// or the file is being read.
    private func add(_ kept: CartoucheTranslation) {
        let key = Key(language: kept.language, text: kept.text)
        if translations.updateValue(kept.translation, forKey: key) != nil {
            order.removeAll { $0 == key }
        }
        order.append(key)
        while order.count > limit {
            translations[order.removeFirst()] = nil
        }
    }

    /// Writes the translations to the file. The lock is held.
    private func save() {
        let all = order.compactMap { key in
            translations[key].map { CartoucheTranslation(language: key.language, text: key.text, translation: $0) }
        }
        do {
            let data = try JSONEncoder().encode(CartoucheTranslationFile(translations: all))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            // Kept while Cartouche runs, and translated again after.
            NSLog("[Cartouche] cannot keep the summaries' translations: %@", String(describing: error))
        }
    }
}
