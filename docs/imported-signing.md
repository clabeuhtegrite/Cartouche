# Using your signing certificate (.p12) and its provisioning profile

Apple ID signing remains the default. If you already have your signing certificate (.p12) and its provisioning profile, Cartouche can use them for installation and game signing, installed from a computer with the Cartouche Installer, or with no computer, signed on the iPhone by a signing app. Apple ID sign-in, LocalDevVPN and SideStore’s weekly renewal are not required for this optional mode. Cartouche does not recommend certificate sellers, signing apps or third-party signing services.

## Install from a computer

In Cartouche Installer, select your iPhone, then choose **Certificate (.p12)** at the top of the Apple Account step (**I have a signing certificate (.p12)**, under it, in earlier Installers). Select your signing certificate (.p12) and its provisioning profile (`.mobileprovision`). Enter the P12 password supplied with your certificate; leave it empty only if the P12 has no password. Install the latest Cartouche or choose a Cartouche IPA from your computer.

Signing runs locally. The installer checks the private key, certificate validity, profile expiry, certificate/profile match, device eligibility, application identifier and game keychain permissions. It never signs in to Apple, changes developer portal permissions or revokes account certificates on this path.

The profile must permit all 128 LiveContainer game keychain groups for the signing team: `<team>.com.kdt.livecontainer.shared` and `.1` through `.127`. A wildcard app profile with `<team>.*` keychain permission normally covers these requirements. A profile limited to its own keychain group is insufficient. A fixed application identifier must be Cartouche’s own, `<team>.io.github.clabeuhtegrite.cartouche`, and a wildcard one must cover it: iOS installs an app only under an App ID its profile covers, so the installer names a profile made for another app as soon as it is chosen, and never signs with it. Wildcard identifiers are expanded only within the permissions granted by the profile. iOS remains the final authority on installation and execution, and app services such as document opening must be checked with the selected profile. The P12 must contain an RSA private key and its matching certificate; if the Apple intermediate certificate cannot be resolved, include it in the P12 certificate chain.

Imported installation uses Cartouche's base bundle identifier. Apple ID installations use a team-suffixed identifier, so these may appear as separate apps. Changing installation methods does not automatically migrate games, saves or keychain data between them.

## Install with no computer

From the version of November 15, each release has a second IPA beside `Cartouche-<version>.ipa`: `Cartouche-<version>-Own-Certificate.ipa`, for a signing app on the iPhone. [`app/scripts/own_certificate_ipa.py`](../app/scripts/own_certificate_ipa.py) makes it from the release's IPA, which it keeps file for file but for two changes: `CartoucheImportedSigning` set in its Info.plist, so that Cartouche starts in this mode, and no app extension (LiveProcess, the widget, the built-in SideStore's, the Watch app), since a profile signs one app. It holds no game. The publish guard checks it as it checks the release's IPA, and the source lists it in that version's entry (`ownCertificateDownloadURL`, `ownCertificateSize`, `ownCertificateSHA256`), which only Cartouche reads.

1. On the iPhone, download that IPA from the release's page on GitHub.
2. Sign it in your signing app with your signing certificate (.p12), its password and its provisioning profile, keeping the bundle identifier the IPA has and every entitlement of the profile, and install it.
3. Open Cartouche. Its setup, and the first game's guide, ask for one thing: the certificate the signing app signed Cartouche with, and its password. There is no profile to choose: Cartouche reads the profile the signing app put in it (`embedded.mobileprovision`), checks that it lists this certificate, then that iOS runs what LiveContainer signs with it, and keeps it in the keychain. Another certificate is refused: sign Cartouche again with it first.

Without a computer, nothing checks the profile before the install. **System → Setup** then says what Cartouche's signature gives it, from the entitlements it runs with and those of its profile ([`CartoucheOwnSignature.swift`](../launcher/Sources/CartoucheOwnSignature.swift)):

- Increased Memory Limit. Without it, iOS gives Cartouche, and the games that start in its place, about 3 GB, too little for most games. Left out by the signing app while the profile allows it, signing Cartouche again with every entitlement of the profile brings it back; missing from the profile, it needs an App ID with the capability, and a new profile.
- The games' keychain groups, `<team>.com.kdt.livecontainer.shared` and `.1` through `.127`. iOS gives a keychain group only to a signature that names it, or names `*`: a signing app that copies the profile's `<team>.*` pattern into the signature as it is gives none. Without them, the games share Cartouche's keychain, which most games do not use.

Cartouche reads the source as before. When a new version is out, it says so over the console, once a day at most, and on **System → Updates**, with **Download**, which opens that version's IPA for the player's own certificate in Safari: only an IPA of Cartouche's releases on GitHub. Sign it as the first time and install it over Cartouche: the games, their saves and the imported certificate stay, as long as the bundle identifier does. Cartouche never installs it itself. A certificate that expires or is revoked is replaced the same way, by signing Cartouche again with the new one, then importing it.

The Cartouche Installer's option for the player's own certificate also takes this IPA, from a computer, as any Cartouche IPA. With an Apple ID, the installer refuses it: signed that way, Cartouche would start asking for a certificate, without the Apple ID's setup.

## Open Cartouche

The installer encrypts the signing handoff with AES-256-GCM and a fresh per-install key stored in the signed app’s Info.plist. `CartoucheSigning.plist` in Documents contains ciphertext, not the P12 and its password in the clear. On its next launch, Cartouche decrypts and validates the handoff against its installed profile, then tests whether iOS accepts signed code before saving it in the device keychain. The handoff file is deleted after processing, including on failure. Keep Cartouche closed until the installer finishes preparing it.

Games use the imported certificate. Foreground refresh does not replace it with SideStore's account certificate. A refused certificate asks for a valid replacement instead of triggering Apple ID sign-in.

In an imported installation, you can replace the certificate from **System → Setup → Import signing certificate** using the P12, password and profile. This link is not shown in Apple ID installations. The installed app must already authorize that signing certificate. If it does not, install Cartouche with the replacement certificate and profile from the computer. A failed import keeps the existing selection.

## Features and updates

The imported installation omits bundled app extensions and uses Cartouche's private sandbox instead of requiring an app group. Games run in Cartouche's place; keeping the console open behind a game is unavailable. Memory permissions come from the supplied profile. Before installation, the installer checks for `com.apple.developer.kernel.increased-memory-limit`. If it is missing, the installer warns plainly that most games will not start: without this permission, the app has about 3 GB of memory. Signing cannot add that permission to the profile.

Cartouche still checks for new releases, and says when one is out. Installed from a computer, install updates and renew an expiring certificate through Cartouche Installer using the imported option; signed on the iPhone, through the signing app, as above. In-app SideStore update/renewal actions, including existing Shortcuts, are blocked in this mode.

To return to Apple ID installation, use the installer's Apple ID option with an original Cartouche release IPA. The Apple ID install and its in-app setup remain unchanged.

## Verification limits

Automated checks exercise local signing with generated test credentials, profile eligibility, credential handoff, launcher validation, localization and compilation. They do not establish that your signing certificate (.p12) and its provisioning profile is trusted by iOS. Installation, game launch, restart, certificate replacement and updating still need verification on an iPhone with the actual signing material.

For the IPA a signing app signs on the iPhone, the checks cover the IPA itself (`app/tests/test_own_certificate_ipa.py`), its entry in the source (`app/tests/test_add_release.py`), what Cartouche reads of its signature (`CartoucheOwnSignatureTests`) and its screens in the launcher's gallery and UI tests (`OwnCertificateUITests`). No signing app has signed it with a real certificate yet: that this IPA installs, that Cartouche accepts the certificate and that a game starts is still to be seen on an iPhone.

A real-device validation pass must confirm that Cartouche opens and accepts the handoff, that `CartoucheSigning.plist` is gone from Documents, that a game starts, the actual limit shown in **System → Memory**, and that both app and game still work after quitting and reopening. Record the iPhone model, iOS version and memory limit with the result.
