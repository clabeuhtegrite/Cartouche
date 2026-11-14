//
//  CartoucheGameNames.swift
//  Cartouche
//
//  The names Siri and Shortcuts know a game of the player's by
//  (CartoucheShortcuts.swift): the name the console shows, and the shorter
//  ones a player says, "Mario Kart" for Mario Kart World or "Ocarina of
//  Time" for The Legend of Zelda: Ocarina of Time; and the games that what
//  a player types in Shortcuts finds.
//
//  A shorter name goes only to a game that no other of the player's games
//  could also take it from: Siri would then have to ask which one.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

enum CartoucheGameNames {
    /// The words a shorter name never starts with, in English and French.
    static let articles: Set<String> = ["the", "a", "an", "le", "la", "les", "l"]
    /// The words a shorter name never ends with: "Tales of" says nothing.
    static let joining: Set<String> = articles.union(["of", "and", "to", "in", "on", "for", "de", "du", "des", "et", "en", "au", "aux"])

    /// The shorter names of NAME that Siri also takes, in the order they
    /// come: each part of a name that a colon or a dash cuts in two, "The
    /// Legend of Zelda" and "Ocarina of Time"; the first two words of a
    /// name of three, "Mario Kart" of Mario Kart World, unless the second
    /// only joins the others, as in Tales of Arise; and each of those, and
    /// the name, without its article, "Legend of Zelda". None is a
    /// single article or shorter than two letters, and none that one of
    /// OTHERS, the player's other games' names, could also take, nor that
    /// names one of them.
    static func synonyms(of name: String, among others: [String]) -> [String] {
        let taken = Set(others.filter { folded($0) != folded(name) }
            .flatMap { [folded($0)] + candidates(of: $0).map(folded) })
        var found: [String] = []
        var seen: Set<String> = [folded(name)]
        for candidate in candidates(of: name) {
            let key = folded(candidate)
            guard key.count >= 2, !articles.contains(key), !taken.contains(key), seen.insert(key).inserted else { continue }
            found.append(candidate)
        }
        return found
    }

    /// Whether QUERY, as a player types or says it, names the game NAME,
    /// which Siri also knows by SYNONYMS: every word of it begins a word of
    /// the name or of one of them, whatever their case, accents and
    /// punctuation. An empty query names no game.
    static func matches(_ query: String, name: String, synonyms: [String] = []) -> Bool {
        let wanted = words(of: query)
        guard !wanted.isEmpty else { return false }
        return ([name] + synonyms).contains { candidate in
            let have = words(of: candidate)
            return wanted.allSatisfy { word in have.contains { $0.hasPrefix(word) } }
        }
    }

    /// TEXT as names compare: lowercase, without accents, its punctuation
    /// as spaces, one space between words.
    static func folded(_ text: String) -> String {
        words(of: text).joined(separator: " ")
    }

    // MARK: Inside

    /// The shorter names NAME could go by, before any is checked.
    private static func candidates(of name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let cut = trimmed.range(of: #"\s*(?::|\s[-–—]\s)\s*"#, options: .regularExpression) {
            let before = String(trimmed[..<cut.lowerBound])
            let after = String(trimmed[cut.upperBound...])
            parts = [before, after].filter { !$0.isEmpty }
        } else {
            let spaced = trimmed.split(separator: " ")
            if spaced.count == 3, !joining.contains(folded(String(spaced[1]))) {
                parts = [spaced.prefix(2).joined(separator: " ")]
            }
        }
        var all: [String] = []
        for part in parts + [trimmed] {
            if part != trimmed { all.append(part) }
            if let bare = withoutArticle(part) { all.append(bare) }
        }
        return all
    }

    /// PART without the article it starts with, if it has one and more
    /// words after it.
    private static func withoutArticle(_ part: String) -> String? {
        let pattern = #"^(?:the|a|an|le|la|les)\s+|^l['’]\s*"#
        guard let range = part.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              range.upperBound < part.endIndex else { return nil }
        return String(part[range.upperBound...])
    }

    /// The words of TEXT, folded: lowercase, without accents, apart at
    /// every space and punctuation mark but an apostrophe, which goes:
    /// "Link's" is "links".
    private static func words(of text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
