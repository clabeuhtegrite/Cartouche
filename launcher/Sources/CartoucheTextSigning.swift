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
    static var guideImportedIntro: String { s("guide.importedIntro", "Three steps from here to your first game. Each one ticks itself once it is done.") }
    static var signingWait: String { s("signing.wait", "Wait for the current sign-in or update to finish before changing certificates.") }
    static var signingHandoffFailed: String { s("signing.handoffFailed", "Cartouche could not open the certificate the installer gave it. Install Cartouche again with your certificate and its profile.") }
}
