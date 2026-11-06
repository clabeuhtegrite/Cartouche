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

`scripts/build.sh`, on a Mac with Xcode 26.4 and `ldid`:

1. `scripts/prepare.sh` copies LiveContainer and SideStore to `build/app/work/src`, applies `patches/livecontainer/*.patch` and `patches/sidestore/*.patch` in name order, adds the launcher ([`launcher/Sources`](../launcher/Sources/)) to LiveContainer's SwiftUI sources, then gives the copies Cartouche's identity with `scripts/brand.py`;
2. builds dylibify;
3. builds SideStore with its own Makefile (`make build fakesign ipa`);
4. builds LiveContainer with `xcodebuild archive`, with Cartouche's bundle identifier from [`config.env`](config.env);
5. assembles `build/app/Cartouche.ipa` with `scripts/package.sh`, adapted from LiveContainer's own packaging script: SideStore goes into the app as a framework, with its intents and widget, and the sheets and device profiles of [`catalog/`](../catalog/) go into `CartoucheCatalog/` for the launcher.

The IPA is unsigned; SideStore or iloader signs it when installing it. `prepare.sh` also runs on Linux: CI runs it on every pull request, with the tests in [`tests/`](tests/) of `brand.py` and of the launcher's words, so a patch or a name that no longer applies shows up in a minute rather than after the Mac build.

## Identity

Cartouche uses none of LiveContainer's or SideStore's names, so that it can sit next to a LiveContainer or a SideStore on the same iPhone and share nothing with them. Its names come from [`config.env`](config.env):

| | LiveContainer+SideStore | Cartouche |
| --- | --- | --- |
| Bundle identifier, and App IDs | `com.kdt.livecontainer` | `io.github.clabeuhtegrite.cartouche` |
| Bundle identifier of the built-in SideStore | `com.SideStore.SideStore` | `io.github.clabeuhtegrite.cartouche.SideStore` |
| App group | `group.com.SideStore.SideStore`, and AltStore's | `group.io.github.clabeuhtegrite.cartouche` only |
| Keychain groups of the apps it runs | `com.kdt.livecontainer.shared.N` | `io.github.clabeuhtegrite.cartouche.shared.N` |
| URL schemes | `livecontainer`, `livecontainer2`, `livecontainer3` | `cartouche`, `cartouche2`, `cartouche3` |
| URL scheme of the built-in SideStore | `sidestore` | `sidestore.cartouche` |
| Source the built-in SideStore reads | LiveContainer's releases | [`sidestore-source.json`](sidestore-source.json): Cartouche itself, and nothing else |
| Notice SideStore sends to every app before it migrates its database | `com.rileytestut.AltStore.WillMigrateDatabase` | `io.github.clabeuhtegrite.cartouche.WillMigrateDatabase` |

When SideStore signs Cartouche, it appends the team identifier to the app group, and usually to the bundle identifier. With LiveContainer's names, Cartouche's SideStore would open the same app group as a LiveContainer+SideStore installed next to it, take that LiveContainer for itself and refresh it, `livecontainer://` and `sidestore://` links would reach either app, and each SideStore would quit when the other migrates its database.

`scripts/brand.py` renames the names in the copies of the sources after the patches, and stops the build when a name it expects has moved or when an old name is left. [`patches/livecontainer/0001`](patches/livecontainer/0001-use-the-built-in-sidestore-app-group-only.patch) drops the AltStore app group, and [`0002`](patches/livecontainer/0002-never-fall-back-to-another-apps-app-group.patch) keeps Cartouche from opening any other app group that a signature would give it. `scripts/package.sh` sets the name on the home screen, the app group SideStore signs with, and the built-in SideStore's URL scheme and bundle identifier. The icon is still LiveContainer's.

The built-in SideStore's bundle identifier matters to [iloader](https://github.com/nab138/iloader): it takes any app with a `com.SideStore.SideStore` framework inside for a LiveContainer+SideStore, and gives it the app group `group.com.SideStore.SideStore.<team>`, which every LiveContainer+SideStore of the account shares. With its own, Cartouche is installed as an ordinary app, with `group.io.github.clabeuhtegrite.cartouche.<team>`, the group its SideStore signs it with afterwards. How the first install then gets the pairing file and the certificate is in [docs/architecture.md](../docs/architecture.md#first-install).
