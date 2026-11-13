//
//  CartoucheMeasuredNote.swift
//  Cartouche
//
//  A result Cartouche's game measurements made, as a game's sheet shows it
//  under Testers' results, in Cartouche's language: the weekly Game
//  measurements workflow (telemetry/sheets.py) writes its note and its
//  engine in English, and with them every figure they say, in `measured`
//  (catalog/schema/game.schema.json). Cartouche says those figures itself,
//  in its own words (CartoucheTextResults.swift), with the numbers and dates
//  of the player's language: how many iPhones, or iPads, of the model and
//  how many sessions, when, the frame rate and the stutters, how many
//  sessions ended badly and how, and the nxnative builds they reported.
//  What testers wrote stays as they wrote it, for the iPhone to translate
//  (CartoucheGameResultsView.swift). Foundation only, so that swift test
//  checks it on a Mac (launcher/Package.swift).
//

import Foundation

/// What a sheet's result says the game measurements found
/// (catalog/schema/game.schema.json, a result's `measured`).
struct CartoucheMeasured: Decodable, Hashable {
    /// How the sessions that ended badly ended.
    struct EndedBadly: Decodable, Hashable {
        var crashes: Int?
        var outOfMemory: Int?
        var didNotStart: Int?
    }

    /// The iPhones, or iPads, of the model whose sessions count.
    let iPhones: Int
    let sessions: Int
    /// The first and the last day of those sessions: 2026-11-11.
    let from: String
    let to: String
    var fps: Double? = nil
    var slowestFps: Double? = nil
    var targetFps: Int? = nil
    var stuttersPerMinute: Double? = nil
    let endedBadlyPercent: Double
    /// Left out by the sheets made before Cartouche said them.
    var endedBadly: EndedBadly? = nil
    /// The nxnative commit most sessions reported, if any did.
    var nxnative: String? = nil
    /// How many other commits some sessions reported.
    var otherBuilds: Int? = nil
}

/// A line of a result's engine or notes: what Cartouche says itself, in its
/// language, or what a tester wrote, in English, which the iPhone
/// translates.
enum CartoucheResultLine: Hashable {
    case said(String)
    case written(String)
}

/// A measured result's note and engine, and a result's date, in Cartouche's
/// language.
enum CartoucheMeasuredNote {
    /// What sheets.py writes as the engine of a result whose sessions
    /// reported no build, which says it in English.
    static let buildNotReported = "nxnative, its build not reported"

    /// What a result of DEVICE shows of its ENGINE and its NOTES: what
    /// Cartouche says itself of MEASURED, in WORDS, in place of what
    /// sheets.py wrote, the engine and the first note; what testers wrote,
    /// as they wrote it.
    static func lines(device: String, engine: String, notes: [String], measured: CartoucheMeasured?,
                      words: CartoucheMeasuredWords) -> (engine: CartoucheResultLine, notes: [CartoucheResultLine]) {
        guard let measured else {
            return (.written(engine), notes.map { .written($0) })
        }
        let said = self.engine(measured, written: engine, words: words).map { CartoucheResultLine.said($0) }
        return (said ?? .written(engine),
                [.said(note(measured, device: device, words: words))] + notes.dropFirst().map { .written($0) })
    }

    /// What MEASURED found of DEVICE, a model (iPhone19,4, iPad15,3), in
    /// WORDS.
    static func note(_ measured: CartoucheMeasured, device: String, words: CartoucheMeasuredWords) -> String {
        let locale = words.locale
        let lead = words.lead(devices: measured.iPhones, iPads: device.hasPrefix("iPad"), sessions: measured.sessions,
                              period: period(from: measured.from, to: measured.to, locale: locale))
        var figures: [String] = []
        if let fps = measured.fps {
            figures.append(words.fps(number(fps, locale: locale), target: measured.targetFps))
        }
        if let slowest = measured.slowestFps {
            figures.append(words.slowest(number(slowest, locale: locale)))
        }
        if let stutters = measured.stuttersPerMinute {
            figures.append(words.stutters(number(stutters, locale: locale)))
        }
        let ending = self.ending(measured, words: words)
        return figures.isEmpty ? words.withoutFigures(lead, ending)
            : words.withFigures(lead, figures.joined(separator: ", "), ending)
    }

    /// How many sessions ended badly, and how when the sheet says it: the
    /// most first, as sheets.py writes them.
    private static func ending(_ measured: CartoucheMeasured, words: CartoucheMeasuredWords) -> String {
        if let endedBadly = measured.endedBadly {
            let kinds: [(Int, String, (Int) -> String)] = [
                (endedBadly.crashes ?? 0, "crash", words.crashes),
                (endedBadly.outOfMemory ?? 0, "memory-likely", words.outOfMemory),
                (endedBadly.didNotStart ?? 0, "boot-failed", words.didNotStart),
            ].filter { $0.0 > 0 }
            let count = kinds.reduce(0) { $0 + $1.0 }
            if count > 0 {
                let how = kinds.sorted { ($0.0, $1.1) > ($1.0, $0.1) }.map { $0.2($0.0) }.joined(separator: ", ")
                return words.endedBadly(count, how: how)
            }
        }
        // A sheet made before it said how: the share of the sessions.
        let count = Int((measured.endedBadlyPercent * Double(measured.sessions) / 100).rounded())
        return count > 0 ? words.endedBadly(count, how: nil) : words.noneEndedBadly
    }

    /// The nxnative builds the sessions reported, in WORDS; nil for a sheet
    /// made before `measured` named them, whose engine WRITTEN says them its
    /// own way, but when it says none was reported.
    static func engine(_ measured: CartoucheMeasured, written: String, words: CartoucheMeasuredWords) -> String? {
        guard let commit = measured.nxnative else {
            return written == buildNotReported ? words.buildNotReported : nil
        }
        guard let others = measured.otherBuilds, others > 0 else { return "nxnative " + commit }
        return words.builds(commit, others: others)
    }

    /// A day as a result has it, 2026-11-12, with LOCALE's words: 12 nov.
    /// 2026, Nov 12, 2026; as it is when it is no such day.
    static func day(_ day: String, locale: Locale) -> String {
        guard let date = date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = utc
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// From one day to another, with LOCALE's words: 11–12 nov. 2026; the
    /// day alone when they are the same.
    static func period(from: String, to: String, locale: Locale) -> String {
        guard let start = date(from), let end = date(to), start < end else { return day(from, locale: locale) }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = utc
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: end)
    }

    /// A figure as sheets.py rounds it, to a tenth, with LOCALE's digits:
    /// 32,2 in French, 83 rather than 83.0.
    static func number(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let utc = TimeZone(identifier: "UTC")!

    private static func date(_ day: String) -> Date? {
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.calendar = Calendar(identifier: .gregorian)
        reader.timeZone = utc
        reader.dateFormat = "yyyy-MM-dd"
        return reader.date(from: day)
    }
}
