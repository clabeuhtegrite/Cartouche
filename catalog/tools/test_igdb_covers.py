"""igdb_covers.py with IGDB's answers stood in for: no network, no key."""

import io
import json
import unittest

import igdb_covers

PLATFORMS = [{"id": 130, "name": "Nintendo Switch"}, {"id": 508, "name": "Nintendo Switch 2"}]

CATALOG = {"games": [
    {"titleId": "0400C3F00006E000", "name": "Mario Kart World", "platform": "switch2"},
    {"titleId": "0100F2C0115B6000", "name": "The Legend of Zelda: Tears of the Kingdom", "platform": "switch"},
    {"titleId": "01002B30028F6000", "name": "Celeste", "platform": "switch"},
    {"titleId": "0100152000022000", "name": "Mario Kart 8 Deluxe", "platform": "switch"},
]}

SEARCHES = {
    "Mario Kart World": [
        {"id": 1, "name": "Mario Kart World", "platforms": [508], "cover": {"image_id": "mkw"},
         "artworks": [{"image_id": "mkw-art"}]},
        {"id": 2, "name": "Mario Kart 8", "platforms": [41], "cover": {"image_id": "mk8"}},
    ],
    "The Legend of Zelda: Tears of the Kingdom": [
        {"id": 3, "name": "The Legend of Zelda: Tears of the Kingdom - Nintendo Switch 2 Edition",
         "platforms": [508], "cover": {"image_id": "totk2"}},
        {"id": 4, "name": "The Legend of Zelda: Tears of the Kingdom", "platforms": [130],
         "cover": {"image_id": "totk"}},
    ],
    # Only an entry without a cover, and one that is not the game.
    "Celeste": [
        {"id": 5, "name": "Celeste", "platforms": [130]},
        {"id": 6, "name": "Celeste Classic 2", "platforms": [130], "cover": {"image_id": "c2"}},
    ],
    # Known by another name only.
    "Mario Kart 8 Deluxe": [
        {"id": 7, "name": "Mario Kart 8: Deluxe Edition", "platforms": [130], "cover": {"image_id": "mk8d"},
         "alternative_names": [{"name": "Mario Kart 8 Deluxe"}]},
    ],
}


def stand_in(asked):
    def ask(endpoint, query):
        asked.append((endpoint, query))
        if endpoint == "platforms":
            return PLATFORMS
        name = json.loads(query.split(";")[0].removeprefix("search "))
        return SEARCHES.get(name, [])
    return ask


class IgdbCoversTest(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(igdb_covers.plain("Pokémon™ Legends: Z-A – Nintendo Switch 2 Edition"),
                         "pokemon legends z a")
        self.assertEqual(igdb_covers.plain("Ratchet & Clank"), "ratchet and clank")

    def test_covers(self):
        asked = []
        log = io.StringIO()
        records = igdb_covers.covers(CATALOG, stand_in(asked), log=log)
        self.assertEqual(records, [
            {"titleId": "0100152000022000", "igdb": 7, "name": "Mario Kart 8: Deluxe Edition", "cover": "mk8d"},
            {"titleId": "0100F2C0115B6000", "igdb": 4, "name": "The Legend of Zelda: Tears of the Kingdom",
             "cover": "totk"},
            {"titleId": "0400C3F00006E000", "igdb": 1, "name": "Mario Kart World", "cover": "mkw",
             "artwork": "mkw-art"},
        ])
        # The search is limited to the two Switch platforms, by ID.
        self.assertIn("where platforms = (130,508)", asked[1][1])
        self.assertIn("no cover: Celeste (01002B30028F6000)", log.getvalue())
        self.assertIn("close: Mario Kart 8 Deluxe -> Mario Kart 8: Deluxe Edition", log.getvalue())
        self.assertIn("== 3 of 4 games have a cover", log.getvalue())

    def test_search_again_with_words(self):
        # IGDB finds the game only once the colon is a space.
        game = {"titleId": "010056B015FE8000", "name": "NieR:Automata The End of YoRHa Edition", "platform": "switch"}
        entry = {"id": 8, "name": "NieR:Automata - The End of YoRHa Edition", "platforms": [130],
                 "cover": {"image_id": "nier"}}
        asked = []
        searches = {"NieR Automata The End of YoRHa Edition": [entry]}

        def ask(endpoint, query):
            asked.append(query)
            if endpoint == "platforms":
                return PLATFORMS
            return searches.get(json.loads(query.split(";")[0].removeprefix("search ")), [])

        records = igdb_covers.covers({"games": [game]}, ask, log=io.StringIO())
        self.assertEqual(records[0]["igdb"], 8)
        self.assertEqual([q.split(";")[0] for q in asked if q.startswith("search")],
                         ['search "NieR:Automata The End of YoRHa Edition"',
                          'search "NieR Automata The End of YoRHa Edition"'])
        self.assertEqual(igdb_covers.words("Mario + Rabbids® Sparks of Hope"), "Mario Rabbids Sparks of Hope")
        # A name that is already words is searched once.
        asked.clear()
        igdb_covers.covers({"games": [CATALOG["games"][2]]}, stand_in(asked), log=io.StringIO())
        self.assertEqual(len([q for _, q in asked if q.startswith("search")]), 1)

    def test_switch_2_edition(self):
        # Both entries have the game's name once plain: the game's own
        # platform decides.
        found = SEARCHES["The Legend of Zelda: Tears of the Kingdom"]
        self.assertEqual(igdb_covers.choose("The Legend of Zelda: Tears of the Kingdom", 508, found)["id"], 3)
        self.assertEqual(igdb_covers.choose("The Legend of Zelda: Tears of the Kingdom", 130, found)["id"], 4)

    def test_pinned(self):
        asked = []
        igdb_covers.MATCHES["01002B30028F6000"] = 6
        try:
            def ask(endpoint, query):
                asked.append(query)
                if endpoint == "platforms":
                    return PLATFORMS
                if "where id = 6;" in query:
                    return [SEARCHES["Celeste"][1]]
                return []
            records = igdb_covers.covers({"games": [CATALOG["games"][2]]}, ask, log=io.StringIO())
        finally:
            del igdb_covers.MATCHES["01002B30028F6000"]
        self.assertEqual(records[0]["igdb"], 6)
        self.assertFalse(any(query.startswith("search") for query in asked))

    def test_document_has_no_address(self):
        text = igdb_covers.document([{"titleId": "0400C3F00006E000", "igdb": 1, "name": "Mario Kart World",
                                      "cover": "mkw"}])
        self.assertNotIn("://", text)
        self.assertEqual(json.loads(text)["source"], "IGDB")


if __name__ == "__main__":
    unittest.main()
