# Launcher

The interface players see: a console-style catalogue of every game Cartouche supports, with the player's own games first. Its SwiftUI sources are in [`Sources/`](Sources/). `app/scripts/prepare.sh` adds them to LiveContainer's SwiftUI sources, and [`livecontainer/0003`](../app/patches/livecontainer/0003-open-on-cartouches-games-with-its-system-page.patch) opens the app on them. Its bridge to the built-in SideStore, [`SideStoreSupport/`](SideStoreSupport/), joins LiveContainer's SideStoreSupport framework the same way.

## Screens

- **Catalogue, the home screen:** every game Cartouche supports, from the compatibility sheets in [`catalog/`](../catalog/).
  - The player's own games come first, large and featured, each with the icon from their own copy of the game and its state: ready, engine update in progress, not recommended on this iPhone.
  - The other supported games follow, smaller, with their status on this iPhone and one action, **Import my copy**, which opens Files. There is no download button and no hint of where to get a game.
  - A game the player does not have gets a tile we design (title, colours, platform), never official cover art, which is not ours to redistribute. The tile gives way to the icon of the player's copy once they import it.
- **Game sheet:** what the game needs against what this iPhone has (memory limit measured on the phone, iOS version, GPU features), recommended settings, testers' results.
- **Import:** an IPA built on a Mac (v1) or the player's own dump (v2), from Files, iCloud Drive, a USB-C drive or a network share.
- **System:** signature days left and renewal, updates, the memory probe, opt-in reports.

The catalogue shows what Cartouche can run, never where to get a game.

## What the first build does

The first launcher, Phase 1, on iOS 17 or later; an older iOS opens on LiveContainer's app list as before. The tab bar holds **Games** and **System**, then LiveContainer's **Apps** and **Settings**. LiveContainer's Sources and Tweaks tabs are gone: Cartouche downloads no app, and games need no tweak.

- **Games.** The sheets of [`catalog/`](../catalog/) as of the build, which `app/scripts/package.sh` puts in the app (`CartoucheCatalog/`); updates from the server come later.
  - The player's games are found among LiveContainer's apps by the bundle identifier nxnative gives its iOS apps, `org.nxnative.<title ID>`, or else by the `DMLanguage` key it writes into their `Info.plist`. A game is matched to its sheet by title ID, or by name when the build had another bundle identifier. A game without a sheet still shows, as *No sheet yet*, and starts.
  - **Import my copy** opens Files. LiveContainer's Apps tab then installs the IPA, reading it where it is: a game's IPA is too large to copy first.
  - **Play** hands the game to the Apps tab, which starts it as a `livecontainer-launch` link does.
- **How a game fits this iPhone,** from its sheet and what the launcher measures here:
  - *Not supported* when iOS is older than the game needs, or the GPU cannot read BC-compressed textures;
  - *Not recommended* when the game needs Increased Memory Limit and Cartouche does not have it, when its measured peak is above the limit measured here, or when the latest result on this model is *does not run*;
  - *Runs on this iPhone* when the latest result on this model is playable;
  - *Not tried on this iPhone yet* otherwise. On the player's own game, the badge reads *Ready* when nothing stands in the way.
- **System.**
  - The memory limit iOS sets for Cartouche, which its games share, measured as in [`devices.json`](../catalog/devices.json): footprint plus `os_proc_available_memory()`. Whether the signature carries Increased Memory Limit, and what testers measured on this model.
  - When the signature expires, the days left, and when it was last renewed. SideStore renews an app by installing a new provisioning profile and leaves the `embedded.mobileprovision` inside the app as its last install wrote it, so the launcher takes the later of that date and the one the built-in SideStore records for its widget after each renewal (`widget_data.json` in the app group).
  - **Renew now** renews without leaving Cartouche, with LocalDevVPN connected, and shows the progress. It runs the same refresh as the **Refresh All Apps** action that LiveContainer gives Shortcuts: the built-in SideStore starts in LiveProcess and renews every app it manages, Cartouche first. The launcher cannot import SideStoreSupport, so [`CartoucheRefresh`](SideStoreSupport/CartoucheRefresh.swift) joins that framework and the launcher finds it by its Objective-C name. **Open SideStore** stays, for the account and the certificate.
  - **Renew every night** explains the automation that renews Cartouche with no computer: in Shortcuts, a *Time of Day* automation, daily and *Run Immediately*, that runs Cartouche's *Refresh All Apps*, with LocalDevVPN left connected. iOS lets no app create the automation itself.
  - **Expiry alerts,** once the player allows them, 24 hours and 6 hours before the signature expires, and when it has. SideStore schedules its own after each renewal, in English and about "SideStore", under the same identifiers (`sidestore-expiration-warning.24h`, `.6h`, `.0h`), so each replaces the other: after a renewal in the background, SideStore's take the new date, and Cartouche writes its own again whenever it comes to the foreground. A separate warning two days ahead would keep the old date after a renewal in the background, so there is none. [`app/tests/test_renewal.py`](../app/tests/test_renewal.py) checks these identifiers, and the bridge's names, against the pinned sources.
  - This iPhone: model, chip and memory from `devices.json`, iOS, and the GPU's BC support. Cartouche's version with the commit it was built from, the LiveContainer and SideStore it is based on, and how many sheets it carries ([app/README.md](../app/README.md#version)).
- **Setup,** at the top of Games and System until it is done, and wherever **Play** would fail without a certificate ([`CartoucheSetup.swift`](Sources/CartoucheSetup.swift)):<a id="setup"></a>
  1. *Pairing file:* iloader's **Place In All Apps** puts it into the built-in SideStore's Documents as `ALTPairingFile.mobiledevicepairing`, as for a LiveContainer+SideStore, the name iloader lists Cartouche under ([app/README.md](../app/README.md#identity)). The step looks for it every two seconds while it is not there, so it ticks itself while the player is still at the computer. A file iloader exported can also be opened with Cartouche from AirDrop or Files ([`app/patches/livecontainer/0004`](../app/patches/livecontainer/0004-hand-a-pairing-file-opened-from-another-app-to-cartouches-setup.patch)), which shows the setup, or chosen here; Cartouche checks that it is one and copies it to the same place.
  2. *Apple ID:* **Sign in with SideStore** opens the built-in SideStore on its onboarding, even when the player went through it before without signing in: the setup leaves a request in the app group, which [`CartoucheOnboardingReturn.m`](SideStoreSupport/CartoucheOnboardingReturn.m) reads in SideStore. The onboarding opens LocalDevVPN, then the Apple ID sign-in, each once and by itself ([`app/patches/sidestore/0007`](../app/patches/sidestore/0007-take-the-player-through-the-onboarding-with-as-few-taps-as-possible.patch)), and brings the player back to Cartouche once they are signed in. SideStore signs in through the SideStore (New) anisette server and takes the certificate iloader wrote into it ([app/README.md](../app/README.md#identity)). The step reads as done once SideStore's keychain holds the Apple ID.
  3. *Certificate:* Cartouche reads SideStore's certificate from their shared keychain (service: Cartouche's bundle identifier, `CartoucheBundleIdentifier` in the Info.plist) and hands it to LiveContainer, as LiveContainer's *Import Certificate from SideStore* does after a confirmation. It does so whenever it comes to the front, and again when SideStore's certificate changes; one whose key does not open is left aside.
  - LocalDevVPN, for renewals, with a link to the App Store.
- **Words** in [`Sources/Cartouche.xcstrings`](Sources/Cartouche.xcstrings), in English and French. The code carries the English too, for a missing translation. [`app/tests/test_launcher_strings.py`](../app/tests/test_launcher_strings.py) checks that both match, that every format takes the arguments the code passes, and the French no-break spaces.
- **Layout.** In a compact width, a game's sheet opens over the catalogue. In a regular width, the catalogue and the sheet sit side by side when the view is wider than tall, and one above the other when it is taller than wide, chosen from the view's own size; folding or unfolding keeps the selected game and the catalogue's scroll position.
- **Not yet:** the split `ArrangementView` and `reservedRegions` of iOS 27.1, `backgroundExtensionEffect()`, sheets updated from the server, the state of an engine update, and opt-in reports.

## Every iPhone, the iPhone Duo included

The launcher lays itself out from the space it is given, never from the iPhone model, as Apple asks of apps for the iPhone Duo ([Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)). One design then serves every iPhone, both displays of the Duo and the iPad. The model matters only to the game sheets, for memory.

| Where | Width class | Catalogue |
| --- | --- | --- |
| Any other iPhone, portrait | compact | One column: the player's games large at the top, then the grid. A game's sheet opens over the catalogue. |
| iPhone Duo folded: outer display, 5.4 in | compact | As on the other iPhones. iOS moves the bars to the side of the display. |
| iPhone Duo unfolded: inner display, 7.6 in | regular | The catalogue and the selected game's sheet together, one on each side of the fold. |
| iPad | regular | As on the unfolded Duo; one column in a narrow window. |

- **Size classes and our own bounds, not the screen.** Layout follows `horizontalSizeClass` and the bounds of the scene or the containing view, never `UIScreen.main.bounds`, `userInterfaceIdiom` or the interface orientation.
- **System containers and bars.** `NavigationStack`, `toolbar(content:)` and the bars iOS provides, which it presents vertically on the side of the Duo's outer display, and for some views on the inner one. Every bar item has an icon and a title: iOS does not present a title-only item or a custom view vertically. The banner of the player's games extends under a vertical bar with `backgroundExtensionEffect()`.
- **Regular width.** A split `ArrangementView` (iOS 27.1) holds the catalogue and the game sheet: side by side when the display is wider than tall, the catalogue above and the sheet below when it is taller than wide, and iOS places them around the fold. It sits at the top level, not inside a split view, list or scroll view, as Apple advises. Until Cartouche is built with Xcode 27.1, two navigation stacks in the same arrangement stand in for it, since a `NavigationSplitView` cannot put one above the other.
- **Nothing in the fold or under a camera.** Views we draw ourselves read `reservedRegions(kind:options:layoutDirectionBehavior:)` and keep text and controls out of the fold while the Duo is partly folded, and out of the outer front camera, which always covers part of the outer display. System views move on their own.
- **Folding loses nothing.** Folding, unfolding or rotating keeps the selected game, the scroll position and any import in progress; imports run outside the views.
- **Built with Xcode 27.1 or later.** Apple: an app built with Xcode 26 or earlier does not extend under the Duo's status bar and camera. CI builds with Xcode 26.4 today, and GitHub's macOS runners offer Xcode 27 only as a public preview ([runner-images#14404](https://github.com/actions/runner-images/issues/14404)). Cartouche moves to it once LiveContainer and SideStore build with it. Until then it works on the Duo without using the whole display.
- **Tested** in the Duo simulator, then on a Duo closed, open and partly folded, rotated in each pose, as Apple recommends.

### Games on the Duo

A game's picture and its touch controls are drawn by nxnative's iOS app, which runs inside Cartouche. We do not patch it: what follows goes to nxnative as proposals, with measurements, like our other fixes.

- **A 16:9 picture on near-square displays.** The Duo's displays are about 1.4:1, against 2.2:1 for the other iPhones ([specifications](https://www.apple.com/uk/iphone-duo/specs/): 1878 × 2670 inside, 1398 × 2034 outside). In landscape, a 16:9 game leaves bands above and below rather than at the sides: 2670 × 1502 unfolded, 2034 × 1144 folded. Touch controls therefore sit over the picture, out of the fold and the camera.
- **On a table, the game above the fold and the controls below,** like a two-screen console. Apple's overlay `ArrangementView` does this: it shows the primary view, the controls, over the secondary view, the game, when the Duo is closed or flat, and below the fold when it is partly open on a table. The upper half then shows the picture at 1878 × 1056, nearly pixel for pixel for the 1080p of handheld mode.
- **Handheld mode at 1080p stays the rule.** Unfolded, the picture is scaled up to 2670 × 1502.
- **A game sees Cartouche's SDK version.** Inside Cartouche, system libraries work to the SDK version Cartouche was built with, not the game's, unless LiveContainer's per-app *Spoof SDK Version* setting is on ([`Dyld.m`](https://github.com/LiveContainer/LiveContainer/blob/9108ae624ea001f7d7696d48407f890b48fa2653/LiveContainer/Tweaks/Dyld.m)). Once Cartouche is built with Xcode 27.1, games will likely use the whole display too, the camera area included. Phase 1 checks on a Duo that the touch controls stay clear of the camera and the fold, and that folding or unfolding mid-race neither restarts the game nor pushes it over its memory limit.
