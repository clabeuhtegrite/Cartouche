"""Checks Cartouche's App Intents on their way into the app, so that a
rename or a missing translation fails here, on Linux, rather than as a Siri
that knows no game on an iPhone (launcher/Sources/CartoucheShortcuts.swift,
docs/decisions.md, 90):

- app/scripts/app_intents.py merges the launcher's intents, which Xcode
  writes into LiveContainerSwiftUI.framework, into the app's own
  Metadata.appintents, beside the built-in SideStore's: the launcher's App
  Shortcuts first and its provider, SideStore's intents kept, no flexible
  matching assets trained on SideStore's name, and the French of every
  title and phrase beside LiveContainer's strings; it stops the build when
  the launcher's intents are missing, clash with SideStore's or lack their
  French;
- launcher/AppIntents/fr.json translates every title and phrase the Swift
  file declares, each phrase with Cartouche's name and its game;
- package.sh runs the merge once SideStore's intents are in place;
- nothing asks for Siri's entitlement, an extension or a key of the
  Info.plist: App Shortcuts need none.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import importlib.util
import json
import plistlib
import re
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "app" / "scripts" / "app_intents.py"
PACKAGE = ROOT / "app" / "scripts" / "package.sh"
FRENCH = ROOT / "launcher" / "AppIntents" / "fr.json"
SWIFT = ROOT / "launcher" / "Sources" / "CartoucheShortcuts.swift"

spec = importlib.util.spec_from_file_location("app_intents", SCRIPT)
app_intents = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app_intents)


def resource(key):
    """A LocalizedStringResource as Xcode writes it into the metadata."""
    return {"alternatives": [], "key": key}


def sidestore_metadata():
    """The app's intents as package.sh leaves them: the built-in
    SideStore's, renamed to SideStoreSupport's types, with its App
    Shortcuts and provider."""
    return {
        "actions": {
            "RefreshAllIntent": {
                "identifier": "RefreshAllIntent",
                "mangledTypeNameV2": "16SideStoreSupport20RefreshAllAppsIntentV",
                "openAppWhenRun": False,
                "parameters": [],
                "title": resource("Refresh All Apps"),
            },
            "InstallIPAIntent": {
                "identifier": "InstallIPAIntent",
                "mangledTypeNameV2": "9SideStore16InstallIPAIntentV",
                "parameters": [],
                "title": resource("Install IPA"),
            },
        },
        "assistantEntities": [],
        "assistantIntentNegativePhrases": [],
        "assistantIntents": [],
        "autoShortcutProviderMangledName": "9SideStore17ShortcutsProviderV",
        "autoShortcuts": [
            {
                "actionIdentifier": "RefreshAllIntent",
                "phraseTemplates": [{"alternatives": [], "key": "Refresh ${applicationName}"}],
                "shortTitle": resource("Refresh All Apps"),
                "systemImageName": "arrow.triangle.2.circlepath",
            },
        ],
        "entities": {},
        "enums": [],
        "generator": {"name": "xcode-tools", "version": "27B52"},
        "negativePhrases": [],
        "queries": {},
        "shortcutTileColor": 5,
        "version": 1,
    }


PHRASES = [
    "Play ${game} in ${applicationName}",
    "Play ${game} with ${applicationName}",
    "Start ${game} in ${applicationName}",
    "Launch ${game} in ${applicationName}",
    "Open ${game} in ${applicationName}",
    "Play a game in ${applicationName}",
]


def launcher_metadata():
    """The launcher's intents as Xcode writes them into
    LiveContainerSwiftUI.framework: Play a Game, its game and their query,
    and Siri's phrases."""
    return {
        "actions": {
            "CartouchePlayGameIntent": {
                "actionConfiguration": {
                    "actionSummary": {
                        "wrapper": {"otherParameterIdentifiers": [],
                                    "summaryString": {"formatString": "Play ${game}", "parameterIdentifiers": ["game"]}},
                    },
                },
                "descriptionMetadata": {
                    "descriptionText": resource("Opens Cartouche and starts one of your games, as Play does."),
                    "searchKeywords": [],
                },
                "fullyQualifiedTypeName": "LiveContainerSwiftUI.CartouchePlayGameIntent",
                "identifier": "CartouchePlayGameIntent",
                "mangledTypeNameV2": "20LiveContainerSwiftUI23CartouchePlayGameIntentV",
                "openAppWhenRun": True,
                "parameters": [
                    {"name": "game", "title": resource("Game"),
                     "typeSpecificMetadata": [], "valueType": {"entity": {"wrapper": {"typeIdentifier": "CartoucheGameEntity"}}}},
                ],
                "title": resource("Play a Game"),
            },
        },
        "assistantEntities": [],
        "assistantIntentNegativePhrases": [],
        "assistantIntents": [],
        "autoShortcutProviderMangledName": "20LiveContainerSwiftUI26CartoucheShortcutsProviderV",
        "autoShortcuts": [
            {
                "actionIdentifier": "CartouchePlayGameIntent",
                "phraseTemplates": [{"alternatives": [], "key": phrase} for phrase in PHRASES],
                "shortTitle": resource("Play a Game"),
                "systemImageName": "gamecontroller.fill",
            },
        ],
        "entities": {
            "CartoucheGameEntity": {
                "displayTypeName": resource("Game"),
                "mangledTypeNameV2": "20LiveContainerSwiftUI19CartoucheGameEntityV",
                "typeIdentifier": "CartoucheGameEntity",
            },
        },
        "enums": [],
        "generator": {"name": "xcode-tools", "version": "27B53"},
        "negativePhrases": [],
        "queries": {
            "CartoucheGameQuery": {"mangledTypeNameV2": "20LiveContainerSwiftUI18CartoucheGameQueryV"},
        },
        "shortcutTileColor": 9,
        "version": 1,
    }


class MergeTest(unittest.TestCase):
    """The merge, on an app as package.sh leaves it."""

    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.app = self.folder / "LiveContainer.app"
        self.write_metadata(self.app / "Metadata.appintents", sidestore_metadata())
        (self.app / "Metadata.appintents" / "nlu").mkdir()
        (self.app / "Metadata.appintents" / "nlu" / "nlu.lzfse").write_bytes(b"SideStore's")
        self.write_metadata(self.app / "Frameworks" / "LiveContainerSwiftUI.framework" / "Metadata.appintents",
                            launcher_metadata())
        (self.app / "fr.lproj").mkdir()
        (self.app / "fr.lproj" / "Localizable.strings").write_bytes(
            plistlib.dumps({"lc.common.ok": "OK", "lc.common.cancel": "Annuler"}, fmt=plistlib.FMT_BINARY))
        (self.app / "fr_CA.lproj").mkdir()
        (self.app / "fr_CA.lproj" / "InfoPlist.strings").write_bytes(plistlib.dumps({"CFBundleDisplayName": "Cartouche"}))
        (self.app / "en.lproj").mkdir()
        self.french = json.loads(FRENCH.read_text(encoding="utf-8"))

    @staticmethod
    def write_metadata(folder: Path, metadata: dict):
        folder.mkdir(parents=True)
        (folder / "extract.actionsdata").write_text(json.dumps(metadata), encoding="utf-8")
        (folder / "version.json").write_text('{"toolsVersion": "27B52", "version": "3.0"}', encoding="utf-8")

    def write_launcher(self, change):
        metadata = launcher_metadata()
        change(metadata)
        path = self.app / "Frameworks" / "LiveContainerSwiftUI.framework" / "Metadata.appintents" / "extract.actionsdata"
        path.write_text(json.dumps(metadata), encoding="utf-8")

    def merge(self):
        with redirect_stdout(StringIO()):
            return app_intents.merge(self.app, FRENCH)

    def merge_fails(self, *words):
        with self.assertRaises(app_intents.MergeError) as failure:
            self.merge()
        for word in words:
            self.assertIn(word, str(failure.exception))
        return str(failure.exception)

    def test_the_launchers_intents_join_sidestores_in_the_apps_metadata(self):
        self.merge()
        merged = json.loads((self.app / "Metadata.appintents" / "extract.actionsdata").read_text(encoding="utf-8"))
        self.assertEqual(set(merged["actions"]), {"RefreshAllIntent", "InstallIPAIntent", "CartouchePlayGameIntent"})
        # SideStore's, as package.sh renamed them, untouched.
        self.assertEqual(merged["actions"]["RefreshAllIntent"], sidestore_metadata()["actions"]["RefreshAllIntent"])
        self.assertEqual(merged["entities"], launcher_metadata()["entities"])
        self.assertEqual(merged["queries"], launcher_metadata()["queries"])
        # The launcher's App Shortcuts first, then SideStore's; its provider,
        # the one iOS asks for the games.
        self.assertEqual([shortcut["actionIdentifier"] for shortcut in merged["autoShortcuts"]],
                         ["CartouchePlayGameIntent", "RefreshAllIntent"])
        self.assertEqual(merged["autoShortcutProviderMangledName"], "20LiveContainerSwiftUI26CartoucheShortcutsProviderV")
        self.assertEqual(merged["shortcutTileColor"], 9)
        # The app's own tools and format.
        self.assertEqual(merged["generator"], sidestore_metadata()["generator"])
        self.assertEqual(merged["version"], 1)
        # No flexible matching trained on SideStore's name and phrases.
        self.assertFalse((self.app / "Metadata.appintents" / "nlu").exists())

    def test_the_french_goes_beside_livecontainers_strings(self):
        self.merge()
        with open(self.app / "fr.lproj" / "Localizable.strings", "rb") as file:
            self.assertTrue(file.read(6) == b"bplist", "it stays a binary table, as Xcode compiles it")
        strings = plistlib.loads((self.app / "fr.lproj" / "Localizable.strings").read_bytes())
        self.assertEqual(strings["lc.common.ok"], "OK", "LiveContainer's strings stay")
        self.assertEqual(strings["Play a Game"], "Lancer un jeu")
        self.assertEqual(strings["Game"], "Jeu")
        phrases = plistlib.loads((self.app / "fr.lproj" / "AppShortcuts.strings").read_bytes())
        self.assertEqual(phrases["Play ${game} in ${applicationName}"], "Lance ${game} dans ${applicationName}")
        # Canadian French has Siri's phrases, and LiveContainer's strings in
        # French's table, which one of its own would hide.
        self.assertTrue((self.app / "fr_CA.lproj" / "AppShortcuts.strings").exists())
        self.assertFalse((self.app / "fr_CA.lproj" / "Localizable.strings").exists())
        self.assertEqual(sorted(path.name for path in (self.app / "en.lproj").iterdir()), [],
                         "English is the intents' own")

    def test_it_stops_without_the_launchers_intents(self):
        shutil.rmtree(self.app / "Frameworks" / "LiveContainerSwiftUI.framework" / "Metadata.appintents")
        self.merge_fails("Xcode wrote no intents")

    def test_it_stops_without_play_a_game_its_game_or_its_phrases(self):
        self.write_launcher(lambda metadata: metadata["actions"].clear())
        self.merge_fails("CartouchePlayGameIntent")
        self.write_launcher(lambda metadata: metadata["entities"].clear())
        self.merge_fails("CartoucheGameEntity")
        self.write_launcher(lambda metadata: metadata.update(autoShortcuts=[]))
        self.merge_fails("no App Shortcuts")
        self.write_launcher(lambda metadata: metadata.pop("autoShortcutProviderMangledName"))
        self.merge_fails("CartoucheShortcutsProvider")

    def test_it_stops_on_an_intent_outside_the_framework(self):
        self.write_launcher(lambda metadata: metadata["actions"]["CartouchePlayGameIntent"].update(
            mangledTypeNameV2="9Cartouche23CartouchePlayGameIntentV"))
        self.merge_fails("not a type of LiveContainerSwiftUI")

    def test_it_stops_on_a_name_sidestore_has(self):
        def clash(metadata):
            metadata["actions"]["RefreshAllIntent"] = dict(metadata["actions"]["CartouchePlayGameIntent"])
        self.write_launcher(clash)
        self.merge_fails("RefreshAllIntent", "SideStore")

    def test_it_stops_on_what_it_does_not_know(self):
        self.write_launcher(lambda metadata: metadata.update(packages=[{"name": "Cartouche"}]))
        self.merge_fails("packages")

    def test_it_stops_on_a_title_or_a_phrase_without_french(self):
        def untranslated(metadata):
            metadata["actions"]["CartouchePlayGameIntent"]["title"] = resource("Start a Game")
            metadata["autoShortcuts"][0]["phraseTemplates"].append({"alternatives": [], "key": "Go ${game} in ${applicationName}"})
        self.write_launcher(untranslated)
        self.merge_fails("'Start a Game'", "'Go ${game} in ${applicationName}'")

    def test_it_stops_on_a_phrase_without_cartouches_name_or_its_game(self):
        self.french["phrases"]["Play ${game} in ${applicationName}"] = "Lance ${game}"
        with self.assertRaises(app_intents.MergeError) as failure:
            app_intents.check_french(launcher_metadata(), self.french)
        self.assertIn("${applicationName}", str(failure.exception))
        self.french = json.loads(FRENCH.read_text(encoding="utf-8"))
        self.french["phrases"]["Play ${game} in ${applicationName}"] = "Lance un jeu dans ${applicationName}"
        with self.assertRaises(app_intents.MergeError) as failure:
            app_intents.check_french(launcher_metadata(), self.french)
        self.assertIn("other parameters", str(failure.exception))

    def test_it_never_changes_a_string_of_livecontainers(self):
        (self.app / "fr.lproj" / "Localizable.strings").write_bytes(
            plistlib.dumps({"Game": "Partie"}, fmt=plistlib.FMT_BINARY))
        self.merge_fails("'Game'", "Partie")

    def test_the_command_says_why_it_stopped(self):
        shutil.rmtree(self.app / "Metadata.appintents")
        error = StringIO()
        with redirect_stderr(error):
            code = app_intents.main([str(self.app), "--french", str(FRENCH)])
        self.assertEqual(code, 1)
        self.assertIn("SideStore's intents", error.getvalue())


def swift_template(literal: str) -> str:
    """A phrase or a summary of the Swift file as the metadata keys it:
    \\(\\.$game) as ${game}, \\(.applicationName) as ${applicationName}."""
    literal = re.sub(r"\\\(\\\.\$(\w+)\)", r"${\1}", literal)
    return literal.replace("\\(.applicationName)", "${applicationName}")


class SourcesTest(unittest.TestCase):
    """The Swift file, its French, and the build."""

    @classmethod
    def setUpClass(cls):
        cls.swift = SWIFT.read_text(encoding="utf-8")
        cls.french = json.loads(FRENCH.read_text(encoding="utf-8"))

    def declared_phrases(self):
        block = re.search(r"phrases: \[(.*?)\]", self.swift, re.DOTALL)
        self.assertIsNotNone(block, "no phrases in CartoucheShortcuts.swift")
        return [swift_template(phrase) for phrase in re.findall(r'"((?:[^"\\]|\\.)*)"', block.group(1))]

    def declared_words(self):
        patterns = [
            r'static let title: LocalizedStringResource = "([^"]+)"',
            r'IntentDescription\("([^"]+)"\)',
            r'@Parameter\(title: "([^"]+)"',
            r'IntentDialog\("([^"]+)"\)',
            r'shortTitle: "([^"]+)"',
            r'TypeDisplayRepresentation = "([^"]+)"',
            r'Summary\("((?:[^"\\]|\\.)*)"\)',
        ]
        words = []
        for pattern in patterns:
            found = re.findall(pattern, self.swift)
            self.assertTrue(found, f"nothing in CartoucheShortcuts.swift for {pattern}")
            words += [swift_template(word) for word in found]
        return words

    def test_every_phrase_has_cartouches_name_and_its_french(self):
        phrases = self.declared_phrases()
        self.assertGreaterEqual(len(phrases), 2)
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertIn("${applicationName}", phrase, "Siri takes no phrase without the app's name")
                self.assertIn(phrase, self.french["phrases"])
        self.assertEqual(sorted(self.french["phrases"]), sorted(phrases), "French of phrases the file no longer has")
        # Siri can ask which game, from a phrase without one.
        self.assertTrue(any("${game}" not in phrase for phrase in phrases))

    def test_every_title_has_its_french(self):
        words = self.declared_words()
        for word in words:
            with self.subTest(word=word):
                self.assertIn(word, self.french["strings"])
        self.assertEqual(sorted(self.french["strings"]), sorted(set(words)), "French of words the file no longer has")

    def test_french_typography(self):
        for english, french in list(self.french["strings"].items()) + list(self.french["phrases"].items()):
            with self.subTest(english=english):
                self.assertTrue(french.strip())
                # A no-break space before the French ? ! : ;
                self.assertIsNone(re.search(r"[^  ][?!:;](?:\s|$)", french), french)

    def test_the_merge_of_the_real_french_passes(self):
        said = StringIO()
        with redirect_stdout(said):
            app_intents.check_french(launcher_metadata(), self.french)
        # The question Siri asks without a game, which the intent asks as
        # it runs.
        self.assertIn("'Which game?'", said.getvalue())

    def test_package_merges_them_once_sidestores_are_in_place(self):
        package = PACKAGE.read_text(encoding="utf-8")
        copy = package.index('cp -R "$SS/Metadata.appintents" "$APP/Metadata.appintents"')
        merge = package.index('python3 "$HERE/app_intents.py" "$APP" --french "$HERE/../../launcher/AppIntents/fr.json"')
        archive = package.index('zip -qr "$OUT_IPA" Payload')
        self.assertLess(copy, merge)
        self.assertLess(merge, archive)
        self.assertIn('HERE="$(cd "$(dirname "$0")" && pwd)"', package)

    def test_no_siri_entitlement_extension_nor_infoplist_key(self):
        # App Shortcuts need neither Siri's entitlement nor an Intents
        # extension, nor NSSiriUsageDescription: Cartouche asks for none.
        for path in [PACKAGE, ROOT / "app" / "scripts" / "build.sh", ROOT / "app" / "scripts" / "brand.py", SCRIPT]:
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path.name):
                self.assertNotIn("com.apple.developer.siri", text)
                self.assertNotIn("NSSiriUsageDescription", text)
                self.assertNotIn("IntentsExtension", text)
        for patch in sorted((ROOT / "app" / "patches").rglob("*.patch")):
            added = [line for line in patch.read_text(encoding="utf-8", errors="replace").splitlines() if line.startswith("+")]
            with self.subTest(patch=patch.name):
                self.assertFalse(any("com.apple.developer.siri" in line or "NSSiriUsageDescription" in line for line in added))
        self.assertNotIn("INPreferences", self.swift)
        self.assertIn("static let openAppWhenRun: Bool = true", self.swift, "the game starts in Cartouche, as Play does")


if __name__ == "__main__":
    unittest.main()
