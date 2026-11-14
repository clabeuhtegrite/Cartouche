"""Checks the release notes of each version, app/releases/<version>.md, in
English, and <version>.<language>.md in Cartouche's other languages, which
the app carries and shows (launcher/Sources/CartoucheReleaseNotes.swift):
What's new over the console after an update, and the System page's What's
new.

- each is plain text in the shape the app reads: a sentence that says what
  the version brings, a blank line, then one item per line that begins with
  "- ";
- a translation is in a language of the launcher's, beside its English,
  with as many items;
- every version from 0.12.2 on has its French, and the version being built
  its English, without which What's new shows nothing after its update;
- what tells an update from a first install, the preferences an older
  Cartouche leaves, is still written by the launcher;
- the build puts the notes into the app, and the launcher's gallery too.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASES = ROOT / "app" / "releases"
CONFIG = ROOT / "app" / "config.env"
SOURCES = ROOT / "launcher" / "Sources"
NOTES_SWIFT = SOURCES / "CartoucheReleaseNotes.swift"
WHATS_NEW_SWIFT = SOURCES / "CartoucheWhatsNewView.swift"
BUILD = ROOT / "app" / "scripts" / "build.sh"
PACKAGE = ROOT / "app" / "scripts" / "package.sh"
GALLERY = ROOT / "launcher" / "Gallery"

NAME = re.compile(r"(?P<version>\d+\.\d+\.\d+)(?:\.(?P<language>[A-Za-z]{2,3}(?:-[A-Za-z0-9]+)?))?\.md")
# The first version whose notes are written in French too, as agreed with
# the thread that cuts the releases: 0.12.1's came before What's new.
FRENCH_FROM = (0, 12, 2)


def version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


def setting(key: str) -> str:
    for line in CONFIG.read_text(encoding="utf-8").splitlines():
        name, _, value = line.partition("=")
        if name.strip() == key and not line.lstrip().startswith("#"):
            return value.strip()
    raise AssertionError(f"{key} is missing from app/config.env")


def notes() -> dict[str, dict[str | None, Path]]:
    """Each version's notes: language (None for English) -> file."""
    found: dict[str, dict[str | None, Path]] = {}
    for path in sorted(RELEASES.iterdir()):
        if path.name == "README.md":
            continue
        match = NAME.fullmatch(path.name)
        if not match:
            raise AssertionError(f"app/releases/{path.name} is not <version>.md nor <version>.<language>.md")
        found.setdefault(match["version"], {})[match["language"]] = path
    return found


def items(path: Path) -> list[str]:
    return [line for line in path.read_text(encoding="utf-8").split("\n") if line.startswith("- ")]


class ReleaseNotesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.notes = notes()
        catalog = json.loads((SOURCES / "Cartouche.xcstrings").read_text(encoding="utf-8"))
        languages = {language for entry in catalog["strings"].values() for language in entry["localizations"]}
        cls.translations = sorted(languages - {catalog["sourceLanguage"]})

    def test_each_file_is_plain_text_in_the_shape_the_app_reads(self):
        self.assertTrue(self.notes, "no release notes in app/releases")
        for languages in self.notes.values():
            for path in languages.values():
                with self.subTest(file=path.name):
                    text = path.read_text(encoding="utf-8")
                    self.assertTrue(text.endswith("\n") and not text.endswith("\n\n"), "it must end with one line end")
                    self.assertNotIn("\r", text)
                    lines = text[:-1].split("\n")
                    self.assertGreaterEqual(len(lines), 3, "a sentence, a blank line, then the items")
                    summary, blank, *rest = lines
                    self.assertTrue(summary.strip() and not summary.startswith(("- ", "#")),
                                    "it must begin with the sentence that says what the version brings")
                    self.assertEqual(blank, "", "a blank line comes between the sentence and the items")
                    for line in [summary] + rest:
                        self.assertEqual(line, line.rstrip(), f"a space ends {line!r}")
                        self.assertIsNone(re.search(r"\*\*|`|\]\(|^#", line), f"Markdown in {line!r}: plain text only")
                    for line in rest:
                        self.assertRegex(line, r"^- \S", "each line after the blank one is an item")

    def test_a_translation_is_in_a_language_of_the_launcher_beside_its_english(self):
        self.assertEqual(self.translations, ["fr"])
        for number, languages in self.notes.items():
            for language, path in languages.items():
                if language is None:
                    continue
                with self.subTest(file=path.name):
                    self.assertIn(language, self.translations, "the launcher's words are not in that language")
                    self.assertIn(None, languages, f"no English notes, {number}.md, beside it")
                    self.assertEqual(len(items(path)), len(items(languages[None])), "not as many items as the English")

    def test_every_version_from_0_12_2_has_its_french(self):
        for number, languages in self.notes.items():
            if version(number) >= FRENCH_FROM and None in languages:
                with self.subTest(version=number):
                    self.assertIn("fr", languages, f"no {number}.fr.md: What's new would show the English in French")

    def test_the_version_built_has_its_notes(self):
        number = setting("CARTOUCHE_VERSION")
        self.assertIn(None, self.notes.get(number, {}),
                      f"no app/releases/{number}.md: What's new would show nothing after its update")

    def test_what_tells_an_update_from_a_first_install_is_still_written(self):
        swift = NOTES_SWIFT.read_text(encoding="utf-8")
        block = re.search(r"static let earlierKeys = \[(.*?)\]", swift, re.DOTALL)
        self.assertIsNotNone(block, "no earlierKeys in CartoucheReleaseNotes.swift")
        keys = re.findall(r'"([^"]+)"', block.group(1))
        self.assertTrue(keys)
        others = "\n".join(path.read_text(encoding="utf-8") for path in sorted(SOURCES.glob("*.swift"))
                           if path != NOTES_SWIFT)
        for key in keys:
            with self.subTest(key=key):
                self.assertIn(f'"{key}"', others, "no part of the launcher writes it any more")

    def test_the_build_puts_the_notes_into_the_app(self):
        self.assertIn('--releases "$ROOT/app/releases"', BUILD.read_text(encoding="utf-8"))
        package = PACKAGE.read_text(encoding="utf-8")
        self.assertIn('mkdir -p "$APP/CartoucheReleases"', package)
        self.assertIn('cp "$RELEASES"/[0-9]*.md "$APP/CartoucheReleases/"', package)
        self.assertIn('appendingPathComponent("CartoucheReleases"', WHATS_NEW_SWIFT.read_text(encoding="utf-8"))
        project = (GALLERY / "project.sh").read_text(encoding="utf-8")
        self.assertIn('cp "$ROOT"/app/releases/[0-9]*.md "$BUILD/CartoucheReleases/"', project)
        self.assertIn("path: Build/CartoucheReleases", (GALLERY / "project.yml").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
