#!/usr/bin/env python3
"""Writes the IPAs of the storage tests: apps of a few made-up files, never a game.

usage: make_ipas.py PACK_IPA OUT [--big-mib N]

PACK_IPA is nxnative's dm/ios/tools/pack_ipa.py, at the commit Cartouche pins,
which packs these apps as it packs games: folders, Unix modes, links, DOS
times, the UTF-8 flag, small files deflated, large ones streamed, Zip64 past
4 GiB. OUT receives each app's folder (apps/), its IPA (ipas/) and
fixtures.json, which says what each IPA holds, for the tests to check what
they read back.

- small.ipa: an app of about 50 MiB, with a file of random bytes that does
  not deflate and a text that does, larger than a read of the storage, so
  that both cross the boundaries of the reads; an executable, a link, an
  empty file, a name with accents.
- big.ipa, with --big-mib: the same Info.plist and a file of zeros of N MiB,
  then a small file that lies past them, as a game's IPA holds files past
  4 GiB. The zeros are a sparse file in apps/, but pack_ipa.py writes them.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import random
import subprocess
import sys
import zipfile
from pathlib import Path

BUNDLE_ID = "io.github.clabeuhtegrite.cartouche.storagetest"
# Made up, as nxnative writes them: a commit of 12 digits, a shader chain.
COMMIT = "c0ffee5eed42"
CHAIN = "5eedc0ffee42"

WORDS = ("cartouche", "console", "partie", "sauvegarde", "niveau", "monde", "course", "manette",
         "écran", "jeu", "étoile", "château", "forêt", "rivière", "trésor", "épreuve")


def write(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def text(size: int, seed: int) -> bytes:
    """About SIZE bytes of words, which deflate to about a third."""
    rng = random.Random(seed)
    lines = []
    total = 0
    while total < size:
        line = " ".join(rng.choice(WORDS) + str(rng.randrange(10_000)) for _ in range(12)) + "\n"
        lines.append(line)
        total += len(line.encode())
    return "".join(lines).encode()[:size]


def info_plist(name: str, display: str, version: str) -> bytes:
    return plistlib.dumps({
        "CFBundleIdentifier": BUNDLE_ID + "." + name.lower(),
        "CFBundleName": name,
        "CFBundleDisplayName": display,
        "CFBundleExecutable": name,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1",
        "CFBundlePackageType": "APPL",
        "DMCommit": COMMIT,
        "DMChain": CHAIN,
    })


def small_app(root: Path) -> Path:
    app = root / "StorageTest.app"
    write(app / "Info.plist", info_plist("StorageTest", "Essai de stockage", "1.2.0"))
    write(app / "StorageTest", random.Random(1).randbytes(300_000), 0o755)
    # Stored (--store .bin): 24 MiB that do not deflate, three reads of 8 MiB.
    write(app / "romfs" / "data.bin", random.Random(2).randbytes(24 << 20 | 12_345))
    # Deflated: about 9 MiB once deflated, more than a read of 8 MiB too.
    write(app / "romfs" / "texte.txt", text(30 << 20, 3))
    write(app / "Données" / "sauvegarde é.txt", "Partie du 10 novembre, château de la forêt.\n".encode())
    write(app / "vide", b"")
    (app / "Frameworks").mkdir(parents=True, exist_ok=True)
    os.symlink("romfs/data.bin", app / "lien")
    return app


def big_app(root: Path, mib: int) -> Path:
    app = root / "BigTest.app"
    write(app / "Info.plist", info_plist("BigTest", "Gros essai", "2.0.0"))
    write(app / "BigTest", random.Random(4).randbytes(65_536), 0o755)
    zeros = app / "romfs" / "zeros.bin"
    zeros.parent.mkdir(parents=True, exist_ok=True)
    with open(zeros, "wb") as f:
        f.truncate(mib << 20)
    # After romfs/ in the archive, past the zeros.
    write(app / "suite" / "fin.bin", random.Random(5).randbytes(1 << 20 | 777))
    return app


def pack(pack_ipa: Path, ipa: Path, app: Path) -> None:
    subprocess.run([sys.executable, str(pack_ipa), str(ipa), "--store", ".bin", "--no-reuse",
                    f"Payload/{app.name}={app}"], check=True, stdout=subprocess.DEVNULL)
    # pack_ipa.py keeps an index beside the IPA, for its next pack.
    for extra in ipa.parent.glob(ipa.name + ".idx*"):
        extra.unlink()


def describe(ipa: Path, app: Path, key: str) -> dict:
    """What the IPA holds, as Python's zipfile reads it."""
    with zipfile.ZipFile(ipa) as archive:
        infos = archive.infolist()
        entries = [{"name": i.filename, "size": i.file_size, "method": i.compress_type, "offset": i.header_offset}
                   for i in infos]
    files = {}
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            files[relative] = {"link": os.readlink(path)}
        elif path.is_dir():
            files[relative] = {"folder": True}
        elif path.stat().st_size > 64 << 20:
            files[relative] = {"size": path.stat().st_size}
        else:
            files[relative] = {"size": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                               "mode": path.stat().st_mode & 0o777}
    info = plistlib.loads((app / "Info.plist").read_bytes())
    return {
        "ipa": str(ipa),
        "app": str(app),
        "bundle": f"Payload/{app.name}",
        "size": ipa.stat().st_size,
        "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest() if ipa.stat().st_size < 1 << 30 else None,
        "info": info,
        "entries": entries,
        "files": files,
        "key": key,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pack_ipa", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--big-mib", type=int, default=0, help="also big.ipa, with a file of N MiB of zeros")
    args = parser.parse_args(argv)
    out = args.out.resolve()
    (out / "apps").mkdir(parents=True, exist_ok=True)
    (out / "ipas").mkdir(parents=True, exist_ok=True)

    fixtures = {}
    app = small_app(out / "apps")
    pack(args.pack_ipa, out / "ipas" / "small.ipa", app)
    fixtures["small"] = describe(out / "ipas" / "small.ipa", app, "small")
    if args.big_mib:
        app = big_app(out / "apps", args.big_mib)
        pack(args.pack_ipa, out / "ipas" / "big.ipa", app)
        fixtures["big"] = describe(out / "ipas" / "big.ipa", app, "big")
        after = next(e for e in fixtures["big"]["entries"] if e["name"].endswith("suite/fin.bin"))
        if after["offset"] < 1 << 32:
            print(f"big.ipa: suite/fin.bin lies at {after['offset']}, before 4 GiB", file=sys.stderr)
            return 1
    (out / "fixtures.json").write_text(json.dumps(fixtures, indent=2, ensure_ascii=False, default=str))
    for key, fixture in fixtures.items():
        print(f"{key}.ipa: {fixture['size']} bytes, {len(fixture['entries'])} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
