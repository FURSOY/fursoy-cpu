`ifndef FURSOY_S1_FP_IQ_SV
`define FURSOY_S1_FP_IQ_SV

// =============================================================================
// Fursoy Slice-1 16-Entry Floating-Point Issue Queue (FPIQ16) — Milestone 8 Phase B
// =============================================================================
// Dedicated issue queue for Port 4 scalar floating-point execution pipeline.
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 6.1, Section 11
//
// Invariants:
// - 16-entry dedicated queue (FPIQ16).
// - Up to 2 allocations/cycle from Rename/Dispatch stage.
// - Evaluates source operand readiness across up to 3 FPRF registers (prs1, prs2, prs3).
// - Arbitrates 1 ready FP uop/cycle enforcing oldest-ready circular ROB age priority.
// - Non-blocking: FDIV/FSQRT uops require !fdiv_busy_i to issue; independent FMA,
//   moves, conversions and comparisons issue freely while divider is busy.
// - Lossless deallocation on issue, instant flush, and branch recovery squashes.
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_fp_iq
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Flush & Recovery
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    // Dispatch Interface (from Rename)
    output logic [1:0]        dispatch_ready_o,
    input  logic [1:0]        rename_ack_i,

    // Uop 0 Dispatch Payload
    input  logic              uop0_valid_i,
    input  logic              uop0_is_fp_i,
    input  uop_class_t        uop0_class_i,
    input  uop_subop_t        uop0_subop_i,
    input  logic [2:0]        uop0_frm_i,
    input  fpreg_t            uop0_prs1_fp_i,
    input  logic              uop0_prs1_fp_ready_i,
    input  fpreg_t            uop0_prs2_fp_i,
    input  logic              uop0_prs2_fp_ready_i,
    input  fpreg_t            uop0_prs3_fp_i,
    input  logic              uop0_prs3_fp_ready_i,
    input  fpreg_t            uop0_prd_fp_i,
    input  logic              uop0_fp_dest_valid_i,
    input  preg_t             uop0_pnew_i,
    input  rob_idx_t          uop0_rob_idx_i,
    input  rob_epoch_t        uop0_rob_epoch_i,
    input  logic [63:0]       uop0_pc_i,

    // Uop 1 Dispatch Payload
    input  logic              uop1_valid_i,
    input  logic              uop1_is_fp_i,
    input  uop_class_t        uop1_class_i,
    input  uop_subop_t        uop1_subop_i,
    input  logic [2:0]        uop1_frm_i,
    input  fpreg_t            uop1_prs1_fp_i,
    input  logic              uop1_prs1_fp_ready_i,
    input  fpreg_t            uop1_prs2_fp_i,
    input  logic              uop1_prs2_fp_ready_i,
    input  fpreg_t            uop1_prs3_fp_i,
    input  logic              uop1_prs3_fp_ready_i,
    input  fpreg_t            uop1_prd_fp_i,
    input  logic              uop1_fp_dest_valid_i,
    input  preg_t             uop1_pnew_i,
    input  rob_idx_t          uop1_rob_idx_i,
    input  rob_epoch_t        uop1_rob_epoch_i,
    input  logic [63:0]       uop1_pc_i,

    // Writeback Tag Wakeup Snoop (from FPRF writeback ports)
    input  logic              wb0_fp_valid_i,
    input  fpreg_t            wb0_fp_paddr_i,
    input  logic              wb1_fp_valid_i,
    input  fpreg_t            wb1_fp_paddr_i,
    input  logic              wb2_fp_valid_i,
    input  fpreg_t            wb2_fp_paddr_i,

    // Divider & Conversion Buffer Busy Status
    input  logic              fdiv_busy_i,
    input  logic              fconv_fprf_busy_i,
    input  logic              fconv_prf_busy_i,

    // Port 4 Issue Output
    output logic              issue_valid_o,
    output fpiq_entry_t       issue_uop_o
);

    // -------------------------------------------------------------------------
    // Helper Functions: Operands Usage & Classification
    // -------------------------------------------------------------------------
    function automatic logic is_fpiq_target(input uop_subop_t op);
        case (op)
            // Int-to-Float uops allocate to IntIQ
            FP_FMV_W_X, FP_FMV_D_X,
            FP_FCVT_S_W, FP_FCVT_D_W,
            FP_FCVT_S_WU, FP_FCVT_D_WU,
            FP_FCVT_S_L, FP_FCVT_D_L,
            FP_FCVT_S_LU, FP_FCVT_D_LU: return 1'b0;
            default: return 1'b1;
        endcase
    endfunction

    function automatic logic is_fdiv_subop(input uop_subop_t op);
        case (op)
            FP_FDIV_S, FP_FDIV_D, FP_FSQRT_S, FP_FSQRT_D: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    function automatic logic is_fconv_to_fprf_subop(input uop_subop_t op);
        case (op)
            FP_FCVT_S_D, FP_FCVT_D_S,
            FP_FSGNJ_S, FP_FSGNJN_S, FP_FSGNJX_S,
            FP_FSGNJ_D, FP_FSGNJN_D, FP_FSGNJX_D,
            FP_FMIN_S, FP_FMAX_S,
            FP_FMIN_D, FP_FMAX_D: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    function automatic logic is_f2i_subop(input uop_subop_t op);
        case (op)
            FP_FMV_X_W, FP_FMV_X_D,
            FP_FCVT_W_S, FP_FCVT_WU_S, FP_FCVT_L_S, FP_FCVT_LU_S,
            FP_FCVT_W_D, FP_FCVT_WU_D, FP_FCVT_L_D, FP_FCVT_LU_D,
            FP_FEQ_S, FP_FLT_S, FP_FLE_S,
            FP_FEQ_D, FP_FLT_D, FP_FLE_D,
            FP_FCLASS_S, FP_FCLASS_D: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    function automatic logic uses_rs2_fp(input uop_subop_t op);
        case (op)
            FP_FSQRT_S, FP_FSQRT_D,
            FP_FCVT_S_D, FP_FCVT_D_S,
            FP_FMV_X_W, FP_FMV_X_D,
            FP_FCVT_W_S, FP_FCVT_W_D,
            FP_FCVT_WU_S, FP_FCVT_WU_D,
            FP_FCVT_L_S, FP_FCVT_L_D,
            FP_FCVT_LU_S, FP_FCVT_LU_D,
            FP_FCLASS_S, FP_FCLASS_D: return 1'b0;
            default: return 1'b1;
        endcase
    endfunction

    function automatic logic uses_rs3_fp(input uop_subop_t op);
        case (op)
            FP_FMADD_S, FP_FMADD_D,
            FP_FMSUB_S, FP_FMSUB_D,
            FP_FNMSUB_S, FP_FNMSUB_D,
            FP_FNMADD_S, FP_FNMADD_D: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Storage Array (16 entries)
    // -------------------------------------------------------------------------
    fpiq_entry_t entries_q [FPIQ_DEPTH];

    // Capacity & Allocation Detection
    logic [4:0] free_count;
    always_comb begin
        free_count = 5'd0;
        for (int i = 0; i < FPIQ_DEPTH; i++) begin
            if (!entries_q[i].valid) free_count = free_count + 5'd1;
        end
    end

    assign dispatch_ready_o[0] = (free_count >= 5'd1) && !flush_valid_i;
    assign dispatch_ready_o[1] = (free_count >= 5'd2) && !flush_valid_i;

    // Find free allocation slots
    logic [3:0] alloc_slot0, alloc_slot1;
    logic       slot0_found, slot1_found;

    always_comb begin
        alloc_slot0 = 4'd0;
        alloc_slot1 = 4'd0;
        slot0_found = 1'b0;
        slot1_found = 1'b0;

        for (int i = 0; i < FPIQ_DEPTH; i++) begin
            if (!entries_q[i].valid) begin
                if (!slot0_found) begin
                    alloc_slot0 = 4'(i);
                    slot0_found = 1'b1;
                end else if (!slot1_found) begin
                    alloc_slot1 = 4'(i);
                    slot1_found = 1'b1;
                end
            end
        end
    end

    wire uop0_is_mem = (uop0_class_i == UOP_LOAD) || (uop0_class_i == UOP_STORE) ||
                       (uop0_class_i == UOP_AMO)  || (uop0_class_i == UOP_FENCE);
    wire uop1_is_mem = (uop1_class_i == UOP_LOAD) || (uop1_class_i == UOP_STORE) ||
                       (uop1_class_i == UOP_AMO)  || (uop1_class_i == UOP_FENCE);

    wire uop0_alloc_req = uop0_valid_i && !uop0_is_mem && (uop0_class_i == UOP_FP) && uop0_is_fp_i && is_fpiq_target(uop0_subop_i);
    wire uop1_alloc_req = uop1_valid_i && !uop1_is_mem && (uop1_class_i == UOP_FP) && uop1_is_fp_i && is_fpiq_target(uop1_subop_i);

    wire [3:0] alloc_slot1_eff = uop0_alloc_req ? alloc_slot1 : alloc_slot0;
    wire       slot1_found_eff = uop0_alloc_req ? slot1_found : slot0_found;

    wire alloc0_fire = uop0_alloc_req && rename_ack_i[0] && !flush_valid_i && slot0_found;
    wire alloc1_fire = uop1_alloc_req && rename_ack_i[1] && !flush_valid_i && slot1_found_eff;

    // -------------------------------------------------------------------------
    // Wakeup & Readiness Evaluation
    // -------------------------------------------------------------------------
    logic [FPIQ_DEPTH-1:0] ready_mask;

    always_comb begin
        for (int i = 0; i < FPIQ_DEPTH; i++) begin
            logic r1, r2, r3;
            logic div_ok;
            logic fconv_ok;

            r1 = !entries_q[i].use_rs1_fp || entries_q[i].prs1_fp_ready;
            r2 = !entries_q[i].use_rs2_fp || entries_q[i].prs2_fp_ready;
            r3 = !entries_q[i].use_rs3_fp || entries_q[i].prs3_fp_ready;

            div_ok = !is_fdiv_subop(entries_q[i].sub_op) || !fdiv_busy_i;
            fconv_ok = (!is_fconv_to_fprf_subop(entries_q[i].sub_op) || !fconv_fprf_busy_i) &&
                       (!is_f2i_subop(entries_q[i].sub_op)           || !fconv_prf_busy_i);

            ready_mask[i] = entries_q[i].valid && r1 && r2 && r3 && div_ok && fconv_ok;
        end
    end

    // -------------------------------------------------------------------------
    // Oldest-Ready Arbiter via Wrap-Safe `rob_dist`
    // -------------------------------------------------------------------------
    logic [3:0] sel_idx;
    logic       sel_valid;

    always_comb begin
        rob_dist_t best_dist;
        rob_dist_t d;
        sel_idx   = 4'd0;
        sel_valid = 1'b0;
        best_dist = rob_dist_t'(ROB_DEPTH - 1);
        d         = '0;

        for (int i = 0; i < FPIQ_DEPTH; i++) begin
            if (ready_mask[i]) begin
                d = rob_dist(entries_q[i].rob_idx, rob_head_i);
                if (!sel_valid || (d < best_dist)) begin
                    best_dist = d;
                    sel_idx   = 4'(i);
                    sel_valid = 1'b1;
                end
            end
        end
    end

    assign issue_valid_o = sel_valid;
    assign issue_uop_o   = entries_q[sel_idx];

    // -------------------------------------------------------------------------
    // Sequential State Update & Recovery
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            for (int i = 0; i < FPIQ_DEPTH; i++) begin
                entries_q[i] <= '0;
            end
        end else begin
            // 1. Deallocate issued entry
            if (sel_valid) begin
                entries_q[sel_idx].valid <= 1'b0;
            end

            // 2. Branch misprediction recovery squash
            if (recover_valid_i) begin
                for (int i = 0; i < FPIQ_DEPTH; i++) begin
                    if (entries_q[i].valid &&
                        (rob_dist(entries_q[i].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        entries_q[i].valid <= 1'b0;
                    end
                end
            end

            // 3. Writeback snoop wakeup across all entries
            for (int i = 0; i < FPIQ_DEPTH; i++) begin
                if (entries_q[i].valid) begin
                    if (wb0_fp_valid_i && (entries_q[i].prs1_fp == wb0_fp_paddr_i)) entries_q[i].prs1_fp_ready <= 1'b1;
                    if (wb1_fp_valid_i && (entries_q[i].prs1_fp == wb1_fp_paddr_i)) entries_q[i].prs1_fp_ready <= 1'b1;
                    if (wb2_fp_valid_i && (entries_q[i].prs1_fp == wb2_fp_paddr_i)) entries_q[i].prs1_fp_ready <= 1'b1;

                    if (wb0_fp_valid_i && (entries_q[i].prs2_fp == wb0_fp_paddr_i)) entries_q[i].prs2_fp_ready <= 1'b1;
                    if (wb1_fp_valid_i && (entries_q[i].prs2_fp == wb1_fp_paddr_i)) entries_q[i].prs2_fp_ready <= 1'b1;
                    if (wb2_fp_valid_i && (entries_q[i].prs2_fp == wb2_fp_paddr_i)) entries_q[i].prs2_fp_ready <= 1'b1;

                    if (wb0_fp_valid_i && (entries_q[i].prs3_fp == wb0_fp_paddr_i)) entries_q[i].prs3_fp_ready <= 1'b1;
                    if (wb1_fp_valid_i && (entries_q[i].prs3_fp == wb1_fp_paddr_i)) entries_q[i].prs3_fp_ready <= 1'b1;
                    if (wb2_fp_valid_i && (entries_q[i].prs3_fp == wb2_fp_paddr_i)) entries_q[i].prs3_fp_ready <= 1'b1;
                end
            end

            // 4. Allocate Uop 0
            if (alloc0_fire) begin
                entries_q[alloc_slot0].valid          <= 1'b1;
                entries_q[alloc_slot0].uop_class      <= uop0_class_i;
                entries_q[alloc_slot0].sub_op         <= uop0_subop_i;
                entries_q[alloc_slot0].frm            <= uop0_frm_i;
                entries_q[alloc_slot0].prs1_fp        <= uop0_prs1_fp_i;
                entries_q[alloc_slot0].prs1_fp_ready  <= uop0_prs1_fp_ready_i ||
                                                          (wb0_fp_valid_i && (uop0_prs1_fp_i == wb0_fp_paddr_i)) ||
                                                          (wb1_fp_valid_i && (uop0_prs1_fp_i == wb1_fp_paddr_i)) ||
                                                          (wb2_fp_valid_i && (uop0_prs1_fp_i == wb2_fp_paddr_i));
                entries_q[alloc_slot0].use_rs1_fp     <= 1'b1;
                entries_q[alloc_slot0].prs2_fp        <= uop0_prs2_fp_i;
                entries_q[alloc_slot0].prs2_fp_ready  <= uop0_prs2_fp_ready_i ||
                                                          (wb0_fp_valid_i && (uop0_prs2_fp_i == wb0_fp_paddr_i)) ||
                                                          (wb1_fp_valid_i && (uop0_prs2_fp_i == wb1_fp_paddr_i)) ||
                                                          (wb2_fp_valid_i && (uop0_prs2_fp_i == wb2_fp_paddr_i));
                entries_q[alloc_slot0].use_rs2_fp     <= uses_rs2_fp(uop0_subop_i);
                entries_q[alloc_slot0].prs3_fp        <= uop0_prs3_fp_i;
                entries_q[alloc_slot0].prs3_fp_ready  <= uop0_prs3_fp_ready_i ||
                                                          (wb0_fp_valid_i && (uop0_prs3_fp_i == wb0_fp_paddr_i)) ||
                                                          (wb1_fp_valid_i && (uop0_prs3_fp_i == wb1_fp_paddr_i)) ||
                                                          (wb2_fp_valid_i && (uop0_prs3_fp_i == wb2_fp_paddr_i));
                entries_q[alloc_slot0].use_rs3_fp     <= uses_rs3_fp(uop0_subop_i);
                entries_q[alloc_slot0].prd_fp         <= uop0_prd_fp_i;
                entries_q[alloc_slot0].fp_dest_valid  <= uop0_fp_dest_valid_i;
                entries_q[alloc_slot0].pnew           <= uop0_pnew_i;
                entries_q[alloc_slot0].int_dest_valid <= !uop0_fp_dest_valid_i;
                entries_q[alloc_slot0].rd             <= '0;
                entries_q[alloc_slot0].rob_idx        <= uop0_rob_idx_i;
                entries_q[alloc_slot0].rob_epoch      <= uop0_rob_epoch_i;
                entries_q[alloc_slot0].pc             <= uop0_pc_i;
            end

            // 5. Allocate Uop 1
            if (alloc1_fire) begin
                entries_q[alloc_slot1_eff].valid          <= 1'b1;
                entries_q[alloc_slot1_eff].uop_class      <= uop1_class_i;
                entries_q[alloc_slot1_eff].sub_op         <= uop1_subop_i;
                entries_q[alloc_slot1_eff].frm            <= uop1_frm_i;
                entries_q[alloc_slot1_eff].prs1_fp        <= uop1_prs1_fp_i;
                entries_q[alloc_slot1_eff].prs1_fp_ready  <= uop1_prs1_fp_ready_i ||
                                                          (wb0_fp_valid_i && (uop1_prs1_fp_i == wb0_fp_paddr_i)) ||
                                                          (wb1_fp_valid_i && (uop1_prs1_fp_i == wb1_fp_paddr_i)) ||
                                                          (wb2_fp_valid_i && (uop1_prs1_fp_i == wb2_fp_paddr_i));
                entries_q[alloc_slot1_eff].use_rs1_fp     <= 1'b1;
                entries_q[alloc_slot1_eff].prs2_fp        <= uop1_prs2_fp_i;
                entries_q[alloc_slot1_eff].prs2_fp_ready  <= uop1_prs2_fp_ready_i ||
                                                          (wb0_fp_valid_i && (uop1_prs2_fp_i == wb0_fp_paddr_i)) ||
                                                          (wb1_fp_valid_i && (uop1_prs2_fp_i == wb1_fp_paddr_i)) ||
                                                          (wb2_fp_valid_i && (uop1_prs2_fp_i == wb2_fp_paddr_i));
                entries_q[alloc_slot1_eff].use_rs2_fp     <= uses_rs2_fp(uop1_subop_i);
                entries_q[alloc_slot1_eff].prs3_fp        <= uop1_prs3_fp_i;
                entries_q[alloc_slot1_eff].prs3_fp_ready  <= uop1_prs3_fp_ready_i ||
                                                          (wb0_fp_valid_i && (uop1_prs3_fp_i == wb0_fp_paddr_i)) ||
                                                          (wb1_fp_valid_i && (uop1_prs3_fp_i == wb1_fp_paddr_i)) ||
                                                          (wb2_fp_valid_i && (uop1_prs3_fp_i == wb2_fp_paddr_i));
                entries_q[alloc_slot1_eff].use_rs3_fp     <= uses_rs3_fp(uop1_subop_i);
                entries_q[alloc_slot1_eff].prd_fp         <= uop1_prd_fp_i;
                entries_q[alloc_slot1_eff].fp_dest_valid  <= uop1_fp_dest_valid_i;
                entries_q[alloc_slot1_eff].pnew           <= uop1_pnew_i;
                entries_q[alloc_slot1_eff].int_dest_valid <= !uop1_fp_dest_valid_i;
                entries_q[alloc_slot1_eff].rd             <= '0;
                entries_q[alloc_slot1_eff].rob_idx        <= uop1_rob_idx_i;
                entries_q[alloc_slot1_eff].rob_epoch      <= uop1_rob_epoch_i;
                entries_q[alloc_slot1_eff].pc             <= uop1_pc_i;
            end
        end
    end

endmodule

`endif // FURSOY_S1_FP_IQ_SV
