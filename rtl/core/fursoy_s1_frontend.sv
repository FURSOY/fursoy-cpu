`ifndef FURSOY_S1_FRONTEND_SV
`define FURSOY_S1_FRONTEND_SV

// =============================================================================
// Fursoy Slice-1 Frontend Subsystem — Milestone 4
// =============================================================================
// Integrates:
// - F0 GenPC: Deterministic redirect priority arbiter, odd-slot next-PC +4 calculation.
// - F1 ReqMem: Virtual instruction address generation, ITLB lookup, parallel BPU query.
// - F2 RspMem: Non-blocking L1I cache lookup, 2 I-MSHRs, F2 synchronous skid buffer.
// - F3 Align: 64-bit fetch block extraction, odd-slot masking, gated early JAL redirect.
// - F4 Queue: 12-entry decoupled Fetch Queue FIFO.
// - D0 Decode: 2-wide parallel decoder with decode exception bypass.
// - M4 System Serialization Controller for FENCE.I.
// - Hardware Performance Event Counters (18 architectural telemetry counters).
// Reference: docs/architecture/slice1-m4-frontend-v1.md
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_bpu.sv"
`include "fursoy_s1_itlb.sv"
`include "fursoy_s1_ptw.sv"
`include "fursoy_s1_l1i.sv"
`include "fursoy_s1_fetch_queue.sv"
`include "fursoy_s1_decode.sv"
`include "fursoy_s1_serialization.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_frontend
    import fursoy_s1_pkg::*;
#(
    parameter logic [63:0] RESET_PC = 64'h0000_0000_8000_0000
) (
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              frontend_en_i,        // High = active, Low = held in reset
    input  logic              wfi_sleep_i,
    input  logic              sfence_active_i,

    // Architectural System State (from CSRs / Privilege Mode)
    input  logic [1:0]        priv_mode_i,          // 00=U, 01=S, 11=M
    input  logic [63:0]       mstatus_i,
    input  logic [63:0]       satp_i,
    input  logic              pmp_allow_i,          // PMP execution permission

    // -------------------------------------------------------------------------
    // Redirect Interfaces (Deterministic Priority Hierarchy per Section 11)
    // -------------------------------------------------------------------------
    // Priority 2: Trap (ROB Head)
    input  logic              trap_valid_i,
    input  logic [63:0]       trap_target_i,

    // Priority 3: Return (MRET / SRET)
    input  logic              mret_valid_i,
    input  logic [63:0]       mret_target_i,

    // Priority 4: Port 0 Mispredict Recovery
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  chkpt_idx_t        recover_chkpt_id_i,
    input  logic              recover_actual_taken_i,
    input  logic [63:0]       recover_target_i,

    // Milestone 5 Phase B1: ROB-Head Memory Replay Interface
    input  logic              mem_replay_valid_i,
    input  logic [63:0]       mem_replay_pc_i,

    // Flush Input (Traps, Interrupts)
    input  logic              flush_valid_i,

    // -------------------------------------------------------------------------
    // SFENCE.VMA Interface
    // -------------------------------------------------------------------------
    input  logic              sfence_vma_valid_i,
    input  logic [63:0]       sfence_vma_va_i,
    input  logic [15:0]       sfence_vma_asid_i,

    // -------------------------------------------------------------------------
    // Branch Checkpoint Capture at Rename (from M1 Substrate)
    // -------------------------------------------------------------------------
    input  logic              chkpt_alloc_valid0_i,
    input  chkpt_idx_t        chkpt_alloc_id0_i,
    input  ghr_t              chkpt_alloc_ghr0_i,
    input  ras_chkpt_t        chkpt_alloc_ras0_i,
    input  tage_csr_bundle_t  chkpt_alloc_csr0_i,

    input  logic              chkpt_alloc_valid1_i,
    input  chkpt_idx_t        chkpt_alloc_id1_i,
    input  ghr_t              chkpt_alloc_ghr1_i,
    input  ras_chkpt_t        chkpt_alloc_ras1_i,
    input  tage_csr_bundle_t  chkpt_alloc_csr1_i,

    // Predictor Training from Resolved Control-Flow (Port 0 WB)
    input  logic              train_valid_i,
    input  logic [63:0]       train_pc_i,
    input  logic              train_actual_taken_i,
    input  logic [63:0]       train_actual_target_i,
    input  branch_type_t      train_br_type_i,
    input  ghr_t              train_ghr_i,

    // -------------------------------------------------------------------------
    // Decoded Micro-ops Handoff to M1 Rename / Dispatch
    // -------------------------------------------------------------------------
    output logic              uop0_valid_o,
    output uop_decoded_t      uop0_o,
    output ghr_t              uop0_pre_ghr_o,
    output ras_chkpt_t        uop0_ras_chkpt_o,
    output tage_csr_bundle_t  uop0_csr_chkpt_o,

    output logic              uop1_valid_o,
    output uop_decoded_t      uop1_o,
    output ghr_t              uop1_pre_ghr_o,
    output ras_chkpt_t        uop1_ras_chkpt_o,
    output tage_csr_bundle_t  uop1_csr_chkpt_o,

    input  logic [1:0]        rename_ack_i,         // M1 dispatch acceptance

    // -------------------------------------------------------------------------
    // System Serialization Controller Interface (FENCE.I)
    // -------------------------------------------------------------------------
    input  rob_idx_t          rob_head_i,
    input  rob_epoch_t        retire_epoch_i,
    input  logic              rob_retire_valid_i,
    output logic              retire_ready_o,

    input  logic              sq_empty_i,
    output logic              dcache_clean_all_req_o,
    input  logic              dcache_clean_all_done_i,

    input  logic              alloc0_fence_i_i,
    input  rob_idx_t          alloc0_rob_idx_i,
    input  rob_epoch_t        alloc0_rob_epoch_i,
    input  logic [63:0]       alloc0_pc_i,

    input  logic              alloc1_fence_i_i,
    input  rob_idx_t          alloc1_rob_idx_i,
    input  rob_epoch_t        alloc1_rob_epoch_i,
    input  logic [63:0]       alloc1_pc_i,

    // -------------------------------------------------------------------------
    // External Memory Refill / PTW Bus Interface
    // -------------------------------------------------------------------------
    // L1I Refill Bus (64-byte line)
    output logic              l1i_bus_rd_req_valid_o,
    output logic [49:0]       l1i_bus_rd_req_addr_o,
    output logic [1:0]        l1i_bus_rd_req_tag_o,
    input  logic              l1i_bus_rd_req_ready_i,

    input  logic              l1i_bus_rd_rsp_valid_i,
    input  logic [1:0]        l1i_bus_rd_rsp_tag_i,
    input  logic [511:0]      l1i_bus_rd_rsp_data_i,
    input  logic              l1i_bus_rd_rsp_error_i,

    // PTW Memory Bus (64-bit PTE read)
    output logic              ptw_mem_req_valid_o,
    output logic [55:0]       ptw_mem_req_addr_o,
    input  logic              ptw_mem_req_ready_i,

    input  logic              ptw_mem_rsp_valid_i,
    input  logic [63:0]       ptw_mem_rsp_data_i,
    input  logic              ptw_mem_rsp_error_i,

    // M3 DTLB Request / Response to Shared PTW
    input  logic              dtlb_req_valid_i,
    input  tr_id_t            dtlb_req_tr_id_i,
    input  logic [26:0]       dtlb_req_vpn_i,
    input  logic              dtlb_req_is_store_i,
    input  logic              dtlb_req_is_amo_i,
    output logic              dtlb_req_ready_o,

    output logic              dtlb_rsp_valid_o,
    output tr_id_t            dtlb_rsp_tr_id_o,
    output logic [55:0]       dtlb_rsp_pa_o,
    output logic              dtlb_rsp_page_fault_o,
    output logic              dtlb_rsp_access_fault_o,
    output logic [1:0]        dtlb_rsp_level_o,
    output logic [63:0]       dtlb_rsp_pte_o,

    // -------------------------------------------------------------------------
    // Diagnostics & Performance Counters
    // -------------------------------------------------------------------------
    output logic [4:0]        fetch_queue_count_o,
    output logic              fetch_queue_full_o,
    output logic              fetch_queue_empty_o,

    output logic [63:0]       hpm_fetch_words_o,
    output logic [63:0]       hpm_fetch_uops_o,
    output logic [63:0]       hpm_fetch_empty_cyc_o,
    output logic [63:0]       hpm_fetch_full_cyc_o,
    output logic [63:0]       hpm_l1i_hits_o,
    output logic [63:0]       hpm_l1i_misses_o,
    output logic [63:0]       hpm_itlb_hits_o,
    output logic [63:0]       hpm_itlb_misses_o,
    output logic [63:0]       hpm_btb_hits_o,
    output logic [63:0]       hpm_btb_misses_o,
    output logic [63:0]       hpm_bpu_cond_pred_o,
    output logic [63:0]       hpm_ras_calls_o,
    output logic [63:0]       hpm_ras_returns_o,
    output logic [63:0]       hpm_fence_i_flushes_o,
    output logic [63:0]       hpm_redirect_cyc_o,

    // Diagnostics
    output logic [2:0]        diag_grants_since_itlb_o,

    // Observability & Telemetry (Milestone 5)
    output logic              event_fetch_cycles_o,
    output logic              event_fetch_blocks_o,
    output logic [1:0]        event_fetch_uops_o,
    output logic              event_fetch_fq_starved_o,
    output logic              event_fetch_fq_full_o,
    output logic              event_fetch_odd_slot_o,
    output logic              event_l1i_hits_o,
    output logic              event_l1i_misses_o,
    output logic [1:0]        event_l1i_imshr_occ_o,
    output logic              event_itlb_misses_o,
    output logic              event_btb_queries_o,
    output logic              event_btb_hits_o,
    output logic              event_bpu_cond_pred_o,
    output logic              event_ras_call_push_o,
    output logic              event_ras_ret_pop_o,

    // Milestone 9 Phase A: Architectural Fetch PC Export
    output logic [63:0]       fe_pc_o,
    output logic              fence_i_at_head_o,
    output logic              fence_i_flush_o
);

    assign fe_pc_o         = f0_pc_q;
    assign fence_i_flush_o = fence_i_redirect_valid;

    // =========================================================================
    // Subsystem Interconnect Signals
    // =========================================================================
    // Pipeline control
    wire flush_all = rst_i || !frontend_en_i || flush_valid_i;

    // FENCE.I serialization signals
    wire        fence_i_l1i_inval;
    wire        fence_i_frontend_purge;
    wire        fence_i_redirect_valid;
    wire [63:0] fence_i_redirect_target;
    wire        fence_i_event_done;

    // BPU Prediction signals
    wire        bpu_pred_redirect;
    wire [63:0] bpu_pred_target;
    wire        bpu_pred_slot;

    wire        slot0_btb_hit;
    wire        slot0_pred_taken;
    wire [63:0] slot0_pred_target;
    branch_type_t slot0_br_type;
    ghr_t             slot0_pre_ghr;
    ras_chkpt_t       slot0_ras_chkpt;
    tage_csr_bundle_t slot0_csr_chkpt;

    wire        slot1_btb_hit;
    wire        slot1_pred_taken;
    wire [63:0] slot1_pred_target;
    branch_type_t slot1_br_type;
    ghr_t             slot1_pre_ghr;
    ras_chkpt_t       slot1_ras_chkpt;
    tage_csr_bundle_t slot1_csr_chkpt;

    // Stage F3 Early JAL recovery signals
    logic             early_jal_redirect;
    logic [63:0]      early_jal_target;
    ghr_t             early_jal_restore_ghr;
    ras_chkpt_t       early_jal_restore_ras;
    tage_csr_bundle_t early_jal_restore_csr;

    // PTW to ITLB superpage and PTE channels
    wire [1:0]   ptw_to_itlb_rsp_level;
    wire [63:0]  ptw_to_itlb_rsp_pte;

    // ITLB signals
    wire        itlb_rsp_valid;
    wire [55:0] itlb_rsp_pa;
    wire        itlb_rsp_page_fault;
    wire        itlb_rsp_access_fault;
    wire        itlb_busy;
    wire        itlb_event_hit;
    wire        itlb_event_miss;
    wire        l1i_event_hit;
    wire        l1i_event_miss;
    wire [1:0]  l1i_imshr_occ;
    wire        btb_event_hit;
    wire        btb_event_miss;
    wire        bpu_event_cond_pred;
    wire        bpu_event_ras_call;
    wire        bpu_event_ras_ret;

    wire        ptw_to_itlb_req_valid;
    wire        ptw_to_itlb_req_itrt_id;
    wire [26:0] ptw_to_itlb_req_vpn;
    wire        ptw_to_itlb_req_ready;

    wire        ptw_to_itlb_rsp_valid;
    wire        ptw_to_itlb_rsp_itrt_id;
    wire [55:0] ptw_to_itlb_rsp_pa;
    wire        ptw_to_itlb_rsp_page_fault;
    wire        ptw_to_itlb_rsp_access_fault;

    // L1I signals
    wire        l1i_ready;
    wire        f3_valid;
    wire [63:0] f3_pc;
    wire [63:0] f3_data;
    wire        f3_exception_valid;
    wire [4:0]  f3_exception_cause;
    wire [63:0] f3_fault_addr;

    wire        f2_stall_f0;
    wire        f2_stall_f1;

    // Fetch Queue signals
    wire [1:0]  push_ack;
    wire        fq_empty;
    wire        fq_full;
    wire [4:0]  fq_count;
    wire [4:0]  fq_free_count;

    wire        fq_pop0_valid;
    fetch_queue_entry_t fq_pop0_entry;
    wire        fq_pop1_valid;
    fetch_queue_entry_t fq_pop1_entry;

    assign fetch_queue_count_o = fq_count;
    assign fetch_queue_full_o  = fq_full;
    assign fetch_queue_empty_o = fq_empty;

    // Global redirect notification to kill in-flight waiters and flush stages
    wire any_redirect = trap_valid_i || mem_replay_valid_i || mret_valid_i || recover_valid_i ||
                        fence_i_redirect_valid || early_jal_redirect || flush_valid_i || sfence_vma_valid_i;

    wire backend_flush = trap_valid_i || mem_replay_valid_i || mret_valid_i || recover_valid_i ||
                         fence_i_redirect_valid || fence_i_frontend_purge || flush_valid_i || sfence_vma_valid_i;

    // =========================================================================
    // 1. Stage F0: Next-PC Generation (`GenPC`) — Section 3.1 & 11
    // =========================================================================
    logic [63:0] f0_pc_q;
    logic        f0_valid_q;

    // Sequential next-PC calculation per Section 3.1
    wire [63:0] seq_next_pc = (f0_pc_q[2] == 1'b0)
                            ? (f0_pc_q + 64'd8)
                            : ({f0_pc_q[63:3] + 1'b1, 3'b000});

    // Exact Priority Hierarchy per Section 11:
    // 1. Reset > 2. Trap > 3. MRET/SRET > 4. Port 0 Mispredict >
    // 5. FENCE.I Redirect > 6. Early JAL > 7. BPU Predict > 8. Sequential Next-PC
    logic [63:0] next_fetch_pc;
    logic        next_fetch_valid;

    always_comb begin
        if (rst_i || !frontend_en_i) begin
            next_fetch_pc    = RESET_PC;
            next_fetch_valid = frontend_en_i;
        end else if (trap_valid_i) begin
            next_fetch_pc    = trap_target_i;
            next_fetch_valid = 1'b1;
        end else if (mem_replay_valid_i) begin
            next_fetch_pc    = mem_replay_pc_i;
            next_fetch_valid = 1'b1;
        end else if (mret_valid_i) begin
            next_fetch_pc    = mret_target_i;
            next_fetch_valid = 1'b1;
        end else if (recover_valid_i) begin
            next_fetch_pc    = recover_target_i;
            next_fetch_valid = 1'b1;
        end else if (fence_i_redirect_valid) begin
            next_fetch_pc    = fence_i_redirect_target;
            next_fetch_valid = 1'b1;
        end else if (early_jal_redirect) begin
            next_fetch_pc    = early_jal_target;
            next_fetch_valid = 1'b1;
        end else if (wfi_sleep_i) begin
            next_fetch_pc    = f0_pc_q;
            next_fetch_valid = 1'b0;
        end else if (bpu_pred_redirect && !f2_stall_f0 && (bpu_pred_target != 64'd0)) begin
            next_fetch_pc    = bpu_pred_target;
            next_fetch_valid = 1'b1;
        end else if (!f2_stall_f0 && !sfence_active_i && itlb_rsp_valid && l1i_ready && !f3_exception_valid) begin
            next_fetch_pc    = seq_next_pc;
            next_fetch_valid = 1'b1;
        end else begin
            next_fetch_pc    = f0_pc_q;
            next_fetch_valid = f0_valid_q;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!frontend_en_i) begin
            f0_pc_q    <= RESET_PC;
            f0_valid_q <= 1'b0;
        end else if (rst_i) begin
            f0_pc_q    <= RESET_PC;
            f0_valid_q <= 1'b1;
        end else begin
            f0_pc_q    <= next_fetch_pc;
            f0_valid_q <= next_fetch_valid;
        end
    end

    // =========================================================================
    // 2. Stage F1: Memory Request & ITLB Lookup
    // =========================================================================
    wire f1_fire = f0_valid_q && !wfi_sleep_i && !sfence_active_i && !f2_stall_f1 && !itlb_busy && l1i_ready && !f3_exception_valid && !any_redirect;

    /* verilator lint_off PINCONNECTEMPTY */
    // ITLB & Persistent ITRT
    fursoy_s1_itlb u_itlb (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i || !frontend_en_i),
        .priv_mode_i              (priv_mode_i),
        .satp_i                   (satp_i),
        .pmp_allow_i              (pmp_allow_i),

        .trans_req_valid_i        (f1_fire),
        .trans_req_va_i           (f0_pc_q),
        .trans_rsp_valid_o        (itlb_rsp_valid),
        .trans_rsp_pa_o           (itlb_rsp_pa),
        .trans_rsp_page_fault_o   (itlb_rsp_page_fault),
        .trans_rsp_access_fault_o (itlb_rsp_access_fault),
        .trans_busy_o             (itlb_busy),

        .redirect_flush_i         (any_redirect || fence_i_frontend_purge),

        .sfence_vma_valid_i       (sfence_vma_valid_i),
        .sfence_vma_va_i          (sfence_vma_va_i),
        .sfence_vma_asid_i        (sfence_vma_asid_i),

        .ptw_req_valid_o          (ptw_to_itlb_req_valid),
        .ptw_req_itrt_id_o        (ptw_to_itlb_req_itrt_id),
        .ptw_req_vpn_o            (ptw_to_itlb_req_vpn),
        .ptw_req_ready_i          (ptw_to_itlb_req_ready),

        .ptw_rsp_valid_i          (ptw_to_itlb_rsp_valid),
        .ptw_rsp_itrt_id_i        (ptw_to_itlb_rsp_itrt_id),
        .ptw_rsp_pa_i             (ptw_to_itlb_rsp_pa),
        .ptw_rsp_page_fault_i     (ptw_to_itlb_rsp_page_fault),
        .ptw_rsp_access_fault_i   (ptw_to_itlb_rsp_access_fault),
        .ptw_rsp_level_i          (ptw_to_itlb_rsp_level),
        .ptw_rsp_pte_i            (ptw_to_itlb_rsp_pte),

        .event_itlb_hit_o         (itlb_event_hit),
        .event_itlb_miss_o        (itlb_event_miss)
    );

    // Shared PTW Instance
    fursoy_s1_ptw u_ptw (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i || !frontend_en_i),
        .priv_mode_i              (priv_mode_i),
        .mstatus_i                (mstatus_i),
        .satp_i                   (satp_i),
        .sfence_vma_valid_i       (sfence_vma_valid_i),
        .sfence_active_i          (sfence_active_i),

        // M3 DTLB Channel
        .dtlb_req_valid_i         (dtlb_req_valid_i),
        .dtlb_req_tr_id_i         (dtlb_req_tr_id_i),
        .dtlb_req_vpn_i           (dtlb_req_vpn_i),
        .dtlb_req_is_store_i      (dtlb_req_is_store_i),
        .dtlb_req_is_amo_i        (dtlb_req_is_amo_i),
        .dtlb_req_ready_o         (dtlb_req_ready_o),

        .dtlb_rsp_valid_o         (dtlb_rsp_valid_o),
        .dtlb_rsp_tr_id_o         (dtlb_rsp_tr_id_o),
        .dtlb_rsp_pa_o            (dtlb_rsp_pa_o),
        .dtlb_rsp_page_fault_o    (dtlb_rsp_page_fault_o),
        .dtlb_rsp_access_fault_o  (dtlb_rsp_access_fault_o),
        .dtlb_rsp_level_o         (dtlb_rsp_level_o),
        .dtlb_rsp_pte_o           (dtlb_rsp_pte_o),

        // M4 ITLB Channel
        .itlb_req_valid_i         (ptw_to_itlb_req_valid),
        .itlb_req_itrt_id_i       (ptw_to_itlb_req_itrt_id),
        .itlb_req_vpn_i           (ptw_to_itlb_req_vpn),
        .itlb_req_ready_o         (ptw_to_itlb_req_ready),

        .itlb_rsp_valid_o         (ptw_to_itlb_rsp_valid),
        .itlb_rsp_itrt_id_o       (ptw_to_itlb_rsp_itrt_id),
        .itlb_rsp_pa_o            (ptw_to_itlb_rsp_pa),
        .itlb_rsp_page_fault_o    (ptw_to_itlb_rsp_page_fault),
        .itlb_rsp_access_fault_o  (ptw_to_itlb_rsp_access_fault),
        .itlb_rsp_level_o         (ptw_to_itlb_rsp_level),
        .itlb_rsp_pte_o           (ptw_to_itlb_rsp_pte),

        // Coherent Memory Read Port (64-bit PTE reads outside L1D)
        .mem_req_valid_o          (ptw_mem_req_valid_o),
        .mem_req_addr_o           (ptw_mem_req_addr_o),
        .mem_req_ready_i          (ptw_mem_req_ready_i),

        .mem_rsp_valid_i          (ptw_mem_rsp_valid_i),
        .mem_rsp_data_i           (ptw_mem_rsp_data_i),
        .mem_rsp_error_i          (ptw_mem_rsp_error_i),

        .diag_grants_since_itlb_o (diag_grants_since_itlb_o)
    );

    wire f1_to_l1i_valid = f0_valid_q && !wfi_sleep_i && !sfence_active_i && itlb_rsp_valid && !f2_stall_f1 && l1i_ready && !f3_exception_valid && !any_redirect;
    wire bpu_lookup_valid = f1_to_l1i_valid && !itlb_rsp_page_fault && !itlb_rsp_access_fault;

    // Dynamic Branch Prediction Subsystem (BPU)
    fursoy_s1_bpu u_bpu (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i || !frontend_en_i),

        .fetch_pc_i               (f0_pc_q),
        .fetch_lookup_valid_i     (bpu_lookup_valid),

        .pred_redirect_o          (bpu_pred_redirect),
        .pred_target_o            (bpu_pred_target),
        .pred_slot_o              (bpu_pred_slot),

        .slot0_btb_hit_o          (slot0_btb_hit),
        .slot0_pred_taken_o       (slot0_pred_taken),
        .slot0_pred_target_o      (slot0_pred_target),
        .slot0_br_type_o          (slot0_br_type),
        .slot0_pre_ghr_o          (slot0_pre_ghr),
        .slot0_ras_chkpt_o        (slot0_ras_chkpt),
        .slot0_csr_chkpt_o        (slot0_csr_chkpt),

        .slot1_btb_hit_o          (slot1_btb_hit),
        .slot1_pred_taken_o       (slot1_pred_taken),
        .slot1_pred_target_o      (slot1_pred_target),
        .slot1_br_type_o          (slot1_br_type),
        .slot1_pre_ghr_o          (slot1_pre_ghr),
        .slot1_ras_chkpt_o        (slot1_ras_chkpt),
        .slot1_csr_chkpt_o        (slot1_csr_chkpt),

        .early_jal_valid_i        (early_jal_redirect),
        .early_jal_restore_ghr_i  (early_jal_restore_ghr),
        .early_jal_restore_ras_i  (early_jal_restore_ras),
        .early_jal_restore_csr_i  (early_jal_restore_csr),

        // Branch Checkpoint Allocation at Rename (from M1 Substrate)
        .chkpt_alloc_valid0_i     (chkpt_alloc_valid0_i),
        .chkpt_alloc_id0_i        (chkpt_alloc_id0_i),
        .chkpt_alloc_ghr0_i       (chkpt_alloc_ghr0_i),
        .chkpt_alloc_ras0_i       (chkpt_alloc_ras0_i),
        .chkpt_alloc_csr0_i       (chkpt_alloc_csr0_i),

        .chkpt_alloc_valid1_i     (chkpt_alloc_valid1_i),
        .chkpt_alloc_id1_i        (chkpt_alloc_id1_i),
        .chkpt_alloc_ghr1_i       (chkpt_alloc_ghr1_i),
        .chkpt_alloc_ras1_i       (chkpt_alloc_ras1_i),
        .chkpt_alloc_csr1_i       (chkpt_alloc_csr1_i),

        .slot0_tage_pred_o        (),
        .slot1_tage_pred_o        (),
        .slot0_tage_prov_o        (),
        .slot0_tage_alt_o         (),
        .slot0_tage_alt_used_o    (),
        .slot1_tage_prov_o        (),
        .slot1_tage_alt_o         (),
        .slot1_tage_alt_used_o    (),

        .recover_valid_i          (recover_valid_i),
        .recover_chkpt_id_i       (recover_chkpt_id_i),
        .recover_actual_taken_i   (recover_actual_taken_i),
        .recover_actual_target_i  (recover_target_i),

        .flush_valid_i            (flush_valid_i || fence_i_frontend_purge),

        .train_valid_i            (train_valid_i),
        .train_pc_i               (train_pc_i),
        .train_actual_taken_i     (train_actual_taken_i),
        .train_actual_target_i    (train_actual_target_i),
        .train_br_type_i          (train_br_type_i),
        .train_ghr_i              (train_ghr_i),

        .event_btb_hit_o          (btb_event_hit),
        .event_btb_miss_o         (btb_event_miss),
        .event_cond_pred_o        (bpu_event_cond_pred),
        .event_ras_call_o         (bpu_event_ras_call),
        .event_ras_ret_o          (bpu_event_ras_ret)
    );

    // =========================================================================
    // 2.1 BPU Prediction Metadata FIFO (F0 -> F3 Pipeline Synchronization)
    // =========================================================================
    typedef struct packed {
        logic [63:0]       pc;
        logic              slot0_btb_hit;
        logic              slot0_pred_taken;
        logic [63:0]       slot0_pred_target;
        branch_type_t      slot0_br_type;
        ghr_t              slot0_pre_ghr;
        ras_chkpt_t        slot0_ras_chkpt;
        tage_csr_bundle_t  slot0_csr_chkpt;
        logic              slot1_btb_hit;
        logic              slot1_pred_taken;
        logic [63:0]       slot1_pred_target;
        branch_type_t      slot1_br_type;
        ghr_t              slot1_pre_ghr;
        ras_chkpt_t        slot1_ras_chkpt;
        tage_csr_bundle_t  slot1_csr_chkpt;
    } bpu_meta_entry_t;

    localparam int BPU_FIFO_DEPTH = 8;
    bpu_meta_entry_t bpu_fifo_q [BPU_FIFO_DEPTH];
    logic [2:0]      bpu_fifo_head_q;
    logic [2:0]      bpu_fifo_tail_q;
    logic [3:0]      bpu_fifo_count_q;

    wire bpu_fifo_push = f1_to_l1i_valid && (bpu_fifo_count_q < 4'd8);
    wire bpu_fifo_pop  = f3_valid && !stall_downstream && (bpu_fifo_count_q != 4'd0);

    bpu_meta_entry_t bpu_push_entry;
    always_comb begin
        bpu_push_entry.pc                = f0_pc_q;
        bpu_push_entry.slot0_btb_hit     = slot0_btb_hit;
        bpu_push_entry.slot0_pred_taken  = slot0_pred_taken;
        bpu_push_entry.slot0_pred_target = slot0_pred_target;
        bpu_push_entry.slot0_br_type     = slot0_br_type;
        bpu_push_entry.slot0_pre_ghr     = slot0_pre_ghr;
        bpu_push_entry.slot0_ras_chkpt   = slot0_ras_chkpt;
        bpu_push_entry.slot0_csr_chkpt   = slot0_csr_chkpt;
        bpu_push_entry.slot1_btb_hit     = slot1_btb_hit;
        bpu_push_entry.slot1_pred_taken  = slot1_pred_taken;
        bpu_push_entry.slot1_pred_target = slot1_pred_target;
        bpu_push_entry.slot1_br_type     = slot1_br_type;
        bpu_push_entry.slot1_pre_ghr     = slot1_pre_ghr;
        bpu_push_entry.slot1_ras_chkpt   = slot1_ras_chkpt;
        bpu_push_entry.slot1_csr_chkpt   = slot1_csr_chkpt;
    end

    always_ff @(posedge clk_i) begin
        if (rst_i || !frontend_en_i || any_redirect || fence_i_frontend_purge) begin
            bpu_fifo_head_q  <= 3'd0;
            bpu_fifo_tail_q  <= 3'd0;
            bpu_fifo_count_q <= 4'd0;
        end else begin
            case ({bpu_fifo_push, bpu_fifo_pop})
                2'b10: begin
                    bpu_fifo_q[bpu_fifo_tail_q] <= bpu_push_entry;
                    bpu_fifo_tail_q             <= bpu_fifo_tail_q + 3'd1;
                    bpu_fifo_count_q            <= bpu_fifo_count_q + 4'd1;
                end
                2'b01: begin
                    bpu_fifo_head_q  <= bpu_fifo_head_q + 3'd1;
                    bpu_fifo_count_q <= bpu_fifo_count_q - 4'd1;
                end
                2'b11: begin
                    bpu_fifo_q[bpu_fifo_tail_q] <= bpu_push_entry;
                    bpu_fifo_tail_q             <= bpu_fifo_tail_q + 3'd1;
                    bpu_fifo_head_q             <= bpu_fifo_head_q + 3'd1;
                end
                default: ;
            endcase
        end
    end

    bpu_meta_entry_t f3_bpu_meta;
    assign f3_bpu_meta = (bpu_fifo_count_q != 4'd0) ? bpu_fifo_q[bpu_fifo_head_q] : '0;

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i && frontend_en_i && f3_valid && !stall_downstream && !backend_flush) begin
            if ((bpu_fifo_count_q == 4'd0) || (f3_bpu_meta.pc != f3_pc)) begin
                $fatal(1, "[FRONTEND ASSERTION FAILED] BPU FIFO PC mismatch: count=%0d meta_pc=0x%h f3_pc=0x%h",
                       bpu_fifo_count_q, f3_bpu_meta.pc, f3_pc);
            end
        end
    end
`endif

    // =========================================================================
    // 3. Stage F2: Level-1 Instruction Cache (L1I) & Response Skid Buffer
    // =========================================================================
    wire pop0_req = rename_ack_i[0] && fq_pop0_valid;
    wire pop1_req = rename_ack_i[1] && fq_pop1_valid;
    wire [1:0] fq_actual_pops = (pop0_req && pop1_req) ? 2'd2 :
                                (pop0_req)             ? 2'd1 : 2'd0;
    wire [4:0] fq_avail_slots = fq_free_count + {3'd0, fq_actual_pops};

    wire [1:0] num_pushes = {1'b0, fq_entry0.valid} + {1'b0, fq_entry1.valid};
    wire stall_downstream = (num_pushes == 2'd2) ? (fq_avail_slots < 5'd2) :
                            (num_pushes == 2'd1) ? (fq_avail_slots < 5'd1) : 1'b0;

    // L1I translation response valid


    fursoy_s1_l1i u_l1i (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i || !frontend_en_i),

        .f1_req_valid_i           (f1_to_l1i_valid),
        .f1_req_pc_i              (f0_pc_q),
        .f1_req_pa_i              (itlb_rsp_pa),
        .f1_req_page_fault_i      (itlb_rsp_page_fault),
        .f1_req_access_fault_i    (itlb_rsp_access_fault),
        .l1i_ready_o              (l1i_ready),

        .stall_f3_i               (stall_downstream),
        .redirect_flush_i         (any_redirect || fence_i_frontend_purge),
        .l1i_inval_all_i          (fence_i_l1i_inval),
        .sfence_vma_i             (sfence_vma_valid_i),
        .fq_free_count_i          (fq_free_count),
        .ptw_req_active_i         (ptw_mem_req_valid_o),

        .f3_valid_o               (f3_valid),
        .f3_pc_o                  (f3_pc),
        .f3_data_o                (f3_data),
        .f3_exception_valid_o     (f3_exception_valid),
        .f3_exception_cause_o     (f3_exception_cause),
        .f3_fault_addr_o          (f3_fault_addr),

        .f2_stall_f0_o            (f2_stall_f0),
        .f2_stall_f1_o            (f2_stall_f1),

        .bus_rd_req_valid_o       (l1i_bus_rd_req_valid_o),
        .bus_rd_req_addr_o        (l1i_bus_rd_req_addr_o),
        .bus_rd_req_tag_o         (l1i_bus_rd_req_tag_o),
        .bus_rd_req_ready_i       (l1i_bus_rd_req_ready_i),

        .bus_rd_rsp_valid_i       (l1i_bus_rd_rsp_valid_i),
        .bus_rd_rsp_tag_i         (l1i_bus_rd_rsp_tag_i),
        .bus_rd_rsp_data_i        (l1i_bus_rd_rsp_data_i),
        .bus_rd_rsp_error_i       (l1i_bus_rd_rsp_error_i),

        .event_l1i_hit_o          (l1i_event_hit),
        .event_l1i_miss_o         (l1i_event_miss),
        .imshr_occ_o              (l1i_imshr_occ),
        .diag_f2_skid_valid_o     (),
        .diag_nlp_alloc_o         (),
        .diag_nlp_hit_o           (),
        .diag_nlp_promote_o       (),
        .diag_nlp_abort_page_o    (),
        .diag_nlp_drop_resident_o ()
    );

    // =========================================================================
    // 4. Stage F3: Alignment & Gated Early JAL Check — Section 3.3 & 13
    // =========================================================================
    wire [31:0] inst_slot0 = f3_data[31:0];
    wire [31:0] inst_slot1 = f3_data[63:32];

    wire [63:0] pc_slot0 = {f3_pc[63:3], 3'b000};
    wire [63:0] pc_slot1 = {f3_pc[63:3], 3'b100};

    // Odd-slot start masking per Section 4:
    // If fetch began at upper half (f3_pc[2] == 1), Slot 0 is masked!
    wire slot0_eligible = f3_valid && (f3_pc[2] == 1'b0);
    wire slot1_eligible = f3_valid;

    // JAL target computation for Slot 0 and Slot 1
    wire [63:0] jal_imm0 = {{43{inst_slot0[31]}}, inst_slot0[31], inst_slot0[19:12], inst_slot0[20], inst_slot0[30:21], 1'b0};
    wire [63:0] jal_imm1 = {{43{inst_slot1[31]}}, inst_slot1[31], inst_slot1[19:12], inst_slot1[20], inst_slot1[30:21], 1'b0};

    wire is_jal0 = slot0_eligible && !f3_exception_valid && (inst_slot0[6:0] == 7'b1101111);
    wire is_jal1 = slot1_eligible && !f3_exception_valid && (inst_slot1[6:0] == 7'b1101111);

    wire is_branch0 = slot0_eligible && !f3_exception_valid && (inst_slot0[6:0] == 7'b1100011);
    wire is_branch1 = slot1_eligible && !f3_exception_valid && (inst_slot1[6:0] == 7'b1100011);
    wire is_jalr0   = slot0_eligible && !f3_exception_valid && (inst_slot0[6:0] == 7'b1100111);
    wire is_jalr1   = slot1_eligible && !f3_exception_valid && (inst_slot1[6:0] == 7'b1100111);

    wire slot0_taken_branch   = is_branch0 && f3_bpu_meta.slot0_pred_taken;
    wire slot0_taken_transfer = slot0_taken_branch || is_jal0 || is_jalr0;

    wire [63:0] computed_jal_target0 = pc_slot0 + jal_imm0;
    wire [63:0] computed_jal_target1 = pc_slot1 + jal_imm1;

    // Gated Early JAL Redirect (Section 3.3):
    // early_jal_redirect = decoded_jal && !already_correctly_predicted
    wire jal0_correctly_predicted = f3_bpu_meta.slot0_btb_hit && f3_bpu_meta.slot0_pred_taken && (f3_bpu_meta.slot0_pred_target == computed_jal_target0);
    wire jal1_correctly_predicted = f3_bpu_meta.slot1_btb_hit && f3_bpu_meta.slot1_pred_taken && (f3_bpu_meta.slot1_pred_target == computed_jal_target1);

    wire jal0_needs_redirect = is_jal0 && !jal0_correctly_predicted;
    wire jal1_needs_redirect = is_jal1 && !jal1_correctly_predicted;

    function automatic branch_type_t classify_br(
        input logic [31:0] inst,
        input logic is_branch,
        input logic is_jal,
        input logic is_jalr
    );
        return classify_branch(inst, is_branch, is_jal, is_jalr);
    endfunction

    always_comb begin
        early_jal_redirect    = 1'b0;
        early_jal_target      = 64'd0;
        early_jal_restore_ghr = f3_bpu_meta.slot0_pre_ghr;
        early_jal_restore_ras = f3_bpu_meta.slot0_ras_chkpt;
        early_jal_restore_csr = f3_bpu_meta.slot0_csr_chkpt;

        if (jal0_needs_redirect && !stall_downstream) begin
            early_jal_redirect    = 1'b1;
            early_jal_target      = computed_jal_target0;
            early_jal_restore_ghr = f3_bpu_meta.slot0_pre_ghr;
            early_jal_restore_ras = f3_bpu_meta.slot0_ras_chkpt;
            early_jal_restore_csr = f3_bpu_meta.slot0_csr_chkpt;
        end else if (jal1_needs_redirect && !slot0_taken_transfer && !stall_downstream) begin
            early_jal_redirect    = 1'b1;
            early_jal_target      = computed_jal_target1;
            early_jal_restore_ghr = f3_bpu_meta.slot1_pre_ghr;
            early_jal_restore_ras = f3_bpu_meta.slot1_ras_chkpt;
            early_jal_restore_csr = f3_bpu_meta.slot1_csr_chkpt;
        end
    end

    // Accurate branch type derivation
    wire branch_type_t eff_br_type0 = f3_bpu_meta.slot0_btb_hit ? f3_bpu_meta.slot0_br_type :
                                      classify_br(inst_slot0, is_branch0, is_jal0, is_jalr0);
    wire branch_type_t eff_br_type1 = f3_bpu_meta.slot1_btb_hit ? f3_bpu_meta.slot1_br_type :
                                      classify_br(inst_slot1, is_branch1, is_jal1, is_jalr1);

    // Packaging into Fetch Queue Entries
    fetch_queue_entry_t fq_entry0;
    fetch_queue_entry_t fq_entry1;

    always_comb begin
        fq_entry0 = '0;
        fq_entry0.valid           = slot0_eligible;
        fq_entry0.pc              = pc_slot0;
        fq_entry0.inst            = inst_slot0;
        fq_entry0.exception_valid = f3_exception_valid && slot0_eligible;
        fq_entry0.exception_cause = f3_exception_cause;
        fq_entry0.fault_addr      = f3_fault_addr;
        fq_entry0.pred_taken      = (is_branch0 || is_jal0 || is_jalr0) ? f3_bpu_meta.slot0_pred_taken : 1'b0;
        fq_entry0.pred_target     = (is_branch0 || is_jal0 || is_jalr0) ? f3_bpu_meta.slot0_pred_target : 64'd0;
        fq_entry0.is_branch       = is_branch0;
        fq_entry0.is_jal          = is_jal0;
        fq_entry0.is_jalr         = is_jalr0;
        fq_entry0.br_type         = eff_br_type0;
        fq_entry0.pre_branch_ghr  = f3_bpu_meta.slot0_pre_ghr;
        fq_entry0.ras_chkpt       = f3_bpu_meta.slot0_ras_chkpt;
        fq_entry0.csr_chkpt       = f3_bpu_meta.slot0_csr_chkpt;

        fq_entry1 = '0;
        // If Slot 0 is predicted taken branch or is a JAL/JALR, Slot 1 must not be enqueued!
        fq_entry1.valid           = slot1_eligible && !(slot0_eligible && slot0_taken_transfer);
        fq_entry1.pc              = pc_slot1;
        fq_entry1.inst            = inst_slot1;
        fq_entry1.exception_valid = f3_exception_valid && slot1_eligible && !(slot0_eligible && slot0_taken_transfer);
        fq_entry1.exception_cause = f3_exception_cause;
        fq_entry1.fault_addr      = f3_fault_addr;
        fq_entry1.pred_taken      = (is_branch1 || is_jal1 || is_jalr1) ? f3_bpu_meta.slot1_pred_taken : 1'b0;
        fq_entry1.pred_target     = (is_branch1 || is_jal1 || is_jalr1) ? f3_bpu_meta.slot1_pred_target : 64'd0;
        fq_entry1.is_branch       = is_branch1;
        fq_entry1.is_jal          = is_jal1;
        fq_entry1.is_jalr         = is_jalr1;
        fq_entry1.br_type         = eff_br_type1;
        fq_entry1.pre_branch_ghr  = f3_bpu_meta.slot1_pre_ghr;
        fq_entry1.ras_chkpt       = f3_bpu_meta.slot1_ras_chkpt;
        fq_entry1.csr_chkpt       = f3_bpu_meta.slot1_csr_chkpt;
    end

    // =========================================================================
    // 5. Stage F4: Decoupled Fetch Queue FIFO (16 Entries)
    // =========================================================================

    fursoy_s1_fetch_queue u_fetch_queue (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i || !frontend_en_i),
        .flush_i                  (backend_flush),

        .push0_valid_i            (fq_entry0.valid && !stall_downstream && !backend_flush),
        .push0_entry_i            (fq_entry0),
        .push1_valid_i            (fq_entry1.valid && !stall_downstream && !backend_flush),
        .push1_entry_i            (fq_entry1),
        .push_ack_o               (push_ack),

        .pop0_i                   (pop0_req),
        .pop1_i                   (pop1_req),
        .pop0_valid_o             (fq_pop0_valid),
        .pop0_entry_o             (fq_pop0_entry),
        .pop1_valid_o             (fq_pop1_valid),
        .pop1_entry_o             (fq_pop1_entry),

        .empty_o                  (fq_empty),
        .full_o                   (fq_full),
        .count_o                  (fq_count),
        .free_count_o             (fq_free_count)
    );

    // =========================================================================
    // 6. Stage D0: Decode & Exception Bypass
    // =========================================================================
    uop_decoded_t dec_uop0, dec_uop1;

    fursoy_s1_decode u_decode (
        .priv_mode_i              (priv_mode_i),
        .in0_valid_i              (fq_pop0_valid),
        .in0_entry_i              (fq_pop0_entry),

        .in1_valid_i              (fq_pop1_valid),
        .in1_entry_i              (fq_pop1_entry),

        .uop0_valid_o             (uop0_valid_o),
        .uop0_o                   (dec_uop0),

        .uop1_valid_o             (uop1_valid_o),
        .uop1_o                   (dec_uop1)
    );

    // Replay-Safe Token Forward-Progress Controller (Section 6.10)
    logic        replay_safe_active_q;
    logic [63:0] replay_safe_pc_q;

    wire uop0_is_target_load = dec_uop0.valid && (dec_uop0.pc == replay_safe_pc_q) && (dec_uop0.uop_class == UOP_LOAD);
    wire uop1_is_target_load = dec_uop1.valid && (dec_uop1.pc == replay_safe_pc_q) && (dec_uop1.uop_class == UOP_LOAD);

    always_comb begin
        uop0_o = dec_uop0;
        uop1_o = dec_uop1;
        if (replay_safe_active_q) begin
            if (uop0_is_target_load) begin
                uop0_o.replay_safe = 1'b1;
            end else if (uop1_is_target_load) begin
                uop1_o.replay_safe = 1'b1;
            end
        end
    end

    wire token_consumed = replay_safe_active_q &&
        ((uop0_is_target_load && pop0_req) ||
         (!uop0_is_target_load && uop1_is_target_load && pop1_req));

    always_ff @(posedge clk_i) begin
        if (rst_i || !frontend_en_i || trap_valid_i || mret_valid_i || fence_i_redirect_valid || sfence_vma_valid_i || (flush_valid_i && !mem_replay_valid_i)) begin
            replay_safe_active_q <= 1'b0;
            replay_safe_pc_q     <= 64'd0;
        end else if (mem_replay_valid_i) begin
            replay_safe_active_q <= 1'b1;
            replay_safe_pc_q     <= mem_replay_pc_i;
        end else if (recover_valid_i) begin
            // Branch recovery flushes pre-dispatch uops; cancel token
            replay_safe_active_q <= 1'b0;
        end else if (token_consumed) begin
            replay_safe_active_q <= 1'b0;
        end
    end

    assign uop0_pre_ghr_o   = fq_pop0_entry.pre_branch_ghr;
    assign uop0_ras_chkpt_o = fq_pop0_entry.ras_chkpt;
    assign uop0_csr_chkpt_o = fq_pop0_entry.csr_chkpt;

    assign uop1_pre_ghr_o   = fq_pop1_entry.pre_branch_ghr;
    assign uop1_ras_chkpt_o = fq_pop1_entry.ras_chkpt;
    assign uop1_csr_chkpt_o = fq_pop1_entry.csr_chkpt;

    // =========================================================================
    // 7. M4 System Serialization Controller (FENCE.I)
    // =========================================================================
    fursoy_s1_serialization u_serialization (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i || !frontend_en_i),
        .flush_valid_i            (flush_valid_i),
        .recover_valid_i          (recover_valid_i),
        .recover_rob_idx_i        (recover_rob_idx_i),

        .alloc0_fence_i_i         (alloc0_fence_i_i),
        .alloc0_rob_idx_i         (alloc0_rob_idx_i),
        .alloc0_rob_epoch_i       (alloc0_rob_epoch_i),
        .alloc0_pc_i              (alloc0_pc_i),

        .alloc1_fence_i_i         (alloc1_fence_i_i),
        .alloc1_rob_idx_i         (alloc1_rob_idx_i),
        .alloc1_rob_epoch_i       (alloc1_rob_epoch_i),
        .alloc1_pc_i              (alloc1_pc_i),

        .rob_head_i               (rob_head_i),
        .retire_epoch_i           (retire_epoch_i),
        .rob_retire_valid_i       (rob_retire_valid_i),
        .retire_ready_o           (retire_ready_o),

        .sq_empty_i               (sq_empty_i),
        .dcache_clean_all_req_o   (dcache_clean_all_req_o),
        .dcache_clean_all_done_i  (dcache_clean_all_done_i),

        .l1i_inval_all_o          (fence_i_l1i_inval),
        .frontend_purge_o         (fence_i_frontend_purge),
        .redirect_valid_o         (fence_i_redirect_valid),
        .redirect_target_o        (fence_i_redirect_target),

        .fence_i_at_head_o        (fence_i_at_head_o),
        .fence_i_active_o         (),
        .event_fence_i_completed_o(fence_i_event_done)
    );

    // =========================================================================
    // 8. Architectural Performance Event Counters (18 Counters) — Section 14
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i || !frontend_en_i) begin
            hpm_fetch_words_o     <= 64'd0;
            hpm_fetch_uops_o      <= 64'd0;
            hpm_fetch_empty_cyc_o <= 64'd0;
            hpm_fetch_full_cyc_o  <= 64'd0;
            hpm_l1i_hits_o        <= 64'd0;
            hpm_l1i_misses_o      <= 64'd0;
            hpm_itlb_hits_o       <= 64'd0;
            hpm_itlb_misses_o     <= 64'd0;
            hpm_btb_hits_o        <= 64'd0;
            hpm_btb_misses_o      <= 64'd0;
            hpm_bpu_cond_pred_o   <= 64'd0;
            hpm_ras_calls_o       <= 64'd0;
            hpm_ras_returns_o     <= 64'd0;
            hpm_fence_i_flushes_o <= 64'd0;
            hpm_redirect_cyc_o    <= 64'd0;
        end else begin
            if (f1_fire)                                    hpm_fetch_words_o     <= hpm_fetch_words_o + 1'b1;
            if (rename_ack_i[0] && uop0_valid_o)            hpm_fetch_uops_o      <= hpm_fetch_uops_o + 1'b1;
            if (rename_ack_i[1] && uop1_valid_o)            hpm_fetch_uops_o      <= hpm_fetch_uops_o + 1'b1;
            if (fq_empty)                                   hpm_fetch_empty_cyc_o <= hpm_fetch_empty_cyc_o + 1'b1;
            if (fq_full)                                    hpm_fetch_full_cyc_o  <= hpm_fetch_full_cyc_o + 1'b1;
            if (l1i_event_hit)                              hpm_l1i_hits_o        <= hpm_l1i_hits_o + 1'b1;
            if (l1i_event_miss)                             hpm_l1i_misses_o      <= hpm_l1i_misses_o + 1'b1;
            if (itlb_event_hit)                             hpm_itlb_hits_o       <= hpm_itlb_hits_o + 1'b1;
            if (itlb_event_miss)                            hpm_itlb_misses_o     <= hpm_itlb_misses_o + 1'b1;
            if (btb_event_hit)                              hpm_btb_hits_o        <= hpm_btb_hits_o + 1'b1;
            if (btb_event_miss)                             hpm_btb_misses_o      <= hpm_btb_misses_o + 1'b1;
            if (bpu_event_cond_pred)                        hpm_bpu_cond_pred_o   <= hpm_bpu_cond_pred_o + 1'b1;
            if (bpu_event_ras_call)                         hpm_ras_calls_o       <= hpm_ras_calls_o + 1'b1;
            if (bpu_event_ras_ret)                          hpm_ras_returns_o     <= hpm_ras_returns_o + 1'b1;
            if (fence_i_event_done)                         hpm_fence_i_flushes_o <= hpm_fence_i_flushes_o + 1'b1;
            if (any_redirect)                               hpm_redirect_cyc_o    <= hpm_redirect_cyc_o + 1'b1;
        end
    end

    // Milestone 5 Telemetry Event Assignments
    assign event_fetch_cycles_o     = f0_valid_q && frontend_en_i && !rst_i;
    assign event_fetch_blocks_o     = f3_valid && !f3_exception_valid;
    assign event_fetch_uops_o       = (fq_entry0.valid && !stall_downstream ? 2'd1 : 2'd0) +
                                      (fq_entry1.valid && !stall_downstream ? 2'd1 : 2'd0);
    assign event_fetch_fq_starved_o = fq_empty && frontend_en_i && !rst_i;
    assign event_fetch_fq_full_o    = fq_full;
    assign event_fetch_odd_slot_o   = f3_valid && (f3_pc[2] == 1'b1);
    assign event_l1i_hits_o         = l1i_event_hit;
    assign event_l1i_misses_o       = l1i_event_miss;
    assign event_l1i_imshr_occ_o    = l1i_imshr_occ;
    assign event_itlb_misses_o      = itlb_event_miss;
    assign event_btb_queries_o      = f0_valid_q && !f2_stall_f1;
    assign event_btb_hits_o         = btb_event_hit;
    assign event_bpu_cond_pred_o    = bpu_event_cond_pred;
    assign event_ras_call_push_o    = bpu_event_ras_call;
    assign event_ras_ret_pop_o      = bpu_event_ras_ret;

    /* verilator lint_on PINCONNECTEMPTY */

endmodule

`endif // FURSOY_S1_FRONTEND_SV
