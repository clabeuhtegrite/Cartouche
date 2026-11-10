import unittest

from cartouche_builder.engine import Commit
from cartouche_builder.impact import Matcher, analyze, classify, derived_names, normalize

NAMES = {
    "0400486024DEC000": "The Legend of Zelda: Ocarina of Time",
    "01007EF00011E000": "The Legend of Zelda: Breath of the Wild",
    "010057D006492000": "OCTOPATH TRAVELER",
    "0100A3501946E000": "OCTOPATH TRAVELER II",
    "010013C00E930000": "Hollow Knight: Silksong",
    "0100A0000E2F0000": "Hollow Knight",
    "0100276009872000": "ŌKAMI HD",
    "040074A01BF12000": "Donkey Kong Bananza",
    "010056B015FE8000": "NieR:Automata The End of YoRHa Edition",
    "0100B8E016F76000": "NieR:Automata The End of YoRHa Edition",
}


class Names(unittest.TestCase):
    def test_normalize(self):
        self.assertEqual(normalize("ŌKAMI™  HD"), "okami hd")
        self.assertEqual(normalize("Link’s"), "link's")

    def test_derived(self):
        self.assertIn("Ocarina of Time", derived_names("The Legend of Zelda: Ocarina of Time"))
        self.assertIn("Legend of Zelda", derived_names("The Legend of Zelda: Ocarina of Time"))
        self.assertNotIn("Z-A", derived_names("Pokémon Legends: Z-A"))


class Matching(unittest.TestCase):
    def setUp(self):
        self.matcher = Matcher(NAMES, {"0400486024DEC000": ["Hyrule remake"]})

    def named(self, message):
        return self.matcher.named(message)

    def test_short_form_of_one_game(self):
        self.assertEqual(self.named("Ocarina of Time's castle town wall no longer draws black"), {"0400486024DEC000"})

    def test_shared_short_form_names_none(self):
        self.assertEqual(self.named("The Legend of Zelda games keep their saves"), set())

    def test_longest_name_wins(self):
        self.assertEqual(self.named("OCTOPATH TRAVELER II: the menu draws"), {"0100A3501946E000"})
        self.assertEqual(self.named("OCTOPATH TRAVELER's battle"), {"010057D006492000"})

    def test_a_game_own_name_beats_another_short_form(self):
        self.assertEqual(self.named("Hollow Knight boots"), {"0100A0000E2F0000"})
        self.assertEqual(self.named("Silksong boots"), {"010013C00E930000"})

    def test_accents_and_case(self):
        self.assertEqual(self.named("okami hd's ink"), {"0100276009872000"})

    def test_known_and_player_aliases(self):
        self.assertEqual(self.named("Bananza's water"), {"040074A01BF12000"})
        self.assertEqual(self.named("BotW's shrines"), {"01007EF00011E000"})
        self.assertEqual(self.named("the Hyrule remake's fields"), {"0400486024DEC000"})

    def test_word_boundaries(self):
        self.assertEqual(self.named("Bananzas"), set())

    def test_title_id_in_message(self):
        self.assertEqual(self.named("profile 040074A01BF12000 registers 1.1"), {"040074A01BF12000"})

    def test_two_regional_variants(self):
        self.assertEqual(self.named("NieR:Automata The End of YoRHa Edition renders"), {"010056B015FE8000", "0100B8E016F76000"})


class Paths(unittest.TestCase):
    def test_classify(self):
        self.assertEqual(classify("dm/games/0400486024DEC000/patches.py"), ("profile", "0400486024DEC000"))
        self.assertEqual(classify("dm/games/0400486024DEC000/README.md"), ("none", None))
        self.assertEqual(classify("dm/games/game.py"), ("shared", None))
        self.assertEqual(classify("dm/host/hle_fs.c"), ("shared", None))
        self.assertEqual(classify("scripts/build_ipa_from_nsp.py"), ("shared", None))
        self.assertEqual(classify("docs/frontends.md"), ("none", None))
        self.assertEqual(classify(".github/workflows/ci.yml"), ("none", None))
        self.assertEqual(classify("dm/tools/tests/test_romfs.py"), ("none", None))
        self.assertEqual(classify("README.md"), ("none", None))


class Analysis(unittest.TestCase):
    def test_kinds_of_commits(self):
        oot, botw = "0400486024DEC000", "01007EF00011E000"
        commits = [
            Commit("a" * 40, 1, "Ocarina of Time registers its update", ["dm/games/0400486024DEC000/game.tsv"]),
            Commit("b" * 40, 2, "A texture keeps its mark: Ocarina of Time's wall (PR #1)", ["dm/gfx/nvn/tex.c"]),
            Commit("c" * 40, 3, "Pool walks are cheaper; chain d403eb0683df", ["dm/gfx/nvn/pool.c", "dm/gfx/nvn/dmsh_chain.h"]),
            Commit("d" * 40, 4, "Ocarina of Time's note in the README", ["README.md", "docs/games.md"]),
            Commit("e" * 40, 5, "Breath of the Wild's profile names its fixes\n\nFront-ends: new: a NUP with no base game is accepted", ["dm/games/01007EF00011E000/patches.py"]),
        ]
        matcher = Matcher(NAMES)
        impacts = analyze(commits, [oot, botw], matcher)
        self.assertEqual([c.sha[0] for c in impacts[oot].profile], ["a"])
        self.assertEqual([c.sha[0] for c in impacts[oot].named], ["b"])
        self.assertEqual([c.sha[0] for c in impacts[oot].shared], ["c"])
        self.assertEqual([c.sha[0] for c in impacts[oot].chain], ["c"])
        self.assertTrue(impacts[oot].touched)
        self.assertEqual([c.sha[0] for c in impacts[botw].profile], ["e"])
        self.assertEqual([c.sha[0] for c in impacts[botw].shared], ["b", "c"])
        self.assertEqual(impacts[botw].notes, [("e" * 12, "new", "a NUP with no base game is accepted")])


if __name__ == "__main__":
    unittest.main()
