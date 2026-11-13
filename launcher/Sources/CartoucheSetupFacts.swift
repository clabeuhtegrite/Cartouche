//
//  CartoucheSetupFacts.swift
//  CartoucheCore
//
//  What Cartouche's measurements say of its installation when it starts
//  (app.opened, telemetry/README.md), and where the sign-in with the
//  player's Apple ID stands, apart from the setup that reads them
//  (CartoucheSetup.swift), so that they can be tested.
//

import Foundation

/// The parts of the installation, as the measurements send them: whether
/// LiveContainer's certificate works, whether the pairing file is in place,
/// whether the built-in SideStore has an Apple ID, never which.
struct CartoucheSetupFacts: Equatable {
    var hasCertificate: Bool
    /// Whether the certificate works: nil while Cartouche checks it, which
    /// ends a few seconds after the launch.
    var certificateWorks: Bool?
    var hasPairingFile: Bool
    var signedIn: Bool

    /// Whether the check of the certificate has ended, or there is none to
    /// check. Before it, no installation is ready yet: up to 0.11.2,
    /// Cartouche often measured it then.
    static func isChecked(hasCertificate: Bool, certificateWorks: Bool?) -> Bool {
        !hasCertificate || certificateWorks != nil
    }

    var isChecked: Bool { Self.isChecked(hasCertificate: hasCertificate, certificateWorks: certificateWorks) }

    /// Where the certificate stands: "none", "checking", "works" or
    /// "refused".
    var certificate: String {
        guard hasCertificate else { return "none" }
        switch certificateWorks {
        case nil: return "checking"
        case true?: return "works"
        case false?: return "refused"
        }
    }

    /// The fields app.opened sends of them.
    var fields: [String: CartoucheTelemetryValue] {
        ["certificate": .text(certificate), "pairing": .flag(hasPairingFile), "signedIn": .flag(signedIn)]
    }

    /// Where the sign-in stands: an Apple ID without a certificate is a
    /// sign-in that stopped before it.
    var signInStep: CartoucheSignInStep {
        guard signedIn else { return .notSignedIn }
        return hasCertificate ? .done : .unfinished
    }
}

/// Where the sign-in with the player's Apple ID stands, as the setup, the
/// guide and the banners show it.
enum CartoucheSignInStep: Equatable, Sendable {
    /// The built-in SideStore keeps no Apple ID.
    case notSignedIn
    /// SideStore keeps the Apple ID, and LiveContainer has no certificate:
    /// the sign-in stopped once Apple had accepted the account, before
    /// SideStore took the certificate, at the team's step or the
    /// certificate's. SideStore keeps the Apple ID and its password in its
    /// keychain, which an install of Cartouche over this copy, or after
    /// deleting it, leaves in place: only signing in again brings the
    /// certificate. Up to 0.11.2, the setup showed it as signed in.
    case unfinished
    /// Signed in, and LiveContainer has the certificate, whether iOS still
    /// accepts it or not (the certificate's own step).
    case done
}

/// The last sign-in Cartouche started, by the player or by itself, kept
/// across launches: in which installation of Cartouche, and when.
struct CartoucheLastSignIn: Codable, Equatable, Sendable {
    /// The installation it started in (installation(of:)).
    var installation: String
    var started: Date

    /// An installation of Cartouche, from where its BUNDLE is: iOS puts each
    /// install in a folder of its own, over a copy or after deleting it, and
    /// keeps it there until the next one.
    static func installation(of bundle: URL) -> String {
        bundle.standardizedFileURL.deletingLastPathComponent().lastPathComponent
    }

    /// Whether Cartouche signs in again by itself, in INSTALLATION, after
    /// LAST, while the sign-in stands at STEP: once per installation, when
    /// the last sign-in stopped before the certificate in an earlier one,
    /// as when the player installed Cartouche again, as they were told to,
    /// and had no sign-in of their own to make then. With the pairing file
    /// and LocalDevVPN connected only, which the sign-in needs: Cartouche
    /// tries again each time it comes back to the front until then. Once
    /// tried, the player signs in again from the setup, which says why the
    /// last one stopped.
    static func signsInAgain(after last: CartoucheLastSignIn?, at step: CartoucheSignInStep, installation: String,
                             hasPairingFile: Bool, vpnConnected: Bool) -> Bool {
        step == .unfinished && hasPairingFile && vpnConnected && last?.installation != installation
    }

    /// The report on why the sign-in stopped, among REPORTS, the newest
    /// first, as Cartouche keeps them: the newest on a sign-in, unless LAST
    /// started after it, which ended without one.
    static func report(after last: CartoucheLastSignIn?, among reports: [CartoucheReport]) -> CartoucheReport? {
        guard let report = reports.first(where: { $0.origin == .signIn }) else { return nil }
        if let last, report.date < last.started { return nil }
        return report
    }
}
