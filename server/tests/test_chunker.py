import io
import random
import unittest

from cartouche_server.chunker import DEFAULT, Params, chunk_bytes, chunk_stream

SMALL = Params(min_size=256, avg_size=1024, max_size=4096)


def random_bytes(size: int, seed: int) -> bytes:
    return random.Random(seed).randbytes(size)


class ChunkerTest(unittest.TestCase):
    def test_chunks_rebuild_the_input(self):
        data = random_bytes(200_000, 1)
        chunks = [bytes(c) for c in chunk_bytes(data, SMALL)]
        self.assertEqual(b"".join(chunks), data)

    def test_sizes_stay_within_bounds(self):
        data = random_bytes(300_000, 2)
        sizes = [len(c) for c in chunk_bytes(data, SMALL)]
        self.assertTrue(all(SMALL.min_size <= s <= SMALL.max_size for s in sizes[:-1]))
        self.assertLessEqual(sizes[-1], SMALL.max_size)
        average = sum(sizes) / len(sizes)
        self.assertGreater(average, SMALL.min_size)
        self.assertLess(average, SMALL.max_size)

    def test_boundaries_are_deterministic(self):
        data = random_bytes(100_000, 3)
        first = [len(c) for c in chunk_bytes(data, SMALL)]
        second = [len(c) for c in chunk_bytes(data, SMALL)]
        self.assertEqual(first, second)

    def test_stream_matches_bytes(self):
        data = random_bytes(150_000, 4)
        from_bytes = [bytes(c) for c in chunk_bytes(data, SMALL)]
        from_stream = list(chunk_stream(io.BytesIO(data), SMALL))
        self.assertEqual(from_bytes, from_stream)

    def test_an_insertion_keeps_most_chunks(self):
        data = random_bytes(400_000, 5)
        edited = data[:200_000] + b"inserted bytes" + data[200_000:]
        before = {bytes(c) for c in chunk_bytes(data, SMALL)}
        after = [bytes(c) for c in chunk_bytes(edited, SMALL)]
        shared = sum(1 for c in after if c in before)
        self.assertGreaterEqual(shared, len(after) - 3)

    def test_small_and_empty_inputs(self):
        self.assertEqual(list(chunk_bytes(b"", SMALL)), [])
        self.assertEqual([bytes(c) for c in chunk_bytes(b"abc", SMALL)], [b"abc"])
        self.assertEqual(list(chunk_stream(io.BytesIO(b""), SMALL)), [])

    def test_bad_parameters(self):
        with self.assertRaises(ValueError):
            Params(min_size=10, avg_size=1000, max_size=4096)  # average not a power of two
        with self.assertRaises(ValueError):
            Params(min_size=4096, avg_size=1024, max_size=8192)

    def test_default_parameters(self):
        self.assertEqual((DEFAULT.min_size, DEFAULT.avg_size, DEFAULT.max_size), (1 << 20, 1 << 22, 1 << 23))


if __name__ == "__main__":
    unittest.main()
