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

1. copies LiveContainer and SideStore to `build/app/work` and applies `patches/livecontainer/*.patch` and `patches/sidestore/*.patch` in name order;
2. builds dylibify;
3. builds SideStore with its own Makefile (`make build fakesign ipa`);
4. builds LiveContainer with `xcodebuild archive`, with Cartouche's bundle identifier from [`config.env`](config.env);
5. assembles `build/app/Cartouche.ipa` with `scripts/package.sh`, adapted from LiveContainer's own packaging script: SideStore goes into the app as a framework, with its intents and widget.

The IPA is unsigned; SideStore or iloader signs it when installing it.

## Bundle identifier

`io.github.clabeuhtegrite.cartouche`. It differs from LiveContainer's (`com.kdt.livecontainer`) so that Cartouche gets its own App ID and can never replace an installed LiveContainer. The rest of the branding (strings that still name LiveContainer's identifier, the name and the icon) moves to Cartouche's in a patch in Phase 1; until then, CI builds are not meant to be installed.
