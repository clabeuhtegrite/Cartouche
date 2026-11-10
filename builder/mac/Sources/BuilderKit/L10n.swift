//
//  L10n.swift
//  Cartouche Builder
//
//  The app speaks French or English: the Mac's language, or the one chosen
//  in its settings. Each text is written in both, where it is used:
//  tr("Library", "Bibliothèque").
//

import Foundation

public enum L10n {
    /// The language chosen in the settings: "fr", "en", or "" for the Mac's.
    public private(set) static var chosen = ""
    public private(set) static var french = systemIsFrench

    public static var systemIsFrench: Bool {
        if let forced = ProcessInfo.processInfo.environment["CARTOUCHE_BUILDER_LANG"], !forced.isEmpty {
            return forced.lowercased().hasPrefix("fr")
        }
        return (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("fr")
    }

    public static func use(_ language: String) {
        chosen = language == "fr" || language == "en" ? language : ""
        french = chosen.isEmpty ? systemIsFrench : chosen == "fr"
    }

    /// "fr" or "en": the language in use, for the engine and the formatters.
    public static var code: String { french ? "fr" : "en" }
    public static var locale: Locale { Locale(identifier: french ? "fr_FR" : "en_US") }
}

/// ENGLISH or FRENCH, in the app's language.
public func tr(_ english: String, _ french: String) -> String {
    L10n.french ? french : english
}
