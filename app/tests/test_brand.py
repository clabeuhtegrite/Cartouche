"""Tests for app/scripts/brand.py.

Run from the repository root: python3 -m unittest discover -s app/tests -v
CI also runs app/scripts/prepare.sh, which brands the real pinned sources.
"""

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "app" / "scripts"))

import brand  # noqa: E402

IDENTITY = brand.Identity(
    bundle_id="io.github.example.cartouche",
    display_name="Cartouche",
    url_scheme="cartouche",
    sidestore_source_url="https://example.com/source.json",
)

# One line of upstream code per rule, as the rule finds it.
SAMPLES = {
    "bundle identifier": 'return @"com.kdt.livecontainer";',
    "bundle identifiers of extra copies": 'infoDict[@"CFBundleIdentifier"] = [NSString stringWithFormat:@"com.kdt.%@", name];',
    "names of extra copies": 'InstallAnotherLCButton(lcName: "LiveContainer2", delegate: self)',
    "URL scheme": 'url = @"livecontainer://livecontainer-launch?bundle-name=%@";',
    "built-in SideStore URL scheme": 'return @"sidestore://install?url=%@";',
    "SideStore source": 'url = @"https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps_ss_lc.json";',
    "store bundle identifier": '@objc dynamic static let storeAppBundleIdentifier = "com.SideStore.SideStore"',
    "backup return URL": 'guard let altstoreOpenURL = URL(string: "sidestore://")',
    "database migration notification": 'static let willMigrateDatabase = CFNotificationName("com.rileytestut.AltStore.WillMigrateDatabase" as CFString)',
}


def write_fixture(root: Path, rules) -> None:
    """A tree where every file a rule expects holds that rule's sample."""
    lines: dict[str, list[str]] = {}
    for rule in rules:
        for relative in rule.expect:
            lines.setdefault(relative, []).append(SAMPLES[rule.what])
    for relative, content in lines.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(content) + "\n")


def rename(pattern, text: str, replacement: str) -> str:
    return pattern.sub(replacement, text)


class SchemePatternTest(unittest.TestCase):
    def test_livecontainer_schemes_are_renamed_where_they_are_schemes(self):
        pattern = brand.scheme_pattern("livecontainer", numbered=True)
        cases = {
            '"livecontainer"': '"cartouche"',
            '@"livecontainer"': '@"cartouche"',
            '"livecontainer1"': '"cartouche1"',
            '"livecontainer3"': '"cartouche3"',
            "<string>livecontainer2</string>": "<string>cartouche2</string>",
            '@"livecontainer://livecontainer-launch?x"': '@"cartouche://livecontainer-launch?x"',
            "callback_template=livecontainer%3A%2F%2Fcertificate": "callback_template=cartouche%3A%2F%2Fcertificate",
        }
        for before, after in cases.items():
            with self.subTest(before=before):
                self.assertEqual(rename(pattern, before, "cartouche"), after)

    def test_hosts_web_addresses_and_names_are_left_alone(self):
        pattern = brand.scheme_pattern("livecontainer", numbered=True)
        for text in (
            '"livecontainer-launch"',
            "https://livecontainer.github.io/docs/faq",
            '"com.livecontainer.download.1"',
            "// livecontainer2.liveprocess, such that",
            '"\\(runningLC)://livecontainer-launch?bundle-name="',
            '"LiveContainer"',
            '"livecontainer4"',
        ):
            with self.subTest(text=text):
                self.assertIsNone(pattern.search(text))

    def test_sidestore_scheme(self):
        pattern = brand.scheme_pattern("sidestore")
        self.assertEqual(rename(pattern, '"sidestore"', "sidestore.cartouche"), '"sidestore.cartouche"')
        self.assertEqual(
            rename(pattern, '"sidestore://enable-jit?bundle-id=x"', "sidestore.cartouche"),
            '"sidestore.cartouche://enable-jit?bundle-id=x"',
        )
        self.assertEqual(rename(pattern, "<string>sidestore</string>", "s.c"), "<string>s.c</string>")
        for text in ('"sidestore-com.example.app"', 'Text("SideStore")', '"sidestore.cartouche"', '"sidestore.cartouche://"'):
            with self.subTest(text=text):
                self.assertIsNone(pattern.search(text))


class IdentityTest(unittest.TestCase):
    def write_config(self, **changes) -> Path:
        settings = {
            "CARTOUCHE_BUNDLE_ID": "io.github.example.cartouche",
            "CARTOUCHE_DISPLAY_NAME": "Cartouche",
            "CARTOUCHE_URL_SCHEME": "cartouche",
            "CARTOUCHE_SIDESTORE_SOURCE_URL": "https://example.com/source.json",
        }
        settings.update(changes)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "config.env"
        path.write_text("# comment\n\n" + "".join(f"{k}={v}\n" for k, v in settings.items() if v is not None))
        return path

    def test_the_repository_config(self):
        identity = brand.load_identity(ROOT / "app" / "config.env")
        self.assertEqual(identity.bundle_id, "io.github.clabeuhtegrite.cartouche")
        self.assertEqual(identity.store_url_scheme, "sidestore.cartouche")
        self.assertEqual(identity.bundle_id_parent, "io.github.clabeuhtegrite")
        self.assertTrue(identity.sidestore_source_url.startswith("https://"))

    def test_upstream_names_are_refused(self):
        for key, value in (
            ("CARTOUCHE_BUNDLE_ID", "com.kdt.livecontainer"),
            ("CARTOUCHE_BUNDLE_ID", "com.SideStore.SideStore"),
            ("CARTOUCHE_BUNDLE_ID", "cartouche"),
            ("CARTOUCHE_URL_SCHEME", "livecontainer"),
            ("CARTOUCHE_URL_SCHEME", "sidestore"),
            ("CARTOUCHE_URL_SCHEME", "Cartouche"),
            ("CARTOUCHE_SIDESTORE_SOURCE_URL", "http://example.com/source.json"),
            ("CARTOUCHE_DISPLAY_NAME", "Car<touche>"),
            ("CARTOUCHE_URL_SCHEME", None),
        ):
            with self.subTest(key=key, value=value):
                with self.assertRaises(brand.BrandError):
                    brand.load_identity(self.write_config(**{key: value}))


class BrandTreeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        write_fixture(self.root, brand.LIVECONTAINER_RULES)

    def brand(self):
        return brand.brand(self.root, brand.LIVECONTAINER_RULES, brand.LIVECONTAINER_LEFTOVERS, IDENTITY)

    def test_every_name_is_renamed(self):
        summary = self.brand()
        self.assertEqual(len(summary), len(brand.LIVECONTAINER_RULES))

        hooks = (self.root / "SideStoreSupport/SideStoreHooks.m").read_text()
        self.assertIn('@"io.github.example.cartouche"', hooks)
        self.assertIn('@"https://example.com/source.json"', hooks)

        utils = (self.root / "LiveContainerSwiftUI/Utilities/LCUtils.m").read_text()
        self.assertIn('@"io.github.example.%@"', utils)
        self.assertIn('@"sidestore.cartouche://install?url=%@"', utils)

        guest_hooks = (self.root / "TweakLoader/UIKit+GuestHooks.m").read_text()
        self.assertIn('@"cartouche://livecontainer-launch?bundle-name=%@"', guest_hooks)

        multi = (self.root / "LiveContainerSwiftUI/Views/Settings/LCMultiLCManagementView.swift").read_text()
        self.assertIn('lcName: "Cartouche2"', multi)

        self.assertEqual(brand.find_leftovers(self.root, brand.LIVECONTAINER_LEFTOVERS), [])
        self.assertEqual((self.root / brand.MARKER).read_text().strip(), IDENTITY.bundle_id)

    def test_a_name_that_moved_upstream_stops_the_build(self):
        path = self.root / "LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift"
        path.write_text("// the keychain service moved elsewhere\n")
        with self.assertRaisesRegex(
            brand.BrandError, "bundle identifier: not found in LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift"
        ):
            self.brand()

    def test_the_names_iloader_gives_stay_livecontainer_sidestores(self):
        # iloader gives any app with a com.SideStore.SideStore framework this
        # app group and these keychain groups, and nothing else.
        kept = {
            "LiveContainer/Tweaks/SecItem.m": (
                'accessGroup = [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared", groupId];\n'
                'accessGroup = [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared.%d", groupId, keychainGroupId];\n'
            ),
            "entitlements.xml": "<string>$(AppIdentifierPrefix)com.kdt.livecontainer.shared.127</string>\n",
            "LiveContainer/LCSharedUtils.m": 'NSString *base = @"group.com.SideStore.SideStore";\n',
            "SideStoreSupport/Kept.m": 'return @"group.com.SideStore.SideStore";\n',
        }
        for relative, text in kept.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a") as file:
                file.write(text)
        self.brand()
        for relative, text in kept.items():
            with self.subTest(relative=relative):
                self.assertTrue((self.root / relative).read_text().endswith(text))

    def test_an_old_name_no_rule_renames_stops_the_build(self):
        (self.root / "LiveContainer/New.m").write_text('// new upstream code\nNSString *g = @"group.com.rileytestut.AltStore";\n')
        with self.assertRaisesRegex(brand.BrandError, r"LiveContainer/New\.m:2: the AltStore app group"):
            self.brand()

    def test_a_name_in_a_new_file_is_renamed_too(self):
        (self.root / "LiveContainer/New.swift").write_text('let s = "livecontainer"\n')
        self.brand()
        self.assertEqual((self.root / "LiveContainer/New.swift").read_text(), 'let s = "cartouche"\n')

    def test_release_tooling_and_other_files_are_left_alone(self):
        (self.root / ".github").mkdir()
        (self.root / ".github/build_github.sh").write_text("sidestore-com.kdt.livecontainer\n")
        (self.root / "README.md").write_text("com.kdt.livecontainer\n")
        (self.root / "Binary.plist").write_bytes(b"bplist00\xff\xfe com.kdt.livecontainer")
        self.brand()
        self.assertEqual((self.root / ".github/build_github.sh").read_text(), "sidestore-com.kdt.livecontainer\n")
        self.assertEqual((self.root / "README.md").read_text(), "com.kdt.livecontainer\n")
        self.assertEqual((self.root / "Binary.plist").read_bytes(), b"bplist00\xff\xfe com.kdt.livecontainer")

    def test_a_second_run_only_checks(self):
        self.brand()
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(self.brand(), ["already branded"])
        after = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_a_tree_branded_for_another_identity_is_refused(self):
        self.brand()
        (self.root / brand.MARKER).write_text("com.example.other\n")
        with self.assertRaisesRegex(brand.BrandError, "already branded for com.example.other"):
            self.brand()


class SideStoreTreeTest(unittest.TestCase):
    def test_store_identity_and_backup_return_url(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_fixture(root, brand.SIDESTORE_RULES)
            helpers_path = root / "Shared/Extensions/Bundle+AltStore.swift"
            # SideStore's own identifier stays: the widget finds the app group with it.
            own = '@objc dynamic static let appbundleIdentifier = "com.SideStore.SideStore"\n'
            helpers_path.write_text(helpers_path.read_text() + own)
            brand.brand(root, brand.SIDESTORE_RULES, brand.SIDESTORE_LEFTOVERS, IDENTITY)
            helpers = helpers_path.read_text()
            self.assertIn('storeAppBundleIdentifier = "io.github.example.cartouche"', helpers)
            self.assertIn(own, helpers)
            backup = (root / "SideStore/Core/Operations/PipelineOperations/PerformBackupRestoreOperation.swift").read_text()
            self.assertIn('URL(string: "sidestore.cartouche://")', backup)
            database = (root / "AltStore/Core/Model/DatabaseManager/DatabaseManager.swift").read_text()
            self.assertIn('"io.github.example.cartouche.WillMigrateDatabase"', database)


class MainTest(unittest.TestCase):
    def test_main_reports_errors_without_a_traceback(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "missing"
            code = brand.main([
                "--config", str(ROOT / "app" / "config.env"),
                "--livecontainer", str(missing),
                "--sidestore", str(missing),
            ])
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
