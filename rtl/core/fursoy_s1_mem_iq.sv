`ifndef FURSOY_S1_MEM_IQ_SV
`define FURSOY_S1_MEM_IQ_SV

// =============================================================================
// Fursoy Slice-1 Memory Issue Queue (MemIQ) — Milestone 3
// =============================================================================
// 12-entry out-of-order issue queue for memory micro-operations (Loads, Stores,
// AMOs, FENCEs).
// Reference: docs/architecture/slice1-m3-memory-v1.md Section 4
//
// Key Features:
// - 2-wide dispatch allocation atomic with M1 rename permits.
// - Decoupled store data: Store AGU issues with prs1 (base) ready only.
// - Wrap-safe circular ROB age selection via rob_dist.
// - Tag wakeup snoop from Port 0, Port 1, and Port 2 validated writebacks.
// - Instantaneous branch squash and full flush recovery.
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_mem_iq
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    // Dispatch Handshake & Readiness
    output logic [1:0]        mem_ready_o,
    input  logic [1:0]        rename_ack_i,

    // Uop 0 Dispatch
    input  logic              uop0_valid_i,
    input  uop_class_t        uop0_class_i,
    input  uop_subop_t        uop0_subop_i,
    input  mem_size_t         uop0_size_i,
    input  logic              uop0_sign_ext_i,
    input  logic [63:0]       uop0_imm_i,
    input  preg_t             uop0_prs1_i,
    input  logic              uop0_prs1_ready_i,
    input  preg_t             uop0_prs2_i,
    input  logic              uop0_prs2_ready_i,
    input  preg_t             uop0_pnew_i,
    input  rob_idx_t          uop0_rob_idx_i,
    input  rob_epoch_t        uop0_rob_epoch_i,
    input  lq_idx_t           uop0_lq_idx_i,
    input  sq_idx_t           uop0_sq_idx_i,
    input  logic [63:0]       uop0_pc_i,
    input  logic              uop0_replay_safe_i,

    // Uop 1 Dispatch
    input  logic              uop1_valid_i,
    input  uop_class_t        uop1_class_i,
    input  uop_subop_t        uop1_subop_i,
    input  mem_size_t         uop1_size_i,
    input  logic              uop1_sign_ext_i,
    input  logic [63:0]       uop1_imm_i,
    input  preg_t             uop1_prs1_i,
    input  logic              uop1_prs1_ready_i,
    input  preg_t             uop1_prs2_i,
    input  logic              uop1_prs2_ready_i,
    input  preg_t             uop1_pnew_i,
    input  rob_idx_t          uop1_rob_idx_i,
    input  rob_epoch_t        uop1_rob_epoch_i,
    input  lq_idx_t           uop1_lq_idx_i,
    input  sq_idx_t           uop1_sq_idx_i,
    input  logic [63:0]       uop1_pc_i,
    input  logic              uop1_replay_safe_i,

    // Validated Writeback Tag Snoop for Wakeup (WB0, WB1, WB2)
    input  logic              wb0_valid_i,
    input  logic              wb0_comp_ack_i,
    input  preg_t             wb0_pnew_i,

    input  logic              wb1_valid_i,
    input  logic              wb1_comp_ack_i,
    input  preg_t             wb1_pnew_i,

    input  logic              wb2_valid_i,
    input  logic              wb2_comp_ack_i,
    input  logic              wb2_comp_exception_i,
    input  preg_t             wb2_pnew_i,

    // Port 2 AGU Stall / Hold
    input  logic              port2_busy_i,

    // Port 2 Issue Output
    output logic              issue_valid_o,
    output memiq_entry_t      issue_uop_o,

    // Diagnostics
    output logic [11:0]       diag_valid_mask_o,
    output logic [11:0]       diag_ready_mask_o,
    output logic [3:0]        free_count_o
);

    // -------------------------------------------------------------------------
    // Storage Array (12 entries)
    // -------------------------------------------------------------------------
    memiq_entry_t entries_q [MEM_IQ_DEPTH];

    // Count Free Entries
    logic [3:0] free_count;
    always_comb begin
        free_count = 4'd0;
        for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
            if (!entries_q[i].valid) free_count = free_count + 4'd1;
        end
    end

    assign free_count_o = free_count;
    assign mem_ready_o[0] = (free_count >= 4'd1) && !flush_valid_i;
    assign mem_ready_o[1] = (free_count >= 4'd2) && !flush_valid_i;

    // -------------------------------------------------------------------------
    // Allocation Slots Finder
    // -------------------------------------------------------------------------
    logic [3:0] alloc_slot0, alloc_slot1;
    logic       slot0_found, slot1_found;

    always_comb begin
        alloc_slot0 = 4'd0;
        alloc_slot1 = 4'd0;
        slot0_found = 1'b0;
        slot1_found = 1'b0;

        for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
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

    // Allocation Fires
    wire uop0_is_mem = (uop0_class_i == UOP_LOAD) || (uop0_class_i == UOP_STORE) ||
                       (uop0_class_i == UOP_AMO)  || (uop0_class_i == UOP_FENCE);
    wire uop1_is_mem = (uop1_class_i == UOP_LOAD) || (uop1_class_i == UOP_STORE) ||
                       (uop1_class_i == UOP_AMO)  || (uop1_class_i == UOP_FENCE);

    wire [3:0] alloc_slot1_eff = uop0_is_mem ? alloc_slot1 : alloc_slot0;
    wire       slot1_found_eff = uop0_is_mem ? slot1_found : slot0_found;

    wire alloc0_fire = uop0_valid_i && uop0_is_mem && rename_ack_i[0] && !flush_valid_i && slot0_found;
    wire alloc1_fire = uop1_valid_i && uop1_is_mem && rename_ack_i[1] && !flush_valid_i && slot1_found_eff;

    // -------------------------------------------------------------------------
    // Issue Readiness Evaluation (Section 4.3)
    // -------------------------------------------------------------------------
    // Loads require prs1 (base) ready.
    // Stores require prs1 (base) ready (prs2 data decoupled).
    // FENCE / AMO require prs1 ready.
    logic [MEM_IQ_DEPTH-1:0] can_issue;

    always_comb begin
        for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
            if (entries_q[i].valid && !entries_q[i].addr_issued) begin
                can_issue[i] = entries_q[i].prs1_ready;
            end else begin
                can_issue[i] = 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Oldest-Ready Arbiter via wrap-safe rob_dist
    // -------------------------------------------------------------------------
    logic [3:0] sel_slot;
    logic       sel_valid;
    logic [5:0] min_dist;
    logic [5:0] d;

    always_comb begin
        sel_slot  = 4'd0;
        sel_valid = 1'b0;
        min_dist  = 6'd63;
        d         = 6'd0;

        for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
            if (can_issue[i]) begin
                d = rob_dist(entries_q[i].rob_idx, rob_head_i);
                if (!sel_valid || (d < min_dist)) begin
                    min_dist  = d;
                    sel_slot  = 4'(i);
                    sel_valid = 1'b1;
                end
            end
        end
    end

    wire issue_fire = sel_valid && !port2_busy_i && !flush_valid_i;

    assign issue_valid_o = issue_fire;
    assign issue_uop_o   = entries_q[sel_slot];

    // Diagnostics
    always_comb begin
        for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
            diag_valid_mask_o[i] = entries_q[i].valid;
            diag_ready_mask_o[i] = can_issue[i];
        end
    end

    // -------------------------------------------------------------------------
    // Sequential State Update & Tag Wakeup Snooping
    // -------------------------------------------------------------------------
    wire wb0_match = wb0_valid_i && wb0_comp_ack_i && (wb0_pnew_i != 7'd0);
    wire wb1_match = wb1_valid_i && wb1_comp_ack_i && (wb1_pnew_i != 7'd0);
    // Port 2 faulting loads do NOT wake dependent uops (Section 3.2, 17.3)
    wire wb2_match = wb2_valid_i && wb2_comp_ack_i && !wb2_comp_exception_i && (wb2_pnew_i != 7'd0);

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
                entries_q[i] <= '0;
            end
        end else begin
            // 1. Tag Wakeup Snooping on existing entries
            for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
                if (entries_q[i].valid) begin
                    // Base address wakeup
                    if (!entries_q[i].prs1_ready) begin
                        if ((wb0_match && (wb0_pnew_i == entries_q[i].prs1)) ||
                            (wb1_match && (wb1_pnew_i == entries_q[i].prs1)) ||
                            (wb2_match && (wb2_pnew_i == entries_q[i].prs1))) begin
                            entries_q[i].prs1_ready <= 1'b1;
                        end
                    end
                    // Store data wakeup (for informational capture)
                    if (!entries_q[i].prs2_ready) begin
                        if ((wb0_match && (wb0_pnew_i == entries_q[i].prs2)) ||
                            (wb1_match && (wb1_pnew_i == entries_q[i].prs2)) ||
                            (wb2_match && (wb2_pnew_i == entries_q[i].prs2))) begin
                            entries_q[i].prs2_ready <= 1'b1;
                        end
                    end
                end
            end

            // 2. Issue Deallocation / Mark Issued
            if (issue_fire) begin
                // Once issued to Port 2 AGU, entry has launched into LQ/SQ
                entries_q[sel_slot].valid <= 1'b0;
            end

            // 3. Branch Recovery Squash
            if (recover_valid_i) begin
                for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
                    if (entries_q[i].valid) begin
                        if (rob_dist(entries_q[i].rob_idx, rob_head_i) >
                            rob_dist(recover_rob_idx_i, rob_head_i)) begin
                            entries_q[i].valid <= 1'b0;
                        end
                    end
                end
            end

            // 4. New Allocations (Allocation overrides squash on freshly allocated slot)
            if (alloc0_fire) begin
                entries_q[alloc_slot0].valid        <= 1'b1;
                entries_q[alloc_slot0].uop_class    <= uop0_class_i;
                entries_q[alloc_slot0].sub_op       <= uop0_subop_i;
                entries_q[alloc_slot0].size         <= uop0_size_i;
                entries_q[alloc_slot0].sign_ext     <= uop0_sign_ext_i;
                entries_q[alloc_slot0].imm          <= uop0_imm_i;
                entries_q[alloc_slot0].prs1         <= uop0_prs1_i;
                // Check if already ready or waking up in same cycle
                entries_q[alloc_slot0].prs1_ready   <= uop0_prs1_ready_i ||
                    (wb0_match && (wb0_pnew_i == uop0_prs1_i)) ||
                    (wb1_match && (wb1_pnew_i == uop0_prs1_i)) ||
                    (wb2_match && (wb2_pnew_i == uop0_prs1_i));
                entries_q[alloc_slot0].prs2         <= uop0_prs2_i;
                entries_q[alloc_slot0].prs2_ready   <= uop0_prs2_ready_i ||
                    (wb0_match && (wb0_pnew_i == uop0_prs2_i)) ||
                    (wb1_match && (wb1_pnew_i == uop0_prs2_i)) ||
                    (wb2_match && (wb2_pnew_i == uop0_prs2_i));
                entries_q[alloc_slot0].pnew         <= uop0_pnew_i;
                entries_q[alloc_slot0].rob_idx      <= uop0_rob_idx_i;
                entries_q[alloc_slot0].rob_epoch    <= uop0_rob_epoch_i;
                entries_q[alloc_slot0].lq_idx       <= uop0_lq_idx_i;
                entries_q[alloc_slot0].sq_idx       <= uop0_sq_idx_i;
                entries_q[alloc_slot0].pc           <= uop0_pc_i;
                entries_q[alloc_slot0].addr_issued  <= 1'b0;
                entries_q[alloc_slot0].replay_safe  <= uop0_replay_safe_i;
            end

            if (alloc1_fire) begin
                entries_q[alloc_slot1_eff].valid        <= 1'b1;
                entries_q[alloc_slot1_eff].uop_class    <= uop1_class_i;
                entries_q[alloc_slot1_eff].sub_op       <= uop1_subop_i;
                entries_q[alloc_slot1_eff].size         <= uop1_size_i;
                entries_q[alloc_slot1_eff].sign_ext     <= uop1_sign_ext_i;
                entries_q[alloc_slot1_eff].imm          <= uop1_imm_i;
                entries_q[alloc_slot1_eff].prs1         <= uop1_prs1_i;
                entries_q[alloc_slot1_eff].prs1_ready   <= uop1_prs1_ready_i ||
                    (wb0_match && (wb0_pnew_i == uop1_prs1_i)) ||
                    (wb1_match && (wb1_pnew_i == uop1_prs1_i)) ||
                    (wb2_match && (wb2_pnew_i == uop1_prs1_i));
                entries_q[alloc_slot1_eff].prs2         <= uop1_prs2_i;
                entries_q[alloc_slot1_eff].prs2_ready   <= uop1_prs2_ready_i ||
                    (wb0_match && (wb0_pnew_i == uop1_prs2_i)) ||
                    (wb1_match && (wb1_pnew_i == uop1_prs2_i)) ||
                    (wb2_match && (wb2_pnew_i == uop1_prs2_i));
                entries_q[alloc_slot1_eff].pnew         <= uop1_pnew_i;
                entries_q[alloc_slot1_eff].rob_idx      <= uop1_rob_idx_i;
                entries_q[alloc_slot1_eff].rob_epoch    <= uop1_rob_epoch_i;
                entries_q[alloc_slot1_eff].lq_idx       <= uop1_lq_idx_i;
                entries_q[alloc_slot1_eff].sq_idx       <= uop1_sq_idx_i;
                entries_q[alloc_slot1_eff].pc           <= uop1_pc_i;
                entries_q[alloc_slot1_eff].addr_issued  <= 1'b0;
                entries_q[alloc_slot1_eff].replay_safe  <= uop1_replay_safe_i;
            end
        end
    end

endmodule

`endif // FURSOY_S1_MEM_IQ_SV
