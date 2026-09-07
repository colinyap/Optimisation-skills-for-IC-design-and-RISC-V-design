//==========================================================================
// tb_lsu.v
//
// Load/store unit testbench. Demonstrates the *matrix loop* pattern: instead
// of hand-writing cases, iterate the parameter space (size x byte offset x
// signedness) and let the loop generate the cases. Six lines of loop cover
// what would be forty lines of hand-written stimulus, and it keeps finding
// things when you extend the DUT.
//
//   iverilog -g2001 -o tb.vvp -s tb_lsu rv32_multicycle.v tb_lsu.v && vvp tb.vvp
//==========================================================================

`timescale 1ns/1ps

module tb_lsu;

    integer errors = 0;
    integer checks = 0;

    reg  [1:0]  addr_lo;
    reg  [2:0]  funct3;
    reg  [31:0] store_data;
    reg  [31:0] mem_rdata;
    wire [31:0] load_data;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire        misaligned;

    rv32_lsu dut (
        .addr_lo(addr_lo), .funct3(funct3), .store_data(store_data),
        .mem_rdata(mem_rdata), .load_data(load_data),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .misaligned(misaligned)
    );

    localparam [2:0] F_LB = 3'b000, F_LH = 3'b001, F_LW = 3'b010,
                     F_LBU = 3'b100, F_LHU = 3'b101;
    localparam [2:0] F_SB = 3'b000, F_SH = 3'b001, F_SW = 3'b010;

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

    // Golden load model, written from the spec rather than from the DUT.
    function [31:0] load_golden;
        input [31:0] word;
        input [1:0]  off;
        input [2:0]  f3;
        reg [7:0]  bs;
        reg [15:0] hs;
        begin
            case (off)
                2'b00  : bs = word[7:0];
                2'b01  : bs = word[15:8];
                2'b10  : bs = word[23:16];
                default: bs = word[31:24];
            endcase
            hs = off[1] ? word[31:16] : word[15:0];
            case (f3)
                F_LB   : load_golden = {{24{bs[7]}},  bs};
                F_LH   : load_golden = {{16{hs[15]}}, hs};
                F_LW   : load_golden = word;
                F_LBU  : load_golden = {24'b0, bs};
                F_LHU  : load_golden = {16'b0, hs};
                default: load_golden = word;
            endcase
        end
    endfunction

    integer i, off, sz;
    reg [31:0] patt [0:3];
    reg [2:0]  ltype [0:4];
    reg [31:0] exp_wdata;
    reg [3:0]  exp_wstrb;

    initial begin
        #100000;
        $display("FAIL: timeout"); $display("RESULT: FAIL"); $finish;
    end

    initial begin
        // Patterns chosen so every byte lane is distinguishable and the high
        // bit of each field is set somewhere -- otherwise sign extension is
        // never exercised and LB/LBU look identical.
        patt[0] = 32'h8090_A0B0;
        patt[1] = 32'h0123_4567;
        patt[2] = 32'hFFFF_FFFF;
        patt[3] = 32'h7F80_017F;

        ltype[0] = F_LB;  ltype[1] = F_LH;  ltype[2] = F_LW;
        ltype[3] = F_LBU; ltype[4] = F_LHU;

        //---------------------------------------------------------------
        // LOADS: pattern x offset x load type, skipping illegal alignments
        //---------------------------------------------------------------
        for (i = 0; i < 4; i = i + 1)
          for (off = 0; off < 4; off = off + 1)
            for (sz = 0; sz < 5; sz = sz + 1) begin
                mem_rdata = patt[i];
                addr_lo   = off[1:0];
                funct3    = ltype[sz];
                store_data = 32'b0;
                #1;
                if (!misaligned)
                    check("load matrix", load_data,
                          load_golden(patt[i], off[1:0], ltype[sz]));
            end

        //---------------------------------------------------------------
        // STORES: check both the replicated data and the byte strobes.
        // The strobes are the half people get wrong -- unshifted store data
        // passes every offset-0 test and fails everywhere else.
        //---------------------------------------------------------------
        for (off = 0; off < 4; off = off + 1) begin
            store_data = 32'hAABB_CCDD;
            addr_lo    = off[1:0];

            funct3 = F_SB; #1;
            check("SB wdata replicated", mem_wdata, 32'hDDDD_DDDD);
            check("SB wstrb", {28'b0, mem_wstrb}, {28'b0, 4'b0001 << off[1:0]});

            funct3 = F_SH; #1;
            if (!misaligned) begin
                check("SH wdata replicated", mem_wdata, 32'hCCDD_CCDD);
                exp_wstrb = off[1] ? 4'b1100 : 4'b0011;
                check("SH wstrb", {28'b0, mem_wstrb}, {28'b0, exp_wstrb});
            end

            funct3 = F_SW; #1;
            if (!misaligned) begin
                check("SW wdata", mem_wdata, 32'hAABB_CCDD);
                check("SW wstrb", {28'b0, mem_wstrb}, {28'b0, 4'b1111});
            end
        end

        //---------------------------------------------------------------
        // MISALIGNMENT: assert for exactly the illegal combinations
        //---------------------------------------------------------------
        for (off = 0; off < 4; off = off + 1) begin
            addr_lo = off[1:0];

            funct3 = F_LB; #1;
            check("LB never misaligned", {31'b0, misaligned}, 32'd0);

            funct3 = F_LH; #1;
            check("LH misaligned iff addr[0]",
                  {31'b0, misaligned}, {31'b0, off[0]});

            funct3 = F_LW; #1;
            check("LW misaligned iff addr[1:0]!=0",
                  {31'b0, misaligned}, {31'b0, |off[1:0]});
        end

        //---------------------------------------------------------------
        // Named spot checks: the specific values a reviewer will ask about
        //---------------------------------------------------------------
        mem_rdata = 32'h0000_00FF; addr_lo = 2'b00;
        funct3 = F_LB;  #1; check("LB  0xFF -> sign extended", load_data, 32'hFFFF_FFFF);
        funct3 = F_LBU; #1; check("LBU 0xFF -> zero extended", load_data, 32'h0000_00FF);

        mem_rdata = 32'h8000_0000; addr_lo = 2'b10;
        funct3 = F_LH;  #1; check("LH  high half signed",  load_data, 32'hFFFF_8000);
        funct3 = F_LHU; #1; check("LHU high half unsigned", load_data, 32'h0000_8000);

        $display("---- tb_lsu: %0d checks, %0d errors ----", checks, errors);
        $display("RESULT: %0s", (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
