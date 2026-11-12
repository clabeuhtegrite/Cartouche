# Architecture

Cartouche puts everything a player needs on the iPhone into one app. This page describes its parts, how it gets installed and stays signed, how games get the memory they need, how they are installed, and how Cartouche updates itself. Choices and their reasons are in [decisions.md](decisions.md); milestones in [roadmap.md](roadmap.md).

## Parts

| Where | Part | Role |
| --- | --- | --- |
| iPhone | **Cartouche** | The one app the player installs |
| | LiveContainer (base) | Runs each game as a guest app, in a process of its own behind Cartouche's console or in Cartouche's place, and signs it with Cartouche's certificate |
| | SideStore (built in) | Signs in to the Apple account; installs, re-signs and renews Cartouche; asks for the memory capability |
| | Launcher | Catalogue of every supported game with the player's own first, import, compatibility sheets, memory probe, updates; the only screens the player sees, LiveContainer's and SideStore's never show |
| Player's own storage | A shared folder of their Mac, PC or NAS (SMB), a private S3 bucket, an FTP or SFTP server of theirs, or a folder in Files | Keeps the player's games, as IPAs Cartouche installs from there, and their saves, kept in step with each iPhone's, with the player's own account |
| iPhone | LocalDevVPN (App Store) | A loopback VPN through which SideStore reaches the phone's own services, so it needs no computer |
| Player's Mac, optional | Cartouche Builder | Builds the player's games with nxnative from their own files into their games folder, and builds a game again when a change to nxnative touches it ([builder/README.md](../builder/README.md)) |
| Computer, once | Cartouche Installer, for macOS and Windows | Installs the latest Cartouche, under its own App ID with the memory capability, gives it its certificate and puts the pairing file in it ([installer/README.md](../installer/README.md)) |
| Server | GitHub releases | Hold each version of the app, listed in the source the built-in SideStore reads |
| Server | GitHub Actions | Builds, checks and releases the app, with the publish guard in [`guard/`](../guard/) on every IPA and on the catalog |

Supported hardware follows nxnative: iOS 26 or later, an iPhone 15 Pro (A17 Pro) or newer, or an iPad with an M1 or newer. nxnative refuses an older GPU, which cannot read the BC-compressed textures that the games use (`dm/ios/Sources/main.m`), and an older build of nxnative stops at the game's first texture: players with an iPhone 13 Pro or an iPhone 15 installed games that closed at once, so Cartouche asks there before an install, and says so on every game's sheet ([decisions.md](decisions.md), 64). The interface adapts to each by size class, both displays and the fold of the iPhone Duo included ([launcher/README.md](../launcher/README.md#every-iphone-the-iphone-duo-included)).

## First install

A computer is needed once, because iOS lets nothing install a sideloaded app until one is already there.

1. On the iPhone, install LocalDevVPN from the App Store.
2. On a Mac or a Windows PC, the [Cartouche Installer](../installer/README.md) signs in to the player's Apple account, downloads the latest Cartouche from its release and checks it against Cartouche's source, and installs it under its own App ID with Increased Memory Limit. Its signing library, isideload, takes Cartouche for a LiveContainer+SideStore, since the built-in SideStore keeps SideStore's bundle identifier, and so writes its signing certificate inside it ([app/README.md](../app/README.md#identity)). The installer then puts the pairing file where the built-in SideStore reads it, through house arrest. It is a fork of [iloader](https://github.com/nab138/iloader), which installs Cartouche the same way with "Import IPA" but places pairing files only in the apps of its own list ([decisions.md](decisions.md), 25).
3. Cartouche opens on its guide to the first game, which begins with the setup: LocalDevVPN, then the sign-in, the pairing file already in place ([launcher/README.md](../launcher/README.md#setup)). With LocalDevVPN connected, the player signs in once with their Apple ID on Cartouche's own screen, and types the verification code Apple sends there too: the built-in SideStore signs in with it in LiveProcess, out of sight, as it renews Cartouche. SideStore registers the iPhone and takes the installer's certificate at sign-in, and Cartouche hands it to LiveContainer, which signs each game with it. From then on SideStore renews Cartouche without the computer.
4. The guide's next steps take the player to their first game: Cartouche Builder on a Mac, installed from its disk image, builds it into their games folder, and Cartouche installs it from there ([getting-started.md](getting-started.md)). A player whose games are built already, or who has no Mac, says No thanks to the Mac's step and goes on to their games folder, or imports an IPA.

The pairing file can also be dropped on Cartouche in Apple Devices, iTunes or the Finder (Files), as iloader's "Export" saves it, opened with Cartouche from AirDrop, Mail or Files, or chosen in the setup: Cartouche checks it and puts it at the same place. A Cartouche installed over a copy that had no certificate, such as 0.1.0, which had an app group of its own, needs to be installed again with the installer, over that copy: the App ID stays, and with it the games and the memory capability.

Cartouche's SideStore never revokes a certificate on its own, nor creates one when the account already has one ([app/patches/README.md](../app/patches/README.md#applied)). When it does not find the installer's, signing in stops and asks for the install with the installer. An install from another computer may revoke the certificate SideStore keeps: Cartouche finds that iOS refuses what LiveContainer signs with it, and has SideStore sign in again, which takes the installer's new one ([launcher/README.md](../launcher/README.md#setup)).

## Signing and renewal

A free Apple account signs apps for seven days, allows three sideloaded apps at a time and ten new App IDs in seven days.

- Cartouche is one app with one App ID. Games are guest apps inside it, signed on the phone with Cartouche's certificate (LiveContainer's signing without JIT), so they take no App ID and do not count against the limit of three. nxnative runs games natively and needs no JIT, so StikDebug is not needed either.
- The built-in SideStore renews Cartouche before it expires, with LocalDevVPN on: from the launcher's System page (**Renew now**), or every night from a Shortcuts automation that runs Cartouche's *Refresh All Apps* action, which the System page explains how to set up, since iOS lets no app create one. The launcher shows the days left and, once the player allows it, warns 24 hours and 6 hours before expiry ([launcher/README.md](../launcher/README.md#what-it-does)).
- Cartouche reuses the account's existing certificate when it can and never revokes one on its own: every app signed with a revoked certificate stops opening.

## Memory

iOS ends an app that goes over its memory limit. On a 12 GB iPhone (A20 Pro, iOS 27.3):

| Process | Measured | Limit |
| --- | --- | --- |
| an app without Increased Memory Limit | 4 November 2026 | 3,376 MiB |
| an app with Increased Memory Limit | 4 November 2026 | 6,143 MiB |
| Cartouche 0.10.0, with Increased Memory Limit and Game Mode | 10 November 2026 | 8,192 MiB |
| a game behind the console, in LiveContainer's LiveProcess extension, with Increased Memory Limit | 10 November 2026 | 6,144 MiB |

Mario Kart World peaked at 5,404 to 6,074 MiB in our trials on that iPhone, so the bigger games need the capability. It belongs to the App ID, and Cartouche's App ID is new, so Cartouche must turn it on itself:

- On a free account, SideStore enables only app groups and inter-app audio on an App ID, so the capability is dropped ([SideStore#1616](https://github.com/SideStore/SideStore/issues/1616)).
- AltStore 2.3 and GetMoreRam enable it on free accounts through the developer services API's bundle ID capabilities request.
- Cartouche patches SideStore and its signing library, SideSign, to make that request when they register or update Cartouche's App ID, so that the provisioning profile, and then the app, carry `com.apple.developer.kernel.increased-memory-limit`.

The launcher measures the real limit at start-up (footprint plus `os_proc_available_memory()`) and compares it with each game's measured peak. The debugging memory entitlement is out of reach of a free account through SideStore and is not pursued.

Game Mode, which Cartouche turns on from 0.10.0 ([decisions.md](decisions.md), 38), came with 2 GiB more: the player found 8,192 MiB on the System page, where the same iPhone, on the same iOS, gave Cartouche 6,143 before. The game's process behind the console kept 6,144 MiB: LiveContainer's extension has no Game Mode keys of its own. [`app/scripts/package.sh`](../app/scripts/package.sh) gives it Cartouche's, and whether its limit rises too is measured on the iPhone with the next version.

Behind the console ([decisions.md](decisions.md), 38), a game runs in LiveContainer's LiveProcess extension, a process of its own with a limit of its own. The extension's entitlements ask for Increased Memory Limit, as Cartouche's do, and SideStore makes the same request for each App ID it signs an app with, extensions included; what the process gets is iOS's to say. The game's process writes its footprint, its peak and its limit every two seconds, with the sizes of its screen ([`CartoucheGuest.m`](../launcher/LiveProcessSupport/CartoucheGuest.m), in `Cartouche/GameMemory.plist` of the app group), and the System page shows the limit. Cartouche compares that limit with its own instead of assuming which is higher ([`CartoucheGamePlace.swift`](../launcher/Sources/CartoucheGamePlace.swift), [decisions.md](decisions.md), 48). While its own is higher, as with Game Mode, a game that needs more than it has behind the console starts in Cartouche's place, with all of Cartouche's memory: one whose peak, by its sheet, leaves it less room under the limit there than Cartouche counts as near it (an eighth of the limit, and at least 512 MiB); one that needs Increased Memory Limit and has no peak on its sheet, as Mario Kart World; and from then on one iOS stopped there close to its limit. One that needs more and started behind the console starts again in Cartouche's place at once. When the game's process has as much as Cartouche, or more, every game stays behind the console, a game iOS stopped there for its memory is told that it would have no more in Cartouche's place, and a game's sheet compares its peak with the higher of the two limits.

The game's process also writes whether it has Increased Memory Limit, as its signature gives it (`increasedMemoryLimit`, read with Security's `SecTaskCopyValueForEntitlement`, [decisions.md](decisions.md), 64). Some installs signed it without: on an iPhone Duo where Cartouche had 8,192 MiB, the game's process had 6,144 with one version and 3,376 with the next, and iOS stopped Donkey Kong Bananza, which has no sheet, within two seconds there, four times; an iPhone 13 Pro lost it the same way. Cartouche keeps the answer of the last game behind the console with the install it came from: while that process lacks the capability and Cartouche's own limit is higher, every game but one whose peak fits there starts in Cartouche's place, and one that iOS stopped there before its first measurement, on screen, starts again in Cartouche's place at once. Another install of Cartouche signs the process again, and the next game tries behind the console; so does **Try behind Cartouche again**, on the System page and on a game's sheet. Why some installs lose it is still to find.

## Games

The player builds a game's IPA on a Mac with nxnative's `scripts/build_ipa_from_nsp.py` (or a Mac app built on it) from their own dump, then imports it into Cartouche from Files, iCloud Drive, a USB-C drive, a network share or their games folder. Cartouche Builder does it for a whole library: it builds each game into the games folder, and builds it again when nxnative changes its profile or a fix names it, or once a week for nxnative's shared code ([builder/README.md](../builder/README.md#when-a-game-is-built-again)). Cartouche installs it as a guest app and signs it, on its own screens, and starts it without nxnative's settings screen, with the choices the game's settings page in Cartouche saved where nxnative reads them, behind its console when the game has the memory there: the console then comes back over the game, paused, at the press of a Home button, and the game comes back where it was. Big games are built with `--romfs separate`, and their RomFS goes into the guest app's Documents folder. When the games folder holds a newer build of an installed game, a later version or a build from another nxnative commit made after it, Cartouche offers to install it over the game, which keeps its settings and saves ([decisions.md](decisions.md), 30).

Cartouche does not build games, and carries nothing of nxnative's build tools ([decisions.md](decisions.md), 28), until building on the iPhone comes ([roadmap.md](roadmap.md#later), 55); Cartouche Builder is a program of its own, on the Mac, never part of the app or its releases (29). What it knows of nxnative's games is the list of their profiles at a pinned commit ([catalog/README.md](../catalog/README.md)).

## Updates

Each version of Cartouche is a GitHub release of this repository, and is listed, with its size and SHA-256, in the source the built-in SideStore reads, [`app/sidestore-source.json`](../app/sidestore-source.json). Cartouche offers a version higher than its own over the console and on its System page, and has the built-in SideStore install it without showing SideStore ([app/releases/README.md](../app/releases/README.md)). The release workflow runs the publish guard on the IPA before attaching it, and the source entry goes to main through a pull request of its own.

The game sheets, device profiles and nxnative's list of games are carried inside the app ([catalog/README.md](../catalog/README.md)), so a new version of Cartouche brings new ones. The games' covers are carried too, and Cartouche also reads a newer list of them every day, which the Live covers workflow keeps on the branch `live-covers`: the covers of the games nxnative added since the version, which a game of the player's finds by its title ID, and those IGDB had none for yet ([decisions.md](decisions.md), 33).

## Privacy

Cartouche sends none of the player's games or saves: they go only to the storage they set up themselves, with their own account, and the password stays in the iPhone's keychain. What it reads from this repository, its source and the newest covers, is the same for every player, and reading it sends nothing about the player's games. It sends game measurements, unless the player turns them off on the System page ([decision 35](decisions.md)): after each game session, the numbers nxnative wrote in the game's log, read on the iPhone into a report of the session ([`CartoucheGameLog.swift`](../launcher/Sources/CartoucheGameLog.swift)), and Cartouche's own events, to the project's telemetry server, a Cloudflare Worker and its D1 database in the EU jurisdiction ([telemetry/README.md](../telemetry/README.md)). A report carries the iPhone's model and iOS and a random number of this copy of Cartouche, and never a line of a log, a file, the Apple ID or anything of the player's storage. What is sent and kept, and for how long: [privacy.md](privacy.md).
