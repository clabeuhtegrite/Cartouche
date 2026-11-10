"""The one-command install, install.sh, against what the builder checks on
the Mac (toolchain.py): it installs what the Mac tools would ask Homebrew
for, readies Xcode as they check it, and the app it makes opens the window
with the same Python as Cartouche Builder.command."""

import re
import unittest
from pathlib import Path

from cartouche_builder import toolchain

BUILDER = Path(__file__).resolve().parent.parent
INSTALL = (BUILDER / "install.sh").read_text(encoding="utf-8")
TOOLCHAIN = (BUILDER / "cartouche_builder" / "toolchain.py").read_text(encoding="utf-8")
COMMAND = (BUILDER / "Cartouche Builder.command").read_text(encoding="utf-8")


class InstallScript(unittest.TestCase):
    def formulae(self) -> set[str]:
        found = re.search(r"^FORMULAE=\(([^)]*)\)$", INSTALL, re.MULTILINE)
        self.assertIsNotNone(found, "FORMULAE=(...) in install.sh")
        return set(found.group(1).split())

    def test_it_installs_the_tools_the_doctor_asks_homebrew_for(self):
        # The doctor's ("formula", "command") pairs for Homebrew's tools.
        brew = re.search(r'for name, command in \(((?:\("[^"]+", "[^"]+"\)(?:, )?)+)\)', TOOLCHAIN)
        self.assertIsNotNone(brew, "the doctor's Homebrew tools in toolchain.py")
        tools = set(re.findall(r'\("([^"]+)", "[^"]+"\)', brew.group(1)))
        self.assertTrue(tools)
        python = re.search(r'"brew install (python@([0-9.]+))"', TOOLCHAIN)
        self.assertIsNotNone(python, "the doctor's Python in toolchain.py")
        # The window needs Tk, which Homebrew's Python has apart.
        self.assertLessEqual(tools | {python.group(1), f"python-tk@{python.group(2)}"}, self.formulae())
        self.assertIn(f"PYTHON=/opt/homebrew/bin/python{python.group(2)}\n", INSTALL)

    def test_it_installs_no_dotnet_which_the_nxnative_it_downloads_does_not_need(self):
        # Before the first clone, the doctor asks for none: the newest
        # nxnative, the one the builder clones, builds without it.
        self.assertFalse(toolchain.needs_dotnet(None))
        self.assertFalse(re.search(r"brew install --cask|dotnet-sdk", INSTALL), "install.sh installs the .NET SDK")

    def test_it_readies_xcode_as_the_doctor_checks_it(self):
        for check, fix in (
            ('["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]', "xcodebuild -downloadPlatform iOS"),
            ('["xcrun", "-sdk", "iphoneos", "metal", "--version"]', "xcodebuild -downloadComponent MetalToolchain"),
        ):
            with self.subTest(fix=fix):
                self.assertIn(check, TOOLCHAIN)
                self.assertIn(fix, TOOLCHAIN)
                self.assertIn(" ".join(re.findall(r'"([^"]+)"', check)), INSTALL)
                self.assertIn(fix, INSTALL)
        xcode = re.search(r"/Applications/Xcode-([0-9.]+)\.app", TOOLCHAIN)
        self.assertIsNotNone(xcode)
        self.assertIn(f"XCODE_VERSION={xcode.group(1)}\n", INSTALL)

    def test_it_asks_for_the_macos_the_doctor_asks_for(self):
        macos = re.search(r'Check\("macos", parts >= \((\d+), (\d+)\)', TOOLCHAIN)
        self.assertIsNotNone(macos)
        major, minor = macos.groups()
        self.assertIn(f'[ "$major" -lt {major} ] || {{ [ "$major" -eq {major} ] && [ "$minor" -lt {minor} ]; }}', INSTALL)
        self.assertIn(f"<string>{major}.{minor}</string>", INSTALL)

    def test_the_app_finds_python_as_the_command_does(self):
        candidates = re.search(r"^for candidate in (python3[^;]*); do$", COMMAND, re.MULTILINE)
        self.assertIsNotNone(candidates)
        launcher = INSTALL.split("<<'LAUNCHER'\n", 1)[1].split("\nLAUNCHER\n", 1)[0]
        self.assertIn(f"for candidate in {candidates.group(1)}; do", launcher)
        self.assertIn("import sys, tkinter; sys.exit(sys.version_info < (3, 12))", launcher)
        self.assertIn('exec "$python" -m cartouche_builder "$@"', launcher)

    def test_it_never_fetches_anything_but_homebrew_and_this_repository(self):
        urls = set(re.findall(r"https://[^\s\"')]+", INSTALL))
        allowed = (
            "https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/main/builder/install.sh",
            "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh",
            "https://github.com/$REPOSITORY/archive/refs/heads/$REF.tar.gz",
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd",
        )
        self.assertLessEqual(urls, set(allowed))
        self.assertIn('REPOSITORY="clabeuhtegrite/Cartouche"', INSTALL)


if __name__ == "__main__":
    unittest.main()
