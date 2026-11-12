"""Check credential storage and the CryptoKit handoff reader on macOS."""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ImportedSigningTest(unittest.TestCase):
    def test_imported_secrets_are_not_copied_into_preferences(self):
        adapter = (ROOT / "launcher/Sources/CartoucheImportedSigning.swift").read_text()
        self.assertNotRegex(adapter, r'\.set\(material\.(certificate|password)\b')

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "Needs Apple's Swift compiler and CryptoKit")
    def test_imports_preserve_the_profile_and_reject_incompatible_material(self):
        main = r'''
import Foundation
import CryptoKit

func profile(certificate: Data, expiration: Date = Date().addingTimeInterval(3600)) throws -> Data {
    let data = try PropertyListSerialization.data(fromPropertyList: [
        "ExpirationDate": expiration,
        "TeamIdentifier": ["TEAM"],
        "DeveloperCertificates": [certificate]
    ], format: .xml, options: 0)
    return Data([0x30, 0x80]) + data + Data([0, 0])
}
let certificate = Data([1, 2, 3])
let valid = try profile(certificate: certificate)
let material = CartoucheSigningMaterial(certificate: Data([4]), password: "secret", profile: valid)
let encoded = try PropertyListEncoder().encode(material)
let restored = try PropertyListDecoder().decode(CartoucheSigningMaterial.self, from: encoded)
assert(restored.certificate == material.certificate && restored.password == "secret")
let key = SymmetricKey(size: .bits256)
let keyData = key.withUnsafeBytes { Data($0) }
let sealed = try AES.GCM.seal(encoded, using: key, authenticating: Data("CartoucheSigningHandoff.v1".utf8)).combined!
let opened = try CartoucheSigningMaterial.openHandoff(sealed, key: keyData)
assert(opened.certificate == material.certificate && opened.password == "secret")

try restored.validate(certificateDER: certificate, team: "TEAM", hostTeam: "TEAM", hostProfile: valid)
func rejected(_ action: () throws -> Void) {
    do { try action(); fatalError("Invalid signing material accepted") } catch {}
}
rejected { try restored.validate(certificateDER: Data([9]), team: "TEAM", hostTeam: "TEAM", hostProfile: valid) }
rejected { try restored.validate(certificateDER: certificate, team: "OTHER", hostTeam: "TEAM", hostProfile: valid) }
rejected { try restored.validate(certificateDER: certificate, team: "TEAM", hostTeam: "OTHER", hostProfile: valid) }
let expired = CartoucheSigningMaterial(certificate: Data(), password: "", profile: try profile(certificate: certificate, expiration: .distantPast))
rejected { try expired.validate(certificateDER: certificate, team: "TEAM", hostTeam: "TEAM", hostProfile: valid) }
let corrupt = CartoucheSigningMaterial(certificate: Data(), password: "", profile: Data("not a profile".utf8))
rejected { try corrupt.validate(certificateDER: certificate, team: "TEAM", hostTeam: "TEAM", hostProfile: valid) }
var tampered = sealed
tampered[tampered.count - 1] ^= 1
rejected { _ = try CartoucheSigningMaterial.openHandoff(tampered, key: keyData) }
rejected { _ = try CartoucheSigningMaterial.openHandoff(encoded, key: keyData) }
rejected { _ = try CartoucheSigningMaterial.openHandoff(sealed, key: Data(repeating: 0, count: 32)) }
rejected { _ = try CartoucheSigningMaterial.openHandoff(sealed, key: Data()) }
let otherHost = try profile(certificate: Data([7]))
rejected { try restored.validate(certificateDER: certificate, team: "TEAM", hostTeam: "TEAM", hostProfile: otherHost) }
print("Signing material checks passed")
'''
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / "main.swift").write_text(main)
            result = subprocess.run([
                "swiftc", str(ROOT / "launcher/Sources/CartoucheSigningMaterial.swift"),
                str(folder / "main.swift"), "-o", str(folder / "checks"),
                "-module-cache-path", str(folder / "cache"),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            run = subprocess.run([str(folder / "checks")], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("Signing material checks passed", run.stdout)
