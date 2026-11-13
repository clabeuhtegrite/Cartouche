//
//  CartoucheReleaseNotes.swift
//  Cartouche
//
//  What each version of Cartouche brings, as its release notes say it:
//  app/releases/<version>.md, in English, and <version>.<language>.md, such
//  as 0.12.2.fr.md, in another language of Cartouche's, which the build
//  puts in the app (CartoucheReleases/, app/scripts/package.sh). And which
//  of them the player sees as Cartouche opens (CartoucheWhatsNewRecord):
//  those of the version just installed, once, after an update, however it
//  came, never after a first install; the console shows them
//  (CartoucheWhatsNewView.swift). Foundation only, so that swift test
//  checks it on a Mac (launcher/Package.swift).
//
//  The notes are plain text, as the source the built-in SideStore reads
//  carries them too: a first paragraph that says in a sentence what the
//  version brings, then one item per line that begins with "- ". An item
//  may begin with its topic, a few words before a colon, such as "Games: "
//  or "Jeux : ", which the console sets in bold. The space French puts
//  before a colon, as there, becomes a no-break one, so that no line of
//  the console starts with the colon.
//

import Foundation

/// A version's release notes.
struct CartoucheReleaseNotes: Equatable, Identifiable {
    struct Item: Equatable {
        /// What the item is about, as it begins it, colon included, such as
        /// "Games:" or "Jeux :"; nil when it begins otherwise.
        let topic: String?
        /// The rest of the item, or all of it.
        let text: String
    }

    let version: String
    /// The first paragraph, or paragraphs, before the items.
    let summary: String
    let items: [Item]

    var id: String { version }

    /// A topic is at most this long, and this many words: longer, the words
    /// before the colon are a sentence of the item, such as "Cartouche
    /// Installer 0.2.1, for Mac and Windows: the two-factor code…".
    static let topicLength = 30
    static let topicWords = 4

    /// The notes of VERSION in TEXT; nil when VERSION is not numbers between
    /// dots, or TEXT says nothing.
    init?(version: String, text: String) {
        guard CartoucheVersion.numbers(version) != nil else { return nil }
        var paragraphs: [String] = []
        var items: [String] = []
        // Whether a blank line came since the last line of text.
        var blank = true
        // By character, so that a Windows line end, "\r\n", is one, not a
        // line end and a blank line.
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blank = true
            } else if line.hasPrefix("- ") {
                items.append(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
                blank = false
            } else if items.isEmpty {
                // The summary: a line after a blank one starts a paragraph,
                // the others carry on the one above.
                if blank || paragraphs.isEmpty { paragraphs.append(line) } else { paragraphs[paragraphs.count - 1] += " " + line }
                blank = false
            } else {
                // After the items: a line that carries on the item above, or,
                // after a blank line, one more item.
                if blank { items.append(line) } else { items[items.count - 1] += " " + line }
                blank = false
            }
        }
        guard !paragraphs.isEmpty || !items.isEmpty else { return nil }
        self.version = version
        summary = Self.keepingMarksWithWords(paragraphs.joined(separator: "\n\n"))
        self.items = items.map { Self.item(Self.keepingMarksWithWords($0)) }
    }

    /// TEXT with a no-break space where French puts a space before a colon,
    /// a semicolon, an exclamation or a question mark, and inside its
    /// quotes: none of them goes to the next line alone. English has no
    /// space there.
    static func keepingMarksWithWords(_ text: String) -> String {
        var text = text
        for (spaced, kept) in [(" :", "\u{00A0}:"), (" ;", "\u{00A0};"), (" !", "\u{00A0}!"), (" ?", "\u{00A0}?"),
                               ("« ", "«\u{00A0}"), (" »", "\u{00A0}»")] {
            text = text.replacingOccurrences(of: spaced, with: kept)
        }
        return text
    }

    /// An item's text, with its topic apart when it begins with one.
    static func item(_ text: String) -> Item {
        // The first colon followed by a space, as in "Games: " or, in French,
        // "Jeux : ", with an ordinary or a no-break space either side.
        let spaces = CharacterSet(charactersIn: " \u{00A0}\u{202F}\t")
        var search = text.startIndex
        while let colon = text[search...].firstIndex(of: ":") {
            let after = text.index(after: colon)
            guard after < text.endIndex else { break }
            guard let next = text[after].unicodeScalars.first, spaces.contains(next) else {
                // A time, such as 10:30, or a URL: not a topic's colon.
                search = after
                continue
            }
            let lead = text[..<colon].trimmingCharacters(in: spaces)
            let rest = text[after...].trimmingCharacters(in: spaces)
            let words = lead.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" })
            guard !lead.isEmpty, !rest.isEmpty, lead.count <= topicLength, words.count <= topicWords,
                  !lead.contains(where: { ".!?;".contains($0) }) else { break }
            // As written: "Jeux :" keeps its space before the colon.
            let topic = text[..<after].trimmingCharacters(in: spaces)
            return Item(topic: topic, text: rest)
        }
        return Item(topic: nil, text: text)
    }

    /// The notes of each version in FOLDER, newest first: in LANGUAGE, such
    /// as "fr", when they are written in it (<version>.fr.md), in English
    /// (<version>.md) otherwise. A version without its English notes is left
    /// out, as Release refuses to publish one.
    static func all(in folder: URL, language: String?) -> [CartoucheReleaseNotes] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var english: [String: String] = [:]
        var translated: [String: [String: String]] = [:]
        for name in names where name.hasSuffix(".md") {
            let stem = String(name.dropLast(3))
            if CartoucheVersion.numbers(stem) != nil {
                english[stem] = name
            } else if let dot = stem.lastIndex(of: "."), CartoucheVersion.numbers(String(stem[..<dot])) != nil {
                translated[String(stem[..<dot]), default: [:]][String(stem[stem.index(after: dot)...])] = name
            }
        }
        let wanted = languages(language)
        return english.keys
            .sorted { CartoucheVersion.isHigher($0, than: $1) }
            .compactMap { version in
                let names = wanted.compactMap { translated[version]?[$0] } + [english[version]!]
                // A translation that says nothing gives way to the English.
                return names.lazy.compactMap { name in
                    (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8))
                        .flatMap { CartoucheReleaseNotes(version: version, text: $0) }
                }.first
            }
    }

    /// The names of LANGUAGE to look for, the most precise first: "fr-CA",
    /// then "fr". English has none: its notes are <version>.md.
    static func languages(_ language: String?) -> [String] {
        guard let language, !language.isEmpty, language != "Base" else { return [] }
        let base = String(language.prefix { $0 != "-" && $0 != "_" })
        let names = base == language ? [language] : [language, base]
        return base == "en" ? [] : names
    }
}

/// Which release notes the player sees as Cartouche opens, and the version
/// whose notes they have seen, which the preferences keep.
///
/// After an update, the notes of the version installed, once: until the
/// player closes them. A first install shows none, and keeps its version
/// as seen. An update over several versions shows the notes of each since
/// the one last seen, at most the newest three. An update from a Cartouche
/// older than this record, which kept no version, shows the notes of the
/// version installed, when that Cartouche left something of the player's
/// in the preferences (earlierKeys); a new install has nothing there.
struct CartoucheWhatsNewRecord {
    static let seenKey = "Cartouche.whatsNew.seen"
    /// What a Cartouche older than this record leaves in the preferences
    /// once the player has used it: the guide to the first game, opened or
    /// done; an update started from Cartouche, which leaves the version it
    /// installs; a put-off update. A new install has none as it opens: the
    /// console writes the guide's once it shows. Not the player's storage,
    /// which a new install of a deleted Cartouche finds again in the
    /// keychain (CartoucheStorage) and keeps before the console opens.
    static let earlierKeys = [
        "Cartouche.guide.opened", "Cartouche.guide.finished", "Cartouche.guide.cardHidden",
        "Cartouche.guide.buildSkipped", "Cartouche.update.pending", "Cartouche.update.later.version",
    ]
    /// The most versions whose notes show at once, the newest.
    static let most = 3

    let defaults: UserDefaults

    /// The version whose notes the player has seen, or was installed new.
    var seen: String? { defaults.string(forKey: Self.seenKey) }

    /// The notes to show as version RUNNING opens, newest first, among NOTES,
    /// those of every version the app carries. When there are none, as on a
    /// first install, RUNNING is kept as seen.
    func notesToShow(running: String, among notes: [CartoucheReleaseNotes]) -> [CartoucheReleaseNotes] {
        let seen = seen
        let earlier = seen == nil && Self.earlierKeys.contains { defaults.object(forKey: $0) != nil }
        let shown = Self.choose(seen: seen, earlierRun: earlier, running: running, among: notes)
        if shown.isEmpty { noteSeen(running) }
        return shown
    }

    /// The player has seen the notes of RUNNING, or had none to see: none
    /// of a version up to it shows again. A lower version, as when an older
    /// Cartouche is installed again, leaves the record as it was.
    func noteSeen(_ running: String) {
        guard CartoucheVersion.numbers(running) != nil else { return }
        if let seen, !CartoucheVersion.isHigher(running, than: seen) { return }
        defaults.set(running, forKey: Self.seenKey)
    }

    /// The notes of NOTES to show as RUNNING opens, newest first: none unless
    /// RUNNING has its own; after SEEN, those of each version above it, up
    /// to RUNNING, the newest MOST; with no version seen, those of RUNNING
    /// alone if an EARLIERRUN of Cartouche left its traces, none on a new
    /// install.
    static func choose(seen: String?, earlierRun: Bool, running: String,
                       among notes: [CartoucheReleaseNotes]) -> [CartoucheReleaseNotes] {
        guard let current = notes.first(where: { CartoucheVersion.isSame($0.version, running) }) else { return [] }
        guard let seen else { return earlierRun ? [current] : [] }
        guard CartoucheVersion.isHigher(running, than: seen) else { return [] }
        let since = notes.filter { CartoucheVersion.isHigher($0.version, than: seen) && !CartoucheVersion.isHigher($0.version, than: running) }
            .sorted { CartoucheVersion.isHigher($0.version, than: $1.version) }
        return Array(since.prefix(most))
    }
}

extension CartoucheVersion {
    /// Whether A and B are the same version, "1.2" being "1.2.0".
    static func isSame(_ a: String, _ b: String) -> Bool {
        numbers(a) != nil && numbers(b) != nil && !isHigher(a, than: b) && !isHigher(b, than: a)
    }
}
