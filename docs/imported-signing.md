# Using your signing certificate (.p12) and its provisioning profile

Apple ID signing remains the default. If you already have your signing certificate (.p12) and its provisioning profile, Cartouche can use them for installation and game signing. Apple ID sign-in, LocalDevVPN and SideStore’s weekly renewal are not required for this optional mode. Cartouche does not recommend certificate sellers or third-party signing services.

## Install from a computer

In Cartouche Installer, select your iPhone and choose **I have a signing certificate (.p12)** under the Apple Account step. Select your signing certificate (.p12) and its provisioning profile (`.mobileprovision`). Enter the P12 password supplied with your certificate; leave it empty only if the P12 has no password. Install the latest Cartouche or choose a Cartouche IPA from your computer.

Signing runs locally. The installer checks the private key, certificate validity, profile expiry, certificate/profile match, device eligibility, application identifier and game keychain permissions. It never signs in to Apple, changes developer portal permissions or revokes account certificates on this path.

The profile must permit all 128 LiveContainer game keychain groups for the signing team: `<team>.com.kdt.livecontainer.shared` and `.1` through `.127`. A wildcard app profile with `<team>.*` keychain permission normally covers these requirements. A profile limited to its own keychain group is insufficient. Fixed application identifiers are supported: the installer preserves the profile’s signed `application-identifier` entitlement while keeping Cartouche’s bundle identifier. Wildcard identifiers are expanded only within the permissions granted by the profile. iOS remains the final authority on installation and execution, and app services such as document opening must be checked with the selected profile. The P12 must contain an RSA private key and its matching certificate; if the Apple intermediate certificate cannot be resolved, include it in the P12 certificate chain.

Imported installation uses Cartouche's base bundle identifier. Apple ID installations use a team-suffixed identifier, so these may appear as separate apps. Changing installation methods does not automatically migrate games, saves or keychain data between them.

## Open Cartouche

The installer encrypts the signing handoff with AES-256-GCM and a fresh per-install key stored in the signed app’s Info.plist. `CartoucheSigning.plist` in Documents contains ciphertext, not the P12 and its password in the clear. On its next launch, Cartouche decrypts and validates the handoff against its installed profile, then tests whether iOS accepts signed code before saving it in the device keychain. The handoff file is deleted after processing, including on failure. Keep Cartouche closed until the installer finishes preparing it.

Games use the imported certificate. Foreground refresh does not replace it with SideStore's account certificate. A refused certificate asks for a valid replacement instead of triggering Apple ID sign-in.

In an imported installation, you can replace the certificate from **System → Setup → Import signing certificate** using the P12, password and profile. This link is not shown in Apple ID installations. The installed app must already authorize that signing certificate. If it does not, install Cartouche with the replacement certificate and profile from the computer. A failed import keeps the existing selection.

## Features and updates

The imported installation omits bundled app extensions and uses Cartouche's private sandbox instead of requiring an app group. Games run in Cartouche's place; keeping the console open behind a game is unavailable. Memory permissions come from the supplied profile. Before installation, the installer checks for `com.apple.developer.kernel.increased-memory-limit`. If it is missing, the installer warns plainly that most games will not start: without this permission, the app has about 3 GB of memory. Signing cannot add that permission to the profile.

Cartouche still checks for new releases. Install updates and renew an expiring certificate through Cartouche Installer using the imported option. In-app SideStore update/renewal actions, including existing Shortcuts, are blocked in this mode.

To return to Apple ID installation, use the installer's Apple ID option with an original Cartouche release IPA. The Apple ID install and its in-app setup remain unchanged.

## Verification limits

Automated checks exercise local signing with generated test credentials, profile eligibility, credential handoff, launcher validation, localization and compilation. They do not establish that your signing certificate (.p12) and its provisioning profile is trusted by iOS. Installation, game launch, restart, certificate replacement and updating still need verification on an iPhone with the actual signing material.

A real-device validation pass must confirm that Cartouche opens and accepts the handoff, that `CartoucheSigning.plist` is gone from Documents, that a game starts, the actual limit shown in **System → Memory**, and that both app and game still work after quitting and reopening. Record the iPhone model, iOS version and memory limit with the result.
