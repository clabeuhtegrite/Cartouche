import os
import time
import unittest
import zipfile
from pathlib import Path

from cartouche_builder import library, titles

from support import HOLLOW, MKW, ODYSSEY, Home, make_dump, make_zip_dump, npdm


class TitleIds(unittest.TestCase):
    def test_base_of_an_update_and_dlc(self):
        self.assertEqual(titles.base_title_id("010015100B514800"), "010015100B514000")
        self.assertEqual(titles.base_title_id("010015100B514000"), "010015100B514000")
        self.assertEqual(titles.base_title_id("010015100B515001"), "010015100B514000")

    def test_ids_in_names(self):
        name = "Super Mario Bros. Wonder [010015100B514800][v327680].nsp"
        self.assertEqual(titles.ids_in_name(name), ["010015100B514800"])
        self.assertEqual(titles.ids_in_name("MKW 0400C3F00006E000.nup"), [MKW])
        self.assertEqual(titles.ids_in_name("Game [v0].nsp"), [])

    def test_label(self):
        self.assertEqual(titles.label("Super Mario Odyssey [0100000000010000][v0].nsp"), "Super Mario Odyssey")
        self.assertEqual(titles.label("[0100000000010000]"), "[0100000000010000]")

    def test_npdm(self):
        self.assertEqual(titles.npdm_title_id(npdm(MKW)), MKW)
        self.assertIsNone(titles.npdm_title_id(b"META" + bytes(10)))
        self.assertIsNone(titles.npdm_title_id(npdm("0400C3F00006E800")))  # not an application's ID


class Discovery(Home):
    def sources(self) -> Path:
        root = self.tmp / "sources"
        packages = root / "Super Mario Odyssey"
        packages.mkdir(parents=True)
        (packages / "Super Mario Odyssey [0100000000010000][v0].nsp").write_bytes(b"x" * 10)
        (packages / "Super Mario Odyssey [0100000000010800][v262144].NSP").write_bytes(b"x" * 5)
        (packages / "._Super Mario Odyssey [0100000000010000][v0].nsp").write_bytes(b"apple double")
        make_dump(root / "Mario Kart World", MKW)
        make_zip_dump(root / "Hollow" / "hollow.zip", HOLLOW)
        (root / "Loose [0100000000010000][v0].nsp").write_bytes(b"x")
        (root / "Empty").mkdir()
        (root / ".hidden").mkdir()
        return root

    def test_finds_each_kind(self):
        found = library.discover(self.sources(), {MKW: "Mario Kart World"})
        kinds = {g.title_id: g.kind for g in found.games}
        self.assertEqual(kinds, {ODYSSEY: "packages", MKW: "dump", HOLLOW: "zip"})
        odyssey = next(g for g in found.games if g.title_id == ODYSSEY)
        self.assertEqual(len(odyssey.inputs), 2)  # without the AppleDouble file
        self.assertTrue(odyssey.needs_keys)
        mkw = next(g for g in found.games if g.title_id == MKW)
        self.assertEqual(mkw.display_name, "Mario Kart World")
        self.assertFalse(mkw.needs_keys)
        hollow = next(g for g in found.games if g.title_id == HOLLOW)
        self.assertEqual(hollow.zip_root, "Game")
        issues = "\n".join(found.issues)
        self.assertIn("Loose", issues)
        self.assertIn("Empty", issues)
        self.assertNotIn(".hidden", issues)

    def test_smallest_first(self):
        found = library.discover(self.sources())
        sizes = [g.size for g in found.games]
        self.assertEqual(sizes, sorted(sizes))

    def test_same_game_twice(self):
        root = self.sources()
        make_dump(root / "Mario Kart World copy", MKW)
        found = library.discover(root)
        self.assertEqual([g.title_id for g in found.games].count(MKW), 1)
        self.assertTrue(any("copy" in i for i in found.issues))

    def test_short_tag_needs_a_profile(self):
        root = self.tmp / "sources"
        folder = root / "Odyssey [010000000001000]"
        folder.mkdir(parents=True)
        (folder / "game.nup").write_bytes(b"nup")
        self.assertEqual(library.discover(root).games, [])
        found = library.discover(root, {ODYSSEY: "Super Mario Odyssey"})
        self.assertEqual([g.title_id for g in found.games], [ODYSSEY])

    def test_missing_sources(self):
        with self.assertRaises(FileNotFoundError):
            library.discover(self.tmp / "nowhere")

    def test_fingerprint_follows_the_files(self):
        root = self.sources()
        game = next(g for g in library.discover(root).games if g.title_id == MKW)
        before = game.fingerprint()
        self.assertEqual(before, game.fingerprint())
        target = root / "Mario Kart World" / "base" / "romfs" / "data.bin"
        target.write_bytes(b"other romfs")
        self.assertNotEqual(before, game.fingerprint())


class Zips(Home):
    def test_unpack_keeps_entry_times_and_drops_mac_files(self):
        path = make_zip_dump(self.tmp / "game.zip", HOLLOW)
        game = library._zip_game(path, path.parent, "game")
        out = library.unpack_zip(game, self.tmp / "out")
        self.assertTrue(library.is_dump(out))
        self.assertFalse((out / "__MACOSX").exists())
        expected = time.mktime((2024, 5, 6, 7, 8, 12, 0, 0, -1))
        self.assertEqual(int(os.stat(out / "base/romfs/data.bin").st_mtime), int(expected))
        # The same ZIP unpacked again gives the same files, times included.
        first = {p.relative_to(out): os.stat(p).st_mtime_ns for p in out.rglob("*") if p.is_file()}
        library.unpack_zip(game, self.tmp / "out")
        second = {p.relative_to(out): os.stat(p).st_mtime_ns for p in out.rglob("*") if p.is_file()}
        self.assertEqual(first, second)

    def test_refuses_paths_outside(self):
        path = self.tmp / "evil.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("base/exefs/main.npdm", npdm(HOLLOW))
            archive.writestr("base/romfs/data.bin", b"x")
            archive.writestr("../outside.txt", b"x")
        with self.assertRaises(ValueError):
            library.inspect_zip(path)

    def test_refuses_two_games(self):
        path = self.tmp / "two.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for root, title_id in (("A", HOLLOW), ("B", MKW)):
                archive.writestr(f"{root}/base/exefs/main.npdm", npdm(title_id))
                archive.writestr(f"{root}/base/romfs/data.bin", b"x")
        with self.assertRaises(ValueError):
            library.inspect_zip(path)

    def test_dump_at_the_root(self):
        path = make_zip_dump(self.tmp / "root.zip", HOLLOW, root="")
        root, title_id, size = library.inspect_zip(path)
        self.assertEqual((root, title_id), ("", HOLLOW))
        self.assertGreater(size, 0)


if __name__ == "__main__":
    unittest.main()
