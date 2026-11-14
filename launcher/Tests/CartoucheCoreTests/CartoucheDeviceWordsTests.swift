//
//  CartoucheDeviceWordsTests.swift
//  CartoucheCoreTests
//
//  The launcher's words on an iPad (Sources/CartoucheDeviceWords.swift):
//  the device Cartouche runs on is the iPad, any other iPhone stays.
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheDeviceWordsTests: XCTestCase {
    private func onIPad(_ text: String) -> String {
        CartoucheDeviceWords.onIPad(text)
    }

    /// The gallery's 13-inch iPad showed "On this iPhone" over the player's
    /// games, "This iPhone has what it needs" on a game's sheet, and "This
    /// iPhone" over the System page's first section.
    func testTheDeviceCartoucheRunsOnIsTheIPad() {
        XCTAssertEqual(onIPad("On this iPhone"), "On this iPad")
        XCTAssertEqual(onIPad("This iPhone has what it needs"), "This iPad has what it needs")
        XCTAssertEqual(onIPad("This iPhone: iOS %@"), "This iPad: iOS %@")
        XCTAssertEqual(onIPad("Never your Apple ID, your iPhone’s name, your files"),
                       "Never your Apple ID, your iPad’s name, your files")
        XCTAssertEqual(onIPad("To play on the iPhone, unplug the TV."), "To play on the iPad, unplug the TV.")
        XCTAssertEqual(onIPad("iPhone language"), "iPad language")
        XCTAssertEqual(onIPad("Starts in %@, the iPhone’s language."), "Starts in %@, the iPad’s language.")

        XCTAssertEqual(onIPad("Sur cet iPhone\u{00A0}: %@"), "Sur cet iPad\u{00A0}: %@")
        XCTAssertEqual(onIPad("Cet iPhone a tout ce qu’il faut"), "Cet iPad a tout ce qu’il faut")
        XCTAssertEqual(onIPad("le nom de votre iPhone"), "le nom de votre iPad")
        XCTAssertEqual(onIPad("Langue de l’iPhone"), "Langue de l’iPad")
        XCTAssertEqual(onIPad("Les testeurs n’ont pas pu le lancer sur ce modèle d’iPhone."),
                       "Les testeurs n’ont pas pu le lancer sur ce modèle d’iPad.")
        XCTAssertEqual(onIPad("Ce modèle d’iPhone"), "Ce modèle d’iPad")
    }

    func testAnyOtherIPhoneStays() {
        for text in [
            "nxnative’s games need an iPhone 15 Pro or later, or an iPad with an M1 chip or later",
            "iPhone Duo screen (1.43:1)", "Écran de l’iPhone Duo (1,43:1)",
            "Avec la mémoire augmentée, un iPhone de 12\u{00A0}Go accorde environ 8\u{00A0}Gio à Cartouche.",
            "which your other iPhones take too", "que vos autres iPhone prennent aussi",
            "On iPhone", "Sur iPhone", "nxnative plays it on the iPhone and the Mac.",
            "nobody has reported it on an iPhone yet", "sur quel iPhone",
        ] {
            XCTAssertEqual(onIPad(text), text)
        }
    }

    /// The setting of Cartouche Builder keeps the name the Mac shows.
    func testCartoucheBuildersSettingKeepsItsName() {
        XCTAssertEqual(
            onIPad("On your Mac, open Cartouche Builder and turn on Share with Cartouche on the iPhone, on its iPhone page. This iPhone and the Mac must be on the same Wi-Fi."),
            "On your Mac, open Cartouche Builder and turn on Share with Cartouche on the iPhone, on its iPhone page. This iPad and the Mac must be on the same Wi-Fi.")
        XCTAssertEqual(
            onIPad("Ouvrez-y Cartouche Builder avec Partager avec Cartouche sur l’iPhone activé\u{00A0}: Cartouche réessaie dès que l’iPhone retrouve son Wi-Fi."),
            "Ouvrez-y Cartouche Builder avec Partager avec Cartouche sur l’iPhone activé\u{00A0}: Cartouche réessaie dès que l’iPad retrouve son Wi-Fi.")
    }

    /// Every text of Cartouche.xcstrings, in English and in French, as an
    /// iPad shows it: none calls the iPad an iPhone, and those that still
    /// say iPhone are these, of another iPhone. A new text that says iPhone
    /// another way joins them, or is worded so that the iPad calls itself
    /// the iPad.
    func testEveryTextOfCartoucheOnAnIPad() throws {
        let keeps: Set<String> = [
            "reason.gpu", "saves.putBack.footer", "setting.option.duoScreen", "status.iphone.long",
            "status.iphone.short", "status.mac.long", "storage.mac.busy", "storage.mac.how",
            "storage.mac.offline", "storage.saves.footer", "switchSave.import.sending", "system.memory.footer",
            "system.memory.footer.behind", "telemetry.footer",
        ]
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Cartouche.xcstrings").standardizedFileURL
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: Any])
        XCTAssertGreaterThan(strings.count, 500)

        var stillIPhone: [String: Set<String>] = [:]
        var turned = 0
        for (key, entry) in strings {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for (language, localization) in localizations {
                let unit = (localization as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let text = unit?["value"] as? String else { continue }
                let shown = onIPad(text)
                if shown != text { turned += 1 }
                for device in ["this iPhone", "This iPhone", "your iPhone", "Your iPhone",
                               "cet iPhone", "Cet iPhone", "votre iPhone", "Votre iPhone"] {
                    XCTAssertFalse(shown.contains(device), "\(key) (\(language)) on an iPad: \(shown)")
                }
                if shown.contains("iPhone") { stillIPhone[key, default: []].insert(language) }
            }
        }
        XCTAssertEqual(Set(stillIPhone.keys), keeps, "texts that still say iPhone on an iPad")
        for (key, languages) in stillIPhone {
            XCTAssertEqual(languages, ["en", "fr"], "\(key) says iPhone on an iPad in one language only")
        }
        XCTAssertGreaterThan(turned, 150, "the texts an iPad turns, in English and in French")
    }
}
