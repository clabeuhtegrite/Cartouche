"""Import an existing slim IPA and synthetic DMROMFS1 data; never compile."""

import contextlib
import errno
import io
import json
import os
import struct
import zipfile
from unittest import mock

from cartouche_builder import api, batch, config as configs, ipa, romfs
from cartouche_builder.paths import Paths
from support import Home, MKW, make_ipa


def slim_ipa(folder):
    source = make_ipa(folder / "original.ipa", {
        "CFBundleIdentifier": "org.nxnative." + MKW.lower(),
        "CFBundleDisplayName": "Example Game", "DMCommit": "a" * 12,
    })
    with zipfile.ZipFile(source, "a") as archive:
        archive.writestr("Payload/Game.app/romfs.id",
                         f"DMROMFSID1 title={MKW} version=1.0 build=v0 size=105 index=c7a11b1c1eec2709\n")
    return source


def image(folder):
    # A root, one file and its bytes. The identity is fixed independently
    # of the implementation, using nxnative's DMROMFSID1 word-wise FNV-1a.
    payload = b"example game data"
    index = (struct.pack("<QQIHBB", 1, 1, 0, 0, 0, 0)
             + struct.pack("<QQIHBB", 32, len(payload), 0, 8, 1, 0) + b"data.bin")
    header = struct.pack("<8sQQQ", b"DMROMFS1", 32 + len(payload), len(index), 2)
    path = folder / "romfs.img"
    path.write_bytes(header + payload + index)
    return path


class Bundle(Home):
    def setUp(self):
        super().setUp()
        self.source = slim_ipa(self.tmp)
        self.image = image(self.tmp)
        self.games = self.tmp / "games"
        self.games.mkdir()

    def test_packages_matching_image_without_changing_original_entries(self):
        original = self.source.read_bytes()
        messages = []
        target = ipa.bundle_romfs(self.source, self.image, self.games, progress=messages.append)
        self.assertEqual(self.source.read_bytes(), original)
        with zipfile.ZipFile(target) as result, zipfile.ZipFile(self.source) as source:
            for entry in source.infolist():
                self.assertEqual(result.read(entry.filename), source.read(entry))
                self.assertEqual(result.getinfo(entry.filename).date_time, entry.date_time)
            self.assertEqual(result.read("Payload/Game.app/romfs.img"), self.image.read_bytes())
            self.assertGreaterEqual(result.getinfo("Payload/Game.app/romfs.img").extract_version, 45)
            self.assertIsNone(result.testzip())
        self.assertEqual(ipa.read_info(target).commit, "a" * 12)
        self.assertEqual(list(self.games.iterdir()), [target])
        self.assertTrue(messages)

    def test_same_size_different_index_is_rejected(self):
        data = self.image.read_bytes().replace(b"data.bin", b"evil.bin")
        self.image.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "match"):
            ipa.bundle_romfs(self.source, self.image, self.games)
        self.assertEqual(list(self.games.iterdir()), [])

    def test_truncated_image_is_rejected(self):
        self.image.write_bytes(self.image.read_bytes()[:-1])
        with self.assertRaises(ValueError):
            ipa.bundle_romfs(self.source, self.image, self.games)
        self.assertEqual(list(self.games.iterdir()), [])

    def test_no_identity_file_is_rejected(self):
        source = make_ipa(self.tmp / "unknown.ipa", {"DMTitleID": MKW})
        with self.assertRaisesRegex(ValueError, "romfs.id"):
            ipa.bundle_romfs(source, self.image, self.games)

    def test_identity_labels_do_not_determine_compatibility(self):
        for label in ("", "title=", "title=0100000000010000", f"title={MKW}"):
            with self.subTest(label=label):
                folder = self.tmp / ("labels-" + str(len(list(self.tmp.iterdir()))))
                source = make_ipa(folder / "label.ipa", {"DMTitleID": MKW})
                with zipfile.ZipFile(source, "a") as archive:
                    archive.writestr("Payload/Game.app/romfs.id",
                                     f"DMROMFSID1 {label} size=105 index=c7a11b1c1eec2709\n")
                target = ipa.bundle_romfs(source, self.image, folder)
                with zipfile.ZipFile(target) as archive:
                    self.assertEqual(archive.read("Payload/Game.app/romfs.img"), self.image.read_bytes())

    def test_existing_bundled_image_or_folder_is_rejected(self):
        for name in ("romfs.img", "romfs/data.bin"):
            with self.subTest(name=name):
                source = slim_ipa(self.tmp / ("bundled-" + name.replace("/", "_")))
                with zipfile.ZipFile(source, "a") as archive:
                    archive.writestr("Payload/Game.app/" + name, b"existing")
                with self.assertRaisesRegex(ValueError, "already"):
                    ipa.bundle_romfs(source, self.image, self.games)

    def test_existing_output_is_preserved(self):
        first = ipa.bundle_romfs(self.source, self.image, self.games)
        first.write_bytes(b"keep this file")
        with self.assertRaisesRegex(ValueError, "exists"):
            ipa.bundle_romfs(self.source, self.image, self.games)
        self.assertEqual(first.read_bytes(), b"keep this file")

    def test_an_output_created_during_publication_is_preserved(self):
        publish = ipa._publish

        def collision(source, target):
            target.write_bytes(b"another Mac's IPA")
            return publish(source, target)

        with mock.patch.object(ipa, "_publish", side_effect=collision):
            with self.assertRaisesRegex(ValueError, "exists"):
                ipa.bundle_romfs(self.source, self.image, self.games)
        [target] = list(self.games.iterdir())
        self.assertEqual(target.read_bytes(), b"another Mac's IPA")

    def test_replaced_source_is_revalidated_after_copy(self):
        replacement = make_ipa(self.tmp / "replacement.ipa", {"DMTitleID": MKW})

        def replace(source, target):
            target.write_bytes(replacement.read_bytes())
            return True

        with mock.patch.object(ipa, "_clone", side_effect=replace):
            with self.assertRaises(ValueError):
                ipa.bundle_romfs(self.source, self.image, self.games)
        self.assertEqual(list(self.games.iterdir()), [])

    def test_nas_uses_clean_name_and_refuses_a_second_import(self):
        for number in set((errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS)):
            with self.subTest(errno=number):
                with mock.patch.object(ipa, "_rename_exclusive", side_effect=OSError(number, "unsupported")):
                    target = ipa.bundle_romfs(self.source, self.image, self.games)
                    self.assertEqual(target.name, f"Example Game (with ROMFS) [{MKW}].ipa")
                    with self.assertRaisesRegex(ValueError, "exists"):
                        ipa.bundle_romfs(self.source, self.image, self.games)
                self.assertEqual(list(self.games.iterdir()), [target])
                with zipfile.ZipFile(target) as archive:
                    self.assertEqual(archive.read("Payload/Game.app/romfs.img"), self.image.read_bytes())
                target.unlink()

    def test_nas_rechecks_target_before_fallback_rename(self):
        def unsupported(source, target):
            target.write_bytes(b"another Mac's IPA")
            raise OSError(errno.ENOTSUP, "unsupported")

        with mock.patch.object(ipa, "_rename_exclusive", side_effect=unsupported):
            with self.assertRaisesRegex(ValueError, "exists"):
                ipa.bundle_romfs(self.source, self.image, self.games)
        [target] = list(self.games.iterdir())
        self.assertEqual(target.read_bytes(), b"another Mac's IPA")

    def test_stale_partial_is_replaced_and_hidden_during_copy(self):
        partial = self.games / f".Example Game (with ROMFS) [{MKW}].ipa.builder-partial"
        partial.write_bytes(b"interrupted import")
        copy = ipa._copy

        def check_copy(source, target, *args):
            self.assertEqual(target, partial)
            self.assertFalse(os.path.lexists(partial))
            copy(source, target, *args)
            self.assertEqual(ipa.find_in_folder(self.games, MKW), [])

        with mock.patch.object(ipa, "_clone", return_value=False), mock.patch.object(ipa, "_copy", side_effect=check_copy):
            target = ipa.bundle_romfs(self.source, self.image, self.games)
        self.assertEqual(list(self.games.iterdir()), [target])

    def test_interrupted_copy_removes_partial(self):
        def interrupt(source, target, *args):
            target.write_bytes(b"unfinished copy")
            raise KeyboardInterrupt()

        with mock.patch.object(ipa, "_clone", return_value=False), mock.patch.object(ipa, "_copy", side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                ipa.bundle_romfs(self.source, self.image, self.games)
        self.assertEqual(list(self.games.iterdir()), [])

    def test_failed_delivery_leaves_no_partial_ipa(self):
        with mock.patch.object(ipa, "_copy", side_effect=OSError("disk full")), mock.patch.object(ipa, "_clone", return_value=False):
            with self.assertRaises(OSError):
                ipa.bundle_romfs(self.source, self.image, self.games)
        self.assertEqual(list(self.games.iterdir()), [])

    def test_invalid_ipa_is_rejected(self):
        self.source.write_bytes(b"not a zip")
        with self.assertRaises(ValueError):
            ipa.bundle_romfs(self.source, self.image, self.games)

    def test_api_publishes_without_a_source_folder_or_build_tools(self):
        configs.save(Paths.default(), configs.Config(games=str(self.games)))
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = api.main(["bundle-romfs", "--ipa", str(self.source), "--romfs", str(self.image)])
        self.assertEqual(code, 0, out.getvalue())
        answer = json.loads(out.getvalue())
        self.assertTrue((self.games / answer["ipa"].split("/")[-1]).is_file())

    def test_api_answer_tells_the_game_and_size_for_the_measurements(self):
        configs.save(Paths.default(), configs.Config(games=str(self.games)))
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = api.main(["bundle-romfs", "--ipa", str(self.source), "--romfs", str(self.image)])
        self.assertEqual(code, 0, out.getvalue())
        answer = json.loads(out.getvalue())
        target = self.games / answer["ipa"].split("/")[-1]
        self.assertEqual((answer["title_id"], answer["nxnative"], answer["bytes"]), (MKW, "a" * 12, target.stat().st_size))

    def test_api_bad_zip_keeps_failure_details(self):
        configs.save(Paths.default(), configs.Config(games=str(self.games)))
        out = io.StringIO()
        with mock.patch.object(api.ipas, "bundle_romfs", side_effect=zipfile.BadZipFile("corrupt archive")):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = api.main(["bundle-romfs", "--ipa", str(self.source), "--romfs", str(self.image)])
        error = json.loads(out.getvalue())["error"]
        self.assertEqual((code, error["kind"], error["exception"]), (3, "failed", "BadZipFile"))
        self.assertTrue(error["where"])

    def test_api_mount_progress_explains_share_address(self):
        configs.save(Paths.default(), configs.Config(games=str(self.games)))
        out, progress = io.StringIO(), io.StringIO()

        def reconnect(paths, known, log):
            log("smb://nas/Games")

        with mock.patch.object(api.shares, "reconnect", side_effect=reconnect):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(progress):
                code = api.main(["bundle-romfs", "--ipa", str(self.source), "--romfs", str(self.image)])
        self.assertEqual(code, 0, out.getvalue())
        self.assertEqual(progress.getvalue().splitlines()[0], "Connecting to smb://nas/Games…")

    def test_api_reports_missing_games_folder(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = api.main(["bundle-romfs", "--ipa", str(self.source), "--romfs", str(self.image)])
        self.assertEqual(code, 3)
        self.assertIn("games folder", json.loads(out.getvalue())["error"]["message"])

    def test_api_refuses_import_during_a_batch(self):
        configs.save(Paths.default(), configs.Config(games=str(self.games)))
        out = io.StringIO()
        with batch.batch_lock(Paths.default()), contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = api.main(["bundle-romfs", "--ipa", str(self.source), "--romfs", str(self.image)])
        self.assertEqual(code, 3)
        self.assertEqual(json.loads(out.getvalue())["error"]["kind"], "busy")
        self.assertEqual(list(self.games.iterdir()), [])

    def test_changing_image_during_copy_keeps_the_original_and_no_partial(self):
        original = self.source.read_bytes()

        def change(message):
            if "Adding" in message:
                self.image.write_bytes(b"changed")

        with self.assertRaisesRegex(ValueError, "changed"):
            ipa.bundle_romfs(self.source, self.image, self.games, progress=change)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(list(self.games.iterdir()), [])

    def test_identity_uses_64_bit_offsets_without_reading_the_game_data(self):
        # Sparse synthetic image: only the header and one root entry occupy
        # disk space. No 4 GiB allocation or game data is involved.
        offset = (1 << 32) + 32
        header = struct.pack("<8sQQQ", b"DMROMFS1", offset, 24, 1)
        root = struct.pack("<QQIHBB", 1, 0, 0, 0, 0, 0)
        with self.image.open("wb") as writer:
            writer.write(header)
            writer.seek(offset)
            writer.write(root)
        with self.image.open("rb") as reader:
            size, digest = romfs.identity(reader)
        self.assertEqual(size, offset + 24)
        self.assertEqual(len(digest), 16)
