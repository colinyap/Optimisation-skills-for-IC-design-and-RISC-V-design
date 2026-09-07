//==========================================================================
// tb_unit_template.v
//
// The generic self-checking module testbench pattern, worked end-to-end on
// the ALU. Copy this file, swap the DUT and the golden function, keep the
// five structural parts:
//
//   1. clock / reset
//   2. a check() task that counts errors and prints locating context
//   3. stimulus: directed boundaries first, then loops, then random
//   4. a timeout watchdog so a hang fails instead of hanging
//   5. a RESULT: PASS / RESULT: FAIL summary line
//
// Strict Verilog-2001: no assert, no $error, no $fatal, no string type.
//
//   iverilog -g2001 -o tb.vvp -s tb_unit_template \
//            rv32_multicycle.v tb_unit_template.v && vvp tb.vvp
//==========================================================================

`timescale 1ns/1ps

module tb_unit_template;

    // ---- 1. clock and reset ---------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;                     // 100 MHz

    integer errors = 0;
    integer checks = 0;

    // ---- DUT --------------------------------------------------------------
    reg  [31:0] a, b;
    reg  [3:0]  op;
    wire [31:0] y;

    rv32_alu dut (.a(a), .b(b), .op(op), .y(y));

    localparam [3:0] ALU_ADD = 4'd0, ALU_SUB  = 4'd1, ALU_SLL = 4'd2,
                     ALU_SLT = 4'd3, ALU_SLTU = 4'd4, ALU_XOR = 4'd5,
                     ALU_SRL = 4'd6, ALU_SRA  = 4'd7, ALU_OR  = 4'd8,
                     ALU_AND = 4'd9;

    // ---- 2. the self-checking primitive -----------------------------------
    // Use !== rather than !=. With !=, an all-x output compares "unknown",
    // the if is false, and the check silently PASSES. That single character
    // is the difference between catching uninitialised-register bugs and
    // shipping them.
    task check;
        input [255:0] name;
        input [31:0]  got;
        input [31:0]  expected;
        begin
            checks = checks + 1;
            if (got !== expected) begin
                errors = errors + 1;
                $display("FAIL [%0t] %0s: got %08h expected %08h",
                         $time, name, got, expected);
            end
        end
    endtask

    // Golden model, written independently of the DUT. If you find yourself
    // copying the DUT's expression here, the test proves nothing.
    function [31:0] alu_golden;
        input [31:0] ga, gb;
        input [3:0]  gop;
        begin
            case (gop)
                ALU_ADD : alu_golden = ga + gb;
                ALU_SUB : alu_golden = ga - gb;
                ALU_SLL : alu_golden = ga << gb[4:0];
                ALU_SLT : alu_golden = ($signed(ga) <  $signed(gb)) ? 32'd1 : 32'd0;
                ALU_SLTU: alu_golden = (ga < gb) ? 32'd1 : 32'd0;
                ALU_XOR : alu_golden = ga ^ gb;
                ALU_SRL : alu_golden = ga >> gb[4:0];
                ALU_SRA : alu_golden = $signed(ga) >>> gb[4:0];
                ALU_OR  : alu_golden = ga | gb;
                ALU_AND : alu_golden = ga & gb;
                default : alu_golden = 32'b0;
            endcase
        end
    endfunction

    task do_op;                                // apply and self-check
        input [31:0] ta, tb;
        input [3:0]  top;
        input [255:0] label;
        begin
            a = ta; b = tb; op = top;
            #1;                                // let combinational logic settle
            check(label, y, alu_golden(ta, tb, top));
        end
    endtask

    // ---- 4. watchdog --------------------------------------------------------
    initial begin
        #200000;
        $display("FAIL: timeout at %0t", $time);
        $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        $dumpfile("tb_unit_template.vcd");
        $dumpvars(0, tb_unit_template);
    end

    // ---- 3. stimulus ---------------------------------------------------------
    integer i, j, k;
    reg [31:0] bvals [0:5];                    // boundary values

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        bvals[0] = 32'h0000_0000;
        bvals[1] = 32'h0000_0001;
        bvals[2] = 32'h7FFF_FFFF;
        bvals[3] = 32'h8000_0000;
        bvals[4] = 32'hFFFF_FFFF;
        bvals[5] = 32'h5A5A_5A5A;

        // -- directed cases that encode specific architectural rules ---------
        // SLT vs SLTU must DISAGREE here. If they agree, one of them is wrong.
        do_op(32'h8000_0000, 32'h0000_0001, ALU_SLT,  "SLT  signed neg<pos");
        do_op(32'h8000_0000, 32'h0000_0001, ALU_SLTU, "SLTU unsigned big>small");
        if (dut.y === 32'd1) begin
            // sanity: SLTU of 0x80000000 < 1 must be 0
            $display("NOTE: SLTU polarity check reached");
        end

        // Shift by 32 is a shift by 0 in RV32 -- only shamt[4:0] is used.
        do_op(32'h0000_0001, 32'd32, ALU_SLL, "SLL shamt=32 wraps to 0");
        do_op(32'h8000_0000, 32'd1,  ALU_SRA, "SRA sign fill");
        do_op(32'h8000_0000, 32'd1,  ALU_SRL, "SRL zero fill");

        // -- boundary cross product ------------------------------------------
        for (i = 0; i < 6; i = i + 1)
            for (j = 0; j < 6; j = j + 1)
                for (k = 0; k < 10; k = k + 1)
                    do_op(bvals[i], bvals[j], k[3:0], "boundary cross");

        // -- shift amounts, exhaustively -------------------------------------
        for (i = 0; i < 33; i = i + 1) begin
            do_op(32'hDEAD_BEEF, i[31:0], ALU_SLL, "SLL sweep");
            do_op(32'hDEAD_BEEF, i[31:0], ALU_SRL, "SRL sweep");
            do_op(32'hDEAD_BEEF, i[31:0], ALU_SRA, "SRA sweep");
        end

        // -- random ------------------------------------------------------------
        // $urandom_range is SystemVerilog. $random is signed, so mask it.
        for (i = 0; i < 5000; i = i + 1)
            do_op($random & 32'hFFFF_FFFF, $random & 32'hFFFF_FFFF,
                  ($random & 32'h7FFF_FFFF) % 10, "random");

        // ---- 5. summary -------------------------------------------------------
        $display("---- tb_unit_template: %0d checks, %0d errors ----", checks, errors);
        $display("RESULT: %0s", (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
