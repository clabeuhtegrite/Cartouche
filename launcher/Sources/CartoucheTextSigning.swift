import Foundation

extension CartoucheText {
    static var signingTitle: String { s("signing.title", "Import signing certificate") }
    static var signingHow: String { s("signing.how", "Choose your certificate (.p12), its password and its profile (.mobileprovision). Neither an Apple ID nor LocalDevVPN is needed.") }
    static var signingChooseCertificate: String { s("signing.chooseCertificate", "Choose the certificate (.p12)") }
    static var signingCertificateChosen: String { s("signing.certificateChosen", "Choose another certificate (.p12)") }
    static var signingChooseProfile: String { s("signing.chooseProfile", "Choose its profile (.mobileprovision)") }
    static var signingProfileChosen: String { s("signing.profileChosen", "Choose another profile (.mobileprovision)") }
    static var signingPassword: String { s("signing.password", "Certificate password") }
    static var signingUse: String { s("signing.use", "Use this certificate") }
    static var signingInvalidKey: String { s("signing.invalidKey", "This certificate does not open. Check its password, and that the .p12 holds its private key.") }
    static var signingInvalidProfile: String { s("signing.invalidProfile", "The provisioning profile is invalid, expired or does not match this certificate.") }
    static var signingReinstall: String { s("signing.reinstall", "If the profile Cartouche was installed with does not allow this certificate, install Cartouche again with it and its profile, from the Cartouche Installer.") }
    static var signingRefused: String { s("signing.refused", "iOS refused this certificate. Import another one, or install Cartouche again with a new certificate and its profile, from the Cartouche Installer.") }
    static var signingUpdateOnComputer: String { s("signing.updateOnComputer", "Cartouche is signed with your own certificate: install its updates, and a new certificate before it expires, from the Cartouche Installer on your computer. It needs no renewal each week.") }
    static var signingInvalidFile: String { s("signing.invalidFile", "Choose a signing file smaller than 4 MB.") }
    static var guideImportedIntro: String { s("guide.importedIntro", "Four steps from here to your first game. Each one ticks itself once it is done.") }
    static var signingWait: String { s("signing.wait", "Wait for the current sign-in or update to finish before changing certificates.") }
    static var signingHandoffFailed: String { s("signing.handoffFailed", "Cartouche could not open the certificate the installer gave it. Install Cartouche again with your certificate and its profile.") }

    // Signed on the iPhone, by a signing app, from the IPA for the player's
    // own certificate (docs/imported-signing.md).
    static var signingHowOnIPhone: String { s("signing.howOnIPhone", "Choose the certificate (.p12) your signing app signed Cartouche with, and type its password. Cartouche reads its profile by itself. Neither an Apple ID nor LocalDevVPN is needed.") }
    static var signingOtherCertificate: String { s("signing.otherCertificate", "Cartouche was signed with another certificate. Choose that one, or sign Cartouche again with this one in your signing app.") }
    static var signingOnlyOwnCertificate: String { s("signing.onlyOwnCertificate", "Cartouche takes only the certificate it was signed with. To change certificates, sign Cartouche again with the new one in your signing app, then choose it here.") }
    static var signingRefusedOnIPhone: String { s("signing.refusedOnIPhone", "iOS refused this certificate, which may have been revoked. Sign Cartouche again with a valid certificate in your signing app, then choose that certificate here.") }
    static var signingUpdateOnIPhone: String { s("signing.updateOnIPhone", "Cartouche is signed with your own certificate and needs no renewal each week. When a new version is out, Cartouche says so: download it, sign it in your signing app as the first time, then install it over this one. Your games and saves stay.") }
    static var setupIntroOwnCertificate: String { s("setup.intro.ownCertificate", "One step, once on this iPhone: the certificate Cartouche signs your games with.") }
    static var setupAllDoneOwnCertificate: String { s("setup.done.ownCertificate", "Cartouche signs your games with your own certificate. There is nothing more to do here.") }

    // What the signature gives Cartouche (CartoucheOwnSignature.swift).
    static var signatureCheckTitle: String { s("signature.check.title", "Your signature") }
    static var signatureMemoryLeftOut: String { s("signature.memory.leftOut", "Your signing app left out Increased Memory Limit, which your profile allows: without it, iOS gives Cartouche and its games about 3 GB. Sign Cartouche again, keeping every entitlement of the profile.") }
    static var signatureMemoryNotInProfile: String { s("signature.memory.notInProfile", "Your profile does not allow Increased Memory Limit: without it, iOS gives Cartouche and its games about 3 GB, too little for most games. Use a profile whose App ID has this capability, then sign Cartouche again.") }
    static var signatureKeychains: String { s("signature.keychains", "Games’ keychains") }
    static var signatureKeychainsGranted: String { s("signature.keychains.granted", "Each game keeps its own.") }
    static var signatureKeychainsLeftOut: String { s("signature.keychains.leftOut", "Your signing app did not sign in the games’ keychain groups, which your profile allows: the games share Cartouche’s keychain. Most games do not use it.") }
    static var signatureKeychainsNotInProfile: String { s("signature.keychains.notInProfile", "Your profile does not allow the games’ keychain groups: the games share Cartouche’s keychain. Most games do not use it.") }

    // Its updates, which Cartouche offers and does not install.
    static func updateOfferOnIPhone(_ running: String) -> String { f("updates.offer.onIPhone", "You have version %@. Download the new one, sign it in your signing app as the first time, then install it over this one: your games and saves stay.", running) }
    static func updateOfferOnComputer(_ running: String) -> String { f("updates.offer.onComputer", "You have version %@. Install the new one from the Cartouche Installer on your computer, with your certificate: your games and saves stay.", running) }
    static var updateDownload: String { s("updates.download", "Download") }
    static func updateDownloadVersion(_ version: String) -> String { f("system.updates.download", "Download Cartouche %@", version) }

    // The guide's step for the player's own certificate.
    static var guideCertificateTitle: String { s("guide.certificate.title", "Import your certificate") }
}
