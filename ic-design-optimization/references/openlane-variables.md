# OpenLane Variable Reference (optimization-relevant subset)

Organized by **what you're trying to change**, not by flow stage.

## Read this first: verify against your own run, not against this file

OpenLane variable names and defaults moved substantially between 2022 and the
final 1.x releases, and again in OpenLane 2 / LibreLane. Documentation — including
this file — goes stale. **A run's own expanded config is ground truth for the
version that actually executed.**

```bash
python3 scripts/config_inventory.py <run_dir> --check
```

That flags stale names, shows this version's replacements, and surfaces
behaviour-critical values. Do it before trusting any default quoted anywhere.
`--grep PATTERN` inspects a subset; `--diff <other_run>` compares two runs.

Defaults below are from **OpenLane v1.1.1** (2024, near-final 1.x), verified
against a real run. Where a name changed, the legacy name is given so older
configs and tutorials remain readable.

## Contents
- [Behavioural gotchas that bite first](#behavioural-gotchas-that-bite-first)
- [Establishing a baseline](#establishing-a-baseline)
- [Timing: setup](#timing-setup)
- [Timing: hold](#timing-hold)
- [Design constraints](#design-constraints)
- [Area and utilization](#area-and-utilization)
- [Congestion and routability](#congestion-and-routability)
- [Clock tree](#clock-tree)
- [Antenna and diodes](#antenna-and-diodes)
- [Runtime](#runtime)
- [Checkers and signoff control](#checkers-and-signoff-control)
- [Version name mapping](#version-name-mapping)

---

## Behavioural gotchas that bite first

**The flow aborts on timing violations by default.** In v1.1.1,
`QUIT_ON_SETUP_VIOLATIONS`, `QUIT_ON_HOLD_VIOLATIONS` and
`QUIT_ON_TIMING_VIOLATIONS` all default to `1`. Older OpenLane did not do this.
So a timing failure presents as a *flow crash*, not as a completed run with bad
numbers. If a run dies late with no obvious tool error, check timing before
hunting for a tool bug. Setting these to `0` to see the full picture during
diagnosis is legitimate; shipping that way is not.

**An empty `CLOCK_PORT` produces a virtual clock.** With no clock port, STA
invents `__VIRTUAL_CLK__` at `CLOCK_PERIOD` and applies `IO_PCT` as input and
output external delay. The resulting slack numbers are measured against a clock
that doesn't exist — they are **not physically meaningful** and must not be
reported as an achievement. For a combinational block, the real figure is
pin-to-pin delay: subtract the input external delay from the data arrival time,
and report it at the slow corner. Write a real SDC with `set_max_delay` instead.

**`SYNTH_DRIVING_CELL` already defaults to `inv_2`.** Older material recommends
changing it from `inv_1` to `inv_2` to work around a timing-driven placement
crash. That fix is now the default; if you hit `GPL-0306`, look elsewhere.

**`CELL_PAD_EXCLUDE` is pre-populated but omits diodes.** Default covers
`tap*`, `decap*`, `ef_sc_hd__decap*`, `fill*` — **not** `diode*`. If detailed
placement fails on antenna/diode cells, adding `sky130_fd_sc_hd__diode*` is still
the fix.

**`RUN_KLAYOUT_DRC` now defaults to `1`.** The independent second DRC opinion is
on by default, and `QUIT_ON_KLAYOUT_DRC` is `1` too.

---

## Establishing a baseline

| Variable | Meaning |
|---|---|
| `DESIGN_NAME` | Top module name |
| `VERILOG_FILES` | Source paths |
| `CLOCK_PERIOD` | Target period in **ns**. Drives all slack computation |
| `CLOCK_PORT` | Clock port name. **Empty → virtual clock; see gotchas** |
| `CLOCK_NET` | Net into the root clock buffer, for CTS. Defaults to `CLOCK_PORT` |
| `DESIGN_IS_CORE` | 1 = chip core, 0 = macro. Controls PDN layer usage |

---

## Timing: setup

| Variable | v1.1.1 default | Notes |
|---|---|---|
| `SYNTH_STRATEGY` | `AREA 0` | `DELAY 0-4` / `AREA 0-3`. `flow.tcl -synth_explore` tabulates all. Highest value-per-minute knob |
| `SYNTH_SIZING` | 0 | ABC cell sizing. Helps timing, costs area |
| `SYNTH_BUFFERING` | 1 | ABC cell buffering |
| `SYNTH_ADDER_TYPE` | `YOSYS` | `YOSYS`/`FA`/`RCA`/`CSA`. Sweep on adder-heavy designs |
| `SYNTH_DRIVING_CELL` | `sky130_fd_sc_hd__inv_2` | Already the "fixed" value; see gotchas |
| `SYNTH_CLOCK_UNCERTAINTY` | 0.25 | **Spelled correctly in v1.1.1.** Older versions used `UNCERTAINITY` |
| `SYNTH_CLOCK_TRANSITION` | 0.15 | |
| `SYNTH_TIMING_DERATE` | 0.05 | Fraction, not a `±5%` string |
| `SYNTH_ABC_LEGACY_REWRITE` | 0 | Legacy ABC rewrite pass |
| `SYNTH_ABC_LEGACY_REFACTOR` | 0 | Legacy ABC refactor pass |
| `SYNTH_BUFFER_DIRECT_WIRES` | 1 | |
| `PL_RESIZER_TIMING_OPTIMIZATIONS` | 1 | |
| `PL_RESIZER_SETUP_SLACK_MARGIN` | 0.05 ns | Over-fix target after placement |
| `PL_RESIZER_SETUP_MAX_BUFFER_PERCENT` | 50 | Cap as % of instances |
| `GLB_RESIZER_TIMING_OPTIMIZATIONS` | 1 | Post-global-routing |
| `GLB_RESIZER_SETUP_SLACK_MARGIN` | **0.025 ns** | Note: *tighter* than the PL_ default |
| `GLB_RESIZER_SETUP_MAX_BUFFER_PERCENT` | 50 | |
| `GLB_RESIZER_DESIGN_OPTIMIZATIONS` | 1 | |

Note the asymmetry: `GLB_RESIZER_*` kept its name while `GLB_RT_*` became
`GRT_*`. Both prefixes coexist in v1.1.1 and mean different things.

**Sequence for setup closure:** audit SDC → `-synth_explore` → `SYNTH_SIZING` →
fanout/transition constraints → resizer margins → RTL pipelining.

---

## Timing: hold

| Variable | v1.1.1 default | Notes |
|---|---|---|
| `PL_RESIZER_HOLD_SLACK_MARGIN` | 0.1 ns | Raising this is usually correct — hold failures are fatal |
| `PL_RESIZER_HOLD_MAX_BUFFER_PERCENT` | 50 | Raise if hitting the cap, **and lower `FP_CORE_UTIL` with it** |
| `PL_RESIZER_ALLOW_SETUP_VIOS` | 0 | Set 1 to trade setup for hold when frequency is flexible |
| `GLB_RESIZER_HOLD_SLACK_MARGIN` | **0.05 ns** | Note: *looser* than the PL_ default |
| `GLB_RESIZER_HOLD_MAX_BUFFER_PERCENT` | 50 | |
| `GLB_RESIZER_ALLOW_SETUP_VIOS` | 0 | |

Hold is mostly a clock-skew symptom — check the clock tree before buffering.

---

## Design constraints

These moved out of the `SYNTH_*` namespace into standalone constraint variables:

| Variable | v1.1.1 default | Legacy name |
|---|---|---|
| `MAX_FANOUT_CONSTRAINT` | **10** | `SYNTH_MAX_FANOUT` (default was 5) |
| `MAX_TRANSITION_CONSTRAINT` | 0.75 ns | `SYNTH_MAX_TRAN` |
| `MAX_CAPACITANCE_CONSTRAINT` | 0.2 pF | *(new — no legacy equivalent)* |
| `IO_PCT` | 0.2 | Fraction of period as input+output external delay |
| `PNR_SDC_FILE` | `scripts/base.sdc` | Constraints for PnR steps |
| `SIGNOFF_SDC_FILE` | `scripts/base.sdc` | Constraints for final STA |
| `BASE_SDC_FILE` | `scripts/base.sdc` | Fallback when the two above are unset |

**`PNR_SDC_FILE` / `SIGNOFF_SDC_FILE` exist in OpenLane 1.** This is not an
OL2-only feature. The split is genuinely useful: over-constrain PnR to build in
margin, then sign off against realistic constraints. v1.1.1 warns when they're
unset, and that warning is worth acting on.

Both the fanout default (5 → 10) and the rename matter: a config carrying
`SYNTH_MAX_FANOUT` on v1.1.1 sets a variable nothing reads.

---

## Area and utilization

| Variable | v1.1.1 default | Notes |
|---|---|---|
| `FP_CORE_UTIL` | 50 | Percent. **Most consequential single number.** 35–50 sane; >60 expect congestion. Ignored when `FP_SIZING` is `absolute` |
| `PL_TARGET_DENSITY` | 0.55 | Keep at `FP_CORE_UTIL/100 + 0.01…0.05` |
| `FP_ASPECT_RATIO` | 1 | height/width |
| `FP_SIZING` | `relative` | `absolute` uses `DIE_AREA` instead |
| `DIE_AREA` | unset | `"x0 y0 x1 y1"` µm. Needed for tiny designs with no room for tap cells |
| `CELL_PAD_EXCLUDE` | `tap* decap* ef_sc_hd__decap* fill*` | **Add `diode*` if placement fails on antenna cells** |
| `SYNTH_NO_FLAT` | 0 | 1 for 200k+ cell designs |
| `SYNTH_SHARE_RESOURCES` | 1 | Resource sharing |
| `PL_MAX_DISPLACEMENT_X` / `_Y` | 500 / 100 µm | Legalizer search range |
| `PL_OPTIMIZE_MIRRORING` | 1 | |
| `*_MARGIN_MULT` | 4/4/12/12 | Core margins in site units |

`CELL_PAD` is **not present** in v1.1.1. If you need routing headroom between
cells, use utilization and density rather than padding.

---

## Congestion and routability

`GLB_RT_*` → `GRT_*` happened **within OpenLane 1**, not at the OL2 boundary.

| Variable | v1.1.1 default | Legacy name |
|---|---|---|
| `GRT_ADJUSTMENT` | 0.3 | `GLB_RT_ADJUSTMENT` |
| `GRT_LAYER_ADJUSTMENTS` | `0.99,0,0,0,0,0` | `GLB_RT_LAYER_ADJUSTMENTS`. li1 de-rated to 0.99 |
| `GRT_OVERFLOW_ITERS` | 50 | `GLB_RT_OVERFLOW_ITERS` |
| `GRT_ALLOW_CONGESTION` | 0 | `GLB_RT_ALLOW_CONGESTION` |
| `GRT_ESTIMATE_PARASITICS` | 1 | `GLB_RT_ESTIMATE_PARASITICS` |
| `GRT_MACRO_EXTENSION` | 0 | `GLB_RT_MACRO_EXTENSION` |
| `RT_MIN_LAYER` | `met1` | `GLB_RT_MINLAYER` |
| `RT_MAX_LAYER` | `met5` | `GLB_RT_MAXLAYER`. **Macros must stay at `met4`** |
| `DRT_MIN_LAYER` / `DRT_MAX_LAYER` | = `RT_*` | Lets detailed routing use li1 when global routing avoids it |
| `DRT_OPT_ITERS` | 64 | `ROUTING_OPT_ITERS` |
| `MAX_METAL_LAYER` | 6 | |
| `PL_ROUTABILITY_DRIVEN` | 1 | Keep on |
| `PL_TIME_DRIVEN` | 1 | |
| `FP_IO_HLAYER` / `FP_IO_VLAYER` | `met3` / `met2` | `FP_IO_HMETAL` / `FP_IO_VMETAL` |
| `FP_IO_MODE` | 1 | 1 = random equidistant. Scatters bus bits — hidden congestion cause |
| `FP_PIN_ORDER_CFG` | unset | Manual pin sides. Often a large, cheap win |
| `PL_MACRO_HALO` / `PL_MACRO_CHANNEL` | `0 0` | |
| `GRT_CONGESTION_REPORT_FILE` | auto | Where to read congestion from |

---

## Clock tree

| Variable | v1.1.1 default | Notes |
|---|---|---|
| `RUN_CTS` | 1 | Legacy: `CLOCK_TREE_SYNTH` (both present in v1.1.1) |
| `CTS_CLK_BUFFER_LIST` | `clkbuf_8 clkbuf_4 clkbuf_2` | **Restricting to fewer/smaller buffers improves balance** |
| `CTS_ROOT_BUFFER` | `clkbuf_16` | |
| `CTS_MAX_CAP` | 1.53169 | Max cap on the root buffer output |
| `CTS_TOLERANCE` | 100 | Higher = faster, worse QoR |
| `CTS_SINK_CLUSTERING_SIZE` | 25 | Smaller = better balance |
| `CTS_SINK_CLUSTERING_MAX_DIAMETER` | 50 µm | |
| `CTS_CLK_MAX_WIRE_LENGTH` | 0 (no limit) | Forces segmentation of long clock nets |
| `CTS_DISTANCE_BETWEEN_BUFFERS` | 0 | |
| `CTS_DISABLE_POST_PROCESSING` | 0 | |
| `CTS_MULTICORNER_LIB` | 1 | Multi-corner CTS |
| `CTS_REPORT_TIMING` | 1 | |
| `CLOCK_BUFFER_FANOUT` | 16 | Raise for a shallower tree |
| `RT_CLOCK_MIN_LAYER` | **`met3`** | Does *not* default to `RT_MIN_LAYER` |
| `RT_CLOCK_MAX_LAYER` | = `RT_MAX_LAYER` | Upper metals → lower, more uniform delay |

**`CTS_TARGET_SKEW` is not present in v1.1.1.** Skew is controlled indirectly:
buffer list, sink clustering, `CTS_TOLERANCE`, `CTS_MAX_CAP`, and clock routing
layers. Advice to "lower `CTS_TARGET_SKEW`" applies to older versions only.

---

## Antenna and diodes

**`DIODE_INSERTION_STRATEGY` is deprecated in v1.1.1, and strategies 1, 2 and 5
hard-error.** It was replaced by independent flags. If set, the flow prints a
deprecation warning and auto-converts what it can.

| Variable | v1.1.1 default | Notes |
|---|---|---|
| `GRT_REPAIR_ANTENNAS` | 1 | OpenROAD's `repair_antennas` during global routing |
| `RUN_HEURISTIC_DIODE_INSERTION` | 0 | Munaut's script — inserts diodes by Manhattan distance at global placement |
| `DIODE_ON_PORTS` | `none` | `none` / `in` / `out` / `both` |
| `GRT_ANT_ITERS` | **15** | Was 3 in older versions |
| `GRT_ANT_MARGIN` | 10 | |
| `GRT_MAX_DIODE_INS_ITERS` | 1 | Detects divergence, keeps best result — safe to raise |
| `HEURISTIC_ANTENNA_THRESHOLD` | 90 | Distance threshold for the heuristic script |
| `HEURISTIC_ANTENNA_INSERTION_MODE` | `source` | |
| `DIODE_CELL` | `sky130_fd_sc_hd__diode_2` | |
| `FAKEDIODE_CELL` | `sky130_ef_sc_hd__fakediode_2` | Exists, but strategies using it now error |
| `DIODE_PADDING` | 2 | |
| `USE_ARC_ANTENNA_CHECK` | 1 | 1 = ARC (fast), 0 = Magic (slower, more reliable) |
| `PL_RESIZER_MAX_WIRE_LENGTH` | 0 | µm cap; forces buffering to break long nets |
| `GLB_RESIZER_MAX_WIRE_LENGTH` | 0 | |

Legacy strategy → flag mapping:

| Old strategy | Equivalent flags | Status |
|---|---|---|
| 0 | both flags 0 | works |
| 1 | — | **errors** (brute force, diode on every net) |
| 2 | — | **errors** (fake-diode fill cells, not portable across PDKs) |
| 3 | `GRT_REPAIR_ANTENNAS=1`, `RUN_HEURISTIC_DIODE_INSERTION=0` | works |
| 4 | `GRT_REPAIR_ANTENNAS=0`, `RUN_HEURISTIC_DIODE_INSERTION=1` | works |
| 5 | — | **errors** |
| — | both flags 1 | works; most aggressive supported option |

---

## Runtime

| Variable | v1.1.1 default | Notes |
|---|---|---|
| `ROUTING_CORES` | 2 | Set to physical core count. Biggest runtime lever |
| `MAGIC_DISABLE_HIER_GDS` | 1 | Keep at 1 for digital — 2 minutes vs 20 hours on GDS write |
| `MAGIC_DRC_USE_GDS` | 1 | 1 for macros, 0 (LEF/DEF) at chip level |
| `RUN_KLAYOUT_XOR` | 1 | Disable during exploration |
| `RUN_CVC` | 1 | Voltage-aware ERC |
| `RUN_IRDROP_REPORT` | 1 | Per-instance IR drop CSV |
| `RUN_LINTER` | 1 | RTL lint before synthesis — new in late 1.x |
| `SPEF_EXTRACTOR` | `openrcx` | |
| `RUN_SPEF_EXTRACTION` | 1 | Required for accurate post-route STA |

`LEC_ENABLE`, `SPEF_WIRE_MODEL` and `SPEF_EDGE_CAP_FACTOR` are **not present** in
v1.1.1. For logic equivalence, drive Yosys `equiv_opt` / `sat` yourself.

---

## Checkers and signoff control

| Variable | v1.1.1 default | Legacy name |
|---|---|---|
| `QUIT_ON_SETUP_VIOLATIONS` | **1** | *(new)* — aborts on setup failure |
| `QUIT_ON_HOLD_VIOLATIONS` | **1** | *(new)* — aborts on hold failure |
| `QUIT_ON_TIMING_VIOLATIONS` | **1** | *(new)* |
| `QUIT_ON_TR_DRC` | 1 | |
| `QUIT_ON_MAGIC_DRC` | 1 | |
| `QUIT_ON_KLAYOUT_DRC` | 1 | *(new)* |
| `QUIT_ON_LVS_ERROR` | 1 | |
| `QUIT_ON_ILLEGAL_OVERLAPS` | 1 | May indicate real shorts — investigate, don't disable |
| `QUIT_ON_XOR_ERROR` | 1 | *(new)* |
| `QUIT_ON_UNMAPPED_CELLS` | 1 | `CHECK_UNMAPPED_CELLS` |
| `QUIT_ON_ASSIGN_STATEMENTS` | 0 | `CHECK_ASSIGN_STATEMENTS` |
| `QUIT_ON_SYNTH_CHECKS` | 1 | *(new)* |
| `QUIT_ON_LINTER_ERRORS` | 1 | *(new)* |
| `QUIT_ON_LINTER_WARNINGS` | 0 | *(new)* |
| `QUIT_ON_LONG_WIRE` | 0 | *(new)* |
| `RUN_TAP_DECAP_INSERTION` | 1 | `TAP_DECAP_INSERTION` |
| `RUN_FILL_INSERTION` | 1 | `FILL_INSERTION` |
| `RUN_DRT` | 1 | `RUN_ROUTING_DETAILED` |
| `RUN_LVS` / `RUN_MAGIC` / `RUN_MAGIC_DRC` / `RUN_KLAYOUT` | 1 | |
| `SYNTH_CHECKS_ALLOW_TRISTATE` | 1 | *(new)* |
| `PRIMARY_SIGNOFF_TOOL` | `magic` | |

---

## Version name mapping

| Legacy OpenLane 1 (≤2022) | OpenLane 1.1.x | OpenLane 2 / LibreLane |
|---|---|---|
| `config.tcl`, `set ::env(X) v` | same | `config.json`, `"X": v` |
| `SYNTH_MAX_FANOUT` (5) | `MAX_FANOUT_CONSTRAINT` (10) | `MAX_FANOUT_CONSTRAINT` |
| `SYNTH_MAX_TRAN` | `MAX_TRANSITION_CONSTRAINT` | same |
| `SYNTH_CLOCK_UNCERTAINITY` | `SYNTH_CLOCK_UNCERTAINTY` | same |
| `GLB_RT_*` | `GRT_*` | `GRT_*` |
| `GLB_RESIZER_*` | **unchanged** | `GRT_RESIZER_*` |
| `*_MAX_BUFFER_PERCENT` | unchanged | `*_MAX_BUFFER_PCT` |
| `BASE_SDC_FILE` | + `PNR_SDC_FILE`, `SIGNOFF_SDC_FILE` | `PNR_SDC_FILE`, `SIGNOFF_SDC_FILE` |
| `CTS_CLK_BUFFER_LIST` | unchanged | `CTS_CLK_BUFFERS` |
| `CTS_TARGET_SKEW` | **removed** | — |
| `CELL_PAD` | **removed** | — |
| `LEC_ENABLE` | **removed** | — |
| `SPEF_WIRE_MODEL` | **removed** | — |
| `DIODE_INSERTION_STRATEGY` (0–5) | deprecated; 1/2/5 error | `GRT_REPAIR_ANTENNAS` + `RUN_HEURISTIC_DIODE_INSERTION` |
| `CHECK_UNMAPPED_CELLS` | `QUIT_ON_UNMAPPED_CELLS` | — |
| `TAP_DECAP_INSERTION` | `RUN_TAP_DECAP_INSERTION` | — |
| `CLOCK_TREE_SYNTH` | `RUN_CTS` (both work) | `RUN_CTS` |
| `reports/metrics.csv` | same | per-step metrics + `final_summary_report.csv` |
| `flow.tcl -synth_explore` | same | **no equivalent** — script the sweep yourself |
| `run_designs.py` | same | **no equivalent** |

OL2 STA steps: `OpenROAD.STAPrePNR` (post-synthesis, ideal clock),
`OpenROAD.STAMidPNR` (several times mid-flow), `OpenROAD.STAPostPNR` (final, with
extracted parasitics — the one that counts). Reports land in
`runs/<RUN>/<STEP_ID>/`.

**When docs and tool disagree, the tool wins.** Run `config_inventory.py --check`
and believe it.
