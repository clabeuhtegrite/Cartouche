//
//  CartoucheGamePlace.swift
//  Cartouche
//
//  Where a game has the memory it needs: behind the console, in a process of
//  its own, with the limit iOS sets for that process, or in Cartouche's
//  place, with Cartouche's own limit (docs/decisions.md, 38 and 46). iOS may
//  give either one more than the other, so Cartouche measures both and
//  compares them instead of assuming which is higher: the game's process
//  writes its limit as it runs (CartoucheGameMemoryReading), and Cartouche
//  measures its own (CartoucheMemoryReading). CartoucheGameKeeping
//  (CartoucheRunningGame.swift) asks these questions with them.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

/// The answers, from the two limits in MiB: BEHINDMIB, the one iOS gave the
/// last game behind the console, nil before any ran there; OWNMIB,
/// Cartouche's own, nil when iOS gives none.
enum CartoucheGamePlace {
    /// Increased Memory Limit raises Cartouche's limit by gigabytes: a game's
    /// process this far under it does not have the capability.
    static let capabilityMarginMiB = 256

    /// Whether Cartouche's place gives a game more memory than BEHINDMIB:
    /// Cartouche's own limit is above it, or unknown, as Cartouche took it to
    /// be before it compared them.
    static func cartoucheHasMore(than behindMiB: Int, ownMiB: Int?) -> Bool {
        ownMiB.map { $0 > behindMiB } ?? true
    }

    /// Whether a game that needs Increased Memory Limit (NEEDSIML), or
    /// PEAKMIB at its most, by its sheet, starts behind the console rather
    /// than in Cartouche's place: unless it needs more than it has behind the
    /// console and Cartouche's place has more. Before any game has run behind
    /// the console, every game tries there.
    static func startsBehind(needsIML: Bool, peakMiB: Int?, behindMiB: Int?, ownMiB: Int?) -> Bool {
        guard let behindMiB, cartoucheHasMore(than: behindMiB, ownMiB: ownMiB) else { return true }
        if let peakMiB, peakMiB > behindMiB { return false }
        if needsIML, let ownMiB, behindMiB + capabilityMarginMiB < ownMiB { return false }
        return true
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
}
