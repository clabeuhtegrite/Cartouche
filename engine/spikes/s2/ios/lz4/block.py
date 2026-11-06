"""lz4.block.decompress() and LZ4BlockError, in pure Python.

It decodes the LZ4 block format (https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md)
as LZ4_decompress_safe() does for lz4.block.decompress(source, uncompressed_size=n):
corrupt input raises LZ4BlockError, and so does output that would not fit
in n bytes, but a stream that ends early returns what it decoded, which
nso.py then checks against the segment's size.
"""


class LZ4BlockError(Exception):
    pass


def _length(src, i, n, length):
    """A length of 15 continues in the bytes that follow, while they are 255."""
    if length == 15:
        while True:
            if i >= n:
                raise LZ4BlockError("Decompression failed: corrupt input (length past the end)")
            extra = src[i]
            i += 1
            length += extra
            if extra != 255:
                break
    return length, i


def decompress(source, uncompressed_size=-1, return_bytearray=False, dict=None):
    if uncompressed_size < 0:
        raise LZ4BlockError("this decoder needs uncompressed_size: the size stored before the block is not read")
    if dict:
        raise LZ4BlockError("this decoder takes no dictionary")
    src = memoryview(source).cast("B")
    n = len(src)
    out = bytearray()
    i = 0
    while i < n:
        token = src[i]
        i += 1
        literals, i = _length(src, i, n, token >> 4)
        if i + literals > n:
            raise LZ4BlockError("Decompression failed: corrupt input (literals past the end)")
        out += src[i:i + literals]
        i += literals
        if i == n:
            break   # the last sequence holds only literals
        if i + 2 > n:
            raise LZ4BlockError("Decompression failed: corrupt input (offset past the end)")
        offset = src[i] | src[i + 1] << 8
        i += 2
        if offset == 0 or offset > len(out):
            raise LZ4BlockError(f"Decompression failed: corrupt input (offset {offset} before the start)")
        match, i = _length(src, i, n, token & 15)
        match += 4
        start = len(out) - offset
        if match <= offset:
            out += out[start:start + match]
        else:   # the match overlaps what it copies: its bytes repeat every offset bytes
            pattern = out[start:]
            whole, rest = divmod(match, offset)
            out += pattern * whole + pattern[:rest]
        if len(out) > uncompressed_size:
            raise LZ4BlockError("Decompression failed: insufficient space in destination buffer")
    if len(out) > uncompressed_size:
        raise LZ4BlockError("Decompression failed: insufficient space in destination buffer")
    return out if return_bytearray else bytes(out)
