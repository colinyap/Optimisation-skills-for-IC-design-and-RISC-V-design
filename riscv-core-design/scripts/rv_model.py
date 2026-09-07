#!/usr/bin/env python3
"""
rv_model.py -- RV32I + M(multiply) + custom CRC golden model, assembler, and
hex-image builder.

This is the ORACLE. Build it before the RTL, validate it against riscv-tests or
Spike, then diff its trace against the RTL's trace to localize core bugs to a
single instruction.

Usage
-----
  # assemble to a $readmemh image
  python3 rv_model.py --asm prog.s --hex prog.hex

  # execute an image and emit the retire trace (the thing you diff)
  python3 rv_model.py --trace prog.hex

  # both at once
  python3 rv_model.py --asm prog.s --hex prog.hex --trace prog.hex

  # dump final architectural state
  python3 rv_model.py --run prog.hex --dump-regs

Trace format -- keep the RTL testbench emitting exactly this:
  PPPPPPPP IIIIIIII xN=VVVVVVVV
  (pc, instruction word, destination register and value; x0=00000000 when the
   instruction writes no register)

Customize
---------
CUSTOM_OPCODE / the crc_* entries in R_TYPE and the crc_update() function are
this skill's default CRC extension. Replace them with the project's actual
encoding and semantics -- that is a three-line change here and it keeps the
model, the assembler, and the RTL in agreement.
"""

import argparse
import re
import sys

MASK32 = 0xFFFFFFFF

# --------------------------------------------------------------------------
# Encoding tables
# --------------------------------------------------------------------------
OPC = {
    'lui': 0x37, 'auipc': 0x17, 'jal': 0x6F, 'jalr': 0x67, 'branch': 0x63,
    'load': 0x03, 'store': 0x23, 'op_imm': 0x13, 'op': 0x33,
    'fence': 0x0F, 'system': 0x73,
}
CUSTOM_OPCODE = 0x0B                       # custom-0; override per project spec

# name -> (funct3, funct7)
R_TYPE = {
    'add': (0x0, 0x00), 'sub': (0x0, 0x20), 'sll': (0x1, 0x00),
    'slt': (0x2, 0x00), 'sltu': (0x3, 0x00), 'xor': (0x4, 0x00),
    'srl': (0x5, 0x00), 'sra': (0x5, 0x20), 'or': (0x6, 0x00),
    'and': (0x7, 0x00),
    'mul': (0x0, 0x01), 'mulh': (0x1, 0x01),
    'mulhsu': (0x2, 0x01), 'mulhu': (0x3, 0x01),
}
CRC_TYPE = {'crc.b': 0x0, 'crc.h': 0x1, 'crc.w': 0x2}
I_ARITH = {'addi': 0x0, 'slti': 0x2, 'sltiu': 0x3, 'xori': 0x4,
           'ori': 0x6, 'andi': 0x7}
I_SHIFT = {'slli': (0x1, 0x00), 'srli': (0x5, 0x00), 'srai': (0x5, 0x20)}
LOADS = {'lb': 0x0, 'lh': 0x1, 'lw': 0x2, 'lbu': 0x4, 'lhu': 0x5}
STORES = {'sb': 0x0, 'sh': 0x1, 'sw': 0x2}
BRANCH = {'beq': 0x0, 'bne': 0x1, 'blt': 0x4, 'bge': 0x5,
          'bltu': 0x6, 'bgeu': 0x7}

ABI = {
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
    't0': 5, 't1': 6, 't2': 7, 's0': 8, 'fp': 8, 's1': 9,
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15,
    'a6': 16, 'a7': 17,
    's2': 18, 's3': 19, 's4': 20, 's5': 21, 's6': 22, 's7': 23,
    's8': 24, 's9': 25, 's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31,
}
ABI_NAME = ['zero', 'ra', 'sp', 'gp', 'tp', 't0', 't1', 't2',
            's0', 's1', 'a0', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7',
            's2', 's3', 's4', 's5', 's6', 's7', 's8', 's9', 's10', 's11',
            't3', 't4', 't5', 't6']


def reg(tok):
    t = tok.strip().lower()
    if t in ABI:
        return ABI[t]
    if t.startswith('x') and t[1:].isdigit():
        n = int(t[1:])
        if 0 <= n < 32:
            return n
    raise ValueError("bad register: %r" % tok)


# --------------------------------------------------------------------------
# Field packers -- also usable standalone to hand-encode a custom instruction
# --------------------------------------------------------------------------
def r_type(opcode, funct3, funct7, rd, rs1, rs2):
    return ((funct7 & 0x7F) << 25 | (rs2 & 0x1F) << 20 | (rs1 & 0x1F) << 15 |
            (funct3 & 0x7) << 12 | (rd & 0x1F) << 7 | (opcode & 0x7F))


def i_type(opcode, funct3, rd, rs1, imm):
    return ((imm & 0xFFF) << 20 | (rs1 & 0x1F) << 15 | (funct3 & 0x7) << 12 |
            (rd & 0x1F) << 7 | (opcode & 0x7F))


def s_type(opcode, funct3, rs1, rs2, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25 | (rs2 & 0x1F) << 20 | (rs1 & 0x1F) << 15 |
            (funct3 & 0x7) << 12 | (imm & 0x1F) << 7 | (opcode & 0x7F))


def b_type(opcode, funct3, rs1, rs2, imm):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31 | ((imm >> 5) & 0x3F) << 25 |
            (rs2 & 0x1F) << 20 | (rs1 & 0x1F) << 15 | (funct3 & 0x7) << 12 |
            ((imm >> 1) & 0xF) << 8 | ((imm >> 11) & 1) << 7 | (opcode & 0x7F))


def u_type(opcode, rd, imm):
    return ((imm & 0xFFFFF) << 12 | (rd & 0x1F) << 7 | (opcode & 0x7F))


def j_type(opcode, rd, imm):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3FF) << 21 |
            ((imm >> 11) & 1) << 20 | ((imm >> 12) & 0xFF) << 12 |
            (rd & 0x1F) << 7 | (opcode & 0x7F))


# --------------------------------------------------------------------------
# Assembler
# --------------------------------------------------------------------------
MEMOP_RE = re.compile(r'^\s*(-?\w+)\s*\(\s*(\w+)\s*\)\s*$')


class Assembler(object):
    """Two-pass assembler: pass 1 resolves labels, pass 2 emits words."""

    def __init__(self, base=0):
        self.base = base
        self.labels = {}

    def _imm(self, tok):
        t = tok.strip()
        if t in self.labels:
            return self.labels[t]
        try:
            return int(t, 0)
        except ValueError:
            raise ValueError("unresolved symbol or bad immediate: %r" % t)

    @staticmethod
    def _split(line):
        line = line.split('#')[0].split('//')[0].strip()
        if not line:
            return None, []
        parts = line.replace(',', ' ').split()
        return parts[0].lower(), parts[1:]

    def _expand(self, op, args):
        """Pseudo-instruction expansion. Returns a list of (op, args)."""
        if op == 'nop':
            return [('addi', ['x0', 'x0', '0'])]
        if op == 'mv':
            return [('addi', [args[0], args[1], '0'])]
        if op == 'not':
            return [('xori', [args[0], args[1], '-1'])]
        if op == 'neg':
            return [('sub', [args[0], 'x0', args[1]])]
        if op == 'seqz':
            return [('sltiu', [args[0], args[1], '1'])]
        if op == 'snez':
            return [('sltu', [args[0], 'x0', args[1]])]
        if op == 'j':
            return [('jal', ['x0', args[0]])]
        if op == 'jr':
            return [('jalr', ['x0', args[0], '0'])]
        if op == 'ret':
            return [('jalr', ['x0', 'ra', '0'])]
        if op == 'beqz':
            return [('beq', [args[0], 'x0', args[1]])]
        if op == 'bnez':
            return [('bne', [args[0], 'x0', args[1]])]
        if op == 'li':
            # Always two instructions so the size is label-stable across passes.
            return [('lui', [args[0], '__LI_HI__' + args[1]]),
                    ('addi', [args[0], args[0], '__LI_LO__' + args[1]])]
        return [(op, args)]

    def _size(self, op, args):
        return len(self._expand(op, args))

    def assemble(self, text):
        lines = text.splitlines()

        # ---- pass 1: labels -------------------------------------------------
        addr = self.base
        pending = []
        for raw in lines:
            body = raw.split('#')[0].split('//')[0]
            while ':' in body:
                lbl, body = body.split(':', 1)
                self.labels[lbl.strip()] = addr
            op, args = self._split(body)
            if op is None:
                continue
            if op == '.word':
                addr += 4 * len(args)
                pending.append((addr, op, args))
                continue
            if op.startswith('.'):
                continue
            addr += 4 * self._size(op, args)
            pending.append((addr, op, args))

        # ---- pass 2: emit ---------------------------------------------------
        words = []
        addr = self.base
        for raw in lines:
            body = raw.split('#')[0].split('//')[0]
            while ':' in body:
                _, body = body.split(':', 1)
            op, args = self._split(body)
            if op is None:
                continue
            if op == '.word':
                for a in args:
                    words.append(self._imm(a) & MASK32)
                    addr += 4
                continue
            if op.startswith('.'):
                continue
            for (eop, eargs) in self._expand(op, args):
                words.append(self._encode(eop, eargs, addr))
                addr += 4
        return words

    def _encode(self, op, args, addr):
        # The li expansion must be matched before the generic addi/lui paths.
        if op == 'addi' and args[2].startswith('__LI_LO__'):
            v = self._imm(args[2][9:]) & MASK32
            lo = v & 0xFFF
            if lo >= 0x800:
                lo -= 0x1000
            return i_type(OPC['op_imm'], 0x0, reg(args[0]), reg(args[1]), lo)
        if op in R_TYPE:
            f3, f7 = R_TYPE[op]
            return r_type(OPC['op'], f3, f7, reg(args[0]), reg(args[1]), reg(args[2]))
        if op in CRC_TYPE:
            return r_type(CUSTOM_OPCODE, CRC_TYPE[op], 0x00,
                          reg(args[0]), reg(args[1]), reg(args[2]))
        if op in I_ARITH:
            return i_type(OPC['op_imm'], I_ARITH[op], reg(args[0]), reg(args[1]),
                          self._imm(args[2]))
        if op in I_SHIFT:
            f3, f7 = I_SHIFT[op]
            sh = self._imm(args[2]) & 0x1F
            return i_type(OPC['op_imm'], f3, reg(args[0]), reg(args[1]),
                          (f7 << 5) | sh)
        if op in LOADS:
            m = MEMOP_RE.match(args[1]) if len(args) == 2 else None
            if m:
                off, base = self._imm(m.group(1)), reg(m.group(2))
            else:
                off, base = self._imm(args[2]), reg(args[1])
            return i_type(OPC['load'], LOADS[op], reg(args[0]), base, off)
        if op in STORES:
            m = MEMOP_RE.match(args[1]) if len(args) == 2 else None
            if m:
                off, base = self._imm(m.group(1)), reg(m.group(2))
            else:
                off, base = self._imm(args[2]), reg(args[1])
            return s_type(OPC['store'], STORES[op], base, reg(args[0]), off)
        if op in BRANCH:
            target = self._imm(args[2])
            return b_type(OPC['branch'], BRANCH[op], reg(args[0]), reg(args[1]),
                          target - addr)
        if op == 'lui' or op == 'auipc':
            a = args[1]
            if a.startswith('__LI_HI__'):
                v = self._imm(a[9:]) & MASK32
                # +0x800 compensates for the sign-extension of the addi below
                himm = ((v + 0x800) >> 12) & 0xFFFFF
            else:
                himm = self._imm(a) & 0xFFFFF
            return u_type(OPC['lui'] if op == 'lui' else OPC['auipc'],
                          reg(args[0]), himm)
        if op == 'addi' and args[2].startswith('__LI_LO__'):
            v = self._imm(args[2][9:]) & MASK32
            lo = v & 0xFFF
            if lo >= 0x800:
                lo -= 0x1000
            return i_type(OPC['op_imm'], 0x0, reg(args[0]), reg(args[1]), lo)
        if op == 'jal':
            if len(args) == 1:
                rd, tgt = 1, self._imm(args[0])
            else:
                rd, tgt = reg(args[0]), self._imm(args[1])
            return j_type(OPC['jal'], rd, tgt - addr)
        if op == 'jalr':
            if len(args) == 3:
                return i_type(OPC['jalr'], 0x0, reg(args[0]), reg(args[1]),
                              self._imm(args[2]))
            return i_type(OPC['jalr'], 0x0, 1, reg(args[0]), 0)
        if op == 'ecall':
            return 0x00000073
        if op == 'ebreak':
            return 0x00100073
        if op == 'fence':
            return 0x0000000F
        raise ValueError("unsupported mnemonic: %r" % op)


# --------------------------------------------------------------------------
# CRC -- must match the RTL exactly. Change POLY only; reflection is structural.
# --------------------------------------------------------------------------
CRC_POLY = 0xEDB88320


def crc_update_byte(crc, byte, poly=CRC_POLY):
    c = (crc ^ (byte & 0xFF)) & MASK32
    for _ in range(8):
        c = ((c >> 1) ^ (poly & -(c & 1))) & MASK32
    return c


def crc_update(crc, data, width, poly=CRC_POLY):
    """width: 0 = byte, 1 = halfword, 2 = word. Little-endian byte order."""
    n = {0: 1, 1: 2, 2: 4}.get(width, 0)
    for i in range(n):
        crc = crc_update_byte(crc, (data >> (8 * i)) & 0xFF, poly)
    return crc


# --------------------------------------------------------------------------
# Instruction set simulator
# --------------------------------------------------------------------------
def sext(v, bits):
    m = 1 << (bits - 1)
    return (v ^ m) - m


class Memory(object):
    """Flat sparse byte memory. Regions are for reporting, not enforcement."""

    def __init__(self):
        self.b = {}

    def load_words(self, words, base=0):
        for i, w in enumerate(words):
            self.write(base + 4 * i, w, 4)

    def read(self, addr, n):
        v = 0
        for i in range(n):
            v |= self.b.get(addr + i, 0) << (8 * i)
        return v

    def write(self, addr, val, n):
        for i in range(n):
            self.b[addr + i] = (val >> (8 * i)) & 0xFF


class CPU(object):
    def __init__(self, mem, pc=0, poly=CRC_POLY):
        self.x = [0] * 32
        self.pc = pc
        self.mem = mem
        self.poly = poly
        self.halted = False
        self.halt_code = None
        self.count = 0

    def _wr(self, rd, val):
        if rd:
            self.x[rd] = val & MASK32

    def step(self):
        pc = self.pc
        instr = self.mem.read(pc, 4)
        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        f3 = (instr >> 12) & 0x7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        f7 = (instr >> 25) & 0x7F
        a, b = self.x[rs1], self.x[rs2]

        imm_i = sext(instr >> 20, 12)
        imm_s = sext(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
        imm_b = sext((((instr >> 31) & 1) << 12) | (((instr >> 7) & 1) << 11) |
                     (((instr >> 25) & 0x3F) << 5) | (((instr >> 8) & 0xF) << 1), 13)
        imm_u = instr & 0xFFFFF000
        imm_j = sext((((instr >> 31) & 1) << 20) | (((instr >> 12) & 0xFF) << 12) |
                     (((instr >> 20) & 1) << 11) | (((instr >> 21) & 0x3FF) << 1), 21)

        nxt = (pc + 4) & MASK32
        wrote = (0, 0)

        if opcode == OPC['lui']:
            self._wr(rd, imm_u); wrote = (rd, imm_u & MASK32)
        elif opcode == OPC['auipc']:
            v = (pc + imm_u) & MASK32
            self._wr(rd, v); wrote = (rd, v)
        elif opcode == OPC['jal']:
            v = nxt
            self._wr(rd, v); wrote = (rd, v)
            nxt = (pc + imm_j) & MASK32
        elif opcode == OPC['jalr']:
            v = nxt
            nxt = (a + imm_i) & MASK32 & ~1          # architectural: clear bit 0
            self._wr(rd, v); wrote = (rd, v)
        elif opcode == OPC['branch']:
            sa, sb = sext(a, 32), sext(b, 32)
            taken = {0: sa == sb, 1: sa != sb, 4: sa < sb, 5: sa >= sb,
                     6: a < b, 7: a >= b}.get(f3, False)
            if taken:
                nxt = (pc + imm_b) & MASK32
        elif opcode == OPC['load']:
            addr = (a + imm_i) & MASK32
            if f3 == 0:
                v = sext(self.mem.read(addr, 1), 8) & MASK32
            elif f3 == 1:
                v = sext(self.mem.read(addr, 2), 16) & MASK32
            elif f3 == 2:
                v = self.mem.read(addr, 4)
            elif f3 == 4:
                v = self.mem.read(addr, 1)
            elif f3 == 5:
                v = self.mem.read(addr, 2)
            else:
                v = 0
            self._wr(rd, v); wrote = (rd, v & MASK32)
        elif opcode == OPC['store']:
            addr = (a + imm_s) & MASK32
            n = {0: 1, 1: 2, 2: 4}.get(f3, 4)
            self.mem.write(addr, b, n)
            if addr == 0x20000000:
                self.halted = True
                self.halt_code = b & MASK32
        elif opcode == OPC['op_imm']:
            sa = sext(a, 32)
            if f3 == 0:   v = a + imm_i
            elif f3 == 2: v = 1 if sa < imm_i else 0
            elif f3 == 3: v = 1 if a < (imm_i & MASK32) else 0
            elif f3 == 4: v = a ^ (imm_i & MASK32)
            elif f3 == 6: v = a | (imm_i & MASK32)
            elif f3 == 7: v = a & (imm_i & MASK32)
            elif f3 == 1: v = a << (imm_i & 0x1F)
            elif f3 == 5:
                sh = imm_i & 0x1F
                v = (sa >> sh) if (f7 & 0x20) else (a >> sh)
            else: v = 0
            self._wr(rd, v); wrote = (rd, v & MASK32)
        elif opcode == OPC['op']:
            sa, sb = sext(a, 32), sext(b, 32)
            if f7 == 0x01:                                    # M extension
                if f3 == 0:   v = (sa * sb) & MASK32          # MUL
                elif f3 == 1: v = ((sa * sb) >> 32) & MASK32  # MULH
                elif f3 == 2: v = ((sa * b) >> 32) & MASK32   # MULHSU
                elif f3 == 3: v = ((a * b) >> 32) & MASK32    # MULHU
                else:
                    raise NotImplementedError("div/rem not modelled")
            else:
                sh = b & 0x1F
                if f3 == 0:   v = (a - b) if (f7 & 0x20) else (a + b)
                elif f3 == 1: v = a << sh
                elif f3 == 2: v = 1 if sa < sb else 0
                elif f3 == 3: v = 1 if a < b else 0
                elif f3 == 4: v = a ^ b
                elif f3 == 5: v = (sa >> sh) if (f7 & 0x20) else (a >> sh)
                elif f3 == 6: v = a | b
                else:         v = a & b
            self._wr(rd, v); wrote = (rd, v & MASK32)
        elif opcode == CUSTOM_OPCODE:
            v = crc_update(a, b, f3, self.poly) if f3 <= 2 else a
            self._wr(rd, v); wrote = (rd, v & MASK32)
        elif opcode == OPC['system']:
            self.halted = True
            self.halt_code = self.x[10]
        elif opcode == OPC['fence']:
            pass
        else:
            self.halted = True
            self.halt_code = None
            return pc, instr, (0, 0), True          # illegal

        self.pc = nxt
        self.count += 1
        return pc, instr, wrote, False


# --------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------
def read_hex(path):
    words = []
    with open(path) as f:
        for line in f:
            line = line.split('//')[0].split('#')[0].strip()
            if not line or line.startswith('@'):
                continue
            for tok in line.split():
                words.append(int(tok, 16))
    return words


def write_hex(words, path):
    with open(path, 'w') as f:
        for w in words:
            f.write("%08x\n" % (w & MASK32))


def run(words, trace=False, max_steps=1000000, poly=CRC_POLY):
    mem = Memory()
    mem.load_words(words)
    cpu = CPU(mem, poly=poly)
    for _ in range(max_steps):
        pc, instr, (rd, val), illegal = cpu.step()
        if trace:
            print("%08x %08x x%d=%08x" % (pc, instr, rd, val))
        if illegal:
            sys.stderr.write("ILLEGAL instruction %08x at pc=%08x\n" % (instr, pc))
            break
        if cpu.halted:
            break
    else:
        sys.stderr.write("step limit reached (possible infinite loop)\n")
    return cpu


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--asm', help='assembly source to assemble')
    ap.add_argument('--hex', help='output hex image (with --asm) ')
    ap.add_argument('--trace', metavar='HEX', help='execute image, print retire trace')
    ap.add_argument('--run', metavar='HEX', help='execute image quietly')
    ap.add_argument('--dump-regs', action='store_true')
    ap.add_argument('--poly', default=hex(CRC_POLY), help='CRC polynomial (reflected)')
    args = ap.parse_args()

    poly = int(args.poly, 0)

    if args.asm:
        with open(args.asm) as f:
            words = Assembler().assemble(f.read())
        if args.hex:
            write_hex(words, args.hex)
        else:
            for w in words:
                print("%08x" % w)

    img = args.trace or args.run
    if img:
        cpu = run(read_hex(img), trace=bool(args.trace), poly=poly)
        if cpu.halt_code is not None:
            sys.stderr.write("halted, code=%d (%s)\n" %
                             (cpu.halt_code, "PASS" if cpu.halt_code == 1 else "FAIL"))
        if args.dump_regs:
            for i in range(32):
                sys.stderr.write("x%-2d %-5s %08x\n" % (i, ABI_NAME[i], cpu.x[i]))


if __name__ == '__main__':
    main()
