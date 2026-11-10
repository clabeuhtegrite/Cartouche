"""Checks the launcher's words: launcher/Sources/Cartouche.xcstrings against
the keys and English fallbacks in launcher/Sources/CartoucheText.swift and
the files that carry on its list, CartoucheText<Topic>.swift.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "launcher" / "Sources"
LANGUAGES = ("en", "fr")

# s("key", "English") and f("key", "English", arguments...) in CartoucheText*.swift.
CALL = re.compile(r'\b([sf])\("([^"]+)", "((?:[^"\\]|\\.)*)"((?:, [^)]*)?)\)')
# printf placeholders as Foundation reads them: %@, %1$@, %lld, %%...
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaA%])")


def swift_unescape(text: str) -> str:
    text = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), text)
    return text.replace('\\"', '"').replace("\\\\", "\\")


def placeholders(text: str) -> list[str]:
    """The placeholders of a format, by argument position."""
    found = []
    position = 0
    for match in PLACEHOLDER.finditer(text):
        explicit, conversion = match.groups()
        if conversion == "%":
            continue
        position = int(explicit) if explicit else position + 1
        found.append(f"{position}:{conversion}")
    return sorted(found)


class LauncherStringsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.calls = {}
        for source in sorted(SOURCES.glob("CartoucheText*.swift")):
            swift = source.read_text(encoding="utf-8")
            for kind, key, english, arguments in CALL.findall(swift):
                if key in cls.calls:
                    raise AssertionError(f"{key} is defined twice in {source.name} and before")
                count = len([a for a in arguments.split(",") if a.strip()])
                cls.calls[key] = (kind, swift_unescape(english), count)
        cls.catalog = json.loads((SOURCES / "Cartouche.xcstrings").read_text(encoding="utf-8"))

    def test_the_catalog_holds_exactly_the_keys_the_code_uses(self):
        self.assertTrue(self.calls, "no string found in CartoucheText*.swift")
        keys = set(self.catalog["strings"])
        self.assertEqual(sorted(set(self.calls) - keys), [], "keys missing from Cartouche.xcstrings")
        self.assertEqual(sorted(keys - set(self.calls)), [], "keys no code uses")

    def test_every_string_is_translated(self):
        self.assertEqual(self.catalog["sourceLanguage"], "en")
        for key, entry in self.catalog["strings"].items():
            with self.subTest(key=key):
                # Xcode leaves manual entries alone instead of marking them stale.
                self.assertEqual(entry.get("extractionState"), "manual")
                for language in LANGUAGES:
                    unit = entry["localizations"][language]["stringUnit"]
                    self.assertEqual(unit["state"], "translated")
                    self.assertTrue(unit["value"].strip())

    def test_the_english_matches_the_fallback_in_the_code(self):
        for key, (_, english, _) in self.calls.items():
            with self.subTest(key=key):
                value = self.catalog["strings"][key]["localizations"]["en"]["stringUnit"]["value"]
                self.assertEqual(value, english)

    def test_formats_take_the_arguments_the_code_passes(self):
        for key, (kind, english, count) in self.calls.items():
            with self.subTest(key=key):
                expected = placeholders(english)
                self.assertEqual(len(expected), count if kind == "f" else 0)
                for language in LANGUAGES:
                    value = self.catalog["strings"][key]["localizations"][language]["stringUnit"]["value"]
                    self.assertEqual(placeholders(value), expected, language)

    def test_french_spacing(self):
        # A no-break space before the French colon and semicolon, and
        # between a number and its unit, so that neither starts a line.
        for key, entry in self.catalog["strings"].items():
            value = entry["localizations"]["fr"]["stringUnit"]["value"]
            with self.subTest(key=key):
                self.assertIsNone(re.search(r"[^\u00a0\u202f][:;](?:\s|$)", value), value)
                self.assertIsNone(re.search(r"(?:\d|%@) (?:Mio|Gio|Go)\b", value), value)


if __name__ == "__main__":
    unittest.main()
