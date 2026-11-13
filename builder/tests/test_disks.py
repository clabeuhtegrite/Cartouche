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
        # nxnative's Mac app packer, on a disk where it cannot clone the game's files.
        self.assertTrue(disks.is_full("the app needs 12.3 GB on the volume of /Volumes/Games SSD/Builds/.cartouche-builder/out (no APFS clones from the build there) and 5.0 GB are free"))
        self.assertTrue(disks.is_full("error: couldn't write: [Errno 28] No space left on device"))
        self.assertFalse(disks.is_full(OSError(errno.ENOENT, "No such file or directory")))
        self.assertFalse(disks.is_full("the fake build failed on purpose"))
        self.assertFalse(disks.is_full(None))

    def test_the_disk_a_message_names(self):
        self.assertEqual(disks.path_in("[Errno 28] No space left on device: '/Volumes/NAS/Games/x.ipa'"), Path("/Volumes/NAS/Games/x.ipa"))
        self.assertEqual(disks.path_in("less than 5 GB free on the volume of /Users/player/out"), Path("/Users/player/out"))
        packer = "the app needs 12.3 GB on the volume of /Volumes/Games SSD/Builds/.cartouche-builder/out (no APFS clones from the build there) and 5.0 GB are free"
        self.assertEqual(disks.path_in(packer), Path("/Volumes/Games SSD/Builds/.cartouche-builder/out"))
        with mock.patch.object(disks, "free_bytes", return_value=5_000_000_000):
            self.assertEqual(disks.message(None, packer), "nxnative needs 12 GB free on the disk “Games SSD” to build this game, and 5.0 GB are left. Free some room on it, then try again.")
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

    def result(self, code=1, stage="", said=(), stderr=(), stopped=False, tail="") -> Result:
        return Result(code=code, ok=False, stage=stage, said=list(said), stderr=list(stderr), stopped=stopped, tail=tail)

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
        # A tool's own words, in the last lines of the step that failed:
        # the Mac app's packer finding no room for a copy of the game.
        packer = "---- last lines of /x/logs/mac_app.log ----\nthe app needs 12.3 GB on the volume of /x/out (no APFS clones from the build there) and 0.4 GB are free"
        self.assertEqual(causes.of_build(self.result(stage="Mac app", said=["pack_app.py exit code 1 (full output: /x/logs/mac_app.log)"], tail=packer)), "no_space")
        self.assertEqual(causes.of_build(self.result(stage="Mac app", said=["pack_app.py exit code 1 (full output: /x/logs/mac_app.log)"])), "nxnative")
        missing = Result(code=-1, ok=False, started=False)
        self.assertEqual(causes.of_build(missing), "no_start")

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
