"""Checks that Cartouche reads what a game's own process writes of its
memory: the game, behind the console, runs in LiveContainer's LiveProcess
extension, where launcher/LiveProcessSupport/CartoucheGuest.m writes
Cartouche/GameMemory.plist of the app group, and Cartouche reads it
(CartoucheGameMemoryReading, launcher/Sources/CartoucheRunningGame.swift).
Neither side is built here, so a key one side spells differently would only
show on an iPhone, as a reading Cartouche never gets.

- every key Cartouche reads is one the game's process writes, and the
  header of CartoucheGuest.m lists every key it writes;
- the game's process says whether it has Increased Memory Limit, and
  Cartouche reads it: some installs signed that process without it, which
  left a game 3,376 MiB while Cartouche had 8,192 (docs/decisions.md, 67);
- the game's process asks its signature for the entitlement that Cartouche
  asks its own for, which the built-in SideStore requests for free teams
  (app/patches/sidestore/0002).

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUEST = ROOT / "launcher" / "LiveProcessSupport" / "CartoucheGuest.m"
READING = ROOT / "launcher" / "Sources" / "CartoucheRunningGame.swift"
DEVICE = ROOT / "launcher" / "Sources" / "CartoucheDevice.swift"
SIDESTORE_PATCH = ROOT / "app" / "patches" / "sidestore" / "0002-request-increased-memory-limit-for-free-teams.patch"
ENTITLEMENT = "com.apple.developer.kernel.increased-memory-limit"


def block(text, start, end):
    """The part of TEXT from START to the first END after it."""
    first = text.index(start)
    return text[first:text.index(end, first)]


class GameMemoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guest = GUEST.read_text(encoding="utf-8")
        cls.reading = READING.read_text(encoding="utf-8")
        # What the game's process writes: the reading it starts with, what
        # each measurement adds, and each size its screen took.
        start = block(cls.guest, "reading = [@{", "} mutableCopy];")
        cls.written = set(re.findall(r'@"(\w+)":', start)) | set(re.findall(r'reading\[@"(\w+)"\] =', cls.guest))
        cls.written_sizes = set(re.findall(r'@"(\w+)":', block(cls.guest, "[sizes addObject:@{", "}];")))
        # What Cartouche reads of them.
        init = block(cls.reading, "init?(plist: [String: Any]) {", "\n    }\n")
        cls.read = set(re.findall(r'plist\["(\w+)"\]', init)) | set(re.findall(r'bytes\("(\w+)"\)', init))
        cls.read_sizes = set(re.findall(r'size\["(\w+)"\]', init))
        # The keys the header lists, each at the start of its line.
        listed = block(cls.guest, "The keys:", "//  - ")
        cls.listed = set(re.findall(r"^//        (\w+)", listed, re.M))

    def test_cartouche_reads_only_what_the_games_process_writes(self):
        self.assertTrue(self.read, "CartoucheGameMemoryReading reads no key")
        self.assertLessEqual(self.read, self.written)
        self.assertTrue(self.read_sizes, "CartoucheGameMemoryReading reads no size")
        self.assertLessEqual(self.read_sizes, self.written_sizes)

    def test_the_header_lists_every_key_written(self):
        self.assertEqual(self.listed, self.written)

    def test_the_games_process_says_whether_it_has_increased_memory_limit(self):
        self.assertIn("increasedMemoryLimit", self.written)
        self.assertIn("increasedMemoryLimit", self.read)
        # Written once, as the game starts: a key missing means the process
        # could not tell, and Cartouche then changes nothing.
        self.assertIn('if (increased >= 0) reading[@"increasedMemoryLimit"] = increased == 1 ? @YES : @NO;', self.guest)
        self.assertIn('hasIncreasedMemoryLimit = (plist["increasedMemoryLimit"] as? NSNumber)?.boolValue', self.reading)

    def test_both_ask_for_the_entitlement_sidestore_requests(self):
        def asked(text):
            return set(re.findall(r'"(com\.apple\.developer\.kernel\.[\w.-]+)"', text))

        self.assertEqual(asked(self.guest), {ENTITLEMENT})
        self.assertEqual(asked(DEVICE.read_text(encoding="utf-8")), {ENTITLEMENT})
        self.assertIn(ENTITLEMENT, SIDESTORE_PATCH.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
