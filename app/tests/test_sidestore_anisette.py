"""Checks that the built-in SideStore signs in as the Cartouche Installer
does (app/patches/sidestore/0015), which Apple accepts, since it refuses a
sign-in whose identity is not the kind of machine that made its anisette
(-80045):

- SideStore says it is the Mac the Installer says it is
  (installer/src-tauri/src/account.rs), and names the isideload the
  Installer builds with (installer/src-tauri/Cargo.toml), so that a new
  isideload has these checked again;
- it takes its anisette from the Installer's Mac servers only, in the
  Installer's order (installer/src/pages/Settings.tsx);
- a sign-in gets its anisette that way, from /v3/get_headers alone, with
  the identifier in base64;
- what Cartouche's measurements call those servers is a name Cartouche
  reads (launcher/Sources/CartoucheFailure.swift).

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCHES = ROOT / "app" / "patches" / "sidestore"
ACCOUNT = ROOT / "installer" / "src-tauri" / "src" / "account.rs"
CARGO = ROOT / "installer" / "src-tauri" / "Cargo.toml"
SETTINGS = ROOT / "installer" / "src" / "pages" / "Settings.tsx"
FAILURE = ROOT / "launcher" / "Sources" / "CartoucheFailure.swift"


def patch_files() -> dict:
    """The lines patch 0015 adds, by the file they go in."""
    patches = sorted(PATCHES.glob("*-sign-in-as-the-cartouche-installer-does.patch"))
    if len(patches) != 1:
        raise AssertionError(f"expected one sign-in patch in {PATCHES.relative_to(ROOT)}, found {len(patches)}")
    files, current = {}, None
    for line in patches[0].read_text(encoding="utf-8").splitlines():
        if line.startswith("+++ "):
            current = line[len("+++ b/"):].rstrip("\t")
            files[current] = []
        elif current and line.startswith("+"):
            files[current].append(line[1:])
    return {name: "\n".join(lines) for name, lines in files.items()}


def added(files: dict, path: str) -> str:
    if path not in files:
        raise AssertionError(f"patch 0015 adds nothing to {path}")
    return files[path]


def cartouche_constants(files: dict) -> str:
    """The body of AppConstants.Anisette.Cartouche."""
    text = added(files, "SideStore/AppConstants.swift")
    start = text.find("enum Cartouche {")
    if start < 0:
        raise AssertionError("AppConstants.Anisette.Cartouche not found")
    depth = 0
    for index in range(text.index("{", start), len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index]
    raise AssertionError("AppConstants.Anisette.Cartouche does not close")


def constant(body: str, name: str) -> str:
    found = re.search(rf'static let {name}\s*=\s*"([^"]+)"', body)
    if not found:
        raise AssertionError(f"AppConstants.Anisette.Cartouche.{name} not found")
    return found.group(1)


def installer_identity() -> tuple:
    """The client info and user agent the Installer signs in with."""
    text = ACCOUNT.read_text(encoding="utf-8")
    client_info = re.search(r'client_info:\s*"([^"]+)"', text)
    user_agent = re.search(r'user_agent:\s*"([^"]+)"', text)
    if not client_info or not user_agent:
        raise AssertionError(f"{ACCOUNT.relative_to(ROOT)} no longer says which Mac it is")
    return client_info.group(1), user_agent.group(1)


def installer_servers() -> list:
    """The anisette servers the Installer offers, in its order: those of
    its list that are not commented out."""
    text = SETTINGS.read_text(encoding="utf-8")
    found = re.search(r"^let anisetteServers = \[\n(.*?)^\];", text, re.M | re.S)
    if not found:
        raise AssertionError(f"{SETTINGS.relative_to(ROOT)} no longer lists its anisette servers")
    servers = []
    for line in found.group(1).splitlines():
        entry = re.match(r'\s*\[\s*"([^"]+)"', line)
        if entry:
            servers.append(entry.group(1))
    return servers


class SideStoreAnisetteTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = patch_files()
        cls.constants = cartouche_constants(cls.files)

    def test_sidestore_says_it_is_the_installers_mac(self):
        client_info, user_agent = installer_identity()
        self.assertEqual(constant(self.constants, "clientInfo"), client_info)
        self.assertEqual(constant(self.constants, "userAgent"), user_agent)
        self.assertRegex(constant(self.constants, "xcodeVersion"), r"^\d+\.\d+(\.\d+)? \(\w+\)$")

    def test_the_isideload_it_names_is_the_installers(self):
        cargo = re.search(r'^isideload\s*=\s*\{[^}]*version\s*=\s*"([^"]+)"', CARGO.read_text(encoding="utf-8"), re.M)
        self.assertIsNotNone(cargo, f"{CARGO.relative_to(ROOT)} no longer names isideload")
        named = set(re.findall(r"isideload (\d+\.\d+\.\d+)", added(self.files, "SideStore/AppConstants.swift")))
        self.assertEqual(named, {cargo.group(1)},
                         "the Installer builds with another isideload: check how it signs in again, then name it")

    def test_its_servers_are_the_installers_in_its_order(self):
        servers = re.search(r"static let servers\s*=\s*\[(.*?)\]", self.constants, re.S)
        self.assertIsNotNone(servers, "AppConstants.Anisette.Cartouche.servers not found")
        listed = re.findall(r'"([^"]+)"', servers.group(1))
        expected = [server if server.startswith("http") else f"https://{server}" for server in installer_servers()]
        self.assertTrue(expected, "the Installer offers no anisette server")
        self.assertEqual(listed, expected)

    def test_a_sign_in_gets_its_anisette_as_the_installer_does(self):
        operation = added(self.files, "SideStore/Core/Operations/StandaloneOperations/SignInOperation.swift")
        self.assertIn("signingIn: true", operation)
        self.assertIn("CartoucheAnisette.signInFailed(with: error)", operation)
        self.assertIn("AnisetteRefresh.$fetch.withValue", operation)

        provider = added(self.files, "SideStore/Core/Anisette/AnisetteProvider.swift")
        self.assertIn("CartoucheAnisette.fetch(signingIn: signingIn)", provider)

        anisette = added(self.files, "SideStore/Core/Anisette/CartoucheAnisette.swift")
        self.assertIn("AppConstants.Anisette.Cartouche.servers", anisette)
        self.assertIn("fetchStrictRemoteAnisetteData(", anisette)
        self.assertIn("Keychain.shared.cartoucheAnisette", anisette)

        manager = added(self.files, "Dependencies/SideSign/Sources/Anisette/AnisetteDataManager.swift")
        self.assertRegex(manager, r"RemoteAnisetteDataProvider\(serverURL: server, identifierEncoding: \.base64, allowsV1Fallback: false\)")

    def test_every_sign_in_request_says_it_is_the_anisettes_machine(self):
        authentication = added(self.files, "Dependencies/SideSign/Sources/DeveloperPortal/Authentication.swift")
        # The sign-in's own requests, then those of the verification code.
        self.assertIn('"User-Agent": anisetteData.userAgent', authentication)
        self.assertIn('"User-Agent": a.userAgent', authentication)

    def test_cartouche_reads_what_its_measurements_call_those_servers(self):
        outcome = added(self.files, "SideStore/Intents/CartoucheOutcome.swift")
        self.assertIn('AppConstants.Anisette.Cartouche.servers', outcome)
        self.assertIn('return "anisette"', outcome)
        self.assertRegex(FAILURE.read_text(encoding="utf-8"), r'host == "anisette"')


if __name__ == "__main__":
    unittest.main()
