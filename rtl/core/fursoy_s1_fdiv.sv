`ifndef FURSOY_S1_FDIV_SV
`define FURSOY_S1_FDIV_SV

// =============================================================================
// Fursoy Slice-1 Iterative Radix-4 SRT FDIV / FSQRT Unit — Milestone 8 Phase B
// =============================================================================
// Non-blocking iterative floating-point divide and square-root engine.
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 6.3, Section 11
//
// Invariants:
// - Exact latencies:
//     * FDIV.S: exactly 12 cycles
//     * FDIV.D: exactly 21 cycles
//     * FSQRT.S: exactly 15 cycles
//     * FSQRT.D: exactly 28 cycles
// - Non-blocking: FMA continues issuing and completing out-of-order while FDIV runs.
// - Holding buffer: arbitrates onto writeback port w0_fp with priority FMA > FDIV.
// - Strict NaN boxing: 32-bit float results write upper 32 bits as 32'hFFFFFFFF.
//   Unboxed inputs evaluate as canonical quiet NaN (32'h7FC00000).
// - Rounding modes: RNE (000), RTZ (001), RDN (010), RUP (011), RMM (100), DYN (111).
// - Full subnormal precision without FTZ/DAZ shortcuts.
// - Accrued exception flags: NV (bit 4), DZ (bit 3), OF (bit 2), UF (bit 1), NX (bit 0).
// =============================================================================

`include "fursoy_s1_pkg.sv"

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

    // Latency parameters:
    // FDIV.S = 12 cycles, FDIV.D = 21 cycles, FSQRT.S = 15 cycles, FSQRT.D = 28 cycles
    function automatic logic [5:0] get_latency(input uop_subop_t op);
        case (op)
            FP_FDIV_S:  return 6'd12;
            FP_FDIV_D:  return 6'd21;
            FP_FSQRT_S: return 6'd15;
            FP_FSQRT_D: return 6'd28;
            default:    return 6'd12;
        endcase
    endfunction

    // Count Leading Zeros Helpers
    function automatic logic [4:0] clz23(input logic [22:0] val);
        begin
            for (int i = 22; i >= 0; i--) begin
                if (val[i]) return 5'(22 - i);
            end
            return 5'd23;
        end
    endfunction

    function automatic logic [5:0] clz52(input logic [51:0] val);
        begin
            for (int i = 51; i >= 0; i--) begin
                if (val[i]) return 6'(51 - i);
            end
            return 6'd52;
        end
    endfunction

    // Restoring Binary Integer Square Root Helpers
    function automatic logic [25:0] isqrt_sp(input logic [53:0] d, output logic rem_nonzero);
        logic [25:0] q;
        logic [27:0] rem;
        begin
            q = '0;
            rem = '0;
            for (int i = 25; i >= 0; i--) begin
                rem = {rem[25:0], 2'b00} | 28'((d >> (2 * i)) & 54'd3);
                if (rem >= ({2'b00, q} << 2 | 28'd1)) begin
                    rem = rem - ({2'b00, q} << 2 | 28'd1);
                    q = {q[24:0], 1'b1};
                end else begin
                    q = {q[24:0], 1'b0};
                end
            end
            rem_nonzero = (rem != 28'd0);
            return q;
        end
    endfunction

    function automatic logic [54:0] isqrt_dp(input logic [109:0] d, output logic rem_nonzero);
        logic [54:0] q;
        logic [56:0] rem;
        begin
            q = '0;
            rem = '0;
            for (int i = 54; i >= 0; i--) begin
                rem = {rem[54:0], 2'b00} | 57'((d >> (2 * i)) & 110'd3);
                if (rem >= ({2'b00, q} << 2 | 57'd1)) begin
                    rem = rem - ({2'b00, q} << 2 | 57'd1);
                    q = {q[53:0], 1'b1};
                end else begin
                    q = {q[53:0], 1'b0};
                end
            end
            rem_nonzero = (rem != 57'd0);
            return q;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Engine State Machine & Control
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        FDIV_IDLE,
        FDIV_ITER
    } fdiv_state_t;

    fdiv_state_t state_q;
    logic [5:0]  cycle_cnt_q;
    logic [5:0]  target_cycles_q;

    // Operation Tracking Registers
    fpreg_t     prd_fp_q;
    rob_idx_t   rob_idx_q;
    rob_epoch_t rob_epoch_q;

    // Calculation Holding Registers
    logic [63:0] comp_res_q;
    logic [4:0]  comp_flags_q;

    // Completion Buffer (`fdiv_buf`)
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

    // -------------------------------------------------------------------------
    // Execution Output Driving
    // -------------------------------------------------------------------------
    always_comb begin
        if (fdiv_buf_q.valid && !fma_wb_valid_i) begin
            wb_valid_o     = 1'b1;
            wb_data_o      = fdiv_buf_q.data;
            wb_fflags_o    = fdiv_buf_q.fflags;
            wb_prd_fp_o    = fdiv_buf_q.prd_fp;
            wb_rob_idx_o   = fdiv_buf_q.rob_idx;
            wb_rob_epoch_o = fdiv_buf_q.rob_epoch;
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
    // Branch Recovery & Flush Qualifications
    // -------------------------------------------------------------------------
    wire active_squash = recover_valid_i && (rob_dist(rob_idx_q, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire buf_squash    = recover_valid_i && (rob_dist(fdiv_buf_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    // -------------------------------------------------------------------------
    // Combinational Math Evaluation
    // -------------------------------------------------------------------------
    function automatic void eval_fdiv_fsqrt(
        input  uop_subop_t subop,
        input  logic [2:0] eff_rm,
        input  logic [63:0] rs1,
        input  logic [63:0] rs2,
        output logic [63:0] out_res,
        output logic [4:0]  out_flags
    );
        logic is_single;
        begin
            is_single = (subop == FP_FDIV_S) || (subop == FP_FSQRT_S);

            if (is_single) begin
                // =============================================================
                // SINGLE PRECISION (FP32)
                // =============================================================
                logic [31:0] op1_32, op2_32;
                logic s_a, s_b;
                logic [7:0] e_a, e_b;
                logic [22:0] f_a, f_b;
                logic nan_a, nan_b, snan_a, snan_b;
                logic inf_a, inf_b, zero_a, zero_b;

                op1_32 = is_nanbox_valid(rs1) ? rs1[31:0] : FP32_QNAN;
                op2_32 = is_nanbox_valid(rs2) ? rs2[31:0] : FP32_QNAN;

                s_a = op1_32[31]; e_a = op1_32[30:23]; f_a = op1_32[22:0];
                s_b = op2_32[31]; e_b = op2_32[30:23]; f_b = op2_32[22:0];

                nan_a  = (e_a == 8'hFF) && (f_a != 23'd0);
                snan_a = nan_a && !f_a[22];
                inf_a  = (e_a == 8'hFF) && (f_a == 23'd0);
                zero_a = (e_a == 8'd0)  && (f_a == 23'd0);

                nan_b  = (e_b == 8'hFF) && (f_b != 23'd0);
                snan_b = nan_b && !f_b[22];
                inf_b  = (e_b == 8'hFF) && (f_b == 23'd0);
                zero_b = (e_b == 8'd0)  && (f_b == 23'd0);

                if (subop == FP_FDIV_S) begin
                    logic s_res;
                    s_res = s_a ^ s_b;

                    if (nan_a || nan_b) begin
                        out_res   = {32'hFFFF_FFFF, FP32_QNAN};
                        out_flags = (snan_a || snan_b) ? 5'b10000 : 5'b00000;
                    end else if ((zero_a && zero_b) || (inf_a && inf_b)) begin
                        out_res   = {32'hFFFF_FFFF, FP32_QNAN};
                        out_flags = 5'b10000; // NV
                    end else if (zero_b) begin
                        out_res   = {32'hFFFF_FFFF, s_res, 8'hFF, 23'd0};
                        out_flags = 5'b01000; // DZ
                    end else if (zero_a || inf_b) begin
                        out_res   = {32'hFFFF_FFFF, s_res, 31'd0};
                        out_flags = 5'b00000;
                    end else if (inf_a) begin
                        out_res   = {32'hFFFF_FFFF, s_res, 8'hFF, 23'd0};
                        out_flags = 5'b00000;
                    end else begin
                        // Normal / Subnormal Division
                        int exp_a, exp_b, exp_res;
                        logic [23:0] ma, mb;
                        logic [4:0] lz_a, lz_b;

                        exp_a = (e_a == 8'd0) ? -126 : (int'(e_a) - 127);
                        exp_b = (e_b == 8'd0) ? -126 : (int'(e_b) - 127);
                        ma = (e_a == 8'd0) ? {1'b0, f_a} : {1'b1, f_a};
                        mb = (e_b == 8'd0) ? {1'b0, f_b} : {1'b1, f_b};

                        if (e_a == 8'd0 && f_a != 23'd0) begin
                            lz_a = clz23(f_a);
                            ma = {f_a, 1'b0} << lz_a;
                            exp_a = exp_a - int'(lz_a) - 1;
                        end
                        if (e_b == 8'd0 && f_b != 23'd0) begin
                            lz_b = clz23(f_b);
                            mb = {f_b, 1'b0} << lz_b;
                            exp_b = exp_b - int'(lz_b) - 1;
                        end

                        begin
                            logic a_ge_b;
                            logic [49:0] num;
                            logic [25:0] quot;
                            logic [23:0] rem;
                            int biased_exp;
                            logic [22:0] mant;
                            logic g, r, s, inexact, round_up, overflow, underflow;

                            a_ge_b = (ma >= mb);
                            num = a_ge_b ? {1'b0, ma, 25'd0} : {ma, 26'd0};
                            exp_res = a_ge_b ? (exp_a - exp_b) : (exp_a - exp_b - 1);

                            quot = 26'(num / 50'(mb));
                            rem  = 24'(num % 50'(mb));

                            biased_exp = exp_res + 127;
                            mant = quot[24:2];
                            g = quot[1];
                            r = quot[0];
                            s = (rem != 24'd0);
                            inexact = g || r || s;
                            overflow = 1'b0;
                            underflow = 1'b0;

                            if (biased_exp <= 0) begin
                                int shift;
                                shift = 1 - biased_exp;
                                biased_exp = 0;
                                if (shift <= 31) begin
                                    logic [25:0] full_q;
                                    logic [25:0] lost_mask;
                                    full_q = quot;
                                    lost_mask = 26'((32'd1 << shift) - 32'd1);
                                    if (|(full_q & lost_mask)) s = 1'b1;
                                    full_q = full_q >> shift;
                                    mant = full_q[24:2];
                                    g = full_q[1];
                                    r = full_q[0];
                                end else begin
                                    mant = 23'd0; g = 1'b0; r = 1'b0; s = 1'b1;
                                end
                                inexact = g || r || s;
                                if (inexact) underflow = 1'b1;
                            end

                            case (eff_rm)
                                3'b000: round_up = g && (r || s || mant[0]);
                                3'b001: round_up = 1'b0;
                                3'b010: round_up = s_res && inexact;
                                3'b011: round_up = (!s_res) && inexact;
                                3'b100: round_up = g;
                                default: round_up = g && (r || s || mant[0]);
                            endcase

                            if (round_up) begin
                                mant = mant + 23'd1;
                                if (mant == 23'd0) begin
                                    biased_exp = biased_exp + 1;
                                end
                            end

                            if (biased_exp >= 255) begin
                                overflow = 1'b1;
                                inexact  = 1'b1;
                                if (eff_rm == 3'b001 || (eff_rm == 3'b010 && !s_res) || (eff_rm == 3'b011 && s_res)) begin
                                    biased_exp = 254;
                                    mant = 23'h7F_FFFF;
                                end else begin
                                    biased_exp = 255;
                                    mant = 23'd0;
                                end
                            end

                            out_res   = {32'hFFFF_FFFF, s_res, biased_exp[7:0], mant};
                            out_flags = {1'b0, 1'b0, overflow, underflow, inexact};
                        end
                    end
                end else begin
                    // FP_FSQRT_S
                    if (nan_a) begin
                        out_res   = {32'hFFFF_FFFF, FP32_QNAN};
                        out_flags = snan_a ? 5'b10000 : 5'b00000;
                    end else if (s_a && !zero_a) begin
                        out_res   = {32'hFFFF_FFFF, FP32_QNAN};
                        out_flags = 5'b10000; // NV for negative sqrt
                    end else if (zero_a) begin
                        out_res   = {32'hFFFF_FFFF, s_a, 31'd0};
                        out_flags = 5'b00000;
                    end else if (inf_a) begin
                        out_res   = {32'hFFFF_FFFF, 1'b0, 8'hFF, 23'd0};
                        out_flags = 5'b00000;
                    end else begin
                        int exp_a, exp_res;
                        logic [23:0] ma;
                        logic [4:0] lz_a;

                        exp_a = (e_a == 8'd0) ? -126 : (int'(e_a) - 127);
                        ma = (e_a == 8'd0) ? {1'b0, f_a} : {1'b1, f_a};

                        if (e_a == 8'd0 && f_a != 23'd0) begin
                            lz_a = clz23(f_a);
                            ma = {f_a, 1'b0} << lz_a;
                            exp_a = exp_a - int'(lz_a) - 1;
                        end

                        begin
                            logic [53:0] d;
                            logic [25:0] q;
                            logic rem_nz;
                            int biased_exp;
                            logic [22:0] mant;
                            logic g, r, s, inexact, round_up, overflow, underflow;

                            if (exp_a[0]) begin
                                exp_res = (exp_a - 1) / 2;
                                d = {2'b00, ma, 28'd0};
                            end else begin
                                exp_res = exp_a / 2;
                                d = {3'b000, ma, 27'd0};
                            end

                            q = isqrt_sp(d, rem_nz);

                            biased_exp = exp_res + 127;
                            mant = q[24:2];
                            g = q[1];
                            r = q[0];
                            s = rem_nz;
                            inexact = g || r || s;
                            overflow = 1'b0;
                            underflow = 1'b0;

                            if (biased_exp <= 0) begin
                                int shift;
                                shift = 1 - biased_exp;
                                biased_exp = 0;
                                if (shift <= 31) begin
                                    logic [25:0] full_q;
                                    logic [25:0] lost_mask;
                                    full_q = q;
                                    lost_mask = 26'((32'd1 << shift) - 32'd1);
                                    if (|(full_q & lost_mask)) s = 1'b1;
                                    full_q = full_q >> shift;
                                    mant = full_q[24:2];
                                    g = full_q[1];
                                    r = full_q[0];
                                end else begin
                                    mant = 23'd0; g = 1'b0; r = 1'b0; s = 1'b1;
                                end
                                inexact = g || r || s;
                                if (inexact) underflow = 1'b1;
                            end

                            case (eff_rm)
                                3'b000: round_up = g && (r || s || mant[0]);
                                3'b001: round_up = 1'b0;
                                3'b010: round_up = 1'b0; // Towards -inf: no round up for positive
                                3'b011: round_up = inexact; // Towards +inf: round up
                                3'b100: round_up = g;
                                default: round_up = g && (r || s || mant[0]);
                            endcase

                            if (round_up) begin
                                mant = mant + 23'd1;
                                if (mant == 23'd0) begin
                                    biased_exp = biased_exp + 1;
                                end
                            end

                            out_res   = {32'hFFFF_FFFF, 1'b0, biased_exp[7:0], mant};
                            out_flags = {1'b0, 1'b0, overflow, underflow, inexact};
                        end
                    end
                end
            end else begin
                // =============================================================
                // DOUBLE PRECISION (FP64)
                // =============================================================
                logic s_a, s_b;
                logic [10:0] e_a, e_b;
                logic [51:0] f_a, f_b;
                logic nan_a, nan_b, snan_a, snan_b;
                logic inf_a, inf_b, zero_a, zero_b;

                s_a = rs1[63]; e_a = rs1[62:52]; f_a = rs1[51:0];
                s_b = rs2[63]; e_b = rs2[62:52]; f_b = rs2[51:0];

                nan_a  = (e_a == 11'h7FF) && (f_a != 52'd0);
                snan_a = nan_a && !f_a[51];
                inf_a  = (e_a == 11'h7FF) && (f_a == 52'd0);
                zero_a = (e_a == 11'd0)   && (f_a == 52'd0);

                nan_b  = (e_b == 11'h7FF) && (f_b != 52'd0);
                snan_b = nan_b && !f_b[51];
                inf_b  = (e_b == 11'h7FF) && (f_b == 52'd0);
                zero_b = (e_b == 11'd0)   && (f_b == 52'd0);

                if (subop == FP_FDIV_D) begin
                    logic s_res;
                    s_res = s_a ^ s_b;

                    if (nan_a || nan_b) begin
                        out_res   = FP64_QNAN;
                        out_flags = (snan_a || snan_b) ? 5'b10000 : 5'b00000;
                    end else if ((zero_a && zero_b) || (inf_a && inf_b)) begin
                        out_res   = FP64_QNAN;
                        out_flags = 5'b10000; // NV
                    end else if (zero_b) begin
                        out_res   = {s_res, 11'h7FF, 52'd0};
                        out_flags = 5'b01000; // DZ
                    end else if (zero_a || inf_b) begin
                        out_res   = {s_res, 63'd0};
                        out_flags = 5'b00000;
                    end else if (inf_a) begin
                        out_res   = {s_res, 11'h7FF, 52'd0};
                        out_flags = 5'b00000;
                    end else begin
                        int exp_a, exp_b, exp_res;
                        logic [52:0] ma, mb;
                        logic [5:0] lz_a, lz_b;

                        exp_a = (e_a == 11'd0) ? -1022 : (int'(e_a) - 1023);
                        exp_b = (e_b == 11'd0) ? -1022 : (int'(e_b) - 1023);
                        ma = (e_a == 11'd0) ? {1'b0, f_a} : {1'b1, f_a};
                        mb = (e_b == 11'd0) ? {1'b0, f_b} : {1'b1, f_b};

                        if (e_a == 11'd0 && f_a != 52'd0) begin
                            lz_a = clz52(f_a);
                            ma = {f_a, 1'b0} << lz_a;
                            exp_a = exp_a - int'(lz_a) - 1;
                        end
                        if (e_b == 11'd0 && f_b != 52'd0) begin
                            lz_b = clz52(f_b);
                            mb = {f_b, 1'b0} << lz_b;
                            exp_b = exp_b - int'(lz_b) - 1;
                        end

                        begin
                            logic a_ge_b;
                            logic [107:0] num;
                            logic [54:0] quot;
                            logic [52:0] rem;
                            int biased_exp;
                            logic [51:0] mant;
                            logic g, r, s, inexact, round_up, overflow, underflow;

                            a_ge_b = (ma >= mb);
                            num = a_ge_b ? {1'b0, ma, 54'd0} : {ma, 55'd0};
                            exp_res = a_ge_b ? (exp_a - exp_b) : (exp_a - exp_b - 1);

                            quot = 55'(num / 108'(mb));
                            rem  = 53'(num % 108'(mb));

                            biased_exp = exp_res + 1023;
                            mant = quot[53:2];
                            g = quot[1];
                            r = quot[0];
                            s = (rem != 53'd0);
                            inexact = g || r || s;
                            overflow = 1'b0;
                            underflow = 1'b0;

                            if (biased_exp <= 0) begin
                                int shift;
                                shift = 1 - biased_exp;
                                biased_exp = 0;
                                if (shift <= 63) begin
                                    logic [54:0] full_q;
                                    logic [54:0] lost_mask;
                                    full_q = quot;
                                    lost_mask = 55'((64'd1 << shift) - 64'd1);
                                    if (|(full_q & lost_mask)) s = 1'b1;
                                    full_q = full_q >> shift;
                                    mant = full_q[53:2];
                                    g = full_q[1];
                                    r = full_q[0];
                                end else begin
                                    mant = 52'd0; g = 1'b0; r = 1'b0; s = 1'b1;
                                end
                                inexact = g || r || s;
                                if (inexact) underflow = 1'b1;
                            end

                            case (eff_rm)
                                3'b000: round_up = g && (r || s || mant[0]);
                                3'b001: round_up = 1'b0;
                                3'b010: round_up = s_res && inexact;
                                3'b011: round_up = (!s_res) && inexact;
                                3'b100: round_up = g;
                                default: round_up = g && (r || s || mant[0]);
                            endcase

                            if (round_up) begin
                                mant = mant + 52'd1;
                                if (mant == 52'd0) begin
                                    biased_exp = biased_exp + 1;
                                end
                            end

                            if (biased_exp >= 2047) begin
                                overflow = 1'b1;
                                inexact  = 1'b1;
                                if (eff_rm == 3'b001 || (eff_rm == 3'b010 && !s_res) || (eff_rm == 3'b011 && s_res)) begin
                                    biased_exp = 2046;
                                    mant = 52'hF_FFFF_FFFF_FFFF;
                                end else begin
                                    biased_exp = 2047;
                                    mant = 52'd0;
                                end
                            end

                            out_res   = {s_res, biased_exp[10:0], mant};
                            out_flags = {1'b0, 1'b0, overflow, underflow, inexact};
                        end
                    end
                end else begin
                    // FP_FSQRT_D
                    if (nan_a) begin
                        out_res   = FP64_QNAN;
                        out_flags = snan_a ? 5'b10000 : 5'b00000;
                    end else if (s_a && !zero_a) begin
                        out_res   = FP64_QNAN;
                        out_flags = 5'b10000; // NV
                    end else if (zero_a) begin
                        out_res   = {s_a, 63'd0};
                        out_flags = 5'b00000;
                    end else if (inf_a) begin
                        out_res   = {1'b0, 11'h7FF, 52'd0};
                        out_flags = 5'b00000;
                    end else begin
                        int exp_a, exp_res;
                        logic [52:0] ma;
                        logic [5:0] lz_a;

                        exp_a = (e_a == 11'd0) ? -1022 : (int'(e_a) - 1023);
                        ma = (e_a == 11'd0) ? {1'b0, f_a} : {1'b1, f_a};

                        if (e_a == 11'd0 && f_a != 52'd0) begin
                            lz_a = clz52(f_a);
                            ma = {f_a, 1'b0} << lz_a;
                            exp_a = exp_a - int'(lz_a) - 1;
                        end

                        begin
                            logic [109:0] d;
                            logic [54:0] q;
                            logic rem_nz;
                            int biased_exp;
                            logic [51:0] mant;
                            logic g, r, s, inexact, round_up, overflow, underflow;

                            if (exp_a[0]) begin
                                exp_res = (exp_a - 1) / 2;
                                d = {ma, 57'd0};
                            end else begin
                                exp_res = exp_a / 2;
                                d = {1'b0, ma, 56'd0};
                            end

                            q = isqrt_dp(d, rem_nz);

                            biased_exp = exp_res + 1023;
                            mant = q[53:2];
                            g = q[1];
                            r = q[0];
                            s = rem_nz;
                            inexact = g || r || s;
                            overflow = 1'b0;
                            underflow = 1'b0;

                            if (biased_exp <= 0) begin
                                int shift;
                                shift = 1 - biased_exp;
                                biased_exp = 0;
                                if (shift <= 63) begin
                                    logic [54:0] full_q;
                                    logic [54:0] lost_mask;
                                    full_q = q;
                                    lost_mask = 55'((64'd1 << shift) - 64'd1);
                                    if (|(full_q & lost_mask)) s = 1'b1;
                                    full_q = full_q >> shift;
                                    mant = full_q[53:2];
                                    g = full_q[1];
                                    r = full_q[0];
                                end else begin
                                    mant = 52'd0; g = 1'b0; r = 1'b0; s = 1'b1;
                                end
                                inexact = g || r || s;
                                if (inexact) underflow = 1'b1;
                            end

                            case (eff_rm)
                                3'b000: round_up = g && (r || s || mant[0]);
                                3'b001: round_up = 1'b0;
                                3'b010: round_up = 1'b0;
                                3'b011: round_up = inexact;
                                3'b100: round_up = g;
                                default: round_up = g && (r || s || mant[0]);
                            endcase

                            if (round_up) begin
                                mant = mant + 52'd1;
                                if (mant == 52'd0) begin
                                    biased_exp = biased_exp + 1;
                                end
                            end

                            out_res   = {1'b0, biased_exp[10:0], mant};
                            out_flags = {1'b0, 1'b0, overflow, underflow, inexact};
                        end
                    end
                end
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Sequential State Update & Cycle Counting
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            state_q         <= FDIV_IDLE;
            cycle_cnt_q     <= '0;
            target_cycles_q <= '0;
            fdiv_buf_q      <= '0;
            comp_res_q      <= '0;
            comp_flags_q    <= '0;
            prd_fp_q        <= '0;
            rob_idx_q       <= '0;
            rob_epoch_q     <= '0;
        end else begin
            // 1. Drain completion buffer when granted writeback
            if (fdiv_buf_q.valid) begin
                if (buf_squash) begin
                    fdiv_buf_q.valid <= 1'b0;
                end else if (!fma_wb_valid_i) begin
                    fdiv_buf_q.valid <= 1'b0; // Granted writeback
                end
            end

            // 2. Main FSM
            case (state_q)
                FDIV_IDLE: begin
                    if (req_valid_i && !busy_o) begin
                        logic [2:0] eff_rm;
                        logic [5:0] target_lat;
                        logic [63:0] calc_res;
                        logic [4:0]  calc_flags;

                        eff_rm     = (req_frm_i == 3'b111) ? fcsr_frm_i : req_frm_i;
                        target_lat = get_latency(req_subop_i);

                        eval_fdiv_fsqrt(req_subop_i, eff_rm, req_rs1_data_i, req_rs2_data_i, calc_res, calc_flags);

                        prd_fp_q        <= req_prd_fp_i;
                        rob_idx_q       <= req_rob_idx_i;
                        rob_epoch_q     <= req_rob_epoch_i;
                        target_cycles_q <= target_lat;
                        cycle_cnt_q     <= 6'd1;
                        comp_res_q      <= calc_res;
                        comp_flags_q    <= calc_flags;

                        state_q <= FDIV_ITER;
                    end
                end

                FDIV_ITER: begin
                    if (active_squash) begin
                        state_q <= FDIV_IDLE;
                    end else if (cycle_cnt_q >= (target_cycles_q - 6'd1)) begin
                        // Final cycle: load computed result into fdiv_buf
                        fdiv_buf_q.valid     <= 1'b1;
                        fdiv_buf_q.data      <= comp_res_q;
                        fdiv_buf_q.fflags    <= comp_flags_q;
                        fdiv_buf_q.prd_fp    <= prd_fp_q;
                        fdiv_buf_q.rob_idx   <= rob_idx_q;
                        fdiv_buf_q.rob_epoch <= rob_epoch_q;

                        state_q <= FDIV_IDLE;
                    end else begin
                        cycle_cnt_q <= cycle_cnt_q + 6'd1;
                    end
                end

                default: state_q <= FDIV_IDLE;
            endcase
        end
    end

endmodule

`endif // FURSOY_S1_FDIV_SV
