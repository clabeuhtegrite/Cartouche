//
//  CartoucheSetupFacts.swift
//  CartoucheCore
//
//  What Cartouche's measurements say of its installation when it starts
//  (app.opened, telemetry/README.md), apart from the setup that reads it
//  (CartoucheSetup.swift), so that it can be tested.
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
}
