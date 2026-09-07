# ISA and Encoding Reference

Exact encodings, semantics, and the traps in each. Everything here is for **RV32**
(XLEN=32) and follows the ratified unprivileged specification. Where a project
document disagrees with this file, the project document wins.

## Contents
- [Instruction formats](#instruction-formats)
- [Immediate generation](#immediate-generation)
- [Opcode map](#opcode-map)
- [RV32I instruction table](#rv32i-instruction-table)
- [Semantics traps in RV32I](#semantics-traps-in-rv32i)
- [M extension: the four multiply instructions](#m-extension-the-four-multiply-instructions)
- [Designing a custom extension](#designing-a-custom-extension)
- [A worked custom extension: CRC](#a-worked-custom-extension-crc)
- [Assembler macros for custom instructions](#assembler-macros-for-custom-instructions)
- [Register ABI names](#register-abi-names)

---

## Instruction formats

All RV32 base instructions are 32 bits, and every field sits at a fixed position
across formats. That fixed positioning is deliberate — it lets `rs1`, `rs2`, and
`rd` be extracted before the opcode is even decoded, which is what makes the
decode stage cheap.

```
 31        25 24     20 19     15 14  12 11      7 6       0
+------------+---------+---------+------+---------+---------+
|   funct7   |   rs2   |   rs1   |funct3|    rd   | opcode  |  R
+------------+---------+---------+------+---------+---------+
|      imm[11:0]       |   rs1   |funct3|    rd   | opcode  |  I
+------------+---------+---------+------+---------+---------+
|  imm[11:5] |   rs2   |   rs1   |funct3|imm[4:0] | opcode  |  S
+------------+---------+---------+------+---------+---------+
|imm[12|10:5]|   rs2   |   rs1   |funct3|imm[4:1|11]|opcode |  B
+------------+---------+---------+------+---------+---------+
|            imm[31:12]                 |    rd   | opcode  |  U
+---------------------------------------+---------+---------+
|        imm[20|10:1|11|19:12]          |    rd   | opcode  |  J
+---------------------------------------+---------+---------+
```

Constant field extraction, valid for every format (garbage fields are simply
ignored by the control unit):

```verilog
wire [6:0] opcode = instr[6:0];
wire [4:0] rd     = instr[11:7];
wire [2:0] funct3 = instr[14:12];
wire [4:0] rs1    = instr[19:15];
wire [4:0] rs2    = instr[24:20];
wire [6:0] funct7 = instr[31:25];
wire [4:0] shamt  = instr[24:20];   // RV32 shift amount == rs2 field
```

---

## Immediate generation

The single most bug-prone block in a RISC-V decoder, because B and J formats
scramble the bits to keep the sign bit at `instr[31]` and each immediate bit in a
consistent position across formats. Copy this verbatim; do not re-derive it.

```verilog
wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7],
                     instr[30:25], instr[11:8], 1'b0};
wire [31:0] imm_u = {instr[31:12], 12'b0};
wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12],
                     instr[20], instr[30:21], 1'b0};
```

Checks worth doing once, in a testbench, rather than assuming:

- Each expression concatenates to exactly 32 bits (20+12, 20+7+5, 19+1+1+6+4+1,
  20+12, 11+1+8+1+10+1).
- **B and J immediates are always even** — bit 0 is a hardwired zero, because
  branch and jump targets are 2-byte aligned. If your `imm_b` can be odd, the
  bit-slicing is wrong.
- **U-type is not sign-extended.** It is already 32 bits; `LUI` places it
  directly, `AUIPC` adds it to the PC. Sign-extending it is a common error.
- The sign source is *always* `instr[31]`, in every format that has a sign.

Test vectors that catch the classic mistakes (verify these in the immediate-generator
testbench):

| instr (hex) | asm | format | expected immediate |
|---|---|---|---|
| `FFF00093` | `addi x1, x0, -1` | I | `0xFFFFFFFF` |
| `80000093` | `addi x1, x0, -2048` | I | `0xFFFFF800` |
| `7FF00093` | `addi x1, x0, 2047` | I | `0x000007FF` |
| `FE112E23` | `sw x1, -4(x2)` | S | `0xFFFFFFFC` |
| `FE000EE3` | `beq x0, x0, -4` | B | `0xFFFFFFFC` |
| `00000063` | `beq x0, x0, 0` | B | `0x00000000` |
| `FFFFF0B7` | `lui x1, 0xFFFFF` | U | `0xFFFFF000` |
| `FFDFF06F` | `jal x0, -4` | J | `0xFFFFFFFC` |

---

## Opcode map

Seven bits, but the low two are always `11` for 32-bit instructions, so the
useful field is `instr[6:2]`.

| opcode | hex | name | format | instructions |
|---|---|---|---|---|
| `0110111` | 0x37 | LUI | U | `LUI` |
| `0010111` | 0x17 | AUIPC | U | `AUIPC` |
| `1101111` | 0x6F | JAL | J | `JAL` |
| `1100111` | 0x67 | JALR | I | `JALR` |
| `1100011` | 0x63 | BRANCH | B | 6 branches |
| `0000011` | 0x03 | LOAD | I | 5 loads |
| `0100011` | 0x23 | STORE | S | 3 stores |
| `0010011` | 0x13 | OP-IMM | I | 9 immediate ALU ops |
| `0110011` | 0x33 | OP | R | 10 register ALU ops + M extension |
| `0001111` | 0x0F | MISC-MEM | I | `FENCE` |
| `1110011` | 0x73 | SYSTEM | I | `ECALL`, `EBREAK`, CSR ops |

**Reserved for custom extensions** — these are guaranteed never to be used by
standard extensions in RV32/RV64, which is why your custom instructions belong here:

| opcode | hex | name |
|---|---|---|
| `0001011` | 0x0B | *custom-0* |
| `0101011` | 0x2B | *custom-1* |
| `1011011` | 0x5B | *custom-2* (reserved for RV128) |
| `1111011` | 0x7B | *custom-3* (reserved for RV128) |

Prefer `custom-0` unless the project specifies otherwise. Never place a custom
instruction in a standard opcode's unused `funct3`/`funct7` space — it works
until the day someone adds the standard extension that claims it.

---

## RV32I instruction table

The 37 non-CSR base instructions. `X` means don't-care.

**U / J types**

| instr | opcode | operation |
|---|---|---|
| `LUI rd,imm` | 0110111 | `rd = imm_u` |
| `AUIPC rd,imm` | 0010111 | `rd = pc + imm_u` |
| `JAL rd,imm` | 1101111 | `rd = pc + 4; pc = pc + imm_j` |

**I type — JALR, loads, OP-IMM, SYSTEM**

| instr | opcode | funct3 | funct7/imm | operation |
|---|---|---|---|---|
| `JALR rd,rs1,imm` | 1100111 | 000 | X | `rd = pc+4; pc = (rs1+imm_i) & ~1` |
| `LB rd,imm(rs1)` | 0000011 | 000 | X | `rd = sext(mem8[rs1+imm_i])` |
| `LH rd,imm(rs1)` | 0000011 | 001 | X | `rd = sext(mem16[...])` |
| `LW rd,imm(rs1)` | 0000011 | 010 | X | `rd = mem32[...]` |
| `LBU rd,imm(rs1)` | 0000011 | 100 | X | `rd = zext(mem8[...])` |
| `LHU rd,imm(rs1)` | 0000011 | 101 | X | `rd = zext(mem16[...])` |
| `ADDI` | 0010011 | 000 | X | `rd = rs1 + imm_i` |
| `SLTI` | 0010011 | 010 | X | `rd = ($signed(rs1) < $signed(imm_i))` |
| `SLTIU` | 0010011 | 011 | X | `rd = (rs1 < imm_i)` *unsigned compare of the sign-extended immediate* |
| `XORI` | 0010011 | 100 | X | `rd = rs1 ^ imm_i` |
| `ORI` | 0010011 | 110 | X | `rd = rs1 \| imm_i` |
| `ANDI` | 0010011 | 111 | X | `rd = rs1 & imm_i` |
| `SLLI` | 0010011 | 001 | 0000000 | `rd = rs1 << shamt` |
| `SRLI` | 0010011 | 101 | 0000000 | `rd = rs1 >> shamt` |
| `SRAI` | 0010011 | 101 | 0100000 | `rd = $signed(rs1) >>> shamt` |
| `FENCE` | 0001111 | 000 | X | no-op in a single-hart core without caches |
| `ECALL` | 1110011 | 000 | imm=0 | environment call |
| `EBREAK` | 1110011 | 000 | imm=1 | breakpoint |

**S type — stores**

| instr | opcode | funct3 | operation |
|---|---|---|---|
| `SB rs2,imm(rs1)` | 0100011 | 000 | `mem8[rs1+imm_s] = rs2[7:0]` |
| `SH rs2,imm(rs1)` | 0100011 | 001 | `mem16[...] = rs2[15:0]` |
| `SW rs2,imm(rs1)` | 0100011 | 010 | `mem32[...] = rs2` |

**B type — branches** (all: `if (cond) pc = pc + imm_b; else pc = pc + 4`)

| instr | funct3 | condition |
|---|---|---|
| `BEQ` | 000 | `rs1 == rs2` |
| `BNE` | 001 | `rs1 != rs2` |
| `BLT` | 100 | `$signed(rs1) < $signed(rs2)` |
| `BGE` | 101 | `$signed(rs1) >= $signed(rs2)` |
| `BLTU` | 110 | `rs1 < rs2` unsigned |
| `BGEU` | 111 | `rs1 >= rs2` unsigned |

**R type — OP** (opcode 0110011)

| instr | funct3 | funct7 | operation |
|---|---|---|---|
| `ADD` | 000 | 0000000 | `rs1 + rs2` |
| `SUB` | 000 | 0100000 | `rs1 - rs2` |
| `SLL` | 001 | 0000000 | `rs1 << rs2[4:0]` |
| `SLT` | 010 | 0000000 | signed less-than |
| `SLTU` | 011 | 0000000 | unsigned less-than |
| `XOR` | 100 | 0000000 | `rs1 ^ rs2` |
| `SRL` | 101 | 0000000 | `rs1 >> rs2[4:0]` |
| `SRA` | 101 | 0100000 | arithmetic right shift |
| `OR` | 110 | 0000000 | `rs1 \| rs2` |
| `AND` | 111 | 0000000 | `rs1 & rs2` |

---

## Semantics traps in RV32I

These are the ones that pass a casual testbench and fail an architectural test.

**`x0` is hardwired to zero.** Reads return 0 regardless of what was written;
writes are discarded. Implement as a read mux (`rs1 == 0 ? 32'b0 : regs[rs1]`),
not as a write-enable suppression alone — although suppressing the write too
saves the flop bank and is standard practice.

**`SLTIU` compares unsigned, but the immediate is still sign-extended.** So
`sltiu x1, x0, -1` compares `0 < 0xFFFFFFFF` and yields 1. Sign-extend first,
then compare unsigned. Getting this backwards is the single most common decoder bug.

**Shift amounts use only the low 5 bits** in RV32 — `rs1 << rs2[4:0]`. A shift by
32 is a shift by 0, not a zeroing. Verilog's `<<` on a 32-bit operand with a wide
shift count will produce 0, which is wrong; mask the shift amount explicitly.

**`SRA` needs `$signed` on the operand, not the result.** `$signed(rs1) >>> shamt`.
Writing `rs1 >>> shamt` where `rs1` is an unsigned `wire [31:0]` silently performs
a logical shift.

**`JALR` must clear bit 0** of the computed target. `(rs1 + imm) & ~1`. This is
architectural, not optional, and it exists so that function-pointer arithmetic
cannot produce a misaligned fetch.

**`JAL`/`JALR` link register is `pc + 4`**, the address of the *next* instruction,
not the target. And `rd` may be `x0` (an unconditional jump with no link) — the
x0 rule applies normally.

**Branch and jump targets are relative to the branch's own PC**, not `pc + 4`.

**`AUIPC` adds to the current PC**, again not `pc + 4`.

**Overflow is not detected.** `ADD`/`SUB` wrap silently; RISC-V has no overflow
flag and no trap. Do not add one.

**Misaligned access.** The base ISA permits either supporting misaligned
load/store or raising an address-misaligned exception. For a core without trap
support, detect it and drive an error signal — and write down which choice you
made. Silently returning a rotated word is the worst option because it is
plausible-looking wrong data.

---

## M extension: the four multiply instructions

Full RV32M has eight instructions — four multiply and four divide. A project that
asks for "the multiply extension, four instructions" means these four, all
opcode `0110011` with `funct7 = 0000001`:

| instr | funct3 | operands | result |
|---|---|---|---|
| `MUL` | 000 | — | low 32 bits of the product |
| `MULH` | 001 | both signed | high 32 bits |
| `MULHSU` | 010 | rs1 signed, rs2 **unsigned** | high 32 bits |
| `MULHU` | 011 | both unsigned | high 32 bits |

(`DIV` 100, `DIVU` 101, `REM` 110, `REMU` 111 complete RV32M. Only implement them
if asked — division is a much larger and slower unit than multiplication.)

**The low 32 bits are identical for all signedness combinations**, which is why
`MUL` needs no signed variant. Only the high half differs.

Correct Verilog-2001, with the width extension that makes `MULHSU` right:

```verilog
// Sign/zero extend to 33 bits so one signed multiplier covers all three cases.
wire signed [32:0] a_s = {a[31], a};      // rs1 as signed
wire signed [32:0] a_u = {1'b0,  a};      // rs1 as unsigned
wire signed [32:0] b_s = {b[31], b};      // rs2 as signed
wire signed [32:0] b_u = {1'b0,  b};      // rs2 as unsigned

wire signed [65:0] p_ss = a_s * b_s;      // MULH
wire signed [65:0] p_su = a_s * b_u;      // MULHSU
wire signed [65:0] p_uu = a_u * b_u;      // MULHU

always @(*) begin
    case (funct3)
        3'b000: mul_result = p_uu[31:0];  // MUL   (low half, signedness-agnostic)
        3'b001: mul_result = p_ss[63:32]; // MULH
        3'b010: mul_result = p_su[63:32]; // MULHSU
        3'b011: mul_result = p_uu[63:32]; // MULHU
        default: mul_result = 32'b0;
    endcase
end
```

Three separate multipliers is wasteful; see `optimization.md` for how to collapse
this to one datapath with muxed operand extension, and for the multi-cycle
alternatives when a single-cycle 32×32 is the critical path.

**Corner-case vectors every multiplier testbench needs** (these catch the
sign-extension bugs; all values hex):

| a | b | MUL | MULH | MULHSU | MULHU |
|---|---|---|---|---|---|
| `00000000` | `00000000` | `00000000` | `00000000` | `00000000` | `00000000` |
| `00000001` | `00000001` | `00000001` | `00000000` | `00000000` | `00000000` |
| `FFFFFFFF` | `FFFFFFFF` | `00000001` | `00000000` | `FFFFFFFF` | `FFFFFFFE` |
| `80000000` | `80000000` | `00000000` | `40000000` | `C0000000` | `40000000` |
| `80000000` | `FFFFFFFF` | `80000000` | `00000000` | `80000000` | `7FFFFFFF` |
| `7FFFFFFF` | `7FFFFFFF` | `00000001` | `3FFFFFFF` | `3FFFFFFF` | `3FFFFFFF` |
| `FFFFFFFF` | `00000001` | `FFFFFFFF` | `FFFFFFFF` | `FFFFFFFF` | `00000000` |

The `FFFFFFFF × FFFFFFFF` row alone distinguishes all four instructions — if your
`MULHSU` returns `00000000` there instead of `FFFFFFFF`, the operand extension is
wrong. Generate the rest randomly against the golden model rather than by hand.

---

## Designing a custom extension

When a project defines its own instructions, these decisions have to be made
explicitly, and every one of them is a place where the RTL and the assembler can
silently disagree:

1. **Opcode space.** Use `custom-0` (`0001011`) unless told otherwise.
2. **Format.** R-type is almost always right for a functional unit that takes one
   or two registers and writes one — it reuses the existing `rs1`/`rs2`/`rd`
   extraction with zero extra decode logic. I-type if you need a small immediate.
3. **Sub-opcode field.** `funct3` gives 8 variants for free; `funct7` gives 128
   more. Use `funct3` first; it is the field the decoder already looks at.
4. **Reserved encodings.** Decide now what an unused `funct3` does — safest is
   "behaves as a no-op and asserts an `illegal` flag" rather than an unspecified
   result.
5. **Latency.** If the unit cannot complete in the cycle budget the FSM allows,
   define the stall protocol *before* writing the unit (see `microarchitecture.md`,
   variable-latency execute).
6. **Write down the encoding table** in the same format as the RV32I table above,
   and put it in the deliverables. It is the interface contract.

---

## A worked custom extension: CRC

A CRC unit is the canonical custom-extension exercise: real, useful, cheap in
gates, and impossible to get accidentally right — which makes it a good test of
whether the verification methodology works.

**If the project supplies an encoding and a polynomial, use theirs.** What
follows is a complete, defensible default for when it does not, and the
parameterization that makes swapping in the real spec a one-line change.

### Proposed encoding (default — override with the project spec)

R-type in `custom-0`, `funct7 = 0000000`, three widths mirroring the load/store
size families:

| instr | opcode | funct3 | operation |
|---|---|---|---|
| `CRC.B rd, rs1, rs2` | 0001011 | 000 | fold the low **byte** of rs2 into CRC state rs1 |
| `CRC.H rd, rs1, rs2` | 0001011 | 001 | fold the low **halfword** of rs2 |
| `CRC.W rd, rs1, rs2` | 0001011 | 010 | fold the full **word** of rs2 |

`rs1` carries the running CRC state and `rd` receives the updated state, so a
checksum over a buffer is a load / CRC / branch loop with no extra state
registers. Initialization and final inversion stay in software, which keeps the
hardware polynomial-agnostic and the instruction composable.

### Why the update must be parallel, not bit-serial

A textbook CRC is an LFSR shifting one bit per clock — 8 cycles for a byte, 32
for a word. In a fixed-cycle FSM where Execute is one cycle, that does not fit.
The parallel form unrolls the same recurrence into pure combinational XOR logic:
each output bit is the XOR of a fixed subset of the input bits, so the whole
byte-wise update is roughly 8 levels of 2-input XOR — small, fast, and nowhere
near the critical path in practice.

```verilog
// Reflected (LSB-first) CRC-32, one byte folded per call, fully combinational.
// CRC-32/ISO-HDLC: reflected polynomial 32'hEDB88320.
// Change POLY (and only POLY) for CRC-32C: 32'h82F63B78.
module crc32_byte #(
    parameter [31:0] POLY = 32'hEDB88320
)(
    input  wire [31:0] crc_in,
    input  wire [7:0]  data,
    output reg  [31:0] crc_out
);
    integer i;
    reg [31:0] c;
    always @(*) begin
        c = crc_in ^ {24'b0, data};
        for (i = 0; i < 8; i = i + 1)
            c = (c >> 1) ^ (POLY & {32{c[0]}});
        crc_out = c;
    end
endmodule
```

The `for` loop is a *static unroll*, not a sequential loop — `i` is elaboration
time, so this synthesizes to combinational logic. This is legal and portable
Verilog-2001, and it is the idiom to reach for whenever a recurrence has a fixed
iteration count.

Halfword and word variants chain the byte block, little-endian (low byte first),
which matches how the bytes would arrive from memory:

```verilog
crc32_byte #(POLY) b0 (.crc_in(crc_in), .data(data[ 7: 0]), .crc_out(s0));
crc32_byte #(POLY) b1 (.crc_in(s0),     .data(data[15: 8]), .crc_out(s1));
crc32_byte #(POLY) b2 (.crc_in(s1),     .data(data[23:16]), .crc_out(s2));
crc32_byte #(POLY) b3 (.crc_in(s2),     .data(data[31:24]), .crc_out(s3));
// funct3 selects: 000 -> s0, 001 -> s1, 010 -> s3
```

Four chained blocks is ~32 XOR levels for `CRC.W`. If that shows up as the
critical path in synthesis, the fix is to give `CRC.W` two cycles rather than to
restructure the logic — see `optimization.md`.

### Known-answer vectors

The universally published check value for a CRC is the result over the nine ASCII
bytes `"123456789"`. Use it as the first test; if it passes, the polynomial,
reflection, initial value, and final XOR are all correct together.

| algorithm | poly (reflected) | init | final XOR | check(`"123456789"`) |
|---|---|---|---|---|
| CRC-32/ISO-HDLC (zlib, Ethernet) | `EDB88320` | `FFFFFFFF` | `FFFFFFFF` | `CBF43926` |
| CRC-32C (Castagnoli) | `82F63B78` | `FFFFFFFF` | `FFFFFFFF` | `E3069283` |
| CRC-32/BZIP2 (non-reflected) | `04C11DB7` | `FFFFFFFF` | `FFFFFFFF` | `FC891918` |

Intermediate vectors for the raw hardware block (no init, no final XOR), useful
for debugging the unit in isolation before the software wrapper exists. All
values below are **machine-generated** by `scripts/gen_vectors.py` — regenerate
them rather than trusting this table if you change the polynomial:

| crc_in | data | CRC-32/ISO-HDLC crc_out |
|---|---|---|
| `00000000` | `00` | `00000000` |
| `00000000` | `01` | `77073096` |
| `00000000` | `FF` | `2D02EF8D` |
| `FFFFFFFF` | `00` | `2DFD1072` |
| `FFFFFFFF` | `31` (`'1'`) | `7C231048` |
| `FFFFFFFF` | `FF` | `00FFFFFF` |

A raw block that turns `(FFFFFFFF, 00)` into `2DFD1072` has the reflection and
polynomial right. If it produces something else, the bug is in the block, not in
the software wrapper — which is exactly the localization a unit testbench buys.

The chaining property, also verified: folding `0x34333231` with `CRC.W` from
state `FFFFFFFF` gives `641C1F5C`, and so does folding `31`, `32`, `33`, `34`
with four `CRC.B` operations. If those disagree, the byte order in the word
variant is wrong.

> **Do not hand-write known-answer vectors from memory.** An incorrect expected
> value makes a correct implementation look broken and costs hours. Generate
> them from a reference implementation — that is what `scripts/gen_vectors.py`
> is for, and it takes a second to run.

Note the **non-reflected** variant is a different circuit, not just a different
constant: it shifts left and tests the MSB. Do not try to reach BZIP2's check
value by only changing `POLY` in the module above.

---

## Assembler macros for custom instructions

A stock assembler does not know custom mnemonics, so the instruction word must be
emitted directly. Three approaches, in increasing order of convenience:

**1. Raw word — always works, zero setup.**

```asm
.word 0x0060050B      # crc.b a0, a0, t1  (hand-assembled)
```

Unreadable and unmaintainable. Acceptable for a single smoke test, never for a
test suite.

**2. GNU `as` macro — the right answer for GNU toolchains.**

```asm
# R-type custom instruction builder.
# .insn r opcode, funct3, funct7, rd, rs1, rs2
.macro CRC_B rd, rs1, rs2
    .insn r 0x0B, 0x0, 0x00, \rd, \rs1, \rs2
.endm
.macro CRC_H rd, rs1, rs2
    .insn r 0x0B, 0x1, 0x00, \rd, \rs1, \rs2
.endm
.macro CRC_W rd, rs1, rs2
    .insn r 0x0B, 0x2, 0x00, \rd, \rs1, \rs2
.endm

    CRC_B a0, a0, t1          # now readable, and register names are checked
```

`.insn` is the RISC-V assembler's built-in escape hatch for unknown encodings; it
does the field packing and validates register operands, which removes the entire
class of hand-assembly errors.

**3. Generate the word in Python** when there is no GNU toolchain (a common
situation on browser-based platforms), and emit it into the hex image directly.
`scripts/rv_model.py` includes an encoder for exactly this:

```python
def r_type(opcode, funct3, funct7, rd, rs1, rs2):
    return ((funct7 & 0x7F) << 25 | (rs2 & 0x1F) << 20 | (rs1 & 0x1F) << 15
            | (funct3 & 0x7) << 12 | (rd & 0x1F) << 7 | (opcode & 0x7F))

crc_b = lambda rd, rs1, rs2: r_type(0x0B, 0x0, 0x00, rd, rs1, rs2)
```

**Always verify the macro against the decoder**, in both directions: assemble one
instruction of each variant, disassemble the resulting word with your own model,
and confirm the fields round-trip. A macro with a wrong `funct3` produces a test
suite that exercises the wrong instruction and passes — the most expensive kind
of green result.

---

## Register ABI names

Needed for reading disassembly, writing test programs, and interpreting compiler
output. `x0`–`x31`, all 32 bits:

| reg | ABI | role | preserved? |
|---|---|---|---|
| x0 | zero | hardwired zero | — |
| x1 | ra | return address | no |
| x2 | sp | stack pointer | yes |
| x3 | gp | global pointer | — |
| x4 | tp | thread pointer | — |
| x5–x7 | t0–t2 | temporaries | no |
| x8 | s0/fp | saved / frame pointer | yes |
| x9 | s1 | saved | yes |
| x10–x11 | a0–a1 | arguments / return values | no |
| x12–x17 | a2–a7 | arguments | no |
| x18–x27 | s2–s11 | saved | yes |
| x28–x31 | t3–t6 | temporaries | no |

RV32E halves this to x0–x15 for very small cores; if the project targets RV32E,
the register file drops to 16 entries and the ABI shifts accordingly.
