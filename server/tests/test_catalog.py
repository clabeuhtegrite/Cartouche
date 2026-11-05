"""The catalog files in the repository: valid against their schemas, and
acceptable to the publish guard (no URLs, no download fields)."""

import json
import unittest
from pathlib import Path

from cartouche_server import APP_BUNDLE_ID, guard

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "catalog"

try:
    import jsonschema
except ImportError:  # the dev extra installs it; CI always has it
    jsonschema = None


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


class CatalogTest(unittest.TestCase):
    def game_files(self):
        files = sorted((CATALOG / "games").glob("*.json"))
        self.assertTrue(files, "the catalog has no game sheets")
        return files

    @unittest.skipIf(jsonschema is None, "jsonschema is not installed")
    def test_game_sheets_match_the_schema(self):
        schema = load(CATALOG / "schema" / "game.schema.json")
        jsonschema.Draft202012Validator.check_schema(schema)
        for path in self.game_files():
            with self.subTest(path=path.name):
                sheet = load(path)
                jsonschema.validate(sheet, schema)
                self.assertEqual(path.stem, sheet["titleId"], "a sheet is named after its title ID")

    @unittest.skipIf(jsonschema is None, "jsonschema is not installed")
    def test_devices_match_the_schema(self):
        schema = load(CATALOG / "schema" / "devices.schema.json")
        jsonschema.Draft202012Validator.check_schema(schema)
        jsonschema.validate(load(CATALOG / "devices.json"), schema)

    def test_publish_guard_accepts_the_catalog(self):
        for path in [*self.game_files(), CATALOG / "devices.json"]:
            with self.subTest(path=path.name):
                guard.check_file(path, "catalog")

    def test_bundle_id_matches_the_app_build(self):
        settings = dict(
            line.split("=", 1)
            for line in (ROOT / "app" / "config.env").read_text().splitlines()
            if line and not line.startswith("#")
        )
        self.assertEqual(settings["CARTOUCHE_BUNDLE_ID"], APP_BUNDLE_ID)


if __name__ == "__main__":
    unittest.main()
