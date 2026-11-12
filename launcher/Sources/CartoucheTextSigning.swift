import Foundation

extension CartoucheText {
    static var signingTitle: String { s("signing.title", "Import signing certificate") }
    static var signingHow: String { s("signing.how", "Use your P12, its password and provisioning profile. No Apple ID or VPN is needed for imported signing.") }
    static var signingChooseCertificate: String { s("signing.chooseCertificate", "Choose P12 certificate") }
    static var signingCertificateChosen: String { s("signing.certificateChosen", "P12 selected — replace") }
    static var signingChooseProfile: String { s("signing.chooseProfile", "Choose provisioning profile") }
    static var signingProfileChosen: String { s("signing.profileChosen", "Profile selected — replace") }
    static var signingPassword: String { s("signing.password", "P12 password") }
    static var signingUse: String { s("signing.use", "Use this certificate") }
    static var signingInvalidKey: String { s("signing.invalidKey", "Cannot open this P12. Check its password and that it includes the private key.") }
    static var signingInvalidProfile: String { s("signing.invalidProfile", "The provisioning profile is invalid, expired or does not match this certificate.") }
    static var signingReinstall: String { s("signing.reinstall", "If this certificate is not allowed by the installed app’s profile, install Cartouche again with your signing certificate (.p12) and its provisioning profile using the Cartouche Installer.") }
    static var signingRefused: String { s("signing.refused", "iOS refused this signing certificate. Import a valid replacement; if its profile differs, reinstall Cartouche with it using the computer installer.") }
    static var signingUpdateOnComputer: String { s("signing.updateOnComputer", "Updates and renewal use the Cartouche Installer on your computer with your imported certificate. No weekly Apple ID renewal is needed.") }
    static var signingInvalidFile: String { s("signing.invalidFile", "Choose a signing file smaller than 4 MB.") }
    static var guideImportedIntro: String { s("guide.importedIntro", "Import your certificate, then build and install your first game.") }
    static var signingWait: String { s("signing.wait", "Wait for the current sign-in or update to finish before changing certificates.") }
    static var signingHandoffFailed: String { s("signing.handoffFailed", "The certificate handoff could not be opened. Install Cartouche again with your signing certificate and provisioning profile.") }
}
