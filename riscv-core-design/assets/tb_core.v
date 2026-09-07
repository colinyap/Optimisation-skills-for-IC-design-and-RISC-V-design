//==========================================================================
// tb_core.v
//
// Program-level testbench. Three capabilities beyond a unit testbench:
//   - loads a $readmemh program image, selectable at runtime with +hex=
//   - emits a one-line-per-retired-instruction trace, in exactly the format
//     scripts/rv_model.py emits, so the two can be diffed
//   - terminates on an MMIO write instead of a fixed cycle count
//
//   iverilog -g2001 -o tb.vvp -s tb_core \
//            rv32_multicycle.v rv32_soc_sim.v tb_core.v
//   vvp tb.vvp +hex=prog.hex +trace
//
// Diff against the model:
//   python3 ../scripts/rv_model.py --trace prog.hex > model.trace
//   vvp tb.vvp +hex=prog.hex +trace | grep -E '^[0-9a-f]{8} ' > rtl.trace
//   diff model.trace rtl.trace | head
//==========================================================================

`timescale 1ns/1ps

module tb_core;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire        retire_valid;
    wire [31:0] retire_pc, retire_instr, retire_rd_val;
    wire [4:0]  retire_rd;
    wire        trap_illegal, trap_misaligned;
    wire        mmio_we;
    wire [31:0] mmio_addr, mmio_wdata;

    rv32_soc_sim dut (
        .clk(clk), .rst_n(rst_n),
        .retire_valid(retire_valid), .retire_pc(retire_pc),
        .retire_instr(retire_instr), .retire_rd(retire_rd),
        .retire_rd_val(retire_rd_val),
        .trap_illegal(trap_illegal), .trap_misaligned(trap_misaligned),
        .mmio_we(mmio_we), .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata)
    );

    reg [1023:0] hexfile;
    reg          do_trace;
    integer      i;
    integer      instr_count = 0;
    integer      cycle_count = 0;
    integer      max_cycles;

    // Instruction coverage: one bin per opcode[6:2]. Printing this after a
    // run is the fastest way to discover which instructions the suite never
    // actually exercises.
    integer icov [0:31];

    initial begin
        for (i = 0; i < 32; i = i + 1) icov[i] = 0;

        if (!$value$plusargs("hex=%s", hexfile)) hexfile = "prog.hex";
        if (!$value$plusargs("maxcycles=%d", max_cycles)) max_cycles = 200000;
        do_trace = $test$plusargs("trace");

        // Zero the memories and the register file so no X propagates. The RTL
        // deliberately leaves the datapath registers unreset (see
        // microarchitecture.md); giving them a known state is the testbench's
        // job, not the silicon's.
        for (i = 0; i < 4096; i = i + 1) begin
            dut.imem[i] = 32'h0000_0000;
            dut.dmem[i] = 32'h0000_0000;
        end
        for (i = 1; i < 32; i = i + 1) dut.cpu.u_rf.regs[i] = 32'h0000_0000;
        dut.cpu.ir    = 32'h0;
        dut.cpu.rs1_q = 32'h0;
        dut.cpu.rs2_q = 32'h0;
        dut.cpu.alu_q = 32'h0;

        $readmemh(hexfile, dut.imem);

        if ($test$plusargs("dumpvcd")) begin
            $dumpfile("tb_core.vcd");
            $dumpvars(0, tb_core);
        end

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---- retire trace, byte-identical to the golden model's format ---------
    always @(posedge clk) begin
        if (rst_n && retire_valid) begin
            instr_count = instr_count + 1;
            icov[retire_instr[6:2]] = icov[retire_instr[6:2]] + 1;
            if (do_trace)
                $display("%08h %08h x%0d=%08h",
                         retire_pc, retire_instr, retire_rd, retire_rd_val);
        end
    end

    // ---- traps -------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && trap_illegal) begin
            $display("TRAP: illegal instruction %08h at pc=%08h",
                     retire_instr, retire_pc);
            finish_run(1'b0);
        end
        if (rst_n && trap_misaligned)
            $display("WARN [%0t]: misaligned access at pc=%08h", $time, retire_pc);
    end

    // ---- MMIO: termination and character output ------------------------------
    // The terminating store is seen in EXECUTE, one cycle before it retires.
    // Finishing immediately would drop that instruction from the trace and
    // produce a spurious one-line diff against the golden model, which traces
    // the store and then halts. Latch the request and finish one cycle later.
    reg finish_pending = 1'b0;
    reg finish_passed  = 1'b0;

    always @(posedge clk) begin
        if (rst_n && mmio_we) begin
            case (mmio_addr[11:0])
                12'h000: begin
                    finish_pending <= 1'b1;
                    finish_passed  <= (mmio_wdata == 32'd1);
                end
                12'h004: $write("%c", mmio_wdata[7:0]);
                default: ;
            endcase
        end
        if (rst_n && finish_pending && retire_valid)
            finish_run(finish_passed);
    end

    // ---- watchdog -------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count = cycle_count + 1;
            if (cycle_count > max_cycles) begin
                $display("FAIL: timeout after %0d cycles at pc=%08h",
                         cycle_count, dut.cpu.pc);
                finish_run(1'b0);
            end
        end
    end

    task finish_run;
        input passed;
        integer c;
        begin
            $display("---- %0d instructions, %0d cycles, CPI %0d.%02d ----",
                     instr_count, cycle_count,
                     (instr_count > 0) ? cycle_count / instr_count : 0,
                     (instr_count > 0) ? ((cycle_count * 100) / instr_count) % 100 : 0);
            if ($test$plusargs("cov")) begin
                $display("---- instruction coverage by opcode[6:2] ----");
                for (c = 0; c < 32; c = c + 1)
                    if (icov[c] != 0) $display("  opc[6:2]=%02d : %0d", c, icov[c]);
            end
            $display("RESULT: %0s", passed ? "PASS" : "FAIL");
            $finish;
        end
    endtask
endmodule
