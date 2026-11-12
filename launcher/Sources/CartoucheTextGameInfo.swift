//
//  CartoucheTextGameInfo.swift
//  Cartouche
//
//  The words of what the player says of one of their games, and of what
//  IGDB has of a game Cartouche does not know (CartoucheGameInfoView.swift,
//  CartoucheGameLookup.swift), in Cartouche.xcstrings with the others
//  (CartoucheText.swift).
//

import Foundation

extension CartoucheText {
    // MARK: A game's info

    static var gameInfoEdit: String { s("gameInfo.edit", "Edit the game’s info") }
    static var gameInfoTitle: String { s("gameInfo.title", "Game info") }
    static func gameInfoFound(_ name: String) -> String { f("gameInfo.found", "Found on IGDB by its name: %@.", name) }
    static var gameInfoNotFound: String { s("gameInfo.notFound", "Nothing found on IGDB by this name yet: give the game its exact name, or choose its cover.") }
    static var gameInfoCoverPhotos: String { s("gameInfo.cover.photos", "Choose from Photos") }
    static var gameInfoCoverFile: String { s("gameInfo.cover.file", "Choose a file") }
    static var gameInfoCoverOfficial: String { s("gameInfo.cover.official", "Back to the official cover") }
    static var gameInfoCoverRemove: String { s("gameInfo.cover.remove", "Remove my cover") }
    static var gameInfoCoverUnreadable: String { s("gameInfo.cover.unreadable", "Cartouche cannot read this image.") }
    static var gameInfoName: String { s("gameInfo.name", "Name") }
    static var gameInfoPlatform: String { s("gameInfo.platform", "Platform") }
    static var gameInfoGenre: String { s("gameInfo.genre", "Genre") }
    /// What Cartouche finds by itself, VALUE when it finds something.
    static func gameInfoAutomatic(_ value: String?) -> String {
        guard let value else { return s("gameInfo.automatic", "Automatic") }
        return f("gameInfo.automatic.value", "Automatic (%@)", value)
    }
    static var gameInfoFooter: String { s("gameInfo.footer", "What you change here stays on this iPhone.") }
    static var gameInfoReset: String { s("gameInfo.reset", "Back to Cartouche’s info") }
    static var gameInfoSave: String { s("gameInfo.save", "Save") }
    static func gameInfoNotSaved(_ reason: String) -> String { f("gameInfo.notSaved", "Cartouche cannot keep these changes: %@", reason) }
}
