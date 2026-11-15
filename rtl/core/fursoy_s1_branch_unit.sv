`ifndef FURSOY_S1_BRANCH_UNIT_SV
`define FURSOY_S1_BRANCH_UNIT_SV

// =============================================================================
// Fursoy Slice-1 Branch Resolution Unit — Milestone 2
// =============================================================================
// Evaluates conditional branches (BEQ, BNE, BLT, BGE, BLTU, BGEU), JAL, JALR.
// Computes actual direction and target, compares against prediction metadata,
// and produces return link address PC+4 for JAL/JALR.
// Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.4.2
//
// Timing structure (PPA Stage 1):
// - Candidate targets (PC+imm, PC+4, (rs1+imm)&~1) are computed in parallel
//   with branch condition resolution using logarithmic-depth Kogge-Stone
//   parallel-prefix adders (with preserved intermediate prefix cut points so
//   AIG functional reduction cannot collapse the prefix tree back into a
//   64-stage ripple chain).
// - Predicted-target equality is evaluated concurrently via a carry-free
//   sum-equality test (A+B==K) that does not wait on the target adders.
// - Magnitude comparison (BLT/BGE/BLTU/BGEU) uses a 6-stage parallel-prefix
//   comparator tree shared between signed and unsigned branches.
// - cond_met drives only the final 2:1 selection of actual_target_o,
//   actual_taken_o, and mispredict_o.
// =============================================================================

`include "fursoy_s1_ks_adder.sv"

module fursoy_s1_branch_unit
    import fursoy_s1_pkg::*;
(
    input  uop_class_t   uop_class_i,
    input  uop_subop_t   sub_op_i,
    input  logic [63:0]  pc_i,
    input  logic [63:0]  imm_i,
    input  logic [63:0]  op_a_i,         // rs1
    input  logic [63:0]  op_b_i,         // rs2
    input  logic         pred_taken_i,
    input  logic [63:0]  pred_target_i,

    output logic [63:0]  result_o,       // Link address PC+4 for JAL/JALR
    output logic         actual_taken_o,
    output logic [63:0]  actual_target_o,
    output logic         mispredict_o
);

    // -------------------------------------------------------------------------
    // Carry-free sum-equality test: returns (a + b) == k (mod 2^64).
    // -------------------------------------------------------------------------
    function automatic logic sum_equals(input logic [63:0] a,
                                        input logic [63:0] b,
                                        input logic [63:0] k);
        logic [63:0] z;
        logic [63:0] c;
        z = a ^ b ^ k;
        c = {(a[62:0] & b[62:0]) | ((a[62:0] ^ b[62:0]) & ~k[62:0]), 1'b0};
        return (z == c);
    endfunction

    // -------------------------------------------------------------------------
    // Parallel 64-bit Kogge-Stone Target Adders (3 adders: PC+imm, PC+4, rs1+imm)
    // Intermediate prefix levels use (* keep *) to prevent AIG FRAIG/dc2 from
    // re-serializing the logarithmic prefix tree into a 64-stage ripple chain.
    // -------------------------------------------------------------------------
    logic [63:0] add_a [3];
    logic [63:0] add_b [3];
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] add_s [3];
    /* verilator lint_on UNUSEDSIGNAL */

    assign add_a[0] = pc_i;   assign add_b[0] = imm_i;
    assign add_a[1] = pc_i;   assign add_b[1] = 64'd4;
    assign add_a[2] = op_a_i; assign add_b[2] = imm_i;

    genvar g_idx;
    generate
        for (g_idx = 0; g_idx < 3; g_idx++) begin : gen_ks_add
            fursoy_s1_ks_adder #(
                .WIDTH (64)
            ) u_ks_adder (
                .a_i   (add_a[g_idx]),
                .b_i   (add_b[g_idx]),
                .cin_i (1'b0),
                .sum_o (add_s[g_idx])
            );
        end
    endgenerate

    wire [63:0] pc_plus_imm = add_s[0];
    wire [63:0] pc_plus_4   = add_s[1];
    wire [63:0] jalr_target = {add_s[2][63:1], 1'b0};

    // Predicted-target match per candidate (independent of the adders above).
    wire imm_target_match  = sum_equals(pc_i, imm_i, pred_target_i);
    wire jalr_target_match = sum_equals(op_a_i, imm_i,
                                        {pred_target_i[63:1], op_a_i[0] ^ imm_i[0]}) &&
                             !pred_target_i[0];

    // -------------------------------------------------------------------------
    // Condition resolution (6-stage parallel-prefix comparator)
    // -------------------------------------------------------------------------
    wire [63:0] cmp_p0 = ~(op_a_i ^ op_b_i);
    wire [63:0] cmp_g0 = (~op_a_i) & op_b_i;
    logic [31:0] cmp_p1, cmp_g1;
    (* keep = "true" *) logic [15:0] cmp_p2, cmp_g2;
    logic [7:0]  cmp_p3, cmp_g3;
    (* keep = "true" *) logic [3:0]  cmp_p4, cmp_g4;
    logic [1:0]  cmp_p5, cmp_g5;
    logic         ops_equal, ult;

    always_comb begin
        for (int i = 0; i < 32; i++) begin
            cmp_p1[i] = cmp_p0[2*i+1] & cmp_p0[2*i];
            cmp_g1[i] = cmp_g0[2*i+1] | (cmp_p0[2*i+1] & cmp_g0[2*i]);
        end
        for (int i = 0; i < 16; i++) begin
            cmp_p2[i] = cmp_p1[2*i+1] & cmp_p1[2*i];
            cmp_g2[i] = cmp_g1[2*i+1] | (cmp_p1[2*i+1] & cmp_g1[2*i]);
        end
        for (int i = 0; i < 8; i++) begin
            cmp_p3[i] = cmp_p2[2*i+1] & cmp_p2[2*i];
            cmp_g3[i] = cmp_g2[2*i+1] | (cmp_p2[2*i+1] & cmp_g2[2*i]);
        end
        for (int i = 0; i < 4; i++) begin
            cmp_p4[i] = cmp_p3[2*i+1] & cmp_p3[2*i];
            cmp_g4[i] = cmp_g3[2*i+1] | (cmp_p3[2*i+1] & cmp_g3[2*i]);
        end
        for (int i = 0; i < 2; i++) begin
            cmp_p5[i] = cmp_p4[2*i+1] & cmp_p4[2*i];
            cmp_g5[i] = cmp_g4[2*i+1] | (cmp_p4[2*i+1] & cmp_g4[2*i]);
        end
        ops_equal = cmp_p5[1] & cmp_p5[0];
        ult       = cmp_g5[1] | (cmp_p5[1] & cmp_g5[0]);
    end

    wire slt = (op_a_i[63] ^ op_b_i[63]) ? op_a_i[63] : ult;

    logic cond_met;
    always_comb begin
        case (sub_op_i)
            BR_EQ:  cond_met = ops_equal;
            BR_NE:  cond_met = !ops_equal;
            BR_LT:  cond_met = slt;
            BR_GE:  cond_met = !slt;
            BR_LTU: cond_met = ult;
            BR_GEU: cond_met = !ult;
            default: cond_met = 1'b0;
        endcase
    end

    // -------------------------------------------------------------------------
    // Final selection (cond_met is the late-arriving select)
    // -------------------------------------------------------------------------
    wire br_mispredict_if_taken     = !pred_taken_i || !imm_target_match;
    wire br_mispredict_if_not_taken = pred_taken_i;

    always_comb begin
        actual_taken_o  = 1'b0;
        actual_target_o = pc_plus_4;
        result_o        = pc_plus_4;
        mispredict_o    = 1'b0;

        if (uop_class_i == UOP_BRANCH) begin
            actual_taken_o  = cond_met;
            actual_target_o = cond_met ? pc_plus_imm : pc_plus_4;
            mispredict_o    = cond_met ? br_mispredict_if_taken : br_mispredict_if_not_taken;
            result_o        = 64'd0;
        end else if (uop_class_i == UOP_JAL) begin
            actual_taken_o  = 1'b1;
            actual_target_o = pc_plus_imm;
            mispredict_o    = !imm_target_match || !pred_taken_i;
            result_o        = pc_plus_4;
        end else if (uop_class_i == UOP_JALR) begin
            actual_taken_o  = 1'b1;
            actual_target_o = jalr_target;
            mispredict_o    = !jalr_target_match || !pred_taken_i;
            result_o        = pc_plus_4;
        end
    end

endmodule

`endif // FURSOY_S1_BRANCH_UNIT_SV
