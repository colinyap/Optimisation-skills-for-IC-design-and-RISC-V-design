# Design Space Exploration and Verification

Two things this covers: how to search the configuration space efficiently, and
how to prove the optimized design is still correct.

## Contents
- [Design space exploration](#design-space-exploration)
- [Sweep priorities](#sweep-priorities)
- [Tracking results](#tracking-results)
- [Verification after optimization](#verification-after-optimization)
- [Signoff checklist](#signoff-checklist)
- [Reporting](#reporting)

---

## Design space exploration

Manual tuning explores maybe five configurations an evening. A scripted sweep
explores fifty overnight. For anything time-boxed, the sweep wins — and it also
produces the Pareto data that makes a writeup or design review credible.

### Built-in options

- `flow.tcl -synth_explore` — sweeps `SYNTH_STRATEGY` and tabulates results under
  `reports/`. Cheapest useful exploration in the flow; run it before anything else.
  **OpenLane 1 only** — there is no OL2/LibreLane equivalent, so script the sweep
  yourself there (see the shell pattern below).
- `run_designs.py` — OpenLane 1's exploration script, sweeps arbitrary
  configuration variables across designs.
- **OpenROAD AutoTuner** — ML-driven parameter search. Worth it for a long-running
  serious effort, overkill for a short project.

### Rolling your own

A shell loop over a variable, one run directory per point, then collect the
metrics. Pattern:

```bash
#!/usr/bin/env bash
# Sweep core utilization; one run per value, tagged for later collection.
DESIGN=my_core
for util in 30 35 40 45 50 55 60; do
  ./flow.tcl -design "$DESIGN" \
             -tag "sweep_util_${util}" \
             -overwrite \
             -config_file "configs/util_${util}.tcl" &
done
wait

# Collect: one CSV row per run.
head -1 "designs/$DESIGN/runs/sweep_util_30/reports/metrics.csv" > sweep.csv
for util in 30 35 40 45 50 55 60; do
  tail -1 "designs/$DESIGN/runs/sweep_util_${util}/reports/metrics.csv" >> sweep.csv
done
```

Parallelism notes: each run wants its own `-tag`, and memory is usually the
binding constraint rather than cores — detailed routing on a large design can
take several GB. Divide available RAM by expected peak per run to decide how many
to launch at once, and set `ROUTING_CORES` per run accordingly rather than letting
every run try to grab every core.

### Sweep design

- **One variable per sweep**, several values. Two-variable grids explode fast; only
  run them for pairs you know interact (utilization × density is the main one, and
  even there you're better off holding the standard offset and sweeping one).
- **Coarse then fine.** Sweep utilization 30–60 in steps of 10 first, then refine
  around the winner in steps of 2–3. Two cheap passes beat one expensive fine grid.
- **Bracket the failure.** Include values you expect to fail. Knowing where the
  cliff is tells you how much margin the working point has, which matters more
  than the winning number itself.
- **Sweep for Pareto fronts, not single winners.** Record area *and* timing *and*
  violation counts for every point. The best configuration depends on the
  objective, and having the front already characterized means you can re-answer
  that instantly if the objective shifts.

---

## Sweep priorities

Ordered by expected value per CPU-hour:

1. **`SYNTH_STRATEGY`** — 8 values, synthesis-only, minutes each. Always do this first.
2. **`CLOCK_PERIOD`** — establishes the actual achievable fmax. Sweep down until it
   breaks; that answers "how fast can this design go" definitively rather than by argument.
3. **`FP_CORE_UTIL`** (with coherent `PL_TARGET_DENSITY`) — the dominant
   area/routability tradeoff.
4. **`MAX_FANOUT_CONSTRAINT`** — 3/5/8/10/14, cheap. Default is 10, so sweep both
   directions: below for timing (more buffers), above for area and power (fewer).
5. **Resizer margins** — setup and hold slack margins, buffer percentage caps.
6. **`CTS_TOLERANCE`** and clock buffer list restriction — if hold is the problem.
   (`CTS_TARGET_SKEW` on versions that still have it; removed in v1.1.x.)
7. **`FP_ASPECT_RATIO`** — if congestion is the problem.
8. **`GRT_ADJUSTMENT`** — if global routing won't converge.
9. **`GRT_REPAIR_ANTENNAS` / `RUN_HEURISTIC_DIODE_INSERTION` / `DIODE_ON_PORTS`** —
   if antenna violations remain. (Legacy `DIODE_INSERTION_STRATEGY`; strategies 1, 2
   and 5 hard-error on v1.1.x.)
10. **`SYNTH_ADDER_TYPE`** — only for arithmetic-dominated designs.

Stop when the objective is met. Sweeping past the point of sufficiency is the
most common way to lose a project on the clock.

---

## Tracking results

Keep one table for the whole project. Every row is a run:

| Field | Why |
|---|---|
| Run tag / date | Reproducibility |
| Config delta from baseline | The only thing that explains the result |
| Git commit of RTL | Distinguishes flow changes from RTL changes |
| Setup WNS / TNS (ss corner) | |
| Hold WNS / TNS (ff corner) | |
| Core area, die area, utilization | |
| Cell count, buffer count | Reveals over-buffering |
| Routing DRC / Magic DRC / LVS / antenna counts | |
| Wall-clock runtime | Budgeting |
| Verdict | pass / fail / abandoned, and why |

This table costs a few minutes per run and repeatedly saves hours — it stops you
re-running configurations you already tried, and it's exactly the artifact needed
for a competition submission, report, or design review. Commit it to the repo.

---

## Verification after optimization

Optimization rewrites the netlist. Buffer insertion, resizing, cloning, and
mirroring are all *supposed* to be logic-preserving — but constraint errors and
tool bugs do produce functional breaks, and a fast wrong chip scores zero.

### 1. Multi-corner post-route STA

Non-negotiable. Setup at **ss**, hold at **ff**, both with extracted SPEF
(`RUN_SPEF_EXTRACTION 1`). Reporting only `tt` is meaningless because `tt` is
neither worst case.

Read the reports, don't just read WNS: confirm the paths being reported are the
paths you expect, and that the clock is being analyzed as a real (not ideal) net.

### 2. Gate-level simulation of the final netlist

Run the RTL testbench against `results/final/verilog/gl/*.v` with the sky130 cell
models. Zero-delay GL sim catches logic-breaking optimization bugs, tie-cell
problems, and missing-cell issues.

Note the sky130 Verilog cell models have known issues; corrected versions exist in
the `caravel_mgmt_soc_litex` repository (`verilog/cvc-pdk`) if you hit
model-related weirdness rather than real design bugs.

### 3. SDF-annotated timing simulation

The closest thing to silicon behaviour, and it catches something STA structurally
cannot: STA believes your constraints, so a wrongly declared false path is
invisible to it. Timing simulation exercises the real path and reports the
violation.

OpenLane emits SDF to `results/final/sdf/`. Annotate in the testbench:

```verilog
initial $sdf_annotate("design.sdf", dut_instance);
```

Tool support is the catch: **Verilator has no SDF support, iverilog's is limited**.
CVC (Tachyon DA) handles it and is free for non-commercial use, but must be
compiled separately. Violations reported here that STA missed mean the design is
under-constrained — usually a false path that isn't actually false.

### 4. Logic equivalence checking

On versions that expose `LEC_ENABLE` (**removed in v1.1.x**), setting it to 1
compares netlists at each flow stage using Yosys, directly answering "did
optimization change the logic." Where it isn't available — including v1.1.x — drive
Yosys `equiv_opt` / `sat` yourself against RTL versus the final netlist. Worth the
setup: it's the cheapest possible check that optimization preserved behaviour.

### 5. Physical verification

- Magic DRC (`RUN_MAGIC_DRC`) — `MAGIC_DRC_USE_GDS 1` for macros, `0` at chip level
- KLayout DRC (`RUN_KLAYOUT_DRC 1`) — independent second opinion; the decks
  disagree, and disagreement is informative
- KLayout XOR (`RUN_KLAYOUT_XOR`) — Magic-GDS versus KLayout-GDS. Non-empty XOR
  means a stream-out problem, not a design problem
- Netgen LVS — read *which* nets mismatch, not just the count
- Antenna check — ARC (fast) or Magic (slower, more reliable)
- CVC (`RUN_CVC`) — voltage-aware ERC on the extracted netlist

### 6. Formal properties, if you have them

If the design has assertions or an RVFI-style formal harness, those still apply to
the RTL. They don't verify the netlist, but they verify that the thing you
optimized was correct to begin with — which is a prerequisite nobody should skip
on the assumption that PnR will catch it. It won't.

---

## Signoff checklist

Before declaring done:

- [ ] Flow completed with no disabled checkers
- [ ] Setup WNS ≥ 0 at **ss** corner, post-route, with SPEF
- [ ] Hold WNS ≥ 0 at **ff** corner, post-route, with SPEF
- [ ] Routing DRC = 0
- [ ] Magic DRC = 0 (or every violation individually understood and justified)
- [ ] LVS clean
- [ ] Antenna violations = 0, or within the target shuttle's tolerance
- [ ] No unmapped cells, no unintended latches
- [ ] GL simulation passes the full RTL testbench
- [ ] Clock tree exists and skew is reported and reasonable
- [ ] PDN fully connected (`FP_PDN_CHECK_NODES` clean)
- [ ] Final metrics recorded in the tracking table
- [ ] Configuration committed and the run reproducible from a clean checkout

That last item is worth as much as the rest for anything being judged or
reviewed. A result nobody else can reproduce is treated, correctly, as no result.

---

## Reporting

For a writeup, report, or competition submission, the material that carries weight:

1. **Final PPA numbers with the corner stated.** "WNS +0.12 ns at ss_100C_1v60,
   post-route with extracted parasitics" is a real claim; "timing met" is not.
2. **The Pareto front from the sweeps.** Shows you searched the space rather than
   accepting the first configuration that worked. This is the difference between
   an engineering result and a lucky one.
3. **A specific problem diagnosed and fixed**, with before/after numbers and the
   reasoning. One well-explained congestion or skew fix demonstrates more
   competence than a table of final numbers.
4. **Verification evidence.** Which checks ran, at which corners, what passed.
5. **Reproduction instructions.** One command, from a clean checkout.
6. **Honest limitations.** Known residual violations, untested corners, and
   assumptions. Reviewers find these anyway; stating them first reads as
   competence rather than as a gap.
