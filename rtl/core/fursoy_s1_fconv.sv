`ifndef FURSOY_S1_FCONV_SV
`define FURSOY_S1_FCONV_SV

// =============================================================================
// Fursoy Slice-1 Cross-Domain Move, Conversion & Comparison Unit — Milestone 8 Phase B
// =============================================================================
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 6.4, Section 11
//
// Phase 2 Timing Closure:
// - 2-stage pipelined conversion datapaths (F2F narrowing, I2F, F2I) with
//   binary-tree CLZ64 and parallel round+0 / round+1 evaluation.
// - Stage-1 registers honor flush_valid_i and rob_dist-based recover_valid_i.
// - 16-entry circular writeback FIFOs absorb backpressure + in-flight Stage-1 ops.
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_ks_adder.sv"

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

    // 4-bit nibble-parallel tree 64-bit leading-zero counter (valid for non-zero inputs)
    function automatic logic [5:0] clz64(input logic [63:0] val);
        logic [15:0] nz;
        logic [1:0]  lzc4 [16];
        logic [3:1]  qz;
        logic [1:0]  qlzc [4];
        logic [1:0]  quad_bit_lzc [4];
        logic [5:0]  res;

        for (int n = 0; n < 16; n++) begin
            logic [3:0] nib;
            nib        = val[4*n +: 4];
            nz[n]      = |nib;
            lzc4[n][1] = ~nib[3] & ~nib[2];
            lzc4[n][0] = ~nib[3] & (nib[2] | ~nib[1]);
        end

        for (int q = 0; q < 4; q++) begin
            logic [3:0] qn;
            qn               = nz[4*q +: 4];
            if (q > 0) begin
                qz[q]        = |qn;
            end
            qlzc[q][1]       = ~qn[3] & ~qn[2];
            qlzc[q][0]       = ~qn[3] & (qn[2] | ~qn[1]);
            quad_bit_lzc[q]  = lzc4[{q[1:0], ~qlzc[q]}];
        end

        res[5]   = ~qz[3] & ~qz[2];
        res[4]   = ~qz[3] & (qz[2] | ~qz[1]);
        res[3:2] = qlzc[~res[5:4]];
        res[1:0] = quad_bit_lzc[~res[5:4]];
        return res;
    endfunction

    function automatic logic fcvt_check_range(
        input logic        is_64,
        input logic        is_signed,
        input logic        sign,
        input logic [64:0] rmag
    );
        if (!is_64 && is_signed)
            return (!sign && (rmag <= 65'd2147483647)) || (sign && (rmag <= 65'd2147483648));
        else if (!is_64 && !is_signed)
            return (!sign && (rmag <= 65'h0_FFFF_FFFF)) || (sign && (rmag == 65'd0));
        else if (is_64 && is_signed)
            return (!sign && (rmag <= 65'h0_7FFF_FFFF_FFFF_FFFF)) || (sign && (rmag <= 65'h0_8000_0000_0000_0000));
        else
            return (!sign && (rmag <= 65'h0_FFFF_FFFF_FFFF_FFFF)) || (sign && (rmag == 65'd0));
    endfunction

    // =========================================================================
    // 1. Float-to-Float & Min/Max/Sign-Injection (Stage 1 -> Stage 2 -> FPRF)
    // =========================================================================
    logic               p4_s1_comb_valid;
    logic               p4_s1_comb_bypass;
    logic [63:0]        p4_s1_comb_bypass_data;
    logic [4:0]         p4_s1_comb_bypass_fflags;
    logic [2:0]         p4_s1_comb_rm;
    logic               p4_s1_comb_s;
    logic signed [13:0] p4_s1_comb_exp_sp;
    logic [24:0]        p4_s1_comb_mant_sp;
    logic               p4_s1_comb_guard;
    logic               p4_s1_comb_round;
    logic               p4_s1_comb_sticky;
    logic               p4_s1_comb_tiny;

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
        logic f2f_guard, f2f_round_bit, f2f_sticky_bit;
        logic f2f_unb_all1, f2f_unb_inexact, f2f_unb_inc;
        logic signed [13:0] f2f_shift;
        logic [54:0] f2f_tmp;
        logic [31:0] f2f_op;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [5:0]  f2f_lzc_raw;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [4:0]  f2f_lzc;
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
        f2f_unb_all1 = 1'b0; f2f_unb_inexact = 1'b0; f2f_unb_inc = 1'b0;
        f2f_shift = '0; f2f_tmp = '0;
        f2f_op = '0; f2f_lzc_raw = '0; f2f_lzc = '0; f2f_sh_f = '0; f2f_new_exp = '0;

        p4_s1_comb_valid         = 1'b0;
        p4_s1_comb_bypass        = 1'b1;
        p4_s1_comb_bypass_data   = '0;
        p4_s1_comb_bypass_fflags = '0;
        p4_s1_comb_rm            = eff_rm;
        p4_s1_comb_s             = 1'b0;
        p4_s1_comb_exp_sp        = '0;
        p4_s1_comb_mant_sp       = '0;
        p4_s1_comb_guard         = 1'b0;
        p4_s1_comb_round         = 1'b0;
        p4_s1_comb_sticky        = 1'b0;
        p4_s1_comb_tiny          = 1'b0;

        if (p4_req_valid_i && p4_req_fp_dest_valid_i) begin
            case (p4_req_subop_i)
                FP_FCVT_S_D: begin
                    f2f_s = p4_req_rs1_fp_data_i[63]; f2f_e = p4_req_rs1_fp_data_i[62:52]; f2f_f = p4_req_rs1_fp_data_i[51:0];
                    p4_s1_comb_valid = 1'b1;
                    if (f2f_e == 11'h7FF) begin
                        p4_s1_comb_bypass = 1'b1;
                        if (f2f_f != 52'd0) begin
                            p4_s1_comb_bypass_data   = {32'hFFFF_FFFF, FP32_QNAN};
                            p4_s1_comb_bypass_fflags = !f2f_f[51] ? 5'b10000 : 5'b00000;
                        end else begin
                            p4_s1_comb_bypass_data   = {32'hFFFF_FFFF, f2f_s, 8'hFF, 23'd0};
                            p4_s1_comb_bypass_fflags = 5'b00000;
                        end
                    end else if (f2f_e == 11'd0 && f2f_f == 52'd0) begin
                        p4_s1_comb_bypass        = 1'b1;
                        p4_s1_comb_bypass_data   = {32'hFFFF_FFFF, f2f_s, 31'd0};
                        p4_s1_comb_bypass_fflags = 5'b00000;
                    end else begin
                        p4_s1_comb_bypass = 1'b0;
                        f2f_exp_sp     = signed'(14'(f2f_e)) - 14'sd1023 + 14'sd127;
                        f2f_mant_sp    = {2'b01, f2f_f[51:29]};
                        f2f_guard      = f2f_f[28];
                        f2f_round_bit  = f2f_f[27];
                        f2f_sticky_bit = (f2f_f[26:0] != 27'd0);

                        // IEEE-754-2008 §7.5 tininess after rounding (unbounded exponent)
                        f2f_unb_all1    = &f2f_mant_sp[23:0];
                        f2f_unb_inexact = f2f_guard || f2f_round_bit || f2f_sticky_bit;
                        case (eff_rm)
                            3'b000: f2f_unb_inc = f2f_guard;
                            3'b001: f2f_unb_inc = 1'b0;
                            3'b010: f2f_unb_inc = f2f_s && f2f_unb_inexact;
                            3'b011: f2f_unb_inc = !f2f_s && f2f_unb_inexact;
                            3'b100: f2f_unb_inc = f2f_guard;
                            default: f2f_unb_inc = f2f_guard;
                        endcase
                        p4_s1_comb_tiny = (f2f_exp_sp < 14'sd0) ||
                                          ((f2f_exp_sp == 14'sd0) && !(f2f_unb_all1 && f2f_unb_inc));

                        if (f2f_exp_sp <= 14'sd0) begin
                            f2f_shift = 14'sd1 - f2f_exp_sp;
                            if (f2f_shift > 14'sd30) begin
                                f2f_mant_sp    = '0;
                                f2f_guard      = 1'b0;
                                f2f_round_bit  = 1'b0;
                                f2f_sticky_bit = 1'b1;
                            end else begin
                                f2f_tmp        = {f2f_mant_sp[23:0], f2f_guard, f2f_round_bit, 29'd0} >> f2f_shift;
                                f2f_mant_sp    = {1'b0, f2f_tmp[54:31]};
                                f2f_guard      = f2f_tmp[30];
                                f2f_round_bit  = f2f_tmp[29];
                                f2f_sticky_bit = f2f_sticky_bit || (f2f_tmp[28:0] != 29'd0);
                            end
                            f2f_exp_sp = 14'sd0;
                        end

                        p4_s1_comb_s      = f2f_s;
                        p4_s1_comb_exp_sp = f2f_exp_sp;
                        p4_s1_comb_mant_sp= f2f_mant_sp;
                        p4_s1_comb_guard  = f2f_guard;
                        p4_s1_comb_round  = f2f_round_bit;
                        p4_s1_comb_sticky = f2f_sticky_bit;
                    end
                end

                FP_FCVT_D_S: begin
                    f2f_op = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    f2f_s = f2f_op[31]; f2f_e = {3'd0, f2f_op[30:23]}; f2f_f = {f2f_op[22:0], 29'd0};
                    p4_s1_comb_valid  = 1'b1;
                    p4_s1_comb_bypass = 1'b1;

                    if (f2f_e[7:0] == 8'hFF) begin
                        if (f2f_f[51:29] != 23'd0) begin
                            p4_s1_comb_bypass_data   = FP64_QNAN;
                            p4_s1_comb_bypass_fflags = !f2f_f[51] ? 5'b10000 : 5'b00000;
                        end else begin
                            p4_s1_comb_bypass_data   = {f2f_s, 11'h7FF, 52'd0};
                            p4_s1_comb_bypass_fflags = 5'b00000;
                        end
                    end else if (f2f_e[7:0] == 8'd0) begin
                        if (f2f_f[51:29] == 23'd0) begin
                            p4_s1_comb_bypass_data   = {f2f_s, 63'd0};
                            p4_s1_comb_bypass_fflags = 5'b00000;
                        end else begin
                            f2f_lzc_raw = clz64({f2f_f[51:29], 41'd0});
                            f2f_lzc     = f2f_lzc_raw[4:0];
                            f2f_sh_f    = f2f_f[51:29] << (f2f_lzc + 5'd1);
                            f2f_new_exp = 11'd1023 - 11'd127 - 11'(f2f_lzc);
                            p4_s1_comb_bypass_data   = {f2f_s, f2f_new_exp, f2f_sh_f, 29'd0};
                            p4_s1_comb_bypass_fflags = 5'b00000;
                        end
                    end else begin
                        f2f_new_exp = 11'(f2f_e[7:0]) - 11'd127 + 11'd1023;
                        p4_s1_comb_bypass_data   = {f2f_s, f2f_new_exp, f2f_f};
                        p4_s1_comb_bypass_fflags = 5'b00000;
                    end
                end

                // Sign Injection
                FP_FSGNJ_S: begin
                    sgnj_op1 = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    sgnj_op2 = is_nanbox_valid(p4_req_rs2_fp_data_i) ? p4_req_rs2_fp_data_i[31:0] : FP32_QNAN;
                    p4_s1_comb_valid       = 1'b1;
                    p4_s1_comb_bypass      = 1'b1;
                    p4_s1_comb_bypass_data = {32'hFFFF_FFFF, sgnj_op2[31], sgnj_op1[30:0]};
                end
                FP_FSGNJN_S: begin
                    sgnj_op1 = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    sgnj_op2 = is_nanbox_valid(p4_req_rs2_fp_data_i) ? p4_req_rs2_fp_data_i[31:0] : FP32_QNAN;
                    p4_s1_comb_valid       = 1'b1;
                    p4_s1_comb_bypass      = 1'b1;
                    p4_s1_comb_bypass_data = {32'hFFFF_FFFF, ~sgnj_op2[31], sgnj_op1[30:0]};
                end
                FP_FSGNJX_S: begin
                    sgnj_op1 = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    sgnj_op2 = is_nanbox_valid(p4_req_rs2_fp_data_i) ? p4_req_rs2_fp_data_i[31:0] : FP32_QNAN;
                    p4_s1_comb_valid       = 1'b1;
                    p4_s1_comb_bypass      = 1'b1;
                    p4_s1_comb_bypass_data = {32'hFFFF_FFFF, sgnj_op1[31] ^ sgnj_op2[31], sgnj_op1[30:0]};
                end
                FP_FSGNJ_D: begin
                    p4_s1_comb_valid       = 1'b1;
                    p4_s1_comb_bypass      = 1'b1;
                    p4_s1_comb_bypass_data = {p4_req_rs2_fp_data_i[63], p4_req_rs1_fp_data_i[62:0]};
                end
                FP_FSGNJN_D: begin
                    p4_s1_comb_valid       = 1'b1;
                    p4_s1_comb_bypass      = 1'b1;
                    p4_s1_comb_bypass_data = {~p4_req_rs2_fp_data_i[63], p4_req_rs1_fp_data_i[62:0]};
                end
                FP_FSGNJX_D: begin
                    p4_s1_comb_valid       = 1'b1;
                    p4_s1_comb_bypass      = 1'b1;
                    p4_s1_comb_bypass_data = {p4_req_rs1_fp_data_i[63] ^ p4_req_rs2_fp_data_i[63], p4_req_rs1_fp_data_i[62:0]};
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

                    p4_s1_comb_valid         = 1'b1;
                    p4_s1_comb_bypass        = 1'b1;
                    p4_s1_comb_bypass_fflags = (min_snan1 || min_snan2) ? 5'b10000 : 5'b00000;

                    if (min_nan1 && min_nan2) begin
                        p4_s1_comb_bypass_data = {32'hFFFF_FFFF, FP32_QNAN};
                    end else if (min_nan1) begin
                        p4_s1_comb_bypass_data = {32'hFFFF_FFFF, min_op2};
                    end else if (min_nan2) begin
                        p4_s1_comb_bypass_data = {32'hFFFF_FFFF, min_op1};
                    end else if ((min_op1[30:0] == 31'd0) && (min_op2[30:0] == 31'd0)) begin
                        min_s = (p4_req_subop_i == FP_FMIN_S) ? (min_op1[31] || min_op2[31]) : (min_op1[31] && min_op2[31]);
                        p4_s1_comb_bypass_data = {32'hFFFF_FFFF, min_s, 31'd0};
                    end else begin
                        min_pick_op1 = (p4_req_subop_i == FP_FMIN_S) ? min_less : !min_less;
                        p4_s1_comb_bypass_data = {32'hFFFF_FFFF, min_pick_op1 ? min_op1 : min_op2};
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

                    p4_s1_comb_valid         = 1'b1;
                    p4_s1_comb_bypass        = 1'b1;
                    p4_s1_comb_bypass_fflags = (min_snan1 || min_snan2) ? 5'b10000 : 5'b00000;

                    if (min_nan1 && min_nan2) begin
                        p4_s1_comb_bypass_data = FP64_QNAN;
                    end else if (min_nan1) begin
                        p4_s1_comb_bypass_data = p4_req_rs2_fp_data_i;
                    end else if (min_nan2) begin
                        p4_s1_comb_bypass_data = p4_req_rs1_fp_data_i;
                    end else if ((p4_req_rs1_fp_data_i[62:0] == 63'd0) && (p4_req_rs2_fp_data_i[62:0] == 63'd0)) begin
                        min_s = (p4_req_subop_i == FP_FMIN_D) ? (p4_req_rs1_fp_data_i[63] || p4_req_rs2_fp_data_i[63]) : (p4_req_rs1_fp_data_i[63] && p4_req_rs2_fp_data_i[63]);
                        p4_s1_comb_bypass_data = {min_s, 63'd0};
                    end else begin
                        min_pick_op1 = (p4_req_subop_i == FP_FMIN_D) ? min_less : !min_less;
                        p4_s1_comb_bypass_data = min_pick_op1 ? p4_req_rs1_fp_data_i : p4_req_rs2_fp_data_i;
                    end
                end

                default: ;
            endcase
        end
    end

    // Stage 1 -> Stage 2 Pipeline Registers (P4 -> FPRF)
    logic               p4_s1_valid_q;
    logic               p4_s1_bypass_q;
    logic [63:0]        p4_s1_bypass_data_q;
    logic [4:0]         p4_s1_bypass_fflags_q;
    logic [2:0]         p4_s1_rm_q;
    logic               p4_s1_s_q;
    logic signed [13:0] p4_s1_exp_sp_q;
    logic [24:0]        p4_s1_mant_sp_q;
    logic               p4_s1_guard_q;
    logic               p4_s1_round_q;
    logic               p4_s1_sticky_q;
    logic               p4_s1_tiny_q;
    fpreg_t             p4_s1_prd_fp_q;
    rob_idx_t           p4_s1_rob_idx_q;
    rob_epoch_t         p4_s1_rob_epoch_q;

    // P4 -> FPRF Stage 2 Combinational Rounding
    logic        p4_to_fprf_valid;
    logic [63:0] p4_to_fprf_data;
    logic [4:0]  p4_to_fprf_fflags;
    fpreg_t      p4_to_fprf_prd_fp;
    rob_idx_t    p4_to_fprf_rob_idx;
    rob_epoch_t  p4_to_fprf_rob_epoch;

    always_comb begin
        logic               f2f_inexact, f2f_round_up, f2f_overflow, f2f_underflow;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [24:0]        f2f_mant_p1, f2f_mant_fin;
        /* verilator lint_on UNUSEDSIGNAL */
        logic signed [13:0] f2f_exp_fin;
        logic [7:0]         f2f_final_exp;

        f2f_inexact   = 1'b0;
        f2f_round_up  = 1'b0;
        f2f_overflow  = 1'b0;
        f2f_underflow = 1'b0;
        f2f_mant_p1   = 25'd0;
        f2f_mant_fin  = 25'd0;
        f2f_exp_fin   = 14'sd0;
        f2f_final_exp = 8'd0;

        p4_to_fprf_valid     = p4_s1_valid_q;
        p4_to_fprf_prd_fp    = p4_s1_prd_fp_q;
        p4_to_fprf_rob_idx   = p4_s1_rob_idx_q;
        p4_to_fprf_rob_epoch = p4_s1_rob_epoch_q;

        if (p4_s1_bypass_q) begin
            p4_to_fprf_data   = p4_s1_bypass_data_q;
            p4_to_fprf_fflags = p4_s1_bypass_fflags_q;
        end else begin
            f2f_inexact  = p4_s1_guard_q || p4_s1_round_q || p4_s1_sticky_q;
            f2f_round_up = 1'b0;
            case (p4_s1_rm_q)
                3'b000: f2f_round_up = p4_s1_guard_q && (p4_s1_round_q || p4_s1_sticky_q || p4_s1_mant_sp_q[0]);
                3'b001: f2f_round_up = 1'b0;
                3'b010: f2f_round_up = p4_s1_s_q && f2f_inexact;
                3'b011: f2f_round_up = !p4_s1_s_q && f2f_inexact;
                3'b100: f2f_round_up = p4_s1_guard_q;
                default: f2f_round_up = p4_s1_guard_q && (p4_s1_round_q || p4_s1_sticky_q || p4_s1_mant_sp_q[0]);
            endcase

            f2f_mant_p1 = p4_s1_mant_sp_q + 25'd1;
            f2f_exp_fin = p4_s1_exp_sp_q;
            if (f2f_round_up) begin
                if (f2f_mant_p1 == 25'h100_0000) begin
                    f2f_mant_fin = f2f_mant_p1 >> 1;
                    f2f_exp_fin  = p4_s1_exp_sp_q + 14'sd1;
                end else begin
                    f2f_mant_fin = f2f_mant_p1;
                    if (f2f_mant_p1[23] && (p4_s1_exp_sp_q == 14'sd0)) f2f_exp_fin = 14'sd1;
                end
            end else begin
                f2f_mant_fin = p4_s1_mant_sp_q;
            end

            f2f_overflow  = 1'b0;
            f2f_underflow = 1'b0;
            if (f2f_exp_fin >= 14'sd255) begin
                f2f_overflow  = 1'b1;
                f2f_inexact   = 1'b1;
                if ((p4_s1_rm_q == 3'b001) ||
                    (p4_s1_rm_q == 3'b010 && !p4_s1_s_q) ||
                    (p4_s1_rm_q == 3'b011 && p4_s1_s_q)) begin
                    f2f_final_exp = 8'hFE;
                    f2f_mant_fin  = 25'h07F_FFFF;
                end else begin
                    f2f_final_exp = 8'hFF;
                    f2f_mant_fin  = 25'd0;
                end
            end else begin
                f2f_final_exp = f2f_exp_fin[7:0];
                f2f_underflow = p4_s1_tiny_q && f2f_inexact;
            end

            p4_to_fprf_data   = {32'hFFFF_FFFF, p4_s1_s_q, f2f_final_exp, f2f_mant_fin[22:0]};
            p4_to_fprf_fflags = {1'b0, 1'b0, f2f_overflow, f2f_underflow, f2f_inexact};
        end
    end

    // =========================================================================
    // 2. Integer-to-Float Moves & Conversions (Stage 1 -> Stage 2 -> FPRF)
    // =========================================================================
    logic        i2f_s1_comb_valid;
    logic        i2f_s1_comb_bypass;
    logic [63:0] i2f_s1_comb_bypass_data;
    logic [2:0]  i2f_s1_comb_rm;
    logic        i2f_s1_comb_is_sp;
    logic        i2f_s1_comb_s;
    logic [63:0] i2f_s1_comb_mag;
    logic [5:0]  i2f_s1_comb_lzc;

    logic [63:0] i2f_neg64_w;

    // Preserve prefix cut points via fursoy_s1_ks_adder so ABC cannot collapse
    // two's-complement negation back into a ripple carry chain.
    fursoy_s1_ks_adder #(.WIDTH(64)) u_i2f_neg_adder (
        .a_i   (~int2fp_req_int_data_i),
        .b_i   (64'd0),
        .cin_i (1'b1),
        .sum_o (i2f_neg64_w)
    );

    always_comb begin
        logic [2:0]  i2f_rm;
        logic        i2f_is_64;
        logic        i2f_is_signed;
        logic        i2f_is_sp;
        logic        i2f_s;
        logic [63:0] i2f_mag;
        logic [63:0] i2f_clz_in;
        logic [5:0]  i2f_lzc_raw;
        logic [5:0]  i2f_lzc_m1;
        logic        i2f_lzc_adj;
        logic        i2f_is_zero;

        i2f_rm        = (int2fp_req_frm_i == 3'b111) ? fcsr_frm_i : int2fp_req_frm_i;
        i2f_is_64     = 1'b0;
        i2f_is_signed = 1'b0;
        i2f_is_sp     = 1'b0;
        i2f_s         = 1'b0;
        i2f_mag       = 64'd0;
        i2f_clz_in    = 64'd0;
        i2f_lzc_raw   = 6'd0;
        i2f_lzc_m1    = 6'd0;
        i2f_lzc_adj   = 1'b0;
        i2f_is_zero   = 1'b0;

        i2f_s1_comb_valid       = 1'b0;
        i2f_s1_comb_bypass      = 1'b1;
        i2f_s1_comb_bypass_data = 64'd0;
        i2f_s1_comb_rm          = i2f_rm;
        i2f_s1_comb_is_sp       = 1'b0;
        i2f_s1_comb_s           = 1'b0;
        i2f_s1_comb_mag         = 64'd0;
        i2f_s1_comb_lzc         = 6'd0;

        if (int2fp_req_valid_i) begin
            case (int2fp_req_subop_i)
                FP_FMV_W_X: begin
                    i2f_s1_comb_valid       = 1'b1;
                    i2f_s1_comb_bypass      = 1'b1;
                    i2f_s1_comb_bypass_data = {32'hFFFF_FFFF, int2fp_req_int_data_i[31:0]};
                end
                FP_FMV_D_X: begin
                    i2f_s1_comb_valid       = 1'b1;
                    i2f_s1_comb_bypass      = 1'b1;
                    i2f_s1_comb_bypass_data = int2fp_req_int_data_i;
                end
                FP_FCVT_S_W, FP_FCVT_S_WU, FP_FCVT_S_L, FP_FCVT_S_LU,
                FP_FCVT_D_W, FP_FCVT_D_WU, FP_FCVT_D_L, FP_FCVT_D_LU: begin
                    i2f_is_sp     = (int2fp_req_subop_i == FP_FCVT_S_W)  || (int2fp_req_subop_i == FP_FCVT_S_WU) ||
                                    (int2fp_req_subop_i == FP_FCVT_S_L)  || (int2fp_req_subop_i == FP_FCVT_S_LU);
                    i2f_is_64     = (int2fp_req_subop_i == FP_FCVT_S_L)  || (int2fp_req_subop_i == FP_FCVT_S_LU) ||
                                    (int2fp_req_subop_i == FP_FCVT_D_L)  || (int2fp_req_subop_i == FP_FCVT_D_LU);
                    i2f_is_signed = (int2fp_req_subop_i == FP_FCVT_S_W)  || (int2fp_req_subop_i == FP_FCVT_S_L)  ||
                                    (int2fp_req_subop_i == FP_FCVT_D_W)  || (int2fp_req_subop_i == FP_FCVT_D_L);
                    // Parallel Kogge-Stone negation (~x + 1) and ~x CLZ; with y[63]==0,
                    // y == 2^k - 1 (k>=1) iff y != 0 and no upward 0->1 transition (~y[i] & y[i+1]).
                    i2f_s       = i2f_is_signed && (i2f_is_64 ? int2fp_req_int_data_i[63] : int2fp_req_int_data_i[31]);
                    i2f_mag     = {
                        i2f_is_64 ? (i2f_s ? i2f_neg64_w[63:32] : int2fp_req_int_data_i[63:32]) : 32'd0,
                        i2f_s     ? i2f_neg64_w[31:0] : int2fp_req_int_data_i[31:0]
                    };
                    i2f_clz_in  = {
                        i2f_is_64 ? (i2f_s ? ~int2fp_req_int_data_i[63:32] : int2fp_req_int_data_i[63:32]) : 32'd0,
                        i2f_s     ? ~int2fp_req_int_data_i[31:0] : int2fp_req_int_data_i[31:0]
                    };
                    i2f_lzc_raw = clz64(i2f_clz_in);
                    i2f_lzc_m1  = i2f_lzc_raw - 6'd1;
                    i2f_lzc_adj = i2f_s && (i2f_clz_in != 64'd0) && (((~i2f_clz_in[62:0]) & i2f_clz_in[63:1]) == 63'd0);
                    i2f_is_zero = (int2fp_req_int_data_i[31:0] == 32'd0) &&
                                  (!i2f_is_64 || (int2fp_req_int_data_i[63:32] == 32'd0));

                    i2f_s1_comb_valid = 1'b1;
                    i2f_s1_comb_is_sp = i2f_is_sp;
                    i2f_s1_comb_s     = i2f_s;
                    i2f_s1_comb_mag   = i2f_mag;
                    i2f_s1_comb_lzc   = i2f_lzc_adj ? i2f_lzc_m1 : i2f_lzc_raw;

                    if (i2f_is_zero) begin
                        i2f_s1_comb_bypass      = 1'b1;
                        i2f_s1_comb_bypass_data = i2f_is_sp ? {32'hFFFF_FFFF, 32'd0} : 64'd0;
                    end else begin
                        i2f_s1_comb_bypass      = 1'b0;
                    end
                end
                default: ;
            endcase
        end
    end

    // Stage 1 -> Stage 2 Pipeline Registers (Int2FP -> FPRF)
    logic        i2f_s1_valid_q;
    logic        i2f_s1_bypass_q;
    logic [63:0] i2f_s1_bypass_data_q;
    logic [2:0]  i2f_s1_rm_q;
    logic        i2f_s1_is_sp_q;
    logic        i2f_s1_s_q;
    logic [63:0] i2f_s1_mag_q;
    logic [5:0]  i2f_s1_lzc_q;
    fpreg_t      i2f_s1_prd_fp_q;
    rob_idx_t    i2f_s1_rob_idx_q;
    rob_epoch_t  i2f_s1_rob_epoch_q;

    // Int2FP Stage 2 Combinational Shift & Rounding
    logic        int2fp_out_valid;
    logic [63:0] int2fp_out_data;
    logic [4:0]  int2fp_out_fflags;
    fpreg_t      int2fp_out_prd_fp;
    rob_idx_t    int2fp_out_rob_idx;
    rob_epoch_t  int2fp_out_rob_epoch;

    always_comb begin
        logic [63:0] i2f_sh_m;
        logic [7:0]  exp_sp_base, exp_sp;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [24:0] mant_sp_p0, mant_sp_p1, mant_sp;
        /* verilator lint_on UNUSEDSIGNAL */
        logic        guard_sp, sticky_sp, inexact_sp, rup_sp;
        logic [10:0] exp_dp_base, exp_dp;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [53:0] mant_dp_p0, mant_dp_p1, mant_dp;
        /* verilator lint_on UNUSEDSIGNAL */
        logic        guard_dp, sticky_dp, inexact_dp, rup_dp;

        exp_sp     = '0; mant_sp_p0 = '0; mant_sp_p1 = '0; mant_sp = '0;
        guard_sp   = '0; sticky_sp  = '0; inexact_sp = '0; rup_sp  = '0;
        exp_dp     = '0; mant_dp_p0 = '0; mant_dp_p1 = '0; mant_dp = '0;
        guard_dp   = '0; sticky_dp  = '0; inexact_dp = '0; rup_dp  = '0;

        i2f_sh_m    = i2f_s1_mag_q << i2f_s1_lzc_q;
        exp_sp_base = 8'd190 - {2'd0, i2f_s1_lzc_q};
        exp_dp_base = 11'd1086 - {5'd0, i2f_s1_lzc_q};

        int2fp_out_valid     = i2f_s1_valid_q;
        int2fp_out_prd_fp    = i2f_s1_prd_fp_q;
        int2fp_out_rob_idx   = i2f_s1_rob_idx_q;
        int2fp_out_rob_epoch = i2f_s1_rob_epoch_q;

        if (i2f_s1_bypass_q) begin
            int2fp_out_data   = i2f_s1_bypass_data_q;
            int2fp_out_fflags = 5'b00000;
        end else if (i2f_s1_is_sp_q) begin
            mant_sp_p0 = {1'b0, i2f_sh_m[63:40]};
            mant_sp_p1 = mant_sp_p0 + 25'd1;
            guard_sp   = i2f_sh_m[39];
            sticky_sp  = (i2f_sh_m[38:0] != 39'd0);
            inexact_sp = guard_sp || sticky_sp;
            rup_sp     = fp_round_up(i2f_s1_rm_q, i2f_s1_s_q, mant_sp_p0[0], guard_sp, sticky_sp);
            mant_sp    = rup_sp ? mant_sp_p1 : mant_sp_p0;
            exp_sp     = (rup_sp && mant_sp_p1[24]) ? (exp_sp_base + 8'd1) : exp_sp_base;
            int2fp_out_data   = {32'hFFFF_FFFF, i2f_s1_s_q, exp_sp, (rup_sp && mant_sp_p1[24]) ? 23'd0 : mant_sp[22:0]};
            int2fp_out_fflags = {4'b0000, inexact_sp};
        end else begin
            mant_dp_p0 = {1'b0, i2f_sh_m[63:11]};
            mant_dp_p1 = mant_dp_p0 + 54'd1;
            guard_dp   = i2f_sh_m[10];
            sticky_dp  = (i2f_sh_m[9:0] != 10'd0);
            inexact_dp = guard_dp || sticky_dp;
            rup_dp     = fp_round_up(i2f_s1_rm_q, i2f_s1_s_q, mant_dp_p0[0], guard_dp, sticky_dp);
            mant_dp    = rup_dp ? mant_dp_p1 : mant_dp_p0;
            exp_dp     = (rup_dp && mant_dp_p1[53]) ? (exp_dp_base + 11'd1) : exp_dp_base;
            int2fp_out_data   = {i2f_s1_s_q, exp_dp, (rup_dp && mant_dp_p1[53]) ? 52'd0 : mant_dp[51:0]};
            int2fp_out_fflags = {4'b0000, inexact_dp};
        end
    end

    // Stage 1 Registers (FPRF paths: p4_to_fprf & int2fp)
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            p4_s1_valid_q         <= 1'b0;
            p4_s1_bypass_q        <= 1'b1;
            p4_s1_bypass_data_q   <= 64'd0;
            p4_s1_bypass_fflags_q <= 5'd0;
            p4_s1_rm_q            <= 3'd0;
            p4_s1_s_q             <= 1'b0;
            p4_s1_exp_sp_q        <= '0;
            p4_s1_mant_sp_q       <= '0;
            p4_s1_guard_q         <= 1'b0;
            p4_s1_round_q         <= 1'b0;
            p4_s1_sticky_q        <= 1'b0;
            p4_s1_tiny_q          <= 1'b0;
            p4_s1_prd_fp_q        <= '0;
            p4_s1_rob_idx_q       <= '0;
            p4_s1_rob_epoch_q     <= '0;

            i2f_s1_valid_q        <= 1'b0;
            i2f_s1_bypass_q       <= 1'b1;
            i2f_s1_bypass_data_q  <= 64'd0;
            i2f_s1_rm_q           <= 3'd0;
            i2f_s1_is_sp_q        <= 1'b0;
            i2f_s1_s_q            <= 1'b0;
            i2f_s1_mag_q          <= 64'd0;
            i2f_s1_lzc_q          <= 6'd0;
            i2f_s1_prd_fp_q       <= '0;
            i2f_s1_rob_idx_q      <= '0;
            i2f_s1_rob_epoch_q    <= '0;
        end else begin
            logic p4_req_squashed, i2f_req_squashed;
            p4_req_squashed  = recover_valid_i && (rob_dist(p4_req_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
            i2f_req_squashed = recover_valid_i && (rob_dist(int2fp_req_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

            p4_s1_valid_q         <= p4_s1_comb_valid && !p4_req_squashed;
            p4_s1_bypass_q        <= p4_s1_comb_bypass;
            p4_s1_bypass_data_q   <= p4_s1_comb_bypass_data;
            p4_s1_bypass_fflags_q <= p4_s1_comb_bypass_fflags;
            p4_s1_rm_q            <= p4_s1_comb_rm;
            p4_s1_s_q             <= p4_s1_comb_s;
            p4_s1_exp_sp_q        <= p4_s1_comb_exp_sp;
            p4_s1_mant_sp_q       <= p4_s1_comb_mant_sp;
            p4_s1_guard_q         <= p4_s1_comb_guard;
            p4_s1_round_q         <= p4_s1_comb_round;
            p4_s1_sticky_q        <= p4_s1_comb_sticky;
            p4_s1_tiny_q          <= p4_s1_comb_tiny;
            p4_s1_prd_fp_q        <= p4_req_prd_fp_i;
            p4_s1_rob_idx_q       <= p4_req_rob_idx_i;
            p4_s1_rob_epoch_q     <= p4_req_rob_epoch_i;

            i2f_s1_valid_q        <= i2f_s1_comb_valid && !i2f_req_squashed;
            i2f_s1_bypass_q       <= i2f_s1_comb_bypass;
            i2f_s1_bypass_data_q  <= i2f_s1_comb_bypass_data;
            i2f_s1_rm_q           <= i2f_s1_comb_rm;
            i2f_s1_is_sp_q        <= i2f_s1_comb_is_sp;
            i2f_s1_s_q            <= i2f_s1_comb_s;
            i2f_s1_mag_q          <= i2f_s1_comb_mag;
            i2f_s1_lzc_q          <= i2f_s1_comb_lzc;
            i2f_s1_prd_fp_q       <= int2fp_req_prd_fp_i;
            i2f_s1_rob_idx_q      <= int2fp_req_rob_idx_i;
            i2f_s1_rob_epoch_q    <= int2fp_req_rob_epoch_i;
        end
    end

    // Lossless circular writeback FIFO for FPRF w0_fp (16 entries)
    localparam int FPRF_FIFO_DEPTH = 16;
    typedef struct packed {
        logic        valid;
        logic [63:0] data;
        fpreg_t      prd_fp;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
        logic [4:0]  fflags;
    } fconv_fprf_buf_t;

    fconv_fprf_buf_t fprf_fifo [FPRF_FIFO_DEPTH];
    logic [3:0] fprf_head;
    logic [3:0] fprf_tail;
    logic [4:0] fprf_count;

    assign fprf_busy_o = (fprf_count >= 5'd10);

    wire fprf_head_squashed = recover_valid_i &&
                              (rob_dist(fprf_fifo[fprf_head].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    wire fprf_pop = (fprf_count > 5'd0) && (!fprf_fifo[fprf_head].valid || fprf_head_squashed || !fprf_wb_busy_i);

    assign fprf_wb_valid_o     = (fprf_count > 5'd0) && fprf_fifo[fprf_head].valid && !fprf_head_squashed && !fprf_wb_busy_i;
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
            fprf_head  <= 4'd0;
            fprf_tail  <= 4'd0;
            fprf_count <= 5'd0;
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
                logic [3:0] cur_head;
                logic [3:0] cur_tail;
                logic [4:0] cur_count;
                logic       push0_squashed, push1_squashed;

                cur_head  = fprf_head;
                cur_tail  = fprf_tail;
                cur_count = fprf_count;

                if (fprf_pop) begin
                    fprf_fifo[cur_head].valid <= 1'b0;
                    cur_head  = cur_head + 4'd1;
                    cur_count = cur_count - 5'd1;
                end

                push0_squashed = recover_valid_i && (rob_dist(push0_entry.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
                push1_squashed = recover_valid_i && (rob_dist(push1_entry.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

                case ({p4_to_fprf_valid && !push0_squashed, int2fp_out_valid && !push1_squashed})
                    2'b11: begin
                        fprf_fifo[cur_tail]        <= push0_entry;
                        fprf_fifo[cur_tail + 4'd1] <= push1_entry;
                        cur_tail  = cur_tail + 4'd2;
                        cur_count = cur_count + 5'd2;
                    end
                    2'b10: begin
                        fprf_fifo[cur_tail]        <= push0_entry;
                        cur_tail  = cur_tail + 4'd1;
                        cur_count = cur_count + 5'd1;
                    end
                    2'b01: begin
                        fprf_fifo[cur_tail]        <= push1_entry;
                        cur_tail  = cur_tail + 4'd1;
                        cur_count = cur_count + 5'd1;
                    end
                    default: ;
                endcase

                fprf_head  <= cur_head;
                fprf_tail  <= cur_tail;
                fprf_count <= cur_count;
            end
        end
    end

    // =========================================================================
    // 3. Float-to-Integer Move, Conversion & Comparison (Stage 1 -> Stage 2 -> PRF)
    // =========================================================================
    logic        f2i_s1_comb_valid;
    logic        f2i_s1_comb_bypass;
    logic [63:0] f2i_s1_comb_bypass_data;
    logic [4:0]  f2i_s1_comb_bypass_fflags;
    logic [2:0]  f2i_s1_comb_rm;
    logic        f2i_s1_comb_is_64;
    logic        f2i_s1_comb_is_signed;
    logic        f2i_s1_comb_s;
    logic [63:0] f2i_s1_comb_mag;
    logic        f2i_s1_comb_g;
    logic        f2i_s1_comb_st;
    logic [63:0] f2i_s1_comb_sat_val;

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
        logic        fcvt_g, fcvt_st;
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
        fcvt_g = '0; fcvt_st = '0;
        sp_in = '0; fcvt_rsh = 0; fcvt_rem_bits = '0;

        f2i_s1_comb_valid         = 1'b0;
        f2i_s1_comb_bypass        = 1'b1;
        f2i_s1_comb_bypass_data   = '0;
        f2i_s1_comb_bypass_fflags = '0;
        f2i_s1_comb_rm            = f2i_rm;
        f2i_s1_comb_is_64         = 1'b0;
        f2i_s1_comb_is_signed     = 1'b0;
        f2i_s1_comb_s             = 1'b0;
        f2i_s1_comb_mag           = 64'd0;
        f2i_s1_comb_g             = 1'b0;
        f2i_s1_comb_st            = 1'b0;
        f2i_s1_comb_sat_val       = 64'd0;

        if (p4_req_valid_i && !p4_req_fp_dest_valid_i) begin
            case (p4_req_subop_i)
                FP_FMV_X_W: begin
                    f2i_s1_comb_valid         = 1'b1;
                    f2i_s1_comb_bypass        = 1'b1;
                    f2i_s1_comb_bypass_data   = {{32{p4_req_rs1_fp_data_i[31]}}, p4_req_rs1_fp_data_i[31:0]};
                    f2i_s1_comb_bypass_fflags = 5'b00000;
                end
                FP_FMV_X_D: begin
                    f2i_s1_comb_valid         = 1'b1;
                    f2i_s1_comb_bypass        = 1'b1;
                    f2i_s1_comb_bypass_data   = p4_req_rs1_fp_data_i;
                    f2i_s1_comb_bypass_fflags = 5'b00000;
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

                    f2i_s1_comb_valid  = 1'b1;
                    f2i_s1_comb_bypass = 1'b1;
                    if (p4_req_subop_i == FP_FEQ_S) begin
                        f2i_s1_comb_bypass_data   = cmp_eq ? 64'd1 : 64'd0;
                        f2i_s1_comb_bypass_fflags = (cmp_snan1 || cmp_snan2) ? 5'b10000 : 5'b00000;
                    end else if (p4_req_subop_i == FP_FLT_S) begin
                        f2i_s1_comb_bypass_data   = cmp_lt ? 64'd1 : 64'd0;
                        f2i_s1_comb_bypass_fflags = (cmp_nan1 || cmp_nan2) ? 5'b10000 : 5'b00000;
                    end else begin
                        f2i_s1_comb_bypass_data   = (cmp_lt || cmp_eq) ? 64'd1 : 64'd0;
                        f2i_s1_comb_bypass_fflags = (cmp_nan1 || cmp_nan2) ? 5'b10000 : 5'b00000;
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

                    f2i_s1_comb_valid  = 1'b1;
                    f2i_s1_comb_bypass = 1'b1;
                    if (p4_req_subop_i == FP_FEQ_D) begin
                        f2i_s1_comb_bypass_data   = cmp_eq ? 64'd1 : 64'd0;
                        f2i_s1_comb_bypass_fflags = (cmp_snan1 || cmp_snan2) ? 5'b10000 : 5'b00000;
                    end else if (p4_req_subop_i == FP_FLT_D) begin
                        f2i_s1_comb_bypass_data   = cmp_lt ? 64'd1 : 64'd0;
                        f2i_s1_comb_bypass_fflags = (cmp_nan1 || cmp_nan2) ? 5'b10000 : 5'b00000;
                    end else begin
                        f2i_s1_comb_bypass_data   = (cmp_lt || cmp_eq) ? 64'd1 : 64'd0;
                        f2i_s1_comb_bypass_fflags = (cmp_nan1 || cmp_nan2) ? 5'b10000 : 5'b00000;
                    end
                end

                // FCLASS (10-bit mask)
                FP_FCLASS_S: begin
                    fclass_op = is_nanbox_valid(p4_req_rs1_fp_data_i) ? p4_req_rs1_fp_data_i[31:0] : FP32_QNAN;
                    fclass_s = fclass_op[31]; fclass_e = {3'd0, fclass_op[30:23]}; fclass_f = {fclass_op[22:0], 29'd0};
                    fclass_mask = 10'd0;
                    if (fclass_op[30:23] == 8'hFF) begin
                        if (fclass_op[22:0] != 23'd0) begin
                            fclass_mask[8] = !fclass_op[22];
                            fclass_mask[9] = fclass_op[22];
                        end else begin
                            fclass_mask[0] = fclass_s;
                            fclass_mask[7] = !fclass_s;
                        end
                    end else if (fclass_op[30:23] == 8'd0) begin
                        if (fclass_op[22:0] == 23'd0) begin
                            fclass_mask[3] = fclass_s;
                            fclass_mask[4] = !fclass_s;
                        end else begin
                            fclass_mask[2] = fclass_s;
                            fclass_mask[5] = !fclass_s;
                        end
                    end else begin
                        fclass_mask[1] = fclass_s;
                        fclass_mask[6] = !fclass_s;
                    end
                    f2i_s1_comb_valid         = 1'b1;
                    f2i_s1_comb_bypass        = 1'b1;
                    f2i_s1_comb_bypass_data   = {54'd0, fclass_mask};
                    f2i_s1_comb_bypass_fflags = 5'b00000;
                end

                FP_FCLASS_D: begin
                    fclass_s = p4_req_rs1_fp_data_i[63]; fclass_e = p4_req_rs1_fp_data_i[62:52]; fclass_f = p4_req_rs1_fp_data_i[51:0];
                    fclass_mask = 10'd0;
                    if (fclass_e == 11'h7FF) begin
                        if (fclass_f != 52'd0) begin
                            fclass_mask[8] = !fclass_f[51];
                            fclass_mask[9] = fclass_f[51];
                        end else begin
                            fclass_mask[0] = fclass_s;
                            fclass_mask[7] = !fclass_s;
                        end
                    end else if (fclass_e == 11'd0) begin
                        if (fclass_f == 52'd0) begin
                            fclass_mask[3] = fclass_s;
                            fclass_mask[4] = !fclass_s;
                        end else begin
                            fclass_mask[2] = fclass_s;
                            fclass_mask[5] = !fclass_s;
                        end
                    end else begin
                        fclass_mask[1] = fclass_s;
                        fclass_mask[6] = !fclass_s;
                    end
                    f2i_s1_comb_valid         = 1'b1;
                    f2i_s1_comb_bypass        = 1'b1;
                    f2i_s1_comb_bypass_data   = {54'd0, fclass_mask};
                    f2i_s1_comb_bypass_fflags = 5'b00000;
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

                    if (!fcvt_is_64 && fcvt_is_signed)
                        fcvt_sat_val = (!fcvt_is_nan && fcvt_s) ? 64'hFFFF_FFFF_8000_0000 : 64'h0000_0000_7FFF_FFFF;
                    else if (!fcvt_is_64 && !fcvt_is_signed)
                        fcvt_sat_val = (!fcvt_is_nan && fcvt_s) ? 64'h0000_0000_0000_0000 : 64'hFFFF_FFFF_FFFF_FFFF;
                    else if (fcvt_is_64 && fcvt_is_signed)
                        fcvt_sat_val = (!fcvt_is_nan && fcvt_s) ? 64'h8000_0000_0000_0000 : 64'h7FFF_FFFF_FFFF_FFFF;
                    else
                        fcvt_sat_val = (!fcvt_is_nan && fcvt_s) ? 64'h0000_0000_0000_0000 : 64'hFFFF_FFFF_FFFF_FFFF;

                    f2i_s1_comb_valid     = 1'b1;
                    f2i_s1_comb_is_64     = fcvt_is_64;
                    f2i_s1_comb_is_signed = fcvt_is_signed;
                    f2i_s1_comb_s         = fcvt_s;
                    f2i_s1_comb_sat_val   = fcvt_sat_val;

                    if (fcvt_is_nan || fcvt_is_inf || (fcvt_exp >= 14'sd64)) begin
                        f2i_s1_comb_bypass        = 1'b1;
                        f2i_s1_comb_bypass_data   = fcvt_sat_val;
                        f2i_s1_comb_bypass_fflags = 5'b10000;
                    end else begin
                        f2i_s1_comb_bypass = 1'b0;
                        if (fcvt_is_zero) begin
                            fcvt_int_mag = 64'd0; fcvt_g = 1'b0; fcvt_st = 1'b0;
                        end else if (fcvt_exp < -14'sd1) begin
                            fcvt_int_mag = 64'd0; fcvt_g = 1'b0; fcvt_st = 1'b1;
                        end else if (fcvt_exp == -14'sd1) begin
                            fcvt_int_mag = 64'd0; fcvt_g = fcvt_sig[52]; fcvt_st = (fcvt_sig[51:0] != 52'd0);
                        end else if (fcvt_exp <= 14'sd52) begin
                            fcvt_rsh     = 32'(unsigned'(14'sd52 - fcvt_exp));
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

                        f2i_s1_comb_mag = fcvt_int_mag;
                        f2i_s1_comb_g   = fcvt_g;
                        f2i_s1_comb_st  = fcvt_st;
                    end
                end

                default: ;
            endcase
        end
    end

    // Stage 1 -> Stage 2 Pipeline Registers (F2I -> PRF)
    logic        f2i_s1_valid_q;
    logic        f2i_s1_bypass_q;
    logic [63:0] f2i_s1_bypass_data_q;
    logic [4:0]  f2i_s1_bypass_fflags_q;
    logic [2:0]  f2i_s1_rm_q;
    logic        f2i_s1_is_64_q;
    logic        f2i_s1_is_signed_q;
    logic        f2i_s1_s_q;
    logic [63:0] f2i_s1_mag_q;
    logic        f2i_s1_g_q;
    logic        f2i_s1_st_q;
    logic [63:0] f2i_s1_sat_val_q;
    preg_t       f2i_s1_pnew_q;
    rob_idx_t    f2i_s1_rob_idx_q;
    rob_epoch_t  f2i_s1_rob_epoch_q;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            f2i_s1_valid_q         <= 1'b0;
            f2i_s1_bypass_q        <= 1'b1;
            f2i_s1_bypass_data_q   <= 64'd0;
            f2i_s1_bypass_fflags_q <= 5'd0;
            f2i_s1_rm_q            <= 3'd0;
            f2i_s1_is_64_q         <= 1'b0;
            f2i_s1_is_signed_q     <= 1'b0;
            f2i_s1_s_q             <= 1'b0;
            f2i_s1_mag_q           <= 64'd0;
            f2i_s1_g_q             <= 1'b0;
            f2i_s1_st_q            <= 1'b0;
            f2i_s1_sat_val_q       <= 64'd0;
            f2i_s1_pnew_q          <= '0;
            f2i_s1_rob_idx_q       <= '0;
            f2i_s1_rob_epoch_q     <= '0;
        end else begin
            logic f2i_req_squashed;
            f2i_req_squashed = recover_valid_i && (rob_dist(p4_req_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

            f2i_s1_valid_q         <= f2i_s1_comb_valid && !f2i_req_squashed;
            f2i_s1_bypass_q        <= f2i_s1_comb_bypass;
            f2i_s1_bypass_data_q   <= f2i_s1_comb_bypass_data;
            f2i_s1_bypass_fflags_q <= f2i_s1_comb_bypass_fflags;
            f2i_s1_rm_q            <= f2i_s1_comb_rm;
            f2i_s1_is_64_q         <= f2i_s1_comb_is_64;
            f2i_s1_is_signed_q     <= f2i_s1_comb_is_signed;
            f2i_s1_s_q             <= f2i_s1_comb_s;
            f2i_s1_mag_q           <= f2i_s1_comb_mag;
            f2i_s1_g_q             <= f2i_s1_comb_g;
            f2i_s1_st_q            <= f2i_s1_comb_st;
            f2i_s1_sat_val_q       <= f2i_s1_comb_sat_val;
            f2i_s1_pnew_q          <= p4_req_pnew_i;
            f2i_s1_rob_idx_q       <= p4_req_rob_idx_i;
            f2i_s1_rob_epoch_q     <= p4_req_rob_epoch_i;
        end
    end

    // F2I Stage 2 Combinational Rounding, Range Check & Sign Negation
    // Parallel round+0 / round+1 avoids cascading two 64-bit adders in Stage 2:
    // -(mag + 1) == ~mag (zero-adder negate for the round-up negative case).
    logic        f2i_comb_valid;
    logic [63:0] f2i_comb_data;
    logic [4:0]  f2i_comb_fflags;
    preg_t       f2i_comb_pnew;
    rob_idx_t    f2i_comb_rob_idx;
    rob_epoch_t  f2i_comb_rob_epoch;

    always_comb begin
        logic        fcvt_inc, fcvt_inexact;
        logic [64:0] rmag_p0, rmag_p1;
        logic        in_range_p0, in_range_p1, fcvt_in_range;
        logic [63:0] sres_p0, sres_p1, fcvt_sres;

        fcvt_inc      = 1'b0;
        fcvt_inexact  = 1'b0;
        rmag_p0       = 65'd0;
        rmag_p1       = 65'd0;
        in_range_p0   = 1'b0;
        in_range_p1   = 1'b0;
        fcvt_in_range = 1'b0;
        sres_p0       = 64'd0;
        sres_p1       = 64'd0;
        fcvt_sres     = 64'd0;

        f2i_comb_valid     = f2i_s1_valid_q;
        f2i_comb_pnew      = f2i_s1_pnew_q;
        f2i_comb_rob_idx   = f2i_s1_rob_idx_q;
        f2i_comb_rob_epoch = f2i_s1_rob_epoch_q;

        if (f2i_s1_bypass_q) begin
            f2i_comb_data   = f2i_s1_bypass_data_q;
            f2i_comb_fflags = f2i_s1_bypass_fflags_q;
        end else begin
            fcvt_inexact = f2i_s1_g_q || f2i_s1_st_q;
            fcvt_inc     = fp_round_up(f2i_s1_rm_q, f2i_s1_s_q, f2i_s1_mag_q[0], f2i_s1_g_q, f2i_s1_st_q);
            rmag_p0      = {1'b0, f2i_s1_mag_q};
            rmag_p1      = rmag_p0 + 65'd1;

            in_range_p0   = fcvt_check_range(f2i_s1_is_64_q, f2i_s1_is_signed_q, f2i_s1_s_q, rmag_p0);
            in_range_p1   = fcvt_check_range(f2i_s1_is_64_q, f2i_s1_is_signed_q, f2i_s1_s_q, rmag_p1);
            fcvt_in_range = fcvt_inc ? in_range_p1 : in_range_p0;

            sres_p0   = f2i_s1_s_q ? (~f2i_s1_mag_q + 64'd1) : f2i_s1_mag_q;
            sres_p1   = f2i_s1_s_q ? (~f2i_s1_mag_q)         : rmag_p1[63:0];
            fcvt_sres = fcvt_inc ? sres_p1 : sres_p0;

            if (!fcvt_in_range) begin
                f2i_comb_data   = f2i_s1_sat_val_q;
                f2i_comb_fflags = 5'b10000;
            end else begin
                f2i_comb_data   = f2i_s1_is_64_q ? fcvt_sres : {{32{fcvt_sres[31]}}, fcvt_sres[31:0]};
                f2i_comb_fflags = {4'b0000, fcvt_inexact};
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Lossless Circular Writeback FIFO for Float-to-Integer (16 entries)
    // -------------------------------------------------------------------------
    localparam int F2I_FIFO_DEPTH = 16;
    typedef struct packed {
        logic        valid;
        logic [63:0] data;
        logic [4:0]  fflags;
        preg_t       pnew;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
    } f2i_entry_t;

    f2i_entry_t f2i_fifo [F2I_FIFO_DEPTH];
    logic [3:0] f2i_head;
    logic [3:0] f2i_tail;
    logic [4:0] f2i_count;

    assign prf_busy_o = (f2i_count >= 5'd10);

    wire prf_head_squashed = recover_valid_i &&
                             (rob_dist(f2i_fifo[f2i_head].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    wire f2i_pop = (f2i_count > 5'd0) && (!f2i_fifo[f2i_head].valid || prf_head_squashed || !int_wb_busy_i);

    assign prf_wb_valid_o     = (f2i_count > 5'd0) && f2i_fifo[f2i_head].valid && !prf_head_squashed && !int_wb_busy_i;
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
            f2i_head  <= 4'd0;
            f2i_tail  <= 4'd0;
            f2i_count <= 5'd0;
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
                logic [3:0] cur_head;
                logic [3:0] cur_tail;
                logic [4:0] cur_count;
                logic       f2i_push_squashed;

                cur_head  = f2i_head;
                cur_tail  = f2i_tail;
                cur_count = f2i_count;

                if (f2i_pop) begin
                    f2i_fifo[cur_head].valid <= 1'b0;
                    cur_head  = cur_head + 4'd1;
                    cur_count = cur_count - 5'd1;
                end

                f2i_push_squashed = recover_valid_i && (rob_dist(f2i_push_entry.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

                if (f2i_comb_valid && !f2i_push_squashed) begin
                    f2i_fifo[cur_tail] <= f2i_push_entry;
                    cur_tail  = cur_tail + 4'd1;
                    cur_count = cur_count + 5'd1;
                end

                f2i_head  <= cur_head;
                f2i_tail  <= cur_tail;
                f2i_count <= cur_count;
            end
        end
    end

endmodule

`endif // FURSOY_S1_FCONV_SV
