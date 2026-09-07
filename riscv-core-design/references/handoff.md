# Handoff to `ic-design-optimization`

Read this at Phase G, before any PPA work begins.

---

### The handoff packet

`ic-design-optimization` Phase 0/1 asks for specific things by name, and a
partial handoff makes it guess. Assemble all of it before switching skills:

| Field | Source |
|---|---|
| Primary objective, **ranked** | The spec or contest rules |
| **Scoring function**, verbatim, if this is a contest | The rules. Do not paraphrase it |
| Hard constraints: fixed clock, fixed `DIE_AREA`, fixed pins, macros | The spec |
| Acceptance bar: tapeout-clean, or are some DRCs survivable? | The spec |
| Iteration budget: hours and cores | You |
| `reports/metrics.csv` (or `final_summary_report.csv`) | The run |
| Synthesis stat: cell count, cell area, chip area, **flop count**, gate breakdown | The run |
| Post-synthesis STA: numeric `wns`/`tns`, plus the worst path with full delay breakdown | The run |
| `config.tcl` / `config.json` — non-default values especially | The run |
| OpenLane version and PDK variant (sky130A vs sky130B, `hd` vs another SCL) | The environment |
| **Measured CPI on a representative program** | Phase F |
| **The forbidden-fix list** (below) | The spec |

### Translate the objective before you hand it over

`ic-design-optimization` optimizes what you name. Its objective model is
frequency, area, and power — it has no concept of instruction throughput, so
"maximize fmax" is a request it will grant literally and a CPU is the one design
class where granting it can lose. The real figure of merit is:

```
time per instruction  =  CPI x T_clk
```

Both terms are live, and they are owned by different skills: `T_clk` belongs to
`ic-design-optimization`, `CPI` belongs here. A change that improves one while
worsening the other must be evaluated on the product, and only you can do that
arithmetic — so do it before accepting any RTL-level timing fix:

```
accept the change only if   CPI_new x T_new  <  CPI_old x T_old
equivalently, required speedup  =  CPI_new / CPI_old
```

**Worked example, measured on `assets/`.** Splitting the EXECUTE state in two is
a textbook class-C fix for a critical path that lands in the ALU or multiplier.
Applied to the reference core it moved CPI from 4.00 to 5.00 on the benchmark —
so it must buy **25% higher fmax just to break even**, which splitting a single
state rarely does. At a generous +15%, `T` improves 10.0ns to 8.70ns while time
per instruction goes 40.0ns to 43.5ns: the core got **8.7% slower** while every
metric the optimization skill tracks reported an improvement.

The same edit also silently broke the core — the bus-drive side effects in
EXECUTE now fire across two cycles, and the regression went from PASS to FAIL.
That is the Rung 1 bug class in `microarchitecture.md`, and it is why the
re-verification step in Phase I is not optional.

State the objective to `ic-design-optimization` as **"minimize `T_clk` subject to
CPI staying at N"**, name N, and list the forbidden fixes. Then it can optimize
freely inside a box that cannot cost you throughput.

### The forbidden-fix list

Some legitimate class-C fixes are prohibited by the specification, and the
optimization skill has no way to know that. Write the list down and hand it over.
Typical entries when a spec mandates a microarchitecture:

- **Adding or removing FSM states** when the spec mandates a fixed-length cycle
  structure (a uniform four-state Fetch/Decode/Execute/Writeback core cannot
  become five states, however good the timing argument).
- **Pipelining** when the spec names a multicycle implementation.
- **Changing the ISA** — dropping an instruction to shorten a path is not a
  tradeoff, it is a different processor.
- **Changing the memory interface or map** when downstream integration depends
  on it.
- Anything that changes an interface another team or a later phase depends on.

If a recommended fix is on this list, it is not a tradeoff to evaluate — it is
out of bounds, and the honest report is that this path is closed and the timing
must come from somewhere else. Principle 1 governs: the spec outranks the skill.

