# Cartouche Builder

Cartouche Builder builds your own games into IPAs with [nxnative](https://github.com/seedds/nxnative) on your Mac, puts them in the games folder Cartouche reads, and builds a game again when a change to nxnative touches it. It is a program of its own, beside the app: Cartouche on the iPhone then sees the newer IPA in your games folder and offers to update the game.

It runs nxnative's own build script, as nxnative's [front-end page](https://github.com/seedds/nxnative/blob/main/docs/frontends.md) describes, and adds what a library of games needs: one folder per game, a plan that says which games are due and why, a batch that builds them one after the other, and a nightly run.

## What you need

A Mac that builds nxnative games: macOS 26.6 or later on Apple silicon, Xcode 27.2 with its iOS platform and Metal toolchain, `xcodegen`, `zstd` and `glslang` from Homebrew, and Python 3.12 or later with Tk (`brew install python@3.13 python-tk@3.13`). Since its commit 641636e2 (10 November 2026) nxnative needs no .NET: only an older copy of nxnative asks for the .NET 10 SDK. **Mac tools…** in the window checks each one and opens the command that installs a missing one in Terminal. The builder downloads nxnative and makes the Python environment nxnative's scripts need by itself, in its own folder.

## Install

In Terminal, on the Mac:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/main/builder/install.sh)"
```

[`install.sh`](install.sh) installs Homebrew when the Mac has none, then with it Python 3.13 and its Tk, `xcodegen`, `zstd` and `glslang`, with no .NET, which nxnative no longer needs; puts Cartouche Builder in `~/Applications`, as an app that opens its window; readies Xcode's iOS platform and Metal toolchain; downloads nxnative and makes its Python environment (`cartouche-builder setup`); and opens Cartouche Builder. Xcode itself comes from Apple, with its licence: when it is missing or was never opened, the script opens it or its App Store page and asks for the command again afterwards. The same command updates Cartouche Builder, and leaves its settings, its copy of nxnative and the games alone. `CARTOUCHE_REF=<branch>` before it installs another branch's builder. The step by step guide, from the iPhone to the first game: [docs/getting-started.md](../docs/getting-started.md#2-build-your-game-on-your-mac).

## Start

Open **Cartouche Builder** from Applications, once installed. From the repository, double-click **Cartouche Builder.command** in this folder instead. Or, in Terminal, from this folder:

```
python3 -m cartouche_builder                 # the window
python3 -m cartouche_builder plan            # what is due, and why
python3 -m cartouche_builder build           # build what is due
python3 -m cartouche_builder build 0400C3F00006E000 --force
python3 -m cartouche_builder doctor          # the Mac's tools
python3 -m cartouche_builder schedule on --at 03:30
```

`pipx install ./builder`, from the repository, gives the same commands as `cartouche-builder`.

Then choose your folders:

- **Game sources**: one folder per game, which the builder only reads. A game's folder holds its packages (`.nsp`, `.xci`, `.nsz`, `.xcz`: the game, its update and DLC, which need `prod.keys`), a Switch 2 game's `.nup`, a dump as nxnative's `scripts/pack_dump.py` lays it out (`base/exefs`, `base/romfs`, `updates/<version>/`, `dlc/`), or a `.zip` of such a dump, which the builder unpacks for the build and removes after. A `.nup` or `.zip` can also sit in the sources folder itself. A game is known by its title ID: in its folder's or files' names (`[0100000000010000]`), or in a dump's `main.npdm`.
- **Games folder**: where the IPAs go, the folder Cartouche reads on your Mac, PC or NAS. A new IPA takes the place of the game's IPA there, under the same name, so Cartouche keeps finding it; a game's first IPA is named as Cartouche names them, `<game> [<title ID>].ipa`. It is copied as a hidden file first and renamed once whole, so Cartouche never sees half an IPA.
- **prod.keys**: your console's keys, for packages only.
- **Build folders** (optional): nxnative's build folder of each game, `<title ID>_build`, which keeps what the next build reuses, so a build after a small change takes minutes instead of hours. A size limit in **Settings…** removes the folders of the games built longest ago. **Keep each IPA in the build folders too** keeps a copy of each IPA there, which nxnative's packer updates in place at the next build (only what changed is written again), at the cost of as much space again as the IPAs.

## When a game is built again

nxnative gets dozens of commits a day, and almost all of them change code every game shares, so building every game for each would keep the Mac busy for nothing. Before a batch, the builder moves its copy of nxnative to the newest commit of `main` and reads what changed since each game's build:

| A game is built when | |
| --- | --- |
| it was never built, or its IPA left the games folder | |
| its folder holds other files | a new update, DLC or dump |
| a commit changed its profile | `dm/games/<title ID>/` |
| a commit names it and changes code that goes into a build | most fixes say which game they were made for: "Ocarina of Time's wall no longer draws black". A name counts in nxnative's spelling or a short form ("Ocarina of Time", "BotW"); **Other names in commits** adds yours |
| nxnative's shared code changed, as **Settings…** says | every week by default: a game is built again for shared changes once its build is a week old; or at once, or never |
| Xcode or the iOS SDK changed | |
| its IPA was built from a commit `main` does not have | a fork's: what changed since cannot be known |

Documentation, tests and nxnative's own tooling never make a game due. A game whose build failed waits for nxnative or its files to change instead of failing again every night; **Build the selection** builds the games picked in the list at once, due or not. Each commit's `Front-ends:` line, where nxnative's authors say what a front end must know ([Following main](https://github.com/seedds/nxnative/blob/main/docs/frontends.md#following-main)), shows in the window and the batch's report.

## The nightly run

**Build what is due every night at** installs a launchd agent of your session (`~/Library/LaunchAgents/io.github.clabeuhtegrite.cartouche-builder.plist`) that runs `cartouche-builder build` at that time, with `caffeinate` keeping the Mac awake while it builds. A Mac asleep at that time runs it when it wakes. A sources or games folder on a network share that is not mounted is mounted again, with the password saved in the keychain. One batch runs at a time: the nightly run leaves the window's batch alone. A notification says how it went, and **Reports** keeps each batch's report.

## Coming from NxNative Batch Builder

At its first start, Cartouche Builder takes over NxNative Batch Builder's settings (its sources, IPA and build folders, `prod.keys` and the games you ticked) and the games it built, with the nxnative commit of each, from `~/Library/Application Support/NxNative Batch Builder`; it only reads them. Only the games ticked there are followed: the plan shows the others as not ticked, with the nxnative commit of their last build, until you tick them in the list. Its build folders stay where they are and are reused as they are. Two of its features are not taken over:

- The ZIP archives of build folders on the NAS: a build folder stays on the Mac, under the size limit you set, instead of going to the NAS and back for each build.
- Three builds at once: one by default, since nxnative uses every core for one game and a large game needs most of a 16 GB Mac's memory. **Settings…** allows up to four.

## Where it keeps things

Everything of its own is in `~/Library/Application Support/Cartouche Builder`: `config.json`, one record per game in `state/` (its last build: the nxnative commit and shader chain, the files it was made from, the Apple tools, the IPA's name), nxnative's copy in `nxnative/`, the Python environment in `python/`, the builds' logs in `logs/<title ID>/` and the batches' reports in `reports/`. Your sources are only read, and the builder writes in your games folder only the IPAs of the games it builds.

## What it never does

It never downloads, shares or uploads a game, a key or an IPA: it builds the games you own from your own files, on your Mac, into your own games folder. None of it ever goes into this repository or Cartouche's releases ([LEGAL.md](../LEGAL.md)).

## Development

The package needs only Python's standard library. Its tests run a fake nxnative (a git repository whose build script writes an IPA of a few bytes) and fake dumps of a few bytes. From this folder:

```
python3 -m unittest discover -s tests -t tests
```

The window's test needs Tk and a display (`xvfb-run` on Linux). The code: `library.py` finds the games, `engine.py` keeps nxnative's copy and reads its history, `impact.py` decides which commits touch a game, `planner.py` makes the plan, `build.py` runs and follows one build, `batch.py` runs a batch, `ipa.py` reads and delivers IPAs, `schedule.py` is the nightly run, `cli.py` and `gui.py` the commands and the window, `texts.py` every text in English and French.
