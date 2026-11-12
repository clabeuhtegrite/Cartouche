//
//  CartouchePickerMeasures.swift
//  Cartouche
//
//  What Cartouche can tell of the Files picker a game is imported with
//  (CartoucheImportPicker). The picker runs in a process of iOS's, inside
//  Cartouche's window, so Cartouche sees only how long it took to come on
//  screen, how and when it closed, and whether Cartouche itself kept
//  answering meanwhile: every touch on the picker goes through Cartouche's
//  main thread first. Each picker gives a line of the journal and an
//  `import.picker` event of the game measurements (telemetry/README.md).
//  The measures are written down while the picker is open, so that one
//  still open when Cartouche ended, as when the player, finding it frozen,
//  quits Cartouche from the App Switcher, is told at the next start.
//

import Foundation

struct CartouchePickerMeasures: Codable, Equatable {
    /// How a picker closed.
    enum Outcome: String, Codable, CaseIterable {
        /// The player picked a file.
        case picked
        /// The player cancelled it, in the picker.
        case cancelled
        /// The player closed it with the controller's B.
        case closed
        /// It left the screen, or never came, without a word to Cartouche,
        /// as when its process ends.
        case lost
        /// Cartouche ended while it was open.
        case quit
    }

    /// A wait of Cartouche's main thread the player sees: half a second.
    static let stall: TimeInterval = 0.5

    /// Where the player asked for it: "home", "sheet", "guide".
    let place: String
    let opened: Date
    /// Whether a game controller was connected as it opened.
    let controller: Bool
    /// When it was on screen, its animation over.
    var shown: Date?
    /// The last time Cartouche was seen running while it was open: its main
    /// thread answered, or was found still busy.
    var lastSeen: Date
    /// The longest Cartouche's main thread took to answer while it was
    /// open, in seconds; a wait still going on counts as long as it has
    /// lasted.
    var longestWait: TimeInterval = 0
    /// How many times it took longer than `stall`.
    var stalls = 0
    /// Whether Cartouche went to the background while it was open.
    var wentToBackground = false

    init(place: String, opened: Date, controller: Bool) {
        self.place = place
        self.opened = opened
        self.controller = controller
        lastSeen = opened
    }

    /// Cartouche's main thread answered after WAIT seconds, at DATE.
    mutating func answered(after wait: TimeInterval, at date: Date) {
        longestWait = max(longestWait, wait)
        if wait > Self.stall { stalls += 1 }
        lastSeen = max(lastSeen, date)
    }

    /// Cartouche's main thread has not answered for WAIT seconds, at DATE.
    mutating func stillWaiting(for wait: TimeInterval, at date: Date) {
        longestWait = max(longestWait, wait)
        lastSeen = max(lastSeen, date)
    }

    /// The fields of its `import.picker` event, closed with OUTCOME at
    /// DATE: words a programmer gave and numbers only.
    func fields(_ outcome: Outcome, at date: Date) -> [String: CartoucheTelemetryValue] {
        var fields: [String: CartoucheTelemetryValue] = [
            "outcome": .text(outcome.rawValue),
            "place": .text(place),
            "seconds": .number(max(0, date.timeIntervalSince(opened)).rounded()),
            "longestStallMs": .number((longestWait * 1000).rounded()),
            "stalls": .number(Double(stalls)),
            "background": .flag(wentToBackground),
            "controller": .flag(controller),
        ]
        if let shown {
            fields["shownMs"] = .number((max(0, shown.timeIntervalSince(opened)) * 1000).rounded())
        }
        return fields
    }

    /// Its line of the journal, closed with OUTCOME at DATE: "Files picker
    /// from the home: picked after 12.3 s, on screen after 0.4 s".
    func line(_ outcome: Outcome, at date: Date) -> String {
        let after = Self.seconds(date.timeIntervalSince(opened))
        var line = "Files picker from " + Self.placeName(place) + ": "
        switch outcome {
        case .picked: line += "picked after " + after
        case .cancelled: line += "cancelled after " + after
        case .closed: line += "closed with the controller after " + after
        case .lost: line += "gone without an answer after " + after
        case .quit: line += "still open when Cartouche ended, " + after + " after it opened"
        }
        if let shown {
            line += ", on screen after " + Self.seconds(shown.timeIntervalSince(opened))
        } else {
            line += ", never on screen"
        }
        if longestWait > Self.stall {
            line += ", Cartouche busy for " + Self.seconds(longestWait) + " at the longest"
            if stalls > 1 { line += " (\(stalls) times over half a second)" }
        }
        if wentToBackground { line += ", Cartouche in the background meanwhile" }
        if controller { line += ", a controller connected" }
        return line
    }

    /// "the home", "a game's sheet", "the guide".
    static func placeName(_ place: String) -> String {
        switch place {
        case "home": return "the home"
        case "sheet": return "a game's sheet"
        case "guide": return "the guide"
        default: return place
        }
    }

    /// "12.3 s".
    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f s", max(0, interval))
    }
}

/// Where the measures of the picker open are written down while it is:
/// still there at the next start, they tell of a picker open when Cartouche
/// ended.
struct CartouchePickerMark {
    static let standard = CartouchePickerMark(defaults: .standard)
    static let key = "CartouchePickerOpen"

    let defaults: UserDefaults

    func write(_ measures: CartouchePickerMeasures) {
        guard let data = try? JSONEncoder().encode(measures) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    /// The measures of a picker open when Cartouche last ended, once: they
    /// are wiped as they are read.
    func take() -> CartouchePickerMeasures? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        clear()
        return try? JSONDecoder().decode(CartouchePickerMeasures.self, from: data)
    }
}
