# Diagnosis Playbook

Scenario → root cause → fix, branched by objective. Variable names are OpenLane 1
(`set ::env(X) value` in `config.tcl`); see `openlane-variables.md` for OL2 /
LibreLane equivalents.

## Contents

- [1. Flow crashes and hard failures](#1-flow-crashes-and-hard-failures)
- [2. Post-synthesis timing](#2-post-synthesis-timing)
- [3. Post-synthesis area and netlist quality](#3-post-synthesis-area-and-netlist-quality)
- [4. Placement problems](#4-placement-problems)
- [5. CTS and clock problems](#5-cts-and-clock-problems)
- [6. Routing and congestion](#6-routing-and-congestion)
- [7. Antenna violations](#7-antenna-violations)
- [8. DRC and LVS](#8-drc-and-lvs)
- [9. Power](#9-power)
- [10. Runtime](#10-runtime)
- [11. Hardening a macro / block-level flow](#11-hardening-a-macro--block-level-flow)
- [12. Quick reference: goal-conditioned first moves](#12-quick-reference-goal-conditioned-first-moves)

---

## 1. Flow crashes and hard failures

Fix these before considering QoR. The error code identifies the stage.

### `[ERROR GPL-0306] RePlAce diverged at wire/density gradient Sum`

Global placement failed to converge.

Causes and fixes, in order of likelihood:
1. `PL_TARGET_DENSITY` incoherent with `FP_CORE_UTIL` — set density ≈ util/100 + 0.01…0.05.
2. Design is tiny (< ~100 cells). Set `PL_RANDOM_GLB_PLACEMENT 1` or
   `PL_RANDOM_INITIAL_PLACEMENT 1`, use low `FP_CORE_UTIL` (e.g. 5) with higher
   `PL_TARGET_DENSITY` (e.g. 0.5).
3. Driving-cell issue — **mostly historical.** Older versions defaulted
   `SYNTH_DRIVING_CELL` to `sky130_fd_sc_hd__inv_1`, which can be excluded from the
   trimmed liberty and break timing-driven placement. **v1.1.x already defaults to
   `inv_2`**, so if you hit `GPL-0306` on a current version, this is not the cause —
   confirm with `config_inventory.py --grep DRIVING` and look elsewhere.
4. Extreme aspect ratio. Move `FP_ASPECT_RATIO` back toward 1.0.
5. As a last resort `PL_TIME_DRIVEN 0` or `PL_ROUTABILITY_DRIVEN 0` to isolate
   which engine diverges — diagnostic, not a fix.

### `[ERROR DPL-0036] Detailed placement failed`

Legalizer could not find legal sites for all instances.

1. Not enough legal area. On versions that have `CELL_PAD` (**removed in
   v1.1.x**), it may be set too high — sky130 `hd` wants 4–6. On v1.1.x, reduce
   `FP_CORE_UTIL` or enlarge `DIE_AREA` instead.
2. Padding is being applied to cells that shouldn't be padded — very common with
   diodes. Exclude them:
   v1.1.x ships a default covering `tap*`, `decap*`, `ef_sc_hd__decap*` and
   `fill*` — but **not** `diode*`. Extend it:
   `set ::env(CELL_PAD_EXCLUDE) {sky130_fd_sc_hd__tap* sky130_fd_sc_hd__decap* sky130_ef_sc_hd__decap* sky130_fd_sc_hd__fill* sky130_fd_sc_hd__diode*}`
3. If the un-placeable instances are `ANTENNA`/diode cells, the diode strategy is
   demanding more diodes than there is room for. Reduce
   `DIODE_INSERTION_STRATEGY` from 4/5 to 3, or lower utilization.
4. Increase `PL_MAX_DISPLACEMENT_X` / `PL_MAX_DISPLACEMENT_Y` to widen the
   legalizer's search (defaults 500/100 µm).
5. Macro halos consuming the floor: reduce `FP_TAP_HORIZONTAL_HALO`,
   `FP_PDN_HORIZONTAL_HALO`.

### Tap cells cannot be inserted / no room in floorplan

Nearly always a very small design where the auto-computed die area is too tight.
Switch to `FP_SIZING absolute` and set `DIE_AREA` manually with generous margin.
Reduce `FP_PDN_HORIZONTAL_HALO` and `FP_PDN_VERTICAL_HALO`.

### Detailed routing never converges / DRC count oscillates

See [§6](#6-routing-and-congestion). Do not simply raise iteration counts — that
converts a fast failure into a slow one.

### Flow aborts on a checker

`QUIT_ON_TR_DRC`, `QUIT_ON_MAGIC_DRC`, `QUIT_ON_KLAYOUT_DRC`, `QUIT_ON_LVS_ERROR`,
`QUIT_ON_XOR_ERROR`, `QUIT_ON_ILLEGAL_OVERLAPS`, `QUIT_ON_UNMAPPED_CELLS`,
`QUIT_ON_SYNTH_CHECKS`, `QUIT_ON_LINTER_ERRORS`. Temporarily disabling these
to *see downstream results for diagnosis* is legitimate. Shipping with them
disabled is not — `QUIT_ON_ILLEGAL_OVERLAPS` in particular can indicate real
undetected shorts.

### The run died and no tool reported an error — check timing

**In OpenLane 1.1.x, `QUIT_ON_SETUP_VIOLATIONS`, `QUIT_ON_HOLD_VIOLATIONS` and
`QUIT_ON_TIMING_VIOLATIONS` all default to `1`.** Older versions did not. So on a
current version a timing failure presents as a **flow crash**, not as a completed
run with bad numbers.

This changes the diagnostic reflex. If a run dies late with no obvious tool error:

1. Read the STA report from the step *before* the abort, not the abort message.
2. Classify it as a timing problem ([§2](#2-post-synthesis-timing)), not a crash.
3. To see the whole picture at once, set the three flags to `0` for one diagnostic
   run so the flow completes and you can read every downstream report — then
   re-enable them. A design that only completes with timing checkers off has not
   closed timing.

Confirm which behaviour your version has before assuming either:
`python3 scripts/config_inventory.py <run_dir> --check` surfaces all three and
flags them explicitly.

---

## 2. Post-synthesis timing

Post-synthesis STA uses an **ideal clock**, so hold violations essentially cannot
appear here. Only setup is meaningful at this stage. If you *do* see hold
violations post-synthesis, your RTL contains an explicit clock tree or gated
clock structure — investigate that.

### First: is the clock real? (combinational and clockless designs)

If `CLOCK_PORT` is empty, OpenLane invents `__VIRTUAL_CLK__` at `CLOCK_PERIOD` and
applies `IO_PCT` (default 0.2) as both input and output external delay. Every slack
number then refers to a clock that does not exist, with IO delays nobody specified.

Symptoms that you're looking at virtual-clock timing:
- Startpoints and endpoints are **input and output ports**, not registers
- Paths are tagged `clocked by __VIRTUAL_CLK__`
- `suggested_clock_period` in `metrics.csv` merely echoes `CLOCK_PERIOD`
- Power figures are near-zero, because nothing has a toggle rate

**Do not report virtual-clock slack as an achievement.** For a combinational
block, the defensible figure is pin-to-pin propagation delay: take `data arrival
time` from the worst path and subtract the `input external delay` line. Report it
at the **slow corner**.

Worked example, from a real 4-bit ripple-carry adder run:

| Corner | Arrival | minus ext. input delay | Combinational delay |
|---|---|---|---|
| Fastest (ff) | 2.98 ns | 2.00 ns | **0.98 ns** |
| Typical (tt) | 3.53 ns | 2.00 ns | **1.53 ns** |
| Slowest (ss) | 4.94 ns | 2.00 ns | **2.94 ns** |

Reported setup slack for that run was +2.76 ns — a statement about an imaginary
10 ns clock, not about the adder. The real answer is 2.94 ns worst case.

The fix is to write a real SDC: `set_max_delay` between the ports, or register the
block's interface. v1.1.x warns when `PNR_SDC_FILE` and `SIGNOFF_SDC_FILE` are
unset — act on that warning rather than accepting the default virtual clock.

### More than one clock domain

**OpenLane assumes a single clock domain.** `CLOCK_PORT` and `CLOCK_PERIOD` are
scalars, CTS builds one tree, and nothing in the flow knows that two clocks are
asynchronous. Anything beyond one clock is your responsibility, expressed through
the SDC.

Symptoms of an unhandled second domain:
- Impossible negative slack on paths crossing between domains, because STA times
  them as if both clocks were the same synchronous clock
- Enormous TNS dominated by crossing paths
- Hold violations that no amount of buffering fixes
- A second clock net with no clock tree — huge skew, or treated as a data net

What to do:

1. **Declare the domains in your own SDC** (`PNR_SDC_FILE` / `SIGNOFF_SDC_FILE`).
   Define both clocks with `create_clock`, then cut the crossings:
   `set_clock_groups -asynchronous -group {clk_a} -group {clk_b}`. Without this,
   every crossing path is timed as a real synchronous path and the numbers are
   meaningless.
2. **Verify the CDC logic exists in RTL** — synchronizer flops, async FIFO, or
   handshake. STA cannot tell you whether a crossing is *safe*, only that it's cut.
   Cutting a path you haven't actually synchronized hides a real bug rather than
   fixing one.
3. **Accept that CTS balances one tree.** The second domain won't get the same
   treatment. Tolerable for a slow secondary clock; for two fast clocks, consider
   hardening the domains as separate macros.
4. **Check `CLOCK_NET`** — if it doesn't cover the second clock's root, that tree
   isn't built at all.

Two fast domains with tight timing on both means OpenLane is working against you.
Splitting into per-domain macros with a thin top level is usually less effort than
fighting the single-domain assumption.

### Setup WNS badly negative (worse than ~20% of clock period)

This is structural. Logic depth exceeds what the period allows, and knobs won't
close a gap this size.

Read the worst path and count logic levels. As a rough sky130 `hd` guide at
nominal, a simple gate contributes roughly 50–150 ps including load, so ~10 GHz⁻¹
of budget per level. If the path has 40 levels and the period is 10 ns, you are
not going to knob your way out.

| Objective | Fix |
|---|---|
| Max frequency | **Pipeline the RTL.** Insert registers to split the path. This is the only real fix. Secondary: restructure arithmetic (carry-select/lookahead instead of ripple), balance the operator tree, precompute. |
| Fixed frequency required | Same — RTL is mandatory. Also check whether the path is real: an unconstrained false path or a reset/config path that never toggles at speed needs `set_false_path`, not pipelining. |
| Frequency flexible | Relax `CLOCK_PERIOD` to where setup closes with margin, report the achieved fmax, and spend remaining effort on hold and signoff. Check `reports/metrics.csv` for the suggested clock period the flow computes. |
| Min area | Relax the period. Pipelining adds flops and area. |

### Setup WNS mildly negative (within ~10% of period)

Recoverable through the flow.

1. `SYNTH_STRATEGY DELAY 0` … `DELAY 4` — run `flow.tcl -synth_explore` to
   tabulate all strategies rather than guessing. This is the highest
   value-per-minute experiment available at this stage.
2. `SYNTH_SIZING 1` (enables ABC cell sizing) — often helps timing; costs area.
3. Reduce `MAX_FANOUT_CONSTRAINT` from the default 10 if the path shows high-fanout
   nets driving heavy loads.
4. Lower `MAX_TRANSITION_CONSTRAINT` to force sharper transitions on critical nets.
5. Raise `PL_RESIZER_SETUP_SLACK_MARGIN` (default 0.05 ns) so the placement-stage
   resizer over-fixes and leaves headroom for later degradation.
6. Check `SYNTH_ADDER_TYPE` — if the design is adder-dominated, `CSA` may beat
   the default `YOSYS` mapping. Sweep it; the winner is design-dependent.

### WNS is bad but TNS is small

A few paths are failing. Local problem. Identify them (`max.rpt` top entries),
check whether they're false paths, then target them: pipeline just that path,
or accept and over-constrain PnR on those endpoints. Do **not** globally relax
the clock for a handful of paths.

### WNS and TNS both large

Global problem: the whole design is slow. Either the clock target is unrealistic
for this RTL, or something systemic is wrong (wrong SCL, wrong corner library,
missing constraints, entire design synthesized with `AREA` strategy at an
aggressive period). Re-baseline the clock target before optimizing.

### Slack degrades sharply from post-synthesis to post-route

Expected to a degree — real parasitics replace estimates. If the degradation is
large (> 30%):

1. Congestion is forcing long detours. Fix congestion ([§6](#6-routing-and-congestion)).
2. Utilization too high, cells placed far apart. Lower `FP_CORE_UTIL`.
3. On versions that expose `SPEF_WIRE_MODEL` (**removed in v1.1.x**, which uses
   OpenRCX via `SPEF_EXTRACTOR`), `Pi` is more accurate than `L` for long nets and
   changes the numbers — usually for the worse, but truthfully.
4. Enable/raise post-GRT resizer optimization (`GLB_RESIZER_TIMING_OPTIMIZATIONS`,
   `GLB_RESIZER_SETUP_SLACK_MARGIN`).

### Hold violations after CTS or routing

Normal and expected — this is when the real clock tree, with its skew, first
appears. Hold is the priority because hold failures are fatal.

1. Raise `PL_RESIZER_HOLD_SLACK_MARGIN` / `GLB_RESIZER_HOLD_SLACK_MARGIN`
   (default 0.1 ns) to over-fix.
2. Raise `PL_RESIZER_HOLD_MAX_BUFFER_PERCENT` / `GLB_RESIZER_HOLD_MAX_BUFFER_PERCENT`
   (default 50) if the optimizer is hitting the cap — **and lower `FP_CORE_UTIL`
   at the same time**, because those buffers need somewhere to live.
3. If frequency is not hard-specified, set `PL_RESIZER_ALLOW_SETUP_VIOS 1` and
   `GLB_RESIZER_ALLOW_SETUP_VIOS 1` to let the optimizer trade setup for hold.
   Then relax `CLOCK_PERIOD` to recover the setup.
4. Attack the cause: reduce clock skew ([§5](#5-cts-and-clock-problems)). Hold
   violations are mostly a skew symptom.
5. Check for badly placed macros — a macro far from its clock source creates
   large local skew.

### Max transition / max capacitance violations, timing otherwise clean

These are warnings about design health, not necessarily failures. Acceptable if
setup and hold are met, but they indicate high fanout or long interconnect, and
they cost dynamic and short-circuit power. Fix via `MAX_FANOUT_CONSTRAINT`,
`PL_RESIZER_MAX_SLEW_MARGIN` / `PL_RESIZER_MAX_CAP_MARGIN`, or by splitting the
offending net in RTL.

---

## 3. Post-synthesis area and netlist quality

### Cell count far higher than expected

Before optimizing, work out what it *should* be. Sanity anchors for sky130 `hd`:
a minimal RV32I core without multiplier or cache lands in the low thousands of
cells; adding an unintended multiplier, barrel shifter per stage, or replicated
decode logic can multiply that several-fold.

1. **Unintended operator inference.** A `*` or `/` in RTL synthesizes to a large
   structure. Search the netlist for wide arithmetic. Fix in RTL.
2. `SYNTH_SHARE_RESOURCES` should be `1` (default) — confirm it wasn't disabled.
3. Memory inferred as flops instead of a macro — a register file written so it
   can't map to anything compact. Restructure, or use a real SRAM macro.
4. `SYNTH_STRATEGY AREA 0`…`AREA 3` if area is the objective.
5. `SYNTH_NO_FLAT 1` for very large designs (200k+ cells) — postpones flattening,
   preserving hierarchy boundaries for better optimization locality.

### Unmapped cells after synthesis

`QUIT_ON_UNMAPPED_CELLS` aborted the run. The RTL contains constructs Yosys
couldn't map to the SCL. Read the synthesis log for the unmapped cell type —
usually non-synthesizable constructs, initial blocks with real intent, or
inferred latches. Fix in RTL; do not disable the checker.

### `assign` statements in the netlist

`QUIT_ON_ASSIGN_STATEMENTS` (default off). Assign statements in a gate-level
netlist mean direct wire connections that can confuse LVS and downstream tools.
Usually from pass-through ports or tied constants. Enable the checker if LVS is
misbehaving mysteriously.

### Unintended latches

Combinational `always` block without complete assignment in all branches. Yosys
warns; the warnings get lost in the log. Grep for it. Fix in RTL — a latch in a
synchronous design is almost always a bug and will produce timing chaos.

---

## 4. Placement problems

### Utilization exploded after timing optimization

The coupling from principle 5. Buffer insertion and upsizing inflate area.

- Lower `FP_CORE_UTIL` and re-run — counterintuitive but correct: give the
  optimizer room rather than fighting it.
- Cap the damage with `PL_RESIZER_SETUP_MAX_BUFFER_PERCENT` /
  `PL_RESIZER_HOLD_MAX_BUFFER_PERCENT` if area is the objective.
- Accept it if frequency is the objective and routing still closes.

### Congestion visible after global placement

Fix at the floorplan, not the router.

1. Lower `FP_CORE_UTIL` (each 5% reduction meaningfully eases routing).
2. Lower `PL_TARGET_DENSITY` to spread cells.
3. Adjust `FP_ASPECT_RATIO` — a design with wide datapaths may route far better
   non-square.
4. On versions with `CELL_PAD`, raise it (4→6) to reserve routing space between
   cells — costs area, directly buys routability. **Not available in v1.1.x**; use
   lower `FP_CORE_UTIL` and `PL_TARGET_DENSITY` instead.
5. `PL_ROUTABILITY_DRIVEN 1` (default) — confirm it's on.
6. Fix pin placement. Random equidistant placement (the default `FP_IO_MODE 1`)
   scatters related bus bits around the die. Use `FP_PIN_ORDER_CFG` to group
   buses on one side, matched to internal dataflow. Frequently a large win and
   commonly overlooked.
7. Structural: if one module is a congestion hotspot, the RTL interconnect
   density is the cause. Consider hardening it as a separate macro.

### Tiny design behaves pathologically

Designs under ~100 cells break the placer's assumptions. Use
`PL_RANDOM_GLB_PLACEMENT 1`, `FP_SIZING absolute` with an explicit `DIE_AREA`,
low `FP_CORE_UTIL`, higher `PL_TARGET_DENSITY`, reduced PDN halos.

---

## 5. CTS and clock problems

Clock skew is the root cause of most hold violations, so this section pays for
itself.

### High clock skew

1. **Restrict the clock buffer list.** Limiting CTS to fewer and smaller buffers
   (`CTS_CLK_BUFFER_LIST`, OL2 `CTS_CLK_BUFFERS`) empirically produces
   better-balanced trees than letting it use the full range. Try dropping the
   largest buffers from the list.
2. Lower `CTS_TARGET_SKEW` (default 200 ps) if your version has it. **Removed in
   v1.1.x** — there skew is controlled indirectly via the buffer list, sink
   clustering, `CTS_TOLERANCE`, `CTS_MAX_CAP`, and clock routing layers.
3. Lower `CTS_TOLERANCE` (default 100) — better QoR, longer runtime.
4. Tune `CTS_SINK_CLUSTERING_SIZE` (default 25) and
   `CTS_SINK_CLUSTERING_MAX_DIAMETER` (default 50 µm). Smaller clusters, better
   balance.
5. `CTS_CLK_MAX_WIRE_LENGTH` to force segmentation of long clock nets.
6. **Check macro placement.** A macro whose clock pin sits far from the clock root
   creates unavoidable local skew. Move it, or accept and fix hold locally.
7. Route the clock on upper metal layers (`RT_CLOCK_MIN_LAYER` /
   `RT_CLOCK_MAX_LAYER`) — lower resistance, lower and more uniform delay. Note
   sky130 `li1` is ~80× the resistance per µm of `met1`; keeping clock nets off
   `li1` matters.

### Clock tree consuming excessive area or power

The clock net is typically the largest single power consumer. If power is the
objective: accept more skew for fewer buffers by raising `CTS_TOLERANCE` and
`CLOCK_BUFFER_FANOUT` (default 16), or `CTS_TARGET_SKEW` on versions that have it
(**removed in v1.1.x**) — then verify hold. Also reduce flop count in RTL and add
clock gating.

### Clock tree not built / CTS skipped

Check `RUN_CTS` is 1 and that `CLOCK_PORT` and `CLOCK_NET` actually
match names in the RTL. A typo here silently produces a design with no clock
tree, ideal-clock timing that looks wonderful, and a non-functional chip. Verify
the clock buffer cell count post-CTS is non-zero.

---

## 6. Routing and congestion

### Global routing overflow won't converge

Congestion is a placement/floorplan problem surfacing at routing. Attempting to
force the router mostly wastes hours.

**Correct order:**
1. Go back to floorplan and placement ([§4](#4-placement-problems)) — lower
   utilization, lower density, fix pins, and raise `CELL_PAD` where available.
2. `GRT_ADJUSTMENT` (default 0.3) — reduces assumed routing capacity, which
   makes global routing *more* conservative and pushes congestion relief into
   placement. Raising it can help by forcing earlier spreading; lowering it lets
   the router attempt denser routing. Sweep both directions; the effect is
   design-dependent.
3. Per-layer adjustments via `GRT_LAYER_ADJUSTMENTS`. In sky130, `li1` is
   heavily de-rated by default (~0.99) because it's high-resistance and mostly
   needed for cell-internal connections.
4. Raise `RT_MAX_LAYER` to `met5` if the design is a core and isn't already using
   it. **Macros must stay at `met4`** and leave `met5` for the top level.
5. `GRT_MACRO_EXTENSION` to add blockage margin around macros.
6. `GRT_OVERFLOW_ITERS` (default 50) — only if it's genuinely converging
   slowly, not if it's stuck.
7. `GRT_ALLOW_CONGESTION 1` — an escape hatch to get through the stage for
   diagnosis. It produces guides that detailed routing will likely fail on.

### Detailed routing DRC violations won't clear

1. Raise `DRT_OPT_ITERS` (default 64) — only if the count is monotonically
   decreasing. If it oscillates, the problem is congestion, not iterations.
2. Fix the underlying congestion.
3. Check `DRT_MIN_LAYER` — in sky130 letting detailed routing use `li1` even when
   global routing avoids it gives it more freedom to resolve local violations.
4. If violations cluster around macros, increase macro halos/channels
   (`PL_MACRO_HALO`, `PL_MACRO_CHANNEL`).
5. If they cluster at the die edge, increase core margins
   (`*_MARGIN_MULT` — defaults 4/4/12/12).

### Diagnosing where congestion actually is

Read the congestion report, and view the layout in the OpenROAD GUI with the
congestion heatmap on. Congestion is nearly always localized — a single hotspot
around one module or macro. Knowing *where* changes the fix completely: a global
utilization reduction is the wrong response to a single hot module.

---

## 7. Antenna violations

Long metal segments accumulate charge during manufacturing and can damage gate
oxide. Fixed by attaching diodes or by bridging to a higher layer.

### The variable changed — check yours first

`DIODE_INSERTION_STRATEGY` is **deprecated in OpenLane 1.1.x, and strategies 1, 2
and 5 hard-error.** It was replaced by three independent flags. If a config still
sets it, the flow prints a deprecation warning and auto-converts what it can.

Run `python3 scripts/config_inventory.py <run_dir> --grep DIODE` to see which
scheme your version uses before changing anything.

| Flag | Default | Effect |
|---|---|---|
| `GRT_REPAIR_ANTENNAS` | 1 | OpenROAD `repair_antennas` during global routing — iterative detect-and-insert |
| `RUN_HEURISTIC_DIODE_INSERTION` | 0 | Munaut's script; inserts diodes by Manhattan distance at global placement |
| `DIODE_ON_PORTS` | `none` | `none` / `in` / `out` / `both` — unconditional diodes on design ports |

Legacy strategy → flag equivalence:

| Old | Equivalent | Status |
|---|---|---|
| 0 | both flags 0 | works |
| 1 | — | **errors** — brute-forced a diode onto every net |
| 2 | — | **errors** — relied on fake-diode fill cells that aren't in every PDK |
| 3 | `GRT_REPAIR_ANTENNAS=1` | works — the default |
| 4 | `RUN_HEURISTIC_DIODE_INSERTION=1` | works |
| 5 | — | **errors** |
| — | both flags 1 | works; most aggressive supported combination |

Anything recommending "sweep strategy 3 → 2 → 4" is pre-1.1 advice and half of it
will now abort the run.

### Workflow when violations remain

1. **Raise the repair iterations.** `GRT_ANT_ITERS` (default **15** in 1.1.x, was 3
   in older versions) and `GRT_MAX_DIODE_INS_ITERS` (default 1). The loop detects
   divergence and keeps the best result, so raising these is safe.
2. **Turn on the heuristic inserter alongside the router repair** — set
   `RUN_HEURISTIC_DIODE_INSERTION=1` with `GRT_REPAIR_ANTENNAS=1` already on. Tune
   `HEURISTIC_ANTENNA_THRESHOLD` (default 90) downward to catch shorter nets.
3. **Add `DIODE_ON_PORTS`** — `in`, `out`, or `both`. Unconditional and area-costly,
   but it closes port-related violations that the net-based passes miss.
4. **Check diodes can actually be placed.** `CELL_PAD_EXCLUDE` ships covering
   `tap*`, `decap*`, `ef_sc_hd__decap*`, `fill*` — but **not** `diode*`. Add
   `sky130_fd_sc_hd__diode*` if placement is failing on antenna cells (see
   [§1](#1-flow-crashes-and-hard-failures)).
5. **Lower utilization** so diodes have somewhere to go.
6. **Reduce long nets at the source** — `GLB_RESIZER_MAX_WIRE_LENGTH` /
   `PL_RESIZER_MAX_WIRE_LENGTH` force buffer insertion that breaks up long wires.
   `0` means no limit.
7. **Raise `GRT_ANT_MARGIN`** (default 10) to make the checker more conservative,
   so repair triggers earlier.
8. `USE_ARC_ANTENNA_CHECK` — ARC (default 1) is fast; the Magic checker is slower
   but more reliable. If they disagree, believe Magic.

A handful of residual antenna violations is often tolerated in hobby and contest
tapeouts; for real tapeout, follow the shuttle's precheck requirements.

---

## 8. DRC and LVS

### Magic DRC violations

1. Check whether they're real or a known deck artifact. sky130 SRAM cells from
   OpenRAM use an optimized ruleset the standard DRC deck lacks, producing large
   numbers of false violations around SRAM macros — a known issue, not your bug.
2. `MAGIC_DRC_USE_GDS 1` for macros (accurate), `0` (LEF/DEF abstract) for
   chip-level — faster and adequate there.
3. Cross-check with KLayout — `RUN_KLAYOUT_DRC` **defaults to 1 in v1.1.x** (and
   `QUIT_ON_KLAYOUT_DRC` to 1), so you likely already have this. The decks
   disagree; where they agree, believe it.
4. Run `RUN_KLAYOUT_XOR` to compare the Magic-generated and KLayout-generated GDS.
   A non-empty XOR indicates a stream-out problem rather than a design problem.

### LVS mismatch

1. Read the Netgen report for *which* nets/devices mismatch — the pattern
   identifies the cause immediately.
2. Power/ground connectivity is the usual culprit. Check `LVS_INSERT_POWER_PINS`
   (default 1), `VDD_NETS`/`GND_NETS`, and `FP_PDN_MACRO_HOOKS` for macros.
3. Unconnected PDN nodes: `FP_PDN_CHECK_NODES 1` catches these earlier.
4. `MAGIC_EXT_USE_GDS` selects device-level (GDS) versus cell-level (LEF/DEF) LVS.
   Device-level is stricter and slower.
5. `YOSYS_REWRITE_VERILOG 1` produces a canonical netlist that sometimes resolves
   spurious mismatches from naming.
6. Assign statements in the netlist (see [§3](#3-post-synthesis-area-and-netlist-quality)).

### Illegal overlaps during extraction

`QUIT_ON_ILLEGAL_OVERLAPS` fired. Can indicate real shorts. Investigate in the
layout viewer at the reported coordinates — do not just disable the check.

---

## 9. Power

OpenLane's power optimization is limited; most of the win is in RTL and clock tree.

**Dynamic power** — dominated by the clock network and switching activity:
1. **Clock gating.** The single largest lever. Yosys can infer it; explicit
   enables in RTL are more reliable. Directly cuts the largest power consumer.
2. Reduce flop count in RTL — fewer clock sinks, smaller tree.
3. Raise `CTS_TOLERANCE` / `CLOCK_BUFFER_FANOUT` — or `CTS_TARGET_SKEW` on
   versions that have it — for a shallower, cheaper tree (verify hold afterwards).
4. Reduce switching on wide buses — gray coding for counters, avoid unnecessary
   toggling, operand isolation for arithmetic units that aren't in use.
5. Lower the clock frequency if the objective allows. Dynamic power scales
   roughly linearly with frequency.

**Leakage** — matters less at 130 nm than in modern nodes but is measurable:
1. Prefer smaller cells: `SYNTH_STRATEGY AREA`, avoid unnecessary upsizing.
2. Fewer cells overall. Area and leakage track together.
3. Consider the `hs` (high-speed) versus `hd` (high-density) library tradeoff —
   see `sky130-data.md`.

**Measuring it**: generate switching activity from a VCD produced by a
representative testbench, then use OpenSTA's power reporting with that activity.
Default power reports assume a uniform toggle rate and are close to meaningless
for comparing design alternatives.

---

## 10. Runtime

When iteration speed is the bottleneck:

1. `ROUTING_CORES` to physical core count — detailed routing dominates total
   runtime and threads well.
2. Raise `CTS_TOLERANCE` (worse QoR, faster).
3. Lower `DRT_OPT_ITERS` and `GRT_OVERFLOW_ITERS` for exploratory runs, restore
   for final.
4. `MAGIC_DISABLE_HIER_GDS 1` (default) — for standard-cell designs this is the
   difference between a 2-minute and a 20-hour GDS write. Never disable it for an
   all-digital design.
5. `RUN_KLAYOUT_XOR 0`, `RUN_CVC 0`, `RUN_IRDROP_REPORT 0` during exploration;
   re-enable for signoff. (`LEC_ENABLE` was removed in v1.1.x.)
6. `MAGIC_DRC_USE_GDS 0` at chip level.
7. Run partial flows: `-to synthesis`, `-to placement`. Most timing questions are
   answerable without routing.
8. Fix congestion — a congested design can route slower than a much larger clean one.

---

## 11. Hardening a macro / block-level flow

Two situations need this: a design too large or too congested to flatten, and a
regular array where one block is instantiated many times (P6's parallel lanes).
Hardening means running a block through to GDS on its own, then instantiating the
result as a black box in the parent.

It is also the standard escape hatch for problems that resist flat-flow tuning —
a single congested module, or two fast clock domains that need separate trees.

### The layer contract — get this wrong and nothing else matters

A macro and its parent share a routing stack. The parent needs the top layer for
PDN straps and global routing, so the macro must stay below it.

| Setting | Macro | Parent (core) |
|---|---|---|
| `DESIGN_IS_CORE` | `0` | `1` |
| `RT_MAX_LAYER` | `met4` | `met5` |
| `FP_PDN_CORE_RING` | `0` | `1` |

A macro built with `RT_MAX_LAYER met5` will route on the layer the parent needs,
and integration fails in ways that look like router bugs. `config_inventory.py
--check` flags both of these.

### Height and power connection

The macro's power grid connects upward through met5→met4 vias, which only exist
where a parent strap crosses the macro. So:

- **Macro height must be at least `FP_PDN_HPITCH`** (default 153.18 µm) so at least
  two met5 straps cross it. A macro shorter than the strap pitch can end up with an
  unconnected power grid.
- In the parent, set **`FP_PDN_MACRO_HOOKS`** to bind each macro instance's power
  pins to the parent's nets. Empty hooks is a common cause of late LVS failures
  that look like nothing to do with power.
- Leave **`FP_PDN_CHECK_NODES 1`** on. It catches unconnected PDN nodes at the
  point they're created rather than at signoff.

### Integrating in the parent

- `MACRO_PLACEMENT_CFG` — explicit `instance_name X Y orientation` per macro.
  Placing macros by hand is almost always better than letting the tool guess;
  macro position dominates both congestion and clock skew.
- `PL_MACRO_HALO` — keep-out margin so standard cells aren't jammed against macro
  edges. `PL_MACRO_CHANNEL` — width of the routing channel between adjacent macros.
  Too-tight channels are a top cause of unroutable designs.
- `GRT_MACRO_EXTENSION` — extra blockage margin during global routing.
- `EXTRA_LEFS`, `EXTRA_GDS_FILES`, `EXTRA_LIBS` — point the parent at the macro's
  outputs. Missing `EXTRA_LIBS` means the parent times the macro as a black box
  with no delay, which produces optimistic and meaningless slack.

### Timing across the boundary

The macro is characterized on its own, so the parent trusts its liberty. Two
consequences:

1. **Register the macro's interface** wherever possible. An unregistered
   combinational path through a macro boundary splits a timing path across two
   independently optimized runs, and neither owns it.
2. **Constrain the macro's IO deliberately** when hardening it. `IO_PCT` defaults
   to 0.2, meaning the macro assumes 20% of the period is spent outside it in each
   direction. If that's wrong, the macro is either over- or under-constrained and
   the parent inherits the error.

### When hardening is the wrong answer

It costs a second flow, a second set of constraints, and a fixed block you can't
re-optimize without re-running. For a design that fits and routes flat, it adds
work and removes the tool's ability to optimize across the boundary. Harden when
the flat flow is actually failing, when a block repeats many times, or when you
need independent clock trees — not by default.

---

## 12. Quick reference: goal-conditioned first moves

Same symptom, different objective, different correct answer.

### Setup violation

| Objective | First move |
|---|---|
| Max frequency | `-synth_explore`, then `SYNTH_STRATEGY DELAY`; pipeline RTL if the gap is structural |
| Min area | Relax `CLOCK_PERIOD` — refuse to buy timing with area |
| Min power | Relax `CLOCK_PERIOD`; lower frequency also cuts power |
| Clean signoff | Relax `CLOCK_PERIOD` until clean, move on |

### Hold violation

| Objective | First move |
|---|---|
| Max frequency | Fix skew via CTS buffer restriction; raise hold margins; keep setup protected |
| Min area | Raise hold margin minimally; fix skew rather than buffering |
| Any, frequency flexible | `ALLOW_SETUP_VIOS 1` + relax period. Hold is non-negotiable |

### Congestion

| Objective | First move |
|---|---|
| Max frequency | Lower `FP_CORE_UTIL` — timing needs routing headroom anyway |
| Min area | Fix pin order first; raise `CELL_PAD` if available, before conceding area |
| Clean signoff | Lower `FP_CORE_UTIL` aggressively; area is cheap here |

### Area over budget

| Objective | First move |
|---|---|
| Min area | `SYNTH_STRATEGY AREA`, cap buffer percentages, raise utilization, check for unintended operator inference |
| Max frequency | Verify the area is buying timing; if not, it's waste from over-fixing |

### Antenna violations

| Objective | First move |
|---|---|
| Clean signoff | Raise `GRT_ANT_ITERS`, then sweep `DIODE_INSERTION_STRATEGY` 3→2→4 |
| Min area | Strategy 2 (fake-then-real) inserts the fewest real diodes |
| Max frequency | Strategy 3 with wire-length capping; diodes add load, so watch slack |
