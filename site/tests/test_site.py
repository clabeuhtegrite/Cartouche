"""What the showcase page may show, load and link to.

    python3 -m unittest discover -s site/tests -v

The page shows Cartouche with games of nxnative's list, their covers and
artworks loaded from IGDB by the IDs of catalog/covers.json, as the app loads
them; it carries no image of a game. Besides those images it loads nothing
from another site, and it links only to Cartouche's repository, nxnative's
and IGDB: never to a game, a dump, an IPA, a catalog of games, keys or
firmware, nor to a server of the project (docs/decisions.md, 40). Its only
downloads are the project's own programs for a computer, the Cartouche
Installer and Cartouche Builder, each a file of their releases marked for
the publication to give its newest one (site/tools/downloads.py), as the
download page, download/index.html, gives them too.

A catalog change that touches a game of the page (its name, its covers, where
nxnative plays it) fails here: update the list at the top of the page's
script, <script id="games">, as the message says.
"""

from __future__ import annotations

import colorsys
import json
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path

SITE = Path(__file__).resolve().parents[1]
PAGE = SITE / "index.html"
DOWNLOAD_PAGE = SITE / "download" / "index.html"
CATALOG = SITE.parent / "catalog"

# The files the site offers, straight from this repository's releases: the
# Cartouche Installer for Mac and for Windows, and Cartouche Builder. A link
# to one is marked data-download="<file>", for the publication to give it the
# newest release (site/tools/downloads.py).
REPOSITORY = "https://github.com/clabeuhtegrite/Cartouche"
DOWNLOADS = {
    "builder": re.compile(re.escape(REPOSITORY) + r"/releases/download/builder-v(\d+\.\d+\.\d+)/Cartouche-Builder-\1\.dmg"),
    "installer-mac": re.compile(re.escape(REPOSITORY) + r"/releases/download/installer-v(\d+\.\d+\.\d+)/Cartouche-Installer-\1-Mac\.dmg"),
    "installer-windows": re.compile(re.escape(REPOSITORY) + r"/releases/download/installer-v(\d+\.\d+\.\d+)/Cartouche-Installer-\1-Windows\.exe"),
}

# Every absolute link the page may hold, whole: the repository and its pages,
# the files above, nxnative, and IGDB, which the page credits.
ALLOWED_LINKS = [
    re.compile(re.escape(REPOSITORY)),
    re.compile(re.escape(REPOSITORY) + r"/blob/main/[\w/.-]+\.md(?:#[\w-]+)?"),
    *DOWNLOADS.values(),
    re.compile(r"https://github\.com/seedds/nxnative"),
    re.compile(r"https://www\.igdb\.com"),
]

# The one other site the page loads from: IGDB's image server, at the sizes
# IGDB names, for the IDs of catalog/covers.json.
IGDB = "https://images.igdb.com/igdb/image/upload/"
IGDB_HOST = "https://images.igdb.com"
IGDB_SIZES = {"t_cover_small", "t_cover_big", "t_cover_big_2x", "t_screenshot_med", "t_screenshot_big", "t_720p", "t_1080p"}

# Files of games, keys, firmware and what carries them.
GAME_FILES = re.compile(
    r"\.(ipa|nsp|nsz|xci|xcz|nca|ncz|nro|nso|nup|kip|keys|bin|zip|7z|rar|tar|gz|torrent|dmg|pkg)\b",
    re.IGNORECASE,
)

# Files the site is made of, and nothing else: no image of a game.
SITE_FILES = {".html", ".svg", ".md", ".py"}

# What the page may say of a game: its status on the page, and where
# nxnative must play it for the page to say so.
STATUSES = {"ready": "iphone", "stored": "iphone", "iphone": "iphone", "mac": "mac"}


class Page(HTMLParser):
    """The page's tags, with their attributes, its scripts and styles, and
    the rest of its text."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.tags: list[tuple[str, dict[str, str]]] = []
        self.ids: set[str] = set()
        self.scripts: list[tuple[dict[str, str], str]] = []
        self.styles: list[str] = []
        self.words: list[str] = []
        self._in: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {name: value or "" for name, value in attrs}
        self.tags.append((tag, values))
        if "id" in values:
            self.ids.add(values["id"])
        if tag == "script":
            self._in = tag
            self.scripts.append((values, ""))
        elif tag == "style":
            self._in = tag
            self.styles.append("")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag: str) -> None:
        if tag == self._in:
            self._in = None

    def handle_data(self, data: str) -> None:
        if self._in == "script":
            attrs, text = self.scripts[-1]
            self.scripts[-1] = (attrs, text + data)
        elif self._in == "style":
            self.styles[-1] += data
        else:
            self.words.append(data)


def read_page(path: Path = PAGE) -> tuple[str, Page]:
    text = path.read_text(encoding="utf-8")
    page = Page()
    page.feed(text)
    page.close()
    return text, page


def download_of(href: str) -> str | None:
    """The file of the site's downloads a link gives, if it gives one."""
    return next((key for key, pattern in DOWNLOADS.items() if pattern.fullmatch(href)), None)


# What a page says to its visitor besides its elements' text.
SAID = ("content", "data-fr", "data-en", "aria-label", "data-label-fr", "data-label-en", "title", "alt")


def check_downloads(test: unittest.TestCase, text: str, page: Page) -> dict[str, str]:
    """Each download of a page: a file of its releases, marked as that file,
    one release for each file wherever the page links to it, and no version
    said: a button says what it downloads, not which version (the owner,
    2026-11-10). The version of each file."""
    versions: dict[str, set[str]] = {}
    for tag, attrs in page.tags:
        key = download_of(attrs.get("href", "")) if tag == "a" else None
        if key or "data-download" in attrs:
            test.assertEqual(attrs.get("data-download"), key, f"<{tag} href={attrs.get('href')!r}> is marked data-download={attrs.get('data-download')!r}")
            versions.setdefault(key, set()).add(DOWNLOADS[key].fullmatch(attrs["href"]).group(1))
    for key, found in versions.items():
        test.assertEqual(len(found), 1, f"{key}: the page links to {sorted(found)}")
    # The Installer's two files are one release.
    if "installer-mac" in versions and "installer-windows" in versions:
        test.assertEqual(versions["installer-mac"], versions["installer-windows"])
    # Only links are marked, and nothing the visitor reads names a version.
    test.assertNotRegex(text, r"\sdata-download-")
    said = page.words + [value for tag, attrs in page.tags for name, value in attrs.items() if name in SAID]
    for words in said:
        test.assertNotRegex(words, r"(?i)\bversion\s+\d")
        for found in versions.values():
            for version in found:
                test.assertNotRegex(words, r"(?<![\d.])" + re.escape(version) + r"(?![\d.])", f"the page says the version {version}")
    return {key: found.pop() for key, found in versions.items()}


def app_colors(title_id: str) -> tuple[str, str]:
    """CartoucheTheme.colors(for:): a hue from the FNV-1a hash of the title
    ID, a light colour and a deep one."""
    value = 0xCBF29CE484222325
    for byte in title_id.encode():
        value = ((value ^ byte) * 0x100000001B3) % (1 << 64)
    hue = (value % 360) / 360

    def color(h: float, s: float, b: float) -> str:
        return "#" + "".join(f"{round(c * 255):02X}" for c in colorsys.hsv_to_rgb(h, s, b))

    return color(hue, 0.62, 0.90), color((hue + 0.07) % 1, 0.80, 0.40)


class SiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text, cls.page = read_page()
        cls.code = "\n".join(text for attrs, text in cls.page.scripts if attrs.get("type") != "application/json")
        data = [text for attrs, text in cls.page.scripts if attrs.get("id") == "games"]
        cls.games = json.loads(data[0]) if len(data) == 1 else []
        # Links the script writes into the screens: href="#…" in its markup
        # and href: "#…" in its data.
        cls.script_links = re.findall(r'href="([^"\']+)"', cls.code) + re.findall(r'href:\s*"([^"]+)"', cls.code)

    def links(self) -> list[str]:
        return [attrs["href"] for tag, attrs in self.page.tags if tag == "a" and "href" in attrs] + self.script_links

    def test_loads_nothing_from_another_site_but_igdb_images(self) -> None:
        for tag, attrs in self.page.tags:
            for name in ("src", "srcset", "poster", "data", "action", "formaction"):
                value = attrs.get(name, "")
                self.assertNotRegex(value, r"^(?:[a-z][a-z0-9+.-]*:|//)", f"<{tag} {name}> loads {value!r}")
            if tag == "link":
                href = attrs.get("href", "")
                # A connection made early to IGDB's image server, nothing loaded.
                if attrs.get("rel") == "preconnect":
                    self.assertEqual(href, IGDB_HOST)
                else:
                    self.assertNotRegex(href, r"^(?:[a-z][a-z0-9+.-]*:|//)", f"<link> loads {href!r}")
            self.assertNotIn(tag, ("iframe", "embed", "object", "form", "base", "video", "audio"), f"the page has an <{tag}>")
            if tag == "script":
                self.assertNotIn("src", attrs, "the page's script is its own, inline")
        for style in self.page.styles:
            self.assertNotIn("@import", style)
            for url in re.findall(r"url\(\s*['\"]?([^'\")]+)", style):
                self.assertFalse(re.match(r"(?:[a-z][a-z0-9+.-]*:|//)", url) and not url.startswith("data:"), f"the styles load {url!r}")
        # The only address the script builds is IGDB's image server's, at
        # IGDB's sizes; every other address in it is a link the page may hold.
        self.assertEqual(self.code.count('"' + IGDB + '"'), 1, "the script names IGDB's image server once")
        for url in re.findall(r"""(?:https?:)?//[^\s"'<>)\\]+""", self.code):
            self.assertTrue(url == IGDB or any(p.fullmatch(url) for p in ALLOWED_LINKS), f"the script holds {url!r}")
        for size in re.findall(r'"(t_\w+)"', self.code):
            self.assertIn(size, IGDB_SIZES)
        # The images are sent without the page's address.
        self.assertRegex(self.text, r'<meta name="referrer" content="no-referrer">')
        # Nothing else reaches a server from the page: no request, beacon or cookie.
        for call in ("fetch(", "XMLHttpRequest", "sendBeacon", "WebSocket", "EventSource", "document.cookie", "import(", "new Image", "navigator.", "Worker("):
            if call == "navigator.":
                # The page reads the browser's languages, nothing else of it.
                self.assertEqual(set(re.findall(r"navigator\.(\w+)", self.text)), {"languages", "language"})
                continue
            self.assertNotIn(call, self.code)

    def test_links_only_to_the_projects_repositories_and_igdb(self) -> None:
        for href in self.links():
            if href.startswith("#"):
                self.assertIn(href[1:], self.page.ids, f"{href} leads nowhere on the page")
            elif href == "download/":
                # The site's download page, beside it on Pages.
                self.assertTrue(DOWNLOAD_PAGE.is_file())
            else:
                self.assertTrue(any(p.fullmatch(href) for p in ALLOWED_LINKS), f"the page links to {href!r}")

    def test_icons_are_the_pages_own(self) -> None:
        for tag, attrs in self.page.tags:
            if tag == "use":
                href = attrs.get("href", attrs.get("xlink:href", ""))
                self.assertTrue(href.startswith("#") and href[1:] in self.page.ids, f"<use> of {href!r}")
        for name in set(re.findall(r'<use href="#([\w-]+)"', self.code)):
            self.assertIn(name, self.page.ids)
        for name in set(re.findall(r'ic\("([\w-]+)"', self.code) + re.findall(r'icon:\s*"([\w-]+)"', self.code)):
            self.assertIn("i-" + name, self.page.ids, f"{name!r} has no symbol")

    def test_no_game_download_or_dump(self) -> None:
        for tag, attrs in self.page.tags:
            self.assertNotIn("download", attrs, f"<{tag} download>")
            for name in ("href", "src"):
                # The project's own Installer and Builder aside.
                if name == "href" and tag == "a" and download_of(attrs.get(name, "")):
                    continue
                self.assertNotRegex(attrs.get(name, ""), GAME_FILES, f"<{tag} {name}> is a file of a game, keys or an archive")
        for href in self.links():
            if download_of(href):
                continue
            self.assertNotRegex(href, GAME_FILES)
            self.assertFalse(href.startswith(("magnet:", "ftp:", "smb:", "sftp:", "s3:")), href)
        # The site holds its page, its icon, its notes and its tests: no image
        # of a game, which IGDB serves.
        for path in SITE.rglob("*"):
            if path.is_file() and "__pycache__" not in path.parts:
                self.assertIn(path.suffix, SITE_FILES, f"{path.relative_to(SITE)} is not a file the site is made of")
                self.assertLess(path.stat().st_size, 512 * 1024, f"{path.relative_to(SITE)} is too large for the site")
        self.assertEqual(sorted(p.name for p in SITE.glob("*.svg")), ["favicon.svg"])

    def test_downloads_are_the_installer_and_the_builder(self) -> None:
        # Each button gives the file itself, Mac and Windows for the
        # Installer, with no version beside it.
        versions = check_downloads(self, self.text, self.page)
        self.assertEqual(sorted(versions), sorted(DOWNLOADS))
        buttons = [attrs["data-download"] for tag, attrs in self.page.tags if tag == "a" and "data-download" in attrs]
        self.assertEqual(buttons, ["builder", "installer-mac", "installer-windows", "builder"])

    def test_no_server_address_or_secret(self) -> None:
        for path in [PAGE, DOWNLOAD_PAGE, SITE / "favicon.svg"]:
            # Drawings' numbers aside: an icon's path can read like an address.
            text = re.sub(r'\s(?:d|points|viewBox|transform)="[^"]*"', "", path.read_text(encoding="utf-8"))
            for pattern, what in (
                (r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "an IP address"),
                (r"(?i)workers\.dev|\.local\b|localhost|telemetry\.|r2\.dev|amazonaws\.com|\.lan\b", "a server"),
                (r"[a-z]+://[^/\s\"']*@", "credentials in a URL"),
                (r"(?i)(?:api[_-]?key|secret|token|password|client[_-]?id)\s*[:=]\s*['\"]\w", "a secret"),
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
        # The games' examples, in both languages too.
        for game in self.games:
            for key in ("time", "sessions", "size", "detail", "stored"):
                if key in game:
                    self.assertEqual(len(game[key]), 2, f"{game['name']}: {key}")
                    self.assertTrue(all(game[key]), f"{game['name']}: {key}")

    def test_the_page_credits_igdb_and_provides_no_game(self) -> None:
        for sentence in (
            "Les noms, les jaquettes et les illustrations des jeux appartiennent à leurs éditeurs ; ils viennent d’<a href=\"https://www.igdb.com\">IGDB</a>",
            "Games’ names, covers and artworks belong to their publishers; they come from <a href=\"https://www.igdb.com\">IGDB</a>",
            "Cartouche n’en fournit aucun : vous construisez les vôtres à partir de vos propres copies.",
            "Cartouche provides none of them: you build your own from your own copies.",
        ):
            self.assertIn(sentence, self.text)

    def test_games_are_the_catalogs(self) -> None:
        nxnative = {game["titleId"]: game for game in json.loads((CATALOG / "nxnative.json").read_text(encoding="utf-8"))["games"]}
        covers = {cover["titleId"]: cover for cover in json.loads((CATALOG / "covers.json").read_text(encoding="utf-8"))["covers"]}
        # A testers' sheet with a game playable on an iPhone says it plays there.
        playable = set()
        for path in (CATALOG / "games").glob("*.json"):
            sheet = json.loads(path.read_text(encoding="utf-8"))
            if any(r.get("status") in ("playable", "playable-with-issues") for r in sheet.get("results", [])):
                playable.add(sheet["titleId"])
        self.assertGreaterEqual(len(self.games), 6)
        self.assertEqual(len({g["id"] for g in self.games}), len(self.games))
        for game in self.games:
            title_id, name = game["titleId"], game["name"]
            with self.subTest(game=name):
                self.assertIn(title_id, nxnative, f"{name} is not in catalog/nxnative.json")
                listed = nxnative[title_id]
                for key in ("name", "platform", "genre"):
                    self.assertEqual(game[key], listed[key], f"{name}: its {key} in catalog/nxnative.json is {listed[key]!r}")
                # Where the page says it plays is where nxnative plays it.
                plays = "iphone" if listed["status"] == "iphone" or title_id in playable else listed["status"]
                self.assertIn(game["status"], STATUSES)
                self.assertEqual(game["catalog"], STATUSES[game["status"]])
                if game["catalog"] == "iphone":
                    self.assertEqual(plays, "iphone", f"{name}: the page says it plays on the iPhone, catalog/nxnative.json says {listed['status']!r}")
                else:
                    self.assertIn(plays, ("mac", "iphone"), f"{name}: the page says it plays on the Mac, catalog/nxnative.json says {listed['status']!r}")
                # Its cover and artwork are those Cartouche shows.
                self.assertIn(title_id, covers, f"{name} has no cover in catalog/covers.json")
                for key in ("cover", "artwork"):
                    self.assertRegex(game[key], r"^[a-z0-9]+$")
                    self.assertEqual(game[key], covers[title_id].get(key), f"{name}: its {key} in catalog/covers.json is {covers[title_id].get(key)!r}")
                # Its colours are those Cartouche gives it.
                self.assertEqual((game["light"], game["dark"]), app_colors(title_id), f"{name}: Cartouche's colours for it")
                # The player's games have their play time and size, or their IPA's.
                if game["status"] == "ready":
                    self.assertTrue(all(key in game for key in ("time", "sessions", "size", "detail")), name)
                if game["status"] == "stored":
                    self.assertIn("stored", game, name)

    def test_the_page_shows_only_igdbs_images_of_its_games(self) -> None:
        for tag, attrs in self.page.tags:
            self.assertNotEqual(tag, "img", "the page's images are its games', which its script shows")
        # The script builds each image's address from IGDB's server, a size
        # and the ID of a game of the list, and from nothing else.
        for src in re.findall(r'(?:src|srcset)="\' \+ (\w+)\(', self.code):
            self.assertEqual(src, "igdb")
        self.assertRegex(self.code, r'function igdb\(size, id\) \{ return IGDB \+ size \+ "/" \+ id \+ "\.jpg"; \}')
        for call in re.findall(r'igdb\("(t_\w+)", (\w+)\.(\w+)\)', self.code):
            self.assertIn(call[0], IGDB_SIZES)
            self.assertIn(call[2], ("cover", "artwork"))
        self.assertNotIn("data:image", self.text)


class DownloadPageTests(unittest.TestCase):
    """download/index.html: the newest file of each of the project's programs
    for a computer, for the links of the repository's guides. A link to it
    that names one, download/#builder, #installer-mac or #installer-windows,
    starts its download from the page's button."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text, cls.page = read_page(DOWNLOAD_PAGE)
        cls.code = "\n".join(text for attrs, text in cls.page.scripts)

    def test_loads_nothing_from_another_site_and_sends_nothing(self) -> None:
        for tag, attrs in self.page.tags:
            for name in ("src", "srcset", "poster", "data", "action", "formaction"):
                self.assertNotRegex(attrs.get(name, ""), r"^(?:[a-z][a-z0-9+.-]*:|//)", f"<{tag} {name}> loads {attrs.get(name)!r}")
            if tag == "link":
                self.assertNotRegex(attrs.get("href", ""), r"^(?:[a-z][a-z0-9+.-]*:|//)", f"<link> loads {attrs.get('href')!r}")
            self.assertNotIn(tag, ("iframe", "embed", "object", "form", "base", "video", "audio", "img"), f"the page has an <{tag}>")
            if tag == "script":
                self.assertNotIn("src", attrs, "the page's script is its own, inline")
        for style in self.page.styles:
            self.assertNotIn("@import", style)
            self.assertNotRegex(style, r"url\(\s*['\"]?(?:[a-z][a-z0-9+.-]*:|//)")
        self.assertRegex(self.text, r'<meta name="referrer" content="no-referrer">')
        # The script names no address: the file it starts is its button's.
        self.assertNotRegex(self.code, r"https?:")
        for call in ("fetch(", "XMLHttpRequest", "sendBeacon", "WebSocket", "EventSource", "document.cookie", "import(", "new Image", "Worker(", "window.open"):
            self.assertNotIn(call, self.code)
        self.assertEqual(set(re.findall(r"navigator\.(\w+)", self.text)), {"languages", "language"})
        self.assertEqual(re.findall(r"location\.href\s*=\s*([^;]+);", self.code), ["link.href"])

    def test_links_to_the_files_the_site_and_the_repository(self) -> None:
        for tag, attrs in self.page.tags:
            if tag != "a":
                continue
            href = attrs.get("href", "")
            if href.startswith("#"):
                self.assertIn(href[1:], self.page.ids, f"{href} leads nowhere on the page")
            elif href != "../":
                self.assertTrue(any(p.fullmatch(href) for p in ALLOWED_LINKS), f"the page links to {href!r}")
        for tag, attrs in self.page.tags:
            if tag == "use":
                href = attrs.get("href", "")
                self.assertTrue(href.startswith("#") and href[1:] in self.page.ids, f"<use> of {href!r}")

    def test_each_file_has_its_card_and_its_button(self) -> None:
        # The address names the card; the card's one button gives its file.
        cards = [attrs["id"] for tag, attrs in self.page.tags if tag == "li" and "file" in attrs.get("class", "").split()]
        self.assertEqual(sorted(cards), sorted(DOWNLOADS))
        for key in cards:
            card = self.text[self.text.index(f'id="{key}"'):]
            card = card[:card.index("</li>")]
            self.assertEqual(re.findall(r'\sdata-download="([^"]*)"', card), [key])
            self.assertEqual(card.count("data-started hidden"), 1, f"{key} says when its download starts")
        versions = check_downloads(self, self.text, self.page)
        self.assertEqual(sorted(versions), sorted(DOWNLOADS))

    def test_the_same_files_as_the_site(self) -> None:
        text, page = read_page()
        self.assertEqual(check_downloads(self, self.text, self.page), check_downloads(self, text, page))

    def test_every_text_in_both_languages(self) -> None:
        body = self.text[self.text.index("<body>"):]
        pairs = re.findall(r'<(\w+)\b[^>]*\slang="(fr|en)"', body)
        self.assertEqual([tag for tag, lang in pairs if lang == "fr"], [tag for tag, lang in pairs if lang == "en"])
        self.assertGreater(len(pairs), 30)
        self.assertEqual(len(re.findall(r"data-label-fr=", self.text)), len(re.findall(r"data-label-en=", self.text)))
        self.assertIn('data-fr="', self.text)
        self.assertIn('data-en="', self.text)

    def test_provides_no_game(self) -> None:
        for sentence in (
            "Cartouche ne contient et ne télécharge aucun jeu, aucune clé ni aucun firmware : vous construisez vos jeux à partir de vos propres copies.",
            "Cartouche contains and downloads no games, no keys and no firmware: you build your games from your own copies.",
        ):
            self.assertIn(sentence, self.text)


if __name__ == "__main__":
    unittest.main()
