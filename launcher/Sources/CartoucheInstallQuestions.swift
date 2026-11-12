//
//  CartoucheInstallQuestions.swift
//  Cartouche
//
//  The question an install of a game asks first, on an iPhone whose GPU
//  cannot read BC-compressed textures, the A16's and older: nxnative
//  refuses that GPU for every game, and players with an iPhone 13 Pro or an
//  iPhone 15 installed games that closed at once, before their first image
//  (docs/decisions.md, 67). A game an older nxnative built may still run,
//  so the player decides: Install anyway, or Cancel. One question is on
//  screen at a time: an install asked for meanwhile, as from another app,
//  takes its place, and the one it replaces goes unanswered, as Cancel
//  leaves it. CartoucheGameActions asks them, and the console shows them
//  (CartoucheGamesView).
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

/// The questions of the installs, each named by INSTALL, what it installs
/// from: a file, or a game in the player's games folder.
struct CartoucheInstallQuestions<Install: Equatable> {
    /// The question on screen, unanswered.
    private(set) var asked: Install?

    /// What an install of INSTALL does now: it starts on a GPU that reads
    /// BC-compressed textures, READSBCTEXTURES, or once the player said to
    /// install it all the same, ANSWERED; otherwise it asks first, in place
    /// of the question on screen, which goes unanswered: DROPPED.
    mutating func install(_ install: Install, readsBCTextures: Bool,
                          answered: Bool) -> (starts: Bool, dropped: Install?) {
        if readsBCTextures || answered {
            if asked == install { asked = nil }
            return (true, nil)
        }
        let dropped = asked == install ? nil : asked
        asked = install
        return (false, dropped)
    }

    /// The question of INSTALL left the screen, answered or not: it goes,
    /// unless another took its place.
    mutating func close(_ install: Install) {
        if asked == install { asked = nil }
    }
}
