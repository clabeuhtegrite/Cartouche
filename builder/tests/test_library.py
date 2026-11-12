import os
import time
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from cartouche_builder import identify, library, titles

from support import HOLLOW, MKW, ODYSSEY, ZELDA, Home, make_dump, make_nsp, make_nup, make_xci, make_zip_dump, npdm, write_keys


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


class NamedWithoutTheirId(Home):
    """Games as players keep them: named as they like, loose or in folders of
    folders, which the builder reads in the files themselves (identify.py)."""

    def setUp(self):
        super().setUp()
        self.root = self.tmp / "sources"
        self.keys = write_keys(self.tmp / "prod.keys")
        self.cache = self.tmp / "identified.json"

    def discover(self, keys=True):
        return library.discover(self.root, keys=self.keys if keys else None, cache=self.cache)

    def test_an_xci_and_a_nup_each_in_its_folder(self):
        # A player's report: "an .XCI and a .NUP in two different folders", no game found.
        make_xci(self.root / "Zelda" / "Zelda.XCI", [ZELDA])
        make_nup(self.root / "Mario Kart World" / "MKW.NUP", [(MKW, 0)])
        found = self.discover()
        self.assertEqual({g.title_id: g.kind for g in found.games}, {ZELDA: "packages", MKW: "nup"})
        zelda = next(g for g in found.games if g.title_id == ZELDA)
        self.assertEqual((zelda.folder, zelda.shared, zelda.label), (self.root / "Zelda", False, "Zelda"))
        self.assertEqual(found.issues, [])

    def test_without_keys_says_so(self):
        make_xci(self.root / "Zelda" / "Zelda.xci", [ZELDA])
        make_nup(self.root / "Mario Kart World" / "MKW.nup", [(MKW, 0)])
        found = self.discover(keys=False)
        self.assertEqual([g.title_id for g in found.games], [MKW])  # a NUP needs no keys
        self.assertEqual(len(found.issues), 1)
        self.assertIn("Zelda/Zelda.xci", found.issues[0])
        self.assertIn("prod.keys", found.issues[0])

    def test_loose_in_the_sources_folder(self):
        make_xci(self.root / "Zelda.xci", [ZELDA])
        make_nsp(self.root / "Zelda update.nsp", [(f"{ZELDA[:13].lower()}800" + "0" * 15 + "5.tik", b"t")])
        make_nsp(self.root / f"Odyssey [{ODYSSEY}][v0].nsp", [("x.nca", b"")])
        make_nup(self.root / "mkw.nup", [(MKW, 0)])
        found = self.discover()
        games = {g.title_id: g for g in found.games}
        self.assertEqual(set(games), {ZELDA, ODYSSEY, MKW})
        self.assertEqual(sorted(p.name for p in games[ZELDA].inputs), ["Zelda update.nsp", "Zelda.xci"])
        self.assertTrue(games[ZELDA].shared and games[ODYSSEY].shared)
        self.assertEqual(games[ZELDA].source, self.root / "Zelda.xci")  # its base game, for the Finder
        self.assertEqual(games[ZELDA].label, "Zelda")
        self.assertEqual(found.issues, [])

    def test_folders_of_folders(self):
        make_xci(self.root / "Switch" / "Zelda" / "zelda.xci", [ZELDA])
        make_dump(self.root / "Switch 2" / "Dumps" / "Mario Kart World", MKW)
        # nxnative's own build folder, beside a game it built: no game in it.
        make_dump(self.root / "Switch" / "Zelda" / f"{ZELDA}_build" / "extract", ODYSSEY)
        (self.root / "Covers").mkdir(parents=True)
        found = self.discover()
        self.assertEqual({g.title_id: g.folder for g in found.games}, {ZELDA: self.root / "Switch" / "Zelda", MKW: self.root / "Switch 2" / "Dumps" / "Mario Kart World"})
        self.assertEqual(found.issues, ["Covers: no game in it (packages, .nup, dump or zipped dump)."])

    def test_what_nxnative_built_is_no_dump(self):
        # A player's report: "I have an existing romfs.img but it says 0
        # games found". What nxnative built goes in the games folder.
        (self.root / "Mario Kart World").mkdir(parents=True)
        (self.root / "Mario Kart World" / "Mario Kart World.ipa").write_bytes(b"PK")
        (self.root / "Mario Kart World" / "RomFS.img").write_bytes(b"DMROMFS1")
        (self.root / "romfs.img").write_bytes(b"DMROMFS1")
        (self.root / f"{MKW}_build" / "extract").mkdir(parents=True)
        found = self.discover()
        self.assertEqual(found.games, [])
        self.assertEqual(found.issues, [
            "romfs.img: a game’s files (its RomFS image), not a dump. They go in your games folder, "
            "beside the IPA nxnative built without them, where Cartouche installs the two together.",
            f"{MKW}_build: a folder nxnative builds a game in, which Cartouche Builder leaves alone. "
            "An IPA nxnative made goes in your games folder, with its romfs.img if it has one.",
            "Mario Kart World/Mario Kart World.ipa: an IPA built already, not a dump. It goes in your games folder, "
            "where Cartouche installs it from, with its romfs.img if it was built without its game files.",
            "Mario Kart World/RomFS.img: a game’s files (its RomFS image), not a dump. They go in your games folder, "
            "beside the IPA nxnative built without them, where Cartouche installs the two together.",
        ])

    def test_what_nxnative_built_beside_a_game_is_the_players(self):
        make_xci(self.root / "Zelda" / "zelda.xci", [ZELDA])
        (self.root / "Zelda" / "Zelda.ipa").write_bytes(b"PK")
        (self.root / "Zelda" / "romfs.img").write_bytes(b"DMROMFS1")
        (self.root / "Zelda" / f"{ZELDA}_build").mkdir()
        make_dump(self.root / "Mario Kart World", MKW)
        (self.root / "Mario Kart World" / "romfs.img").write_bytes(b"DMROMFS1")
        found = self.discover()
        self.assertEqual({g.title_id for g in found.games}, {ZELDA, MKW})
        self.assertEqual(found.issues, [])

    def test_update_in_a_folder_of_its_own(self):
        make_xci(self.root / "Zelda" / "zelda.xci", [ZELDA])
        make_nsp(self.root / "Zelda" / "Update" / "v1.2.nsp", [(f"{ZELDA[:13]}800" + "0" * 15 + "5.tik", b"t")])
        found = self.discover()
        self.assertEqual(len(found.games), 1)
        zelda = found.games[0]
        self.assertEqual([p.name for p in zelda.inputs], ["zelda.xci", "v1.2.nsp"])
        self.assertTrue(zelda.shared)
        self.assertEqual(zelda.source, self.root / "Zelda" / "zelda.xci")
        self.assertEqual(found.issues, [])

    def test_two_copies_keep_the_most_complete(self):
        make_xci(self.root / "Zelda" / "zelda.xci", [ZELDA, "01007EF00011E800"])
        make_xci(self.root / "Old" / "zelda.xci", [ZELDA])
        found = self.discover()
        self.assertEqual([g.folder.name for g in found.games], ["Zelda"])
        self.assertEqual(found.issues, [f"Old: the same game ({ZELDA}) as Zelda; only Zelda is built."])

    def test_a_folder_named_after_its_game_reads_nothing(self):
        # As before: the folder's name says which game its packages are.
        make_xci(self.root / f"Zelda [{ZELDA}]" / "zelda.xci", [ZELDA])
        with mock.patch.object(identify, "package_title_ids", side_effect=AssertionError("read")):
            found = self.discover()
        self.assertEqual([g.title_id for g in found.games], [ZELDA])
        self.assertFalse(found.games[0].shared)

    def test_files_that_are_no_game(self):
        (self.root / "Zelda").mkdir(parents=True)
        (self.root / "Zelda" / "zelda.xci").write_bytes(b"an incomplete download")
        found = self.discover()
        self.assertEqual(found.games, [])
        self.assertEqual(len(found.issues), 1)
        self.assertIn("Zelda/zelda.xci: not a game Cartouche Builder can read", found.issues[0])


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
