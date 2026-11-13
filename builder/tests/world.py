"""The world of Cartouche Builder's end-to-end tests (test_end_to_end.py, and
the Mac app's mac/Tests/BuilderKitTests/EndToEndTests.swift): a player's Mac
of the tests' own, in a temporary folder.

- The player's folders: their games' sources, the games folder Cartouche
  reads, their prod.keys (a header key of the tests' own, no console's).
- Their games, in every layout nxnative reads, as files of a few bytes:
  packages in a folder of their own or loose, named with their title IDs or
  without (a ticket, or the NCAs' headers with the keys, tell the game), a
  cartridge holding two games, a dump folder, a zipped dump, a Switch 2
  game's NUP; and as players have them damaged: a .zs file that is no zstd
  stream, a NUP cut short, an NCA failing its hash. No game is involved, not
  a byte of one: the titles are the tests' own.
- nxnative's repository, a git repository laid out as nxnative's, whose
  build script is simulated_nxnative.py (what Cartouche Builder sees of
  nxnative), with the history the tests write in it: a profile changed,
  shared code changed, the shader chain moved, a commit whose iOS app does
  not link (BROKEN).
- The app (App): the engine's commands and batches as the Mac app runs them
  (mac/Sources/BuilderKit/Engine.swift, CartoucheBuilder/AppModel.swift): a
  process each, of the engine copied as the app carries it in its Resources,
  with the app's environment; a batch detached, written to app-batch.log and
  followed through status.json and queue.json; Stop as SIGTERM to the batch.

What a build needs that the tests do not have is given as a Mac has it:
nxnative's Python environment, made by the builder at its first batch, is
one of the test's own without packages (the simulated nxnative needs only
Python's), and on a Mac, the tools the builder checks before a batch
(Xcode, its iOS SDK and Metal compiler, Homebrew's tools) answer from the
builder's own bin folder, first on the builds' PATH.

  python3 world.py make FOLDER    makes a world in FOLDER for the Mac app's
                                  tests, two games due, and says it in JSON
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILDER = HERE.parent
for folder in (str(HERE), str(BUILDER)):
    if folder not in sys.path:
        sys.path.insert(0, folder)

from cartouche_builder import toolchain  # noqa: E402

from support import GIT_ENV, commit, git, make_nsp, make_xci, nca, npdm, write_keys  # noqa: E402

SIMULATED = HERE / "simulated_nxnative.py"
CHAIN = "d403eb0683df"  # the shader translation chain of the tests' nxnative
ZSTD = b"\x28\xb5\x2f\xfd"

# The tests' games: titles and names of their own, no game's.
LANTERN = "0100E2E000A10000"  # packages in a folder of their own, named with their title IDs
DRIFT = "0100E2E000A20000"  # a dump folder
ORCHARD = "0100E2E000A30000"  # a zipped dump
HARBOR = "0100E2E000A60000"  # packages loose in the sources, named without their title IDs
COMET = "0400E2E000B10000"  # a Switch 2 game's NUP
TWIN_A, TWIN_B = "0100E2E000A40000", "0100E2E000A50000"  # one cartridge holding both
STRAY = "0100E2E000A70000"  # a game nxnative has no profile for
NAMES = {
    LANTERN: "Paper Lantern",
    DRIFT: "Lumen Drift",
    ORCHARD: "Quiet Orchard",
    HARBOR: "Harbor Lights",
    COMET: "Comet Rally",
    TWIN_A: "Twin Peaks A",
    TWIN_B: "Twin Peaks B",
}


def update_id(title_id: str) -> str:
    """A game's update: its title ID with 0x800 in the low 12 bits."""
    return f"{int(title_id, 16) | 0x800:016X}"


def dlc_id(title_id: str, index: int = 1) -> str:
    """A game's DLC: its title ID plus 0x1000 and the DLC's index."""
    return f"{int(title_id, 16) + 0x1000 + index:016X}"


# ---- The games' files ---------------------------------------------------------------


def romfs(folder: Path, damaged: bool = False) -> dict[str, bytes]:
    """A game's romfs of a few bytes: a data file and a zstd file, which
    DAMAGED makes zeros, as a copy cut or zeroed has them."""
    files = {
        "Data/level.bin": b"level of the tests' own " * 8,
        "Model/kart.zs": (bytes(64) if damaged else ZSTD + b"\x00" * 60),
    }
    for name, data in files.items():
        (folder / name).parent.mkdir(parents=True, exist_ok=True)
        (folder / name).write_bytes(data)
    return files


def packages(folder: Path, title_id: str, name: str, update: int = 0, dlc: int = 0, tagged: bool = True, ticket: bool = True,
             damaged: bool = False) -> list[Path]:
    """A game's packages as a player dumps them: its base game, its update
    (of version UPDATE), its DLC; NSPs of a few bytes, an NCA in each. Named
    "Name [title ID][vN].nsp", or without the tags: a ticket then names the
    title, or without one (TICKET false) its NCAs' headers do, which the keys
    decrypt. DAMAGED: an NCA of the base game fails its hash."""
    made = []
    titles = [(title_id, 0, "")]
    if update:
        titles.append((update_id(title_id), update, " Update"))
    titles += [(dlc_id(title_id, i), 0, f" DLC {i}") for i in range(1, dlc + 1)]
    for index, (held, version, part) in enumerate(titles):
        file_name = f"{name}{part} [{held}][v{version}].nsp" if tagged else f"{name}{part}.nsp"
        files = [(f"{index:032x}.cnmt.nca", nca(1, held)), (f"{index + 100:032x}.nca", nca(0, held))]
        if ticket:
            files.insert(0, (f"{held}{'0' * 15}{index % 10}.tik", b"ticket of the tests' own"))
        if damaged and index == 0:
            files.append((f"{index + 200:032x}.nca", b"BAD-NCA-HASH" + bytes(64)))
        made.append(make_nsp(folder / file_name, files))
    return made


def dump(folder: Path, title_id: str, update: int = 0, dlc: int = 0, damaged: str = "") -> Path:
    """A dump folder as nxnative's scripts/pack_dump.py lays it out:
    base/exefs (its main.npdm says the title ID), base/romfs, the update in
    updates/<version>/, the DLC in dlc/<title ID>/. DAMAGED names the version
    whose .zs file is zeros ("v0", "v65536")."""
    base = folder / "base"
    (base / "exefs").mkdir(parents=True, exist_ok=True)
    (base / "exefs" / "main.npdm").write_bytes(npdm(title_id))
    (base / "exefs" / "main").write_bytes(b"code of the tests' own")
    romfs(base / "romfs", damaged == "v0")
    if update:
        patch = folder / "updates" / str(update)
        (patch / "exefs").mkdir(parents=True, exist_ok=True)
        (patch / "exefs" / "main.npdm").write_bytes(npdm(title_id))
        romfs(patch / "romfs", damaged == f"v{update}")
    for index in range(1, dlc + 1):
        extra = folder / "dlc" / dlc_id(title_id, index) / "romfs"
        extra.mkdir(parents=True, exist_ok=True)
        (extra / "bonus.bin").write_bytes(b"DLC of the tests' own")
    return folder


def zipped_dump(path: Path, title_id: str, root: str = "Game") -> Path:
    """A dump zipped by a player, in a folder of its own inside the archive,
    with what the Finder adds to it (__MACOSX)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    prefix = f"{root}/" if root else ""
    files = {
        "base/exefs/main.npdm": npdm(title_id),
        "base/exefs/main": b"code of the tests' own",
        "base/romfs/Data/level.bin": b"level of the tests' own " * 8,
        "base/romfs/Model/kart.zs": ZSTD + b"\x00" * 60,
    }
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr(zipfile.ZipInfo(prefix + name, (2026, 11, 1, 20, 0, 0)), data)
        archive.writestr(f"__MACOSX/{prefix}base/exefs/._main.npdm", b"AppleDouble")
    return path


def nup(path: Path, title_id: str, update: int = 0, dlc: int = 0, damaged: str = "", cut: int = 0) -> Path:
    """A Switch 2 game's NUP: its superblock and table of contents as the
    format has them (identify.py reads them), then the tests' own index of
    each package's files and their bytes (simulated_nxnative.scan_nup). Its
    base game, its update (version UPDATE), its DLC; DAMAGED names the
    version whose .zs file is zeros ("v131072"); CUT bytes cut from its end,
    as a copy that stopped before its end."""
    entries: list[tuple[str, int, int, dict[str, bytes]]] = [(title_id, 0, 0, _nup_files(damaged == "v0"))]
    if update:
        entries.append((update_id(title_id), 1, update, _nup_files(damaged == f"v{update}")))
    entries += [(dlc_id(title_id, i), 2, 0, {"bonus.bin": b"DLC of the tests' own"}) for i in range(1, dlc + 1)]
    count = len(entries)
    toc = b"TOC\x01" + struct.pack("<IQQQQQ", count, 0, 0, 0x30 + 0x40 * count, 0, 0)
    for held, kind, _version, _files in entries:
        toc += struct.pack("<QIIIIBBHIQI20x", int(held, 16), 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, kind, 0, 0, 0, 0, 0)
    index = json.dumps([{"kind": kind, "version": version, "files": [[name, len(data)] for name, data in files.items()]}
                        for _held, kind, version, files in entries]).encode()
    body = struct.pack("<I", len(index)) + index + b"".join(data for *_, files in entries for data in files.values())
    size = 0x80 + len(toc) + len(body)
    head = struct.pack("<4sHHQQ32sQQII16s32s", b"NUP\x01", 0x80, 0, 0x80, len(toc), bytes(32), 0x80 + len(toc), size, count, 0, bytes(16), bytes(32))
    data = head + toc + body
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data[: len(data) - cut] if cut else data)
    return path


def _nup_files(damaged: bool) -> dict[str, bytes]:
    return {"romfs/Data/level.bin": b"level of the tests' own " * 8, "romfs/Model/kart.zs": bytes(64) if damaged else ZSTD + b"\x00" * 60}


def cartridge(path: Path, title_ids: list[str]) -> Path:
    """A cartridge dump (XCI) named without its titles, whose NCAs' headers
    the keys decrypt: one game's, or two games' as some cartridges hold."""
    return make_xci(path, title_ids)


# ---- nxnative --------------------------------------------------------------------------


class Nxnative:
    """nxnative's repository on GitHub, as the tests have it: a git repository
    in the world, laid out as nxnative's, the simulated build script as its
    scripts/build_ipa_from_nsp.py. The builder clones it as it clones
    nxnative (engine_url)."""

    REQUIREMENTS = "# The simulated nxnative needs only Python's own modules.\n"

    def __init__(self, folder: Path, games: dict[str, str]):
        self.folder = folder
        folder.mkdir(parents=True)
        git(folder, "init", "-q", "-b", "main")
        files = {
            "scripts/build_ipa_from_nsp.py": SIMULATED.read_text(encoding="utf-8"),
            ".github/requirements/tools.txt": self.REQUIREMENTS,
            "dm/host/host.c": "int main(void) { return 0; }\n",
            "dm/gfx/nvn/dmsh_chain.h": f'#define DMSH_CHAIN "{CHAIN}"\n',
            # Committed native since nxnative 641636e2: its builds need no .NET
            # (toolchain.needs_dotnet), which a Mac's checks then do not ask for.
            toolchain.NATIVE_NX_EXTRACT: "#!/bin/sh\n# nxnative's nx_extract, which the simulated build script never runs.\nexit 0\n",
            "README.md": "# nxnative, as Cartouche Builder's tests simulate it\n",
        }
        for title_id, name in games.items():
            files[self.profile_path(title_id)] = self.profile_text(title_id, name)
        self.commit("Initial commit", files)

    @staticmethod
    def profile_path(title_id: str) -> str:
        return f"dm/games/{title_id}/game.tsv"

    @staticmethod
    def profile_text(title_id: str, name: str, **values: str) -> str:
        rows = [f"# {name}", f"title_id\t{title_id}", f"name\t{name}", f"ipa\t{name.replace(' ', '')}.ipa"]
        rows += [f"{key}\t{value}" for key, value in values.items()]
        return "\n".join(rows) + "\n"

    def commit(self, message: str, files: dict[str, str | None]) -> str:
        return commit(self.folder, message, files)

    @property
    def head(self) -> str:
        return git(self.folder, "rev-parse", "HEAD")

    def change_profile(self, title_id: str, name: str, message: str = "") -> str:
        """A commit that changes the game's profile: that game is due again."""
        return self.commit(message or f"{name}: steadier frame pacing", {self.profile_path(title_id): self.profile_text(title_id, name, frame_pacing="1")})

    def change_shared(self, message: str = "Faster texture uploads") -> str:
        """A commit of shared code, naming no game."""
        host = self.folder / "dm" / "host" / "host.c"
        return self.commit(message, {"dm/host/host.c": host.read_text() + f"/* {message} */\n"})

    def break_app_build(self, *title_ids: str, message: str = "Probe the GPU with atrace") -> str:
        """A commit of shared code whose iOS app does not link, as nxnative's
        main of 11 November 2026: every game's, or those of TITLE_IDS."""
        host = self.folder / "dm" / "host" / "host.c"
        return self.commit(message, {"dm/host/host.c": host.read_text() + "void probe(void) { _probe_atrace(); }\n",
                                     "BROKEN": "".join(f"{i}\n" for i in title_ids) or "every game\n"})

    def fix_app_build(self, message: str = "Link atrace's probe again") -> str:
        host = self.folder / "dm" / "host" / "host.c"
        return self.commit(message, {"dm/host/host.c": host.read_text() + "/* atrace linked */\n", "BROKEN": None})

    def move_chain(self, chain: str, message: str = "") -> str:
        """A commit that moves the shader translation chain: the shaders of
        every game are translated again at their next build."""
        return self.commit(message or f"Shaders: chain {chain}", {"dm/gfx/nvn/dmsh_chain.h": f'#define DMSH_CHAIN "{chain}"\n'})


# ---- The world -------------------------------------------------------------------------


class World:
    """A player's Mac, of the test's own, in ROOT (a temporary folder when
    none is given): their folders, nxnative's repository with the profiles
    of GAMES, the app's copy of the engine, the builder's folder."""

    def __init__(self, root: Path | None = None, games: dict[str, str] | None = None, language: str = "en"):
        self._tmp = None
        if root is None:
            self._tmp = tempfile.TemporaryDirectory(prefix="cartouche-e2e-")
            root = Path(self._tmp.name)
        root.mkdir(parents=True, exist_ok=True)
        self.root = root.resolve()
        self.language = language
        self.user = self.root / "user"  # the player's home folder
        self.home = self.user / "Library" / "Application Support" / "Cartouche Builder"
        self.sources = self.user / "Games" / "Switch dumps"
        self.games = self.user / "Games" / "Cartouche"
        self.keys = self.user / "Switch" / "prod.keys"
        self.agents = self.root / "LaunchAgents"
        self.scenario_file = self.root / "scenario.json"
        for folder in (self.sources, self.games, self.keys.parent, self.home):
            folder.mkdir(parents=True, exist_ok=True)
        write_keys(self.keys)
        self.nxnative = Nxnative(self.root / "github" / "nxnative", NAMES if games is None else games)
        # The engine as the app carries it in its Resources (bundle.sh): the
        # package alone, which nothing may write in (PYTHONDONTWRITEBYTECODE).
        self.package = self.root / "Cartouche Builder.app" / "Contents" / "Resources" / "engine"
        shutil.copytree(BUILDER / "cartouche_builder", self.package / "cartouche_builder", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        self.python = Path(os.environ.get("CARTOUCHE_BUILDER_PYTHON") or sys.executable)
        self.app = App(self)
        self.scenario()

    # ---- What the player sets up -------------------------------------------------

    def set_up(self, **settings) -> dict:
        """The setup assistant's choices, saved as the app saves them
        (api config --set), and what a build needs ready (ready)."""
        chosen = {
            "sources": str(self.sources),
            "games": str(self.games),
            "keys": str(self.keys),
            "engine_url": str(self.nxnative.folder),
            "min_free_gb": 0,  # the test machines' disks are small
            "notifications": False,
            "setup_done": True,
            **settings,
        }
        self.ready()
        return self.app.api("config", "--set", json.dumps(chosen))

    def ready(self) -> None:
        """nxnative's Python environment as the builder makes it, without
        packages (the simulated nxnative needs none), so that no batch
        installs any; and on a Mac, its tools (mac_tools)."""
        venv = self.home / "python"
        if not (venv / "bin" / "python3").exists():
            subprocess.run([str(self.python), "-m", "venv", "--without-pip", str(venv)], check=True, capture_output=True)
        requirements = self.root / "requirements.txt"
        requirements.write_text(Nxnative.REQUIREMENTS, encoding="utf-8")
        stamp = toolchain.requirements_stamp(requirements, venv / "bin" / "python3")
        (venv / toolchain.STAMP).write_text(stamp + "\n")
        if sys.platform == "darwin":
            self.mac_tools()

    def mac_tools(self, xcode: str = "27.2", build: str = "27C55", sdk: str = "27.2") -> None:
        """The Apple and Homebrew tools a batch checks, answering as Xcode
        27.2 does, in the builder's bin folder: first on the PATH of its
        checks and builds (toolchain.search_path), so that the tests do not
        depend on what the Mac running them installed. The simulated nxnative
        runs none of them."""
        folder = self.home / "bin"
        folder.mkdir(parents=True, exist_ok=True)
        tools = {
            "xcodebuild": f'[ "$1" = "-version" ] && {{ echo "Xcode {xcode}"; echo "Build version {build}"; exit 0; }}\nexit 64\n',
            "xcrun": (
                'case "$*" in\n'
                f'  "--sdk iphoneos --show-sdk-version") echo "{sdk}" ;;\n'
                '  "-sdk iphoneos metal --version") echo "Apple metal version 32023.404 (metalfe-32023.404.2)" ;;\n'
                "  *) exit 64 ;;\nesac\n"
            ),
            "xcodegen": "exit 0\n",
            "zstd": "exit 0\n",
            "glslangValidator": "exit 0\n",
        }
        for name, body in tools.items():
            path = folder / name
            path.write_text("#!/bin/sh\n# A tool of Cartouche Builder's end-to-end tests (world.py).\n" + body)
            path.chmod(0o755)

    def scenario(self, **plan) -> None:
        """What the simulated nxnative does at its next builds
        (simulated_nxnative.py): {} builds every game."""
        self.scenario_file.write_text(json.dumps(plan), encoding="utf-8")

    # ---- What the world holds ------------------------------------------------------

    @property
    def workspace(self) -> Path:
        return self.home / "workspace"

    def build_folder(self, title_id: str) -> Path:
        return self.workspace / f"{title_id}_build"

    def ipa(self, title_id: str) -> Path | None:
        """The game's IPA in the games folder."""
        found = [p for p in self.games.glob("*.ipa") if f"[{title_id}]" in p.name]
        return found[0] if len(found) == 1 else None

    def inside(self, title_id: str) -> dict:
        """What the simulated nxnative wrote in the game's IPA: its Info.plist,
        the files it was given and its options."""
        import plistlib

        path = self.ipa(title_id)
        if path is None:
            raise AssertionError(f"no IPA of {title_id} in {sorted(p.name for p in self.games.iterdir())}")
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            app = next(n for n in names if n.endswith(".app/Info.plist")).rsplit("/", 1)[0]
            return {
                "info": plistlib.loads(archive.read(f"{app}/Info.plist")),
                "inputs": json.loads(archive.read(f"{app}/sim/inputs.json")),
                "args": json.loads(archive.read(f"{app}/sim/args.json")),
                "names": names,
            }

    @property
    def mac_apps(self) -> Path:
        """Where this Mac installs the Mac apps a games folder on a NAS keeps
        in one file, when the settings name no folder: the Applications
        folder of the player's home folder (config.default_mac_apps)."""
        return self.user / "Applications"

    def mac_app(self, title_id: str, folder: Path | None = None) -> Path | None:
        """The game's Mac app in FOLDER (the games folder, where it is built,
        or where this Mac installs it): the app there whose Info.plist names
        it."""
        import plistlib

        folder = folder or self.games
        found = []
        for app in sorted(folder.glob("*.app")) if folder.is_dir() else []:
            try:
                info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
            except (OSError, ValueError):
                continue
            if info.get("DMTitleID") == title_id:
                found.append(app)
        return found[0] if len(found) == 1 else None

    def mac_inside(self, title_id: str, folder: Path | None = None) -> dict:
        """What the simulated nxnative wrote in the game's Mac app: its
        Info.plist, the files it was given and its options."""
        import plistlib

        app = self.mac_app(title_id, folder)
        if app is None:
            where = folder or self.games
            raise AssertionError(f"no Mac app of {title_id} in {sorted(p.name for p in where.iterdir()) if where.is_dir() else where}")
        sim = app / "Contents" / "Resources" / "sim"
        return {
            "app": app,
            "info": plistlib.loads((app / "Contents" / "Info.plist").read_bytes()),
            "inputs": json.loads((sim / "inputs.json").read_text()),
            "args": json.loads((sim / "args.json").read_text()),
        }

    def close(self) -> None:
        """Stops what still runs (a batch, a build a killed batch left, its
        tools) and removes the world."""
        self.app.close()
        for pid_file in [*self.workspace.glob("*_build/nxnative.pid"), *self.workspace.glob("*_build/tool.pid")]:
            try:
                pid = int(pid_file.read_text().strip())
            except (OSError, ValueError):
                continue
            if pid > 1 and alive(pid) and _is_ours(pid, self.root):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        if self._tmp is not None:
            self._tmp.cleanup()

    def describe(self) -> dict:
        """The world for the Mac app's tests: where its folders are, and the
        environment the engine's processes need beside the app's."""
        return {
            "root": str(self.root),
            "home": str(self.home),
            "package": str(self.package),
            "python": str(self.python),
            "sources": str(self.sources),
            "games": str(self.games),
            "keys": str(self.keys),
            "applications": str(self.mac_apps),
            "nxnative": str(self.nxnative.folder),
            "head": self.nxnative.head,
            # Beside what the app gives the engine itself (Engine.environment).
            "environment": {k: v for k, v in self.app.extra.items() if k.startswith(("NXSIM_", "GIT_CONFIG")) or k in ("CARTOUCHE_BUILDER_AGENTS", "CARTOUCHE_BUILDER_QUIET")},
            "titles": {},
        }


def _is_ours(pid: int, root: Path) -> bool:
    """Whether process PID runs something of ROOT's (a build a killed batch
    left, and its tools), not a process that took its number since."""
    try:
        done = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return str(root) in done.stdout or "time.sleep" in done.stdout


def alive(pid) -> bool:
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


# ---- The app ------------------------------------------------------------------------------


class EngineFailure(Exception):
    """An error the engine answered ({"error": {"kind", "message", ...}}),
    as Engine.decode throws it."""

    def __init__(self, error: dict, code: int):
        super().__init__(f"{error.get('kind')}: {error.get('message')}")
        self.error = error
        self.kind = error.get("kind")
        self.code = code


class App:
    """The Mac app, as far as the engine sees it: its commands (Engine.api),
    its batches (Engine.startBatch), what it reads of them (Engine.readStatus,
    readQueue) and its Stop (Engine.stopBatch)."""

    def __init__(self, world: World):
        self.world = world
        self.batches: list[subprocess.Popen] = []
        self.said: list[str] = []  # what the commands wrote on stderr

    @property
    def extra(self) -> dict[str, str]:
        """What the app adds to its environment for the engine (Engine.environment),
        and the world's: its home folder, the nightly run's agents folder, the
        simulated nxnative's scenario and the builder it reads packages with."""
        return {
            "PYTHONPATH": str(self.world.package),
            "PYTHONUNBUFFERED": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "CARTOUCHE_BUILDER_APP": "1",
            "CARTOUCHE_BUILDER_HOME": str(self.world.home),
            "CARTOUCHE_BUILDER_LANG": self.world.language,
            "CARTOUCHE_BUILDER_AGENTS": str(self.world.agents),
            "CARTOUCHE_BUILDER_QUIET": "1",
            "NXSIM_SCENARIO": str(self.world.scenario_file),
            "NXSIM_BUILDER": str(self.world.package),
            "HOME": str(self.world.user),
            **GIT_ENV,
        }

    @property
    def environment(self) -> dict[str, str]:
        """Run.environment: this process's, Homebrew's folders and the
        system's first on the PATH, then the app's (extra)."""
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONHOME", "VIRTUAL_ENV", "PYTHONPATH")}
        path = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        path += [p for p in os.environ.get("PATH", "").split(os.pathsep) if p and p not in path]
        env["PATH"] = os.pathsep.join(path)
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env.update(self.extra)
        return env

    # ---- Commands ----------------------------------------------------------------

    def api(self, *args: str, timeout: float = 300) -> dict:
        """`api ARGS` and its answer: the last line of its output that is a JSON
        object; an error answered is raised (EngineFailure)."""
        done = subprocess.run([str(self.world.python), "-m", "cartouche_builder", "api", *args], cwd=self.world.package, env=self.environment,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
        self.said.append(done.stderr)
        lines = [line for line in done.stdout.splitlines() if line.startswith("{")]
        if not lines:
            raise EngineFailure({"kind": "crashed", "message": (done.stderr or done.stdout).strip()[-2000:]}, done.returncode)
        answer = json.loads(lines[-1])
        if "error" in answer:
            raise EngineFailure(answer["error"], done.returncode)
        return answer

    def library(self, update: bool = False) -> dict:
        return self.api("library", *(["--update"] if update else []))

    def game(self, title_id: str, update: bool = False, library: dict | None = None) -> dict:
        """The game as the library shows it."""
        library = library or self.library(update)
        for game in library["games"]:
            if game["title_id"] == title_id:
                return game
        raise AssertionError(f"{title_id} not in the library: {[g['title_id'] for g in library['games']]}")

    # ---- Batches -----------------------------------------------------------------

    def start_batch(self, games: tuple[str, ...] | list[str] = (), force: bool = False) -> subprocess.Popen:
        """A batch of GAMES (all that are due with none), detached from the app,
        its output appended to logs/app-batch.log, kept awake by caffeinate on
        a Mac (Engine.startBatch)."""
        command = [str(self.world.python), "-m", "cartouche_builder", "build"]
        if force and games:
            command.append("--force")
        command += list(games)
        if sys.platform == "darwin" and os.access("/usr/bin/caffeinate", os.X_OK):
            command = ["/usr/bin/caffeinate", "-i", *command]
        logs = self.world.home / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        with open(logs / "app-batch.log", "ab") as log:
            process = subprocess.Popen(command, cwd=self.world.package, env=self.environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        self.batches.append(process)
        return process

    def build(self, *games: str, force: bool = False) -> subprocess.Popen | None:
        """The Build button (AppModel.build): while a batch runs, GAMES wait
        their turn in it (api queue add); else, or once it ended, a batch of
        their own. None when they were added to the batch running."""
        status = self.status()
        if status and status.get("running"):
            if not games:
                games = tuple(g["title_id"] for g in self.library()["games"] if g["due"])
            answer = self.api("queue", "add", *(["--force"] if force else []), *games)
            if answer["queued"]:
                return None
        return self.start_batch(games, force)

    def status(self) -> dict | None:
        """status.json, as Engine.readStatus reads it: a batch that says it
        runs, whose process is gone, is stopped."""
        try:
            data = json.loads((self.world.home / "status.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        running = data.get("state") in ("preparing", "building")
        if running and not self.alive(data.get("pid")):
            data["state"], data["running"] = "stopped", False
        else:
            data["running"] = running
        return data

    def alive(self, pid) -> bool:
        """Whether the batch of process PID runs: one the app started is asked
        (an ended one it did not wait for yet is no process), another one
        (the nightly run's, Terminal's) is looked for."""
        for process in self.batches:
            if process.pid == pid:
                return process.poll() is None
        return alive(pid)

    def queue(self) -> dict:
        try:
            return json.loads((self.world.home / "queue.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {"version": 1, "games": [], "stop": []}

    def stop(self) -> None:
        """Stop (Engine.stopBatch): SIGTERM to the batch running."""
        status = self.status()
        if status and status.get("running") and isinstance(status.get("pid"), int) and status["pid"] > 1:
            os.kill(status["pid"], signal.SIGTERM)

    def take_out(self, *title_ids: str) -> dict:
        """A game taken out of the batch (api queue remove)."""
        return self.api("queue", "remove", *title_ids)

    # ---- Following a batch ---------------------------------------------------------

    def wait(self, what: str, until, timeout: float = 60.0, every: float = 0.05):
        """UNTIL()'s first true value, asked every EVERY seconds."""
        deadline = time.monotonic() + timeout
        while True:
            value = until()
            if value:
                return value
            if time.monotonic() > deadline:
                raise AssertionError(f"waited {timeout:.0f} s for {what}; status: {json.dumps(self.status(), indent=1)[-3000:]}\nlog: {self.log()[-3000:]}")
            time.sleep(every)

    def progress(self, title_id: str, status: dict | None = None) -> dict | None:
        """The game in the batch running now, or the last one."""
        status = status or self.status()
        for game in (status or {}).get("games", []):
            if game["title_id"] == title_id:
                return game
        return None

    def wait_state(self, title_id: str, *states: str, timeout: float = 60.0) -> dict:
        """Until TITLE_ID's state in the batch is one of STATES."""
        return self.wait(f"{title_id} {' or '.join(states)}", lambda: (g if (g := self.progress(title_id)) and g["state"] in states else None), timeout)

    def wait_stage(self, title_id: str, stage: str, timeout: float = 60.0) -> dict:
        """Until TITLE_ID builds, at nxnative's STAGE."""
        return self.wait(f"{title_id} at {stage}", lambda: (g if (g := self.progress(title_id)) and g["state"] == "building" and g["stage"] == stage else None), timeout)

    def finish(self, process: subprocess.Popen | None = None, timeout: float = 120.0) -> dict:
        """Until the batch ends: its process, and status.json saying how."""
        process = process or self.batches[-1]
        try:
            process.wait(timeout)
        except subprocess.TimeoutExpired:
            raise AssertionError(f"the batch still runs after {timeout:.0f} s; status: {json.dumps(self.status(), indent=1)[-3000:]}\nlog: {self.log()[-3000:]}") from None
        status = self.status()
        if status is None or status.get("running"):
            raise AssertionError(f"the batch ended (exit {process.returncode}) without saying so: {status}\nlog: {self.log()[-3000:]}")
        return status

    def log(self) -> str:
        try:
            return (self.world.home / "logs" / "app-batch.log").read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def close(self) -> None:
        """Stops the batches still running: Stop, then harder."""
        for process in self.batches:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
        for process in self.batches:
            try:
                process.wait(30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(10)


# ---- For the Mac app's tests -----------------------------------------------------------------


def make(folder: Path) -> dict:
    """A world in FOLDER with two games due, a folder of packages and a
    dump, set up as the app's setup assistant leaves it: what the Mac app's
    end-to-end tests start from (EndToEndTests.swift). Its Mac apps go in
    its games folder; those it installs, in the world's own Applications
    folder, named in its settings: the app runs the engine with the Mac's
    home folder, whose Applications folder the tests must never write in."""
    world = World(folder, games={LANTERN: NAMES[LANTERN], DRIFT: NAMES[DRIFT]})
    packages(world.sources / f"{NAMES[LANTERN]} [{LANTERN}]", LANTERN, NAMES[LANTERN], update=65536, dlc=1)
    dump(world.sources / NAMES[DRIFT], DRIFT)
    world.set_up(mac_apps=str(world.mac_apps))
    described = world.describe()
    described["titles"] = {LANTERN: NAMES[LANTERN], DRIFT: NAMES[DRIFT]}
    return described


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "make":
        sys.exit(__doc__.rsplit("\n\n", 1)[-1])
    print(json.dumps(make(Path(sys.argv[2])), indent=2))
