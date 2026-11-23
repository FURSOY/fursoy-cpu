`ifndef FURSOY_S1_MULTIPLIER_SV
`define FURSOY_S1_MULTIPLIER_SV

// =============================================================================
// Fursoy Slice-1 3-Stage Pipelined 65x65 Unified Multiplier — S2.5-M1b
// =============================================================================
// Genuine 3-stage pipelined RV64M integer multiplier (K = 3 stages):
// - Supports MUL, MULH, MULHSU, MULHU, and MULW via one unified 65x65 signed
//   Radix-4 Booth multiplier:
//     * Stage 1 (Issue -> S1): Operand sign/zero extension, 33 Radix-4 Booth
//       partial products, and 4 levels of 3:2 Carry-Save Adders (33 -> 7 rows).
//     * Stage 2 (S1 -> S2): Remaining 4 levels of 3:2 Carry-Save Adders
//       (7 -> 2 carry-save vectors: sum_q[127:0], carry_q[127:0]).
//     * Stage 3 (S2 -> S3): Carry-select 128-bit Kogge-Stone Carry-Propagate
//       Adder (shared fursoy_s1_ks_adder) and MUL/MULH/MULW output selection.
// - Wrap-safe ROB branch-recovery squash at every stage and full flush abort.
// - Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.5.2 & 14
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_ks_adder.sv"

module fursoy_s1_multiplier
    import fursoy_s1_pkg::*;
#(
    /* verilator lint_off UNUSEDPARAM */
    parameter int unsigned K = MUL_STAGES // 3-stage pipeline
    /* verilator lint_on UNUSEDPARAM */
) (
    input  logic              clk_i,
    input  logic              rst_i,

    // Flush and branch recovery interfaces
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    // Issue input (Stage 0 -> Stage 1)
    input  logic              issue_valid_i,
    input  uop_subop_t        sub_op_i,
    input  logic [63:0]       op_a_i,
    input  logic [63:0]       op_b_i,
    input  preg_t             pnew_i,
    input  rob_idx_t          rob_idx_i,
    input  rob_epoch_t        rob_epoch_i,

    // Multiplier pipeline status for pre-issue credit reservation
    output logic [1:0]        in_flight_count_o, // 0..3 ops currently in pipeline

    // Output from Stage 3 (to mul_fifo)
    output logic              out_valid_o,
    output logic [63:0]       out_data_o,
    output preg_t             out_pnew_o,
    output rob_idx_t          out_rob_idx_o,
    output rob_epoch_t        out_rob_epoch_o
);

    // -------------------------------------------------------------------------
    // Pipeline Stage Metadata
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic       valid;
        preg_t      pnew;
        rob_idx_t   rob_idx;
        rob_epoch_t rob_epoch;
        uop_subop_t sub_op;
    } stage_meta_t;

    typedef struct packed {
        logic       valid;
        preg_t      pnew;
        rob_idx_t   rob_idx;
        rob_epoch_t rob_epoch;
    } stage3_meta_t;

    stage_meta_t  stage1_meta_q, stage2_meta_q;
    stage3_meta_t stage3_meta_q;

    // -------------------------------------------------------------------------
    // 3:2 Carry-Save Adder Helper (128-bit)
    // -------------------------------------------------------------------------
    function automatic void csa128(
        input  logic [127:0] a,
        input  logic [127:0] b,
        input  logic [127:0] c,
        output logic [127:0] sum_o,
        output logic [127:0] carry_o
    );
        sum_o   = a ^ b ^ c;
        carry_o = {((a[126:0] & b[126:0]) | (b[126:0] & c[126:0]) | (a[126:0] & c[126:0])), 1'b0};
    endfunction

    // -------------------------------------------------------------------------
    // Stage 1: Unified 65x65 Sign/Zero Extend, 33 Radix-4 Booth PPs & CSA L1-L4
    // -------------------------------------------------------------------------
    wire is_signed_a = (sub_op_i == MUL_MULH) || (sub_op_i == MUL_MULHSU);
    wire is_signed_b = (sub_op_i == MUL_MULH);

    wire [64:0] a_ext = {is_signed_a ? op_a_i[63] : 1'b0, op_a_i};
    wire [64:0] b_ext = {is_signed_b ? op_b_i[63] : 1'b0, op_b_i};

    // Padded 67-bit multiplier for 33 Radix-4 Booth groups (b[-1]=0, b[65]=b[64])
    wire [66:0] b_booth = {b_ext[64], b_ext, 1'b0};

    // Sign-extended 128-bit multiplicand (1x and 2x)
    wire [127:0] a_128  = {{63{a_ext[64]}}, a_ext};
    wire [127:0] a2_128 = {a_128[126:0], 1'b0};

    // Generate 33 Radix-4 Booth partial products + 1 consolidated hot-bit vector
    // for the two's-complement negation (+1 at bit 2*i when Booth digit < 0).
    // Note: bit 2*i is unique across all 33 groups (bits 0,2,4,...,64), so all
    // 33 hot bits pack into ONE 128-bit vector with zero overlap (34 vectors total).
    logic [127:0] pp [34];

    always_comb begin : blk_booth_pp
        logic [127:0] hot_vec;
        hot_vec = 128'd0;

        for (int i = 0; i < 33; i++) begin
            logic [2:0]   grp;
            logic         neg;
            logic [127:0] mag;
            logic [127:0] raw_pp;

            grp = b_booth[2*i +: 3];
            neg = grp[2] && !(grp == 3'b111);

            case (grp)
                3'b001, 3'b010,
                3'b101, 3'b110: mag = a_128;
                3'b011, 3'b100: mag = a2_128;
                default:        mag = 128'd0;
            endcase

            // When neg=1, invert bits and place the +1 at bit position 2*i in hot_vec.
            // Because ~(x << 2*i) + (1 << 2*i) == (-x) << 2*i mod 2^128, we invert mag
            // BEFORE shifting left by 2*i (zeros fill low 2*i bits) and add 1 << 2*i.
            raw_pp = neg ? (~mag) : mag;
            pp[i]  = raw_pp << (2 * i);
            if (neg) begin
                hot_vec[2*i] = 1'b1;
            end
        end

        pp[33] = hot_vec;
    end

    // Stage 1 Wallace CSA Reduction: 34 -> 23 -> 16 -> 11 -> 8 rows (4 CSA levels)
    logic [127:0] s1_out [8];

    always_comb begin : blk_csa_s1
        logic [127:0] l1 [23];
        logic [127:0] l2 [16];
        logic [127:0] l3 [11];
        logic [127:0] s, c;

        // Level 1: 34 -> 23 (11 CSAs + 1 pass-through)
        for (int i = 0; i < 11; i++) begin
            csa128(pp[3*i], pp[3*i + 1], pp[3*i + 2], s, c);
            l1[2*i]     = s;
            l1[2*i + 1] = c;
        end
        l1[22] = pp[33];

        // Level 2: 23 -> 16 (7 CSAs + 2 pass-through)
        for (int i = 0; i < 7; i++) begin
            csa128(l1[3*i], l1[3*i + 1], l1[3*i + 2], s, c);
            l2[2*i]     = s;
            l2[2*i + 1] = c;
        end
        l2[14] = l1[21];
        l2[15] = l1[22];

        // Level 3: 16 -> 11 (5 CSAs + 1 pass-through)
        for (int i = 0; i < 5; i++) begin
            csa128(l2[3*i], l2[3*i + 1], l2[3*i + 2], s, c);
            l3[2*i]     = s;
            l3[2*i + 1] = c;
        end
        l3[10] = l2[15];

        // Level 4: 11 -> 8 (3 CSAs + 2 pass-through)
        for (int i = 0; i < 3; i++) begin
            csa128(l3[3*i], l3[3*i + 1], l3[3*i + 2], s, c);
            s1_out[2*i]     = s;
            s1_out[2*i + 1] = c;
        end
        s1_out[6] = l3[9];
        s1_out[7] = l3[10];
    end

    // Stage 1 -> Stage 2 Pipeline Registers (8 x 128-bit partial-sum rows)
    logic [127:0] s1_rows_q [8];

    wire s0_is_squashed = recover_valid_i && (rob_dist(rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            stage1_meta_q <= '0;
            for (int i = 0; i < 8; i++) begin
                s1_rows_q[i] <= 128'd0;
            end
        end else begin
            if (issue_valid_i && !s0_is_squashed) begin
                stage1_meta_q.valid     <= 1'b1;
                stage1_meta_q.pnew      <= pnew_i;
                stage1_meta_q.rob_idx   <= rob_idx_i;
                stage1_meta_q.rob_epoch <= rob_epoch_i;
                stage1_meta_q.sub_op    <= sub_op_i;
                for (int i = 0; i < 8; i++) begin
                    s1_rows_q[i] <= s1_out[i];
                end
            end else begin
                stage1_meta_q.valid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2: Wallace CSA Reduction (8 -> 6 -> 4 -> 3 -> 2 Carry-Save Pair)
    // -------------------------------------------------------------------------
    logic [127:0] s2_sum_comb, s2_carry_comb;

    always_comb begin : blk_csa_s2
        logic [127:0] l5 [6];
        logic [127:0] l6 [4];
        logic [127:0] l7 [3];
        logic [127:0] s, c;

        // Level 5: 8 -> 6 (2 CSAs + 2 pass-through)
        csa128(s1_rows_q[0], s1_rows_q[1], s1_rows_q[2], l5[0], l5[1]);
        csa128(s1_rows_q[3], s1_rows_q[4], s1_rows_q[5], l5[2], l5[3]);
        l5[4] = s1_rows_q[6];
        l5[5] = s1_rows_q[7];

        // Level 6: 6 -> 4 (2 CSAs)
        csa128(l5[0], l5[1], l5[2], l6[0], l6[1]);
        csa128(l5[3], l5[4], l5[5], l6[2], l6[3]);

        // Level 7: 4 -> 3 (1 CSA + 1 pass-through)
        csa128(l6[0], l6[1], l6[2], l7[0], l7[1]);
        l7[2] = l6[3];

        // Level 8: 3 -> 2 (1 CSA)
        csa128(l7[0], l7[1], l7[2], s, c);
        s2_sum_comb   = s;
        s2_carry_comb = c;
    end

    // Stage 2 -> Stage 3 Pipeline Registers (Carry-Save Pair)
    logic [127:0] s2_sum_q, s2_carry_q;

    wire s1_is_squashed = recover_valid_i && (rob_dist(stage1_meta_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            stage2_meta_q <= '0;
            s2_sum_q      <= 128'd0;
            s2_carry_q    <= 128'd0;
        end else begin
            if (stage1_meta_q.valid && !s1_is_squashed) begin
                stage2_meta_q <= stage1_meta_q;
                s2_sum_q      <= s2_sum_comb;
                s2_carry_q    <= s2_carry_comb;
            end else begin
                stage2_meta_q.valid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3: Carry-Select 128-bit Kogge-Stone CPA & Result Formatting
    // -------------------------------------------------------------------------
    logic [64:0] s3_lo_sum_ext;
    logic [63:0] s3_hi_sum0, s3_hi_sum1;

    // 65-bit lower sum produces exact carry-out into bit 64 in parallel with hi0/hi1
    fursoy_s1_ks_adder #(.WIDTH(65)) u_ks_lo (
        .a_i   ({1'b0, s2_sum_q[63:0]}),
        .b_i   ({1'b0, s2_carry_q[63:0]}),
        .cin_i (1'b0),
        .sum_o (s3_lo_sum_ext)
    );

    fursoy_s1_ks_adder #(.WIDTH(64)) u_ks_hi0 (
        .a_i   (s2_sum_q[127:64]),
        .b_i   (s2_carry_q[127:64]),
        .cin_i (1'b0),
        .sum_o (s3_hi_sum0)
    );

    fursoy_s1_ks_adder #(.WIDTH(64)) u_ks_hi1 (
        .a_i   (s2_sum_q[127:64]),
        .b_i   (s2_carry_q[127:64]),
        .cin_i (1'b1),
        .sum_o (s3_hi_sum1)
    );

    wire [63:0] s3_prod_lo = s3_lo_sum_ext[63:0];
    wire        s3_lo_cout = s3_lo_sum_ext[64];
    wire [63:0] s3_prod_hi = s3_lo_cout ? s3_hi_sum1 : s3_hi_sum0;

    logic [63:0] s3_selected_res;
    always_comb begin
        case (stage2_meta_q.sub_op)
            MUL_MUL:    s3_selected_res = s3_prod_lo;
            MUL_MULH,
            MUL_MULHU,
            MUL_MULHSU: s3_selected_res = s3_prod_hi;
            MUL_MULW:   s3_selected_res = {{32{s3_prod_lo[31]}}, s3_prod_lo[31:0]};
            default:    s3_selected_res = s3_prod_lo;
        endcase
    end

    logic [63:0] s3_result_q;

    wire s2_is_squashed = recover_valid_i && (rob_dist(stage2_meta_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            stage3_meta_q <= '0;
            s3_result_q   <= 64'd0;
        end else begin
            if (stage2_meta_q.valid && !s2_is_squashed) begin
                stage3_meta_q.valid     <= 1'b1;
                stage3_meta_q.pnew      <= stage2_meta_q.pnew;
                stage3_meta_q.rob_idx   <= stage2_meta_q.rob_idx;
                stage3_meta_q.rob_epoch <= stage2_meta_q.rob_epoch;
                s3_result_q             <= s3_selected_res;
            end else begin
                stage3_meta_q.valid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3 Output Assignment
    // -------------------------------------------------------------------------
    wire s3_is_squashed = recover_valid_i && (rob_dist(stage3_meta_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    assign out_valid_o     = stage3_meta_q.valid && !s3_is_squashed && !flush_valid_i;
    assign out_pnew_o      = stage3_meta_q.pnew;
    assign out_rob_idx_o   = stage3_meta_q.rob_idx;
    assign out_rob_epoch_o = stage3_meta_q.rob_epoch;
    assign out_data_o      = s3_result_q;

    // -------------------------------------------------------------------------
    // In-Flight Accounting (for Pre-Issue Credit Gating)
    // -------------------------------------------------------------------------
    logic [1:0] inflight_cnt;
    always_comb begin
        inflight_cnt = 2'd0;
        if (stage1_meta_q.valid && !s1_is_squashed) inflight_cnt = inflight_cnt + 2'd1;
        if (stage2_meta_q.valid && !s2_is_squashed) inflight_cnt = inflight_cnt + 2'd1;
        if (stage3_meta_q.valid && !s3_is_squashed) inflight_cnt = inflight_cnt + 2'd1;
    end
    assign in_flight_count_o = inflight_cnt;

endmodule

`endif // FURSOY_S1_MULTIPLIER_SV
