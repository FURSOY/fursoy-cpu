`ifndef FURSOY_S1_FDIV_SV
`define FURSOY_S1_FDIV_SV

// =============================================================================
// Fursoy Slice-1 Iterative Radix-4 Restoring FDIV / FSQRT Unit — S2.5-M1b
// =============================================================================
// Genuine multi-cycle synthesizable IEEE 754-2008 scalar floating-point
// divider and square-root engine (zero behavioral '/' or '%', zero unrolled
// combinational isqrt loops).
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 6.3, Section 11
//
// Algorithm & Pipeline:
// - Unified parallel 3-subtractor Radix-4 restoring recurrence (2 bits/cycle)
//   for both division (d1=D, d2=2D, d3=3D) and square root (t1=8q+1,
//   t2=16q+4, t3=24q+9 via incrementally tracked q3_p1 = 3q+1) using three
//   shared 60-bit Kogge-Stone subtractors (fursoy_s1_ks_adder).
// - FSM stages (500 MHz Nangate45 timing-balanced):
//     * FDIV_IDLE  : Unpack, NaN-box check, IEEE-754 special-case fast bypass
//     * FDIV_NORM  : Binary-tree CLZ52 & subnormal input normalization
//     * FDIV_SETUP : Exponent & initial remainder/divisor/radicand setup
//     * FDIV_ITER  : 13 cycles (FP32) / 27 cycles (FP64) @ 2 bits/cycle
//     * FDIV_DENORM: Subnormal output right-shift & sticky accumulation
//     * FDIV_ROUND : All 5 IEEE-754 rounding modes, overflow, post-rounding
//                    tininess (RISC-V UF flag), and strict SP NaN-boxing
// - Latencies (issue -> fdiv_buf writeback):
//     * Special cases (NaN/Inf/Zero/neg-sqrt): 1 cycle
//     * FDIV.S / FSQRT.S (finite non-zero)   : 17 cycles
//     * FDIV.D / FSQRT.D (finite non-zero)   : 31 cycles
// - Non-blocking: FMA continues executing out-of-order while FDIV/FSQRT runs;
//   fdiv_buf arbitrates onto w0_fp with priority FMA > FDIV.
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_ks_adder.sv"

module fursoy_s1_fdiv
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Flush and Recovery
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    // Dynamic rounding mode
    input  logic [2:0]        fcsr_frm_i,

    // Issue Request from Port 4
    input  logic              req_valid_i,
    input  uop_subop_t        req_subop_i,
    input  logic [2:0]        req_frm_i,
    input  logic [63:0]       req_rs1_data_i,
    input  logic [63:0]       req_rs2_data_i,
    input  fpreg_t            req_prd_fp_i,
    input  rob_idx_t          req_rob_idx_i,
    input  rob_epoch_t        req_rob_epoch_i,

    // Status to FPIQ
    output logic              busy_o,

    // Writeback Arbitration: FMA writeback takes priority over FDIV writeback
    input  logic              fma_wb_valid_i,

    // Execution Output (to FPRF w0_fp and ROB port 4)
    output logic              wb_valid_o,
    output logic [63:0]       wb_data_o,
    output fpreg_t            wb_prd_fp_o,
    output rob_idx_t          wb_rob_idx_o,
    output rob_epoch_t        wb_rob_epoch_o,
    output logic [4:0]        wb_fflags_o
);

    localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;
    localparam logic [63:0] FP64_QNAN = 64'h7FF8_0000_0000_0000;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic is_nanbox_valid(input logic [63:0] val);
        return (val[63:32] == 32'hFFFF_FFFF);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Balanced nibble-parallel binary-tree CLZ52 (returns 0..52)
    function automatic logic [5:0] clz52(input logic [51:0] val);
        logic [63:0] v;
        logic [5:0]  cnt;
        logic [31:0] v32;
        logic [15:0] v16;
        logic [7:0]  v8;
        logic [3:0]  v4;
        begin
            v   = {val, 12'hFFF}; // Guarantee MSB hit within [63:12] if non-zero
            cnt = 6'd0;
            if (val == 52'd0) begin
                return 6'd52;
            end
            if (v[63:32] == 32'd0)   begin cnt[5] = 1'b1; v32 = v[31:0];   end else begin cnt[5] = 1'b0; v32 = v[63:32]; end
            if (v32[31:16] == 16'd0) begin cnt[4] = 1'b1; v16 = v32[15:0]; end else begin cnt[4] = 1'b0; v16 = v32[31:16]; end
            if (v16[15:8] == 8'd0)   begin cnt[3] = 1'b1; v8  = v16[7:0];  end else begin cnt[3] = 1'b0; v8  = v16[15:8];  end
            if (v8[7:4] == 4'd0)     begin cnt[2] = 1'b1; v4  = v8[3:0];   end else begin cnt[2] = 1'b0; v4  = v8[7:4];    end
            if (v4[3:2] == 2'd0)     begin cnt[1] = 1'b1; cnt[0] = ~v4[1] & v4[0]; end else begin cnt[1] = 1'b0; cnt[0] = ~v4[3]; end
            return cnt;
        end
    endfunction

    // -------------------------------------------------------------------------
    // FSM State & Pipeline Registers
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        FDIV_IDLE   = 3'd0,
        FDIV_NORM   = 3'd1,
        FDIV_SETUP  = 3'd2,
        FDIV_ITER   = 3'd3,
        FDIV_DENORM = 3'd4,
        FDIV_ROUND  = 3'd5
    } fdiv_state_t;

    fdiv_state_t state_q;

    // Operation metadata
    logic        is_single_q;
    logic        is_sqrt_q;
    logic        s_res_q;
    logic [2:0]  rm_q;
    fpreg_t      prd_fp_q;
    rob_idx_t    rob_idx_q;
    rob_epoch_t  rob_epoch_q;

    // Raw unpacked fields (latched at IDLE -> NORM)
    logic        a_is_sub_q, b_is_sub_q;
    logic [10:0] raw_ea_q, raw_eb_q;
    logic [51:0] raw_fa_q, raw_fb_q;

    // Normalized operands (latched at NORM -> SETUP)
    logic [52:0]        ma_q, mb_q;
    logic signed [12:0] exp_a_q, exp_b_q;

    // Iterative Radix-4 restoring engine state (SETUP -> ITER -> DENORM)
    logic [57:0]        rem_q;
    logic [59:0]        d1_q, d2_q, d3_q;
    logic [55:0]        rad_q;
    logic [55:0]        q_q;
    logic [54:0]        q3_q;
    logic [56:0]        q3_p1_q;
    logic [4:0]         iter_q;
    logic signed [12:0] exp_res_q;
    logic               rem_nz_q;

    // Post-denorm rounding stage registers (DENORM -> ROUND)
    logic [51:0]        rnd_mant_q;
    logic signed [12:0] rnd_bexp_q;
    logic               rnd_g_q, rnd_r_q, rnd_s_q;
    logic               rnd_tiny_q;

    // Completion Holding Buffer (`fdiv_buf`)
    typedef struct packed {
        logic        valid;
        logic [63:0] data;
        logic [4:0]  fflags;
        fpreg_t      prd_fp;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
    } fdiv_buf_t;

    fdiv_buf_t fdiv_buf_q;

    assign busy_o = (state_q != FDIV_IDLE) || fdiv_buf_q.valid;

    // Squash detection
    wire req_squash    = recover_valid_i && (rob_dist(req_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire active_squash = recover_valid_i && (state_q != FDIV_IDLE) &&
                         (rob_dist(rob_idx_q, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire buf_squash    = recover_valid_i && (rob_dist(fdiv_buf_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    // Writeback Output Arbitration (FMA > FDIV)
    always_comb begin
        wb_valid_o     = 1'b0;
        wb_data_o      = 64'd0;
        wb_fflags_o    = 5'd0;
        wb_prd_fp_o    = fpreg_t'(0);
        wb_rob_idx_o   = rob_idx_t'(0);
        wb_rob_epoch_o = rob_epoch_t'(0);

        if (fdiv_buf_q.valid && !buf_squash && !fma_wb_valid_i) begin
            wb_valid_o     = 1'b1;
            wb_data_o      = fdiv_buf_q.data;
            wb_fflags_o    = fdiv_buf_q.fflags;
            wb_prd_fp_o    = fdiv_buf_q.prd_fp;
            wb_rob_idx_o   = fdiv_buf_q.rob_idx;
            wb_rob_epoch_o = fdiv_buf_q.rob_epoch;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 0 (FDIV_IDLE): Unpack & IEEE-754 Special-Case Classifier
    // -------------------------------------------------------------------------
    wire        in_single = (req_subop_i == FP_FDIV_S) || (req_subop_i == FP_FSQRT_S);
    wire        in_sqrt   = (req_subop_i == FP_FSQRT_S) || (req_subop_i == FP_FSQRT_D);
    wire [2:0]  in_eff_rm = (req_frm_i == 3'b111) ? fcsr_frm_i : req_frm_i;

    wire [31:0] sp_op1 = is_nanbox_valid(req_rs1_data_i) ? req_rs1_data_i[31:0] : FP32_QNAN;
    wire [31:0] sp_op2 = is_nanbox_valid(req_rs2_data_i) ? req_rs2_data_i[31:0] : FP32_QNAN;

    wire        in_sa  = in_single ? sp_op1[31]           : req_rs1_data_i[63];
    wire        in_sb  = in_single ? sp_op2[31]           : req_rs2_data_i[63];
    wire [10:0] in_ea  = in_single ? {3'd0, sp_op1[30:23]} : req_rs1_data_i[62:52];
    wire [10:0] in_eb  = in_single ? {3'd0, sp_op2[30:23]} : req_rs2_data_i[62:52];
    wire [51:0] in_fa  = in_single ? {sp_op1[22:0], 29'd0} : req_rs1_data_i[51:0];
    wire [51:0] in_fb  = in_single ? {sp_op2[22:0], 29'd0} : req_rs2_data_i[51:0];

    wire        ea_max = in_single ? (sp_op1[30:23] == 8'hFF) : (req_rs1_data_i[62:52] == 11'h7FF);
    wire        eb_max = in_single ? (sp_op2[30:23] == 8'hFF) : (req_rs2_data_i[62:52] == 11'h7FF);
    wire        fa_nz  = (in_fa != 52'd0);
    wire        fb_nz  = (in_fb != 52'd0);

    wire        in_nan_a  = ea_max && fa_nz;
    wire        in_snan_a = in_nan_a && !in_fa[51];
    wire        in_inf_a  = ea_max && !fa_nz;
    wire        in_zero_a = (in_ea == 11'd0) && !fa_nz;

    wire        in_nan_b  = eb_max && fb_nz;
    wire        in_snan_b = in_nan_b && !in_fb[51];
    wire        in_inf_b  = eb_max && !fb_nz;
    wire        in_zero_b = (in_eb == 11'd0) && !fb_nz;

    wire        in_s_res  = in_sqrt ? 1'b0 : (in_sa ^ in_sb);

    logic        in_is_special;
    logic [63:0] in_special_res;
    logic [4:0]  in_special_flags;

    always_comb begin : blk_special
        logic [63:0] qnan_val, inf_val, zero_val;
        qnan_val = in_single ? {32'hFFFF_FFFF, FP32_QNAN}                    : FP64_QNAN;
        inf_val  = in_single ? {32'hFFFF_FFFF, in_s_res, 8'hFF, 23'd0}       : {in_s_res, 11'h7FF, 52'd0};
        zero_val = in_single ? {32'hFFFF_FFFF, in_s_res, 31'd0}              : {in_s_res, 63'd0};

        in_is_special    = 1'b0;
        in_special_res   = 64'd0;
        in_special_flags = 5'd0;

        if (in_sqrt) begin
            if (in_nan_a) begin
                in_is_special    = 1'b1;
                in_special_res   = qnan_val;
                in_special_flags = in_snan_a ? 5'b10000 : 5'b00000;
            end else if (in_zero_a) begin
                in_is_special    = 1'b1;
                in_special_res   = in_single ? {32'hFFFF_FFFF, in_sa, 31'd0} : {in_sa, 63'd0};
                in_special_flags = 5'b00000;
            end else if (in_sa) begin
                // sqrt(negative finite) or sqrt(-Inf) -> canonical qNaN + NV
                in_is_special    = 1'b1;
                in_special_res   = qnan_val;
                in_special_flags = 5'b10000;
            end else if (in_inf_a) begin
                in_is_special    = 1'b1;
                in_special_res   = in_single ? {32'hFFFF_FFFF, 1'b0, 8'hFF, 23'd0} : {1'b0, 11'h7FF, 52'd0};
                in_special_flags = 5'b00000;
            end
        end else begin
            if (in_nan_a || in_nan_b) begin
                in_is_special    = 1'b1;
                in_special_res   = qnan_val;
                in_special_flags = (in_snan_a || in_snan_b) ? 5'b10000 : 5'b00000;
            end else if ((in_zero_a && in_zero_b) || (in_inf_a && in_inf_b)) begin
                in_is_special    = 1'b1;
                in_special_res   = qnan_val;
                in_special_flags = 5'b10000; // NV
            end else if (in_inf_a) begin
                // +/-Inf / finite or +/-Inf / 0 -> +/-Inf, NO flags (IEEE 754-2008 §7.3)
                in_is_special    = 1'b1;
                in_special_res   = inf_val;
                in_special_flags = 5'b00000;
            end else if (in_zero_b) begin
                // Finite non-zero / 0 -> +/-Inf, DZ
                in_is_special    = 1'b1;
                in_special_res   = inf_val;
                in_special_flags = 5'b01000; // DZ
            end else if (in_zero_a || in_inf_b) begin
                in_is_special    = 1'b1;
                in_special_res   = zero_val;
                in_special_flags = 5'b00000;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 1 (FDIV_NORM): Subnormal Normalization (CLZ52 + Barrel Shift)
    // -------------------------------------------------------------------------
    wire [5:0] lz_a_w = clz52(raw_fa_q);
    wire [5:0] lz_b_w = clz52(raw_fb_q);

    wire signed [12:0] norm_bias = is_single_q ? 13'sd127 : 13'sd1023;
    wire signed [12:0] norm_emin = is_single_q ? -13'sd126 : -13'sd1022;

    wire [52:0]        norm_ma   = a_is_sub_q ? ({raw_fa_q, 1'b0} << lz_a_w) : {1'b1, raw_fa_q};
    wire [52:0]        norm_mb   = b_is_sub_q ? ({raw_fb_q, 1'b0} << lz_b_w) : {1'b1, raw_fb_q};
    wire signed [12:0] norm_ea   = a_is_sub_q ? (norm_emin - $signed({7'd0, lz_a_w}) - 13'sd1)
                                              : ($signed({2'b00, raw_ea_q}) - norm_bias);
    wire signed [12:0] norm_eb   = b_is_sub_q ? (norm_emin - $signed({7'd0, lz_b_w}) - 13'sd1)
                                              : ($signed({2'b00, raw_eb_q}) - norm_bias);

    // -------------------------------------------------------------------------
    // Stage 2 (FDIV_SETUP) & Stage 3 (FDIV_ITER): Shared 64-bit KS Subtractors
    // -------------------------------------------------------------------------
    // Shared 3 parallel 64-bit Kogge-Stone subtractors (WIDTH=64 hits the
    // keep-cut parallel-prefix tree in fursoy_s1_ks_adder to close 500 MHz STA):
    // - In FDIV_SETUP: sub1 computes ma - mb (to test ma >= mb and init rem);
    //                  sub2 computes 2*ma - mb (init rem when ma < mb).
    // - In FDIV_ITER : sub1/sub2/sub3 compute rem_sh - t1, rem_sh - t2, rem_sh - t3.
    wire [59:0] iter_rem_sh = is_sqrt_q ? {rem_q[55:0], rad_q[55:52]} : {rem_q[57:0], 2'b00};
    wire [59:0] iter_t1     = is_sqrt_q ? {1'b0, q_q[55:0], 3'b001}   : d1_q;
    wire [59:0] iter_t2     = is_sqrt_q ? {q_q[55:0], 4'b0100}        : d2_q;
    wire [59:0] iter_t3     = is_sqrt_q ? {q3_p1_q[56:0], 3'b001}     : d3_q;

    wire        in_setup    = (state_q == FDIV_SETUP);
    wire [63:0] ks1_a       = in_setup ? {11'd0, ma_q}       : {4'd0, iter_rem_sh};
    wire [63:0] ks1_b       = in_setup ? {11'd0, mb_q}       : {4'd0, iter_t1};
    wire [63:0] ks2_a       = in_setup ? {10'd0, ma_q, 1'b0} : {4'd0, iter_rem_sh};
    wire [63:0] ks2_b       = in_setup ? {11'd0, mb_q}       : {4'd0, iter_t2};
    wire [63:0] ks3_a       = {4'd0, iter_rem_sh};
    wire [63:0] ks3_b       = {4'd0, iter_t3};

    logic [63:0] sub1_w, sub2_w, sub3_w;
    fursoy_s1_ks_adder #(.WIDTH(64)) u_ks_sub1 (
        .a_i   (ks1_a),
        .b_i   (~ks1_b),
        .cin_i (1'b1),
        .sum_o (sub1_w)
    );
    fursoy_s1_ks_adder #(.WIDTH(64)) u_ks_sub2 (
        .a_i   (ks2_a),
        .b_i   (~ks2_b),
        .cin_i (1'b1),
        .sum_o (sub2_w)
    );
    fursoy_s1_ks_adder #(.WIDTH(64)) u_ks_sub3 (
        .a_i   (ks3_a),
        .b_i   (~ks3_b),
        .cin_i (1'b1),
        .sum_o (sub3_w)
    );

    // Precompute d3 = d2 + d1 (in FDIV_SETUP) and q3_p2 = q3_p1_q + 1 (in FDIV_ITER)
    // using one shared 64-bit Kogge-Stone adder.
    wire [63:0] aux_add_a = in_setup ? {10'd0, mb_q, 1'b0} : {7'd0, q3_p1_q};
    wire [63:0] aux_add_b = in_setup ? {11'd0, mb_q}       : 64'd1;
    logic [63:0] aux_add_w;
    fursoy_s1_ks_adder #(.WIDTH(64)) u_ks_aux (
        .a_i   (aux_add_a),
        .b_i   (aux_add_b),
        .cin_i (1'b0),
        .sum_o (aux_add_w)
    );

    // Parallel Radix-4 digit selection & next remainder/root state
    logic [1:0]  q_dig_w;
    logic [57:0] rem_next_w;
    always_comb begin
        if (!sub3_w[63]) begin
            q_dig_w    = 2'b11;
            rem_next_w = sub3_w[57:0];
        end else if (!sub2_w[63]) begin
            q_dig_w    = 2'b10;
            rem_next_w = sub2_w[57:0];
        end else if (!sub1_w[63]) begin
            q_dig_w    = 2'b01;
            rem_next_w = sub1_w[57:0];
        end else begin
            q_dig_w    = 2'b00;
            rem_next_w = iter_rem_sh[57:0];
        end
    end

    wire _unused_fdiv_hi = &{1'b0, sub1_w[62:58], sub2_w[62:58], sub3_w[62:58], aux_add_w[63:55]};

    wire [54:0] q3_p2_w = aux_add_w[54:0];
    logic [54:0] q3_next_w;
    logic [56:0] q3_p1_next_w;
    always_comb begin
        case (q_dig_w)
            2'b00: begin q3_next_w = {q3_q[52:0],     2'b00}; q3_p1_next_w = {q3_q[54:0],     2'b01}; end
            2'b01: begin q3_next_w = {q3_q[52:0],     2'b11}; q3_p1_next_w = {q3_p1_q[54:0],  2'b00}; end
            2'b10: begin q3_next_w = {q3_p1_q[52:0],  2'b10}; q3_p1_next_w = {q3_p1_q[54:0],  2'b11}; end
            2'b11: begin q3_next_w = {q3_p2_w[52:0],  2'b01}; q3_p1_next_w = {q3_p2_w[54:0],  2'b10}; end
        endcase
    end

    // -------------------------------------------------------------------------
    // Stage 4 (FDIV_DENORM): Subnormal Output Right-Shift & Sticky Extraction
    // -------------------------------------------------------------------------
    logic [51:0]        denorm_mant_w;
    logic signed [12:0] denorm_bexp_w;
    logic               denorm_g_w, denorm_r_w, denorm_s_w;
    logic               denorm_tiny_w;

    always_comb begin : blk_denorm
        logic signed [12:0] bexp;
        logic [54:0]        full_q;
        logic               base_s;
        logic signed [12:0] shift_s;
        logic [5:0]         sh_amt;
        logic [53:0]        shifted_q;
        logic [54:0]        lost_mask;
        logic               lost_nz;
        logic               unb_all1, unb_g, unb_r, unb_s, unb_inexact, unb_inc;

        bexp      = exp_res_q + (is_single_q ? 13'sd127 : 13'sd1023);
        full_q    = is_single_q ? {29'd0, q_q[26:1]} : q_q[54:0];
        base_s    = is_single_q ? (rem_nz_q || q_q[0]) : rem_nz_q;
        shift_s   = 13'sd1 - bexp;
        sh_amt    = shift_s[5:0];
        shifted_q = 54'(full_q >> sh_amt);
        lost_mask = (55'd1 << sh_amt) - 55'd1;
        lost_nz   = |(full_q & lost_mask);

        // IEEE-754-2008 §7.5 tininess after rounding (as though exponent range
        // were unbounded): only when bexp == 0 (exp == emin - 1) and the
        // unbounded significand is all-1s AND rounds up does the unbounded
        // rounded magnitude reach 2^emin (not tiny).
        unb_all1    = is_single_q ? (&full_q[25:2]) : (&full_q[54:2]);
        unb_g       = full_q[1];
        unb_r       = full_q[0];
        unb_s       = base_s;
        unb_inexact = unb_g || unb_r || unb_s;
        case (rm_q)
            3'b000: unb_inc = unb_g;                     // RNE (lsb==1 when unb_all1)
            3'b001: unb_inc = 1'b0;                      // RTZ
            3'b010: unb_inc = s_res_q && unb_inexact;    // RDN
            3'b011: unb_inc = (!s_res_q) && unb_inexact; // RUP
            3'b100: unb_inc = unb_g;                     // RMM
            default: unb_inc = unb_g;
        endcase

        if (bexp <= 13'sd0) begin
            denorm_bexp_w = 13'sd0;
            denorm_tiny_w = (bexp < 13'sd0) ? 1'b1 : !(unb_all1 && unb_inc);
            if ((is_single_q && (shift_s >= 13'sd26)) || (!is_single_q && (shift_s >= 13'sd55))) begin
                denorm_mant_w = 52'd0;
                denorm_g_w    = 1'b0;
                denorm_r_w    = 1'b0;
                denorm_s_w    = base_s || (full_q != 55'd0);
            end else begin
                denorm_mant_w = is_single_q ? {29'd0, shifted_q[24:2]} : shifted_q[53:2];
                denorm_g_w    = shifted_q[1];
                denorm_r_w    = shifted_q[0];
                denorm_s_w    = base_s || lost_nz;
            end
        end else begin
            denorm_mant_w = is_single_q ? {29'd0, full_q[24:2]} : full_q[53:2];
            denorm_g_w    = full_q[1];
            denorm_r_w    = full_q[0];
            denorm_s_w    = base_s;
            denorm_bexp_w = bexp;
            denorm_tiny_w = 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 5 (FDIV_ROUND): IEEE-754 Rounding, Overflow, Post-Rounding UF & Pack
    // -------------------------------------------------------------------------
    logic [52:0] mant_inc_w;
    fursoy_s1_ks_adder #(.WIDTH(53)) u_ks_rnd_inc (
        .a_i   ({1'b0, rnd_mant_q}),
        .b_i   (53'd1),
        .cin_i (1'b0),
        .sum_o (mant_inc_w)
    );

    logic [63:0] final_data_w;
    logic [4:0]  final_flags_w;

    always_comb begin : blk_round
        logic               inexact;
        logic               round_up;
        logic               mant_carry;
        logic [51:0]        mant_fin;
        logic signed [12:0] bexp_fin;
        logic               of_flag, uf_flag, nx_flag;
        logic               max_fin_mode;

        inexact = rnd_g_q || rnd_r_q || rnd_s_q;
        case (rm_q)
            3'b000: round_up = rnd_g_q && (rnd_r_q || rnd_s_q || rnd_mant_q[0]); // RNE
            3'b001: round_up = 1'b0;                                             // RTZ
            3'b010: round_up = s_res_q && inexact;                               // RDN
            3'b011: round_up = (!s_res_q) && inexact;                            // RUP
            3'b100: round_up = rnd_g_q;                                          // RMM
            default: round_up = rnd_g_q && (rnd_r_q || rnd_s_q || rnd_mant_q[0]);
        endcase

        mant_carry = round_up && (is_single_q ? mant_inc_w[23] : mant_inc_w[52]);
        mant_fin   = round_up ? (is_single_q ? {29'd0, mant_inc_w[22:0]} : mant_inc_w[51:0])
                              : rnd_mant_q;
        bexp_fin   = mant_carry ? (rnd_bexp_q + 13'sd1) : rnd_bexp_q;

        of_flag = 1'b0;
        uf_flag = 1'b0;
        nx_flag = inexact;

        max_fin_mode = (rm_q == 3'b001) || ((rm_q == 3'b010) && !s_res_q) || ((rm_q == 3'b011) && s_res_q);

        if (is_single_q) begin
            if (bexp_fin >= 13'sd255) begin
                of_flag = 1'b1;
                nx_flag = 1'b1;
                if (max_fin_mode) begin
                    final_data_w = {32'hFFFF_FFFF, s_res_q, 8'hFE, 23'h7F_FFFF};
                end else begin
                    final_data_w = {32'hFFFF_FFFF, s_res_q, 8'hFF, 23'd0};
                end
            end else begin
                // RISC-V IEEE 754-2008 §7.5: tininess detected AFTER rounding (unbounded exponent)
                uf_flag      = rnd_tiny_q && inexact;
                final_data_w = {32'hFFFF_FFFF, s_res_q, bexp_fin[7:0], mant_fin[22:0]};
            end
        end else begin
            if (bexp_fin >= 13'sd2047) begin
                of_flag = 1'b1;
                nx_flag = 1'b1;
                if (max_fin_mode) begin
                    final_data_w = {s_res_q, 11'h7FE, 52'hF_FFFF_FFFF_FFFF};
                end else begin
                    final_data_w = {s_res_q, 11'h7FF, 52'd0};
                end
            end else begin
                // RISC-V IEEE 754-2008 §7.5: tininess detected AFTER rounding (unbounded exponent)
                uf_flag      = rnd_tiny_q && inexact;
                final_data_w = {s_res_q, bexp_fin[10:0], mant_fin[51:0]};
            end
        end

        final_flags_w = {1'b0, 1'b0, of_flag, uf_flag, nx_flag};
    end

    // -------------------------------------------------------------------------
    // Sequential FSM Control
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            state_q      <= FDIV_IDLE;
            is_single_q  <= 1'b0;
            is_sqrt_q    <= 1'b0;
            s_res_q      <= 1'b0;
            rm_q         <= 3'd0;
            prd_fp_q     <= fpreg_t'(0);
            rob_idx_q    <= rob_idx_t'(0);
            rob_epoch_q  <= rob_epoch_t'(0);
            a_is_sub_q   <= 1'b0;
            b_is_sub_q   <= 1'b0;
            raw_ea_q     <= 11'd0;
            raw_eb_q     <= 11'd0;
            raw_fa_q     <= 52'd0;
            raw_fb_q     <= 52'd0;
            ma_q         <= 53'd0;
            mb_q         <= 53'd0;
            exp_a_q      <= 13'sd0;
            exp_b_q      <= 13'sd0;
            rem_q        <= 58'd0;
            d1_q         <= 60'd0;
            d2_q         <= 60'd0;
            d3_q         <= 60'd0;
            rad_q        <= 56'd0;
            q_q          <= 56'd0;
            q3_q         <= 55'd0;
            q3_p1_q      <= 57'd0;
            iter_q       <= 5'd0;
            exp_res_q    <= 13'sd0;
            rem_nz_q     <= 1'b0;
            rnd_mant_q   <= 52'd0;
            rnd_bexp_q   <= 13'sd0;
            rnd_g_q      <= 1'b0;
            rnd_r_q      <= 1'b0;
            rnd_s_q      <= 1'b0;
            rnd_tiny_q   <= 1'b0;
            fdiv_buf_q   <= '0;
        end else begin
            // 1. Drain completion buffer when granted writeback or squashed
            if (fdiv_buf_q.valid) begin
                if (buf_squash) begin
                    fdiv_buf_q.valid <= 1'b0;
                end else if (!fma_wb_valid_i) begin
                    fdiv_buf_q.valid <= 1'b0;
                end
            end

            // 2. Active pipeline abort on branch recovery squash
            if (active_squash) begin
                state_q <= FDIV_IDLE;
            end else begin
                case (state_q)
                    FDIV_IDLE: begin
                        if (req_valid_i && !busy_o && !req_squash) begin
                            is_single_q <= in_single;
                            is_sqrt_q   <= in_sqrt;
                            s_res_q     <= in_s_res;
                            rm_q        <= in_eff_rm;
                            prd_fp_q    <= req_prd_fp_i;
                            rob_idx_q   <= req_rob_idx_i;
                            rob_epoch_q <= req_rob_epoch_i;

                            if (in_is_special) begin
                                fdiv_buf_q.valid     <= 1'b1;
                                fdiv_buf_q.data      <= in_special_res;
                                fdiv_buf_q.fflags    <= in_special_flags;
                                fdiv_buf_q.prd_fp    <= req_prd_fp_i;
                                fdiv_buf_q.rob_idx   <= req_rob_idx_i;
                                fdiv_buf_q.rob_epoch <= req_rob_epoch_i;
                                state_q              <= FDIV_IDLE;
                            end else begin
                                a_is_sub_q <= (in_ea == 11'd0);
                                b_is_sub_q <= (in_eb == 11'd0);
                                raw_ea_q   <= in_ea;
                                raw_eb_q   <= in_eb;
                                raw_fa_q   <= in_fa;
                                raw_fb_q   <= in_fb;
                                state_q    <= FDIV_NORM;
                            end
                        end
                    end

                    FDIV_NORM: begin
                        ma_q    <= norm_ma;
                        mb_q    <= norm_mb;
                        exp_a_q <= norm_ea;
                        exp_b_q <= norm_eb;
                        state_q <= FDIV_SETUP;
                    end

                    FDIV_SETUP: begin
                        q_q    <= 56'd1;
                        iter_q <= is_single_q ? 5'd13 : 5'd27;
                        if (is_sqrt_q) begin
                            exp_res_q <= exp_a_q >>> 1;
                            rem_q     <= exp_a_q[0] ? {56'd0, ma_q[51], !ma_q[51]} : 58'd0;
                            rad_q     <= exp_a_q[0] ? {ma_q[50:0], 5'd0}           : {ma_q[51:0], 4'd0};
                            q3_q      <= 55'd3;
                            q3_p1_q   <= 57'd4;
                        end else begin
                            // sub1_w = ma_q - mb_q; sub1_w[63]==0 iff ma_q >= mb_q
                            exp_res_q <= (!sub1_w[63]) ? (exp_a_q - exp_b_q) : (exp_a_q - exp_b_q - 13'sd1);
                            rem_q     <= (!sub1_w[63]) ? sub1_w[57:0] : sub2_w[57:0];
                            d1_q      <= {7'd0, mb_q};
                            d2_q      <= {6'd0, mb_q, 1'b0};
                            d3_q      <= aux_add_w[59:0];
                        end
                        state_q <= FDIV_ITER;
                    end

                    FDIV_ITER: begin
                        rem_q <= rem_next_w;
                        q_q   <= {q_q[53:0], q_dig_w};
                        if (is_sqrt_q) begin
                            rad_q   <= {rad_q[51:0], 4'd0};
                            q3_q    <= q3_next_w;
                            q3_p1_q <= q3_p1_next_w;
                        end
                        if (iter_q == 5'd1) begin
                            rem_nz_q <= (rem_next_w != 58'd0);
                            state_q  <= FDIV_DENORM;
                        end else begin
                            iter_q <= iter_q - 5'd1;
                        end
                    end

                    FDIV_DENORM: begin
                        rnd_mant_q <= denorm_mant_w;
                        rnd_bexp_q <= denorm_bexp_w;
                        rnd_g_q    <= denorm_g_w;
                        rnd_r_q    <= denorm_r_w;
                        rnd_s_q    <= denorm_s_w;
                        rnd_tiny_q <= denorm_tiny_w;
                        state_q    <= FDIV_ROUND;
                    end

                    FDIV_ROUND: begin
                        fdiv_buf_q.valid     <= 1'b1;
                        fdiv_buf_q.data      <= final_data_w;
                        fdiv_buf_q.fflags    <= final_flags_w;
                        fdiv_buf_q.prd_fp    <= prd_fp_q;
                        fdiv_buf_q.rob_idx   <= rob_idx_q;
                        fdiv_buf_q.rob_epoch <= rob_epoch_q;
                        state_q              <= FDIV_IDLE;
                    end

                    default: state_q <= FDIV_IDLE;
                endcase
            end
        end
    end

endmodule

`endif // FURSOY_S1_FDIV_SV
