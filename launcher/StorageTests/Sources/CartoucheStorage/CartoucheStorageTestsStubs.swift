//
//  CartoucheStorageTestsStubs.swift
//  CartoucheStorageTests
//
//  What the launcher's storage files need from the rest of the launcher,
//  which this package does not build: the class whose bundle holds the
//  launcher's words (CartoucheText.bundle), and the journal the storage
//  notes its steps in (CartoucheReports.note), here the test's output.
//  Without Cartouche.xcstrings here, every text is the English the code
//  carries.
//

final class CartoucheCatalog {}

@MainActor
enum CartoucheReports {
    static func note(_ text: String) {
        print("[journal] " + text)
    }
}
