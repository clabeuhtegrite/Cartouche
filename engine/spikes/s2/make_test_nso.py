#!/usr/bin/env python3
"""Synthetic Switch modules for spike S2: no game code, only a few functions
built here that use what nxnative's rewriter (patch_nso.py) rewrites.

Each module has what the rewriter reads from a real one: the branch and the
MOD0 offset at the start of text, a MOD0 header, and an eh_frame_hdr that
lists the functions. main.nso stores its segments as they are; subsdk0.nso
and sdk.nso compress them with LZ4, as retail modules are, so that the iOS
run also goes through the LZ4 decoder. All of them check each segment's
SHA-256. sdk.nso has more than a megabyte of text, with a second copy of the
functions past the first megabyte: the rewriter scans the text in pieces of
a megabyte, in worker processes where it can fork (a Mac) and in its own
process where it cannot (iOS), and both must write the same files.

usage: make_test_nso.py OUTPUT_DIR   (needs the lz4 package: pip install lz4)
"""

import hashlib
import struct
import sys
from pathlib import Path

import lz4.block

PAGE = 0x1000
RET, NOP = 0xD65F03C0, 0xD503201F

# (offset in text, instruction words): what each one rewrites
FUNCTIONS = [
    (0x100, [0xD53BD040, RET]),                          # mrs x0, tpidr_el0: thread pointer read
    (0x140, [0xD51BD040, RET]),                          # msr tpidr_el0, x0: thread pointer write
    (0x180, [0xD53BD060, RET]),                          # mrs x0, tpidrro_el0: thread local region
    (0x1C0, [0xD40000E1, RET]),                          # svc #7: a supervisor call, through the host gate
    (0x200, [0xD53BE020, RET]),                          # mrs x0, cntpct_el0: the counter, through the host gate
    (0x240, [0xAA1203E0, RET]),                          # mov x0, x18: x18 read
    (0x280, [0xF9400240, RET]),                          # ldr x0, [x18]: x18 as a base
    (0x2C0, [0xCB2163FF, 0x8B2163FF, RET]),              # sub sp, sp, x1; add sp, sp, x1: sp kept aligned
    (0x300, [0x885F7C02, 0x35FFFFE2, 0x88037C01,         # ldxr w2, [x0]; cbnz w2, -4; stxr w3, w1, [x0];
             0x35FFFFA3, RET]),                          # cbnz w3, -12: a lock taken without acquire ordering
    (0x340, [0xD2800020, 0x8B000000, RET]),              # mov x0, #1; add x0, x0, x0: nothing to rewrite
]

MEGABYTE = 0x100000              # the rewriter's x18 scan works in pieces of this size


def layout(text_size):
    """Where ro's MOD0 header, eh_frame_hdr, eh_frame, the dynamic section and
    bss are, for a text segment of this size: ro starts right after text."""
    ro = text_size
    return {"MOD0": ro, "EH_FRAME_HDR": ro + 0x100, "EH_FRAME": ro + 0x200,
            "DYNAMIC": ro + PAGE, "BSS": ro + 2 * PAGE, "BSS_END": ro + 3 * PAGE}


def functions(text_size):
    """FUNCTIONS, and again past each megabyte of text that has room for them."""
    return [(base + offset, words) for base in range(0, text_size - PAGE + 1, MEGABYTE) for offset, words in FUNCTIONS]


def segments(text_size=PAGE):
    at = layout(text_size)
    text = bytearray(text_size)
    struct.pack_into("<I", text, 0, 0x14000000 | (0x100 // 4))   # b 0x100
    struct.pack_into("<I", text, 4, at["MOD0"])
    for offset in range(8, text_size, 4):
        struct.pack_into("<I", text, offset, NOP)
    for offset, words in functions(text_size):
        for index, word in enumerate(words):
            struct.pack_into("<I", text, offset + 4 * index, word)

    ro = bytearray(PAGE)
    mod0, eh_frame_hdr, eh_frame = at["MOD0"], at["EH_FRAME_HDR"], at["EH_FRAME"]
    struct.pack_into("<4s6i", ro, 0, b"MOD0", at["DYNAMIC"] - mod0, at["BSS"] - mod0, at["BSS_END"] - mod0,
                     eh_frame_hdr - mod0, eh_frame - mod0, at["BSS"] - mod0)
    # version 1; eh_frame_ptr pc-relative sdata4, count udata4, table relative to the header sdata4
    header = bytearray([1, 0x1B, 0x03, 0x3B])
    header += struct.pack("<i", eh_frame - (eh_frame_hdr + 4))
    header += struct.pack("<I", len(functions(text_size)))
    for index, (offset, _) in enumerate(functions(text_size)):
        header += struct.pack("<ii", offset - eh_frame_hdr, eh_frame + 0x20 * index - eh_frame_hdr)
    assert len(header) <= eh_frame - eh_frame_hdr, "eh_frame_hdr runs into eh_frame"
    start = eh_frame_hdr - mod0
    ro[start:start + len(header)] = header

    data = bytearray(PAGE)                          # an empty dynamic section: DT_NULL
    return [bytes(text), bytes(ro), bytes(data)]


def nso(name, compress, text_size=PAGE):
    plain = segments(text_size)
    stored = [lz4.block.compress(segment, store_size=False) if compress else segment for segment in plain]
    at = layout(text_size)
    header = bytearray(0x100)
    header[0:4] = b"NSO0"
    flags = 0b111000 | (0b111 if compress else 0)   # SHA-256 checked; LZ4 when compressed
    struct.pack_into("<I", header, 0xC, flags)
    file_offset = 0x100
    for index, (segment, data, memory) in enumerate(zip(plain, stored, (0, text_size, text_size + PAGE))):
        struct.pack_into("<III", header, 0x10 + 0x10 * index, file_offset, memory, len(segment))
        struct.pack_into("<I", header, 0x60 + 4 * index, len(data))
        header[0xA0 + 0x20 * index:0xC0 + 0x20 * index] = hashlib.sha256(segment).digest()
        file_offset += len(data)
    struct.pack_into("<I", header, 0x3C, at["BSS_END"] - at["BSS"])
    header[0x40:0x60] = hashlib.sha256(f"Cartouche spike S2 {name}".encode()).digest()   # build ID
    return bytes(header) + b"".join(stored)


def main(argv):
    out = Path(argv[1])
    out.mkdir(parents=True, exist_ok=True)
    (out / "main.nso").write_bytes(nso("main", compress=False))
    (out / "subsdk0.nso").write_bytes(nso("subsdk0", compress=True))
    (out / "sdk.nso").write_bytes(nso("sdk", compress=True, text_size=MEGABYTE + 0x10000))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
