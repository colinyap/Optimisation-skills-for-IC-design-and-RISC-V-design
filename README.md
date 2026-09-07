# RISC-V Core Design + IC Design Optimization Skills

Two complementary skills that together cover the full path from a RISC-V
specification to verified, optimized silicon on the OpenLane / sky130
open-source flow.

| Skill | Invocation | Owns |
|---|---|---|
| **riscv-core-design** | `/riscv-core-design` | Front-end: spec capture, golden model, microarchitecture, Verilog RTL, functional verification |
| **ic-design-optimization** | `/ic-design-optimization` | Back-end: synthesis through GDSII, timing closure, congestion, DRC/LVS, PPA optimization |

The boundary between them is **synthesis**. Everything before it (and everything
about *what the hardware does*) belongs to `riscv-core-design`; everything from
synthesis onward (and everything about *how fast / small / low-power the layout
is*) belongs to `ic-design-optimization`. They are designed to be used together:
`riscv-core-design` hands off at its synthesis sanity gate, and
`ic-design-optimization` hands back when a problem turns out to be
RTL-structural.

---

## How the two skills fit together

```
                riscv-core-design                          ic-design-optimization
 ┌──────────────────────────────────────────────┐   ┌───────────────────────────────────────────┐
 │ A  Specification capture (gate)              │   │ 0  Establish objective (gate)             │
 │ B  Golden reference model                    │   │ 1  Initial analysis + classification A–F  │
 │ C  Microarchitecture + block diagram         │   │ 2  Planning (time budget, written plan)   │
 │ D  Bottom-up RTL + unit testbenches          │   │ 3  Execution: constraints → synthesis →   │
 │ E  Integration, instruction-level bringup    │──▶│    floorplan → placement → CTS → route    │
 │ F  Program-level + compliance verification   │   │ 4  Post-execution verification            │
 │ G  Synthesis sanity gate  ── HANDOFF ────────┼──▶│    (corners, GL sim, SDF, LEC, DRC/LVS)   │
 │ H  PPA work (owned by the other skill)       │◀──│    class C problems return to RTL         │
 │ I  Gate-level re-verification                │◀──┼── optimized netlist comes back            │
 │ J  Deliverables                              │   │                                           │
 └──────────────────────────────────────────────┘   └───────────────────────────────────────────┘
```

Two things must cross the handoff boundary or the optimization will be aimed
wrong:

1. **The objective, translated.** `ic-design-optimization` optimizes frequency,
   area, and power — it has no concept of instruction throughput. State the goal
   as *"minimize `T_clk` subject to CPI staying at N"* and name N. Execution
   time is `instructions × CPI × T_clk`; the front-end skill owns the CPI term.
2. **The forbidden-fix list.** When the spec mandates a microarchitecture (e.g.
   a uniform four-state multicycle FSM), some legitimate fixes are out of
   bounds — adding FSM states, pipelining, dropping an instruction. The
   optimization skill cannot know this on its own.

The return trip (back-end → front-end) happens by symptom: setup WNS worse than
~20% of the period, cell count far above expectation, unintended latches, or
unmapped cells after synthesis all mean "the next move is an RTL change," not
more flow knobs. Any RTL change made for PPA reasons invalidates verification —
re-run the full test suite after every such edit.

---

## Skill 1: `riscv-core-design`

**Front-end design and functional verification of RISC-V processor cores in
Verilog** — multicycle FSM cores, 5-stage pipelines, and the scaling ladder to
caches, CSRs/traps, and superscalar.

### Enforced workflow

The skill exists because most core projects fail in one of three ways: the spec
was assumed instead of read, the microarchitecture was never drawn, or the
testbench was written after the bug. It enforces the order that avoids that:

- **Phase A — Specification capture (gate).** Written instruction table
  (mnemonic / opcode / funct3 / funct7 / format / pseudocode), custom-extension
  encoding, memory map, reset behaviour, cycle model, unsupported-case
  behaviour, and an explicit open-questions list. Project documents outrank the
  ISA manual, which outranks the skill's defaults. Grading rubrics get extracted
  into a checklist here.
- **Phase B — Golden reference model.** An executable ISA model (Python/C)
  written from the spec, emitting the same one-line-per-instruction trace format
  the RTL testbench will emit — so co-simulation is a `diff`, not a project.
- **Phase C — Microarchitecture.** Execution model → state table → datapath
  block diagram → control-signal table → bus/arbitration plan. The diagram is a
  real artifact, generated from the control table so the two cannot drift.
- **Phase D — Bottom-up RTL + unit tests.** Dependency order: register file →
  immediate generator → ALU → branch comparator → multiplier → custom unit →
  LSU → address decoder → control FSM → core. No module starts until the
  previous one passes a self-checking testbench.
- **Phase E — Instruction-level bringup.** `ADDI` first, then OP-IMM/OP,
  `LUI`/`AUIPC`, loads/stores at every width and offset, branches, `JAL`/`JALR`
  (check the LSB clear), M-extension, custom extension — trace-diffed against
  the golden model at each step.
- **Phase F — Program-level verification.** Directed programs → randomized
  co-simulation → `riscv-tests` / `riscv-arch-test` (note: RISCOF is deprecated,
  replaced by ACT4) → `riscv-formal` where the toolchain allows.
- **Phase G — Synthesis sanity gate + handoff** (see above).
- **Phases H–J — PPA (delegated), gate-level re-verification, deliverables.**

### Key principles

- `CPI × T_clk` is the real metric, not either half. CPI is a *design* parameter
  in a multicycle FSM and is invisible to downstream PPA tools.
- Never infer large memories as flip-flops — `reg [31:0] mem [0:16383]` kills
  more student/competition cores than every timing issue combined.
- Verilog-2001 is a hard constraint when the platform demands it: no `logic`,
  `always_ff`, `typedef enum`, packed structs, `assert`, or `$fatal` — including
  in testbenches. The skill ships a full substitution table.
- A trace is worth a hundred waveform screenshots: instrument one line per
  retired instruction and diff against the golden model before reaching for
  GTKWave.
- Under deadline pressure, cut scope, not verification — a smaller instruction
  set that is provably correct beats a full one that is probably correct.

### Bundled resources

| Path | Contents |
|---|---|
| `references/isa-and-encoding.md` | Encodings, immediate bit-slicing, opcode/funct tables, RV32I+M, custom-extension assembler macros |
| `references/microarchitecture.md` | Full 4-state multicycle FSM, datapath, control-signal table, LSU, memory map, scaling ladder |
| `references/verification.md` | Unit/core TB methodology, co-simulation, riscv-tests/ACT, formal/RVFI, coverage |
| `references/optimization.md` | RISC-V-specific PPA levers: CPI reduction, critical-path surgery, resource sharing, multiplier strategy |
| `references/handoff.md` | The handoff packet for `ic-design-optimization` Phase 0/1 |
| `references/resources.md` | Authoritative sources: specs, reference cores, tools, test suites |
| `assets/` | Verified Verilog-2001: complete RV32IM+CRC multicycle core, simulation SoC, TB templates, self-test, Makefile regression |
| `scripts/rv_model.py` | Executable golden model / assembler / hex-image builder — the co-simulation oracle |
| `scripts/gen_vectors.py` | Known-answer vector generator (immediates, multiplier corners, CRC) — never hand-write expected values |

Everything in `assets/` compiles under `iverilog -g2001` and passes; the core
and the golden model produce byte-identical retire traces on the bundled
self-test.

---

## Skill 2: `ic-design-optimization`

**Systematic PPA optimization and debug for digital IC design on OpenLane +
sky130** (and OpenROAD/Yosys generally), from RTL through GDSII: post-synthesis
triage, timing closure (setup/hold/WNS/TNS), congestion, utilization, antenna
and DRC/LVS violations, CTS skew, power reduction, and design-space exploration.

### Enforced workflow

Optimization without a declared objective is just churn. The skill enforces
**define the goal → measure → classify root cause → intervene at the cheapest
effective layer → re-measure → verify**.

- **Phase 0 — Establish the objective (gate).** Ranked primary objective, hard
  constraints, acceptance bar, scoring function, iteration budget. Then pick one
  of eight research-backed **profiles** as a starting recipe:

  | Profile | Objective |
  |---|---|
  | P0 Maximum Performance | Absolute fmax, area/power free |
  | P1 Performance-Efficient | Best perf/W near the high end |
  | P2 Balanced Mainstream | Meet spec with margin (default) |
  | P3 Area/Cost | Minimum die area |
  | P4 Min Energy/op | Fewest joules per task |
  | P5 Min Power / Always-On | Lowest average watts |
  | P6 Throughput (Parallel) | Max ops/s/W (DSP, crypto, ML) |
  | P7 Robustness | Working first silicon — the right starting point more often than people admit |

- **Phase 1 — Initial analysis.** Run `scripts/config_inventory.py --check`
  first (the run's own expanded config is ground truth — variable names moved
  substantially across OpenLane 1.x and again at OpenLane 2 / LibreLane, and
  some legacy settings now hard-error). Then read `metrics.csv`, sanity-check
  cell count and utilization/density coherence, read the worst timing path in
  full, and look at the slack *distribution* (WNS + TNS), not just WNS. Classify
  before prescribing: **A** flow crash · **B** constraint defect · **C** RTL
  structural · **D** physical/flow-knob · **E** signoff violation · **F**
  already acceptable (a legitimate, underused conclusion).
- **Phase 2 — Planning.** Wall-clock estimates by design size; iterate at the
  cheapest stage that exposes the problem (synthesis-only loops for timing);
  reserve 40% of remaining time for signoff; sweep overnight, single-variable by
  day; freeze a known-good GDS early. Write the plan down: hypothesis → variable
  → expected effect → confirming measurement.
- **Phase 3 — Execution order.** Constraints (SDC audit first, always) →
  synthesis → RTL (only when the evidence says so) → floorplan → placement →
  CTS (check skew first) → routing (fix congestion upstream, not at the router)
  → signoff.
- **Phase 4 — Post-execution verification.** Post-route STA across **all**
  corners, gate-level simulation, SDF-annotated sim if timing-critical, logic
  equivalence, Magic + KLayout DRC, Netgen LVS, antenna, and regression against
  the frozen baseline in a kept run table.

### Key principles

- **The goal determines the fix.** The same negative slack has four different
  correct responses depending on the objective.
- **Fix causes upstream, not symptoms downstream.** Congestion at global routing
  is usually a floorplan or RTL problem; 40%-negative setup slack is an RTL
  logic-depth problem.
- **Intervention ladder, cheapest first:** constraints → flow knobs → floorplan
  → RTL.
- **One variable per experiment.** (Parallel sweeps are one-variable experiments
  run concurrently — different from changing five things in one run.)
- **Timing optimization inflates area; area creates congestion.** Raising
  buffer-insertion percentages? Lower `FP_CORE_UTIL` in the same breath.
- **Hold violations kill a chip; setup violations only slow it down.**
- **Post-route STA with extracted SPEF is the truth;** early STA is optimistic.
- **Trust reports over intent** — confirm the step actually ran before believing
  a clean result.
- **Verify variable names against the tool, never against documentation** — this
  applies to the skill's own reference files too.

### Bundled resources

| Path | Contents |
|---|---|
| `scripts/config_inventory.py` | **Run first on any real run.** Extracts the authoritative variable inventory from the run's config; flags stale/renamed names |
| `references/profiles.md` | Eight complete RTL→signoff recipes (P0–P7) plus the power/energy physics behind them |
| `references/diagnosis-playbook.md` | The main workhorse: scenario → fix mappings, indexed by observed symptom |
| `references/openlane-variables.md` | Exact variable names, defaults, safe ranges, OL1↔OL2 mapping |
| `references/sky130-data.md` | Cell library choice, buffer/cell names, layer RC, corner definitions |
| `references/dse-and-testing.md` | Parallel sweeps, post-run verification, signoff |

---

## Scope boundaries (what these skills deliberately do *not* cover)

| Out of scope | Why |
|---|---|
| Analog / mixed-signal design, custom cell layout | Different tools, different methodology |
| SRAM/macro generation (OpenRAM, DFFRAM) | Integration is covered; generation/characterization is not |
| Functional-verification methodology (UVM, coverage closure, bespoke formal) | Only verification *that optimization preserved behaviour* is in scope |
| Other PDKs / flows / FPGAs | Principles transfer; every name, default, and RC figure here is sky130 + OpenLane |
| GCC/LLVM backend modification, OS/firmware bring-up, Linux boot | Use a proven core (CVA6, Rocket) for that class of problem |
| Tapeout logistics (shuttle rules, precheck, padframes) | Changes per shuttle — read current documentation |
| RISC-V ratification / profile compliance certification | Read the current specification |

When a request falls outside the boundary, the skills say so plainly and name
what would actually be needed, rather than producing confident-sounding guidance
from adjacent knowledge.

---

## Typical usage

**Building a core from scratch:**

```
/riscv-core-design          # Phases A–G: spec → verified, synthesizable RTL
/ic-design-optimization     # Phases 0–4: objective → clean, optimized GDSII
/riscv-core-design          # Phase I: gate-level re-verification, deliverables
```

**Debugging an existing OpenLane run:** go straight to
`/ic-design-optimization` with `metrics.csv`, the relevant STA/synthesis
reports, and the run's config; it will hand back to `/riscv-core-design` if the
root cause is RTL-structural.

**Extending or verifying an existing core:** go straight to
`/riscv-core-design` with the RTL and the project's specification documents.
