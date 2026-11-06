# Third-party components

Cartouche is built from these projects. Each keeps its own licence; their licence files are in their source trees.

## In the app

| Component | What it does in Cartouche | Licence |
| --- | --- | --- |
| [LiveContainer](https://github.com/LiveContainer/LiveContainer) (`app/LiveContainer`) | The app itself: runs games as guest apps, signs them on the device | AGPL-3.0 |
| [SideStore](https://github.com/SideStore/SideStore), LiveContainer's fork (`app/SideStore`, branch `LiveContainerSupport`) | Signs in to the Apple account, installs and renews the app | AGPL-3.0 |
| [SideSign](https://github.com/SideStore/SideSign) (inside SideStore) | SideStore's signing library | GPL-3.0 |
| [minimuxer](https://github.com/SideStore/minimuxer) (inside SideStore) | SideStore's link to the device's services | AGPL-3.0 |
| [litehook](https://github.com/LiveContainer/litehook) (inside LiveContainer) | Function hooking | MIT |
| [fishhook](https://github.com/LiveContainer/fishhook) (inside LiveContainer) | Symbol rebinding | BSD-3-Clause |
| [OpenSSL](https://www.openssl.org), packaged by [krzyzanowskim/OpenSSL](https://github.com/krzyzanowskim/OpenSSL) (inside LiveContainer) | Cryptography for on-device signing | Apache-2.0 |
| ZSign (inside LiveContainer's tree) | On-device code signing | see LiveContainer |

The Swift packages that LiveContainer and SideStore resolve at build time are listed in their `Package.resolved` files.

## In the app's lab

The lab rewrites a game's modules on the iPhone (spike S2, [`engine/spikes/s2`](engine/spikes/s2/README.md)). The app carries the licence of each of these in `python/licenses`.

| Component | What it does in Cartouche | Licence |
| --- | --- | --- |
| [CPython](https://www.python.org) 3.13 for iOS, built by BeeWare's [Python-Apple-support](https://github.com/beeware/Python-Apple-support) | Runs nxnative's rewriter | PSF-2.0 |
| [OpenSSL](https://www.openssl.org) (inside that build) | Python's `ssl` and `hashlib` modules | Apache-2.0 |
| [libffi](https://github.com/libffi/libffi) (inside that build) | Python's `ctypes`, which Capstone's binding uses | MIT |
| [bzip2](https://sourceware.org/bzip2/), [XZ Utils](https://tukaani.org/xz/), [mpdecimal](https://www.bytereef.org/mpdecimal/) (inside that build) | Python's `bz2`, `lzma` and `decimal` modules | bzip2 licence, 0BSD, BSD-2-Clause |
| [Capstone](https://www.capstone-engine.org) 5.0.7, built for iOS | The disassembler of the rewriter | BSD-3-Clause |
| nxnative's `dm/tools` and `dm/games` | The rewriter, `patch_nso.py`, and the game profiles it reads | MIT |

## Engine

| Component | What it does | Licence |
| --- | --- | --- |
| [nxnative](https://github.com/seedds/nxnative) | Runs the games natively; its own third-party components are listed in its `dm/third_party/README.md` | MIT |

## Build tools

| Component | What it does | Licence |
| --- | --- | --- |
| [dylibify](https://github.com/LiveContainer/dylibify) (`app/tools/dylibify`) | Turns SideStore's executable into a library the app loads | MIT |
| [ldid](https://github.com/ProcursusTeam/ldid) | Ad hoc signing during packaging | AGPL-3.0 |

`app/scripts/package.sh` is adapted from LiveContainer's `.github/build_github.sh` (AGPL-3.0).
