#!/usr/bin/env python3
"""Add a release of Cartouche to the source its built-in SideStore reads.

The built-in SideStore reads app/sidestore-source.json from the main branch
(CARTOUCHE_SIDESTORE_SOURCE_URL in app/config.env). When the source lists a
higher version of Cartouche than the one installed, SideStore offers the
update in My Apps, downloads the IPA, checks it and installs it over the app,
without a computer. This script adds one version to that source, from the
IPA that the release workflow (.github/workflows/release.yml) has just
published, and checks the IPA as SideStore will:

- its bundle identifier is Cartouche's, and its version is CARTOUCHE_VERSION,
  which SideStore compares with the source (VerifyAppOperation);
- its version is higher than every version the source already lists;
- the size and SHA-256 written into the source are the IPA's own, which
  SideStore checks again after downloading it.

The source lists Cartouche and nothing else: never a game.

usage: add_release.py --ipa Cartouche.ipa --url URL --notes FILE [--version X.Y.Z]
                      [--date 2026-11-07T08:00:00Z] [--source FILE] [--config FILE]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")
# Versions the source keeps, newest first. SideStore offers the first one
# this iPhone's iOS supports.
KEPT_VERSIONS = 10

# How Cartouche presents itself in its SideStore. The icon is the one the
# app carries (app/icon/), served from the main branch.
APP_ENTRY = {
    "name": "Cartouche",
    "developerName": "Cartouche contributors",
    "subtitle": "Play your own games built with nxnative",
    "localizedDescription": (
        "Cartouche runs the games you build with nxnative from your own copies, "
        "renews itself without a computer, and gives them Increased Memory Limit. "
        "It never downloads a game."
    ),
    "iconURL": "https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/main/app/icon/AppIcon.appiconset/AppIcon1024.png",
    "tintColor": "#4F46E5",
    "category": "games",
}


class ReleaseError(Exception):
    pass


def parse_version(version: str) -> tuple[int, int, int]:
    match = VERSION.fullmatch(version)
    if not match:
        raise ReleaseError(f"not a major.minor.patch version: {version!r}")
    return tuple(int(part) for part in match.groups())


def read_config(path: Path) -> dict[str, str]:
    settings = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, _, value = line.partition("=")
            settings[key.strip()] = value.strip()
    return settings


def app_info(ipa: Path) -> dict:
    """The Info.plist of the one app at the top of an IPA's Payload."""
    with zipfile.ZipFile(ipa) as archive:
        plists = [
            name for name in archive.namelist()
            if len(PurePosixPath(name).parts) == 3
            and PurePosixPath(name).parts[0] == "Payload"
            and PurePosixPath(name).parts[1].endswith(".app")
            and PurePosixPath(name).parts[2] == "Info.plist"
        ]
        if len(plists) != 1:
            raise ReleaseError(f"{ipa.name}: an IPA must hold exactly one Payload/<name>.app/Info.plist")
        return plistlib.loads(archive.read(plists[0]))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def add_release(source: dict, *, ipa: Path, url: str, notes: str, date: str,
                bundle_id: str, version: str) -> dict:
    """The source with this release first among Cartouche's versions."""
    if not url.startswith("https://"):
        raise ReleaseError(f"the download address must be https: {url!r}")
    new = parse_version(version)

    info = app_info(ipa)
    if info.get("CFBundleIdentifier") != bundle_id:
        raise ReleaseError(f"{ipa.name}: bundle identifier {info.get('CFBundleIdentifier')!r}, not Cartouche's {bundle_id!r}")
    if info.get("CFBundleShortVersionString") != version:
        raise ReleaseError(f"{ipa.name}: version {info.get('CFBundleShortVersionString')!r}, not {version!r}")
    if info.get("CFBundleVersion") != version:
        raise ReleaseError(f"{ipa.name}: build version {info.get('CFBundleVersion')!r}, not {version!r}")

    apps = source.setdefault("apps", [])
    others = [app for app in apps if app.get("bundleIdentifier") != bundle_id]
    if others:
        raise ReleaseError("the source must list Cartouche and nothing else: "
                           + ", ".join(repr(app.get("bundleIdentifier")) for app in others))
    previous = apps[0].get("versions", []) if apps else []
    for release in previous:
        if parse_version(release["version"]) >= new:
            raise ReleaseError(f"the source already lists {release['version']}: a release must be higher")

    entry = {
        "version": version,
        "date": date,
        "localizedDescription": notes.strip(),
        "downloadURL": url,
        "size": ipa.stat().st_size,
        "sha256": sha256(ipa),
    }
    if info.get("MinimumOSVersion"):
        entry["minOSVersion"] = info["MinimumOSVersion"]

    source["apps"] = [{
        **APP_ENTRY,
        "bundleIdentifier": bundle_id,
        "versions": [entry, *previous][:KEPT_VERSIONS],
    }]
    return source


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ipa", type=Path, required=True, help="the published Cartouche IPA")
    parser.add_argument("--url", required=True, help="where SideStore downloads it")
    parser.add_argument("--notes", type=Path, required=True, help="release notes, shown by SideStore")
    parser.add_argument("--version", help="the released version (default: CARTOUCHE_VERSION)")
    parser.add_argument("--date", default=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    parser.add_argument("--source", type=Path, default=ROOT / "app" / "sidestore-source.json")
    parser.add_argument("--config", type=Path, default=ROOT / "app" / "config.env")
    args = parser.parse_args(argv)

    settings = read_config(args.config)
    try:
        version = args.version or settings["CARTOUCHE_VERSION"]
        source = json.loads(args.source.read_text(encoding="utf-8"))
        add_release(
            source,
            ipa=args.ipa,
            url=args.url,
            notes=args.notes.read_text(encoding="utf-8"),
            date=args.date,
            bundle_id=settings["CARTOUCHE_BUNDLE_ID"],
            version=version,
        )
    except (ReleaseError, KeyError, zipfile.BadZipFile) as exc:
        print(f"add_release: {exc}", file=sys.stderr)
        return 1
    args.source.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{args.source.name}: Cartouche {version} added")
    return 0


if __name__ == "__main__":
    sys.exit(main())
