"""Checks that what the built-in SideStore leaves Cartouche on how its
actions ended (app/patches/sidestore/0014) lines up with what Cartouche reads
of it (CartoucheSideStoreOutcome, launcher/Sources/CartoucheFailure.swift):

- both sides name the same keychain item and the same actions, and each
  action of SideStore leaves the one Cartouche waits for;
- Cartouche reads every field SideStore writes, each as a number, a name or
  a flag;
- the stages and families Cartouche tells causes from are ones SideStore
  leaves, and the cases it names are cases of SideStore's errors;
- the sentences Cartouche tells LiveContainer's bridge failures by, when
  SideStore left nothing, are still LiveContainer's.

Needs the LiveContainer and SideStore submodules, with SideSign and
minimuxer.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAILURE = ROOT / "launcher" / "Sources" / "CartoucheFailure.swift"
LAUNCHER = ROOT / "launcher" / "Sources"
PATCHES = ROOT / "app" / "patches" / "sidestore"
SIDESTORE = ROOT / "app" / "SideStore"
BRIDGE = ROOT / "app" / "LiveContainer" / "SideStoreSupport"

# The families whose errors Cartouche tells no cause from but their codes.
UNMAPPED_FAMILIES = {"cocoa", "posix", "system", "other"}


def patch_files() -> dict:
    """The lines patch 0014 adds, by the file they go in."""
    patches = sorted(PATCHES.glob("*-tell-cartouche-where-its-actions-stopped-and-why.patch"))
    if len(patches) != 1:
        raise AssertionError(f"expected one outcome patch in {PATCHES.relative_to(ROOT)}, found {len(patches)}")
    files, current = {}, None
    for line in patches[0].read_text(encoding="utf-8").splitlines():
        if line.startswith("+++ "):
            current = line[len("+++ b/"):].rstrip("\t")
            files[current] = []
        elif current and line.startswith("+"):
            files[current].append(line[1:])
    return {name: "\n".join(lines) for name, lines in files.items()}


def block(text: str, opening: str, what: str) -> str:
    """The body of the braces that follow OPENING, which may open on the next
    line (SideStore's style) or on the same one (Cartouche's)."""
    start = text.find(opening)
    if start < 0:
        raise AssertionError(f"{what} not found")
    first = text.index("{", start + len(opening))
    depth = 0
    for index in range(first, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[first + 1:index]
    raise AssertionError(f"{what} does not close")


def cases(body: str) -> set:
    """The cases an enumeration's body declares, without what they carry."""
    names = set()
    for declaration in re.findall(r"^\s*case ([^\n]+)", body, re.M):
        for part in re.split(r",\s*(?![^()]*\))", declaration):
            name = re.match(r"(\w+)", part.strip())
            if name:
                names.add(name.group(1))
    return names


def error_cases(path: Path, name: str) -> set:
    if not path.exists():
        raise AssertionError(f"{path.relative_to(ROOT)} is missing: run git submodule update --init --recursive")
    text = path.read_text(encoding="utf-8")
    return cases(block(text, f"enum {name}:", f"{name} in {path.relative_to(ROOT)}").split("var ")[0])


def ours() -> str:
    return block(FAILURE.read_text(encoding="utf-8"), "struct CartoucheSideStoreOutcome:", "CartoucheSideStoreOutcome")


def branches(cause: str) -> dict:
    """The kinds each family's branch of CartoucheSideStoreOutcome.cause
    names, by family."""
    found = {}
    switch = block(cause, "switch family", "the switch on the family")
    for match in re.finditer(r'^        case ((?:"\w+"(?:, )?)+):\n(.*?)(?=^        (?:case|default)\b)', switch, re.M | re.S):
        families = re.findall(r'"(\w+)"', match.group(1))
        # The kinds its own cases name, not the family or stage it compares.
        kinds = set()
        for listed in re.findall(r'case ((?:"\w+",?\s*)+):', match.group(2)):
            kinds |= set(re.findall(r'"(\w+)"', listed))
        for family in families:
            found[family] = kinds
    return found


class SideStoreOutcomeTest(unittest.TestCase):
    def setUp(self):
        self.files = patch_files()
        self.outcome = self.files["SideStore/Intents/CartoucheOutcome.swift"]
        self.ours = ours()
        self.cause = block(self.ours, "var cause: CartoucheFailure.Cause", "CartoucheSideStoreOutcome.cause")

    def test_both_sides_name_the_same_keychain_item(self):
        account = re.compile(r'static let account = "([^"]+)"')
        self.assertEqual(account.search(self.outcome).group(1), account.search(self.ours).group(1))
        # SideStore's keychain service is Cartouche's bundle identifier, as
        # for the sign-in's items (app/tests/test_sign_in.py).
        self.assertIn("Bundle.Info.appbundleIdentifier", self.outcome)

    def test_each_action_leaves_the_one_cartouche_waits_for(self):
        theirs = cases(block(self.outcome, "enum Action: String", "SideStore's actions"))
        mine = cases(block(self.ours, "enum Action: String", "Cartouche's actions"))
        self.assertEqual(theirs, {"signIn", "refresh", "update"})
        self.assertEqual(theirs, mine)
        left = {
            "SideStore/Intents/CartoucheSignInIntent.swift": "signIn",
            "AltStore/Intents/App Intents/RefreshAllAppsIntent.swift": "refresh",
            "SideStore/Intents/UpdateCartoucheIntent.swift": "update",
        }
        for name, action in left.items():
            self.assertEqual(re.findall(r"CartoucheOutcome\(action: \.(\w+)\)", self.files[name]), [action], name)
        waited = {"CartoucheAccount.swift": "signIn", "CartoucheRenewal.swift": "refresh", "CartoucheUpdates.swift": "update"}
        for name, action in waited.items():
            text = (LAUNCHER / name).read_text(encoding="utf-8")
            self.assertEqual(re.findall(r"CartoucheSideStoreOutcome\(data: \$0, expecting: \.(\w+)", text), [action], name)

    def test_cartouche_reads_every_field_sidestore_writes(self):
        save = block(self.outcome, "func save(", "CartoucheOutcome.save")
        written = set(re.findall(r'^\s*"(\w+)": ', save, re.M)) | set(re.findall(r'outcome\["(\w+)"\]', save))
        noted = set(re.findall(r'\.note\("(\w+)"', self.files["SideStore/Intents/CartoucheSignInIntent.swift"]))
        self.assertIn("codeAsked", noted)
        keys = cases(block(self.ours, "enum Key: String, CodingKey", "the keys Cartouche reads"))
        self.assertEqual(written | noted, keys)
        # Each one read as a number, a name or a flag, apart from the four
        # every outcome has.
        typed = set()
        for listed in re.findall(r"for key in \[Key\.(\w+((?:, \.\w+)*))\]", self.ours):
            typed |= {name.strip(" .") for name in listed[0].split(",")}
        self.assertEqual(typed, keys - {"version", "action", "ok", "date"})
        version = int(re.search(r"static let version = (\d+)", self.outcome).group(1))
        self.assertIn("(1...99).contains(written.version)", self.ours)
        self.assertTrue(1 <= version <= 99)

    def test_the_stages_cartouche_tells_causes_from_are_sidestores(self):
        stages = cases(block(self.files["SideStore/Intents/CartoucheSignInIntent.swift"],
                             "enum Stage: String, CaseIterable", "the sign-in's stages"))
        named = set(re.findall(r'stage == "(\w+)"', self.cause))
        self.assertEqual(named, {"database", "certificate"})
        self.assertLessEqual(named, stages)
        # A refresh or an update leaves its last operation as its stage:
        # the trail AsyncOperation keeps.
        self.assertIn("CartoucheOutcome.reached(", self.files["SideStore/Core/Operations/AsyncOperation.swift"])

    def test_every_family_sidestore_leaves_has_its_causes(self):
        kind = block(self.outcome, "static func kind(of error: Error)", "CartoucheOutcome.kind(of:)")
        families = set(re.findall(r'family = "(\w+)"', kind)) | set(re.findall(r'return \("(\w+)", ', kind))
        self.assertEqual(families - UNMAPPED_FAMILIES, set(branches(self.cause)))

    def test_the_cases_cartouche_names_are_sidestores(self):
        found = branches(self.cause)
        sidesign = SIDESTORE / "Dependencies" / "SideSign" / "Sources"
        portal = error_cases(sidesign / "Models" / "Errors.swift", "DeveloperPortalError")
        signer = error_cases(sidesign / "Models" / "Errors.swift", "SignerError")
        operation = error_cases(SIDESTORE / "SideStore" / "Core" / "Operations" / "Errors" / "OperationError.swift",
                                "OperationError")
        minimuxer = error_cases(SIDESTORE / "Dependencies" / "minimuxer" / "Sources" / "MinimuxerError.swift",
                                "MinimuxerError")
        mine = block(self.files["SideStore/Intents/CartoucheSignInIntent.swift"], "enum Kind: String", "the sign-in's kinds")
        self.assertLessEqual(found["portal"], portal)
        self.assertLessEqual(found["signer"], signer)
        self.assertLessEqual(found["operation"], operation | minimuxer)
        self.assertEqual(found["operation"], found["minimuxer"])
        self.assertLessEqual(found["cartouche"], cases(mine))

    def test_the_bridges_sentences_are_still_livecontainers(self):
        listed = re.search(r"static let bridgeSentences[^=]*= \[(.*?)\n    \]", FAILURE.read_text(encoding="utf-8"), re.S)
        self.assertIsNotNone(listed, "the bridge's sentences not found")
        sentences = re.findall(r'^\s*\("([^"]+)", \.(\w+)\),$', listed.group(1), re.M)
        self.assertEqual(len(sentences), 7)
        bridge = "\n".join(path.read_text(encoding="utf-8") for path in sorted(BRIDGE.glob("*.swift")))
        for sentence, _ in sentences:
            self.assertIn('"' + sentence, bridge, sentence)


if __name__ == "__main__":
    unittest.main()
