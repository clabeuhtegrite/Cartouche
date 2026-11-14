"""A full disk in the player's words (disks.py), and the names of why a game
was not built (causes.py)."""

import errno
import unittest
from pathlib import Path
from unittest import mock

from cartouche_builder import causes, disks, i18n
from cartouche_builder.build import Result


class Disks(unittest.TestCase):
    def tearDown(self):
        i18n.set_language("en")

    def setUp(self):
        i18n.set_language("en")

    def test_what_a_full_disk_looks_like(self):
        self.assertTrue(disks.is_full(OSError(errno.ENOSPC, "No space left on device")))
        self.assertTrue(disks.is_full("cp: write error: No space left on device"))
        self.assertTrue(disks.is_full("less than 32 GB free on the volume of /Users/player/Builder"))
        self.assertTrue(disks.is_full("error: couldn't write: [Errno 28] No space left on device"))
        self.assertFalse(disks.is_full(OSError(errno.ENOENT, "No such file or directory")))
        self.assertFalse(disks.is_full("the fake build failed on purpose"))
        self.assertFalse(disks.is_full(None))

    def test_the_disk_a_message_names(self):
        self.assertEqual(disks.path_in("[Errno 28] No space left on device: '/Volumes/NAS/Games/x.ipa'"), Path("/Volumes/NAS/Games/x.ipa"))
        self.assertEqual(disks.path_in("less than 5 GB free on the volume of /Users/player/out"), Path("/Users/player/out"))
        self.assertIsNone(disks.path_in("fatal: write error: No space left on device"))
        # nxnative's traceback names its own code, on the Mac's disk: never the
        # disk that filled up (an external drive with the build folders).
        traceback = "\n".join([
            "[RED] OSError: [Errno 28] No space left on device",
            "Traceback (most recent call last):",
            '  File "/Users/player/Library/Application Support/Cartouche Builder/nxnative/scripts/build_ipa_from_nsp.py", line 671, in <module>',
            "    sys.exit(cli(sys.argv[1:]))",
            '  File "/opt/homebrew/Cellar/python@3.13/3.13.9/Frameworks/Python.framework/Versions/3.13/lib/python3.13/zipfile/__init__.py", line 1886, in writestr',
            "    dest.write(data)",
            "OSError: [Errno 28] No space left on device",
        ])
        self.assertIsNone(disks.path_in(traceback))
        with mock.patch.object(disks, "free_bytes", return_value=0):
            self.assertEqual(disks.message(Path("/Volumes/Games SSD/Builds/0100E2E000A10000_build"), traceback),
                             "The disk “Games SSD” is full (0.0 GB left). Free some room on it, then try again.")
        self.assertEqual(disks.volume(Path("/Volumes/Games SSD/Builder")), "Games SSD")
        self.assertEqual(disks.volume(Path("/Users/player")), "")
        self.assertEqual(disks.volume(Path("/System/Volumes/Data/Users")), "")
        # A share that is not mounted has nothing left to say.
        self.assertIsNone(disks.free_bytes(Path("/Volumes/Not Mounted/Games")))

    def test_amounts_in_the_players_language(self):
        self.assertEqual((disks.amount(412_000_000), disks.amount(12_400_000_000)), ("0.4 GB", "12 GB"))
        i18n.set_language("fr")
        self.assertEqual((disks.amount(412_000_000), disks.amount(12_400_000_000)), ("0,4 Go", "12 Go"))

    def test_the_players_words(self):
        with mock.patch.object(disks, "free_bytes", return_value=412_000_000):
            self.assertEqual(disks.message(Path("/Users/player/Builder")),
                             "Your Mac's disk is full (0.4 GB left). Free some room, on the Storage page for example, then try again.")
            self.assertEqual(disks.message(None, "No space left on device: '/Volumes/Games SSD/x'"),
                             "The disk “Games SSD” is full (0.4 GB left). Free some room on it, then try again.")
            self.assertEqual(disks.message(None, "less than 32 GB free on the volume of /Users/player/work"),
                             "nxnative needs 32 GB free on your Mac's disk to build this game, and 0.4 GB are left. Free some room, on the Storage page for example, then try again.")
            i18n.set_language("fr")
            self.assertEqual(disks.message(Path("/Users/player/Builder")),
                             "Le disque du Mac est plein (il reste 0,4 Go). Libérez de la place, par exemple dans Stockage, puis réessayez.")
            self.assertEqual(disks.message(None, "less than 32 GB free on the volume of /Volumes/SSD/work"),
                             "nxnative a besoin de 32 Go libres sur le disque « SSD » pour construire ce jeu, et il en reste 0,4 Go. Libérez-y de la place, puis réessayez.")
        with mock.patch.object(disks, "free_bytes", return_value=None):
            self.assertEqual(disks.message(None), "Le disque du Mac est plein. Libérez de la place, par exemple dans Stockage, puis réessayez.")

    def test_no_room_in_the_players_words(self):
        """A game skipped for the room the settings keep free: how much is
        missing, in whole gigabytes that add up, and what makes room."""
        self.assertEqual(disks.no_room(Path("/Users/player/Builder/workspace"), 13.7, 20, 0, 20),
                         "7 GB missing to build this game: Cartouche Builder starts a build only with 20 GB free on your Mac's disk, "
                         "and only 13 GB are free there. Free some room there (the Storage page shows what the build folders take), "
                         "choose build folders on another disk (Settings › Folders), or lower “Keep at least 20 GB free” (Settings › Storage).")
        i18n.set_language("fr")
        self.assertEqual(disks.no_room(Path("/Volumes/SSD/builds"), 25.2, 31.4, 11.4, 20),
                         "Il manque 7 Go pour construire ce jeu : Cartouche Builder ne commence une construction qu'avec 32 Go libres "
                         "sur le disque « SSD », dont 12 Go pour décompresser son zip, et il n'y en a que 25. Libérez-y de la place "
                         "(la page Stockage montre ce que prennent les dossiers de construction), choisissez des dossiers de construction "
                         "sur un autre disque (Réglages › Dossiers) ou baissez « Garder au moins 20 Go libres » (Réglages › Stockage).")

    def test_the_room_before_a_build(self):
        """What the app's card says before a game would be skipped for the
        room kept free: nothing to say while there is room."""
        with mock.patch.object(disks, "free_bytes", return_value=13.7 * 2**30):
            short = disks.room(Path("/Users/player/Builder/workspace"), 20, 2)
            self.assertEqual({k: short[k] for k in ("free_gb", "keep_gb", "folders", "title")},
                             {"free_gb": 13, "keep_gb": 20, "folders": 2, "title": "7 GB missing to build"})
            self.assertEqual(short["text"], "Cartouche Builder starts a build only with 20 GB free on your Mac's disk, and only 13 GB are free there. "
                                            "It first removes the build folders of the games built longest ago (2), which may be enough. "
                                            "Free some room there (Storage shows what the build folders take), choose build folders on another disk, "
                                            "or lower “Keep at least 20 GB free”.")
            self.assertNotIn("removes", disks.room(Path("/Users/player/Builder/workspace"), 20, 0)["text"])
            self.assertEqual(disks.room(Path("/Users/player/Builder/workspace"), 10, 0), {"free_gb": 13, "keep_gb": 10, "folders": 0})
        with mock.patch.object(disks, "free_bytes", return_value=None):
            self.assertIsNone(disks.room(Path("/Volumes/NAS/builds"), 20, 0))

    def test_an_error_described(self):
        error = OSError(errno.ENOSPC, "No space left on device", "/Volumes/NAS/Games/x.ipa")
        self.assertEqual(disks.describe(error), "The disk “NAS” is full. Free some room on it, then try again.")
        other = OSError(errno.EACCES, "Permission denied", "/Users/player/x")
        self.assertEqual(disks.describe(other), str(other))


class Causes(unittest.TestCase):
    def setUp(self):
        i18n.set_language("en")

    def tearDown(self):
        i18n.set_language("en")

    def result(self, code=1, stage="", said=(), stderr=(), stopped=False) -> Result:
        return Result(code=code, ok=False, stage=stage, said=list(said), stderr=list(stderr), stopped=stopped)

    def test_the_cause_of_a_build(self):
        self.assertEqual(causes.of_build(self.result(stopped=True, code=130)), "stopped")
        self.assertEqual(causes.of_build(self.result(code=2)), "refused")
        self.assertEqual(causes.of_build(self.result(said=["less than 32 GB free on the volume of /x"], stage="unpack v0")), "no_space")
        # A full disk at the app build is no commit's fault.
        self.assertEqual(causes.of_build(self.result(stage="app build", stderr=["ld: write error: No space left on device"])), "no_space")
        self.assertEqual(causes.of_build(self.result(said=["v131072: 3 file(s) whose bytes do not start as their names promise (a .zs file that is not a zstd stream), so the game files are damaged:"])), "damaged")
        self.assertEqual(causes.of_build(self.result(said=["/x/game.nup: table of contents does not match its SHA-256 (damaged file)"])), "damaged")
        self.assertEqual(causes.of_build(self.result(code=-9, stage="shaders")), "signal")
        self.assertEqual(causes.of_build(self.result(stage="app build", said=["xcodebuild failed (exit 65)"])), "app_build")
        self.assertEqual(causes.of_build(self.result(stderr=["Traceback (most recent call last):", '  File "x.py", line 1', "KeyError: 'icon'"])), "crashed")
        self.assertEqual(causes.of_build(self.result(said=["no game package with a readable content meta in /x"])), "nxnative")
        missing = Result(code=-1, ok=False, started=False)
        self.assertEqual(causes.of_build(missing), "no_start")

    METAL = ("this Mac's Metal compiler is not the one the shaders were tested with (dm/gfx/tools/dmsh_chain.lock): "
             "metal_iphoneos Apple metal version 32023.620 (tested: Apple metal version 32023.850). Untested compilers are unsupported "
             "(GitHub issue #242). The Metal compiler is the selected Xcode's (selected: Xcode {selected} in /Applications/Xcode.app/Contents/Developer): "
             "install Xcode 27.2 (macOS 26.6 or later) from https://developer.apple.com/download/all/ (beside a newer Xcode, as /Applications/Xcode-27.2.app)")

    def test_another_metal_compiler(self):
        """nxnative's refusal of the Mac's Metal compiler comes after its
        check of the files, at their stage: never "nxnative", nor damaged."""
        said = self.METAL.format(selected="27.1")
        self.assertEqual(causes.of_build(self.result(said=[said], stage="check v131072 files")), "metal")
        self.assertEqual(causes.of_build(self.result(said=[said], stage="unpack v131072")), "metal")
        self.assertTrue(causes.words("metal", said).startswith("nxnative builds this game's shaders only with the Metal compiler of Xcode 27.2, "
                                                                "which it tested them with, and this Mac has Xcode 27.1. Update Xcode in the App Store"))
        self.assertIn("and this Mac's Xcode 27.3 has another one, which nxnative has not tested yet.", causes.words("metal", self.METAL.format(selected="27.3")))
        # Xcode not said, nor the one nxnative wants.
        no_xcode = said.replace("Xcode 27.1 in", "no Xcode in")
        self.assertIn("and this Mac has another Xcode. Update Xcode in the App Store", causes.words("metal", no_xcode))
        self.assertTrue(causes.words("metal", "Metal compiler is not the one the shaders were tested with").startswith(
            "nxnative builds this game's shaders only with the Metal compiler it tested them with, and this Mac's Xcode has another one."))
        i18n.set_language("fr")
        self.assertTrue(causes.words("metal", said).startswith("nxnative ne construit les shaders de ce jeu qu'avec le compilateur Metal de Xcode 27.2, "
                                                                "avec lequel il les a testés, et ce Mac a Xcode 27.1. Mettez Xcode à jour dans l'App Store"))

    def test_older_versions(self):
        self.assertTrue(causes.older("27.1", "27.2"))
        self.assertTrue(causes.older("27.1.1 (27B80)", "27.2"))
        self.assertTrue(causes.older("26.4", "27.2"))
        self.assertFalse(causes.older("27.2", "27.2"))
        self.assertFalse(causes.older("27.2 (27C55)", "27.2"))
        self.assertFalse(causes.older("27.10", "27.2"))
        self.assertFalse(causes.older("28", "27.2"))
        self.assertFalse(causes.older("", "27.2"))
        self.assertFalse(causes.older("beta", "27.2"))

    def test_an_exception_by_its_class_alone(self):
        self.assertEqual(causes.exception_in(["Traceback (most recent call last):", '  File "x.py", line 3, in <module>', "    main()", "romfs_image.FormatError: bad head at /Users/player/x"]), "FormatError")
        self.assertIsNone(causes.exception_in(["KeyError: 'icon'"]))
        self.assertIsNone(causes.exception_in(["Traceback (most recent call last):", "  File \"x.py\"", "not a name: at all"]))

    def test_damaged_files_in_the_players_words(self):
        said = "v131072: 3 file(s) whose bytes do not start as their names promise (a .zs file that is not a zstd stream), so the game files are damaged:"
        self.assertTrue(causes.words("damaged", said).startswith("Some of this game's files are damaged (its update v131072): "))
        self.assertTrue(causes.words("damaged", said.replace("v131072", "v0")).startswith("Some of this game's files are damaged (the base game): "))
        self.assertTrue(causes.words("damaged", "x.nup: 1,024 bytes, its header says 4,096 (copied or downloaded partly?)").startswith("Some of this game's files are damaged: "))
        i18n.set_language("fr")
        self.assertTrue(causes.words("damaged", said).startswith("Des fichiers de ce jeu sont abîmés (sa mise à jour v131072) : "))
        self.assertIsNone(causes.words("nxnative", said))


if __name__ == "__main__":
    unittest.main()
