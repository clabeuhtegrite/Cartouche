//
//  CartoucheGameLanguage.swift
//  Cartouche
//
//  The language a game starts in. A Switch hands a game its own language
//  when the game has it, else a close one among the game's
//  (nn::oe::GetDesiredLanguage); nxnative hands it DM_LANG: the player's
//  choice, saved in the game's preferences ("launcher.DM_LANG"), else the
//  language its IPA was built with (DMLanguage). Cartouche picks that
//  choice from the iPhone's languages, as a Switch from its own: before the
//  game starts, the first of the iPhone's languages (Settings › General ›
//  Language & Region, in their order) that the game has, a language's other
//  forms counting as that language, the iPhone's own form first: American
//  or British English, French of France or Canada, Spanish of Spain or
//  Latin America, Portuguese of Portugal or Brazil, Simplified or
//  Traditional Chinese. A game that has none of them starts in its own. A
//  language the player chooses for a game, in Cartouche or on nxnative's
//  screen, stays that game's.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

enum CartoucheGameLanguage {
    /// nxnative's variable for the game's language (its settings.tsv): a
    /// choice among the game's languages, which the game reads once, as it
    /// starts.
    static let variable = "DM_LANG"
    /// Where nxnative saves the player's choice, in the game's preferences.
    static let savedKey = "launcher." + variable
    /// Who chose the game's language, a Source; absent until Cartouche
    /// first started the game, or showed its choice.
    static let sourceKey = "cartouche.languageSource"
    /// The language Cartouche last chose from the iPhone's.
    static let iPhoneKey = "cartouche.iPhoneLanguage"

    enum Source: String {
        /// Chosen again from the iPhone's languages at each start.
        case iPhone
        /// The player's choice.
        case player
    }

    /// What a game's preferences hold of its language.
    struct Record: Equatable {
        /// nxnative's saved choice: the language the game starts in, if
        /// the game still has it.
        var saved: String?
        var source: Source?
        /// The language Cartouche last chose from the iPhone's.
        var iPhone: String?
    }

    // MARK: The iPhone's languages

    /// The regions of the Americas, where a Switch's English is American and
    /// its Spanish Latin American: North, Central and South America, the
    /// Caribbean and the United States' islands, by their ISO 3166 codes,
    /// and Latin America's own, 419.
    private static let americas: Set<String> = [
        "US", "CA", "MX", "BM", "GL", "PM",
        "BZ", "CR", "GT", "HN", "NI", "PA", "SV",
        "AG", "AI", "AW", "BB", "BL", "BQ", "BS", "CU", "CW", "DM", "DO", "GD", "GP", "HT", "JM", "KN", "KY",
        "LC", "MF", "MQ", "MS", "PR", "SX", "TC", "TT", "VC", "VG", "VI",
        "AR", "BO", "BR", "CL", "CO", "EC", "FK", "GF", "GY", "PE", "PY", "SR", "UY", "VE",
        "AS", "GU", "MP", "UM",
        "419", "005", "013", "019", "021", "029",
    ]

    /// The language, script and region of a language identifier as iOS
    /// lists them ("zh-Hant-TW", "en_GB", "es-419"); what follows them, such
    /// as a variant or "@" keywords, is left out.
    static func parts(of identifier: String) -> (language: String, script: String?, region: String?) {
        let tags = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let subtags = tags.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let language = subtags.first?.lowercased() else { return ("", nil, nil) }
        var script: String?
        var region: String?
        for tag in subtags.dropFirst() {
            let letters = tag.allSatisfy { $0.isASCII && $0.isLetter }
            let digits = tag.allSatisfy { $0.isASCII && $0.isNumber }
            if script == nil, region == nil, tag.count == 4, letters {
                script = tag.prefix(1).uppercased() + tag.dropFirst().lowercased()
            } else if region == nil, (tag.count == 2 && letters) || (tag.count == 3 && digits) {
                region = tag.uppercased()
            } else {
                break
            }
        }
        return (language, script, region)
    }

    /// The Switch's languages, by nxnative's codes (its nacp.py), that one
    /// of the iPhone's languages stands for, the closest first: "fr-CA"
    /// gives Canadian French, then French. Empty for a language no Switch
    /// game has, such as Polish. Chinese also goes by its older codes,
    /// zh-CN and zh-TW, which some games' lists may use.
    static func codes(for identifier: String) -> [String] {
        let (language, script, region) = parts(of: identifier)
        let inAmericas = region.map { americas.contains($0) } ?? false
        switch language {
        case "ja", "ko", "de", "it", "nl", "ru":
            return [language]
        case "en":
            // English without a region is American English on an iPhone.
            return (region == nil || inAmericas) ? ["en-US", "en-GB"] : ["en-GB", "en-US"]
        case "fr":
            return region == "CA" ? ["fr-CA", "fr"] : ["fr", "fr-CA"]
        case "es":
            // Spanish without a region is Spain's on an iPhone.
            return inAmericas ? ["es-419", "es"] : ["es", "es-419"]
        case "pt":
            // Portuguese without a region is Brazil's on an iPhone.
            return (region == nil || region == "BR") ? ["pt-BR", "pt"] : ["pt", "pt-BR"]
        case "zh", "yue":
            // Cantonese is written in Traditional Chinese, unless its script
            // says otherwise; Chinese without a script, by its region.
            let traditional = script.map { $0 == "Hant" }
                ?? (language == "yue" || ["TW", "HK", "MO"].contains(region ?? ""))
            let simplified = ["zh-Hans", "zh-CN"], traditionalCodes = ["zh-Hant", "zh-TW"]
            return traditional ? traditionalCodes + simplified : simplified + traditionalCodes
        default:
            return []
        }
    }

    /// The first of the game's languages (OFFERED, nxnative's codes) that
    /// the iPhone's languages (PREFERRED, in their order) stand for; nil
    /// when the game has none of them.
    static func best(for preferred: [String], among offered: [String]) -> String? {
        for identifier in preferred {
            for code in codes(for: identifier) {
                if let match = offered.first(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) {
                    return match
                }
            }
        }
        return nil
    }

    // MARK: The game's choice

    /// What the game's preferences hold once Cartouche chose from the
    /// iPhone's languages: the first the game has, else its own language,
    /// GAMEDEFAULT. The language is saved even when it is the game's own,
    /// so that a later build of the game, packed with another, starts in it
    /// too.
    static func following(_ preferred: [String], offered: [String], gameDefault: String) -> Record {
        let language = best(for: preferred, among: offered) ?? gameDefault
        return Record(saved: language, source: .iPhone, iPhone: language)
    }

    /// What the game's preferences hold once the player chose LANGUAGE for
    /// the game, even its own: the game no longer follows the iPhone.
    static func chosen(_ language: String) -> Record {
        Record(saved: language, source: .player, iPhone: nil)
    }

    /// What the game's preferences should hold before it starts, from what
    /// they hold (RECORD): the language the iPhone's stand for among the
    /// game's, chosen again at each start, unless the player chose one. A
    /// language nxnative saved before Cartouche first chose is the
    /// player's, from nxnative's screen or from an earlier Cartouche; so is
    /// one that is no longer the one Cartouche chose last, as only
    /// nxnative's screen changes it. A language the game no longer has was
    /// not the player's doing: a new build of the game left it out.
    static func beforeStart(_ record: Record, preferred: [String], offered: [String], gameDefault: String) -> Record {
        let saved = record.saved.flatMap { offered.contains($0) ? $0 : nil }
        switch record.source {
        case .player?:
            return record
        case .iPhone?:
            if let last = record.iPhone, offered.contains(last), (saved ?? gameDefault) != last {
                return Record(saved: record.saved, source: .player, iPhone: nil)
            }
        case nil:
            if saved != nil {
                return Record(saved: record.saved, source: .player, iPhone: nil)
            }
        }
        return following(preferred, offered: offered, gameDefault: gameDefault)
    }

    /// The language the game starts in with RECORD: nxnative's saved
    /// choice when the game has it, else the game's own.
    static func language(of record: Record, offered: [String], gameDefault: String) -> String {
        record.saved.flatMap { offered.contains($0) ? $0 : nil } ?? gameDefault
    }
}
