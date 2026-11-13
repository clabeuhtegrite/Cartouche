"""Checks the words the launcher's UI tests look for on the screen
(launcher/Gallery/UITests/ConsoleTestCase.swift, enum Words) against the
English the launcher shows: each is the English fallback of the key its
comment names in launcher/Sources/CartoucheText*.swift, or its beginning, so
that a change of words fails here, on Linux, rather than as a UI test that
finds nothing on a Mac.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

from test_launcher_strings import CALL, swift_unescape

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "launcher" / "Sources"
TESTS = ROOT / "launcher" / "Gallery" / "UITests"

# static let name = "words" // key
WORD = re.compile(r'^\s*static let (\w+) = "((?:[^"\\]|\\.)*)"\s*//\s*(\S+)\s*$')


class LauncherUITestWordsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.english = {}
        for source in sorted(SOURCES.glob("CartoucheText*.swift")):
            for _, key, english, _ in CALL.findall(source.read_text(encoding="utf-8")):
                cls.english[key] = swift_unescape(english)
        swift = (TESTS / "ConsoleTestCase.swift").read_text(encoding="utf-8")
        words = re.search(r"^enum Words \{\n(.*?)^\}", swift, re.MULTILINE | re.DOTALL)
        if not words:
            raise AssertionError("no enum Words in ConsoleTestCase.swift")
        cls.lines = [line for line in words.group(1).splitlines() if line.strip()]

    def test_every_word_names_its_key(self):
        self.assertTrue(self.lines, "enum Words is empty")
        for line in self.lines:
            with self.subTest(line=line.strip()):
                self.assertRegex(line, WORD, "a word without the key of its English in a comment")

    def test_every_word_is_the_launchers_english(self):
        for line in self.lines:
            found = WORD.match(line)
            if not found:
                continue
            name, words, key = found.groups()
            with self.subTest(word=name, key=key):
                self.assertIn(key, self.english, "no such key in CartoucheText*.swift")
                english = self.english[key]
                self.assertTrue(english.startswith(swift_unescape(words)),
                                f"{name} is {words!r}, the English of {key} is {english!r}")


if __name__ == "__main__":
    unittest.main()
