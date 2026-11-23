`ifndef FURSOY_S1_FMA_SV
`define FURSOY_S1_FMA_SV

// =============================================================================
// Fursoy Slice-1 Pipelined FMA Unit — Milestone 8 Phase B
// =============================================================================
// IEEE 754-2008 compliant pipelined Floating-Point Multiply-Accumulate (FMA) unit.
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 6.2, Section 11
//
// Invariants:
// - FP64 latency: exactly 4 cycles pipelined, 1.0 result/cycle sustained throughput.
// - FP32 latency: exactly 3 cycles pipelined, 1.0 result/cycle sustained throughput.
// - Strict NaN boxing: 32-bit floats write upper 32 bits [63:32] as 32'hFFFFFFFF.
//   Unboxed FP32 inputs evaluate as canonical quiet NaN (32'h7FC00000).
// - Rounding modes: RNE (000), RTZ (001), RDN (010), RUP (011), RMM (100), DYN (111).
// - Full subnormal precision without FTZ/DAZ shortcuts.
// - Accrued exception flags: NV (invalid), DZ (div by zero), OF (overflow), UF (underflow), NX (inexact).
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_fma
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Flush & Branch Recovery
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    // CSR dynamic rounding mode
    input  logic [2:0]        fcsr_frm_i,

    // Issue Request from Port 4
    input  logic              req_valid_i,
    input  uop_subop_t        req_subop_i,
    input  logic [2:0]        req_frm_i,
    input  logic [63:0]       req_rs1_data_i,
    input  logic [63:0]       req_rs2_data_i,
    input  logic [63:0]       req_rs3_data_i,
    input  fpreg_t            req_prd_fp_i,
    input  rob_idx_t          req_rob_idx_i,
    input  rob_epoch_t        req_rob_epoch_i,

    // Pipeline Writeback Output (Stage WB)
    output logic              wb_valid_o,
    output logic [63:0]       wb_data_o,
    output fpreg_t            wb_prd_fp_o,
    output rob_idx_t          wb_rob_idx_o,
    output rob_epoch_t        wb_rob_epoch_o,
    output logic [4:0]        wb_fflags_o
);

    // -------------------------------------------------------------------------
    // Helper Functions: Classification & Unpacking
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic is_nanbox_valid(input logic [63:0] val);
        return (val[63:32] == 32'hFFFF_FFFF);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;
    localparam logic [63:0] FP64_QNAN = 64'h7FF8_0000_0000_0000;

    function automatic logic is_sp(input uop_subop_t op);
        case (op)
            FP_FMADD_S, FP_FMSUB_S, FP_FNMSUB_S, FP_FNMADD_S,
            FP_FADD_S, FP_FSUB_S, FP_FMUL_S: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Double-Precision Core Calculation Functions
    // -------------------------------------------------------------------------
    // Unpack FP64: {sign, exp(11), mantissa(53 with implicit bit)}
    function automatic void unpack_dp(
        input  logic [63:0] val,
        output logic        sign,
        output logic [10:0] exp,
        output logic [52:0] mant,
        output logic        is_nan,
        output logic        is_snan,
        output logic        is_inf,
        output logic        is_zero,
        output logic        is_subnorm
    );
        sign = val[63];
        exp  = val[62:52];
        if (exp == 11'h7FF) begin
            is_inf  = (val[51:0] == 52'd0);
            is_nan  = (val[51:0] != 52'd0);
            is_snan = is_nan && !val[51];
            is_zero = 1'b0;
            is_subnorm = 1'b0;
            mant = {1'b1, val[51:0]};
        end else if (exp == 11'd0) begin
            is_inf  = 1'b0;
            is_nan  = 1'b0;
            is_snan = 1'b0;
            is_zero = (val[51:0] == 52'd0);
            is_subnorm = !is_zero;
            mant = {1'b0, val[51:0]};
        end else begin
            is_inf  = 1'b0;
            is_nan  = 1'b0;
            is_snan = 1'b0;
            is_zero = 1'b0;
            is_subnorm = 1'b0;
            mant = {1'b1, val[51:0]};
        end
    endfunction

    // Unpack FP32 (with strict NaN-box verification)
    function automatic void unpack_sp(
        input  logic [63:0] raw_val,
        output logic        sign,
        output logic [7:0]  exp,
        output logic [23:0] mant,
        output logic        is_nan,
        output logic        is_snan,
        output logic        is_inf,
        output logic        is_zero,
        output logic        is_subnorm
    );
        logic [31:0] val;
        if (!is_nanbox_valid(raw_val)) begin
            val = FP32_QNAN;
        end else begin
            val = raw_val[31:0];
        end

        sign = val[31];
        exp  = val[30:23];
        if (exp == 8'hFF) begin
            is_inf  = (val[22:0] == 23'd0);
            is_nan  = (val[22:0] != 23'd0);
            is_snan = is_nan && !val[22];
            is_zero = 1'b0;
            is_subnorm = 1'b0;
            mant = {1'b1, val[22:0]};
        end else if (exp == 8'd0) begin
            is_inf  = 1'b0;
            is_nan  = 1'b0;
            is_snan = 1'b0;
            is_zero = (val[22:0] == 23'd0);
            is_subnorm = !is_zero;
            mant = {1'b0, val[22:0]};
        end else begin
            is_inf  = 1'b0;
            is_nan  = 1'b0;
            is_snan = 1'b0;
            is_zero = 1'b0;
            is_subnorm = 1'b0;
            mant = {1'b1, val[22:0]};
        end
    endfunction

    // -------------------------------------------------------------------------
    // Stage 1 (EX1): Operands Capture, Decode, Unpack & Multiplication
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic              valid;
        uop_subop_t        subop;
        logic [2:0]        eff_rm;
        fpreg_t            prd_fp;
        rob_idx_t          rob_idx;
        rob_epoch_t        rob_epoch;
        logic              is_single;

        // DP Unpacked state
        logic              sign_a, sign_b, sign_c;
        logic signed [13:0] exp_prod; // exp_a + exp_b - bias
        logic signed [13:0] exp_c;
        logic [105:0]      prod_dp;   // 53 x 53 mantissa product
        logic [52:0]       mant_c_dp;
        logic              eff_sub_dp;
        logic              sign_prod_dp;
        logic              zero_c_dp;

        // SP Unpacked state
        logic signed [11:0] exp_prod_sp;
        logic signed [11:0] exp_c_sp;
        logic [47:0]       prod_sp;   // 24 x 24 mantissa product
        logic [23:0]       mant_c_sp;
        logic              eff_sub_sp;
        logic              sign_prod_sp;
        logic              zero_c_sp;

        // Special condition flags
        logic              special_valid;
        logic [63:0]       special_res;
        logic [4:0]        special_flags;
    } s1_reg_t;

    /* verilator lint_off UNUSEDSIGNAL */
    s1_reg_t s1_q;
    /* verilator lint_on UNUSEDSIGNAL */

    // Combinational evaluation for Stage 1
    s1_reg_t s1_next;

    always_comb begin
        logic [2:0] eff_rm;
        eff_rm = (req_frm_i == 3'b111) ? fcsr_frm_i : req_frm_i;

        s1_next = '0;
        s1_next.valid     = req_valid_i;
        s1_next.subop     = req_subop_i;
        s1_next.eff_rm    = eff_rm;
        s1_next.prd_fp    = req_prd_fp_i;
        s1_next.rob_idx   = req_rob_idx_i;
        s1_next.rob_epoch = req_rob_epoch_i;
        s1_next.is_single = is_sp(req_subop_i);

        if (req_valid_i) begin
            if (s1_next.is_single) begin
                // --- Single-Precision EX1 ---
                logic s_a, s_b, s_c;
                logic [7:0] e_a, e_b, e_c;
                logic [23:0] m_a, m_b, m_c;
                logic nan_a, nan_b, nan_c, snan_a, snan_b, snan_c;
                logic inf_a, inf_b, inf_c, zero_a, zero_b, zero_c;
                /* verilator lint_off UNUSEDSIGNAL */
                logic sub_a, sub_b, sub_c;
                /* verilator lint_on UNUSEDSIGNAL */

                logic [63:0] op1, op2, op3;
                op1 = req_rs1_data_i;

                // Adjust operands based on operation:
                // FADD: rs1 * 1.0 + rs2
                // FSUB: rs1 * 1.0 - rs2
                // FMUL: rs1 * rs2 + 0.0
                case (req_subop_i)
                    FP_FADD_S: begin
                        op2 = {32'hFFFF_FFFF, 32'h3F80_0000}; // 1.0f
                        op3 = req_rs2_data_i;
                    end
                    FP_FSUB_S: begin
                        op2 = {32'hFFFF_FFFF, 32'h3F80_0000}; // 1.0f
                        op3 = {req_rs2_data_i[63:32], ~req_rs2_data_i[31], req_rs2_data_i[30:0]}; // -rs2
                    end
                    FP_FMUL_S: begin
                        op2 = req_rs2_data_i;
                        // Match product sign so FMUL zero/underflow always preserves s_a ^ s_b
                        op3 = {32'hFFFF_FFFF, (req_rs1_data_i[31] ^ req_rs2_data_i[31]), 31'd0};
                    end
                    FP_FMSUB_S: begin
                        op2 = req_rs2_data_i;
                        op3 = {req_rs3_data_i[63:32], ~req_rs3_data_i[31], req_rs3_data_i[30:0]}; // -rs3
                    end
                    FP_FNMSUB_S: begin // -(rs1*rs2) + rs3
                        op2 = {req_rs2_data_i[63:32], ~req_rs2_data_i[31], req_rs2_data_i[30:0]}; // negate prod
                        op3 = req_rs3_data_i;
                    end
                    FP_FNMADD_S: begin // -(rs1*rs2) - rs3
                        op2 = {req_rs2_data_i[63:32], ~req_rs2_data_i[31], req_rs2_data_i[30:0]};
                        op3 = {req_rs3_data_i[63:32], ~req_rs3_data_i[31], req_rs3_data_i[30:0]};
                    end
                    default: begin // FMADD_S
                        op2 = req_rs2_data_i;
                        op3 = req_rs3_data_i;
                    end
                endcase

                unpack_sp(op1, s_a, e_a, m_a, nan_a, snan_a, inf_a, zero_a, sub_a);
                unpack_sp(op2, s_b, e_b, m_b, nan_b, snan_b, inf_b, zero_b, sub_b);
                unpack_sp(op3, s_c, e_c, m_c, nan_c, snan_c, inf_c, zero_c, sub_c);

                s1_next.sign_a = s_a;
                s1_next.sign_b = s_b;
                s1_next.sign_c = s_c;
                s1_next.sign_prod_sp = s_a ^ s_b;
                s1_next.eff_sub_sp   = (s_a ^ s_b) ^ s_c;

                // Exponent arithmetic
                s1_next.exp_prod_sp = signed'(12'(e_a == 8'd0 ? 12'sd1 : 12'(e_a))) +
                                      signed'(12'(e_b == 8'd0 ? 12'sd1 : 12'(e_b))) - 12'sd127;
                s1_next.exp_c_sp    = signed'(12'(e_c == 8'd0 ? 12'sd1 : 12'(e_c)));

                // Multiply mantissas
                s1_next.prod_sp    = 48'(m_a) * 48'(m_b);
                s1_next.mant_c_sp  = m_c;
                s1_next.zero_c_sp  = zero_c;

                // Special case detection
                if (nan_a || nan_b || nan_c) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {32'hFFFF_FFFF, FP32_QNAN};
                    s1_next.special_flags = (snan_a || snan_b || snan_c) ? 5'b10000 : 5'b00000; // NV
                end else if ((inf_a && zero_b) || (zero_a && inf_b)) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {32'hFFFF_FFFF, FP32_QNAN};
                    s1_next.special_flags = 5'b10000; // NV on 0 * inf
                end else if ((inf_a || inf_b) && inf_c && s1_next.eff_sub_sp) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {32'hFFFF_FFFF, FP32_QNAN};
                    s1_next.special_flags = 5'b10000; // NV on inf - inf
                end else if (inf_a || inf_b) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {32'hFFFF_FFFF, s1_next.sign_prod_sp, 8'hFF, 23'd0};
                    s1_next.special_flags = 5'b00000;
                end else if (inf_c) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {32'hFFFF_FFFF, s_c, 8'hFF, 23'd0};
                    s1_next.special_flags = 5'b00000;
                end else if ((zero_a || zero_b) && zero_c) begin
                    logic res_sign;
                    if (s1_next.eff_sub_sp) begin
                        res_sign = (eff_rm == 3'b010) ? 1'b1 : 1'b0; // -0 in RDN
                    end else begin
                        res_sign = s1_next.sign_prod_sp;
                    end
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {32'hFFFF_FFFF, res_sign, 31'd0};
                    s1_next.special_flags = 5'b00000;
                end else if (zero_a || zero_b) begin
                    // Exact 0 + finite non-zero c = c (no rounding, no flags)
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {32'hFFFF_FFFF, s_c, e_c, m_c[22:0]};
                    s1_next.special_flags = 5'b00000;
                end
            end else begin
                // --- Double-Precision EX1 ---
                logic s_a, s_b, s_c;
                logic [10:0] e_a, e_b, e_c;
                logic [52:0] m_a, m_b, m_c;
                logic nan_a, nan_b, nan_c, snan_a, snan_b, snan_c;
                logic inf_a, inf_b, inf_c, zero_a, zero_b, zero_c;
                /* verilator lint_off UNUSEDSIGNAL */
                logic sub_a, sub_b, sub_c;
                /* verilator lint_on UNUSEDSIGNAL */

                logic [63:0] op1, op2, op3;
                op1 = req_rs1_data_i;

                case (req_subop_i)
                    FP_FADD_D: begin
                        op2 = 64'h3FF0_0000_0000_0000; // 1.0
                        op3 = req_rs2_data_i;
                    end
                    FP_FSUB_D: begin
                        op2 = 64'h3FF0_0000_0000_0000; // 1.0
                        op3 = {~req_rs2_data_i[63], req_rs2_data_i[62:0]}; // -rs2
                    end
                    FP_FMUL_D: begin
                        op2 = req_rs2_data_i;
                        // Match product sign so FMUL zero/underflow always preserves s_a ^ s_b
                        op3 = {(req_rs1_data_i[63] ^ req_rs2_data_i[63]), 63'd0};
                    end
                    FP_FMSUB_D: begin
                        op2 = req_rs2_data_i;
                        op3 = {~req_rs3_data_i[63], req_rs3_data_i[62:0]}; // -rs3
                    end
                    FP_FNMSUB_D: begin
                        op2 = {~req_rs2_data_i[63], req_rs2_data_i[62:0]};
                        op3 = req_rs3_data_i;
                    end
                    FP_FNMADD_D: begin
                        op2 = {~req_rs2_data_i[63], req_rs2_data_i[62:0]};
                        op3 = {~req_rs3_data_i[63], req_rs3_data_i[62:0]};
                    end
                    default: begin // FMADD_D
                        op2 = req_rs2_data_i;
                        op3 = req_rs3_data_i;
                    end
                endcase

                unpack_dp(op1, s_a, e_a, m_a, nan_a, snan_a, inf_a, zero_a, sub_a);
                unpack_dp(op2, s_b, e_b, m_b, nan_b, snan_b, inf_b, zero_b, sub_b);
                unpack_dp(op3, s_c, e_c, m_c, nan_c, snan_c, inf_c, zero_c, sub_c);

                s1_next.sign_a = s_a;
                s1_next.sign_b = s_b;
                s1_next.sign_c = s_c;
                s1_next.sign_prod_dp = s_a ^ s_b;
                s1_next.eff_sub_dp   = (s_a ^ s_b) ^ s_c;

                s1_next.exp_prod = signed'(14'(e_a == 11'd0 ? 14'sd1 : 14'(e_a))) +
                                   signed'(14'(e_b == 11'd0 ? 14'sd1 : 14'(e_b))) - 14'sd1023;
                s1_next.exp_c    = signed'(14'(e_c == 11'd0 ? 14'sd1 : 14'(e_c)));

                s1_next.prod_dp   = 106'(m_a) * 106'(m_b);
                s1_next.mant_c_dp = m_c;
                s1_next.zero_c_dp = zero_c;

                // Special case detection
                if (nan_a || nan_b || nan_c) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = FP64_QNAN;
                    s1_next.special_flags = (snan_a || snan_b || snan_c) ? 5'b10000 : 5'b00000;
                end else if ((inf_a && zero_b) || (zero_a && inf_b)) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = FP64_QNAN;
                    s1_next.special_flags = 5'b10000; // NV
                end else if ((inf_a || inf_b) && inf_c && s1_next.eff_sub_dp) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = FP64_QNAN;
                    s1_next.special_flags = 5'b10000; // NV
                end else if (inf_a || inf_b) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {s1_next.sign_prod_dp, 11'h7FF, 52'd0};
                    s1_next.special_flags = 5'b00000;
                end else if (inf_c) begin
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {s_c, 11'h7FF, 52'd0};
                    s1_next.special_flags = 5'b00000;
                end else if ((zero_a || zero_b) && zero_c) begin
                    logic res_sign;
                    if (s1_next.eff_sub_dp) begin
                        res_sign = (eff_rm == 3'b010) ? 1'b1 : 1'b0;
                    end else begin
                        res_sign = s1_next.sign_prod_dp;
                    end
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {res_sign, 63'd0};
                    s1_next.special_flags = 5'b00000;
                end else if (zero_a || zero_b) begin
                    // Exact 0 + finite non-zero c = c (no rounding, no flags)
                    s1_next.special_valid = 1'b1;
                    s1_next.special_res   = {s_c, e_c, m_c[51:0]};
                    s1_next.special_flags = 5'b00000;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2 (EX2): Exponent Alignment, Shift & Addition / Subtraction
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic              valid;
        uop_subop_t        subop;
        logic [2:0]        eff_rm;
        fpreg_t            prd_fp;
        rob_idx_t          rob_idx;
        rob_epoch_t        rob_epoch;
        logic              is_single;

        // DP Sum Stage 2
        logic              sign_res_dp;
        logic signed [13:0] exp_res_dp;
        logic [163:0]      sum_mant_dp; // Product aligned + addend
        logic              sticky_dp;

        // SP Sum Stage 2
        logic              sign_res_sp;
        logic signed [11:0] exp_res_sp;
        logic [79:0]       sum_mant_sp;
        logic              sticky_sp;

        logic              special_valid;
        logic [63:0]       special_res;
        logic [4:0]        special_flags;
    } s2_reg_t;

    s2_reg_t s2_q;
    s2_reg_t s2_next;

    always_comb begin
        logic signed [11:0] exp_diff_sp;
        logic [79:0] p_wide_sp, c_wide_sp;
        logic sticky_sp_s2, c_was_shifted_sp;
        logic [111:0] temp_c_sp;
        logic signed [11:0] shift_p_sp;
        logic [111:0] temp_p_sp;

        logic signed [13:0] exp_diff_dp;
        logic [163:0] p_wide_dp, c_wide_dp;
        logic sticky_dp_s2, c_was_shifted_dp;
        logic [227:0] temp_c_dp;
        logic signed [13:0] shift_p_dp;
        logic [227:0] temp_p_dp;

        exp_diff_sp = '0; p_wide_sp = '0; c_wide_sp = '0; sticky_sp_s2 = '0; c_was_shifted_sp = 1'b0; temp_c_sp = '0; shift_p_sp = '0; temp_p_sp = '0;
        exp_diff_dp = '0; p_wide_dp = '0; c_wide_dp = '0; sticky_dp_s2 = '0; c_was_shifted_dp = 1'b0; temp_c_dp = '0; shift_p_dp = '0; temp_p_dp = '0;

        s2_next = '0;
        s2_next.valid         = s1_q.valid;
        s2_next.subop         = s1_q.subop;
        s2_next.eff_rm        = s1_q.eff_rm;
        s2_next.prd_fp        = s1_q.prd_fp;
        s2_next.rob_idx       = s1_q.rob_idx;
        s2_next.rob_epoch     = s1_q.rob_epoch;
        s2_next.is_single     = s1_q.is_single;
        s2_next.special_valid = s1_q.special_valid;
        s2_next.special_res   = s1_q.special_res;
        s2_next.special_flags = s1_q.special_flags;

        if (s1_q.valid && !s1_q.special_valid) begin
            if (s1_q.is_single) begin
                // --- SP Alignment & Adder ---
                // Product has 48 bits, implicit radix point at bit 46.
                // Weight 1.0 is at bit 77 for both p and c.
                p_wide_sp = {1'b0, s1_q.prod_sp, 31'd0};
                c_wide_sp = '0;
                sticky_sp_s2 = 1'b0;

                if (s1_q.zero_c_sp) begin
                    // Addend c == 0 (including FMUL): preserve exact product exponent
                    s2_next.exp_res_sp  = s1_q.exp_prod_sp;
                    s2_next.sum_mant_sp = p_wide_sp;
                    s2_next.sign_res_sp = s1_q.sign_prod_sp;
                    s2_next.sticky_sp   = 1'b0;
                end else begin
                    exp_diff_sp = s1_q.exp_prod_sp - s1_q.exp_c_sp;
                    if (exp_diff_sp >= 0) begin
                        // Addend c is smaller, shift c right
                        c_was_shifted_sp = 1'b1;
                        s2_next.exp_res_sp = s1_q.exp_prod_sp;
                        if (exp_diff_sp > 12'sd60) begin
                            c_wide_sp = '0;
                            sticky_sp_s2 = (s1_q.mant_c_sp != 24'd0);
                        end else begin
                            temp_c_sp = {2'b0, s1_q.mant_c_sp, 54'd0, 32'd0} >> exp_diff_sp;
                            c_wide_sp = temp_c_sp[111:32];
                            sticky_sp_s2 = (temp_c_sp[31:0] != 32'd0);
                        end
                    end else begin
                        // Product is smaller, shift p right
                        c_was_shifted_sp = 1'b0;
                        shift_p_sp = -exp_diff_sp;
                        s2_next.exp_res_sp = s1_q.exp_c_sp;
                        c_wide_sp = {2'b0, s1_q.mant_c_sp, 54'd0};
                        if (shift_p_sp > 12'sd70) begin
                            p_wide_sp = '0;
                            sticky_sp_s2 = (s1_q.prod_sp != 48'd0);
                        end else begin
                            temp_p_sp = {1'b0, s1_q.prod_sp, 31'd0, 32'd0} >> shift_p_sp;
                            p_wide_sp = temp_p_sp[111:32];
                            sticky_sp_s2 = (temp_p_sp[31:0] != 32'd0);
                        end
                    end

                    if (!s1_q.eff_sub_sp) begin
                        s2_next.sum_mant_sp = p_wide_sp + c_wide_sp;
                        s2_next.sign_res_sp = s1_q.sign_prod_sp;
                    end else begin
                        // Effective subtraction with exact sticky-borrow:
                        // If the subtrahend has shifted-out sticky bits (B + eps),
                        // A - (B + eps) = (A - B - 1) + (1 - eps) -> borrow 1, sticky=1.
                        if (p_wide_sp > c_wide_sp) begin
                            s2_next.sum_mant_sp = p_wide_sp - c_wide_sp - (c_was_shifted_sp && sticky_sp_s2 ? 80'd1 : 80'd0);
                            s2_next.sign_res_sp = s1_q.sign_prod_sp;
                        end else if (c_wide_sp > p_wide_sp) begin
                            s2_next.sum_mant_sp = c_wide_sp - p_wide_sp - (!c_was_shifted_sp && sticky_sp_s2 ? 80'd1 : 80'd0);
                            s2_next.sign_res_sp = s1_q.sign_c;
                        end else begin
                            s2_next.sum_mant_sp = 80'd0;
                            s2_next.sign_res_sp = c_was_shifted_sp ? s1_q.sign_c : s1_q.sign_prod_sp;
                        end
                    end
                    s2_next.sticky_sp = sticky_sp_s2;
                end
            end else begin
                // --- DP Alignment & Adder ---
                // Product has 106 bits, implicit radix point at bit 104.
                // Weight 1.0 is at bit 161 for both p and c.
                p_wide_dp = {1'b0, s1_q.prod_dp, 57'd0};
                c_wide_dp = '0;
                sticky_dp_s2 = 1'b0;

                if (s1_q.zero_c_dp) begin
                    // Addend c == 0 (including FMUL): preserve exact product exponent
                    s2_next.exp_res_dp  = s1_q.exp_prod;
                    s2_next.sum_mant_dp = p_wide_dp;
                    s2_next.sign_res_dp = s1_q.sign_prod_dp;
                    s2_next.sticky_dp   = 1'b0;
                end else begin
                    exp_diff_dp = s1_q.exp_prod - s1_q.exp_c;
                    if (exp_diff_dp >= 0) begin
                        c_was_shifted_dp = 1'b1;
                        s2_next.exp_res_dp = s1_q.exp_prod;
                        if (exp_diff_dp > 14'sd120) begin
                            c_wide_dp = '0;
                            sticky_dp_s2 = (s1_q.mant_c_dp != 53'd0);
                        end else begin
                            temp_c_dp = {2'b0, s1_q.mant_c_dp, 109'd0, 64'd0} >> exp_diff_dp;
                            c_wide_dp = temp_c_dp[227:64];
                            sticky_dp_s2 = (temp_c_dp[63:0] != 64'd0);
                        end
                    end else begin
                        c_was_shifted_dp = 1'b0;
                        shift_p_dp = -exp_diff_dp;
                        s2_next.exp_res_dp = s1_q.exp_c;
                        c_wide_dp = {2'b0, s1_q.mant_c_dp, 109'd0};
                        if (shift_p_dp > 14'sd130) begin
                            p_wide_dp = '0;
                            sticky_dp_s2 = (s1_q.prod_dp != 106'd0);
                        end else begin
                            temp_p_dp = {1'b0, s1_q.prod_dp, 57'd0, 64'd0} >> shift_p_dp;
                            p_wide_dp = temp_p_dp[227:64];
                            sticky_dp_s2 = (temp_p_dp[63:0] != 64'd0);
                        end
                    end

                    if (!s1_q.eff_sub_dp) begin
                        s2_next.sum_mant_dp = p_wide_dp + c_wide_dp;
                        s2_next.sign_res_dp = s1_q.sign_prod_dp;
                    end else begin
                        if (p_wide_dp > c_wide_dp) begin
                            s2_next.sum_mant_dp = p_wide_dp - c_wide_dp - (c_was_shifted_dp && sticky_dp_s2 ? 164'd1 : 164'd0);
                            s2_next.sign_res_dp = s1_q.sign_prod_dp;
                        end else if (c_wide_dp > p_wide_dp) begin
                            s2_next.sum_mant_dp = c_wide_dp - p_wide_dp - (!c_was_shifted_dp && sticky_dp_s2 ? 164'd1 : 164'd0);
                            s2_next.sign_res_dp = s1_q.sign_c;
                        end else begin
                            s2_next.sum_mant_dp = 164'd0;
                            s2_next.sign_res_dp = c_was_shifted_dp ? s1_q.sign_c : s1_q.sign_prod_dp;
                        end
                    end
                    s2_next.sticky_dp = sticky_dp_s2;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3 (EX3): Normalization, SP Rounding & Output, DP Normalization
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic              valid;
        uop_subop_t        subop;
        logic [2:0]        eff_rm;
        fpreg_t            prd_fp;
        rob_idx_t          rob_idx;
        rob_epoch_t        rob_epoch;

        // DP State for Stage 4
        logic              sign_dp;
        logic signed [13:0] exp_dp;
        logic [54:0]       mant_norm_dp; // 53-bit mantissa + guard + round
        logic              sticky_dp;
        logic              zero_dp;

        logic              special_valid;
        logic [63:0]       special_res;
        logic [4:0]        special_flags;
    } s3_reg_t;

    /* verilator lint_off UNUSEDSIGNAL */
    s3_reg_t s3_q;
    /* verilator lint_on UNUSEDSIGNAL */
    s3_reg_t s3_next;

    // SP final results produced in Stage 3 (3-cycle latency)
    logic              sp_done_valid;
    logic [63:0]       sp_done_data;
    logic [4:0]        sp_done_fflags;
    fpreg_t            sp_done_prd_fp;
    rob_idx_t          sp_done_rob_idx;
    rob_epoch_t        sp_done_rob_epoch;

    always_comb begin
        int lzc_sp;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [79:0] norm_mant_sp;
        /* verilator lint_on UNUSEDSIGNAL */
        logic signed [11:0] norm_exp_sp;
        int lzc_dp;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [163:0] norm_mant_dp;
        /* verilator lint_on UNUSEDSIGNAL */
        logic signed [13:0] norm_exp_dp;
        logic guard, round_bit, sticky_bit;
        logic [24:0] final_mant;
        logic [7:0] final_exp;
        logic round_up;
        logic inexact, overflow, underflow;
        logic tiny_after_rnd_sp, unb_all1_sp, unb_inexact_sp, unb_inc_sp;
        logic signed [11:0] rshift;
        logic [47:0] temp_s;
        logic s_zero;

        lzc_sp = 0;
        norm_mant_sp = '0;
        norm_exp_sp = '0;
        lzc_dp = 0;
        norm_mant_dp = '0;
        norm_exp_dp = '0;
        guard = '0; round_bit = '0; sticky_bit = '0;
        final_mant = '0; final_exp = '0;
        round_up = '0; inexact = '0; overflow = '0; underflow = '0;
        tiny_after_rnd_sp = 1'b0; unb_all1_sp = 1'b0; unb_inexact_sp = 1'b0; unb_inc_sp = 1'b0;
        rshift = '0; temp_s = '0; s_zero = '0;

        s3_next = '0;
        s3_next.valid         = s2_q.valid && !s2_q.is_single;
        s3_next.subop         = s2_q.subop;
        s3_next.eff_rm        = s2_q.eff_rm;
        s3_next.prd_fp        = s2_q.prd_fp;
        s3_next.rob_idx       = s2_q.rob_idx;
        s3_next.rob_epoch     = s2_q.rob_epoch;
        s3_next.special_valid = s2_q.special_valid;
        s3_next.special_res   = s2_q.special_res;
        s3_next.special_flags = s2_q.special_flags;

        sp_done_valid     = 1'b0;
        sp_done_data      = '0;
        sp_done_fflags    = '0;
        sp_done_prd_fp    = s2_q.prd_fp;
        sp_done_rob_idx   = s2_q.rob_idx;
        sp_done_rob_epoch = s2_q.rob_epoch;

        if (s2_q.valid) begin
            if (s2_q.is_single) begin
                // --- Complete SP in Stage 3 (3-cycle latency) ---
                if (s2_q.special_valid) begin
                    sp_done_valid  = 1'b1;
                    sp_done_data   = s2_q.special_res;
                    sp_done_fflags = s2_q.special_flags;
                end else if (s2_q.sum_mant_sp == 80'd0 && !s2_q.sticky_sp) begin
                    s_zero = (s2_q.eff_rm == 3'b010) ? 1'b1 : 1'b0; // -0 in RDN
                    sp_done_valid  = 1'b1;
                    sp_done_data   = {32'hFFFF_FFFF, s_zero, 31'd0};
                    sp_done_fflags = 5'b00000;
                end else begin
                    if (s2_q.sum_mant_sp == 80'd0) begin
                        // Residual shifted-out epsilon only (non-zero, strictly tiny)
                        norm_exp_sp = 12'sd0;
                        final_mant  = 25'd0;
                        guard       = 1'b0;
                        round_bit   = 1'b0;
                        sticky_bit  = 1'b1;
                        tiny_after_rnd_sp = 1'b1;
                    end else begin
                        // Find leading zero count
                        lzc_sp = 0;
                        for (int k = 78; k >= 0; k--) begin
                            if (s2_q.sum_mant_sp[k]) begin
                                lzc_sp = 78 - k;
                                break;
                            end
                        end

                        norm_exp_sp  = s2_q.exp_res_sp + 12'sd1 - signed'(12'(lzc_sp));
                        norm_mant_sp = s2_q.sum_mant_sp << lzc_sp;

                        // Radix point at norm_mant_sp[78]
                        final_mant = {1'b0, norm_mant_sp[78:55]};
                        guard      = norm_mant_sp[54];
                        round_bit  = norm_mant_sp[53];
                        sticky_bit = (norm_mant_sp[52:0] != 53'd0) || s2_q.sticky_sp;

                        // IEEE-754-2008 §7.5 tininess after rounding (unbounded exponent)
                        unb_all1_sp    = &final_mant[23:0];
                        unb_inexact_sp = guard || round_bit || sticky_bit;
                        case (s2_q.eff_rm)
                            3'b000: unb_inc_sp = guard;
                            3'b001: unb_inc_sp = 1'b0;
                            3'b010: unb_inc_sp = s2_q.sign_res_sp && unb_inexact_sp;
                            3'b011: unb_inc_sp = !s2_q.sign_res_sp && unb_inexact_sp;
                            3'b100: unb_inc_sp = guard;
                            default: unb_inc_sp = guard;
                        endcase
                        tiny_after_rnd_sp = (norm_exp_sp < 12'sd0) ||
                                            ((norm_exp_sp == 12'sd0) && !(unb_all1_sp && unb_inc_sp));

                        // Subnormal handling if norm_exp_sp <= 0
                        if (norm_exp_sp <= 12'sd0) begin
                            rshift = 12'sd1 - norm_exp_sp;
                            if (rshift > 12'sd40) begin
                                final_mant = '0;
                                guard      = 1'b0;
                                round_bit  = 1'b0;
                                sticky_bit = 1'b1;
                            end else begin
                                temp_s = {final_mant[23:0], guard, round_bit, 22'd0} >> rshift;
                                final_mant = {1'b0, temp_s[47:24]};
                                guard      = temp_s[23];
                                round_bit  = temp_s[22];
                                sticky_bit = sticky_bit || (temp_s[21:0] != 22'd0);
                            end
                            norm_exp_sp = 12'sd0;
                        end
                    end

                    // IEEE 754 Rounding decision
                    inexact = guard || round_bit || sticky_bit;
                    round_up = 1'b0;
                    case (s2_q.eff_rm)
                        3'b000: round_up = guard && (round_bit || sticky_bit || final_mant[0]); // RNE
                        3'b001: round_up = 1'b0; // RTZ
                        3'b010: round_up = s2_q.sign_res_sp && inexact; // RDN
                        3'b011: round_up = !s2_q.sign_res_sp && inexact; // RUP
                        3'b100: round_up = guard; // RMM
                        default: round_up = guard && (round_bit || sticky_bit || final_mant[0]);
                    endcase

                    if (round_up) begin
                        final_mant = final_mant + 25'd1;
                        if (final_mant[23] && (norm_exp_sp == 12'sd0)) begin
                            // Subnormal rounded up to normal
                            norm_exp_sp = 12'sd1;
                        end else if (final_mant[24]) begin
                            final_mant = final_mant >> 1;
                            norm_exp_sp   = norm_exp_sp + 12'sd1;
                        end
                    end

                    overflow  = 1'b0;
                    underflow = 1'b0;

                    if (norm_exp_sp >= 12'sd255) begin
                        overflow = 1'b1;
                        inexact  = 1'b1;
                        // Select max finite or infinity based on rounding mode
                        if ((s2_q.eff_rm == 3'b001) ||
                            (s2_q.eff_rm == 3'b010 && !s2_q.sign_res_sp) ||
                            (s2_q.eff_rm == 3'b011 && s2_q.sign_res_sp)) begin
                            final_exp  = 8'hFE;
                            final_mant = 25'h07F_FFFF;
                        end else begin
                            final_exp  = 8'hFF;
                            final_mant = 25'd0;
                        end
                    end else begin
                        final_exp = norm_exp_sp[7:0];
                        underflow = tiny_after_rnd_sp && inexact;
                    end

                    sp_done_valid = 1'b1;
                    sp_done_data  = {32'hFFFF_FFFF, s2_q.sign_res_sp, final_exp, final_mant[22:0]};
                    sp_done_fflags = {1'b0, 1'b0, overflow, underflow, inexact};
                end
            end else begin
                // --- DP Normalization in Stage 3 -> Advances to Stage 4 ---
                if (!s2_q.special_valid) begin
                    if (s2_q.sum_mant_dp == 164'd0 && !s2_q.sticky_dp) begin
                        s3_next.zero_dp = 1'b1;
                        s3_next.sign_dp = (s2_q.eff_rm == 3'b010) ? 1'b1 : 1'b0;
                    end else if (s2_q.sum_mant_dp == 164'd0) begin
                        // Residual shifted-out epsilon only
                        s3_next.sign_dp      = s2_q.sign_res_dp;
                        s3_next.exp_dp       = -14'sd200;
                        s3_next.mant_norm_dp = 55'd0;
                        s3_next.sticky_dp    = 1'b1;
                    end else begin
                        lzc_dp = 0;
                        for (int k = 162; k >= 0; k--) begin
                            if (s2_q.sum_mant_dp[k]) begin
                                lzc_dp = 162 - k;
                                break;
                            end
                        end

                        norm_exp_dp  = s2_q.exp_res_dp + 14'sd1 - signed'(14'(lzc_dp));
                        norm_mant_dp = s2_q.sum_mant_dp << lzc_dp;

                        s3_next.sign_dp      = s2_q.sign_res_dp;
                        s3_next.exp_dp       = norm_exp_dp;
                        s3_next.mant_norm_dp = norm_mant_dp[162:108]; // 53 mant + guard + round
                        s3_next.sticky_dp    = (norm_mant_dp[107:0] != 108'd0) || s2_q.sticky_dp;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 4 (EX4): DP Rounding, Flag Generation & Packing (4-cycle latency)
    // -------------------------------------------------------------------------
    logic              dp_done_valid;
    logic [63:0]       dp_done_data;
    logic [4:0]        dp_done_fflags;
    fpreg_t            dp_done_prd_fp;
    rob_idx_t          dp_done_rob_idx;
    rob_epoch_t        dp_done_rob_epoch;

    always_comb begin
        logic [53:0] final_mant;
        logic guard, round_bit, sticky_bit;
        logic signed [13:0] norm_exp;
        logic round_up, inexact, overflow, underflow;
        logic tiny_after_rnd_dp, unb_all1_dp, unb_inexact_dp, unb_inc_dp;
        logic [10:0] final_exp;
        logic signed [13:0] rshift;
        logic [105:0] temp_d;

        final_mant = '0;
        guard = '0; round_bit = '0; sticky_bit = '0;
        norm_exp = '0;
        round_up = '0; inexact = '0; overflow = '0; underflow = '0;
        tiny_after_rnd_dp = 1'b0; unb_all1_dp = 1'b0; unb_inexact_dp = 1'b0; unb_inc_dp = 1'b0;
        final_exp = '0;
        rshift = '0; temp_d = '0;

        dp_done_valid     = 1'b0;
        dp_done_data      = '0;
        dp_done_fflags    = '0;
        dp_done_prd_fp    = s3_q.prd_fp;
        dp_done_rob_idx   = s3_q.rob_idx;
        dp_done_rob_epoch = s3_q.rob_epoch;

        if (s3_q.valid) begin
            if (s3_q.special_valid) begin
                dp_done_valid  = 1'b1;
                dp_done_data   = s3_q.special_res;
                dp_done_fflags = s3_q.special_flags;
            end else if (s3_q.zero_dp) begin
                dp_done_valid  = 1'b1;
                dp_done_data   = {s3_q.sign_dp, 63'd0};
                dp_done_fflags = 5'b00000;
            end else begin
                final_mant = {1'b0, s3_q.mant_norm_dp[54:2]};
                guard      = s3_q.mant_norm_dp[1];
                round_bit  = s3_q.mant_norm_dp[0];
                sticky_bit = s3_q.sticky_dp;
                norm_exp   = s3_q.exp_dp;

                // IEEE-754-2008 §7.5 tininess after rounding (unbounded exponent)
                unb_all1_dp    = &final_mant[52:0];
                unb_inexact_dp = guard || round_bit || sticky_bit;
                case (s3_q.eff_rm)
                    3'b000: unb_inc_dp = guard;
                    3'b001: unb_inc_dp = 1'b0;
                    3'b010: unb_inc_dp = s3_q.sign_dp && unb_inexact_dp;
                    3'b011: unb_inc_dp = !s3_q.sign_dp && unb_inexact_dp;
                    3'b100: unb_inc_dp = guard;
                    default: unb_inc_dp = guard;
                endcase
                tiny_after_rnd_dp = (norm_exp < 14'sd0) ||
                                    ((norm_exp == 14'sd0) && !(unb_all1_dp && unb_inc_dp));

                // Subnormal handling if norm_exp <= 0
                if (norm_exp <= 14'sd0) begin
                    rshift = 14'sd1 - norm_exp;
                    if (rshift > 14'sd70) begin
                        final_mant = '0;
                        guard      = 1'b0;
                        round_bit  = 1'b0;
                        sticky_bit = 1'b1;
                    end else begin
                        temp_d = {final_mant[52:0], guard, round_bit, 51'd0} >> rshift;
                        final_mant = {1'b0, temp_d[105:53]};
                        guard      = temp_d[52];
                        round_bit  = temp_d[51];
                        sticky_bit = sticky_bit || (temp_d[50:0] != 51'd0);
                    end
                    norm_exp = 14'sd0;
                end

                inexact = guard || round_bit || sticky_bit;
                round_up = 1'b0;
                case (s3_q.eff_rm)
                    3'b000: round_up = guard && (round_bit || sticky_bit || final_mant[0]); // RNE
                    3'b001: round_up = 1'b0; // RTZ
                    3'b010: round_up = s3_q.sign_dp && inexact; // RDN
                    3'b011: round_up = !s3_q.sign_dp && inexact; // RUP
                    3'b100: round_up = guard; // RMM
                    default: round_up = guard && (round_bit || sticky_bit || final_mant[0]);
                endcase

                if (round_up) begin
                    final_mant = final_mant + 54'd1;
                    if (final_mant[52] && (norm_exp == 14'sd0)) begin
                        norm_exp = 14'sd1;
                    end else if (final_mant[53]) begin
                        final_mant = final_mant >> 1;
                        norm_exp   = norm_exp + 14'sd1;
                    end
                end

                overflow  = 1'b0;
                underflow = 1'b0;

                if (norm_exp >= 14'sd2047) begin
                    overflow = 1'b1;
                    inexact  = 1'b1;
                    if ((s3_q.eff_rm == 3'b001) ||
                        (s3_q.eff_rm == 3'b010 && !s3_q.sign_dp) ||
                        (s3_q.eff_rm == 3'b011 && s3_q.sign_dp)) begin
                        final_exp  = 11'h7FE;
                        final_mant = 54'h0F_FFFF_FFFF_FFFF;
                    end else begin
                        final_exp  = 11'h7FF;
                        final_mant = 54'd0;
                    end
                end else begin
                    final_exp = norm_exp[10:0];
                    underflow = tiny_after_rnd_dp && inexact;
                end

                dp_done_valid  = 1'b1;
                dp_done_data   = {s3_q.sign_dp, final_exp, final_mant[51:0]};
                dp_done_fflags = {1'b0, 1'b0, overflow, underflow, inexact};
            end
        end
    end

    // -------------------------------------------------------------------------
    // Writeback Output Mux & Holding Buffer
    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // Writeback Output Mux & Holding FIFO (up to 4 entries, lossless)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;
        logic [63:0] data;
        logic [4:0]  fflags;
        fpreg_t      prd_fp;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
    } hold_wb_t;

    localparam int unsigned HOLD_DEPTH = 4;
    hold_wb_t hold_fifo [HOLD_DEPTH];
    logic [2:0] hold_count;
    logic [1:0] hold_head;
    logic [1:0] hold_tail;

    wire req_squash     = recover_valid_i && (rob_dist(req_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire s1_squash      = recover_valid_i && (rob_dist(s1_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire s2_squash      = recover_valid_i && (rob_dist(s2_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    wire dp_done_squash = recover_valid_i && (rob_dist(dp_done_rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire sp_done_squash = recover_valid_i && (rob_dist(sp_done_rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire hold_head_squash = recover_valid_i && (rob_dist(hold_fifo[hold_head].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    always_comb begin
        if (hold_count > 3'd0) begin
            wb_valid_o     = hold_fifo[hold_head].valid && !hold_head_squash;
            wb_data_o      = hold_fifo[hold_head].data;
            wb_fflags_o    = hold_fifo[hold_head].fflags;
            wb_prd_fp_o    = hold_fifo[hold_head].prd_fp;
            wb_rob_idx_o   = hold_fifo[hold_head].rob_idx;
            wb_rob_epoch_o = hold_fifo[hold_head].rob_epoch;
        end else if (dp_done_valid && !dp_done_squash) begin
            wb_valid_o     = 1'b1;
            wb_data_o      = dp_done_data;
            wb_fflags_o    = dp_done_fflags;
            wb_prd_fp_o    = dp_done_prd_fp;
            wb_rob_idx_o   = dp_done_rob_idx;
            wb_rob_epoch_o = dp_done_rob_epoch;
        end else if (sp_done_valid && !sp_done_squash) begin
            wb_valid_o     = 1'b1;
            wb_data_o      = sp_done_data;
            wb_fflags_o    = sp_done_fflags;
            wb_prd_fp_o    = sp_done_prd_fp;
            wb_rob_idx_o   = sp_done_rob_idx;
            wb_rob_epoch_o = sp_done_rob_epoch;
        end else begin
            wb_valid_o     = 1'b0;
            wb_data_o      = '0;
            wb_fflags_o    = '0;
            wb_prd_fp_o    = '0;
            wb_rob_idx_o   = '0;
            wb_rob_epoch_o = '0;
        end
    end

    // -------------------------------------------------------------------------
    // Sequential Pipeline Registers & Recovery
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            s1_q       <= '0;
            s2_q       <= '0;
            s3_q       <= '0;
            hold_count <= '0;
            hold_head  <= '0;
            hold_tail  <= '0;
            for (int k = 0; k < HOLD_DEPTH; k++) begin
                hold_fifo[k] <= '0;
            end
        end else begin
            // Stage 1: Check squash against incoming request (req_rob_idx_i)
            if (req_squash) begin
                s1_q.valid <= 1'b0;
            end else begin
                s1_q <= s1_next;
            end

            // Stage 2: Check squash against Stage 1 register transitioning to Stage 2 (s1_q.rob_idx)
            if (s1_squash) begin
                s2_q.valid <= 1'b0;
            end else begin
                s2_q <= s2_next;
            end

            // Stage 3: Check squash against Stage 2 register transitioning to Stage 3 (s2_q.rob_idx)
            if (s2_squash) begin
                s3_q.valid <= 1'b0;
            end else begin
                s3_q <= s3_next;
            end

            // Invalidate squashed entries inside hold_fifo
            if (recover_valid_i) begin
                for (int k = 0; k < HOLD_DEPTH; k++) begin
                    if (hold_fifo[k].valid && (rob_dist(hold_fifo[k].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        hold_fifo[k].valid <= 1'b0;
                    end
                end
            end

            // FIFO Push and Pop Management
            begin : blk_fifo_mgmt
                logic [1:0] next_head;
                logic [1:0] next_tail;
                logic [2:0] next_count;

                next_head  = hold_head;
                next_tail  = hold_tail;
                next_count = hold_count;

                // Pop if FIFO was driving writeback
                if (hold_count > 3'd0) begin
                    next_head  = hold_head + 2'd1;
                    next_count = next_count - 3'd1;
                end

                // Determine pushes:
                if (hold_count > 3'd0) begin
                    // FIFO was draining. Any completing DP/SP must be queued.
                    if (dp_done_valid && !dp_done_squash) begin
                        hold_fifo[next_tail] <= '{
                            valid:     1'b1,
                            data:      dp_done_data,
                            fflags:    dp_done_fflags,
                            prd_fp:    dp_done_prd_fp,
                            rob_idx:   dp_done_rob_idx,
                            rob_epoch: dp_done_rob_epoch
                        };
                        next_tail  = next_tail + 2'd1;
                        next_count = next_count + 3'd1;
                    end
                    if (sp_done_valid && !sp_done_squash) begin
                        hold_fifo[next_tail] <= '{
                            valid:     1'b1,
                            data:      sp_done_data,
                            fflags:    sp_done_fflags,
                            prd_fp:    sp_done_prd_fp,
                            rob_idx:   sp_done_rob_idx,
                            rob_epoch: sp_done_rob_epoch
                        };
                        next_tail  = next_tail + 2'd1;
                        next_count = next_count + 3'd1;
                    end
                end else begin
                    // FIFO was empty (hold_count == 0).
                    // If both DP and SP completed, DP bypassed to wb_valid_o; SP must be queued!
                    if (dp_done_valid && !dp_done_squash && sp_done_valid && !sp_done_squash) begin
                        hold_fifo[next_tail] <= '{
                            valid:     1'b1,
                            data:      sp_done_data,
                            fflags:    sp_done_fflags,
                            prd_fp:    sp_done_prd_fp,
                            rob_idx:   sp_done_rob_idx,
                            rob_epoch: sp_done_rob_epoch
                        };
                        next_tail  = next_tail + 2'd1;
                        next_count = next_count + 3'd1;
                    end
                end

                hold_head  <= next_head;
                hold_tail  <= next_tail;
                hold_count <= next_count;
            end
        end
    end

endmodule

`endif // FURSOY_S1_FMA_SV
