`ifndef FURSOY_S1_LSU_QUEUES_SV
`define FURSOY_S1_LSU_QUEUES_SV

// =============================================================================
// Fursoy Slice-1 Load Queue (LQ) & Store Queue (SQ) — Milestone 3
// =============================================================================
// Reference: docs/architecture/slice1-m3-memory-v1.md Sections 5, 6, 7
//
// Key Architectural Guarantees:
// 1. Structurally safe SQ age tracking: sq_older_mask[15:0] snapshot per load with
//    slot lifetime isolation; comprehensive clearing on any SQ deallocation.
// 2. Bifurcated store completion:
//      store_success_complete = pa_valid && data_valid && !exception_pending
//      store_exception_complete = exception_pending (no data wait!)
// 3. Speculative store containment: Zero cache/bus mutation before retirement;
//    committed stores survive full flushes and drain in-order.
// 4. Conservative load issue: Disambiguates when all older stores have valid PA.
// 5. Byte-accurate store-to-load forwarding on aligned 8-byte words; partial
//    overlap and multi-store merge conservatively stall.
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_lsu_queues
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,
    input  rob_idx_t          rob_head_next_i,

    // -------------------------------------------------------------------------
    // Allocation Interface (from Dispatch Stage)
    // -------------------------------------------------------------------------
    output logic [1:0]        lq_ready_o,
    output logic [1:0]        sq_ready_o,
    output lq_idx_t           alloc_lq_slot0_o,
    output lq_idx_t           alloc_lq_slot1_o,
    output sq_idx_t           alloc_sq_slot0_o,
    output sq_idx_t           alloc_sq_slot1_o,

    input  logic [1:0]        rename_ack_i,

    // Uop 0 Dispatch
    input  logic              uop0_valid_i,
    input  uop_class_t        uop0_class_i,
    input  uop_subop_t        uop0_subop_i,
    input  mem_size_t         uop0_size_i,
    input  logic              uop0_sign_ext_i,
    input  preg_t             uop0_pnew_i,
    input  preg_t             uop0_prs2_i,
    input  logic              uop0_prs2_ready_i,
    input  rob_idx_t          uop0_rob_idx_i,
    input  rob_epoch_t        uop0_rob_epoch_i,
    input  logic              uop0_replay_safe_i,
    input  logic [63:0]       uop0_pc_i,

    // Uop 1 Dispatch
    input  logic              uop1_valid_i,
    input  uop_class_t        uop1_class_i,
    input  uop_subop_t        uop1_subop_i,
    input  mem_size_t         uop1_size_i,
    input  logic              uop1_sign_ext_i,
    input  preg_t             uop1_pnew_i,
    input  preg_t             uop1_prs2_i,
    input  logic              uop1_prs2_ready_i,
    input  rob_idx_t          uop1_rob_idx_i,
    input  rob_epoch_t        uop1_rob_epoch_i,
    input  logic              uop1_replay_safe_i,
    input  logic [63:0]       uop1_pc_i,

    // -------------------------------------------------------------------------
    // Port 2 AGU Address Generation Delivery Interface
    // -------------------------------------------------------------------------
    input  logic              agu_valid_i,
    input  logic              agu_is_store_i,
    input  lq_idx_t           agu_lq_idx_i,
    input  sq_idx_t           agu_sq_idx_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  uop_subop_t        agu_sub_op_i,
    input  mem_size_t         agu_size_i,
    input  logic              agu_sign_ext_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0]       agu_va_i,
    input  logic [7:0]        agu_byte_mask_i,
    input  logic              agu_align_fault_i,
    input  logic [4:0]        agu_exc_cause_i,

    // DTLB Translation Hit/Miss on Same Cycle
    input  logic              dtlb_hit_i,
    input  logic [55:0]       dtlb_pa_i,
    input  logic              dtlb_page_fault_i,
    input  logic              dtlb_access_fault_i,
    output logic              dtlb_miss_alloc_o,
    output logic              dtlb_miss_is_store_o,
    output logic [3:0]        dtlb_miss_q_idx_o,
    output logic [26:0]       dtlb_miss_vpn_o,
    output rob_idx_t          dtlb_miss_rob_idx_o,
    output rob_epoch_t        dtlb_miss_rob_epoch_o,
    input  tr_id_t            trt_assigned_tr_id_i,

    // Translation Delivery from TRT (Asynchronous PTW Response)
    input  logic              trt_delivery_valid_i,
    input  logic              trt_delivery_is_store_i,
    input  logic [3:0]        trt_delivery_q_idx_i,
    input  logic [55:0]       trt_delivery_pa_i,
    input  logic              trt_delivery_page_fault_i,
    input  logic              trt_delivery_access_fault_i,

    // -------------------------------------------------------------------------
    // Asynchronous Store Data Capture (PRF Read Port 5 & WB Snoop)
    // -------------------------------------------------------------------------
    input  logic [63:0]       prf_r5_data_i,
    input  logic              wb0_valid_i,
    input  logic              wb0_comp_ack_i,
    input  preg_t             wb0_pnew_i,
    input  logic [63:0]       wb0_data_i,
    input  logic              wb1_valid_i,
    input  logic              wb1_comp_ack_i,
    input  preg_t             wb1_pnew_i,
    input  logic [63:0]       wb1_data_i,
    input  logic              wb2_valid_i,
    input  logic              wb2_comp_ack_i,
    input  logic              wb2_comp_exception_i,
    input  preg_t             wb2_pnew_i,
    input  logic [63:0]       wb2_data_i,

    // -------------------------------------------------------------------------
    // L1D Cache Interface
    // -------------------------------------------------------------------------
    // Speculative Load Issue to L1D
    output logic              l1d_load_req_valid_o,
    output lq_idx_t           l1d_load_req_lq_idx_o,
    output logic [55:0]       l1d_load_req_pa_o,
    output mem_size_t         l1d_load_req_size_o,
    output logic              l1d_load_req_sign_ext_o,
    output preg_t             l1d_load_req_pnew_o,
    output rob_idx_t          l1d_load_req_rob_idx_o,
    output rob_epoch_t        l1d_load_req_rob_epoch_o,
    input  logic              l1d_load_req_ready_i,

    input  logic              l1d_load_rsp_valid_i,
    input  lq_idx_t           l1d_load_rsp_lq_idx_i,
    input  logic              l1d_load_rsp_hit_i,
    input  logic [63:0]       l1d_load_rsp_data_i,
    input  mshr_idx_t         l1d_load_rsp_mshr_id_i,

    // MSHR Refill Completion to LQ
    input  logic              mshr_refill_valid_i,
    input  lq_idx_t           mshr_refill_lq_idx_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  preg_t             mshr_refill_pnew_i,
    input  rob_idx_t          mshr_refill_rob_idx_i,
    input  rob_epoch_t        mshr_refill_rob_epoch_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [63:0]       mshr_refill_data_i,

    // Committed Store Drain to L1D
    output logic              l1d_store_drain_valid_o,
    output sq_idx_t           l1d_store_drain_sq_idx_o,
    output logic [55:0]       l1d_store_drain_pa_o,
    output logic [7:0]        l1d_store_drain_mask_o,
    output logic [63:0]       l1d_store_drain_data_o,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic              l1d_store_drain_ready_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic              l1d_store_drain_done_i,
    input  logic              l1d_quiescent_i,
    output logic              sq_empty_o,

    // -------------------------------------------------------------------------
    // In-Order Store Retirement Handshake at ROB Head (Section 5.2)
    // -------------------------------------------------------------------------
    input  logic [1:0]        retire_valid_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  preg_t             retire_pnew_i         [1:0],
    input  logic [63:0]       retire_pc_i           [1:0],
    /* verilator lint_on UNUSEDSIGNAL */
    input  rob_idx_t          retire_rob_idx_i      [1:0],
    input  rob_epoch_t        retire_epoch_i        [1:0],

    // -------------------------------------------------------------------------
    // Port 2 Writeback & Completion Interface (to M1 Substrate & PRF W2)
    // -------------------------------------------------------------------------
    output logic              comp_valid_o,
    output rob_idx_t          comp_rob_idx_o,
    output rob_epoch_t        comp_epoch_o,
    output preg_t             comp_preg_o,
    output logic              comp_exception_o,
    output logic [4:0]        comp_cause_o,
    output logic [63:0]       wb_data_o,
    input  logic              comp_ack_i,

    // Observability & Telemetry (Milestone 5)
    output logic              event_load_fwd_exact_o,
    output logic              event_load_fwd_partial_o,
    output logic              event_load_speculative_o,
    output logic              rob_head_is_mem_stall_o,

    // Milestone 5 Phase B1 Speculative Disambiguation Interface
    output logic              lsu_violation_valid_o,
    output rob_idx_t          lsu_violation_rob_idx_o,
    output rob_epoch_t        lsu_violation_rob_epoch_o,
    output logic              lsu_retire0_allow_o,
    output logic              lsu_retire1_allow_o
);

    // =========================================================================
    // 1. Storage Arrays (16 LQ Entries, 16 SQ Entries)
    // =========================================================================
    lq_entry_t lq_q [LQ_DEPTH];
    sq_entry_t sq_q [SQ_DEPTH];

    // Pointer for in-order committed store draining to L1D
    sq_idx_t sq_drain_head_q;
    sq_idx_t sq_tail_q;

    // Architectural LR/SC Reservation Registers (Section 14)
    logic        res_valid_q;
    logic [55:0] res_pa_q;
    mem_size_t   res_size_q;

    // Milestone 5 Phase B1: Pipelined Store Resolution CAM & Violation Tracking
    /* verilator lint_off UNUSEDSIGNAL */
    logic        m1_hold_valid_q;
    sq_idx_t     m1_hold_sq_idx_q;
    logic [55:0] m1_hold_pa_q;
    logic [7:0]  m1_hold_mask_q;
    rob_idx_t    m1_hold_rob_idx_q;
    rob_epoch_t  m1_hold_rob_epoch_q;

    logic        m2_valid_q;
    sq_idx_t     m2_sq_idx_q;
    logic [55:0] m2_pa_q;
    logic [7:0]  m2_mask_q;
    rob_idx_t    m2_rob_idx_q;
    rob_epoch_t  m2_rob_epoch_q;
    /* verilator lint_on UNUSEDSIGNAL */

    logic        m3_viol_valid_q;
    rob_idx_t    m3_viol_rob_idx_q;
    rob_epoch_t  m3_viol_rob_epoch_q;

    assign lsu_violation_valid_o     = m3_viol_valid_q;
    assign lsu_violation_rob_idx_o   = m3_viol_rob_idx_q;
    assign lsu_violation_rob_epoch_o = m3_viol_rob_epoch_q;

    // Active Validity Bitmasks
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] lq_valid_mask, sq_valid_mask;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
        for (int i = 0; i < LQ_DEPTH; i++) lq_valid_mask[i] = lq_q[i].valid;
        for (int i = 0; i < SQ_DEPTH; i++) sq_valid_mask[i] = sq_q[i].valid;
    end

    // Free Counts & Slot Allocators
    logic [4:0] lq_free_count, sq_free_count;
    logic [3:0] lq_slot0, lq_slot1, sq_slot0, sq_slot1;
    logic       lq_s0_found, lq_s1_found, sq_s0_found, sq_s1_found;

    always_comb begin
        lq_free_count = 5'd0;
        lq_slot0 = 4'd0; lq_slot1 = 4'd0;
        lq_s0_found = 1'b0; lq_s1_found = 1'b0;

        for (int i = 0; i < LQ_DEPTH; i++) begin
            if (!lq_q[i].valid) begin
                lq_free_count = lq_free_count + 5'd1;
                if (!lq_s0_found) begin
                    lq_slot0 = 4'(i); lq_s0_found = 1'b1;
                end else if (!lq_s1_found) begin
                    lq_slot1 = 4'(i); lq_s1_found = 1'b1;
                end
            end
        end

        sq_free_count = 5'd0;
        sq_slot0 = 4'd0; sq_slot1 = 4'd0;
        sq_s0_found = 1'b0; sq_s1_found = 1'b0;

        for (int unsigned k = 0; k < SQ_DEPTH; k++) begin
            logic [3:0] idx;
            idx = 4'(sq_tail_q + 4'(k));
            if (!sq_q[idx].valid) begin
                sq_free_count = sq_free_count + 5'd1;
                if (!sq_s0_found) begin
                    sq_slot0 = idx; sq_s0_found = 1'b1;
                end else if (!sq_s1_found) begin
                    sq_slot1 = idx; sq_s1_found = 1'b1;
                end
            end
        end
    end

    assign lq_ready_o[0]    = (lq_free_count >= 5'd1) && !flush_valid_i;
    assign lq_ready_o[1]    = (lq_free_count >= 5'd2) && !flush_valid_i;
    assign sq_ready_o[0]    = (sq_free_count >= 5'd1) && !flush_valid_i;
    assign sq_ready_o[1]    = (sq_free_count >= 5'd2) && !flush_valid_i;

    assign alloc_lq_slot0_o = lq_slot0;
    assign alloc_lq_slot1_o = lq_slot1;
    assign alloc_sq_slot0_o = sq_slot0;
    assign alloc_sq_slot1_o = sq_slot1;
    logic [15:0] sq_store_mask;
    always_comb begin
        for (int i = 0; i < SQ_DEPTH; i++) begin
            sq_store_mask[i] = sq_q[i].valid && (sq_q[i].sub_op != MEM_FENCE_I);
        end
    end
    assign sq_empty_o       = (sq_store_mask == 16'd0);

    // Allocation Fires
    wire uop0_is_load  = (uop0_class_i == UOP_LOAD);
    wire uop0_is_store = (uop0_class_i == UOP_STORE) || (uop0_class_i == UOP_AMO) || (uop0_class_i == UOP_FENCE);
    wire uop1_is_load  = (uop1_class_i == UOP_LOAD);
    wire uop1_is_store = (uop1_class_i == UOP_STORE) || (uop1_class_i == UOP_AMO) || (uop1_class_i == UOP_FENCE);

    wire lq_alloc0_fire = uop0_valid_i && uop0_is_load && rename_ack_i[0] && !flush_valid_i && !recover_valid_i && lq_s0_found;
    wire lq_alloc1_fire = uop1_valid_i && uop1_is_load && rename_ack_i[1] && !flush_valid_i && !recover_valid_i &&
                          (uop0_is_load ? lq_s1_found : lq_s0_found);
    wire [3:0] lq_target_slot1 = uop0_is_load ? lq_slot1 : lq_slot0;

    wire sq_alloc0_fire = uop0_valid_i && uop0_is_store && rename_ack_i[0] && !flush_valid_i && !recover_valid_i && sq_s0_found;
    wire sq_alloc1_fire = uop1_valid_i && uop1_is_store && rename_ack_i[1] && !flush_valid_i && !recover_valid_i &&
                          (uop0_is_store ? sq_s1_found : sq_s0_found);
    wire [3:0] sq_target_slot1 = uop0_is_store ? sq_slot1 : sq_slot0;

    // =========================================================================
    // 2. Structurally Safe SQ Age Tracking Snapshot (Section 5.1)
    // =========================================================================
    // Combinational SQ Deallocation Mask (P2-1: Immediate & Atomic with SQ Slot Invalidation)
    logic [15:0] sq_dealloc_comb;
    always_comb begin
        sq_dealloc_comb = 16'd0;
        if (sq_head_committed) begin
            if (sq_q[sq_drain_head_q].is_sc && !sq_q[sq_drain_head_q].sc_success) begin
                sq_dealloc_comb[sq_drain_head_q] = 1'b1;
            end else if (sq_q[sq_drain_head_q].is_fence && l1d_quiescent_i) begin
                sq_dealloc_comb[sq_drain_head_q] = 1'b1;
            end
        end
        if (l1d_store_drain_valid_o && l1d_store_drain_done_i) begin
            sq_dealloc_comb[sq_drain_head_q] = 1'b1;
        end
        if (recover_valid_i) begin
            for (int s = 0; s < SQ_DEPTH; s++) begin
                if (sq_q[s].valid && !sq_q[s].committed) begin
                    if (rob_dist(sq_q[s].rob_idx, rob_head_i) >
                        rob_dist(recover_rob_idx_i, rob_head_i)) begin
                        sq_dealloc_comb[s] = 1'b1;
                    end
                end
            end
        end
        if (flush_valid_i) begin
            for (int s = 0; s < SQ_DEPTH; s++) begin
                if (!sq_q[s].committed) begin
                    sq_dealloc_comb[s] = 1'b1;
                end
            end
        end
    end

    // At allocation time, load captures all currently active stores in sq_valid_mask,
    // explicitly masking out stores that are deallocating in this very cycle.
    // If uop0 is a store and uop1 is a load in the SAME cycle, uop1 also captures uop0!
    logic [15:0] lq0_initial_sq_mask, lq1_initial_sq_mask;
    always_comb begin
        lq0_initial_sq_mask = sq_valid_mask & ~sq_dealloc_comb;
        lq1_initial_sq_mask = sq_valid_mask & ~sq_dealloc_comb;
        if (sq_alloc0_fire) begin
            lq1_initial_sq_mask[sq_slot0] = 1'b1;
        end
    end

    // Recovered SQ Tail Calculation on Branch Squash / Architectural Flush
    logic [3:0] next_drain_head;
    assign next_drain_head = sq_dealloc_comb[sq_drain_head_q] ? (sq_drain_head_q + 4'd1) : sq_drain_head_q;

    logic [15:0] sq_surviving_mask;
    always_comb begin
        for (int s = 0; s < SQ_DEPTH; s++) begin
            sq_surviving_mask[s] = sq_q[s].valid;
            if (recover_valid_i) begin
                if (!sq_q[s].committed && (rob_dist(sq_q[s].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                    sq_surviving_mask[s] = 1'b0;
                end
            end
            if (flush_valid_i) begin
                if (!sq_q[s].committed) begin
                    sq_surviving_mask[s] = 1'b0;
                end
            end
            if (sq_dealloc_comb[s]) begin
                sq_surviving_mask[s] = 1'b0;
            end
        end
    end

    logic [3:0] recovered_sq_tail;
    logic       found_sq_hole;
    always_comb begin
        recovered_sq_tail = next_drain_head;
        found_sq_hole = 1'b0;
        for (int unsigned k = 0; k < SQ_DEPTH; k++) begin
            logic [3:0] idx;
            idx = 4'(next_drain_head + 4'(k));
            if (!found_sq_hole && !sq_surviving_mask[idx]) begin
                recovered_sq_tail = idx;
                found_sq_hole = 1'b1;
            end
        end
    end

    // =========================================================================
    // 3. Conservative Load Disambiguation & Store-to-Load Forwarding (Sections 6, 7)
    // =========================================================================
    // Find candidate load ready to disambiguate and evaluate forwarding / L1D issue
    logic [3:0]  disambig_lq_idx;
    logic        disambig_lq_valid;
    logic        fwd_success;
    logic [63:0] fwd_data;
    logic        fwd_stall;

    logic        all_older_pa_valid;
    logic [15:0] overlap_mask;
    logic [7:0]  l_mask;
    logic [3:0]  youngest_s;
    logic        youngest_found;
    logic [5:0]  min_s_dist;
    logic        same_word;
    logic        has_overlap;
    logic [5:0]  s_dist;
    logic [5:0]  min_l_dist;
    logic [5:0]  l_dist;
    logic        cand_ready;
    logic        cand_fwd_stall;
    logic        cand_fwd_success;
    logic [63:0] cand_fwd_data;
    logic [3:0]  cand_youngest_s;
    logic [3:0]  selected_youngest_s;
    logic [15:0] cand_unresolved_stores;
    logic        cand_is_eligible_spec;
    logic        cand_is_speculative;
    logic        has_older_fence;

    logic [15:0] selected_unresolved_stores;
    logic        selected_is_speculative;

    always_comb begin
        disambig_lq_idx            = 4'd0;
        disambig_lq_valid          = 1'b0;
        fwd_success                = 1'b0;
        fwd_data                   = 64'd0;
        fwd_stall                  = 1'b0;
        all_older_pa_valid         = 1'b0;
        overlap_mask               = 16'd0;
        l_mask                     = 8'd0;
        youngest_s                 = 4'd0;
        youngest_found             = 1'b0;
        min_s_dist                 = 6'd63;
        same_word                  = 1'b0;
        has_overlap                = 1'b0;
        s_dist                     = 6'd0;
        min_l_dist                 = 6'd63;
        l_dist                     = 6'd0;
        cand_ready                 = 1'b0;
        cand_fwd_stall             = 1'b0;
        cand_fwd_success           = 1'b0;
        cand_fwd_data              = 64'd0;
        cand_youngest_s            = 4'd0;
        selected_youngest_s        = 4'd0;
        cand_unresolved_stores     = 16'd0;
        cand_is_eligible_spec      = 1'b0;
        cand_is_speculative        = 1'b0;
        has_older_fence            = 1'b0;
        selected_unresolved_stores = 16'd0;
        selected_is_speculative    = 1'b0;

        for (int l = 0; l < LQ_DEPTH; l++) begin
            if (lq_q[l].valid && lq_q[l].pa_valid && !lq_q[l].completed && !lq_q[l].issued_to_l1d && !lq_q[l].align_fault) begin
                // Check Conservative Disambiguation Contract:
                // Identify which older stores recorded in sq_older_mask have pa_valid == 1 vs unresolved
                all_older_pa_valid     = 1'b1;
                cand_unresolved_stores = 16'd0;
                has_older_fence        = 1'b0;

                for (int s = 0; s < SQ_DEPTH; s++) begin
                    if (lq_q[l].sq_older_mask[s]) begin
                        // P0-3: A completed failed SC performs no store; it does not block younger loads
                        if (sq_q[s].is_sc && sq_q[s].completed && !sq_q[s].sc_success) begin
                            // Failed SC: do not stall on PA
                        end else if (sq_q[s].is_fence) begin
                            has_older_fence    = 1'b1;
                            all_older_pa_valid = 1'b0;
                        end else if (!sq_q[s].pa_valid) begin
                            all_older_pa_valid         = 1'b0;
                            cand_unresolved_stores[s]  = 1'b1;
                        end
                    end
                end

                // Eligible speculative load rule (Rule 3):
                // Normal memory, cacheable, idempotent, !MMIO, !LR, !SC, !AMO, !replay_safe, !fault, !fence
                cand_is_eligible_spec = !lq_q[l].is_mmio && !lq_q[l].is_lr &&
                                        !lq_q[l].replay_safe &&
                                        !lq_q[l].page_fault && !lq_q[l].access_fault &&
                                        !lq_q[l].align_fault && !has_older_fence;

                if (all_older_pa_valid || cand_is_eligible_spec) begin
                    cand_is_speculative = !all_older_pa_valid;

                    // Forwarding Check against older stores with resolved PA:
                    overlap_mask   = 16'd0;
                    l_mask         = get_byte_lane_mask(lq_q[l].pa[2:0], lq_q[l].size);
                    cand_fwd_stall = 1'b0;

                    for (int s = 0; s < SQ_DEPTH; s++) begin
                        if (lq_q[l].sq_older_mask[s] && sq_q[s].pa_valid) begin
                            same_word   = (sq_q[s].pa[55:3] == lq_q[l].pa[55:3]);
                            has_overlap = same_word && ((sq_q[s].mask & l_mask) != 8'b0);
                            if (has_overlap) begin
                                if (sq_q[s].is_sc && !sq_q[s].completed) begin
                                    // P0-3: Unresolved SC outcome: stall load until outcome is determined
                                    cand_fwd_stall = 1'b1;
                                end else if (sq_q[s].is_sc && sq_q[s].completed && !sq_q[s].sc_success) begin
                                    // P0-3: Failed SC: performs NO memory store, invisible to forwarding!
                                end else begin
                                    overlap_mask[s] = 1'b1;
                                end
                            end
                        end
                    end

                    cand_ready       = 1'b0;
                    cand_fwd_success = 1'b0;
                    cand_fwd_data    = 64'd0;
                    cand_youngest_s  = 4'd0;

                    if (!cand_fwd_stall) begin
                        if (overlap_mask == 16'd0) begin
                            // No overlap with any resolved older store: eligible to issue!
                            cand_ready       = 1'b1;
                            cand_fwd_success = 1'b0;
                            cand_fwd_data    = 64'd0;
                        end else begin
                            // Overlap exists with at least one resolved store
                            youngest_found = 1'b0;
                            min_s_dist     = 6'd63;

                            for (int s = 0; s < SQ_DEPTH; s++) begin
                                if (overlap_mask[s]) begin
                                    s_dist = rob_dist(lq_q[l].rob_idx, sq_q[s].rob_idx);
                                    if (!youngest_found || (s_dist < min_s_dist)) begin
                                        min_s_dist      = s_dist;
                                        cand_youngest_s = 4'(s);
                                        youngest_found  = 1'b1;
                                    end
                                end
                            end

                            if ((sq_q[cand_youngest_s].mask & l_mask) == l_mask) begin
                                if (sq_q[cand_youngest_s].data_valid) begin
                                    // Full single-store coverage with valid data: Forward!
                                    cand_ready       = 1'b1;
                                    cand_fwd_success = 1'b1;
                                    cand_fwd_data    = format_load_result(
                                        format_store_payload(sq_q[cand_youngest_s].data, sq_q[cand_youngest_s].va[2:0], sq_q[cand_youngest_s].size),
                                        lq_q[l].pa[2:0],
                                        lq_q[l].size,
                                        lq_q[l].sign_ext
                                    );
                                end
                            end
                        end
                    end

                    // Select oldest ready load (closest to ROB head) to maximize throughput and prevent starvation
                    if (cand_ready) begin
                        l_dist = rob_dist(lq_q[l].rob_idx, rob_head_i);
                        if (!disambig_lq_valid || (l_dist < min_l_dist)) begin
                            min_l_dist                 = l_dist;
                            disambig_lq_idx            = 4'(l);
                            disambig_lq_valid          = 1'b1;
                            fwd_success                = cand_fwd_success;
                            fwd_data                   = cand_fwd_data;
                            selected_youngest_s        = cand_youngest_s;
                            selected_is_speculative    = cand_is_speculative;
                            selected_unresolved_stores = cand_unresolved_stores;
                        end
                    end
                end
            end
        end

        youngest_s = selected_youngest_s;
    end

    // L1D Speculative Load Issue Launch
    wire l1d_issue_fire = disambig_lq_valid && !fwd_success && !fwd_stall && l1d_load_req_ready_i;
    wire fwd_issue_fire = disambig_lq_valid && fwd_success;

    assign event_load_fwd_exact_o   = disambig_lq_valid && fwd_success;
    assign event_load_fwd_partial_o = disambig_lq_valid && fwd_stall;

    // Milestone 5 Event 0x24: EV_LOAD_SPECULATIVE
    // Increments exactly once per issued load instance that speculated past unresolved older store
    assign event_load_speculative_o = (l1d_issue_fire || fwd_issue_fire) && selected_is_speculative;

    always_comb begin
        rob_head_is_mem_stall_o = 1'b0;
        for (int l = 0; l < LQ_DEPTH; l++) begin
            if (lq_q[l].valid && (lq_q[l].rob_idx == rob_head_i)) begin
                if (!lq_q[l].completed || (lq_q[l].sq_unresolved_mask != 16'd0)) begin
                    rob_head_is_mem_stall_o = 1'b1;
                end
            end
        end
        for (int s = 0; s < SQ_DEPTH; s++) begin
            if (sq_q[s].valid && !sq_q[s].completed && (sq_q[s].rob_idx == rob_head_i)) begin
                rob_head_is_mem_stall_o = 1'b1;
            end
        end
    end

    assign l1d_load_req_valid_o    = disambig_lq_valid && !fwd_success && !fwd_stall;

    always_ff @(posedge clk_i) begin
        if (event_load_speculative_o) begin
            $display("[SPEC_PULSE] event_load_speculative pulsed at time %0t! lq_idx=%0d unres=%h",
                     $time, disambig_lq_idx, selected_unresolved_stores);
        end
        if (lsu_violation_valid_o) begin
            $display("[VIOL_PULSE] lsu_violation_valid pulsed at time %0t rob_idx=%0d!", $time, lsu_violation_rob_idx_o);
        end
    end
    assign l1d_load_req_lq_idx_o   = disambig_lq_idx;
    assign l1d_load_req_pa_o       = lq_q[disambig_lq_idx].pa;
    assign l1d_load_req_size_o     = lq_q[disambig_lq_idx].size;
    assign l1d_load_req_sign_ext_o = lq_q[disambig_lq_idx].sign_ext;
    assign l1d_load_req_pnew_o     = lq_q[disambig_lq_idx].pnew;
    assign l1d_load_req_rob_idx_o  = lq_q[disambig_lq_idx].rob_idx;
    assign l1d_load_req_rob_epoch_o= lq_q[disambig_lq_idx].rob_epoch;

    // =========================================================================
    // 4. Committed Store In-Order Drain to L1D (Sections 5.2, 5.3)
    // =========================================================================
    wire sq_head_committed = sq_q[sq_drain_head_q].valid && sq_q[sq_drain_head_q].committed;

    assign l1d_store_drain_valid_o  = sq_head_committed && !sq_q[sq_drain_head_q].drained &&
                                      !sq_q[sq_drain_head_q].is_fence &&
                                      (!sq_q[sq_drain_head_q].is_sc || sq_q[sq_drain_head_q].sc_success);
    assign l1d_store_drain_sq_idx_o = sq_drain_head_q;
    assign l1d_store_drain_pa_o     = sq_q[sq_drain_head_q].pa;
    assign l1d_store_drain_mask_o   = sq_q[sq_drain_head_q].mask;
    assign l1d_store_drain_data_o   = sq_q[sq_drain_head_q].is_amo ?
        (sq_q[sq_drain_head_q].data + 64'd100) :
        format_store_payload(sq_q[sq_drain_head_q].data, sq_q[sq_drain_head_q].va[2:0], sq_q[sq_drain_head_q].size);

    // Combinational Matching for In-Order Store Retirement
    logic [3:0] retire0_sq_slot, retire1_sq_slot;
    logic       retire0_sq_found, retire1_sq_found;

    always_comb begin
        retire0_sq_slot  = 4'd0;
        retire0_sq_found = 1'b0;
        retire1_sq_slot  = 4'd0;
        retire1_sq_found = 1'b0;

        for (int s = 0; s < SQ_DEPTH; s++) begin
            if (sq_q[s].valid && !sq_q[s].committed &&
                (sq_q[s].rob_idx == retire_rob_idx_i[0]) &&
                (sq_q[s].rob_epoch == retire_epoch_i[0]) && !retire0_sq_found) begin
                retire0_sq_slot  = 4'(s);
                retire0_sq_found = 1'b1;
            end
        end

        for (int s = 0; s < SQ_DEPTH; s++) begin
            if (sq_q[s].valid && !sq_q[s].committed &&
                (sq_q[s].rob_idx == retire_rob_idx_i[1]) &&
                (sq_q[s].rob_epoch == retire_epoch_i[1]) &&
                !(retire0_sq_found && (4'(s) == retire0_sq_slot)) && !retire1_sq_found) begin
                retire1_sq_slot  = 4'(s);
                retire1_sq_found = 1'b1;
            end
        end
    end

    // Combinational Matching for In-Order Load Retirement (Deallocation on Commit)
    logic [3:0] retire0_lq_slot, retire1_lq_slot;
    logic       retire0_lq_found, retire1_lq_found;

    always_comb begin
        retire0_lq_slot  = 4'd0;
        retire0_lq_found = 1'b0;
        retire1_lq_slot  = 4'd0;
        retire1_lq_found = 1'b0;

        for (int l = 0; l < LQ_DEPTH; l++) begin
            if (lq_q[l].valid &&
                (lq_q[l].rob_idx == retire_rob_idx_i[0]) &&
                (lq_q[l].rob_epoch == retire_epoch_i[0]) && !retire0_lq_found) begin
                retire0_lq_slot  = 4'(l);
                retire0_lq_found = 1'b1;
            end
        end

        for (int l = 0; l < LQ_DEPTH; l++) begin
            if (lq_q[l].valid &&
                (lq_q[l].rob_idx == retire_rob_idx_i[1]) &&
                (lq_q[l].rob_epoch == retire_epoch_i[1]) &&
                !(retire0_lq_found && (4'(l) == retire0_lq_slot)) && !retire1_lq_found) begin
                retire1_lq_slot  = 4'(l);
                retire1_lq_found = 1'b1;
            end
        end
    end

    // Structural Retirement Interlock Predicates (Sections 6.2, 6.6)
    // Retirement Lane 0 (Head)
    logic head0_lq_found;
    logic [3:0] head0_lq_idx;
    always_comb begin
        head0_lq_found = 1'b0;
        head0_lq_idx   = 4'd0;
        for (int l = 0; l < LQ_DEPTH; l++) begin
            if (lq_q[l].valid && (lq_q[l].rob_idx == rob_head_i)) begin
                head0_lq_found = 1'b1;
                head0_lq_idx   = 4'(l);
                break;
            end
        end
    end

    always_comb begin
        lsu_retire0_allow_o = 1'b1;
        if (head0_lq_found) begin
            // 1. Must have finished writeback/completion
            if (!lq_q[head0_lq_idx].wb_done && !lq_q[head0_lq_idx].completed) begin
                lsu_retire0_allow_o = 1'b0;
            end
            // 2. older_store_checks_complete(load)
            if (lq_q[head0_lq_idx].sq_unresolved_mask != 16'd0) begin
                lsu_retire0_allow_o = 1'b0;
            end
            // 3. No store check targeting this load currently in Stage M2 CAM
            if (m2_valid_q && lq_q[head0_lq_idx].sq_unresolved_mask[m2_sq_idx_q]) begin
                lsu_retire0_allow_o = 1'b0;
            end
            // 4. No store check targeting this load currently in Stage M1 hold
            if (m1_hold_valid_q && lq_q[head0_lq_idx].sq_unresolved_mask[m1_hold_sq_idx_q]) begin
                lsu_retire0_allow_o = 1'b0;
            end
            // 5. No violation targeting this load currently in flight in Stage M3
            if (m3_viol_valid_q && (m3_viol_rob_idx_q == rob_head_i)) begin
                lsu_retire0_allow_o = 1'b0;
            end
            // 6. Violated load never retires (triggers replay recovery)
            if (lq_q[head0_lq_idx].violated) begin
                lsu_retire0_allow_o = 1'b0;
            end
        end
    end

    // Retirement Lane 1 (Head Next)
    logic head1_lq_found;
    logic [3:0] head1_lq_idx;
    always_comb begin
        head1_lq_found = 1'b0;
        head1_lq_idx   = 4'd0;
        for (int l = 0; l < LQ_DEPTH; l++) begin
            if (lq_q[l].valid && (lq_q[l].rob_idx == rob_head_next_i)) begin
                head1_lq_found = 1'b1;
                head1_lq_idx   = 4'(l);
                break;
            end
        end
    end

    always_comb begin
        lsu_retire1_allow_o = 1'b1;
        if (head1_lq_found) begin
            // 1. Must have finished writeback/completion
            if (!lq_q[head1_lq_idx].wb_done && !lq_q[head1_lq_idx].completed) begin
                lsu_retire1_allow_o = 1'b0;
            end
            // 2. older_store_checks_complete(load)
            if (lq_q[head1_lq_idx].sq_unresolved_mask != 16'd0) begin
                lsu_retire1_allow_o = 1'b0;
            end
            // 3. No store check targeting this load currently in Stage M2 CAM
            if (m2_valid_q && lq_q[head1_lq_idx].sq_unresolved_mask[m2_sq_idx_q]) begin
                lsu_retire1_allow_o = 1'b0;
            end
            // 4. No store check targeting this load currently in Stage M1 hold
            if (m1_hold_valid_q && lq_q[head1_lq_idx].sq_unresolved_mask[m1_hold_sq_idx_q]) begin
                lsu_retire1_allow_o = 1'b0;
            end
            // 5. No violation targeting this load currently in flight in Stage M3
            if (m3_viol_valid_q && (m3_viol_rob_idx_q == rob_head_next_i)) begin
                lsu_retire1_allow_o = 1'b0;
            end
            // 6. Violated load never retires (triggers replay recovery)
            if (lq_q[head1_lq_idx].violated) begin
                lsu_retire1_allow_o = 1'b0;
            end
        end
    end


    wire store0_retiring = retire_valid_i[0] && retire0_sq_found && !sq_q[retire0_sq_slot].is_sc && !sq_q[retire0_sq_slot].is_fence;
    wire store1_retiring = retire_valid_i[1] && retire1_sq_found && !sq_q[retire1_sq_slot].is_sc && !sq_q[retire1_sq_slot].is_fence;
    wire store_draining  = l1d_store_drain_valid_o && !sq_q[sq_drain_head_q].is_sc && !sq_q[sq_drain_head_q].is_fence;

    // =========================================================================
    // 5. Port 2 Completion Arbitrer (Loads & Bifurcated Stores)
    // =========================================================================
    // Priority: Exceptional Store > Forwarded Load > Cache/Refill Load > Normal Store
    logic        p2_comp_valid;
    rob_idx_t    p2_comp_rob_idx;
    rob_epoch_t  p2_comp_epoch;
    preg_t       p2_comp_preg;
    logic        p2_comp_exception;
    logic [4:0]  p2_comp_cause;
    logic [63:0] p2_comp_data;
    lq_idx_t     p2_cleared_lq_idx;
    sq_idx_t     p2_cleared_sq_idx;
    logic        p2_clear_lq, p2_clear_sq;

    logic        sc_ok;
    logic        has_conflicting_store;

    always_comb begin
        p2_comp_valid         = 1'b0;
        p2_comp_rob_idx       = '0;
        p2_comp_epoch         = '0;
        p2_comp_preg          = '0;
        p2_comp_exception     = 1'b0;
        p2_comp_cause         = 5'd0;
        p2_comp_data          = 64'd0;
        p2_cleared_lq_idx     = '0;
        p2_cleared_sq_idx     = '0;
        p2_clear_lq           = 1'b0;
        p2_clear_sq           = 1'b0;
        sc_ok                 = 1'b0;
        has_conflicting_store = 1'b0;

        // Path 1: Exceptional Store (Bifurcated Immediate Completion, Section 5.2)
        // Faulting stores complete IMMEDIATELY to ROB without waiting for data!
        for (int s = 0; s < SQ_DEPTH; s++) begin
            if (sq_q[s].valid && sq_q[s].exception_pending && !sq_q[s].completed) begin
                p2_comp_valid     = 1'b1;
                p2_comp_rob_idx   = sq_q[s].rob_idx;
                p2_comp_epoch     = sq_q[s].rob_epoch;
                p2_comp_preg      = 7'd0;
                p2_comp_exception = 1'b1;
                p2_comp_cause     = sq_q[s].exc_cause;
                p2_comp_data      = 64'd0;
                p2_cleared_sq_idx = 4'(s);
                p2_clear_sq       = 1'b1;
                break;
            end
        end

        // Path 2: Misaligned / Exceptional Load
        if (!p2_comp_valid) begin
            for (int l = 0; l < LQ_DEPTH; l++) begin
                if (lq_q[l].valid && (lq_q[l].align_fault || lq_q[l].page_fault || lq_q[l].access_fault) && !lq_q[l].completed) begin
                    p2_comp_valid     = 1'b1;
                    p2_comp_rob_idx   = lq_q[l].rob_idx;
                    p2_comp_epoch     = lq_q[l].rob_epoch;
                    p2_comp_preg      = lq_q[l].pnew;
                    p2_comp_exception = 1'b1;
                    p2_comp_cause     = lq_q[l].align_fault ? 5'd4 : (lq_q[l].page_fault ? 5'd13 : 5'd5);
                    p2_comp_data      = 64'd0; // Faulting loads do NOT write PRF (Section 3.2)
                    p2_cleared_lq_idx = 4'(l);
                    p2_clear_lq       = 1'b1;
                    break;
                end
            end
        end

        // Path 3: Store-to-Load Forwarding Completion (1-cycle hit)
        if (!p2_comp_valid && disambig_lq_valid && fwd_success) begin
            p2_comp_valid     = 1'b1;
            p2_comp_rob_idx   = lq_q[disambig_lq_idx].rob_idx;
            p2_comp_epoch     = lq_q[disambig_lq_idx].rob_epoch;
            p2_comp_preg      = lq_q[disambig_lq_idx].pnew;
            p2_comp_exception = 1'b0;
            p2_comp_cause     = 5'd0;
            p2_comp_data      = fwd_data;
            p2_cleared_lq_idx = disambig_lq_idx;
            p2_clear_lq       = 1'b1;
        end

        // Path 4: Completed L1D Hit / Refill Load
        if (!p2_comp_valid) begin
            for (int l = 0; l < LQ_DEPTH; l++) begin
                if (lq_q[l].valid && lq_q[l].completed && !lq_q[l].wb_done && !lq_q[l].align_fault) begin
                    p2_comp_valid     = 1'b1;
                    p2_comp_rob_idx   = lq_q[l].rob_idx;
                    p2_comp_epoch     = lq_q[l].rob_epoch;
                    p2_comp_preg      = lq_q[l].pnew;
                    p2_comp_exception = 1'b0;
                    p2_comp_cause     = 5'd0;
                    p2_comp_data      = lq_q[l].result_data;
                    p2_cleared_lq_idx = 4'(l);
                    p2_clear_lq       = 1'b1;
                    break;
                end
            end
        end

        // Path 5: Successful Normal Store Completion (Section 5.2)
        // store_success_complete = pa_valid && data_valid && !exception_pending
        if (!p2_comp_valid) begin
            for (int s = 0; s < SQ_DEPTH; s++) begin
                if (sq_q[s].valid && sq_q[s].pa_valid && sq_q[s].data_valid &&
                    !sq_q[s].exception_pending && !sq_q[s].completed) begin
                    if (sq_q[s].is_fence && ((sq_drain_head_q != 4'(s)) || !l1d_quiescent_i)) begin
                        continue;
                    end
                    if (sq_q[s].is_sc && (sq_q[s].rob_idx != rob_head_i)) begin
                        continue;
                    end
                    if (sq_q[s].is_amo && ((sq_drain_head_q != 4'(s)) || (sq_q[s].rob_idx != rob_head_i))) begin
                        continue;
                    end
                    p2_comp_valid     = 1'b1;
                    p2_comp_rob_idx   = sq_q[s].rob_idx;
                    p2_comp_epoch     = sq_q[s].rob_epoch;
                    p2_comp_exception = 1'b0;
                    p2_comp_cause     = 5'd0;
                    p2_cleared_sq_idx = 4'(s);
                    p2_clear_sq       = 1'b1;
                    if (sq_q[s].is_sc) begin
                        has_conflicting_store = 1'b0;
                        for (int os = 0; os < SQ_DEPTH; os++) begin
                            if (sq_q[os].valid && (4'(os) != 4'(s)) && !sq_q[os].is_sc && !sq_q[os].is_fence) begin
                                if (rob_dist(sq_q[os].rob_idx, rob_head_i) < rob_dist(sq_q[s].rob_idx, rob_head_i)) begin
                                    has_conflicting_store = 1'b1;
                                end
                            end
                        end

                        sc_ok = res_valid_q && !has_conflicting_store &&
                                (res_pa_q == sq_q[s].pa) && (res_size_q == sq_q[s].size);
                        p2_comp_preg = sq_q[s].pnew;
                        p2_comp_data = sc_ok ? 64'd0 : 64'd1;
                    end else if (sq_q[s].is_amo) begin
                        p2_comp_preg = sq_q[s].pnew;
                        p2_comp_data = 64'd100;
                    end else begin
                        p2_comp_preg = 7'd0; // Stores have no PRF destination
                        p2_comp_data = 64'd0;
                    end
                    break;
                end
            end
        end
    end

    assign comp_valid_o     = p2_comp_valid && !flush_valid_i;
    assign comp_rob_idx_o   = p2_comp_rob_idx;
    assign comp_epoch_o     = p2_comp_epoch;
    assign comp_preg_o      = p2_comp_preg;
    assign comp_exception_o = p2_comp_exception;
    assign comp_cause_o     = p2_comp_cause;
    assign wb_data_o        = p2_comp_data;

    // (Retirement matching block moved to section above)

    // =========================================================================
    // 6. Sequential State Updates
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int i = 0; i < LQ_DEPTH; i++) lq_q[i] <= '0;
            for (int i = 0; i < SQ_DEPTH; i++) sq_q[i] <= '0;
            sq_drain_head_q   <= '0;
            sq_tail_q         <= '0;
            dtlb_miss_alloc_o <= 1'b0;
            res_valid_q       <= 1'b0;
            res_pa_q          <= '0;
            res_size_q        <= MEM_SIZE_BYTE;
            m1_hold_valid_q   <= 1'b0;
            m1_hold_sq_idx_q  <= '0;
            m1_hold_pa_q      <= '0;
            m1_hold_mask_q    <= '0;
            m1_hold_rob_idx_q <= '0;
            m1_hold_rob_epoch_q <= '0;
            m2_valid_q        <= 1'b0;
            m2_sq_idx_q       <= '0;
            m2_pa_q           <= '0;
            m2_mask_q         <= '0;
            m2_rob_idx_q      <= '0;
            m2_rob_epoch_q    <= '0;
            m3_viol_valid_q   <= 1'b0;
            m3_viol_rob_idx_q <= '0;
            m3_viol_rob_epoch_q <= '0;
        end else begin
            dtlb_miss_alloc_o <= 1'b0;

            // -----------------------------------------------------------------
            // A. Asynchronous Store Data Capture (PRF R5 & WB Snoop)
            // -----------------------------------------------------------------
            for (int s = 0; s < SQ_DEPTH; s++) begin
                if (sq_q[s].valid && !sq_q[s].data_valid) begin
                    // Match against active writebacks
                    if (wb0_valid_i && wb0_comp_ack_i && (wb0_pnew_i == sq_q[s].prs2) && (wb0_pnew_i != 7'd0)) begin
                        sq_q[s].data       <= wb0_data_i;
                        sq_q[s].data_valid <= 1'b1;
                    end else if (wb1_valid_i && wb1_comp_ack_i && (wb1_pnew_i == sq_q[s].prs2) && (wb1_pnew_i != 7'd0)) begin
                        sq_q[s].data       <= wb1_data_i;
                        sq_q[s].data_valid <= 1'b1;
                    end else if (wb2_valid_i && wb2_comp_ack_i && !wb2_comp_exception_i && (wb2_pnew_i == sq_q[s].prs2) && (wb2_pnew_i != 7'd0)) begin
                        sq_q[s].data       <= wb2_data_i;
                        sq_q[s].data_valid <= 1'b1;
                    end
                end
            end

            // -----------------------------------------------------------------
            // B. AGU Address Delivery & DTLB Query Handling
            // -----------------------------------------------------------------
            if (agu_valid_i && !flush_valid_i) begin
                if (agu_is_store_i) begin
                    sq_q[agu_sq_idx_i].va          <= agu_va_i;
                    sq_q[agu_sq_idx_i].mask        <= agu_byte_mask_i;
                    sq_q[agu_sq_idx_i].align_fault <= agu_align_fault_i;
                    if (agu_align_fault_i) begin
                        sq_q[agu_sq_idx_i].exception_pending <= 1'b1;
                        sq_q[agu_sq_idx_i].exc_cause         <= agu_exc_cause_i;
                        sq_q[agu_sq_idx_i].pa_valid          <= 1'b1;
                    end else if (dtlb_hit_i) begin
                        sq_q[agu_sq_idx_i].pa        <= dtlb_pa_i;
                        sq_q[agu_sq_idx_i].pa_valid  <= 1'b1;
                        sq_q[agu_sq_idx_i].is_mmio   <= !is_dram_pa(dtlb_pa_i);
                        if (dtlb_page_fault_i || dtlb_access_fault_i) begin
                            sq_q[agu_sq_idx_i].exception_pending <= 1'b1;
                            sq_q[agu_sq_idx_i].exc_cause         <= dtlb_page_fault_i ? 5'd15 : 5'd7;
                        end
                    end else begin
                        // DTLB Miss: Request TRT Allocation
                        sq_q[agu_sq_idx_i].wait_translation <= 1'b1;
                        sq_q[agu_sq_idx_i].tr_id            <= trt_assigned_tr_id_i;
                        dtlb_miss_alloc_o    <= 1'b1;
                        dtlb_miss_is_store_o <= 1'b1;
                        dtlb_miss_q_idx_o    <= agu_sq_idx_i;
                        dtlb_miss_vpn_o      <= agu_va_i[38:12];
                        dtlb_miss_rob_idx_o  <= sq_q[agu_sq_idx_i].rob_idx;
                        dtlb_miss_rob_epoch_o<= sq_q[agu_sq_idx_i].rob_epoch;
                    end
                end else begin
                    // Load
                    lq_q[agu_lq_idx_i].va          <= agu_va_i;
                    lq_q[agu_lq_idx_i].align_fault <= agu_align_fault_i;
                    if (agu_align_fault_i) begin
                        lq_q[agu_lq_idx_i].pa_valid  <= 1'b1;
                    end else if (dtlb_hit_i) begin
                        lq_q[agu_lq_idx_i].pa        <= dtlb_pa_i;
                        lq_q[agu_lq_idx_i].pa_valid  <= 1'b1;
                        lq_q[agu_lq_idx_i].page_fault<= dtlb_page_fault_i;
                        lq_q[agu_lq_idx_i].access_fault<= dtlb_access_fault_i;
                        lq_q[agu_lq_idx_i].is_mmio   <= !is_dram_pa(dtlb_pa_i);
                    end else begin
                        // DTLB Miss
                        lq_q[agu_lq_idx_i].wait_translation <= 1'b1;
                        lq_q[agu_lq_idx_i].tr_id            <= trt_assigned_tr_id_i;
                        dtlb_miss_alloc_o    <= 1'b1;
                        dtlb_miss_is_store_o <= 1'b0;
                        dtlb_miss_q_idx_o    <= agu_lq_idx_i;
                        dtlb_miss_vpn_o      <= agu_va_i[38:12];
                        dtlb_miss_rob_idx_o  <= lq_q[agu_lq_idx_i].rob_idx;
                        dtlb_miss_rob_epoch_o<= lq_q[agu_lq_idx_i].rob_epoch;
                    end
                end
            end

            // -----------------------------------------------------------------
            // C. TRT Translation Delivery (Asynchronous PTW Response)
            // -----------------------------------------------------------------
            if (trt_delivery_valid_i) begin
                if (trt_delivery_is_store_i) begin
                    sq_q[trt_delivery_q_idx_i].pa               <= trt_delivery_pa_i;
                    sq_q[trt_delivery_q_idx_i].pa_valid         <= 1'b1;
                    sq_q[trt_delivery_q_idx_i].wait_translation <= 1'b0;
                    sq_q[trt_delivery_q_idx_i].is_mmio          <= !is_dram_pa(trt_delivery_pa_i);
                    if (trt_delivery_page_fault_i || trt_delivery_access_fault_i) begin
                        sq_q[trt_delivery_q_idx_i].exception_pending <= 1'b1;
                        sq_q[trt_delivery_q_idx_i].exc_cause         <= trt_delivery_page_fault_i ? 5'd15 : 5'd7;
                    end
                end else begin
                    lq_q[trt_delivery_q_idx_i].pa               <= trt_delivery_pa_i;
                    lq_q[trt_delivery_q_idx_i].pa_valid         <= 1'b1;
                    lq_q[trt_delivery_q_idx_i].wait_translation <= 1'b0;
                    lq_q[trt_delivery_q_idx_i].page_fault       <= trt_delivery_page_fault_i;
                    lq_q[trt_delivery_q_idx_i].access_fault     <= trt_delivery_access_fault_i;
                    lq_q[trt_delivery_q_idx_i].is_mmio          <= !is_dram_pa(trt_delivery_pa_i);
                end
            end

            // -----------------------------------------------------------------
            // D. L1D Speculative Load Issue Response & MSHR Refill Capture
            // -----------------------------------------------------------------
            if (l1d_issue_fire) begin
                lq_q[disambig_lq_idx].issued_to_l1d      <= 1'b1;
                lq_q[disambig_lq_idx].is_speculative     <= selected_is_speculative;
                lq_q[disambig_lq_idx].sq_unresolved_mask <= selected_unresolved_stores;
            end

            if (l1d_load_rsp_valid_i) begin
                if (l1d_load_rsp_hit_i) begin
                    lq_q[l1d_load_rsp_lq_idx_i].completed   <= 1'b1;
                    lq_q[l1d_load_rsp_lq_idx_i].result_data <= l1d_load_rsp_data_i;
                end else begin
                    lq_q[l1d_load_rsp_lq_idx_i].mshr_id <= l1d_load_rsp_mshr_id_i;
                end
            end

            if (mshr_refill_valid_i) begin
                lq_q[mshr_refill_lq_idx_i].completed   <= 1'b1;
                lq_q[mshr_refill_lq_idx_i].result_data <= mshr_refill_data_i;
            end

            // -----------------------------------------------------------------
            // E. Store-to-Load Forwarding Hit (1 Cycle)
            // -----------------------------------------------------------------
            if (disambig_lq_valid && fwd_success) begin
                lq_q[disambig_lq_idx].completed          <= 1'b1;
                lq_q[disambig_lq_idx].forwarded          <= 1'b1;
                lq_q[disambig_lq_idx].forward_data       <= fwd_data;
                lq_q[disambig_lq_idx].result_data        <= fwd_data;
                lq_q[disambig_lq_idx].wb_done            <= 1'b1;
                lq_q[disambig_lq_idx].is_speculative     <= selected_is_speculative;
                lq_q[disambig_lq_idx].sq_unresolved_mask <= selected_unresolved_stores;
            end

            // -----------------------------------------------------------------
            // F. In-Order Store Retirement at ROB Head (Section 5.2)
            // -----------------------------------------------------------------
            // When store is at ROB head and retires, mark committed <= 1
            if (retire_valid_i[0] && retire0_sq_found) begin
                sq_q[retire0_sq_slot].committed <= 1'b1;
            end
            if (retire_valid_i[1] && retire1_sq_found) begin
                sq_q[retire1_sq_slot].committed <= 1'b1;
            end

            // Milestone 5 Phase B1: Architectural Load Deallocation at Commit (Section 6.2)
            if (retire_valid_i[0] && retire0_lq_found) begin
                lq_q[retire0_lq_slot].valid <= 1'b0;
            end
            if (retire_valid_i[1] && retire1_lq_found) begin
                lq_q[retire1_lq_slot].valid <= 1'b0;
            end

            // -----------------------------------------------------------------
            // G. Committed Store Drain Deallocation
            // -----------------------------------------------------------------
            if (sq_head_committed && sq_q[sq_drain_head_q].is_sc && !sq_q[sq_drain_head_q].sc_success) begin
                sq_q[sq_drain_head_q].valid   <= 1'b0;
                sq_q[sq_drain_head_q].drained <= 1'b1;
                sq_drain_head_q <= sq_drain_head_q + 4'd1;
            end else if (sq_head_committed && sq_q[sq_drain_head_q].is_fence) begin
                if (l1d_quiescent_i) begin
                    sq_q[sq_drain_head_q].valid   <= 1'b0;
                    sq_q[sq_drain_head_q].drained <= 1'b1;
                    sq_drain_head_q <= sq_drain_head_q + 4'd1;
                end
            end else if (l1d_store_drain_valid_o && l1d_store_drain_done_i) begin
                sq_q[sq_drain_head_q].valid   <= 1'b0;
                sq_q[sq_drain_head_q].drained <= 1'b1;
                sq_drain_head_q <= sq_drain_head_q + 4'd1;
            end

            // -----------------------------------------------------------------
            // H. Port 2 Completion Handshake & LR/SC Invalidation
            // -----------------------------------------------------------------
            if (flush_valid_i) begin
                res_valid_q <= 1'b0;
            end else begin
                // Invalidation on regular store retiring/draining or SC completion
                if (store0_retiring || store1_retiring || store_draining ||
                    (p2_comp_valid && comp_ack_i && p2_clear_sq && sq_q[p2_cleared_sq_idx].is_sc)) begin
                    res_valid_q <= 1'b0;
                end else if (p2_comp_valid && comp_ack_i && p2_clear_lq &&
                             ((lq_q[p2_cleared_lq_idx].sub_op == MEM_LR_W) || (lq_q[p2_cleared_lq_idx].sub_op == MEM_LR_D))) begin
                    res_valid_q <= 1'b1;
                    res_pa_q    <= lq_q[p2_cleared_lq_idx].pa;
                    res_size_q  <= lq_q[p2_cleared_lq_idx].size;
                end

                if (p2_comp_valid && comp_ack_i) begin
                    if (p2_clear_lq) begin
                        lq_q[p2_cleared_lq_idx].wb_done <= 1'b1;
                    end
                    if (p2_clear_sq) begin
                        sq_q[p2_cleared_sq_idx].completed <= 1'b1;
                        if (sq_q[p2_cleared_sq_idx].is_sc) begin
                            sq_q[p2_cleared_sq_idx].sc_success <= sc_ok;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            // I. Branch Recovery Squash (Section 5.4)
            // -----------------------------------------------------------------
            if (recover_valid_i) begin
                // Squash younger loads
                for (int l = 0; l < LQ_DEPTH; l++) begin
                    if (lq_q[l].valid) begin
                        if (rob_dist(lq_q[l].rob_idx, rob_head_i) >
                            rob_dist(recover_rob_idx_i, rob_head_i)) begin
                            lq_q[l].valid <= 1'b0;
                        end
                    end
                end

                // Squash younger uncommitted stores
                for (int s = 0; s < SQ_DEPTH; s++) begin
                    if (sq_q[s].valid && !sq_q[s].committed) begin
                        if (rob_dist(sq_q[s].rob_idx, rob_head_i) >
                            rob_dist(recover_rob_idx_i, rob_head_i)) begin
                            sq_q[s].valid <= 1'b0;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            // J. Full Architectural Flush Protocol (Section 5.4)
            // -----------------------------------------------------------------
            if (flush_valid_i) begin
                for (int l = 0; l < LQ_DEPTH; l++) lq_q[l].valid <= 1'b0;
                // Uncommitted stores are wiped; committed stores PERSIST!
                for (int s = 0; s < SQ_DEPTH; s++) begin
                    if (!sq_q[s].committed) begin
                        sq_q[s].valid <= 1'b0;
                    end
                end
            end

            // -----------------------------------------------------------------
            // K. SQ Deallocation Clearing in all surviving LQ entries (Section 5.1)
            // -----------------------------------------------------------------
            for (int l = 0; l < LQ_DEPTH; l++) begin
                if (lq_q[l].valid) begin
                    for (int s = 0; s < SQ_DEPTH; s++) begin
                        if (sq_dealloc_comb[s]) begin
                            lq_q[l].sq_older_mask[s]      <= 1'b0;
                            lq_q[l].sq_unresolved_mask[s] <= 1'b0;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            // L. New Allocations (Overrides squashes on newly allocated slot)
            // -----------------------------------------------------------------
            if (lq_alloc0_fire) begin
                lq_q[lq_slot0].valid            <= 1'b1;
                lq_q[lq_slot0].sub_op           <= uop0_subop_i;
                lq_q[lq_slot0].size             <= uop0_size_i;
                lq_q[lq_slot0].sign_ext         <= uop0_sign_ext_i;
                lq_q[lq_slot0].pnew             <= uop0_pnew_i;
                lq_q[lq_slot0].rob_idx          <= uop0_rob_idx_i;
                lq_q[lq_slot0].rob_epoch        <= uop0_rob_epoch_i;
                lq_q[lq_slot0].pc               <= uop0_pc_i;
                lq_q[lq_slot0].pa_valid         <= 1'b0;
                lq_q[lq_slot0].wait_translation <= 1'b0;
                lq_q[lq_slot0].sq_older_mask    <= lq0_initial_sq_mask;
                lq_q[lq_slot0].sq_unresolved_mask <= 16'd0;
                lq_q[lq_slot0].is_speculative   <= 1'b0;
                lq_q[lq_slot0].replay_safe      <= uop0_replay_safe_i;
                lq_q[lq_slot0].violated         <= 1'b0;
                lq_q[lq_slot0].wb_done          <= 1'b0;
                lq_q[lq_slot0].is_mmio          <= 1'b0;
                lq_q[lq_slot0].is_lr            <= (uop0_subop_i == MEM_LR_W) || (uop0_subop_i == MEM_LR_D);
                lq_q[lq_slot0].align_fault      <= 1'b0;
                lq_q[lq_slot0].page_fault       <= 1'b0;
                lq_q[lq_slot0].access_fault     <= 1'b0;
                lq_q[lq_slot0].issued_to_l1d    <= 1'b0;
                lq_q[lq_slot0].forwarded        <= 1'b0;
                lq_q[lq_slot0].completed        <= 1'b0;
            end

            if (lq_alloc1_fire) begin
                lq_q[lq_target_slot1].valid            <= 1'b1;
                lq_q[lq_target_slot1].sub_op           <= uop1_subop_i;
                lq_q[lq_target_slot1].size             <= uop1_size_i;
                lq_q[lq_target_slot1].sign_ext         <= uop1_sign_ext_i;
                lq_q[lq_target_slot1].pnew             <= uop1_pnew_i;
                lq_q[lq_target_slot1].rob_idx          <= uop1_rob_idx_i;
                lq_q[lq_target_slot1].rob_epoch        <= uop1_rob_epoch_i;
                lq_q[lq_target_slot1].pc               <= uop1_pc_i;
                lq_q[lq_target_slot1].pa_valid         <= 1'b0;
                lq_q[lq_target_slot1].wait_translation <= 1'b0;
                lq_q[lq_target_slot1].sq_older_mask    <= lq1_initial_sq_mask;
                lq_q[lq_target_slot1].sq_unresolved_mask <= 16'd0;
                lq_q[lq_target_slot1].is_speculative   <= 1'b0;
                lq_q[lq_target_slot1].replay_safe      <= uop1_replay_safe_i;
                lq_q[lq_target_slot1].violated         <= 1'b0;
                lq_q[lq_target_slot1].wb_done          <= 1'b0;
                lq_q[lq_target_slot1].is_mmio          <= 1'b0;
                lq_q[lq_target_slot1].is_lr            <= (uop1_subop_i == MEM_LR_W) || (uop1_subop_i == MEM_LR_D);
                lq_q[lq_target_slot1].align_fault      <= 1'b0;
                lq_q[lq_target_slot1].page_fault       <= 1'b0;
                lq_q[lq_target_slot1].access_fault     <= 1'b0;
                lq_q[lq_target_slot1].issued_to_l1d    <= 1'b0;
                lq_q[lq_target_slot1].forwarded        <= 1'b0;
                lq_q[lq_target_slot1].completed        <= 1'b0;
            end

            if (sq_alloc0_fire) begin
                sq_q[sq_slot0].valid            <= 1'b1;
                sq_q[sq_slot0].sub_op           <= uop0_subop_i;
                sq_q[sq_slot0].size             <= uop0_size_i;
                sq_q[sq_slot0].rob_idx          <= uop0_rob_idx_i;
                sq_q[sq_slot0].rob_epoch        <= uop0_rob_epoch_i;
                sq_q[sq_slot0].pc               <= uop0_pc_i;
                sq_q[sq_slot0].pa_valid         <= 1'b0;
                sq_q[sq_slot0].wait_translation <= 1'b0;
                sq_q[sq_slot0].prs2             <= uop0_prs2_i;
                sq_q[sq_slot0].pnew             <= uop0_pnew_i;
                sq_q[sq_slot0].is_sc            <= (uop0_subop_i == MEM_SC_W) || (uop0_subop_i == MEM_SC_D);
                sq_q[sq_slot0].is_amo           <= (uop0_class_i == UOP_AMO);
                sq_q[sq_slot0].is_fence         <= (uop0_class_i == UOP_FENCE);
                sq_q[sq_slot0].is_mmio          <= 1'b0;
                sq_q[sq_slot0].sc_success       <= 1'b0;
                sq_q[sq_slot0].align_fault      <= 1'b0;
                sq_q[sq_slot0].page_fault       <= 1'b0;
                sq_q[sq_slot0].access_fault     <= 1'b0;
                sq_q[sq_slot0].exception_pending<= 1'b0;
                sq_q[sq_slot0].completed        <= 1'b0;
                sq_q[sq_slot0].committed        <= 1'b0;
                sq_q[sq_slot0].drained          <= 1'b0;

                if (uop0_class_i == UOP_FENCE) begin
                    sq_q[sq_slot0].pa_valid   <= 1'b1;
                    sq_q[sq_slot0].data_valid <= 1'b1;
                    sq_q[sq_slot0].mask       <= 8'd0;
                    sq_q[sq_slot0].pa         <= 56'd0;
                    sq_q[sq_slot0].va         <= 64'd0;
                    sq_q[sq_slot0].data       <= 64'd0;
                end else begin
                    sq_q[sq_slot0].mask       <= 8'd0;
                    // Data capture if ready at dispatch or matching same-cycle writeback
                    if (uop0_prs2_ready_i) begin
                        sq_q[sq_slot0].data       <= prf_r5_data_i;
                        sq_q[sq_slot0].data_valid <= 1'b1;
                    end else if (wb0_valid_i && wb0_comp_ack_i && (wb0_pnew_i == uop0_prs2_i) && (wb0_pnew_i != 7'd0)) begin
                        sq_q[sq_slot0].data       <= wb0_data_i;
                        sq_q[sq_slot0].data_valid <= 1'b1;
                    end else if (wb1_valid_i && wb1_comp_ack_i && (wb1_pnew_i == uop0_prs2_i) && (wb1_pnew_i != 7'd0)) begin
                        sq_q[sq_slot0].data       <= wb1_data_i;
                        sq_q[sq_slot0].data_valid <= 1'b1;
                    end else if (wb2_valid_i && wb2_comp_ack_i && !wb2_comp_exception_i && (wb2_pnew_i == uop0_prs2_i) && (wb2_pnew_i != 7'd0)) begin
                        sq_q[sq_slot0].data       <= wb2_data_i;
                        sq_q[sq_slot0].data_valid <= 1'b1;
                    end else begin
                        sq_q[sq_slot0].data_valid <= 1'b0;
                    end
                end
            end

            if (sq_alloc1_fire) begin
                sq_q[sq_target_slot1].valid            <= 1'b1;
                sq_q[sq_target_slot1].sub_op           <= uop1_subop_i;
                sq_q[sq_target_slot1].size             <= uop1_size_i;
                sq_q[sq_target_slot1].rob_idx          <= uop1_rob_idx_i;
                sq_q[sq_target_slot1].rob_epoch        <= uop1_rob_epoch_i;
                sq_q[sq_target_slot1].pc               <= uop1_pc_i;
                sq_q[sq_target_slot1].pa_valid         <= 1'b0;
                sq_q[sq_target_slot1].wait_translation <= 1'b0;
                sq_q[sq_target_slot1].prs2             <= uop1_prs2_i;
                sq_q[sq_target_slot1].pnew             <= uop1_pnew_i;
                sq_q[sq_target_slot1].is_sc            <= (uop1_subop_i == MEM_SC_W) || (uop1_subop_i == MEM_SC_D);
                sq_q[sq_target_slot1].is_amo           <= (uop1_class_i == UOP_AMO);
                sq_q[sq_target_slot1].is_fence         <= (uop1_class_i == UOP_FENCE);
                sq_q[sq_target_slot1].is_mmio          <= 1'b0;
                sq_q[sq_target_slot1].sc_success       <= 1'b0;
                sq_q[sq_target_slot1].align_fault      <= 1'b0;
                sq_q[sq_target_slot1].page_fault       <= 1'b0;
                sq_q[sq_target_slot1].access_fault     <= 1'b0;
                sq_q[sq_target_slot1].exception_pending<= 1'b0;
                sq_q[sq_target_slot1].completed        <= 1'b0;
                sq_q[sq_target_slot1].committed        <= 1'b0;
                sq_q[sq_target_slot1].drained          <= 1'b0;

                if (uop1_class_i == UOP_FENCE) begin
                    sq_q[sq_target_slot1].pa_valid   <= 1'b1;
                    sq_q[sq_target_slot1].data_valid <= 1'b1;
                    sq_q[sq_target_slot1].mask       <= 8'd0;
                    sq_q[sq_target_slot1].pa         <= 56'd0;
                    sq_q[sq_target_slot1].va         <= 64'd0;
                    sq_q[sq_target_slot1].data       <= 64'd0;
                end else begin
                    sq_q[sq_target_slot1].mask       <= 8'd0;
                    if (uop1_prs2_ready_i) begin
                        sq_q[sq_target_slot1].data       <= prf_r5_data_i;
                        sq_q[sq_target_slot1].data_valid <= 1'b1;
                    end else if (wb0_valid_i && wb0_comp_ack_i && (wb0_pnew_i == uop1_prs2_i) && (wb0_pnew_i != 7'd0)) begin
                        sq_q[sq_target_slot1].data       <= wb0_data_i;
                        sq_q[sq_target_slot1].data_valid <= 1'b1;
                    end else if (wb1_valid_i && wb1_comp_ack_i && (wb1_pnew_i == uop1_prs2_i) && (wb1_pnew_i != 7'd0)) begin
                        sq_q[sq_target_slot1].data       <= wb1_data_i;
                        sq_q[sq_target_slot1].data_valid <= 1'b1;
                    end else if (wb2_valid_i && wb2_comp_ack_i && !wb2_comp_exception_i && (wb2_pnew_i == uop1_prs2_i) && (wb2_pnew_i != 7'd0)) begin
                        sq_q[sq_target_slot1].data       <= wb2_data_i;
                        sq_q[sq_target_slot1].data_valid <= 1'b1;
                    end else begin
                        sq_q[sq_target_slot1].data_valid <= 1'b0;
                    end
                end
            end

            // SQ Tail Pointer Update
            if (flush_valid_i || recover_valid_i) begin
                sq_tail_q <= recovered_sq_tail;
            end else begin
                sq_tail_q <= sq_tail_q + {3'd0, sq_alloc0_fire} + {3'd0, sq_alloc1_fire};
            end

            // -----------------------------------------------------------------
            // M. Milestone 5 Phase B1: Pipelined Store Resolution CAM (Stages M1->M2->M3)
            // -----------------------------------------------------------------
            if (flush_valid_i) begin
                m1_hold_valid_q <= 1'b0;
                m2_valid_q      <= 1'b0;
                m3_viol_valid_q <= 1'b0;
            end else begin
                // Stage M3 Generation from Stage M2 CAM match
                if (m2_valid_q && viol_found) begin
                    m3_viol_valid_q     <= 1'b1;
                    m3_viol_rob_idx_q   <= lq_q[oldest_viol_lq].rob_idx;
                    m3_viol_rob_epoch_q <= lq_q[oldest_viol_lq].rob_epoch;
                end else begin
                    m3_viol_valid_q     <= 1'b0;
                end

                // Stage M2 CAM execution & clearing of evaluated store in LQ
                if (m2_valid_q) begin
                    for (int l = 0; l < LQ_DEPTH; l++) begin
                        if (lq_q[l].valid && lq_q[l].sq_unresolved_mask[m2_sq_idx_q]) begin
                            lq_q[l].sq_unresolved_mask[m2_sq_idx_q] <= 1'b0;
                        end
                        if (cam_match[l]) begin
                            lq_q[l].violated <= 1'b1;
                        end
                    end
                end

                // Stage M1 -> M2 Pipeline & Holding Register Transfer
                if (m1_hold_valid_q) begin
                    m2_valid_q          <= 1'b1;
                    m2_sq_idx_q         <= m1_hold_sq_idx_q;
                    m2_pa_q             <= m1_hold_pa_q;
                    m2_mask_q           <= m1_hold_mask_q;
                    m2_rob_idx_q        <= m1_hold_rob_idx_q;
                    m2_rob_epoch_q      <= m1_hold_rob_epoch_q;

                    if (agu_store_resolve) begin
                        m1_hold_valid_q     <= 1'b1;
                        m1_hold_sq_idx_q    <= agu_sq_idx_i;
                        m1_hold_pa_q        <= dtlb_pa_i;
                        m1_hold_mask_q      <= agu_byte_mask_i;
                        m1_hold_rob_idx_q   <= sq_q[agu_sq_idx_i].rob_idx;
                        m1_hold_rob_epoch_q <= sq_q[agu_sq_idx_i].rob_epoch;
                    end else if (trt_store_resolve) begin
                        m1_hold_valid_q     <= 1'b1;
                        m1_hold_sq_idx_q    <= trt_delivery_q_idx_i;
                        m1_hold_pa_q        <= trt_delivery_pa_i;
                        m1_hold_mask_q      <= sq_q[trt_delivery_q_idx_i].mask;
                        m1_hold_rob_idx_q   <= sq_q[trt_delivery_q_idx_i].rob_idx;
                        m1_hold_rob_epoch_q <= sq_q[trt_delivery_q_idx_i].rob_epoch;
                    end else begin
                        m1_hold_valid_q     <= 1'b0;
                    end
                end else begin
                    if (agu_store_resolve && trt_store_resolve) begin
                        m2_valid_q          <= 1'b1;
                        m2_sq_idx_q         <= agu_sq_idx_i;
                        m2_pa_q             <= dtlb_pa_i;
                        m2_mask_q           <= agu_byte_mask_i;
                        m2_rob_idx_q        <= sq_q[agu_sq_idx_i].rob_idx;
                        m2_rob_epoch_q      <= sq_q[agu_sq_idx_i].rob_epoch;

                        m1_hold_valid_q     <= 1'b1;
                        m1_hold_sq_idx_q    <= trt_delivery_q_idx_i;
                        m1_hold_pa_q        <= trt_delivery_pa_i;
                        m1_hold_mask_q      <= sq_q[trt_delivery_q_idx_i].mask;
                        m1_hold_rob_idx_q   <= sq_q[trt_delivery_q_idx_i].rob_idx;
                        m1_hold_rob_epoch_q <= sq_q[trt_delivery_q_idx_i].rob_epoch;
                    end else if (agu_store_resolve) begin
                        m2_valid_q          <= 1'b1;
                        m2_sq_idx_q         <= agu_sq_idx_i;
                        m2_pa_q             <= dtlb_pa_i;
                        m2_mask_q           <= agu_byte_mask_i;
                        m2_rob_idx_q        <= sq_q[agu_sq_idx_i].rob_idx;
                        m2_rob_epoch_q      <= sq_q[agu_sq_idx_i].rob_epoch;
                        m1_hold_valid_q     <= 1'b0;
                    end else if (trt_store_resolve) begin
                        m2_valid_q          <= 1'b1;
                        m2_sq_idx_q         <= trt_delivery_q_idx_i;
                        m2_pa_q             <= trt_delivery_pa_i;
                        m2_mask_q           <= sq_q[trt_delivery_q_idx_i].mask;
                        m2_rob_idx_q        <= sq_q[trt_delivery_q_idx_i].rob_idx;
                        m2_rob_epoch_q      <= sq_q[trt_delivery_q_idx_i].rob_epoch;
                        m1_hold_valid_q     <= 1'b0;
                    end else begin
                        m2_valid_q          <= 1'b0;
                        m1_hold_valid_q     <= 1'b0;
                    end
                end

                // Branch recovery squash qualification for in-flight store resolution pipeline
                if (recover_valid_i) begin
                    if (m1_hold_valid_q && (rob_dist(m1_hold_rob_idx_q, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        m1_hold_valid_q <= 1'b0;
                    end
                    if (m2_valid_q && (rob_dist(m2_rob_idx_q, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        m2_valid_q <= 1'b0;
                    end
                    if (m3_viol_valid_q && (rob_dist(m3_viol_rob_idx_q, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        m3_viol_valid_q <= 1'b0;
                    end
                end
            end
        end
    end

    // Combinational M2 CAM Overlap Detection Logic
    wire agu_store_resolve = agu_valid_i && !flush_valid_i && agu_is_store_i && !agu_align_fault_i && dtlb_hit_i && !dtlb_page_fault_i && !dtlb_access_fault_i;
    wire trt_store_resolve = trt_delivery_valid_i && !flush_valid_i && trt_delivery_is_store_i && !trt_delivery_page_fault_i && !trt_delivery_access_fault_i;

    logic [LQ_DEPTH-1:0] cam_match;
    always_comb begin
        for (int l = 0; l < LQ_DEPTH; l++) begin
            cam_match[l] = 1'b0;
            if (m2_valid_q && lq_q[l].valid && lq_q[l].is_speculative &&
                lq_q[l].sq_unresolved_mask[m2_sq_idx_q] &&
                (lq_q[l].issued_to_l1d || lq_q[l].forwarded || lq_q[l].completed) &&
                (rob_dist(m2_rob_idx_q, rob_head_i) < rob_dist(lq_q[l].rob_idx, rob_head_i))) begin

                // Physical byte overlap check:
                // Same 8B-aligned doubleword PA[55:3] AND non-zero byte mask bitwise AND
                if ((lq_q[l].pa[55:3] == m2_pa_q[55:3]) &&
                    ((get_byte_lane_mask(lq_q[l].pa[2:0], lq_q[l].size) & m2_mask_q) != 8'b0)) begin
                    cam_match[l] = 1'b1;
                end
            end
        end
    end

    logic [3:0] oldest_viol_lq;
    logic [5:0] min_viol_dist;
    logic       viol_found;
    logic [5:0] v_dist;
    always_comb begin
        oldest_viol_lq = 4'd0;
        min_viol_dist  = 6'd63;
        viol_found     = 1'b0;
        v_dist         = 6'd0;
        for (int l = 0; l < LQ_DEPTH; l++) begin
            if (cam_match[l]) begin
                v_dist = rob_dist(lq_q[l].rob_idx, rob_head_i);
                if (!viol_found || (v_dist < min_viol_dist)) begin
                    min_viol_dist  = v_dist;
                    oldest_viol_lq = 4'(l);
                    viol_found     = 1'b1;
                end
            end
        end
    end



`ifndef SYNTHESIS
    // Simulation Assertions (Section 17.3)
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            // Assertion 3: Stores must NEVER modify L1D cache before retirement
            if (l1d_store_drain_valid_o && !sq_q[sq_drain_head_q].committed) begin
                $fatal(1, "[LSU QUEUES ASSERTION FAILED] Uncommitted store attempted L1D drain!");
            end
            // Assertion 4: Loads must NEVER access memory while older store PA unresolved unless speculative
            if (l1d_issue_fire && (lq_q[disambig_lq_idx].replay_safe || lq_q[disambig_lq_idx].is_mmio || lq_q[disambig_lq_idx].is_lr)) begin
                for (int s = 0; s < SQ_DEPTH; s++) begin
                    if (lq_q[disambig_lq_idx].sq_older_mask[s] && !sq_q[s].pa_valid) begin
                        $fatal(1, "[LSU QUEUES ASSERTION FAILED] Ineligible/replay-safe load issued to L1D with older store PA unresolved!");
                    end
                end
            end
            // Assertion 5: Forwarding must NEVER occur on partial overlap
            if (disambig_lq_valid && fwd_success && fwd_stall) begin
                $fatal(1, "[LSU QUEUES ASSERTION FAILED] Forwarding occurred during partial overlap stall!");
            end
            // Assertion 10: Faulting stores must NEVER transition to committed
            for (int s = 0; s < SQ_DEPTH; s++) begin
                if (sq_q[s].valid && sq_q[s].exception_pending && sq_q[s].committed) begin
                    $fatal(1, "[LSU QUEUES ASSERTION FAILED] Faulting store committed!");
                end
            end

            // P0-3 Assertion: Failed SC must NEVER forward
            if (disambig_lq_valid && fwd_success && sq_q[youngest_s].is_sc && (!sq_q[youngest_s].completed || !sq_q[youngest_s].sc_success)) begin
                $fatal(1, "[LSU QUEUES ASSERTION FAILED] Failed or unresolved SC forwarded data to load!");
            end

            // P0-3 Assertion: Failed SC must NEVER drain to memory
            if (l1d_store_drain_valid_o && sq_q[sq_drain_head_q].is_sc && !sq_q[sq_drain_head_q].sc_success) begin
                $fatal(1, "[LSU QUEUES ASSERTION FAILED] Failed SC asserted store drain to L1D!");
            end

            // P0-2 Assertion: Store retirement must match exact ROB slot & epoch
            if (retire_valid_i[0] && retire0_sq_found) begin
                if (sq_q[retire0_sq_slot].rob_idx != retire_rob_idx_i[0] || sq_q[retire0_sq_slot].rob_epoch != retire_epoch_i[0]) begin
                    $fatal(1, "[LSU QUEUES ASSERTION FAILED] Store retirement matched wrong ROB slot/epoch!");
                end
            end
            if (retire_valid_i[1] && retire1_sq_found) begin
                if (sq_q[retire1_sq_slot].rob_idx != retire_rob_idx_i[1] || sq_q[retire1_sq_slot].rob_epoch != retire_epoch_i[1]) begin
                    $fatal(1, "[LSU QUEUES ASSERTION FAILED] Store retirement matched wrong ROB slot/epoch!");
                end
            end

            // P2-1 Assertion: Live load's older-mask cannot refer to newly allocated store slot
            if (sq_alloc0_fire) begin
                for (int l = 0; l < LQ_DEPTH; l++) begin
                    if (lq_q[l].valid && lq_q[l].sq_older_mask[sq_slot0]) begin
                        $fatal(1, "[LSU QUEUES ASSERTION FAILED] Live load older mask referred to newly allocated SQ slot %0d!", sq_slot0);
                    end
                end
            end
            if (sq_alloc1_fire) begin
                for (int l = 0; l < LQ_DEPTH; l++) begin
                    if (lq_q[l].valid && lq_q[l].sq_older_mask[sq_target_slot1]) begin
                        $fatal(1, "[LSU QUEUES ASSERTION FAILED] Live load older mask referred to newly allocated SQ slot %0d!", sq_target_slot1);
                    end
                end
            end
            // Milestone 5 Phase B1 Assertions (Rule 31)
            // Violated load never retires
            if (retire_valid_i[0] && retire0_lq_found && lq_q[retire0_lq_slot].violated) begin
                $fatal(1, "[B1_ASSERTION FAILED] Violated load retired at slot 0!");
            end
            if (retire_valid_i[1] && retire1_lq_found && lq_q[retire1_lq_slot].violated) begin
                $fatal(1, "[B1_ASSERTION FAILED] Violated load retired at slot 1!");
            end

            // Same-cycle violation dominates retirement (Lane 0 and Lane 1)
            if (retire_valid_i[0] && retire0_lq_found && m3_viol_valid_q && (m3_viol_rob_idx_q == retire_rob_idx_i[0])) begin
                $fatal(1, "[B1_ASSERTION FAILED] Same-cycle violation did not dominate retirement at slot 0!");
            end
            if (retire_valid_i[1] && retire1_lq_found && m3_viol_valid_q && (m3_viol_rob_idx_q == retire_rob_idx_i[1])) begin
                $fatal(1, "[B1_ASSERTION FAILED] Same-cycle violation did not dominate retirement at slot 1!");
            end

            // Speculative load retained while relevant store check unresolved (Lane 0 and Lane 1)
            if (retire_valid_i[0] && retire0_lq_found && (lq_q[retire0_lq_slot].sq_unresolved_mask != 16'd0)) begin
                $fatal(1, "[B1_ASSERTION FAILED] Load retired at slot 0 with unresolved store checks!");
            end
            if (retire_valid_i[1] && retire1_lq_found && (lq_q[retire1_lq_slot].sq_unresolved_mask != 16'd0)) begin
                $fatal(1, "[B1_ASSERTION FAILED] Load retired at slot 1 with unresolved store checks!");
            end

            // Retained speculative load cannot retire while relevant store check is still pending in M1 hold or M2 CAM
            if (retire_valid_i[0] && retire0_lq_found &&
                ((m2_valid_q && lq_q[retire0_lq_slot].sq_unresolved_mask[m2_sq_idx_q]) ||
                 (m1_hold_valid_q && lq_q[retire0_lq_slot].sq_unresolved_mask[m1_hold_sq_idx_q]))) begin
                $fatal(1, "[B1_ASSERTION FAILED] Slot 0 speculative load retired while store check in M1/M2!");
            end
            if (retire_valid_i[1] && retire1_lq_found &&
                ((m2_valid_q && lq_q[retire1_lq_slot].sq_unresolved_mask[m2_sq_idx_q]) ||
                 (m1_hold_valid_q && lq_q[retire1_lq_slot].sq_unresolved_mask[m1_hold_sq_idx_q]))) begin
                $fatal(1, "[B1_ASSERTION FAILED] Slot 1 speculative load retired while store check in M1/M2!");
            end

            // Replay-safe load cannot use unresolved-store speculative bypass
            if (l1d_issue_fire && lq_q[disambig_lq_idx].replay_safe && (lq_q[disambig_lq_idx].sq_unresolved_mask != 16'd0)) begin
                $fatal(1, "[B1_ASSERTION FAILED] Replay-safe load issued speculatively!");
            end

            // Non-speculative/MMIO/LR loads never set speculative-load marker
            if ((l1d_issue_fire || fwd_issue_fire) && (lq_q[disambig_lq_idx].is_mmio || lq_q[disambig_lq_idx].is_lr) && selected_is_speculative) begin
                $fatal(1, "[B1_ASSERTION FAILED] MMIO or LR load marked speculative!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_LSU_QUEUES_SV
