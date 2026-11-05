import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from cartouche_server import APP_BUNDLE_ID, guard

from fixtures import (
    CLEAN_MACHO,
    GAME_SECTION_MACHO,
    GAME_SEGMENT_MACHO,
    fat,
    ipa,
    macho,
    tar_gz_bytes,
    zip_bytes,
)


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name: str, data: bytes) -> Path:
        path = self.dir / name
        path.write_bytes(data)
        return path

    def assertAccepted(self, name, data, kind):
        guard.check_file(self.write(name, data), kind, app_bundle_id_expected=APP_BUNDLE_ID)

    def assertRefused(self, name, data, kind, reason):
        with self.assertRaises(guard.Rejected) as caught:
            guard.check_file(self.write(name, data), kind, app_bundle_id_expected=APP_BUNDLE_ID)
        self.assertIn(reason, str(caught.exception))

    # Engine hosts -----------------------------------------------------------

    def test_clean_engine_host(self):
        self.assertAccepted("host", CLEAN_MACHO, "engine-host")
        self.assertAccepted("host-fat", fat(CLEAN_MACHO, CLEAN_MACHO), "engine-host")

    def test_rewritten_game_code_is_refused(self):
        self.assertRefused("host", GAME_SEGMENT_MACHO, "engine-host", "segment __DMmainW")
        self.assertRefused("host", GAME_SECTION_MACHO, "engine-host", "__TEXT,__dmmainx0")
        self.assertRefused("host-fat", fat(CLEAN_MACHO, GAME_SEGMENT_MACHO), "engine-host", "__DMmainW")

    def test_malformed_macho_is_refused(self):
        broken = CLEAN_MACHO[:40]
        self.assertRefused("host", broken, "engine-host", "malformed")

    def test_engine_host_must_be_macho(self):
        self.assertRefused("host.txt", b"hello", "engine-host", "Mach-O")

    def test_java_class_is_not_macho(self):
        self.assertFalse(guard.is_macho(struct.pack(">IHH", 0xCAFEBABE, 0, 52) + b"\0" * 16))

    # Switch formats -----------------------------------------------------------

    def test_switch_magics_are_refused_whatever_the_name(self):
        self.assertRefused("tools.bin", b"PFS0" + b"\0" * 64, "engine-host", "PFS0")
        self.assertRefused("a.bin", b"NSO0" + b"\0" * 64, "engine-host", "NSO")
        self.assertRefused("a.bin", b"\0" * 0x10 + b"NRO0" + b"\0" * 64, "engine-host", "NRO")

    def test_weak_magics_need_a_large_file(self):
        small = b"\0" * 0x100 + b"HEAD" + b"\0" * 16
        guard.check_blob(guard.Blob("small.bin", small))
        large_romfs = struct.pack("<Q", 0x50) + b"\0" * (1 << 20)
        with self.assertRaises(guard.Rejected):
            guard.check_blob(guard.Blob("big.bin", large_romfs))

    def test_names_and_extensions_are_refused(self):
        for name in ("prod.keys", "title.keys", "ROMFS.IMG", "Game [0100000000010000][v0].nsp", "game.xci", "main.nso", "x.keys.txt"):
            with self.subTest(name=name), self.assertRaises(guard.Rejected):
                guard.check_name(name)
        guard.check_name("libpython3.13.dylib")

    # Apps -----------------------------------------------------------------

    def test_cartouche_ipa(self):
        self.assertAccepted("Cartouche.ipa", ipa(), "app")

    def test_other_bundle_id_is_refused(self):
        self.assertRefused("Game.ipa", ipa("com.example.game"), "app", "is not Cartouche's")

    def test_game_inside_an_ipa_is_refused(self):
        self.assertRefused("Cartouche.ipa", ipa(extra={"Payload/LiveContainer.app/romfs.img": b"x"}), "app", "romfs.img")
        self.assertRefused(
            "Cartouche.ipa",
            ipa(extra={"Payload/LiveContainer.app/Frameworks/Game.framework/Game": GAME_SEGMENT_MACHO}),
            "app",
            "__DMmainW",
        )

    def test_nested_archives_are_searched(self):
        inner = zip_bytes({"Payload/x.app/main": b"NSO0" + b"\0" * 64})
        self.assertRefused("Cartouche.ipa", ipa(extra={"Payload/LiveContainer.app/SideBackup.ipa": inner}), "app", "NSO")

    def test_ipa_needs_one_app(self):
        self.assertRefused("x.ipa", zip_bytes({"readme.txt": b"hi"}), "app", "exactly one")

    # Toolchains -----------------------------------------------------------

    def test_toolchain_archives(self):
        self.assertAccepted("python.tar.gz", tar_gz_bytes({"python/lib/libpython.dylib": CLEAN_MACHO}), "toolchain")
        self.assertRefused("python.tar.gz", tar_gz_bytes({"python/keys/prod.keys": b"x"}), "toolchain", "prod.keys")
        self.assertRefused("tool.bin", CLEAN_MACHO, "toolchain", "archive")

    def test_unreadable_archive_is_refused(self):
        self.assertRefused("broken.zip", b"PK\x03\x04garbage", "toolchain", "cannot read")

    # Catalog and pipeline lists ---------------------------------------------

    def test_catalog(self):
        self.assertAccepted("game.json", b'{"titleId": "0400C3F00006E000", "status": "playable"}', "catalog")
        self.assertRefused("game.json", b'{"downloadUrl": "x"}', "catalog", "not allowed")
        self.assertRefused("game.json", b'{"notes": ["see https://example.com"]}', "catalog", "no URLs")
        self.assertRefused("game.json", b"\xff\xfe", "catalog", "not UTF-8 JSON")

    def test_pipeline_list(self):
        self.assertAccepted("pso_manifest.tsv", b"hash\tstate\n0123\tabc\n", "pipeline-list")
        self.assertRefused("pso_manifest.tsv", b"\x00\x01\x02", "pipeline-list", "text")

    # Sizes and kinds ----------------------------------------------------------

    def test_size_limit(self):
        with mock.patch.dict(guard.MAX_SIZE, {"catalog": 8}):
            self.assertRefused("game.json", b'{"a": "0123456789"}', "catalog", "limit")

    def test_unknown_kind(self):
        self.assertRefused("x", b"x", "game", "unknown kind")


if __name__ == "__main__":
    unittest.main()
