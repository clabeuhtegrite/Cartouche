"""The games' Mac apps (macapps.py): what their Info.plist says, the name
each gets in the Mac apps folder, finding them there, and putting a new one
in place of the old, never in place of another app, never half; kept in one
file in a games folder that cannot hold an app (a NAS's), and installed on
this Mac from there."""

import os
import plistlib
import subprocess
import threading
import zipfile
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

    # ---- Kept in one file ------------------------------------------------------------

    def test_where_the_apps_are_kept(self):
        """As they are on this Mac's own kind of disk (APFS, Mac OS
        Extended), in one file on a NAS's share or on a disk formatted for
        Windows; as they are when the Mac cannot tell."""
        games = self.tmp / "Games"
        games.mkdir()

        def mounted(kind):
            return (f"/dev/disk9s1 on /Volumes/Nowhere ({kind}, local)\n"
                    f"//player@nas.local/Games on {self.tmp} ({kind}, nodev, nosuid, mounted by player)\n")

        self.assertEqual(macapps.filesystem(games, mounted("smbfs")), "smbfs")
        for kind, holds in (("apfs", True), ("hfs", True), ("smbfs", False), ("exfat", False), ("msdos", False), ("nfs", False)):
            self.assertEqual(macapps.holds_apps(games, mounted(kind)), holds, kind)
        self.assertIsNone(macapps.filesystem(games, "map auto_home on /System/Volumes/Data/home (autofs, automounted)\n"))
        self.assertTrue(macapps.holds_apps(games, ""))
        self.assertTrue(macapps.holds_apps(self.tmp / "Not there", mounted("smbfs")))
        # A share the builder knows, mounted or not.
        self.assertFalse(macapps.holds_apps(games, "", shares=[str(self.tmp)]))
        self.assertTrue(macapps.holds_apps(games, "", shares=["/Volumes/Games"]))
        # The tests' own way to say it.
        with mock.patch.dict(os.environ, {macapps.PACKED_ENV: "1"}):
            self.assertFalse(macapps.holds_apps(games, mounted("apfs")))
        with mock.patch.dict(os.environ, {macapps.PACKED_ENV: "0"}):
            self.assertTrue(macapps.holds_apps(games, mounted("smbfs"), shares=[str(self.tmp)]))

    def packed_app(self, commit="222222222222"):
        """A game's app as nxnative lays it out, with its launcher and a
        framework's link, kept in one file in a NAS's games folder."""
        app = make_app(self.out / f"{MKW}.app", MKW, commit)
        launcher = app / "Contents" / "MacOS" / "nxnative"
        launcher.write_text("#!/bin/sh\n")
        launcher.chmod(0o755)
        versions = app / "Contents" / "Frameworks" / "Host.framework" / "Versions"
        (versions / "A").mkdir(parents=True)
        (versions / "A" / "Host").write_bytes(b"host")
        os.symlink("A", versions / "Current")
        named = macapps.named(app, "Mario Kart World")
        self.assertEqual(named.name, "Mario Kart World.app")
        library = self.tmp / "NAS" / "Jeux"
        packed = library / macapps.packed_name("Mario Kart World", MKW)
        self.assertEqual(macapps.pack(named, packed), packed.stat().st_size)
        macapps.forget_built(app)
        self.assertEqual(list(self.out.iterdir()), [])
        return packed

    def test_kept_in_one_file_and_installed_whole(self):
        packed = self.packed_app()
        library = packed.parent
        self.assertEqual(sorted(p.name for p in library.iterdir()), [f"Mario Kart World [{MKW}].app.zip"])
        self.assertEqual(macapps.index_packed(library), {MKW: packed})
        # Installed under the game's name, its launcher still executable,
        # its links still links.
        old = make_app(self.folder / "Mario Kart World.app", MKW, "111111111111")
        heard = []
        installed = macapps.install(packed, self.folder, MKW, old.name, progress=lambda done, total: heard.append((done, total)))
        self.assertEqual(installed, old)
        self.assertEqual(macapps.read_info(installed).commit, "222222222222")
        self.assertTrue(os.access(installed / "Contents" / "MacOS" / "nxnative", os.X_OK))
        current = installed / "Contents" / "Frameworks" / "Host.framework" / "Versions" / "Current"
        self.assertEqual((os.readlink(current), (current / "Host").read_bytes()), ("A", b"host"))
        total = macapps.unpacked_size(packed)
        self.assertEqual(heard[-1], (total, total))
        self.assertEqual(sorted(p.name for p in self.folder.iterdir()), ["Mario Kart World.app"])
        # The file stays in the games folder.
        self.assertTrue(packed.is_file())
        # Kept again of a new build: in place of the old file, never half.
        stop = threading.Event()
        stop.set()
        app = macapps.named(make_app(self.out / f"{MKW}.app", MKW, "333333333333"), "Mario Kart World")
        with self.assertRaises(InterruptedError):
            macapps.pack(app, packed, stop=stop)
        self.assertEqual(sorted(p.name for p in library.iterdir()), [packed.name])
        macapps.pack(app, packed)
        self.assertEqual(sorted(p.name for p in library.iterdir()), [packed.name])
        macapps.install(packed, self.folder, MKW, installed.name)
        self.assertEqual(macapps.read_info(installed).commit, "333333333333")

    def test_a_file_that_is_not_the_games_app_is_refused(self):
        library = self.tmp / "NAS"
        library.mkdir()
        old = make_app(self.folder / "Mario Kart World.app", MKW, "111111111111")

        def zipped(name, entries):
            path = library / name
            with zipfile.ZipFile(path, "w") as archive:
                for entry, data in entries.items():
                    archive.writestr(entry, data)
            return path

        info = plistlib.dumps({"DMTitleID": MKW})
        cases = {
            "not a zip": library / "Broken.app.zip",
            "outside": zipped("Outside.app.zip", {"Mario Kart World.app/Contents/Info.plist": info, "../../escaped.txt": b"x"}),
            "absolute": zipped("Absolute.app.zip", {"/tmp/escaped.txt": b"x"}),
            "another game's": zipped("Odyssey.app.zip", {"Super Mario Odyssey.app/Contents/Info.plist": plistlib.dumps({"DMTitleID": ODYSSEY})}),
            "two apps": zipped("Two.app.zip", {"A.app/Contents/Info.plist": info, "B.app/Contents/Info.plist": info}),
        }
        cases["not a zip"].write_bytes(b"not a zip")
        for case, path in cases.items():
            with self.subTest(case), self.assertRaises(ValueError):
                macapps.install(path, self.folder, MKW, old.name)
            self.assertEqual(macapps.read_info(old).commit, "111111111111", case)
            self.assertEqual(sorted(p.name for p in self.folder.iterdir()), [old.name], case)
        self.assertFalse((self.tmp / "escaped.txt").exists())
        # Files named after a game, that are no app of it: never listed as
        # one, never in place of its own.
        self.assertEqual(macapps.index_packed(library), {})
        (library / f".Mario Kart World [{MKW}].app.zip.builder-partial").write_bytes(b"half")
        (library / f"Mario Kart World [{MKW}].ipa").write_bytes(b"ipa")
        self.assertEqual(macapps.index_packed(library), {})
