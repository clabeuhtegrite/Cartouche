"""Checks Cartouche's console on the Mac (builder/mac/Sources/CartoucheConsole),
which builds the iPhone's console screens for the Mac:

- its Shared folder holds links to the launcher's own files, by their own
  names, and nothing else, so that the Mac shows what the iPhone shows;
- the Builder's workflow builds the app again when one of those files or the
  launcher's words change (.github/workflows/builder.yml);
- none of those files uses, outside an iPhone-only part, a name of UIKit's
  or of the iPhone's SwiftUI that the Mac does not have, but those the
  console's shims give it (Mac/ConsoleShims.swift);
- the Mac's own words (builder/mac/console/strings.json) say what the
  launcher's say, with the same placeholders, and console/strings.py writes
  each language's table where the console reads it.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import importlib.util
import json
import os
import plistlib
import re
import tempfile
import unittest
from pathlib import Path

from test_launcher_strings import placeholders

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "launcher" / "Sources"
CONSOLE = ROOT / "builder" / "mac" / "Sources" / "CartoucheConsole"
SHARED = CONSOLE / "Shared"
WORKFLOW = ROOT / ".github" / "workflows" / "builder.yml"
CATALOG = LAUNCHER / "Cartouche.xcstrings"
MAC_STRINGS = ROOT / "builder" / "mac" / "console" / "strings.json"
WRITER = ROOT / "builder" / "mac" / "console" / "strings.py"
LANGUAGES = ("en", "fr")

# Names the Mac does not have: UIKit's, and the iPhone's alone in SwiftUI.
IPHONE_ONLY = re.compile(
    r"\bUI(?!Image\b|Application\.did(?:BecomeActive|EnterBackground)Notification\b)[A-Z]\w*"
    r"|\bnavigationBar(?:TitleDisplayMode|Drawer|Leading|Trailing|Hidden|Items)\b"
    r"|\bfor: \.navigationBar\b|\btopBar(?:Leading|Trailing)\b|\binsetGrouped\b"
    r"|\bfullScreenCover\b|\btextInputAutocapitalization\b|\bkeyboardType\b|\bstatusBarHidden\b"
    r"|\bnavigationTransition\b|\bmatchedTransitionSource\b|\bEditButton\b|\bPageTabViewStyle\b"
)
# The conditions of an iPhone-only part.
IPHONE_CONDITION = re.compile(r"^(?:os\(iOS\)|canImport\(UIKit\))(?:\s*\|\|\s*os\((?:iOS|visionOS|tvOS)\))*$")


def outside_iphone_parts(swift: str):
    """The lines the Mac compiles, as (number, line): those outside the
    `#if os(iOS)` or `#if canImport(UIKit)` parts, comments left out."""
    stack = []  # for each #if, whether its current branch is the iPhone's alone
    for number, line in enumerate(swift.splitlines(), start=1):
        directive = line.strip()
        if directive.startswith("#if "):
            stack.append(bool(IPHONE_CONDITION.match(directive[4:].strip())))
            continue
        if directive.startswith("#elseif ") or directive == "#else":
            # Another branch: the iPhone's alone only if it says so.
            stack[-1] = directive.startswith("#elseif ") and bool(IPHONE_CONDITION.match(directive[8:].strip()))
            continue
        if directive == "#endif":
            stack.pop()
            continue
        if any(stack):
            continue
        code = line.split("//", 1)[0]
        if code.strip():
            yield number, code


def load_writer():
    spec = importlib.util.spec_from_file_location("mac_console_strings", WRITER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MacConsoleSources(unittest.TestCase):
    def test_the_shared_files_are_links_to_the_launchers_own(self):
        names = sorted(path.name for path in SHARED.iterdir())
        self.assertGreater(len(names), 0)
        for name in names:
            with self.subTest(name=name):
                link = SHARED / name
                self.assertTrue(link.is_symlink(), f"{name} is a file of its own, not the launcher's")
                self.assertEqual(os.readlink(link), f"../../../../../launcher/Sources/{name}")
                self.assertTrue((LAUNCHER / name).is_file(), f"launcher/Sources/{name} is gone")

    def test_the_macs_own_files_are_beside_them(self):
        for path in (CONSOLE / "Mac").iterdir():
            with self.subTest(name=path.name):
                self.assertFalse(path.is_symlink())
                self.assertFalse((LAUNCHER / path.name).exists(), "a name of the launcher's own")

    def test_the_builders_workflow_runs_when_a_shared_file_changes(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        trigger = workflow.split("pull_request:", 1)[1].split("workflow_dispatch:", 1)[0]
        listed = set(re.findall(r'^\s*- "launcher/Sources/([^"*]+)"$', trigger, re.MULTILINE))
        linked = {path.name for path in SHARED.iterdir()}
        self.assertEqual(sorted(listed - linked - {CATALOG.name}), [], "files the console no longer links")
        self.assertEqual(sorted(linked - listed), [], "files the console links that the workflow misses")
        self.assertIn(CATALOG.name, listed)
        # A run that changes only them is built again, not taken as built.
        self.assertIn("$SHARED launcher/Sources/Cartouche.xcstrings", workflow)

    def test_the_shared_files_use_nothing_the_mac_lacks(self):
        for link in sorted(SHARED.iterdir()):
            with self.subTest(name=link.name):
                lines = list(outside_iphone_parts(link.read_text(encoding="utf-8")))
                found = [f"{link.name}:{number}: {code.strip()}"
                         for number, code in lines if IPHONE_ONLY.search(code)]
                self.assertEqual(found, [], "wrap them in #if os(iOS), or give the Mac its own in Mac/")
                imports = [code.strip() for _, code in lines if re.match(r"\s*(?:@\w+\s+)?import UIKit\b", code)]
                self.assertEqual(imports, [], "import UIKit only under #if canImport(UIKit)")

    def test_the_check_sees_an_unguarded_name(self):
        swift = "\n".join([
            "#if os(iOS)", "let a = UIDevice.current", "#else", "let b = 1", "#endif",
            "let c = UIImage()", "let d = UIScreen.main // the screen",
            "#if canImport(UIKit)", "import UIKit", "#endif",
        ])
        lines = list(outside_iphone_parts(swift))
        self.assertEqual([number for number, code in lines if IPHONE_ONLY.search(code)], [7])
        self.assertNotIn(2, [number for number, _ in lines])
        self.assertIn(4, [number for number, _ in lines])


class MacConsoleWords(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
        cls.mac = json.loads(MAC_STRINGS.read_text(encoding="utf-8"))

    def test_the_overrides_say_what_the_launchers_words_say(self):
        overrides = self.mac["overrides"]
        self.assertIn("sheet.onThisIPhone", overrides)
        for key, values in overrides.items():
            with self.subTest(key=key):
                self.assertIn(key, self.catalog, "a word the launcher does not have: put it in \"strings\"")
                english = self.catalog[key]["localizations"]["en"]["stringUnit"]["value"]
                self.assertEqual(sorted(values), list(LANGUAGES))
                for language in LANGUAGES:
                    self.assertTrue(values[language].strip())
                    self.assertEqual(placeholders(values[language]), placeholders(english), language)
                self.assertNotIn("iPhone", values["en"] + values["fr"])

    def test_the_macs_own_words_are_its_own(self):
        for key, values in self.mac.get("strings", {}).items():
            with self.subTest(key=key):
                self.assertNotIn(key, self.catalog, "a word of the launcher's: put it in \"overrides\"")
                self.assertEqual(sorted(values), list(LANGUAGES))
                self.assertTrue(all(values[language].strip() for language in LANGUAGES))
                self.assertEqual(placeholders(values["fr"]), placeholders(values["en"]))

    def test_the_file_is_written_as_the_test_reads_it(self):
        text = MAC_STRINGS.read_text(encoding="utf-8")
        self.assertEqual(text, json.dumps(self.mac, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    def test_each_language_is_written_where_the_console_reads_it(self):
        writer = load_writer()
        with tempfile.TemporaryDirectory() as folder:
            resources = Path(folder)
            written = writer.write(CATALOG, MAC_STRINGS, resources)
            paths = {language: [resources / f"{language}.lproj" / "Cartouche.strings",
                                resources / "Console" / language / "Cartouche.strings",
                                resources / "Console" / language / f"{language}.lproj" / "Cartouche.strings"]
                     for language in LANGUAGES}
            self.assertEqual(sorted(written), sorted(path for language in LANGUAGES for path in paths[language]))
            keys = set(self.catalog) | set(self.mac.get("strings", {}))
            for language in LANGUAGES:
                # Its folder holds that language alone, the same words at
                # its root and in its localization as in the app's.
                folder = sorted(path.name for path in (resources / "Console" / language).iterdir())
                self.assertEqual(folder, ["Cartouche.strings", f"{language}.lproj"])
                tables = [plistlib.loads(path.read_bytes()) for path in paths[language]]
                self.assertEqual(set(tables[0]), keys)
                self.assertTrue(all(table == tables[0] for table in tables), language)
            french = plistlib.loads((resources / "Console" / "fr" / "Cartouche.strings").read_bytes())
            english = plistlib.loads((resources / "en.lproj" / "Cartouche.strings").read_bytes())
            # The Mac's words over the launcher's; the others as the launcher has them.
            self.assertEqual(french["sheet.onThisIPhone"], self.mac["overrides"]["sheet.onThisIPhone"]["fr"])
            self.assertEqual(english["sheet.onThisIPhone"], "On this Mac")
            for key in sorted(set(self.catalog) - set(self.mac["overrides"]))[:50]:
                self.assertEqual(french[key], self.catalog[key]["localizations"]["fr"]["stringUnit"]["value"])


if __name__ == "__main__":
    unittest.main()
