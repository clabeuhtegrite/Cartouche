# Cartouche

Cartouche is an all-in-one iOS app for playing the games that [nxnative](https://github.com/seedds/nxnative) supports on an iPhone, from your own copies of those games. It brings the pieces that sideloading needs today into one app that sets itself up and keeps itself signed, so that a computer is needed only once, for the first install.

> **Status: early development.** Nothing can be installed yet. The milestones are in [docs/roadmap.md](docs/roadmap.md).

## What Cartouche will do

- **One app to install.** Cartouche is built on [LiveContainer](https://github.com/LiveContainer/LiveContainer) with [SideStore](https://github.com/SideStore/SideStore) built in. Games run inside it as guest apps, so they do not count against a free Apple account's limit of three sideloaded apps. Besides Cartouche, a player installs only LocalDevVPN from the App Store, which SideStore needs to install and refresh apps without a computer.
- **Keeps itself signed.** The built-in SideStore renews the seven-day signature of a free account in the background.
- **Gets games the memory they need.** On a 12 GB iPhone, an app may use about 3.3 GiB by default and about 6.0 GiB with the Increased Memory Limit capability on its App ID (3,376 and 6,143 MiB, measured on an A20 Pro). SideStore does not request that capability for free accounts today ([SideStore#1616](https://github.com/SideStore/SideStore/issues/1616)); Cartouche's SideStore will.
- **A catalogue.** A console-style catalogue of every game Cartouche supports, with your own games first and featured, and a sheet for each game that says how it runs on your iPhone: the memory it needs against the limit Cartouche measures on the phone, the recommended settings, what testers saw. Games you do not have offer one thing only: importing your own copy.
- **Your own storage.** Your games and saves on a shared folder of your Mac, PC or NAS, or a folder in Files, with your own account: the games there show in the catalogue, ready to install again, and your saves are copied after each game.
- **Every iPhone, the Duo included.** The interface follows the space it has: one column on an iPhone or a folded iPhone Duo, the catalogue and a game's sheet together on an unfolded Duo or an iPad, and nothing in the fold or under a camera ([details](launcher/README.md#every-iphone-the-iphone-duo-included)).
- **Updates.** The app, the nxnative engine builds and the compatibility sheets update automatically from a signed manifest.

## What it does not do

Cartouche ships no games, no keys and no firmware, and it never downloads them. You import games you own and dumped yourself, from Files, iCloud Drive, a USB-C drive, a network share or your own storage. See [LEGAL.md](LEGAL.md).

## How it works

```
 Computer, once           iPhone                                   Update server (R2)
 ──────────────           ─────────────────────────────────        ──────────────────
 Cartouche          ──▶   Cartouche                                signed manifest
 Installer puts it,       ├─ launcher: catalogue, sheets, probe ◀─ app, engine builds,
 with its own App ID      ├─ SideStore: sign, install, renew       tools, sheets
 and its pairing file     ├─ build pipeline (v2)                   (never games)
                          └─ games, as guest apps
                          LocalDevVPN (App Store)
```

- **v1** plays games built on a Mac with nxnative's own script: you import the IPA into Cartouche.
- **v2** builds the game on the iPhone from your own dump, with an engine build that our CI makes from nxnative's source for each supported game.

Details: [docs/architecture.md](docs/architecture.md). Decisions and their reasons: [docs/decisions.md](docs/decisions.md).

## Repository layout

| Path | What it holds |
| --- | --- |
| [`app/`](app/) | The iOS app: LiveContainer and SideStore at pinned commits, our patches, the build scripts |
| [`installer/`](installer/) | The Cartouche Installer: the Mac and Windows app that installs Cartouche the first time, a fork of iloader |
| [`launcher/`](launcher/) | The launcher: the catalogue of games, their sheets, the player's storage, the memory probe, and the signature's days left and renewal |
| [`engine/`](engine/) | How the nxnative engine will be built for each supported game (planned) |
| [`catalog/`](catalog/) | Device profiles and per-game compatibility sheets, with their schemas |
| [`server/`](server/) | Tools that publish the signed update manifest and its chunks, and refuse anything that looks like game content |
| [`docs/`](docs/) | Architecture, roadmap, decision log |

## Building

The app builds on a Mac with Xcode 27.2 and Homebrew:

```
git clone --recursive https://github.com/clabeuhtegrite/Cartouche.git && cd Cartouche
brew install ldid
app/scripts/build.sh          # writes build/app/Cartouche.ipa, unsigned
```

CI builds it on every pull request that touches `app/`, `launcher/` or `catalog/` and attaches the unsigned IPA to the workflow run. These are development builds: they have their own bundle identifier, so they never replace an installed LiveContainer, but they are not ready to use yet.

The server tools need Python 3.11 or newer:

```
python3 -m venv .venv && .venv/bin/pip install -e "server[dev]"
.venv/bin/python -m unittest discover -s server/tests -t server/tests
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

## Licence

Cartouche is free software under the [GNU Affero General Public License v3.0](LICENSE), the licence of LiveContainer and SideStore, which it builds on. Third-party components and their licences: [NOTICE.md](NOTICE.md).

Cartouche is not affiliated with Nintendo, Apple, or the LiveContainer, SideStore and nxnative projects.
