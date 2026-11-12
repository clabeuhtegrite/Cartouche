//
//  ComebackReads.swift
//  Cartouche Builder
//
//  When the app reads the dumps and the games folder again as the player
//  comes back to it, maybe from the Finder, where they put a game in one of
//  them: at once, so that the game shows, but at most once in ten seconds,
//  so that going from one window to another does not read them each time.
//  The read the app makes as it opens counts as one.
//

import Foundation

public struct ComebackReads: Sendable {
    /// The least time between two reads.
    public let interval: TimeInterval
    /// When the library was last read for the player's coming back, or as
    /// the app opened.
    private var last: Date?

    public init(interval: TimeInterval = 10) {
        self.interval = interval
    }

    /// Notes a read of the library at NOW, as the app makes as it opens.
    public mutating func read(at now: Date = Date()) {
        last = now
    }

    /// Whether the player's coming back at NOW reads the library again; if
    /// it does, that read counts from NOW.
    public mutating func comeBack(at now: Date = Date()) -> Bool {
        if let last, now.timeIntervalSince(last) < interval { return false }
        last = now
        return true
    }
}
