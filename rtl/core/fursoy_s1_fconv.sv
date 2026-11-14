`ifndef FURSOY_S1_FCONV_SV
`define FURSOY_S1_FCONV_SV

// =============================================================================
// Fursoy Slice-1 Cross-Domain Move, Conversion & Comparison Unit — Milestone 8 Phase B
// =============================================================================
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 6.4, Section 11
//
// Invariants:
// - Float-to-Float: FCVT.S.D (narrowing with NaN-boxing) and FCVT.D.S (widening).
// - Float-to-Integer: FMV.X.W (sign-extended to 64 bits), FMV.X.D, FCVT.W/L/WU/LU,
//   FEQ, FLT, FLE, FCLASS. Output to Integer PRF with holding buffer f2i_wb_buf.
//   Arbitration priority: ALU0/ALU1 > F2I.
// - Integer-to-Float: FMV.W.X (NaN-boxed [63:32]=32'hFFFFFFFF), FMV.D.X,
//   FCVT.S/D.W/L/WU/LU. Output to FPRF w0_fp.
// - Sign injection: FSGNJ, FSGNJN, FSGNJX (.S and .D).
// - Min / Max: FMIN, FMAX (.S and .D).
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_fconv
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Flush and Recovery
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    input  logic [2:0]        fcsr_frm_i,

    // Port 4 Request (F2F, F2I, Compare, Classify, Min/Max, Sign Injection)
    input  logic              p4_req_valid_i,
    input  uop_subop_t        p4_req_subop_i,
    input  logic [2:0]        p4_req_frm_i,
    input  logic [63:0]       p4_req_rs1_fp_data_i,
    input  logic [63:0]       p4_req_rs2_fp_data_i,
    input  fpreg_t            p4_req_prd_fp_i,
    input  preg_t             p4_req_pnew_i,
    input  logic              p4_req_fp_dest_valid_i,
    input  rob_idx_t          p4_req_rob_idx_i,
    input  rob_epoch_t        p4_req_rob_epoch_i,

    // Port 0/1 Request (Int-to-Float: FMV.W.X, FMV.D.X, FCVT.S/D.W/L/WU/LU)
    input  logic              int2fp_req_valid_i,
    input  uop_subop_t        int2fp_req_subop_i,
    input  logic [2:0]        int2fp_req_frm_i,
    input  logic [63:0]       int2fp_req_int_data_i,
    input  fpreg_t            int2fp_req_prd_fp_i,
    input  rob_idx_t          int2fp_req_rob_idx_i,
    input  rob_epoch_t        int2fp_req_rob_epoch_i,

    // Integer PRF writeback bus arbitration (ALU0/ALU1 busy)
    input  logic              int_wb_busy_i,
    // FPRF w0_fp writeback bus arbitration (FMA/FDIV busy)
    input  logic              fprf_wb_busy_i,

    // Outputs writing to FPRF (w0_fp)
    output logic              fprf_wb_valid_o,
    output logic [63:0]       fprf_wb_data_o,
    output fpreg_t            fprf_wb_prd_fp_o,
    output rob_idx_t          fprf_wb_rob_idx_o,
    output rob_epoch_t        fprf_wb_rob_epoch_o,
    output logic [4:0]        fprf_wb_fflags_o,

    // Outputs writing to Integer PRF (Float-to-Integer)
    output logic              prf_wb_valid_o,
    output logic [63:0]       prf_wb_data_o,
    output preg_t             prf_wb_pnew_o,
    output rob_idx_t          prf_wb_rob_idx_o,
    output rob_epoch_t        prf_wb_rob_epoch_o,
    output logic [4:0]        prf_wb_fflags_o,

    // Buffer Backpressure Status
    output logic              fprf_busy_o,
    output logic              prf_busy_o
);

    localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;
    localparam logic [63:0] FP64_QNAN = 64'h7FF8_0000_0000_0000;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic is_nanbox_valid(input logic [63:0] val);
        return (val[63:32] == 32'hFFFF_FFFF);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    function automatic logic fp_round_up(
        input logic [2:0] rm,
        input logic       sign,
        input logic       lsb,
        input logic       guard,
        input logic       sticky
    );
        logic inexact;
        inexact = guard || sticky;
        case (rm)
            3'b000: return guard && (sticky || lsb); // RNE
            3'b001: return 1'b0;                     // RTZ
            3'b010: return sign && inexact;          // RDN
            3'b011: return !sign && inexact;         // RUP
            3'b100: return guard;                    // RMM
            default: return guard && (sticky || lsb);
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // 1. Float-to-Float & Min/Max/Sign-Injection (Direct to FPRF w0_fp)
    // -------------------------------------------------------------------------
    logic        p4_to_fprf_valid;
    logic [63:0] p4_to_fprf_data;
    logic [4:0]  p4_to_fprf_fflags;
    fpreg_t      p4_to_fprf_prd_fp;
    rob_idx_t    p4_to_fprf_rob_idx;
    rob_epoch_t  p4_to_fprf_rob_epoch;

    always_comb begin
        logic [2:0] eff_rm;
        logic [31:0] sgnj_op1;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [31:0] sgnj_op2;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [31:0] min_op1, min_op2;
        logic min_nan1, min_nan2, min_snan1, min_snan2, min_less;
        logic min_s;
        logic min_pick_op1;
        logic f2f_s;
        logic [10:0] f2f_e;
        logic [51:0] f2f_f;
        logic signed [13:0] f2f_exp_sp;
        logic [24:0] f2f_mant_sp;
        logic f2f_guard, f2f_round_bit, f2f_sticky_bit, f2f_inexact, f2f_round_up, f2f_overflow, f2f_underflow;
        logic [7:0] f2f_final_exp;
        logic signed [13:0] f2f_shift;
        logic [54:0] f2f_tmp;
        logic [31:0] f2f_op;
        int f2f_lzc;
        logic [22:0] f2f_sh_f;
        logic [10:0] f2f_new_exp;

        eff_rm = (p4_req_frm_i == 3'b111) ? fcsr_frm_i : p4_req_frm_i;
        sgnj_op1 = '0; sgnj_op2 = '0;
        min_op1 = '0; min_op2 = '0;
        min_nan1 = '0; min_nan2 = '0; min_snan1 = '0; min_snan2 = '0; min_less = '0;
        min_s = '0; min_pick_op1 = '0;
        f2f_s = '0; f2f_e = '0; f2f_f = '0;
        f2f_exp_sp = '0; f2f_mant_sp = '0;
        f2f_guard = '0; f2f_round_bit = '0; f2f_sticky_bit = '0;
        f2f_inexact = '0; f2f_round_up = '0; f2f_overflow = '0; f2f_underflow = '0;
        f2f_final_exp = '0; f2f_shift = '0; f2f_tmp = '0;
        f2f_op = '0; f2f_lzc = 0; f2f_sh_f = '0; f2f_new_exp = '0;

        p4_to_fprf_valid     = 1'b0;
        p4_to_fprf_data      = '0;
        p4_to_fprf_fflags    = '0;
        p4_to_fprf_prd_fp    = p4_req_prd_fp_i;
        p4_to_fprf_rob_idx   = p4_req_rob_idx_i;
        p4_to_fprf_rob_epoch = p4_req_rob_epoch_i;

        if (p4_req_valid_i && p4_req_fp_dest_valid_i) begin
            case (p4_req_subop_i)
                FP_FCVT_S_D: begin
                    // Narrowing 64-bit float to 32-bit float
                    f2f_s = p4_req_rs1_fp_data_i[63]; f2f_e = p4_req_rs1_fp_data_i[62:52]; f2f_f = p4_req_rs1_fp_data_i[51:0];
                    p4_to_fprf_valid = 1'b1;
                    if (f2f_e == 11'h7FF) begin
                        if (f2f_f != 52'd0) begin
                            // NaN
                            p4_to_fprf_data   = {32'hFFFF_FFFF, FP32_QNAN};
                            p4_to_fprf_fflags = !f2f_f[51] ? 5'b10000 : 5'b00000; // NV on sNaN
                        end else begin
                            // Infinity
                            p4_to_fprf_data   = {32'hFFFF_FFFF, f2f_s, 8'hFF, 23'd0};
                            p4_to_fprf_fflags = 5'b00000;
                        end
                    end else if (f2f_e == 11'd0 && f2f_f == 52'd0) begin
                        p4_to_fprf_data   = {32'hFFFF_FFFF, f2f_s, 31'd0};
                        p4_to_fprf_fflags = 5'b00000;
                    end else begin
                        // Normal / subnormal conversion with rounding
                        f2f_exp_sp = signed'(14'(f2f_e)) - 14'sd1023 + 14'sd127;
                        f2f_mant_sp = {2'b01, f2f_f[51:29]};
                        f2f_guard   = f2f_f[28];
                        f2f_round_bit = f2f_f[27];
                        f2f_sticky_bit = (f2f_f[26:0] != 27'd0);

                        if (f2f_exp_sp <= 14'sd0) begin
                            f2f_shift = 14'sd1 - f2f_exp_sp;
                            if (f2f_shift > 14'sd30) begin
                                f2f_mant_sp = '0; f2f_guard = 1'b0; f2f_round_bit = 1'b0; f2f_sticky_bit = 1'b1;
                            end else begin
                                f2f_tmp = {f2f_mant_sp[23:0], f2f_guard, f2f_round_bit, 29'd0} >> f2f_shift;
                                f2f_mant_sp   = {1'b0, f2f_tmp[54:31]};
                                f2f_guard     = f2f_tmp[30];
                                f2f_round_bit = f2f_tmp[29];
                                f2f_sticky_bit = f2f_sticky_bit || (f2f_tmp[28:0] != 29'd0);
                            end
                            f2f_exp_sp = 14'sd0;
                        end

                        f2f_inexact = f2f_guard || f2f_round_bit || f2f_sticky_bit;
                        f2f_round_up = 1'b0;
                        case (eff_rm)
                            3'b000: f2f_round_up = f2f_guard && (f2f_round_bit || f2f_sticky_bit || f2f_mant_sp[0]);
                            3'b001: f2f_round_up = 1'b0;
                            3'b010: f2f_round_up = f2f_s && f2f_inexact;
                            3'b011: f2f_round_up = !f2f_s && f2f_inexact;
                            3'b100: f2f_round_up = f2f_guard;
                            default: f2f_round_up = f2f_guard && (f2f_round_bit || f2f_sticky_bit || f2f_mant_sp[0]);
                        endcase

                        if (f2f_round_up) begin
                            f2f_mant_sp = f2f_mant_sp + 25'd1;
                            if (f2f_mant_sp[23] && (f2f_exp_sp == 14'sd0)) f2f_exp_sp = 14'sd1;
                            else if (f2f_mant_sp == 25'h100_0000) begin
                                f2f_mant_sp = f2f_mant_sp >> 1;
                                f2f_exp_sp  = f2f_exp_sp + 14'sd1;
                            end
                        end

                        f2f_overflow = 1'b0; f2f_underflow = 1'b0;
                        if (f2f_exp_sp >= 14'sd255) begin
                            f2f_overflow = 1'b1; f2f_inexact = 1'b1;
                            f2f_final_exp = 8'hFF; f2f_mant_sp = 25'd0;
                        end else if (f2f_exp_sp == 14'sd0) begin
                            f2f_final_exp = 8'd0;
                            if (f2f_inexact) f2f_underflow = 1'b1;
                        end else begin
                            f2f_final_exp = f2f_exp_sp[7:0];
                        end

                        p4_to_fprf_data   = {32'hFFFF_FFFF, f2f_s, f2f_final_exp, f2f_mant_sp[22:0]};
                        p4_to_fprf_fflags = {1'b0, 1'b0, f2f_overflow, f2f_underflow, f2f_inexact};
                    end
                end

                FP_FCVT_D_S: begin
                    // Widening 32-bit float to 64-bit float
                    f2f_op = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    f2f_s = f2f_op[31]; f2f_e = {3'd0, f2f_op[30:23]}; f2f_f = {f2f_op[22:0], 29'd0};
                    p4_to_fprf_valid = 1'b1;

                    if (f2f_e[7:0] == 8'hFF) begin
                        if (f2f_f[51:29] != 23'd0) begin
                            p4_to_fprf_data   = FP64_QNAN;
                            p4_to_fprf_fflags = !f2f_f[51] ? 5'b10000 : 5'b00000;
                        end else begin
                            p4_to_fprf_data   = {f2f_s, 11'h7FF, 52'd0};
                            p4_to_fprf_fflags = 5'b00000;
                        end
                    end else if (f2f_e[7:0] == 8'd0) begin
                        if (f2f_f[51:29] == 23'd0) begin
                            p4_to_fprf_data   = {f2f_s, 63'd0};
                            p4_to_fprf_fflags = 5'b00000;
                        end else begin
                            // Subnormal widening: normalize mantissa
                            f2f_lzc = 0;
                            for (int k = 22; k >= 0; k--) begin
                                if (f2f_f[29 + k]) begin f2f_lzc = 22 - k; break; end
                            end
                            f2f_sh_f    = f2f_f[51:29] << (f2f_lzc + 1);
                            f2f_new_exp = 11'd1023 - 11'd126 - 11'(f2f_lzc);
                            p4_to_fprf_data   = {f2f_s, f2f_new_exp, f2f_sh_f, 29'd0};
                            p4_to_fprf_fflags = 5'b00000;
                        end
                    end else begin
                        // Normal exact widening
                        f2f_new_exp = 11'(f2f_e[7:0]) - 11'd127 + 11'd1023;
                        p4_to_fprf_data   = {f2f_s, f2f_new_exp, f2f_f};
                        p4_to_fprf_fflags = 5'b00000;
                    end
                end

                // Sign Injection
                FP_FSGNJ_S: begin
                    sgnj_op1 = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    sgnj_op2 = is_nanbox_valid(p4_req_rs2_fp_data_i) ? p4_req_rs2_fp_data_i[31:0] : FP32_QNAN;
                    p4_to_fprf_valid = 1'b1;
                    p4_to_fprf_data  = {32'hFFFF_FFFF, sgnj_op2[31], sgnj_op1[30:0]};
                end
                FP_FSGNJN_S: begin
                    sgnj_op1 = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    sgnj_op2 = is_nanbox_valid(p4_req_rs2_fp_data_i) ? p4_req_rs2_fp_data_i[31:0] : FP32_QNAN;
                    p4_to_fprf_valid = 1'b1;
                    p4_to_fprf_data  = {32'hFFFF_FFFF, ~sgnj_op2[31], sgnj_op1[30:0]};
                end
                FP_FSGNJX_S: begin
                    sgnj_op1 = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    sgnj_op2 = is_nanbox_valid(p4_req_rs2_fp_data_i) ? p4_req_rs2_fp_data_i[31:0] : FP32_QNAN;
                    p4_to_fprf_valid = 1'b1;
                    p4_to_fprf_data  = {32'hFFFF_FFFF, sgnj_op1[31] ^ sgnj_op2[31], sgnj_op1[30:0]};
                end
                FP_FSGNJ_D: begin
                    p4_to_fprf_valid = 1'b1;
                    p4_to_fprf_data  = {p4_req_rs2_fp_data_i[63], p4_req_rs1_fp_data_i[62:0]};
                end
                FP_FSGNJN_D: begin
                    p4_to_fprf_valid = 1'b1;
                    p4_to_fprf_data  = {~p4_req_rs2_fp_data_i[63], p4_req_rs1_fp_data_i[62:0]};
                end
                FP_FSGNJX_D: begin
                    p4_to_fprf_valid = 1'b1;
                    p4_to_fprf_data  = {p4_req_rs1_fp_data_i[63] ^ p4_req_rs2_fp_data_i[63], p4_req_rs1_fp_data_i[62:0]};
                end

                // Min / Max
                FP_FMIN_S, FP_FMAX_S: begin
                    min_op1 = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    min_op2 = is_nanbox_valid(p4_req_rs2_fp_data_i) ? p4_req_rs2_fp_data_i[31:0] : FP32_QNAN;
                    min_nan1  = (min_op1[30:23] == 8'hFF) && (min_op1[22:0] != 23'd0);
                    min_snan1 = min_nan1 && !min_op1[22];
                    min_nan2  = (min_op2[30:23] == 8'hFF) && (min_op2[22:0] != 23'd0);
                    min_snan2 = min_nan2 && !min_op2[22];

                    if (min_op1[31] != min_op2[31]) begin
                        min_less = min_op1[31] && !((min_op1[30:0] == 31'd0) && (min_op2[30:0] == 31'd0));
                    end else if (min_op1[31]) begin
                        min_less = (min_op1[30:0] > min_op2[30:0]);
                    end else begin
                        min_less = (min_op1[30:0] < min_op2[30:0]);
                    end

                    p4_to_fprf_valid  = 1'b1;
                    p4_to_fprf_fflags = (min_snan1 || min_snan2) ? 5'b10000 : 5'b00000;

                    if (min_nan1 && min_nan2) begin
                        p4_to_fprf_data = {32'hFFFF_FFFF, FP32_QNAN};
                    end else if (min_nan1) begin
                        p4_to_fprf_data = {32'hFFFF_FFFF, min_op2};
                    end else if (min_nan2) begin
                        p4_to_fprf_data = {32'hFFFF_FFFF, min_op1};
                    end else if ((min_op1[30:0] == 31'd0) && (min_op2[30:0] == 31'd0)) begin
                        // Zeros: FMIN(-0, +0) = -0, FMAX(-0, +0) = +0
                        min_s = (p4_req_subop_i == FP_FMIN_S) ? (min_op1[31] || min_op2[31]) : (min_op1[31] && min_op2[31]);
                        p4_to_fprf_data = {32'hFFFF_FFFF, min_s, 31'd0};
                    end else begin
                        min_pick_op1 = (p4_req_subop_i == FP_FMIN_S) ? min_less : !min_less;
                        p4_to_fprf_data = {32'hFFFF_FFFF, min_pick_op1 ? min_op1 : min_op2};
                    end
                end

                FP_FMIN_D, FP_FMAX_D: begin
                    min_nan1  = (p4_req_rs1_fp_data_i[62:52] == 11'h7FF) && (p4_req_rs1_fp_data_i[51:0] != 52'd0);
                    min_snan1 = min_nan1 && !p4_req_rs1_fp_data_i[51];
                    min_nan2  = (p4_req_rs2_fp_data_i[62:52] == 11'h7FF) && (p4_req_rs2_fp_data_i[51:0] != 52'd0);
                    min_snan2 = min_nan2 && !p4_req_rs2_fp_data_i[51];

                    if (p4_req_rs1_fp_data_i[63] != p4_req_rs2_fp_data_i[63]) begin
                        min_less = p4_req_rs1_fp_data_i[63] && !((p4_req_rs1_fp_data_i[62:0] == 63'd0) && (p4_req_rs2_fp_data_i[62:0] == 63'd0));
                    end else if (p4_req_rs1_fp_data_i[63]) begin
                        min_less = (p4_req_rs1_fp_data_i[62:0] > p4_req_rs2_fp_data_i[62:0]);
                    end else begin
                        min_less = (p4_req_rs1_fp_data_i[62:0] < p4_req_rs2_fp_data_i[62:0]);
                    end

                    p4_to_fprf_valid  = 1'b1;
                    p4_to_fprf_fflags = (min_snan1 || min_snan2) ? 5'b10000 : 5'b00000;

                    if (min_nan1 && min_nan2) begin
                        p4_to_fprf_data = FP64_QNAN;
                    end else if (min_nan1) begin
                        p4_to_fprf_data = p4_req_rs2_fp_data_i;
                    end else if (min_nan2) begin
                        p4_to_fprf_data = p4_req_rs1_fp_data_i;
                    end else if ((p4_req_rs1_fp_data_i[62:0] == 63'd0) && (p4_req_rs2_fp_data_i[62:0] == 63'd0)) begin
                        min_s = (p4_req_subop_i == FP_FMIN_D) ? (p4_req_rs1_fp_data_i[63] || p4_req_rs2_fp_data_i[63]) : (p4_req_rs1_fp_data_i[63] && p4_req_rs2_fp_data_i[63]);
                        p4_to_fprf_data = {min_s, 63'd0};
                    end else begin
                        min_pick_op1 = (p4_req_subop_i == FP_FMIN_D) ? min_less : !min_less;
                        p4_to_fprf_data = min_pick_op1 ? p4_req_rs1_fp_data_i : p4_req_rs2_fp_data_i;
                    end
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 2. Integer-to-Float Moves & Conversions (from Port 0/1 to FPRF w0_fp)
    // -------------------------------------------------------------------------
    logic        int2fp_out_valid;
    logic [63:0] int2fp_out_data;
    logic [4:0]  int2fp_out_fflags;
    fpreg_t      int2fp_out_prd_fp;
    rob_idx_t    int2fp_out_rob_idx;
    rob_epoch_t  int2fp_out_rob_epoch;

    always_comb begin
        logic [2:0]  i2f_rm;
        logic        i2f_is_64;
        logic        i2f_is_signed;
        logic        i2f_s;
        logic [63:0] i2f_mag;
        int          i2f_lzc;
        logic [63:0] i2f_sh_m;
        logic [7:0]  exp_sp;
        logic [24:0] mant_sp;
        logic        guard_sp, sticky_sp, inexact_sp, rup_sp;
        logic [10:0] exp_dp;
        logic [53:0] mant_dp;
        logic        guard_dp, sticky_dp, inexact_dp, rup_dp;

        i2f_rm        = (int2fp_req_frm_i == 3'b111) ? fcsr_frm_i : int2fp_req_frm_i;
        i2f_is_64     = 1'b0;
        i2f_is_signed = 1'b0;
        i2f_s         = 1'b0;
        i2f_mag       = 64'd0;
        i2f_lzc       = 0;
        i2f_sh_m      = 64'd0;
        exp_sp        = '0; mant_sp = '0; guard_sp = '0; sticky_sp = '0; inexact_sp = '0; rup_sp = '0;
        exp_dp        = '0; mant_dp = '0; guard_dp = '0; sticky_dp = '0; inexact_dp = '0; rup_dp = '0;

        int2fp_out_valid     = 1'b0;
        int2fp_out_data      = '0;
        int2fp_out_fflags    = '0;
        int2fp_out_prd_fp    = int2fp_req_prd_fp_i;
        int2fp_out_rob_idx   = int2fp_req_rob_idx_i;
        int2fp_out_rob_epoch = int2fp_req_rob_epoch_i;

        if (int2fp_req_valid_i) begin
            case (int2fp_req_subop_i)
                FP_FMV_W_X: begin
                    int2fp_out_valid  = 1'b1;
                    int2fp_out_data   = {32'hFFFF_FFFF, int2fp_req_int_data_i[31:0]}; // NaN-boxed
                    int2fp_out_fflags = 5'b00000;
                end
                FP_FMV_D_X: begin
                    int2fp_out_valid  = 1'b1;
                    int2fp_out_data   = int2fp_req_int_data_i;
                    int2fp_out_fflags = 5'b00000;
                end
                FP_FCVT_S_W, FP_FCVT_S_WU, FP_FCVT_S_L, FP_FCVT_S_LU,
                FP_FCVT_D_W, FP_FCVT_D_WU, FP_FCVT_D_L, FP_FCVT_D_LU: begin
                    i2f_is_64     = (int2fp_req_subop_i == FP_FCVT_S_L)  || (int2fp_req_subop_i == FP_FCVT_S_LU) ||
                                    (int2fp_req_subop_i == FP_FCVT_D_L)  || (int2fp_req_subop_i == FP_FCVT_D_LU);
                    i2f_is_signed = (int2fp_req_subop_i == FP_FCVT_S_W)  || (int2fp_req_subop_i == FP_FCVT_S_L)  ||
                                    (int2fp_req_subop_i == FP_FCVT_D_W)  || (int2fp_req_subop_i == FP_FCVT_D_L);
                    if (i2f_is_64) begin
                        i2f_s   = i2f_is_signed && int2fp_req_int_data_i[63];
                        i2f_mag = i2f_s ? unsigned'(-signed'(int2fp_req_int_data_i)) : int2fp_req_int_data_i;
                    end else begin
                        i2f_s   = i2f_is_signed && int2fp_req_int_data_i[31];
                        i2f_mag = i2f_s ? {32'd0, unsigned'(-signed'(int2fp_req_int_data_i[31:0]))}
                                        : {32'd0, int2fp_req_int_data_i[31:0]};
                    end

                    int2fp_out_valid = 1'b1;
                    if (i2f_mag == 64'd0) begin
                        if ((int2fp_req_subop_i == FP_FCVT_S_W) || (int2fp_req_subop_i == FP_FCVT_S_WU) ||
                            (int2fp_req_subop_i == FP_FCVT_S_L) || (int2fp_req_subop_i == FP_FCVT_S_LU))
                            int2fp_out_data = {32'hFFFF_FFFF, 32'd0};
                        else
                            int2fp_out_data = 64'd0;
                        int2fp_out_fflags = 5'b00000;
                    end else begin
                        i2f_lzc = 0;
                        for (int k = 63; k >= 0; k--) begin
                            if (i2f_mag[k]) begin i2f_lzc = 63 - k; break; end
                        end
                        i2f_sh_m = i2f_mag << i2f_lzc;

                        if ((int2fp_req_subop_i == FP_FCVT_S_W) || (int2fp_req_subop_i == FP_FCVT_S_WU) ||
                            (int2fp_req_subop_i == FP_FCVT_S_L) || (int2fp_req_subop_i == FP_FCVT_S_LU)) begin
                            exp_sp     = 8'(127 + 63 - i2f_lzc);
                            mant_sp    = {1'b0, i2f_sh_m[63:40]};
                            guard_sp   = i2f_sh_m[39];
                            sticky_sp  = (i2f_sh_m[38:0] != 39'd0);
                            inexact_sp = guard_sp || sticky_sp;
                            rup_sp     = fp_round_up(i2f_rm, i2f_s, mant_sp[0], guard_sp, sticky_sp);
                            if (rup_sp) begin
                                mant_sp = mant_sp + 25'd1;
                                if (mant_sp[24]) begin mant_sp = mant_sp >> 1; exp_sp = exp_sp + 8'd1; end
                            end
                            int2fp_out_data   = {32'hFFFF_FFFF, i2f_s, exp_sp, mant_sp[22:0]};
                            int2fp_out_fflags = {4'b0000, inexact_sp};
                        end else begin
                            exp_dp     = 11'(1023 + 63 - i2f_lzc);
                            mant_dp    = {1'b0, i2f_sh_m[63:11]};
                            guard_dp   = i2f_sh_m[10];
                            sticky_dp  = (i2f_sh_m[9:0] != 10'd0);
                            inexact_dp = guard_dp || sticky_dp;
                            rup_dp     = fp_round_up(i2f_rm, i2f_s, mant_dp[0], guard_dp, sticky_dp);
                            if (rup_dp) begin
                                mant_dp = mant_dp + 54'd1;
                                if (mant_dp[53]) begin mant_dp = mant_dp >> 1; exp_dp = exp_dp + 11'd1; end
                            end
                            int2fp_out_data   = {i2f_s, exp_dp, mant_dp[51:0]};
                            int2fp_out_fflags = {4'b0000, inexact_dp};
                        end
                    end
                end
                default: ;
            endcase
        end
    end

    // Lossless circular writeback FIFO for FPRF w0_fp (8 entries)
    localparam int FPRF_FIFO_DEPTH = 8;
    typedef struct packed {
        logic        valid;
        logic [63:0] data;
        fpreg_t      prd_fp;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
        logic [4:0]  fflags;
    } fconv_fprf_buf_t;

    fconv_fprf_buf_t fprf_fifo [FPRF_FIFO_DEPTH];
    logic [2:0] fprf_head;
    logic [2:0] fprf_tail;
    logic [3:0] fprf_count;

    assign fprf_busy_o = (fprf_count >= 4'd6);

    wire fprf_pop = (fprf_count > 4'd0) && (!fprf_fifo[fprf_head].valid || !fprf_wb_busy_i);

    assign fprf_wb_valid_o     = (fprf_count > 4'd0) && fprf_fifo[fprf_head].valid && !fprf_wb_busy_i;
    assign fprf_wb_data_o      = fprf_fifo[fprf_head].data;
    assign fprf_wb_prd_fp_o    = fprf_fifo[fprf_head].prd_fp;
    assign fprf_wb_rob_idx_o   = fprf_fifo[fprf_head].rob_idx;
    assign fprf_wb_rob_epoch_o = fprf_fifo[fprf_head].rob_epoch;
    assign fprf_wb_fflags_o    = fprf_fifo[fprf_head].fflags;

    fconv_fprf_buf_t push0_entry;
    assign push0_entry.valid     = 1'b1;
    assign push0_entry.data      = p4_to_fprf_data;
    assign push0_entry.prd_fp    = p4_to_fprf_prd_fp;
    assign push0_entry.rob_idx   = p4_to_fprf_rob_idx;
    assign push0_entry.rob_epoch = p4_to_fprf_rob_epoch;
    assign push0_entry.fflags    = p4_to_fprf_fflags;

    fconv_fprf_buf_t push1_entry;
    assign push1_entry.valid     = 1'b1;
    assign push1_entry.data      = int2fp_out_data;
    assign push1_entry.prd_fp    = int2fp_out_prd_fp;
    assign push1_entry.rob_idx   = int2fp_out_rob_idx;
    assign push1_entry.rob_epoch = int2fp_out_rob_epoch;
    assign push1_entry.fflags    = int2fp_out_fflags;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            for (int k = 0; k < FPRF_FIFO_DEPTH; k++) begin
                fprf_fifo[k] <= '0;
            end
            fprf_head  <= 3'd0;
            fprf_tail  <= 3'd0;
            fprf_count <= 4'd0;
        end else begin
            // 1. Branch misprediction recovery squashes
            if (recover_valid_i) begin
                for (int k = 0; k < FPRF_FIFO_DEPTH; k++) begin
                    if (fprf_fifo[k].valid && (rob_dist(fprf_fifo[k].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        fprf_fifo[k].valid <= 1'b0;
                    end
                end
            end

            // 2. FIFO update (Pop and Push)
            begin : blk_fprf_fifo
                logic [2:0] cur_head;
                logic [2:0] cur_tail;
                logic [3:0] cur_count;
                logic       push0_squashed, push1_squashed;

                cur_head  = fprf_head;
                cur_tail  = fprf_tail;
                cur_count = fprf_count;

                if (fprf_pop) begin
                    fprf_fifo[cur_head].valid <= 1'b0;
                    cur_head  = cur_head + 3'd1;
                    cur_count = cur_count - 4'd1;
                end

                push0_squashed = recover_valid_i && (rob_dist(push0_entry.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
                push1_squashed = recover_valid_i && (rob_dist(push1_entry.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

                case ({p4_to_fprf_valid && !push0_squashed, int2fp_out_valid && !push1_squashed})
                    2'b11: begin
                        fprf_fifo[cur_tail]        <= push0_entry;
                        fprf_fifo[cur_tail + 3'd1] <= push1_entry;
                        cur_tail  = cur_tail + 3'd2;
                        cur_count = cur_count + 4'd2;
                    end
                    2'b10: begin
                        fprf_fifo[cur_tail]        <= push0_entry;
                        cur_tail  = cur_tail + 3'd1;
                        cur_count = cur_count + 4'd1;
                    end
                    2'b01: begin
                        fprf_fifo[cur_tail]        <= push1_entry;
                        cur_tail  = cur_tail + 3'd1;
                        cur_count = cur_count + 4'd1;
                    end
                    default: ;
                endcase

                fprf_head  <= cur_head;
                fprf_tail  <= cur_tail;
                fprf_count <= cur_count;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. Float-to-Integer Move, Conversion & Comparison (Writing to Integer PRF)
    // -------------------------------------------------------------------------
    logic        f2i_comb_valid;
    logic [63:0] f2i_comb_data;
    logic [4:0]  f2i_comb_fflags;
    preg_t       f2i_comb_pnew;
    rob_idx_t    f2i_comb_rob_idx;
    rob_epoch_t  f2i_comb_rob_epoch;

    always_comb begin
        logic [31:0] cmp_s_op1, cmp_s_op2;
        logic cmp_nan1, cmp_nan2, cmp_snan1, cmp_snan2, cmp_eq, cmp_lt;
        logic [31:0] fclass_op;
        logic fclass_s;
        logic [10:0] fclass_e;
        logic [51:0] fclass_f;
        logic [9:0]  fclass_mask;
        logic [2:0]  f2i_rm;
        logic        fcvt_is_sp, fcvt_is_64, fcvt_is_signed;
        logic        fcvt_s, fcvt_is_nan, fcvt_is_inf, fcvt_is_zero;
        logic signed [13:0] fcvt_exp;
        logic [52:0] fcvt_sig;
        logic [63:0] fcvt_sat_val;
        logic [63:0] fcvt_int_mag;
        logic        fcvt_g, fcvt_st, fcvt_inc, fcvt_inexact, fcvt_in_range;
        logic [64:0] fcvt_rmag;
        logic [63:0] fcvt_sres;
        logic [31:0] sp_in;
        int unsigned fcvt_rsh;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [52:0] fcvt_rem_bits;
        /* verilator lint_on UNUSEDSIGNAL */

        cmp_s_op1 = '0; cmp_s_op2 = '0;
        cmp_nan1 = '0; cmp_nan2 = '0; cmp_snan1 = '0; cmp_snan2 = '0; cmp_eq = '0; cmp_lt = '0;
        fclass_op = '0; fclass_s = '0; fclass_e = '0; fclass_f = '0; fclass_mask = '0;
        f2i_rm = (p4_req_frm_i == 3'b111) ? fcsr_frm_i : p4_req_frm_i;
        fcvt_is_sp = '0; fcvt_is_64 = '0; fcvt_is_signed = '0;
        fcvt_s = '0; fcvt_is_nan = '0; fcvt_is_inf = '0; fcvt_is_zero = '0;
        fcvt_exp = '0; fcvt_sig = '0; fcvt_sat_val = '0; fcvt_int_mag = '0;
        fcvt_g = '0; fcvt_st = '0; fcvt_inc = '0; fcvt_inexact = '0; fcvt_in_range = '0;
        fcvt_rmag = '0; fcvt_sres = '0;
        sp_in = '0; fcvt_rsh = 0; fcvt_rem_bits = '0;

        f2i_comb_valid     = 1'b0;
        f2i_comb_data      = '0;
        f2i_comb_fflags    = '0;
        f2i_comb_pnew      = p4_req_pnew_i;
        f2i_comb_rob_idx   = p4_req_rob_idx_i;
        f2i_comb_rob_epoch = p4_req_rob_epoch_i;

        if (p4_req_valid_i && !p4_req_fp_dest_valid_i) begin
            case (p4_req_subop_i)
                FP_FMV_X_W: begin
                    // Per RISC-V §11.6: sign-extended to 64 bits!
                    f2i_comb_valid  = 1'b1;
                    f2i_comb_data   = {{32{p4_req_rs1_fp_data_i[31]}}, p4_req_rs1_fp_data_i[31:0]};
                    f2i_comb_fflags = 5'b00000;
                end
                FP_FMV_X_D: begin
                    f2i_comb_valid  = 1'b1;
                    f2i_comb_data   = p4_req_rs1_fp_data_i;
                    f2i_comb_fflags = 5'b00000;
                end

                // FP Comparisons (FEQ, FLT, FLE)
                FP_FEQ_S, FP_FLT_S, FP_FLE_S: begin
                    cmp_s_op1 = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    cmp_s_op2 = is_nanbox_valid(p4_req_rs2_fp_data_i) ? p4_req_rs2_fp_data_i[31:0] : FP32_QNAN;

                    cmp_nan1  = (cmp_s_op1[30:23] == 8'hFF) && (cmp_s_op1[22:0] != 23'd0);
                    cmp_snan1 = cmp_nan1 && !cmp_s_op1[22];
                    cmp_nan2  = (cmp_s_op2[30:23] == 8'hFF) && (cmp_s_op2[22:0] != 23'd0);
                    cmp_snan2 = cmp_nan2 && !cmp_s_op2[22];

                    cmp_eq = ((cmp_s_op1 == cmp_s_op2) || ((cmp_s_op1[30:0] == 31'd0) && (cmp_s_op2[30:0] == 31'd0))) && !cmp_nan1 && !cmp_nan2;

                    if (cmp_s_op1[31] != cmp_s_op2[31]) begin
                        cmp_lt = cmp_s_op1[31] && !((cmp_s_op1[30:0] == 31'd0) && (cmp_s_op2[30:0] == 31'd0));
                    end else if (cmp_s_op1[31]) begin
                        cmp_lt = (cmp_s_op1[30:0] > cmp_s_op2[30:0]);
                    end else begin
                        cmp_lt = (cmp_s_op1[30:0] < cmp_s_op2[30:0]);
                    end
                    if (cmp_nan1 || cmp_nan2) cmp_lt = 1'b0;

                    f2i_comb_valid = 1'b1;
                    if (p4_req_subop_i == FP_FEQ_S) begin
                        f2i_comb_data   = cmp_eq ? 64'd1 : 64'd0;
                        f2i_comb_fflags = (cmp_snan1 || cmp_snan2) ? 5'b10000 : 5'b00000; // NV only on sNaN
                    end else if (p4_req_subop_i == FP_FLT_S) begin
                        f2i_comb_data   = cmp_lt ? 64'd1 : 64'd0;
                        f2i_comb_fflags = (cmp_nan1 || cmp_nan2) ? 5'b10000 : 5'b00000; // NV on any NaN
                    end else begin // FLE_S
                        f2i_comb_data   = (cmp_lt || cmp_eq) ? 64'd1 : 64'd0;
                        f2i_comb_fflags = (cmp_nan1 || cmp_nan2) ? 5'b10000 : 5'b00000;
                    end
                end

                FP_FEQ_D, FP_FLT_D, FP_FLE_D: begin
                    cmp_nan1  = (p4_req_rs1_fp_data_i[62:52] == 11'h7FF) && (p4_req_rs1_fp_data_i[51:0] != 52'd0);
                    cmp_snan1 = cmp_nan1 && !p4_req_rs1_fp_data_i[51];
                    cmp_nan2  = (p4_req_rs2_fp_data_i[62:52] == 11'h7FF) && (p4_req_rs2_fp_data_i[51:0] != 52'd0);
                    cmp_snan2 = cmp_nan2 && !p4_req_rs2_fp_data_i[51];

                    cmp_eq = ((p4_req_rs1_fp_data_i == p4_req_rs2_fp_data_i) ||
                              ((p4_req_rs1_fp_data_i[62:0] == 63'd0) && (p4_req_rs2_fp_data_i[62:0] == 63'd0))) && !cmp_nan1 && !cmp_nan2;

                    if (p4_req_rs1_fp_data_i[63] != p4_req_rs2_fp_data_i[63]) begin
                        cmp_lt = p4_req_rs1_fp_data_i[63] && !((p4_req_rs1_fp_data_i[62:0] == 63'd0) && (p4_req_rs2_fp_data_i[62:0] == 63'd0));
                    end else if (p4_req_rs1_fp_data_i[63]) begin
                        cmp_lt = (p4_req_rs1_fp_data_i[62:0] > p4_req_rs2_fp_data_i[62:0]);
                    end else begin
                        cmp_lt = (p4_req_rs1_fp_data_i[62:0] < p4_req_rs2_fp_data_i[62:0]);
                    end
                    if (cmp_nan1 || cmp_nan2) cmp_lt = 1'b0;

                    f2i_comb_valid = 1'b1;
                    if (p4_req_subop_i == FP_FEQ_D) begin
                        f2i_comb_data   = cmp_eq ? 64'd1 : 64'd0;
                        f2i_comb_fflags = (cmp_snan1 || cmp_snan2) ? 5'b10000 : 5'b00000;
                    end else if (p4_req_subop_i == FP_FLT_D) begin
                        f2i_comb_data   = cmp_lt ? 64'd1 : 64'd0;
                        f2i_comb_fflags = (cmp_nan1 || cmp_nan2) ? 5'b10000 : 5'b00000;
                    end else begin // FLE_D
                        f2i_comb_data   = (cmp_lt || cmp_eq) ? 64'd1 : 64'd0;
                        f2i_comb_fflags = (cmp_nan1 || cmp_nan2) ? 5'b10000 : 5'b00000;
                    end
                end

                // FCLASS (10-bit mask)
                FP_FCLASS_S: begin
                    fclass_op = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    fclass_s = fclass_op[31]; fclass_e = {3'd0, fclass_op[30:23]}; fclass_f = {fclass_op[22:0], 29'd0};
                    fclass_mask = 10'd0;
                    if (fclass_op[30:23] == 8'hFF) begin
                        if (fclass_op[22:0] != 23'd0) begin
                            fclass_mask[8] = !fclass_op[22]; // sNaN
                            fclass_mask[9] = fclass_op[22];  // qNaN
                        end else begin
                            fclass_mask[0] = fclass_s;  // -inf
                            fclass_mask[7] = !fclass_s; // +inf
                        end
                    end else if (fclass_op[30:23] == 8'd0) begin
                        if (fclass_op[22:0] == 23'd0) begin
                            fclass_mask[3] = fclass_s;  // -0
                            fclass_mask[4] = !fclass_s; // +0
                        end else begin
                            fclass_mask[2] = fclass_s;  // -subnormal
                            fclass_mask[5] = !fclass_s; // +subnormal
                        end
                    end else begin
                        fclass_mask[1] = fclass_s;  // -normal
                        fclass_mask[6] = !fclass_s; // +normal
                    end
                    f2i_comb_valid  = 1'b1;
                    f2i_comb_data   = {54'd0, fclass_mask};
                    f2i_comb_fflags = 5'b00000;
                end

                FP_FCLASS_D: begin
                    fclass_s = p4_req_rs1_fp_data_i[63]; fclass_e = p4_req_rs1_fp_data_i[62:52]; fclass_f = p4_req_rs1_fp_data_i[51:0];
                    fclass_mask = 10'd0;
                    if (fclass_e == 11'h7FF) begin
                        if (fclass_f != 52'd0) begin
                            fclass_mask[8] = !fclass_f[51]; // sNaN
                            fclass_mask[9] = fclass_f[51];  // qNaN
                        end else begin
                            fclass_mask[0] = fclass_s;  // -inf
                            fclass_mask[7] = !fclass_s; // +inf
                        end
                    end else if (fclass_e == 11'd0) begin
                        if (fclass_f == 52'd0) begin
                            fclass_mask[3] = fclass_s;  // -0
                            fclass_mask[4] = !fclass_s; // +0
                        end else begin
                            fclass_mask[2] = fclass_s;  // -subnormal
                            fclass_mask[5] = !fclass_s; // +subnormal
                        end
                    end else begin
                        fclass_mask[1] = fclass_s;  // -normal
                        fclass_mask[6] = !fclass_s; // +normal
                    end
                    f2i_comb_valid  = 1'b1;
                    f2i_comb_data   = {54'd0, fclass_mask};
                    f2i_comb_fflags = 5'b00000;
                end

                // FCVT.{W,WU,L,LU}.{S,D}
                FP_FCVT_W_S, FP_FCVT_WU_S, FP_FCVT_L_S, FP_FCVT_LU_S,
                FP_FCVT_W_D, FP_FCVT_WU_D, FP_FCVT_L_D, FP_FCVT_LU_D: begin
                    fcvt_is_sp     = (p4_req_subop_i == FP_FCVT_W_S)  || (p4_req_subop_i == FP_FCVT_WU_S) ||
                                     (p4_req_subop_i == FP_FCVT_L_S)  || (p4_req_subop_i == FP_FCVT_LU_S);
                    fcvt_is_64     = (p4_req_subop_i == FP_FCVT_L_S)  || (p4_req_subop_i == FP_FCVT_LU_S) ||
                                     (p4_req_subop_i == FP_FCVT_L_D)  || (p4_req_subop_i == FP_FCVT_LU_D);
                    fcvt_is_signed = (p4_req_subop_i == FP_FCVT_W_S)  || (p4_req_subop_i == FP_FCVT_L_S)  ||
                                     (p4_req_subop_i == FP_FCVT_W_D)  || (p4_req_subop_i == FP_FCVT_L_D);

                    if (fcvt_is_sp) begin
                        sp_in       = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                        fcvt_s      = sp_in[31];
                        fcvt_is_nan = (sp_in[30:23] == 8'hFF) && (sp_in[22:0] != 23'd0);
                        fcvt_is_inf = (sp_in[30:23] == 8'hFF) && (sp_in[22:0] == 23'd0);
                        fcvt_is_zero= (sp_in[30:23] == 8'd0)  && (sp_in[22:0] == 23'd0);
                        fcvt_exp    = (sp_in[30:23] == 8'd0)  ? -14'sd2 : (signed'(14'(sp_in[30:23])) - 14'sd127);
                        fcvt_sig    = {1'b1, sp_in[22:0], 29'd0};
                    end else begin
                        fcvt_s      = p4_req_rs1_fp_data_i[63];
                        fcvt_is_nan = (p4_req_rs1_fp_data_i[62:52] == 11'h7FF) && (p4_req_rs1_fp_data_i[51:0] != 52'd0);
                        fcvt_is_inf = (p4_req_rs1_fp_data_i[62:52] == 11'h7FF) && (p4_req_rs1_fp_data_i[51:0] == 52'd0);
                        fcvt_is_zero= (p4_req_rs1_fp_data_i[62:52] == 11'd0)   && (p4_req_rs1_fp_data_i[51:0] == 52'd0);
                        fcvt_exp    = (p4_req_rs1_fp_data_i[62:52] == 11'd0)   ? -14'sd2 : (signed'(14'(p4_req_rs1_fp_data_i[62:52])) - 14'sd1023);
                        fcvt_sig    = {1'b1, p4_req_rs1_fp_data_i[51:0]};
                    end

                    // Canonical saturation output on NV (NaN maps to positive max; -overflow to min)
                    if (!fcvt_is_64 && fcvt_is_signed)
                        fcvt_sat_val = (!fcvt_is_nan && fcvt_s) ? 64'hFFFF_FFFF_8000_0000 : 64'h0000_0000_7FFF_FFFF;
                    else if (!fcvt_is_64 && !fcvt_is_signed)
                        fcvt_sat_val = (!fcvt_is_nan && fcvt_s) ? 64'h0000_0000_0000_0000 : 64'hFFFF_FFFF_FFFF_FFFF;
                    else if (fcvt_is_64 && fcvt_is_signed)
                        fcvt_sat_val = (!fcvt_is_nan && fcvt_s) ? 64'h8000_0000_0000_0000 : 64'h7FFF_FFFF_FFFF_FFFF;
                    else
                        fcvt_sat_val = (!fcvt_is_nan && fcvt_s) ? 64'h0000_0000_0000_0000 : 64'hFFFF_FFFF_FFFF_FFFF;

                    f2i_comb_valid = 1'b1;
                    if (fcvt_is_nan || fcvt_is_inf || (fcvt_exp >= 14'sd64)) begin
                        f2i_comb_data   = fcvt_sat_val;
                        f2i_comb_fflags = 5'b10000; // NV
                    end else begin
                        if (fcvt_is_zero) begin
                            fcvt_int_mag = 64'd0; fcvt_g = 1'b0; fcvt_st = 1'b0;
                        end else if (fcvt_exp < -14'sd1) begin
                            // Subnormal or |x| < 0.5
                            fcvt_int_mag = 64'd0; fcvt_g = 1'b0; fcvt_st = 1'b1;
                        end else if (fcvt_exp == -14'sd1) begin
                            fcvt_int_mag = 64'd0; fcvt_g = fcvt_sig[52]; fcvt_st = (fcvt_sig[51:0] != 52'd0);
                        end else if (fcvt_exp <= 14'sd52) begin
                            fcvt_rsh = 32'(unsigned'(14'sd52 - fcvt_exp));
                            fcvt_int_mag = {11'd0, fcvt_sig} >> fcvt_rsh;
                            if (fcvt_rsh == 0) begin
                                fcvt_g = 1'b0; fcvt_st = 1'b0;
                            end else begin
                                fcvt_rem_bits = fcvt_sig << (53 - fcvt_rsh);
                                fcvt_g        = fcvt_rem_bits[52];
                                fcvt_st       = (fcvt_rem_bits[51:0] != 52'd0);
                            end
                        end else begin
                            fcvt_int_mag = {11'd0, fcvt_sig} << unsigned'(fcvt_exp - 14'sd52);
                            fcvt_g       = 1'b0; fcvt_st = 1'b0;
                        end

                        fcvt_inexact = fcvt_g || fcvt_st;
                        fcvt_inc     = fp_round_up(f2i_rm, fcvt_s, fcvt_int_mag[0], fcvt_g, fcvt_st);
                        fcvt_rmag    = {1'b0, fcvt_int_mag} + {64'd0, fcvt_inc};

                        if (!fcvt_is_64 && fcvt_is_signed)
                            fcvt_in_range = (!fcvt_s && (fcvt_rmag <= 65'd2147483647)) || (fcvt_s && (fcvt_rmag <= 65'd2147483648));
                        else if (!fcvt_is_64 && !fcvt_is_signed)
                            fcvt_in_range = (!fcvt_s && (fcvt_rmag <= 65'h0_FFFF_FFFF)) || (fcvt_s && (fcvt_rmag == 65'd0));
                        else if (fcvt_is_64 && fcvt_is_signed)
                            fcvt_in_range = (!fcvt_s && (fcvt_rmag <= 65'h0_7FFF_FFFF_FFFF_FFFF)) || (fcvt_s && (fcvt_rmag <= 65'h0_8000_0000_0000_0000));
                        else
                            fcvt_in_range = (!fcvt_s && (fcvt_rmag <= 65'h0_FFFF_FFFF_FFFF_FFFF)) || (fcvt_s && (fcvt_rmag == 65'd0));

                        if (!fcvt_in_range) begin
                            f2i_comb_data   = fcvt_sat_val;
                            f2i_comb_fflags = 5'b10000; // NV (no NX on out-of-range)
                        end else begin
                            fcvt_sres = fcvt_s ? (~fcvt_rmag[63:0] + 64'd1) : fcvt_rmag[63:0];
                            f2i_comb_data   = fcvt_is_64 ? fcvt_sres : {{32{fcvt_sres[31]}}, fcvt_sres[31:0]};
                            f2i_comb_fflags = {4'b0000, fcvt_inexact};
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 4. Lossless Circular Writeback FIFO for Float-to-Integer (8 entries)
    // -------------------------------------------------------------------------
    localparam int F2I_FIFO_DEPTH = 8;
    typedef struct packed {
        logic        valid;
        logic [63:0] data;
        logic [4:0]  fflags;
        preg_t       pnew;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
    } f2i_entry_t;

    f2i_entry_t f2i_fifo [F2I_FIFO_DEPTH];
    logic [2:0] f2i_head;
    logic [2:0] f2i_tail;
    logic [3:0] f2i_count;

    assign prf_busy_o = (f2i_count >= 4'd6);

    wire f2i_pop = (f2i_count > 4'd0) && (!f2i_fifo[f2i_head].valid || !int_wb_busy_i);

    assign prf_wb_valid_o     = (f2i_count > 4'd0) && f2i_fifo[f2i_head].valid && !int_wb_busy_i;
    assign prf_wb_data_o      = f2i_fifo[f2i_head].data;
    assign prf_wb_fflags_o    = f2i_fifo[f2i_head].fflags;
    assign prf_wb_pnew_o      = f2i_fifo[f2i_head].pnew;
    assign prf_wb_rob_idx_o   = f2i_fifo[f2i_head].rob_idx;
    assign prf_wb_rob_epoch_o = f2i_fifo[f2i_head].rob_epoch;

    f2i_entry_t f2i_push_entry;
    assign f2i_push_entry.valid     = 1'b1;
    assign f2i_push_entry.data      = f2i_comb_data;
    assign f2i_push_entry.fflags    = f2i_comb_fflags;
    assign f2i_push_entry.pnew      = f2i_comb_pnew;
    assign f2i_push_entry.rob_idx   = f2i_comb_rob_idx;
    assign f2i_push_entry.rob_epoch = f2i_comb_rob_epoch;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            for (int k = 0; k < F2I_FIFO_DEPTH; k++) begin
                f2i_fifo[k] <= '0;
            end
            f2i_head  <= 3'd0;
            f2i_tail  <= 3'd0;
            f2i_count <= 4'd0;
        end else begin
            // 1. Branch misprediction recovery squashes
            if (recover_valid_i) begin
                for (int k = 0; k < F2I_FIFO_DEPTH; k++) begin
                    if (f2i_fifo[k].valid && (rob_dist(f2i_fifo[k].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        f2i_fifo[k].valid <= 1'b0;
                    end
                end
            end

            // 2. FIFO update (Pop and Push)
            begin : blk_f2i_fifo
                logic [2:0] cur_head;
                logic [2:0] cur_tail;
                logic [3:0] cur_count;
                logic       f2i_push_squashed;

                cur_head  = f2i_head;
                cur_tail  = f2i_tail;
                cur_count = f2i_count;

                if (f2i_pop) begin
                    f2i_fifo[cur_head].valid <= 1'b0;
                    cur_head  = cur_head + 3'd1;
                    cur_count = cur_count - 4'd1;
                end

                f2i_push_squashed = recover_valid_i && (rob_dist(f2i_push_entry.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

                if (f2i_comb_valid && !f2i_push_squashed) begin
                    f2i_fifo[cur_tail] <= f2i_push_entry;
                    cur_tail  = cur_tail + 3'd1;
                    cur_count = cur_count + 4'd1;
                end

                f2i_head  <= cur_head;
                f2i_tail  <= cur_tail;
                f2i_count <= cur_count;
            end
        end
    end

endmodule

`endif // FURSOY_S1_FCONV_SV
