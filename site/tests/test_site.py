"""What the showcase page may show, load and link to.

    python3 -m unittest discover -s site/tests -v

The page shows Cartouche with games and covers made up for it, loads nothing
from another site, and links only to Cartouche's repository and nxnative's:
never to a game, a dump, an IPA, a catalog of games, keys or firmware, nor to
a server of the project (docs/decisions.md, 37).
"""

from __future__ import annotations

import importlib.util
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path

SITE = Path(__file__).resolve().parents[1]
PAGE = SITE / "index.html"
COVERS = SITE / "covers"

# Every absolute link the page may hold, whole: the repository and its pages,
# the Installer's releases, and nxnative.
REPOSITORY = "https://github.com/clabeuhtegrite/Cartouche"
ALLOWED_LINKS = [
    re.compile(re.escape(REPOSITORY)),
    re.compile(re.escape(REPOSITORY) + r"/blob/main/[\w/.-]+\.md(?:#[\w-]+)?"),
    re.compile(re.escape(REPOSITORY) + r"/releases\?q=installer&expanded=true"),
    re.compile(r"https://github\.com/seedds/nxnative"),
]

# Files of games, keys, firmware and what carries them.
GAME_FILES = re.compile(
    r"\.(ipa|nsp|nsz|xci|xcz|nca|ncz|nro|nso|nup|kip|keys|bin|zip|7z|rar|tar|gz|torrent|dmg|pkg)\b",
    re.IGNORECASE,
)

# Files the site is made of, and nothing else.
SITE_FILES = {".html", ".svg", ".md", ".py"}


class Page(HTMLParser):
    """The page's tags, with their attributes, and its scripts and styles."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.tags: list[tuple[str, dict[str, str]]] = []
        self.ids: set[str] = set()
        self.scripts: list[str] = []
        self.styles: list[str] = []
        self._in: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {name: value or "" for name, value in attrs}
        self.tags.append((tag, values))
        if "id" in values:
            self.ids.add(values["id"])
        if tag in ("script", "style"):
            self._in = tag
            (self.scripts if tag == "script" else self.styles).append("")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag: str) -> None:
        if tag == self._in:
            self._in = None

    def handle_data(self, data: str) -> None:
        if self._in == "script":
            self.scripts[-1] += data
        elif self._in == "style":
            self.styles[-1] += data


def read_page() -> tuple[str, Page]:
    text = PAGE.read_text(encoding="utf-8")
    page = Page()
    page.feed(text)
    page.close()
    return text, page


def load_make_covers():
    spec = importlib.util.spec_from_file_location("make_covers", COVERS / "make_covers.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text, cls.page = read_page()
        script = "\n".join(cls.page.scripts)
        # Links the script writes into the screens: href="#…" in its markup
        # and href: "#…" in its data.
        cls.script_links = re.findall(r'href="([^"\']+)"', script) + re.findall(r'href:\s*"([^"]+)"', script)

    def links(self) -> list[str]:
        return [attrs["href"] for tag, attrs in self.page.tags if tag == "a" and "href" in attrs] + self.script_links

    def test_loads_nothing_from_another_site(self) -> None:
        for tag, attrs in self.page.tags:
            for name in ("src", "srcset", "poster", "data", "action", "formaction"):
                value = attrs.get(name, "")
                self.assertNotRegex(value, r"^(?:[a-z][a-z0-9+.-]*:|//)", f"<{tag} {name}> loads {value!r}")
            if tag == "link":
                self.assertNotRegex(attrs.get("href", ""), r"^(?:[a-z][a-z0-9+.-]*:|//)", f"<link> loads {attrs.get('href')!r}")
            self.assertNotIn(tag, ("iframe", "embed", "object", "form", "base"), f"the page has an <{tag}>")
            if tag == "script":
                self.assertNotIn("src", attrs, "the page's script is its own, inline")
        for style in self.page.styles:
            self.assertNotIn("@import", style)
            for url in re.findall(r"url\(\s*['\"]?([^'\")]+)", style):
                self.assertFalse(re.match(r"(?:[a-z][a-z0-9+.-]*:|//)", url) and not url.startswith("data:"), f"the styles load {url!r}")
        # Nothing reaches a server from the page: no request, beacon or cookie.
        for script in self.page.scripts:
            for call in ("fetch(", "XMLHttpRequest", "sendBeacon", "WebSocket", "EventSource", "document.cookie", "import(", "new Image"):
                self.assertNotIn(call, script)

    def test_links_only_to_the_projects_repositories(self) -> None:
        for href in self.links():
            if href.startswith("#"):
                self.assertIn(href[1:], self.page.ids, f"{href} leads nowhere on the page")
            else:
                self.assertTrue(any(p.fullmatch(href) for p in ALLOWED_LINKS), f"the page links to {href!r}")

    def test_icons_are_the_pages_own(self) -> None:
        for tag, attrs in self.page.tags:
            if tag == "use":
                href = attrs.get("href", attrs.get("xlink:href", ""))
                self.assertTrue(href.startswith("#") and href[1:] in self.page.ids, f"<use> of {href!r}")
        for name in set(re.findall(r'<use href="#([\w-]+)"', "\n".join(self.page.scripts))):
            self.assertIn(name, self.page.ids)
        for name in set(re.findall(r'ic\("([\w-]+)"', "\n".join(self.page.scripts))):
            self.assertIn("i-" + name, self.page.ids, f"ic({name!r}) has no symbol")

    def test_no_game_download_or_dump(self) -> None:
        for tag, attrs in self.page.tags:
            self.assertNotIn("download", attrs, f"<{tag} download>")
            for name in ("href", "src"):
                self.assertNotRegex(attrs.get(name, ""), GAME_FILES, f"<{tag} {name}> is a file of a game, keys or an archive")
        for href in self.links():
            self.assertNotRegex(href, GAME_FILES)
            self.assertFalse(href.startswith(("magnet:", "ftp:", "smb:", "sftp:", "s3:")), href)
        # The site holds its page, its covers and their script, nothing else.
        for path in SITE.rglob("*"):
            if path.is_file() and "__pycache__" not in path.parts:
                self.assertIn(path.suffix, SITE_FILES, f"{path.relative_to(SITE)} is not a file the site is made of")
                self.assertLess(path.stat().st_size, 512 * 1024, f"{path.relative_to(SITE)} is too large for the site")

    def test_no_server_address_or_secret(self) -> None:
        for path in [PAGE, *COVERS.glob("*.svg")]:
            # Drawings' numbers aside: an icon's path can read like an address.
            text = re.sub(r'\s(?:d|points|viewBox|transform)="[^"]*"', "", path.read_text(encoding="utf-8"))
            for pattern, what in (
                (r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "an IP address"),
                (r"(?i)workers\.dev|\.local\b|localhost|telemetry\.|r2\.dev|amazonaws\.com|\.lan\b", "a server"),
                (r"[a-z]+://[^/\s\"']*@", "credentials in a URL"),
                (r"(?i)(?:api[_-]?key|secret|token|password)\s*[:=]\s*['\"]\w", "a secret"),
            ):
                found = re.search(pattern, text)
                self.assertIsNone(found, f"{path.name} holds {what}: {found and found.group(0)!r}")

    def test_every_text_in_both_languages(self) -> None:
        # Static text: each element in French is followed by its English twin.
        body = self.text[self.text.index("<body>"):]
        pairs = re.findall(r'<(\w+)\b[^>]*\slang="(fr|en)"', body)
        french = [tag for tag, lang in pairs if lang == "fr"]
        english = [tag for tag, lang in pairs if lang == "en"]
        self.assertEqual(french, english, "the page's French and English elements differ")
        self.assertGreater(len(french), 100)
        labels_fr = re.findall(r"data-label-fr=", self.text)
        self.assertEqual(len(labels_fr), len(re.findall(r"data-label-en=", self.text)))
        for tag, attrs in self.page.tags:
            if "data-label-fr" in attrs:
                self.assertIn("aria-label", attrs, f"<{tag}> has no label before the script names it")
        self.assertIn('data-fr="', self.text)
        self.assertIn('data-en="', self.text)

    def test_the_page_says_its_games_are_made_up(self) -> None:
        self.assertIn("Les jeux et les jaquettes de cette page sont inventés.", self.text)
        self.assertIn("The games and covers on this page are made up.", self.text)

    def test_covers_are_the_ones_their_script_draws(self) -> None:
        make_covers = load_make_covers()
        drawn = {f"{name}.svg" for name in make_covers.COVERS}
        on_disk = {path.name for path in COVERS.glob("*.svg")}
        self.assertEqual(drawn, on_disk)
        for name, draw in make_covers.COVERS.items():
            self.assertEqual(draw(), (COVERS / f"{name}.svg").read_text(), f"covers/{name}.svg is not what make_covers.py draws: run it")

    def test_the_page_shows_only_its_covers(self) -> None:
        script = "\n".join(self.page.scripts)
        files = set(re.findall(r'file:\s*"([\w-]+)"', script))
        self.assertTrue(files)
        for name in files:
            self.assertTrue((COVERS / f"{name}.svg").is_file(), f"no cover {name}.svg")
        for tag, attrs in self.page.tags:
            if tag == "img":
                self.assertRegex(attrs.get("src", ""), r"^covers/[\w-]+\.svg$")
        for src in re.findall(r'src="([^"]+)"', script):
            self.assertTrue(src.startswith("covers/"), src)


if __name__ == "__main__":
    unittest.main()
