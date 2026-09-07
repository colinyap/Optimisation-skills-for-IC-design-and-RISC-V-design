# Microarchitecture Reference

From the four-state multicycle core up to the structures that appear in
production designs. Read the section that matches the execution model the
specification actually asks for.

## Contents
- [Choosing an execution model](#choosing-an-execution-model)
- [The four-state multicycle core](#the-four-state-multicycle-core)
- [Where the memory access lands (the decision that defines the design)](#where-the-memory-access-lands-the-decision-that-defines-the-design)
- [Datapath inventory](#datapath-inventory)
- [Control signal table](#control-signal-table)
- [Bus arbitration in a shared-port core](#bus-arbitration-in-a-shared-port-core)
- [Load-store unit](#load-store-unit)
- [Memory map and address decoding](#memory-map-and-address-decoding)
- [Variable-latency execute](#variable-latency-execute)
- [Register file](#register-file)
- [Reset, X-propagation, and bringup](#reset-x-propagation-and-bringup)
- [The scaling ladder](#the-scaling-ladder)

---

## Choosing an execution model

| Model | CPI | Rel. fmax | Complexity | Use when |
|---|---|---|---|---|
| Single-cycle | 1.0 | very low | trivial | Teaching the datapath; never for silicon |
| **Multicycle FSM (fixed 4)** | **4.0** | high | low | Specified cycle model; shared memory port; small area |
| Multicycle FSM (variable 3–5) | ~3.4 | high | low-med | Same, with CPI headroom taken |
| 5-stage pipeline | ~1.2 | high | medium | Throughput matters; hazard logic is affordable |
| Pipeline + branch prediction | ~1.1 | high | med-high | Branch-heavy code, deeper pipe |
| Superscalar / OoO | <1.0 | high | very high | Only with a verification budget to match |

**If the specification names a model, build that model.** A four-state
Fetch/Decode/Execute/Writeback FSM is a specification, not a suggestion — a
five-stage pipeline submitted against it is wrong even if it is faster. Note also
that a fixed-length four-state FSM is *not* the variable-length multicycle
machine in Patterson & Hennessy or Harris & Harris, which uses eight to eleven
states with different instructions taking different numbers of cycles. Copying
that FSM against a uniform-four-state spec produces a mismatch that is easy to
miss and hard to argue with in review.

The honest case for a fixed-length FSM: it costs a little CPI and buys a
dramatically simpler control unit, one memory port shared between instruction and
data without a structural hazard, and room to add functional units with
multi-cycle latency later. That last point is usually why a course or competition
asks for it.

---

## The four-state multicycle core

```
                 ┌──────────────────────────────────────────┐
                 ▼                                          │
            ┌─────────┐    ┌─────────┐   ┌─────────┐   ┌──────────┐
   reset ──►│  FETCH  │───►│ DECODE  │──►│ EXECUTE │──►│ WRITEBACK│
            └─────────┘    └─────────┘   └─────────┘   └──────────┘
             drive PC       instr valid    ALU / MUL     load data
             on bus         decode+regread  / CRC        returns
             latch addr     latch IR,A,B    drive dmem   regfile write
                                            addr, store  PC update
```

State encoding — plain `localparam`, because `typedef enum` is SystemVerilog:

```verilog
localparam [1:0] S_FETCH  = 2'd0,
                 S_DECODE = 2'd1,
                 S_EXEC   = 2'd2,
                 S_WB     = 2'd3;

reg [1:0] state, next_state;

always @(posedge clk) begin
    if (!rst_n) state <= S_FETCH;
    else        state <= next_state;
end

always @(*) begin
    next_state = state;                 // default: hold (see note)
    case (state)
        S_FETCH : next_state = S_DECODE;
        S_DECODE: next_state = S_EXEC;
        S_EXEC  : next_state = ex_done ? S_WB : S_EXEC;   // stall hook
        S_WB    : next_state = mem_ready ? S_FETCH : S_WB;
        default : next_state = S_FETCH;
    endcase
end
```

Two things in that skeleton matter more than they look:

- **The default assignment `next_state = state` at the top.** Without it, any
  path through the `case` that does not assign `next_state` infers a latch. This
  is the most common source of "my FSM works in simulation and hangs after
  synthesis."

  Two refinements worth knowing. First, a `case` whose branches are exhaustive
  *and* which has a `default:` branch that assigns every output does not infer a
  latch even without the top-of-block default — but write the default anyway,
  because the discipline costs one line and survives the edit where somebody adds
  a branch. The real exposure is not a missing `default:`; it is a branch that
  assigns *some* outputs and forgets others, which is invisible on inspection
  once a control block has a dozen signals.

  Second, and this is the part that costs people days: **simulation will not
  catch this.** A latch in an `always @(*)` block simply holds its previous value
  in simulation, which is frequently the correct value for the sequence you
  happen to be testing. A core with inferred latches in its decoder can pass a
  full instruction-level regression with byte-identical traces and still fail
  after synthesis. Detection is therefore a synthesis-time or lint-time activity,
  never a simulation one: run the design through a lint pass or a trial synthesis
  and read the inferred-latch warnings before you believe a clean regression.
  This is why Phase G is a gate and not a formality.
- **The `ex_done` and `mem_ready` hooks.** They cost nothing when tied to 1, and
  they are how a multi-cycle multiplier or a slow peripheral gets added later
  without redesigning the FSM. Put them in from the start.

Use a three-block FSM (state register / next-state logic / output logic) rather
than a single always block. It is more verbose and it is what every synthesis
tool, linter, and reviewer expects.

---

## Where the memory access lands (the decision that defines the design)

A four-state FSM has to place the instruction fetch and the data access somewhere,
and the right placement depends entirely on whether memory read data is
**combinational** or **registered**. Getting this wrong produces a core that works
in simulation against a behavioral memory and fails the moment a real SRAM macro
appears.

| | **Mapping A** — async-read memory | **Mapping B** — sync-read memory |
|---|---|---|
| FETCH | drive PC; `rdata` returns in-cycle; latch IR | drive PC; memory registers the address |
| DECODE | decode `IR`; read regfile; latch A, B | `rdata` = instruction; decode it combinationally; latch IR, A, B, control |
| EXECUTE | ALU/MUL/CRC; drive data address | ALU/MUL/CRC; drive data address + `wstrb`; memory registers it |
| WRITEBACK | data available; align/extend; write regfile; update PC | `rdata` = load data; align/extend; write regfile; update PC |
| Memory model | `assign rdata = mem[addr]` | `always @(posedge clk) rdata <= mem[addr]` |
| Synthesizes to a real SRAM? | **no** | **yes** |

**Choose Mapping B.** Asynchronous-read memory exists in textbooks and in FPGA
distributed RAM; it does not exist as an ASIC macro. Mapping B also lands the
data return in WRITEBACK naturally, which is what a four-state specification is
usually describing.

The one thing Mapping B costs: decode must be combinational off `bus_rdata`
during DECODE, so the path *memory output → decoder → register-file read →
operand register* is real and worth watching in synthesis. If it becomes the
critical path, the fix is to register the instruction in DECODE and move decode
into EXECUTE — which turns the load path into five cycles, so weigh it against
the CPI cost rather than doing it reflexively.

Stores commit at the end of EXECUTE (address and `wstrb` are driven during
EXECUTE, the memory latches both), which makes WRITEBACK a dead cycle for stores
and branches — the basis of the early-exit optimization in `optimization.md`.

---

## Datapath inventory

Every register and mux the four-state core needs. If your block diagram is
missing one of these, that is the bug you would otherwise find in integration.

**State-holding elements**

| Element | Width | Written in | Purpose |
|---|---|---|---|
| `pc` | 32 | WRITEBACK | current instruction address |
| `ir` | 32 | DECODE (mapping B) | instruction under execution |
| `rs1_q`, `rs2_q` | 32 each | DECODE | register operands captured for EX/WB |
| `alu_q` | 32 | EXECUTE | result carried to writeback; also the load/store address |
| control regs | ~15 | DECODE | decoded control carried into EX and WB |
| `regfile` | 32×32 | WRITEBACK | architectural registers |

**Multiplexers** — name each select signal; these become your control signals.

| Mux | Selects between | Select signal |
|---|---|---|
| ALU operand A | `rs1_q`, `pc` | `alu_a_sel` |
| ALU operand B | `rs2_q`, immediate, `4` | `alu_b_sel[1:0]` |
| Immediate | I, S, B, U, J | `imm_sel[2:0]` |
| Result | ALU, multiplier, CRC, LSU load data, `pc+4`, `imm_u` | `wb_sel[2:0]` |
| Next PC | `pc+4`, branch/jump target, `(rs1+imm)&~1` | `pc_sel[1:0]` |
| Bus address | `pc`, `alu_q` | `addr_sel` (FSM state) |

The result mux is the one people under-size. `LUI` needs the raw upper immediate,
`AUIPC` needs a PC-relative sum, `JAL`/`JALR` need `pc+4`, loads need the LSU
output, and multiply and CRC each need their own port. Route `AUIPC` through the
ALU (operand A = `pc`, operand B = `imm_u`) rather than adding a seventh mux input.

---

## Control signal table

Filling in this table *is* the control unit design. One row per signal, one
column per instruction class; the FSM state then gates when each is active.
Blank cells are bugs.

| signal | OP / OP-IMM | LOAD | STORE | BRANCH | JAL/JALR | LUI | AUIPC | MUL | CRC |
|---|---|---|---|---|---|---|---|---|---|
| `alu_a_sel` | rs1 | rs1 | rs1 | pc | pc | – | pc | rs1 | rs1 |
| `alu_b_sel` | rs2/imm | imm_i | imm_s | imm_b | imm_j/imm_i | – | imm_u | rs2 | rs2 |
| `alu_op` | from f3/f7 | ADD | ADD | ADD | ADD | – | ADD | – | – |
| `mem_read` | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `mem_write` | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| `mem_size` | – | f3 | f3 | – | – | – | – | – | – |
| `reg_write` | 1 | 1 | 0 | 0 | 1 | 1 | 1 | 1 | 1 |
| `wb_sel` | ALU | LSU | – | – | PC4 | IMM | ALU | MUL | CRC |
| `pc_sel` | +4 | +4 | +4 | cond | target | +4 | +4 | +4 | +4 |
| `branch_op` | – | – | – | f3 | – | – | – | – | – |

Two derived rules that eliminate a whole class of bugs:

- **`reg_write` must be forced to 0 when `rd == 0`.** Do it in one place — at the
  register file write port — not in every instruction's control decode.
- **`mem_write` must be qualified by the FSM state.** A `mem_write` that is
  combinationally true throughout EXECUTE *and* WRITEBACK writes memory twice.
  Gate every side-effecting signal with the state that owns it.

---

## Bus arbitration in a shared-port core

The structural reason to build a multicycle machine: one memory port, used for
instructions in one cycle and data in another, so instruction and data can live
in the same address space without a second port.

```verilog
// Address/control mux driven by FSM state. The state IS the arbiter.
always @(*) begin
    bus_addr  = pc;                       // safe default
    bus_wdata = 32'b0;
    bus_wstrb = 4'b0000;                  // no write unless explicitly enabled
    bus_req   = 1'b0;
    case (state)
        S_FETCH: begin
            bus_addr = pc;
            bus_req  = 1'b1;
        end
        S_EXEC: if (mem_read || mem_write) begin
            bus_addr  = alu_result;       // rs1 + imm, computed this cycle
            bus_wdata = lsu_wdata;
            bus_wstrb = mem_write ? lsu_wstrb : 4'b0000;
            bus_req   = 1'b1;
        end
        default: ;                        // DECODE and WB consume, not drive
    endcase
end
```

Note `bus_wstrb` defaults to zero and is only set on an explicit store in
EXECUTE. Write enables are the signals where a missing default assignment causes
memory corruption rather than a wrong value, so give them a safe default at the
top of the block and never rely on the `case` covering every path.

If the specification instead calls for separate instruction and data memories
(Harvard), the same structure applies with two ports and no arbitration — but
keep the address decoder, because loads that target the instruction memory are a
normal thing for a program that reads constants from its own image, and that is
exactly the case a Harvard split breaks.

---

## Load-store unit

The LSU sits between the core and the bus and does four jobs: compute nothing
(the ALU already computed the address), select the addressed bytes out of a
word-wide read, extend them, and place store data in the correct lane with the
correct byte strobes.

**Store path** — replicate the data across lanes, then let `wstrb` pick:

```verilog
always @(*) begin
    case (funct3)
        3'b000: begin                                  // SB
            wdata = {4{rs2_q[7:0]}};
            wstrb = 4'b0001 << addr[1:0];
        end
        3'b001: begin                                  // SH
            wdata = {2{rs2_q[15:0]}};
            wstrb = addr[1] ? 4'b1100 : 4'b0011;
        end
        3'b010: begin                                  // SW
            wdata = rs2_q;
            wstrb = 4'b1111;
        end
        default: begin
            wdata = rs2_q;
            wstrb = 4'b0000;                           // unknown size: no write
        end
    endcase
end
```

Replication is what makes the byte strobes sufficient — the memory never has to
shift, it just masks. Sending unshifted data and expecting the memory to place it
is the most common LSU bug, and it only shows up at non-zero byte offsets.

**Load path** — select, then extend:

```verilog
reg [7:0]  byte_sel;
reg [15:0] half_sel;
always @(*) begin
    case (addr[1:0])
        2'b00: byte_sel = rdata[7:0];
        2'b01: byte_sel = rdata[15:8];
        2'b10: byte_sel = rdata[23:16];
        2'b11: byte_sel = rdata[31:24];
    endcase
    half_sel = addr[1] ? rdata[31:16] : rdata[15:0];

    case (funct3)
        3'b000: load_data = {{24{byte_sel[7]}},  byte_sel};   // LB  signed
        3'b001: load_data = {{16{half_sel[15]}}, half_sel};   // LH  signed
        3'b010: load_data = rdata;                            // LW
        3'b100: load_data = {24'b0, byte_sel};                // LBU zero
        3'b101: load_data = {16'b0, half_sel};                // LHU zero
        default: load_data = rdata;
    endcase
end
```

**Misalignment** — `LH`/`LHU`/`SH` require `addr[0] == 0`; `LW`/`SW` require
`addr[1:0] == 00`. Detect and expose it:

```verilog
wire misaligned = ((funct3[1:0] == 2'b01) && addr[0]) ||      // half
                  ((funct3[1:0] == 2'b10) && (|addr[1:0]));    // word
```

What to do with it is a spec question — trap, ignore, or drive an error output.
Without trap support, an error output plus a note in the documentation is the
honest choice. Silently returning rotated data is the worst outcome because it
looks like working hardware.

**LSU test matrix** — every load type × every legal byte offset × a value whose
high bit is set (to catch sign extension) is 20-odd cases and finds essentially
all LSU bugs. Write it as a loop, not by hand; see `verification.md`.

---

## Memory map and address decoding

Decode on the **high** address bits, one-hot select, and always define the
default. Defaults below — **replace them with the project's memory map document.**

```verilog
// Region bases (override from the project spec).
localparam [31:0] IMEM_BASE = 32'h0000_0000, IMEM_SIZE = 32'h0001_0000; // 64 KiB
localparam [31:0] DMEM_BASE = 32'h1000_0000, DMEM_SIZE = 32'h0001_0000;
localparam [31:0] MMIO_BASE = 32'h2000_0000, MMIO_SIZE = 32'h0000_1000;

wire sel_imem = (addr[31:16] == IMEM_BASE[31:16]);
wire sel_dmem = (addr[31:16] == DMEM_BASE[31:16]);
wire sel_mmio = (addr[31:12] == MMIO_BASE[31:12]);
wire sel_none = ~(sel_imem | sel_dmem | sel_mmio);   // bus fault

// Read data mux — one-hot, with a defined value on no-match.
assign rdata = sel_imem ? imem_rdata :
               sel_dmem ? dmem_rdata :
               sel_mmio ? mmio_rdata : 32'hDEAD_BEEF;
```

Points that matter:

- **Compare only the bits that distinguish regions.** A full 32-bit comparison
  per region is a wide gate on the address path for no benefit.
- **Give unmapped accesses a defined value**, not `x`. An `x` here propagates
  through the whole core and turns a localized bug into an unreadable waveform.
  A recognizable poison value makes the bug obvious in a trace.
- **Both fetch and load/store must reach every region they need.** If the program
  reads constants from the instruction image — normal for `.rodata` — the
  load path needs an `imem` route. This is the case a naive Harvard split silently
  breaks, and it is worth an explicit test.
- **Route the decoder's `sel_none` to a visible error signal or MMIO status bit.**
  A wild pointer is far easier to debug when the hardware says so.
- **MMIO is not memory.** Reads can have side effects, writes can be
  write-only, and latency can exceed one cycle. Give the bus a `ready` signal
  from the start and hold the FSM in WRITEBACK until it asserts — retrofitting
  that later touches every state.

A minimal, extremely useful MMIO set for bringup: a character-output register
(write a byte, the testbench prints it), a cycle counter, and a
simulation-terminate register. Those three turn a silent core into one that can
report its own results.

---

## Variable-latency execute

Any functional unit that cannot finish in one cycle — a multi-cycle multiplier, a
divider, a wide CRC, a slow peripheral — needs a handshake rather than an FSM
rewrite. Define it once:

```verilog
// Unit interface: start pulses for one cycle, done stays high until consumed.
wire mul_start = (state == S_EXEC) && is_mul && !mul_done;
wire ex_done   = is_mul ? mul_done : 1'b1;   // single-cycle units are always done
```

With `ex_done` already wired into the FSM (see the skeleton above), adding a
32-cycle shift-add multiplier is a local change to one module. Without it, the
same change touches the state encoding, every state transition, and every control
output — which is why the hook goes in before it is needed.

The same pattern generalizes: `ex_done` for compute latency, `mem_ready` for bus
latency. Two signals cover every stall the core can experience.

---

## Register file

32 entries × 32 bits, two read ports, one write port. On sky130 this is ~1024
flip-flops plus mux trees and is typically the largest single block in a small
core — worth understanding before optimizing anything else.

```verilog
reg [31:0] regs [1:31];                 // no storage for x0

// Combinational reads with the x0 rule applied at the read port.
assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 : regs[rs1_addr];
assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 : regs[rs2_addr];

always @(posedge clk) begin
    if (rd_we && (rd_addr != 5'd0))
        regs[rd_addr] <= rd_data;
end
```

- **Declaring `regs[1:31]` rather than `[0:31]`** removes 32 flip-flops and makes
  the x0 rule structural instead of behavioural.
- **No reset on the array.** Architecturally, register state after reset is
  undefined, and resetting 1024 flops costs a large reset buffer tree for nothing.
  Initialize in the testbench instead — but see the X-propagation note below.
- **Read-during-write** returns the old value here (the write lands at the clock
  edge). In this multicycle core that never matters, because reads happen in
  DECODE and writes in WRITEBACK. In a pipeline it matters a great deal.
- **Do not infer this as a RAM macro** for a 2-read/1-write port file — most
  single-port macros cannot do it, and the tool will either fail or silently
  build something wrong.

---

## Reset, X-propagation, and bringup

**Reset only what needs it.** `pc`, `state`, and any signal that gates a side
effect (`mem_write`, `reg_write`) must reset. Datapath registers generally need
not — resetting everything inflates the reset tree, which becomes a real
placement and timing problem.

**But unreset registers propagate X in simulation**, and a core full of X is
undebuggable. The resolution: keep the RTL unreset, and have the *testbench* force
a known initial state — a `$readmemh` into the register file array, or a short
initialization loop. That keeps simulation clean without paying for reset in
silicon.

**Reset style.** Synchronous active-low (`if (!rst_n)` inside
`always @(posedge clk)`) is the portable default. Asynchronous assert with
synchronous de-assert is the safer choice for a real chip; either is fine, but
mixing them across modules is not — pick one and apply it everywhere.

**Reset must be held long enough** for any clock-domain-crossing synchronizer to
settle. In a single-clock core, a handful of cycles is plenty; the failure mode
is releasing reset in the same cycle it is applied in a testbench and getting a
race.

**Bringup order that finds bugs fastest**: hold reset, check `pc` is at the reset
vector and `state == S_FETCH`; release reset and single-step one instruction,
checking the bus address equals the reset vector; then `ADDI`, then the sequence
in the main skill's Phase E.

---

## The scaling ladder

Everything above scales. Each rung adds capability and a specific new class of
bug — the bug class is the part worth knowing before committing.

**Climb one rung at a time, and only from a verified footing.** Each rung
assumes the rung below it is passing its full regression, because every rung's
new bug class is diagnosed by *ruling out* the ones beneath it. A forwarding bug
and an ALU bug produce the same wrong register value; if the ALU was never
verified standalone, you cannot tell them apart, and the debugging cost is not
additive but multiplicative. Pick a rung by what is verified, never by ambition
or by what sounds impressive in a report. A correct rung 1 beats a broken rung 2
on every criterion including the marks.

### Rung 1 — Variable-length multicycle
Skip WRITEBACK for stores and branches; CPI drops from 4.0 to roughly 3.4 on
typical code. New bug class: state-dependent side effects firing in the wrong
state. Cheap and safe *when the spec permits it* — a spec that mandates a
uniform fixed-length FSM forbids this rung outright, however good the CPI
argument. Check the forbidden-fix list in `handoff.md` before climbing. Detail in `optimization.md`.

### Rung 2 — Classic 5-stage pipeline (IF/ID/EX/MEM/WB)
CPI approaches 1. Three new hazard classes, and all three must be handled:

- **RAW data hazards** — an instruction reads a register a previous instruction
  has not yet written. Solved by **forwarding**: EX/MEM → EX and MEM/WB → EX
  bypass muxes on both ALU operands, with the EX/MEM path taking priority
  (it carries the more recent value).
- **Load-use hazard** — a load's data is not available until the end of MEM, so an
  immediately dependent instruction cannot be forwarded to. This one *requires* a
  one-cycle stall; no forwarding path can fix it. Detect it as
  `ID/EX.mem_read && (ID/EX.rd == IF/ID.rs1 || ID/EX.rd == IF/ID.rs2)`.
- **Control hazards** — the branch outcome is unknown until EX (or MEM). Either
  flush the wrongly fetched instructions or predict. Resolving branches earlier
  reduces the penalty but lengthens the ID critical path.

Also required: **write-before-read forwarding in the register file** (a register
written in WB must be visible to an instruction reading in ID in the same cycle),
which is usually done by making the read port bypass the write port
combinationally.

**What forwarding must handle.** Deliberately a requirements list, not code —
the mux structure depends on your stage boundaries and register conventions, so
copying someone else's forwarding logic is how you get a subtly wrong core.
Enumerate and test each case:

- EX/MEM result forwarded to either EX operand.
- MEM/WB result forwarded to either EX operand.
- Both hazards live at once: the *newer* producer wins. Getting this priority
  backwards is the single most common forwarding bug and it only shows up on
  back-to-back-to-back dependent instructions.
- Forwarding suppressed when the producer does not write a register (stores,
  branches) — otherwise you forward a stale or meaningless value.
- Forwarding suppressed when the destination is `x0`. Writes to `x0` are
  discarded, so forwarding one propagates a value that architecturally does not
  exist.
- Load-use is *not* forwardable: the data is not available in time, so it needs
  a one-cycle stall, not a mux input.

Test each bullet as its own directed sequence before running anything larger.

### Rung 3 — Branch prediction
Static (backward-taken/forward-not-taken) costs almost nothing and captures most
loop behaviour. Dynamic — a branch history table of 2-bit saturating counters,
then a branch target buffer, then gshare correlating global history — buys more
on branchy code. New bug class: misprediction recovery that leaves architectural
state partially updated. Mispredict recovery must be exercised deliberately;
random tests hit it far too rarely.

### Rung 4 — Caches
Direct-mapped is the starting point: index, tag, valid, and a hit comparator.
Write-through with a write buffer is much easier to verify than write-back
(no dirty-bit tracking, no eviction write path); set associativity adds a
replacement policy. New bug class: coherence between the instruction and data
views of the same address — self-modifying code and freshly loaded programs both
hit this, and RISC-V's `FENCE.I` exists precisely for it.

### Rung 5 — CSRs, traps, and interrupts
The Zicsr extension plus machine-mode trap handling: `mstatus`, `mtvec`, `mepc`,
`mcause`, `mtval`, `mie`, `mip`, and the `CSRRW/CSRRS/CSRRC` instruction family
with their immediate variants. Traps need precise state: on an exception, `mepc`
must hold the address of the faulting instruction and no architectural side
effect from that instruction may have committed. New bug class: imprecise
exceptions — the hardest debugging in this list, because the symptom appears
several instructions after the cause. This rung is also where `riscv-arch-test`
starts being genuinely necessary rather than merely useful.

Machine-mode CSR addresses, for the decode table (from the RISC-V privileged
specification — verify against the current version, addresses are stable but
field layouts have changed across ratifications):

| Address | Name | Purpose |
|---|---|---|
| `0x300` | `mstatus` | Global interrupt enable (`MIE`), previous state (`MPIE`, `MPP`) |
| `0x301` | `misa` | ISA and extensions supported; may read as zero |
| `0x304` | `mie` | Per-source interrupt enable |
| `0x305` | `mtvec` | Trap vector base and mode (direct or vectored) |
| `0x340` | `mscratch` | Scratch register for trap handlers |
| `0x341` | `mepc` | Address of the interrupted or faulting instruction |
| `0x342` | `mcause` | Trap cause; MSB set means interrupt, clear means exception |
| `0x343` | `mtval` | Faulting address or instruction bits |
| `0x344` | `mip` | Per-source interrupt pending |
| `0xF11` | `mvendorid` | Vendor; zero is legal |
| `0xF12` | `marchid` | Architecture; zero is legal |
| `0xF13` | `mimpid` | Implementation; zero is legal |
| `0xF14` | `mhartid` | Hart ID; must read zero on a single-hart core |

Two encoding facts that catch people: CSR address bits `[11:10]` encode
read-only when both are set, so a write to any `0xF..` CSR must raise an illegal
instruction; and `CSRRS`/`CSRRC` with `rs1 = x0` must not write the CSR at all,
which matters because that is how a plain CSR read is encoded.

### Rung 6 — Superscalar and out-of-order
Multiple issue needs dependency checking across the issue group and duplicated
functional units. Out-of-order adds register renaming, reservation stations or an
issue queue, and a reorder buffer to retire in program order. New bug class:
memory-ordering violations between speculatively executed loads and older stores.
Do not attempt this rung without formal verification and a randomized
co-simulation flow already working — simulation alone will not find the bugs.

### Rung 7 — Multicore and coherence
Multiple harts, atomic instructions (the A extension: LR/SC and AMOs), a cache
coherence protocol (MSI/MESI), and the RISC-V memory consistency model (RVWMO).
New bug class: races that appear once in a billion cycles and depend on relative
timing. This is a research-scale effort; the right first move is to integrate a
proven core.

### Bus protocols, at any rung
A simple `valid`/`ready` handshake is sufficient for a single-master core and is
what the `mem_ready` hook above already anticipates. **Wishbone B4** is the
lightest standard option and the common choice in the open-source ASIC world.
**AXI4-Lite** is the right choice when integrating third-party IP; full AXI4 with
bursts and out-of-order IDs is a substantial verification project in its own
right and is not worth it for a core that issues one word at a time.
