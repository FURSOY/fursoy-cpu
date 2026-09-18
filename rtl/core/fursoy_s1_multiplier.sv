`ifndef FURSOY_S1_MULTIPLIER_SV
`define FURSOY_S1_MULTIPLIER_SV

// =============================================================================
// Fursoy Slice-1 Pipelined 64-bit Multiplier — Milestone 2
// =============================================================================
// Pipelined RV64M integer multiplier with K=3 stages (provisional baseline).
// Supports MUL, MULH, MULHSU, MULHU, and MULW.
// Features wrap-safe ROB squash invalidation and full flush recovery.
// Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.5.2 & 14
// =============================================================================

module fursoy_s1_multiplier
    import fursoy_s1_pkg::*;
#(
    /* verilator lint_off UNUSEDPARAM */
    parameter int unsigned K = MUL_STAGES // Baseline K=3
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

    // Output from Stage K (to mul_fifo)
    output logic              out_valid_o,
    output logic [63:0]       out_data_o,
    output preg_t             out_pnew_o,
    output rob_idx_t          out_rob_idx_o,
    output rob_epoch_t        out_rob_epoch_o
);

    // -------------------------------------------------------------------------
    // Pipeline Stage Registers (K = 3)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic       valid;
        preg_t      pnew;
        rob_idx_t   rob_idx;
        rob_epoch_t rob_epoch;
        uop_subop_t sub_op;
    } stage_meta_t;

    /* verilator lint_off UNUSEDSIGNAL */
    stage_meta_t stage1_meta_q, stage2_meta_q, stage3_meta_q;

    // Intermediate computation registers
    logic signed [127:0] s1_prod_signed;
    logic        [127:0] s1_prod_unsigned;
    logic signed [129:0] s1_prod_su;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        [31:0]  s1_prod_w;
    logic        [63:0]  s1_prod_low;

    logic        [63:0]  s2_result_q;
    logic        [63:0]  s3_result_q;
    logic        [63:0]  s4_result_q;

    // -------------------------------------------------------------------------
    // Stage 1 Combinational Products
    // -------------------------------------------------------------------------
    always_comb begin
        // Signed x Signed (for MULH)
        s1_prod_signed   = $signed({{64{op_a_i[63]}}, op_a_i}) * $signed({{64{op_b_i[63]}}, op_b_i});
        // Unsigned x Unsigned (for MULHU)
        s1_prod_unsigned = {64'd0, op_a_i} * {64'd0, op_b_i};
        // Signed x Unsigned (for MULHSU)
        s1_prod_su       = $signed({{66{op_a_i[63]}}, op_a_i}) * $signed({66'd0, op_b_i});
        // Word product (for MULW)
        s1_prod_w        = op_a_i[31:0] * op_b_i[31:0];
        // Low product (for MUL)
        s1_prod_low      = op_a_i * op_b_i;
    end

    // Combinational result selection for Stage 1 -> Stage 2
    logic [63:0] s1_selected_res;
    always_comb begin
        case (sub_op_i)
            MUL_MUL:    s1_selected_res = s1_prod_low;
            MUL_MULH:   s1_selected_res = s1_prod_signed[127:64];
            MUL_MULHU:  s1_selected_res = s1_prod_unsigned[127:64];
            MUL_MULHSU: s1_selected_res = s1_prod_su[127:64];
            MUL_MULW:   s1_selected_res = {{32{s1_prod_w[31]}}, s1_prod_w};
            default:    s1_selected_res = s1_prod_low;
        endcase
    end

    // -------------------------------------------------------------------------
    // Stage 1 Register Update (IS -> Stage 1)
    // -------------------------------------------------------------------------
    wire s0_is_squashed = recover_valid_i && (rob_dist(rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            stage1_meta_q <= '0;
            s2_result_q   <= 64'd0;
        end else begin
            if (issue_valid_i && !s0_is_squashed) begin
                stage1_meta_q.valid     <= 1'b1;
                stage1_meta_q.pnew      <= pnew_i;
                stage1_meta_q.rob_idx   <= rob_idx_i;
                stage1_meta_q.rob_epoch <= rob_epoch_i;
                stage1_meta_q.sub_op    <= sub_op_i;
                s2_result_q             <= s1_selected_res;
            end else begin
                stage1_meta_q.valid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2 Register Update (Stage 1 -> Stage 2)
    // -------------------------------------------------------------------------
    wire s1_is_squashed = recover_valid_i && (rob_dist(stage1_meta_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            stage2_meta_q <= '0;
            s3_result_q   <= 64'd0;
        end else begin
            if (stage1_meta_q.valid && !s1_is_squashed) begin
                stage2_meta_q <= stage1_meta_q;
                s3_result_q   <= s2_result_q;
            end else begin
                stage2_meta_q.valid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3 Register Update (Stage 2 -> Stage 3 / Output)
    // -------------------------------------------------------------------------
    wire s2_is_squashed = recover_valid_i && (rob_dist(stage2_meta_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            stage3_meta_q <= '0;
            s4_result_q   <= 64'd0;
        end else begin
            if (stage2_meta_q.valid && !s2_is_squashed) begin
                stage3_meta_q <= stage2_meta_q;
                s4_result_q   <= s3_result_q;
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
    assign out_data_o      = s4_result_q;

    // -------------------------------------------------------------------------
    // In-Flight Accounting (for Pre-Issue Credit Gating)
    // -------------------------------------------------------------------------
    // Counts how many valid operations are currently in stages 1..3
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
