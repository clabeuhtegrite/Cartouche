#!/usr/bin/env python3
"""A simulated nxnative: the scripts/build_ipa_from_nsp.py of a checkout that
builds nothing, for Cartouche Builder's end-to-end tests (test_end_to_end.py,
world.py). No game is involved: what it reads are the tests' files of a few
bytes, and the IPA it writes holds no game.

It is what Cartouche Builder sees of nxnative, as nxnative's front-end page
describes it (docs/frontends.md) and its script does it (seedds/nxnative
547c5db6, 12 November 2026):

- its options, every one of the real script's: one it does not take ends it
  with its usage on stderr, no JSON event, and exit code 2;
- with --progress json, one JSON object per line on stdout (stage, step,
  progress, stage_end, shaders_stale, game, say), each with its time "t";
- its exit code: 0 for a finished build, 1 for an error, said last as a
  message starting with "[RED] " (an unexpected one also prints its
  traceback on stderr), 130 when interrupted (SIGINT), 143 for SIGTERM and
  129 for SIGHUP, the tool it runs stopped with it;
- what it reads, as nxnative reads it: a folder of one game's packages (the
  base game, its update, its DLC; prod.keys needed, and more than one game
  refused), a dump (base/exefs/main.npdm, updates/<version>/, dlc/), or a
  NUP, the file or a folder holding it;
- what it checks before it builds: the room on the build folder's disk (the
  game's size and some slack: "less than N GB free on the volume of ..."),
  and the files of a NUP or a dump, whose .zs files must be zstd streams
  ("v131072: 3 file(s) whose bytes do not start as their names promise ...",
  as Ocarina of Time's update on a player's NUP), and a NUP's size;
- its build folder (--work-dir, used as given): logs/, the extracted files in
  extract/ (removed after the IPA with --no-keep-extracted), a shader cache
  per translation chain (shaders/b-<chain>: a new chain rebuilds them, which
  shaders_stale says), the app's icon, and for the tests its process number
  (nxnative.pid);
- the IPA at -o, written whole under another name then renamed: an app of
  Payload/<name>.app whose Info.plist names the game (DMTitleID, its version,
  its bundle ID org.nxnative.<title ID>) and the build (DMCommit, "+dirty"
  for a checkout with changes, DMChain, DMLanguage), with the settings list
  dm/launcher.json, and sim/inputs.json: every file it was given, by name,
  size and SHA-256, for the tests to see what reached nxnative;
- with --platform mac-app, the game's Mac app at -o instead, which must end
  in .app (stages "Mac shaders", "Mac host" and "Mac app" in place of the
  iOS shaders, the app build and the IPA pack; the extracted files kept
  whatever it is asked, the app being made of clones of them; the Mac
  shaders' cache in mac-shaders/b-<chain>): written as
  nxnative's packer (dm/mac/pack_app.py) writes it, under <app>.partial,
  then in place of the app there, its reuse key in <app>.key; its
  Contents/Info.plist says what an IPA's says (DMTitleID, DMCommit, DMChain,
  DMLanguage, the version, the bundle ID, CFBundleName) and DMSaveSyncChoice,
  its launcher and host in Contents/MacOS (nxnative, dmhost), the game's
  files in Contents/Resources/romfs, sim/inputs.json and sim/args.json in
  Contents/Resources.

What breaks, breaks as with nxnative. The checkout's own commits can break
the app build (a file BROKEN at its root: every game's, or those whose title
IDs it lists, as nxnative's main did on 11 November 2026, "_probe_atrace");
the game's files can be damaged. The rest comes from the tests' scenario,
the JSON file NXSIM_SCENARIO names, read at each build:

  {"slow": {ID: seconds},   the iOS shaders take that long, with a tool of
                            their own running meanwhile (its pid in the build
                            folder's tool.pid)
   "crash": [ID],           an exception of the script's own (KeyError)
   "killed": [ID],          killed by the system (SIGKILL) at the shaders
   "app_build": [ID],       the iOS app does not link, at any commit
   "quiet": {ID: seconds},  the app build takes that long without a word,
                            as Xcode compiling
   "no_ipa": [ID],          ends well without an IPA
   "mac_slow": {ID: seconds},
                            the Mac shaders take that long, with a tool of
                            their own running meanwhile (tool.pid)
   "mac_host": [ID],        the Mac host does not build (clang)
   "mac_room": [ID],        the Mac app's packer finds no room for a copy of
                            the game's files, as on a disk where it cannot
                            clone them
   "ipa_bytes": {ID: n},    an IPA of about n bytes
   "refused": [option],     options this nxnative does not take, as one
                            from before or after them ("-l")
   "slack_gb": n}           nxnative's room on top of the game's size (6 GB
                            in nxnative; 0 here, for the test machines), or
                            {ID: n}

ID is a game's title ID, or "*" for every game. It finds the title IDs of
packages named without them as nxnative does, in their tickets, or in their
NCAs' headers decrypted with prod.keys' header key, with the builder's own
AES (cartouche_builder/identify.py, checked against FIPS 197 by
test_identify.py), from the folder NXSIM_BUILDER names.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PACKAGES = (".nsp", ".xci", ".nsz", ".xcz")
ZSTD = b"\x28\xb5\x2f\xfd"
LANGUAGES = ("ja", "en-US", "en", "fr", "de", "it", "es", "zh-Hans", "ko", "nl", "pt", "ru", "zh-Hant", "en-GB", "fr-CA", "es-419", "pt-BR")
NUP_SUPER = struct.Struct("<4sHHQQ32sQQII16s32s")
NUP_TOC = struct.Struct("<4sIQQQQQ")
NUP_PACKAGE = struct.Struct("<QIIIIBBHIQI20x")


class BuildError(Exception):
    """An error the build says as its last message, exit code 1."""


class Stopped(BaseException):
    def __init__(self, sig: int):
        super().__init__(sig)
        self.sig = sig


# ---- The events -------------------------------------------------------------------


class Progress:
    """nxnative's PROG in json mode: the stages, numbered k of n."""

    def __init__(self, mode: str):
        self.mode = mode
        self.k = self.n = 0
        self.current: str | None = None
        self.started = 0.0
        self.lock = threading.RLock()

    def _json(self, fields: dict) -> None:
        if self.mode != "json":
            return
        fields.setdefault("t", round(time.time(), 3))
        sys.stdout.write(json.dumps(fields) + "\n")
        sys.stdout.flush()

    def plan(self, n: int) -> None:
        self.k, self.n = 0, n

    def add(self, n: int) -> None:
        self.n += n

    def stage(self, name: str, step: str = "") -> None:
        with self.lock:
            self.end()
            self.k += 1
            self.current, self.started = name, time.time()
            self._json({"ev": "stage", "k": self.k, "n": self.n, "name": name, "step": step})

    def step(self, step: str) -> None:
        with self.lock:
            self._json({"ev": "step", "k": self.k, "name": self.current, "step": step})

    def set(self, done, total, unit: str = "", note: str = "") -> None:
        with self.lock:
            frac = min(done / total, 0.99) if total else None
            elapsed = time.time() - self.started
            eta = round(elapsed / frac - elapsed, 1) if frac else None
            self._json({"ev": "progress", "k": self.k, "name": self.current, "step": "", "done": done, "total": total, "unit": unit,
                        "est": False, "note": note, "frac": frac, "eta": eta, "elapsed": round(elapsed, 3)})

    def end(self, summary: str = "", ok: bool = True, warn: bool = False) -> None:
        with self.lock:
            if self.current is None:
                return
            fields = {"ev": "stage_end", "k": self.k, "name": self.current, "ok": ok, "summary": summary, "elapsed": round(time.time() - self.started, 3)}
            if warn:
                fields["warn"] = True
            self._json(fields)
            self.current = None

    def event(self, ev: str, **fields) -> None:
        self._json({"ev": ev, **fields})

    def say(self, message: str) -> None:
        self._json({"ev": "say", "msg": message})
        if self.mode != "json":
            print(message, flush=True)


PROG = Progress("off")


def say(message: str) -> None:
    PROG.say(f"[{time.strftime('%H:%M:%S')}] {message}")


# ---- The options --------------------------------------------------------------------


def parse_args(argv: list[str], refused: set[str] = frozenset()) -> argparse.Namespace:
    """nxnative's options, every one of them, as of 547c5db6, but those
    REFUSED: argparse ends on them, its usage on stderr, exit code 2."""
    parser = argparse.ArgumentParser(prog="build_ipa_from_nsp.py", description="Build an IPA from one game's NSPs, dump or NUP (simulated).")

    class Options:
        @staticmethod
        def add_argument(*names, **options):
            if not set(names) & refused:
                parser.add_argument(*names, **options)

    ap = Options()
    ap.add_argument("nsp_dir", nargs="?")
    ap.add_argument("-k", "--keys")
    ap.add_argument("--title-id")
    ap.add_argument("-p", "--package")
    ap.add_argument("-o", "--out")
    ap.add_argument("--app-name")
    ap.add_argument("--bundle-id")
    ap.add_argument("--romfs", choices=("bundle", "separate"))
    ap.add_argument("--shader-files", action=argparse.BooleanOptionalAction)
    ap.add_argument("--prepare-xcode", action="store_true")
    ap.add_argument("--platform", choices=("ios", "mac", "mac-app"))
    ap.add_argument("--icon")
    ap.add_argument("--fallback-icon")
    ap.add_argument("--mac-sign")
    ap.add_argument("--team-id")
    ap.add_argument("--xcode-workspace")
    ap.add_argument("-l", "--language")
    ap.add_argument("--keep-extracted", action=argparse.BooleanOptionalAction)
    ap.add_argument("--work-dir")
    ap.add_argument("--env-file")
    ap.add_argument("--gpu")
    ap.add_argument("--seen-shaders", action=argparse.BooleanOptionalAction)
    ap.add_argument("--show-fps", action=argparse.BooleanOptionalAction)
    ap.add_argument("--motion", action=argparse.BooleanOptionalAction)
    ap.add_argument("--survey-only", action="store_true")
    ap.add_argument("--program", type=int, default=None)
    ap.add_argument("--allow-damaged", action="store_true")
    ap.add_argument("--allow-shader-regressions", action="store_true")
    ap.add_argument("--allow-other-metal", action="store_true")
    ap.add_argument("--profile-out")
    ap.add_argument("--provisional", action="store_true")
    ap.add_argument("--no-heap-check", action="store_true")
    ap.add_argument("--progress", choices=("auto", "bar", "lines", "json", "off"))
    return parser.parse_args(argv)


# ---- What the tests ask of it -------------------------------------------------------


def scenario() -> dict:
    path = os.environ.get("NXSIM_SCENARIO")
    if not path:
        return {}
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def asked(plan: dict, key: str, title_id: str):
    """What the scenario's KEY says of TITLE_ID: its value, True for a list
    that names it, None when it does not."""
    value = plan.get(key)
    if isinstance(value, dict):
        return value.get(title_id, value.get("*"))
    if isinstance(value, list):
        return True if title_id in value or "*" in value else None
    return None


# ---- The game's files -----------------------------------------------------------------


class Family:
    """One game's files: its title ID, the versions packed (the base game
    and its newest update), its DLC, and every file given."""

    def __init__(self, title_id: str, kind: str):
        self.title_id = title_id
        self.kind = kind  # "packages", "dump" or "nup"
        self.version = 0  # the newest version given, packed into the IPA
        self.dlc: list[str] = []
        self.files: list[Path] = []
        self.name = ""  # the game's name, as its files say it
        self.contents: dict[str, dict[str, bytes]] = {}  # a dump's or a NUP's files, by version


def title_ids_of(path: Path, keys: Path | None) -> list[str]:
    """The titles a package holds, as nxnative reads its content metas: by
    the name's tag, its ticket, or its NCAs with the keys."""
    named = re.findall(r"\[([0-9A-Fa-f]{16})\]", path.name)
    if named:
        return [named[0].upper()]
    builder = os.environ.get("NXSIM_BUILDER")
    if builder:
        sys.path.insert(0, builder)
        from cartouche_builder import identify  # noqa: PLC0415 - the builder's AES, for the NCAs' headers

        try:
            return identify.Reader(keys).ids(path)
        except identify.Unreadable as error:
            raise BuildError(f"the packages' content metas could not be read ({path.name}: {error})") from error
    raise BuildError(f"{path.name}: no content meta readable without the keys")


def base_of(title_id: str) -> str:
    """The game a title belongs to: an update is the game's ID with 0x800 in
    its low 12 bits, a DLC the game's ID plus 0x1000 and its index."""
    value = int(title_id, 16)
    if not value & 0xFFF:
        return f"{value:016X}"
    if value & 0xFFF == 0x800:
        return f"{value & ~0xFFF:016X}"
    return f"{(value & ~0xFFF) - 0x1000:016X}"


def version_in(path: Path) -> int:
    found = re.search(r"\[v(\d+)\]", path.name)
    return int(found.group(1)) if found else 0


def scan_packages(folder: Path, keys: Path | None, want: str | None) -> Family:
    packages = sorted(p for p in folder.iterdir() if p.suffix.lower() in PACKAGES and not p.name.startswith("."))
    if not packages:
        raise BuildError(f"no NSP, XCI, NSZ or XCZ in {folder}")
    if keys is None:
        raise BuildError("prod.keys not given: JSON mode does not prompt; give it on the command line (-h for usage)")
    if not keys.is_file():
        raise BuildError(f"prod.keys: no such file {keys}")
    titles: dict[str, list[tuple[Path, str]]] = {}
    for path in packages:
        # A link the builder made to the player's file: nxnative reads the file.
        if not path.resolve().is_file():
            raise BuildError(f"{path}: no such file")
        for title_id in title_ids_of(path, keys):
            titles.setdefault(base_of(title_id), []).append((path, title_id))
    games = sorted(titles)
    wanted = want.upper() if want else None
    if wanted and wanted not in titles:
        raise BuildError(f"no game {wanted} (--title-id / TITLE_ID) in {folder}, which holds {', '.join(games)}")
    if not wanted and len(games) > 1:
        raise BuildError(f"more than one game in the folder: {', '.join(games)}; keep one game per folder, or name the one to pack with --title-id / TITLE_ID (a cartridge dump that holds two games)")
    title_id = wanted or games[0]
    family = Family(title_id, "packages")
    for path, held in titles[title_id]:
        family.files.append(path)
        value = int(held, 16)
        if value & 0xFFF == 0x800:
            family.version = max(family.version, version_in(path) or 65536)
        elif value & 0xFFF:
            family.dlc.append(held)
        if b"BAD-NCA-HASH" in path.read_bytes()[:1 << 16]:
            raise BuildError(f"{path.name}: an NCA fails its hash check (NCA hash mismatch): an incomplete copy or a broken download")
    family.name = re.sub(r"\s*\[[^\]]*\]", "", Path(family.files[0].name).stem).strip()
    return family


def npdm_title_id(npdm: Path) -> str:
    data = npdm.read_bytes()
    if data[:4] != b"META":
        raise BuildError(f"{npdm}: not a main.npdm")
    offset = struct.unpack_from("<I", data, 0x70)[0]
    return f"{struct.unpack_from('<Q', data, offset + 0x10)[0]:016X}"


def files_of(folder: Path) -> dict[str, bytes]:
    return {p.relative_to(folder).as_posix(): p.read_bytes() for p in sorted(folder.rglob("*")) if p.is_file()}


def scan_dump(folder: Path) -> Family:
    """A dump as nxnative's scripts/pack_dump.py lays it out."""
    base = folder / "base" if (folder / "base").is_dir() else folder
    npdm = base / "exefs" / "main.npdm"
    if not npdm.is_file():
        raise BuildError(f"{folder}: no exefs/main.npdm, the dump's code is missing")
    family = Family(npdm_title_id(npdm), "dump")
    family.contents["v0"] = files_of(base / "romfs") if (base / "romfs").is_dir() else {}
    for update in sorted((folder / "updates").iterdir()) if (folder / "updates").is_dir() else []:
        number = int(update.name.lstrip("v")) if update.name.lstrip("v").isdigit() else 0
        family.version = max(family.version, number)
        family.contents[f"v{number}"] = files_of(update / "romfs") if (update / "romfs").is_dir() else {}
    family.dlc = sorted(p.name for p in (folder / "dlc").iterdir()) if (folder / "dlc").is_dir() else []
    family.files = sorted(p for p in folder.rglob("*") if p.is_file())
    family.name = folder.name
    return family


def scan_nup(path: Path) -> Family:
    """A NUP: its superblock and table of contents as the format has them,
    then, in the tests' NUPs, each package's files (world.make_nup)."""
    data = path.read_bytes()
    if len(data) < NUP_SUPER.size or data[:3] != b"NUP":
        raise BuildError(f"{path}: not a NUP")
    _magic, _head, _, toc_offset, toc_size, _, _, file_size, count, _, _, _ = NUP_SUPER.unpack_from(data)
    if len(data) < file_size:
        raise BuildError(f"{path.name}: {len(data):,} bytes, its header says {file_size:,} (copied or downloaded partly?)")
    packages = [NUP_PACKAGE.unpack_from(data, toc_offset + NUP_TOC.size + i * NUP_PACKAGE.size) for i in range(count)]
    bases = [p for p in packages if p[5] == 0]
    if not bases:
        raise BuildError(f"{path.name}: no base game in the NUP")
    family = Family(f"{bases[0][0]:016X}", "nup")
    family.files = [path]
    family.name = re.sub(r"\s*\[[^\]]*\]", "", path.stem).strip()
    end = toc_offset + toc_size
    index_size = struct.unpack_from("<I", data, end)[0] if len(data) >= end + 4 else 0
    index = json.loads(data[end + 4 : end + 4 + index_size]) if index_size else []
    cursor = end + 4 + index_size
    for package in index:
        files: dict[str, bytes] = {}
        for name, size in package["files"]:
            files[name] = data[cursor : cursor + size]
            cursor += size
        version = int(package.get("version", 0))
        if package.get("kind", 0) == 1:
            family.version = max(family.version, version)
        if package.get("kind", 0) in (0, 1):
            family.contents[f"v{version}"] = files
    family.dlc = [f"{p[0]:016X}" for p in packages if p[5] == 2]
    return family


def scan(source: Path, keys: Path | None, want: str | None) -> Family:
    if source.is_file():
        if source.suffix.lower() == ".nup":
            return scan_nup(source)
        raise BuildError(f"{source}: give the folder that holds the game's files")
    if not source.is_dir():
        raise BuildError(f"{source}: no such folder")
    if (source / "base" / "exefs").is_dir() or (source / "exefs").is_dir():
        return scan_dump(source)
    nups = sorted(p for p in source.iterdir() if p.suffix.lower() == ".nup" and not p.name.startswith("."))
    if nups and not any(p.suffix.lower() in PACKAGES for p in source.iterdir()):
        if len(nups) > 1:
            raise BuildError(f"more than one NUP in {source}: give the one to pack")
        return scan_nup(nups[0])
    return scan_packages(source, keys, want)


def check_files(family: Family, allow: bool) -> None:
    """nxnative's check of a NUP's or a dump's files, which carry no hashes:
    a .zs file must be a zstd stream."""
    for version, files in family.contents.items():
        PROG.add(1)
        PROG.stage(f"check {version} files", step="reading file heads")
        bad = [(name, len(data), data[:3].hex()) for name, data in files.items() if name.lower().endswith(".zs") and not data.startswith(ZSTD)]
        PROG.end(f"{len(bad)} damaged" if bad else "ok")
        if not bad:
            continue
        rows = "\n".join(f"  {name} ({size:,} bytes, starts {head or '(nothing)'})" for name, size, head in bad[:20])
        message = f"{version}: {len(bad)} file(s) whose bytes do not start as their names promise (a .zs file that is not a zstd stream), so the game files are damaged:\n{rows}"
        if not allow:
            raise BuildError(f"{message}\nPack again from a good copy of the game (--allow-damaged packs these files as they are)")
        say(f"[RED] {message}\npacked as they are (--allow-damaged)")


# ---- The build ---------------------------------------------------------------------------


def git(*args: str) -> str:
    done = subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else ""


def profile(title_id: str) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for line in (REPO / "dm" / "games" / title_id / "game.tsv").read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("\t")
            if key and not key.startswith("#"):
                values.setdefault(key, value)
    except OSError:
        pass
    return values


def chain() -> str:
    try:
        found = re.search(r'DMSH_CHAIN\s+"([0-9a-f]+)"', (REPO / "dm/gfx/nvn/dmsh_chain.h").read_text(encoding="utf-8"))
    except OSError:
        found = None
    return found.group(1) if found else "000000000000"


def free_gb(path: Path) -> float:
    path.mkdir(parents=True, exist_ok=True)
    return shutil.disk_usage(path).free / 2**30


def broken_for(title_id: str) -> bool:
    """A file BROKEN at the checkout's root: the iOS app does not link, for
    every game, or for those whose title IDs it lists."""
    marker = REPO / "BROKEN"
    if not marker.is_file():
        return False
    named = re.findall(r"[0-9A-Fa-f]{16}", marker.read_text(encoding="utf-8", errors="replace"))
    return not named or title_id in {n.upper() for n in named}


def run_tool(seconds: float, work: Path, name: str) -> None:
    """A tool of the build, running for SECONDS in the script's process group
    (as Xcode or the shader translator do), its pid in the build folder."""
    tool = subprocess.Popen([sys.executable, "-c", f"import time; time.sleep({seconds})"], stdin=subprocess.DEVNULL)
    (work / "tool.pid").write_text(f"{tool.pid}\n")
    started = time.time()
    try:
        while tool.poll() is None:
            done = min(time.time() - started, seconds)
            PROG.set(done=round(done, 1), total=seconds, note=name)
            time.sleep(0.1)
    finally:
        if tool.poll() is None:
            tool.terminate()
            tool.wait()
    if tool.returncode:
        raise BuildError(f"{name} failed (exit {tool.returncode})")


def main(args: argparse.Namespace) -> None:
    global PROG
    PROG = Progress(args.progress or "off")
    plan = scenario()
    if not args.nsp_dir:
        raise BuildError("NSP folder not given: JSON mode does not prompt; give it on the command line (-h for usage)")
    if args.language and args.language not in LANGUAGES:
        raise BuildError(f"--language / LANGUAGE: no language {args.language}; one of {', '.join(LANGUAGES)}")
    if args.title_id and not re.fullmatch(r"[0-9A-Fa-f]{16}", args.title_id):
        raise BuildError(f"--title-id / TITLE_ID takes a title ID, 16 hex digits: {args.title_id}")
    source = Path(args.nsp_dir)
    keys = Path(args.keys) if args.keys else None
    family = scan(source, keys, args.title_id)
    title_id = family.title_id
    work = Path(args.work_dir) if args.work_dir else (source.parent if source.is_file() else source) / f"{title_id}_build"
    out = Path(args.out) if args.out else (source.parent if source.is_file() else source) / f"{title_id}.ipa"
    logs = work / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    # For the tests, which stop what a batch killed left running.
    (work / "nxnative.pid").write_text(f"{os.getpid()}\n")
    keep = args.keep_extracted is not False
    mac_app = args.platform == "mac-app"
    if mac_app and out.suffix != ".app":
        raise BuildError(f"the Mac app (-o / OUT_IPA) must end in .app: {out}")
    if mac_app and not keep:
        say("keeping the extracted game files all the same: the game runs from them on the Mac and the app is made of clones of them")
        keep = True
    say("Mac app: the Mac shaders and the Mac host, packed into a Mac app; no iOS shaders, Xcode project or IPA" if mac_app else f"output IPA: {out}")
    say(f"work folder (extracted game files in extract/, {'kept for the next build' if keep else 'deleted after the IPA is built'}): {work}")

    # The room the build needs, as nxnative counts it: the game's size and some slack.
    size = sum(p.stat().st_size for p in family.files)
    slack = asked(plan, "slack_gb", title_id) if isinstance(plan.get("slack_gb"), dict) else plan.get("slack_gb")
    needed = size / 2**30 + float(slack or 0)
    if free_gb(work) < needed:
        raise BuildError(f"less than {needed:.0f} GB free on the volume of {work}")

    versions = sorted({0, family.version})
    PROG.plan(len(versions) + bool(family.dlc) + 4)
    extract = work / "extract"
    extract.mkdir(parents=True, exist_ok=True)
    verb = {"packages": "extract", "dump": "pack", "nup": "unpack"}[family.kind]
    with open(logs / "extract.log", "a", encoding="utf-8") as log:
        for version in versions:
            PROG.stage(f"{verb} v{version}")
            for done in range(1, 3):
                PROG.set(done=done * size // 2, total=size, unit="B")
            folder = extract / f"v{version}"
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "RomFS.img").write_bytes(hashlib.sha256(f"{title_id} v{version}".encode()).digest() * 64)
            log.write(f"v{version}: {size} bytes\n")
        if family.dlc:
            PROG.stage("extract DLC" if family.kind == "packages" else "unpack DLC")
            (extract / "dlc.txt").write_text("\n".join(family.dlc) + "\n")
    if family.kind in ("dump", "nup"):
        check_files(family, args.allow_damaged)

    # The game event, once its name, version and bundle ID are settled.
    values = profile(title_id)
    name = args.app_name or values.get("name") or family.name or title_id
    version = "1.0.0" if not family.version else f"1.{family.version // 65536}.0"
    bundle_id = args.bundle_id or f"org.nxnative.{title_id.lower()}"
    icon = None
    if family.kind != "dump":
        icon = extract / "icon.jpg"
        icon.write_bytes(b"\xff\xd8\xff\xe0 icon of " + title_id.encode())
    elif args.fallback_icon:
        icon = Path(args.fallback_icon)
    PROG.event("game", title_id=title_id, name=name, version=version, bundle_id=bundle_id, out=str(out), icon=str(icon) if icon else None)
    say(f"game: {name} {version} ({bundle_id})")

    PROG.stage("rewrite", step="checking the inputs")
    if asked(plan, "crash", title_id):
        modules = {}
        modules["icon"]  # an error of the script's own: KeyError, its traceback on stderr
    if mac_app:
        build_mac_app(args, plan, family, work, out, name, version, bundle_id)
        return
    PROG.stage("iOS shaders", step="checking the inputs")
    current = chain()
    shaders = work / "shaders"
    old = sorted(p.name for p in shaders.glob("b-*")) if shaders.is_dir() else []
    if old and f"b-{current}" not in old:
        PROG.event("shaders_stale", reason="chain", old=old, new=f"b-{current}", count=3)
        say(f"shaders of another translation chain ({', '.join(old)}): rebuilt for b-{current}")
        for stale in old:
            shutil.rmtree(shaders / stale, ignore_errors=True)
    cache = shaders / f"b-{current}"
    reused = cache.is_dir()
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "cache.bin").write_bytes(b"shaders " + current.encode())
    PROG.step("translating" if not reused else "reusing the library")
    if asked(plan, "killed", title_id):
        os.kill(os.getpid(), signal.SIGKILL)
    slow = asked(plan, "slow", title_id)
    if slow:
        run_tool(float(slow), work, "dmsh_xlate")
    PROG.end("reused" if reused else "3 translated")

    PROG.stage("app build", step="starting")
    with open(logs / "xcodebuild.log", "a", encoding="utf-8") as log:
        if broken_for(title_id) or asked(plan, "app_build", title_id):
            log.write('Undefined symbols for architecture arm64:\n  "_probe_atrace", referenced from: dm_host_main\n')
            print('Undefined symbols for architecture arm64: "_probe_atrace"', file=sys.stderr, flush=True)
            raise BuildError("xcodebuild failed (exit 65): see the app build's log")
        quiet = asked(plan, "quiet", title_id)
        if quiet:
            time.sleep(float(quiet))
        log.write("** BUILD SUCCEEDED **\n")

    PROG.stage("IPA pack", step="listing the files")
    if asked(plan, "no_ipa", title_id):
        PROG.end("no IPA (simulated)")
        return
    commit = git("rev-parse", "--short=12", "HEAD")
    if git("status", "--porcelain", "--untracked-files=no"):
        commit += "+dirty"
    info = {
        "CFBundleDisplayName": name,
        "CFBundleName": name,
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": str(family.version),
        "CFBundleExecutable": "nxnative",
        "DMTitleID": title_id,
        "DMCommit": commit,
        "DMChain": current,
        "DMLanguage": args.language or "en-US",
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
    }
    inputs = [{"name": p.name, "path": str(p), "size": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in family.files]
    app = f"Payload/{re.sub(r'[^A-Za-z0-9]', '', name) or 'Game'}.app/"
    partial = out.with_name(f".{out.name}.partial")
    out.parent.mkdir(parents=True, exist_ok=True)
    now = time.localtime()[:6]
    with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(zipfile.ZipInfo(app + "Info.plist", now), plistlib.dumps(info))
        archive.writestr(zipfile.ZipInfo(app + "nxnative", now), b"\xcf\xfa\xed\xfe simulated host of " + title_id.encode())
        archive.writestr(zipfile.ZipInfo(app + "dm/launcher.json", now), json.dumps({"schema": 1, "game": title_id, "settings": []}))
        archive.writestr(zipfile.ZipInfo(app + "sim/inputs.json", now), json.dumps({"kind": family.kind, "files": inputs, "dlc": family.dlc}, indent=1))
        archive.writestr(zipfile.ZipInfo(app + "sim/args.json", now), json.dumps(sys.argv[1:]))
        padding = asked(plan, "ipa_bytes", title_id)
        if padding:
            entry = zipfile.ZipInfo(app + "sim/padding.bin", now)
            entry.compress_type = zipfile.ZIP_STORED
            archive.writestr(entry, os.urandom(int(padding)))
    os.replace(partial, out)
    PROG.end(f"{out.stat().st_size:,} bytes")
    if not keep:
        shutil.rmtree(extract, ignore_errors=True)
    say(f"built {out}")


def build_mac_app(args: argparse.Namespace, plan: dict, family: Family, work: Path, out: Path, name: str, version: str, bundle_id: str) -> None:
    """The stages of --platform mac-app after the rewrite: the Mac shaders,
    the Mac host and the app, packed as dm/mac/pack_app.py packs it."""
    title_id = family.title_id
    logs = work / "logs"
    PROG.stage("Mac shaders", step="checking the inputs")
    current = chain()
    shaders = work / "mac-shaders"
    for stale in sorted(shaders.glob("b-*")) if shaders.is_dir() else []:
        if stale.name != f"b-{current}":
            shutil.rmtree(stale, ignore_errors=True)
    cache = shaders / f"b-{current}"
    reused = cache.is_dir()
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "cache.bin").write_bytes(b"Mac shaders " + current.encode())
    slow = asked(plan, "mac_slow", title_id)
    if slow:
        run_tool(float(slow), work, "dmsh_xlate")
    PROG.end("reused" if reused else "3 translated")

    PROG.stage("Mac host", step="building")
    host_log = logs / "mac_host.log"
    if asked(plan, "mac_host", title_id):
        host_log.write_text("dm/host/mac/host.m:12:5: error: use of undeclared identifier 'probe_atrace'\n1 error generated.\n", encoding="utf-8")
        PROG.end(ok=False)
        PROG.say(f"---- last lines of {host_log} ----\n" + host_log.read_text(encoding="utf-8").rstrip("\n"))
        raise BuildError(f"clang exit code 1 (full output: {host_log})")
    (work / "tools").mkdir(parents=True, exist_ok=True)
    (work / "tools" / "dmhost").write_bytes(b"\xcf\xfa\xed\xfe simulated Mac host of " + title_id.encode())
    PROG.end(str(work / "tools" / "dmhost"))

    PROG.stage("Mac app", step="starting")
    app_log = logs / "mac_app.log"
    if asked(plan, "mac_room", title_id):
        app_log.write_text(f"step: checking the room\nthe app needs 12.3 GB on the volume of {out.parent} (no APFS clones from the build there) and 0.4 GB are free\n", encoding="utf-8")
        PROG.end(ok=False)
        PROG.say(f"---- last lines of {app_log} ----\n" + app_log.read_text(encoding="utf-8").rstrip("\n"))
        raise BuildError(f"pack_app.py exit code 1 (full output: {app_log})")
    commit = git("rev-parse", "--short=12", "HEAD")
    if git("status", "--porcelain", "--untracked-files=no"):
        commit += "+dirty"
    current = chain()
    info = {
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "nxnative",
        "LSApplicationCategoryType": "public.app-category.games",
        "DMTitleID": title_id,
        "DMLanguage": args.language or "en-US",
        "DMSaveSyncChoice": 1,
        "DMCommit": commit,
        "DMChain": current,
    }
    inputs = [{"name": p.name, "path": str(p), "size": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in family.files]
    partial = out.with_name(out.name + ".partial")
    aside = out.with_name(out.name + ".old")
    shutil.rmtree(partial, ignore_errors=True)
    contents = partial / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources" / "sim").mkdir(parents=True)
    PROG.step("launcher and host (clones of the game files)")
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    (contents / "MacOS" / "nxnative").write_bytes(b"\xcf\xfa\xed\xfe simulated launcher of " + title_id.encode())
    (contents / "MacOS" / "dmhost").write_bytes((work / "tools" / "dmhost").read_bytes())
    PROG.step("game files")
    shutil.copytree(work / "extract", contents / "Resources" / "romfs")
    (contents / "Resources" / "sim" / "inputs.json").write_text(json.dumps({"kind": family.kind, "files": inputs, "dlc": family.dlc}, indent=1))
    (contents / "Resources" / "sim" / "args.json").write_text(json.dumps(sys.argv[1:]))
    # In place of the app there once whole, as RENAME_SWAP or its moves do.
    if out.exists():
        shutil.rmtree(aside, ignore_errors=True)
        os.rename(out, aside)
    os.rename(partial, out)
    shutil.rmtree(aside, ignore_errors=True)
    out.with_name(out.name + ".key").write_text(hashlib.sha256(json.dumps([commit, current, inputs]).encode()).hexdigest() + "\n")
    if not (out / "Contents" / "MacOS" / "dmhost").is_file():
        raise BuildError(f"no app at {out}")
    PROG.end(f"{out.name}, {sum(p.stat().st_size for p in out.rglob('*') if p.is_file()):,} bytes")
    say(f"done: {out} (0.0 GB); open it from Finder. Its save is in ~/Library/Application Support/nxnative/{title_id}/, "
        f"its log in ~/Library/Logs/nxnative/{title_id}.log")


def stop(sig, frame):
    raise Stopped(sig)


def cli(argv: list[str]) -> int:
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, stop)
    refused = {str(option) for option in scenario().get("refused") or []}
    try:
        main(parse_args(argv, refused))
    except BuildError as error:
        PROG.end(ok=False)
        PROG.say(f"[RED] {error}")
        return 1
    except KeyboardInterrupt:
        PROG.end(ok=False)
        PROG.say("[RED] interrupted")
        return 130
    except Stopped as stopped:
        PROG.end(ok=False)
        PROG.say(f"[RED] stopped ({signal.Signals(stopped.sig).name})")
        return 128 + int(stopped.sig)
    except Exception as error:
        PROG.end(ok=False)
        if PROG.mode == "json":
            PROG.say(f"[RED] {type(error).__name__}: {error}")
        raise
    return 0


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
