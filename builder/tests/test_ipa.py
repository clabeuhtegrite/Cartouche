import threading
import unittest
from datetime import datetime

from cartouche_builder import ipa

from support import MKW, Home, make_ipa


class Info(Home):
    def test_reads_what_nxnative_writes(self):
        path = make_ipa(self.tmp / "game.ipa", {
            "DMCommit": "2EB71820ABCD+dirty", "DMChain": "adec7d81d970", "DMTitleID": MKW,
            "CFBundleShortVersionString": "1.0.0", "CFBundleIdentifier": "org.nxnative.0400c3f00006e000", "CFBundleDisplayName": "Mario Kart World",
        })
        info = ipa.read_info(path)
        self.assertEqual(info.commit, "2eb71820abcd")
        self.assertTrue(info.dirty)
        self.assertEqual(info.chain, "adec7d81d970")
        self.assertEqual(info.title_id, MKW)
        self.assertEqual(info.version, "1.0.0")
        self.assertEqual(info.built, datetime(2026, 11, 9, 21, 15, 52))

    def test_title_id_from_the_bundle_id(self):
        path = make_ipa(self.tmp / "game.ipa", {"CFBundleIdentifier": "org.nxnative.0400c3f00006e000"})
        self.assertEqual(ipa.read_info(path).title_id, MKW)

    def test_not_an_ipa(self):
        path = self.tmp / "nope.ipa"
        path.write_bytes(b"not a zip")
        self.assertIsNone(ipa.read_info(path))


class Names(unittest.TestCase):
    def test_as_cartouche_names_them(self):
        self.assertEqual(ipa.file_name("Mario Kart World", MKW.lower()), f"Mario Kart World [{MKW}].ipa")
        self.assertEqual(ipa.clean_name('NieR:Automata  "The End"?'), "NieR Automata The End")
        self.assertEqual(ipa.clean_name(" .Game. "), "Game")
        self.assertEqual(ipa.clean_name("..."), "Game")
        self.assertEqual(len(ipa.clean_name("x" * 300)), 120)
        self.assertEqual(ipa.clean_name("A\tB​C"), "A B C")


class Folder(Home):
    def test_finds_by_name_then_by_info(self):
        games = self.tmp / "games"
        make_ipa(games / f"Mario Kart World [{MKW}].ipa", {"DMTitleID": MKW})
        make_ipa(games / "MarioKartWorld-v2.ipa", {"DMTitleID": MKW})
        make_ipa(games / "Other.ipa", {"DMTitleID": "0100000000010000"})
        found = ipa.find_in_folder(games, MKW)
        self.assertEqual([p.name for p in found], [f"Mario Kart World [{MKW}].ipa", "MarioKartWorld-v2.ipa"])
        self.assertEqual([p.name for p in ipa.find_in_folder(games, MKW, read=False)], [f"Mario Kart World [{MKW}].ipa"])

    def test_delivery_replaces_whole(self):
        games = self.tmp / "games"
        games.mkdir()
        (games / "Game.ipa").write_bytes(b"old")
        source = self.tmp / "new.ipa"
        source.write_bytes(b"new" * 1000)
        target = ipa.deliver(source, games, "Game.ipa")
        self.assertEqual(target.read_bytes(), b"new" * 1000)
        self.assertEqual(sorted(p.name for p in games.iterdir()), ["Game.ipa"])

    def test_stopped_delivery_keeps_the_old_one(self):
        games = self.tmp / "games"
        games.mkdir()
        (games / "Game.ipa").write_bytes(b"old")
        source = self.tmp / "new.ipa"
        source.write_bytes(b"new" * (4 << 20))
        stop = threading.Event()
        stop.set()
        with self.assertRaises(InterruptedError):
            ipa.deliver(source, games, "Game.ipa", stop=stop)
        self.assertEqual((games / "Game.ipa").read_bytes(), b"old")
        self.assertEqual(sorted(p.name for p in games.iterdir()), ["Game.ipa"])


if __name__ == "__main__":
    unittest.main()
