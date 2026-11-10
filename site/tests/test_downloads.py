"""The script that gives the site's download links the newest file of their
releases when the site is published (site/tools/downloads.py).

    python3 -m unittest discover -s site/tests -v

Releases here are made up, as GitHub's API lists them: no file is fetched.
"""

from __future__ import annotations

import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

SITE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SITE / "tools"))

import downloads  # noqa: E402

BASE = "https://github.com/clabeuhtegrite/Cartouche/releases/download/"
PAGES = [SITE / "index.html", SITE / "download" / "index.html"]


def release(tag: str, *names: str, draft: bool = False, prerelease: bool = False, host: str = BASE,
            size: int = 3_390_144, sizes: dict[str, int] | None = None, state: str = "uploaded") -> dict:
    return {
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "assets": [
            {"name": name, "size": (sizes or {}).get(name, size), "state": state, "browser_download_url": host + tag + "/" + name}
            for name in names
        ],
    }


def builder(version: str, **options) -> dict:
    name = f"Cartouche-Builder-{version}.dmg"
    return release(f"builder-v{version}", name, name + ".sha256", **options)


def installer(version: str, *systems: str, **options) -> dict:
    names = {"mac": f"Cartouche-Installer-{version}-Mac.dmg", "windows": f"Cartouche-Installer-{version}-Windows.exe"}
    return release(f"installer-v{version}", *(names[system] for system in systems or ("mac", "windows")), **options)


def offered(releases: list[dict]) -> dict[str, downloads.Download]:
    return {key: found for key in downloads.FILES if (found := downloads.newest(releases, key))}


class NewestTests(unittest.TestCase):
    def test_the_highest_version_rather_than_the_last_published(self) -> None:
        found = downloads.newest([builder("0.9.0"), builder("0.10.0"), builder("0.2.0")], "builder")
        self.assertEqual(found.version, "0.10.0")
        self.assertEqual(found.url, BASE + "builder-v0.10.0/Cartouche-Builder-0.10.0.dmg")
        self.assertEqual(found.size, 3_390_144)

    def test_neither_drafts_nor_pre_releases_nor_other_programs(self) -> None:
        releases = [
            builder("0.2.0"),
            builder("0.4.0", draft=True),
            builder("0.3.0", prerelease=True),
            release("v0.10.0", "Cartouche-0.10.0.ipa", prerelease=True),
            installer("0.5.0"),
            release("builder-v0.5.0-beta", "Cartouche-Builder-0.5.0-beta.dmg", "Cartouche-Builder-0.5.0-beta.dmg.sha256"),
        ]
        self.assertEqual(downloads.newest(releases, "builder").version, "0.2.0")
        self.assertEqual(downloads.newest(releases, "installer-windows").version, "0.5.0")

    def test_a_release_with_all_its_files(self) -> None:
        # The Builder's SHA-256, which its updates read; the Installer's two
        # files, so that both buttons give the same version.
        releases = [builder("0.2.0"), release("builder-v0.3.0", "Cartouche-Builder-0.3.0.dmg"), installer("0.1.0"), installer("0.2.0", "mac")]
        self.assertEqual(downloads.newest(releases, "builder").version, "0.2.0")
        self.assertEqual(downloads.newest(releases, "installer-mac").version, "0.1.0")
        self.assertEqual(downloads.newest(releases, "installer-windows").version, "0.1.0")

    def test_only_this_repository_s_files_uploaded_whole(self) -> None:
        releases = [
            builder("0.2.0"),
            builder("0.3.0", host="https://example.com/clabeuhtegrite/Cartouche/releases/download/"),
            builder("0.4.0", host="https://github.com/someone-else/Cartouche/releases/download/"),
            builder("0.5.0", state="starter"),
            builder("0.6.0", size=0),
        ]
        self.assertEqual(downloads.newest(releases, "builder").version, "0.2.0")

    def test_nothing_without_a_release(self) -> None:
        self.assertIsNone(downloads.newest([installer("0.1.0")], "builder"))

    def test_the_pages_of_github_s_answer(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "releases.json"
            path.write_text(json.dumps([[builder("0.2.0")], [installer("0.1.0")]]))
            self.assertEqual([r["tag_name"] for r in downloads.load(path)], ["builder-v0.2.0", "installer-v0.1.0"])
            path.write_text(json.dumps([builder("0.2.0")]))
            self.assertEqual([r["tag_name"] for r in downloads.load(path)], ["builder-v0.2.0"])
            path.write_text(json.dumps({"message": "Bad credentials"}))
            with self.assertRaises(downloads.DownloadError):
                downloads.load(path)


class RewriteTests(unittest.TestCase):
    PAGE = (
        '<a class="btn" data-download="builder" href="' + BASE + 'builder-v0.1.0/Cartouche-Builder-0.1.0.dmg">Download</a>'
        ' <a href="https://github.com/clabeuhtegrite/Cartouche">GitHub</a>'
        ' <p>Version <span data-download-version="builder">0.1.0</span> ·'
        ' <span lang="fr" data-download-size="builder">1,0 Mo</span><span lang="en" data-download-size="builder">1.0 MB</span></p>'
    )

    def setUp(self) -> None:
        self.offered = offered([builder("0.2.0"), builder("0.3.0"), installer("0.2.0")])

    def test_each_mark_gets_its_file(self) -> None:
        html, used = downloads.rewrite(self.PAGE, self.offered)
        self.assertIn('data-download="builder" href="' + BASE + 'builder-v0.3.0/Cartouche-Builder-0.3.0.dmg"', html)
        self.assertIn('<span data-download-version="builder">0.3.0</span>', html)
        self.assertIn('<span lang="fr" data-download-size="builder">3,4 Mo</span>', html)
        self.assertIn('<span lang="en" data-download-size="builder">3.4 MB</span>', html)
        self.assertIn('<a href="https://github.com/clabeuhtegrite/Cartouche">GitHub</a>', html)
        self.assertEqual(used, ["builder"] * 4)

    def test_a_file_no_release_has(self) -> None:
        with self.assertRaisesRegex(downloads.DownloadError, r"builder-v<version>"):
            downloads.rewrite(self.PAGE, {})

    def test_a_file_it_does_not_know(self) -> None:
        with self.assertRaisesRegex(downloads.DownloadError, "no file is called"):
            downloads.rewrite('<a data-download="cartouche" href="#">x</a>', self.offered)

    def test_a_size_without_its_language(self) -> None:
        with self.assertRaisesRegex(downloads.DownloadError, "language"):
            downloads.rewrite('<span data-download-size="builder">1 MB</span>', self.offered)

    def test_a_mark_it_cannot_fill(self) -> None:
        for html in ('<p data-download-version="builder"><b>0.1.0</b></p>', '<button data-download="builder">x</button>', '<a data-download="builder">x</a>'):
            with self.subTest(html=html), self.assertRaises(downloads.DownloadError):
                downloads.rewrite(html, self.offered)

    def test_sizes_as_the_finder_shows_them(self) -> None:
        self.assertEqual(downloads.size_text(3_390_144, "fr"), "3,4 Mo")
        self.assertEqual(downloads.size_text(19_565_087, "en"), "19.6 MB")
        self.assertEqual(downloads.size_text(123_456_789, "fr"), "123 Mo")


class MainTests(unittest.TestCase):
    def run_on_the_pages(self, releases: list) -> tuple[int, list[str], str, str]:
        with tempfile.TemporaryDirectory() as folder:
            listed = Path(folder) / "releases.json"
            listed.write_text(json.dumps(releases))
            copies = []
            for number, page in enumerate(PAGES):
                copy = Path(folder) / f"{number}.html"
                copy.write_text(page.read_text(encoding="utf-8"), encoding="utf-8")
                copies.append(copy)
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = downloads.main([str(listed), *map(str, copies)])
            return code, [copy.read_text(encoding="utf-8") for copy in copies], out.getvalue(), err.getvalue()

    def test_the_site_s_pages_get_the_newest_files(self) -> None:
        code, pages, out, _ = self.run_on_the_pages([[builder("0.2.0"), installer("0.1.0")], [builder("0.3.0"), installer("0.2.0", size=19_565_087)]])
        self.assertEqual(code, 0)
        for html in pages:
            self.assertNotIn("builder-v0.2.0", html)
            self.assertNotIn("installer-v0.1.0", html)
            self.assertIn(BASE + "builder-v0.3.0/Cartouche-Builder-0.3.0.dmg", html)
            self.assertIn(BASE + "installer-v0.2.0/Cartouche-Installer-0.2.0-Mac.dmg", html)
            self.assertIn(BASE + "installer-v0.2.0/Cartouche-Installer-0.2.0-Windows.exe", html)
            self.assertIn('<span lang="fr" data-download-size="installer-mac">19,6 Mo</span>', html)
        self.assertIn("Cartouche Builder 0.3.0, 3.4 MB: " + BASE + "builder-v0.3.0/Cartouche-Builder-0.3.0.dmg", out)

    def test_the_pages_as_they_are_for_the_releases_they_name(self) -> None:
        # Published from the releases and the sizes the pages show, they keep
        # every byte: what they say is what the publication writes.
        files: dict[str, tuple[str, str, int]] = {}
        for page in PAGES:
            text = page.read_text(encoding="utf-8")
            for key, url in re.findall(r'data-download="([\w-]+)" href="([^"]+)"', text):
                tag, name = url.removeprefix(BASE).split("/")
                files[key] = (tag, name, files.get(key, ("", "", 0))[2])
            for key, size in re.findall(r'lang="en" data-download-size="([\w-]+)">([\d.]+) MB<', text):
                files[key] = files[key][:2] + (round(float(size) * 1_000_000),)
        self.assertEqual(sorted(files), sorted(downloads.FILES))
        tags: dict[str, dict[str, int]] = {}
        for tag, name, size in files.values():
            tags.setdefault(tag, {})[name] = size
            if name.startswith("Cartouche-Builder-"):
                tags[tag][name + ".sha256"] = 94
        code, pages, _, err = self.run_on_the_pages([release(tag, *sizes, sizes=sizes) for tag, sizes in tags.items()])
        self.assertEqual(code, 0, err)
        self.assertEqual(pages, [page.read_text(encoding="utf-8") for page in PAGES])

    def test_nothing_written_without_a_file_a_page_needs(self) -> None:
        code, pages, _, err = self.run_on_the_pages([builder("0.3.0")])
        self.assertEqual(code, 1)
        self.assertIn("installer-v<version>", err)
        self.assertEqual(pages, [page.read_text(encoding="utf-8") for page in PAGES])

    def test_a_page_without_a_download(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            listed = Path(folder) / "releases.json"
            listed.write_text(json.dumps([builder("0.2.0")]))
            page = Path(folder) / "page.html"
            page.write_text("<p>Nothing to download.</p>")
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(downloads.main([str(listed), str(page)]), 1)
            self.assertIn("no download link", err.getvalue())


if __name__ == "__main__":
    unittest.main()
