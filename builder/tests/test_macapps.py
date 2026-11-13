"""The games' Mac apps (macapps.py): what their Info.plist says, the name
each gets in the Mac apps folder, finding them there, and putting a new one
in place of the old, never in place of another app, never half."""

import plistlib
import subprocess
import threading
from pathlib import Path
from unittest import mock

from cartouche_builder import macapps

from support import MKW, ODYSSEY, Home


def make_app(path: Path, title_id: str | None = MKW, commit: str = "0123456789ab", **info) -> Path:
    """An app of a few bytes, as nxnative's packer lays it out."""
    (path / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)
    keys = {"CFBundleName": path.stem, "CFBundleShortVersionString": "1.0.0", **info}
    if title_id:
        keys.update({"DMTitleID": title_id, "DMCommit": commit, "DMChain": "abcdef012345"})
    (path / "Contents" / "Info.plist").write_bytes(plistlib.dumps(keys))
    (path / "Contents" / "MacOS" / "dmhost").write_bytes(b"host " + commit.encode())
    return path


class MacApps(Home):
    def setUp(self):
        super().setUp()
        self.folder = self.tmp / "Applications"
        self.folder.mkdir()
        self.out = self.tmp / "workspace" / ".cartouche-builder" / "out"
        self.out.mkdir(parents=True)

    def test_what_its_info_plist_says(self):
        app = make_app(self.tmp / "Game.app", MKW.lower(), commit="0123456789AB+dirty", CFBundleDisplayName="Mario Kart World", CFBundleIdentifier="org.nxnative.mkw")
        info = macapps.read_info(app)
        self.assertEqual((info.title_id, info.commit, info.dirty, info.chain, info.version), (MKW, "0123456789ab", True, "abcdef012345", "1.0.0"))
        self.assertEqual((info.name, info.bundle_id), ("Mario Kart World", "org.nxnative.mkw"))
        self.assertTrue(macapps.is_games(app, MKW))
        self.assertFalse(macapps.is_games(app, ODYSSEY))
        # Another app, a folder that is no app, an Info.plist that is no plist.
        other = make_app(self.tmp / "Other.app", None)
        self.assertIsNone(macapps.read_info(other).title_id)
        self.assertFalse(macapps.is_games(other, MKW))
        self.assertIsNone(macapps.read_info(self.tmp / "Nothing.app"))
        broken = self.tmp / "Broken.app" / "Contents"
        broken.mkdir(parents=True)
        (broken / "Info.plist").write_bytes(b"not a plist")
        self.assertIsNone(macapps.read_info(broken.parent))

    def test_the_games_name_as_nxnative_names_its_app(self):
        self.assertEqual(macapps.clean_name("The Legend of Zelda: Tears of the Kingdom"), "The Legend of Zelda - Tears of the Kingdom")
        self.assertEqual(macapps.clean_name("Fire/Ice : Saga"), "Fire - Ice - Saga")
        self.assertEqual(macapps.clean_name(" .Odd\tname​. "), "Odd name")
        self.assertEqual(macapps.clean_name("..."), "Game")
        self.assertEqual(len(macapps.clean_name("A" * 300)), 120)

    def test_the_name_it_gets_in_the_folder(self):
        self.assertEqual(macapps.target_name(self.folder, MKW, "Mario Kart World"), "Mario Kart World.app")
        # The game's own app there keeps its name; another app's name is not taken.
        make_app(self.folder / "Mario Kart World.app", MKW)
        self.assertEqual(macapps.target_name(self.folder, MKW, "Mario Kart World"), "Mario Kart World.app")
        self.assertEqual(macapps.target_name(self.folder, ODYSSEY, "Mario Kart World"), f"Mario Kart World [{ODYSSEY}].app")
        make_app(self.folder / "Super Mario Odyssey.app", None)
        self.assertEqual(macapps.target_name(self.folder, ODYSSEY, "Super Mario Odyssey"), f"Super Mario Odyssey [{ODYSSEY}].app")
        # The name the player gave it in the Finder, while it is still the game's or gone.
        make_app(self.folder / "MKW.app", MKW)
        self.assertEqual(macapps.target_name(self.folder, MKW, "Mario Kart World", "MKW.app"), "MKW.app")
        self.assertEqual(macapps.target_name(self.folder, MKW, "Mario Kart World", "Gone.app"), "Gone.app")
        self.assertEqual(macapps.target_name(self.folder, ODYSSEY, "Super Mario Odyssey", "MKW.app"), f"Super Mario Odyssey [{ODYSSEY}].app")
        # A link of that name is no app of the game's.
        (self.folder / "Link.app").symlink_to(self.folder / "MKW.app")
        self.assertEqual(macapps.target_name(self.folder, MKW, "Link"), f"Link [{MKW}].app")

    def test_finding_the_games_apps(self):
        make_app(self.folder / "B.app", MKW)
        make_app(self.folder / "A.app", MKW)
        make_app(self.folder / "Odyssey.app", ODYSSEY)
        make_app(self.folder / "Safari.app", None)
        make_app(self.folder / ".Hidden.app", ODYSSEY)
        (self.folder / "Notes.txt").write_text("not an app")
        self.assertEqual(macapps.index(self.folder), {MKW: self.folder / "A.app", ODYSSEY: self.folder / "Odyssey.app"})
        self.assertEqual(macapps.index(self.tmp / "none"), {})
        self.assertEqual(macapps.index(None), {})
        self.assertEqual(macapps.find(self.folder, MKW, "B.app"), self.folder / "B.app")
        self.assertEqual(macapps.find(self.folder, MKW, "Odyssey.app"), self.folder / "A.app")
        self.assertEqual(macapps.find(self.folder, MKW.lower()), self.folder / "A.app")
        self.assertIsNone(macapps.find(self.folder, "0100A0000E2F0000"))
        self.assertIsNone(macapps.find(None, MKW))

    def built(self, commit: str = "0123456789ab") -> Path:
        """What nxnative leaves in the workspace: the app, and its packer's files beside it."""
        app = make_app(self.out / f"{MKW}.app", MKW, commit)
        Path(f"{app}.key").write_text("key\n")
        make_app(Path(f"{app}.partial"), MKW)
        return app

    def test_a_new_app_in_place_of_the_old(self):
        old = make_app(self.folder / "Mario Kart World.app", MKW, "111111111111")
        (old / "Contents" / "Resources").mkdir()
        (old / "Contents" / "Resources" / "stale.bin").write_bytes(b"old")
        built = self.built("222222222222")
        target = macapps.deliver(built, self.folder, "Mario Kart World.app")
        self.assertEqual(target, self.folder / "Mario Kart World.app")
        self.assertEqual(macapps.read_info(target).commit, "222222222222")
        self.assertFalse((target / "Contents" / "Resources" / "stale.bin").exists())
        # Nothing of it in the workspace, nothing half in the folder.
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), [])
        self.assertEqual(sorted(p.name for p in self.folder.iterdir()), ["Mario Kart World.app"])

    def test_copied_whole_to_another_disk(self):
        built = self.built()
        with mock.patch.object(macapps, "same_volume", return_value=False):
            target = macapps.deliver(built, self.folder, "Mario Kart World.app")
        self.assertEqual((target / "Contents" / "MacOS" / "dmhost").read_bytes(), b"host 0123456789ab")
        self.assertFalse(built.exists())
        self.assertEqual(sorted(p.name for p in self.folder.iterdir()), ["Mario Kart World.app"])

    def test_stopped_or_failed_on_the_way_the_old_app_stays(self):
        old = make_app(self.folder / "Mario Kart World.app", MKW, "111111111111")
        stop = threading.Event()
        stop.set()
        built = self.built("222222222222")
        with self.assertRaises(InterruptedError):
            macapps.deliver(built, self.folder, "Mario Kart World.app", stop=stop)
        self.assertEqual(macapps.read_info(old).commit, "111111111111")
        self.assertEqual(sorted(p.name for p in self.folder.iterdir()), ["Mario Kart World.app"])
        # A copy to another disk that fails half way.
        calls = []

        def failing(src, dst, *args, **kwargs):
            calls.append(src)
            if len(calls) > 1:
                raise OSError(28, "No space left on device")
            return src

        with mock.patch.object(macapps, "same_volume", return_value=False), mock.patch.object(macapps.shutil, "copy2", side_effect=failing):
            with self.assertRaises(OSError):
                macapps.deliver(built, self.folder, "Mario Kart World.app")
        self.assertEqual(macapps.read_info(old).commit, "111111111111")
        self.assertEqual(sorted(p.name for p in self.folder.iterdir()), ["Mario Kart World.app"])

    def test_what_nxnative_left_is_forgotten(self):
        built = self.built()
        Path(f"{built}.old").mkdir()
        macapps.forget_built(built)
        self.assertEqual(list(self.out.iterdir()), [])
        macapps.forget_built(built)  # nothing left: no error

    def test_a_game_running_from_its_app(self):
        app = self.folder / "Mario Kart World.app"
        lines = f"/sbin/launchd\n{app}/Contents/MacOS/nxnative\n{app}/Contents/MacOS/dmhost --game x\n"
        with mock.patch.object(macapps.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, lines, "")):
            self.assertTrue(macapps.running(app))
            self.assertFalse(macapps.running(self.folder / "Mario Kart.app"))
        with mock.patch.object(macapps.subprocess, "run", side_effect=OSError("no ps")):
            self.assertFalse(macapps.running(app))
