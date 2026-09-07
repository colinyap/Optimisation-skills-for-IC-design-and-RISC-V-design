---
name: ic-design-optimization
description: Systematic PPA optimization and debug for digital IC design on OpenLane + sky130 (and OpenROAD/Yosys generally), from RTL through GDSII. Covers post-synthesis triage, timing closure (setup/hold/WNS/TNS), congestion, utilization, antenna and DRC/LVS violations, CTS skew, power reduction, and design-space exploration. Use this whenever the user shares OpenLane output — metrics.csv, STA or synthesis reports, congestion or DRC reports, config.tcl/config.json, a run log or tarball — or asks about slack, WNS, skew, target density, utilization, cell count, area, fmax, routing failures, diode insertion, or why a run failed. Also use it when the user states a design goal rather than a problem (maximum performance, minimum power, best perf-per-watt, minimum energy per operation, smallest area, power-versus-speed tradeoffs), since it carries eight ready-made optimization profiles for those design points. Also for tapeout prep, competition PPA tuning, hardening a macro, and sky130 cell-library selection.
---

# IC Design Optimization (OpenLane / sky130)

Optimization without a declared objective is just churn. This skill enforces a
sequence: **define the goal → measure → classify root cause → intervene at the
cheapest effective layer → re-measure → verify**. Most wasted effort in
open-source PnR comes from twiddling router knobs to fix problems that were
created in the RTL, or from changing five variables at once and not knowing
which one helped.

Detailed material lives in `references/` — read the relevant file when you get
to that stage rather than loading everything up front:

| File | Read when |
|---|---|
| `scripts/config_inventory.py` | **Run this first on any real run.** Extracts the authoritative variable inventory from the run's own config, flags stale/renamed names, and surfaces behaviour-critical values. Documentation goes stale; a run's config does not. |
| `references/profiles.md` | You need a complete RTL→signoff recipe for a stated objective — eight industry design points from maximum performance to minimum power, plus the power/energy physics behind them. **Read this at Phase 0.** |
| `references/diagnosis-playbook.md` | You have real reports and need scenario → fix mappings. **This is the main workhorse.** |
| `references/openlane-variables.md` | You need exact variable names, defaults, safe ranges, OL1↔OL2 name mapping |
| `references/sky130-data.md` | You need cell library choice, buffer/cell names, layer RC, corner definitions |
| `references/dse-and-testing.md` | You're setting up parallel sweeps, or doing post-run verification and signoff |

---

## Core operating principles

**1. The goal determines the fix.** The same negative slack has four different
correct responses depending on whether the objective is max frequency, min area,
min power, or "just produce a clean GDS." Never propose a fix before the
objective and its constraints are known. If the user hasn't said, ask — this is
the one question always worth asking up front.

**2. Fix causes upstream, not symptoms downstream.** The layer where a problem
*appears* is rarely the layer that *created* it. Congestion at global routing is
usually a floorplan or RTL structure problem. Setup slack that's 40% negative is
an RTL logic-depth problem; no amount of `SYNTH_STRATEGY` tuning recovers it.
Work up the chain: **RTL → constraints/SDC → floorplan → placement → CTS →
routing**. Ask "what is the earliest stage that could have caused this?"

**3. Intervention ladder — always try cheapest first.** Cost here means both
engineering time and risk of breaking something that already works:

1. **Constraints (SDC)** — nearly free, and frequently the actual bug. A missing
   `set_false_path` makes the tool burn optimization effort on a path that
   physically never toggles. Always audit constraints before touching anything else.
2. **Flow knobs** — cheap, one flow re-run. Strategy, density, margins, iterations.
3. **Floorplan** — moderate. Utilization, aspect ratio, pin placement, macro placement.
4. **RTL** — expensive and invalidates verification, but often the only real fix
   for deep combinational paths, high-fanout nets, and structural congestion.

**4. One variable per experiment.** If two things change and the result improves,
you have learned nothing transferable. Sweeps are the exception — they're
one-variable experiments run in parallel, which is different from changing five
things in one run.

**5. Timing optimization inflates area, and area creates congestion.** Every
buffer inserted to fix slack consumes site area and routing resource. This
coupling is the single most common cause of "I fixed timing and now it won't
route." When raising buffer-insertion percentages, lower `FP_CORE_UTIL` in the
same breath.

**6. Hold violations kill a chip; setup violations only slow it down.** A setup
failure means the part must run slower. A hold failure means the part is
non-functional at *any* frequency. Unless the clock frequency is hard-specified
by an external interface, relax the clock period until setup is clean and spend
the effort on hold.

**7. Post-synthesis STA is optimistic and post-route STA is the truth.** Early
STA uses ideal clocks (so hold violations essentially cannot appear) and
estimated parasitics. Never declare closure before post-route STA with extracted
SPEF. Expect degradation at each successive stage; if slack *improves* late in
the flow, be suspicious that something isn't being analyzed.

**8. Trust reports over intent, and check the report actually ran.** "Zero
violations" from a step that crashed, was skipped, or analyzed the wrong corner
is worse than a real violation, because it hides. Confirm the step executed and
the report is non-empty before believing a clean result.

**9. Verify variable names against the tool, never against documentation.**
OpenLane's variable names and defaults moved substantially across the 1.x line and
again at OpenLane 2 / LibreLane. Names get renamed (`GLB_RT_*` → `GRT_*`), defaults
change (`MAX_FANOUT_CONSTRAINT` went 5 → 10), variables get removed
(`CTS_TARGET_SKEW`, `CELL_PAD`, `LEC_ENABLE`), and some legacy settings now
**hard-error** rather than warn (`DIODE_INSERTION_STRATEGY` strategies 1, 2 and 5).
Advice copied from a tutorial, a 2022 doc page, or an earlier session can silently
set a variable nothing reads — or abort the run. The run's own expanded config is
ground truth; `scripts/config_inventory.py --check` reads it in seconds. This
applies to this skill's own reference files too.

---

## Scope boundary

This skill covers **digital standard-cell implementation on OpenLane/OpenROAD with
sky130**: RTL through GDSII, PPA optimization, and signoff debug. Adjacent things
it does *not* cover, and where guessing would be worse than saying so:

- **Analog and mixed-signal design.** Different tools, different methodology.
  sky130 supports analog, but nothing in this skill applies.
- **Custom cell or macro layout.** Magic and KLayout appear here only as
  verification tools. Drawing polygons is a separate discipline.
- **SRAM/macro generation** (OpenRAM, DFFRAM). This skill covers *integrating* a
  macro — halos, PDN hooks, `met4` ceiling, LVS — not generating or characterizing
  one.
- **Cell characterization.** Producing liberty files (e.g. with `lctime`) is
  relevant to near-threshold work in `profiles.md` but is not covered.
- **Functional verification methodology.** Testbench architecture, UVM, coverage
  closure, and formal property development are out of scope. What *is* covered is
  verifying that optimization preserved behaviour — GL simulation, SDF annotation,
  logic equivalence.
- **Other PDKs and other flows.** The principles and physics transfer; every
  variable name, default, cell name and RC figure here is sky130 and OpenLane.
- **FPGA.** Different constraints, different tools, no floorplan in this sense.
- **Tapeout logistics** — shuttle submission rules, precheck requirements, and
  padframe integration. These change per shuttle; read the current
  documentation rather than trusting anything cached here.

When a request falls outside this boundary, say so plainly and name what would
actually be needed, rather than producing confident-sounding guidance from
adjacent knowledge. The failure mode to avoid is answering an analog or
characterization question in the register of the digital advice above.

---

## Phase 0 — Establish the objective (gate; do not skip)

Get these before analysis. If the user has provided data but not the objective,
state the assumption explicitly and proceed rather than stalling.

- **Primary objective**, ranked: max frequency / min area / min power / min
  runtime / clean signoff. Pure ties are rare — push for a rank order.
- **Hard constraints**: fixed clock frequency? fixed die area or `DIE_AREA`?
  fixed pin locations (template DEF)? macro/SRAM instances?
- **Acceptance bar**: is a handful of DRC violations survivable, or is this
  tapeout-clean-or-nothing?
- **Scoring function**, if this is a contest — optimize the scoring function, not
  your instinct for what good design looks like. If area is unscored, spend area
  freely.
- **Iteration budget**: hours available and cores available. This determines
  sweep width versus depth.

### Map objective to levers

Quick orientation, and the fallback when the objective doesn't match a profile
cleanly. Use this to reason from first principles about any objective, including
ones no profile covers — mixed objectives, a contest scoring function that
weights several metrics at once, a constraint imposed from outside, or a target
that only matters for one block of a larger design.

| Objective | Primary levers | Accept as cost |
|---|---|---|
| Max frequency | `SYNTH_STRATEGY DELAY`, RTL pipelining, tighter `CLOCK_PERIOD`, setup slack margins, lower utilization | Area growth, power, longer runtime |
| Min area | `SYNTH_STRATEGY AREA`, resource sharing, high `FP_CORE_UTIL`, minimal buffering | Lower fmax, congestion risk, harder routing |
| Min power | Clock gating, smaller cells, reduced clock-tree depth, lower fmax, lower voltage corner | Timing margin, some area |
| Min energy per operation | Lower voltage corner, reduced switched capacitance and activity, shorter logic depth | Frequency, some area |
| Clean signoff | Relaxed clock, low utilization, conservative diode strategy, `AREA 0` | Everything else |
| Min runtime | Fewer optimization passes, higher `CTS_TOLERANCE`, more `ROUTING_CORES`, partial flows | QoR across the board |

Every lever has a cost in the right-hand column, and that column is what makes
mixed objectives tractable: a lever is worth pulling only when what it buys is
scored higher than what it spends. When two objectives conflict, resolve by
whichever the scoring function or spec weights more — not by splitting the
difference, which tends to satisfy neither.

For a genuinely novel objective, work back to the physics in
`references/profiles.md` ("The physics underneath") and derive the levers from
the three equations rather than guessing by analogy.

### Then pick a profile

For the common objectives, don't rebuild the recipe from the table above — select
a profile from `references/profiles.md` and read that section. Each is a complete,
researched recipe: RTL structure, constraints, synthesis, floorplan, placement,
CTS, routing, library choice, and what to measure, for one objective function.

| Profile | Objective | Use when |
|---|---|---|
| **P0** Maximum Performance | Absolute fmax, area/power free | Contest fmax score, high-perf datapath |
| **P1** Performance-Efficient | Best perf/W near the high end | Where most commercial high-perf parts sit |
| **P2** Balanced Mainstream | Meet spec with margin | Default when nobody specified otherwise |
| **P3** Area/Cost | Minimum die area | High-volume cost-driven, small macros |
| **P4** Min Energy/op | Fewest joules per task | Battery device with a defined workload |
| **P5** Min Power / Always-On | Lowest average watts | IoT sensor, wake-up domain, very low duty cycle |
| **P6** Throughput (Parallel) | Max ops/s/W | DSP, crypto, ML accelerator — parallelizable work |
| **P7** Robustness | Working first silicon | First tapeout, MPW shuttle, first pass through the flow |

Profiles are composable and adaptable — they're starting points, not cages:

- **Start from the nearest profile and adjust** the two or three settings the
  difference implies, rather than starting from defaults or from scratch.
- **Mix by block** — P0 on the critical datapath, P3 on a peripheral, each
  hardened separately as a macro.
- **Interpolate deliberately** — P1 exists precisely because it's the measured
  knee between P0 and P2; the same sweep-and-find-the-knee method works between
  any adjacent pair.

Say which profile you started from and what you changed. A documented deviation is
reproducible; an undocumented blend is not.

Two selection traps worth naming up front, both covered in detail in the profiles file:

- **Minimum power and minimum energy are different optima.** Lowest instantaneous
  draw favours running slowly; fewest joules per task may favour finishing fast
  and idling. Which applies depends on the leakage share, and at sky130 leakage is
  small enough (~1.5 nW/kGate) that the answer is usually the opposite of what
  advice written for modern nodes suggests.
- **P7 is the right starting profile more often than people admit.** Get a clean
  GDS committed, then re-target and optimize from a working baseline.

If the objective is minimum *runtime* rather than a PPA target, that's a
different activity — see the runtime section of the diagnosis playbook.

---

## Phase 1 — Initial analysis

### Data to request

When the user says they'll provide post-synthesis data, ask for these
specifically (naming files gets better results than asking for "the reports"):

**Essential**
- `reports/metrics.csv` (or `final_summary_report.csv`) — the whole run on one line
- Synthesis stat: cell count, cell area, chip area, flop count, gate breakdown
- Post-synthesis STA: `wns`/`tns`, plus the worst `max.rpt` path with full delay breakdown
- `config.tcl` / `config.json` — non-default values are where the story is
- OpenLane version and PDK variant (sky130A vs sky130B; `hd` vs another SCL)

**Useful when the problem is downstream**
- Post-CTS: clock skew, clock-tree cell count, latency
- Global routing: congestion/overflow report
- Detailed routing: DRC violation count and violation *types*
- Antenna report; Magic DRC; LVS report
- The failing stage's log if a step errored

### Read order

Deliberately from cheap-and-global to expensive-and-specific:

0. **Pin down the version's actual variable set.** Run
   `python3 scripts/config_inventory.py <run_dir> --check`. This takes seconds and
   prevents the most common failure mode in this whole workflow: recommending a
   variable that was renamed, removed, or now hard-errors. It also flags two things
   that change the entire diagnosis — whether the flow aborts on timing violations,
   and whether `CLOCK_PORT` is empty (which makes all slack numbers refer to a
   virtual clock). Do this before reading anything else.
1. **Did the flow finish?** A crash is a different problem class from bad QoR.
   Get the failing step and its error code first (`DPL-0036`, `GPL-0306`,
   `GRT-*`, `DRT-*` — these are diagnostic, look them up in the playbook).
   Note that on OpenLane 1.1.x a **timing failure presents as a crash**, because
   `QUIT_ON_SETUP_VIOLATIONS` and `QUIT_ON_HOLD_VIOLATIONS` default to 1.
2. **metrics.csv row** — one line gives area, utilization, cell count, WNS, TNS,
   violation counts, runtime. Establishes the baseline you'll compare against.
3. **Sanity-check scale.** Is the cell count plausible for this RTL? A 32-bit
   RISC-V core with no cache landing at 300k cells means something is wrong
   structurally (unintended multipliers, no resource sharing, replicated logic),
   and that dwarfs any knob tuning.
4. **Utilization vs density coherence.** `PL_TARGET_DENSITY` should sit roughly
   `FP_CORE_UTIL/100 + 0.01…0.05`. A mismatch here causes placement divergence
   and phantom congestion.
5. **The worst timing path, read in full.** Not just the slack number — the
   *path*. Count logic levels, find where the delay accumulates, note whether
   it's reg-to-reg / in-to-reg / reg-to-out. Then check whether the path is even
   real, or a false path nobody constrained.
6. **Slack distribution, not just WNS.** WNS with small TNS means a handful of
   paths — a local, fixable problem. WNS with large TNS means the whole design is
   slow — a global problem needing a different clock target or RTL restructuring.
   `TNS/WNS` roughly indicates how many paths are failing.

### Classify before prescribing

Assign the problem to exactly one of these. The class determines which section
of the playbook applies:

- **A. Flow crash** — a step errored. Fix the crash; QoR is meaningless until it runs.
- **B. Constraint defect** — false paths, multicycle paths, wrong IO delays,
  missing clock definition, multiple clock domains treated as one.
- **C. RTL structural** — logic depth, fanout, unintended inference, missing
  pipelining, poor resource sharing.
- **D. Physical/flow-knob** — density, utilization, aspect ratio, buffer margins,
  layer adjustments, iteration counts.
- **E. Signoff violation** — DRC, LVS, antenna. Often independent of timing.
- **F. Already acceptable** — the design meets the objective and further
  optimization is not the best use of remaining time. Say so plainly; this is a
  legitimate and underused conclusion.

---

## Phase 2 — Planning

### Time budgeting

Wall-clock estimates for full RTL→GDS on a typical laptop/workstation, sky130 `hd`:

| Design size | Full flow | Synthesis only | Iterations/hour |
|---|---|---|---|
| < 1k cells | 3–8 min | seconds | ~10 |
| 1k–10k cells | 8–25 min | < 1 min | 3–6 |
| 10k–50k cells | 25 min–2 h | 1–5 min | 1–2 |
| 50k–200k cells | 2–8 h | 5–20 min | overnight |
| > 200k cells | 8–24 h+ | 20 min+ | one shot per day |

Detailed routing usually dominates, and it degrades non-linearly with
congestion — a congested 50k-cell design can take longer than a clean 150k-cell
one. `ROUTING_CORES` helps here more than anywhere else in the flow.

Planning rules that follow from this:

- **Iterate at the cheapest stage that exposes the problem.** Timing-limited?
  Iterate on synthesis alone (`-to synthesis`) — minutes per experiment instead
  of hours. Only run the full flow once synthesis-stage timing is credible.
- **Reserve 40% of remaining time for signoff and the unexpected.** DRC and LVS
  surprises appear at the very end and are unbudgetable. A design that closes
  timing beautifully and fails LVS the night before the deadline scores zero.
- **Parallel-sweep overnight, single-variable by day.** Wide sweeps are for when
  you'd otherwise be asleep. See `references/dse-and-testing.md`.
- **Freeze a known-good configuration early.** Get *any* clean GDS committed as a
  fallback before chasing PPA. Optimization from a working baseline is far less
  stressful than optimization hoping to reach one.

### Write the plan down

Before executing, produce an explicit list: hypothesis → variable to change →
expected direction of effect → measurement that confirms or refutes it. Then
order the list by (expected gain) / (cost + risk). This makes it obvious when a
proposed change has no measurable success criterion, which is the usual sign
it's cargo-culted.

---

## Phase 3 — Execution order

Work in this sequence. Later stages are built on earlier ones, so fixing an
early-stage problem invalidates measurements taken later.

**Step 1 — Constraints.** Audit the SDC first, every time. Clock defined
correctly? IO delays realistic (`IO_PCT` default 0.2 = 20% of period each way)?
False paths declared? Multicycle paths declared? Multiple clock domains handled
(OpenLane assumes a single clock domain — anything else is your responsibility)?
Consider over-constraining PnR while signing off with realistic constraints:
`PNR_SDC_FILE` + `SIGNOFF_SDC_FILE` (present in OpenLane 1.1.x as well as OL2),
falling back to `BASE_SDC_FILE` when unset. v1.1.x warns when they're unset — act
on that warning.

**Step 2 — Synthesis.** Cheapest meaningful iteration point. Explore
`SYNTH_STRATEGY` (`-synth_explore` runs the sweep for you and tabulates it), then
`MAX_FANOUT_CONSTRAINT`, `SYNTH_SIZING`/`SYNTH_BUFFERING`, `SYNTH_ADDER_TYPE`. Confirm
the netlist is sane — cell count, no unmapped cells, no unintended latches — before
proceeding. Getting a bad netlist through PnR faster is not progress.

**Step 3 — RTL, if synthesis says so.** If the post-synthesis critical path has
excessive logic depth for the target period, stop and fix the RTL: pipeline it,
restructure the arithmetic, break up the fanout. This is the expensive branch, so
it needs evidence from Step 2 — but when it's the answer, nothing downstream
substitutes for it.

**Step 4 — Floorplan.** Set `FP_CORE_UTIL` with headroom for the buffers that
timing optimization will add. 35–50% is a sane starting band for most designs;
above 60% expect congestion pain. Set `FP_ASPECT_RATIO` to suit the design's
natural dataflow (near 1.0 unless you have a reason). Fix pin placement
deliberately if the design has wide buses — random equidistant pin placement,
the default, is a common hidden cause of congestion.

**Step 5 — Placement.** Keep `PL_TARGET_DENSITY` coherent with `FP_CORE_UTIL`.
Tune resizer margins (`PL_RESIZER_SETUP_SLACK_MARGIN`,
`PL_RESIZER_HOLD_SLACK_MARGIN`) and buffer-percentage caps. Watch area growth.

**Step 6 — CTS.** Check skew before anything else — high skew is the dominant
cause of hold violations. Restricting the clock buffer list
(`CTS_CLK_BUFFER_LIST` / OL2 `CTS_CLK_BUFFERS`) to fewer, smaller buffers
empirically produces better-balanced trees. Then tune `CTS_TOLERANCE`, sink
clustering, and clock routing layers. Note `CTS_TARGET_SKEW` was **removed in
v1.1.x** — skew is controlled indirectly there.

**Step 7 — Routing.** Global routing congestion is addressed by going *back* to
floorplan/placement, not by forcing the router. Legitimate routing-stage knobs:
`GRT_ADJUSTMENT`, layer min/max, `GRT_OVERFLOW_ITERS`, `DRT_OPT_ITERS`,
`ROUTING_CORES`. Antenna handling via `GRT_REPAIR_ANTENNAS`,
`RUN_HEURISTIC_DIODE_INSERTION` and `DIODE_ON_PORTS` (legacy:
`DIODE_INSERTION_STRATEGY`, whose strategies 1/2/5 now hard-error).

**Step 8 — Signoff.** DRC, LVS, antenna, post-route STA with extracted SPEF.
Treat this as its own phase with its own time budget, not a formality.

At every step: record the metric delta and whether it matched the prediction. A
change that helped for a reason you don't understand will betray you later.

---

## Phase 4 — Post-execution testing

Optimization is not done when the numbers look good; it's done when the design is
verified to still be *correct*. Full detail in `references/dse-and-testing.md`.
The essential sequence:

1. **Post-route STA across all corners** — not just typical. sky130 ss/tt/ff plus
   temperature and voltage. Setup is worst at the slow corner, hold at the fast
   corner. Signing off only at `tt` is the classic student mistake.
2. **Gate-level simulation of the final netlist.** Every optimization step
   rewrites the netlist; buffer insertion and cell resizing are supposed to be
   logic-preserving, but bugs and constraint errors do produce functional breaks.
   Run the RTL testbench against the post-route netlist with sky130 cell models.
3. **SDF-annotated GL simulation** if timing is critical. This is the closest
   thing to silicon behaviour and it catches false-path mistakes that STA cannot,
   because STA believes your constraints. Note that Verilator has no SDF support
   and iverilog's is limited — CVC handles it if you need it.
4. **Formal equivalence (LEC)** between RTL and final netlist where available
   (`LEC_ENABLE` where available — removed in v1.1.x — otherwise Yosys
   `equiv_opt`/`sat` driven manually). Fast, and directly answers "did optimization
   change the logic".
5. **Physical verification**: Magic DRC, Netgen LVS, antenna check. Plus KLayout
   DRC as an independent second opinion — the two decks disagree, and
   disagreement is informative.
6. **Regression against the frozen baseline.** Confirm you improved the target
   metric *without* silently regressing another. Keep a table of every run:
   config delta, WNS, TNS, area, utilization, cell count, DRC/LVS/antenna counts,
   runtime. This table is also exactly what a competition writeup or design
   review needs.

---

## Reporting results

When presenting analysis to the user, lead with the diagnosis and the single
highest-value action, not with a list of everything possible. Structure:

1. **Diagnosis** — problem class (A–F) and root-cause stage, with the evidence
   that points there.
2. **Recommended action** — one primary change, with the expected effect and how
   to measure whether it worked.
3. **Alternatives** — ranked, with their tradeoffs stated against the declared objective.
4. **What to check next** — the specific report or metric that confirms the fix.

Quantify wherever the data allows, flag where you're extrapolating, and say
plainly when the design is good enough and further tuning isn't worth the
remaining time.
