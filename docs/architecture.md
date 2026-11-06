# Architecture

Cartouche puts everything a player needs on the iPhone into one app. This page describes its parts, how it gets installed and stays signed, how games get the memory they need, how games are built, and how updates work. Choices and their reasons are in [decisions.md](decisions.md); milestones in [roadmap.md](roadmap.md).

## Parts

| Where | Part | Role |
| --- | --- | --- |
| iPhone | **Cartouche** | The one app the player installs |
| | LiveContainer (base) | Runs each game as a guest app inside Cartouche and signs it with Cartouche's certificate |
| | SideStore (built in) | Signs in to the Apple account; installs, re-signs and renews Cartouche; asks for the memory capability |
| | Launcher | Catalogue of every supported game with the player's own first, import, compatibility sheets, memory probe, updates |
| | Build pipeline (v2) | Builds a game on the phone from the player's own dump |
| iPhone | LocalDevVPN (App Store) | A loopback VPN through which SideStore reaches the phone's own services, so it needs no computer |
| Computer, once | iloader | Installs Cartouche, under its own App ID with the memory capability |
| Server | Cloudflare R2 bucket, public read | Holds the signed manifest and the chunks of the app, engine builds, tools and sheets |
| Server | GitHub Actions | Builds the app and the engine builds, publishes them with the tools in [`server/`](../server/) |

Supported hardware follows nxnative: iOS 26 or later, an iPhone 15 Pro (A17 Pro) or newer, or an iPad with an M1 or newer. The interface adapts to each by size class, both displays and the fold of the iPhone Duo included ([launcher/README.md](../launcher/README.md#every-iphone-the-iphone-duo-included)).

## First install

A computer is needed once, because iOS lets nothing install a sideloaded app until one is already there.

1. On the iPhone, install LocalDevVPN from the App Store.
2. On a computer (Windows, macOS or Linux), [iloader](https://github.com/nab138/iloader) signs in to the player's Apple account and installs Cartouche with "Import IPA", under its own App ID with Increased Memory Limit and with its own app group.
3. Cartouche opens on the phone. Its SideStore gets the pairing file that lets it talk to the phone and the account's certificate (below), signs in to the same account and takes over: from now on it renews Cartouche without the computer.

iloader installs Cartouche as an ordinary app. It would take an app with SideStore's bundle identifier inside for a LiveContainer+SideStore, and give it the app group and keychain groups that every LiveContainer+SideStore of the account shares, so Cartouche's built-in SideStore has a bundle identifier of its own ([app/README.md](../app/README.md#identity)). In return, iloader neither places the pairing file nor gives its certificate to Cartouche's SideStore, which gets both on the phone:

- **From another SideStore on the iPhone**, such as the one inside a LiveContainer+SideStore: in the onboarding, "Import from SideStore" asks it for its pairing file, and "Import the Certificate from SideStore" for its certificate, before signing in. The other SideStore asks the player to confirm the export of its certificate, and Cartouche's to confirm each import. Both then sign with the same certificate, and nothing is created or revoked.
- **Without one:** iloader exports the pairing file to the computer, and the player imports that file in the onboarding. Cartouche's SideStore creates a certificate only for an account that has none, and the account already has iloader's. If that certificate signs nothing but Cartouche, the player can revoke it by hand in Settings → Advanced Settings → Certificate Management and let Cartouche's SideStore create its own, then refresh Cartouche right away, before closing it: an app signed with a revoked certificate no longer opens.

Cartouche's SideStore never revokes a certificate on its own, nor creates one when the account already has one ([app/patches/README.md](../app/patches/README.md#applied)).

## Signing and renewal

A free Apple account signs apps for seven days, allows three sideloaded apps at a time and ten new App IDs in seven days.

- Cartouche is one app with one App ID. Games are guest apps inside it, signed on the phone with Cartouche's certificate (LiveContainer's signing without JIT), so they take no App ID and do not count against the limit of three. nxnative runs games natively and needs no JIT, so StikDebug is not needed either.
- The built-in SideStore renews Cartouche before it expires, with LocalDevVPN on: from the launcher's System tab (**Renew now**), or every night from a Shortcuts automation that runs Cartouche's *Refresh All Apps* action, which the System tab explains how to set up, since iOS lets no app create one. The launcher shows the days left and, once the player allows it, warns 24 hours and 6 hours before expiry ([launcher/README.md](../launcher/README.md#what-the-first-build-does)).
- Cartouche reuses the account's existing certificate when it can and never revokes one on its own: every app signed with a revoked certificate stops opening.

## Memory

iOS ends an app that goes over its memory limit. On a 12 GB iPhone (A20 Pro, iOS 27.3, measured on 4 November 2026):

| App ID | Limit |
| --- | --- |
| without Increased Memory Limit | 3,376 MiB |
| with Increased Memory Limit | 6,143 MiB |

Mario Kart World peaked at 5,404 to 6,074 MiB in our trials on that iPhone, so the bigger games need the capability. It belongs to the App ID, and Cartouche's App ID is new, so Cartouche must turn it on itself:

- On a free account, SideStore enables only app groups and inter-app audio on an App ID, so the capability is dropped ([SideStore#1616](https://github.com/SideStore/SideStore/issues/1616)).
- AltStore 2.3 and GetMoreRam enable it on free accounts through the developer services API's bundle ID capabilities request.
- Cartouche patches SideStore and its signing library, SideSign, to make that request when they register or update Cartouche's App ID, so that the provisioning profile, and then the app, carry `com.apple.developer.kernel.increased-memory-limit`.

The launcher measures the real limit at start-up (footprint plus `os_proc_available_memory()`) and compares it with each game's measured peak. The debugging memory entitlement is out of reach of a free account through SideStore and is not pursued.

## Games

### v1: import a game built on a Mac

The player builds the IPA on a Mac with nxnative's `scripts/build_ipa_from_nsp.py` (or a Mac app built on it) from their own dump, then imports it into Cartouche from Files, iCloud Drive, a USB-C drive or a network share. Cartouche installs it as a guest app and signs it. Big games are built with `--romfs separate`, and their RomFS goes into the guest app's Documents folder.

### v2: build on the iPhone

nxnative builds a game in steps: read the dump (LibHac), rewrite the game's code for the Apple chip (`patch_nso.py`, with capstone), translate the shaders (Ryujinx's translator to SPIR-V, SPIRV-Cross to Metal Shading Language, then Metal), and link the app with Xcode. On the phone:

- reading the dump and translating shaders run as .NET code compiled ahead of time (NativeAOT for iOS); rewriting runs on CPython for iOS (PEP 730) with capstone;
- Metal compiles shader source at run time, so no offline compiler is needed;
- iOS has no linker, so the engine host is not linked on the phone. Our CI builds it from nxnative's source for each supported game (nxnative builds a host per game, `make GAME=<title ID>`), with none of the game in it. The phone writes the rewritten modules into a Mach-O framework, Cartouche signs it, and the host loads it through nxnative's `dm_set_game_image_header()`, which exists for apps that link the modules into a framework instead of the executable.

Spikes S2 to S4 in the roadmap test each step before v2 is built.

## Updates

The server publishes, per channel (for example `stable`):

```
channels/<channel>/manifest.json        what is available: artifacts and their chunks
channels/<channel>/manifest.json.sig    Ed25519 signature of manifest.json
chunks/<aa>/<sha256>                    chunk bytes, named by their SHA-256
```

- Artifacts are of five kinds only: `app`, `engine-host`, `toolchain`, `pipeline-list`, `catalog`. There is no kind for games, and the publish guard refuses files that look like game content, keys or firmware, Mach-O images carrying a game's rewritten code, IPAs with another bundle identifier, and URLs in catalog files.
- Files are cut into chunks of 1 to 8 MiB with content-defined chunking (FastCDC), so a new engine build shares most chunks with the previous one, and engine builds of different games share most of theirs.
- The app pins the public key, checks the signature, refuses a manifest whose `sequence` is lower than the last one it accepted, downloads only the chunks it lacks and checks each one's SHA-256.
- App updates are installed by the built-in SideStore; engine builds, tools and sheets are applied by the launcher.

The format and tools are in [`server/`](../server/).

## Privacy

Cartouche sends nothing about the player's games. Telemetry is planned as opt-in anonymous reports (device model, iOS version, game title ID, memory peak, crash signature), with no account data and no files.
