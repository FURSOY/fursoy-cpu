// RV64I load/store and RV64A atomic instruction decode and naturally-aligned byte-address generation.
module fursoy_s0_lsu_decode (
    input logic insn_valid_i,
    /* verilator lint_off UNUSEDSIGNAL */ // rs1 number is consumed by the surrounding register file.
    input logic [31:0] insn_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [63:0] rs1_i,
    input logic [63:0] rs2_i,
    output logic lsu_valid_o,
    output logic lsu_store_o,
    output logic lsu_lr_o,
    output logic lsu_sc_o,
    output logic lsu_amo_o,
    output logic [4:0] amo_op_o,
    output logic [63:0] address_o,
    output logic [2:0] size_o,       // log2(byte count): 0,1,2,3
    output logic load_unsigned_o,
    output logic [63:0] store_data_o,
    output logic misaligned_o
);
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [4:0] funct5;
    logic [63:0] immediate;
    logic [2:0] size;
    logic legal;
    logic is_lr, is_sc, is_amo;

    assign opcode = insn_i[6:0];
    assign funct3 = insn_i[14:12];
    assign funct5 = insn_i[31:27];

    always_comb begin
        legal = 1'b0;
        size = 3'd0;
        load_unsigned_o = 1'b0;
        immediate = '0;
        is_lr = 1'b0;
        is_sc = 1'b0;
        is_amo = 1'b0;

        if (opcode == 7'b0000011) begin // LOAD
            immediate = {{52{insn_i[31]}}, insn_i[31:20]};
            unique case(funct3)
                3'b000: legal = 1'b1;                         // LB
                3'b001: begin legal = 1'b1; size = 3'd1; end  // LH
                3'b010: begin legal = 1'b1; size = 3'd2; end  // LW
                3'b011: begin legal = 1'b1; size = 3'd3; end  // LD
                3'b100: begin legal = 1'b1; load_unsigned_o = 1'b1; end
                3'b101: begin legal = 1'b1; size = 3'd1; load_unsigned_o = 1'b1; end
                3'b110: begin legal = 1'b1; size = 3'd2; load_unsigned_o = 1'b1; end
                default: ;
            endcase
        end else if (opcode == 7'b0100011) begin // STORE
            immediate = {{52{insn_i[31]}}, insn_i[31:25], insn_i[11:7]};
            unique case(funct3)
                3'b000: legal = 1'b1;                         // SB
                3'b001: begin legal = 1'b1; size = 3'd1; end  // SH
                3'b010: begin legal = 1'b1; size = 3'd2; end  // SW
                3'b011: begin legal = 1'b1; size = 3'd3; end  // SD
                default: ;
            endcase
        end else if (opcode == 7'b0101111) begin // AMO / ATOMIC
            // funct3 must be 010 (W) or 011 (D)
            if (funct3 == 3'b010) size = 3'd2;
            else if (funct3 == 3'b011) size = 3'd3;

            if (funct3 == 3'b010 || funct3 == 3'b011) begin
                case (funct5)
                    5'b00010: begin // LR
                        if (insn_i[24:20] == 5'd0) begin // rs2 must be 0
                            legal = 1'b1;
                            is_lr = 1'b1;
                        end
                    end
                    5'b00011: begin // SC
                        legal = 1'b1;
                        is_sc = 1'b1;
                    end
                    5'b00001, // AMOSWAP
                    5'b00000, // AMOADD
                    5'b00100, // AMOXOR
                    5'b01100, // AMOAND
                    5'b01000, // AMOOR
                    5'b10000, // AMOMIN
                    5'b10100, // AMOMAX
                    5'b11000, // AMOMINU
                    5'b11100: begin // AMOMAXU
                        legal = 1'b1;
                        is_amo = 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    assign lsu_valid_o = insn_valid_i && legal;
    assign lsu_store_o = lsu_valid_o && (opcode == 7'b0100011 || is_sc);
    assign lsu_lr_o    = lsu_valid_o && is_lr;
    assign lsu_sc_o    = lsu_valid_o && is_sc;
    assign lsu_amo_o   = lsu_valid_o && is_amo;
    assign amo_op_o    = funct5;
    assign address_o   = rs1_i + immediate;
    assign size_o      = lsu_valid_o ? size : '0;
    assign store_data_o = (lsu_store_o || lsu_amo_o) ? rs2_i : '0;
    assign misaligned_o = lsu_valid_o && ((address_o & ((64'd1 << size) - 1)) != 0);
endmodule
