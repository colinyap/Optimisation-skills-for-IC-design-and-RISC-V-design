#!/usr/bin/env python3
"""
gen_vectors.py -- generate machine-verified known-answer vectors.

Hand-written expected values are one of the most expensive mistakes available
in RTL verification: a wrong vector makes a *correct* implementation look
broken, and the hours go into debugging working hardware. Generate them.

  python3 gen_vectors.py --all                 # markdown tables for docs
  python3 gen_vectors.py --mul --format verilog > mul_vectors.vh
  python3 gen_vectors.py --crc --poly 0x82F63B78    # CRC-32C instead

Emitting `--format verilog` produces `$readmemh`-compatible vector files that a
testbench can loop over, which keeps the documentation and the testbench from
drifting apart.
"""

import argparse
import sys

MASK32 = 0xFFFFFFFF
CRC_POLY_ISO = 0xEDB88320       # CRC-32/ISO-HDLC (zlib, Ethernet), reflected
CRC_POLY_C = 0x82F63B78         # CRC-32C (Castagnoli), reflected


def sx(v):
    return v - (1 << 32) if v >> 31 else v


# --------------------------------------------------------------------------
def mul_vectors():
    """The corner cases that distinguish MUL / MULH / MULHSU / MULHU."""
    pairs = [(0, 0), (1, 1), (MASK32, MASK32),
             (0x80000000, 0x80000000), (0x80000000, MASK32),
             (0x7FFFFFFF, 0x7FFFFFFF), (MASK32, 1),
             (0x00010001, 0x00010001), (0xDEADBEEF, 0xCAFEBABE)]
    rows = []
    for a, b in pairs:
        rows.append((a, b,
                     (sx(a) * sx(b)) & MASK32,          # MUL
                     ((sx(a) * sx(b)) >> 32) & MASK32,  # MULH
                     ((sx(a) * b) >> 32) & MASK32,      # MULHSU
                     ((a * b) >> 32) & MASK32))         # MULHU
    return rows


def crc_byte(crc, byte, poly):
    c = (crc ^ (byte & 0xFF)) & MASK32
    for _ in range(8):
        c = ((c >> 1) ^ (poly & -(c & 1))) & MASK32
    return c


def crc_vectors(poly):
    cases = [(0x00000000, 0x00), (0x00000000, 0x01), (0x00000000, 0xFF),
             (0xFFFFFFFF, 0x00), (0xFFFFFFFF, 0x31), (0xFFFFFFFF, 0xFF),
             (0x12345678, 0xA5)]
    return [(c, d, crc_byte(c, d, poly)) for c, d in cases]


def crc_check(poly, init=0xFFFFFFFF, xorout=0xFFFFFFFF):
    """The published check value: CRC over the nine bytes '123456789'."""
    c = init
    for ch in b"123456789":
        c = crc_byte(c, ch, poly)
    return c ^ xorout


def crc_chain_property(poly):
    """CRC.W over a word must equal four chained CRC.B, low byte first."""
    word = 0x34333231
    w = 0xFFFFFFFF
    for i in range(4):
        w = crc_byte(w, (word >> (8 * i)) & 0xFF, poly)
    b = 0xFFFFFFFF
    for byte in [0x31, 0x32, 0x33, 0x34]:
        b = crc_byte(b, byte, poly)
    return word, w, b, (w == b)


# --------------------------------------------------------------------------
def imm_vectors():
    """Encoded instruction -> expected immediate, computed by field extraction."""
    def i_imm(x): return sx_n((x >> 20) & 0xFFF, 12)
    def s_imm(x): return sx_n((((x >> 25) & 0x7F) << 5) | ((x >> 7) & 0x1F), 12)
    def b_imm(x): return sx_n((((x >> 31) & 1) << 12) | (((x >> 7) & 1) << 11) |
                              (((x >> 25) & 0x3F) << 5) | (((x >> 8) & 0xF) << 1), 13)
    def u_imm(x): return x & 0xFFFFF000
    def j_imm(x): return sx_n((((x >> 31) & 1) << 20) | (((x >> 12) & 0xFF) << 12) |
                              (((x >> 20) & 1) << 11) | (((x >> 21) & 0x3FF) << 1), 21)

    def sx_n(v, bits):
        m = 1 << (bits - 1)
        return ((v ^ m) - m) & MASK32

    cases = [
        (0xFFF00093, "addi x1, x0, -1",      "I", i_imm),
        (0x80000093, "addi x1, x0, -2048",   "I", i_imm),
        (0x7FF00093, "addi x1, x0, 2047",    "I", i_imm),
        (0xFE112E23, "sw x1, -4(x2)",        "S", s_imm),
        (0xFE000EE3, "beq x0, x0, -4",       "B", b_imm),
        (0x00000063, "beq x0, x0, 0",        "B", b_imm),
        (0xFFFFF0B7, "lui x1, 0xFFFFF",      "U", u_imm),
        (0xFFDFF06F, "jal x0, -4",           "J", j_imm),
    ]
    return [(w, asm, fmt, fn(w) & MASK32) for w, asm, fmt, fn in cases]


# --------------------------------------------------------------------------
def emit_mul(fmt):
    rows = mul_vectors()
    if fmt == "verilog":
        print("// a b MUL MULH MULHSU MULHU")
        for r in rows:
            print(" ".join("%08x" % v for v in r))
        return
    print("| a | b | MUL | MULH | MULHSU | MULHU |")
    print("|---|---|---|---|---|---|")
    for r in rows:
        print("| " + " | ".join("`%08X`" % v for v in r) + " |")


def emit_crc(poly, fmt):
    rows = crc_vectors(poly)
    if fmt == "verilog":
        print("// crc_in data crc_out   (poly=%08x)" % poly)
        for c, d, o in rows:
            print("%08x %02x %08x" % (c, d, o))
        return
    print("Polynomial (reflected): `%08X`" % poly)
    print()
    print("| crc_in | data | crc_out |")
    print("|---|---|---|")
    for c, d, o in rows:
        print("| `%08X` | `%02X` | `%08X` |" % (c, d, o))
    print()
    print("Check value over `\"123456789\"` (init FFFFFFFF, final XOR FFFFFFFF): "
          "`%08X`" % crc_check(poly))
    word, w, b, ok = crc_chain_property(poly)
    print("Chain property: CRC.W(`%08X`) = `%08X`, four chained CRC.B = `%08X` -> %s"
          % (word, w, b, "AGREE" if ok else "DISAGREE"))


def emit_imm(fmt):
    rows = imm_vectors()
    if fmt == "verilog":
        print("// instr expected_imm")
        for w, _, _, e in rows:
            print("%08x %08x" % (w, e))
        return
    print("| instr (hex) | asm | format | expected immediate |")
    print("|---|---|---|---|")
    for w, asm, f, e in rows:
        print("| `%08X` | `%s` | %s | `0x%08X` |" % (w, asm, f, e))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--mul', action='store_true')
    ap.add_argument('--crc', action='store_true')
    ap.add_argument('--imm', action='store_true')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--poly', default=hex(CRC_POLY_ISO))
    ap.add_argument('--format', choices=['markdown', 'verilog'], default='markdown')
    a = ap.parse_args()

    if not (a.mul or a.crc or a.imm or a.all):
        ap.print_help()
        return 1

    if a.all or a.imm:
        if a.format == 'markdown':
            print("### Immediate generation vectors\n")
        emit_imm(a.format)
        print()
    if a.all or a.mul:
        if a.format == 'markdown':
            print("### Multiplier corner vectors\n")
        emit_mul(a.format)
        print()
    if a.all or a.crc:
        if a.format == 'markdown':
            print("### CRC vectors\n")
        emit_crc(int(a.poly, 0), a.format)
        if a.all and a.format == 'markdown':
            print()
            emit_crc(CRC_POLY_C, a.format)
    return 0


if __name__ == '__main__':
    sys.exit(main())
