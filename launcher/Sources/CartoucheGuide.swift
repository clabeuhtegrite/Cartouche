//
//  CartoucheGuide.swift
//  Cartouche
//
//  The way from a new install to the first game, for a player who has
//  never used Cartouche (CartoucheGuideView): LocalDevVPN, the Apple ID,
//  the game built on a Mac with Cartouche Builder, the games folder, then
//  the game installed. Each step ticks itself from what Cartouche sees, in
//  any order. The Mac's step is the player's to take: No thanks skips it,
//  for a player whose games are built already or who has no Mac, and the
//  guide goes on without it. The guide opens by itself once, the first
//  time the console shows before the player has signed in, and stays a
//  card at the top of the home until the first game is installed, unless
//  the player takes the card off the home; from then on it shows there no
//  more, whatever happens later, and the setup banner takes its place. The
//  System page opens it at any time.
//

import SwiftUI
import UIKit

@available(iOS 17.0, *)
@MainActor
final class CartoucheGuide: ObservableObject {
    static let shared = CartoucheGuide()

    enum Step: Int, CaseIterable, Identifiable {
        case vpn, account, build, folder, play

        var id: Int { rawValue }
        var number: Int { rawValue + 1 }
    }

    /// What the steps read: the setup, the player's games folder and games.
    struct Progress: Equatable {
        var vpnConnected = false
        var hasPairingFile = false
        var signedIn = false
        /// LiveContainer has the certificate, and iOS has not refused it.
        var canPlay = false
        /// A game installed, or one in the games folder.
        var hasGame = false
        var hasGamesFolder = false
        var hasInstalledGame = false
        /// The player said No thanks to building their game on a Mac.
        var buildSkipped = false
        var requiresAccount = true

        func isDone(_ step: Step) -> Bool {
            switch step {
            // Once signed in, the VPN was on when it counted.
            case .vpn: return vpnConnected || signedIn
            case .account: return signedIn && canPlay
            case .build: return hasGame
            // A game imported from Files needs no games folder.
            case .folder: return hasGamesFolder || hasInstalledGame
            case .play: return hasInstalledGame
            }
        }

        /// A step the player passed over without doing it: the Mac's, after
        /// No thanks, until a game of theirs shows anyway.
        func isSkipped(_ step: Step) -> Bool {
            (!requiresAccount && (step == .vpn || step == .account))
                || (step == .build && buildSkipped && !isDone(step))
        }

        /// The first step left, nil once every step is done or skipped.
        var current: Step? { Step.allCases.first { !isDone($0) && !isSkipped($0) } }
        var isFinished: Bool { current == nil }
    }

    @Published private(set) var vpnConnected = CartoucheVPN.isConnected
    /// Whether the player has had a game installed once: the home shows the
    /// guide no more.
    @Published private(set) var isFinishedOnce: Bool
    /// Whether the player said No thanks to the Mac's step.
    @Published private(set) var buildSkipped: Bool
    /// Whether the player took the guide's card off the home.
    @Published private(set) var isCardHidden: Bool
    /// The System page asked for the guide, which opens over the console
    /// once the page has gone (CartoucheGamesView).
    @Published private(set) var isOpenRequested = false

    private let defaults: UserDefaults
    private static let openedKey = "Cartouche.guide.opened"
    private static let finishedKey = "Cartouche.guide.finished"
    private static let buildSkippedKey = "Cartouche.guide.buildSkipped"
    private static let cardHiddenKey = "Cartouche.guide.cardHidden"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isFinishedOnce = defaults.bool(forKey: Self.finishedKey)
        buildSkipped = defaults.bool(forKey: Self.buildSkippedKey)
        isCardHidden = defaults.bool(forKey: Self.cardHiddenKey)
    }

    /// Reads again whether LocalDevVPN is connected.
    func refreshVPN() {
        let connected = CartoucheVPN.isConnected
        if connected != vpnConnected { vpnConnected = connected }
    }

    /// Where the player stands, with these games.
    func progress(_ entries: CartoucheCatalog.Entries) -> Progress {
        let setup = CartoucheSetup.shared
        return Progress(
            vpnConnected: vpnConnected,
            hasPairingFile: setup.hasPairingFile,
            signedIn: setup.appleID != nil,
            canPlay: setup.canPlay,
            hasGame: !entries.owned.isEmpty,
            hasGamesFolder: CartoucheStorageSettings.shared.location(.games) != nil
                || CartoucheStoredGames.shared.serverName != nil,
            hasInstalledGame: entries.owned.contains { $0.app != nil },
            buildSkipped: buildSkipped,
            requiresAccount: !setup.usesImportedSigning)
    }

    /// Whether the home shows the guide's card, in place of the setup banner:
    /// until the player's first game is installed, unless they took the
    /// card off the home.
    func showsCard(_ progress: Progress) -> Bool {
        !isFinishedOnce && !isCardHidden && !progress.hasInstalledGame
    }

    /// Whether the guide opens by itself: once, the first time the console
    /// shows to a player who has not signed in yet, which a new install is.
    func opensByItself(_ progress: Progress) -> Bool {
        !isFinishedOnce && !isCardHidden && !progress.signedIn && !progress.hasInstalledGame
            && !defaults.bool(forKey: Self.openedKey)
    }

    /// The guide has been on screen: it opens by itself no more.
    func noteOpened() {
        defaults.set(true, forKey: Self.openedKey)
    }

    /// No thanks to the Mac's step: the guide goes on to the games folder,
    /// and the home's card with it. The step stays in the guide, closed, for
    /// a player who wants it after all.
    func skipBuild() {
        guard !buildSkipped else { return }
        buildSkipped = true
        defaults.set(true, forKey: Self.buildSkippedKey)
    }

    /// Takes the guide's card off the home, for good: the System page still
    /// opens the guide, and the setup banner says what the setup lacks.
    func hideCard() {
        guard !isCardHidden else { return }
        isCardHidden = true
        defaults.set(true, forKey: Self.cardHiddenKey)
    }

    /// Opens the guide over the console, from the System page.
    func requestOpen() {
        isOpenRequested = true
    }

    /// The console has the request, and opens the guide.
    func noteOpenRequestTaken() {
        isOpenRequested = false
    }

    /// Keeps that the player has had their first game installed, once they
    /// have: from then on, the setup banner says what may be missing.
    func note(_ progress: Progress) {
        guard progress.hasInstalledGame, !isFinishedOnce else { return }
        isFinishedOnce = true
        defaults.set(true, forKey: Self.finishedKey)
    }

    #if CARTOUCHE_GALLERY
    /// A guide never opened nor finished, as on a new install, for each
    /// scenario of the launcher's gallery (launcher/Gallery): they run one
    /// after the other, and a scenario with a game installed finishes it.
    func startOverForGallery() {
        for key in [Self.openedKey, Self.finishedKey, Self.buildSkippedKey, Self.cardHiddenKey] {
            defaults.removeObject(forKey: key)
        }
        isFinishedOnce = false
        buildSkipped = false
        isCardHidden = false
    }
    #endif

    // MARK: Cartouche Builder

    /// What the Mac's step sends the Mac, by AirDrop or Messages: Cartouche
    /// Builder's part of Cartouche's site, in the language of the Mac's
    /// browser, with its disk image.
    static let builderPage = URL(string: "https://clabeuhtegrite.github.io/Cartouche/#builder")!

    // MARK: LocalDevVPN

    static let localDevVPN = URL(string: "localdevvpn://")!
    static let localDevVPNAppStore = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    /// Whether LocalDevVPN is on this iPhone: Cartouche lists its scheme
    /// among those it may ask about (app/scripts/package.sh).
    var hasLocalDevVPN: Bool {
        UIApplication.shared.canOpenURL(Self.localDevVPN)
    }

    /// Has LocalDevVPN connect, then open Cartouche again by Cartouche's own
    /// URL scheme, as SideStore's onboarding has it come back to SideStore;
    /// opens LocalDevVPN's page of the App Store when it is not installed.
    func connectVPN() {
        var components = URLComponents()
        components.scheme = "localdevvpn"
        components.host = "enable"
        components.queryItems = [URLQueryItem(name: "scheme", value: Self.ownScheme)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url) { opened in
            if !opened { UIApplication.shared.open(Self.localDevVPNAppStore) }
        }
    }

    /// The URL scheme that opens this Cartouche: LiveContainer's, which
    /// app/scripts/brand.py names after Cartouche, and numbers for a second
    /// copy of the app (+[NSUserDefaults lcAppUrlScheme]), read as the
    /// built-in SideStore's onboarding reads it (app/patches/sidestore/0007).
    static var ownScheme: String {
        let selector = NSSelectorFromString("lcAppUrlScheme")
        if UserDefaults.responds(to: selector),
           let own = UserDefaults.perform(selector)?.takeUnretainedValue() as? String, !own.isEmpty {
            return own
        }
        return "cartouche"
    }
}
