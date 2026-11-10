"""What the tests build on: fake game files, a fake nxnative and a builder home
of their own. Nothing here is a game: the "dumps" are a few bytes with the
layout nxnative reads, and the fake build script writes an IPA of a few bytes."""

from __future__ import annotations

import os
import plistlib
import struct
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

GIT_ENV = {
    "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.invalid",
    "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.invalid",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
}

MKW = "0400C3F00006E000"
ODYSSEY = "0100000000010000"
HOLLOW = "0100A0000E2F0000"


def npdm(title_id: str) -> bytes:
    """A main.npdm with only what titles.npdm_title_id reads: META, and an
    ACI0 section with the program ID."""
    data = bytearray(0x200)
    data[0:4] = b"META"
    struct.pack_into("<II", data, 0x70, 0x100, 0x40)
    data[0x100:0x104] = b"ACI0"
    struct.pack_into("<Q", data, 0x110, int(title_id, 16))
    return bytes(data)


def make_dump(folder: Path, title_id: str, romfs_file: str = "data.bin") -> Path:
    (folder / "base" / "exefs").mkdir(parents=True, exist_ok=True)
    (folder / "base" / "exefs" / "main.npdm").write_bytes(npdm(title_id))
    (folder / "base" / "exefs" / "main").write_bytes(b"code")
    (folder / "base" / "romfs").mkdir(parents=True, exist_ok=True)
    (folder / "base" / "romfs" / romfs_file).write_bytes(b"romfs")
    return folder


def make_zip_dump(path: Path, title_id: str, root: str = "Game") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    prefix = root + "/" if root else ""
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(zipfile.ZipInfo(prefix + "base/exefs/main.npdm", (2024, 5, 6, 7, 8, 10)), npdm(title_id))
        archive.writestr(zipfile.ZipInfo(prefix + "base/exefs/main", (2024, 5, 6, 7, 8, 10)), b"code")
        archive.writestr(zipfile.ZipInfo(prefix + "base/romfs/data.bin", (2024, 5, 6, 7, 8, 12)), b"romfs")
        archive.writestr("__MACOSX/" + prefix + "base/exefs/._main.npdm", b"apple double")
    return path


def make_ipa(path: Path, info: dict, when=(2026, 11, 9, 21, 15, 52)) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(zipfile.ZipInfo("Payload/Game.app/Info.plist", when), plistlib.dumps(info))
        archive.writestr("Payload/Game.app/Game", b"binary")
    return path


FAKE_BUILD = r'''#!/usr/bin/env python3
# A stand-in for nxnative's scripts/build_ipa_from_nsp.py: the same options and
# JSON events, and an IPA of a few bytes.
import argparse, json, os, plistlib, struct, subprocess, sys, time, zipfile
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("nsp_dir")
ap.add_argument("-k", "--keys")
ap.add_argument("--work-dir")
ap.add_argument("-o", "--out")
ap.add_argument("--platform")
ap.add_argument("--progress")
ap.add_argument("-l", "--language")
a = ap.parse_args()
repo = Path(__file__).resolve().parents[1]

def ev(**fields):
    fields.setdefault("t", round(time.time(), 3))
    print(json.dumps(fields), flush=True)

source = Path(a.nsp_dir)
npdm = source / "base/exefs/main.npdm"
if npdm.is_file():
    data = npdm.read_bytes()
    offset = struct.unpack_from("<I", data, 0x70)[0]
    title_id = "%016X" % struct.unpack_from("<Q", data, offset + 0x10)[0]
else:
    import re
    names = [source.name] + ([p.name for p in source.iterdir()] if source.is_dir() else [])
    found = [m.group(1) for n in names if (m := re.search(r"\[([0-9A-Fa-f]{16})\]", n))]
    title_id = "%016X" % (int(found[0], 16) & ~0xFFF)
name = ""
tsv = repo / "dm/games" / title_id / "game.tsv"
if tsv.is_file():
    for line in tsv.read_text().splitlines():
        if line.startswith("name\t"):
            name = line.split("\t", 1)[1]
name = name or source.name
work = Path(a.work_dir)
work.mkdir(parents=True, exist_ok=True)
runs = work / "runs.txt"
runs.write_text(runs.read_text() + "run\n" if runs.exists() else "run\n")
(work / "args.json").write_text(json.dumps(sys.argv[1:]))
ev(ev="stage", k=1, n=2, name="extract", step="")
ev(ev="progress", k=1, name="extract", step="", done=1, total=2, unit="", est=False, note="", frac=0.5, eta=3, elapsed=0.1)
ev(ev="stage_end", k=1, name="extract", ok=True, summary="", elapsed=0.1)
print("not json: a tool's own line", flush=True)
print("a warning on stderr", file=sys.stderr, flush=True)
commit = subprocess.run(["git", "-C", str(repo), "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True).stdout.strip()
ev(ev="game", title_id=title_id, name=name, version="1.0.0", bundle_id="org.nxnative." + title_id.lower(), out=a.out, icon=None)
if os.environ.get("FAKE_FAIL") == title_id:
    ev(ev="say", msg="[RED] the fake build failed on purpose")
    sys.exit(1)
if os.environ.get("FAKE_SLEEP"):
    ev(ev="stage", k=2, n=2, name="shaders", step="")
    for _ in range(int(os.environ["FAKE_SLEEP"]) * 10):
        time.sleep(0.1)
ev(ev="stage", k=2, n=2, name="pack", step="")
out = Path(a.out)
out.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(out, "w") as archive:
    archive.writestr("Payload/Game.app/Info.plist", plistlib.dumps({
        "DMCommit": commit, "DMChain": "abcdef012345", "DMTitleID": title_id,
        "CFBundleShortVersionString": "1.0.0", "CFBundleIdentifier": "org.nxnative." + title_id.lower(),
        "CFBundleDisplayName": name}))
    archive.writestr("Payload/Game.app/Game", b"binary " + commit.encode())
ev(ev="stage_end", k=2, n=2, name="pack", ok=True, summary="", elapsed=0.1)
sys.exit(0)
'''


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, check=True, env={**os.environ, **GIT_ENV}).stdout.strip()


def commit(repo: Path, message: str, files: dict[str, str]) -> str:
    for name, text in files.items():
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def make_engine_remote(folder: Path, games: dict[str, str]) -> Path:
    """A git repository laid out as nxnative: its build script, profiles and
    Python requirements."""
    folder.mkdir(parents=True)
    git(folder, "init", "-q", "-b", "main")
    files = {
        "scripts/build_ipa_from_nsp.py": FAKE_BUILD,
        ".github/requirements/tools.txt": "# none for the fake\n",
        "dm/host/host.c": "int main(void) { return 0; }\n",
        "dm/gfx/nvn/dmsh_chain.h": "#define DMSH_CHAIN \"abcdef012345\"\n",
        "README.md": "# nxnative (fake)\n",
    }
    for title_id, name in games.items():
        files[f"dm/games/{title_id}/game.tsv"] = f"# {name}\ntitle_id\t{title_id}\nname\t{name}\nipa\t{name.replace(' ', '')}.ipa\n"
    commit(folder, "Initial commit", files)
    return folder


class Home(unittest.TestCase):
    """A test with a builder home, a legacy home and a launch agents folder of its own."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self._env = {k: os.environ.get(k) for k in ("CARTOUCHE_BUILDER_HOME", "CARTOUCHE_BUILDER_LEGACY_HOME", "CARTOUCHE_BUILDER_AGENTS", "CARTOUCHE_BUILDER_LANG", "CARTOUCHE_BUILDER_QUIET", "FAKE_FAIL", "FAKE_SLEEP")}
        os.environ["CARTOUCHE_BUILDER_HOME"] = str(self.tmp / "home")
        os.environ["CARTOUCHE_BUILDER_LEGACY_HOME"] = str(self.tmp / "legacy")
        os.environ["CARTOUCHE_BUILDER_AGENTS"] = str(self.tmp / "agents")
        os.environ["CARTOUCHE_BUILDER_LANG"] = "en"
        os.environ["CARTOUCHE_BUILDER_QUIET"] = "1"
        os.environ.pop("FAKE_FAIL", None)
        os.environ.pop("FAKE_SLEEP", None)
        from cartouche_builder import i18n

        i18n.set_language("en")

    def tearDown(self) -> None:
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self._tmp.cleanup()
