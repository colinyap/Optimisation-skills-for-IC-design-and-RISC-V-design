//==========================================================================
// rv32_soc_sim.v
//
// Simulation-only SoC wrapper: core + instruction memory + data memory +
// MMIO, with the address decoder.
//
//   *** DO NOT PUT THIS FILE IN A SYNTHESIS FILE LIST. ***
//
// The memory arrays here are behavioural. Synthesized as written they become
// hundreds of thousands of flip-flops -- see "The memory trap" in
// references/optimization.md. Keeping the simulation memories in their own
// file is what makes that mistake structurally impossible rather than merely
// unlikely.
//
// Memory map (this skill's defaults -- replace with the project's):
//   0x0000_0000 .. 0x0000_FFFF   instruction memory  (also readable as data)
//   0x1000_0000 .. 0x1000_FFFF   data memory
//   0x2000_0000                  result register: write 1 = PASS, else FAIL
//   0x2000_0004                  character output
//   0x2000_0008                  cycle counter (read-only)
//==========================================================================

`default_nettype none

module rv32_soc_sim #(
    parameter IMEM_WORDS = 4096,          // 16 KiB
    parameter DMEM_WORDS = 4096,
    parameter [31:0] RESET_VECTOR = 32'h0000_0000,
    parameter [31:0] CRC_POLY     = 32'hEDB88320
)(
    input  wire        clk,
    input  wire        rst_n,
    // exposed for the testbench
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instr,
    output wire [4:0]  retire_rd,
    output wire [31:0] retire_rd_val,
    output wire        trap_illegal,
    output wire        trap_misaligned,
    output wire        mmio_we,
    output wire [31:0] mmio_addr,
    output wire [31:0] mmio_wdata
);
    wire [31:0] bus_addr, bus_wdata;
    wire [3:0]  bus_wstrb;
    wire        bus_req;
    reg  [31:0] bus_rdata;
    wire        bus_ready = 1'b1;          // all targets are single-cycle here

    rv32_core #(.RESET_VECTOR(RESET_VECTOR), .CRC_POLY(CRC_POLY)) cpu (
        .clk(clk), .rst_n(rst_n),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_wstrb(bus_wstrb),
        .bus_req(bus_req), .bus_rdata(bus_rdata), .bus_ready(bus_ready),
        .retire_valid(retire_valid), .retire_pc(retire_pc),
        .retire_instr(retire_instr), .retire_rd(retire_rd),
        .retire_rd_val(retire_rd_val),
        .trap_illegal(trap_illegal), .trap_misaligned(trap_misaligned)
    );

    // ---- address decode: compare only the distinguishing high bits --------
    wire sel_imem = (bus_addr[31:16] == 16'h0000);
    wire sel_dmem = (bus_addr[31:16] == 16'h1000);
    wire sel_mmio = (bus_addr[31:12] == 20'h20000);
    wire sel_none = ~(sel_imem | sel_dmem | sel_mmio);

    // ---- memories ---------------------------------------------------------
    reg [31:0] imem [0:IMEM_WORDS-1];
    reg [31:0] dmem [0:DMEM_WORDS-1];

    wire [31:0] imem_word_addr = bus_addr[31:2] & (IMEM_WORDS-1);
    wire [31:0] dmem_word_addr = bus_addr[31:2] & (DMEM_WORDS-1);

    reg [31:0] imem_rdata, dmem_rdata, mmio_rdata;
    reg [31:0] cycle_count;

    // NOTE: with synchronous-read memory the SELECT must be registered along
    // with the address, because read data arrives a cycle after the select was
    // evaluated. Using the live select to mux registered data is a classic
    // off-by-one that shows up only when consecutive accesses hit different
    // regions.
    reg sel_imem_q, sel_dmem_q, sel_mmio_q, sel_none_q;

    integer k;
    always @(posedge clk) begin
        sel_imem_q <= sel_imem & bus_req;
        sel_dmem_q <= sel_dmem & bus_req;
        sel_mmio_q <= sel_mmio & bus_req;
        sel_none_q <= sel_none & bus_req;

        if (bus_req && sel_imem) begin
            imem_rdata <= imem[imem_word_addr];
            for (k = 0; k < 4; k = k + 1)
                if (bus_wstrb[k]) imem[imem_word_addr][k*8 +: 8] <= bus_wdata[k*8 +: 8];
        end
        if (bus_req && sel_dmem) begin
            dmem_rdata <= dmem[dmem_word_addr];
            for (k = 0; k < 4; k = k + 1)
                if (bus_wstrb[k]) dmem[dmem_word_addr][k*8 +: 8] <= bus_wdata[k*8 +: 8];
        end
    end

    // ---- MMIO --------------------------------------------------------------
    assign mmio_we    = bus_req & sel_mmio & (|bus_wstrb);
    assign mmio_addr  = bus_addr;
    assign mmio_wdata = bus_wdata;

    always @(posedge clk) begin
        if (!rst_n) cycle_count <= 32'd0;
        else        cycle_count <= cycle_count + 32'd1;
        mmio_rdata <= (bus_addr[11:0] == 12'h008) ? cycle_count : 32'd0;
    end

    // ---- read data mux: registered selects, defined value on no match -------
    always @(*) begin
        if      (sel_imem_q) bus_rdata = imem_rdata;
        else if (sel_dmem_q) bus_rdata = dmem_rdata;
        else if (sel_mmio_q) bus_rdata = mmio_rdata;
        else                 bus_rdata = 32'hDEAD_BEEF;   // poison, never x
    end
endmodule

`default_nettype wire
