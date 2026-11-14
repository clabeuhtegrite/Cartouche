//
//  CartoucheTextShortcuts.swift
//  Cartouche
//
//  The words of Siri and the Home Screen: the page of a game's sheet that
//  says how to start the game with Siri or from an icon of its own
//  (CartoucheGameShortcutsView.swift), and what Siri says when Cartouche
//  cannot start it (CartoucheShortcuts.swift), in Cartouche.xcstrings with
//  the others (CartoucheText.swift). The words Siri and Shortcuts show of
//  Cartouche's action, its title and phrases, are the action's own, with
//  their French in launcher/AppIntents/fr.json: the steps below name the
//  action as Shortcuts does.
//

import Foundation

extension CartoucheText {
    // MARK: Siri and the Home Screen

    static var shortcutsTitle: String { s("shortcuts.title", "Siri and Home Screen") }
    static func shortcutsIntro(_ name: String) -> String {
        f("shortcuts.intro", "Siri and Shortcuts start %@ as Play does, behind the console or in Cartouche’s place.", name)
    }
    static var shortcutsSiri: String { s("shortcuts.siri", "Say to Siri") }
    /// The sentence Siri takes, with the game's NAME.
    static func shortcutsPhrase(_ name: String) -> String { f("shortcuts.phrase", "“Play %@ in Cartouche”", name) }
    /// Another sentence Siri takes, with a shorter NAME of the game.
    static func shortcutsShorter(_ name: String) -> String { f("shortcuts.shorter", "“Play %@ in Cartouche” works too.", name) }
    static var shortcutsSiriFooter: String {
        s("shortcuts.siri.footer", "Siri needs Cartouche’s name in the sentence. To say the game’s name alone, give it to a shortcut, below.")
    }
    static var shortcutsHome: String { s("shortcuts.home", "An icon on the Home Screen") }
    static var shortcutsStepNew: String { s("shortcuts.step1", "In Shortcuts, tap + to make a new shortcut.") }
    static var shortcutsStepAction: String { s("shortcuts.step2", "Tap Add Action, search for Cartouche, and choose Play a Game.") }
    static func shortcutsStepGame(_ name: String) -> String { f("shortcuts.step3", "Tap Game, then choose %@.", name) }
    static func shortcutsStepName(_ name: String) -> String {
        f("shortcuts.step4", "Tap the shortcut’s name at the top and rename it as you will say it to Siri, such as “%@”.", name)
    }
    static var shortcutsStepHome: String {
        s("shortcuts.step5", "Tap the Share button, then Add to Home Screen. Its icon starts the game as Play does.")
    }

    // MARK: What Siri says

    static func shortcutNotInstalled(_ name: String) -> String { f("shortcut.notInstalled", "%@ is no longer installed in Cartouche.", name) }
    /// WORK: what Cartouche does, "Installing Mario Kart World".
    static func shortcutBusy(_ work: String) -> String { f("shortcut.busy", "Cartouche is busy: %@. Try again once it is over.", work) }
}
