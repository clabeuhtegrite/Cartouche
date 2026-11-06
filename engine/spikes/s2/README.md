# Spike S2: rewriting a game's modules on the iPhone

In v2, Cartouche builds a game on the iPhone from the player's own dump ([architecture](../../../docs/architecture.md#v2-build-on-the-iphone)). The step after reading the dump rewrites the game's code modules for the Apple chip with nxnative's [`dm/tools/patch_nso.py`](https://github.com/seedds/nxnative/blob/main/dm/tools/patch_nso.py), a Python script that disassembles with Capstone. Spike S2 checks that this script runs under CPython for iOS ([PEP 730](https://peps.python.org/pep-0730/)) and writes there the same files as on a Mac.

Nothing of a game is in this folder or in its CI run: the rewriter comes from nxnative at the commit Cartouche pins ([`engine/nxnative.commit`](../../nxnative.commit)), and the modules it rewrites in CI are synthetic ones made by [`make_test_nso.py`](make_test_nso.py).

## What runs where

| | On a Mac | On iOS |
| --- | --- | --- |
| Python | 3.13 | CPython 3.13 for iOS, from BeeWare's [Python-Apple-support](https://github.com/beeware/Python-Apple-support), release `3.13-b18` ([`runtime.env`](runtime.env) pins it, with Capstone) |
| Capstone | `pip install capstone==5.0.7` | The same version's sources, built for iOS by [`build_capstone_ios.sh`](build_capstone_ios.sh) |
| LZ4 | The `lz4` package | [`ios/lz4`](ios/lz4/block.py), a decoder of the LZ4 block format in pure Python |
| nxnative | `dm/tools` and `dm/games` at the pinned commit | The same files, inside the app |

- **One process.** iOS lets an app start no other process, so [`cartouche_s2/rewriter.py`](cartouche_s2/rewriter.py) runs `patch_nso.py` in its own process with `runpy`, and does by hand what a new process would give it: it forgets the script's modules after each game module, sets the environment of a run for that run only, and puts the script's SIGTERM handler back afterwards.
- **Starting again.** When a module's patch area needs more room before the module's base than its first pass left, `patch_nso.py` starts itself again with `DM_PATCH_FRONT` set, through `os.execve()`, which iOS does not allow. While the script runs, the runner stands in for `os.execve()` and runs it again in the same process, with the environment it asked for ([`tests/test_rewriter.py`](tests/test_rewriter.py)).
- **One worker.** `patch_nso.py` shares a large module between workers that are forked processes, and an iOS app cannot fork, so on iOS the runner sets `DM_REWRITE_J=1`: the script then rewrites in its own process. One of the synthetic modules is large enough for a Mac to share it between two workers, so the comparison checks that both ways write the same files.
- **The game.** [`cartouche_s2/phone.py`](cartouche_s2/phone.py) finds the game's nxnative profile by the build ID of its main module, as the Mac build does, sets `DM_GAME` to it, and rewrites the modules the profile names, in load order, into one folder; for a game without a profile, every module of the folder.
- **Capstone's binding** names its library `libcapstone.so` on every platform but macOS and Windows, iOS included. `build_capstone_ios.sh` changes that one line, since the library is a dylib on iOS too.
- **LZ4.** The `lz4` package is a C extension with no build for iOS. `nso.py` only calls `lz4.block.decompress()`, which `ios/lz4` provides; [`tests/test_lz4_shim.py`](tests/test_lz4_shim.py) checks it against the `lz4` package. It decodes about 25 MB a second on a computer, so a few seconds for a module of a hundred megabytes.

## Steps

1. **In the iOS simulator, in CI.** [`spike-s2.yml`](../../../.github/workflows/spike-s2.yml) runs `patch_nso.py` on synthetic modules, on the runner's macOS and then in the iOS simulator, and compares the SHA-256 of every file the two runs write. The modules hold ten small functions that use what the rewriter rewrites: the thread registers, `svc`, the counter, `x18`, `sp` alignment, and a lock taken without acquire ordering. `main` is stored plain, `subsdk0` and `sdk` compressed with LZ4, as retail modules are, and `sdk` holds over a megabyte of code, which a Mac shares between two workers.
   Passed on 6 November 2026: CPython 3.13.18 in the iPhone 17e simulator on iOS 26.5 wrote the same 16 files as Python 3.13.17 on the runner's macOS, byte for byte, from `main` and `subsdk0`. With `sdk` and the runner of step 2, a run writes 23 files.
2. **On the iPhone, with the player's own game.** Cartouche carries the same runtime: [`build_ios_runtime.sh`](build_ios_runtime.sh) builds it, `app/scripts/package.sh --python` puts it in the app, and Python starts only when the lab runs ([`CartouchePython.swift`](../../../launcher/Sources/CartouchePython.swift)). The lab is in the System tab, **Lab › Rewrite a game's modules** ([`CartoucheLab.swift`](../../../launcher/Sources/CartoucheLab.swift)). To run it:
   1. On the Mac that built the game with nxnative's `scripts/build_ipa_from_nsp.py`, list the files its rewriter wrote, which are in the `patched_<version>` folder of the game's build folder (`<title ID>_build` beside the dump, unless `--work-dir` named another): `cd <build folder>/patched_v0 && shasum -a 256 * > ~/Desktop/mac.sha256`.
   2. Put the game's ExeFS folder, or its modules alone (`main`, `subsdk0`… `sdk`, as the dump has them), and `mac.sha256` into one folder that the iPhone sees in Files, such as a folder of iCloud Drive.
   3. In Cartouche, choose that folder in the lab, tap Rewrite, and keep Cartouche open with the screen on until the end.

   Cartouche copies the modules into a folder of its own, `Documents/Cartouche/Lab/S2`, rewrites them with `cartouche_s2.phone`, reads its memory twice a second, and writes into the chosen folder `iphone-report.txt` (the iPhone, its memory limit, each module's time and memory peak, and each file written, the same as the Mac's, different, or missing from the Mac's list), `iphone.sha256` (its own list, in the same format), and `iphone-rewrite.log` (what the rewriter printed). When iOS closes Cartouche during a rewrite, for lack of memory for instance, Cartouche writes the report when it next opens, with its last memory reading.
   The gate of S2: Mario Kart World's modules give the same files, and the time and memory it takes on the iPhone are measured.

## Run it on a Mac

Step 1, the comparison with the iOS simulator, needs Xcode with an iOS simulator, CMake and Python 3.13:

```sh
engine/spikes/s2/fetch_nxnative.sh build/nxnative
engine/spikes/s2/fetch_python_support.sh build/support
engine/spikes/s2/run_simulator.sh build/support build/nxnative build/s2
```

The job of step 2 also runs on a Mac, with Python 3.13, `capstone==5.0.7` and `lz4`: from `engine/spikes/s2`, `python3 -m cartouche_s2 --tools <nxnative>/dm/tools --modules <the folder of the modules> --reference <the folder>/mac.sha256` prints the SHA-256 of each file written, then the files that are not the same as on the Mac's list.

## Not covered yet

- A restart through `os.execve()` with a real module: the synthetic modules never need one, so only the stand-in of [`tests/test_rewriter.py`](tests/test_rewriter.py) takes that path.
- The NROs some games load besides their modules, which the Mac build also rewrites: the lab rewrites the modules of ExeFS only, and lists the Mac's other files as written by the Mac only.
- Speed and memory with a whole game, on the iPhone: what step 2 measures, with Mario Kart World.
