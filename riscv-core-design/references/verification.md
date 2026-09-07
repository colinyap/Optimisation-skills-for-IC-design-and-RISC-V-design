# Verification Reference

How to prove a RISC-V core is correct, in Verilog-2001, without SystemVerilog
assertions, classes, or constrained-random infrastructure. Runnable templates are
in `assets/`; this file explains what to test, why, and how to debug when a test
fails.

## Contents
- [The verification pyramid](#the-verification-pyramid)
- [Anatomy of a self-checking testbench](#anatomy-of-a-self-checking-testbench)
- [Per-module test plans](#per-module-test-plans)
- [Core-level testbench](#core-level-testbench)
- [Trace format and co-simulation](#trace-format-and-co-simulation)
- [Test program conventions](#test-program-conventions)
- [Architectural test suites](#architectural-test-suites)
- [Formal verification with RVFI](#formal-verification-with-rvfi)
- [Coverage without SystemVerilog](#coverage-without-systemverilog)
- [Debug playbook](#debug-playbook)
- [Writing new testbenches](#writing-new-testbenches)

---

## The verification pyramid

Effort at the bottom is cheap and localizing; effort at the top is expensive and
only tells you *that* something is wrong. Build upward, and never skip a layer to
save time — a bug that escapes to the layer above costs roughly an order of
magnitude more to find.

```
        formal (RVFI)          ── proves properties over all inputs
     architectural suites      ── riscv-arch-test / riscv-tests
   randomized co-simulation    ── RTL trace vs golden model, diffed
      directed programs        ── loops, calls, memcpy, CRC over a buffer
   instruction-level bringup   ── one instruction at a time
    module testbenches         ── ALU, LSU, regfile, CRC, ...
```

The two highest-return-per-hour layers are **module testbenches** and
**randomized co-simulation**. Module testbenches because they localize; random
co-simulation because it generates thousands of cases from one afternoon of work
and the diff points at the exact instruction that broke.

---

## Anatomy of a self-checking testbench

A testbench that prints waveforms and requires a human to look at them has not
tested anything. Every testbench needs five parts:

1. **Clock and reset generation**
2. **A `check` task** that compares actual against expected, counts errors, and
   prints enough context to localize a failure
3. **Stimulus** — directed cases, then loops, then random
4. **A timeout watchdog** so a hung DUT fails rather than hangs the regression
5. **A summary** that prints `PASS` or `FAIL` and exits

Skeleton, pure Verilog-2001 (`assert`, `$error`, and `$fatal` are all
SystemVerilog and unavailable):

```verilog
`timescale 1ns/1ps
module tb_template;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz

    integer errors = 0;
    integer checks = 0;

    // ---- self-checking primitive -------------------------------------
    task check;
        input [255:0] name;                     // packed ASCII label
        input [31:0]  got;
        input [31:0]  expected;
        begin
            checks = checks + 1;
            if (got !== expected) begin         // !== catches x and z too
                errors = errors + 1;
                $display("FAIL [%0t] %0s: got %08h expected %08h",
                         $time, name, got, expected);
            end
        end
    endtask

    // ---- watchdog ----------------------------------------------------
    initial begin
        #100000;
        $display("FAIL: timeout at %0t", $time);
        $display("RESULT: FAIL");
        $finish;
    end

    // ---- waveform ----------------------------------------------------
    initial begin
        $dumpfile("tb_template.vcd");
        $dumpvars(0, tb_template);
    end

    // ---- stimulus ----------------------------------------------------
    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // ... directed and random stimulus, calling check() ...

        $display("---- %0d checks, %0d errors ----", checks, errors);
        $display("RESULT: %0s", (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
```

Details that pay for themselves:

- **`!==` not `!=`.** `!=` returns `x` when either operand contains `x`, and an
  `x` condition is false, so an all-`x` output *passes* a `!=` check. This one
  substitution catches uninitialized-register bugs that otherwise survive to
  integration.
- **Print `$time` and the label in every failure.** A bare "mismatch" message in
  a 500-case loop is nearly useless.
- **Always print a machine-greppable `RESULT: PASS`/`RESULT: FAIL` line.** It is
  what turns a testbench into a regression suite you can run with one command.
- **The watchdog is not optional.** A core that hangs with no watchdog fails the
  whole regression run silently.
- Verilog-2001 has no `string`; a `[255:0]` reg printed with `%0s` carries a
  32-character label, which is enough.

---

## Per-module test plans

What each module needs, and the specific cases that catch real bugs rather than
padding the count.

### Register file
- Write then read back, every register 1–31.
- **x0: write a non-zero value, read back 0.** Both read ports.
- Both read ports reading the same register simultaneously.
- Read-during-write: read register N in the same cycle it is written; confirm the
  behaviour matches what the microarchitecture assumes (old value in this design).
- Write with `rd_we` low leaves the register unchanged.

### Immediate generator
- The eight vectors in `isa-and-encoding.md`, verbatim.
- Sign boundary for each format: most-positive and most-negative immediate.
- **B and J immediates are always even** — sweep random instruction words through
  the B and J paths and check `imm[0] == 0` every time.
- U-type is not sign-extended: `lui x1, 0xFFFFF` gives `0xFFFFF000`, not
  `0xFFFFFFFF...`.

### ALU
- Every operation against a behavioural golden expression in the same testbench.
- Boundaries: `0`, `1`, `-1`, `0x7FFFFFFF`, `0x80000000`, `0xFFFFFFFF`.
- `SLT` vs `SLTU` on the pair (`0x80000000`, `0x00000001`) — signed says less
  than, unsigned says greater. If both give the same answer, one is wrong.
- **Shift amounts 0, 1, 31, and 32.** Shift-by-32 must use only `shamt[4:0]` and
  therefore be a shift by 0.
- `SRA` on a negative value: `0x80000000 >>> 1` is `0xC0000000`, not `0x40000000`.
- Then 10,000 random pairs against the golden expression. Cheap and thorough.

### Branch comparator
- All six conditions, each with equal / less / greater operands.
- Signed vs unsigned disagreement cases: `(0x80000000, 0x00000001)` and
  `(0xFFFFFFFF, 0x00000000)`. `BLT` and `BLTU` must disagree on both.
- Equality with both operands zero, and with both operands `0xFFFFFFFF`.

### Multiplier
- The seven-row corner table in `isa-and-encoding.md`.
- Random pairs against a 64-bit golden product computed three ways in the
  testbench (`$signed`×`$signed`, `$signed`×unsigned, unsigned×unsigned).
- If multi-cycle: start/done handshake, back-to-back operations without an idle
  cycle between them, and a `start` pulse arriving while `done` is still high.

### CRC unit
- Raw-block vectors from `isa-and-encoding.md` (`(FFFFFFFF, 00) → 2144DF1C`).
- Full check value: fold the nine bytes of `"123456789"` starting from
  `0xFFFFFFFF`, invert the result, expect `0xCBF43926`.
- Chaining consistency: `CRC.W(x, d)` must equal four chained `CRC.B` calls on
  the bytes of `d`, low byte first. This one property catches nearly every
  byte-ordering bug in the halfword and word variants.
- A byte of `0x00` folded into state `0x00000000` must leave it at `0x00000000`.

### LSU
Write it as nested loops, not as hand-written cases — the matrix is the point:

```verilog
for (sz = 0; sz < 3; sz = sz + 1)          // byte, half, word
  for (off = 0; off < 4; off = off + 1)    // byte offset within the word
    for (t = 0; t < 2; t = t + 1) begin    // signed / unsigned
        // skip illegal (size, offset) combinations, check the rest
    end
```

- Every legal (size, offset) pair for all five loads and three stores.
- A value with the high bit of the selected field set, so sign extension is
  actually exercised: load `0xFF` as `LB` gives `0xFFFFFFFF`, as `LBU` gives
  `0x000000FF`.
- Store byte strobes: `SB` at offset 2 must produce `wstrb == 4'b0100` and place
  the data in bits [23:16].
- Misalignment detection asserts for each illegal combination and only those.

### Address decoder
- One address inside each region, one at each region's first and last byte.
- An unmapped address asserts the fault indication.
- Exactly one select is asserted for any in-range address — check the one-hot
  property directly, since overlapping regions from a typo pass every
  single-region test.

### Control FSM
- Reset lands in FETCH.
- The state sequence is FETCH → DECODE → EXECUTE → WRITEBACK → FETCH for a
  representative instruction of each class.
- `ex_done` held low keeps the machine in EXECUTE, and it advances when released.
- `mem_ready` held low keeps the machine in WRITEBACK.
- **No unreachable states and no illegal state values** — force the state register
  to each unused encoding and confirm recovery to FETCH via the `default` branch.

---

## Core-level testbench

The core TB loads a program image, runs it, and checks architectural state. It
needs three capabilities beyond the module template: program loading, a retire
trace, and a termination convention.

```verilog
`timescale 1ns/1ps
module tb_core;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // DUT with memories instantiated inside or alongside.
    rv_soc dut (.clk(clk), .rst_n(rst_n));

    // ---- program load ------------------------------------------------
    initial begin
        if (!$value$plusargs("hex=%s", hexfile)) hexfile = "program.hex";
        $readmemh(hexfile, dut.imem.mem);
        // Force a known register-file state so X does not propagate.
        for (i = 1; i < 32; i = i + 1) dut.cpu.rf.regs[i] = 32'h0;
    end

    // ---- retire trace: one line per committed instruction -------------
    always @(posedge clk) begin
        if (rst_n && dut.cpu.retire_valid)
            $display("%08h %08h x%0d=%08h",
                     dut.cpu.retire_pc, dut.cpu.retire_instr,
                     dut.cpu.retire_rd, dut.cpu.retire_rd_val);
    end

    // ---- termination via MMIO ------------------------------------------
    always @(posedge clk) begin
        if (dut.mmio_we && dut.mmio_addr == 32'h2000_0000) begin
            $display("RESULT: %0s", (dut.mmio_wdata == 32'd1) ? "PASS" : "FAIL");
            $finish;
        end
        if (dut.mmio_we && dut.mmio_addr == 32'h2000_0004)
            $write("%c", dut.mmio_wdata[7:0]);     // character output
    end
endmodule
```

The `retire_valid` / `retire_pc` / `retire_instr` / `retire_rd` / `retire_rd_val`
signals are worth adding to the core as **verification-only outputs**. In a
four-state FSM they are trivial — assert in WRITEBACK — and they are what makes
the trace diff below possible. This is the same idea as the RVFI interface, in
miniature; adding them now makes formal verification cheap later.

Use `$value$plusargs` for the program filename so one compiled testbench runs the
entire test suite: `vvp tb_core +hex=tests/addi.hex`.

---

## Trace format and co-simulation

The single highest-leverage tool in core bringup. Emit the same one-line format
from the golden model and the RTL, then `diff`.

```
00000000 00500093 x1=00000005
00000004 00A00113 x2=0000000a
00000008 002081B3 x3=0000000f
```

`PC`, instruction word, and the architectural register write (omit or print
`x0=00000000` for instructions that write nothing). Keep it to exactly this
much — adding the ALU result or internal state makes the diff noisy without
adding localization.

Workflow:

```bash
python3 scripts/rv_model.py --trace program.hex > model.trace
vvp tb_core +hex=program.hex | grep -E '^[0-9a-f]{8} ' > rtl.trace
diff model.trace rtl.trace | head -20
```

The first differing line is the first instruction that behaved differently, and
its PC tells you exactly which instruction to look at. Nearly every core bug is
diagnosable this way in under a minute, without opening a waveform viewer.

**Randomized co-simulation** extends this: generate random instruction sequences,
run both, diff. The generator needs three constraints to be useful rather than
noisy — keep memory addresses inside the mapped data region, avoid writing the
stack pointer if the program uses one, and end the sequence with a terminator.
Random tests find interaction bugs that directed tests structurally cannot,
because nobody thinks to write a test where a load's result feeds a shift amount
that happens to be 32.

### When the traces disagree, suspect the oracle too

Co-simulation tells you the two implementations differ. It does not tell you
which one is wrong, and treating the model as automatically correct will send you
hunting through RTL for a bug that is not there. Three things can be at fault,
and they are distinguishable:

| Symptom | Likely culprit | How to confirm |
|---|---|---|
| Divergence at one instruction, RTL value is architecturally wrong per the spec | RTL | Hand-decode the instruction and compute the expected result from the ISA manual |
| Divergence at one instruction, RTL value is *correct* per the spec | Golden model | Same check — the manual is the real authority, not the model |
| Traces agree line for line but one ends earlier, or the last line differs | Testbench | Look at termination and flush timing, not at either implementation |

The third row is the one that wastes the most time, because it looks like a deep
core bug and is not. A testbench that ends simulation the moment it sees a
store to the exit address will terminate *during* that instruction's execute
cycle, before the store retires, so the final retire line never prints. The fix
is to latch the request and finish one instruction later — never to change the
RTL. `assets/tb_core.v` carries this fix and a comment marking why.

The rule: when a trace diverges, decode the instruction by hand and derive the
expected value from the specification before editing anything. The model is a
convenience, not an authority. The ISA manual is the authority.

---

## Test program conventions

**Termination and result reporting.** The `riscv-tests` convention writes a
result code to a magic address (`tohost`). Reproduce it with a single MMIO
register:

```asm
    li   t0, 0x20000000     # result register
    li   t1, 1              # 1 = pass, anything else = fail
    sw   t1, 0(t0)
1:  j    1b                 # hang; the testbench calls $finish
```

**Self-checking assembly** — each test compares against an expected value and
branches to a failure path that writes a distinguishing code, so a failing
regression tells you *which* check failed without a debugger:

```asm
    li   x1, 5
    li   x2, 10
    add  x3, x1, x2
    li   x4, 15
    bne  x3, x4, fail
    # ... more checks ...
pass:
    li   t0, 0x20000000
    li   t1, 1
    sw   t1, 0(t0)
    j    .
fail:
    li   t0, 0x20000000
    li   t1, 0
    sw   t1, 0(t0)
    j    .
```

**Building the hex image.** With a GNU toolchain:

```bash
riscv32-unknown-elf-as  -march=rv32im test.s -o test.o
riscv32-unknown-elf-ld  -Ttext=0x0 test.o -o test.elf
riscv32-unknown-elf-objcopy -O verilog test.elf test.hex
```

Without one — the common case on browser-based platforms —
`scripts/rv_model.py` includes a minimal assembler that covers RV32I, the four
multiply instructions, and custom R-type macros, and emits `$readmemh` format
directly.

`$readmemh` reads **one word per line** as hex with no `0x` prefix, and `//`
comments are allowed. A frequent silent failure is an image whose word order or
endianness does not match how the memory array is indexed — verify by
disassembling the first few words of the loaded array in the testbench before
trusting any test result.

---

## Architectural test suites

**`riscv-tests`** (Berkeley) — self-checking assembly, one ELF per instruction,
each writing pass/fail to `tohost`. The fastest path to broad ISA coverage, and
the `rv32ui-p-*` set maps directly onto a simple core with no privileged support.
Start here.

**`riscv-arch-test`** — the official Architectural Certification Tests. Much
stronger coverage, signature-based: the test writes a memory region, the
framework compares that signature against the Sail golden model.

> **Currency note:** `riscv-arch-test` moved to the **ACT4 framework**, and the
> older **RISCOF** tool is deprecated. Most tutorials and blog posts online still
> describe the RISCOF flow. Read the repository's current README before following
> any guide, and expect the plugin/config mechanism described in older material
> not to apply.

Both suites assume a toolchain and a way to run ELFs. If neither is available on
the target platform, the fallback that captures most of the value is: extract the
*test vectors* from the suites (they are readable assembly), re-express them as
directed tests in your own harness, and lean harder on randomized co-simulation.

**Neither suite covers custom extensions.** Those need known-answer vectors plus
model comparison — the CRC vectors in `isa-and-encoding.md` are the pattern.

---

## Formal verification with RVFI

`riscv-formal` proves ISA compliance over all reachable states, which simulation
cannot do. The core exposes an **RVFI** (RISC-V Formal Interface) port — a
superset of the retire-trace signals suggested above — and the framework generates
one bounded-model-check per instruction.

Cost: implementing RVFI (a day for a simple core, and mostly free if the retire
trace already exists), plus a SymbiYosys/Yosys toolchain. Return: it finds
corner-case bugs that random simulation misses entirely, particularly around
hazards and misaligned or unusual operands.

Worth it when the core is pipelined or has traps. For a straightforward
multicycle core with a working co-simulation flow, directed plus randomized
testing is usually sufficient, and the honest recommendation is to spend the time
on coverage instead.

---

## Coverage without SystemVerilog

No covergroups in Verilog-2001, but the information is still obtainable and it is
what tells you whether a passing suite means anything.

**Instruction coverage** — a counter array indexed by decoded opcode class,
incremented in the testbench on each retire, printed at the end:

```verilog
integer icount [0:63];                       // one bin per opcode[6:1]
always @(posedge clk)
    if (retire_valid) icount[retire_instr[6:1]] = icount[retire_instr[6:1]] + 1;
```

Extend the index to include `funct3` for per-instruction granularity. Printing
this table after a suite run immediately exposes the instructions nothing
exercises — usually `SRAI`, `BGEU`, `LHU`, and the custom extension.

**State coverage** — the same technique on the FSM state register, which proves
every state is reachable.

**Toggle coverage** — Verilator (`--coverage`) or a commercial simulator provides
it directly if available, and it is the fastest way to find whole modules nothing
touches.

**Cross coverage that matters most for a core**: instruction × operand class
(zero, negative, maximum), load/store × byte offset, and branch × taken/not-taken.
Three small counter arrays cover the space where the bugs actually live.

---

## Debug playbook

Symptom → most likely cause, ordered by how often each turns out to be the
culprit. Check in this order before opening a waveform.

| Symptom | Look at first |
|---|---|
| Core fetches address 0 forever | PC never updates: `pc_sel` default, or PC write not gated to WRITEBACK, or reset held |
| Every register reads 0 | `reg_write` never asserts, or the x0 read-mux comparison is inverted |
| First instruction correct, all later ones wrong | PC increment, or IR captured in the wrong state (see the mapping table in `microarchitecture.md`) |
| Loads return the *previous* load's data | Synchronous-memory latency off by one — address issued in the same state the data is consumed |
| Loads work at offset 0, fail at 1–3 | LSU byte-lane select, or store data not replicated across lanes |
| `LB` returns `0x000000FF` for `0xFF` | Sign extension using the wrong bit, or the signed/unsigned `funct3` decode swapped |
| Branch always taken (or never) | Comparator polarity, or `imm_b` bit-slicing, or branch condition evaluated against stale operand registers |
| Backward branches wrong, forward branches fine | `imm_b` sign extension |
| `MULHSU` wrong only when rs1 is negative | Operand extension to 33 bits (see `isa-and-encoding.md`) |
| `JALR` occasionally jumps one byte off | Missing `& ~1` on the target |
| Passes RTL sim, hangs after synthesis | Inferred latch in the FSM — a `case` or `if` path that leaves `next_state` unassigned |
| Passes RTL sim, fails gate-level sim | Unreset register read before written (X-propagation), or a reset-polarity mismatch between core and testbench |
| Random test fails, directed tests pass | An instruction interaction — get the trace diff; the first differing line names it |
| Works in the simulator, wrong on FPGA | `initial` blocks used for reset (FPGA-only behaviour), or a memory inferred as distributed RAM with different read timing |
| Everything is `x` after reset | Register file or memory not initialized in the testbench; add the initialization loop |

**The general procedure**, when the table does not resolve it: get a trace diff,
find the first differing instruction, then look at that instruction's operands in
the waveform for exactly the four cycles it occupies. Do not start by scrolling
the waveform — start by knowing which cycle to scroll to.

---

## Writing new testbenches

When a module appears that has no template here:

**Decide what the oracle is before writing stimulus.** Three options, in order of
preference: a behavioural expression in the testbench itself (works for the ALU,
comparators, immediate generation); the golden model (works for anything
instruction-level); or a hand-computed vector table (the only option for a custom
unit with no reference, and the reason known-answer vectors matter). A testbench
without an oracle is a waveform generator.

**Write the failing case first.** Feed the DUT a value you know is wrong and
confirm the testbench reports `FAIL`. A checker with an inverted comparison or an
unconnected DUT output passes everything, and this takes thirty seconds to rule out.

**Cover the boundaries before the middle.** For any N-bit value: 0, 1, all-ones,
the sign boundary, and the two values either side of it. Random values in the
middle of the range find far less per test than these five.

**Make it loop.** A testbench that runs one case per hand-written line stops
growing when you get bored. A testbench built around nested loops over the
parameter space keeps finding things — the LSU matrix above is 20-odd cases from
six lines of code.

**Print the summary line even when everything passes.** `RESULT: PASS` plus a
check count is what makes a regression script possible, and a check count of zero
is how you find out the stimulus loop never ran.

**Keep the testbench in the same language as the DUT.** Under a Verilog-2001
constraint the testbench goes through the same parser; a SystemVerilog testbench
that will not compile on the target platform is worth nothing regardless of how
good it is.
