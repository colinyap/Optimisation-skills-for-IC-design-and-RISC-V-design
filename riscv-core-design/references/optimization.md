# RISC-V Core Optimization

The optimizations that live in the RTL and the microarchitecture — the ones no
synthesis strategy, floorplan, or router setting can recover. Everything from
synthesis onward belongs to `ic-design-optimization`; read this file to decide
what to hand it.

## Contents
- [The performance equation](#the-performance-equation)
- [Deciding whether this file or the flow is the right lever](#deciding-whether-this-file-or-the-flow-is-the-right-lever)
- [CPI optimization](#cpi-optimization)
- [Critical path surgery](#critical-path-surgery)
- [Multiplier strategy](#multiplier-strategy)
- [Custom functional unit strategy](#custom-functional-unit-strategy)
- [Area optimization](#area-optimization)
- [Power and energy optimization](#power-and-energy-optimization)
- [The memory trap](#the-memory-trap)
- [Handoff to ic-design-optimization](#handoff-to-ic-design-optimization)
- [Optimization ladder](#optimization-ladder)

---

## The performance equation

```
        execution time = instruction_count × CPI × clock_period
```

Three terms, three owners:

| Term | Controlled by | Owned by |
|---|---|---|
| instruction count | the ISA and the compiler | mostly fixed; custom instructions move it |
| **CPI** | **the microarchitecture** | **this file — invisible to any PPA tool** |
| clock period | logic depth, then physical implementation | this file *and* `ic-design-optimization` |

The failure mode this equation exists to prevent: spending a week raising fmax
15% while a control change that would have cut CPI 15% sits undone, or worse,
taking a CPI hit to buy fmax and shipping a slower core with better-looking
timing reports.

**Custom instructions attack the first term**, and that is usually where their
value is. A CRC instruction that replaces an eight-instruction software inner
loop cuts the dynamic instruction count for that workload by roughly 8×, which no
amount of frequency work can match. When justifying a custom extension, measure
it in instructions eliminated per byte processed, not in gates added.

---

## Deciding whether this file or the flow is the right lever

`ic-design-optimization` classifies problems A–F. This table says which class
comes back here.

| Their diagnosis | Fix lives in | What to do |
|---|---|---|
| A — flow crash | flow | Stay there |
| B — constraint defect | flow (SDC) | Stay there |
| **C — RTL structural** | **here** | Critical path surgery, resource sharing, pipelining |

**Before applying any fix from this table, check it against `CPI x T_clk`.**
`ic-design-optimization` measures `T_clk` and cannot measure CPI, so a fix that
adds cycles will look like a clean win from that side of the boundary. Anything
that changes the number of cycles an instruction takes — extra FSM states, a
multi-cycle functional unit, a stall — must buy at least a proportional
frequency improvement to break even, and must then be re-verified: measured on
`assets/`, splitting EXECUTE moved CPI 4.00 to 5.00 *and* turned a passing
regression into a failing one. Check the forbidden-fix list from Phase G too;
when the spec mandates the microarchitecture, several rows of this table are
simply unavailable.
| D — physical / flow knob | flow | Stay there |
| E — signoff violation | flow | Stay there, unless caused by a memory inferred as flops |
| F — already acceptable | neither | Stop |

Two symptoms that look like D but are always C:

- **Setup slack more than ~30% negative after synthesis.** No strategy, density,
  or margin setting recovers that. It is logic depth, and it needs an RTL change.
- **Cell count an order of magnitude above expectation.** Almost always an
  inferred memory or an unintended multiplier. Knob tuning on a structurally
  wrong netlist is wasted effort.

---

## CPI optimization

In a multicycle core, CPI is a number you choose in the FSM. It is the cheapest
performance lever in the design and the one most often left on the table.

### Early exit (variable-length FSM)

Stores, branches, and jumps have nothing to do in WRITEBACK: the store committed
in EXECUTE, and the PC update can be performed at the end of EXECUTE just as
easily. Returning those instructions to FETCH one cycle early:

```verilog
S_EXEC: begin
    if (!ex_done)                next_state = S_EXEC;
    else if (no_writeback_needed) next_state = S_FETCH;   // store / branch / jump
    else                          next_state = S_WB;
end
```

Typical integer code is roughly 10% stores and 15% branches and jumps, so CPI
moves from 4.00 to about 3.75 — a 6% speedup for a few lines of control logic,
with no impact on the critical path.

**Check the specification first.** If it mandates uniform four-cycle execution,
this is a deviation, and an undocumented one will read as a bug. Implement it
behind a parameter (`parameter EARLY_EXIT = 0`) so both behaviours are available
and the deviation is explicit.

### Fetch-ahead

Driving the *next* PC onto the bus during WRITEBACK means the instruction is
already valid when FETCH begins, collapsing fetch and decode into one state and
taking CPI to roughly 3.0. It costs a next-PC computation on a tighter path and
some care around branches, where the next PC is not known until the condition
resolves — a mispredicted early fetch must be discarded, which is a small
pipeline flush in a machine that otherwise has no pipeline.

Worth doing only after the simpler wins, and only with the early-exit tests
already passing, because it makes state and bus timing interact.

### Multi-cycle units done right

A 32-cycle iterative multiplier in code that is 3% multiplies adds about 0.9 to
CPI — a 22% slowdown to save area. A 4-bit-per-cycle Booth multiplier costs about
0.2 CPI for most of the area saving. Compute this before choosing, using the
actual instruction mix of the target workload rather than a generic average; the
answer changes completely between integer control code and a DSP kernel.

### Do not confuse CPI with cycle count in a benchmark

If the scoring function measures wall-clock time on a fixed program, optimize
`CPI × T_clk`. If it measures fmax alone, CPI work scores nothing. Read the
scoring function — this is `ic-design-optimization`'s Phase 0 point and it
applies identically here.

---

## Critical path surgery

The paths that are actually longest in a small RISC-V core, in the order they
usually appear. Measure before acting — the intuition that arithmetic is the
slow part is wrong more often than not.

**1. The writeback result mux chain.** ALU, multiplier, custom unit, load data,
`pc+4`, and immediate all converge on one mux feeding the register file. With a
multiplier and a CRC unit in the mix, this mux is fed by the slowest of them, so
its input arrival time is the real problem, not the mux itself. Fixes: register
the slow unit's output so it arrives early in the next state, and use a one-hot
mux rather than a priority chain (`assign r = ({32{sel_alu}} & alu) | ({32{sel_mul}} & mul) | ...`).

**2. Memory output → decode → register read → operand register.** In Mapping B
(see `microarchitecture.md`) this whole chain happens in DECODE. Fixes: decode
only what DECODE needs (the register addresses come straight out of the
instruction word with no decode at all — route them directly and let the rest of
the control decode settle in parallel), and precompute the register file read
address mux off the raw instruction bits rather than off decoded signals.

**3. The ALU, when it contains the shifter.** A 32-bit barrel shifter is five mux
levels; combined with an adder and a result mux it is frequently the longest
arithmetic path. Fixes: build the shifter as a five-stage funnel with SLL, SRL
and SRA sharing one structure (reverse the input for left shifts, reverse the
output back — this is nearly free and eliminates a second shifter); and keep the
shifter out of the same mux level as the adder output.

**4. The adder.** Yosys infers a ripple-carry adder by default, which is 32 carry
levels. This is the classic case where a *flow* setting fixes an *RTL-looking*
problem: `SYNTH_ADDER_TYPE` in OpenLane selects a faster structure. Try that
before hand-writing a carry-lookahead adder, which is a large amount of code to
maintain for something the tool can do.

**5. Branch comparison feeding the PC mux.** If branch resolution and the next-PC
computation are in the same cycle, the path is compare → condition select → PC
mux → PC register. Fix: use a dedicated equality/magnitude comparator rather than
reusing the ALU's subtract output, which arrives late because it shares the adder.

**6. Address decode on the bus path.** Wide equality comparisons against full
32-bit region bases, in series with the memory access. Fix: compare only the
distinguishing high bits (see `microarchitecture.md`).

**A note on where not to look:** the register file read mux is a 32:1 mux and
looks expensive, but synthesis maps it well and it is rarely critical. The
immediate generator is pure wiring and never critical. Time spent optimizing
either is time not spent on the six paths above.

---

## Multiplier strategy

The largest single design decision in an RV32IM core. Decide with data, in this
order.

| Strategy | Latency | Relative area | fmax impact | Choose when |
|---|---|---|---|---|
| Single-cycle `*` | 1 cycle | largest | likely the critical path | Correctness bringup, always; keep it if timing closes |
| Radix-4 Booth, 4 b/cycle | 8 cycles | ~1/4 | negligible | Area-constrained, multiply-light workload |
| Shift-add, 1 b/cycle | 32 cycles | smallest | none | Very area-constrained, multiply-rare |
| Pipelined array (2–3 stages) | 1/cycle throughput | large | none | Multiply-heavy and throughput matters |

**Start with `*` and let synthesis infer.** Writing a Booth multiplier before
knowing whether the inferred one closes timing is premature, and Yosys plus ABC
produce a reasonable array multiplier. Then measure: if the multiplier is not the
critical path, stop.

**Collapse the three multipliers into one.** The naive `MULH`/`MULHSU`/`MULHU`
implementation instantiates three 33×33 multipliers and muxes the results —
roughly three times the area for no benefit. Mux the *operand extension* instead,
so one multiplier serves all four instructions:

```verilog
wire a_signed = (funct3 == 3'b001) || (funct3 == 3'b010);  // MULH, MULHSU
wire b_signed = (funct3 == 3'b001);                        // MULH only
wire signed [32:0] a_ext = {a_signed & a[31], a};
wire signed [32:0] b_ext = {b_signed & b[31], b};
wire signed [65:0] product = a_ext * b_ext;
// MUL -> product[31:0]; the three high variants -> product[63:32]
```

This is one of the few places where a small RTL change removes a large amount of
area with no downside, and it is worth doing even during bringup.

**When making it multi-cycle**, use the `ex_done` handshake already in the FSM
rather than adding states. And gate the operands (below) — an idle multiplier
whose inputs keep toggling burns power for nothing.

---

## Custom functional unit strategy

For a CRC unit or any similar block:

**Match the unit's latency to the cycle budget, not to elegance.** The parallel
CRC in `isa-and-encoding.md` is combinational because the FSM gives EXECUTE one
cycle. A bit-serial LFSR is smaller and is the textbook answer, and it is the
wrong answer here — it needs 8 or 32 cycles, which means either an `ex_done`
stall (acceptable) or an FSM redesign (not).

**If the widest variant is the critical path, give it more cycles rather than
restructuring the logic.** `CRC.W` is four chained byte blocks, ~32 XOR levels.
Splitting it into two cycles of two blocks each, using `ex_done`, halves the path
and costs one cycle on an instruction that is rare relative to loads and ALU ops.
Restructuring the XOR network to be shallower is possible but produces
hard-to-verify code for a smaller gain.

**Parameterize the constant, not the structure.** The polynomial is a
`parameter`; the reflection convention is not. Changing reflection changes the
circuit (shift direction, which bit is tested), so if the specification's
convention is uncertain, build both and select with a `generate`.

**Gate the inputs.** A custom unit that computes on every instruction and has its
output ignored 95% of the time is pure wasted dynamic power. See below.

---

## Area optimization

Ranked by return, for a small core:

**1. Do not infer memories as flip-flops.** See [the memory trap](#the-memory-trap).
This dominates everything else by orders of magnitude when it happens.

**2. One multiplier, not three.** See above.

**3. Share the adder.** The classic multicycle machine uses a single adder for
ALU operations, PC increment, and address computation, muxing the operands per
state. It saves two 32-bit adders — meaningful in a core this size — at the cost
of a wider operand mux in front of the adder, which lengthens the arithmetic
path. Worth doing when area is scored and fmax is not; skip it when fmax is
scored, because the operand mux lands directly on the critical path.

**4. Register file structure.** `regs[1:31]` rather than `[0:31]` removes 32
flops for free. Beyond that, the file is ~992 flip-flops and is typically the
largest block after the multiplier; the only large win available is replacing it
with a macro, which needs a 2-read/1-write structure most single-port macros
cannot provide. Usually the right answer is to accept the area.

**5. RV32E.** If the specification permits it, halving the register file to 16
entries removes ~500 flops — the single largest area saving available in the core
proper. It is an ISA change, so it needs to be sanctioned, not assumed.

**6. Control encoding.** Binary-encoded state and control saves flops over
one-hot; one-hot saves decode logic and is faster. At four states the difference
is negligible — do not spend time here.

---

## Power and energy optimization

`ic-design-optimization` profiles P4 and P5 cover the flow side. The RTL side:

**Operand isolation (data gating)** is the highest-value technique in a core with
large functional units. The multiplier's combinational logic toggles on every
instruction whose operands happen to change, whether or not the result is used:

```verilog
// Hold multiplier inputs stable unless this is actually a multiply.
wire [31:0] mul_a = is_mul ? rs1_q : mul_a_hold;
wire [31:0] mul_b = is_mul ? rs2_q : mul_b_hold;
```

Or register the operands with an enable, which is cheaper still. For a 32×32
array multiplier this removes the large majority of its dynamic power on
non-multiply instructions, and multiplies are typically a few percent of the
instruction stream.

**Clock gating** on the register file write port and on the operand registers.
Synthesis-inserted clock gating is not enabled by default in all flows, so
express the enable clearly (`if (we) q <= d`) and confirm in the netlist whether
the tool inserted a gate or a feedback mux. Both are correct; only one saves
clock power.

**Reduce switched capacitance on wide buses.** The 32-bit result mux and the bus
address are the widest, highest-activity nets in the design. Keeping the bus
address stable when no access is in flight (rather than letting it follow the PC
through every state) is a small change with a measurable effect.

**Energy per operation, not power.** A multicycle core drawing less instantaneous
power but taking 4 cycles per instruction may use more energy per program than a
pipelined core that finishes sooner and idles. Which one the objective wants is
`ic-design-optimization`'s P4-versus-P5 distinction, and at sky130's low leakage
the answer is more often "finish fast and idle" than advice written for modern
nodes suggests.

**The clock tree is a large share of core power.** Fewer flops means a smaller
tree — another reason the register file and any inferred memory dominate the
power budget, not just the area budget.

---

## The memory trap

Worth its own section because it ends more core projects than every other issue
combined.

```verilog
reg [31:0] mem [0:16383];      // "64 KB of RAM"
```

Synthesized as-is, that is **524,288 flip-flops**. For scale, the entire rest of
a multicycle RV32IM core is on the order of 5,000–15,000 cells. Synthesis will
either run for hours and produce something that cannot be placed, or fall over.

**Know your flop budget before you synthesize.** Count it by hand from the
architectural state; anything above it is inferred storage you did not intend:

| State | Arithmetic | Flops |
|---|---|---|
| Register file (x1–x31; x0 is a constant, not storage) | 31 x 32 | 992 |
| Program counter | 1 x 32 | 32 |
| Instruction register | 1 x 32 | 32 |
| Operand registers A and B | 2 x 32 | 64 |
| ALU / memory-data result register | 1 x 32 | 32 |
| FSM state | 4 states | 2–4 |
| **Total architectural state** | | **~1,160** |

A multicycle RV32IM core should land near 1,200 flops and 5,000–15,000 total
cells. If synthesis reports 30,000 flops you have inferred a small memory; if it
reports 500,000 you have inferred a large one. If it reports 700 you have lost
architectural state — usually a register file optimized away because its outputs
are unconnected, which means your top level is not wired up.

How to tell the memory trap has happened: the post-synthesis flop count is in the
hundreds of thousands, or synthesis runtime jumps from minutes to hours. Check
the flop count before looking at any other metric — this is exactly `ic-design-optimization`'s
"sanity-check scale" step, and a core is the design class where it matters most.

The three correct options:

1. **Keep memory outside the hardened block.** The core exposes a bus port; the
   memory is a separate macro, an FPGA block RAM, or testbench-only. Almost always
   the right answer for a competition or coursework core, and it also makes the
   core reusable.
2. **Use a memory macro** — DFFRAM or OpenRAM on sky130 — instantiated
   explicitly, with the halo, PDN, and routing-layer constraints that
   `ic-design-optimization` covers under macro integration.
3. **Shrink it drastically.** A few hundred words of scratchpad as flops is
   viable; tens of kilobytes is not.

For simulation, a behavioural array is correct and expected. The trap is carrying
the same file into synthesis. Keep the simulation memory in a separate file that
the synthesis file list excludes, and the mistake becomes impossible rather than
merely unlikely.

---

## Handoff to ic-design-optimization

State these when handing off, because each one changes that skill's Phase 0
answers:

| Item | Why it matters there |
|---|---|
| Objective, ranked | Selects the optimization profile (P0–P7) |
| Scoring function, if a contest | Tells it what to spend area/power on |
| **CPI** | Without it, clock-period work optimizes the wrong term |
| Target clock period and whether it is externally fixed | Determines whether to relax the clock |
| Known critical path (module and depth) | Skips a diagnosis step |
| Cell and flop count from a clean synthesis run | Their baseline and scale sanity check |
| Whether memories are inside or outside the block | Changes floorplan, utilization, and macro handling entirely |
| What re-verification costs you | Determines how expensive an RTL-level fix is |

And carry back their diagnosis: a class C result means returning to
[critical path surgery](#critical-path-surgery) rather than continuing to tune
flow knobs.

---

## Optimization ladder

In order. Do not start a rung before the one below it is done and measured.

1. **Correct.** All Phase D–F tests pass. Nothing below is meaningful otherwise.
2. **Structurally sane.** No inferred memories, no latches, cell count plausible.
   This is the Phase G gate.
3. **Free wins.** One multiplier instead of three; `regs[1:31]`; one-hot result
   mux; shared shifter. Each is a small, local, verification-cheap change.
4. **Measure.** Synthesize, read the critical path, count cells. Everything above
   this line is done blind; everything below must be data-driven.
5. **CPI.** Early exit, then the multi-cycle-unit tradeoff computed against the
   real instruction mix. Usually the largest single performance gain available.
6. **Critical path.** The six paths above, in whatever order the timing report
   says — not in the order they are listed here.
7. **Flow.** Hand off to `ic-design-optimization`. Most remaining gain is there.
8. **Re-verify.** Every RTL change made for rungs 3, 5, and 6 invalidates
   verification. Re-run Phase D–F, then gate-level.
9. **Stop.** When the objective is met, say so. Further tuning against a met
   objective is the most common way a working design becomes a broken one.
