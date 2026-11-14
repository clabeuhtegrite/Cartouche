"""Checks that the built-in SideStore signs LiveProcess, the extension that
Cartouche runs a game in behind its console, with Increased Memory Limit,
as the Cartouche Installer does (docs/decisions.md, 105).

An update:
- keeps Cartouche's extensions, LiveProcess and the widget, signed with the
  app's own provisioning profile, whose App ID has the capability
  (app/patches/sidestore/0021): the step that decides it runs before the
  profiles are fetched and the app is signed, neither the player's setting
  nor another step undoes it, and the steps that follow give every bundle
  that profile and each extension a bundle ID of its own under the app's;
- signs as before, with an App ID for each extension, when those steps
  could not, or when the last update that tried it never ended
  (CartoucheExtensionsProfile, tried in Swift);
- records the choice only once the new version runs, for the renewals.

A renewal signs nothing again: it renews the profiles the app was signed
with, as its InstalledApp records them, Cartouche's own alone after an
update that signed its extensions with it.

Both ask Apple to turn the capability on for a free team's App ID
(app/patches/sidestore/0002), with the value SideStore's additional
entitlements give the key, which is never true: up to Cartouche 0.12.1 the
request waited for true, and never went out. A request Apple refuses, for
too many requests or otherwise, is only logged: the update or renewal goes
on as before. The request is tried in Swift.

The Swift tests are skipped without a compiler, except in GitHub Actions,
where the App sources job has one and its absence fails them.

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
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_sidestore_outcome import PATCHES, ROOT, SIDESTORE, hunks, patched

OPERATIONS = "SideStore/Core/Operations"
REMOVE_EXTENSIONS = f"{OPERATIONS}/PipelineOperations/RemoveAppExtensionsOperation.swift"
PROFILE_RULE = f"{OPERATIONS}/CartoucheExtensionsProfile.swift"
FETCH_PROFILES = f"{OPERATIONS}/PipelineOperations/FetchProvisioningProfilesOperation.swift"
PREPARE_IDS = f"{OPERATIONS}/PipelineOperations/PrepareAppExtensionBundleIDsOperation.swift"
RESIGN = f"{OPERATIONS}/PipelineOperations/ResignAppOperation.swift"
INSTALL = f"{OPERATIONS}/PipelineOperations/InstallAppOperation.swift"
REFRESH = f"{OPERATIONS}/PipelineOperations/RefreshAppOperation.swift"
RUNNER = f"{OPERATIONS}/PipelineRunner.swift"
STEPS = f"{OPERATIONS}/OperationStepDefinition.swift"
ADDITIONAL = f"{OPERATIONS}/OperationEntitlements.swift"
APP_DELEGATE = "AltStore/AppDelegate.swift"
ALTSTORE_APP = "Shared/Extensions/ALTApplication+AltStoreApp.swift"
BUNDLE = "Shared/Extensions/Bundle+AltStore.swift"
SIGNER = "Dependencies/SideSign/Sources/CodeSigning/CodeSignerAPI.swift"
LIVECONTAINER = ROOT / "app" / "LiveContainer"
CARTOUCHE_ENTITLEMENTS = LIVECONTAINER / "entitlements.xml"
LIVEPROCESS_ENTITLEMENTS = LIVECONTAINER / "LiveProcess" / "LiveProcess.entitlements"
LIVEPROCESS_SETTINGS = LIVECONTAINER / "xcconfigs" / "LiveProcess.xcconfig"
HOOKS = LIVECONTAINER / "SideStoreSupport" / "SideStoreHooks.m"
BRAND = ROOT / "app" / "scripts" / "brand.py"
PACKAGE = ROOT / "app" / "scripts" / "package.sh"
IML = "com.apple.developer.kernel.increased-memory-limit"
SWIFTC = shutil.which("swiftc")


def need_swift(test: unittest.TestCase, reason: str = "Needs a Swift compiler") -> None:
    """Skips TEST without a Swift compiler, but fails it in GitHub Actions,
    whose Ubuntu runners have one: the App sources job, which runs these
    tests, never leaves the rule or the request untried without a word."""
    if SWIFTC:
        return
    if os.environ.get("GITHUB_ACTIONS") == "true":
        test.fail(f"{reason}: GitHub's runners have one, so this job must run it")
    test.skipTest(reason)


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


def declaration_of(source: str, opening: str, what: str) -> str:
    """The declaration that starts with OPENING, a regular expression whose
    match ends with its brace, up to the brace that closes it."""
    match = re.search(opening, source)
    if not match:
        raise AssertionError(f"{what} not found")
    return match.group(0) + body_of(source[match.start():], opening, what) + "}"


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


def run_swift(files: dict) -> list:
    """Builds FILES, Swift sources by their name, main.swift among them, with
    the Swift compiler, and runs them: the lines they print."""
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        for name, text in files.items():
            (folder / name).write_text(text, encoding="utf-8")
        built = subprocess.run([SWIFTC, "-module-cache-path", str(folder / "cache"), "-o", str(folder / "probe"),
                                *(str(folder / name) for name in sorted(files))],
                               capture_output=True, text=True, timeout=600)
        if built.returncode != 0:
            raise AssertionError(f"Swift did not build:\n{built.stderr[-4000:]}")
        ran = subprocess.run([str(folder / "probe")], capture_output=True, text=True, timeout=60)
        if ran.returncode != 0:
            raise AssertionError(f"Swift did not run:\n{ran.stderr[-4000:]}")
        return ran.stdout.splitlines()


def swift_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


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


def cartouche_block() -> tuple:
    """RemoveAppExtensionsOperation.execute, and the block in it for the app
    SideStore is built into."""
    execute = body_of(patched(REMOVE_EXTENSIONS),
                      r"override func execute\(parentProgress: Progress\?\) async throws -> ALTApplication \{",
                      "RemoveAppExtensionsOperation.execute")
    return execute, body_of(execute, r"if targetAppBundle\.isAltStoreApp \{",
                            "the block for the app SideStore is built into")


# The rule's call, its arguments one level of parentheses deep.
RULE_CALL = r"if CartoucheExtensionsProfile\.signsWithAppProfile\(((?:[^()]|\([^()]*\))*)\) \{"


def extension_suffixes() -> list:
    """What follows Cartouche's bundle ID in its extensions' own: LiveProcess,
    as LiveContainer's settings name it, and the widget, as package.sh
    names SideStore's."""
    process = re.search(r"PRODUCT_BUNDLE_IDENTIFIER = \$\(LIVECONTAINER_BUNDLE_IDENTIFIER\)(\.\w+)",
                        LIVEPROCESS_SETTINGS.read_text(encoding="utf-8"))
    widget = re.search(r'Set :CFBundleIdentifier \$BUNDLE_ID(\.\w+)" "\$WIDGET/Info\.plist"',
                       PACKAGE.read_text(encoding="utf-8"))
    if not (process and widget):
        raise AssertionError("the bundle IDs of LiveProcess or the widget not found")
    return [process.group(1), widget.group(1)]


class CartoucheExtensionsProfileTest(unittest.TestCase):
    """app/patches/sidestore/0021: an update."""

    def test_sidestore_keeps_cartouches_profile_for_its_extensions(self):
        execute, cartouche = cartouche_block()
        call = re.search(RULE_CALL, cartouche)
        self.assertIsNotNone(call, "the block does not ask CartoucheExtensionsProfile")
        given = {name: value.strip() for name, value in
                 (re.fullmatch(r"\s*(\w+):\s*(.+?)\s*", part, re.S).groups() for part in top_level(call.group(1), ","))}
        self.assertEqual(given, {
            "appBundleIdentifier": "targetAppBundle.bundleIdentifier",
            "extensionBundleIdentifiers": "targetAppBundle.appExtensions.map { $0.bundleIdentifier }",
            "bundleIdentifier": "self.context.bundleIdentifier",
            "targetBundleIdentifier": "self.context.targetBundleIdentifier",
            "startedFrom": "startedFrom",
            "runningVersion": "runningVersion",
        })
        self.assertIn("let startedFrom = UserDefaults.standard.string(forKey: CartoucheExtensionsProfile.startedFromKey)",
                      cartouche)
        # The app SideStore is built into: LiveContainer's hook gives it as
        # the active bundle in LiveProcess.
        self.assertIn("let runningVersion = CartoucheExtensionsProfile.version(of: Bundle.Info.activeBundle.infoDictionary)",
                      cartouche)
        kept = body_of(cartouche, RULE_CALL, "what the block does with the app's profile")
        recorded = kept.index("UserDefaults.standard.set(runningVersion, forKey: CartoucheExtensionsProfile.startedFromKey)")
        chosen = kept.index("self.context.useMainProfile = true")
        self.assertLess(recorded, chosen, "the version is kept before anything can stop the update")
        self.assertLess(chosen, kept.index("return targetAppBundle"))
        # Before the player's setting, the alert that asks, or the removal of
        # an extension can apply.
        start = execute.index("if targetAppBundle.isAltStoreApp {")
        for later in ("customizeAppExtensions", "selectAppExtensionsToRemove", "removeExtensions(", "processExtensionsInfo("):
            self.assertLess(start, execute.index(later), f"{later} comes before Cartouche's own profile is chosen")
        self.assertGreater(start, execute.index("guard let targetAppBundle = context.targetAppBundle"))

    def test_otherwise_its_extensions_are_signed_as_before(self):
        _, cartouche = cartouche_block()
        call = re.search(RULE_CALL, cartouche)
        kept = body_of(cartouche, RULE_CALL, "what the block does with the app's profile")
        after = cartouche[call.end() + len(kept) + 1:]
        self.assertIn("UserDefaults.standard.removeObject(forKey: CartoucheExtensionsProfile.startedFromKey)", after,
                      "a version kept after an update that ended would sign the next one as before")
        self.assertNotIn("useMainProfile", after)
        self.assertNotIn("return", after)
        # The patch only adds that block to SideStore's own code: past it, the
        # choice of extensions, the alert and the setting apply as they
        # always did.
        patch = sorted(PATCHES.glob("*-sign-cartouches-extensions-with-its-own-profile.patch"))
        self.assertEqual(len(patch), 1)
        touching = [other.name for other in sorted(PATCHES.glob("*.patch")) if REMOVE_EXTENSIONS in hunks(other)]
        self.assertEqual(touching, [patch[0].name])
        for _, _, lines in hunks(patch[0])[REMOVE_EXTENSIONS]:
            self.assertNotIn("-", {tag for tag, _ in lines}, "the patch changes a line of SideStore's own")
        added = [text for _, _, lines in hunks(patch[0])[REMOVE_EXTENSIONS] for tag, text in lines if tag == "+"]
        self.assertEqual(added[0].strip()[:len("// Cartouche:")], "// Cartouche:")
        self.assertEqual([line.strip() for line in added[-2:]], ["}", ""])

    def test_the_rule_in_swift(self):
        need_swift(self)
        app = "com.example.cartouche"
        extensions = [app + suffix for suffix in extension_suffixes()]
        cases = [
            # name, app's bundle, its extensions, known as, signed as, last tried from, expected
            ("update", app, extensions, app, app, None, True),
            ("after an update that ended", app, extensions, app, app, "0.13.0 (5)", True),
            ("after one that never ended", app, extensions, app, app, "0.14.0 (6)", False),
            ("a bundle ID of the player's own", app, extensions, app, "com.example.mine", None, False),
            ("the installed app signed again", app + ".TEAMID", [e.replace(app, app + ".TEAMID") for e in extensions],
             app, app, None, False),
            ("an extension outside the app's bundle ID", app, [extensions[0], "com.example.widget"], app, app, None, False),
            ("an extension that only starts like it", app, [extensions[0], app + "Widget"], app, app, None, False),
        ]
        main = []
        for name, bundle, exts, known, target, started, _ in cases:
            main.append(
                f"print({swift_string(name)} + \": \" + String(CartoucheExtensionsProfile.signsWithAppProfile("
                f"appBundleIdentifier: {swift_string(bundle)}, "
                f"extensionBundleIdentifiers: [{', '.join(swift_string(e) for e in exts)}], "
                f"bundleIdentifier: {swift_string(known)}, targetBundleIdentifier: {swift_string(target)}, "
                f"startedFrom: {swift_string(started) if started else 'nil'}, runningVersion: \"0.14.0 (6)\")))")
        main.append('print("version: " + CartoucheExtensionsProfile.version(of: '
                    '["CFBundleShortVersionString": "0.14.0", "CFBundleVersion": "6"]))')
        main.append('print("no version: " + CartoucheExtensionsProfile.version(of: nil))')
        printed = run_swift({"CartoucheExtensionsProfile.swift": patched(PROFILE_RULE), "main.swift": "\n".join(main) + "\n"})
        expected = [f"{name}: {str(result).lower()}" for name, *_, result in cases]
        self.assertEqual(printed, expected + ["version: 0.14.0 (6)", "no version: ? (?)"])

    def test_the_rule_lets_through_what_the_steps_that_follow_sign(self):
        """Walks the bundle IDs through the steps that follow, as their code
        reads them, and checks that the rule lets through exactly the cases
        where every extension ends up with a bundle ID of its own under the
        app profile's, each signed with that profile."""
        fetch, prepare, resign = patched(FETCH_PROFILES), patched(PREPARE_IDS), patched(RESIGN)
        # Fetching: the app's profile alone, under the bundle ID it is signed as.
        self.assertIn("let effectiveBundleId = self.context.targetBundleIdentifier", fetch)
        self.assertIn("var profiles = [effectiveBundleId: profile]", fetch)
        self.assertRegex(fetch, r"guard !self\.context\.useMainProfile, !appExtensions\.isEmpty else \{[^}]*return profiles\s*\}")
        # Naming the extensions: under the bundle ID SideStore knows the app by.
        self.assertIn("let profile = self.context.provisioningProfiles?[self.context.bundleIdentifier]", prepare)
        self.assertRegex(prepare, r"appexBundleIds\[appex\.bundleIdentifier\] = appex\.bundleIdentifier\s*"
                                  r"\.replacingOccurrences\(of: appBundle\.bundleIdentifier, with: profile\.bundleIdentifier\)")
        # Signing: every bundle with the first profile, each extension named
        # from what the step before gave it, or else the profile's own.
        self.assertIn("let bundleIdentifier = context.targetBundleIdentifier", resign)
        self.assertIn("appExtension.bundleIdentifier.replacingOccurrences(of: targetAppBundle.bundleIdentifier, with: bundleIdentifier)",
                      resign)
        self.assertEqual(resign.count("context.useMainProfile ? profiles.values.first : profiles["), 2)
        self.assertIn("let newBundleID = appexBundleIds[identifier] ?? profile.bundleIdentifier", resign)

        def signed(bundle, exts, known, target):
            profile = target + ".TEAMID"                    # its App ID, the team's ID appended
            profiles = {target: profile}
            main = profiles.get(known)
            appex = {e: e.replace(bundle, main) for e in exts} if main else {}
            return {e: appex.get(e.replace(bundle, target), profile) for e in exts}, profile

        def works(bundle, exts, known, target):
            names, profile = signed(bundle, exts, known, target)
            ok = [names[e] == profile + e[len(bundle):] for e in exts if e.startswith(bundle + ".")]
            return len(ok) == len(exts) and all(ok) and len(set(names.values())) == len(exts)

        app = "com.example.cartouche"
        suffixes = extension_suffixes()
        names, profile = signed(app, [app + s for s in suffixes], app, app)
        self.assertEqual(names, {app + s: profile + s for s in suffixes},
                         "LiveProcess and the widget do not get bundle IDs of their own under Cartouche's")
        grid = []
        for bundle in (app, app + ".TEAMID"):
            for target in (app, "com.example.mine"):
                for exts in ([bundle + s for s in suffixes], [bundle + suffixes[0], "com.example.widget"],
                             [bundle + suffixes[0], bundle + "Widget"]):
                    grid.append((bundle, exts, app, target))
        expected = [works(*case) for case in grid]
        self.assertIn(True, expected)
        self.assertIn(False, expected)
        need_swift(self, "Needs a Swift compiler for the rule itself")
        main = "\n".join(
            "print(CartoucheExtensionsProfile.signsWithAppProfile("
            f"appBundleIdentifier: {swift_string(bundle)}, extensionBundleIdentifiers: [{', '.join(map(swift_string, exts))}], "
            f"bundleIdentifier: {swift_string(known)}, targetBundleIdentifier: {swift_string(target)}, "
            "startedFrom: nil, runningVersion: \"1 (1)\"))" for bundle, exts, known, target in grid)
        printed = run_swift({"CartoucheExtensionsProfile.swift": patched(PROFILE_RULE), "main.swift": main + "\n"})
        self.assertEqual(printed, [str(value).lower() for value in expected])

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


class RecordAndRenewalTest(unittest.TestCase):
    """What an update records, and what a renewal does with it."""

    def test_an_update_records_the_choice_once_the_new_version_runs(self):
        install = patched(INSTALL)
        record = body_of(install, r"private func fetchOrCreateApp\(", "InstallAppOperation.fetchOrCreateApp")
        self.assertIn("installedApp.useMainProfile = context.useMainProfile", record)
        # The app SideStore is built into stops as iOS installs it: what the
        # install records waits beside the app...
        self.assertIn('containerURL.appendingPathComponent("StagedSelfReinstall.json")', install)
        # ...for the app to start again from its new bundle, never from the
        # one an update that never ended left.
        reconcile = body_of(patched(APP_DELEGATE), r"static func reconcileSelfReinstallationIfNeeded\(\) \{",
                            "AppDelegate.reconcileSelfReinstallationIfNeeded")
        applied = body_of(reconcile, r"if let lastBundlePath, currBundlePath != lastBundlePath \{", "the reinstall confirmed")
        self.assertIn("InstalledApp.deserialize(from: jsonData", applied)
        self.assertEqual(reconcile.count("InstalledApp.deserialize("), 1)
        # Other apps: the runner saves an operation's changes only once it
        # succeeded.
        perform = body_of(patched(RUNNER), r"func performOperation\(for operation: AppOperation, .*?\) async throws \{",
                          "PipelineRunner.performOperation")
        succeeded, failed = perform.split("\n        } catch {", 1)
        self.assertIn("try dbContext.save()", succeeded)
        self.assertNotIn("save()", failed)

    def test_a_renewal_signs_nothing_again(self):
        order = steps(patched(STEPS), "refresh")
        self.assertRegex(patched(STEPS), r"case \.refresh:\s*return refresh")
        for signing in ("removeAppExtensions", "prepareAppExtensionBundleIDs", "resignApp", "installApp"):
            self.assertNotIn(signing, order)
        self.assertLess(order.index("fetchProvisioningProfiles"), order.index("refreshApp"))

    def test_a_renewal_renews_the_profiles_the_record_names(self):
        runner = body_of(patched(RUNNER), r"if let app = operation\.app as\? InstalledApp \{", "the runner's InstalledApp")
        self.assertIn("context.useMainProfile = app.useMainProfile", runner)
        # With Cartouche's own profile: that one alone.
        fetch = patched(FETCH_PROFILES)
        alone = fetch.index("guard !self.context.useMainProfile, !appExtensions.isEmpty else {")
        self.assertLess(fetch.index("let profile = try await self.provisionAndFetchProfile(for: targetAppBundle, parentAppBundle: nil"),
                        alone)
        self.assertLess(alone, fetch.index("parentAppBundle: targetAppBundle"))
        # Every profile fetched goes to the iPhone, one by one or in a batch.
        refresh = body_of(patched(REFRESH), r"override func execute\(parentProgress: Progress\?\) async throws -> InstalledApp \{",
                          "RefreshAppOperation.execute")
        self.assertRegex(refresh, r"for p in profiles \{\s*try await installProvisioningProfiles\(p\.value\.data\)\s*\}")
        self.assertIn("profiles: profiles.values.map { $0.data }", refresh)

    def test_updates_and_renewals_ask_for_the_capability(self):
        definition = patched(STEPS)
        for name in ("install", "refresh"):
            self.assertIn("fetchProvisioningProfiles", steps(definition, name), name)
        provision = body_of(patched(FETCH_PROFILES), r"private func provisionAndFetchProfile\(for targetAppBundle: ALTApplication,",
                            "provisionAndFetchProfile")
        self.assertIn("await self.enableIncreasedMemoryLimitIfRequested(for: groupAppID, targetAppBundle: targetAppBundle, team: team)",
                      provision)


class LiveProcessEntitlementTest(unittest.TestCase):
    def test_liveprocess_and_cartouche_ask_for_the_entitlement(self):
        for path in (LIVEPROCESS_ENTITLEMENTS, CARTOUCHE_ENTITLEMENTS):
            entitlements = plistlib.loads(path.read_bytes())
            self.assertIs(entitlements.get(IML), True, path.name)

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

    def test_a_refused_request_stops_nothing(self):
        # It cannot throw, and its call does not try: the profile is
        # downloaded whatever Apple answered, as before the request.
        fetch = patched(FETCH_PROFILES)
        self.assertRegex(fetch, r"func enableIncreasedMemoryLimitIfRequested\([^)]*\) async \{")
        provision = body_of(fetch, r"private func provisionAndFetchProfile\(for targetAppBundle: ALTApplication,",
                            "provisionAndFetchProfile")
        self.assertNotRegex(provision, r"try\s+await self\.enableIncreasedMemoryLimitIfRequested")
        caught = body_of(self.request(), r"\} catch \{", "the request's catch")
        self.assertNotIn("throw", caught)
        self.assertIn("debugLog", caught)

    def test_the_request_in_swift(self):
        need_swift(self)
        function = declaration_of(patched(FETCH_PROFILES),
                                  r"func enableIncreasedMemoryLimitIfRequested\(.*?\) async \{",
                                  "enableIncreasedMemoryLimitIfRequested")
        additional = "\n".join(line for line in patched(ADDITIONAL).splitlines() if not line.startswith("import SideSign"))
        own = {path.name: plistlib.loads(path.read_bytes()).get(IML) for path in (CARTOUCHE_ENTITLEMENTS, LIVEPROCESS_ENTITLEMENTS)}
        sidestore = "OperationEntitlements.defaultAdditionalEntitlements"
        cases = [
            # name, team, the app's own value, additional entitlements, Apple's answer, requests expected
            ("SideStore's additional entitlements", "free", None, sidestore, None, 1),
            ("Cartouche's own entitlements", "free", own["entitlements.xml"], "[:]", None, 1),
            ("LiveProcess's own entitlements", "free", own["LiveProcess.entitlements"], "[:]", None, 1),
            ("turned off", "free", False, "[:]", None, 0),
            ("not asked for", "free", None, "[:]", None, 0),
            ("a paid team", "individual", True, sidestore, None, 0),
            ("too many requests", "free", None, sidestore, 429, 1),
            ("refused", "free", None, sidestore, 403, 1),
        ]
        main = [STUB_MAIN]
        for name, team, value, extra, status, _ in cases:
            entitlements = "[:]" if value is None else f"[{swift_string(IML)}: {str(value).lower()}]"
            failure = "nil" if status is None else f"AppleAnswer(status: {status})"
            main.append(f"await ask({swift_string(name)}, team: .{team}, own: {entitlements}, additional: {extra}, failure: {failure})")
        printed = run_swift({"Stubs.swift": REQUEST_STUBS, "OperationEntitlements.swift": additional,
                             "Request.swift": "extension Probe {\n" + function + "\n}\n", "main.swift": "\n".join(main) + "\n"})
        self.assertEqual(printed, [f"{name}: {count} request(s), then the profile" for name, *_, count in cases])


# What enableIncreasedMemoryLimitIfRequested needs of SideSign and SideStore,
# as they give it: entitlements by their key, a team, an App ID, the
# request, which fails with what Apple answers.
REQUEST_STUBS = """import Foundation

struct ALTEntitlement: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    static let increasedMemoryLimit = ALTEntitlement("com.apple.developer.kernel.increased-memory-limit")
    static let increasedDebuggingMemoryLimit = ALTEntitlement("com.apple.developer.kernel.increased-debugging-memory-limit")
    static let extendedVirtualAddressing = ALTEntitlement("com.apple.developer.kernel.extended-virtual-addressing")
}

extension Dictionary where Key == String {
    subscript(entitlement: ALTEntitlement) -> Value? {
        get { self[entitlement.rawValue] }
        set { self[entitlement.rawValue] = newValue }
    }
}

enum TeamType { case free, individual }
struct ALTTeam { var type: TeamType }
struct ALTAppID { var bundleIdentifier: String }
struct ALTApplication { var bundleIdentifier: String; var entitlements: [String: any Sendable] }
enum BundleIDCapability { static let increasedMemoryLimit = "INCREASED_MEMORY_LIMIT" }

struct AppleAnswer: LocalizedError {
    let status: Int
    var errorDescription: String? { "HTTP \\(status)" }
}

final class DeveloperPortalProxy: @unchecked Sendable {
    static let shared = DeveloperPortalProxy()
    var requests = 0
    var failure: Error?
    func enableCapabilities(_ capabilities: [String], for appID: ALTAppID, team: ALTTeam? = nil) async throws {
        precondition(capabilities == [BundleIDCapability.increasedMemoryLimit])
        requests += 1
        if let failure { throw failure }
    }
}

final class ProbeContext {
    var customEntitlementsByBundleID: [String: [String: any Sendable]] = [:]
    var additionalEntitlements: [ALTEntitlement: any Sendable] = [:]
}

final class Probe {
    let context = ProbeContext()
    func debugLog(_ message: String) {}
}
"""

# Asks as provisionAndFetchProfile does, without try, then says that the
# profile comes next.
STUB_MAIN = """func ask(_ name: String, team: TeamType, own: [String: any Sendable],
         additional: [ALTEntitlement: any Sendable], failure: Error?) async {
    DeveloperPortalProxy.shared.requests = 0
    DeveloperPortalProxy.shared.failure = failure
    let probe = Probe()
    probe.context.additionalEntitlements = additional
    await probe.enableIncreasedMemoryLimitIfRequested(for: ALTAppID(bundleIdentifier: "com.example.cartouche.TEAMID"),
                                                      targetAppBundle: ALTApplication(bundleIdentifier: "com.example.cartouche", entitlements: own),
                                                      team: ALTTeam(type: team))
    print("\\(name): \\(DeveloperPortalProxy.shared.requests) request(s), then the profile")
}
"""


if __name__ == "__main__":
    unittest.main()
