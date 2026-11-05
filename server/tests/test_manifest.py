import unittest

from cartouche_server import signing
from cartouche_server.manifest import Artifact, Chunk, Manifest, ManifestError, canonical_json, chunk_path

SHA_A = "a" * 64
SHA_B = "b" * 64


def artifact(**overrides) -> Artifact:
    fields = dict(id="app", kind="app", version="0.1.0", size=3, sha256=SHA_A, chunks=(Chunk(SHA_B, 3),))
    fields.update(overrides)
    return Artifact(**fields)


def manifest(**overrides) -> Manifest:
    fields = dict(channel="stable", sequence=1, published="2026-11-05T22:00:00Z", artifacts=[artifact()])
    fields.update(overrides)
    return Manifest(**fields)


class ManifestTest(unittest.TestCase):
    def test_round_trip(self):
        original = manifest(artifacts=[artifact(), artifact(id="engine-host/0400C3F00006E000", kind="engine-host")])
        parsed = Manifest.from_bytes(original.to_bytes())
        self.assertEqual(parsed.to_json(), original.to_json())

    def test_canonical_bytes_do_not_depend_on_order(self):
        one = manifest(artifacts=[artifact(), artifact(id="catalog", kind="catalog")])
        two = manifest(artifacts=[artifact(id="catalog", kind="catalog"), artifact()])
        self.assertEqual(one.to_bytes(), two.to_bytes())
        self.assertEqual(canonical_json({"b": 1, "a": "é"}), '{"a":"é","b":1}'.encode())

    def test_there_is_no_kind_for_games(self):
        for kind in ("game", "nsp", "rom", "ipa"):
            with self.assertRaises(ManifestError):
                artifact(id=kind, kind=kind).validate()

    def test_id_must_start_with_kind(self):
        with self.assertRaises(ManifestError):
            artifact(id="engine-host/x", kind="app").validate()

    def test_sizes_must_add_up(self):
        with self.assertRaises(ManifestError):
            artifact(size=4).validate()

    def test_duplicate_ids(self):
        with self.assertRaises(ManifestError):
            manifest(artifacts=[artifact(), artifact()]).validate()

    def test_bad_fields(self):
        for bad in (dict(channel="Stable"), dict(sequence=0), dict(published="5 Nov 2026")):
            with self.assertRaises(ManifestError):
                manifest(**bad).validate()
        with self.assertRaises(ManifestError):
            Manifest.from_bytes(b"{not json")

    def test_chunk_path(self):
        self.assertEqual(chunk_path(SHA_A), f"chunks/aa/{SHA_A}")


class SigningTest(unittest.TestCase):
    def setUp(self):
        self.private, self.public = signing.generate()
        self.raw = manifest().to_bytes()

    def test_sign_and_verify(self):
        signature = signing.sign(self.raw, self.private)
        self.assertTrue(signing.verify(self.raw, signature, self.public))
        self.assertEqual(signing.public_from_private(self.private), self.public)

    def test_tampering_is_caught(self):
        signature = signing.sign(self.raw, self.private)
        tampered = self.raw.replace(b'"sequence":1', b'"sequence":9')
        self.assertFalse(signing.verify(tampered, signature, self.public))

    def test_another_key_fails(self):
        _, other_public = signing.generate()
        signature = signing.sign(self.raw, self.private)
        self.assertFalse(signing.verify(self.raw, signature, other_public))

    def test_garbage_signature_fails(self):
        self.assertFalse(signing.verify(self.raw, "not base64!", self.public))

    def test_bad_keys(self):
        with self.assertRaises(signing.SigningKeyError):
            signing.sign(self.raw, "c2hvcnQ=")


if __name__ == "__main__":
    unittest.main()
