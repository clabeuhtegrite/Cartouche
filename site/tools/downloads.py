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
in its newest release. The pages say no version: a button says what it
downloads, and the file is the newest. The Builder and Installer workflows
publish the site again once they have published a release.

The newest is the highest version among the releases that are neither
drafts nor pre-releases and have the file, named as their workflow names it
and served from this repository's releases, as Cartouche Builder picks its
own updates (builder/mac/Sources/BuilderKit/Updater.swift): those of the
repository the workflow names, GITHUB_REPOSITORY, whose addresses GitHub's
answer gives wherever the repository lives, once it has moved to an
organization too. The script fails rather than publish a link to nothing: a
file a page asks for that no release has, a mark on something else than a
link, a page without a download link.

usage: downloads.py [--repository OWNER/NAME] RELEASES PAGE [PAGE ...]

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

# The repository whose releases they are, unless --repository says another.
REPOSITORY = "clabeuhtegrite/Cartouche"
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
    # Both files of one release, so that the Mac's button and Windows' give
    # the same version.
    "installer-mac": File("installer-v", "Cartouche-Installer-{version}-Mac.dmg", ("Cartouche-Installer-{version}-Windows.exe",), "Cartouche Installer for Mac"),
    "installer-windows": File("installer-v", "Cartouche-Installer-{version}-Windows.exe", ("Cartouche-Installer-{version}-Mac.dmg",), "Cartouche Installer for Windows"),
}


@dataclass(frozen=True)
class Download:
    key: str
    version: str
    url: str


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


def newest(releases: list[dict], key: str, repository: str = REPOSITORY) -> Download | None:
    """The file KEY in the newest release of REPOSITORY that has it, or
    None."""
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
        url = f"https://github.com/{repository}/releases/download/{tag}/{name}"
        asset = assets.get(name)
        # The file itself, from this repository's releases, and not empty.
        if not asset or str(asset.get("browser_download_url") or "").lower() != url.lower():
            continue
        if not isinstance(asset.get("size"), int) or asset["size"] <= 0:
            continue
        if any(other.format(version=version) not in assets for other in file.also):
            continue
        order = tuple(int(part) for part in parts.groups())
        if best is None or order > best[0]:
            best = (order, Download(key, version, url))
    return best[1] if best else None


LINK = re.compile(r"<a\b[^>]*>")
MARK = re.compile(r'\sdata-download="([^"]*)"')
HREF = re.compile(r'(\shref=")[^"]*(")')
MARKS = re.compile(r"\sdata-download[\w-]*=")


def rewrite(html: str, downloads: dict[str, Download]) -> tuple[str, list[str]]:
    """HTML with each marked link given its download, and the files it
    offers, once per link."""
    used: list[str] = []

    def link(match: re.Match[str]) -> str:
        tag = match.group(0)
        mark = MARK.search(tag)
        if not mark:
            return tag
        key = mark.group(1)
        if key not in FILES:
            raise DownloadError(f"no file is called {key!r}: one of {', '.join(FILES)}")
        if key not in downloads:
            file = FILES[key]
            raise DownloadError(f"no release {file.prefix}<version> has {file.named('<version>')}")
        tag, count = HREF.subn(lambda m: m.group(1) + downloads[key].url + m.group(2), tag)
        if count != 1:
            raise DownloadError(f"the link {match.group(0)!r} has no single href")
        used.append(key)
        return tag

    html = LINK.sub(link, html)
    # Every mark was on a link: nothing else of a page is filled in, not
    # even a version, which the pages do not show.
    if len(MARKS.findall(html)) != len(used):
        raise DownloadError("a data-download mark is on something else than a link")
    return html, used


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repository", default=REPOSITORY,
                        help="the repository the releases are of, OWNER/NAME, as GITHUB_REPOSITORY gives it (default: %(default)s)")
    parser.add_argument("releases", type=Path, help="GitHub's list of the repository's releases, as JSON")
    parser.add_argument("pages", type=Path, nargs="+", help="the pages to rewrite in place")
    args = parser.parse_args(argv)
    try:
        releases = load(args.releases)
        downloads = {key: found for key in FILES if (found := newest(releases, key, args.repository))}
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
            print(f"- {FILES[key].title} {download.version}: {download.url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
