//
//  CartoucheTextSwitchSave.swift
//  Cartouche
//
//  The words of a game's save between the player's Switch and this iPhone
//  (CartoucheSwitchSaveView.swift), in Cartouche.xcstrings with the others
//  (CartoucheText.swift).
//

import Foundation

extension CartoucheText {
    // MARK: Saves of the Switch

    static var switchSaveTitle: String { s("switchSave.title", "Switch saves") }
    static var switchSaveImportHeader: String { s("switchSave.import.header", "Continue a game from the Switch") }
    static var switchSaveIntro: String { s("switchSave.import.intro", "On your Switch, export this game’s save with JKSV or Checkpoint, then put its folder or its ZIP on this iPhone, in Files: from the microSD card with a USB-C reader, through iCloud Drive or from your NAS.") }
    static var switchSaveSwitch2: String { s("switchSave.switch2", "No public tool exports a Switch 2 game’s save yet.") }
    static var switchSaveChoose: String { s("switchSave.choose", "Choose the exported save") }
    static var switchSaveGame: String { s("switchSave.game", "Game") }
    static var switchSaveChecked: String { s("switchSave.game.checked", "This one, by JKSV’s fiche") }
    static var switchSaveUnchecked: String { s("switchSave.game.unchecked", "Not checked: no JKSV fiche") }
    static var switchSaveKind: String { s("switchSave.kind", "Save") }
    static var switchSaveAccount: String { s("switchSave.kind.account", "A player’s") }
    static var switchSaveDevice: String { s("switchSave.kind.device", "The console’s") }
    static var switchSaveContent: String { s("switchSave.content", "Content") }
    static func switchSaveFiles(_ count: Int, _ size: String) -> String {
        count == 1 ? f("switchSave.files.one", "1 file, %@", size) : f("switchSave.files.many", "%lld files, %@", count, size)
    }
    static var switchSaveVersion: String { s("switchSave.version", "Version on this iPhone") }
    static var switchSaveImport: String { s("switchSave.import.action", "Continue this game here") }
    static var switchSaveImportFooter: String { s("switchSave.import.footer", "The game on your Switch should not be newer than this iPhone’s: a game may not read the save of a newer version.") }
    static var switchSaveImportQuestion: String { s("switchSave.import.question", "Continue this game here?") }
    static var switchSaveImportMessage: String { s("switchSave.import.message", "It replaces this game’s save on this iPhone, which Cartouche keeps here: you can put it back.") }
    static var switchSaveImportMessageFolder: String { s("switchSave.import.message.folder", "It replaces this game’s save on this iPhone, which Cartouche keeps here: you can put it back. It then goes to your saves folder, as the newest copy.") }
    static var switchSaveImported: String { s("switchSave.import.done", "The game from your Switch is in place: start the game to continue it.") }
    static var switchSaveImportedSending: String { s("switchSave.import.sending", "It goes to your saves folder too, for your other iPhones.") }
    static var switchSavePutBack: String { s("switchSave.putBack", "Put back the game from before the import") }
    static func switchSavePutBackFooter(_ date: String) -> String { f("switchSave.putBack.footer", "Cartouche kept this iPhone’s save when the game from your Switch replaced it, on %@.", date) }
    static var switchSavePutBackQuestion: String { s("switchSave.putBack.question", "Put back the game from before the import?") }
    static var switchSavePutBackMessage: String { s("switchSave.putBack.message", "It replaces the game from your Switch on this iPhone, which Cartouche keeps too.") }
    static var switchSavePutBackDone: String { s("switchSave.putBack.done", "The game from before the import is back.") }
    static var switchSaveSendHeader: String { s("switchSave.send.header", "Send this game to the Switch") }
    static var switchSaveSendMake: String { s("switchSave.send.make", "Make the ZIP for JKSV") }
    static func switchSaveSendShare(_ name: String) -> String { f("switchSave.send.share", "Share %@", name) }
    static var switchSaveSendFooter: String { s("switchSave.send.footer", "Put the ZIP on your Switch’s microSD card, in the game’s folder of JKSV (JKSV, then the game’s name), then restore it in JKSV over the game’s save.") }
    static var switchSaveSendNone: String { s("switchSave.send.none", "This game has no save on this iPhone yet.") }
    static var switchSaveRunning: String { s("switchSave.running", "Quit the game to bring in or send its save.") }

    // MARK: What cannot come

    static var switchSaveEmpty: String { s("switchSave.problem.empty", "There is no save in it: choose the folder or the ZIP that JKSV or Checkpoint made.") }
    static var switchSaveSeveral: String { s("switchSave.problem.several", "It holds more than one save: choose the folder or the ZIP of one.") }
    static var switchSaveUnreadable: String { s("switchSave.problem.unreadable", "It is not a save Cartouche can read.") }
    static func switchSaveCaseClash(_ first: String, _ second: String) -> String {
        f("switchSave.problem.case", "Two of its files differ only by their capitals, %1$@ and %2$@: the iPhone cannot keep both.", first, second)
    }
    static func switchSaveOtherGame(_ game: String) -> String { f("switchSave.problem.otherGame", "It is the save of another game: %@.", game) }
    static var switchSaveNotAGame: String { s("switchSave.problem.notAGame", "It is not a game’s save, but system, BCAT or cache data.") }
    static var switchSaveStartFirst: String { s("switchSave.problem.startFirst", "It is the console’s save: start the game once, then come back, and Cartouche will know where it goes.") }
    static var switchSaveCloudPull: String { s("switchSave.problem.cloudPull", "nxnative did not finish bringing this game’s save from iCloud: start the game once, then come back.") }

    // MARK: What failed

    static var switchSaveReadFailed: String { s("switchSave.failed.read", "The save was not read") }
    static var switchSaveImportFailed: String { s("switchSave.failed.import", "The game from your Switch was not put in place") }
    static var switchSavePutBackFailed: String { s("switchSave.failed.putBack", "The game from before the import was not put back") }
    static var switchSaveSendFailed: String { s("switchSave.failed.send", "The ZIP for the Switch was not made") }
}
