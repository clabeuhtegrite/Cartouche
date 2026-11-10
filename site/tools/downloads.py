#!/usr/bin/env python3
"""Give the site's download links the newest file of their releases.

Cartouche Builder and the Cartouche Installer are releases of this
repository, builder-v<version> and installer-v<version>, beside Cartouche's
own v<version>. GitHub's /releases/latest names a single release of the
three, and each file carries its version in its name, so no address of
GitHub's stays the newest Builder or Installer. The site's buttons and its
download page (site/download/) link to the files themselves, and the
Showcase site workflow (.github/workflows/site.yml) runs this script on the
copies it publishes: each link marked data-download="<file>" gets that file
in its newest release, each element marked data-download-version="<file>"
its version, and each one marked data-download-size="<file>" its size, in
the element's language. The Builder and Installer workflows publish the site
again once they have published a release.

The newest is the highest version among the releases that are neither
drafts nor pre-releases and have the file, named as their workflow names it
and served from this repository's releases, as Cartouche Builder picks its
own updates (builder/mac/Sources/BuilderKit/Updater.swift). The script fails
rather than publish a link to nothing: a file a page asks for that no release
has, a mark it cannot fill, a page without a download link.

usage: downloads.py RELEASES PAGE [PAGE ...]

RELEASES is GitHub's list of releases, as `gh api --paginate --slurp
repos/<owner>/<repo>/releases` writes it: a list of pages, or a single list.
Each PAGE is rewritten in place; what each link now gives goes to the
standard output, in Markdown, for the run's summary.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPOSITORY = "clabeuhtegrite/Cartouche"
DOWNLOADS = f"https://github.com/{REPOSITORY}/releases/download/"
VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")


@dataclass(frozen=True)
class File:
    """A file the site offers: the releases it comes from, its name in
    them, and the other files a release must have for it to count."""

    prefix: str
    name: str
    also: tuple[str, ...] = ()
    title: str = ""

    def named(self, version: str) -> str:
        return self.name.format(version=version)


FILES = {
    # The disk image and its SHA-256, which the app's updates need too.
    "builder": File("builder-v", "Cartouche-Builder-{version}.dmg", ("Cartouche-Builder-{version}.dmg.sha256",), "Cartouche Builder"),
    # Both files of one release, so that the Mac's and Windows' are the
    # same version, as the site says.
    "installer-mac": File("installer-v", "Cartouche-Installer-{version}-Mac.dmg", ("Cartouche-Installer-{version}-Windows.exe",), "Cartouche Installer for Mac"),
    "installer-windows": File("installer-v", "Cartouche-Installer-{version}-Windows.exe", ("Cartouche-Installer-{version}-Mac.dmg",), "Cartouche Installer for Windows"),
}


@dataclass(frozen=True)
class Download:
    key: str
    version: str
    url: str
    size: int


class DownloadError(Exception):
    pass


def load(path: Path) -> list[dict]:
    """The releases of GitHub's answer: its pages put end to end."""
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise DownloadError(f"{path} is not a list of releases")
    releases: list[dict] = []
    for item in data:
        releases.extend(item if isinstance(item, list) else [item])
    if not all(isinstance(release, dict) for release in releases):
        raise DownloadError(f"{path} is not a list of releases")
    return releases


def newest(releases: list[dict], key: str) -> Download | None:
    """The file KEY in the newest release that has it, or None."""
    file = FILES[key]
    best: tuple[tuple[int, ...], Download] | None = None
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        tag = str(release.get("tag_name") or "")
        version = tag[len(file.prefix):] if tag.startswith(file.prefix) else ""
        parts = VERSION.fullmatch(version)
        if not parts:
            continue
        assets = {
            asset.get("name"): asset
            for asset in release.get("assets") or []
            if isinstance(asset, dict) and asset.get("state", "uploaded") == "uploaded"
        }
        name = file.named(version)
        url = DOWNLOADS + tag + "/" + name
        asset = assets.get(name)
        # The file itself, from this repository's releases, and not empty.
        if not asset or str(asset.get("browser_download_url") or "").lower() != url.lower():
            continue
        size = asset.get("size")
        if not isinstance(size, int) or size <= 0:
            continue
        if any(other.format(version=version) not in assets for other in file.also):
            continue
        order = tuple(int(part) for part in parts.groups())
        if best is None or order > best[0]:
            best = (order, Download(key, version, url, size))
    return best[1] if best else None


def size_text(size: int, lang: str) -> str:
    """A size as the Finder and Windows' download show it, in megabytes of
    a million bytes: 3,4 Mo in French, 3.4 MB in English."""
    megabytes = size / 1_000_000
    text = f"{megabytes:.1f}" if megabytes < 100 else f"{megabytes:.0f}"
    return text.replace(".", ",") + " Mo" if lang == "fr" else text + " MB"


LINK = re.compile(r"<a\b[^>]*>")
MARK = re.compile(r'\sdata-download="([^"]*)"')
HREF = re.compile(r'(\shref=")[^"]*(")')
TEXT = re.compile(r'(<(\w+)\b[^>]*\sdata-download-(version|size)="([^"]*)"[^>]*>)([^<]*)(</\2>)')
LANG = re.compile(r'\slang="(fr|en)"')
MARKS = re.compile(r'\sdata-download(?:-version|-size)?="')


def rewrite(html: str, downloads: dict[str, Download]) -> tuple[str, list[str]]:
    """HTML with each marked link and text given its download, and the
    files it offers, once per mark."""
    used: list[str] = []

    def find(key: str) -> Download:
        if key not in FILES:
            raise DownloadError(f"no file is called {key!r}: one of {', '.join(FILES)}")
        if key not in downloads:
            file = FILES[key]
            raise DownloadError(f"no release {file.prefix}<version> has {file.named('<version>')}")
        used.append(key)
        return downloads[key]

    def link(match: re.Match[str]) -> str:
        tag = match.group(0)
        mark = MARK.search(tag)
        if not mark:
            return tag
        download = find(mark.group(1))
        tag, count = HREF.subn(lambda m: m.group(1) + download.url + m.group(2), tag)
        if count != 1:
            raise DownloadError(f"the link {match.group(0)!r} has no single href")
        return tag

    def text(match: re.Match[str]) -> str:
        start, _, kind, key, _, end = match.groups()
        download = find(key)
        if kind == "version":
            return start + download.version + end
        lang = LANG.search(start)
        if not lang:
            raise DownloadError(f"{start!r} says a size without its language")
        return start + size_text(download.size, lang.group(1)) + end

    html = LINK.sub(link, html)
    html = TEXT.sub(text, html)
    # Every mark was one of the above: on a link, or on an element of text alone.
    if len(MARKS.findall(html)) != len(used):
        raise DownloadError("a data-download mark is on something else than a link or an element of text alone")
    return html, used


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("releases", type=Path, help="GitHub's list of the repository's releases, as JSON")
    parser.add_argument("pages", type=Path, nargs="+", help="the pages to rewrite in place")
    args = parser.parse_args(argv)
    try:
        releases = load(args.releases)
        downloads = {key: found for key in FILES if (found := newest(releases, key))}
        offered: set[str] = set()
        rewritten: list[tuple[Path, str]] = []
        for page in args.pages:
            html, used = rewrite(page.read_text(encoding="utf-8"), downloads)
            if not used:
                raise DownloadError(f"{page} has no download link")
            rewritten.append((page, html))
            offered.update(used)
        # Every page or none.
        for page, html in rewritten:
            page.write_text(html, encoding="utf-8")
    except (OSError, ValueError, DownloadError) as error:
        print(f"downloads.py: {error}", file=sys.stderr)
        return 1
    print("The site's downloads:\n")
    for key in FILES:
        if key in offered:
            download = downloads[key]
            print(f"- {FILES[key].title} {download.version}, {size_text(download.size, 'en')}: {download.url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
