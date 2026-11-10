import time
import unittest

from cartouche_builder import config as configs
from cartouche_builder import library
from cartouche_builder.engine import Engine
from cartouche_builder.paths import Paths
from cartouche_builder.planner import plan
from cartouche_builder.state import Build, Store, attempt_now
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


class Planning(Home):
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
        self.config = configs.Config(sources=str(self.sources), games=str(self.games))

    def make_plan(self, force=None, now=None, toolchain=""):
        found = library.discover(self.sources, NAMES)
        return {e.title_id: e for e in plan(found.games, self.engine, self.engine.head(), self.engine.profiles(), self.store, self.config, self.games, toolchain, force, now).entries}

    def built_now(self, title_id, days_ago=0.0, commit_sha=None, toolchain=""):
        game = next(g for g in library.discover(self.sources, NAMES).games if g.title_id == title_id)
        name = f"{NAMES[title_id]} [{title_id}].ipa"
        make_ipa(self.games / name, {"DMTitleID": title_id, "DMCommit": (commit_sha or self.engine.head())[:12]})
        when = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - days_ago * 86400))
        self.store.built(title_id, Build(commit=(commit_sha or self.engine.head())[:12], built_at=when, ipa=name, fingerprint=fingerprint(game), toolchain=toolchain))

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


if __name__ == "__main__":
    unittest.main()
