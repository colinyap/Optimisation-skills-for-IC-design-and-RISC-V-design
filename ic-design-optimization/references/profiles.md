# Optimization Profiles

Eight design points along the power/performance spectrum, each with a full
RTL→signoff workflow. These are not compromises between two extremes — each is a
**distinct optimum for a distinct objective function**, and the correct settings
for one are actively wrong for another.

## Contents

- [The physics underneath](#the-physics-underneath)
- [Profile selection](#profile-selection)
- [sky130 library selection as the Vt knob](#sky130-library-selection-as-the-vt-knob)
- [P0 — Maximum Performance](#p0--maximum-performance)
- [P1 — Performance-Efficient](#p1--performance-efficient)
- [P2 — Balanced Mainstream](#p2--balanced-mainstream)
- [P3 — Area/Cost-Optimized](#p3--areacost-optimized)
- [P4 — Minimum Energy per Operation](#p4--minimum-energy-per-operation)
- [P5 — Minimum Power / Always-On](#p5--minimum-power--always-on)
- [P6 — Throughput-Optimized (Parallel)](#p6--throughput-optimized-parallel)
- [P7 — Robustness / First Silicon](#p7--robustness--first-silicon)
- [What OpenLane cannot do](#what-openlane-cannot-do)
- [Measuring power honestly](#measuring-power-honestly)

---

## The physics underneath

Every profile is a different position on the same three equations.

**Dynamic power** — the dominant term at sky130:

> P_dyn ≈ α · C · V² · f

α is activity factor, C switched capacitance, V supply, f frequency. Note the
square on voltage: this is why voltage scaling beats every other power technique
when it's available.

**Leakage power** — scales with total transistor width (so with area), with
temperature, and inversely with threshold voltage:

> P_leak ≈ N_gates · I_leak(Vt, T) · V

**Delay** — and therefore maximum frequency:

> f_max ≈ 1 / (LD · t_gate),  where t_gate grows sharply as V approaches Vt

LD is logic depth. That LD term is the lever that connects RTL structure to
voltage scaling: **halving logic depth lets you either double frequency at the
same voltage, or hold frequency while dropping voltage** — and the voltage route
buys quadratic power savings. This is why pipelining is a power technique, not
just a speed technique.

### The four consequences that drive profile choice

**1. Minimum power ≠ minimum energy.** Minimum power means lowest instantaneous
draw — favours running slowly with small, low-leakage cells. Minimum energy per
operation means fewest joules per unit of work — and a slow design that leaks for
longer can burn *more* total energy than a fast one that finishes and idles.
Which wins depends on the leakage share. Ask which one the application actually
cares about: a battery-powered sensor cares about energy per measurement; a
thermally limited part cares about power.

**2. Energy versus voltage is convex, giving a minimum energy point (MEP).** As
you lower V, dynamic energy falls quadratically but the period stretches, so
leakage energy per operation rises. The two cross at a minimum. For typical CMOS
that point sits around 300–500 mV, and the total achievable energy improvement
from voltage scaling is roughly 3–10×.

**3. At sky130, dynamic power dominates overwhelmingly.** Leakage for `hd` is
0.86 nA/kGate at tt/1.80 V/25 °C — about 1.5 nW/kGate. A 10k-gate design leaks
on the order of tens of nanowatts, while its dynamic power at any real frequency
is microwatts to milliwatts. **Consequence: leakage-reduction techniques barely
matter at 130 nm unless the design is idle the overwhelming majority of the
time.** This inverts advice written for modern nodes — "race to idle" is usually
the wrong instinct here, and slow-and-steady generally wins. Do the arithmetic
for your duty cycle before choosing.

**4. Parallelism can beat frequency on energy.** Two units at half frequency do
the same work as one at full frequency, but each can run at lower voltage — and
V² means the pair can consume substantially less power despite double the area.
This is architecture-driven voltage scaling (Chandrakasan). It only works if the
workload parallelizes and if you can actually lower the voltage — see P6.

### Useful figures of merit

- **Energy per operation** (J/op) — the metric for battery life
- **Energy-delay product** (EDP) — balances the two symmetrically; the standard
  choice when neither dominates
- **ED²P** — weights delay more heavily; used when performance matters more
- **Power density** (W/mm²) — the metric when thermals bind

State which one you're optimizing. "Better PPA" without a figure of merit cannot
be evaluated, and two engineers optimizing different figures of merit will
disagree forever while both being right.

---

## Profile selection

| Profile | Objective | fmax | Area | Power | Typical application |
|---|---|---|---|---|---|
| **P0** Maximum Performance | Absolute fmax | 100% | very high | very high | Contest fmax score, high-perf datapath |
| **P1** Performance-Efficient | Best perf/W at high perf | 80–90% | high | moderate | Where most commercial high-perf parts sit |
| **P2** Balanced Mainstream | Meet spec with margin | 60–75% | moderate | moderate | Default commercial ASIC, general SoC |
| **P3** Area/Cost | Min die area | 50–65% | minimum | low-ish | High-volume cost-driven, small macros |
| **P4** Min Energy/op | Min J per task | 30–50% | moderate | low | Battery devices with duty cycles |
| **P5** Min Power / Always-On | Min average watts | 10–30% | low | minimum | IoT sensor, wake-up domain, RTC |
| **P6** Throughput (Parallel) | Max ops/s/W | low per-unit | high | moderate | DSP, crypto, ML accelerators |
| **P7** Robustness | Working first silicon | 40–60% | generous | unoptimized | Student tapeout, MPW shuttle, first spin |

Selection questions, in order:

1. **Is there a hard frequency spec?** Yes → P0/P1/P2 depending on headroom. No →
   power and area profiles open up.
2. **Battery powered?** Yes → is the metric energy per task (P4) or average power
   at low duty cycle (P5)?
3. **Does the workload parallelize?** Yes, and energy matters → P6 beats P1 and P4.
4. **High volume?** Yes → P3; die area is unit cost.
5. **First time through the flow, or first silicon?** → P7 until it works, then
   re-target. This is the correct starting profile more often than people admit.

---

## sky130 library selection as the Vt knob

In a commercial PDK you would mix HVT/SVT/LVT cells within one library. In
sky130, **the threshold-voltage choice is expressed as the library choice**,
because each library is built from different device flavours:

| Library | NMOS device | PMOS device | Leakage @tt/1.8V/25°C | Speed | Cell height |
|---|---|---|---|---|---|
| `hs` | `nfet_01v8_lvt` | `pfet_01v8_lvt` | highest | highest | 3.33 µm |
| `ms` | `nfet_01v8_lvt` | `pfet_01v8` | medium | medium | 3.33 µm |
| `ls` | `nfet_01v8` | `pfet_01v8_hvt` | low | low | 3.33 µm |
| `lp` | `nfet_01v8` | `pfet_01v8_hvt` | low | low | 3.33 µm |
| `hd` | `nfet_01v8` | `pfet_01v8` | 0.86 nA/kGate | baseline | 2.72 µm |
| `hdll` | `nfet_01v8` | `pfet_01v8_hvt` | **0.08 nA/kGate** | lower | 2.72 µm |
| `hvl` | 5 V devices | 5 V devices | — | — | 4.07 µm |

Density and cost:

| Library | Raw gate density | Routed density | NAND2 area |
|---|---|---|---|
| `hd` | 266 kGates/mm² | ≥160 kGates/mm² | 3.75 µm² |
| `hdll` | 200 kGates/mm² | 120 kGates/mm² | 5.00 µm² |
| `hvl` | 102 kGates/mm² (actual) | ≥100 kGates/mm² | 9.77 µm² |

The key tradeoffs to know:

- **`hdll` gives 5–10× lower leakage for ~33% more area**, at the same cell
  height and pin grid as `hd`, and is documented as DRC-clean when intermingled
  with `hd` cells. That intermixability is the closest thing sky130 offers to a
  dual-Vt flow — though OpenLane will not do the swapping for you.
- **`hs`/`ms`/`ls` are drop-in compatible with each other** for the same function
  and drive strength. `hd` is *not* drop-in compatible with any of them, and has
  lower drive strength as its density tradeoff.
- **`hd` has the lowest dynamic power** of the comparison group and comparable
  timing to `ls`, which is why it's the default and why it's the right choice far
  more often than the naming suggests.
- **`hs`/`ms`/`ls` models are characterized 1.60–1.95 V**, all cells functional at
  1.2 V. `lp` is characterized 1.55–2.0 V. `hs` includes timing data for 10% and
  20% dynamic IR drop analysis.
- **Low-power infrastructure lives in the non-`hd` libraries**: `lp` and `ls`
  support sleep transistors, `ms` has state-retention flops. `hd`, `hdll`, `lp`,
  `ls`, `ms` all include integrated clock-gating cells.

**Practical warning.** OpenLane's tuning, CI, DRC exclusion lists, and community
knowledge are overwhelmingly `hd`. Switching libraries means leaving the
well-trodden path, and the debugging cost usually exceeds the PPA gain on a
time-boxed project. Change library only when the objective genuinely demands it
(P5 leakage, P0 last-resort speed), and budget time for unfamiliar failures.

---

## P0 — Maximum Performance

**Objective:** highest fmax. Area and power are free.
**Accept:** large area, high power, long runtime, difficult routing.

### RTL
- **Pipeline aggressively.** This is the dominant lever; everything downstream is
  a rounding error by comparison. Target 8–15 logic levels per stage.
- Restructure arithmetic for depth: carry-lookahead or carry-select over ripple,
  Wallace/Booth over naive multiplication, balanced adder trees over chains.
- Precompute and speculate: compute both branches and select, rather than
  computing after deciding.
- Retime manually — move logic across register boundaries to balance stage delays.
  A pipeline is only as fast as its worst stage, so balance beats depth.
- Break high-fanout nets with explicit replication rather than trusting the tool.
- Register all module boundaries so each block's timing is independent.
- **Watch the flop count.** Every pipeline register adds clock load, and past some
  point the clock tree eats the gains. Measure, don't assume.

### Constraints
- Set `CLOCK_PERIOD` to the target. **Over-constrain PnR by 5–10%** so the
  optimizer leaves headroom for post-route degradation, then sign off at the real
  period.
- Declare every false path and multicycle path rigorously. Effort spent
  optimizing paths that never toggle is effort stolen from real paths.
- Consider raising `IO_PCT` if the surrounding system is slow, or lowering it if
  you control the interface and can promise fast IO.

### Synthesis
```tcl
set ::env(SYNTH_STRATEGY) "DELAY 0"   ;# sweep DELAY 0-4
set ::env(SYNTH_SIZING) 1
set ::env(SYNTH_BUFFERING) 1
set ::env(MAX_FANOUT_CONSTRAINT) 3          ;# down from default 10
set ::env(SYNTH_ADDER_TYPE) "CSA"      ;# sweep vs YOSYS
```
Run `-synth_explore` first — the winning strategy is design-specific and it costs
minutes to find out rather than guess.

### Floorplan and placement
```tcl
set ::env(FP_CORE_UTIL) 30             ;# low: timing opt needs room for buffers
set ::env(PL_TARGET_DENSITY) 0.35
set ::env(PL_RESIZER_SETUP_SLACK_MARGIN) 0.15
set ::env(PL_RESIZER_SETUP_MAX_BUFFER_PERCENT) 70
# CELL_PAD 6 for routing headroom -- removed in v1.1.x; low util does the job
```
Low utilization is not wasteful here — it's what makes aggressive buffering and
upsizing possible without congestion. Set `FP_ASPECT_RATIO` to match dataflow so
the critical path runs along the long axis.

### CTS
Tight skew, because skew directly consumes setup margin:
```tcl
set ::env(CTS_TOLERANCE) 50            ;# tight tree (CTS_TARGET_SKEW gone in 1.1.x)
set ::env(CTS_SINK_CLUSTERING_SIZE) 16
set ::env(RT_CLOCK_MIN_LAYER) "met4"   ;# low-R clock routing
```

### Routing
```tcl
set ::env(RT_MAX_LAYER) "met5"         ;# core only; macros stay at met4
set ::env(GLB_RESIZER_SETUP_SLACK_MARGIN) 0.15
set ::env(GLB_RESIZER_TIMING_OPTIMIZATIONS) 1
```

### Library
Stay on `hd` unless you've exhausted RTL and flow options. `hs` (LVT both
devices) is genuinely faster but taller (3.33 µm), less dense, much leakier, and
off the tested path. Community high-speed libraries such as `sky130_as_sc_hs`
exist and claim better results than `hd` — treat as experimental.

### Accept / measure
Report fmax as the reciprocal of the tightest period that closes post-route at
the **ss** corner. Sweep `CLOCK_PERIOD` downward until it breaks; that number is
the deliverable. Expect area and power several times the P2 baseline.

---

## P1 — Performance-Efficient

**Objective:** best performance per watt while staying near the high end. This is
where most real commercial high-performance parts actually live, because the last
10–15% of fmax costs disproportionate energy.
**Accept:** slightly below peak frequency.

The core insight: as you approach fmax, closing each additional picosecond
requires progressively larger cells and more buffers, so power rises steeply
while performance barely moves. Backing off past the knee of that curve recovers
most of the power for very little speed.

### Method
1. Run P0 to find true fmax.
2. Re-run at 85–90% of that frequency.
3. Compare energy per operation and EDP between the two. The P1 point usually
   wins EDP decisively.
4. Sweep 75/80/85/90/95% and plot energy versus frequency. Pick the knee. This
   sweep *is* the deliverable — it's also exactly the plot that makes a design
   review or writeup credible.

### Settings — P0 with the extremes relaxed
```tcl
set ::env(SYNTH_STRATEGY) "DELAY 0"
set ::env(SYNTH_SIZING) 1
set ::env(MAX_FANOUT_CONSTRAINT) 4     ;# default 10
set ::env(FP_CORE_UTIL) 40
set ::env(PL_TARGET_DENSITY) 0.45
set ::env(PL_RESIZER_SETUP_SLACK_MARGIN) 0.05    ;# no over-fixing
set ::env(PL_RESIZER_SETUP_MAX_BUFFER_PERCENT) 40 ;# cap the buffer explosion
set ::env(CTS_TOLERANCE) 75            ;# moderate tree balance
```
RTL: pipeline to meet the target, then stop. Additional pipelining beyond the
requirement adds flops and clock power for no benefit.

Add clock gating here if the design has idle regions — see P4 for the mechanics.
It reduces power with essentially no frequency cost, which makes it the one
technique that's unambiguously right in this profile.

### Accept / measure
Energy per operation and EDP, both at the achieved frequency, with switching
activity from a real workload VCD. Report the frequency sweep, not just the
chosen point.

---

## P2 — Balanced Mainstream

**Objective:** meet the spec with margin, at reasonable area and power. The
default commercial point and the right answer when nobody has specified otherwise.
**Accept:** nothing maximal.

This profile is mostly OpenLane defaults, which exist because they were tuned
across a large design set. Deviating without a measured reason usually makes
things worse.

```tcl
set ::env(SYNTH_STRATEGY) "AREA 0"     ;# or DELAY 0 if slack is tight
set ::env(FP_CORE_UTIL) 45
set ::env(PL_TARGET_DENSITY) 0.50
set ::env(PL_RESIZER_SETUP_SLACK_MARGIN) 0.05
set ::env(PL_RESIZER_HOLD_SLACK_MARGIN) 0.1
set ::env(CTS_TOLERANCE) 100           ;# default
```

### Method
1. Set `CLOCK_PERIOD` to the spec plus ~10% margin.
2. Run defaults. If it closes, stop — you're done, and further optimization has
   negative expected value against the objective.
3. If it doesn't close, apply the intervention ladder from SKILL.md: constraints,
   then synthesis strategy, then floorplan, then RTL.
4. Sanity-sweep `FP_CORE_UTIL` at 40/45/50/55 to confirm you're not sitting on a
   congestion cliff.

Target 10–20% timing margin at signoff. Enough to absorb process variation and a
late RTL change; not so much that you're leaving obvious performance unclaimed.

---

## P3 — Area/Cost-Optimized

**Objective:** minimum die area. In volume production, area is unit cost.
**Accept:** lower fmax, harder routing, longer runtime.

### RTL
- **Share resources aggressively.** One multiplier used across four cycles
  instead of four multipliers. This is the largest area lever available and it
  lives entirely in the RTL.
- Serialize: convert parallel datapaths to iterative ones with a state machine.
  Trades cycles for area — exactly the intended direction.
- Minimize state: every flop is area. Recompute cheap values rather than storing them.
- Use memory macros instead of flop arrays for anything more than a few dozen words.
- Encode FSM states compactly (binary over one-hot) when the decode cost is acceptable.
- Remove speculation and precomputation — they buy speed with area, which is
  backwards here.

### Synthesis
```tcl
set ::env(SYNTH_STRATEGY) "AREA 0"     ;# sweep AREA 0-3
set ::env(SYNTH_SIZING) 0
set ::env(SYNTH_SHARE_RESOURCES) 1
set ::env(MAX_FANOUT_CONSTRAINT) 12         ;# above default 10: fewer buffers
set ::env(SYNTH_ADDER_TYPE) "RCA"      ;# smallest adder structure
```

### Floorplan and placement
```tcl
set ::env(FP_CORE_UTIL) 60             ;# push up; watch for congestion cliff
set ::env(PL_TARGET_DENSITY) 0.65
set ::env(PL_RESIZER_SETUP_MAX_BUFFER_PERCENT) 15   ;# hard cap on buffering
set ::env(PL_RESIZER_HOLD_MAX_BUFFER_PERCENT) 20
# CELL_PAD -- removed in v1.1.x; utilization is the only area lever left
```
Sweep `FP_CORE_UTIL` upward until routing fails, then back off one step. **The
cliff is the answer** — the highest utilization that still routes cleanly with
acceptable DRC. Expect it somewhere in 55–70% depending on interconnect density.

### CTS and routing
```tcl
set ::env(CTS_TOLERANCE) 200           ;# looser tree, fewer clock buffers
set ::env(CLOCK_BUFFER_FANOUT) 20      ;# shallower tree
set ::env(GRT_REPAIR_ANTENNAS) 1       ;# router repair only: fewest real diodes
set ::env(RUN_HEURISTIC_DIODE_INSERTION) 0
```

### Accept / measure
Die area is the metric. Report the utilization/routability cliff you found —
it demonstrates the search rather than a lucky guess. Relax `CLOCK_PERIOD` freely;
buying timing with area is self-defeating here.

---

## P4 — Minimum Energy per Operation

**Objective:** fewest joules per task. The metric for anything battery powered
with a defined workload.
**Accept:** low frequency, moderate area.

Distinct from P5. Here the design does a fixed amount of work and you minimize
the integral of power over the time to complete it — so a design that runs slower
but leaks the whole time can lose.

### The central decision: race-to-halt or slow-and-steady

- **Slow-and-steady** wins when dynamic power dominates: lower f, lower V, longer
  runtime, and the reduced V² term more than pays for the extra leakage time.
- **Race-to-halt** wins when leakage dominates: finish fast, then power down.

**At sky130, dynamic almost always dominates** (leakage ~1.5 nW/kGate), so
slow-and-steady is the default answer. Compute it for your case:

> leakage share ≈ P_leak / (P_leak + P_dyn)

If that's below ~10%, don't spend any effort on leakage; go slow-and-steady and
put all effort into dynamic power. That will be the situation for most sky130
designs at any real frequency.

### RTL — the highest-leverage stage for energy
- **Clock gating is the single largest lever.** The clock network is typically
  30–50% of switching capacitance, and it toggles every cycle regardless of
  whether the logic is doing anything. Gate it per module and per pipeline stage.
- **Reduce switched capacitance**: operand isolation (don't let inputs toggle
  through an ALU that isn't in use), data gating, guarded evaluation.
- **Reduce activity factor**: Gray coding for counters and bus encodings, avoid
  redundant transitions, use enables rather than recomputing.
- **Minimize logic depth** — not for speed, but because shorter paths permit a
  lower voltage at the same frequency, and voltage is quadratic.
- **Memory over logic**: SRAM reads cost far less energy than recomputation.
- Avoid glitchy structures — balanced logic trees glitch less than chains, and
  every glitch is charge you paid for and threw away.

### Clock gating in OpenLane — read this before trying

The clock-gating cell `sky130_fd_sc_hd__dlclkp_*` exists, and `hd` is documented
as including integrated clock-gating cells. **But `dlclkp` is listed in
`no_synth.cells`, which excludes it from synthesis by default** — and an Efabless
maintainer has confirmed on the community Slack that it is "not expected to be
used," with the reasons for each exclusion undocumented.

Consequences:
- Writing `if (en) q <= d;` will get you an enable **multiplexer**, not a gated
  clock. That saves some switching but leaves the clock toggling.
- To get real clock gating you must remove `dlclkp` from the `no_synth.cells`
  list (via `NO_SYNTH_CELL_LIST` pointing at your own edited copy), or instantiate
  the cell explicitly in RTL.
- Either way, **verify what actually happened**: grep the netlist for the cell,
  and confirm CTS built a tree through the gate rather than treating the gate
  output as a non-clock net. A clock gate that CTS didn't understand is a
  correctness hazard, not just a missed optimization.
- Budget real debugging time for this. It is the highest-value power technique
  available and also the least well-supported.

### Constraints and synthesis
Relax the clock — this is a deliberate choice, not a concession:
```tcl
set ::env(CLOCK_PERIOD) 20             ;# 50 MHz; whatever the workload needs
set ::env(SYNTH_STRATEGY) "AREA 0"     ;# small cells switch less capacitance
set ::env(SYNTH_SIZING) 0
set ::env(MAX_FANOUT_CONSTRAINT) 12    ;# above default 10: fewer buffers
```
Only meet the frequency the workload requires. Excess frequency is wasted energy.

### Voltage scaling — what's actually possible in sky130
Voltage is the strongest lever (V², and it also relaxes leakage), but the open
PDK constrains you:
- `hd` liberty corners exist at 1.60 / 1.80 / 1.95 V.
- `hs`/`ms`/`ls` are characterized 1.60–1.95 V and documented functional at 1.2 V;
  `lp` is characterized 1.55–2.0 V.
- **There are no near-threshold (0.4–0.5 V) characterized liberty files** in the
  standard distribution. Getting the real MEP would require characterizing cells
  yourself with a tool like `lctime` — a serious side project, not a flow setting.

Practical approach: sign off at the 1.60 V corner rather than 1.80 V, which is a
legitimate and free ~21% reduction in the V² term if your system can supply
1.60 V. Point `LIB_SYNTH` and the STA libraries at the 1.60 V set and re-close
timing at the lower frequency that voltage supports.

### Floorplan through routing
```tcl
set ::env(FP_CORE_UTIL) 45
set ::env(PL_TARGET_DENSITY) 0.50
set ::env(PL_RESIZER_SETUP_MAX_BUFFER_PERCENT) 20   ;# buffers cost energy
set ::env(CTS_TOLERANCE) 200                        ;# fewer clock buffers
set ::env(CLOCK_BUFFER_FANOUT) 20                   ;# shallower tree
set ::env(RT_CLOCK_MIN_LAYER) "met4"                ;# low-R clock = less power
```
Keeping wires short matters directly: interconnect capacitance is switched
capacitance. Good placement is a power optimization.

### Accept / measure
Energy per operation, computed from VCD-annotated power at the achieved
frequency, over a representative workload. Report the energy-versus-frequency
sweep and identify your operating point on it.

---

## P5 — Minimum Power / Always-On

**Objective:** lowest average power, typically at very low duty cycle. The
always-on domain: RTC, wake-up logic, sensor monitoring.
**Accept:** very low frequency, minimal functionality.

Distinct from P4: here the design spends most of its life idle, so **leakage
share rises and can dominate the average** even at sky130.

Check first: if duty cycle is D, then
> P_avg ≈ D · P_dyn + P_leak

At sky130's ~1.5 nW/kGate, leakage only becomes the dominant term at very low D.
For a 10k-gate design leaking ~15 nW, leakage dominates when active power ×
duty cycle drops below that — which needs D on the order of a fraction of a
percent for a design consuming even tens of microwatts when active. **Do this
arithmetic before choosing this profile**, because if leakage isn't dominant you
should be running P4 instead.

### RTL
- **Minimize gate count** — leakage is proportional to it. Every removed gate is
  a permanent power saving.
- Split into always-on and switchable domains. Keep the always-on domain as small
  as physically possible; this partitioning is the main architectural decision.
- Aggressive clock gating everywhere, plus coarse enables at domain level.
- Consider an asynchronous or event-driven wake-up path so the clock can stop
  entirely rather than merely being gated.
- Minimize retained state — every retention flop is always-on area.

### Library — the one profile where switching from `hd` is justified
`sky130_fd_sc_hdll` gives **5–10× lower leakage** (0.08 vs 0.86 nA/kGate) for
about 33% more area, at the same cell height and pin grid as `hd`, and is
documented DRC-clean when intermingled with `hd`.

```tcl
set ::env(STD_CELL_LIBRARY) "sky130_fd_sc_hdll"
```
Expect to fix up config that assumed `hd` cell names — `SYNTH_DRIVING_CELL`,
`CTS_ROOT_BUFFER`, `CLK_BUFFER`, and the DRC exclusion lists all reference
library-specific cells. This is the "leaving the tested path" cost; it is worth
it here and rarely elsewhere.

For sleep-transistor power gating you need `lp` or `ls` (sleep transistors) or
`ms` (state-retention flops) — but those are 3.33 µm cell height, a different
site, and substantially further off the supported path. OpenLane has no power-gating
automation, so this means manual instantiation and manual verification.

### Synthesis through routing
```tcl
set ::env(CLOCK_PERIOD) 100            ;# 10 MHz or slower
set ::env(SYNTH_STRATEGY) "AREA 0"
set ::env(SYNTH_SIZING) 0
set ::env(MAX_FANOUT_CONSTRAINT) 14         ;# above default 10: fewest buffers
set ::env(FP_CORE_UTIL) 50
set ::env(PL_TARGET_DENSITY) 0.55
set ::env(PL_RESIZER_SETUP_MAX_BUFFER_PERCENT) 10
set ::env(PL_RESIZER_HOLD_MAX_BUFFER_PERCENT) 15
set ::env(CTS_TOLERANCE) 400           ;# slow clock, skew is cheap
set ::env(CLOCK_BUFFER_FANOUT) 24
```
At a very low clock frequency, timing is easy and you should spend all the
resulting slack on smaller cells and fewer buffers.

### Accept / measure
Average power at the target duty cycle, and leakage power separately. Report both
active and idle power. Sign off leakage at the **worst-case leakage corner**
(high temperature, high voltage, ff silicon) — leakage roughly doubles per 10 °C
and the typical corner will understate it badly.

---

## P6 — Throughput-Optimized (Parallel)

**Objective:** maximum operations per second per watt, for workloads that
parallelize. DSP, crypto, ML accelerators, anything streaming.
**Accept:** large area, low per-unit frequency, higher latency per operation.

This is architecture-driven voltage scaling. Instead of one unit at high f and
high V, use N units at f/N and lower V. Throughput is preserved, and because
dynamic power goes as V², the parallel version can consume substantially less
power despite N× the area.

The catch is that the V² benefit requires you to *actually be able to lower the
voltage*. In sky130's open PDK the characterized range is limited (see P4), so
you can realize part of this — 1.80 V → 1.60 V is available and real — but not the
dramatic near-threshold version described in the literature. **At a fixed voltage,
parallelism alone buys you throughput and lower frequency, but not a large energy
win.** Be honest about which you're getting.

### RTL — this profile is almost entirely an RTL exercise
- **Replicate datapaths.** N parallel lanes, each at 1/N the throughput requirement.
- **Deepen pipelines** to cut per-stage logic depth, which is what permits the
  lower frequency-voltage operating point.
- Combine both: parallel lanes of pipelined units.
- Watch the aggregation cost — the mux/reduce tree that combines N lanes grows and
  can eat the benefit. Tree-structure it; don't chain it.
- Memory bandwidth becomes the binding constraint before compute does. Parallel
  lanes starved of data are pure waste. Bank the memory and check the arithmetic
  on required bandwidth before committing to N.
- Clock gate idle lanes so a partially loaded pipeline isn't burning full power.

### Flow
```tcl
set ::env(CLOCK_PERIOD) 20             ;# low per-lane frequency
set ::env(SYNTH_STRATEGY) "AREA 0"     ;# many copies: area per copy matters
set ::env(FP_CORE_UTIL) 40             ;# large design, keep routable
set ::env(PL_TARGET_DENSITY) 0.45
```
Floorplan deliberately: lay out lanes as a regular array so the aggregation
network is short and regular. Consider hardening one lane as a macro and
instantiating it N times — that gives you a known-good, characterized block and
massively better runtime than flattening everything. This is standard industry
practice for regular arrays and it also makes the design far easier to reason about.

### Accept / measure
Throughput per watt (ops/s/W) and total throughput. Report the N you chose and
why, including the aggregation and memory-bandwidth analysis. Compare against a
single-lane implementation at N× frequency — that comparison is the whole point
of the profile and it's what makes the result meaningful rather than merely large.

---

## P7 — Robustness / First Silicon

**Objective:** working silicon on the first attempt. Everything else is secondary.
**Accept:** mediocre PPA across the board.

The right profile for a first tapeout, a student MPW submission, or the first
time a design goes through the flow. Unglamorous and frequently correct. A
working unoptimized chip is worth infinitely more than an optimized one that
doesn't come back alive.

### Principles
- **Margin everywhere.** Relax the clock 30–50% below what closes. Keep
  utilization low. Over-fix hold.
- **Hold violations are the enemy.** They make silicon non-functional at any
  frequency. Over-fix them and don't apologize for the area.
- **Zero tolerance on signoff.** No disabled checkers, no accepted DRC, LVS
  perfectly clean.
- **Sign off at every corner**, including the ones you think don't matter.
- **Verify functionally at gate level.** GL simulation of the actual netlist, not
  just STA.

### Flow
```tcl
set ::env(CLOCK_PERIOD) 40              ;# well below achievable
set ::env(SYNTH_STRATEGY) "AREA 0"
set ::env(FP_CORE_UTIL) 35              ;# generous
set ::env(PL_TARGET_DENSITY) 0.40
set ::env(PL_RESIZER_HOLD_SLACK_MARGIN) 0.25    ;# heavy over-fix
set ::env(GLB_RESIZER_HOLD_SLACK_MARGIN) 0.25
set ::env(PL_RESIZER_ALLOW_SETUP_VIOS) 1        ;# hold wins, always
set ::env(CTS_TOLERANCE) 50                     ;# tight tree limits hold vios
set ::env(GRT_REPAIR_ANTENNAS) 1                ;# default
set ::env(RUN_HEURISTIC_DIODE_INSERTION) 1      ;# belt and braces
set ::env(DIODE_ON_PORTS) "both"                ;# unconditional port protection
set ::env(RUN_KLAYOUT_DRC) 1                    ;# default 1 in v1.1.x
set ::env(RUN_CVC) 1                            ;# voltage-aware ERC
```
All `QUIT_ON_*` checkers stay enabled. If the flow aborts, that is the flow doing
its job.

### Accept / measure
Timing margin at every corner, zero violations of every kind, GL simulation
passing the full testbench. Report the achieved frequency as a *result*, not a
target — and then, once you have a clean baseline committed, re-target to a real
profile and optimize from safety.

---

## What OpenLane cannot do

Be straight about these rather than proposing workflows that quietly assume
commercial tooling. Every one of these is standard in a commercial low-power flow
and absent here:

| Technique | Status in OpenLane + sky130 |
|---|---|
| Automatic clock gating | Cell exists but is in `no_synth.cells`; requires manual enabling and verification |
| Multi-Vt cell swapping | No automation. Vt = library choice, and it's global. `hd`/`hdll` are intermixable in principle but you'd be scripting it yourself |
| Power gating / sleep transistors | Cells exist in `lp`/`ls`. No flow support. Manual instantiation, manual verification |
| UPF / CPF power intent | Not supported |
| Multiple power domains | No automated support; `FP_PDN_MACRO_HOOKS` and `VDD_NETS`/`GND_NETS` give crude manual control |
| Level shifters | Cells exist in `hs`/`ms`/`ls`/`lp`. No automatic insertion |
| DVFS | Not supported; would be a system-level design exercise |
| Retention flops | `ms` library only. No flow support |
| Near-threshold operation | No characterized liberty below ~1.55 V. Requires custom characterization |
| Activity-driven power optimization | No. Power reporting is available but nothing optimizes against it |
| Body biasing | Libraries are body-biasable; no flow support |

What this means practically: **on sky130 through OpenLane, your power levers are
frequency, voltage corner, gate count, library choice, clock-tree size, and
whatever clock gating you build by hand.** That is a real but narrow set. The
implication is that power optimization here is overwhelmingly an RTL and
architecture activity, not a flow-tuning activity — considerably more so than
timing optimization is.

---

## Measuring power honestly

A power number without stated activity assumptions is not a measurement.

**The problem.** Default power reports assume a uniform toggle rate (often 0.1 or
0.5) across all nets. That is fiction. Real designs have wildly non-uniform
activity — the clock toggles every cycle, a reset line essentially never toggles,
data buses depend entirely on workload. Comparing two design alternatives using
default activity can easily rank them backwards.

**The method:**

1. Write a testbench that runs a *representative* workload. Not a corner-case
   test, not an all-ones pattern — what the chip will actually do.
2. Simulate the post-route gate-level netlist and dump VCD.
3. Feed the VCD to OpenSTA via `read_power_activities -vcd`, then `report_power`.
4. Report internal / switching / leakage separately. The split tells you which
   lever to pull: high switching means attack activity and capacitance, high
   leakage means attack gate count and library.
5. State the corner. Power is worst at high voltage and high temperature; leakage
   roughly doubles per 10 °C. Report the power-worst corner (ff, high V, high T),
   not the typical corner.
6. For energy per operation, divide by the number of operations the workload
   performed. This is the number that predicts battery life.

**Reporting template:**

> Power at 50 MHz, ff_n40C_1v95 corner, activity from `<workload>` VCD over
> N operations: internal X µW, switching Y µW, leakage Z nW, total T µW.
> Energy per operation: T/(50e6/cycles_per_op) = E pJ/op.

Anything less specific than that cannot be compared against anything, including
your own earlier runs — which is exactly when power optimization silently stops
working.
