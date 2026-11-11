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
//  asks these questions with them.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

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
    /// Before any game has run behind the console, every game tries there.
    static func startsBehind(needsIML: Bool, peakMiB: Int?, behindMiB: Int?, ownMiB: Int?) -> Bool {
        guard let behindMiB, cartoucheHasMore(than: behindMiB, ownMiB: ownMiB) else { return true }
        if let peakMiB { return peakMiB + roomMiB(under: behindMiB) <= behindMiB }
        return !needsIML
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
