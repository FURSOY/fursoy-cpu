`ifndef FURSOY_S1_BRANCH_UNIT_SV
`define FURSOY_S1_BRANCH_UNIT_SV

// =============================================================================
// Fursoy Slice-1 Branch Resolution Unit — Milestone 2
// =============================================================================
// Evaluates conditional branches (BEQ, BNE, BLT, BGE, BLTU, BGEU), JAL, JALR.
// Computes actual direction and target, compares against prediction metadata,
// and produces return link address PC+4 for JAL/JALR.
// Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.4.2
// =============================================================================

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

    logic cond_met;
    always_comb begin
        case (sub_op_i)
            BR_EQ:  cond_met = (op_a_i == op_b_i);
            BR_NE:  cond_met = (op_a_i != op_b_i);
            BR_LT:  cond_met = ($signed(op_a_i) < $signed(op_b_i));
            BR_GE:  cond_met = ($signed(op_a_i) >= $signed(op_b_i));
            BR_LTU: cond_met = (op_a_i < op_b_i);
            BR_GEU: cond_met = (op_a_i >= op_b_i);
            default: cond_met = 1'b0;
        endcase
    end

    always_comb begin
        actual_taken_o  = 1'b0;
        actual_target_o = pc_i + 64'd4;
        result_o        = pc_i + 64'd4;
        mispredict_o    = 1'b0;

        if (uop_class_i == UOP_BRANCH) begin
            actual_taken_o  = cond_met;
            actual_target_o = cond_met ? (pc_i + imm_i) : (pc_i + 64'd4);
            mispredict_o    = (actual_taken_o != pred_taken_i) ||
                              (actual_taken_o && (actual_target_o != pred_target_i));
            result_o        = 64'd0;
        end else if (uop_class_i == UOP_JAL) begin
            actual_taken_o  = 1'b1;
            actual_target_o = pc_i + imm_i;
            mispredict_o    = (actual_target_o != pred_target_i) || (!pred_taken_i);
            result_o        = pc_i + 64'd4;
        end else if (uop_class_i == UOP_JALR) begin
            actual_taken_o  = 1'b1;
            actual_target_o = (op_a_i + imm_i) & ~64'd1;
            mispredict_o    = (actual_target_o != pred_target_i) || (!pred_taken_i);
            result_o        = pc_i + 64'd4;
        end
    end

endmodule

`endif // FURSOY_S1_BRANCH_UNIT_SV
