//
//  IPhoneBuilds.swift
//  Cartouche Builder
//
//  The builds Cartouche shows on a paired iPhone, on each game's sheet,
//  and the build it asks for there, as the game's Build button here does
//  (BridgeServer's BridgeBuildsSource): the library, the games building and
//  those waiting their turn, as the window shows them (BridgeBuilds.swift).
//

import BuilderKit
import CartoucheCore
import Foundation

extension BridgeController: BridgeBuildsSource {
    func bridgeBuilds() -> CartoucheBridgeBuilds {
        guard let model else { return CartoucheBridgeBuilds(ready: false, why: IPhoneBuilds.starting) }
        let running = model.status?.running == true
        return BridgeBuilds.shared(games: model.library?.games ?? [], building: running ? model.status?.current ?? [] : [],
                                   waiting: model.waiting, running: model.isBuilding, ready: model.canBuild,
                                   why: IPhoneBuilds.why(model), stage: stageText)
    }

    func bridgeBuild(_ titleID: String) throws {
        guard let model else { throw CartoucheBridgeError(.failed, IPhoneBuilds.starting) }
        guard let game = model.library?.game(titleID) else { throw CartoucheBridgeError(.notFound, titleID) }
        guard game.canBuild else { throw CartoucheBridgeError(.failed, IPhoneBuilds.ipaOnly) }
        guard model.canBuild else { throw CartoucheBridgeError(.failed, IPhoneBuilds.why(model)) }
        // Building, or waiting its turn already: nothing more to ask.
        guard model.progress(titleID) == nil else { return }
        // As its Build button: built again even up to date, unless due; due
        // for its app for this Mac alone, its IPA is built again too.
        model.build([titleID], force: game.state != .due || BridgeBuilds.dueForMacAppAlone(game))
    }
}

/// What the Mac answers a paired iPhone when it takes no build.
enum IPhoneBuilds {
    static var starting: String {
        tr("Cartouche Builder is starting on the Mac: try again in a moment.",
           "Cartouche Builder démarre sur le Mac : réessayez dans un instant.")
    }

    static var ipaOnly: String {
        tr("Only its IPA is on the Mac: put its dump in the sources folder to build it again.",
           "Seule son IPA est sur le Mac : mettez son dump dans le dossier des sources pour le reconstruire.")
    }

    /// Why the Mac takes no build now: an IPA being imported, or its tools
    /// not ready.
    @MainActor
    static func why(_ model: AppModel) -> String {
        if model.bundling {
            return tr("The Mac is importing an IPA: try again once it is done.",
                      "Le Mac importe une IPA : réessayez une fois l’import fini.")
        }
        return tr("The Mac’s tools are not ready: open Cartouche Builder on the Mac to finish installing them.",
                  "Les outils du Mac ne sont pas prêts : ouvrez Cartouche Builder sur le Mac pour finir de les installer.")
    }
}
