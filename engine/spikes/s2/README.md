# Spike S2: rewriting a game's modules on the iPhone

In v2, Cartouche builds a game on the iPhone from the player's own dump ([architecture](../../../docs/architecture.md#v2-build-on-the-iphone)). The step after reading the dump rewrites the game's code modules for the Apple chip with nxnative's [`dm/tools/patch_nso.py`](https://github.com/seedds/nxnative/blob/main/dm/tools/patch_nso.py), a Python script that disassembles with Capstone. Spike S2 checks that this script runs under CPython for iOS ([PEP 730](https://peps.python.org/pep-0730/)) and writes there the same files as on a Mac.

Nothing of a game is in this folder or in its CI run: the rewriter comes from nxnative at the commit Cartouche pins ([`engine/nxnative.commit`](../../nxnative.commit)), and the modules it rewrites in CI are synthetic ones made by [`make_test_nso.py`](make_test_nso.py).

## What runs where

| | On a Mac | On iOS |
| --- | --- | --- |
| Python | 3.13 | CPython 3.13 for iOS, from BeeWare's [Python-Apple-support](https://github.com/beeware/Python-Apple-support) |
| Capstone | `pip install capstone==5.0.7` | The same version's sources, built for iOS by [`build_capstone_ios.sh`](build_capstone_ios.sh) |
| LZ4 | The `lz4` package | [`ios/lz4`](ios/lz4/block.py), a decoder of the LZ4 block format in pure Python |
| nxnative | `dm/tools` and `dm/games` at the pinned commit | The same files, inside the app |

- **One process.** iOS lets an app start no other process, so [`cartouche_s2`](cartouche_s2/__main__.py) runs `patch_nso.py` in its own process with `runpy`, and forgets the script's modules between two game modules, as a new process would.
- **Capstone's binding** names its library `libcapstone.so` on every platform but macOS and Windows, iOS included. `build_capstone_ios.sh` changes that one line, since the library is a dylib on iOS too.
- **LZ4.** The `lz4` package is a C extension with no build for iOS. `nso.py` only calls `lz4.block.decompress()`, which `ios/lz4` provides; [`tests/test_lz4_shim.py`](tests/test_lz4_shim.py) checks it against the `lz4` package. It decodes about 25 MB a second on a computer, so a few seconds for a module of a hundred megabytes.

## Steps

1. **In the iOS simulator, in CI.** [`spike-s2.yml`](../../../.github/workflows/spike-s2.yml) runs `patch_nso.py` on two synthetic modules, on the runner's macOS and then in the iOS simulator, and compares the SHA-256 of every file the two runs write. The modules hold ten small functions that use what the rewriter rewrites: the thread registers, `svc`, the counter, `x18`, `sp` alignment, and a lock taken without acquire ordering. One module is stored plain, the other compressed with LZ4, as retail modules are.
2. **On the iPhone, with the player's own game** (to do). Cartouche runs the same script on the modules of the player's own dump and shows the SHA-256 of each file it writes, which the player compares with the files nxnative's `scripts/build_ipa_from_nsp.py` writes from the same dump on their Mac. The gate of S2: Mario Kart World's modules give the same files, and the time and memory it takes on the iPhone are measured.

## Run it on a Mac

Needs Xcode with an iOS simulator, CMake and Python 3.13.

```sh
engine/spikes/s2/fetch_nxnative.sh build/nxnative
# Download Python-Apple-support's iOS package for 3.13 and unpack it in build/support.
engine/spikes/s2/run_simulator.sh build/support build/nxnative build/s2
```

## Not covered yet

- When a module's patch area does not fit before the module, `patch_nso.py` starts itself again with `DM_PATCH_FRONT` set, through `os.execve()`, which iOS does not allow. Step 2 will have to run it again in the same process instead. The synthetic modules never take that path.
- Speed and memory with a whole game, on the iPhone: step 2.
