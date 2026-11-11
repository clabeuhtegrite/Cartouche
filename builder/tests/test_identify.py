import json
import unittest
from unittest import mock

from cartouche_builder import identify

from support import HEADER_KEY, MKW, ODYSSEY, ZELDA, Home, make_nsp, make_nup, make_xci, nca, write_keys


class Cipher(unittest.TestCase):
    def test_aes_known_answer(self):
        # FIPS 197, appendix C.1.
        aes = identify.AES128(bytes.fromhex("000102030405060708090a0b0c0d0e0f"))
        block = bytes.fromhex("00112233445566778899aabbccddeeff")
        self.assertEqual(aes.encrypt(block).hex(), "69c4e0d86a7b0430d8cdb78070b4c55a")
        self.assertEqual(aes.decrypt(bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a")), block)

    def test_xts_known_answers(self):
        # IEEE 1619, vectors 1 and 2 (the data unit number little-endian there).
        self.assertEqual(identify.xts_decrypt(bytes(16), bytes(16), bytes(16), bytes.fromhex(
            "917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e")), bytes(32))
        self.assertEqual(identify.xts_decrypt(bytes([0x11] * 16), bytes([0x22] * 16), (0x3333333333).to_bytes(16, "little"), bytes.fromhex(
            "c454185e6a16936e39334038acef838bfb186fff7480adc4289382ecd6d394f0")), bytes([0x44] * 32))
        # An NCA header's sector 1 under Nintendo's big-endian tweak, as
        # Python's cryptography package encrypts it.
        plain = identify.xts_decrypt(HEADER_KEY[:16], HEADER_KEY[16:], identify.nintendo_tweak(1), bytes.fromhex(
            "a37b2d113cdce529b090b5878fc9c035c5ed0bdfef829d220ca9e21164f0f15d"))
        self.assertEqual(plain.hex(), "4e43413300010000000000000000000000000100000000010000000000000000")

    def test_header_key(self):
        path = write_keys(self.tmp_path())
        self.assertEqual(identify.header_key(path), HEADER_KEY)
        path.write_text("header_key = short\n")
        self.assertIsNone(identify.header_key(path))
        self.assertIsNone(identify.header_key(None))

    def tmp_path(self):
        import tempfile
        from pathlib import Path

        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        return Path(folder.name) / "prod.keys"


class Files(Home):
    def test_nup(self):
        path = make_nup(self.tmp / "game.nup", [(MKW, 0), ("0400C3F00006E800", 1), ("0400C3F00006F001", 2)])
        self.assertEqual(identify.game_of(identify.nup_title_ids(path)), MKW)
        # An update packed alone: a base record without its ID.
        path = make_nup(self.tmp / "update.nup", [("0000000000000000", 0), ("0400C3F00006E800", 1)])
        self.assertEqual(identify.game_of(identify.nup_title_ids(path)), MKW)
        (self.tmp / "cut.nup").write_bytes(path.read_bytes()[:0x90])
        with self.assertRaises(identify.Unreadable):
            identify.nup_title_ids(self.tmp / "cut.nup")

    def test_nsp_by_its_ticket_without_keys(self):
        path = make_nsp(self.tmp / "game.nsp", [
            (f"{ODYSSEY.lower()}0000000000000005.tik", b"ticket"),
            ("0123456789abcdef0123456789abcdef.nca", b"\0" * 0x400),
        ])
        self.assertEqual(identify.package_title_ids(path, None), [ODYSSEY])

    def test_nsp_without_a_ticket_needs_the_keys(self):
        path = make_nsp(self.tmp / "game.nsp", [
            ("00000000000000000000000000000001.cnmt.nca", nca(1, "0100000000010800")),
            ("00000000000000000000000000000002.nca", nca(0, "0100000000010800")),
        ])
        with self.assertRaises(identify.NeedsKeys):
            identify.package_title_ids(path, None)
        self.assertEqual(identify.package_title_ids(path, HEADER_KEY), ["0100000000010800"])
        self.assertEqual(identify.game_of(identify.package_title_ids(path, HEADER_KEY)), ODYSSEY)
        with self.assertRaises(identify.Unreadable):
            identify.package_title_ids(path, bytes(32))  # another console's keys

    def test_xci(self):
        path = make_xci(self.tmp / "ZELDA.XCI", [ZELDA, "01007EF00011E800"])
        self.assertEqual(identify.game_of(identify.package_title_ids(path, HEADER_KEY)), ZELDA)
        with self.assertRaises(identify.NeedsKeys):
            identify.package_title_ids(path, None)
        two = make_xci(self.tmp / "two.xci", [ZELDA, ODYSSEY])
        with self.assertRaises(identify.Unreadable):
            identify.game_of(identify.package_title_ids(two, HEADER_KEY))

    def test_neither(self):
        path = self.tmp / "game.nsp"
        path.write_bytes(b"not a package at all" * 20)
        with self.assertRaises(identify.Unreadable):
            identify.package_title_ids(path, HEADER_KEY)

    def test_cache_reads_each_file_once(self):
        keys = write_keys(self.tmp / "prod.keys")
        cache = self.tmp / "identified.json"
        path = make_xci(self.tmp / "zelda.xci", [ZELDA])
        self.assertEqual(identify.Reader(keys, cache).ids(path), [ZELDA])
        reader = identify.Reader(keys, cache)
        reader.ids(path)
        reader.save()
        with mock.patch.object(identify, "package_title_ids", side_effect=AssertionError("read again")):
            self.assertEqual(identify.Reader(keys, cache).ids(path), [ZELDA])
        # Without the keys first, then with them: read again once they are there.
        other = make_xci(self.tmp / "other.xci", [ODYSSEY])
        without = identify.Reader(None, cache)
        with self.assertRaises(identify.NeedsKeys):
            without.ids(other)
        without.save()
        self.assertTrue(json.loads(cache.read_text())["files"][str(other)]["needs_keys"])
        self.assertNotIn(str(path), json.loads(cache.read_text())["files"])  # not looked at: forgotten
        self.assertEqual(identify.Reader(keys, cache).ids(other), [ODYSSEY])


if __name__ == "__main__":
    unittest.main()
