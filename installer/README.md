# Cartouche Installer

The app that puts Cartouche on an iPhone from a Mac or a Windows PC, the one time a computer is needed. In three steps on one window, it:

1. finds the iPhone plugged into the computer, and pairs with it the first time (the iPhone asks to trust the computer);
2. signs in to the player's Apple account, a free one being enough, with the two-factor code when Apple asks for it;
3. downloads the latest Cartouche from its GitHub release, checks its size and SHA-256 against Cartouche's source ([`app/sidestore-source.json`](../app/sidestore-source.json)), signs and installs it under its own App ID with Increased Memory Limit, writes the signing certificate into its built-in SideStore, and puts the pairing file where Cartouche reads it (`Documents/SideStore/Documents/ALTPairingFile.mobiledevicepairing`).

Cartouche then opens on its setup with the pairing file and the certificate in place: the player only signs in to the built-in SideStore ([launcher/README.md](../launcher/README.md#setup)). Installing again over Cartouche keeps its App ID, its games and their saves, and updates it to the latest release.

The window also installs Cartouche from an IPA of Cartouche on the computer, and puts the pairing file in Cartouche again, after the iPhone was erased or its stored pairing deleted. Settings hold the language (English or French), the anisette server, the account's certificates and App IDs, the logs, and the pairing stored for the selected iPhone.

It installs nothing but Cartouche: an IPA whose bundle identifier is not Cartouche's is refused, and it never downloads anything but Cartouche's own releases.

## Download and first open

Download it [for Mac](https://clabeuhtegrite.github.io/Cartouche/download/#installer-mac) or [for Windows](https://clabeuhtegrite.github.io/Cartouche/download/#installer-windows): these links, like the buttons of [Cartouche's site](https://clabeuhtegrite.github.io/Cartouche/#install), give the file itself, at once.

Each version is the GitHub release `installer-v<version>`, published without GitHub's *Latest* mark, which is meant for Cartouche. While Cartouche's versions are 0.x pre-releases, GitHub still gives that mark to the newest release that is not one, the Installer's or Cartouche Builder's. Nothing reads it: the installer and Cartouche take Cartouche's newest version from its source, and the site takes the Installer's and the Builder's from their releases each time it is published ([site/README.md](../site/README.md#publishing)).

| Computer | File | First open |
| --- | --- | --- |
| Mac, Apple silicon or Intel, macOS 11 or later | `Cartouche-Installer-<version>-Mac.dmg` | The app is signed ad hoc and not notarized, so macOS says it cannot check it. Open **System Settings › Privacy & Security**, and click **Open Anyway** next to Cartouche Installer, once. |
| Windows 10 or 11, x64 | `Cartouche-Installer-<version>-Windows.exe` | SmartScreen may stop the setup, which is not signed: **More info › Run anyway**. The setup installs for the current user, with no administrator rights. Windows talks to an iPhone only with **Apple Devices** from the Microsoft Store, or iTunes, installed. |

On the iPhone, install LocalDevVPN from the App Store before or after: the built-in SideStore needs it to renew Cartouche without a computer ([docs/architecture.md](../docs/architecture.md#first-install)).

## How it is built

The installer is a fork of [iloader](https://github.com/nab138/iloader) by nab138 (MIT), version 2.4.1: the same [Tauri](https://tauri.app) app, with a Rust backend that signs and installs through [isideload](https://crates.io/crates/isideload) and talks to the iPhone through [idevice](https://crates.io/crates/idevice), and a React window. What changed:

- **Cartouche only.** [`src-tauri/src/cartouche.rs`](src-tauri/src/cartouche.rs) reads Cartouche's source, downloads its newest release with a progress bar and checks it, finds Cartouche on the iPhone by its bundle identifier, with or without the team appended, and places the pairing file in it. iloader's list of apps, its other installs and its pairing page are gone.
- **Increased Memory Limit and the certificate.** isideload asks for the capability on Cartouche's App ID, and takes Cartouche for a LiveContainer+SideStore by its `com.SideStore.SideStore` framework, so it writes the certificate into it ([app/README.md](../app/README.md#identity)).
- **One window of three steps**, with Cartouche's icon and colours, in English and French ([`src/locales`](src/locales)). The account's password stays in the computer's keychain, when there is one.
- **No updater.** The window shows its version; a new one is a new release.
- **Names of its own:** the app `Cartouche Installer`, the identifier `io.github.clabeuhtegrite.cartouche.installer`, its own keychain service and its own label on the pairing records and certificates it makes. iloader's name and logos are its author's ([iloader's LICENSE-BRANDING](https://github.com/nab138/iloader/blob/main/LICENSE-BRANDING)); the installer uses neither.

The crates are the ones of iloader's `Cargo.lock`, less those of its updater and process plugins, with `sha2`, `hex` and `zip` taken from the same lockfile's versions.

## Developing

With Node.js 22, Rust stable, and on Linux the WebKitGTK libraries (`libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libdbus-1-dev`):

```
cd installer
npm ci
npx tauri dev                 # the app, reloading as the window's code changes
npm run build                 # the window only: TypeScript, then Vite
(cd src-tauri && cargo test --locked)
```

On Windows, isideload's cryptography needs Strawberry Perl, make, and the Visual Studio build tools' environment, as in iloader's own build.

## CI and publishing

[`.github/workflows/installer.yml`](../.github/workflows/installer.yml) runs on every pull request that touches `installer/` or Cartouche's source, which its tests read: on a Mac, the tests, then the app for Apple silicon and Intel in a disk image; on Windows, the setup. Both are kept with the run for 30 days.

To publish a version:

1. In a pull request, raise the version in [`src-tauri/tauri.conf.json`](src-tauri/tauri.conf.json), which names the release, in [`src-tauri/Cargo.toml`](src-tauri/Cargo.toml) then `Cargo.lock` (`cargo update -p cartouche-installer`), and in `package.json` and its lockfile (`npm version <version> --no-git-tag-version`), and write the notes of the release in [`RELEASE.md`](RELEASE.md).
2. Once it is merged, which starts the [Full test pass](../.github/full-pass/README.md), every test of the repository, run **Actions › Installer › Run workflow** on `main` with **Publish** ticked. The workflow builds both and, once the full test pass has passed on that commit, publishes them as the release `installer-v<version>`, never marked as the latest, and publishes the site again, whose buttons and download page then give this version. It stops if that release exists already, or if the pass fails.

## Licence

MIT, as iloader: [LICENSE](LICENSE), with iloader's copyright notice kept. The rest of Cartouche is under the AGPL-3.0. The Cartouche Installer is not affiliated with iloader or Apple.
