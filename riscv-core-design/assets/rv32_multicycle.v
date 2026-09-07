//==========================================================================
// rv32_multicycle.v
//
// A complete, working four-state multicycle RV32I + M(multiply) core with a
// custom CRC extension, in strict Verilog-2001.
//
//   PURPOSE: a verified reference to read, adapt, and check your own design
//   against. It is NOT a drop-in submission. The custom-extension encoding
//   and the memory map here are this skill's defaults -- replace them with
//   the ones your project specifies before using any of it.
//
//   States: FETCH -> DECODE -> EXECUTE -> WRITEBACK, uniform 4 cycles.
//   Memory: synchronous read (Mapping B). Address is registered by the
//           memory at the end of the cycle that drives it; data is valid
//           during the following cycle. This is what a real SRAM does.
//
//   Verification outputs (retire_*) are for the testbench only and cost
//   nothing in synthesis if left unconnected.
//
//   Modules in this file:
//     rv32_regfile  rv32_immgen  rv32_alu     rv32_branch
//     rv32_mul      crc32_byte   rv32_crc     rv32_lsu
//     rv32_decode   rv32_core
//==========================================================================

`default_nettype none

//--------------------------------------------------------------------------
// Register file: 32 x 32, 2 read / 1 write. x0 has no storage.
//--------------------------------------------------------------------------
module rv32_regfile (
    input  wire        clk,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data,
    input  wire        rd_we
);
    // Index 1..31 only: x0 needs no flops, which makes the ISA rule structural.
    reg [31:0] regs [1:31];

    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 : regs[rs2_addr];

    always @(posedge clk) begin
        if (rd_we && (rd_addr != 5'd0))
            regs[rd_addr] <= rd_data;
    end
endmodule

//--------------------------------------------------------------------------
// Immediate generator. Selector values match rv32_decode.
//--------------------------------------------------------------------------
module rv32_immgen (
    input  wire [31:0] instr,
    input  wire [2:0]  imm_sel,
    output reg  [31:0] imm
);
    localparam [2:0] IMM_I = 3'd0, IMM_S = 3'd1, IMM_B = 3'd2,
                     IMM_U = 3'd3, IMM_J = 3'd4;

    always @(*) begin
        case (imm_sel)
            IMM_I:   imm = {{20{instr[31]}}, instr[31:20]};
            IMM_S:   imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            IMM_B:   imm = {{19{instr[31]}}, instr[31], instr[7],
                            instr[30:25], instr[11:8], 1'b0};
            IMM_U:   imm = {instr[31:12], 12'b0};
            IMM_J:   imm = {{11{instr[31]}}, instr[31], instr[19:12],
                            instr[20], instr[30:21], 1'b0};
            default: imm = 32'b0;
        endcase
    end
endmodule

//--------------------------------------------------------------------------
// ALU. Shift amount is masked to 5 bits, which is the RV32 rule.
//--------------------------------------------------------------------------
module rv32_alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] y
);
    localparam [3:0] ALU_ADD = 4'd0, ALU_SUB  = 4'd1, ALU_SLL = 4'd2,
                     ALU_SLT = 4'd3, ALU_SLTU = 4'd4, ALU_XOR = 4'd5,
                     ALU_SRL = 4'd6, ALU_SRA  = 4'd7, ALU_OR  = 4'd8,
                     ALU_AND = 4'd9;

    wire [4:0] shamt = b[4:0];              // RV32: only the low 5 bits

    always @(*) begin
        case (op)
            ALU_ADD : y = a + b;
            ALU_SUB : y = a - b;
            ALU_SLL : y = a << shamt;
            ALU_SLT : y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU: y = (a < b)                   ? 32'd1 : 32'd0;
            ALU_XOR : y = a ^ b;
            ALU_SRL : y = a >> shamt;
            ALU_SRA : y = $signed(a) >>> shamt;     // $signed on the OPERAND
            ALU_OR  : y = a | b;
            ALU_AND : y = a & b;
            default : y = 32'b0;
        endcase
    end
endmodule

//--------------------------------------------------------------------------
// Branch comparator. Dedicated, not sharing the ALU subtract: the ALU is
// busy computing addresses and its output arrives late.
//--------------------------------------------------------------------------
module rv32_branch (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [2:0]  funct3,
    output reg         taken
);
    always @(*) begin
        case (funct3)
            3'b000: taken = (a == b);                        // BEQ
            3'b001: taken = (a != b);                        // BNE
            3'b100: taken = ($signed(a) <  $signed(b));      // BLT
            3'b101: taken = ($signed(a) >= $signed(b));      // BGE
            3'b110: taken = (a <  b);                        // BLTU
            3'b111: taken = (a >= b);                        // BGEU
            default: taken = 1'b0;
        endcase
    end
endmodule

//--------------------------------------------------------------------------
// Multiplier: MUL, MULH, MULHSU, MULHU.
// ONE multiplier, with the operand extension muxed. Instantiating three
// separate multipliers is the common mistake and roughly triples the area.
//--------------------------------------------------------------------------
module rv32_mul (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [2:0]  funct3,
    output reg  [31:0] y
);
    // MULH treats both signed; MULHSU treats rs1 signed and rs2 unsigned.
    wire a_signed = (funct3 == 3'b001) || (funct3 == 3'b010);
    wire b_signed = (funct3 == 3'b001);

    wire signed [32:0] a_ext = {a_signed & a[31], a};
    wire signed [32:0] b_ext = {b_signed & b[31], b};
    wire signed [65:0] product = a_ext * b_ext;

    always @(*) begin
        case (funct3)
            3'b000 : y = product[31:0];      // MUL: low half is signedness-agnostic
            3'b001 : y = product[63:32];     // MULH
            3'b010 : y = product[63:32];     // MULHSU
            3'b011 : y = product[63:32];     // MULHU
            default: y = 32'b0;
        endcase
    end
endmodule

//--------------------------------------------------------------------------
// CRC: one byte folded per block, fully combinational (static unroll).
// Reflected CRC-32. Change POLY only -- reflection is structural.
//--------------------------------------------------------------------------
module crc32_byte #(
    parameter [31:0] POLY = 32'hEDB88320
)(
    input  wire [31:0] crc_in,
    input  wire [7:0]  data,
    output reg  [31:0] crc_out
);
    integer i;
    reg [31:0] c;
    always @(*) begin
        c = crc_in ^ {24'b0, data};
        for (i = 0; i < 8; i = i + 1)
            c = (c >> 1) ^ (POLY & {32{c[0]}});
        crc_out = c;
    end
endmodule

//--------------------------------------------------------------------------
// CRC functional unit: CRC.B / CRC.H / CRC.W, little-endian byte order.
// rs1 = running CRC state, rs2 = data, rd = updated state.
//--------------------------------------------------------------------------
module rv32_crc #(
    parameter [31:0] POLY = 32'hEDB88320
)(
    input  wire [31:0] crc_in,
    input  wire [31:0] data,
    input  wire [2:0]  funct3,
    output reg  [31:0] y
);
    wire [31:0] s0, s1, s2, s3;
    crc32_byte #(.POLY(POLY)) b0 (.crc_in(crc_in), .data(data[ 7: 0]), .crc_out(s0));
    crc32_byte #(.POLY(POLY)) b1 (.crc_in(s0),     .data(data[15: 8]), .crc_out(s1));
    crc32_byte #(.POLY(POLY)) b2 (.crc_in(s1),     .data(data[23:16]), .crc_out(s2));
    crc32_byte #(.POLY(POLY)) b3 (.crc_in(s2),     .data(data[31:24]), .crc_out(s3));

    always @(*) begin
        case (funct3)
            3'b000 : y = s0;      // CRC.B
            3'b001 : y = s1;      // CRC.H
            3'b010 : y = s3;      // CRC.W
            default: y = crc_in;  // reserved encodings pass state through
        endcase
    end
endmodule

//--------------------------------------------------------------------------
// Load/store unit: byte-lane select, sign/zero extension, store replication
// and byte strobes, misalignment detection.
//--------------------------------------------------------------------------
module rv32_lsu (
    input  wire [1:0]  addr_lo,      // addr[1:0]
    input  wire [2:0]  funct3,
    input  wire [31:0] store_data,   // rs2
    input  wire [31:0] mem_rdata,
    output reg  [31:0] load_data,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wstrb,
    output wire        misaligned
);
    reg [7:0]  byte_sel;
    reg [15:0] half_sel;

    always @(*) begin
        case (addr_lo)
            2'b00  : byte_sel = mem_rdata[7:0];
            2'b01  : byte_sel = mem_rdata[15:8];
            2'b10  : byte_sel = mem_rdata[23:16];
            default: byte_sel = mem_rdata[31:24];
        endcase
        half_sel = addr_lo[1] ? mem_rdata[31:16] : mem_rdata[15:0];

        case (funct3)
            3'b000 : load_data = {{24{byte_sel[7]}},  byte_sel};   // LB
            3'b001 : load_data = {{16{half_sel[15]}}, half_sel};   // LH
            3'b010 : load_data = mem_rdata;                        // LW
            3'b100 : load_data = {24'b0, byte_sel};                // LBU
            3'b101 : load_data = {16'b0, half_sel};                // LHU
            default: load_data = mem_rdata;
        endcase
    end

    // Store: replicate across lanes so the memory only has to mask, never shift.
    always @(*) begin
        case (funct3)
            3'b000 : begin                                   // SB
                mem_wdata = {4{store_data[7:0]}};
                mem_wstrb = 4'b0001 << addr_lo;
            end
            3'b001 : begin                                   // SH
                mem_wdata = {2{store_data[15:0]}};
                mem_wstrb = addr_lo[1] ? 4'b1100 : 4'b0011;
            end
            3'b010 : begin                                   // SW
                mem_wdata = store_data;
                mem_wstrb = 4'b1111;
            end
            default: begin
                mem_wdata = store_data;
                mem_wstrb = 4'b0000;                         // unknown size: no write
            end
        endcase
    end

    assign misaligned = ((funct3[1:0] == 2'b01) && addr_lo[0]) ||
                        ((funct3[1:0] == 2'b10) && (|addr_lo));
endmodule

//--------------------------------------------------------------------------
// Decoder: purely combinational, one instance, input muxed between the live
// bus data (in DECODE) and the captured IR (in EXECUTE/WRITEBACK).
//--------------------------------------------------------------------------
module rv32_decode (
    input  wire [31:0] instr,
    output wire [4:0]  rs1_addr,
    output wire [4:0]  rs2_addr,
    output wire [4:0]  rd_addr,
    output wire [2:0]  funct3,
    output reg  [2:0]  imm_sel,
    output reg  [3:0]  alu_op,
    output reg         alu_a_pc,     // 0 = rs1, 1 = pc
    output reg         alu_b_imm,    // 0 = rs2, 1 = imm
    output reg  [2:0]  wb_sel,
    output reg         reg_write,
    output reg         mem_read,
    output reg         mem_write,
    output reg         is_branch,
    output reg         is_jal,
    output reg         is_jalr,
    output reg         is_mul,
    output reg         is_crc,
    output reg         illegal
);
    localparam [6:0] OP_LUI = 7'b0110111, OP_AUIPC = 7'b0010111,
                     OP_JAL = 7'b1101111, OP_JALR  = 7'b1100111,
                     OP_BR  = 7'b1100011, OP_LOAD  = 7'b0000011,
                     OP_ST  = 7'b0100011, OP_IMM   = 7'b0010011,
                     OP_REG = 7'b0110011, OP_FENCE = 7'b0001111,
                     OP_SYS = 7'b1110011, OP_CUST0 = 7'b0001011;

    localparam [2:0] IMM_I = 3'd0, IMM_S = 3'd1, IMM_B = 3'd2,
                     IMM_U = 3'd3, IMM_J = 3'd4;
    localparam [2:0] WB_ALU = 3'd0, WB_MEM = 3'd1, WB_PC4 = 3'd2,
                     WB_IMM = 3'd3, WB_MUL = 3'd4, WB_CRC = 3'd5;
    localparam [3:0] ALU_ADD = 4'd0, ALU_SUB  = 4'd1, ALU_SLL = 4'd2,
                     ALU_SLT = 4'd3, ALU_SLTU = 4'd4, ALU_XOR = 4'd5,
                     ALU_SRL = 4'd6, ALU_SRA  = 4'd7, ALU_OR  = 4'd8,
                     ALU_AND = 4'd9;

    wire [6:0] opcode = instr[6:0];
    wire [6:0] funct7 = instr[31:25];

    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];
    assign funct3   = instr[14:12];

    // ALU operation from funct3/funct7 for the arithmetic opcodes.
    reg [3:0] arith_op;
    always @(*) begin
        case (funct3)
            3'b000 : arith_op = (opcode == OP_REG && funct7[5]) ? ALU_SUB : ALU_ADD;
            3'b001 : arith_op = ALU_SLL;
            3'b010 : arith_op = ALU_SLT;
            3'b011 : arith_op = ALU_SLTU;
            3'b100 : arith_op = ALU_XOR;
            3'b101 : arith_op = funct7[5] ? ALU_SRA : ALU_SRL;
            3'b110 : arith_op = ALU_OR;
            default: arith_op = ALU_AND;
        endcase
    end

    always @(*) begin
        // Defaults FIRST. Every output assigned on every path -> no latches.
        imm_sel   = IMM_I;
        alu_op    = ALU_ADD;
        alu_a_pc  = 1'b0;
        alu_b_imm = 1'b1;
        wb_sel    = WB_ALU;
        reg_write = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        is_branch = 1'b0;
        is_jal    = 1'b0;
        is_jalr   = 1'b0;
        is_mul    = 1'b0;
        is_crc    = 1'b0;
        illegal   = 1'b0;

        case (opcode)
            OP_LUI: begin
                imm_sel = IMM_U; wb_sel = WB_IMM; reg_write = 1'b1;
            end
            OP_AUIPC: begin
                imm_sel = IMM_U; alu_a_pc = 1'b1; reg_write = 1'b1;
            end
            OP_JAL: begin
                imm_sel = IMM_J; wb_sel = WB_PC4; reg_write = 1'b1; is_jal = 1'b1;
            end
            OP_JALR: begin
                imm_sel = IMM_I; wb_sel = WB_PC4; reg_write = 1'b1; is_jalr = 1'b1;
            end
            OP_BR: begin
                imm_sel = IMM_B; is_branch = 1'b1;
            end
            OP_LOAD: begin
                imm_sel = IMM_I; wb_sel = WB_MEM; reg_write = 1'b1; mem_read = 1'b1;
            end
            OP_ST: begin
                imm_sel = IMM_S; mem_write = 1'b1;
            end
            OP_IMM: begin
                imm_sel = IMM_I; alu_op = arith_op; reg_write = 1'b1;
            end
            OP_REG: begin
                alu_b_imm = 1'b0;
                reg_write = 1'b1;
                if (funct7 == 7'b0000001) begin              // M extension
                    is_mul = 1'b1;
                    wb_sel = WB_MUL;
                    illegal = funct3[2];                     // div/rem not implemented
                end else begin
                    alu_op = arith_op;
                end
            end
            OP_CUST0: begin                                  // custom CRC extension
                alu_b_imm = 1'b0;
                reg_write = 1'b1;
                is_crc    = 1'b1;
                wb_sel    = WB_CRC;
                illegal   = (funct3 > 3'b010);               // only B/H/W defined
            end
            OP_FENCE: ;                                      // no-op in this core
            OP_SYS:   ;                                      // ECALL/EBREAK: halt handled in TB
            default:  illegal = 1'b1;
        endcase
    end
endmodule

//--------------------------------------------------------------------------
// Core: four-state FSM, single shared bus port.
//--------------------------------------------------------------------------
module rv32_core #(
    parameter [31:0] RESET_VECTOR = 32'h0000_0000,
    parameter [31:0] CRC_POLY     = 32'hEDB88320
)(
    input  wire        clk,
    input  wire        rst_n,

    // Single memory port. Address is captured by the target at the clock edge
    // ending the cycle in which bus_req is high; bus_rdata is valid the cycle
    // after that.
    output reg  [31:0] bus_addr,
    output reg  [31:0] bus_wdata,
    output reg  [3:0]  bus_wstrb,
    output reg         bus_req,
    input  wire [31:0] bus_rdata,
    input  wire        bus_ready,

    // Verification-only outputs. Leave unconnected in synthesis.
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instr,
    output wire [4:0]  retire_rd,
    output wire [31:0] retire_rd_val,
    output wire        trap_illegal,
    output wire        trap_misaligned
);
    localparam [1:0] S_FETCH = 2'd0, S_DECODE = 2'd1, S_EXEC = 2'd2, S_WB = 2'd3;
    localparam [2:0] WB_ALU = 3'd0, WB_MEM = 3'd1, WB_PC4 = 3'd2,
                     WB_IMM = 3'd3, WB_MUL = 3'd4, WB_CRC = 3'd5;

    reg  [1:0]  state, next_state;
    reg  [31:0] pc, ir, rs1_q, rs2_q, alu_q;

    // ---- FSM ------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) state <= S_FETCH;
        else        state <= next_state;
    end

    wire ex_done = 1'b1;   // hook: tie to a multi-cycle unit's done signal

    always @(*) begin
        next_state = state;                       // default prevents a latch
        case (state)
            S_FETCH : next_state = bus_ready ? S_DECODE : S_FETCH;
            S_DECODE: next_state = S_EXEC;
            S_EXEC  : next_state = ex_done   ? S_WB    : S_EXEC;
            S_WB    : next_state = bus_ready ? S_FETCH : S_WB;
            default : next_state = S_FETCH;
        endcase
    end

    // ---- decode ---------------------------------------------------------
    // In DECODE the instruction is live on the bus; afterwards it is in IR.
    wire [31:0] dec_instr = (state == S_DECODE) ? bus_rdata : ir;

    wire [4:0] rs1_addr, rs2_addr, rd_addr;
    wire [2:0] funct3, imm_sel, wb_sel;
    wire [3:0] alu_op;
    wire alu_a_pc, alu_b_imm, reg_write, mem_read, mem_write;
    wire is_branch, is_jal, is_jalr, is_mul, is_crc, illegal;

    rv32_decode u_dec (
        .instr(dec_instr), .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rd_addr(rd_addr), .funct3(funct3), .imm_sel(imm_sel), .alu_op(alu_op),
        .alu_a_pc(alu_a_pc), .alu_b_imm(alu_b_imm), .wb_sel(wb_sel),
        .reg_write(reg_write), .mem_read(mem_read), .mem_write(mem_write),
        .is_branch(is_branch), .is_jal(is_jal), .is_jalr(is_jalr),
        .is_mul(is_mul), .is_crc(is_crc), .illegal(illegal)
    );

    wire [31:0] imm;
    rv32_immgen u_imm (.instr(dec_instr), .imm_sel(imm_sel), .imm(imm));

    // ---- register file --------------------------------------------------
    wire [31:0] rs1_data, rs2_data;
    reg  [31:0] wb_data;
    wire        rf_we = (state == S_WB) && reg_write && !illegal;

    rv32_regfile u_rf (
        .clk(clk), .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rs1_data(rs1_data), .rs2_data(rs2_data),
        .rd_addr(rd_addr), .rd_data(wb_data), .rd_we(rf_we)
    );

    // ---- functional units ------------------------------------------------
    wire [31:0] alu_a = alu_a_pc  ? pc    : rs1_q;
    wire [31:0] alu_b = alu_b_imm ? imm   : rs2_q;
    wire [31:0] alu_y;
    rv32_alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));

    wire [31:0] mul_y;
    rv32_mul u_mul (.a(rs1_q), .b(rs2_q), .funct3(funct3), .y(mul_y));

    wire [31:0] crc_y;
    rv32_crc #(.POLY(CRC_POLY)) u_crc
        (.crc_in(rs1_q), .data(rs2_q), .funct3(funct3), .y(crc_y));

    wire branch_taken;
    rv32_branch u_br (.a(rs1_q), .b(rs2_q), .funct3(funct3), .taken(branch_taken));

    wire [31:0] load_data, lsu_wdata;
    wire [3:0]  lsu_wstrb;
    wire        lsu_misaligned;
    rv32_lsu u_lsu (
        .addr_lo(alu_q[1:0]), .funct3(funct3), .store_data(rs2_q),
        .mem_rdata(bus_rdata), .load_data(load_data),
        .mem_wdata(lsu_wdata), .mem_wstrb(lsu_wstrb), .misaligned(lsu_misaligned)
    );

    // Store misalignment must be checked against the live address in EXECUTE,
    // where the strobes are driven -- alu_q is not yet updated at that point.
    wire [1:0] ex_addr_lo = alu_y[1:0];
    wire ex_misaligned = ((funct3[1:0] == 2'b01) && ex_addr_lo[0]) ||
                         ((funct3[1:0] == 2'b10) && (|ex_addr_lo));

    // ---- writeback mux (one-hot; keeps the slowest input off a priority chain)
    always @(*) begin
        case (wb_sel)
            WB_ALU : wb_data = alu_q;
            WB_MEM : wb_data = load_data;
            WB_PC4 : wb_data = pc + 32'd4;
            WB_IMM : wb_data = imm;
            WB_MUL : wb_data = mul_y;
            WB_CRC : wb_data = crc_y;
            default: wb_data = alu_q;
        endcase
    end

    // ---- next PC ---------------------------------------------------------
    wire [31:0] pc_plus_4   = pc + 32'd4;
    wire [31:0] pc_plus_imm = pc + imm;
    reg  [31:0] pc_next;
    always @(*) begin
        if (is_jalr)                        pc_next = {alu_q[31:1], 1'b0}; // clear bit 0
        else if (is_jal)                    pc_next = pc_plus_imm;
        else if (is_branch && branch_taken) pc_next = pc_plus_imm;
        else                                pc_next = pc_plus_4;
    end

    // ---- sequential state -------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            pc <= RESET_VECTOR;
            // ir / rs1_q / rs2_q / alu_q deliberately unreset: no functional
            // need, and resetting them inflates the reset tree. The testbench
            // is responsible for a clean initial state (see verification.md).
        end else begin
            case (state)
                S_DECODE: begin
                    ir    <= bus_rdata;
                    rs1_q <= rs1_data;
                    rs2_q <= rs2_data;
                end
                S_EXEC: begin
                    alu_q <= alu_y;
                end
                S_WB: if (bus_ready) begin
                    pc <= pc_next;
                end
                default: ;
            endcase
        end
    end

    // ---- bus arbitration: the FSM state IS the arbiter ---------------------
    always @(*) begin
        bus_addr  = pc;
        bus_wdata = 32'b0;
        bus_wstrb = 4'b0000;      // safe default: never write unless asked
        bus_req   = 1'b0;
        case (state)
            S_FETCH: begin
                bus_addr = pc;
                bus_req  = 1'b1;
            end
            S_EXEC: if (mem_read || mem_write) begin
                bus_addr  = alu_y;                       // rs1 + imm, live this cycle
                bus_wdata = lsu_wdata;
                bus_wstrb = (mem_write && !ex_misaligned) ? lsu_wstrb : 4'b0000;
                bus_req   = 1'b1;
            end
            default: ;
        endcase
    end

    // ---- verification outputs ---------------------------------------------
    assign retire_valid  = (state == S_WB) && bus_ready;
    assign retire_pc     = pc;
    assign retire_instr  = ir;
    assign retire_rd     = rf_we ? rd_addr : 5'd0;
    assign retire_rd_val = rf_we ? wb_data : 32'd0;
    assign trap_illegal  = (state == S_WB) && illegal;
    assign trap_misaligned = ((state == S_WB) && mem_read  && lsu_misaligned) ||
                             ((state == S_EXEC) && mem_write && ex_misaligned);
endmodule

`default_nettype wire
