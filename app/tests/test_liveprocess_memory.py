"""Checks that the built-in SideStore signs LiveProcess, the extension that
Cartouche runs a game in behind its console, with Increased Memory Limit,
as the Cartouche Installer does (docs/decisions.md, 88):

- whenever SideStore signs Cartouche again, as its updates do, Cartouche's
  extensions keep the app's own provisioning profile, whose App ID has the
  capability (app/patches/sidestore/0021): the step that decides it runs
  before the profiles are fetched and the app is signed, neither the
  player's setting nor another step undoes it, and the install records it
  for the renewals that follow;
- the extension asks for the entitlement, which SideSign's signature keeps
  only when the profile has it, and SideSign signs an extension with the
  first profile it is given when none is the extension's own;
- the request that turns the capability on for a free team's App ID
  (app/patches/sidestore/0002) goes out with the value SideStore's
  additional entitlements give the key, which is never true: up to
  Cartouche 0.12.0 it waited for true, and never went out.

An update by the built-in SideStore signed LiveProcess with an App ID of
its own, without the capability: a game behind the console had 3,376 MiB
instead of 6,144 on an iPhone with 12 GB, from the first update until the
Installer installed Cartouche again.

SideStore's sources are read as app/scripts/prepare.sh leaves them, every
patch applied (test_sidestore_outcome.patched). Needs the LiveContainer and
SideStore submodules, with SideSign.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import ast
import plistlib
import re
import unittest

from test_sidestore_outcome import PATCHES, ROOT, SIDESTORE, hunks, patched

OPERATIONS = "SideStore/Core/Operations"
REMOVE_EXTENSIONS = f"{OPERATIONS}/PipelineOperations/RemoveAppExtensionsOperation.swift"
FETCH_PROFILES = f"{OPERATIONS}/PipelineOperations/FetchProvisioningProfilesOperation.swift"
INSTALL = f"{OPERATIONS}/PipelineOperations/InstallAppOperation.swift"
RUNNER = f"{OPERATIONS}/PipelineRunner.swift"
STEPS = f"{OPERATIONS}/OperationStepDefinition.swift"
ADDITIONAL = f"{OPERATIONS}/OperationEntitlements.swift"
ALTSTORE_APP = "Shared/Extensions/ALTApplication+AltStoreApp.swift"
BUNDLE = "Shared/Extensions/Bundle+AltStore.swift"
SIGNER = "Dependencies/SideSign/Sources/CodeSigning/CodeSignerAPI.swift"
LIVEPROCESS_ENTITLEMENTS = ROOT / "app" / "LiveContainer" / "LiveProcess" / "LiveProcess.entitlements"
HOOKS = ROOT / "app" / "LiveContainer" / "SideStoreSupport" / "SideStoreHooks.m"
BRAND = ROOT / "app" / "scripts" / "brand.py"
IML = "com.apple.developer.kernel.increased-memory-limit"


def body_of(source: str, opening: str, what: str) -> str:
    """The text between the brace that ends OPENING, a regular expression,
    and the one that closes it."""
    match = re.search(opening, source)
    if not match:
        raise AssertionError(f"{what} not found")
    start = source.index("{", match.end() - 1)
    depth = 0
    for index in range(start, len(source)):
        depth += {"{": 1, "}": -1}.get(source[index], 0)
        if depth == 0:
            return source[start + 1:index]
    raise AssertionError(f"{what} does not end")


def steps(source: str, name: str) -> list:
    """The steps of the list NAME of PipelineStepDefinition, in order."""
    found = re.search(rf"static let {name}: \[PipelineExecutionStep\] = \[(.*?)\n    \]", source, re.S)
    if not found:
        raise AssertionError(f"the {name} steps not found")
    return re.findall(r"PipelineExecutionStep\(\.(\w+),", found.group(1))


def swift_sources() -> dict:
    """SideStore's own Swift sources, every patch applied, by their path,
    with the files the patches add."""
    touched = {path for patch in sorted(PATCHES.glob("*.patch")) for path in hunks(patch)}
    paths = {str(path.relative_to(SIDESTORE)) for path in SIDESTORE.rglob("*.swift")
             if "Dependencies" not in path.relative_to(SIDESTORE).parts}
    paths |= {path for path in touched if path.endswith(".swift") and not path.startswith("Dependencies/")}
    return {path: patched(path) if path in touched else (SIDESTORE / path).read_text(encoding="utf-8")
            for path in sorted(paths)}


# What the guard of enableIncreasedMemoryLimitIfRequested reads, as Swift does.
MISSING = object()   # the key is not in the entitlements
OTHER = object()     # a value of another type than Bool, as SideStore's own


def as_bool(value):
    """Swift's `value as? Bool`."""
    return value if isinstance(value, bool) else None


def top_level(text: str, separator: str) -> list:
    """TEXT split at SEPARATOR outside brackets and parentheses."""
    parts, depth, current = [], 0, ""
    for character in text:
        depth += {"(": 1, "[": 1, ")": -1, "]": -1}.get(character, 0)
        if character == separator and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += character
    return parts + [current]


ALLOWED_NODES = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp, ast.Not, ast.Compare, ast.Eq,
                 ast.NotEq, ast.Is, ast.IsNot, ast.Name, ast.Load, ast.Constant, ast.Call)


def guard_lets_through(guard: str, value) -> bool:
    """Whether GUARD, the conditions of a Swift guard on the entitlement,
    holds when the entitlements give the key VALUE: True, False, OTHER or
    MISSING. Reads the conditions SideStore's code writes: optional
    bindings of the value, `as? Bool`, comparisons with true, false and
    nil, &&, || and !; any other raises, for this test to learn it."""
    read = re.compile(r"entitlements\[(?:ALTEntitlement)?\.increasedMemoryLimit(?:\.rawValue)?\]")
    names = {"VALUE": None if value is MISSING else value, "as_bool": as_bool}
    for condition in (part.strip() for part in top_level(guard, ",")):
        binding = re.fullmatch(r"let (\w+) = (.+)", condition, re.S)
        if binding:
            if not read.fullmatch(binding.group(2).strip()):
                raise AssertionError(f"the guard binds something else: {condition}")
            if value is MISSING:
                return False
            names[binding.group(1)] = value
            continue
        expression = read.sub("VALUE", condition)
        expression = re.sub(r"\(([^()]+?) as\? Bool\)", r"as_bool(\1)", expression)
        expression = re.sub(r"\b(\w+) as\? Bool\b", r"as_bool(\1)", expression)
        expression = re.sub(r"\btrue\b", "True", expression)
        expression = re.sub(r"\bfalse\b", "False", expression)
        expression = re.sub(r"\bnil\b", "None", expression)
        expression = expression.replace("&&", " and ").replace("||", " or ")
        expression = re.sub(r"!(?!=)", " not ", expression)
        tree = ast.parse(" ".join(expression.split()), mode="eval")
        for node in ast.walk(tree):
            if not isinstance(node, ALLOWED_NODES):
                raise AssertionError(f"the guard reads in a way this test cannot: {condition}")
            if isinstance(node, ast.Name) and node.id not in names:
                raise AssertionError(f"the guard reads {node.id}, which this test does not know: {condition}")
            if isinstance(node, ast.Call) and not (isinstance(node.func, ast.Name) and node.func.id == "as_bool"):
                raise AssertionError(f"the guard calls something this test does not know: {condition}")
        if not eval(compile(tree, "guard", "eval"), {"__builtins__": {}}, names):
            return False
    return True


class CartoucheExtensionsProfileTest(unittest.TestCase):
    """app/patches/sidestore/0021."""

    def test_sidestore_keeps_cartouches_profile_for_its_extensions(self):
        execute = body_of(patched(REMOVE_EXTENSIONS), r"override func execute\(parentProgress: Progress\?\) async throws -> ALTApplication \{",
                          "RemoveAppExtensionsOperation.execute")
        cartouche = re.search(r"if targetAppBundle\.isAltStoreApp \{(.*?)\n        \}", execute, re.S)
        self.assertIsNotNone(cartouche, "RemoveAppExtensionsOperation does not single out the app SideStore is built into")
        self.assertIn("self.context.useMainProfile = true", cartouche.group(1))
        self.assertIn("return targetAppBundle", cartouche.group(1),
                      "the app SideStore is built into would still go through the choice of extensions")
        # Before the player's setting, the alert that asks, or the removal of
        # an extension can apply.
        for later in ("customizeAppExtensions", "selectAppExtensionsToRemove", "removeExtensions(", "processExtensionsInfo("):
            self.assertIn(later, execute)
            self.assertLess(cartouche.start(), execute.index(later), f"{later} comes before Cartouche's own profile is chosen")
        self.assertGreater(cartouche.start(), execute.index("guard let targetAppBundle = context.targetAppBundle"))

    def test_isaltstoreapp_is_cartouche_in_the_built_in_sidestore(self):
        # The app SideStore is built into: the running bundle, or one whose
        # bundle ID contains Bundle.Info.appbundleIdentifier, which
        # LiveContainer's hook gives LiveContainer's own, which brand.py
        # turns into Cartouche's.
        app = patched(ALTSTORE_APP)
        self.assertIn("return self.bundleIdentifier.isAltStoreAppID", app)
        self.assertRegex(patched(BUNDLE), r"let altstoreID = Bundle\.Info\.appbundleIdentifier")
        hook = body_of(HOOKS.read_text(encoding="utf-8"), r"\+ \(NSString\*\)hook_appbundleIdentifier \{",
                       "LiveContainer's hook of appbundleIdentifier")
        returned = re.search(r'return @"([^"]+)";', hook)
        self.assertIsNotNone(returned)
        pattern = re.search(r'BUNDLE_ID_PATTERN = re\.compile\(r"(.+?)"\)', BRAND.read_text(encoding="utf-8"))
        self.assertIsNotNone(pattern, "brand.py's BUNDLE_ID_PATTERN not found")
        self.assertRegex(returned.group(1), pattern.group(1), "brand.py would not give the hook Cartouche's bundle ID")

    def test_the_choice_holds_until_the_app_is_signed(self):
        definition = patched(STEPS)
        # Updates and reinstalls take the install's steps.
        self.assertRegex(definition, r"case \.install, \.update, \.reinstall:\s*return install")
        for name in ("install", "resign"):
            order = steps(definition, name)
            for later in ("fetchProvisioningProfiles", "prepareAppExtensionBundleIDs", "resignApp", "installApp"):
                self.assertLess(order.index("removeAppExtensions"), order.index(later), f"{name}: {later}")
        # Only the runner, before any step, and that step set the choice.
        setters = {path for path, text in swift_sources().items()
                   if re.search(r"\bcontext\.useMainProfile\s*=(?!=)", text)}
        self.assertEqual(setters, {RUNNER, REMOVE_EXTENSIONS})

    def test_the_install_records_it_for_the_renewals(self):
        self.assertIn("installedApp.useMainProfile = context.useMainProfile", patched(INSTALL))
        # A renewal signs nothing again: it renews the profiles the app was
        # signed with, as its InstalledApp records them.
        self.assertNotIn("removeAppExtensions", steps(patched(STEPS), "refresh"))
        self.assertIn("context.useMainProfile = app.useMainProfile", patched(RUNNER))


class LiveProcessEntitlementTest(unittest.TestCase):
    def test_liveprocess_asks_for_the_entitlement(self):
        entitlements = plistlib.loads(LIVEPROCESS_ENTITLEMENTS.read_bytes())
        self.assertIs(entitlements.get(IML), True)

    def test_sidesign_signs_an_extension_with_the_first_profile(self):
        signer = patched(SIGNER)
        chooser = body_of(signer, r"func profile\(for app: AppBundle\) -> ProvisioningProfile\? \{", "SideSign's profile(for:)")
        self.assertIn("return profiles.first", chooser)
        # The signature keeps the profile's entitlements that the app asks
        # for, and the identifiers.
        self.assertIn("var filteredEntitlements = matchedProfile.entitlements", signer)
        self.assertIn("filteredEntitlements.removeValue(forKey: key)", signer)


class IncreasedMemoryLimitRequestTest(unittest.TestCase):
    """app/patches/sidestore/0002."""

    def request(self) -> str:
        return body_of(patched(FETCH_PROFILES), r"func enableIncreasedMemoryLimitIfRequested\(.*?\) async \{",
                       "enableIncreasedMemoryLimitIfRequested")

    def value_seen(self, request: str):
        """The value the request reads for the key: SideStore's additional
        entitlements', which it sets over the app's own, or else the app's
        own, true for Cartouche and LiveProcess."""
        additional = re.search(r"static let defaultAdditionalEntitlements: \[ALTEntitlement: any Sendable\] = \[(.*?)\n    \]",
                               patched(ADDITIONAL), re.S)
        self.assertIsNotNone(additional, "SideStore's additional entitlements not found")
        given = re.search(r"\.increasedMemoryLimit\s*:\s*([^,\n]+)", additional.group(1))
        merged = re.search(r"for \(key, value\) in self\.context\.additionalEntitlements \{\s*entitlements\[key\] = value",
                           request)
        if not (given and merged):
            return True
        return {"true": True, "false": False}.get(given.group(1).strip(), OTHER)

    def guard(self, request: str) -> str:
        guards = [match.group(1) for match in re.finditer(r"guard (.*?) else \{ return \}", request, re.S)
                  if "increasedMemoryLimit" in match.group(1)]
        self.assertEqual(len(guards), 1, "expected one guard on the entitlement")
        return guards[0]

    def test_the_request_goes_out_for_the_value_sidestore_gives(self):
        request = self.request()
        value = self.value_seen(request)
        self.assertIn(value, (OTHER, True), "SideStore's additional entitlements turn the capability off")
        self.assertTrue(guard_lets_through(self.guard(request), value),
                        "the request for Increased Memory Limit never goes out with SideStore's additional entitlements")

    def test_the_request_reads_the_value_as_updatefeatures_does(self):
        guard = self.guard(self.request())
        self.assertTrue(guard_lets_through(guard, True))
        self.assertTrue(guard_lets_through(guard, OTHER))
        self.assertFalse(guard_lets_through(guard, False))
        self.assertFalse(guard_lets_through(guard, MISSING))

    def test_the_request_goes_before_the_profile_is_downloaded(self):
        provision = body_of(patched(FETCH_PROFILES), r"private func provisionAndFetchProfile\(for targetAppBundle: ALTApplication,",
                            "provisionAndFetchProfile")
        call = provision.index("await self.enableIncreasedMemoryLimitIfRequested(for: groupAppID")
        self.assertLess(call, provision.index("downloadProvisioningProfile(for: groupAppID"))
        self.assertIn("guard team.type == .free else { return }", self.request())


if __name__ == "__main__":
    unittest.main()
