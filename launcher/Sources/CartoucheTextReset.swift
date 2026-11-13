//
//  CartoucheTextReset.swift
//  Cartouche
//
//  The words of System › Reset Cartouche (CartoucheResetView.swift,
//  CartoucheReset.swift), in Cartouche.xcstrings with the others
//  (CartoucheText.swift). None names the device: Cartouche runs on an iPad
//  too.
//

import Foundation

extension CartoucheText {
    // MARK: Reset Cartouche

    static var resetTitle: String { s("reset.title", "Reset Cartouche") }
    static var resetFooter: String { s("reset.footer", "Cartouche as just installed, without a computer: your games, settings and storage are erased; the certificate and the pairing file stay.") }
    static var resetIntro: String { s("reset.intro", "Cartouche erases everything you put in it, then starts again as it opened the first time: without a computer, and without installing it again.") }

    static var resetGoesHeader: String { s("reset.goes.header", "Erased") }
    static var resetGoesGames: String { s("reset.goes.games", "Your games, with their saves, settings and play time, and what was kept of the games you uninstalled.") }
    static var resetGoesStorage: String { s("reset.goes.storage", "Your storage: its servers and folders, with their passwords and sign-ins, Google Drive and your Mac among them.") }
    static var resetGoesAccount: String { s("reset.goes.account", "Your Apple ID: you sign in again in Setup.") }
    static var resetGoesSettings: String { s("reset.goes.settings", "Cartouche’s settings, the names and covers you gave your games, the guide’s progress, and the reports on problems.") }

    static var resetStaysHeader: String { s("reset.stays.header", "Kept") }
    static var resetStaysSigning: String { s("reset.stays.signing", "The certificate Cartouche is signed with, and the pairing file: you need no computer to set it up again.") }
    static var resetStaysStorage: String { s("reset.stays.storage", "What your storage holds, the copies of your games and saves, even in a folder of Cartouche’s own space in Files: add your storage again to find them.") }
    static var resetStaysTelemetry: String { s("reset.stays.telemetry", "Game measurements: their random number, their switch and the reports not sent yet.") }
    static var resetStaysSystem: String { s("reset.stays.system", "What iOS keeps: the days left on Cartouche’s signature, its permissions, and LocalDevVPN.") }

    static var resetSavesHeader: String { s("reset.saves.header", "Saves") }
    static var resetSavesChecking: String { s("reset.saves.checking", "Looking for saves that are not in your saves folder…") }
    static var resetSavesSafe: String { s("reset.saves.safe", "Your games’ saves are in your saves folder: add it again in Storage, and they come back with the games.") }
    static var resetSavesNone: String { s("reset.saves.none", "No game has saves to lose.") }
    static func resetSavesAtRisk(_ games: String) -> String { f("reset.saves.atRisk", "The saves of %@ are not in your saves folder: the reset erases them.", games) }
    static var resetSavesSend: String { s("reset.saves.send", "Send them to the saves folder now") }
    static var resetSavesSending: String { s("reset.saves.sending", "Sending the saves…") }
    static var resetSavesNoFolder: String { s("reset.saves.noFolder", "To keep them, choose a saves folder in Storage first.") }

    static var resetErase: String { s("reset.erase", "Erase everything and restart") }
    static var resetConfirmTitle: String { s("reset.confirm.title", "Erase everything?") }
    static var resetConfirmMessage: String { s("reset.confirm.message", "Your games and their saves here, your settings and your storage are erased, then Cartouche starts again. This cannot be undone.") }
    static var resetConfirmMessageAccount: String { s("reset.confirm.message.account", "Your games and their saves here, your settings, your storage and your Apple ID are erased, then Cartouche starts again. This cannot be undone.") }
    static var resetConfirmErase: String { s("reset.confirm.erase", "Erase everything") }

    static func resetWhilePlaying(_ game: String) -> String { f("reset.whilePlaying", "%@ is running: quit it before resetting Cartouche.", game) }
    static func resetBusy(_ work: String) -> String { f("reset.busy", "%@: wait for it to end before resetting Cartouche.", work) }
    static var resetWait: String { s("reset.wait", "Cartouche is busy: wait for it to finish before resetting it.") }

    static var resetErasing: String { s("reset.erasing", "Erasing…") }
    static var resetRestarting: String { s("reset.restarting", "Restarting…") }
    static var resetFailed: String { s("reset.failed", "Cartouche could not erase everything") }
    static func resetFailedMessage(_ count: Int) -> String { f("reset.failed.message", "Items left: %lld. Copy the report, then try again, or restart Cartouche as it is.", count) }
    static var resetRestart: String { s("reset.restart", "Restart Cartouche") }
}
