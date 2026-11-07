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
| [SMBClient](https://github.com/kishikawakatsumi/SMBClient) (`app/SMBClient`, pinned at `66eafaa`) | Reads and writes the player's shared folders (SMB 2 and 3) for their games and saves | MIT |
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) 0.15.0, by Apple (linked by `app/patches/livecontainer/0007`) | Speaks SSH to the player's SFTP servers for their games and saves | Apache-2.0 |
| [swift-nio](https://github.com/apple/swift-nio), [swift-crypto](https://github.com/apple/swift-crypto), [swift-asn1](https://github.com/apple/swift-asn1), [swift-atomics](https://github.com/apple/swift-atomics), [swift-collections](https://github.com/apple/swift-collections) and [swift-system](https://github.com/apple/swift-system), by Apple (what swift-nio-ssh needs, pinned in the `Package.resolved` of 0007) | Networking and cryptography under swift-nio-ssh | Apache-2.0 |

The Swift packages that LiveContainer and SideStore resolve at build time are listed in their `Package.resolved` files.

## Cartouche Installer

The computer app that installs Cartouche the first time ([`installer/`](installer/README.md)) is under the MIT licence, as the project it is forked from; its [LICENSE](installer/LICENSE) keeps that project's notice.

| Component | What it does in the installer | Licence |
| --- | --- | --- |
| [iloader](https://github.com/nab138/iloader) 2.4.1, by nab138 | The installer is a fork of it: the app, its backend and its window. iloader's name and logos are not used | MIT |
| [isideload](https://crates.io/crates/isideload) | Signs in to the Apple account, signs and installs Cartouche, writes its certificate | MIT |
| [idevice](https://crates.io/crates/idevice) | Talks to the iPhone: pairing, the apps installed, house arrest for the pairing file | MIT |
| [Tauri](https://tauri.app) 2 and its dialog, opener and store plugins | The app around the window | Apache-2.0 or MIT |
| [React](https://react.dev), [i18next](https://www.i18next.com), [sonner](https://sonner.emilkowal.ski), [react-virtuoso](https://virtuoso.dev) | The window | MIT |
| [Font Awesome Free](https://fontawesome.com) 6 icons, through [react-icons](https://react-icons.github.io/react-icons/) (MIT) | The icons of each step of an install | CC BY 4.0 |

The crates and npm packages they bring are listed in [`installer/src-tauri/Cargo.lock`](installer/src-tauri/Cargo.lock) and [`installer/package-lock.json`](installer/package-lock.json).

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
