//
//  CartoucheLocalDevVPN.swift
//  Cartouche
//
//  Cartouche has LocalDevVPN connect by itself when what reaches this
//  iPhone through it starts with LocalDevVPN off (CartoucheVPNConnect):
//  the sign-in, the registration of this iPhone, Renew now and an update,
//  as the player asks for them; and, by itself, the renewal in the last
//  days of the signature (CartoucheRenewals) and the sign-in again for a
//  certificate iOS no longer accepts (CartoucheAccount). LocalDevVPN's own
//  URL connects it and opens Cartouche again a second later, by Cartouche's
//  URL scheme: the player sees LocalDevVPN for a moment, and Cartouche goes
//  on as soon as the tunnel is up. Up to 0.12.1, the player connected
//  LocalDevVPN in its app before each of them, and came back. The first
//  time, iOS asks the player, in LocalDevVPN, to allow its VPN
//  configuration, as the guide's first step has them do.
//
//  Cartouche goes on after CartoucheVPNConnect.timeout at most, connected
//  or not, as up to 0.12.1: a LocalDevVPN set to other addresses than its
//  own carries SideStore's traffic all the same, and SideStore says why
//  when it cannot reach this iPhone.
//

import Foundation
import UIKit

@available(iOS 17.0, *)
@MainActor
final class CartoucheLocalDevVPN {
    static let shared = CartoucheLocalDevVPN()

    static let url = URL(string: "localdevvpn://")!
    static let appStore = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    /// When Cartouche last opened LocalDevVPN by itself, without the player
    /// asking, kept across launches.
    static let lastAutomaticOpenKey = "Cartouche.localDevVPN.lastAutomaticOpen"

    /// How a wait for LocalDevVPN went.
    struct Connection: Equatable {
        /// Whether LocalDevVPN was connected once the wait ended.
        var connected: Bool
        /// Whether Cartouche opened LocalDevVPN for it.
        var opened: Bool
        /// How long Cartouche waited for it in front, in whole seconds.
        var seconds: Double

        static let connectedAlready = Connection(connected: true, opened: false, seconds: 0)
    }

    /// How long Cartouche waits for the tunnel in front, once it has opened
    /// LocalDevVPN: CartoucheVPNConnect.timeout, shorter in a test of the
    /// launcher's harness.
    var waitLimit = CartoucheVPNConnect.timeout

    private init() {}

    /// Whether LocalDevVPN is connected: always, in the simulator, which has
    /// none, and where SideStore does not go through it; as a test of the
    /// launcher's harness says.
    static var isConnected: Bool {
        #if CARTOUCHE_HARNESS
        return HarnessLC.vpnConnected
        #elseif targetEnvironment(simulator)
        return true
        #else
        return CartoucheVPN.isConnected
        #endif
    }

    /// Whether LocalDevVPN is on this iPhone: Cartouche lists its scheme
    /// among those it may ask about (app/scripts/package.sh).
    var isInstalled: Bool {
        #if CARTOUCHE_HARNESS
        return HarnessLC.localDevVPNInstalled
        #else
        return UIApplication.shared.canOpenURL(Self.url)
        #endif
    }

    /// Whether Cartouche is in front.
    private var isInFront: Bool {
        #if CARTOUCHE_HARNESS
        return HarnessLC.cartoucheInFront
        #else
        return UIApplication.shared.applicationState == .active
        #endif
    }

    /// What Cartouche finds, for what the player asked for, with a tap, or
    /// what Cartouche starts by itself.
    func situation(playerAsked: Bool) -> CartoucheVPNConnect.Situation {
        CartoucheVPNConnect.Situation(
            connected: Self.isConnected,
            installed: isInstalled,
            inFront: isInFront,
            playerAsked: playerAsked,
            gameRunning: CartoucheGameActions.shared.running != nil,
            lastAutomaticOpen: UserDefaults.standard.object(forKey: Self.lastAutomaticOpenKey) as? Date)
    }

    /// What Cartouche would do now about LocalDevVPN.
    func decide(playerAsked: Bool) -> CartoucheVPNConnect.Decision {
        CartoucheVPNConnect.decide(situation(playerAsked: playerAsked), at: Date())
    }

    /// Opens LocalDevVPN, which connects and opens Cartouche again, for
    /// WHAT, which the journal names, when CartoucheVPNConnect says so.
    /// Returns whether it opened it.
    @discardableResult
    func open(for what: String, playerAsked: Bool) -> Bool {
        guard decide(playerAsked: playerAsked) == .open,
              let url = CartoucheVPNConnect.enableURL(returningTo: Self.ownScheme) else { return false }
        if !playerAsked {
            UserDefaults.standard.set(Date(), forKey: Self.lastAutomaticOpenKey)
        }
        CartoucheReports.note(what + (playerAsked ? ": opening LocalDevVPN" : ": opening LocalDevVPN, by itself"))
        Self.openURL(url)
        return true
    }

    /// Has LocalDevVPN connect for WHAT, before it goes on: at once when it
    /// is connected; otherwise opens it, when it can, and waits for its
    /// tunnel, `waitLimit` at most while Cartouche is in front.
    func connect(for what: String, playerAsked: Bool) async -> Connection {
        if Self.isConnected { return .connectedAlready }
        guard open(for: what, playerAsked: playerAsked) else {
            return Connection(connected: false, opened: false, seconds: 0)
        }
        var wait = CartoucheVPNConnect.Wait(started: Date(), limit: waitLimit)
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            switch wait.next(connected: Self.isConnected, inFront: isInFront, at: Date()) {
            case .goOn:
                CartoucheReports.note(what + ": LocalDevVPN connected")
                return Connection(connected: true, opened: true, seconds: wait.seconds)
            case .stop:
                CartoucheReports.note(what + ": LocalDevVPN did not connect in time, going on")
                return Connection(connected: false, opened: true, seconds: wait.seconds)
            case .keepWaiting:
                continue
            }
        }
    }

    /// Connects LocalDevVPN as the player asks, from a button of the guide
    /// or of the sign-in; opens its page of the App Store when it is not on
    /// this iPhone.
    func connectForPlayer() {
        guard isInstalled else {
            Self.openURL(Self.appStore)
            return
        }
        open(for: "Connect LocalDevVPN", playerAsked: true)
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

    private static func openURL(_ url: URL) {
        #if CARTOUCHE_HARNESS
        HarnessLC.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
