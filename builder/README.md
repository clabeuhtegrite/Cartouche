# Cartouche Builder

Cartouche Builder is a Mac app that builds your own games into IPAs with [nxnative](https://github.com/seedds/nxnative), puts them in the games folder Cartouche reads, and builds a game again when a change to nxnative makes it better. Cartouche on the iPhone then sees the newer IPA and offers to update the game. The games folder can be on the Mac or on your NAS, and the Mac itself can be Cartouche's storage: Cartouche finds it on the Wi-Fi, pairs once with a code both screens show, and installs your games from it and keeps your saves there.

It runs nxnative's own build script, as nxnative's [front-end page](https://github.com/seedds/nxnative/blob/main/docs/frontends.md) describes, and adds what a library of games needs: each game followed with what nxnative changed for it, a plan that says which games are due and why, a batch that builds them one after the other, and a nightly run.

## Install

[Download Cartouche Builder](https://clabeuhtegrite.github.io/Cartouche/download/#builder), or use the button on [Cartouche's site](https://clabeuhtegrite.github.io/Cartouche/#builder): the disk image downloads at once. Open it, and drag **Cartouche Builder** onto **Applications**. The app is signed ad hoc, not by Apple: the first time, macOS says it cannot check it. Open **System Settings › Privacy & Security** and click **Open Anyway** beside Cartouche Builder, once. Its updates open without asking again.

At its first start a setup assistant opens, with no Terminal, and opens again at each start until it is gone through to its end. Nothing is chosen for you: every folder starts empty, and the app reads nothing another app left on the Mac. Its steps, on the left with what is done and what is missing; each choice is saved as you make it, and all of them can be changed later in the settings, where **Advanced › Open the setup assistant** opens it again:

1. **Welcome:** what the app does.
2. **This Mac's tools:** what nxnative builds with, checked and installed for you. Xcode 27.2 comes from the App Store, with Apple's licence, which the app opens for you; Homebrew from its own installer, which asks for your Mac's password; then `xcodegen`, `zstd` and `glslang`, Python 3.12 or later, Xcode's iOS platform and Metal toolchain, nxnative and its Python environment, in the background. The next steps can be done while they install. Since its commit 641636e2 (10 November 2026) nxnative needs no .NET.
3. **Your dumps:** the folder your games are in, loose or in folders, on the Mac or on your NAS, with the number of games found in it.
4. **Games folder:** where the IPAs go, on the Mac (the assistant can create `Cartouche Games` in your home folder) or on your NAS. For a NAS, type its share's address (`smb://…`) and the Finder connects it, then choose the folder in it.
5. **Keys:** `prod.keys`, for games given as packages only.
6. **At night:** whether to build what is due every night, and when; notifications.
7. **iPhone:** whether the Mac shares its games and saves with Cartouche ([The iPhone](#the-iphone)), how to pair it, and opening at login.
8. **Ready:** what each step chose, with a button back to it.

A Mac that builds nxnative games has Apple silicon and macOS 26.6 or later. The step by step guide, from the iPhone to the first game: [docs/getting-started.md](../docs/getting-started.md#2-build-your-game-on-your-mac).

## The app

- **Library:** your games with their covers: those in the sources folder, and those whose IPA alone is in the games folder, such as games built before. Each says whether it is up to date, due for a rebuild and why, built at night, or failed and what failed. A game's sheet shows what nxnative changed for it since its build, its IPA, its build folder, **Build**, **Rebuild** or **Build again**, whether it is followed, and the other names of the game in nxnative's commits. **Rebuild what is due** builds every game nxnative improved.
- **Builds:** the batch under way, game by game and stage by stage, its queue, and the ones before, with their logs.
- **Storage:** what the builder keeps on the Mac, and how to free it.
- **iPhone:** the bridge to Cartouche, its two folders and the iPhones paired.
- **This Mac's tools:** each tool, installed or missing, and an install for what is missing.
- **Settings** (⌘,): the folders and `prod.keys`, the rebuilds when nxnative's shared code changes, the nightly run, how many games build at once, the games' language, the disk the builds may use, notifications, the menu bar, opening at login, updates and measures.

The menu bar shows a build under way, the games nxnative improved and an update ready; notifications say when a batch ends and when nxnative improves one of your games.

### Import an IPA with separate game data

For an existing nxnative IPA that expects an external `romfs.img`, choose
**Import IPA + ROMFS…** in Library. Select the IPA and its matching image,
then **Create complete IPA**. This needs Python, but no Xcode, console keys,
sources folder or compilation. The build must support `romfs.img` inside its
app bundle; packaging cannot add that capability to an older executable.

Builder compares the image's size and index identity with the IPA's
`romfs.id`. It rejects mismatched or incomplete
images, IPAs without an identity, and IPAs that already contain game data.
This is nxnative's build compatibility check, not an authenticity check of
the game data. The original files and executable stay unchanged. A complete
IPA named `<game> (with ROMFS) [<title ID>].ipa` is published to the games
folder only once it is whole and its ZIP checksums pass. An existing file
under that name is kept; move it first to import again.

Refresh Cartouche on the iPhone to install the complete IPA. Cartouche signs
the app at installation; no separate ROMFS transfer is needed. On a NAS,
the game remains available while the Mac is off.

### While a batch builds

A game asked for while a batch builds, with **Add to the queue** on its sheet or its card's menu, or **Add them to the queue** for the games nxnative improved, waits its turn at the end of the batch: it is built after the batch's own games and those asked for before it, in the same batch, with one report and one notification at the end. **Builds** lists the queue in its order, with a button that takes a game out of it. **Stop this game**, there or on its sheet, stops only the game building, and the batch goes on with the next; **Stop all** stops the batch and empties its queue. In the Terminal, `cartouche-builder build ID`, while a batch builds, adds the games to it in the same way.

The app looks at nxnative and your games when it opens, if it last did more than six hours before, then every six hours and when you ask: a few seconds, or a minute over a NAS, while the spinner turns under the sidebar. A build asked for meanwhile waits for that look to end, as does one asked for while the builder frees space, and starts on its own: its games wait their turn on their sheets and in **Builds** from your click on, and **Stop** there ends it before it starts. The nightly run waits in the same way.

### Your folders

- **Game sources:** your games, which the builder only reads: their packages (`.nsp`, `.xci`, `.nsz`, `.xcz`: the game, its update and DLC, which need `prod.keys`), a Switch 2 game's `.nup`, a dump as nxnative's `scripts/pack_dump.py` lays it out (`base/exefs`, `base/romfs`, `updates/<version>/`, `dlc/`), or a `.zip` of such a dump, which the builder unpacks for the build and removes after. They can be loose in the folder, one folder per game, or in folders of folders, four levels down at most; an update or DLC in a folder of its own, such as `Zelda/Update/`, is built with its game. A game is known by its title ID: the one its folder's or files' names carry (`[0100000000010000]`), else the one its files hold, read in a few hundred bytes of them: a `.nup`'s table of contents, an `.nsp`'s ticket, or the header of an `.xci`'s or `.nsp`'s NCAs, which `prod.keys` decrypts (the builder keeps what it read, so it reads each file once). A dump's title ID is in its `main.npdm`. The packages of a game lying beside another game's, or in several folders, go to nxnative as a folder of links to them alone, in the builder's workspace; a game's folder that holds only its own goes as it is. The library says what it left aside, and why: a file whose name does not say its game while `prod.keys` is not chosen, a file cut short, a second copy of a game (the most complete one is built).
- **Games folder:** where the IPAs go, the folder Cartouche reads, on the Mac or on your NAS. A new IPA takes the place of the game's IPA there, under the same name, so Cartouche keeps finding it; a game's first IPA is named as Cartouche names them, `<game> [<title ID>].ipa`. It is copied as a hidden file first and renamed once whole, so Cartouche never sees half an IPA.
- **prod.keys:** your console's keys, for packages only. They stay on the Mac.

A folder on your NAS works: connect its share in the Finder once, and the builder connects it again by itself, with the password saved in the keychain.

### Little room on the Mac

A game's build folder, `<title ID>_build`, keeps what the next build reuses, so a build after a small change takes minutes instead of hours. The builder keeps the Mac's disk from filling:

- the files it extracts from a game's packages, as big as the game, are removed once the build ends, unless **Keep the extracted files** is on, for a faster next build;
- before a build, and when the disk has less free room than **Keep at least … GB free**, the build folders used the longest ago go first, and a size limit can be set for all of them;
- an IPA kept beside the games folder on the same disk is an APFS clone, which takes no room.

**Storage** shows each of these, with what it takes and **Free**.

## The iPhone

On the **iPhone** page, **Share with Cartouche on the iPhone** makes the Mac a storage place Cartouche can add. Cartouche sees two folders: **Games**, the games folder, wherever it is, and **Saves**, a folder you choose for the copies of your saves. Nothing else of the Mac can be reached.

1. In Cartouche, **System › Storage › Add your Mac (Cartouche Builder)**.
2. Choose the Mac under **Macs nearby**.
3. Both screens show six digits: when they are the same, click **Allow** on the Mac.

From then on, Cartouche installs your games from the Mac and keeps your saves there, encrypted on the way, with a key both keep and that never crosses the network. The Mac is found on the Wi-Fi by Bonjour, or at the address it was last reached at, through your VPN too; it stays awake while an iPhone is connected. Removing an iPhone from the list ends its sessions. The bridge is [`launcher/Sources/CartoucheBridge.swift`](../launcher/Sources/CartoucheBridge.swift), the same file on both sides.

## Updates

The app reads the project's `builder-v<version>` releases when it opens and every six hours. A newer version is downloaded and checked against the SHA-256 published beside it, then checked again before it replaces the app: the same bundle identifier, the version the release names, a macOS it runs on, an intact signature. It is put in place when the app quits, at once with **Restart**, or when nothing builds and no window is open. **Install updates by itself** in the settings can be turned off; the app then offers each update instead.

## When a game is built again

nxnative gets dozens of commits a day, and almost all of them change code every game shares, so building every game for each would keep the Mac busy for nothing. Before a batch, the builder moves its copy of nxnative to the newest commit of `main` and reads what changed since each game's build:

| A game is built when | |
| --- | --- |
| it was never built, or its IPA left the games folder | |
| its folder holds other files | a new update, DLC or dump |
| a commit changed its profile | `dm/games/<title ID>/` |
| a commit names it and changes code that goes into a build | most fixes say which game they were made for: "Ocarina of Time's wall no longer draws black". A name counts in nxnative's spelling or a short form ("Ocarina of Time", "BotW"); the other names on a game's sheet add yours |
| nxnative's shared code changed, as the settings say | every week by default: a game is built again for shared changes once its build is a week old; or at once, or never |
| Xcode or the iOS SDK changed | |
| its IPA was built from a commit `main` does not have | a fork's: what changed since cannot be known |

Documentation, tests and nxnative's own tooling never make a game due. A game whose build failed waits for nxnative or its files to change instead of failing again every night; **Build again**, on a game's sheet, builds it at once, due or not. Each commit's `Front-ends:` line, where nxnative's authors say what a front end must know ([Following main](https://github.com/seedds/nxnative/blob/main/docs/frontends.md#following-main)), shows on the game's sheet and in the batch's report.

## The nightly run

**Build what is due every night**, in the settings, installs a launchd agent of your session (`~/Library/LaunchAgents/io.github.clabeuhtegrite.cartouche-builder.plist`) that runs `cartouche-builder build` at that time, with `caffeinate` keeping the Mac awake while it builds. A Mac asleep at that time runs it when it wakes. A sources or games folder on a network share that is not mounted is mounted again, with the password saved in the keychain. One batch runs at a time: the nightly run leaves the app's batch alone, and a game asked for while one runs waits its turn in it. A notification says how it went, and **Builds** keeps each batch's report.

## Where it keeps things

Everything of its own is in `~/Library/Application Support/Cartouche Builder`: `config.json`, one record per game in `state/` (its last build: the nxnative commit and shader chain, the files it was made from, the Apple tools, the IPA's name), nxnative's copy in `nxnative/`, the Python environment in `python/`, the builds' logs in `logs/<title ID>/` and the batches' reports in `reports/`; and for the app, the batch under way in `status.json`, the games asked for while it runs and those taken out of it in `queue.json`, the library as last read in `library.json`, the iPhones paired and their keys in `bridge.json`, readable by your account only, the iPhones' saves in `Saves/` unless you chose another folder, and the measures not sent yet in `telemetry.json`. The covers and a downloaded update are in `~/Library/Caches/io.github.clabeuhtegrite.cartouche-builder`, which macOS may empty. Your sources are only read, and the builder writes in your games folder only the IPAs of the games it builds.

## What it never does

It never downloads, shares or uploads a game, a key or an IPA: it builds the games you own from your own files, on your Mac, into your own games folder. None of it ever goes into this repository or Cartouche's releases ([LEGAL.md](../LEGAL.md)).

## Development

The builder has two parts. Its engine, the Python package `cartouche_builder`, needs only Python's standard library: `library.py` finds the games, `engine.py` keeps nxnative's copy and reads its history, `impact.py` decides which commits touch a game, `planner.py` makes the plan, `build.py` runs and follows one build, `batch.py` runs a batch, `queue.py` keeps the games asked for while one runs, `status.py` writes what a batch is doing, `storage.py` measures and frees what the builder keeps, `ipa.py` reads and delivers IPAs, `shares.py` connects the network folders again, `toolchain.py` checks the Mac's tools, `schedule.py` is the nightly run, `cli.py` the commands, `api.py` the app's commands (`cartouche-builder api <command>`, one JSON answer each) and `texts.py` every text in English and French.

The Mac app, `mac/`, is a Swift package that runs the engine and shows what it answers. `mac/Sources/BuilderKit` is what the app does without its window: the engine's answers (`Engine.swift`, `Models.swift`), this Mac's tools and their installs (`MacSetup.swift`), the bridge with Cartouche (`BridgeServer.swift`, `BridgeDevices.swift`), the updates (`Updater.swift`) and the measures (`BuilderTelemetry.swift`). `mac/Sources/CartoucheBuilder` is its window, its settings and its menu bar.

The engine's tests run a fake nxnative (a git repository whose build script writes an IPA of a few bytes) and fake dumps of a few bytes. From this folder:

```
python3 -m unittest discover -s tests -t tests
```

`tests/test_app_contract.py` checks that what the engine answers is what the app's tests read (`mac/Tests/BuilderKitTests/Fixtures`). The app's tests, on a Mac with Xcode 27.2:

```
swift test --package-path mac
```

`mac/bundle.sh` makes `Cartouche Builder.app` with the engine inside, and `mac/make_dmg.sh` its disk image. Started with `--gallery FOLDER`, the app saves a picture of each page on sample games, in English and French, light and dark: the **Builder** workflow takes them for each pull request and keeps them on the branch `builder-screens/<branch>`.

Started with `--layout-check`, the app opens its window on sample games whose nxnative commits are as long as nxnative's own, takes it through a game's sheet, a message above the page, widths from 1600 points to below its least, the sidebar hidden and shown, each page, the pages chosen with the arrow keys and a build asked for while nxnative is checked, and ends with an error when a column leaves the window, across or down, the page shown is not the one the sidebar chose, AppKit raises an exception, or SwiftUI says in the app's log that a change was published while it updated the window ([`LayoutCheck.swift`](mac/Sources/CartoucheBuilder/LayoutCheck.swift)): the **Builder** workflow runs it once the app is built. The columns' widths are in `Columns` ([`Theme.swift`](mac/Sources/CartoucheBuilder/Theme.swift)): the window is never narrower than the sidebar at its widest, a page and a game's sheet, and each page lays out what it holds to fit its column.

### Publishing a version

A version is the one in `pyproject.toml`, with its notes in `RELEASE.md`; the merge of the pull request that raises it starts the [Full test pass](../.github/full-pass/README.md), every test of the repository, on main. On `main`, run the **Builder** workflow from the Actions tab with **Publish** ticked: it tests and builds the app, makes its disk image and, once the full test pass has passed on that commit, publishes both with the SHA-256 as the release `builder-v<version>`, without GitHub's Latest mark, which stays Cartouche's. Each copy of the app finds it within six hours, and the workflow publishes the site again, whose buttons and download page then give this version ([site/README.md](../site/README.md#publishing)).
