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


# ---- Packages and NUPs named without their title ID (identify.py) -------------

# A header key of the tests' own, as a prod.keys line gives it: no console's.
HEADER_KEY = bytes(range(32))
ZELDA = "01007EF00011E000"


def write_keys(path: Path) -> Path:
    path.write_text(f"master_key_00 = {'00' * 16}\nheader_key = {HEADER_KEY.hex()}\n")
    return path


def xts_encrypt(key: bytes, tweak: bytes, data: bytes) -> bytes:
    """AES-128-XTS, the other way from identify.xts_decrypt."""
    from cartouche_builder.identify import AES128, _double

    cipher, step = AES128(key[:16]), AES128(key[16:]).encrypt(tweak)
    out = bytearray()
    for i in range(0, len(data), 16):
        block = bytes(a ^ b for a, b in zip(data[i : i + 16], step))
        out += bytes(a ^ b for a, b in zip(cipher.encrypt(block), step))
        step = _double(step)
    return bytes(out)


def nca(content_type: int, program_id: str, key: bytes = HEADER_KEY) -> bytes:
    """The first 0x400 bytes of an NCA, its header's sector encrypted as a
    console's are: magic, content type and program ID, nothing else."""
    sector = bytearray(0x200)
    sector[0:4] = b"NCA3"
    sector[5] = content_type
    struct.pack_into("<Q", sector, 0x10, int(program_id, 16))
    return bytes(0x200) + xts_encrypt(key, (1).to_bytes(16, "big"), bytes(sector))


def partition(magic: bytes, files: list[tuple[str, bytes]]) -> bytes:
    """A PFS0 (NSP) or HFS0 (XCI) partition of FILES."""
    names = b"".join(name.encode() + b"\0" for name, _ in files)
    table, offset, name_offset = b"", 0, 0
    for name, data in files:
        entry = struct.pack("<QQI", offset, len(data), name_offset)
        table += entry + (bytes(4) if magic == b"PFS0" else struct.pack("<I", 0x200) + bytes(40))
        offset += len(data)
        name_offset += len(name.encode()) + 1
    return magic + struct.pack("<III", len(files), len(names), 0) + table + names + b"".join(d for _, d in files)


def make_nsp(path: Path, files: list[tuple[str, bytes]]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(partition(b"PFS0", files))
    return path


def make_xci(path: Path, title_ids: list[str], key: bytes = HEADER_KEY) -> Path:
    """A cartridge dump: its header, and a secure partition with a content
    meta NCA and a program NCA for each title."""
    secure = []
    for i, title_id in enumerate(title_ids):
        secure.append((f"{i:032x}.cnmt.nca", nca(1, title_id, key)))
        secure.append((f"{i + 100:032x}.nca", nca(0, title_id, key)))
    root = partition(b"HFS0", [("update", partition(b"HFS0", [])), ("secure", partition(b"HFS0", secure))])
    head = bytearray(0x200)
    head[0x100:0x104] = b"HEAD"
    struct.pack_into("<Q", head, 0x130, 0x200)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(head) + root)
    return path


def make_nup(path: Path, packages: list[tuple[str, int]]) -> Path:
    """A NUP's superblock and table of contents: (title ID, kind) per package
    (0 base, 1 update, 2 DLC), with no files."""
    toc = b"TOC\x01" + struct.pack("<IQQQQQ", len(packages), 0, 0, 0x30 + 0x40 * len(packages), 0, 0)
    for title_id, kind in packages:
        toc += struct.pack("<QIIIIBBHIQI20x", int(title_id, 16), 0, 0xFFFFFFFF, 0xFFFFFFFF, 0, kind, 0, 0, 0, 0, 0)
    head = struct.pack("<4sHHQQ32sQQII16s32s", b"NUP\x01", 0x80, 0, 0x80, len(toc), bytes(32), 0x80 + len(toc), 0x80 + len(toc), len(packages), 0, bytes(16), bytes(32))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(head + toc)
    return path


def make_ipa(path: Path, info: dict, when=(2026, 11, 9, 21, 15, 52)) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(zipfile.ZipInfo("Payload/Game.app/Info.plist", when), plistlib.dumps(info))
        archive.writestr("Payload/Game.app/Game", b"binary")
    return path


FAKE_BUILD = r'''#!/usr/bin/env python3
# A stand-in for nxnative's scripts/build_ipa_from_nsp.py: the same options and
# JSON events, and an IPA of a few bytes; with --platform mac-app, a Mac app
# of a few bytes (Contents/Info.plist, MacOS/dmhost), written as nxnative's
# packer writes it: under <app>.partial, then renamed, its reuse key beside.
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
ap.add_argument("--keep-extracted", action=argparse.BooleanOptionalAction)
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
    # The builder's folder of links to a game's packages is named by its ID.
    found += [source.name] if re.fullmatch(r"[0-9A-F]{16}", source.name) else []
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
mac = a.platform == "mac-app"
# The runs, and the options of the last, of each platform.
prefix = "mac_" if mac else ""
if not mac:
    (work / "had_ipa.txt").write_text("yes" if Path(a.out).exists() else "no")
runs = work / f"{prefix}runs.txt"
runs.write_text(runs.read_text() + "run\n" if runs.exists() else "run\n")
(work / f"{prefix}args.json").write_text(json.dumps(sys.argv[1:]))
# As nxnative: the extracted files, the game's icon among them, and a shader cache.
(work / "extract").mkdir(exist_ok=True)
(work / "extract" / "game.bin").write_bytes(b"extracted" * 100)
(work / "extract" / "icon_AmericanEnglish.jpg").write_bytes(b"\xff\xd8\xff icon")
(work / "shader").mkdir(exist_ok=True)
(work / "shader" / "cache.bin").write_bytes(b"shader" * 50)
ev(ev="stage", k=1, n=2, name="extract", step="")
ev(ev="progress", k=1, name="extract", step="", done=1, total=2, unit="", est=False, note="", frac=0.5, eta=3, elapsed=0.1)
ev(ev="stage_end", k=1, name="extract", ok=True, summary="", elapsed=0.1)
print("not json: a tool's own line", flush=True)
print("a warning on stderr", file=sys.stderr, flush=True)
commit = subprocess.run(["git", "-C", str(repo), "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True).stdout.strip()
ev(ev="game", title_id=title_id, name=name, version="1.0.0", bundle_id="org.nxnative." + title_id.lower(), out=a.out, icon=str(work / "extract" / "icon_AmericanEnglish.jpg"))
if mac:
    if not a.out.endswith(".app"):
        ev(ev="say", msg=f"[RED] the Mac app (-o / OUT_IPA) must end in .app: {a.out}")
        sys.exit(1)
    if os.environ.get("FAKE_MAC_FAIL") == title_id:
        ev(ev="stage", k=2, n=3, name="Mac host", step="building")
        ev(ev="say", msg="[RED] the Mac host did not build (exit 1): see mac_host.log")
        sys.exit(1)
    if os.environ.get("FAKE_MAC_NO_SPACE") == title_id:
        ev(ev="stage", k=3, n=3, name="Mac app", step="starting")
        ev(ev="say", msg=f"---- last lines of mac_app.log ----\nthe app needs 12.3 GB on the volume of {Path(a.out).parent} (no APFS clones from the build there) and 0.1 GB are free")
        ev(ev="say", msg="[RED] pack_app.py failed (exit 1): see mac_app.log")
        sys.exit(1)
    if os.environ.get("FAKE_MAC_SLEEP") and os.environ.get("FAKE_SLEEP_ONLY", title_id) == title_id:
        ev(ev="stage", k=2, n=3, name="Mac shaders", step="")
        for _ in range(int(os.environ["FAKE_MAC_SLEEP"]) * 10):
            time.sleep(0.1)
    ev(ev="stage", k=3, n=3, name="Mac app", step="starting")
    if os.environ.get("FAKE_MAC_NO_APP") == title_id:
        ev(ev="stage_end", k=3, n=3, name="Mac app", ok=True, summary="", elapsed=0.1)
        sys.exit(0)
    import shutil
    app = Path(a.out)
    partial, old = Path(f"{app}.partial"), Path(f"{app}.old")
    shutil.rmtree(partial, ignore_errors=True)
    (partial / "Contents" / "MacOS").mkdir(parents=True)
    (partial / "Contents" / "Resources").mkdir()
    (partial / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
        "DMCommit": commit, "DMChain": "abcdef012345", "DMTitleID": title_id, "DMSaveSyncChoice": 1,
        "CFBundleShortVersionString": "1.0.0", "CFBundleIdentifier": "org.nxnative.mac." + title_id.lower(),
        "CFBundleName": name, "CFBundleExecutable": "nxnative"}))
    (partial / "Contents" / "MacOS" / "nxnative").write_bytes(b"launcher " + commit.encode())
    (partial / "Contents" / "MacOS" / "dmhost").write_bytes(b"host " + commit.encode())
    (partial / "Contents" / "Resources" / "romfs.img").write_bytes((work / "extract" / "game.bin").read_bytes())
    if app.exists():
        os.rename(app, old)
    os.rename(partial, app)
    shutil.rmtree(old, ignore_errors=True)
    Path(f"{app}.key").write_text(commit + "\n")
    ev(ev="stage_end", k=3, n=3, name="Mac app", ok=True, summary=app.name, elapsed=0.1)
    ev(ev="say", msg=f"done: {app} (0.0 GB); open it from Finder. Its save is in ~/Library/Application Support/nxnative/{title_id}/")
    sys.exit(0)
if os.environ.get("FAKE_FAIL") == title_id:
    ev(ev="say", msg="[RED] the fake build failed on purpose")
    sys.exit(1)
if os.environ.get("FAKE_NO_SPACE") == title_id:
    ev(ev="say", msg=f"[RED] less than 32 GB free on the volume of {work}")
    sys.exit(1)
if os.environ.get("FAKE_DAMAGED") == title_id:
    ev(ev="stage", k=2, n=2, name="unpack v131072", step="")
    ev(ev="say", msg="[RED] v131072: 3 file(s) whose bytes do not start as their names promise (a .zs file that is not a zstd stream), so the game files are damaged:\n"
       "  romfs/Texture/a.zs (12,288 bytes, starts 000000)\nPack again from a good copy of the game (--allow-damaged packs these files as they are)")
    sys.exit(1)
if os.environ.get("FAKE_METAL") == title_id:
    # As nxnative's check_metal, after its check of the files and with no
    # stage of its own, with the Xcode the Mac builds with: FAKE_XCODE.
    ev(ev="stage", k=2, n=2, name="check v131072 files", step="")
    selected = os.environ.get("FAKE_XCODE", "27.1")
    ev(ev="say", msg="[RED] this Mac's Metal compiler is not the one the shaders were tested with (dm/gfx/tools/dmsh_chain.lock): "
       "metal_iphoneos Apple metal version 32023.620 (metalfe-32023.620) (tested: Apple metal version 32023.850 (metalfe-32023.850)). "
       "Untested compilers are unsupported (GitHub issue #242). The Metal compiler is the selected Xcode's "
       f"(selected: Xcode {selected} in /Applications/Xcode.app/Contents/Developer): install Xcode 27.2 (macOS 26.6 or later) "
       "from https://developer.apple.com/download/all/ (beside a newer Xcode, as /Applications/Xcode-27.2.app), select it "
       "(sudo xcode-select -s /Applications/Xcode-27.2.app, or DEVELOPER_DIR=/Applications/Xcode-27.2.app/Contents/Developer for one build), "
       "then download its Metal toolchain (xcodebuild -downloadComponent MetalToolchain), "
       "or ALLOW_OTHER_METAL = True (--allow-other-metal) to build with this one anyway")
    sys.exit(1)
if os.environ.get("FAKE_CRASH") == title_id:
    print("Traceback (most recent call last):\n  File \"build_ipa_from_nsp.py\", line 1, in <module>\nKeyError: 'icon'", file=sys.stderr, flush=True)
    ev(ev="say", msg="[RED] KeyError: 'icon'")
    sys.exit(1)
# As nxnative's commit of 11 November 2026: the iOS app does not link, for
# every game (a BROKEN file in the checkout), or for one at any commit.
broken = (repo / "BROKEN").exists() and os.environ.get("FAKE_BROKEN_ONLY", title_id) == title_id
if broken or os.environ.get("FAKE_APP_BUILD") == title_id:
    ev(ev="stage", k=2, n=2, name="app build", step="starting")
    print("Undefined symbols for architecture arm64: \"_probe_atrace\"", file=sys.stderr, flush=True)
    ev(ev="say", msg="[RED] xcodebuild failed (exit 65): see the app build's log")
    sys.exit(1)
if os.environ.get("FAKE_SLEEP") and os.environ.get("FAKE_SLEEP_ONLY", title_id) == title_id:
    ev(ev="stage", k=2, n=2, name="shaders", step="")
    for _ in range(int(os.environ["FAKE_SLEEP"]) * 10):
        time.sleep(0.1)
ev(ev="stage", k=2, n=2, name="pack", step="")
if os.environ.get("FAKE_NO_IPA") == title_id:
    ev(ev="stage_end", k=2, n=2, name="pack", ok=True, summary="", elapsed=0.1)
    sys.exit(0)
out = Path(a.out)
out.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(out, "w") as archive:
    archive.writestr("Payload/Game.app/Info.plist", plistlib.dumps({
        "DMCommit": commit, "DMChain": "abcdef012345", "DMTitleID": title_id,
        "CFBundleShortVersionString": "1.0.0", "CFBundleIdentifier": "org.nxnative." + title_id.lower(),
        "CFBundleDisplayName": name}))
    archive.writestr("Payload/Game.app/Game", b"binary " + commit.encode())
ev(ev="stage_end", k=2, n=2, name="pack", ok=True, summary="", elapsed=0.1)
if a.keep_extracted is False:
    # Minutes after the game event in a real build: time for the builder to
    # read it, and keep the icon it names.
    import shutil
    time.sleep(0.3)
    shutil.rmtree(work / "extract")
sys.exit(0)
'''


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, check=True, env={**os.environ, **GIT_ENV}).stdout.strip()


def commit(repo: Path, message: str, files: dict[str, str | None]) -> str:
    """Commits FILES, by their text; None removes one."""
    for name, text in files.items():
        path = repo / name
        if text is None:
            path.unlink()
            continue
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


# What makes the fake nxnative fail, sleep or end without an IPA (or a Mac
# app), for a game.
FAKES = ("FAKE_FAIL", "FAKE_SLEEP", "FAKE_SLEEP_ONLY", "FAKE_NO_IPA", "FAKE_NO_SPACE", "FAKE_DAMAGED", "FAKE_METAL", "FAKE_XCODE", "FAKE_CRASH",
         "FAKE_APP_BUILD", "FAKE_BROKEN_ONLY", "FAKE_MAC_FAIL", "FAKE_MAC_NO_SPACE", "FAKE_MAC_SLEEP", "FAKE_MAC_NO_APP")


class Home(unittest.TestCase):
    """A test with a builder home, a home folder and a launch agents folder of its own."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self._env = {k: os.environ.get(k) for k in ("HOME", "CARTOUCHE_BUILDER_HOME", "CARTOUCHE_BUILDER_AGENTS", "CARTOUCHE_BUILDER_LANG", "CARTOUCHE_BUILDER_QUIET", *FAKES)}
        # A home folder of the test's own: what another app left in the
        # player's Library is never read, and the tests show it.
        os.environ["HOME"] = str(self.tmp / "user")
        os.environ["CARTOUCHE_BUILDER_HOME"] = str(self.tmp / "home")
        os.environ["CARTOUCHE_BUILDER_AGENTS"] = str(self.tmp / "agents")
        os.environ["CARTOUCHE_BUILDER_LANG"] = "en"
        os.environ["CARTOUCHE_BUILDER_QUIET"] = "1"
        for fake in FAKES:
            os.environ.pop(fake, None)
        from cartouche_builder import i18n

        i18n.set_language("en")

    def tearDown(self) -> None:
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self._tmp.cleanup()
