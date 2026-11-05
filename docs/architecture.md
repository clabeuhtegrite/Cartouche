# Architecture

Cartouche puts everything a player needs on the iPhone into one app. This page describes its parts, how it gets installed and stays signed, how games get the memory they need, how games are built, and how updates work. Choices and their reasons are in [decisions.md](decisions.md); milestones in [roadmap.md](roadmap.md).

## Parts

| Where | Part | Role |
| --- | --- | --- |
| iPhone | **Cartouche** | The one app the player installs |
| | LiveContainer (base) | Runs each game as a guest app inside Cartouche and signs it with Cartouche's certificate |
| | SideStore (built in) | Signs in to the Apple account; installs, re-signs and renews Cartouche; asks for the memory capability |
| | Launcher | Library, import, compatibility sheets, memory probe, updates |
| | Build pipeline (v2) | Builds a game on the phone from the player's own dump |
| iPhone | LocalDevVPN (App Store) | A loopback VPN through which SideStore reaches the phone's own services, so it needs no computer |
| Computer, once | iloader | Installs Cartouche and places the pairing file |
| Server | Cloudflare R2 bucket, public read | Holds the signed manifest and the chunks of the app, engine builds, tools and sheets |
| Server | GitHub Actions | Builds the app and the engine builds, publishes them with the tools in [`server/`](../server/) |

Supported hardware follows nxnative: iOS 26 or later, an iPhone 15 Pro (A17 Pro) or newer, or an iPad with an M1 or newer.

## First install

A computer is needed once, because iOS lets nothing install a sideloaded app until one is already there.

1. On the iPhone, install LocalDevVPN from the App Store.
2. On a computer (Windows, macOS or Linux), [iloader](https://github.com/nab138/iloader) signs in to the player's Apple account, installs Cartouche and places the pairing file that lets SideStore talk to the phone later.
3. Cartouche opens on the phone. Its SideStore signs in to the same account and takes over: from now on it renews Cartouche without the computer.

iloader handles LiveContainer with SideStore today: it imports the account's certificate into SideStore and places the pairing file where SideStore looks for it. Cartouche needs the same, either by iloader recognising Cartouche (a small contribution to iloader) or by Cartouche importing both from files. Phase 1 settles which.

## Signing and renewal

A free Apple account signs apps for seven days, allows three sideloaded apps at a time and ten new App IDs in seven days.

- Cartouche is one app with one App ID. Games are guest apps inside it, signed on the phone with Cartouche's certificate (LiveContainer's signing without JIT), so they take no App ID and do not count against the limit of three. nxnative runs games natively and needs no JIT, so StikDebug is not needed either.
- The built-in SideStore renews Cartouche before it expires, in the background (App Intents, Shortcuts automation, background tasks), with LocalDevVPN on. The launcher shows the days left and warns early.
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
