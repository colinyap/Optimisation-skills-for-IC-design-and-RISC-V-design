# Resources: Where to Find Authoritative Information

Ordered by authority. When two sources disagree, the one higher in this file
wins — and the project's own documents outrank everything here.

## Contents
- [Precedence order](#precedence-order)
- [Specifications](#specifications)
- [Reference implementations](#reference-implementations)
- [Test suites and verification tools](#test-suites-and-verification-tools)
- [Toolchain and simulators](#toolchain-and-simulators)
- [Physical implementation](#physical-implementation)
- [Textbooks and courses](#textbooks-and-courses)
- [CRC references](#crc-references)
- [Reading a reference core productively](#reading-a-reference-core-productively)
- [Staleness warnings](#staleness-warnings)

---

## Precedence order

1. **The project's own documents** — block guide, memory map, rubric, platform
   docs. These define the custom parts, which exist nowhere else.
2. **The ratified RISC-V specification** for standard instructions.
3. **`riscv-opcodes`**, the machine-readable encoding source of truth — generate
   decode tables from it rather than transcribing by hand.
4. **A reference implementation** that has passed the architectural tests.
5. **This skill's reference files.**
6. **Tutorials, blog posts, and course slides** — useful for intuition, routinely
   out of date on specifics.

---

## Specifications

| Source | What it gives you |
|---|---|
| `riscv.org/technical/specifications/` | The ratified ISA specifications. **Volume 1, Unprivileged** is the one you need for RV32I and M. **Volume 2, Privileged** for CSRs, traps, and machine mode. |
| `github.com/riscv/riscv-isa-manual` | Source of the above, including drafts. Check which version a project targets — encodings are stable, but assembly mnemonics and CSR details have moved. |
| `github.com/riscv/riscv-opcodes` | Machine-readable encoding tables plus generators that emit C headers, Verilog `localparam` sets, and Chisel. **Use this to produce decode constants** — hand-transcribed opcode tables are a recurring source of silent bugs. |
| RISC-V ISA reference card ("green card") | One-page instruction summary. Excellent desk reference, not authoritative. |

For the four multiply instructions, the relevant section is the **M extension**
chapter of Volume 1 — note that the specification defines eight instructions and
a project asking for "four" means the multiply half only.

---

## Reference implementations

Read these. Reading a working core teaches more per hour than any tutorial, and
comparing two that made opposite tradeoffs teaches more still.

**The language column matters** — under a Verilog-2001 constraint, a
SystemVerilog reference is still worth reading for structure but cannot be copied.

| Core | Language | Style | Read it for |
|---|---|---|---|
| `github.com/YosysHQ/picorv32` | **Verilog** | multicycle-ish, size-optimized | The best-documented small Verilog core in existence. Excellent memory interface, clean parameterization, and a reference implementation of RVFI. **Start here.** |
| `github.com/olofk/serv` | **Verilog** | bit-serial | The world's smallest RISC-V core. An extreme, instructive lesson in the area/CPI tradeoff — one bit per cycle. |
| `github.com/darklife/darkriscv` | **Verilog** | 2-3 stage pipeline | Deliberately minimal and readable; a good second core after picorv32. |
| `github.com/AngeloJacobo/RISC-V` | **Verilog** | 5-stage pipeline + Zicsr | Passes `rv32ui` and `rv32mi`; includes a regression script and FPGA flow. Good model for how to structure a *verified* project. |
| `github.com/wdevore/RISC-V-RV32I-MultiCycle` | Verilog/SV mix | **multicycle** | One of the few public multicycle RV32I cores — directly relevant when the spec asks for an FSM core. |
| `github.com/PebPeb/Single-Cycle-RV32I` | **Verilog** | single-cycle | Small enough to read in one sitting; useful as the "before" picture when converting to multicycle. |
| `github.com/franzflasch/leiwand_rv32` | **Verilog** | simple FSM | Honest, small, educational; the author documents what is *not* implemented, which is instructive. |
| BRISC-V (`arxiv.org/abs/1908.09992`) | **Verilog** | parameterized, multi-core | Academic design-space-exploration platform. The paper is a good read on modularity in core design. |
| `github.com/lowRISC/ibex` | SystemVerilog | 2-stage, production | Industrial quality. Read the verification setup and the documentation structure even if you cannot copy the RTL. |
| `github.com/openhwgroup/cv32e40p` | SystemVerilog | 4-stage, production | Industrial, with a full verification environment. Same value as ibex. |
| `github.com/stnolting/neorv32` | VHDL | full SoC | The best reference for *SoC integration* — peripherals, memory maps, bootloader — even though the language is wrong for a Verilog project. |
| `github.com/SpinalHDL/VexRiscv` | SpinalHDL | configurable pipeline | Read the architecture docs for how a configurable pipeline is organized. |
| `github.com/ucb-bar/riscv-mini` | Chisel | 3-stage | Small, clean, and paired with a good testing setup. |

---

## Test suites and verification tools

| Source | What it is |
|---|---|
| `github.com/riscv-software-src/riscv-tests` | Berkeley's self-checking assembly tests. `isa/rv32ui-p-*` covers base integer, `rv32um-p-*` covers M. The fastest route to broad coverage. **Start here.** |
| `github.com/riscv/riscv-arch-test` | Official Architectural Certification Tests. Signature-based, compared against the Sail model. Now uses the **ACT4 framework**. |
| `riscof.readthedocs.io` | The older RISCOF framework — **deprecated**, replaced by ACT4. Most online tutorials still describe it. |
| `github.com/YosysHQ/riscv-formal` | Formal ISA-compliance framework via the RVFI interface. Includes bindings for picorv32 as a worked example. Note the repo moved from `SymbioticEDA` to `YosysHQ`. |
| `github.com/riscv-software-src/riscv-isa-sim` | Spike, the golden-reference ISS. Use it to validate your own golden model before trusting it. |
| `github.com/riscv/sail-riscv` | The formal Sail model — the specification as executable code. The authority when the prose is ambiguous. |

---

## Toolchain and simulators

| Tool | Notes |
|---|---|
| `github.com/riscv-collab/riscv-gnu-toolchain` | GCC, binutils, newlib. Build with `--with-arch=rv32im --with-abi=ilp32`. Needed for `.insn` macros and `objcopy -O verilog`. |
| Icarus Verilog (`github.com/steveicarus/iverilog`) | Best default for Verilog-2001 testbenches. Full event-driven semantics, VCD output, tiny install. |
| Verilator (`github.com/verilator/verilator`) | Orders of magnitude faster, and the right choice for long random co-simulation runs. Cycle-accurate only — **no delay or SDF support**, and it lints strictly, which is a feature. |
| GTKWave / Surfer | Waveform viewers. Reach for them *after* the trace diff, not before. |
| Yosys (`github.com/YosysHQ/yosys`) | Synthesis. Also the fastest lint available: `read_verilog -sv0` plus `hierarchy -check` and `check` catches most structural errors. |
| SymbiYosys (`github.com/YosysHQ/sby`) | Formal front-end, required by `riscv-formal`. |

**Minimal simulation loop** worth scripting on day one:

```bash
iverilog -g2001 -o sim.vvp -s tb_core rtl/*.v tb/tb_core.v && \
vvp sim.vvp +hex=$1 | tee run.log && \
grep -q "RESULT: PASS" run.log && echo OK || echo BROKEN
```

`-g2001` pins the language version, which turns an accidental SystemVerilog
construct into an immediate error instead of a portability surprise later.

---

## Physical implementation

Everything here is `ic-design-optimization` territory; listed so the handoff has
addresses.

| Source | Notes |
|---|---|
| `chipinventor.com` | Cloud EDA platform built on OpenROAD/OpenLane, with a block-diagram interface, Verilog module authoring, FPGA prototyping, and a path to fabrication. Verilog HDL, not SystemVerilog. |
| `github.com/The-OpenROAD-Project/OpenLane` | The RTL-to-GDSII flow underneath. |
| `github.com/google/skywater-pdk` | The sky130 PDK. |
| `github.com/AUCOHL/DFFRAM` | Standard-cell memory compiler — the practical answer for small RAMs on sky130 without an SRAM macro. |
| `github.com/VLSIDA/OpenRAM` | SRAM compiler for larger arrays. |

---

## Textbooks and courses

| Source | Why |
|---|---|
| Harris & Harris, *Digital Design and Computer Architecture, RISC-V Edition* | The definitive treatment of single-cycle, **multicycle**, and pipelined RISC-V datapaths, with complete control tables. Chapter 7 is the direct reference for FSM-based cores. Note its multicycle machine is variable-length (8–11 states) — see `microarchitecture.md` for why that differs from a uniform four-state spec. |
| Patterson & Hennessy, *Computer Organization and Design, RISC-V Edition* | The canonical treatment of pipelining, hazards, and forwarding. The pipeline chapter is the reference for scaling-ladder rung 2. |
| Waterman, *Design of the RISC-V Instruction Set Architecture* (PhD thesis, Berkeley) | Why the ISA is shaped the way it is — particularly why the immediate encodings look scrambled. Read it once and the immediate generator stops feeling arbitrary. |
| Hennessy & Patterson, *Computer Architecture: A Quantitative Approach* | For scaling-ladder rungs 5–7: superscalar, out-of-order, memory hierarchy. |
| Berkeley CS152 / MIT 6.191 open courseware | Lecture material and problem sets on exactly these microarchitectures. |

---

## CRC references

| Source | Why |
|---|---|
| Ross Williams, *A Painless Guide to CRC Error Detection Algorithms* | The standard tutorial. Explains reflection, initial value, and final XOR — the three parameters that make two "CRC-32" implementations disagree. |
| `reveng.sourceforge.io/crc-catalogue/` | Catalogue of CRC parameterizations with their **check values** (the result over `"123456789"`). The fastest way to identify which CRC a specification actually means. |
| `zlib` `crc32.c` | A reference software implementation of CRC-32/ISO-HDLC. Useful for generating expected values for arbitrary test buffers. |

---

## Reading a reference core productively

Reading a core front-to-back rarely works. This order does:

1. **The top-level port list.** How does it talk to memory? One port or two?
   Handshake or fixed latency? This constrains everything else.
2. **The state register or pipeline register declarations.** They are the
   microarchitecture. Everything else is combinational logic between them.
3. **The decoder.** Compare it against your own encoding table — this is where you
   discover an instruction you got wrong.
4. **The one hard part.** For a multicycle core, the FSM. For a pipeline, the
   hazard unit. Skip everything else on the first pass.
5. **Its testbench and test list.** Frequently more instructive than the RTL,
   because it shows what the author was afraid of.

Compare *pairs* that made opposite choices — `picorv32` against `serv` on the
area/CPI axis, or a single-cycle core against a multicycle one on the same ISA.
The differences carry the design reasoning; either core alone just looks like the
way it had to be done.

---

## Staleness warnings

Things that are commonly wrong in older material, checked as of this skill's
writing and worth re-verifying rather than trusting:

- **RISCOF is deprecated**, replaced by the ACT4 framework in `riscv-arch-test`.
  Most tutorials still describe RISCOF's plugin and config-file flow.
- **`riscv-formal` moved** from `SymbioticEDA` to `YosysHQ`. Old links redirect
  but old instructions may not match.
- **RISC-V specification versions.** Encodings for RV32I and M are stable and
  ratified; CSR details, mnemonics, and the privileged specification have moved
  more. Check which version a project targets.
- **OpenLane 1 versus OpenLane 2 / LibreLane** — variables renamed, defaults
  changed, some legacy settings now hard-error. `ic-design-optimization` covers
  this in detail and ships a script to check a run's actual variable set.
- **Toolchain target triples** vary (`riscv32-unknown-elf-`, `riscv64-unknown-elf-`
  with `-march=rv32im`, distro packages with other prefixes). Do not hardcode a
  prefix in a build script without checking what is installed.

The general rule, borrowed from `ic-design-optimization`: **verify against the
tool, not against documentation.** Disassemble what your assembler produced,
inspect the netlist your synthesis run created, and read the config the flow
actually expanded. Documentation goes stale; artifacts do not.
