"""Checks the pure-Python LZ4 decoder that the spike S2 app carries for iOS
(engine/spikes/s2/ios/lz4) against the lz4 package nxnative uses on a Mac.

Needs the lz4 package: python3 -m pip install lz4
Run from the repository root: python3 -m unittest discover -s engine/spikes/s2/tests -v
"""

import importlib.util
import os
import random
import sys
import unittest
from pathlib import Path

import lz4.block as reference

SHIM = Path(__file__).resolve().parents[1] / "ios" / "lz4" / "block.py"
spec = importlib.util.spec_from_file_location("lz4_shim_block", SHIM)
shim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shim)


def samples():
    rng = random.Random(0x5A)
    yield b""
    yield b"a"
    yield b"abcd" * 3
    yield bytes(70000)                                   # one long overlapping match
    yield os.urandom(5000)                               # literals only
    yield bytes(rng.randrange(4) for _ in range(100000))  # short matches everywhere
    code = bytearray()
    for _ in range(20000):                               # instruction-like words with repeats
        code += rng.choice([b"\x1f\x20\x03\xd5", b"\xc0\x03\x5f\xd6", rng.randbytes(4)])
    yield bytes(code)
    yield b"".join(bytes([k]) * rng.randrange(1, 600) for k in range(256))   # lengths past 255


class LZ4ShimTest(unittest.TestCase):
    def test_it_decodes_what_lz4_encodes(self):
        for index, data in enumerate(samples()):
            for mode in ("default", "high_compression"):
                with self.subTest(sample=index, mode=mode):
                    packed = reference.compress(data, mode=mode, store_size=False)
                    self.assertEqual(shim.decompress(packed, uncompressed_size=len(data)), data)

    def test_it_agrees_with_lz4_on_a_short_or_damaged_stream(self):
        data = bytes(range(256)) * 64
        packed = reference.compress(data, store_size=False)
        # A buffer too small is an error for both.
        with self.assertRaises(reference.LZ4BlockError):
            reference.decompress(packed, uncompressed_size=len(data) - 1)
        with self.assertRaises(shim.LZ4BlockError):
            shim.decompress(packed, uncompressed_size=len(data) - 1)
        # An offset before the start of the output is an error for both.
        bad = bytes([0x1F, 0x41, 0xFF, 0xFF])
        with self.assertRaises(reference.LZ4BlockError):
            reference.decompress(bad, uncompressed_size=100)
        with self.assertRaises(shim.LZ4BlockError):
            shim.decompress(bad, uncompressed_size=100)

    def test_it_returns_bytes_or_a_bytearray(self):
        packed = reference.compress(b"abc" * 10, store_size=False)
        self.assertIsInstance(shim.decompress(packed, uncompressed_size=30), bytes)
        self.assertIsInstance(shim.decompress(packed, uncompressed_size=30, return_bytearray=True), bytearray)


if __name__ == "__main__":
    unittest.main()
