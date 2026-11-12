//
//  CartoucheGamePlace.swift
//  Cartouche
//
//  Where a game has the memory it needs: behind the console, in a process of
//  its own, with the limit iOS sets for that process, or in Cartouche's
//  place, with Cartouche's own limit (docs/decisions.md, 38 and 48). The two
//  move apart: on an iPhone with 12 GB and Increased Memory Limit, Game Mode
//  took Cartouche's own from 6,143 MiB to 8,192, while a game's process kept
//  6,144. So Cartouche measures both and compares them instead of assuming
//  which is higher: the game's process writes its limit as it runs
//  (CartoucheGameMemoryReading), and Cartouche measures its own
//  (CartoucheMemoryReading). CartoucheGameKeeping (CartoucheRunningGame.swift)
//  asks these questions with them, and CartoucheGameActions acts on what a
//  game's first measurement there and its end say (afterMeasure,
//  afterStop). The game's process also says whether it has Increased
//  Memory Limit: some installs signed it without, which left a game 3,376
//  MiB there while Cartouche had 8,192 (docs/decisions.md, 67). Cartouche
//  keeps that answer with the install it came from
//  (CartoucheBehindIMLRecord).
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

/// The answers, from the two limits in MiB: BEHINDMIB, the one iOS gave the
/// last game behind the console, nil before any ran there; OWNMIB,
/// Cartouche's own, nil when iOS gives none.
enum CartoucheGamePlace {
    /// Two limits this close count as the same, as 6,143 and 6,144 MiB, which
    /// iOS gave Cartouche and a game's process with the same capability.
    static let marginMiB = 256

    /// Whether Cartouche's place gives a game more memory than BEHINDMIB:
    /// Cartouche's own limit is above it by more than the margin, or
    /// unknown, as Cartouche took it to be before it compared them.
    static func cartoucheHasMore(than behindMiB: Int, ownMiB: Int?) -> Bool {
        ownMiB.map { $0 > behindMiB + marginMiB } ?? true
    }

    /// The room a game keeps under LIMITMIB: a game iOS stopped with less
    /// left, or after a peak closer to it, was near its limit
    /// (CartoucheGameMemoryReading.wasNearLimit).
    static func roomMiB(under limitMiB: Int) -> Int {
        max(512, limitMiB / 8)
    }

    /// Whether a game starts behind the console rather than in Cartouche's
    /// place, by its sheet: PEAKMIB, the most it used, or else NEEDSIML,
    /// whether it needs Increased Memory Limit. Behind the console, unless
    /// Cartouche's place has more and the game needs more: a peak that
    /// leaves less than its room under the limit there, as Mario Kart
    /// World's, up to 6,074 MiB, under 6,144, or, without a peak, the
    /// capability, as a game does that needs all the memory it can have.
    /// Without a peak, any game needs more once the process there ran
    /// without the capability, BEHINDLACKSIML: iOS stopped Donkey Kong
    /// Bananza within seconds there, four times, with 3,376 MiB, while
    /// Cartouche's place had 8,192.
    /// Before any game has run behind the console, every game tries there.
    static func startsBehind(needsIML: Bool, peakMiB: Int?, behindMiB: Int?, behindLacksIML: Bool = false,
                             ownMiB: Int?) -> Bool {
        guard let behindMiB, cartoucheHasMore(than: behindMiB, ownMiB: ownMiB) else { return true }
        if let peakMiB { return peakMiB + roomMiB(under: behindMiB) <= behindMiB }
        return !needsIML && !behindLacksIML
    }

    /// Whether every game starts in Cartouche's place, but one whose peak
    /// fits behind the console: the process there ran without Increased
    /// Memory Limit, BEHINDLACKSIML, and Cartouche's place has more.
    static func sendsGamesInPlace(behindMiB: Int?, behindLacksIML: Bool, ownMiB: Int?) -> Bool {
        guard behindLacksIML, let behindMiB else { return false }
        return cartoucheHasMore(than: behindMiB, ownMiB: ownMiB)
    }

    /// Whether a game that went to Cartouche's place for its memory, after
    /// iOS stopped it behind the console, still starts there: while that
    /// place has more.
    static func staysInPlace(behindMiB: Int?, ownMiB: Int?) -> Bool {
        guard let behindMiB else { return true }
        return cartoucheHasMore(than: behindMiB, ownMiB: ownMiB)
    }

    /// The most memory Play can give a game while games run behind the
    /// console: the limit there, or Cartouche's own, for a game short of
    /// memory there, which starts in Cartouche's place when that has more.
    /// Before any game has run behind the console, Cartouche's own.
    static func gameLimitMiB(behindMiB: Int?, ownMiB: Int?) -> Int? {
        guard let behindMiB else { return ownMiB }
        return max(behindMiB, ownMiB ?? 0)
    }

    /// What follows the first measurement of a game behind the console,
    /// three seconds in (CartoucheGameActions.gameMeasured).
    enum AfterMeasure: Equatable {
        /// It has what it needs there.
        case staysBehind
        /// It starts again in Cartouche's place at once; FROMNOWON, it
        /// starts there from then on too (CartoucheGameKeeping.startInPlace).
        case startsAgainInPlace(fromNowOn: Bool)
    }

    /// What follows the first measurement of a game behind the console, by
    /// the limit iOS set there, LIMITMIB, and NEEDSIML, PEAKMIB,
    /// BEHINDLACKSIML and OWNMIB, as for startsBehind: a game that needs
    /// more than it has there starts again in Cartouche's place, and
    /// starts there from then on, but while the process there runs without
    /// Increased Memory Limit. Every game goes to Cartouche's place then
    /// anyway (sendsGamesInPlace), and one marked for that would stay there
    /// once another install signs that process with the capability, though
    /// it fits behind the console again.
    static func afterMeasure(limitMiB: Int, needsIML: Bool, peakMiB: Int?, behindLacksIML: Bool,
                             ownMiB: Int?) -> AfterMeasure {
        if startsBehind(needsIML: needsIML, peakMiB: peakMiB, behindMiB: limitMiB, behindLacksIML: behindLacksIML,
                        ownMiB: ownMiB) {
            return .staysBehind
        }
        let everyGame = sendsGamesInPlace(behindMiB: limitMiB, behindLacksIML: behindLacksIML, ownMiB: ownMiB)
        return .startsAgainInPlace(fromNowOn: !everyGame)
    }

    /// What follows when iOS stopped a game behind the console, which the
    /// player did not quit (CartoucheGameActions.gameDidEnd).
    enum AfterStop: Equatable {
        /// It starts again in Cartouche's place at once, as its first
        /// measurement would have sent it: the process there runs without
        /// Increased Memory Limit, and the game needs more than it has
        /// there. iOS stopped Donkey Kong Bananza within two seconds,
        /// before that measurement, four times, with 3,376 MiB, while
        /// Cartouche had 8,192.
        case startsAgainInPlace
        /// Stopped near its limit, it starts in Cartouche's place from then
        /// on, which has more, and the console says so.
        case startsInPlaceFromNowOn
        /// Stopped near its limit, it stays behind the console, where it has
        /// as much, and the console says so.
        case staysBehind
        /// Stopped for another cause, or in the background: the console says
        /// so.
        case stopped
    }

    /// What follows when iOS stopped a game behind the console, by its last
    /// reading there: LIMITMIB, the limit iOS set, nil without a reading,
    /// and NEARLIMIT, whether it was close to it
    /// (CartoucheGameMemoryReading.wasNearLimit); WASINFRONT, whether the
    /// game was on screen; STARTPENDING, whether it was already to start
    /// again, as after its first measurement. NEEDSIML, PEAKMIB,
    /// BEHINDLACKSIML and OWNMIB, as for startsBehind.
    static func afterStop(limitMiB: Int?, nearLimit: Bool, wasInFront: Bool, startPending: Bool,
                          needsIML: Bool, peakMiB: Int?, behindLacksIML: Bool, ownMiB: Int?) -> AfterStop {
        guard wasInFront, let limitMiB else { return .stopped }
        if !startPending, sendsGamesInPlace(behindMiB: limitMiB, behindLacksIML: behindLacksIML, ownMiB: ownMiB),
           !startsBehind(needsIML: needsIML, peakMiB: peakMiB, behindMiB: limitMiB, behindLacksIML: behindLacksIML,
                         ownMiB: ownMiB) {
            return .startsAgainInPlace
        }
        guard nearLimit else { return .stopped }
        return cartoucheHasMore(than: limitMiB, ownMiB: ownMiB) ? .startsInPlaceFromNowOn : .staysBehind
    }
}

/// Whether the game's process behind the console ran without Increased
/// Memory Limit, as Cartouche keeps it in DEFAULTS from one launch to the
/// next: with the install of Cartouche that process ran with, INSTALL, as
/// CartoucheGameKeeping names it (its version, its build and its bundle
/// folder, which iOS moves at each install). Another install signs that
/// process again, maybe with the capability: its record of an earlier
/// install goes, and the next game tries behind the console again.
struct CartoucheBehindIMLRecord {
    static let key = "Cartouche.keepConsoleOpen.lacksIML"

    let defaults: UserDefaults
    let install: String

    /// Whether the process ran without the capability with this install.
    func load() -> Bool {
        guard let recorded = defaults.string(forKey: Self.key) else { return false }
        if recorded == install { return true }
        defaults.removeObject(forKey: Self.key)
        return false
    }

    /// What the process said, HAS, nil when it could not tell, which leaves
    /// LACKED, what was known: whether it runs without the capability now.
    func record(has: Bool?, lacked: Bool) -> Bool {
        guard let has else { return lacked }
        if has {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(install, forKey: Self.key)
        }
        return !has
    }

    /// The player tries behind the console again: the next game there says
    /// whether its process has the capability.
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
