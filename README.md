# Cartouche

Cartouche is an iOS app that turns an iPhone into a console for the games [nxnative](https://github.com/seedds/nxnative) runs natively, from your own copies of those games. It installs, starts and keeps your games, signs and renews itself, and gets them the memory they need. A computer is needed once, for the first install.

> **Status: test builds (0.x).** Each version is a [GitHub release](https://github.com/clabeuhtegrite/Cartouche/releases), and Cartouche offers the next ones itself. What comes next: [docs/roadmap.md](docs/roadmap.md).

## What it does

- **A console's home.** Your games and the games nxnative plays on an iPhone, as cartridges on two shelves with their official covers, every game of nxnative's list one step away, a sheet for each game that says how it runs on your iPhone, and touch or a game controller throughout.
- **Your games, installed and started in Cartouche.** Import an IPA you built with nxnative, play it, change its nxnative settings on a page of Cartouche's own, uninstall it. Games run inside Cartouche as guest apps, so they do not count against a free Apple account's limit of three sideloaded apps.
- **Your own storage.** Keep your games and saves on a shared folder of your Mac, PC or NAS, or a folder in Files, with your own account: the games there show in the library, ready to install, and your saves are copied after each game.
- **Signed and renewed by itself.** The built-in SideStore renews Cartouche's seven-day signature from the System page or every night from a Shortcuts automation, and Cartouche warns before it expires.
- **The memory games need.** Cartouche's App ID gets Increased Memory Limit, about 6 GiB instead of 3.3 GiB on a 12 GB iPhone, on a free account.
- **Updates from the iPhone.** Cartouche offers its new versions over the console, and the built-in SideStore installs them.
- **Every iPhone, the Duo included.** The interface follows the space it has, folded or unfolded, and keeps clear of the fold and the cameras.

You never see LiveContainer or SideStore, which Cartouche is built on: it drives them out of sight.

## Install

1. On the iPhone, install **LocalDevVPN** from the App Store: the built-in SideStore needs it to renew Cartouche without a computer.
2. On a Mac or a Windows PC, download the **Cartouche Installer** from its latest [`installer-v…` release](https://github.com/clabeuhtegrite/Cartouche/releases), plug in the iPhone, sign in with your Apple account (a free one is enough) and install. It puts the latest Cartouche on the iPhone with its certificate, the memory capability and the pairing file ([installer/README.md](installer/README.md)).
3. Open Cartouche and follow its setup.

Supported: iOS 26 or later on an iPhone 15 Pro or newer, or an iPad with an M1 or newer, as nxnative. The bigger games need a 12 GB iPhone.

## What it does not do

Cartouche ships no games, no keys and no firmware, and never downloads them: it has no catalogue of downloadable games, no link to one, and no public storage. You import games you own and built yourself. See [LEGAL.md](LEGAL.md).

## Repository

| Path | What it holds |
| --- | --- |
| [`app/`](app/) | The iOS app: LiveContainer and SideStore at pinned commits, our patches, the build scripts, the releases and their source |
| [`launcher/`](launcher/) | Cartouche's own screens: the console, the game sheets, the player's storage, setup, renewal and updates |
| [`installer/`](installer/) | The Cartouche Installer for macOS and Windows, a fork of iloader |
| [`catalog/`](catalog/) | What the app knows about games and devices: nxnative's list of games, covers' IDs, compatibility sheets, device memory limits |
| [`guard/`](guard/) | The publish guard, which refuses to publish anything that looks like game content |
| [`docs/`](docs/) | Architecture, roadmap, decisions |

## Building

The app builds on a Mac with Xcode 27.2 and Homebrew:

```
git clone --recursive https://github.com/clabeuhtegrite/Cartouche.git && cd Cartouche
brew install ldid
app/scripts/build.sh          # writes build/app/Cartouche.ipa, unsigned
```

CI builds it on every pull request that touches the app and attaches the unsigned IPA to the run; a pull request that touches the launcher also gets screenshots of every screen. How a release is cut: [app/releases/README.md](app/releases/README.md). More in [app/README.md](app/README.md) and [docs/architecture.md](docs/architecture.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

## Licence

Cartouche is free software under the [GNU Affero General Public License v3.0](LICENSE), the licence of LiveContainer and SideStore, which it builds on; the Cartouche Installer is under iloader's MIT licence. Third-party components: [NOTICE.md](NOTICE.md).

Cartouche is not affiliated with Nintendo, Apple, or the LiveContainer, SideStore, iloader and nxnative projects.
