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
    output logic [4:0]        lq_count_o,
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
    // Milestone 8 Phase C FP Memory Extensions
    input  logic              uop0_is_fp_i,
    input  fpreg_t            uop0_prd_fp_i,
    input  fpreg_t            uop0_prs2_fp_i,
    input  logic              uop0_prs2_fp_ready_i,

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
    // Milestone 8 Phase C FP Memory Extensions
    input  logic              uop1_is_fp_i,
    input  fpreg_t            uop1_prd_fp_i,
    input  fpreg_t            uop1_prs2_fp_i,
    input  logic              uop1_prs2_fp_ready_i,

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

    // -------------------------------------------------------------------------
    // Port 3 AGU Address Generation Delivery Interface (Loads Strictly)
    // -------------------------------------------------------------------------
    input  logic              agu1_valid_i,
    input  lq_idx_t           agu1_lq_idx_i,
    input  logic [63:0]       agu1_va_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [7:0]        agu1_byte_mask_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic              agu1_align_fault_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [4:0]        agu1_exc_cause_i,
    /* verilator lint_on UNUSEDSIGNAL */

    // DTLB Translation Hit/Miss for Port 3
    input  logic              dtlb1_hit_i,
    input  logic [55:0]       dtlb1_pa_i,
    input  logic              dtlb1_page_fault_i,
    input  logic              dtlb1_access_fault_i,
    output logic              port3_busy_o,

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
    input  logic              wb3_valid_i,
    input  logic              wb3_comp_ack_i,
    input  logic              wb3_comp_exception_i,
    input  preg_t             wb3_pnew_i,
    input  logic [63:0]       wb3_data_i,

    // Milestone 8 Phase C FP Store Data & Writeback Snoop
    input  logic [63:0]       fprf_r3_data_i,
    input  logic              wb0_fp_valid_i,
    input  fpreg_t            wb0_fp_paddr_i,
    input  logic [63:0]       wb0_fp_data_i,

    // -------------------------------------------------------------------------
    // L1D Cache Interface
    // -------------------------------------------------------------------------
    // Speculative Load Issue to L1D — Port 0 (Lane 0)
    output logic              l1d_load0_req_valid_o,
    output lq_idx_t           l1d_load0_req_lq_idx_o,
    output logic [55:0]       l1d_load0_req_pa_o,
    output mem_size_t         l1d_load0_req_size_o,
    output logic              l1d_load0_req_sign_ext_o,
    output preg_t             l1d_load0_req_pnew_o,
    output rob_idx_t          l1d_load0_req_rob_idx_o,
    output rob_epoch_t        l1d_load0_req_rob_epoch_o,
    input  logic              l1d_load0_req_ready_i,

    input  logic              l1d_load0_rsp_valid_i,
    input  lq_idx_t           l1d_load0_rsp_lq_idx_i,
    input  logic              l1d_load0_rsp_hit_i,
    input  logic [63:0]       l1d_load0_rsp_data_i,
    input  mshr_idx_t         l1d_load0_rsp_mshr_id_i,

    // Speculative Load Issue to L1D — Port 1 (Lane 1)
    output logic              l1d_load1_req_valid_o,
    output lq_idx_t           l1d_load1_req_lq_idx_o,
    output logic [55:0]       l1d_load1_req_pa_o,
    output mem_size_t         l1d_load1_req_size_o,
    output logic              l1d_load1_req_sign_ext_o,
    output preg_t             l1d_load1_req_pnew_o,
    output rob_idx_t          l1d_load1_req_rob_idx_o,
    output rob_epoch_t        l1d_load1_req_rob_epoch_o,
    input  logic              l1d_load1_req_ready_i,

    input  logic              l1d_load1_rsp_valid_i,
    input  lq_idx_t           l1d_load1_rsp_lq_idx_i,
    input  logic              l1d_load1_rsp_hit_i,
    input  logic [63:0]       l1d_load1_rsp_data_i,
    input  mshr_idx_t         l1d_load1_rsp_mshr_id_i,

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

    // -------------------------------------------------------------------------
    // Port 3 Writeback & Completion Interface (to M1 Substrate & PRF W3)
    // -------------------------------------------------------------------------
    output logic              p3_comp_valid_o,
    output rob_idx_t          p3_comp_rob_idx_o,
    output rob_epoch_t        p3_comp_epoch_o,
    output preg_t             p3_comp_preg_o,
    output logic              p3_comp_exception_o,
    output logic [4:0]        p3_comp_cause_o,
    output logic [63:0]       p3_wb_data_o,
    input  logic              p3_comp_ack_i,

    // Milestone 8 Phase C Floating-Point Completion Outputs
    output logic              comp_is_fp_o,
    output fpreg_t            comp_prd_fp_o,
    output logic              p3_comp_is_fp_o,
    output fpreg_t            p3_comp_prd_fp_o,

    output logic              p2_fp_wb_valid_o,
    output fpreg_t            p2_fp_wb_paddr_o,
    output logic [63:0]       p2_fp_wb_data_o,

    output logic              p3_fp_wb_valid_o,
    output fpreg_t            p3_fp_wb_paddr_o,
    output logic [63:0]       p3_fp_wb_data_o,

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
    output logic              lsu_retire1_allow_o,

    // External Coherence Snoop Interface (Milestone 7 §8.3, PROP_M7_36)
    input  logic              snoop_req_valid_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [55:0]       snoop_req_addr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [1:0]        snoop_req_type_i,
    output logic              event_snoop_replay_o,

    // -------------------------------------------------------------------------
    // Dedicated Uncached MMIO Master Channel (§4.1)
    // -------------------------------------------------------------------------
    output logic              mmio_req_valid_o,
    output logic [63:0]       mmio_req_addr_o,
    output logic              mmio_req_is_store_o,
    output logic [2:0]        mmio_req_size_o,      // 0=1B, 1=2B, 2=4B, 3=8B
    output logic [63:0]       mmio_req_wdata_o,
    output logic [7:0]        mmio_req_wstrb_o,     // Byte enable mask
    input  logic              mmio_req_ready_i,

    input  logic              mmio_rsp_valid_i,
    input  logic [63:0]       mmio_rsp_rdata_i,
    input  logic              mmio_rsp_error_i,
    output logic              mmio_rsp_ready_o
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

    // Milestone 7 Dual-AGU: Port 3 DTLB Miss Retry Tracking
    logic        p3_dtlb_retry_q;
    lq_idx_t     p3_retry_lq_idx_q;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] p3_retry_va_q;
    logic [7:0]  p3_retry_byte_mask_q;
    /* verilator lint_on UNUSEDSIGNAL */

    assign port3_busy_o = p3_dtlb_retry_q;

    // External Coherence Snoop Hazard Evaluation (§8.3, PROP_M7_36)
    wire snoop_do_inv = (snoop_req_type_i[0] == 1'b1) || (snoop_req_type_i == 2'b00);
    wire [49:0] snoop_line_addr = snoop_req_addr_i[55:6];

    logic [LQ_DEPTH-1:0] snoop_lq_match;
    logic                snoop_match_found;
    lq_idx_t             oldest_snoop_viol_lq;

    always_comb begin
        snoop_match_found    = 1'b0;
        oldest_snoop_viol_lq = '0;
        for (int l = 0; l < LQ_DEPTH; l++) begin
            snoop_lq_match[l] = snoop_req_valid_i && snoop_do_inv &&
                                lq_q[l].valid && lq_q[l].pa_valid &&
                                (lq_q[l].pa[55:6] == snoop_line_addr) &&
                                (lq_q[l].completed || lq_q[l].wb_done || lq_q[l].forwarded);
            if (snoop_lq_match[l]) begin
                if (!snoop_match_found || (rob_dist(lq_q[l].rob_idx, rob_head_i) < rob_dist(lq_q[oldest_snoop_viol_lq].rob_idx, rob_head_i))) begin
                    oldest_snoop_viol_lq = lq_idx_t'(l);
                    snoop_match_found    = 1'b1;
                end
            end
        end
    end

    assign event_snoop_replay_o = snoop_match_found;

    wire snoop_viol_older_than_m3 = !m3_viol_valid_q ||
        (snoop_match_found && (rob_dist(lq_q[oldest_snoop_viol_lq].rob_idx, rob_head_i) < rob_dist(m3_viol_rob_idx_q, rob_head_i)));
    wire snoop_viol_wins = snoop_match_found && snoop_viol_older_than_m3;

    assign lsu_violation_valid_o     = snoop_viol_wins ? 1'b1 : m3_viol_valid_q;
    assign lsu_violation_rob_idx_o   = snoop_viol_wins ? lq_q[oldest_snoop_viol_lq].rob_idx   : m3_viol_rob_idx_q;
    assign lsu_violation_rob_epoch_o = snoop_viol_wins ? lq_q[oldest_snoop_viol_lq].rob_epoch : m3_viol_rob_epoch_q;

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
    assign lq_count_o       = 5'd16 - lq_free_count;
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
            end else if (sq_q[sq_drain_head_q].is_mmio && sq_q[sq_drain_head_q].drained) begin
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
    // 3. Dual-Lane Store-to-Load Forwarding & Dual Load Selection (§7.2, PROP_M7_22..24)
    // =========================================================================
    logic [LQ_DEPTH-1:0] lq_entry_ready;
    logic [LQ_DEPTH-1:0] lq_entry_fwd_success;
    logic [LQ_DEPTH-1:0] lq_entry_fwd_stall;
    logic [63:0]         lq_entry_fwd_data [LQ_DEPTH];
    logic [3:0]          lq_entry_youngest_s [LQ_DEPTH];
    logic [LQ_DEPTH-1:0] lq_entry_is_speculative;
    logic [15:0]         lq_entry_unres_stores [LQ_DEPTH];

    logic        all_older_pa_valid_l;
    logic        has_older_fence_l;
    logic        cand_is_eligible_spec_l;
    logic [15:0] overlap_mask_l;
    logic [7:0]  l_mask_l;
    logic        cand_fwd_stall_l;
    logic        youngest_found_l;
    logic [5:0]  min_s_dist_l;
    logic [3:0]  youngest_s_l;
    logic        same_word_s;
    logic        has_overlap_s;
    logic [5:0]  s_dist_val;
    logic [5:0]  l_dist_head;
    logic [63:0] raw_fwd_val;

    always_comb begin
        all_older_pa_valid_l    = 1'b0;
        has_older_fence_l       = 1'b0;
        cand_is_eligible_spec_l = 1'b0;
        overlap_mask_l          = 16'd0;
        l_mask_l                = 8'd0;
        cand_fwd_stall_l        = 1'b0;
        youngest_found_l        = 1'b0;
        min_s_dist_l            = 6'd63;
        youngest_s_l            = 4'd0;
        same_word_s             = 1'b0;
        has_overlap_s           = 1'b0;
        s_dist_val              = 6'd0;
        raw_fwd_val             = 64'd0;

        for (int l = 0; l < LQ_DEPTH; l++) begin
            lq_entry_ready[l]          = 1'b0;
            lq_entry_fwd_success[l]    = 1'b0;
            lq_entry_fwd_stall[l]      = 1'b0;
            lq_entry_fwd_data[l]       = 64'd0;
            lq_entry_youngest_s[l]     = 4'd0;
            lq_entry_is_speculative[l] = 1'b0;
            lq_entry_unres_stores[l]   = 16'd0;

            all_older_pa_valid_l    = 1'b1;
            has_older_fence_l       = 1'b0;
            cand_is_eligible_spec_l = 1'b0;
            overlap_mask_l          = 16'd0;
            cand_fwd_stall_l        = 1'b0;
            youngest_found_l        = 1'b0;
            min_s_dist_l            = 6'd63;
            youngest_s_l            = 4'd0;
            l_mask_l                = get_byte_lane_mask(lq_q[l].pa[2:0], lq_q[l].size);
            same_word_s             = 1'b0;
            has_overlap_s           = 1'b0;
            s_dist_val              = 6'd0;

            if (lq_q[l].valid && lq_q[l].pa_valid && !lq_q[l].completed && !lq_q[l].issued_to_l1d && !lq_q[l].align_fault) begin
                for (int s = 0; s < SQ_DEPTH; s++) begin
                    if (lq_q[l].sq_older_mask[s]) begin
                        if (sq_q[s].is_sc && sq_q[s].completed && !sq_q[s].sc_success) begin
                            // Failed SC: ignore
                        end else if (sq_q[s].is_fence) begin
                            has_older_fence_l    = 1'b1;
                            all_older_pa_valid_l = 1'b0;
                        end else if (!sq_q[s].pa_valid) begin
                            all_older_pa_valid_l = 1'b0;
                            lq_entry_unres_stores[l][s] = 1'b1;
                        end
                    end
                end

                cand_is_eligible_spec_l = !lq_q[l].is_mmio && !lq_q[l].is_lr &&
                                          !lq_q[l].replay_safe &&
                                          !lq_q[l].page_fault && !lq_q[l].access_fault &&
                                          !lq_q[l].align_fault && !has_older_fence_l;

                if (!lq_q[l].is_mmio && (all_older_pa_valid_l || cand_is_eligible_spec_l)) begin
                    lq_entry_is_speculative[l] = !all_older_pa_valid_l;

                    for (int s = 0; s < SQ_DEPTH; s++) begin
                        if (lq_q[l].sq_older_mask[s] && sq_q[s].pa_valid) begin
                            same_word_s   = (sq_q[s].pa[55:3] == lq_q[l].pa[55:3]);
                            has_overlap_s = same_word_s && ((sq_q[s].mask & l_mask_l) != 8'b0);
                            if (has_overlap_s) begin
                                if (sq_q[s].is_sc && !sq_q[s].completed) begin
                                    cand_fwd_stall_l = 1'b1;
                                end else if (sq_q[s].is_sc && sq_q[s].completed && !sq_q[s].sc_success) begin
                                    // Failed SC performs no memory store
                                end else begin
                                    overlap_mask_l[s] = 1'b1;
                                end
                            end
                        end
                    end

                    if (cand_fwd_stall_l) begin
                        lq_entry_fwd_stall[l] = 1'b1;
                        lq_entry_ready[l]     = 1'b0;
                    end else if (overlap_mask_l == 16'd0) begin
                        lq_entry_ready[l]       = 1'b1;
                        lq_entry_fwd_success[l] = 1'b0;
                        lq_entry_fwd_data[l]    = 64'd0;
                    end else begin
                        for (int s = 0; s < SQ_DEPTH; s++) begin
                            if (overlap_mask_l[s]) begin
                                s_dist_val = rob_dist(lq_q[l].rob_idx, sq_q[s].rob_idx);
                                if (!youngest_found_l || (s_dist_val < min_s_dist_l)) begin
                                    min_s_dist_l     = s_dist_val;
                                    youngest_s_l     = 4'(s);
                                    youngest_found_l = 1'b1;
                                end
                            end
                        end
                        lq_entry_youngest_s[l] = youngest_s_l;

                        if ((sq_q[youngest_s_l].mask & l_mask_l) == l_mask_l) begin
                            if (sq_q[youngest_s_l].data_valid) begin
                                lq_entry_ready[l]       = 1'b1;
                                lq_entry_fwd_success[l] = 1'b1;
                                raw_fwd_val = format_load_result(
                                    format_store_payload(sq_q[youngest_s_l].data, sq_q[youngest_s_l].va[2:0], sq_q[youngest_s_l].size),
                                    lq_q[l].pa[2:0],
                                    lq_q[l].size,
                                    lq_q[l].sign_ext
                                );
                                if (lq_q[l].sub_op == MEM_FLW) begin
                                    lq_entry_fwd_data[l] = {32'hFFFFFFFF, raw_fwd_val[31:0]};
                                end else begin
                                    lq_entry_fwd_data[l] = raw_fwd_val;
                                end
                            end else begin
                                lq_entry_fwd_stall[l] = 1'b1;
                                lq_entry_ready[l]     = 1'b0;
                            end
                        end else begin
                            lq_entry_fwd_stall[l] = 1'b1;
                            lq_entry_ready[l]     = 1'b0;
                        end
                    end
                end
            end
        end
    end

    // Dual Load Selection: Scan for Oldest Ready (cand_slot0) and Second Oldest Ready (cand_slot1)
    logic       has_cand0, has_cand1;
    logic [3:0] cand_slot0, cand_slot1;
    logic [5:0] dist_cand0, dist_cand1;

    always_comb begin
        has_cand0   = 1'b0;
        has_cand1   = 1'b0;
        cand_slot0  = 4'd0;
        cand_slot1  = 4'd0;
        dist_cand0  = 6'd63;
        dist_cand1  = 6'd63;
        l_dist_head = 6'd0;

        for (int l = 0; l < LQ_DEPTH; l++) begin
            if (lq_entry_ready[l]) begin
                l_dist_head = rob_dist(lq_q[l].rob_idx, rob_head_i);
                if (!has_cand0 || (l_dist_head < dist_cand0)) begin
                    has_cand1  = has_cand0;
                    cand_slot1 = cand_slot0;
                    dist_cand1 = dist_cand0;
                    has_cand0  = 1'b1;
                    cand_slot0 = 4'(l);
                    dist_cand0 = l_dist_head;
                end else if (!has_cand1 || (l_dist_head < dist_cand1)) begin
                    has_cand1  = 1'b1;
                    cand_slot1 = 4'(l);
                    dist_cand1 = l_dist_head;
                end
            end
        end
    end

    // Lane 0 & Lane 1 Issue Fires
    wire fwd0_issue_fire = has_cand0 && lq_entry_fwd_success[cand_slot0];
    wire l1d0_issue_fire = has_cand0 && !lq_entry_fwd_success[cand_slot0] && l1d_load0_req_ready_i;

    wire fwd1_issue_fire = has_cand1 && lq_entry_fwd_success[cand_slot1];
    wire l1d1_issue_fire = has_cand1 && !lq_entry_fwd_success[cand_slot1] && l1d_load1_req_ready_i;

    assign event_load_fwd_exact_o   = fwd0_issue_fire || fwd1_issue_fire;
    assign event_load_fwd_partial_o = (|lq_entry_fwd_stall);
    assign event_load_speculative_o = (has_cand0 && (l1d0_issue_fire || fwd0_issue_fire) && lq_entry_is_speculative[cand_slot0]) ||
                                      (has_cand1 && (l1d1_issue_fire || fwd1_issue_fire) && lq_entry_is_speculative[cand_slot1]);

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

    // Speculative Load Issue to L1D (Port 0 / Lane 0)
    assign l1d_load0_req_valid_o    = has_cand0 && !lq_entry_fwd_success[cand_slot0];
    assign l1d_load0_req_lq_idx_o   = cand_slot0;
    assign l1d_load0_req_pa_o       = lq_q[cand_slot0].pa;
    assign l1d_load0_req_size_o     = lq_q[cand_slot0].size;
    assign l1d_load0_req_sign_ext_o = lq_q[cand_slot0].sign_ext;
    assign l1d_load0_req_pnew_o     = lq_q[cand_slot0].pnew;
    assign l1d_load0_req_rob_idx_o  = lq_q[cand_slot0].rob_idx;
    assign l1d_load0_req_rob_epoch_o= lq_q[cand_slot0].rob_epoch;

    // Speculative Load Issue to L1D (Port 1 / Lane 1)
    assign l1d_load1_req_valid_o    = has_cand1 && !lq_entry_fwd_success[cand_slot1];
    assign l1d_load1_req_lq_idx_o   = cand_slot1;
    assign l1d_load1_req_pa_o       = lq_q[cand_slot1].pa;
    assign l1d_load1_req_size_o     = lq_q[cand_slot1].size;
    assign l1d_load1_req_sign_ext_o = lq_q[cand_slot1].sign_ext;
    assign l1d_load1_req_pnew_o     = lq_q[cand_slot1].pnew;
    assign l1d_load1_req_rob_idx_o  = lq_q[cand_slot1].rob_idx;
    assign l1d_load1_req_rob_epoch_o= lq_q[cand_slot1].rob_epoch;

    // =========================================================================
    // 4. Committed Store In-Order Drain to L1D (Sections 5.2, 5.3)
    // =========================================================================
    wire sq_head_committed = sq_q[sq_drain_head_q].valid && sq_q[sq_drain_head_q].committed;

    assign l1d_store_drain_valid_o  = sq_head_committed && !sq_q[sq_drain_head_q].drained &&
                                      !sq_q[sq_drain_head_q].is_fence &&
                                      !sq_q[sq_drain_head_q].is_mmio &&
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
            if (!lq_q[head0_lq_idx].wb_done && !lq_q[head0_lq_idx].completed &&
                !(mmio_comp_valid && !mmio_is_store_q && (head0_lq_idx == mmio_lq_idx_q))) begin
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
            // 5. No violation targeting this load currently in flight in Stage M3 or from snoop
            if ((m3_viol_valid_q && (m3_viol_rob_idx_q == rob_head_i)) ||
                (snoop_match_found && (lq_q[oldest_snoop_viol_lq].rob_idx == rob_head_i))) begin
                lsu_retire0_allow_o = 1'b0;
            end
            // 6. Violated load never retires (triggers replay recovery)
            if (lq_q[head0_lq_idx].violated || snoop_lq_match[head0_lq_idx]) begin
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
        if (mmio_comp_valid) begin
            lsu_retire1_allow_o = 1'b0;
        end else if (head1_lq_found) begin
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
            // 5. No violation targeting this load currently in flight in Stage M3 or from snoop
            if ((m3_viol_valid_q && (m3_viol_rob_idx_q == rob_head_next_i)) ||
                (snoop_match_found && (lq_q[oldest_snoop_viol_lq].rob_idx == rob_head_next_i))) begin
                lsu_retire1_allow_o = 1'b0;
            end
            // 6. Violated load never retires (triggers replay recovery)
            if (lq_q[head1_lq_idx].violated || snoop_lq_match[head1_lq_idx]) begin
                lsu_retire1_allow_o = 1'b0;
            end
        end
    end


    wire store0_retiring = retire_valid_i[0] && retire0_sq_found && !sq_q[retire0_sq_slot].is_sc && !sq_q[retire0_sq_slot].is_fence;
    wire store1_retiring = retire_valid_i[1] && retire1_sq_found && !sq_q[retire1_sq_slot].is_sc && !sq_q[retire1_sq_slot].is_fence;
    wire store_draining  = l1d_store_drain_valid_o && !sq_q[sq_drain_head_q].is_sc && !sq_q[sq_drain_head_q].is_fence;

    // =========================================================================
    // 5. Port 2 & Port 3 Completion Arbiters (Dual Completion)
    // =========================================================================
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
    logic        p2_comp_is_fp;
    fpreg_t      p2_comp_prd_fp;

    logic        p3_comp_valid;
    rob_idx_t    p3_comp_rob_idx;
    rob_epoch_t  p3_comp_epoch;
    preg_t       p3_comp_preg;
    logic        p3_comp_exception;
    logic [4:0]  p3_comp_cause;
    logic [63:0] p3_comp_data;
    lq_idx_t     p3_cleared_lq_idx;
    logic        p3_clear_lq;
    logic        p3_comp_is_fp;
    fpreg_t      p3_comp_prd_fp;

    logic        sc_ok;

    // Load completion candidate evaluations
    logic        lq_ready_comp   [LQ_DEPTH];
    rob_idx_t    lq_comp_rob_idx [LQ_DEPTH];
    rob_epoch_t  lq_comp_epoch   [LQ_DEPTH];
    preg_t       lq_comp_preg    [LQ_DEPTH];
    logic        lq_comp_exc     [LQ_DEPTH];
    logic [4:0]  lq_comp_cause   [LQ_DEPTH];
    logic [63:0] lq_comp_data    [LQ_DEPTH];
    logic        lq_comp_is_fp   [LQ_DEPTH];
    fpreg_t      lq_comp_prd_fp  [LQ_DEPTH];

    always_comb begin
        for (int l = 0; l < LQ_DEPTH; l++) begin
            lq_ready_comp[l]   = 1'b0;
            lq_comp_rob_idx[l] = lq_q[l].rob_idx;
            lq_comp_epoch[l]   = lq_q[l].rob_epoch;
            lq_comp_preg[l]    = lq_q[l].pnew;
            lq_comp_exc[l]     = 1'b0;
            lq_comp_cause[l]   = 5'd0;
            lq_comp_data[l]    = 64'd0;
            lq_comp_is_fp[l]   = lq_q[l].is_fp;
            lq_comp_prd_fp[l]  = lq_q[l].prd_fp;

            if (lq_q[l].valid && (lq_q[l].align_fault || lq_q[l].page_fault || lq_q[l].access_fault) && !lq_q[l].completed) begin
                lq_ready_comp[l] = 1'b1;
                lq_comp_exc[l]   = 1'b1;
                lq_comp_cause[l] = lq_q[l].align_fault ? 5'd4 : (lq_q[l].page_fault ? 5'd15 : 5'd5);
                lq_comp_data[l]  = 64'd0;
            end else if (fwd0_issue_fire && (4'(l) == cand_slot0)) begin
                lq_ready_comp[l] = 1'b1;
                lq_comp_data[l]  = lq_entry_fwd_data[cand_slot0];
            end else if (fwd1_issue_fire && (4'(l) == cand_slot1)) begin
                lq_ready_comp[l] = 1'b1;
                lq_comp_data[l]  = lq_entry_fwd_data[cand_slot1];
            end else if (lq_q[l].valid && lq_q[l].completed && !lq_q[l].wb_done && !lq_q[l].align_fault) begin
                lq_ready_comp[l] = 1'b1;
                lq_comp_data[l]  = lq_q[l].result_data;
            end
        end
    end

    // Scan for two oldest ready loads by rob_dist
    logic       has_l0, has_l1;
    lq_idx_t    cand_l0, cand_l1;
    logic [5:0] dist_l0, dist_l1;
    logic [5:0] comp_l_dist;

    always_comb begin
        has_l0      = 1'b0;
        has_l1      = 1'b0;
        cand_l0     = '0;
        cand_l1     = '0;
        dist_l0     = '1;
        dist_l1     = '1;
        comp_l_dist = '0;

        for (int l = 0; l < LQ_DEPTH; l++) begin
            if (lq_ready_comp[l]) begin
                comp_l_dist = rob_dist(lq_q[l].rob_idx, rob_head_i);
                if (!has_l0 || (comp_l_dist < dist_l0)) begin
                    has_l1  = has_l0;
                    cand_l1 = cand_l0;
                    dist_l1 = dist_l0;
                    has_l0  = 1'b1;
                    cand_l0 = 4'(l);
                    dist_l0 = comp_l_dist;
                end else if (!has_l1 || (comp_l_dist < dist_l1)) begin
                    has_l1  = 1'b1;
                    cand_l1 = 4'(l);
                    dist_l1 = comp_l_dist;
                end
            end
        end
    end

    // Scan for oldest ready store by rob_dist (Path 1 exceptional or Path 5 normal)
    logic        has_store;
    sq_idx_t     cand_store;
    logic [5:0]  dist_store;
    logic        store_is_exc;
    logic [4:0]  store_exc_cause;
    preg_t       store_preg;
    logic [63:0] store_data;
    logic        store_sc_ok;
    logic [5:0]  comp_s_dist;
    logic        has_conflict;
    logic        sc_ok_val;

    always_comb begin
        has_store       = 1'b0;
        cand_store      = '0;
        dist_store      = '1;
        store_is_exc    = 1'b0;
        store_exc_cause = 5'd0;
        store_preg      = 7'd0;
        store_data      = 64'd0;
        store_sc_ok     = 1'b0;
        comp_s_dist     = '0;
        has_conflict    = 1'b0;
        sc_ok_val       = 1'b0;

        for (int s = 0; s < SQ_DEPTH; s++) begin
            if (sq_q[s].valid) begin
                comp_s_dist = rob_dist(sq_q[s].rob_idx, rob_head_i);
                if (sq_q[s].exception_pending && !sq_q[s].completed) begin
                    if (!has_store || (comp_s_dist < dist_store)) begin
                        has_store       = 1'b1;
                        cand_store      = 4'(s);
                        dist_store      = comp_s_dist;
                        store_is_exc    = 1'b1;
                        store_exc_cause = sq_q[s].exc_cause;
                        store_preg      = 7'd0;
                        store_data      = 64'd0;
                        store_sc_ok     = 1'b0;
                    end
                end else if (sq_q[s].pa_valid && sq_q[s].data_valid && !sq_q[s].exception_pending && !sq_q[s].completed) begin
                    if (sq_q[s].is_fence && ((sq_drain_head_q != 4'(s)) || !l1d_quiescent_i)) continue;
                    if (sq_q[s].is_sc && (sq_q[s].rob_idx != rob_head_i)) continue;
                    if (sq_q[s].is_amo && ((sq_drain_head_q != 4'(s)) || (sq_q[s].rob_idx != rob_head_i))) continue;
                    if (sq_q[s].is_mmio) continue;

                    if (!has_store || (comp_s_dist < dist_store)) begin
                        has_conflict = 1'b0;
                        sc_ok_val    = 1'b0;
                        if (sq_q[s].is_sc) begin
                            for (int os = 0; os < SQ_DEPTH; os++) begin
                                if (sq_q[os].valid && (4'(os) != 4'(s)) && !sq_q[os].is_sc && !sq_q[os].is_fence) begin
                                    if (rob_dist(sq_q[os].rob_idx, rob_head_i) < rob_dist(sq_q[s].rob_idx, rob_head_i)) begin
                                        has_conflict = 1'b1;
                                    end
                                end
                            end
                            sc_ok_val = res_valid_q && !has_conflict &&
                                        (res_pa_q == sq_q[s].pa) && (res_size_q == sq_q[s].size);
                        end

                        has_store       = 1'b1;
                        cand_store      = 4'(s);
                        dist_store      = comp_s_dist;
                        store_is_exc    = 1'b0;
                        store_exc_cause = 5'd0;
                        store_sc_ok     = sc_ok_val;
                        if (sq_q[s].is_sc) begin
                            store_preg = sq_q[s].pnew;
                            store_data = sc_ok_val ? 64'd0 : 64'd1;
                        end else if (sq_q[s].is_amo) begin
                            store_preg = sq_q[s].pnew;
                            store_data = 64'd100;
                        end else begin
                            store_preg = 7'd0;
                            store_data = 64'd0;
                        end
                    end
                end
            end
        end
    end

    // =========================================================================
    // Uncached MMIO Pipeline Controller (§4, PROP_M9_07..PROP_M9_12)
    // =========================================================================
    typedef enum logic [1:0] {
        MMIO_IDLE     = 2'd0,
        MMIO_REQ      = 2'd1,
        MMIO_WAIT_RSP = 2'd2
    } mmio_state_t;

    mmio_state_t mmio_state_q;
    logic        mmio_is_store_q;
    lq_idx_t     mmio_lq_idx_q;
    sq_idx_t     mmio_sq_idx_q;
    rob_idx_t    mmio_rob_idx_q;
    rob_epoch_t  mmio_rob_epoch_q;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] mmio_addr_q;
    logic [2:0]  mmio_size_q;
    uop_subop_t  mmio_subop_q;
    preg_t       mmio_pnew_q;
    logic        mmio_is_fp_q;
    fpreg_t      mmio_prd_fp_q;
    logic [63:0] mmio_wdata_q;
    logic [7:0]  mmio_wstrb_q;
    /* verilator lint_on UNUSEDSIGNAL */

    assign mmio_rsp_ready_o = 1'b1;

    logic        mmio_cand_valid;
    logic        mmio_cand_is_store;
    lq_idx_t     mmio_cand_lq_idx;
    sq_idx_t     mmio_cand_sq_idx;
    rob_idx_t    mmio_cand_rob_idx;
    rob_epoch_t  mmio_cand_rob_epoch;
    logic [63:0] mmio_cand_addr;
    mem_size_t   mmio_cand_size;
    uop_subop_t  mmio_cand_subop;
    preg_t       mmio_cand_pnew;
    logic        mmio_cand_is_fp;
    fpreg_t      mmio_cand_prd_fp;
    logic [63:0] mmio_cand_wdata;
    logic [7:0]  mmio_cand_wstrb;

    always_comb begin
        mmio_cand_valid     = 1'b0;
        mmio_cand_is_store  = 1'b0;
        mmio_cand_lq_idx    = '0;
        mmio_cand_sq_idx    = '0;
        mmio_cand_rob_idx   = '0;
        mmio_cand_rob_epoch = '0;
        mmio_cand_addr      = '0;
        mmio_cand_size      = MEM_SIZE_BYTE;
        mmio_cand_subop     = MEM_LB;
        mmio_cand_pnew      = '0;
        mmio_cand_is_fp     = 1'b0;
        mmio_cand_prd_fp    = '0;
        mmio_cand_wdata     = 64'd0;
        mmio_cand_wstrb     = 8'd0;

        if (!flush_valid_i && !recover_valid_i) begin
            // 1. MMIO Load at ROB head (all older stores resolved & drained)
            for (int l = 0; l < LQ_DEPTH; l++) begin
                if (lq_q[l].valid && lq_q[l].is_mmio && lq_q[l].pa_valid &&
                    !lq_q[l].completed && !lq_q[l].align_fault &&
                    !lq_q[l].page_fault && !lq_q[l].access_fault &&
                    (lq_q[l].rob_idx == rob_head_i) &&
                    (lq_q[l].sq_older_mask == 16'd0) && (sq_drain_head_q == sq_tail_q)) begin
                    mmio_cand_valid     = 1'b1;
                    mmio_cand_is_store  = 1'b0;
                    mmio_cand_lq_idx    = 4'(l);
                    mmio_cand_rob_idx   = lq_q[l].rob_idx;
                    mmio_cand_rob_epoch = lq_q[l].rob_epoch;
                    mmio_cand_addr      = {8'd0, lq_q[l].pa};
                    mmio_cand_size      = lq_q[l].size;
                    mmio_cand_subop     = lq_q[l].sub_op;
                    mmio_cand_pnew      = lq_q[l].pnew;
                    mmio_cand_is_fp     = lq_q[l].is_fp;
                    mmio_cand_prd_fp    = lq_q[l].prd_fp;
                    mmio_cand_wdata     = 64'd0;
                    mmio_cand_wstrb     = 8'd0;
                end
            end

            // 2. MMIO Store at ROB head (at drain head, data ready)
            for (int s = 0; s < SQ_DEPTH; s++) begin
                if (sq_q[s].valid && sq_q[s].is_mmio && sq_q[s].pa_valid && sq_q[s].data_valid &&
                    !sq_q[s].completed && !sq_q[s].drained && !sq_q[s].exception_pending &&
                    (sq_q[s].rob_idx == rob_head_i) && (4'(s) == sq_drain_head_q)) begin
                    mmio_cand_valid     = 1'b1;
                    mmio_cand_is_store  = 1'b1;
                    mmio_cand_sq_idx    = 4'(s);
                    mmio_cand_rob_idx   = sq_q[s].rob_idx;
                    mmio_cand_rob_epoch = sq_q[s].rob_epoch;
                    mmio_cand_addr      = {8'd0, sq_q[s].pa};
                    mmio_cand_size      = sq_q[s].size;
                    mmio_cand_subop     = sq_q[s].sub_op;
                    mmio_cand_pnew      = sq_q[s].pnew;
                    mmio_cand_is_fp     = sq_q[s].is_fp;
                    mmio_cand_prd_fp    = '0;
                    mmio_cand_wstrb     = sq_q[s].mask;
                    mmio_cand_wdata     = format_store_payload(sq_q[s].data, sq_q[s].va[2:0], sq_q[s].size);
                end
            end
        end
    end

    wire mmio_comp_valid = ((mmio_state_q == MMIO_WAIT_RSP) ||
                            (mmio_state_q == MMIO_REQ && mmio_req_ready_i)) && mmio_rsp_valid_i;

    logic [63:0] mmio_formatted_rdata;
    always_comb begin
        if (mmio_is_store_q) begin
            mmio_formatted_rdata = 64'd0;
        end else begin
            logic [63:0] raw_fmt;
            logic sign_ext;
            case (mmio_subop_q)
                MEM_LB, MEM_LH, MEM_LW: sign_ext = 1'b1;
                default:                sign_ext = 1'b0;
            endcase
            raw_fmt = format_load_result(mmio_rsp_rdata_i, mmio_addr_q[2:0], mem_size_t'(mmio_size_q[1:0]), sign_ext);
            if (mmio_subop_q == MEM_FLW) begin
                mmio_formatted_rdata = {32'hFFFFFFFF, raw_fmt[31:0]};
            end else begin
                mmio_formatted_rdata = raw_fmt;
            end
        end
    end

    // Dual-Completion Assignment Matrix (Table 5.2 / Section 5.1)
    always_comb begin
        p2_comp_valid     = 1'b0;
        p2_comp_rob_idx   = '0;
        p2_comp_epoch     = '0;
        p2_comp_preg      = 7'd0;
        p2_comp_exception = 1'b0;
        p2_comp_cause     = 5'd0;
        p2_comp_data      = 64'd0;
        p2_clear_lq       = 1'b0;
        p2_cleared_lq_idx = '0;
        p2_clear_sq       = 1'b0;
        p2_cleared_sq_idx = '0;
        sc_ok             = 1'b0;

        p3_comp_valid     = 1'b0;
        p3_comp_rob_idx   = '0;
        p3_comp_epoch     = '0;
        p3_comp_preg      = 7'd0;
        p3_comp_exception = 1'b0;
        p3_comp_cause     = 5'd0;
        p3_comp_data      = 64'd0;
        p3_clear_lq       = 1'b0;
        p3_cleared_lq_idx = '0;
        p2_comp_is_fp     = 1'b0;
        p2_comp_prd_fp    = 6'd0;
        p3_comp_is_fp     = 1'b0;
        p3_comp_prd_fp    = 6'd0;

        if (mmio_comp_valid) begin
            p2_comp_valid     = 1'b1;
            p2_comp_rob_idx   = mmio_rob_idx_q;
            p2_comp_epoch     = mmio_rob_epoch_q;
            p2_comp_preg      = mmio_pnew_q;
            p2_comp_exception = mmio_rsp_error_i;
            p2_comp_cause     = mmio_is_store_q ? 5'd7 : 5'd5;
            p2_comp_data      = mmio_formatted_rdata;
            p2_comp_is_fp     = mmio_is_fp_q;
            p2_comp_prd_fp    = mmio_prd_fp_q;
            p2_clear_lq       = !mmio_is_store_q;
            p2_cleared_lq_idx = mmio_lq_idx_q;
            p2_clear_sq       = mmio_is_store_q;
            p2_cleared_sq_idx = mmio_sq_idx_q;
            sc_ok             = 1'b0;
        end else if (has_store && has_l0) begin
            // Case 1: 1 Store + 1 Load ready -> Store to Port 2, Load to Port 3
            p2_comp_valid     = 1'b1;
            p2_comp_rob_idx   = sq_q[cand_store].rob_idx;
            p2_comp_epoch     = sq_q[cand_store].rob_epoch;
            p2_comp_preg      = store_preg;
            p2_comp_exception = store_is_exc;
            p2_comp_cause     = store_exc_cause;
            p2_comp_data      = store_data;
            p2_comp_is_fp     = 1'b0;
            p2_comp_prd_fp    = 6'd0;
            p2_clear_sq       = 1'b1;
            p2_cleared_sq_idx = cand_store;
            sc_ok             = store_sc_ok;

            p3_comp_valid     = 1'b1;
            p3_comp_rob_idx   = lq_comp_rob_idx[cand_l0];
            p3_comp_epoch     = lq_comp_epoch[cand_l0];
            p3_comp_preg      = lq_comp_preg[cand_l0];
            p3_comp_exception = lq_comp_exc[cand_l0];
            p3_comp_cause     = lq_comp_cause[cand_l0];
            p3_comp_data      = lq_comp_data[cand_l0];
            p3_comp_is_fp     = lq_comp_is_fp[cand_l0];
            p3_comp_prd_fp    = lq_comp_prd_fp[cand_l0];
            p3_clear_lq       = 1'b1;
            p3_cleared_lq_idx = cand_l0;
        end else if (has_store) begin
            // Single ready store -> Port 2
            p2_comp_valid     = 1'b1;
            p2_comp_rob_idx   = sq_q[cand_store].rob_idx;
            p2_comp_epoch     = sq_q[cand_store].rob_epoch;
            p2_comp_preg      = store_preg;
            p2_comp_exception = store_is_exc;
            p2_comp_cause     = store_exc_cause;
            p2_comp_data      = store_data;
            p2_comp_is_fp     = 1'b0;
            p2_comp_prd_fp    = 6'd0;
            p2_clear_sq       = 1'b1;
            p2_cleared_sq_idx = cand_store;
            sc_ok             = store_sc_ok;
        end else if (has_l0 && has_l1) begin
            // Case 2: 2 Loads ready -> older to Port 2, younger to Port 3
            p2_comp_valid     = 1'b1;
            p2_comp_rob_idx   = lq_comp_rob_idx[cand_l0];
            p2_comp_epoch     = lq_comp_epoch[cand_l0];
            p2_comp_preg      = lq_comp_preg[cand_l0];
            p2_comp_exception = lq_comp_exc[cand_l0];
            p2_comp_cause     = lq_comp_cause[cand_l0];
            p2_comp_data      = lq_comp_data[cand_l0];
            p2_comp_is_fp     = lq_comp_is_fp[cand_l0];
            p2_comp_prd_fp    = lq_comp_prd_fp[cand_l0];
            p2_clear_lq       = 1'b1;
            p2_cleared_lq_idx = cand_l0;

            p3_comp_valid     = 1'b1;
            p3_comp_rob_idx   = lq_comp_rob_idx[cand_l1];
            p3_comp_epoch     = lq_comp_epoch[cand_l1];
            p3_comp_preg      = lq_comp_preg[cand_l1];
            p3_comp_exception = lq_comp_exc[cand_l1];
            p3_comp_cause     = lq_comp_cause[cand_l1];
            p3_comp_data      = lq_comp_data[cand_l1];
            p3_comp_is_fp     = lq_comp_is_fp[cand_l1];
            p3_comp_prd_fp    = lq_comp_prd_fp[cand_l1];
            p3_clear_lq       = 1'b1;
            p3_cleared_lq_idx = cand_l1;
        end else if (has_l0) begin
            // Single ready load -> Port 2
            p2_comp_valid     = 1'b1;
            p2_comp_rob_idx   = lq_comp_rob_idx[cand_l0];
            p2_comp_epoch     = lq_comp_epoch[cand_l0];
            p2_comp_preg      = lq_comp_preg[cand_l0];
            p2_comp_exception = lq_comp_exc[cand_l0];
            p2_comp_cause     = lq_comp_cause[cand_l0];
            p2_comp_data      = lq_comp_data[cand_l0];
            p2_comp_is_fp     = lq_comp_is_fp[cand_l0];
            p2_comp_prd_fp    = lq_comp_prd_fp[cand_l0];
            p2_clear_lq       = 1'b1;
            p2_cleared_lq_idx = cand_l0;
        end
    end

    assign comp_valid_o        = p2_comp_valid && !flush_valid_i;
    assign comp_rob_idx_o      = p2_comp_rob_idx;
    assign comp_epoch_o        = p2_comp_epoch;
    assign comp_preg_o         = p2_comp_preg;
    assign comp_exception_o    = p2_comp_exception;
    assign comp_cause_o        = p2_comp_cause;
    assign wb_data_o           = p2_comp_data;

    assign p3_comp_valid_o     = p3_comp_valid && !flush_valid_i;
    assign p3_comp_rob_idx_o   = p3_comp_rob_idx;
    assign p3_comp_epoch_o     = p3_comp_epoch;
    assign p3_comp_preg_o      = p3_comp_preg;
    assign p3_comp_exception_o = p3_comp_exception;
    assign p3_comp_cause_o     = p3_comp_cause;
    assign p3_wb_data_o        = p3_comp_data;

    assign comp_is_fp_o        = p2_comp_is_fp;
    assign comp_prd_fp_o       = p2_comp_prd_fp;
    assign p3_comp_is_fp_o     = p3_comp_is_fp;
    assign p3_comp_prd_fp_o    = p3_comp_prd_fp;

    assign p2_fp_wb_valid_o    = p2_comp_valid && !flush_valid_i && p2_comp_is_fp && !p2_comp_exception;
    assign p2_fp_wb_paddr_o    = p2_comp_prd_fp;
    assign p2_fp_wb_data_o     = p2_comp_data;

    assign p3_fp_wb_valid_o    = p3_comp_valid && !flush_valid_i && p3_comp_is_fp && !p3_comp_exception;
    assign p3_fp_wb_paddr_o    = p3_comp_prd_fp;
    assign p3_fp_wb_data_o     = p3_comp_data;

    wire p2_fp_wb_fire = p2_comp_valid && !flush_valid_i && p2_comp_is_fp && !p2_comp_exception;
    wire p3_fp_wb_fire = p3_comp_valid && !flush_valid_i && p3_comp_is_fp && !p3_comp_exception;

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
            mmio_state_q        <= MMIO_IDLE;
            mmio_req_valid_o    <= 1'b0;
            mmio_req_addr_o     <= '0;
            mmio_req_is_store_o <= 1'b0;
            mmio_req_size_o     <= 3'd0;
            mmio_req_wdata_o    <= '0;
            mmio_req_wstrb_o    <= 8'd0;
            mmio_is_store_q     <= 1'b0;
            mmio_lq_idx_q       <= '0;
            mmio_sq_idx_q       <= '0;
            mmio_rob_idx_q      <= '0;
            mmio_rob_epoch_q    <= '0;
            mmio_addr_q         <= '0;
            mmio_size_q         <= 3'd0;
            mmio_subop_q        <= MEM_LB;
            mmio_pnew_q         <= '0;
            mmio_is_fp_q        <= 1'b0;
            mmio_prd_fp_q       <= '0;
            mmio_wdata_q        <= '0;
            mmio_wstrb_q        <= 8'd0;
        end else begin
            dtlb_miss_alloc_o <= 1'b0;

            // -----------------------------------------------------------------
            // A. Asynchronous Store Data Capture (PRF R5 & WB Snoop)
            // -----------------------------------------------------------------
            for (int s = 0; s < SQ_DEPTH; s++) begin
                if (sq_q[s].valid && !sq_q[s].data_valid) begin
                    if (sq_q[s].is_fp) begin
                        if (wb0_fp_valid_i && (wb0_fp_paddr_i == sq_q[s].prs2_fp)) begin
                            sq_q[s].data       <= wb0_fp_data_i;
                            sq_q[s].data_valid <= 1'b1;
                        end else if (p2_fp_wb_fire && (p2_comp_prd_fp == sq_q[s].prs2_fp)) begin
                            sq_q[s].data       <= p2_comp_data;
                            sq_q[s].data_valid <= 1'b1;
                        end else if (p3_fp_wb_fire && (p3_comp_prd_fp == sq_q[s].prs2_fp)) begin
                            sq_q[s].data       <= p3_comp_data;
                            sq_q[s].data_valid <= 1'b1;
                        end
                    end else begin
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
                        end else if (wb3_valid_i && wb3_comp_ack_i && !wb3_comp_exception_i && (wb3_pnew_i == sq_q[s].prs2) && (wb3_pnew_i != 7'd0)) begin
                            sq_q[s].data       <= wb3_data_i;
                            sq_q[s].data_valid <= 1'b1;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            // B. AGU Address Delivery & DTLB Query Handling (Dual AGU)
            // -----------------------------------------------------------------
            // Evaluate Port 2 AGU0 Miss
            begin : b_agu_eval
                logic agu0_dtlb_miss;
                agu0_dtlb_miss = agu_valid_i && !flush_valid_i && !agu_align_fault_i && !dtlb_hit_i;

                // 1. Port 2 AGU Delivery (Loads or Stores)
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
                            // DTLB Miss on Port 2 Store: Always takes priority for TRT Allocation
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
                        // Port 2 Load
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
                            // DTLB Miss on Port 2 Load: Always takes priority for TRT Allocation
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

                // 2. Port 3 AGU Delivery (Loads Strictly)
                if (agu1_valid_i && !flush_valid_i) begin
                    lq_q[agu1_lq_idx_i].va          <= agu1_va_i;
                    lq_q[agu1_lq_idx_i].align_fault <= agu1_align_fault_i;
                    if (agu1_align_fault_i) begin
                        lq_q[agu1_lq_idx_i].pa_valid  <= 1'b1;
                    end else if (dtlb1_hit_i) begin
                        lq_q[agu1_lq_idx_i].pa        <= dtlb1_pa_i;
                        lq_q[agu1_lq_idx_i].pa_valid  <= 1'b1;
                        lq_q[agu1_lq_idx_i].page_fault<= dtlb1_page_fault_i;
                        lq_q[agu1_lq_idx_i].access_fault<= dtlb1_access_fault_i;
                        lq_q[agu1_lq_idx_i].is_mmio   <= !is_dram_pa(dtlb1_pa_i);
                    end else begin
                        // Port 3 DTLB Miss: Check if Port 2 also missed
                        if (agu0_dtlb_miss) begin
                            // Concurrent miss: Port 2 takes priority; Port 3 stalls and retries in Cycle 1
                            p3_dtlb_retry_q      <= 1'b1;
                            p3_retry_lq_idx_q    <= agu1_lq_idx_i;
                            p3_retry_va_q        <= agu1_va_i;
                            p3_retry_byte_mask_q <= agu1_byte_mask_i;
                        end else begin
                            // Port 2 did not miss: Port 3 allocates into TRT directly in Cycle 0
                            lq_q[agu1_lq_idx_i].wait_translation <= 1'b1;
                            lq_q[agu1_lq_idx_i].tr_id            <= trt_assigned_tr_id_i;
                            dtlb_miss_alloc_o    <= 1'b1;
                            dtlb_miss_is_store_o <= 1'b0;
                            dtlb_miss_q_idx_o    <= agu1_lq_idx_i;
                            dtlb_miss_vpn_o      <= agu1_va_i[38:12];
                            dtlb_miss_rob_idx_o  <= lq_q[agu1_lq_idx_i].rob_idx;
                            dtlb_miss_rob_epoch_o<= lq_q[agu1_lq_idx_i].rob_epoch;
                        end
                    end
                end else if (p3_dtlb_retry_q && !flush_valid_i) begin
                    // 3. Port 3 DTLB Miss Retry Execution in Cycle 1 (§5.3.1)
                    lq_q[p3_retry_lq_idx_q].wait_translation <= 1'b1;
                    lq_q[p3_retry_lq_idx_q].tr_id            <= trt_assigned_tr_id_i;
                    dtlb_miss_alloc_o    <= 1'b1;
                    dtlb_miss_is_store_o <= 1'b0;
                    dtlb_miss_q_idx_o    <= p3_retry_lq_idx_q;
                    dtlb_miss_vpn_o      <= p3_retry_va_q[38:12];
                    dtlb_miss_rob_idx_o  <= lq_q[p3_retry_lq_idx_q].rob_idx;
                    dtlb_miss_rob_epoch_o<= lq_q[p3_retry_lq_idx_q].rob_epoch;
                    p3_dtlb_retry_q      <= 1'b0;
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
            if (l1d0_issue_fire) begin
                lq_q[cand_slot0].issued_to_l1d      <= 1'b1;
                lq_q[cand_slot0].is_speculative     <= lq_entry_is_speculative[cand_slot0];
                lq_q[cand_slot0].sq_unresolved_mask <= lq_entry_unres_stores[cand_slot0];
            end
            if (l1d1_issue_fire) begin
                lq_q[cand_slot1].issued_to_l1d      <= 1'b1;
                lq_q[cand_slot1].is_speculative     <= lq_entry_is_speculative[cand_slot1];
                lq_q[cand_slot1].sq_unresolved_mask <= lq_entry_unres_stores[cand_slot1];
            end

            if (l1d_load0_rsp_valid_i) begin
                if (l1d_load0_rsp_hit_i) begin
                    lq_q[l1d_load0_rsp_lq_idx_i].completed   <= 1'b1;
                    if (lq_q[l1d_load0_rsp_lq_idx_i].sub_op == MEM_FLW) begin
                        lq_q[l1d_load0_rsp_lq_idx_i].result_data <= {32'hFFFFFFFF, l1d_load0_rsp_data_i[31:0]};
                    end else begin
                        lq_q[l1d_load0_rsp_lq_idx_i].result_data <= l1d_load0_rsp_data_i;
                    end
                end else begin
                    lq_q[l1d_load0_rsp_lq_idx_i].mshr_id <= l1d_load0_rsp_mshr_id_i;
                end
            end
            if (l1d_load1_rsp_valid_i) begin
                if (l1d_load1_rsp_hit_i) begin
                    lq_q[l1d_load1_rsp_lq_idx_i].completed   <= 1'b1;
                    if (lq_q[l1d_load1_rsp_lq_idx_i].sub_op == MEM_FLW) begin
                        lq_q[l1d_load1_rsp_lq_idx_i].result_data <= {32'hFFFFFFFF, l1d_load1_rsp_data_i[31:0]};
                    end else begin
                        lq_q[l1d_load1_rsp_lq_idx_i].result_data <= l1d_load1_rsp_data_i;
                    end
                end else begin
                    lq_q[l1d_load1_rsp_lq_idx_i].mshr_id <= l1d_load1_rsp_mshr_id_i;
                end
            end

            if (mshr_refill_valid_i) begin
                lq_q[mshr_refill_lq_idx_i].completed   <= 1'b1;
                if (lq_q[mshr_refill_lq_idx_i].sub_op == MEM_FLW) begin
                    lq_q[mshr_refill_lq_idx_i].result_data <= {32'hFFFFFFFF, mshr_refill_data_i[31:0]};
                end else begin
                    lq_q[mshr_refill_lq_idx_i].result_data <= mshr_refill_data_i;
                end
            end

            // -----------------------------------------------------------------
            // E. Store-to-Load Forwarding Hit (Dual-Lane)
            // -----------------------------------------------------------------
            if (fwd0_issue_fire) begin
                lq_q[cand_slot0].completed          <= 1'b1;
                lq_q[cand_slot0].forwarded          <= 1'b1;
                lq_q[cand_slot0].forward_data       <= lq_entry_fwd_data[cand_slot0];
                lq_q[cand_slot0].result_data        <= lq_entry_fwd_data[cand_slot0];
                lq_q[cand_slot0].wb_done            <= 1'b1;
                lq_q[cand_slot0].is_speculative     <= lq_entry_is_speculative[cand_slot0];
                lq_q[cand_slot0].sq_unresolved_mask <= lq_entry_unres_stores[cand_slot0];
            end
            if (fwd1_issue_fire) begin
                lq_q[cand_slot1].completed          <= 1'b1;
                lq_q[cand_slot1].forwarded          <= 1'b1;
                lq_q[cand_slot1].forward_data       <= lq_entry_fwd_data[cand_slot1];
                lq_q[cand_slot1].result_data        <= lq_entry_fwd_data[cand_slot1];
                lq_q[cand_slot1].wb_done            <= 1'b1;
                lq_q[cand_slot1].is_speculative     <= lq_entry_is_speculative[cand_slot1];
                lq_q[cand_slot1].sq_unresolved_mask <= lq_entry_unres_stores[cand_slot1];
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
            end else if (sq_head_committed && sq_q[sq_drain_head_q].is_mmio && sq_q[sq_drain_head_q].drained) begin
                sq_q[sq_drain_head_q].valid   <= 1'b0;
                sq_drain_head_q <= sq_drain_head_q + 4'd1;
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

                if (p3_comp_valid && p3_comp_ack_i) begin
                    if (p3_clear_lq) begin
                        lq_q[p3_cleared_lq_idx].wb_done <= 1'b1;
                    end
                end
            end

            // -----------------------------------------------------------------
            // I. Branch Recovery Squash (Section 5.4)
            // -----------------------------------------------------------------
            if (recover_valid_i) begin
                if (p3_dtlb_retry_q && (rob_dist(lq_q[p3_retry_lq_idx_q].rob_idx, rob_head_i) >
                                        rob_dist(recover_rob_idx_i, rob_head_i))) begin
                    p3_dtlb_retry_q <= 1'b0;
                end

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
                p3_dtlb_retry_q <= 1'b0;
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
                lq_q[lq_slot0].is_fp            <= uop0_is_fp_i;
                lq_q[lq_slot0].prd_fp           <= uop0_prd_fp_i;
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
                lq_q[lq_target_slot1].is_fp            <= uop1_is_fp_i;
                lq_q[lq_target_slot1].prd_fp           <= uop1_prd_fp_i;
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
                    sq_q[sq_slot0].is_fp      <= 1'b0;
                    sq_q[sq_slot0].prs2_fp    <= 6'd0;
                end else if (uop0_is_fp_i) begin
                    sq_q[sq_slot0].mask       <= 8'd0;
                    sq_q[sq_slot0].is_fp      <= 1'b1;
                    sq_q[sq_slot0].prs2_fp    <= uop0_prs2_fp_i;
                    if (uop0_prs2_fp_ready_i) begin
                        sq_q[sq_slot0].data       <= fprf_r3_data_i;
                        sq_q[sq_slot0].data_valid <= 1'b1;
                    end else if (wb0_fp_valid_i && (wb0_fp_paddr_i == uop0_prs2_fp_i)) begin
                        sq_q[sq_slot0].data       <= wb0_fp_data_i;
                        sq_q[sq_slot0].data_valid <= 1'b1;
                    end else if (p2_fp_wb_fire && (p2_comp_prd_fp == uop0_prs2_fp_i)) begin
                        sq_q[sq_slot0].data       <= p2_comp_data;
                        sq_q[sq_slot0].data_valid <= 1'b1;
                    end else if (p3_fp_wb_fire && (p3_comp_prd_fp == uop0_prs2_fp_i)) begin
                        sq_q[sq_slot0].data       <= p3_comp_data;
                        sq_q[sq_slot0].data_valid <= 1'b1;
                    end else begin
                        sq_q[sq_slot0].data_valid <= 1'b0;
                    end
                end else begin
                    sq_q[sq_slot0].mask       <= 8'd0;
                    sq_q[sq_slot0].is_fp      <= 1'b0;
                    sq_q[sq_slot0].prs2_fp    <= 6'd0;
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
                    end else if (wb3_valid_i && wb3_comp_ack_i && !wb3_comp_exception_i && (wb3_pnew_i == uop0_prs2_i) && (wb3_pnew_i != 7'd0)) begin
                        sq_q[sq_slot0].data       <= wb3_data_i;
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
                    sq_q[sq_target_slot1].is_fp      <= 1'b0;
                    sq_q[sq_target_slot1].prs2_fp    <= 6'd0;
                end else if (uop1_is_fp_i) begin
                    sq_q[sq_target_slot1].mask       <= 8'd0;
                    sq_q[sq_target_slot1].is_fp      <= 1'b1;
                    sq_q[sq_target_slot1].prs2_fp    <= uop1_prs2_fp_i;
                    if (uop1_prs2_fp_ready_i) begin
                        sq_q[sq_target_slot1].data       <= fprf_r3_data_i;
                        sq_q[sq_target_slot1].data_valid <= 1'b1;
                    end else if (wb0_fp_valid_i && (wb0_fp_paddr_i == uop1_prs2_fp_i)) begin
                        sq_q[sq_target_slot1].data       <= wb0_fp_data_i;
                        sq_q[sq_target_slot1].data_valid <= 1'b1;
                    end else if (p2_fp_wb_fire && (p2_comp_prd_fp == uop1_prs2_fp_i)) begin
                        sq_q[sq_target_slot1].data       <= p2_comp_data;
                        sq_q[sq_target_slot1].data_valid <= 1'b1;
                    end else if (p3_fp_wb_fire && (p3_comp_prd_fp == uop1_prs2_fp_i)) begin
                        sq_q[sq_target_slot1].data       <= p3_comp_data;
                        sq_q[sq_target_slot1].data_valid <= 1'b1;
                    end else begin
                        sq_q[sq_target_slot1].data_valid <= 1'b0;
                    end
                end else begin
                    sq_q[sq_target_slot1].mask       <= 8'd0;
                    sq_q[sq_target_slot1].is_fp      <= 1'b0;
                    sq_q[sq_target_slot1].prs2_fp    <= 6'd0;
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
                    end else if (wb3_valid_i && wb3_comp_ack_i && !wb3_comp_exception_i && (wb3_pnew_i == uop1_prs2_i) && (wb3_pnew_i != 7'd0)) begin
                        sq_q[sq_target_slot1].data       <= wb3_data_i;
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

                // External Coherence Snoop Load Hazard Invalidation (§8.3, PROP_M7_36)
                if (snoop_req_valid_i && snoop_do_inv) begin
                    for (int l = 0; l < LQ_DEPTH; l++) begin
                        if (snoop_lq_match[l]) begin
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

            // -----------------------------------------------------------------
            // N. Uncached MMIO State Machine (§4)
            // -----------------------------------------------------------------
            case (mmio_state_q)
                MMIO_IDLE: begin
                    mmio_req_valid_o <= 1'b0;
                    if (mmio_cand_valid && !flush_valid_i) begin
                        mmio_state_q        <= MMIO_REQ;
                        mmio_req_valid_o    <= 1'b1;
                        mmio_req_addr_o     <= mmio_cand_addr;
                        mmio_req_is_store_o <= mmio_cand_is_store;
                        mmio_req_size_o     <= {1'b0, mmio_cand_size};
                        mmio_req_wdata_o    <= mmio_cand_wdata;
                        mmio_req_wstrb_o    <= mmio_cand_wstrb;

                        mmio_is_store_q     <= mmio_cand_is_store;
                        mmio_lq_idx_q       <= mmio_cand_lq_idx;
                        mmio_sq_idx_q       <= mmio_cand_sq_idx;
                        mmio_rob_idx_q      <= mmio_cand_rob_idx;
                        mmio_rob_epoch_q    <= mmio_cand_rob_epoch;
                        mmio_addr_q         <= mmio_cand_addr;
                        mmio_size_q         <= {1'b0, mmio_cand_size};
                        mmio_subop_q        <= mmio_cand_subop;
                        mmio_pnew_q         <= mmio_cand_pnew;
                        mmio_is_fp_q        <= mmio_cand_is_fp;
                        mmio_prd_fp_q       <= mmio_cand_prd_fp;
                        mmio_wdata_q        <= mmio_cand_wdata;
                        mmio_wstrb_q        <= mmio_cand_wstrb;
                    end
                end

                MMIO_REQ: begin
                    if (flush_valid_i && !mmio_req_ready_i) begin
                        mmio_req_valid_o <= 1'b0;
                        mmio_state_q     <= MMIO_IDLE;
                    end else if (mmio_req_ready_i) begin
                        mmio_req_valid_o <= 1'b0;
                        if (mmio_rsp_valid_i) begin
                            mmio_state_q <= MMIO_IDLE;
                        end else begin
                            mmio_state_q <= MMIO_WAIT_RSP;
                        end
                    end
                end

                MMIO_WAIT_RSP: begin
                    mmio_req_valid_o <= 1'b0;
                    if (mmio_rsp_valid_i) begin
                        mmio_state_q <= MMIO_IDLE;
                    end
                end

                default: begin
                    mmio_state_q     <= MMIO_IDLE;
                    mmio_req_valid_o <= 1'b0;
                end
            endcase

            if (mmio_comp_valid) begin
                if (!mmio_is_store_q) begin
                    lq_q[mmio_lq_idx_q].completed   <= 1'b1;
                    lq_q[mmio_lq_idx_q].wb_done     <= 1'b1;
                    lq_q[mmio_lq_idx_q].result_data <= mmio_formatted_rdata;
                end else begin
                    sq_q[mmio_sq_idx_q].completed   <= 1'b1;
                    sq_q[mmio_sq_idx_q].drained     <= 1'b1;
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
            if (l1d0_issue_fire && (lq_q[cand_slot0].replay_safe || lq_q[cand_slot0].is_mmio || lq_q[cand_slot0].is_lr)) begin
                for (int s = 0; s < SQ_DEPTH; s++) begin
                    if (lq_q[cand_slot0].sq_older_mask[s] && !sq_q[s].pa_valid) begin
                        $fatal(1, "[LSU QUEUES ASSERTION FAILED] Lane 0 ineligible/replay-safe load issued to L1D with older store PA unresolved!");
                    end
                end
            end
            if (l1d1_issue_fire && (lq_q[cand_slot1].replay_safe || lq_q[cand_slot1].is_mmio || lq_q[cand_slot1].is_lr)) begin
                for (int s = 0; s < SQ_DEPTH; s++) begin
                    if (lq_q[cand_slot1].sq_older_mask[s] && !sq_q[s].pa_valid) begin
                        $fatal(1, "[LSU QUEUES ASSERTION FAILED] Lane 1 ineligible/replay-safe load issued to L1D with older store PA unresolved!");
                    end
                end
            end
            // Assertion 5: Forwarding must NEVER occur on partial overlap
            if (fwd0_issue_fire && lq_entry_fwd_stall[cand_slot0]) begin
                $fatal(1, "[LSU QUEUES ASSERTION FAILED] Lane 0 forwarding occurred during partial overlap stall!");
            end
            if (fwd1_issue_fire && lq_entry_fwd_stall[cand_slot1]) begin
                $fatal(1, "[LSU QUEUES ASSERTION FAILED] Lane 1 forwarding occurred during partial overlap stall!");
            end
            // Assertion 10: Faulting stores must NEVER transition to committed
            for (int s = 0; s < SQ_DEPTH; s++) begin
                if (sq_q[s].valid && sq_q[s].exception_pending && sq_q[s].committed) begin
                    $fatal(1, "[LSU QUEUES ASSERTION FAILED] Faulting store committed!");
                end
            end

            // P0-3 Assertion: Failed SC must NEVER forward
            if (fwd0_issue_fire && sq_q[lq_entry_youngest_s[cand_slot0]].is_sc && (!sq_q[lq_entry_youngest_s[cand_slot0]].completed || !sq_q[lq_entry_youngest_s[cand_slot0]].sc_success)) begin
                $fatal(1, "[LSU QUEUES ASSERTION FAILED] Failed or unresolved SC forwarded data to Lane 0 load!");
            end
            if (fwd1_issue_fire && sq_q[lq_entry_youngest_s[cand_slot1]].is_sc && (!sq_q[lq_entry_youngest_s[cand_slot1]].completed || !sq_q[lq_entry_youngest_s[cand_slot1]].sc_success)) begin
                $fatal(1, "[LSU QUEUES ASSERTION FAILED] Failed or unresolved SC forwarded data to Lane 1 load!");
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
            if (retire_valid_i[0] && retire0_lq_found && lsu_violation_valid_o && (lsu_violation_rob_idx_o == retire_rob_idx_i[0])) begin
                $fatal(1, "[B1_ASSERTION FAILED] Same-cycle violation did not dominate retirement at slot 0!");
            end
            if (retire_valid_i[1] && retire1_lq_found && lsu_violation_valid_o && (lsu_violation_rob_idx_o == retire_rob_idx_i[1])) begin
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
            if (l1d0_issue_fire && lq_q[cand_slot0].replay_safe && (lq_q[cand_slot0].sq_unresolved_mask != 16'd0)) begin
                $fatal(1, "[B1_ASSERTION FAILED] Lane 0 replay-safe load issued speculatively!");
            end
            if (l1d1_issue_fire && lq_q[cand_slot1].replay_safe && (lq_q[cand_slot1].sq_unresolved_mask != 16'd0)) begin
                $fatal(1, "[B1_ASSERTION FAILED] Lane 1 replay-safe load issued speculatively!");
            end

            // Non-speculative/MMIO/LR loads never set speculative-load marker
            if ((l1d0_issue_fire || fwd0_issue_fire) && (lq_q[cand_slot0].is_mmio || lq_q[cand_slot0].is_lr) && lq_entry_is_speculative[cand_slot0]) begin
                $fatal(1, "[B1_ASSERTION FAILED] Lane 0 MMIO or LR load marked speculative!");
            end
            if ((l1d1_issue_fire || fwd1_issue_fire) && (lq_q[cand_slot1].is_mmio || lq_q[cand_slot1].is_lr) && lq_entry_is_speculative[cand_slot1]) begin
                $fatal(1, "[B1_ASSERTION FAILED] Lane 1 MMIO or LR load marked speculative!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_LSU_QUEUES_SV
