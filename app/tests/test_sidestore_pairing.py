"""Checks that a pairing file put in place in Cartouche after the first one is
the one the built-in SideStore reads (app/patches/sidestore/0023):

- the Cartouche Installer and Cartouche's setup put a pairing file where
  SideStore reads it, under its legacy name, and Cartouche counts the files
  SideStore keeps under its own names;
- SideStore takes a file put in place under the legacy name before it reads
  any pairing file, for the boot of minimuxer, the sign-in's check of this
  iPhone and every other read;
- PairingFileManager itself, built and run with Swift where there is one:
  the first pairing file, a pairing file put in place again after SideStore
  moved the first one to its own names, one of the other kind, none, and a
  file that is no pairing file.

SideStore moves a file it finds under the legacy name to its own names once,
at its first launch (MaintenanceManager.migratePairingFiles), and read those
first ever after: a pairing file put in place again was never read.

SideStore's sources are read as app/scripts/prepare.sh leaves them, every
patch applied. Needs the SideStore submodule.

Run from the repository root: python3 -m unittest discover -s app/tests -v
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_sidestore_outcome import block, patched

ROOT = Path(__file__).resolve().parents[2]
MANAGER = "SideStore/Core/Pairing/PairingFileManager.swift"
CONSTANTS = "SideStore/AppConstants.swift"
MAINTENANCE = "SideStore/MaintenanceManager.swift"
INSTALLER = ROOT / "installer" / "src-tauri" / "src" / "cartouche.rs"
SETUP = ROOT / "launcher" / "Sources" / "CartoucheSetup.swift"

# The methods of PairingFileManager the checks build, by how each one opens.
METHODS = (
    "nonisolated func pairingFileURL(for mode: PairingProtocol)",
    "nonisolated func fetchPairingFile(for mode: PairingProtocol)",
    "nonisolated func sanitizePairingFileFor(",
    "nonisolated func adoptPlacedPairingFile()",
    "nonisolated func fetchPairingFile(preferred: PairingProtocol? = nil)",
    "nonisolated func parse(content: String, preferred: PairingProtocol? = nil)",
)


def method(text: str, opening: str) -> str:
    """The declaration that starts with OPENING, with its whole body."""
    start = text.find(opening)
    if start < 0:
        raise AssertionError(f"PairingFileManager.{opening.split('func ')[1]} not found")
    body = block(text, opening, opening)
    end = text.index(body, start) + len(body)
    return text[start:end] + "}"


def pairing_names() -> dict:
    """SideStore's names of its pairing files, by their constant."""
    names = dict(re.findall(r'static let (\w+PairingFileName)\s*=\s*"([^"]+)"', patched(CONSTANTS)))
    if set(names) != {"lockdownPairingFileName", "remotePairingFileName", "legacyPairingFileName"}:
        raise AssertionError(f"AppConstants.Pairing names other pairing files: {sorted(names)}")
    return names


class SideStorePairingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manager = patched(MANAGER)
        cls.names = pairing_names()

    def test_cartouche_and_the_installer_put_it_where_sidestore_reads_it(self):
        legacy = self.names["legacyPairingFileName"]
        placed = re.search(r'const PAIRING_PATH: &str = "([^"]+)";', INSTALLER.read_text(encoding="utf-8"))
        self.assertIsNotNone(placed, "the Installer no longer says where it puts the pairing file")
        self.assertEqual(placed.group(1), "SideStore/Documents/" + legacy)
        setup = SETUP.read_text(encoding="utf-8")
        self.assertIn(f'static let importName = "{legacy}"', setup)
        # Cartouche counts every name SideStore reads one under.
        listed = re.search(r"static let fileNames = \[([^\]]+)\]", setup)
        self.assertIsNotNone(listed)
        self.assertEqual(set(re.findall(r'"([^"]+)"', listed.group(1))), set(self.names.values()))

    def test_sidestore_moves_the_first_one_to_its_own_names_once(self):
        # What 0023 answers: should SideStore move the file again at each
        # launch, or read the legacy name first, it is no longer needed.
        maintenance = patched(MAINTENANCE)
        self.assertIn("await migratePairingFiles()", maintenance)
        moving = block(maintenance, "func migratePairingFiles()", "MaintenanceManager.migratePairingFiles")
        self.assertIn("!fileManager.fileExists(atPath: remoteURL.path)", moving)
        self.assertIn("try? fileManager.removeItem(at: legacyURL)", moving)

    def test_every_read_takes_a_file_put_in_place_first(self):
        reading = block(self.manager, METHODS[4], "PairingFileManager.fetchPairingFile(preferred:)")
        self.assertTrue(reading.strip().startswith("adoptPlacedPairingFile()"),
                        "fetchPairingFile(preferred:) must take a file put in place before it reads one")
        # The boot, the sign-in's check (0019) and hasPairingFile (0005) read
        # through it.
        for name in ("SideStore/AppBootManager.swift", "SideStore/Intents/CartoucheDeviceCheck.swift"):
            self.assertIn("PairingFileManager.shared.fetchPairingFile()", patched(name), name)
        self.assertIn("if fetchPairingFile() != nil", block(self.manager, "nonisolated func hasPairingFile() -> Bool",
                                                            "PairingFileManager.hasPairingFile"))

    @unittest.skipUnless(shutil.which("swiftc"), "Needs Swift")
    def test_a_pairing_file_put_in_place_again_is_the_one_read(self):
        methods = "\n\n".join("    " + method(self.manager, opening) for opening in METHODS)
        constants = "\n".join(f'        static let {name} = "{value}"' for name, value in sorted(self.names.items()))
        stubs = '''
import Foundation

public enum PairingProtocol: String, Sendable { case rppairing, lockdown, unknown }

public protocol PairingFile { var mode: PairingProtocol { get } }
struct ParsedPairingFile: PairingFile { let mode: PairingProtocol }

enum PairingError: Error { case incomplete, ambiguous, invalid }

/// minimuxer's PairingFileParser (Common/PairingFile.swift), by the keys of
/// each kind.
enum PairingFileParser {
    static let remoteKeys = ["private_key", "public_key", "identifier"]
    static let lockdownKeys = ["WiFiMACAddress", "SystemBUID", "RootPrivateKey", "HostPrivateKey", "HostID",
                               "RootCertificate", "UDID", "EscrowBag", "HostCertificate", "DeviceCertificate"]

    static func parse(content: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        guard let data = content.data(using: .utf8),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { throw PairingError.invalid }
        let remote = remoteKeys.allSatisfy { plist[$0] != nil }
        let lockdown = lockdownKeys.allSatisfy { plist[$0] != nil }
        switch preferred {
        case .rppairing?:
            guard remote else { throw PairingError.incomplete }
            return ParsedPairingFile(mode: .rppairing)
        case .lockdown?:
            guard lockdown else { throw PairingError.incomplete }
            return ParsedPairingFile(mode: .lockdown)
        case .unknown?:
            throw PairingError.invalid
        case nil:
            if remote && lockdown { throw PairingError.ambiguous }
            if remote { return ParsedPairingFile(mode: .rppairing) }
            if lockdown { return ParsedPairingFile(mode: .lockdown) }
            throw PairingError.invalid
        }
    }
}

enum AppConstants {
    enum Pairing {
''' + constants + '''
    }
}

extension FileManager {
    var documentsDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["PAIRING_DOCUMENTS"]!, isDirectory: true)
    }
}

func debugLog(_ message: @autoclosure () -> String) {}

final class PairingFileManager: NSObject {
    static let shared = PairingFileManager()
    nonisolated(unsafe) static var preferred: PairingProtocol?
    nonisolated(unsafe) static var persisted: PairingProtocol?

    var preferredProtocol: PairingProtocol? {
        get { Self.preferred }
        set { Self.preferred = newValue }
    }

    var persistedActiveProtocol: PairingProtocol? {
        get { Self.persisted }
        set { Self.persisted = newValue }
    }

''' + methods + '''
}
'''
        checks = r'''
import Foundation

func plist(_ values: [String: String]) -> String {
    String(data: try! PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0), encoding: .utf8)!
}

func remote(_ by: String) -> [String: String] {
    ["private_key": by, "public_key": by, "identifier": by]
}

func lockdown(_ by: String) -> [String: String] {
    Dictionary(uniqueKeysWithValues: PairingFileParser.lockdownKeys.map { ($0, by) })
}

func both(_ by: String) -> [String: String] {
    remote(by).merging(lockdown(by)) { first, _ in first }
}

let documents = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PAIRING_DOCUMENTS"]!, isDirectory: true)
let manager = PairingFileManager.shared

func url(_ mode: PairingProtocol) -> URL { manager.pairingFileURL(for: mode) }

func put(_ mode: PairingProtocol, _ values: [String: String]?) {
    try? FileManager.default.removeItem(at: url(mode))
    if let values { try! plist(values).write(to: url(mode), atomically: true, encoding: .utf8) }
}

func put(_ mode: PairingProtocol, text: String) {
    try! text.write(to: url(mode), atomically: true, encoding: .utf8)
}

func held(_ mode: PairingProtocol) -> String? {
    try? String(contentsOf: url(mode), encoding: .utf8)
}

/// The values of a pairing file as read, by key.
func values(_ read: String?) -> [String: String] {
    guard let data = read?.data(using: .utf8),
          let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
    else { return [:] }
    return plist
}

func expect(_ condition: Bool, _ what: String) {
    if !condition {
        print("FAILED: \(what)")
        exit(1)
    }
}

func start(_ rp: [String: String]?, _ ld: [String: String]?, placed: [String: String]?) {
    put(.rppairing, rp)
    put(.lockdown, ld)
    put(.unknown, placed)
    PairingFileManager.persisted = nil
    PairingFileManager.preferred = nil
}

// The first pairing file, as the Installer puts it, before SideStore moved it.
start(nil, nil, placed: both("new"))
expect(values(manager.fetchPairingFile()) == remote("new"), "the first pairing file is read, as Remote Pairing")
expect(values(held(.rppairing)) == both("new") && values(held(.lockdown)) == both("new"),
       "the first pairing file is kept under both of SideStore's names")
expect(held(.unknown) == nil, "the first pairing file leaves the legacy name")
expect(PairingFileManager.persisted == .rppairing, "the first pairing file is recorded as Remote Pairing")

// One put in place again, once SideStore had moved the first one: what 0023
// is for.
start(both("old"), both("old"), placed: both("new"))
expect(values(manager.fetchPairingFile()) == remote("new"), "a pairing file put in place again is the one read")
expect(values(held(.rppairing)) == both("new") && values(held(.lockdown)) == both("new"),
       "a pairing file put in place again replaces both of SideStore's")
expect(held(.unknown) == nil, "a pairing file put in place again leaves the legacy name")
expect(values(manager.fetchPairingFile()) == remote("new"), "the next read reads it again")

// A Lockdown pairing file over a Remote Pairing one.
start(both("old"), both("old"), placed: lockdown("new"))
expect(values(manager.fetchPairingFile()) == lockdown("new"), "a Lockdown pairing file put in place is read")
expect(held(.rppairing) == nil, "the Remote Pairing file it replaces goes")
expect(PairingFileManager.persisted == .lockdown, "it is recorded as Lockdown")

// A Remote Pairing file over a Lockdown one.
start(nil, lockdown("old"), placed: remote("new"))
expect(values(manager.fetchPairingFile()) == remote("new"), "a Remote Pairing file put in place is read")
expect(held(.lockdown) == nil, "the Lockdown file it replaces goes")

// None put in place: SideStore's own, untouched.
start(remote("old"), nil, placed: nil)
expect(values(manager.fetchPairingFile()) == remote("old"), "SideStore's own pairing file is read")
expect(values(held(.rppairing)) == remote("old") && held(.lockdown) == nil && held(.unknown) == nil,
       "nothing changes when no pairing file was put in place")

// A file that is no pairing file: left where it is, SideStore's own read.
start(remote("old"), nil, placed: nil)
put(.unknown, text: "not a pairing file")
expect(values(manager.fetchPairingFile()) == remote("old"), "a file that is no pairing file changes nothing")
expect(held(.unknown) == "not a pairing file", "a file that is no pairing file stays")

// A preferred kind the new file does not hold: the new file all the same.
start(both("old"), both("old"), placed: lockdown("new"))
PairingFileManager.preferred = .rppairing
expect(values(manager.fetchPairingFile()) == lockdown("new"), "a preferred kind the new file lacks reads the new file")

print("Pairing file checks passed")
'''
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            documents = folder / "Documents"
            documents.mkdir()
            (folder / "PairingFileManager.swift").write_text(stubs, encoding="utf-8")
            (folder / "main.swift").write_text(checks, encoding="utf-8")
            built = subprocess.run([
                "swiftc", "-module-name", "PairingChecks", str(folder / "PairingFileManager.swift"),
                str(folder / "main.swift"), "-o", str(folder / "checks"), "-module-cache-path", str(folder / "cache"),
            ], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(folder / "checks")], capture_output=True, text=True, timeout=60,
                                 env={**os.environ, "PAIRING_DOCUMENTS": str(documents)})
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("Pairing file checks passed", run.stdout)


if __name__ == "__main__":
    unittest.main()
