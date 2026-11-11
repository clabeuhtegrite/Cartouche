# Signing with a FlareStore certificate

Cartouche can use a supplied signing certificate for its installation and for games. Apple ID sign-in, LocalDevVPN and SideStore's weekly renewal are not required in this mode. The existing Apple ID option remains available.

## Install from a computer

In Cartouche Installer, select your iPhone, choose **Import certificate**, and select your `.p12` certificate and `.mobileprovision` profile. Enter the P12 password supplied with your certificate; leave it empty only if the P12 has no password. Install the latest Cartouche or choose a Cartouche IPA from your computer.

Signing runs locally. The installer checks the private key, certificate validity, profile expiry, certificate/profile match, device eligibility, application identifier and game keychain permissions. It never signs in to Apple, changes developer portal permissions or revokes account certificates on this path.

Use a profile that permits Cartouche's identifier, `io.github.clabeuhtegrite.cartouche`, and all 128 LiveContainer game keychain groups for the signing team: `<team>.com.kdt.livecontainer.shared` and `.1` through `.127`. A wildcard app profile with `<team>.*` keychain permission normally covers these requirements. An explicit profile limited to another app or to its own keychain group is insufficient. The P12 must contain an RSA private key and its matching certificate; if the Apple intermediate certificate cannot be resolved, include it in the P12 certificate chain.

Imported installation uses Cartouche's base bundle identifier. Apple ID installations use a team-suffixed identifier, so these may appear as separate apps. Changing installation methods does not automatically migrate games, saves or keychain data between them.

## Open Cartouche

The installer transfers a signing handoff to Cartouche. On its next launch, Cartouche validates it against its installed profile and tests whether iOS accepts signed code before saving it in the device keychain. The handoff file is deleted after processing. Keep Cartouche closed until the installer finishes preparing it.

Games use the imported certificate. Foreground refresh does not replace it with SideStore's account certificate. A refused certificate asks for a valid replacement instead of triggering Apple ID sign-in.

You can also import a replacement from **System → Setup → Import signing certificate** using the P12, password and profile. The installed app must already authorize that signing certificate. If it does not, install Cartouche with the replacement certificate and profile from the computer. A failed import keeps the existing selection.

## Features and updates

The imported installation omits bundled app extensions and uses Cartouche's private sandbox instead of requiring an app group. Games run in Cartouche's place; keeping the console open behind a game is unavailable. Memory permissions come from the supplied profile, so a profile without Increased Memory Limit does not gain it through signing.

Cartouche still checks for new releases. Install updates and renew an expiring certificate through Cartouche Installer using the imported option. In-app SideStore update/renewal actions, including existing Shortcuts, are blocked in this mode.

To return to Apple ID installation, use the installer's Apple ID option with an original Cartouche release IPA. If you imported a certificate into an existing account installation, **Use Apple ID signing** in setup switches that installation back directly.

## Verification limits

Automated checks exercise local signing with generated test credentials, profile eligibility, credential handoff, launcher validation, localization and compilation. They do not establish that a particular FlareStore certificate is trusted by iOS. Installation, game launch, restart, certificate replacement and updating still need verification on an iPhone with the actual signing material.
