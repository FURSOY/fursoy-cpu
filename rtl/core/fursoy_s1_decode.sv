`ifndef FURSOY_S1_DECODE_SV
`define FURSOY_S1_DECODE_SV

// =============================================================================
// Fursoy Slice-1 2-Wide Parallel Instruction Decoder — Milestone 4
// =============================================================================
// Decodes fetched instructions into canonical uop_decoded_t format.
// Features:
// - Decode Exception Bypass: Checks exception_valid FIRST. If set, bypasses normal
//   instruction decoding and emits a benign placeholder exception uop (rd=x0) to
//   prevent spurious Illegal Instruction (Cause 2) exception overwrites.
// - Full RV64I, M, A, Zicsr, Zifencei, Zba, Zbb, and System instruction coverage.
// - Implements 2 parallel decode channels (Slot 0 and Slot 1).
// Reference: docs/architecture/slice1-m4-frontend-v1.md Sections 3.4, 26, 27
// =============================================================================

`include "fursoy_s1_pkg.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_decode
    import fursoy_s1_pkg::*;
(
    input  logic [1:0]        priv_mode_i,
    input  logic [1:0]        mstatus_fs_i,
    input  logic [1:0]        mstatus_vs_i,
    input  logic [2:0]        fcsr_frm_i,
    input  logic              mstatus_tw_i,
    input  logic [63:0]       vtype_i,

    // Input Channels (from Stage F4 Decoupled Fetch Queue)
    input  logic              in0_valid_i,
    input  fetch_queue_entry_t in0_entry_i,

    input  logic              in1_valid_i,
    input  fetch_queue_entry_t in1_entry_i,

    // Decoded Micro-op Outputs (to M1 Rename / Dispatch)
    output logic              uop0_valid_o,
    output uop_decoded_t      uop0_o,

    output logic              uop1_valid_o,
    output uop_decoded_t      uop1_o
);

    // =========================================================================
    // Single-Instruction Decoder Function
    // =========================================================================
    function automatic uop_decoded_t decode_inst(
        input logic               valid,
        input fetch_queue_entry_t entry,
        input logic [1:0]         priv_mode,
        input logic [1:0]         mstatus_fs,
        input logic [1:0]         mstatus_vs,
        input logic [2:0]         fcsr_frm,
        input logic               mstatus_tw,
        input logic [63:0]        vtype
    );
        uop_decoded_t uop;
        logic [31:0]  inst;
        logic [6:0]   opcode;
        logic [2:0]   funct3;
        logic [6:0]   funct7;
        logic [4:0]   rd;
        logic [4:0]   rs1;
        logic [4:0]   rs2;
        logic [4:0]   amo_funct5;
        logic [3:0]   vec_chk_vd_ng, vec_chk_vs1_ng, vec_chk_vs2_ng;
        logic         vec_chk_illegal;

        inst   = entry.inst;
        opcode = inst[6:0];
        funct3 = inst[14:12];
        funct7 = inst[31:25];
        rd     = inst[11:7];
        rs1    = inst[19:15];
        rs2    = inst[24:20];

        uop = '0;
        uop.valid = valid;
        uop.pc    = entry.pc;
        uop.inst  = entry.inst;

        // ---------------------------------------------------------------------
        // 1. Decode Exception Bypass (Section 3.4 & 26)
        // ---------------------------------------------------------------------
        if (entry.exception_valid) begin
            uop.exception   = 1'b1;
            uop.exc_cause   = entry.exception_cause;
            uop.uop_class   = UOP_ALU_INT;
            uop.sub_op      = ALU_ADD;
            uop.rd          = 5'd0; // x0 destination suppresses PRF write
            uop.rs1         = 5'd0;
            uop.rs2         = 5'd0;
            uop.use_imm     = 1'b1;
            uop.imm         = 64'd0;
            uop.is_branch   = 1'b0;
            uop.is_jal      = 1'b0;
            uop.is_jalr     = 1'b0;
            uop.pred_taken  = 1'b0;
            uop.pred_target = 64'd0;
            return uop;
        end

        // ---------------------------------------------------------------------
        // 2. Normal Instruction Decode
        // ---------------------------------------------------------------------
        uop.rd          = rd;
        uop.rs1         = rs1;
        uop.rs2         = rs2;
        uop.br_type     = entry.br_type;
        uop.pre_ghr     = entry.pre_branch_ghr;
        uop.pred_taken  = entry.pred_taken;
        uop.pred_target = entry.pred_target;

        case (opcode)
            // LUI
            7'b0110111: begin
                uop.uop_class = UOP_ALU_INT;
                uop.sub_op    = ALU_LUI;
                uop.use_imm   = 1'b1;
                uop.imm       = {{32{inst[31]}}, inst[31:12], 12'd0};
            end

            // AUIPC
            7'b0010111: begin
                uop.uop_class = UOP_ALU_INT;
                uop.sub_op    = ALU_AUIPC;
                uop.use_imm   = 1'b1;
                uop.imm       = {{32{inst[31]}}, inst[31:12], 12'd0};
            end

            // JAL
            7'b1101111: begin
                uop.uop_class = UOP_JAL;
                uop.sub_op    = ALU_ADD;
                uop.is_jal    = 1'b1;
                uop.use_imm   = 1'b1;
                uop.imm       = {{43{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
            end

            // JALR
            7'b1100111: begin
                uop.uop_class = UOP_JALR;
                uop.sub_op    = ALU_ADD;
                uop.is_jalr   = 1'b1;
                uop.is_branch = entry.is_jalr; // Speculative JALR allocates checkpoint
                uop.use_imm   = 1'b1;
                uop.imm       = {{52{inst[31]}}, inst[31:20]};
            end

            // Conditional Branch
            7'b1100011: begin
                uop.uop_class = UOP_BRANCH;
                uop.is_branch = 1'b1;
                uop.rd        = 5'd0;
                uop.use_imm   = 1'b1;
                uop.imm       = {{51{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
                case (funct3)
                    3'b000: uop.sub_op = BR_EQ;
                    3'b001: uop.sub_op = BR_NE;
                    3'b100: uop.sub_op = BR_LT;
                    3'b101: uop.sub_op = BR_GE;
                    3'b110: uop.sub_op = BR_LTU;
                    3'b111: uop.sub_op = BR_GEU;
                    default: begin
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd2; // Illegal Instruction
                    end
                endcase
            end

            // Base Integer ALU OP-IMM (RV64I + Zba + Zbb)
            7'b0010011: begin
                uop.use_imm = 1'b1;
                uop.imm     = {{52{inst[31]}}, inst[31:20]};
                case (funct3)
                    3'b000: begin
                        uop.uop_class = UOP_ALU_INT;
                        uop.sub_op    = ALU_ADD;
                    end
                    3'b010: begin
                        uop.uop_class = UOP_ALU_INT;
                        uop.sub_op    = ALU_SLT;
                    end
                    3'b011: begin
                        uop.uop_class = UOP_ALU_INT;
                        uop.sub_op    = ALU_SLTU;
                    end
                    3'b100: begin
                        uop.uop_class = UOP_ALU_INT;
                        uop.sub_op    = ALU_XOR;
                    end
                    3'b110: begin
                        uop.uop_class = UOP_ALU_INT;
                        uop.sub_op    = ALU_OR;
                    end
                    3'b111: begin
                        uop.uop_class = UOP_ALU_INT;
                        uop.sub_op    = ALU_AND;
                    end
                    3'b001: begin
                        if (funct7[6:1] == 6'b000000) begin
                            uop.uop_class = UOP_ALU_SHIFT;
                            uop.sub_op    = ALU_SLL;
                            uop.imm       = {58'd0, inst[25:20]};
                        end else if (funct7 == 7'b0110000 && inst[24:20] == 5'b00000) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_CLZ;
                        end else if (funct7 == 7'b0110000 && inst[24:20] == 5'b00001) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_CTZ;
                        end else if (funct7 == 7'b0110000 && inst[24:20] == 5'b00010) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_CPOP;
                        end else if (funct7 == 7'b0110000 && inst[24:20] == 5'b00100) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_SEXTB;
                        end else if (funct7 == 7'b0110000 && inst[24:20] == 5'b00101) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_SEXTH;
                        end else begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2;
                        end
                    end
                    3'b101: begin
                        if (funct7[6:1] == 6'b000000) begin
                            uop.uop_class = UOP_ALU_SHIFT;
                            uop.sub_op    = ALU_SRL;
                            uop.imm       = {58'd0, inst[25:20]};
                        end else if (funct7[6:1] == 6'b010000) begin
                            uop.uop_class = UOP_ALU_SHIFT;
                            uop.sub_op    = ALU_SRA;
                            uop.imm       = {58'd0, inst[25:20]};
                        end else if (funct7[6:1] == 6'b011000) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_ROR;
                            uop.imm       = {58'd0, inst[25:20]};
                        end else if (funct7 == 7'b0010100 && inst[24:20] == 5'b00111) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_ORC_B;
                        end else if (funct7 == 7'b0110101 && inst[24:20] == 5'b11000) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_REV8;
                        end else begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2;
                        end
                    end
                    default: begin
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd2;
                    end
                endcase
            end

            // Base Integer ALU OP (RV64I + RV64M + Zba + Zbb)
            7'b0110011: begin
                uop.use_imm = 1'b0;
                if (funct7 == 7'b0000001) begin
                    // RV64M Multiplier & Divider
                    case (funct3)
                        3'b000: begin uop.uop_class = UOP_MUL; uop.sub_op = MUL_MUL; end
                        3'b001: begin uop.uop_class = UOP_MUL; uop.sub_op = MUL_MULH; end
                        3'b010: begin uop.uop_class = UOP_MUL; uop.sub_op = MUL_MULHSU; end
                        3'b011: begin uop.uop_class = UOP_MUL; uop.sub_op = MUL_MULHU; end
                        3'b100: begin uop.uop_class = UOP_DIV; uop.sub_op = DIV_DIV; end
                        3'b101: begin uop.uop_class = UOP_DIV; uop.sub_op = DIV_DIVU; end
                        3'b110: begin uop.uop_class = UOP_DIV; uop.sub_op = DIV_REM; end
                        3'b111: begin uop.uop_class = UOP_DIV; uop.sub_op = DIV_REMU; end
                    endcase
                end else if (funct7 == 7'b0010000) begin
                    // Zba
                    case (funct3)
                        3'b010: begin uop.uop_class = UOP_ALU_ZBA; uop.sub_op = ALU_SH1ADD; end
                        3'b100: begin uop.uop_class = UOP_ALU_ZBA; uop.sub_op = ALU_SH2ADD; end
                        3'b110: begin uop.uop_class = UOP_ALU_ZBA; uop.sub_op = ALU_SH3ADD; end
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end else if (funct7 == 7'b0110000) begin
                    // Zbb rotate (ROL/ROR)
                    case (funct3)
                        3'b001: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_ROL; end
                        3'b101: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_ROR; end
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end else if (funct7 == 7'b0100000) begin
                    case (funct3)
                        3'b000: begin uop.uop_class = UOP_ALU_INT; uop.sub_op = ALU_SUB; end
                        3'b101: begin uop.uop_class = UOP_ALU_SHIFT; uop.sub_op = ALU_SRA; end
                        3'b110: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_ORN; end
                        3'b100: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_XNOR; end
                        3'b111: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_ANDN; end
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end else if (funct7 == 7'b0000101) begin
                    case (funct3)
                        3'b100: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_MIN; end
                        3'b101: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_MINU; end
                        3'b110: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_MAX; end
                        3'b111: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_MAXU; end
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end else if (funct7 == 7'b0000000) begin
                    uop.uop_class = UOP_ALU_INT;
                    case (funct3)
                        3'b000: uop.sub_op = ALU_ADD;
                        3'b001: begin uop.uop_class = UOP_ALU_SHIFT; uop.sub_op = ALU_SLL; end
                        3'b010: uop.sub_op = ALU_SLT;
                        3'b011: uop.sub_op = ALU_SLTU;
                        3'b100: uop.sub_op = ALU_XOR;
                        3'b101: begin uop.uop_class = UOP_ALU_SHIFT; uop.sub_op = ALU_SRL; end
                        3'b110: uop.sub_op = ALU_OR;
                        3'b111: uop.sub_op = ALU_AND;
                    endcase
                end else begin
                    uop.exception = 1'b1;
                    uop.exc_cause = 5'd2;
                end
            end

            // Word Operations OP-IMM-32 (RV64I W-forms + Zba)
            7'b0011011: begin
                uop.use_imm = 1'b1;
                uop.imm     = {{52{inst[31]}}, inst[31:20]};
                case (funct3)
                    3'b000: begin
                        uop.uop_class = UOP_ALU_INT;
                        uop.sub_op    = ALU_ADDW;
                    end
                    3'b001: begin
                        if (funct7 == 7'b0000000) begin
                            uop.uop_class = UOP_ALU_SHIFT;
                            uop.sub_op    = ALU_SLLW;
                            uop.imm       = {59'd0, inst[24:20]};
                        end else if (funct7[6:1] == 6'b000010) begin
                            uop.uop_class = UOP_ALU_ZBA;
                            uop.sub_op    = ALU_SLLI_UW;
                            uop.imm       = {58'd0, inst[25:20]};
                        end else if (funct7 == 7'b0110000 && inst[24:20] == 5'b00000) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_CLZW;
                        end else if (funct7 == 7'b0110000 && inst[24:20] == 5'b00001) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_CTZW;
                        end else if (funct7 == 7'b0110000 && inst[24:20] == 5'b00010) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_CPOPW;
                        end else begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2;
                        end
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000) begin
                            uop.uop_class = UOP_ALU_SHIFT;
                            uop.sub_op    = ALU_SRLW;
                            uop.imm       = {59'd0, inst[24:20]};
                        end else if (funct7 == 7'b0100000) begin
                            uop.uop_class = UOP_ALU_SHIFT;
                            uop.sub_op    = ALU_SRAW;
                            uop.imm       = {59'd0, inst[24:20]};
                        end else if (funct7 == 7'b0110000) begin
                            uop.uop_class = UOP_ALU_ZBB;
                            uop.sub_op    = ALU_RORW;
                            uop.imm       = {59'd0, inst[24:20]};
                        end else begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2;
                        end
                    end
                    default: begin
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd2;
                    end
                endcase
            end

            // Word Operations OP-32 (RV64I + RV64M + Zba)
            7'b0111011: begin
                uop.use_imm = 1'b0;
                if (funct7 == 7'b0000001) begin
                    case (funct3)
                        3'b000: begin uop.uop_class = UOP_MUL; uop.sub_op = MUL_MULW; end
                        3'b100: begin uop.uop_class = UOP_DIV; uop.sub_op = DIV_DIVW; end
                        3'b101: begin uop.uop_class = UOP_DIV; uop.sub_op = DIV_DIVUW; end
                        3'b110: begin uop.uop_class = UOP_DIV; uop.sub_op = DIV_REMW; end
                        3'b111: begin uop.uop_class = UOP_DIV; uop.sub_op = DIV_REMUW; end
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end else if (funct7 == 7'b0000000) begin
                    case (funct3)
                        3'b000: begin uop.uop_class = UOP_ALU_INT; uop.sub_op = ALU_ADDW; end
                        3'b001: begin uop.uop_class = UOP_ALU_SHIFT; uop.sub_op = ALU_SLLW; end
                        3'b101: begin uop.uop_class = UOP_ALU_SHIFT; uop.sub_op = ALU_SRLW; end
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end else if (funct7 == 7'b0100000) begin
                    case (funct3)
                        3'b000: begin uop.uop_class = UOP_ALU_INT; uop.sub_op = ALU_SUBW; end
                        3'b101: begin uop.uop_class = UOP_ALU_SHIFT; uop.sub_op = ALU_SRAW; end
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end else if (funct7 == 7'b0010000) begin
                    case (funct3)
                        3'b010: begin uop.uop_class = UOP_ALU_ZBA; uop.sub_op = ALU_SH1ADD_UW; end
                        3'b100: begin uop.uop_class = UOP_ALU_ZBA; uop.sub_op = ALU_SH2ADD_UW; end
                        3'b110: begin uop.uop_class = UOP_ALU_ZBA; uop.sub_op = ALU_SH3ADD_UW; end
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end else if (funct7 == 7'b0110000) begin
                    case (funct3)
                        3'b001: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_ROLW; end
                        3'b101: begin uop.uop_class = UOP_ALU_ZBB; uop.sub_op = ALU_RORW; end
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end else if (funct7 == 7'b0000100 && funct3 == 3'b000) begin
                    uop.uop_class = UOP_ALU_ZBA;
                    uop.sub_op    = ALU_ADD_UW;
                end else if (funct7 == 7'b0000100 && funct3 == 3'b100 && inst[24:20] == 5'b00000) begin
                    uop.uop_class = UOP_ALU_ZBB;
                    uop.sub_op    = ALU_ZEXTH;
                end else begin
                    uop.exception = 1'b1;
                    uop.exc_cause = 5'd2;
                end
            end

            // Loads (RV64I)
            7'b0000011: begin
                uop.uop_class = UOP_LOAD;
                uop.use_imm   = 1'b1;
                uop.imm       = {{52{inst[31]}}, inst[31:20]};
                case (funct3)
                    3'b000: uop.sub_op = MEM_LB;
                    3'b001: uop.sub_op = MEM_LH;
                    3'b010: uop.sub_op = MEM_LW;
                    3'b011: uop.sub_op = MEM_LD;
                    3'b100: uop.sub_op = MEM_LBU;
                    3'b101: uop.sub_op = MEM_LHU;
                    3'b110: uop.sub_op = MEM_LWU;
                    default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                endcase
            end

            // Stores (RV64I)
            7'b0100011: begin
                uop.uop_class = UOP_STORE;
                uop.rd        = 5'd0;
                uop.use_imm   = 1'b1;
                uop.imm       = {{52{inst[31]}}, inst[31:25], inst[11:7]};
                case (funct3)
                    3'b000: uop.sub_op = MEM_SB;
                    3'b001: uop.sub_op = MEM_SH;
                    3'b010: uop.sub_op = MEM_SW;
                    3'b011: uop.sub_op = MEM_SD;
                    default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                endcase
            end

            // Scalar Floating-Point Loads (FLW/FLD) & Vector Loads (VLE/VLEFF/VLSE)
            7'b0000111: begin
                if (funct3 == 3'b010 || funct3 == 3'b011) begin
                    if (mstatus_fs == 2'b00) begin
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd2;
                    end else begin
                        uop.uop_class      = UOP_LOAD;
                        uop.is_fp          = 1'b1;
                        uop.fp_dest_valid  = 1'b1;
                        uop.rd             = inst[11:7];
                        uop.rs1            = inst[19:15];
                        uop.rs2            = 5'd0;
                        uop.use_imm        = 1'b1;
                        uop.imm            = {{52{inst[31]}}, inst[31:20]};
                        uop.sub_op         = (funct3 == 3'b010) ? MEM_FLW : MEM_FLD;
                    end
                end else if (funct3 == 3'b000 || funct3 == 3'b101 || funct3 == 3'b110 || funct3 == 3'b111) begin
                    if (mstatus_vs == 2'b00 || inst[31:29] != 3'b000 || inst[28] != 1'b0) begin
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd2;
                    end else begin
                        uop.uop_class      = UOP_VEC;
                        uop.is_vec         = 1'b1;
                        uop.vec_dest_valid = 1'b1;
                        uop.rd             = 5'd0;
                        uop.rs1            = inst[19:15];
                        uop.vec_uses_rs1   = 1'b1;
                        uop.vec_vm         = inst[25];
                        uop.vec_vd         = inst[11:7];
                        uop.vec_mop        = inst[27:26];
                        case (funct3)
                            3'b000:  uop.vec_eew = 3'd0;
                            3'b101:  uop.vec_eew = 3'd1;
                            3'b110:  uop.vec_eew = 3'd2;
                            default: uop.vec_eew = 3'd3;
                        endcase
                        if (inst[27:26] == 2'b00 && inst[24:20] == 5'b00000) begin
                            uop.sub_op = VEC_VLE;
                        end else if (inst[27:26] == 2'b00 && inst[24:20] == 5'b10000) begin
                            uop.sub_op = VEC_VLEFF;
                        end else if (inst[27:26] == 2'b10) begin
                            uop.sub_op       = VEC_VLSE;
                            uop.rs2          = inst[24:20];
                            uop.vec_uses_rs2 = 1'b1;
                        end else if (inst[27:26] == 2'b01 || inst[27:26] == 2'b11) begin
                            uop.sub_op       = VEC_VLUXEI;
                            uop.vec_vs2      = inst[24:20];
                            uop.vec_uses_vs2 = 1'b1;
                        end else begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2;
                        end
                    end
                end else begin
                    uop.exception = 1'b1;
                    uop.exc_cause = 5'd2;
                end
            end

            // Scalar Floating-Point Stores (FSW/FSD) & Vector Stores (VSE/VSSE)
            7'b0100111: begin
                if (funct3 == 3'b010 || funct3 == 3'b011) begin
                    if (mstatus_fs == 2'b00) begin
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd2;
                    end else begin
                        uop.uop_class      = UOP_STORE;
                        uop.is_fp          = 1'b1;
                        uop.fp_dest_valid  = 1'b0;
                        uop.rd             = 5'd0;
                        uop.rs1            = inst[19:15];
                        uop.rs2            = inst[24:20];
                        uop.use_imm        = 1'b1;
                        uop.imm            = {{52{inst[31]}}, inst[31:25], inst[11:7]};
                        uop.sub_op         = (funct3 == 3'b010) ? MEM_FSW : MEM_FSD;
                    end
                end else if (funct3 == 3'b000 || funct3 == 3'b101 || funct3 == 3'b110 || funct3 == 3'b111) begin
                    if (mstatus_vs == 2'b00 || inst[31:29] != 3'b000 || inst[28] != 1'b0) begin
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd2;
                    end else begin
                        uop.uop_class      = UOP_VEC;
                        uop.is_vec         = 1'b1;
                        uop.vec_dest_valid = 1'b0;
                        uop.rd             = 5'd0;
                        uop.rs1            = inst[19:15];
                        uop.vec_uses_rs1   = 1'b1;
                        uop.vec_vm         = inst[25];
                        uop.vec_vd         = inst[11:7]; // vs3 stored register
                        uop.vec_mop        = inst[27:26];
                        case (funct3)
                            3'b000:  uop.vec_eew = 3'd0;
                            3'b101:  uop.vec_eew = 3'd1;
                            3'b110:  uop.vec_eew = 3'd2;
                            default: uop.vec_eew = 3'd3;
                        endcase
                        if (inst[27:26] == 2'b00 && inst[24:20] == 5'b00000) begin
                            uop.sub_op = VEC_VSE;
                        end else if (inst[27:26] == 2'b10) begin
                            uop.sub_op       = VEC_VSSE;
                            uop.rs2          = inst[24:20];
                            uop.vec_uses_rs2 = 1'b1;
                        end else if (inst[27:26] == 2'b01 || inst[27:26] == 2'b11) begin
                            uop.sub_op       = VEC_VSOXEI;
                            uop.vec_vs2      = inst[24:20];
                            uop.vec_uses_vs2 = 1'b1;
                        end else begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2;
                        end
                    end
                end else begin
                    uop.exception = 1'b1;
                    uop.exc_cause = 5'd2;
                end
            end

            // Floating-Point Fused Multiply-Add (RV64F / RV64D)
            7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111: begin
                if (mstatus_fs == 2'b00 || inst[26] != 1'b0 || funct3 == 3'b101 || funct3 == 3'b110 ||
                    ((funct3 == 3'b111) && (fcsr_frm >= 3'd5))) begin
                    uop.exception = 1'b1;
                    uop.exc_cause = 5'd2;
                end else begin
                    uop.uop_class     = UOP_FP;
                    uop.is_fp         = 1'b1;
                    uop.fp_dest_valid = 1'b1;
                    uop.rd            = inst[11:7];
                    uop.rs1           = inst[19:15];
                    uop.rs2           = inst[24:20];
                    uop.fs3           = inst[31:27];
                    uop.frm           = funct3;
                    case ({opcode[3:2], inst[25]})
                        3'b000: uop.sub_op = FP_FMADD_S;
                        3'b001: uop.sub_op = FP_FMADD_D;
                        3'b010: uop.sub_op = FP_FMSUB_S;
                        3'b011: uop.sub_op = FP_FMSUB_D;
                        3'b100: uop.sub_op = FP_FNMSUB_S;
                        3'b101: uop.sub_op = FP_FNMSUB_D;
                        3'b110: uop.sub_op = FP_FNMADD_S;
                        default: uop.sub_op = FP_FNMADD_D;
                    endcase
                end
            end

            // Floating-Point Computational & Conversion Operations (OP-FP, RV64F / RV64D)
            7'b1010011: begin
                if (mstatus_fs == 2'b00) begin
                    uop.exception = 1'b1;
                    uop.exc_cause = 5'd2;
                end else begin
                    logic fp_rm_invalid;
                    fp_rm_invalid     = (funct3 == 3'b101) || (funct3 == 3'b110) ||
                                        ((funct3 == 3'b111) && (fcsr_frm >= 3'd5));
                    uop.uop_class     = UOP_FP;
                    uop.is_fp         = 1'b1;
                    uop.fp_dest_valid = 1'b1;
                    uop.rd            = inst[11:7];
                    uop.rs1           = inst[19:15];
                    uop.rs2           = inst[24:20];
                    uop.frm           = funct3;
                    case (funct7)
                        7'b0000000: if (fp_rm_invalid) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = FP_FADD_S;
                        7'b0000001: if (fp_rm_invalid) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = FP_FADD_D;
                        7'b0000100: if (fp_rm_invalid) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = FP_FSUB_S;
                        7'b0000101: if (fp_rm_invalid) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = FP_FSUB_D;
                        7'b0001000: if (fp_rm_invalid) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = FP_FMUL_S;
                        7'b0001001: if (fp_rm_invalid) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = FP_FMUL_D;
                        7'b0001100: if (fp_rm_invalid) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = FP_FDIV_S;
                        7'b0001101: if (fp_rm_invalid) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = FP_FDIV_D;
                        7'b0101100, 7'b0101101: begin
                            uop.rs2 = 5'd0;
                            if (fp_rm_invalid || inst[24:20] != 5'd0) begin
                                uop.exception = 1'b1;
                                uop.exc_cause = 5'd2;
                            end else begin
                                uop.sub_op = funct7[0] ? FP_FSQRT_D : FP_FSQRT_S;
                            end
                        end
                        7'b0010000, 7'b0010001: begin
                            case (funct3)
                                3'b000: uop.sub_op = funct7[0] ? FP_FSGNJ_D  : FP_FSGNJ_S;
                                3'b001: uop.sub_op = funct7[0] ? FP_FSGNJN_D : FP_FSGNJN_S;
                                3'b010: uop.sub_op = funct7[0] ? FP_FSGNJX_D : FP_FSGNJX_S;
                                default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                            endcase
                        end
                        7'b0010100, 7'b0010101: begin
                            case (funct3)
                                3'b000: uop.sub_op = funct7[0] ? FP_FMIN_D : FP_FMIN_S;
                                3'b001: uop.sub_op = funct7[0] ? FP_FMAX_D : FP_FMAX_S;
                                default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                            endcase
                        end
                        7'b0100000: begin
                            uop.rs2 = 5'd0;
                            if (fp_rm_invalid || inst[24:20] != 5'd1) begin
                                uop.exception = 1'b1;
                                uop.exc_cause = 5'd2;
                            end else begin
                                uop.sub_op = FP_FCVT_S_D;
                            end
                        end
                        7'b0100001: begin
                            uop.rs2 = 5'd0;
                            if (fp_rm_invalid || inst[24:20] != 5'd0) begin
                                uop.exception = 1'b1;
                                uop.exc_cause = 5'd2;
                            end else begin
                                uop.sub_op = FP_FCVT_D_S;
                            end
                        end
                        7'b1010000, 7'b1010001: begin
                            uop.fp_dest_valid = 1'b0;
                            case (funct3)
                                3'b010: uop.sub_op = funct7[0] ? FP_FEQ_D : FP_FEQ_S;
                                3'b001: uop.sub_op = funct7[0] ? FP_FLT_D : FP_FLT_S;
                                3'b000: uop.sub_op = funct7[0] ? FP_FLE_D : FP_FLE_S;
                                default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                            endcase
                        end
                        7'b1110000, 7'b1110001: begin
                            uop.fp_dest_valid = 1'b0;
                            uop.rs2           = 5'd0;
                            if (inst[24:20] != 5'd0) begin
                                uop.exception = 1'b1;
                                uop.exc_cause = 5'd2;
                            end else if (funct3 == 3'b000) begin
                                uop.sub_op = funct7[0] ? FP_FMV_X_D : FP_FMV_X_W;
                            end else if (funct3 == 3'b001) begin
                                uop.sub_op = funct7[0] ? FP_FCLASS_D : FP_FCLASS_S;
                            end else begin
                                uop.exception = 1'b1;
                                uop.exc_cause = 5'd2;
                            end
                        end
                        7'b1100000, 7'b1100001: begin
                            uop.fp_dest_valid = 1'b0;
                            uop.rs2           = 5'd0;
                            if (fp_rm_invalid || inst[24:22] != 3'b000) begin
                                uop.exception = 1'b1;
                                uop.exc_cause = 5'd2;
                            end else begin
                                case (inst[21:20])
                                    2'b00: uop.sub_op = funct7[0] ? FP_FCVT_W_D  : FP_FCVT_W_S;
                                    2'b01: uop.sub_op = funct7[0] ? FP_FCVT_WU_D : FP_FCVT_WU_S;
                                    2'b10: uop.sub_op = funct7[0] ? FP_FCVT_L_D  : FP_FCVT_L_S;
                                    2'b11: uop.sub_op = funct7[0] ? FP_FCVT_LU_D : FP_FCVT_LU_S;
                                endcase
                            end
                        end
                        7'b1111000, 7'b1111001: begin
                            uop.rs2 = 5'd0;
                            if (funct3 != 3'b000 || inst[24:20] != 5'd0) begin
                                uop.exception = 1'b1;
                                uop.exc_cause = 5'd2;
                            end else begin
                                uop.sub_op = funct7[0] ? FP_FMV_D_X : FP_FMV_W_X;
                            end
                        end
                        7'b1101000, 7'b1101001: begin
                            uop.rs2 = 5'd0;
                            if (fp_rm_invalid || inst[24:22] != 3'b000) begin
                                uop.exception = 1'b1;
                                uop.exc_cause = 5'd2;
                            end else begin
                                case (inst[21:20])
                                    2'b00: uop.sub_op = funct7[0] ? FP_FCVT_D_W  : FP_FCVT_S_W;
                                    2'b01: uop.sub_op = funct7[0] ? FP_FCVT_D_WU : FP_FCVT_S_WU;
                                    2'b10: uop.sub_op = funct7[0] ? FP_FCVT_D_L  : FP_FCVT_S_L;
                                    2'b11: uop.sub_op = funct7[0] ? FP_FCVT_D_LU : FP_FCVT_S_LU;
                                endcase
                            end
                        end
                        default: begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2;
                        end
                    endcase
                end
            end

            // RISC-V Vector Configuration & Integer Vector Arithmetic (OP-V)
            7'b1010111: begin
                if (mstatus_vs == 2'b00) begin
                    uop.exception = 1'b1;
                    uop.exc_cause = 5'd2;
                end else if (funct3 == 3'b111) begin
                    uop.uop_class = UOP_SYSTEM;
                    uop.rd        = inst[11:7];
                    uop.use_imm   = 1'b0;
                    if (inst[31] == 1'b0) begin
                        uop.sub_op = VEC_VSETVLI;
                        uop.rs1    = inst[19:15];
                        uop.rs2    = 5'd0;
                        uop.imm    = {47'd0, inst[19:15], (inst[11:7] == 5'd0), inst[30:20]};
                    end else if (inst[31:30] == 2'b11) begin
                        uop.sub_op = VEC_VSETIVLI;
                        uop.rs1    = 5'd0;
                        uop.rs2    = 5'd0;
                        uop.imm    = {47'd0, inst[19:15], (inst[11:7] == 5'd0), 1'b0, inst[29:20]};
                    end else if (inst[31:25] == 7'b1000000) begin
                        uop.sub_op = VEC_VSETVL;
                        uop.rs1    = inst[19:15];
                        uop.rs2    = inst[24:20];
                        uop.imm    = {47'd0, inst[19:15], (inst[11:7] == 5'd0), 11'd0};
                    end else begin
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd2;
                    end
                end else if (funct3 == 3'b000 || funct3 == 3'b011 || funct3 == 3'b100) begin
                    logic [5:0] v_funct6;
                    v_funct6           = inst[31:26];
                    uop.uop_class      = UOP_VEC;
                    uop.is_vec         = 1'b1;
                    uop.vec_dest_valid = 1'b1;
                    uop.rd             = 5'd0;
                    uop.vec_vm         = inst[25];
                    uop.vec_vd         = inst[11:7];
                    uop.vec_vs2        = inst[24:20];
                    uop.vec_vs1        = inst[19:15];
                    uop.vec_uses_vs2   = 1'b1;
                    uop.vec_uses_vs1   = (funct3 == 3'b000);
                    uop.vec_uses_rs1   = (funct3 == 3'b100);
                    if (funct3 == 3'b100) begin
                        uop.rs1 = inst[19:15];
                    end
                    if (funct3 == 3'b011) begin
                        uop.use_imm = 1'b1;
                        uop.imm     = {{59{inst[19]}}, inst[19:15]};
                    end
                    case (v_funct6)
                        6'b000000: uop.sub_op = VEC_VADD;
                        6'b000010: if (funct3 == 3'b011) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VSUB;
                        6'b000011: if (funct3 == 3'b000) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VRSUB;
                        6'b000100: if (funct3 == 3'b011) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMINU;
                        6'b000101: if (funct3 == 3'b011) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMIN;
                        6'b000110: if (funct3 == 3'b011) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMAXU;
                        6'b000111: if (funct3 == 3'b011) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMAX;
                        6'b001001: uop.sub_op = VEC_VAND;
                        6'b001010: uop.sub_op = VEC_VOR;
                        6'b001011: uop.sub_op = VEC_VXOR;
                        6'b001110: if (funct3 == 3'b000) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VSLIDEUP;
                        6'b001111: if (funct3 == 3'b000) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VSLIDEDOWN;
                        6'b010111: begin
                            uop.vec_uses_vs2 = 1'b0;
                            if (!inst[25] || inst[24:20] != 5'd0) begin
                                uop.exception = 1'b1;
                                uop.exc_cause = 5'd2;
                            end else begin
                                uop.sub_op = VEC_VMV;
                            end
                        end
                        6'b011000: uop.sub_op = VEC_VMSEQ;
                        6'b011001: uop.sub_op = VEC_VMSNE;
                        6'b011010: if (funct3 == 3'b011) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMSLTU;
                        6'b011011: if (funct3 == 3'b011) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMSLT;
                        6'b011100: uop.sub_op = VEC_VMSLEU;
                        6'b011101: uop.sub_op = VEC_VMSLE;
                        6'b011110: if (funct3 == 3'b000) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMSGTU;
                        6'b011111: if (funct3 == 3'b000) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMSGT;
                        6'b100101: uop.sub_op = VEC_VSLL;
                        6'b101000: uop.sub_op = VEC_VSRL;
                        6'b101001: uop.sub_op = VEC_VSRA;
                        default: begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2;
                        end
                    endcase
                end else if (funct3 == 3'b010 || funct3 == 3'b110) begin
                    logic [5:0] v_funct6;
                    v_funct6           = inst[31:26];
                    uop.uop_class      = UOP_VEC;
                    uop.is_vec         = 1'b1;
                    uop.vec_dest_valid = 1'b1;
                    uop.rd             = 5'd0;
                    uop.vec_vm         = inst[25];
                    uop.vec_vd         = inst[11:7];
                    uop.vec_vs2        = inst[24:20];
                    uop.vec_vs1        = inst[19:15];
                    uop.vec_uses_vs2   = 1'b1;
                    uop.vec_uses_vs1   = (funct3 == 3'b010);
                    uop.vec_uses_rs1   = (funct3 == 3'b110);
                    if (funct3 == 3'b110) begin
                        uop.rs1 = inst[19:15];
                    end
                    case (v_funct6)
                        6'b000000: if (funct3 != 3'b010) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VREDSUM;
                        6'b001110: if (funct3 != 3'b110) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VSLIDE1UP;
                        6'b001111: if (funct3 != 3'b110) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VSLIDE1DOWN;
                        6'b011001: if (funct3 != 3'b010 || !inst[25]) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMAND;
                        6'b011010: if (funct3 != 3'b010 || !inst[25]) begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end else uop.sub_op = VEC_VMOR;
                        6'b100000: uop.sub_op = VEC_VDIVU;
                        6'b100001: uop.sub_op = VEC_VDIV;
                        6'b100101: uop.sub_op = VEC_VMUL;
                        default: begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2;
                        end
                    endcase
                end else begin
                    uop.exception = 1'b1;
                    uop.exc_cause = 5'd2;
                end
            end

            // Atomics (RV64A: LR/SC & AMO)
            7'b0101111: begin
                amo_funct5 = inst[31:27];
                if (amo_funct5 == 5'b00010) begin
                    // LR
                    uop.uop_class = UOP_LOAD;
                    uop.sub_op    = (funct3 == 3'b010) ? MEM_LR_W : MEM_LR_D;
                    uop.use_imm   = 1'b0;
                end else if (amo_funct5 == 5'b00011) begin
                    // SC
                    uop.uop_class = UOP_STORE;
                    uop.sub_op    = (funct3 == 3'b010) ? MEM_SC_W : MEM_SC_D;
                    uop.use_imm   = 1'b0;
                end else begin
                    // AMO
                    uop.uop_class = UOP_AMO;
                    uop.use_imm   = 1'b0;
                    case (amo_funct5)
                        5'b00001: uop.sub_op = (funct3 == 3'b010) ? AMO_SWAP_W : AMO_SWAP_D;
                        5'b00000: uop.sub_op = (funct3 == 3'b010) ? AMO_ADD_W  : AMO_ADD_D;
                        5'b00100: uop.sub_op = (funct3 == 3'b010) ? AMO_XOR_W  : AMO_XOR_D;
                        5'b01100: uop.sub_op = (funct3 == 3'b010) ? AMO_AND_W  : AMO_AND_D;
                        5'b01000: uop.sub_op = (funct3 == 3'b010) ? AMO_OR_W   : AMO_OR_D;
                        5'b10000: uop.sub_op = (funct3 == 3'b010) ? AMO_MIN_W  : AMO_MIN_D;
                        5'b10100: uop.sub_op = (funct3 == 3'b010) ? AMO_MAX_W  : AMO_MAX_D;
                        5'b11000: uop.sub_op = (funct3 == 3'b010) ? AMO_MINU_W : AMO_MINU_D;
                        5'b11100: uop.sub_op = (funct3 == 3'b010) ? AMO_MAXU_W : AMO_MAXU_D;
                        default: begin uop.exception = 1'b1; uop.exc_cause = 5'd2; end
                    endcase
                end
            end

            // MISC-MEM (FENCE & FENCE.I)
            7'b0001111: begin
                uop.uop_class = UOP_FENCE;
                uop.rd        = 5'd0;
                if (funct3 == 3'b000) begin
                    uop.sub_op = MEM_FENCE;
                end else if (funct3 == 3'b001) begin
                    uop.sub_op = MEM_FENCE_I;
                end else begin
                    uop.exception = 1'b1;
                    uop.exc_cause = 5'd2;
                end
            end

            // SYSTEM (ECALL, EBREAK, MRET, SRET, WFI, SFENCE.VMA, CSR)
            7'b1110011: begin
                if (funct3 == 3'b000) begin
                    if (inst[31:20] == 12'h000) begin
                        // ECALL: cause 8 (U-mode), 9 (S-mode), 11 (M-mode)
                        uop.uop_class = UOP_SYSTEM;
                        uop.exception = 1'b1;
                        uop.exc_cause = (priv_mode == 2'b11) ? 5'd11 :
                                        (priv_mode == 2'b01) ? 5'd9  : 5'd8;
                        uop.rd        = 5'd0;
                    end else if (inst[31:20] == 12'h001) begin
                        // EBREAK
                        uop.uop_class = UOP_SYSTEM;
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd3; // Breakpoint
                        uop.rd        = 5'd0;
                    end else if (inst[31:20] == 12'h302) begin
                        // MRET: requires M-mode
                        if (priv_mode < 2'b11) begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2; // Illegal Instruction
                        end else begin
                            uop.uop_class = UOP_SYSTEM;
                            uop.sub_op    = SYS_MRET;
                            uop.rd        = 5'd0;
                        end
                    end else if (inst[31:20] == 12'h102) begin
                        // SRET: requires S-mode or higher
                        if (priv_mode < 2'b01) begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2; // Illegal Instruction
                        end else begin
                            uop.uop_class = UOP_SYSTEM;
                            uop.sub_op    = SYS_SRET;
                            uop.rd        = 5'd0;
                        end
                    end else if (inst[31:20] == 12'h105) begin
                        // WFI: illegal in U-mode or S-mode with mstatus.TW=1
                        if ((priv_mode == 2'b00) || ((priv_mode == 2'b01) && mstatus_tw)) begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2; // Illegal Instruction
                        end else begin
                            uop.uop_class = UOP_SYSTEM;
                            uop.sub_op    = SYS_WFI;
                            uop.rd        = 5'd0;
                        end
                    end else if (funct7 == 7'b0001001) begin
                        // SFENCE.VMA: requires S-mode or higher
                        if (priv_mode == 2'b00) begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2; // Illegal Instruction
                        end else begin
                            uop.uop_class = UOP_SYSTEM;
                            uop.sub_op    = SYS_SFENCE_VMA;
                            uop.rd        = 5'd0;
                            uop.imm       = {62'd0, (inst[24:20] == 5'd0), (inst[19:15] == 5'd0)};
                        end
                    end else begin
                        uop.exception = 1'b1;
                        uop.exc_cause = 5'd2; // Illegal Instruction
                    end
                end else begin
                    // Canonical CSR Instructions (Zicsr)
                    uop.uop_class = UOP_SYSTEM;
                    uop.imm       = {47'd0, rs1, inst[31:20]}; // 12-bit CSR addr [11:0], 5-bit rs1/zimm [16:12]
                    uop.use_imm   = 1'b1;
                    case (funct3)
                        3'b001: uop.sub_op = SYS_CSRRW;
                        3'b010: uop.sub_op = SYS_CSRRS;
                        3'b011: uop.sub_op = SYS_CSRRC;
                        3'b101: begin
                            uop.sub_op    = SYS_CSRRWI;
                            uop.rs1       = 5'd0;
                            uop.imm[16:12]= rs1; // 5-bit zimm
                        end
                        3'b110: begin
                            uop.sub_op    = SYS_CSRRSI;
                            uop.rs1       = 5'd0;
                            uop.imm[16:12]= rs1; // 5-bit zimm
                        end
                        3'b111: begin
                            uop.sub_op    = SYS_CSRRCI;
                            uop.rs1       = 5'd0;
                            uop.imm[16:12]= rs1; // 5-bit zimm
                        end
                        default: begin
                            uop.exception = 1'b1;
                            uop.exc_cause = 5'd2; // Illegal Instruction
                        end
                    endcase
                end
            end

            default: begin
                // Illegal instruction
                uop.exception = 1'b1;
                uop.exc_cause = 5'd2; // Illegal Instruction
            end
        endcase

        if (!uop.exception && (uop.uop_class == UOP_VEC)) begin
            vtype_bundle_t vt;
            vt = vtype_bundle_t'({vtype[63], vtype[7:6], vsew_t'(vtype[5:3]), vlmul_t'(vtype[2:0])});
            calc_vec_emul_info(
                vt, uop.sub_op, uop.vec_eew,
                uop.vec_vd, uop.vec_vs1, uop.vec_vs2, uop.vec_vm,
                uop.vec_uses_vs1, uop.vec_uses_vs2,
                vec_chk_vd_ng, vec_chk_vs1_ng, vec_chk_vs2_ng, vec_chk_illegal
            );
            if (vec_chk_illegal) begin
                uop.exception = 1'b1;
                uop.exc_cause = 5'd2; // Illegal Instruction (EMUL/alignment/wrap/v0 overlap/vill)
            end
        end

        if (uop.exception) begin
            uop.uop_class      = UOP_SYSTEM;
            uop.rd             = 5'd0;
            uop.fp_dest_valid  = 1'b0;
            uop.vec_dest_valid = 1'b0;
            uop.is_fp          = 1'b0;
            uop.is_vec         = 1'b0;
        end

        return uop;
    endfunction

    // Decode Channel 0 and Channel 1
    assign uop0_valid_o = in0_valid_i;
    assign uop0_o       = decode_inst(in0_valid_i, in0_entry_i, priv_mode_i, mstatus_fs_i, mstatus_vs_i,
                                      fcsr_frm_i, mstatus_tw_i, vtype_i);

    assign uop1_valid_o = in1_valid_i;
    assign uop1_o       = decode_inst(in1_valid_i, in1_entry_i, priv_mode_i, mstatus_fs_i, mstatus_vs_i,
                                      fcsr_frm_i, mstatus_tw_i, vtype_i);

endmodule

`endif // FURSOY_S1_DECODE_SV
