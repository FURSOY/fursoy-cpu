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

    // Validated Writeback Tag Snoop for Wakeup (WB0, WB1, WB2, WB3)
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

    input  logic              wb3_valid_i,
    input  logic              wb3_comp_ack_i,
    input  logic              wb3_comp_exception_i,
    input  preg_t             wb3_pnew_i,

    // Port 2 & Port 3 AGU Stall / Hold
    input  logic              port2_busy_i,
    input  logic              port3_busy_i,

    // Port 2 Issue Output (AGU0: Loads, Stores, AMOs, Fences)
    output logic              issue0_valid_o,
    output memiq_entry_t      issue0_uop_o,

    // Port 3 Issue Output (AGU1: Loads strictly)
    output logic              issue1_valid_o,
    output memiq_entry_t      issue1_uop_o,

    // Diagnostics
    output logic [MEM_IQ_DEPTH-1:0] diag_valid_mask_o,
    output logic [MEM_IQ_DEPTH-1:0] diag_ready_mask_o,
    output logic [MEM_IQ_IDX_W:0]   free_count_o,
    output logic [MEM_IQ_IDX_W:0]   count_o
);

    localparam int unsigned MEM_IQ_CNT_W = MEM_IQ_IDX_W + 1;
    typedef logic [MEM_IQ_IDX_W-1:0] memiq_slot_t;

    // -------------------------------------------------------------------------
    // Storage Array (MEM_IQ_DEPTH entries)
    // -------------------------------------------------------------------------
    memiq_entry_t entries_q [MEM_IQ_DEPTH];

    // -------------------------------------------------------------------------
    // Issue Readiness Evaluation (Section 4.3 & 7.3)
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
    // Oldest-Ready Arbiter via wrap-safe rob_dist & Dual-Issue Selection Matrix
    // Reference: docs/architecture/slice1-m7-multibank-l1d-v1.md Section 5.2
    // -------------------------------------------------------------------------
    memiq_slot_t cand0_slot, cand1_slot;
    logic        cand0_valid, cand1_valid;
    rob_dist_t   cand0_dist, cand1_dist;
    rob_dist_t   d;

    always_comb begin
        cand0_slot  = '0;
        cand0_valid = 1'b0;
        cand0_dist  = rob_dist_t'(ROB_DEPTH - 1);

        cand1_slot  = '0;
        cand1_valid = 1'b0;
        cand1_dist  = rob_dist_t'(ROB_DEPTH - 1);
        d           = '0;

        // Step 1: Scan for oldest ready entry (cand0)
        for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
            if (can_issue[i]) begin
                d = rob_dist(entries_q[i].rob_idx, rob_head_i);
                if (!cand0_valid || (d < cand0_dist)) begin
                    cand0_dist  = d;
                    cand0_slot  = memiq_slot_t'(i);
                    cand0_valid = 1'b1;
                end
            end
        end

        // Step 2: Scan for second-oldest ready entry (cand1)
        if (cand0_valid) begin
            for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
                if ((memiq_slot_t'(i) != cand0_slot) && can_issue[i]) begin
                    d = rob_dist(entries_q[i].rob_idx, rob_head_i);
                    if (!cand1_valid || (d < cand1_dist)) begin
                        cand1_dist  = d;
                        cand1_slot  = memiq_slot_t'(i);
                        cand1_valid = 1'b1;
                    end
                end
            end
        end
    end

    // Step 3: Port Assignment following Section 5.2 & Table 5.2
    logic        sel_p2_valid, sel_p3_valid;
    memiq_slot_t sel_p2_slot,  sel_p3_slot;
    logic        cand0_is_load, cand0_is_store, cand0_is_ser;
    logic        cand1_is_load, cand1_is_store, cand1_is_ser;

    always_comb begin
        sel_p2_valid   = 1'b0;
        sel_p2_slot    = '0;
        sel_p3_valid   = 1'b0;
        sel_p3_slot    = '0;
        cand0_is_load  = 1'b0;
        cand0_is_store = 1'b0;
        cand0_is_ser   = 1'b0;
        cand1_is_load  = 1'b0;
        cand1_is_store = 1'b0;
        cand1_is_ser   = 1'b0;

        if (cand0_valid && cand1_valid) begin
            cand0_is_load  = (entries_q[cand0_slot].uop_class == UOP_LOAD);
            cand0_is_store = (entries_q[cand0_slot].uop_class == UOP_STORE);
            cand0_is_ser   = (entries_q[cand0_slot].uop_class == UOP_AMO) || (entries_q[cand0_slot].uop_class == UOP_FENCE);

            cand1_is_load  = (entries_q[cand1_slot].uop_class == UOP_LOAD);
            cand1_is_store = (entries_q[cand1_slot].uop_class == UOP_STORE);
            cand1_is_ser   = (entries_q[cand1_slot].uop_class == UOP_AMO) || (entries_q[cand1_slot].uop_class == UOP_FENCE);

            if (cand0_is_ser) begin
                // Row 5: AMO / FENCE (A0) issues strictly as singleton on Port 2
                sel_p2_valid = 1'b1;
                sel_p2_slot  = cand0_slot;
                sel_p3_valid = 1'b0;
            end else if (cand0_is_store && cand1_is_load) begin
                // Row 3: Store (cand0) + Load (cand1) -> Store to Port 2, Load to Port 3
                sel_p2_valid = 1'b1;
                sel_p2_slot  = cand0_slot;
                sel_p3_valid = 1'b1;
                sel_p3_slot  = cand1_slot;
            end else if (cand0_is_load && cand1_is_store) begin
                // Row 2: Load (cand0) + Store (cand1) -> Store to Port 2, Load to Port 3
                sel_p2_valid = 1'b1;
                sel_p2_slot  = cand1_slot;
                sel_p3_valid = 1'b1;
                sel_p3_slot  = cand0_slot;
            end else if (cand0_is_load && cand1_is_load) begin
                // Row 1: Dual Loads -> Older load to Port 2, younger load to Port 3
                sel_p2_valid = 1'b1;
                sel_p2_slot  = cand0_slot;
                sel_p3_valid = 1'b1;
                sel_p3_slot  = cand1_slot;
            end else if (cand0_is_store && (cand1_is_store || cand1_is_ser)) begin
                // Row 4: Two stores -> Only older store to Port 2 (stores strictly single-issue)
                sel_p2_valid = 1'b1;
                sel_p2_slot  = cand0_slot;
                sel_p3_valid = 1'b0;
            end else if (cand0_is_load && cand1_is_ser) begin
                // Load older than serialized AMO/FENCE -> Load to Port 2, AMO remains queued
                sel_p2_valid = 1'b1;
                sel_p2_slot  = cand0_slot;
                sel_p3_valid = 1'b0;
            end else begin
                sel_p2_valid = 1'b1;
                sel_p2_slot  = cand0_slot;
                sel_p3_valid = 1'b0;
            end
        end else if (cand0_valid) begin
            // Case 4: Single ready candidate
            cand0_is_load = (entries_q[cand0_slot].uop_class == UOP_LOAD);
            if (cand0_is_load && port2_busy_i && !port3_busy_i) begin
                // Port 2 backpressured: Load issues to Port 3
                sel_p3_valid = 1'b1;
                sel_p3_slot  = cand0_slot;
            end else begin
                // Normal single issue to Port 2
                sel_p2_valid = 1'b1;
                sel_p2_slot  = cand0_slot;
            end
        end
    end

    // Squash checks
    wire p2_squashed = recover_valid_i && sel_p2_valid &&
                       (rob_dist(entries_q[sel_p2_slot].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire p3_squashed = recover_valid_i && sel_p3_valid &&
                       (rob_dist(entries_q[sel_p3_slot].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    // Issue fires
    wire issue0_fire = sel_p2_valid && !port2_busy_i && !flush_valid_i && !p2_squashed;
    wire issue1_fire = sel_p3_valid && !port3_busy_i && !flush_valid_i && !p3_squashed;

    assign issue0_valid_o = issue0_fire;
    assign issue0_uop_o   = entries_q[sel_p2_slot];

    assign issue1_valid_o = issue1_fire;
    assign issue1_uop_o   = entries_q[sel_p3_slot];

    // -------------------------------------------------------------------------
    // Occupancy, Capacity & Allocation Slots Finder (Accounting for Same-Cycle Deallocation)
    // -------------------------------------------------------------------------
    logic [MEM_IQ_CNT_W-1:0] free_count;
    logic [MEM_IQ_CNT_W-1:0] count;
    memiq_slot_t             alloc_slot0, alloc_slot1;
    logic                    slot0_found, slot1_found;
    logic [MEM_IQ_DEPTH-1:0] slot_free;

    always_comb begin
        free_count  = '0;
        count       = '0;
        alloc_slot0 = '0;
        alloc_slot1 = '0;
        slot0_found = 1'b0;
        slot1_found = 1'b0;

        for (int i = 0; i < MEM_IQ_DEPTH; i++) begin
            if (entries_q[i].valid) count = count + MEM_IQ_CNT_W'(1);
            slot_free[i] = !entries_q[i].valid ||
                           (issue0_fire && (memiq_slot_t'(i) == sel_p2_slot)) ||
                           (issue1_fire && (memiq_slot_t'(i) == sel_p3_slot));
            if (slot_free[i]) begin
                free_count = free_count + MEM_IQ_CNT_W'(1);
                if (!slot0_found) begin
                    alloc_slot0 = memiq_slot_t'(i);
                    slot0_found = 1'b1;
                end else if (!slot1_found) begin
                    alloc_slot1 = memiq_slot_t'(i);
                    slot1_found = 1'b1;
                end
            end
        end
    end

    assign count_o        = count;
    assign free_count_o   = free_count;
    assign mem_ready_o[0] = (free_count >= MEM_IQ_CNT_W'(1)) && !flush_valid_i;
    assign mem_ready_o[1] = (free_count >= MEM_IQ_CNT_W'(2)) && !flush_valid_i;

    // Allocation Fires
    wire uop0_is_mem = (uop0_class_i == UOP_LOAD) || (uop0_class_i == UOP_STORE) ||
                       (uop0_class_i == UOP_AMO)  || (uop0_class_i == UOP_FENCE);
    wire uop1_is_mem = (uop1_class_i == UOP_LOAD) || (uop1_class_i == UOP_STORE) ||
                       (uop1_class_i == UOP_AMO)  || (uop1_class_i == UOP_FENCE);

    wire uop0_v_mem  = uop0_valid_i && uop0_is_mem;

    memiq_slot_t alloc_slot1_eff;
    assign alloc_slot1_eff = uop0_v_mem ? alloc_slot1 : alloc_slot0;
    wire   slot1_found_eff = uop0_v_mem ? slot1_found : slot0_found;

    wire alloc0_fire = uop0_v_mem && rename_ack_i[0] && !flush_valid_i && slot0_found;
    wire alloc1_fire = uop1_valid_i && uop1_is_mem && rename_ack_i[1] && !flush_valid_i && slot1_found_eff;

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
    wire wb0_match = wb0_valid_i && wb0_comp_ack_i && (wb0_pnew_i != preg_t'(0));
    wire wb1_match = wb1_valid_i && wb1_comp_ack_i && (wb1_pnew_i != preg_t'(0));
    // Faulting loads do NOT wake dependent uops (Section 3.2, 17.3)
    wire wb2_match = wb2_valid_i && wb2_comp_ack_i && !wb2_comp_exception_i && (wb2_pnew_i != preg_t'(0));
    wire wb3_match = wb3_valid_i && wb3_comp_ack_i && !wb3_comp_exception_i && (wb3_pnew_i != preg_t'(0));

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
                            (wb2_match && (wb2_pnew_i == entries_q[i].prs1)) ||
                            (wb3_match && (wb3_pnew_i == entries_q[i].prs1))) begin
                            entries_q[i].prs1_ready <= 1'b1;
                        end
                    end
                    // Store data wakeup (for informational capture)
                    if (!entries_q[i].prs2_ready) begin
                        if ((wb0_match && (wb0_pnew_i == entries_q[i].prs2)) ||
                            (wb1_match && (wb1_pnew_i == entries_q[i].prs2)) ||
                            (wb2_match && (wb2_pnew_i == entries_q[i].prs2)) ||
                            (wb3_match && (wb3_pnew_i == entries_q[i].prs2))) begin
                            entries_q[i].prs2_ready <= 1'b1;
                        end
                    end
                end
            end

            // 2. Issue Deallocation
            if (issue0_fire) begin
                entries_q[sel_p2_slot].valid <= 1'b0;
            end
            if (issue1_fire) begin
                entries_q[sel_p3_slot].valid <= 1'b0;
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
                entries_q[alloc_slot0].prs1_ready   <= uop0_prs1_ready_i || (uop0_prs1_i == preg_t'(0)) ||
                    (wb0_match && (wb0_pnew_i == uop0_prs1_i)) ||
                    (wb1_match && (wb1_pnew_i == uop0_prs1_i)) ||
                    (wb2_match && (wb2_pnew_i == uop0_prs1_i)) ||
                    (wb3_match && (wb3_pnew_i == uop0_prs1_i));
                entries_q[alloc_slot0].prs2         <= uop0_prs2_i;
                entries_q[alloc_slot0].prs2_ready   <= uop0_prs2_ready_i || (uop0_prs2_i == preg_t'(0)) ||
                    (wb0_match && (wb0_pnew_i == uop0_prs2_i)) ||
                    (wb1_match && (wb1_pnew_i == uop0_prs2_i)) ||
                    (wb2_match && (wb2_pnew_i == uop0_prs2_i)) ||
                    (wb3_match && (wb3_pnew_i == uop0_prs2_i));
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
                entries_q[alloc_slot1_eff].prs1_ready   <= uop1_prs1_ready_i || (uop1_prs1_i == preg_t'(0)) ||
                    (wb0_match && (wb0_pnew_i == uop1_prs1_i)) ||
                    (wb1_match && (wb1_pnew_i == uop1_prs1_i)) ||
                    (wb2_match && (wb2_pnew_i == uop1_prs1_i)) ||
                    (wb3_match && (wb3_pnew_i == uop1_prs1_i));
                entries_q[alloc_slot1_eff].prs2         <= uop1_prs2_i;
                entries_q[alloc_slot1_eff].prs2_ready   <= uop1_prs2_ready_i || (uop1_prs2_i == preg_t'(0)) ||
                    (wb0_match && (wb0_pnew_i == uop1_prs2_i)) ||
                    (wb1_match && (wb1_pnew_i == uop1_prs2_i)) ||
                    (wb2_match && (wb2_pnew_i == uop1_prs2_i)) ||
                    (wb3_match && (wb3_pnew_i == uop1_prs2_i));
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

`ifndef SYNTHESIS
    // Verification Invariant Assertions
    always_ff @(posedge clk_i) begin
        if (!rst_i && !flush_valid_i) begin
            assert (count <= MEM_IQ_CNT_W'(MEM_IQ_DEPTH))
                else $fatal(1, "[MEMIQ_ASSERTION_FAILED] MemIQ occupancy count exceeded %0d: %0d", MEM_IQ_DEPTH, count);
            if (count == MEM_IQ_CNT_W'(MEM_IQ_DEPTH) && !issue0_fire && !issue1_fire) begin
                assert (!alloc0_fire && !alloc1_fire)
                    else $fatal(1, "[MEMIQ_ASSERTION_FAILED] Allocation accepted into full MemIQ without issue deallocation!");
            end
            // PROP_M7_03: Store uop is never selected for issue on Port 3 (load-only restriction)
            if (issue1_fire) begin
                assert (entries_q[sel_p3_slot].uop_class == UOP_LOAD)
                    else $fatal(1, "[MEMIQ_ASSERTION_FAILED] PROP_M7_03 Violated: Non-load uop issued to Port 3!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_MEM_IQ_SV
