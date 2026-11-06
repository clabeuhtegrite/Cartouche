# The app

Cartouche is LiveContainer with SideStore built in, plus our patches. Nothing here is a copy of those projects: they are submodules pinned to exact commits, and every change we make to them is a patch file in [`patches/`](patches/).

## Pinned sources

| Submodule | Repository | Commit |
| --- | --- | --- |
| `LiveContainer` | [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer) | `9108ae62` (17 October 2026) |
| `SideStore` | [LiveContainer/SideStore](https://github.com/LiveContainer/SideStore), branch `LiveContainerSupport` | `ee3cc16a` (17 October 2026) |
| `tools/dylibify` | [LiveContainer/dylibify](https://github.com/LiveContainer/dylibify) | `5daf713d` |

To move to a newer upstream commit, update the submodule, check that every patch still applies, and say so in the pull request.

## How the IPA is built

`scripts/build.sh`, on a Mac with Xcode 27.2, CMake and `ldid`, with the network:

1. `scripts/prepare.sh` copies LiveContainer and SideStore to `build/app/work/src`, applies `patches/livecontainer/*.patch` and `patches/sidestore/*.patch` in name order, adds the launcher ([`launcher/Sources`](../launcher/Sources/)) to LiveContainer's SwiftUI sources and its bridge to the built-in SideStore ([`launcher/SideStoreSupport`](../launcher/SideStoreSupport/)) to SideStoreSupport, puts Cartouche's icon ([`icon/`](icon/)) in place of LiveContainer's, then gives the copies Cartouche's identity with `scripts/brand.py`;
2. builds dylibify;
3. builds SideStore with its own Makefile (`make build fakesign ipa`);
4. builds the lab's runtime with [`engine/spikes/s2/build_ios_runtime.sh`](../engine/spikes/s2/build_ios_runtime.sh): CPython for iOS and Capstone at the versions of its `runtime.env`, and the part of nxnative the rewriter reads, at the pinned commit;
5. builds LiveContainer with `xcodebuild archive`, with Cartouche's bundle identifier from [`config.env`](config.env);
6. assembles `build/app/Cartouche.ipa` with `scripts/package.sh`, adapted from LiveContainer's own packaging script: SideStore goes into the app as a framework, with its intents and widget, the sheets and device profiles of [`catalog/`](../catalog/) go into `CartoucheCatalog/` for the launcher, and the lab's runtime goes into `Frameworks/` and `python/`, each of Python's extension modules in a framework of its own, as iOS requires.

The IPA is unsigned; SideStore or iloader signs it when installing it. `prepare.sh` also runs on Linux: CI runs it on every pull request, with the tests in [`tests/`](tests/) of `brand.py`, the icon, the launcher's words, the names its renewal shares with LiveContainer and SideStore, and the version, so a patch or a name that no longer applies shows up in a minute rather than after the Mac build.

## Version

Cartouche has its own version, `CARTOUCHE_VERSION` in [`config.env`](config.env), as major.minor.patch. `scripts/package.sh` writes it as the app's `CFBundleShortVersionString` and `CFBundleVersion` in place of LiveContainer's, and the commit it is built from as `LCVersionInfo`. LiveContainer's and SideStore's own versions stay in `CartoucheLiveContainerVersion` and `CartoucheSideStoreVersion`, and the System tab shows them all.

The built-in SideStore offers an update when its source, [`sidestore-source.json`](sidestore-source.json), lists a higher version than the one installed. So every release raises the version, and a build is never older than a release the source lists ([`tests/test_version.py`](tests/test_version.py)). How a release is cut and added to the source: [`releases/README.md`](releases/README.md).

## Identity

Cartouche has its own bundle identifier, URL schemes and source, so that LiveContainer's links never reach it and its SideStore never takes a LiveContainer for itself. Its names come from [`config.env`](config.env). Two names stay LiveContainer+SideStore's on purpose, the app group and the keychain groups, so that iloader installs Cartouche with its certificate (below):

| | LiveContainer+SideStore | Cartouche |
| --- | --- | --- |
| Bundle identifier, and App IDs | `com.kdt.livecontainer` | `io.github.clabeuhtegrite.cartouche` |
| Bundle identifier of the built-in SideStore | `com.SideStore.SideStore` | the same |
| Display name in the Info.plist, which iloader reads | `LiveContainer` | the same |
| Name on the home screen, from each localization | `LiveContainer` | `Cartouche` |
| App group | `group.com.SideStore.SideStore`, and AltStore's | `group.com.SideStore.SideStore` only |
| Keychain groups of the app and the apps it runs | `com.kdt.livecontainer.shared` and `.1` to `.127` | the same |
| URL schemes | `livecontainer`, `livecontainer2`, `livecontainer3` | `cartouche`, `cartouche2`, `cartouche3` |
| URL scheme of the built-in SideStore | `sidestore` | `sidestore.cartouche` |
| Source the built-in SideStore reads | LiveContainer's releases | [`sidestore-source.json`](sidestore-source.json): Cartouche itself, and nothing else |
| Notice SideStore sends to every app before it migrates its database | `com.rileytestut.AltStore.WillMigrateDatabase` | `io.github.clabeuhtegrite.cartouche.WillMigrateDatabase` |

When SideStore or iloader signs Cartouche, it appends the team identifier to the app group, and usually to the bundle identifier. With LiveContainer's bundle identifier and URL schemes, Cartouche's SideStore would take a LiveContainer for itself and refresh it, `livecontainer://` and `sidestore://` links would reach either app, and each SideStore would quit when the other migrates its database.

`scripts/brand.py` renames the names in the copies of the sources after the patches, and stops the build when a name it expects has moved or when an old name is left. [`patches/livecontainer/0001`](patches/livecontainer/0001-use-the-built-in-sidestore-app-group-only.patch) drops the AltStore app group, and [`0002`](patches/livecontainer/0002-never-fall-back-to-another-apps-app-group.patch) keeps Cartouche from opening any other app group that a signature would give it. `scripts/package.sh` sets the names (the Info.plist's for iloader, each localization's for the home screen), the app group SideStore signs with, and the built-in SideStore's URL scheme, and checks that the built-in SideStore is still `com.SideStore.SideStore`.

The icon is a game cartridge of our own, in [`icon/`](icon/): light, dark and tinted, and in grey for an extra copy of Cartouche installed from its settings, where LiveContainer uses a grey icon too. [`icon/make_icon.py`](icon/make_icon.py) writes the SVG sources, which are rendered at 1024 × 1024 into the icon sets.

The built-in SideStore's bundle identifier matters to [iloader](https://github.com/nab138/iloader): it takes any app with a `com.SideStore.SideStore` framework inside for a LiveContainer+SideStore. It writes its signing certificate into that framework (`ALTCertificate.p12`, and `ALTCertificateID` in its Info.plist), where the built-in SideStore finds it when the player signs in, and gives the app the app group `group.com.SideStore.SideStore.<team>` and the keychain groups `<team>.com.kdt.livecontainer.shared` and `.1` to `.127`, nothing else. Cartouche 0.1.0 had names of its own: iloader installed it as an ordinary app, without a certificate, so LiveContainer could sign no game and SideStore could not renew it. The price of LiveContainer+SideStore's names is that Cartouche takes the place of a LiveContainer+SideStore on the iPhone: the two would share their SideStore data and keychain. How the first install goes is in [docs/architecture.md](../docs/architecture.md#first-install).

iloader also places a pairing file, on its Pairing page (Manage Pairing File › Place In All Apps), but only in the apps of its own list (`PAIRING_APPS`, in its `src-tauri/src/pairing.rs`). It compares that list with the `CFBundleDisplayName` the iPhone reports for each app, and puts the file of an app named `LiveContainer` at `Documents/SideStore/Documents/ALTPairingFile.mobiledevicepairing`, where a LiveContainer+SideStore's SideStore reads it, and Cartouche's too. Cartouche's Info.plist keeps that name, and every localization of the app, an `InfoPlist.strings` in each of its `.lproj` folders, names it Cartouche: the home screen, Settings and Files show that name, and so does the built-in SideStore ([`patches/sidestore/0008`](patches/sidestore/0008-name-an-app-as-its-home-screen-does.patch)). The iPhone reports the name in its own language too, so iloader 2.4.1 lists Cartouche only on an iPhone set to a language Cartouche has no localization for (tested on 0.1.2). Until its list has Cartouche, the player exports the pairing file from iloader and drops it on Cartouche from the computer ([launcher/README.md](../launcher/README.md#setup)).
