//
//  CartoucheRenewalRules.swift
//  CartoucheCore
//
//  When Cartouche renews itself, as it comes to the front in the last days
//  of its signature, and what renewed a signature that lasts longer than
//  it did, as the measurements send it, apart from the renewal itself
//  (CartoucheRenewal.swift), so that they can be tested.
//

import Foundation

/// Cartouche renews itself, without the player, each time it comes to the
/// front in the last days of its signature, with LocalDevVPN connected: up
/// to 0.12.0, only Renew now, on the System page, and an automation the
/// player made in Shortcuts renewed it, while the System page said that it
/// renewed itself. A renewal installs new provisioning profiles, and signs
/// nothing again: Cartouche keeps Increased Memory Limit, as the
/// measurements of the week of November 10 showed on every renewal.
enum CartoucheAutomaticRenewal {
    /// From how many days left: those from which the home's top bar shows
    /// them (CartoucheHomeView.expirySoonDays). A free Apple account's
    /// signature lasts seven days.
    static let days = 3
    /// How long Cartouche waits after it tried, whether the renewal went
    /// through or not, before it tries again: each renewal asks Apple's
    /// servers for the profiles, and one that failed, with Apple or with
    /// LocalDevVPN, fails the same way minutes later.
    static let spacing: TimeInterval = 6 * 3_600

    /// What Cartouche finds as it comes to the front.
    struct Situation: Equatable {
        /// Whole days left on the signature (CartoucheSignature.daysLeft),
        /// nil when Cartouche could not read it.
        var daysLeft: Int?
        /// Whether the built-in SideStore renews it, with the Apple ID: not
        /// with the player's own certificate (docs/imported-signing.md).
        var canRenew: Bool
        /// Whether the setup has nothing left: the certificate works, the
        /// pairing file is in place, SideStore is signed in and this iPhone
        /// is registered with the account.
        var isSetUp: Bool
        var vpnConnected: Bool
        /// Whether the built-in SideStore is at something else, which it
        /// takes one at a time: a renewal, an update of Cartouche, a sign-in
        /// or the registration of this iPhone, under way or waiting for
        /// LocalDevVPN.
        var sideStoreBusy: Bool
        /// Whether Apple's limit on sign-ins holds (CartoucheSignInPause): a
        /// renewal signs in again when Apple asks for it.
        var signInsPaused: Bool
        /// Whether a game runs behind the console: SideStore would start in
        /// a process of its own beside the game's, which iOS ends first.
        var gameRunning: Bool
        /// When Cartouche last renewed itself, or tried to.
        var lastTry: Date?
    }

    /// Why Cartouche does not renew itself now.
    enum Wait: String, Equatable {
        /// More days are left than `days`, or none could be read.
        case notDue
        /// The player's own certificate signs Cartouche, or the built-in
        /// SideStore is not there.
        case cannotRenew
        /// The setup has something left, which a renewal needs.
        case setup
        /// LocalDevVPN is not connected: Cartouche tries again each time it
        /// comes back, as when the player turned it on.
        case vpn
        case sideStoreBusy
        case signInsPaused
        case gameRunning
        /// Cartouche tried less than `spacing` ago.
        case triedLately
    }

    /// Why Cartouche does not renew itself, in SITUATION, at NOW: nil when
    /// it does. A last try dated after NOW, as when the iPhone's clock went
    /// back, holds nothing back.
    static func wait(_ situation: Situation, at now: Date) -> Wait? {
        guard let daysLeft = situation.daysLeft, daysLeft <= days else { return .notDue }
        guard situation.canRenew else { return .cannotRenew }
        guard situation.isSetUp else { return .setup }
        guard !situation.sideStoreBusy else { return .sideStoreBusy }
        guard !situation.gameRunning else { return .gameRunning }
        guard !situation.signInsPaused else { return .signInsPaused }
        if let lastTry = situation.lastTry, now >= lastTry, now.timeIntervalSince(lastTry) < spacing {
            return .triedLately
        }
        guard situation.vpnConnected else { return .vpn }
        return nil
    }

    /// Whether Cartouche renews itself now.
    static func isDue(_ situation: Situation, at now: Date) -> Bool {
        wait(situation, at: now) == nil
    }
}

/// What renewed the signature, when it lasts longer than it did, as
/// signature.renewed sends it (`via`): up to 0.12.0, the measurements could
/// not tell the automation of Shortcuts from Renew now, from an install of
/// the Cartouche Installer, or from an update.
enum CartoucheRenewalVia: String, Equatable {
    /// A new version of Cartouche, which its update signed again, from the
    /// built-in SideStore or from the Cartouche Installer.
    case update
    /// The same version installed again, by the Cartouche Installer or
    /// another signer: iOS put it in a folder of its own
    /// (CartoucheLastSignIn.installation(of:)).
    case reinstall
    /// Cartouche renewed itself: Renew now, or by itself as it came to the
    /// front (CartoucheAutomaticRenewal).
    case cartouche
    /// Something else renewed it, while Cartouche was closed or in the
    /// background: its Refresh All Apps action, as the automation of
    /// Shortcuts runs it every night.
    case outside

    /// What renewed the signature since Cartouche last read it: UPDATED, a
    /// new version; REINSTALLED, another installation of it, nil when
    /// Cartouche had not noted the one before; RENEWED HERE, Cartouche
    /// renewed itself meanwhile. Nil when it cannot tell.
    static func of(updated: Bool, reinstalled: Bool?, renewedHere: Bool) -> CartoucheRenewalVia? {
        if updated { return .update }
        if reinstalled == true { return .reinstall }
        if renewedHere { return .cartouche }
        return reinstalled == false ? .outside : nil
    }
}
