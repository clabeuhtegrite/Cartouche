//
//  IPhoneBuilds.swift
//  Cartouche Builder
//
//  The builds Cartouche shows on a paired iPhone, on each game's sheet and
//  on its page of the Mac's builds (System), and what it asks of them
//  there, as this window's buttons do (BridgeServer's BridgeBuildsSource):
//  the library, the games building and those waiting their turn, as the
//  window shows them (BridgeBuilds.swift); a game built, Build what is due,
//  Stop, Remove from the queue, Stop all, Follow, and the nightly build.
//

import BuilderKit
import CartoucheCore
import Foundation

extension BridgeController: BridgeBuildsSource {
    func bridgeBuilds() -> CartoucheBridgeBuilds {
        guard let model else { return CartoucheBridgeBuilds(ready: false, why: IPhoneBuilds.starting) }
        let running = model.status?.running == true
        let nightly = model.config.map { CartoucheBridgeBuilds.Nightly(on: $0.schedule, hour: $0.scheduleHour, minute: $0.scheduleMinute) }
        let control = BridgeBuilds.Control(stoppable: { IPhoneBuilds.stoppable($0, model) }, stopping: { model.stopping($0) },
                                           due: model.dueOutsideBatch.count, nightly: nightly)
        return BridgeBuilds.shared(games: model.library?.games ?? [], building: running ? model.status?.current ?? [] : [],
                                   waiting: model.waiting, running: model.isBuilding, ready: model.canBuild,
                                   why: IPhoneBuilds.why(model), stage: stageText, control: control)
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

    func bridgeBuildDue() throws {
        guard let model else { throw CartoucheBridgeError(.failed, IPhoneBuilds.starting) }
        guard model.canBuild else { throw CartoucheBridgeError(.failed, IPhoneBuilds.why(model)) }
        // Nothing due that the batch does not have: nothing to ask.
        guard !model.dueOutsideBatch.isEmpty else { return }
        // As Build what is due, or Add what is due while a batch runs.
        model.build()
    }

    func bridgeStop(_ titleID: String?) throws {
        guard let model else { throw CartoucheBridgeError(.failed, IPhoneBuilds.starting) }
        guard let titleID else {
            // As Stop all: the game building, and every game waiting.
            model.stop()
            return
        }
        // Neither building nor waiting any more, or stopping already:
        // nothing more to ask.
        guard let progress = model.progress(titleID), !model.stopping(titleID) else { return }
        guard IPhoneBuilds.stoppable(titleID, model) else {
            throw CartoucheBridgeError(.failed, IPhoneBuilds.notAlone)
        }
        if progress.state == "building" {
            // As Stop on its sheet: the batch goes on with the next game.
            model.stopBuild(titleID)
        } else {
            // As Remove from the queue.
            model.takeOut(titleID)
        }
    }

    func bridgeFollow(_ titleID: String, _ followed: Bool) async throws {
        guard let model, let engine = model.engine else { throw CartoucheBridgeError(.failed, IPhoneBuilds.starting) }
        guard let game = model.library?.game(titleID) else { throw CartoucheBridgeError(.notFound, titleID) }
        guard game.canBuild else { throw CartoucheBridgeError(.failed, IPhoneBuilds.ipaOnly) }
        guard game.followed != followed else { return }
        // As Follow on its sheet, and the library read again before the
        // iPhone is answered: it shows the game as the Mac has it now.
        do {
            try await engine.follow(titleID, followed)
        } catch {
            throw CartoucheBridgeError(.failed, error.localizedDescription)
        }
        await model.loadConfig()
        await model.refreshLibrary(update: false)
    }

    func bridgeNightly(_ nightly: CartoucheBridgeBuilds.Nightly) throws {
        guard let model, model.config != nil else { throw CartoucheBridgeError(.failed, IPhoneBuilds.starting) }
        // As Build what is due every night and its time in the settings.
        model.update {
            $0.schedule = nightly.on
            $0.scheduleHour = nightly.hour
            $0.scheduleMinute = nightly.minute
        }
    }
}

/// What the Mac answers a paired iPhone when it takes no build: "the app",
/// never its name, which changes.
enum IPhoneBuilds {
    static var starting: String {
        tr("The app is starting on the Mac: try again in a moment.",
           "L’app démarre sur le Mac : réessayez dans un instant.")
    }

    static var ipaOnly: String {
        tr("Only its IPA is on the Mac: put its dump in the sources folder to build it again.",
           "Seule son IPA est sur le Mac : mettez son dump dans le dossier des sources pour le reconstruire.")
    }

    static var notAlone: String {
        tr("The Mac cannot take this game out of the queue yet: try again in a moment, or stop every game.",
           "Le Mac ne peut pas encore retirer ce jeu de la file : réessayez dans un instant, ou arrêtez tous les jeux.")
    }

    /// Whether the iPhone can stop the build of TITLE_ID, the batch going on
    /// with the next game, or take it out of the queue, as this window's
    /// Stop and Remove from the queue: building, unless it is stopping;
    /// waiting, once the batch runs.
    @MainActor
    static func stoppable(_ titleID: String, _ model: AppModel) -> Bool {
        guard let progress = model.progress(titleID) else { return false }
        return progress.state == "building" ? !model.stopping(titleID) : model.canTakeOut(titleID)
    }

    /// Why the Mac takes no build now: an IPA being imported, or its tools
    /// not ready.
    @MainActor
    static func why(_ model: AppModel) -> String {
        if model.bundling {
            return tr("The Mac is importing an IPA: try again once it is done.",
                      "Le Mac importe une IPA : réessayez une fois l’import fini.")
        }
        return tr("The Mac’s tools are not ready: open the app on the Mac to finish installing them.",
                  "Les outils du Mac ne sont pas prêts : ouvrez l’app sur le Mac pour finir de les installer.")
    }
}
