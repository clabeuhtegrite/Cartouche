"""Checks that the play time counter (launcher/Guest) still runs in every game
and writes what the launcher reads:

- app/scripts/prepare.sh copies launcher/Guest into LiveContainer's Tweaks
  folder, which Xcode builds whole into LiveContainerShared, the framework
  that Cartouche's own executable opens first thing and LiveProcess links:
  a game runs in one or the other;
- the counter and the launcher (launcher/Sources/CartouchePlayTime.swift)
  name the same file, keys and version;
- the counter does not link UIKit, which LiveContainerShared loads before.

Needs the LiveContainer submodule.
Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COUNTER = ROOT / "launcher" / "Guest" / "CartouchePlayTimeCounter.m"
READER = ROOT / "launcher" / "Sources" / "CartouchePlayTime.swift"
PREPARE = ROOT / "app" / "scripts" / "prepare.sh"
LC = ROOT / "app" / "LiveContainer"
PROJECT = LC / "LiveContainer.xcodeproj" / "project.pbxproj"


def read(path: Path) -> str:
    if not path.exists():
        raise AssertionError(f"{path.relative_to(ROOT)} is missing: run git submodule update --init --recursive")
    return path.read_text(encoding="utf-8")


def project_objects() -> dict[str, str]:
    """The objects of LiveContainer's Xcode project, by identifier: the text
    between `<ID> /* name */ = {` and its `};`."""
    objects = {}
    lines = read(PROJECT).split("\n")
    start = re.compile(r"^\t\t([0-9A-F]{24}) (?:/\*.*?\*/ )?= \{(.*)$")
    index = 0
    while index < len(lines):
        match = start.match(lines[index])
        index += 1
        if not match:
            continue
        identifier, rest = match.groups()
        if rest.endswith("};"):
            objects[identifier] = rest[:-2]
            continue
        body = [rest]
        while index < len(lines) and lines[index] != "\t\t};":
            body.append(lines[index])
            index += 1
        objects[identifier] = "\n".join(body)
    return objects


def listed(body: str, key: str) -> list[str]:
    """The identifiers of the list KEY = ( ... ); in an object."""
    match = re.search(rf"\b{key} = \((.*?)\);", body, re.S)
    return re.findall(r"\b([0-9A-F]{24})\b", match.group(1)) if match else []


def target(objects: dict[str, str], name: str) -> str:
    for body in objects.values():
        if "isa = PBXNativeTarget;" in body and re.search(rf"\bname = {re.escape(name)};", body):
            return body
    raise AssertionError(f"LiveContainer's project has no target {name}")


class PlayTimeTest(unittest.TestCase):
    def test_prepare_puts_the_counter_in_the_tweaks_folder(self):
        match = re.search(r'rsync -a --delete "\$ROOT/launcher/Guest/" "\$SRC/LiveContainer/LiveContainer/Tweaks/([^"/]+)/"',
                          read(PREPARE))
        self.assertIsNotNone(match, "prepare.sh no longer copies launcher/Guest into LiveContainer/Tweaks")
        # The folder holds LiveContainerShared's own tweaks.
        self.assertTrue((LC / "LiveContainer" / "Tweaks" / "Dead10ccFix.m").exists())

    def test_the_tweaks_folder_builds_whole_into_livecontainershared(self):
        objects = project_objects()
        shared = target(objects, "LiveContainerShared")
        groups = [objects[i] for i in listed(shared, "fileSystemSynchronizedGroups")]
        tweaks = [g for g in groups if "isa = PBXFileSystemSynchronizedRootGroup;" in g and "path = Tweaks;" in g]
        self.assertEqual(len(tweaks), 1, "LiveContainerShared no longer builds the Tweaks folder as a synchronized folder")
        # Only the files an exception names stay out of the build.
        for exception in listed(tweaks[0], "exceptions"):
            left_out = re.search(r"membershipExceptions = \((.*?)\);", objects[exception], re.S)
            names = re.findall(r"[^\s,]+", left_out.group(1)) if left_out else []
            self.assertFalse([n for n in names if not n.endswith(".h")], f"the Tweaks folder leaves out {names}")

    def test_cartouche_and_liveprocess_load_livecontainershared(self):
        objects = project_objects()

        def files(target_name: str, isa: str) -> list[str]:
            """The paths of the files of TARGET_NAME's build phases of ISA."""
            phases = [objects[i] for i in listed(target(objects, target_name), "buildPhases")]
            paths = []
            for phase in phases:
                if f"isa = {isa};" not in phase:
                    continue
                for build_file in listed(phase, "files"):
                    reference = re.search(r"fileRef = ([0-9A-F]{24})", objects[build_file])
                    path = reference and re.search(r"\bpath = ([^;]+);", objects[reference.group(1)])
                    if path:
                        paths.append(path.group(1))
            return paths

        # Cartouche's own executable, where a game runs in place of
        # Cartouche, embeds the framework and opens it first thing.
        self.assertIn("LiveContainerShared.framework", files("LiveContainer", "PBXCopyFilesBuildPhase"))
        main = read(LC / "LiveContainer" / "main.c")
        self.assertIn('dlopen("@executable_path/Frameworks/LiveContainerShared.framework/LiveContainerShared"', main)
        self.assertIn('dlsym(lcShared, "LiveContainerMain")', main)
        # LiveProcess, where a game runs beside Cartouche, links it.
        self.assertIn("LiveContainerShared.framework", files("LiveProcess", "PBXFrameworksBuildPhase"))
        self.assertIn("LiveContainerMain(argc, argv)", read(LC / "LiveProcess" / "main.m"))

    def test_the_counter_writes_what_the_launcher_reads(self):
        counter, reader = read(COUNTER), read(READER)
        written = re.search(r'CartouchePlayTimeFile = @"([^"]+)"', counter).group(1)
        self.assertEqual(re.search(r'static let file = "([^"]+)"', reader).group(1), written)
        self.assertEqual(written, "Library/Cartouche/PlayTime.plist")

        keys = set(re.findall(r'total\[@"(\w+)"\] =', counter))
        self.assertTrue({"seconds", "sessions", "firstPlayed", "lastPlayed", "lastSession", "version"} <= keys, keys)
        read_keys = set(re.findall(r'plist\["(\w+)"\]', reader))
        self.assertTrue(read_keys, "CartouchePlayTime.swift reads no key")
        self.assertEqual(read_keys - keys, set(), "keys the launcher reads that the counter never writes")

        self.assertEqual(re.search(r'total\[@"version"\] = @(\d+);', counter).group(1),
                         re.search(r"static let version = (\d+)", reader).group(1))

    def test_the_counter_does_not_link_uikit(self):
        counter = read(COUNTER)
        self.assertIsNone(re.search(r"@import UIKit|#(?:import|include) <UIKit", counter))
        # UIKit's class is found at run time, never referenced at link time.
        self.assertIsNone(re.search(r"\[UIApplication ", counter))


if __name__ == "__main__":
    unittest.main()
