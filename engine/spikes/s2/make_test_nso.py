#!/usr/bin/env python3
"""Synthetic Switch modules for spike S2: no game code, only a few functions
built here that use what nxnative's rewriter (patch_nso.py) rewrites.

Each module has what the rewriter reads from a real one: the branch and the
MOD0 offset at the start of text, a MOD0 header, and an eh_frame_hdr that
lists the functions. main.nso stores its segments as they are; subsdk0.nso
compresses them with LZ4, as retail modules are, so that the iOS run also
goes through the LZ4 decoder. Both check each segment's SHA-256.

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

MOD0 = 0x1000                     # at the start of ro
EH_FRAME_HDR, EH_FRAME = 0x1100, 0x1200
DYNAMIC, BSS, BSS_END = 0x2000, 0x3000, 0x4000


def segments():
    text = bytearray(PAGE)
    struct.pack_into("<I", text, 0, 0x14000000 | (0x100 // 4))   # b 0x100
    struct.pack_into("<I", text, 4, MOD0)
    for offset in range(8, PAGE, 4):
        struct.pack_into("<I", text, offset, NOP)
    for offset, words in FUNCTIONS:
        for index, word in enumerate(words):
            struct.pack_into("<I", text, offset + 4 * index, word)

    ro = bytearray(PAGE)
    struct.pack_into("<4s6i", ro, 0, b"MOD0", DYNAMIC - MOD0, BSS - MOD0, BSS_END - MOD0,
                     EH_FRAME_HDR - MOD0, EH_FRAME - MOD0, BSS - MOD0)
    # version 1; eh_frame_ptr pc-relative sdata4, count udata4, table relative to the header sdata4
    header = bytearray([1, 0x1B, 0x03, 0x3B])
    header += struct.pack("<i", EH_FRAME - (EH_FRAME_HDR + 4))
    header += struct.pack("<I", len(FUNCTIONS))
    for index, (offset, _) in enumerate(FUNCTIONS):
        header += struct.pack("<ii", offset - EH_FRAME_HDR, EH_FRAME + 0x20 * index - EH_FRAME_HDR)
    start = EH_FRAME_HDR - PAGE
    ro[start:start + len(header)] = header

    data = bytearray(PAGE)                          # an empty dynamic section: DT_NULL
    return [bytes(text), bytes(ro), bytes(data)]


def nso(name, compress):
    stored = [lz4.block.compress(segment, store_size=False) if compress else segment for segment in segments()]
    header = bytearray(0x100)
    header[0:4] = b"NSO0"
    flags = 0b111000 | (0b111 if compress else 0)   # SHA-256 checked; LZ4 when compressed
    struct.pack_into("<I", header, 0xC, flags)
    file_offset = 0x100
    for index, (segment, data) in enumerate(zip(segments(), stored)):
        struct.pack_into("<III", header, 0x10 + 0x10 * index, file_offset, index * PAGE, len(segment))
        struct.pack_into("<I", header, 0x60 + 4 * index, len(data))
        header[0xA0 + 0x20 * index:0xC0 + 0x20 * index] = hashlib.sha256(segment).digest()
        file_offset += len(data)
    struct.pack_into("<I", header, 0x3C, BSS_END - BSS)
    header[0x40:0x60] = hashlib.sha256(f"Cartouche spike S2 {name}".encode()).digest()   # build ID
    return bytes(header) + b"".join(stored)


def main(argv):
    out = Path(argv[1])
    out.mkdir(parents=True, exist_ok=True)
    (out / "main.nso").write_bytes(nso("main", compress=False))
    (out / "subsdk0.nso").write_bytes(nso("subsdk0", compress=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
