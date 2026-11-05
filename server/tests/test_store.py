import contextlib
import io
import json
import os
import random
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from cartouche_server import APP_BUNDLE_ID, cli, signing, store
from cartouche_server.chunker import Params
from cartouche_server.manifest import Manifest

from fixtures import CLEAN_MACHO, GAME_SEGMENT_MACHO, ipa

SMALL = Params(min_size=256, avg_size=1024, max_size=4096)


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.root = self.dir / "bucket"
        self.private, self.public = signing.generate()
        self.host = self.dir / "host"
        self.host.write_bytes(CLEAN_MACHO + random.Random(7).randbytes(50_000))
        self.app = self.dir / "Cartouche.ipa"
        self.app.write_bytes(ipa())

    def tearDown(self):
        self.tmp.cleanup()

    def publish(self, items, published="2026-11-05T22:00:00Z"):
        return store.publish(
            self.root, "stable", items,
            private_key=self.private, app_bundle_id=APP_BUNDLE_ID, published=published, params=SMALL,
        )

    def item(self, path, kind, artifact_id, version="1"):
        return store.ReleaseItem(artifact_id, kind, version, path)

    def test_publish_then_verify(self):
        manifest = self.publish([self.item(self.host, "engine-host", "engine-host/0400C3F00006E000"), self.item(self.app, "app", "app")])
        self.assertEqual(manifest.sequence, 1)
        self.assertEqual(store.verify(self.root, "stable", self.public), [])
        host = manifest.artifact("engine-host/0400C3F00006E000")
        self.assertGreater(len(host.chunks), 1)

    def test_second_publish_carries_over_and_bumps_sequence(self):
        self.publish([self.item(self.app, "app", "app")])
        second = self.publish([self.item(self.host, "engine-host", "engine-host/0400C3F00006E000")], "2026-11-06T08:00:00Z")
        self.assertEqual(second.sequence, 2)
        self.assertEqual({a.id for a in second.artifacts}, {"app", "engine-host/0400C3F00006E000"})

    def test_new_version_reuses_chunks(self):
        self.publish([self.item(self.host, "engine-host", "engine-host/0400C3F00006E000")])
        count = sum(1 for _ in (self.root / "chunks").rglob("*") if _.is_file())
        data = self.host.read_bytes()
        self.host.write_bytes(data[:30_000] + b"one small change" + data[30_000:])
        self.publish([self.item(self.host, "engine-host", "engine-host/0400C3F00006E000", "2")])
        added = sum(1 for _ in (self.root / "chunks").rglob("*") if _.is_file()) - count
        self.assertLessEqual(added, 4)

    def test_refused_file_writes_nothing(self):
        bad = self.dir / "host-with-game"
        bad.write_bytes(GAME_SEGMENT_MACHO)
        with self.assertRaises(store.guard.Rejected):
            self.publish([self.item(self.app, "app", "app"), self.item(bad, "engine-host", "engine-host/0400C3F00006E000")])
        self.assertFalse(self.root.exists())

    def test_tampered_manifest_is_caught(self):
        self.publish([self.item(self.app, "app", "app")])
        manifest_file, _ = store.manifest_paths(self.root, "stable")
        manifest_file.write_bytes(manifest_file.read_bytes().replace(b'"sequence":1', b'"sequence":5'))
        self.assertTrue(store.verify(self.root, "stable", self.public))
        with self.assertRaises(store.StoreError):
            self.publish([self.item(self.app, "app", "app")])

    def test_damaged_chunk_is_caught(self):
        manifest = self.publish([self.item(self.host, "engine-host", "engine-host/0400C3F00006E000")])
        chunk = manifest.artifacts[0].chunks[0]
        (self.root / "chunks" / chunk.sha256[:2] / chunk.sha256).write_bytes(b"damaged")
        problems = store.verify(self.root, "stable", self.public)
        self.assertTrue(any("damaged" in p for p in problems))


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_keygen_publish_verify(self):
        key_file = self.dir / "manifest.key"
        code, out, _ = self.run_cli("keygen", "--out", str(key_file))
        self.assertEqual(code, 0)
        self.assertEqual(key_file.stat().st_mode & 0o777, 0o600)
        public = out.strip().splitlines()[-1].split(": ", 1)[1]
        (self.dir / "stable.pub").write_text(public + "\n")

        app = self.dir / "Cartouche.ipa"
        app.write_bytes(ipa())
        spec = self.dir / "release.json"
        spec.write_text(json.dumps({"channel": "stable", "artifacts": [{"id": "app", "kind": "app", "version": "0.1.0", "file": str(app)}]}))
        bucket = self.dir / "bucket"
        with mock.patch.dict(os.environ, {"CARTOUCHE_MANIFEST_KEY": key_file.read_text()}):
            code, out, err = self.run_cli("publish", str(spec), "--store", str(bucket), "--key-env", "CARTOUCHE_MANIFEST_KEY")
        self.assertEqual(code, 0, err)
        self.assertIn("sequence 1", out)
        code, out, err = self.run_cli("verify", "--store", str(bucket), "--channel", "stable", "--public-key", str(self.dir / "stable.pub"))
        self.assertEqual(code, 0, err)
        manifest_file, _ = store.manifest_paths(bucket, "stable")
        self.assertEqual(Manifest.from_bytes(manifest_file.read_bytes()).artifact("app").version, "0.1.0")

    def test_keygen_refuses_to_overwrite(self):
        key_file = self.dir / "manifest.key"
        key_file.write_text("existing")
        with self.assertRaises(SystemExit):
            self.run_cli("keygen", "--out", str(key_file))
        self.assertEqual(key_file.read_text(), "existing")

    def test_check_reports_refusals(self):
        game = self.dir / "Game.ipa"
        game.write_bytes(ipa("com.example.game"))
        code, _, err = self.run_cli("check", "--kind", "app", str(game))
        self.assertEqual(code, 1)
        self.assertIn("REFUSED", err)


if __name__ == "__main__":
    unittest.main()
