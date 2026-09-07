# sky130 PDK Data

Physical facts about the process that drive optimization decisions. Numbers here
are for reasoning and estimation — read the actual liberty and tech LEF for
authoritative values.

## PDK variants

| Variant | Description |
|---|---|
| `sky130A` | Standard. **Better-calibrated timing extraction — use this unless you specifically need ReRAM** |
| `sky130B` | Adds a ReRAM layer between met1 and met2. This makes via1 twice as tall, which changes timing |

Default `PDK` is `sky130A`. If someone reports inexplicable timing, confirm which
variant they're on.

## Standard cell libraries

Seven foundry libraries in three cell heights. The **device flavour differs per
library**, which means in sky130 the threshold-voltage choice *is* the library
choice — there is no in-library HVT/SVT/LVT mix as you'd have in a commercial PDK.

| Library | NMOS / PMOS device | Leakage @tt/1.8V/25°C | Height | Character |
|---|---|---|---|---|
| `sky130_fd_sc_hd` | `nfet_01v8` / `pfet_01v8` | 0.86 nA/kGate | 2.72 µm | **High density. The default and best-supported path** |
| `sky130_fd_sc_hdll` | `nfet_01v8` / `pfet_01v8_hvt` | **0.08 nA/kGate** | 2.72 µm | High density, low leakage. 5–10× less leakage, ~33% more area |
| `sky130_fd_sc_hs` | `nfet_01v8_lvt` / `pfet_01v8_lvt` | highest | 3.33 µm | High speed, highest leakage |
| `sky130_fd_sc_ms` | `nfet_01v8_lvt` / `pfet_01v8` | medium | 3.33 µm | Medium speed. Has state-retention flops |
| `sky130_fd_sc_ls` | `nfet_01v8` / `pfet_01v8_hvt` | low | 3.33 µm | Low speed, low leakage. Sleep transistors |
| `sky130_fd_sc_lp` | `nfet_01v8` / `pfet_01v8_hvt` | low | 3.33 µm | Low power, ~750 cells (largest). Sleep transistors |
| `sky130_fd_sc_hvl` | 5 V devices | — | 4.07 µm | Only 5 V-tolerant library. Models valid 1.65–5.5 V |

Density:

| Library | Raw gate density | Routed density | NAND2 area |
|---|---|---|---|
| `hd` | 266 kGates/mm² | ≥160 kGates/mm² | 3.75 µm² |
| `hdll` | 200 kGates/mm² | 120 kGates/mm² | 5.00 µm² |
| `hvl` | 102 kGates/mm² (actual) | ≥100 kGates/mm² | 9.77 µm² |

Compatibility facts that matter:

- `hs` / `ms` / `ls` are **drop-in compatible with each other** for the same
  function and drive strength. `hd` is not drop-in compatible with any of them.
- `hdll` shares `hd`'s cell height and pin grid and is documented DRC-clean when
  intermingled with `hd` — the closest sky130 gets to a dual-Vt flow, though
  OpenLane won't automate the swapping.
- `hd`, `hdll`, `lp`, `ls`, `ms` all include integrated clock-gating cells. But see
  the clock-gating warning in `profiles.md` — the `hd` gate cell is excluded from
  synthesis by default.
- `hs`/`ms`/`ls` models are characterized 1.60–1.95 V (functional at 1.2 V); `lp`
  is 1.55–2.0 V. `hs` includes 10% and 20% dynamic IR-drop timing data.

For choosing a library against a specific objective, see the profile that matches
it in `profiles.md`.

Practical guidance: `hd` is what OpenLane, the CI, and effectively every tutorial
and shuttle project use. Its defaults are tuned, its DRC exclusion lists are
populated, and its problems are documented. Switching libraries to chase a few
percent of timing usually costs more in debugging unfamiliar failures than it
gains — and in a time-boxed project that trade is rarely worth it. Mixing
libraries in one design is possible but adds real integration risk.

All `hd` cells are **2.72 µm tall**; only width varies. This is why custom cells
must match that height — the power/ground rails won't line up otherwise.

## Cell naming and drive strength

Format: `sky130_fd_sc_hd__<function><inputs>_<drive>`

Examples: `sky130_fd_sc_hd__nand2_1`, `nand2_2`, `nand2_4`, `nand2_8` —
the suffix is drive strength. Higher drive = lower delay into a given load, but
larger input capacitance, so it loads *its* driver more. This is why blind
upsizing along a path doesn't monotonically improve it, and why the resizer works
iteratively.

Cells worth knowing:

| Cell | Role |
|---|---|
| `inv_1`, `inv_2`, … | Inverters. `SYNTH_DRIVING_CELL` defaults to `inv_2` in v1.1.x (older versions used `inv_1`, which could crash timing-driven placement) |
| `buf_1` … `buf_16` | Buffers. Used for slew repair, long-net segmentation, and hold padding |
| `clkbuf_1` … `clkbuf_16` | Clock buffers. `clkbuf_16` is the default root buffer, `clkbuf_4` for inner nodes |
| `dfxtp_*` | D flip-flop, no reset |
| `dfrtp_*` | D flip-flop with reset — what most RTL infers |
| `diode_2` | Antenna diode |
| `decap_*`, `fill_*`, `tap_*` | Physical-only cells. Covered by the default `CELL_PAD_EXCLUDE`; `diode*` is **not** — add it |
| `conb_1` | Constant tie cell |

`DRC_EXCLUDE_CELL_LIST` and `NO_SYNTH_CELL_LIST` (in
`$PDK_ROOT/$PDK/libs.tech/openlane/$STD_CELL_LIBRARY/`) define cells excluded
from synthesis and from resizer optimization because of known DRC problems.
`sky130_fd_sc_hd__inv_1` missing from the trimmed liberty was the source of the
historical `PL_TIME_DRIVEN` crash — fixed by the v1.1.x default of `inv_2`. If a cell you expect isn't being used, check these lists.

## Routing stack and layer RC

sky130 has 6 routing layers. Resistance and capacitance per micron:

| Layer | R/µm (Ω) | C/µm (fF) | Notes |
|---|---|---|---|
| `li1` | 71.76 | 0.15 | **~80× the resistance of met1.** Local interconnect only. Keep long nets and clocks off it |
| `mcon` | 9.25 (per via) | — | |
| `met1` | 0.893 | 0.145 | |
| `via` | 4.5 (per via) | — | |
| `met2` | 0.893 | 0.133 | |
| `via2` | 3.369 (per via) | — | |
| `met3` | 0.157 | 0.146 | Resistance drops ~5.7× from met2 |
| `via3` | 0.376 (per via) | — | |
| `met4` | 0.157 | 0.13 | **Macro routing ceiling** |
| `via4` | 0.005 (per via) | — | |
| `met5` | 0.018 | 0.15 | Lowest resistance. Reserve for core/top-level and PDN |

Via resistances are **per via**, not per micron.

Consequences worth internalizing:

- The `li1` → `met1` resistance cliff is dramatic. A long net routed on `li1`
  behaves completely differently from the same net on `met1`. This is why sky130's
  default `GRT_LAYER_ADJUSTMENTS` de-rates `li1` to ~0.99, near-forbidding it
  for global routing while `DRT_MIN_LAYER` can still let detailed routing use it
  for short local fixes.
- Clock nets on `met4`/`met5` get lower and more uniform delay — directly reduces
  skew, which directly reduces hold violations.
- Capacitance is roughly flat across layers (~0.13–0.15 fF/µm), so layer choice is
  fundamentally a resistance decision.
- Vias are not free. A path with many layer changes accumulates via resistance.

## PDN structure

Power flows: pads → ring → straps → rails.

Rails have a **2.72 µm pitch**, matching cell height. Defaults: `met4` vertical
straps (`FP_PDN_VPITCH` 153.6, `FP_PDN_VOFFSET` 16.32), `met5` horizontal straps
(`FP_PDN_HPITCH` 153.18, `FP_PDN_HOFFSET` 16.65).

Rules that bite:

- **Macros: only `met1` (rails) and `met4` (straps). `met5` belongs to the core.**
  Set `DESIGN_IS_CORE 0`, `FP_PDN_CORE_RING 0`, `RT_MAX_LAYER met4` when hardening
  a macro.
- Macro height must be ≥ `FP_PDN_HPITCH` so at least two `met5` straps cross it,
  allowing met5→met4 vias to connect the macro's grid to the core ring. A macro
  shorter than the pitch may end up with unconnected power.
- `FP_PDN_CHECK_NODES 1` catches unconnected PDN nodes — leave it on; these show
  up later as baffling LVS failures.

## Timing corners

| Corner | Library | Analysis |
|---|---|---|
| Fast | `sky130_fd_sc_hd__ff_n40C_1v95.lib` | **Hold** (minimum delay) |
| Typical | `sky130_fd_sc_hd__tt_025C_1v80.lib` | Nominal reference, synthesis default |
| Slow | `sky130_fd_sc_hd__ss_100C_1v60.lib` | **Setup** (maximum delay) |

Naming: `<corner>_<temperature>C_<voltage>`. `n40C` is −40 °C. Voltage `1v95` /
`1v80` / `1v60`.

Signing off only at `tt` is the classic mistake — it is neither the setup-worst
nor the hold-worst condition, so it can look clean while both real corners fail.
Always report setup at `ss` and hold at `ff`.

See the trap note in `openlane-variables.md`: the `LIB_FASTEST`/`LIB_SLOWEST`
descriptions in the OL1 docs are swapped relative to their defaults.

## Estimation heuristics

Rough figures for sanity-checking, not for signing off:

- A simple gate with moderate load: ~50–150 ps. So roughly 7–20 logic levels fit
  in a 1 ns budget, load-dependent.
- Flop CLK→Q: ~200–400 ps depending on cell and load.
- Setup time: ~50–150 ps. Hold time: near zero to slightly negative for many `hd`
  flops.
- A design with a 10 ns period (100 MHz) and ~40 levels of logic will not close.
  A design with ~10 levels closes comfortably.
- 100 MHz is a comfortable target for a straightforward RISC-V core in sky130 `hd`
  through OpenLane. 50 MHz is easy. Pushing past ~150–200 MHz requires deliberate
  pipelining and real effort.

Use these to decide **whether a target is achievable at all** before spending
hours tuning toward it. The most valuable early conclusion is often "this clock
target is unrealistic for this RTL" — reached in five minutes instead of five
hours.
