---
name: riscv-core-design
description: Front-end design and verification of RISC-V processor cores in Verilog — spec capture, golden reference model, microarchitecture and block diagrams, RTL, and testbench methodology — then hands off to ic-design-optimization for PPA. Covers multicycle FSM cores (Fetch/Decode/Execute/Writeback), 5-stage pipelines, and scaling to caches, CSRs/traps, and superscalar. Use whenever the user is building, debugging, verifying, extending, or documenting a RISC-V core or its parts — datapath, ALU, register file, immediate gen, control FSM, LSU/load-store unit, multiplier, CRC or custom unit, address decoder, memory map, MMIO. Trigger on RV32I, RV32IM, M-extension, MUL/MULH/MULHSU/MULHU, custom opcodes, assembler macros, decode tables, hazards, forwarding, CPI, riscv-tests, riscv-arch-test/ACT, riscv-formal/RVFI, Spike, or gate-level core sim. Also when a core misses timing or has an odd cell/flop count after synthesis. Also for ChipInventor / ChampionCHIP work and coursework wanting RTL + block diagram + testbench.
---

# RISC-V Core Design (front-end RTL and verification)

A processor is the point where a specification, a microarchitecture, and a
verification plan have to agree. Most core projects fail not because the RTL is
hard but because one of those three was skipped: the spec was assumed instead of
read, the microarchitecture was never drawn, or the testbench was written after
the bug.

This skill enforces the order that avoids that: **read the authoritative spec →
build an executable golden model → draw the microarchitecture → write RTL
bottom-up with a testbench per module → verify at instruction level, then program
level → gate on synthesis sanity → hand off to `ic-design-optimization` for PPA
→ re-verify at gate level.**

`ic-design-optimization` owns everything from synthesis onward (OpenLane/sky130,
timing closure, congestion, DRC/LVS, PPA profiles). This skill owns everything
before it, plus the RISC-V-specific optimization decisions that PPA tuning cannot
recover — CPI, logic depth, resource sharing, and memory structure. **The two are
designed to be used together.** When work reaches synthesis, read
`ic-design-optimization` rather than reasoning about OpenLane variables here.

Detailed material lives in `references/`. Read the relevant file when you reach
that phase rather than loading everything up front:

| File | Read when |
|---|---|
| `references/isa-and-encoding.md` | You need exact instruction encodings, immediate bit-slicing, opcode/funct tables, RV32I + M semantics, or you are designing a custom extension and its assembler macros. **Read at Phase A.** |
| `references/microarchitecture.md` | You are choosing or building a microarchitecture — the 4-state multicycle FSM in full, datapath, control-signal table, LSU, memory map/decoder, plus the scaling ladder to pipelined, superscalar, OoO, caches, CSRs and traps. **Read at Phase C.** |
| `references/verification.md` | You are writing any testbench, choosing a verification strategy, or debugging a failing test. Covers unit TBs, core TBs, golden-model co-simulation, riscv-tests/ACT, formal/RVFI, coverage. **Read at Phase B and D.** |
| `references/optimization.md` | You need RISC-V-specific PPA levers — CPI reduction, critical-path surgery, resource sharing, multiplier strategy, memory macro decisions. **Read at Phase G, before handing off.** |
| `references/resources.md` | You need to find an authoritative source: specs, reference cores, tools, test suites, textbooks, CRC references. **Read at Phase A.** |
| `assets/` | Runnable, verified Verilog-2001: a complete four-state multicycle RV32IM+CRC core (`rv32_multicycle.v`), a simulation SoC (`rv32_soc_sim.v`), three testbench templates, a self-checking test program, and a `Makefile` regression loop. Copy and adapt rather than writing from scratch. |
| `scripts/rv_model.py` | Executable golden model, assembler, and hex-image builder for RV32I + M + a custom extension. The oracle for co-simulation. |
| `scripts/gen_vectors.py` | Generates known-answer vectors (immediates, multiplier corners, CRC) as markdown or `$readmemh` files. **Use it instead of hand-writing expected values** — a wrong vector makes correct hardware look broken. |

Everything in `assets/` compiles under `iverilog -g2001` and passes; the core and
the golden model produce byte-identical retire traces on the bundled self-test.
That makes them a working baseline you can diff against, not just examples.

---

## Core operating principles

**1. The specification you were given outranks anything in this skill.** Every
encoding, memory map, and cycle count here is a well-researched default, not an
authority. A course block guide, a competition spec, or a PDK document is ground
truth. Where this skill and a provided document disagree, the document wins —
say so explicitly and record the deviation. This matters most for **custom
extensions**, where there is no standard to fall back on.

**2. Build the golden model before the RTL.** An executable reference
implementation (Python or C, a few hundred lines) written from the spec is the
cheapest artifact in the project and the most valuable. It is the oracle for
every subsequent test, it forces you to read the spec precisely, and it catches
specification misunderstandings while they still cost minutes. Writing RTL first
means debugging two unknowns against each other.

**3. Verify bottom-up; integration debug cost is superlinear.** A bug caught in a
50-line ALU testbench takes minutes. The same bug found in a 200-instruction
program running on the full core takes hours, because you must first localize it.
Every module gets a self-checking testbench and passes it before integration.
This is not process ceremony; it is the single highest-leverage habit in RTL work.

**4. Correctness first, then measure, then optimize.** Do not choose a multiplier
architecture, a shifter structure, or an adder type before you have a working
core and a synthesis report telling you where the critical path actually is.
Premature microarchitectural optimization in a core almost always targets the
wrong path — the arithmetic looks expensive, but the decode-to-writeback mux
chain is usually longer.

**5. `CPI × T_clk` is the real metric, not either half.** Execution time is
`instructions × CPI × clock period`. Halving the clock period is worthless if it
costs a cycle per instruction. In multicycle cores, CPI is a *design* parameter
you control directly in the FSM — it is usually the cheaper of the two levers,
and it is invisible to any downstream PPA tool. Decide it deliberately.

**6. Never infer large memories as flip-flops.** `reg [31:0] mem [0:16383]`
synthesizes to 512k flip-flops. On sky130 this is not "large," it is a design
that will never place, route, or finish. Memory arrays belong in a macro
(DFFRAM/OpenRAM) or outside the hardened block entirely, behind a bus port. This
single mistake kills more student and competition cores than every timing issue
combined — check for it before the first synthesis run.

**7. Verilog-2001 is a real constraint, not a stylistic one.** If the platform
says Verilog and not SystemVerilog, then `logic`, `always_ff`, `always_comb`,
`typedef enum`, packed structs, interfaces, `unique case`, `assert`, `$error` and
`$fatal` are all unavailable — including in testbenches, which run through the
same parser. See the Verilog-2001 discipline section below. Code copied from a
SystemVerilog reference core will not compile, and the error messages are
frequently unhelpful.

**8. A trace is worth a hundred waveform screenshots.** Instrument the core to
print one line per retired instruction (PC, instruction, disassembly, register
write). Diffing that trace against the golden model's trace localizes a failure
to a single instruction in seconds. Reaching for GTKWave before you have a trace
diff is a common and expensive habit.

**9. Deliverables are part of the design.** When the grading criteria or spec
name block diagrams, testbenches, and simulation evidence, those are not
documentation of the work — they *are* the work being assessed. Budget for them
from the start and generate them from the design rather than reconstructing them
at the end.

---

## Scope boundary

This skill covers **front-end design and functional verification of RISC-V
processor cores in Verilog**. Where guessing would be worse than saying so:

- **Physical implementation and PPA closure** — synthesis strategy, floorplan,
  placement, CTS, routing, DRC/LVS, timing closure. That is
  `ic-design-optimization`. This skill hands off to it at Phase G and takes the
  design back at Phase I.
- **Analog, mixed-signal, and custom cell layout.** Entirely different discipline.
- **Software toolchain internals.** Using the RISC-V GCC toolchain, writing
  assembler macros, and building hex images are covered. Modifying GCC/LLVM
  backends to natively emit a custom instruction is not.
- **Operating-system and firmware bring-up.** Booting Linux needs an MMU,
  privileged spec Volume 2 compliance, and a device tree — all far beyond this
  skill's coverage, and the honest answer is to use a proven core (CVA6, Rocket).
- **Formal proof development.** Running `riscv-formal` against a core is covered;
  writing bespoke SVA property sets and proving them is not — and note that SVA
  is unavailable under a Verilog-2001 constraint anyway.
- **RISC-V ratification process and profile compliance certification.** The
  official position on what a compliant core must implement changes; read the
  current specification rather than anything cached here.

When a request falls outside this boundary, name what would actually be needed
instead of producing confident-sounding guidance from adjacent knowledge.

---

## Phase A — Specification capture (gate; do not skip)

Nothing downstream is worth doing against a guessed specification. Produce a
written spec table before any RTL. Read `references/isa-and-encoding.md` and
`references/resources.md` here.

**Collect the authoritative sources, in this order of precedence:**

1. The **project's own documents** — block guide, memory-map document, grading
   rubric, platform constraints. Ask for them by name if not provided; they
   contain the custom parts that exist nowhere else.
2. The **RISC-V unprivileged ISA specification** for standard instructions.
3. This skill's reference files as a well-researched default where 1 and 2 are
   silent.

**Then write down, explicitly:**

- **Instruction list**, one row per instruction: mnemonic, opcode, funct3,
  funct7, format, operation in one line of pseudocode. This table is the contract
  between the golden model, the RTL, and the tests. Generate it, do not
  improvise it — `riscv-opcodes` produces it mechanically for standard extensions.
- **Custom extension encoding**, if any: which custom opcode space, field layout,
  exact semantics, and what happens on reserved encodings. Flag every field you
  inferred rather than read.
- **Memory map**: each region's base, size, access width rules, and whether it is
  readable/writable/executable. Note which regions the load-store path must reach
  and which the fetch path must reach — they are often not the same set.
- **Reset behaviour**: reset vector, register file state after reset, reset
  polarity and synchronicity.
- **Cycle model**: cycles per instruction, and whether it is uniform.
- **Unsupported cases and their behaviour**: misaligned access, illegal
  instruction, unmapped address. "Undefined" is an acceptable answer only if you
  write it down.
- **Open questions**, with the assumption you are proceeding on. Route these to
  whoever owns the spec. Listing an assumption costs one line and prevents a
  rewrite.

**Do not skip the deliverables audit.** If the project is graded, extract the
grading criteria into a checklist now and keep it visible. A core that scores on
front-end correctness and verification should not receive area optimization
effort until those are complete.

---

## Phase B — Golden reference model

Write an executable model of the ISA before writing RTL. `scripts/rv_model.py`
is a working starting point covering RV32I + M plus a parameterized custom-unit
hook; extend it rather than starting over. Read `references/verification.md`.

The model must be able to: execute a hex/ELF image, dump the architectural state
(32 registers, PC, and touched memory) after each instruction, and emit a
one-line-per-instruction trace in the same format the RTL testbench will emit.
That last requirement is what makes co-simulation a `diff` rather than a project.

Validate the model itself against `riscv-tests` or Spike before trusting it. An
unvalidated oracle is worse than none, because it makes the RTL look wrong.

---

## Phase C — Microarchitecture and block diagram

Read `references/microarchitecture.md`. Decide and document, in this order:

1. **Execution model** — multicycle FSM, pipelined, or something further up the
   ladder. Driven by the spec and by the `CPI × T_clk` target, not by ambition.
   If the spec names the model (for example, a uniform four-state
   Fetch/Decode/Execute/Writeback FSM), implement exactly that; a "better"
   microarchitecture that does not match the specification scores zero.
2. **State table** — every state, its outputs, and its transition conditions.
3. **Datapath block diagram** — every register, functional unit, and mux, with
   bus widths labelled. Name the mux select signals; they become your control
   signals.
4. **Control signal table** — one row per control signal, one column per state or
   instruction class. Filling this table *is* the control unit design; the RTL
   afterwards is transcription. Blank cells are the bugs you would otherwise find
   in integration.
5. **Bus and arbitration plan** — which unit drives the memory port in which
   cycle. In a multicycle core sharing one memory port between fetch and
   load/store, the FSM state *is* the arbiter, and this is the main structural
   reason multicycle is being asked for.

Produce the diagram as a real artifact, not a mental model. It is usually a
graded deliverable, it is the fastest way to get a design review, and drawing it
reliably exposes a missing mux.

**How to produce it.** Do not freehand it and do not describe it in prose. Derive
it mechanically from the control signal table, which already contains every mux
and its selects:

1. One box per module instance, labelled `instance : module_name`.
2. One arrow per wire in the top-level netlist, labelled `name[msb:lo]`. If a
   signal exists in the RTL and not on the diagram, the diagram is wrong.
3. Draw the shared memory port once, with the arbitration annotated on it
   (`FETCH: PC | EXECUTE: alu_result`). This single annotation is what a reviewer
   looks for first in a multicycle design.
4. Keep the FSM as a separate state-transition bubble diagram. Mixing datapath
   and control on one sheet is the most common reason a diagram is unreadable.

Text-based formats survive review better than drawing tools because they diff.
Mermaid `flowchart LR` or Graphviz `digraph` both render on most platforms and in
most documents. Generate the datapath diagram *from* the control table so the two
cannot drift apart; if you edit one by hand, regenerate the other.

If the target platform has a schematic or block-editor front end, the diagram is
not a deliverable *about* the design — it is the design entry itself, and the
block boundaries you choose here become the module boundaries you must live
with. Choose them so each block has an independently testable interface.

---

## Platform constraints — check before Phase D

Phases D through F assume you can run a simulator on demand and loop in seconds.
Confirm that assumption before you rely on it, because the whole verification
strategy forks on the answer.

**If you have a local simulator** (Icarus, Verilator, ModelSim, or a platform
that exposes one), use the workflow as written: a one-command regression, run
after every edit. `assets/Makefile` is that loop.

**If the platform is browser-hosted with a slow, queued, or manual run button**,
the cost of a simulation goes from seconds to minutes and the whole economics
change. Adapt:

- **Batch your checks.** One testbench that runs every module's tests and prints
  a single summary beats eight testbenches you must launch individually.
- **Front-load the oracle.** Generate expected values offline with the golden
  model and embed them as `$readmemh` vector files, so a run is one comparison
  pass rather than an interactive debug session.
- **Make every run print a verdict.** When a run costs minutes, a testbench that
  ends without `RESULT: PASS` or `RESULT: FAIL` has wasted the whole cycle.
- **Increase the work per run.** Widen loops and add cases until a single
  invocation exercises everything you currently believe; you are paying for the
  launch, not the cycles.
- **Keep a local mirror if the language allows it.** Verilog-2001 that runs on
  the platform generally also runs under Icarus, which is a small install. Debug
  locally at full speed, then run the platform simulator to confirm. Treat the
  platform as the authority and the local run as the fast path.

Do not let a slow simulator push you into skipping unit tests. The integration
debug it causes is far more expensive than the runs it saves.

---

## Phase D — Bottom-up RTL and unit verification

Read `references/verification.md` and copy templates from `assets/`.

Build in dependency order, and **do not start a module until the previous one
passes its testbench**:

1. Register file → 2. Immediate generator → 3. ALU → 4. Branch comparator →
5. Multiplier → 6. Custom unit (CRC or other) → 7. LSU → 8. Address decoder →
9. Control FSM → 10. Core integration.

Each module gets a self-checking testbench that reports a pass/fail count and
exits non-silently. "It looks right in the waveform" is not a passing test — a
testbench that cannot fail has not tested anything.

For each module, the testbench covers: every operation, the boundary values
(0, 1, −1, `0x8000_0000`, `0x7FFF_FFFF`, all-ones), the architecturally special
cases (x0 behaviour, shift amounts ≥ 32, signed/unsigned boundaries), and — where
a model exists — randomized comparison against the golden model.

---

## Phase E — Integration and instruction-level bringup

Bring instructions up one at a time, in this order, because each group depends on
the previous group working:

1. `ADDI` alone (proves fetch, decode, immediate, ALU, writeback, PC increment)
2. Remaining OP-IMM, then OP (register-register ALU)
3. `LUI`, `AUIPC`
4. Loads and stores, every width and every byte offset
5. Branches, all six, taken and not-taken
6. `JAL`, `JALR` (check the mandatory `JALR` LSB clear)
7. M-extension multiply
8. Custom extension

Keep a checklist of which instructions pass. At each step, diff the RTL trace
against the golden-model trace; the first differing line names the bug.

---

## Phase F — Program-level and compliance verification

Once single instructions pass, the failures that remain are interaction bugs, and
they need real programs. In increasing order of strength:

1. **Directed programs** — a hand-written loop, a function call with a stack, a
   memory copy, a CRC over a known buffer.
2. **Randomized co-simulation** — generate random instruction sequences, run
   both the model and the RTL, diff the traces. This finds far more than directed
   tests per unit of effort.
3. **Architectural test suites** — `riscv-tests` for a quick self-checking pass,
   and `riscv-arch-test` for real ISA coverage. Note that **RISCOF is deprecated
   and replaced by the ACT4 framework** in current `riscv-arch-test`; check the
   repository's current instructions rather than following older tutorials.
4. **Formal**, if the toolchain allows — `riscv-formal` via the RVFI interface
   proves properties no amount of simulation can. Requires SymbiYosys.

Custom extensions are covered by none of these suites. They need directed tests
built from known-answer vectors plus randomized comparison against your model —
see the CRC known-answer vectors in `references/verification.md`.

---

## Phase G — Synthesis sanity gate (handoff to `ic-design-optimization`)

Before any PPA work, confirm the design is synthesizable and structurally sane.
Read `references/optimization.md` for the RISC-V-specific decisions to make here;
everything about the flow itself belongs to `ic-design-optimization`.

Gate criteria — all must pass before optimization begins:

- **Lint clean**, or every remaining warning explained. Width mismatches and
  incomplete sensitivity lists are real bugs, not noise.
- **Zero inferred latches.** Any latch in a core datapath is a bug.
- **No unintended memory inference.** Check the flip-flop count against your
  expectation before believing any other number (principle 6).
- **Cell count plausible.** A multicycle RV32IM core with a 32×32 register file
  and no memories lands roughly in the 5k–20k cell range on sky130 depending on
  the multiplier. An order of magnitude outside that band means something
  structural is wrong, and no knob tuning will fix it.
- **Critical path identified and understood** — which module, how many logic
  levels. You need this before choosing between the multiplier strategies.
- **Post-synthesis netlist simulates**, running the same tests as the RTL.

Then hand off. **Read `references/handoff.md` and assemble the handoff packet
first** — it lists every field `ic-design-optimization` Phase 0/1 asks for by
name, the objective translation that keeps CPI from being optimized away, and
the forbidden-fix list for specs that mandate a microarchitecture. A partial
handoff makes the receiving skill guess, and the thing it guesses wrong is
usually throughput.

Two things that must cross the boundary or the optimization is aimed wrong:

- **The objective, translated.** `ic-design-optimization` optimizes frequency,
  area, and power; it has no concept of instruction throughput. State the goal
  as *"minimize `T_clk` subject to CPI staying at N"* and name N. Time per
  instruction is `CPI x T_clk`, and you own the CPI term.
- **The forbidden-fix list.** When the spec mandates the microarchitecture, some
  legitimate class-C fixes are out of bounds — adding FSM states to a mandated
  uniform-length core, pipelining a mandated multicycle core, dropping an
  instruction. The optimization skill cannot know this. Principle 1 governs.

Then follow `ic-design-optimization` Phase 0 onward.

---

## Phase H — PPA optimization

Owned by `ic-design-optimization`. Two things to carry across the boundary:

- **Some PPA problems are only fixable here, in the RTL.** That skill classifies
  a problem as class C (RTL structural) — excessive logic depth, high fanout,
  unintended inference, poor resource sharing — and the fix then belongs back
  here in `references/optimization.md`, not in more flow knobs.

  Watch for the return trip by symptom, not by label: its diagnosis playbook is
  indexed by what you observed, and the class letters appear only in its main
  SKILL.md, so nothing in the playbook will tell you to come back. These are the
  sections that mean "return to RTL": *setup WNS badly negative* (worse than ~20%
  of the period, where no knob will close it), *cell count far higher than
  expected*, *unintended latches*, and *unmapped cells after synthesis*. Land on
  any of those and the next move is an RTL change here — evaluated against the
  `CPI x T_clk` rule and the forbidden-fix list from Phase G.
- **Any RTL change invalidates verification.** Re-run Phase D–F tests after every
  RTL edit made for PPA reasons. This is the most commonly skipped step in
  optimization and the most expensive one to skip.

---

## Phase I — Post-optimization re-verification

Gate-level simulation of the final netlist against the same testbenches, plus
SDF-annotated simulation if timing is critical. Detail lives in
`ic-design-optimization` Phase 4; the RISC-V-specific point is that your
instruction-level test suite and trace diff work unchanged at gate level, so
reuse them rather than writing something new. A core that passes RTL simulation
and fails gate-level simulation usually has an X-propagation or reset problem,
not a logic problem.

---

## Phase J — Deliverables

Assemble against the Phase A rubric checklist: block diagrams, control-signal
table, RTL with readable module boundaries, testbench sources, simulation logs
and waveform captures, test-coverage summary, and a results table (cell count,
area, fmax, CPI, and the PPA numbers if Phase H ran). Say plainly which tests
pass, which fail, and what is unimplemented — a documented gap reads as
engineering judgement; an undocumented one reads as a bug.

---

## Verilog-2001 discipline

When the platform forbids SystemVerilog, these substitutions apply throughout,
**including in testbenches**:

| Instead of | Use |
|---|---|
| `logic` | `reg` in procedural contexts, `wire` for continuous assignment |
| `always_ff @(posedge clk)` | `always @(posedge clk)` |
| `always_comb` | `always @(*)` |
| `typedef enum` for states | `localparam` constants + a plain `reg [N-1:0] state` |
| packed structs / interfaces | explicit signals, or concatenation with named `localparam` bit offsets |
| `unique case` / `priority case` | `case` with a mandatory `default` |
| `assert`, `$error`, `$fatal` | `if (cond) begin $display("ERROR: ..."); errors = errors + 1; end` |
| `int`, `bit`, `byte` | `integer`, `reg`, `reg [7:0]` |
| `.*` port connections | explicit named port connections |
| `$urandom_range(a,b)` | `a + ({$random} % (b-a+1))` — note `$random` is signed |

Still available and worth using: `generate`/`genvar`, named parameter overrides
`#(.WIDTH(32))`, `$signed`/`$unsigned`, `$readmemh`/`$readmemb`, `$display`,
`$monitor`, `$dumpfile`/`$dumpvars`, `$time`, `$finish`, `for` loops with an
`integer` inside `always` blocks, and `localparam`.

Two rules that prevent most synthesis-simulation mismatches: **non-blocking `<=`
in sequential blocks, blocking `=` in combinational blocks**, and **assign a
default value to every output at the top of every `always @(*)` block** so no
branch can leave a signal unassigned.

---

## When time is short

Under deadline the temptation is to cut verification. Cut scope instead: a
smaller instruction set that is provably correct beats a full one that is
probably correct, and it is worth far more marks. Order the remaining work by
confidence gained per hour, which is the verification pyramid read as a schedule:

| Order | Work | Why it is this high |
|---|---|---|
| 1 | Golden model + trace co-simulation on one directed program | Catches the largest class of bugs per hour spent; localizes to a single instruction |
| 2 | Unit tests for the LSU and the decoder | The two densest bug sites; both are pure combinational and cheap to test exhaustively |
| 3 | The synthesis sanity gate (Phase G) | A design that will not synthesize scores nothing regardless of simulation results |
| 4 | Remaining unit tests | Diminishing returns once co-simulation is clean |
| 5 | Randomized co-simulation | High value but only after directed tests pass |
| 6 | Architectural suites, formal | Highest assurance, highest setup cost |

Deliver the diagram and the simulation evidence for whatever *is* finished.
An unreported passing test is worth the same as a failing one.

---

## Reporting results

Lead with state, not with narration. Structure:

1. **Where the design is** — which phase, which instructions pass, which fail.
2. **The single most important issue** and its root cause, with the evidence.
3. **The next action**, with what it will change and how you will know it worked.
4. **Deferred items**, so nothing silently drops.

When presenting RTL, present it as files with clear module boundaries, not as
inline fragments — a core is a multi-file artifact and reviewing it as prose does
not work. Quantify wherever the data allows, and say plainly when the design is
correct and further work is not the best use of the remaining time.
