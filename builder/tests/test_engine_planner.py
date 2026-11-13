import plistlib
import shutil
import time
import unittest

from cartouche_builder import config as configs
from cartouche_builder import library, macapps
from cartouche_builder.engine import Engine
from cartouche_builder.paths import Paths
from cartouche_builder.planner import plan
from cartouche_builder.state import Build, MacBuild, Store, attempt_now
from cartouche_builder.planner import fingerprint

from support import MKW, ODYSSEY, Home, commit, make_dump, make_engine_remote, make_ipa

NAMES = {MKW: "Mario Kart World", ODYSSEY: "Super Mario Odyssey"}


class EngineTests(Home):
    def setUp(self):
        super().setUp()
        self.remote = make_engine_remote(self.tmp / "remote", NAMES)
        self.engine = Engine(self.tmp / "engine", str(self.remote), "main")

    def test_clone_update_and_history(self):
        before, first = self.engine.update()
        self.assertIsNone(before)
        self.assertEqual(set(self.engine.profiles()), {MKW, ODYSSEY})
        self.assertEqual(self.engine.profiles()[MKW].name, "Mario Kart World")
        second = commit(self.remote, "Mario Kart World's karts", {"dm/host/kart.c": "x"})
        (self.engine.root / "dm/gfx/nvn/dmsh_chain.h").write_text("changed by a build\n")
        old, new = self.engine.update()
        self.assertEqual((old, new), (first, second))
        self.assertEqual((self.engine.root / "dm/gfx/nvn/dmsh_chain.h").read_text(), '#define DMSH_CHAIN "abcdef012345"\n')
        commits = self.engine.commits(first, second)
        self.assertEqual([c.sha for c in commits], [second])
        self.assertEqual(commits[0].files, ["dm/host/kart.c"])
        self.assertEqual(self.engine.resolve(first[:12] + "+dirty"), first)
        self.assertIsNone(self.engine.resolve("0123456789ab"))
        self.assertTrue(self.engine.is_ancestor(first, second))
        self.assertFalse(self.engine.is_ancestor(second, first))


class PlanHome(Home):
    """Two games' dumps, nxnative's checkout, and the plan of their builds."""

    mac = False  # whether the games are built for this Mac too (the default)

    def setUp(self):
        super().setUp()
        self.remote = make_engine_remote(self.tmp / "remote", NAMES)
        self.engine = Engine(self.tmp / "engine", str(self.remote), "main")
        self.engine.update()
        self.paths = Paths.default()
        self.store = Store(self.paths)
        self.sources = self.tmp / "sources"
        make_dump(self.sources / "Mario Kart World", MKW)
        make_dump(self.sources / "Odyssey", ODYSSEY)
        self.games = self.tmp / "games"
        self.games.mkdir()
        self.mac_apps = self.tmp / "Applications"
        self.config = configs.Config(sources=str(self.sources), games=str(self.games), mac=self.mac, mac_apps=str(self.mac_apps))
        # The games folder keeps the Mac apps, as they are on this Mac's disk.
        self.place = macapps.Place(library=self.games, packed=False, installs=self.mac_apps)

    def make_plan(self, force=None, now=None, toolchain=""):
        found = library.discover(self.sources, NAMES)
        entries = plan(found.games, self.engine, self.engine.head(), self.engine.profiles(), self.store, self.config, self.games, toolchain, force, now, mac=self.place).entries
        return {e.title_id: e for e in entries}

    def built_now(self, title_id, days_ago=0.0, commit_sha=None, toolchain=""):
        game = next(g for g in library.discover(self.sources, NAMES).games if g.title_id == title_id)
        name = f"{NAMES[title_id]} [{title_id}].ipa"
        make_ipa(self.games / name, {"DMTitleID": title_id, "DMCommit": (commit_sha or self.engine.head())[:12]})
        when = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - days_ago * 86400))
        self.store.built(title_id, Build(commit=(commit_sha or self.engine.head())[:12], built_at=when, ipa=name, fingerprint=fingerprint(game), toolchain=toolchain))

    def mac_built(self, title_id, days_ago=0.0, commit_sha=None, name=None):
        """The game's Mac app as the games folder keeps it (in one file when
        the place is packed), and its record."""
        game = next(g for g in library.discover(self.sources, NAMES).games if g.title_id == title_id)
        sha = (commit_sha or self.engine.head())[:12]
        when = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - days_ago * 86400))
        if self.place.packed:
            app = self.games / (name or macapps.packed_name(NAMES[title_id], title_id))
            app.write_bytes(b"PK")
        else:
            app = self.games / (name or f"{NAMES[title_id]}.app")
            (app / "Contents").mkdir(parents=True, exist_ok=True)
            (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"DMTitleID": title_id, "DMCommit": sha}))
        self.store.mac_built(title_id, MacBuild(commit=sha, built_at=when, app=app.name, folder=str(self.games), fingerprint=fingerprint(game), packed=self.place.packed))
        return app


class Planning(PlanHome):
    def test_never_built(self):
        entries = self.make_plan()
        self.assertTrue(entries[MKW].build)
        self.assertEqual(entries[MKW].reasons, ["new"])
        self.assertEqual(entries[MKW].ipa_name, f"Mario Kart World [{MKW}].ipa")

    def test_up_to_date(self):
        self.built_now(MKW)
        self.assertEqual(self.make_plan()[MKW].reasons, ["up_to_date"])

    def test_a_commit_naming_the_game(self):
        self.built_now(MKW)
        self.built_now(ODYSSEY)
        commit(self.remote, "Mario Kart World's shadows no longer flicker (PR #12)", {"dm/gfx/nvn/shadow.c": "x"})
        self.engine.update()
        entries = self.make_plan()
        self.assertEqual(entries[MKW].reasons, ["named"])
        self.assertTrue(entries[MKW].build)
        self.assertFalse(entries[ODYSSEY].build)
        self.assertIn("weekly", entries[ODYSSEY].detail)

    def test_a_profile_change(self):
        self.built_now(ODYSSEY)
        commit(self.remote, "Registers 1.3", {f"dm/games/{ODYSSEY}/game.tsv": "name\tSuper Mario Odyssey\n"})
        self.engine.update()
        self.assertEqual(self.make_plan()[ODYSSEY].reasons, ["profile"])

    def test_docs_only_changes_nothing(self):
        self.built_now(MKW)
        commit(self.remote, "Mario Kart World's page", {"docs/games.md": "x", "README.md": "y"})
        self.engine.update()
        self.assertEqual(self.make_plan()[MKW].reasons, ["up_to_date"])

    def test_shared_changes_by_policy(self):
        self.built_now(MKW, days_ago=8)
        commit(self.remote, "A shared fix", {"dm/host/shared.c": "x"})
        self.engine.update()
        self.assertEqual(self.make_plan()[MKW].reasons, ["shared"])
        self.config.engine_policy = "never"
        entry = self.make_plan()[MKW]
        self.assertFalse(entry.build)
        self.config.engine_policy = "always"
        self.built_now(MKW, days_ago=0, commit_sha=self.engine.git("rev-parse", "HEAD~1").strip())
        self.assertEqual(self.make_plan()[MKW].reasons, ["shared"])
        self.config.engine_policy = "weekly"
        self.assertFalse(self.make_plan()[MKW].build)

    def test_new_files_in_the_folder(self):
        self.built_now(MKW)
        (self.sources / "Mario Kart World" / "updates" / "65536" / "exefs").mkdir(parents=True)
        (self.sources / "Mario Kart World" / "updates" / "65536" / "exefs" / "main").write_bytes(b"update")
        self.assertEqual(self.make_plan()[MKW].reasons, ["source"])

    def test_missing_ipa(self):
        self.built_now(MKW)
        (self.games / f"Mario Kart World [{MKW}].ipa").unlink()
        self.assertEqual(self.make_plan()[MKW].reasons, ["missing"])

    def test_toolchain_change(self):
        self.built_now(MKW, toolchain="Xcode 27.1")
        self.assertEqual(self.make_plan(toolchain="Xcode 27.2")[MKW].reasons, ["toolchain"])

    def test_a_fork_commit(self):
        self.built_now(MKW, commit_sha="52124866abcd")
        self.assertEqual(self.make_plan()[MKW].reasons, ["unknown_base"])

    def test_an_ipa_built_elsewhere_is_taken_as_the_base(self):
        make_ipa(self.games / "MarioKartWorld.ipa", {"DMTitleID": MKW, "DMCommit": self.engine.head()[:12]})
        entry = self.make_plan()[MKW]
        self.assertEqual(entry.reasons, ["up_to_date"])
        self.assertEqual(entry.ipa_name, "MarioKartWorld.ipa")
        self.assertEqual(self.store.get(MKW).build.origin, "ipa")

    def test_failure_waits_for_a_change(self):
        game = next(g for g in library.discover(self.sources, NAMES).games if g.title_id == MKW)
        self.store.failed(MKW, attempt_now(self.engine.head()[:12], "failed", "boom", fingerprint(game), "", "/log"))
        entry = self.make_plan()[MKW]
        self.assertFalse(entry.build)
        self.assertEqual(entry.reasons, ["failed_here"])
        self.assertTrue(self.make_plan(force={MKW})[MKW].build)
        commit(self.remote, "Mario Kart World boots", {"dm/host/boot.c": "x"})
        self.engine.update()
        self.assertTrue(self.make_plan()[MKW].build)

    def test_selection_and_profiles(self):
        self.config.skip = [MKW]
        entries = self.make_plan()
        self.assertEqual(entries[MKW].reasons, ["not_selected"])
        make_dump(self.sources / "Unknown game", "0100A0000E2F0000")
        entries = self.make_plan()
        self.assertEqual(entries["0100A0000E2F0000"].reasons, ["no_profile"])
        self.config.unprofiled = True
        self.assertEqual(self.make_plan()["0100A0000E2F0000"].reasons, ["new"])



class MacPlanning(PlanHome):
    """A game built for the iPhone and for this Mac, as by default: its Mac
    app after its IPA, or alone (planner._mac)."""

    mac = True

    def test_both_by_default(self):
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac, entry.mac_only, entry.mac_reason), (True, ["new"], True, False, "with_ipa"))
        self.assertIsNone(entry.mac_app)

    def test_its_mac_app_alone_when_its_ipa_is_up_to_date(self):
        self.built_now(MKW)
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac, entry.mac_only), (True, ["mac_new"], True, True))
        self.assertEqual(entry.detail, "Not on this Mac yet: its Mac app is built")

    def test_up_to_date_on_both(self):
        self.built_now(MKW, days_ago=1)
        app = self.mac_built(MKW)
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac, entry.mac_reason), (False, ["up_to_date"], False, "up_to_date"))
        self.assertEqual((entry.mac_app, entry.mac_name), (app, "Mario Kart World.app"))

    def test_its_mac_app_gone_or_older_than_its_ipa(self):
        self.built_now(MKW, days_ago=1)
        app = self.mac_built(MKW)
        shutil.rmtree(app)
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.reasons, entry.mac_only, entry.mac_name), (["mac_missing"], True, "Mario Kart World.app"))
        # Another app of that name is not the game's.
        (app / "Contents").mkdir(parents=True)
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleName": "Mario Kart World"}))
        self.assertEqual(self.make_plan()[MKW].reasons, ["mac_missing"])
        shutil.rmtree(app)
        # Built before its IPA: built again from the IPA's commit and files.
        self.mac_built(MKW, days_ago=2)
        self.assertEqual(self.make_plan()[MKW].reasons, ["mac_behind"])

    def test_kept_in_one_file_on_a_nas(self):
        # The games folder on a NAS keeps the game's app in one file, beside
        # its IPA: the file is what the plan looks for.
        self.place = macapps.Place(library=self.games, packed=True, installs=self.mac_apps)
        self.built_now(MKW, days_ago=1)
        kept = self.mac_built(MKW)
        self.assertEqual(kept.name, f"Mario Kart World [{MKW}].app.zip")
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.reasons, entry.mac_reason, entry.mac_app, entry.mac_name), (["up_to_date"], "up_to_date", kept, kept.name))
        # This Mac's copy of it does not count: gone from the NAS, it is built again.
        (self.mac_apps / "Mario Kart World.app" / "Contents").mkdir(parents=True)
        (self.mac_apps / "Mario Kart World.app" / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"DMTitleID": MKW}))
        kept.unlink()
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.reasons, entry.mac_only, entry.mac_app), (["mac_missing"], True, None))
        # Found by the title ID its name ends with, under another name.
        (self.games / f"MKW [{MKW}].app.zip").write_bytes(b"PK")
        self.assertEqual(self.make_plan()[MKW].mac_app, self.games / f"MKW [{MKW}].app.zip")

    def test_an_app_kept_as_it_is_before_the_games_folder_went_to_a_nas(self):
        self.built_now(MKW, days_ago=1)
        self.mac_built(MKW)
        self.place = macapps.Place(library=self.games, packed=True, installs=self.mac_apps)
        self.assertEqual(self.make_plan()[MKW].reasons, ["mac_missing"])

    def test_its_mac_app_found_under_another_name(self):
        self.built_now(MKW, days_ago=1)
        self.mac_built(MKW)
        # Renamed by the player in the Finder: its Info.plist still names the game.
        (self.games / "Mario Kart World.app").rename(self.games / "MKW.app")
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.reasons, entry.mac_app, entry.mac_name), (["up_to_date"], self.games / "MKW.app", "MKW.app"))

    def test_with_its_ipa_when_its_ipa_is_due(self):
        self.built_now(MKW, days_ago=1)
        self.mac_built(MKW)
        commit(self.remote, "Mario Kart World's shadows no longer flicker (PR #12)", {"dm/gfx/nvn/shadow.c": "x"})
        self.engine.update()
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.reasons, entry.mac, entry.mac_only, entry.mac_reason), (["named"], True, False, "with_ipa"))

    def test_after_its_ipa_when_its_ipa_failed_here(self):
        game = next(g for g in library.discover(self.sources, NAMES).games if g.title_id == MKW)
        self.store.failed(MKW, attempt_now(self.engine.head()[:12], "failed", "boom", fingerprint(game), "", "/log"))
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac, entry.mac_reason), (False, ["failed_here"], False, "after_ipa"))

    def test_a_mac_app_that_failed_waits_for_a_change(self):
        self.built_now(MKW)
        game = next(g for g in library.discover(self.sources, NAMES).games if g.title_id == MKW)
        self.store.mac_failed(MKW, attempt_now(self.engine.head()[:12], "failed", "the Mac host did not build\nmore", fingerprint(game), "", "/log"))
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac, entry.mac_reason), (False, ["up_to_date"], False, "failed_here"))
        self.assertIn("the Mac host did not build", entry.mac_detail)
        # Not a failure of the game's: a full disk, a game open on this Mac.
        self.store.mac_failed(MKW, attempt_now(self.engine.head()[:12], "skipped", "full", fingerprint(game), "", ""))
        self.assertEqual(self.make_plan()[MKW].reasons, ["mac_new"])
        # Tried again when nxnative changes.
        self.store.mac_failed(MKW, attempt_now(self.engine.head()[:12], "failed", "boom", fingerprint(game), "", "/log"))
        commit(self.remote, "Mario Kart World boots", {"dm/host/boot.c": "x"})
        self.engine.update()
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.reasons, entry.mac_reason), (["named"], "with_ipa"))

    def test_a_game_built_for_this_mac_alone(self):
        self.config.set_platform(MKW, "ios", False)
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac, entry.mac_only), (True, ["new"], True, True))
        # Planned from its app's build, as an IPA is: no IPA is missing.
        self.mac_built(MKW)
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac_reason, entry.base), (False, ["up_to_date"], "up_to_date", self.engine.head()[:12]))
        commit(self.remote, "Mario Kart World's shadows no longer flicker (PR #12)", {"dm/gfx/nvn/shadow.c": "x"})
        self.engine.update()
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac_only, entry.mac_reason), (True, ["named"], True, "named"))
        shutil.rmtree(self.games / "Mario Kart World.app")
        self.assertEqual(self.make_plan()[MKW].reasons[:2], ["mac_missing", "named"])
        # Its failure waits for a change, as an IPA's does.
        game = next(g for g in library.discover(self.sources, NAMES).games if g.title_id == MKW)
        self.store.mac_failed(MKW, attempt_now(self.engine.head()[:12], "failed", "boom", fingerprint(game), "", "/log"))
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac), (False, ["failed_here"], False))

    def test_a_game_built_for_the_iphone_alone(self):
        self.config.set_platform(MKW, "mac", False)
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac, entry.mac_reason), (True, ["new"], False, ""))
        self.built_now(MKW)
        self.assertEqual(self.make_plan()[MKW].reasons, ["up_to_date"])
        # For every game, in the settings.
        self.config.mac = False
        self.built_now(ODYSSEY)
        self.assertEqual(self.make_plan()[ODYSSEY].reasons, ["up_to_date"])

    def test_built_for_neither(self):
        self.config.ios = False
        self.config.set_platform(MKW, "mac", False)
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.reasons, entry.mac), (False, ["no_platform"], False))
        self.assertTrue(self.make_plan()[ODYSSEY].mac_only)

    def test_a_game_not_followed_is_built_for_neither(self):
        self.config.skip = [MKW]
        entry = self.make_plan()[MKW]
        self.assertEqual((entry.build, entry.mac, entry.mac_reason), (False, False, "not_selected"))


if __name__ == "__main__":
    unittest.main()
