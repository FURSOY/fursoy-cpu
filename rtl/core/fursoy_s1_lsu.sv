`ifndef FURSOY_S1_LSU_SV
`define FURSOY_S1_LSU_SV

// =============================================================================
// Fursoy Slice-1 Load/Store Unit (LSU) Subsystem — Milestone 3
// =============================================================================
// Reference: docs/architecture/slice1-m3-memory-v1.md
//
// Integrates:
// - MemIQ (12 entries, wrap-safe rob_dist age selection)
// - Port 2 AGU (EA calculation, natural alignment check, byte mask generation)
// - Translation Request Table (TRT, 4 entries, persistent request ownership)
// - Load Queue (16 entries, sq_older_mask snapshot with slot lifetime isolation)
// - Store Queue (16 entries, bifurcated completion, in-order retirement & drain)
// - Non-Blocking L1D Cache (16 KiB 4-Way, 4 MSHRs with selective squash, 2 WBBs)
// - LR/SC Reservation Tracking (56-bit PA + size matching) & FENCE synchronization
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_agu.sv"
`include "fursoy_s1_mem_iq.sv"
`include "fursoy_s1_trt.sv"
`include "fursoy_s1_lsu_queues.sv"
`include "fursoy_s1_dtlb.sv"

`include "fursoy_s1_l1d.sv"

module fursoy_s1_lsu
    import fursoy_s1_pkg::*;
#(
    parameter bit SMP_COHERENCE_EN = 1'b0
) (
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,
    input  rob_idx_t          rob_head_next_i,

    // -------------------------------------------------------------------------
    // Dispatch Handshake & Readiness
    // -------------------------------------------------------------------------
    output logic [1:0]        mem_dispatch_ready_o,
    input  logic [1:0]        rename_ack_i,

    // Uop 0 Dispatch Payload
    input  logic              uop0_valid_i,
    input  uop_class_t        uop0_class_i,
    input  uop_subop_t        uop0_subop_i,
    input  logic [63:0]       uop0_imm_i,
    input  preg_t             uop0_prs1_i,
    input  logic              uop0_prs1_ready_i,
    input  preg_t             uop0_prs2_i,
    input  logic              uop0_prs2_ready_i,
    input  preg_t             uop0_pnew_i,
    input  rob_idx_t          uop0_rob_idx_i,
    input  rob_epoch_t        uop0_rob_epoch_i,
    input  logic              uop0_replay_safe_i,
    input  logic [63:0]       uop0_pc_i,
    input  logic              uop0_is_fp_i,
    input  fpreg_t            uop0_prd_fp_i,
    input  fpreg_t            uop0_prs2_fp_i,
    input  logic              uop0_prs2_fp_ready_i,

    // Uop 1 Dispatch Payload
    input  logic              uop1_valid_i,
    input  uop_class_t        uop1_class_i,
    input  uop_subop_t        uop1_subop_i,
    input  logic [63:0]       uop1_imm_i,
    input  preg_t             uop1_prs1_i,
    input  logic              uop1_prs1_ready_i,
    input  preg_t             uop1_prs2_i,
    input  logic              uop1_prs2_ready_i,
    input  preg_t             uop1_pnew_i,
    input  rob_idx_t          uop1_rob_idx_i,
    input  rob_epoch_t        uop1_rob_epoch_i,
    input  logic              uop1_replay_safe_i,
    input  logic [63:0]       uop1_pc_i,
    input  logic              uop1_is_fp_i,
    input  fpreg_t            uop1_prd_fp_i,
    input  fpreg_t            uop1_prs2_fp_i,
    input  logic              uop1_prs2_fp_ready_i,

    // -------------------------------------------------------------------------
    // PRF Read Port 4 (Base), Port 5 (Store Data) & Port 6 (AGU1 Base) Operands
    // -------------------------------------------------------------------------
    output preg_t             r4_paddr_o,
    input  logic [63:0]       r4_data_i,

    output preg_t             r5_paddr_o,
    input  logic [63:0]       r5_data_i,

    output preg_t             r6_paddr_o,
    input  logic [63:0]       r6_data_i,

    // FPRF Read Port 3 (FP Store Data)
    output fpreg_t            r3_fp_paddr_o,
    input  logic [63:0]       r3_fp_data_i,

    // -------------------------------------------------------------------------
    // Writeback Snoop Buses for Tag Wakeup & Store Data Capture
    // -------------------------------------------------------------------------
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

    // FPRF Port 4 Writeback Snoop
    input  logic              wb0_fp_valid_i,
    input  fpreg_t            wb0_fp_paddr_i,
    input  logic [63:0]       wb0_fp_data_i,

    // -------------------------------------------------------------------------
    // In-Order Store Retirement Handshake at ROB Head
    // -------------------------------------------------------------------------
    input  logic [1:0]        retire_valid_i,
    input  preg_t             retire_pnew_i         [1:0],
    input  logic [63:0]       retire_pc_i           [1:0],
    input  rob_idx_t          retire_rob_idx_i      [1:0],
    input  rob_epoch_t        retire_epoch_i        [1:0],

    // -------------------------------------------------------------------------
    // Port 2 Validated Writeback Output (to M1 Substrate & PRF W2)
    // -------------------------------------------------------------------------
    output logic              p2_comp_valid_o,
    output rob_idx_t          p2_comp_rob_idx_o,
    output rob_epoch_t        p2_comp_epoch_o,
    output preg_t             p2_comp_preg_o,
    output logic              p2_comp_exception_o,
    output logic [4:0]        p2_comp_cause_o,
    output logic [63:0]       p2_wb_data_o,
    input  logic              p2_comp_ack_i,
    output logic              p2_comp_is_fp_o,
    output fpreg_t            p2_comp_prd_fp_o,
    output logic              p2_fp_wb_valid_o,
    output fpreg_t            p2_fp_wb_paddr_o,
    output logic [63:0]       p2_fp_wb_data_o,

    // -------------------------------------------------------------------------
    // Port 3 Validated Writeback Output (to M1 Substrate & PRF W3)
    // -------------------------------------------------------------------------
    output logic              p3_comp_valid_o,
    output rob_idx_t          p3_comp_rob_idx_o,
    output rob_epoch_t        p3_comp_epoch_o,
    output preg_t             p3_comp_preg_o,
    output logic              p3_comp_exception_o,
    output logic [4:0]        p3_comp_cause_o,
    output logic [63:0]       p3_wb_data_o,
    input  logic              p3_comp_ack_i,
    output logic              p3_comp_is_fp_o,
    output fpreg_t            p3_comp_prd_fp_o,
    output logic              p3_fp_wb_valid_o,
    output fpreg_t            p3_fp_wb_paddr_o,
    output logic [63:0]       p3_fp_wb_data_o,

    // -------------------------------------------------------------------------
    // External Memory Interconnect & Translation Interface
    // -------------------------------------------------------------------------
    // Read Channel (MSHR Refills)
    output logic              bus_rd_req_valid_o,
    output logic [49:0]       bus_rd_req_addr_o,
    output mshr_idx_t         bus_rd_req_tag_o,
    output coh_req_op_t       bus_rd_req_op_o,
    input  logic              bus_rd_req_ready_i,

    input  logic              bus_rd_rsp_valid_i,
    input  mshr_idx_t         bus_rd_rsp_tag_i,
    input  logic [511:0]      bus_rd_rsp_data_i,
    input  mesi_state_t       bus_rd_rsp_state_i,
    input  logic              bus_rd_rsp_has_data_i,

    // Write Channel (WBB Dirty Evictions)
    output logic              bus_wr_req_valid_o,
    output logic [49:0]       bus_wr_req_addr_o,
    output logic [511:0]      bus_wr_req_data_o,
    output logic              bus_wr_req_dirty_o,
    input  logic              bus_wr_req_ready_i,

    input  logic              bus_wr_rsp_valid_i,

    // DTLB / PTW Interface
    output logic              ptw_req_valid_o,
    output tr_id_t            ptw_req_tr_id_o,
    output logic [26:0]       ptw_req_vpn_o,
    output logic [1:0]        ptw_req_access_type_o,
    input  logic              ptw_req_ready_i,

    input  logic              ptw_rsp_valid_i,
    input  tr_id_t            ptw_rsp_tr_id_i,
    input  logic [55:0]       ptw_rsp_pa_i,
    input  logic              ptw_rsp_page_fault_i,
    input  logic              ptw_rsp_access_fault_i,
    input  logic [1:0]        ptw_rsp_level_i,
    input  logic [63:0]       ptw_rsp_pte_i,

    // SFENCE.VMA Invalidation Interface
    input  logic              sfence_vma_valid_i,
    input  logic [63:0]       sfence_vma_va_i,
    input  logic [15:0]       sfence_vma_asid_i,
    input  logic              sfence_vma_rs1_zero_i,
    input  logic              sfence_vma_rs2_zero_i,

    // Architectural Privileged State for LSU DTLB Translation
    input  logic [1:0]        priv_mode_i,
    input  logic [63:0]       satp_i,
    input  logic [63:0]       mstatus_i,

    // L1D Maintenance & Serialization (M4)
    input  logic              dcache_clean_all_req_i,
    output logic              dcache_clean_all_done_o,
    output logic              sq_empty_o,

    // Observability & Telemetry (Milestone 5)
    output logic              event_load_issued_o,
    output logic              event_load_fwd_exact_o,
    output logic              event_load_fwd_partial_o,
    output logic              event_load_speculative_o,
    output logic              event_l1d_hit_o,
    output logic              event_l1d_miss_o,
    output logic [1:0]        event_l1d_miss_cold_o,
    output logic [1:0]        event_l1d_miss_conflict_o,
    output logic [1:0]        event_l1d_dirty_evict_o,
    output logic [2:0]        event_l1d_mshr_occ_o,
    output logic              event_l1d_wbb_full_o,
    output logic              event_dtlb_miss_o,
    output logic              rob_head_is_mem_stall_o,

    // Milestone 5 Phase B1 Speculative Disambiguation Interface
    output logic              lsu_violation_valid_o,
    output rob_idx_t          lsu_violation_rob_idx_o,
    output rob_epoch_t        lsu_violation_rob_epoch_o,
    output logic              lsu_retire0_allow_o,
    output logic              lsu_retire1_allow_o,

    output logic [1:0]        memiq_ready_o,
    output logic [1:0]        lq_ready_o,
    output logic [1:0]        sq_ready_o,
    output logic [4:0]        lq_count_o,
    output logic [MEM_IQ_DEPTH-1:0] memiq_diag_ready_o,

    // External Coherence Snoop Interface (Milestone 7 Section 8 / Slice-2)
    input  logic              snoop_req_valid_i,
    input  logic [55:0]       snoop_req_addr_i,
    input  logic [1:0]        snoop_req_type_i,
    output logic              snoop_req_ready_o,
    output logic              snoop_rsp_valid_o,
    output logic              snoop_rsp_has_data_o,
    output logic              snoop_rsp_was_dirty_o,
    output logic [511:0]      snoop_rsp_data_o,
    input  logic              snoop_rsp_ready_i,
    output logic              snoop_rsp_ack_only_o,

    // Hardware PTW Coherent Dirty-Line Snoop (Read-Only, Non-Destructive)
    input  logic [55:0]       ptw_snoop_pa_i,
    output logic              ptw_snoop_dirty_hit_o,
    output logic [63:0]       ptw_snoop_data_o,

    // Slice-2 Non-Speculative IRQ Interlock for SC/AMO
    input  logic              irq_pending_i,
    output logic              atomic_irq_inhibit_o,

    // Milestone 7 Telemetry Events (Section 10.2)
    output logic              event_mem_dual_issue_o,
    output logic [1:0]        event_bank_access_count_o,
    output logic              event_bank_conflict_o,
    output logic              event_bank_broadcast_o,
    output logic              event_store_drain_concurrent_o,
    output logic              event_snoop_query_o,
    output logic              event_snoop_hit_o,
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
    output logic              mmio_rsp_ready_o,

    // Vector Non-Speculative Single-Element Memory Access Interface (M8 Full Vector)
    input  logic              vec_mem_req_valid_i,
    input  logic              vec_mem_req_is_store_i,
    input  mem_size_t         vec_mem_req_size_i,
    input  logic [63:0]       vec_mem_req_va_i,
    input  logic [63:0]       vec_mem_req_wdata_i,
    input  rob_idx_t          vec_mem_req_rob_idx_i,
    input  rob_epoch_t        vec_mem_req_rob_epoch_i,
    output logic              vec_mem_rsp_valid_o,
    output logic [63:0]       vec_mem_rsp_rdata_o,
    output logic              vec_mem_rsp_exception_o,
    output logic [4:0]        vec_mem_rsp_cause_o
);

    // =========================================================================
    // Internal Wiring & Decode Helpers
    // =========================================================================
    function automatic mem_size_t get_mem_size(input uop_subop_t sub_op);
        case (sub_op)
            MEM_LB, MEM_LBU, MEM_SB:                 return MEM_SIZE_BYTE;
            MEM_LH, MEM_LHU, MEM_SH:                 return MEM_SIZE_HALF;
            MEM_LW, MEM_LWU, MEM_SW, MEM_LR_W, MEM_SC_W,
            MEM_FLW, MEM_FSW,
            AMO_SWAP_W, AMO_ADD_W, AMO_XOR_W,
            AMO_AND_W, AMO_OR_W, AMO_MIN_W,
            AMO_MAX_W, AMO_MINU_W, AMO_MAXU_W:       return MEM_SIZE_WORD;
            MEM_FENCE, MEM_FENCE_I:                  return MEM_SIZE_BYTE;
            default:                                 return MEM_SIZE_DOUBLE;
        endcase
    endfunction

    function automatic logic get_mem_sign_ext(input uop_subop_t sub_op);
        case (sub_op)
            MEM_LB, MEM_LH, MEM_LW, MEM_LR_W: return 1'b1;
            default:                           return 1'b0;
        endcase
    endfunction

    wire [1:0] memiq_ready;
    wire [1:0] lq_ready;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [1:0] sq_ready;
    /* verilator lint_on UNUSEDSIGNAL */
    lq_idx_t   alloc_lq0, alloc_lq1;
    sq_idx_t   alloc_sq0, alloc_sq1;

    // Combined Memory Dispatch Readiness (Section 4.2)
    // mem_can_dispatch[s] = (memiq_free > s) && (is_load[s] => lq_free > s) && (is_store[s] => sq_free > s)
    wire uop0_is_load  = (uop0_class_i == UOP_LOAD);
    wire uop0_is_store = (uop0_class_i == UOP_STORE) || (uop0_class_i == UOP_AMO) || (uop0_class_i == UOP_FENCE);
    wire uop1_is_load  = (uop1_class_i == UOP_LOAD);
    wire uop1_is_store = (uop1_class_i == UOP_STORE) || (uop1_class_i == UOP_AMO) || (uop1_class_i == UOP_FENCE);

    wire uop0_is_mem  = uop0_is_load || uop0_is_store;
    wire uop0_v_load  = uop0_valid_i && uop0_is_load;
    wire uop0_v_store = uop0_valid_i && uop0_is_store;
    wire uop0_v_mem   = uop0_valid_i && uop0_is_mem;
    wire uop1_v_store = uop1_valid_i && uop1_is_store;

    assign mem_dispatch_ready_o[0] = memiq_ready[0] &&
                                     (!uop0_is_load  || lq_ready[0]) &&
                                     (!uop0_is_store || sq_ready[0]);

    assign mem_dispatch_ready_o[1] = (uop0_v_mem ? memiq_ready[1] : memiq_ready[0]) &&
                                     (!uop1_is_load  || (uop0_v_load ? lq_ready[1] : lq_ready[0])) &&
                                     (!uop1_is_store || (!uop0_v_store && sq_ready[0]));

    // =========================================================================
    // 1. Memory Issue Queue (MemIQ) — Dual-Issue Arbitration
    // =========================================================================
    logic         memiq_issue0_valid;
    logic         memiq_issue1_valid;

    assign event_mem_dual_issue_o = memiq_issue0_valid && memiq_issue1_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    memiq_entry_t memiq_issue0_uop;
    /* verilator lint_on UNUSEDSIGNAL */

    /* verilator lint_off UNUSEDSIGNAL */
    memiq_entry_t memiq_issue1_uop;
    /* verilator lint_on UNUSEDSIGNAL */

    wire lsu_queues_port2_busy;
    wire lsu_queues_port3_busy;

    // Non-Speculative Vector Memory Element FSM Declarations
    typedef enum logic [2:0] {
        VMEM_IDLE        = 3'd0,
        VMEM_DTLB_CHK    = 3'd1,
        VMEM_WAIT_TRT    = 3'd2,
        VMEM_L1D_LD_REQ  = 3'd3,
        VMEM_L1D_LD_WAIT = 3'd4,
        VMEM_L1D_ST_WAIT = 3'd5
    } vmem_state_t;

    vmem_state_t vmem_state_q;
    logic        vmem_trt_alloc_q;
    logic [55:0] vmem_pa_q;
    wire       vmem_active = (vmem_state_q != VMEM_IDLE);
    wire [7:0] vmem_base_mask = (vec_mem_req_size_i == MEM_SIZE_BYTE) ? 8'h01 :
                                (vec_mem_req_size_i == MEM_SIZE_HALF) ? 8'h03 :
                                (vec_mem_req_size_i == MEM_SIZE_WORD) ? 8'h0F : 8'hFF;
    wire [7:0] vmem_store_mask = vmem_base_mask << vmem_pa_q[2:0];

    fursoy_s1_mem_iq u_mem_iq (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .flush_valid_i      (flush_valid_i),
        .recover_valid_i    (recover_valid_i),
        .recover_rob_idx_i  (recover_rob_idx_i),
        .rob_head_i         (rob_head_i),

        .mem_ready_o        (memiq_ready),
        .rename_ack_i       (rename_ack_i),

        .uop0_valid_i       (uop0_valid_i),
        .uop0_class_i       (uop0_class_i),
        .uop0_subop_i       (uop0_subop_i),
        .uop0_size_i        (get_mem_size(uop0_subop_i)),
        .uop0_sign_ext_i    (get_mem_sign_ext(uop0_subop_i)),
        .uop0_imm_i         (uop0_imm_i),
        .uop0_prs1_i        (uop0_prs1_i),
        .uop0_prs1_ready_i  (uop0_prs1_ready_i),
        .uop0_prs2_i        (uop0_prs2_i),
        .uop0_prs2_ready_i  (uop0_prs2_ready_i),
        .uop0_pnew_i        (uop0_pnew_i),
        .uop0_rob_idx_i     (uop0_rob_idx_i),
        .uop0_rob_epoch_i   (uop0_rob_epoch_i),
        .uop0_replay_safe_i (uop0_replay_safe_i),
        .uop0_lq_idx_i      (alloc_lq0),
        .uop0_sq_idx_i      (alloc_sq0),
        .uop0_pc_i          (uop0_pc_i),

        .uop1_valid_i       (uop1_valid_i),
        .uop1_class_i       (uop1_class_i),
        .uop1_subop_i       (uop1_subop_i),
        .uop1_size_i        (get_mem_size(uop1_subop_i)),
        .uop1_sign_ext_i    (get_mem_sign_ext(uop1_subop_i)),
        .uop1_imm_i         (uop1_imm_i),
        .uop1_prs1_i        (uop1_prs1_i),
        .uop1_prs1_ready_i  (uop1_prs1_ready_i),
        .uop1_prs2_i        (uop1_prs2_i),
        .uop1_prs2_ready_i  (uop1_prs2_ready_i),
        .uop1_pnew_i        (uop1_pnew_i),
        .uop1_rob_idx_i     (uop1_rob_idx_i),
        .uop1_rob_epoch_i   (uop1_rob_epoch_i),
        .uop1_replay_safe_i (uop1_replay_safe_i),
        .uop1_lq_idx_i      (uop0_v_load  ? alloc_lq1 : alloc_lq0),
        .uop1_sq_idx_i      (uop0_v_store ? alloc_sq1 : alloc_sq0),
        .uop1_pc_i          (uop1_pc_i),

        .wb0_valid_i        (wb0_valid_i),
        .wb0_comp_ack_i     (wb0_comp_ack_i),
        .wb0_pnew_i         (wb0_pnew_i),

        .wb1_valid_i        (wb1_valid_i),
        .wb1_comp_ack_i     (wb1_comp_ack_i),
        .wb1_pnew_i         (wb1_pnew_i),

        .wb2_valid_i        (wb2_valid_i),
        .wb2_comp_ack_i     (wb2_comp_ack_i),
        .wb2_comp_exception_i(wb2_comp_exception_i),
        .wb2_pnew_i         (wb2_pnew_i),

        .wb3_valid_i        (wb3_valid_i),
        .wb3_comp_ack_i     (wb3_comp_ack_i),
        .wb3_comp_exception_i(wb3_comp_exception_i),
        .wb3_pnew_i         (wb3_pnew_i),

        .port2_busy_i       (lsu_queues_port2_busy || vmem_active),
        .port3_busy_i       (lsu_queues_port3_busy || vmem_active),
        .issue0_valid_o     (memiq_issue0_valid),
        .issue0_uop_o       (memiq_issue0_uop),
        .issue1_valid_o     (memiq_issue1_valid),
        .issue1_uop_o       (memiq_issue1_uop),

        /* verilator lint_off PINCONNECTEMPTY */
        .diag_valid_mask_o  (),
        .diag_ready_mask_o  (memiq_diag_ready_o),
        .free_count_o       (),
        .count_o            ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    assign event_load_issued_o = (memiq_issue0_valid && (memiq_issue0_uop.uop_class == UOP_LOAD)) ||
                                 (memiq_issue1_valid && (memiq_issue1_uop.uop_class == UOP_LOAD));
    assign memiq_ready_o       = memiq_ready;
    assign lq_ready_o          = lq_ready;
    assign sq_ready_o          = sq_ready;
    assign event_dtlb_miss_o   = ptw_req_valid_o && ptw_req_ready_i;

    // Drive PRF Read Port 4 (Port 2 Base Address) & Port 6 (Port 3 Base Address)
    assign r4_paddr_o = memiq_issue0_uop.prs1;
    assign r6_paddr_o = memiq_issue1_uop.prs1;
    // Drive PRF Read Port 5 (Store Data)
    assign r5_paddr_o = uop0_v_store ? uop0_prs2_i : uop1_prs2_i; // Monitored during dispatch

    // Drive FPRF Read Port 3 (FP Store Data)
    assign r3_fp_paddr_o = (uop0_v_store && uop0_is_fp_i) ? uop0_prs2_fp_i :
                           (uop1_v_store && uop1_is_fp_i) ? uop1_prs2_fp_i : 6'd0;

    // Read Operand Forwarding for Port 2 Base Address
    logic [63:0] agu0_base_operand;
    always_comb begin
        if (memiq_issue0_uop.prs1 == preg_t'(0)) begin
            agu0_base_operand = 64'd0;
        end else if (wb3_valid_i && wb3_comp_ack_i && !wb3_comp_exception_i && (wb3_pnew_i == memiq_issue0_uop.prs1)) begin
            agu0_base_operand = wb3_data_i;
        end else if (wb2_valid_i && wb2_comp_ack_i && !wb2_comp_exception_i && (wb2_pnew_i == memiq_issue0_uop.prs1)) begin
            agu0_base_operand = wb2_data_i;
        end else if (wb1_valid_i && wb1_comp_ack_i && (wb1_pnew_i == memiq_issue0_uop.prs1)) begin
            agu0_base_operand = wb1_data_i;
        end else if (wb0_valid_i && wb0_comp_ack_i && (wb0_pnew_i == memiq_issue0_uop.prs1)) begin
            agu0_base_operand = wb0_data_i;
        end else begin
            agu0_base_operand = r4_data_i;
        end
    end

    // Read Operand Forwarding for Port 3 Base Address
    logic [63:0] agu1_base_operand;
    always_comb begin
        if (memiq_issue1_uop.prs1 == preg_t'(0)) begin
            agu1_base_operand = 64'd0;
        end else if (wb3_valid_i && wb3_comp_ack_i && !wb3_comp_exception_i && (wb3_pnew_i == memiq_issue1_uop.prs1)) begin
            agu1_base_operand = wb3_data_i;
        end else if (wb2_valid_i && wb2_comp_ack_i && !wb2_comp_exception_i && (wb2_pnew_i == memiq_issue1_uop.prs1)) begin
            agu1_base_operand = wb2_data_i;
        end else if (wb1_valid_i && wb1_comp_ack_i && (wb1_pnew_i == memiq_issue1_uop.prs1)) begin
            agu1_base_operand = wb1_data_i;
        end else if (wb0_valid_i && wb0_comp_ack_i && (wb0_pnew_i == memiq_issue1_uop.prs1)) begin
            agu1_base_operand = wb0_data_i;
        end else begin
            agu1_base_operand = r6_data_i;
        end
    end

    // =========================================================================
    // 2. Dual Address Generation Units (Port 2 AGU0 & Port 3 AGU1)
    // =========================================================================
    // Port 2 AGU0: Loads, Stores, AMOs, Fences
    logic [63:0] agu0_ea;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [2:0]  agu0_byte_offset;
    logic [5:0]  agu0_line_offset;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  agu0_byte_mask;
    logic        agu0_align_fault;
    logic [4:0]  agu0_exc_cause;

    fursoy_s1_agu u_agu0 (
        .valid_i        (memiq_issue0_valid),
        .sub_op_i       (memiq_issue0_uop.sub_op),
        .size_i         (memiq_issue0_uop.size),
        .base_i         (agu0_base_operand),
        .imm_i          (memiq_issue0_uop.imm),
        .is_store_i     ((memiq_issue0_uop.uop_class == UOP_STORE) || (memiq_issue0_uop.uop_class == UOP_AMO) || (memiq_issue0_uop.uop_class == UOP_FENCE)),
        .ea_o           (agu0_ea),
        .byte_offset_o  (agu0_byte_offset),
        .line_offset_o  (agu0_line_offset),
        .byte_mask_o    (agu0_byte_mask),
        .align_fault_o  (agu0_align_fault),
        .exc_cause_o    (agu0_exc_cause)
    );

    // Port 3 AGU1: Loads strictly (§5.1, PROP_M7_03)
    logic [63:0] agu1_ea;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [2:0]  agu1_byte_offset;
    logic [5:0]  agu1_line_offset;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  agu1_byte_mask;
    logic        agu1_align_fault;
    logic [4:0]  agu1_exc_cause;

    fursoy_s1_agu u_agu1 (
        .valid_i        (memiq_issue1_valid),
        .sub_op_i       (memiq_issue1_uop.sub_op),
        .size_i         (memiq_issue1_uop.size),
        .base_i         (agu1_base_operand),
        .imm_i          (memiq_issue1_uop.imm),
        .is_store_i     (1'b0),
        .ea_o           (agu1_ea),
        .byte_offset_o  (agu1_byte_offset),
        .line_offset_o  (agu1_line_offset),
        .byte_mask_o    (agu1_byte_mask),
        .align_fault_o  (agu1_align_fault),
        .exc_cause_o    (agu1_exc_cause)
    );

    // =========================================================================
    // 3. Translation Request Table (TRT)
    // =========================================================================
    logic        trt_alloc_req;
    logic        trt_alloc_is_store;
    logic [3:0]  trt_alloc_q_idx;
    logic [26:0] trt_alloc_vpn;
    rob_idx_t    trt_alloc_rob_idx;
    rob_epoch_t  trt_alloc_rob_epoch;
    tr_id_t      trt_assigned_tr_id;

    logic        trt_delivery_valid;
    logic        trt_delivery_is_store;
    logic [3:0]  trt_delivery_q_idx;
    logic [55:0] trt_delivery_pa;
    logic        trt_delivery_page_fault;
    logic        trt_delivery_access_fault;
    rob_idx_t    trt_delivery_rob_idx;
    rob_epoch_t  trt_delivery_rob_epoch;

    logic        trt_alloc_ready;
    logic        dtlb_refill_valid;
    logic [26:0] dtlb_refill_vpn;
    logic [1:0]  dtlb_refill_level;
    logic [63:0] dtlb_refill_pte;
    logic [55:0] dtlb_refill_pa;

    fursoy_s1_trt u_trt (
        .clk_i                      (clk_i),
        .rst_i                      (rst_i),
        .flush_valid_i              (flush_valid_i),
        .recover_valid_i            (recover_valid_i),
        .recover_rob_idx_i          (recover_rob_idx_i),
        .rob_head_i                 (rob_head_i),

        .alloc_req_i                (vmem_active ? (vmem_state_q == VMEM_WAIT_TRT && vmem_trt_alloc_q) : trt_alloc_req),
        .alloc_is_store_i           (vmem_active ? vec_mem_req_is_store_i : trt_alloc_is_store),
        .alloc_q_idx_i              (vmem_active ? 4'd0                   : trt_alloc_q_idx),
        .alloc_vpn_i                (vmem_active ? vec_mem_req_va_i[38:12] : trt_alloc_vpn),
        .alloc_access_type_i        ((vmem_active ? vec_mem_req_is_store_i : trt_alloc_is_store) ? 2'b01 : 2'b00),
        .alloc_rob_idx_i            (vmem_active ? vec_mem_req_rob_idx_i  : trt_alloc_rob_idx),
        .alloc_rob_epoch_i          (vmem_active ? vec_mem_req_rob_epoch_i: trt_alloc_rob_epoch),
        .alloc_ready_o              (trt_alloc_ready),
        .alloc_tr_id_o              (trt_assigned_tr_id),

        .ptw_req_valid_o            (ptw_req_valid_o),
        .ptw_req_tr_id_o            (ptw_req_tr_id_o),
        .ptw_req_vpn_o              (ptw_req_vpn_o),
        .ptw_req_access_type_o      (ptw_req_access_type_o),
        .ptw_req_ready_i            (ptw_req_ready_i),

        .ptw_rsp_valid_i            (ptw_rsp_valid_i),
        .ptw_rsp_tr_id_i            (ptw_rsp_tr_id_i),
        .ptw_rsp_pa_i               (ptw_rsp_pa_i),
        .ptw_rsp_page_fault_i       (ptw_rsp_page_fault_i),
        .ptw_rsp_access_fault_i     (ptw_rsp_access_fault_i),
        .ptw_rsp_level_i            (ptw_rsp_level_i),
        .ptw_rsp_pte_i              (ptw_rsp_pte_i),

        .dtlb_refill_valid_o        (dtlb_refill_valid),
        .dtlb_refill_vpn_o          (dtlb_refill_vpn),
        .dtlb_refill_level_o        (dtlb_refill_level),
        .dtlb_refill_pte_o          (dtlb_refill_pte),
        .dtlb_refill_pa_o           (dtlb_refill_pa),

        .trt_delivery_valid_o       (trt_delivery_valid),
        .trt_delivery_is_store_o    (trt_delivery_is_store),
        .trt_delivery_q_idx_o       (trt_delivery_q_idx),
        .trt_delivery_pa_o          (trt_delivery_pa),
        .trt_delivery_page_fault_o  (trt_delivery_page_fault),
        .trt_delivery_access_fault_o(trt_delivery_access_fault),
        .trt_delivery_rob_idx_o     (trt_delivery_rob_idx),
        .trt_delivery_rob_epoch_o   (trt_delivery_rob_epoch)
    );

    // =========================================================================
    // 3b. Genuine Architectural Sv39 Dual-Port DTLB (P0-2)
    // =========================================================================
    logic        dtlb0_hit;
    logic [55:0] dtlb0_pa;
    logic        dtlb0_page_fault;
    logic        dtlb0_access_fault;

    logic        dtlb1_hit;
    logic [55:0] dtlb1_pa;
    logic        dtlb1_page_fault;
    logic        dtlb1_access_fault;

    fursoy_s1_dtlb u_dtlb (
        .clk_i                      (clk_i),
        .rst_i                      (rst_i),

        .priv_mode_i                (priv_mode_i),
        .satp_i                     (satp_i),
        .mstatus_i                  (mstatus_i),

        .p0_req_valid_i             ((vmem_state_q == VMEM_DTLB_CHK) ? 1'b1 : memiq_issue0_valid),
        .p0_req_va_i                ((vmem_state_q == VMEM_DTLB_CHK) ? vec_mem_req_va_i : agu0_ea),
        .p0_req_is_store_i          ((vmem_state_q == VMEM_DTLB_CHK) ? vec_mem_req_is_store_i : ((memiq_issue0_uop.uop_class == UOP_STORE) || (memiq_issue0_uop.uop_class == UOP_AMO) || (memiq_issue0_uop.uop_class == UOP_FENCE))),
        .p0_req_is_amo_i            ((vmem_state_q == VMEM_DTLB_CHK) ? 1'b0 : (memiq_issue0_uop.uop_class == UOP_AMO)),
        .p0_rsp_hit_o               (dtlb0_hit),
        .p0_rsp_pa_o                (dtlb0_pa),
        .p0_rsp_page_fault_o        (dtlb0_page_fault),
        .p0_rsp_access_fault_o      (dtlb0_access_fault),

        .p1_req_valid_i             (memiq_issue1_valid),
        .p1_req_va_i                (agu1_ea),
        .p1_rsp_hit_o               (dtlb1_hit),
        .p1_rsp_pa_o                (dtlb1_pa),
        .p1_rsp_page_fault_o        (dtlb1_page_fault),
        .p1_rsp_access_fault_o      (dtlb1_access_fault),

        .sfence_vma_valid_i         (sfence_vma_valid_i),
        .sfence_vma_va_i            (sfence_vma_va_i),
        .sfence_vma_asid_i          (sfence_vma_asid_i),
        .sfence_vma_rs1_zero_i      (sfence_vma_rs1_zero_i),
        .sfence_vma_rs2_zero_i      (sfence_vma_rs2_zero_i),

        .refill_valid_i             (dtlb_refill_valid),
        .refill_vpn_i               (dtlb_refill_vpn),
        .refill_level_i             (dtlb_refill_level),
        .refill_pte_i               (dtlb_refill_pte),
        .refill_pa_i                (dtlb_refill_pa)
    );

    // =========================================================================
    // 4. Non-Blocking L1 Data Cache (L1D) Subsystem
    // =========================================================================
    logic        l1d_load0_req_valid;
    lq_idx_t     l1d_load0_req_lq_idx;
    logic [55:0] l1d_load0_req_pa;
    mem_size_t   l1d_load0_req_size;
    logic        l1d_load0_req_sign_ext;
    preg_t       l1d_load0_req_pnew;
    rob_idx_t    l1d_load0_req_rob_idx;
    rob_epoch_t  l1d_load0_req_rob_epoch;
    logic        l1d_load0_req_is_amo;
    logic        l1d_load0_req_ready;

    logic        l1d_load0_rsp_valid;
    lq_idx_t     l1d_load0_rsp_lq_idx;
    logic        l1d_load0_rsp_hit;
    logic [63:0] l1d_load0_rsp_data;
    mshr_idx_t   l1d_load0_rsp_mshr_id;

    logic        l1d_load1_req_valid;
    lq_idx_t     l1d_load1_req_lq_idx;
    logic [55:0] l1d_load1_req_pa;
    mem_size_t   l1d_load1_req_size;
    logic        l1d_load1_req_sign_ext;
    preg_t       l1d_load1_req_pnew;
    rob_idx_t    l1d_load1_req_rob_idx;
    rob_epoch_t  l1d_load1_req_rob_epoch;
    logic        l1d_load1_req_ready;

    logic        l1d_load1_rsp_valid;
    lq_idx_t     l1d_load1_rsp_lq_idx;
    logic        l1d_load1_rsp_hit;
    logic [63:0] l1d_load1_rsp_data;
    mshr_idx_t   l1d_load1_rsp_mshr_id;

    logic        refill_comp_valid;
    lq_idx_t     refill_comp_lq_idx;
    preg_t       refill_comp_pnew;
    rob_idx_t    refill_comp_rob_idx;
    rob_epoch_t  refill_comp_rob_epoch;
    logic [63:0] refill_comp_data;

    logic        l1d_store_drain_valid;
    sq_idx_t     l1d_store_drain_sq_idx;
    logic [55:0] l1d_store_drain_pa;
    logic [7:0]  l1d_store_drain_mask;
    logic [63:0] l1d_store_drain_data;
    logic        l1d_store_drain_ready;
    logic        l1d_store_drain_done;
    logic        l1d_quiescent;
    logic        l1d_snoop_s0_valid;
    logic [49:0] l1d_snoop_s0_addr;
    logic        l1d_snoop_s0_do_inv;
    logic        l1d_sc_acquire_valid;
    logic [55:0] l1d_sc_acquire_pa;
    logic [7:0]  l1d_sc_acquire_mask;
    logic [63:0] l1d_sc_acquire_data;
    logic        l1d_sc_res_valid;
    logic        l1d_sc_acquire_accepted;
    logic        l1d_sc_acquire_done;
    logic        l1d_sc_acquire_ok;

    fursoy_s1_l1d #(
        .SMP_COHERENCE_EN           (SMP_COHERENCE_EN)
    ) u_l1d (
        .clk_i                      (clk_i),
        .rst_i                      (rst_i),
        .flush_valid_i              (flush_valid_i),
        .recover_valid_i            (recover_valid_i),
        .recover_rob_idx_i          (recover_rob_idx_i),
        .rob_head_i                 (rob_head_i),

        .load0_req_valid_i          (vmem_active ? (vmem_state_q == VMEM_L1D_LD_REQ) : l1d_load0_req_valid),
        .load0_req_lq_idx_i         (vmem_active ? 4'd0                    : l1d_load0_req_lq_idx),
        .load0_req_pa_i             (vmem_active ? vmem_pa_q               : l1d_load0_req_pa),
        .load0_req_size_i           (vmem_active ? vec_mem_req_size_i      : l1d_load0_req_size),
        .load0_req_sign_ext_i       (vmem_active ? 1'b0                    : l1d_load0_req_sign_ext),
        .load0_req_pnew_i           (vmem_active ? preg_t'(0)              : l1d_load0_req_pnew),
        .load0_req_rob_idx_i        (vmem_active ? vec_mem_req_rob_idx_i   : l1d_load0_req_rob_idx),
        .load0_req_rob_epoch_i      (vmem_active ? vec_mem_req_rob_epoch_i : l1d_load0_req_rob_epoch),
        .load0_req_is_amo_i         (vmem_active ? 1'b0                    : l1d_load0_req_is_amo),
        .load0_req_ready_o          (l1d_load0_req_ready),

        .load0_rsp_valid_o          (l1d_load0_rsp_valid),
        .load0_rsp_lq_idx_o         (l1d_load0_rsp_lq_idx),
        .load0_rsp_hit_o            (l1d_load0_rsp_hit),
        .load0_rsp_data_o           (l1d_load0_rsp_data),
        .load0_rsp_mshr_id_o        (l1d_load0_rsp_mshr_id),

        .load1_req_valid_i          (l1d_load1_req_valid),
        .load1_req_lq_idx_i         (l1d_load1_req_lq_idx),
        .load1_req_pa_i             (l1d_load1_req_pa),
        .load1_req_size_i           (l1d_load1_req_size),
        .load1_req_sign_ext_i       (l1d_load1_req_sign_ext),
        .load1_req_pnew_i           (l1d_load1_req_pnew),
        .load1_req_rob_idx_i        (l1d_load1_req_rob_idx),
        .load1_req_rob_epoch_i      (l1d_load1_req_rob_epoch),
        .load1_req_ready_o          (l1d_load1_req_ready),

        .load1_rsp_valid_o          (l1d_load1_rsp_valid),
        .load1_rsp_lq_idx_o         (l1d_load1_rsp_lq_idx),
        .load1_rsp_hit_o            (l1d_load1_rsp_hit),
        .load1_rsp_data_o           (l1d_load1_rsp_data),
        .load1_rsp_mshr_id_o        (l1d_load1_rsp_mshr_id),

        .store_drain_valid_i        (vmem_active ? (vmem_state_q == VMEM_L1D_ST_WAIT) : l1d_store_drain_valid),
        .store_drain_sq_idx_i       (vmem_active ? 4'd0       : l1d_store_drain_sq_idx),
        .store_drain_pa_i           (vmem_active ? vmem_pa_q  : l1d_store_drain_pa),
        .store_drain_mask_i         (vmem_active ? vmem_store_mask : l1d_store_drain_mask),
        .store_drain_data_i         (vmem_active ? (vec_mem_req_wdata_i << {vmem_pa_q[2:0], 3'b000}) : l1d_store_drain_data),
        .store_drain_ready_o        (l1d_store_drain_ready),
        .store_drain_done_o         (l1d_store_drain_done),

        .sc_acquire_valid_i         (vmem_active ? 1'b0 : l1d_sc_acquire_valid),
        .sc_acquire_pa_i            (l1d_sc_acquire_pa),
        .sc_acquire_mask_i          (l1d_sc_acquire_mask),
        .sc_acquire_data_i          (l1d_sc_acquire_data),
        .sc_res_valid_i             (l1d_sc_res_valid),
        .sc_acquire_accepted_o      (l1d_sc_acquire_accepted),
        .sc_acquire_done_o          (l1d_sc_acquire_done),
        .sc_acquire_ok_o            (l1d_sc_acquire_ok),

        .refill_comp_valid_o        (refill_comp_valid),
        .refill_comp_lq_idx_o       (refill_comp_lq_idx),
        .refill_comp_pnew_o         (refill_comp_pnew),
        .refill_comp_rob_idx_o      (refill_comp_rob_idx),
        .refill_comp_rob_epoch_o    (refill_comp_rob_epoch),
        .refill_comp_data_o         (refill_comp_data),

        .event_l1d_hit_o            (event_l1d_hit_o),
        .event_l1d_miss_o           (event_l1d_miss_o),
        .event_l1d_miss_cold_o      (event_l1d_miss_cold_o),
        .event_l1d_miss_conflict_o  (event_l1d_miss_conflict_o),
        .event_l1d_dirty_evict_o    (event_l1d_dirty_evict_o),
        .mshr_occ_o                 (event_l1d_mshr_occ_o),
        .wbb_full_o                 (event_l1d_wbb_full_o),
        .event_bank_access_count_o  (event_bank_access_count_o),
        .event_bank_conflict_o      (event_bank_conflict_o),
        .event_bank_broadcast_o     (event_bank_broadcast_o),
        .event_store_drain_concurrent_o(event_store_drain_concurrent_o),
        .event_snoop_query_o        (event_snoop_query_o),
        .event_snoop_hit_o          (event_snoop_hit_o),

        .bus_rd_req_valid_o         (bus_rd_req_valid_o),
        .bus_rd_req_addr_o          (bus_rd_req_addr_o),
        .bus_rd_req_tag_o           (bus_rd_req_tag_o),
        .bus_rd_req_op_o            (bus_rd_req_op_o),
        .bus_rd_req_ready_i         (bus_rd_req_ready_i),

        .bus_rd_rsp_valid_i         (bus_rd_rsp_valid_i),
        .bus_rd_rsp_tag_i           (bus_rd_rsp_tag_i),
        .bus_rd_rsp_data_i          (bus_rd_rsp_data_i),
        .bus_rd_rsp_state_i         (bus_rd_rsp_state_i),
        .bus_rd_rsp_has_data_i      (bus_rd_rsp_has_data_i),

        .bus_wr_req_valid_o         (bus_wr_req_valid_o),
        .bus_wr_req_addr_o          (bus_wr_req_addr_o),
        .bus_wr_req_data_o          (bus_wr_req_data_o),
        .bus_wr_req_dirty_o         (bus_wr_req_dirty_o),
        .bus_wr_req_ready_i         (bus_wr_req_ready_i),

        .bus_wr_rsp_valid_i         (bus_wr_rsp_valid_i),

        .dcache_clean_all_req_i     (dcache_clean_all_req_i),
        .dcache_clean_all_done_o    (dcache_clean_all_done_o),
        .l1d_quiescent_o            (l1d_quiescent),

        .snoop_req_valid_i          (snoop_req_valid_i),
        .snoop_req_addr_i           (snoop_req_addr_i[55:6]),
        .snoop_req_type_i           (snoop_req_type_i),
        .snoop_req_ready_o          (snoop_req_ready_o),
        .snoop_rsp_valid_o          (snoop_rsp_valid_o),
        .snoop_rsp_has_data_o       (snoop_rsp_has_data_o),
        .snoop_rsp_data_o           (snoop_rsp_data_o),
        .snoop_rsp_was_dirty_o      (snoop_rsp_was_dirty_o),
        .snoop_rsp_ready_i          (snoop_rsp_ready_i),
        .snoop_rsp_ack_only_o       (snoop_rsp_ack_only_o),

        .snoop_s0_valid_o           (l1d_snoop_s0_valid),
        .snoop_s0_addr_o            (l1d_snoop_s0_addr),
        .snoop_s0_do_inv_o          (l1d_snoop_s0_do_inv),

        .ptw_snoop_pa_i             (ptw_snoop_pa_i),
        .ptw_snoop_dirty_hit_o      (ptw_snoop_dirty_hit_o),
        .ptw_snoop_data_o           (ptw_snoop_data_o)
    );

    // =========================================================================
    // 5. Load Queue (LQ) & Store Queue (SQ)
    // =========================================================================
    fursoy_s1_lsu_queues #(
        .SMP_COHERENCE_EN           (SMP_COHERENCE_EN)
    ) u_lsu_queues (
        .clk_i                      (clk_i),
        .rst_i                      (rst_i),
        .flush_valid_i              (flush_valid_i),
        .recover_valid_i            (recover_valid_i),
        .recover_rob_idx_i          (recover_rob_idx_i),
        .rob_head_i                 (rob_head_i),
        .rob_head_next_i            (rob_head_next_i),

        .lq_ready_o                 (lq_ready),
        .sq_ready_o                 (sq_ready),
        .lq_count_o                 (lq_count_o),
        .alloc_lq_slot0_o           (alloc_lq0),
        .alloc_lq_slot1_o           (alloc_lq1),
        .alloc_sq_slot0_o           (alloc_sq0),
        .alloc_sq_slot1_o           (alloc_sq1),
        .rename_ack_i               (rename_ack_i),

        .uop0_valid_i               (uop0_valid_i),
        .uop0_class_i               (uop0_class_i),
        .uop0_subop_i               (uop0_subop_i),
        .uop0_size_i                (get_mem_size(uop0_subop_i)),
        .uop0_sign_ext_i            (get_mem_sign_ext(uop0_subop_i)),
        .uop0_pnew_i                (uop0_pnew_i),
        .uop0_prs2_i                (uop0_prs2_i),
        .uop0_prs2_ready_i          (uop0_prs2_ready_i),
        .uop0_rob_idx_i             (uop0_rob_idx_i),
        .uop0_rob_epoch_i           (uop0_rob_epoch_i),
        .uop0_replay_safe_i         (uop0_replay_safe_i),
        .uop0_pc_i                  (uop0_pc_i),
        .uop0_is_fp_i               (uop0_is_fp_i),
        .uop0_prd_fp_i              (uop0_prd_fp_i),
        .uop0_prs2_fp_i             (uop0_prs2_fp_i),
        .uop0_prs2_fp_ready_i       (uop0_prs2_fp_ready_i),

        .uop1_valid_i               (uop1_valid_i),
        .uop1_class_i               (uop1_class_i),
        .uop1_subop_i               (uop1_subop_i),
        .uop1_size_i                (get_mem_size(uop1_subop_i)),
        .uop1_sign_ext_i            (get_mem_sign_ext(uop1_subop_i)),
        .uop1_pnew_i                (uop1_pnew_i),
        .uop1_prs2_i                (uop1_prs2_i),
        .uop1_prs2_ready_i          (uop1_prs2_ready_i),
        .uop1_rob_idx_i             (uop1_rob_idx_i),
        .uop1_rob_epoch_i           (uop1_rob_epoch_i),
        .uop1_replay_safe_i         (uop1_replay_safe_i),
        .uop1_pc_i                  (uop1_pc_i),
        .uop1_is_fp_i               (uop1_is_fp_i),
        .uop1_prd_fp_i              (uop1_prd_fp_i),
        .uop1_prs2_fp_i             (uop1_prs2_fp_i),
        .uop1_prs2_fp_ready_i       (uop1_prs2_fp_ready_i),

        .agu_valid_i                (memiq_issue0_valid),
        .agu_is_store_i             ((memiq_issue0_uop.uop_class == UOP_STORE) || (memiq_issue0_uop.uop_class == UOP_AMO) || (memiq_issue0_uop.uop_class == UOP_FENCE)),
        .agu_lq_idx_i               (memiq_issue0_uop.lq_idx),
        .agu_sq_idx_i               (memiq_issue0_uop.sq_idx),
        .agu_sub_op_i               (memiq_issue0_uop.sub_op),
        .agu_size_i                 (memiq_issue0_uop.size),
        .agu_sign_ext_i             (memiq_issue0_uop.sign_ext),
        .agu_va_i                   (agu0_ea),
        .agu_byte_mask_i            (agu0_byte_mask),
        .agu_align_fault_i          (agu0_align_fault),
        .agu_exc_cause_i            (agu0_exc_cause),

        // Genuine Architectural Sv39 DTLB Translation for Port 2 (P0-2)
        .dtlb_hit_i                 (dtlb0_hit),
        .dtlb_pa_i                  (dtlb0_pa),
        .dtlb_page_fault_i          (dtlb0_page_fault),
        .dtlb_access_fault_i        (dtlb0_access_fault),
        .dtlb_miss_alloc_o          (trt_alloc_req),
        .dtlb_miss_is_store_o       (trt_alloc_is_store),
        .dtlb_miss_q_idx_o          (trt_alloc_q_idx),
        .dtlb_miss_vpn_o            (trt_alloc_vpn),
        .dtlb_miss_rob_idx_o        (trt_alloc_rob_idx),
        .dtlb_miss_rob_epoch_o      (trt_alloc_rob_epoch),
        .trt_assigned_tr_id_i       (trt_assigned_tr_id),
        .trt_alloc_ready_i          (trt_alloc_ready),

        // Port 3 AGU Delivery
        .agu1_valid_i               (memiq_issue1_valid),
        .agu1_lq_idx_i              (memiq_issue1_uop.lq_idx),
        .agu1_va_i                  (agu1_ea),
        .agu1_byte_mask_i           (agu1_byte_mask),
        .agu1_align_fault_i         (agu1_align_fault),
        .agu1_exc_cause_i           (agu1_exc_cause),

        // Genuine Architectural Sv39 DTLB Translation for Port 3 (P0-2)
        .dtlb1_hit_i                (dtlb1_hit),
        .dtlb1_pa_i                 (dtlb1_pa),
        .dtlb1_page_fault_i         (dtlb1_page_fault),
        .dtlb1_access_fault_i       (dtlb1_access_fault),
        .port2_busy_o               (lsu_queues_port2_busy),
        .port3_busy_o               (lsu_queues_port3_busy),

        .trt_delivery_valid_i       (vmem_active ? 1'b0 : trt_delivery_valid),
        .trt_delivery_is_store_i    (trt_delivery_is_store),
        .trt_delivery_q_idx_i       (trt_delivery_q_idx),
        .trt_delivery_pa_i          (trt_delivery_pa),
        .trt_delivery_page_fault_i  (trt_delivery_page_fault),
        .trt_delivery_access_fault_i(trt_delivery_access_fault),
        .trt_delivery_rob_idx_i     (trt_delivery_rob_idx),
        .trt_delivery_rob_epoch_i   (trt_delivery_rob_epoch),

        .prf_r5_data_i              (r5_data_i),
        .fprf_r3_data_i             (r3_fp_data_i),
        .wb0_valid_i                (wb0_valid_i),
        .wb0_comp_ack_i             (wb0_comp_ack_i),
        .wb0_pnew_i                 (wb0_pnew_i),
        .wb0_data_i                 (wb0_data_i),
        .wb0_fp_valid_i             (wb0_fp_valid_i),
        .wb0_fp_paddr_i             (wb0_fp_paddr_i),
        .wb0_fp_data_i              (wb0_fp_data_i),
        .wb1_valid_i                (wb1_valid_i),
        .wb1_comp_ack_i             (wb1_comp_ack_i),
        .wb1_pnew_i                 (wb1_pnew_i),
        .wb1_data_i                 (wb1_data_i),
        .wb2_valid_i                (wb2_valid_i),
        .wb2_comp_ack_i             (wb2_comp_ack_i),
        .wb2_comp_exception_i       (wb2_comp_exception_i),
        .wb2_pnew_i                 (wb2_pnew_i),
        .wb2_data_i                 (wb2_data_i),
        .wb3_valid_i                (wb3_valid_i),
        .wb3_comp_ack_i             (wb3_comp_ack_i),
        .wb3_comp_exception_i       (wb3_comp_exception_i),
        .wb3_pnew_i                 (wb3_pnew_i),
        .wb3_data_i                 (wb3_data_i),

        .l1d_load0_req_valid_o      (l1d_load0_req_valid),
        .l1d_load0_req_lq_idx_o     (l1d_load0_req_lq_idx),
        .l1d_load0_req_pa_o         (l1d_load0_req_pa),
        .l1d_load0_req_size_o       (l1d_load0_req_size),
        .l1d_load0_req_sign_ext_o   (l1d_load0_req_sign_ext),
        .l1d_load0_req_pnew_o       (l1d_load0_req_pnew),
        .l1d_load0_req_rob_idx_o    (l1d_load0_req_rob_idx),
        .l1d_load0_req_rob_epoch_o  (l1d_load0_req_rob_epoch),
        .l1d_load0_req_is_amo_o     (l1d_load0_req_is_amo),
        .l1d_load0_req_ready_i      (l1d_load0_req_ready),

        .l1d_load0_rsp_valid_i      (vmem_active ? 1'b0 : l1d_load0_rsp_valid),
        .l1d_load0_rsp_lq_idx_i     (l1d_load0_rsp_lq_idx),
        .l1d_load0_rsp_hit_i        (l1d_load0_rsp_hit),
        .l1d_load0_rsp_data_i       (l1d_load0_rsp_data),
        .l1d_load0_rsp_mshr_id_i    (l1d_load0_rsp_mshr_id),

        .l1d_load1_req_valid_o      (l1d_load1_req_valid),
        .l1d_load1_req_lq_idx_o     (l1d_load1_req_lq_idx),
        .l1d_load1_req_pa_o         (l1d_load1_req_pa),
        .l1d_load1_req_size_o       (l1d_load1_req_size),
        .l1d_load1_req_sign_ext_o   (l1d_load1_req_sign_ext),
        .l1d_load1_req_pnew_o       (l1d_load1_req_pnew),
        .l1d_load1_req_rob_idx_o    (l1d_load1_req_rob_idx),
        .l1d_load1_req_rob_epoch_o  (l1d_load1_req_rob_epoch),
        .l1d_load1_req_ready_i      (l1d_load1_req_ready),

        .l1d_load1_rsp_valid_i      (l1d_load1_rsp_valid),
        .l1d_load1_rsp_lq_idx_i     (l1d_load1_rsp_lq_idx),
        .l1d_load1_rsp_hit_i        (l1d_load1_rsp_hit),
        .l1d_load1_rsp_data_i       (l1d_load1_rsp_data),
        .l1d_load1_rsp_mshr_id_i    (l1d_load1_rsp_mshr_id),

        .mshr_refill_valid_i        (vmem_active ? 1'b0 : refill_comp_valid),
        .mshr_refill_lq_idx_i       (refill_comp_lq_idx),
        .mshr_refill_pnew_i         (refill_comp_pnew),
        .mshr_refill_rob_idx_i      (refill_comp_rob_idx),
        .mshr_refill_rob_epoch_i    (refill_comp_rob_epoch),
        .mshr_refill_data_i         (refill_comp_data),

        .l1d_store_drain_valid_o    (l1d_store_drain_valid),
        .l1d_store_drain_sq_idx_o   (l1d_store_drain_sq_idx),
        .l1d_store_drain_pa_o       (l1d_store_drain_pa),
        .l1d_store_drain_mask_o     (l1d_store_drain_mask),
        .l1d_store_drain_data_o     (l1d_store_drain_data),
        .l1d_store_drain_ready_i    (l1d_store_drain_ready),
        .l1d_store_drain_done_i     (vmem_active ? 1'b0 : l1d_store_drain_done),
        .l1d_quiescent_i            (l1d_quiescent),
        .sq_empty_o                 (sq_empty_o),

        .l1d_sc_acquire_valid_o     (l1d_sc_acquire_valid),
        .l1d_sc_acquire_pa_o        (l1d_sc_acquire_pa),
        .l1d_sc_acquire_mask_o      (l1d_sc_acquire_mask),
        .l1d_sc_acquire_data_o      (l1d_sc_acquire_data),
        .l1d_sc_res_valid_o         (l1d_sc_res_valid),
        .l1d_sc_acquire_accepted_i  (l1d_sc_acquire_accepted),
        .l1d_sc_acquire_done_i      (l1d_sc_acquire_done),
        .l1d_sc_acquire_ok_i        (l1d_sc_acquire_ok),
        .irq_pending_i              (irq_pending_i),
        .atomic_irq_inhibit_o       (atomic_irq_inhibit_o),

        .retire_valid_i             (retire_valid_i),
        .retire_pnew_i              (retire_pnew_i),
        .retire_pc_i                (retire_pc_i),
        .retire_rob_idx_i           (retire_rob_idx_i),
        .retire_epoch_i             (retire_epoch_i),

        .comp_valid_o               (p2_comp_valid_o),
        .comp_rob_idx_o             (p2_comp_rob_idx_o),
        .comp_epoch_o               (p2_comp_epoch_o),
        .comp_preg_o                (p2_comp_preg_o),
        .comp_exception_o           (p2_comp_exception_o),
        .comp_cause_o               (p2_comp_cause_o),
        .wb_data_o                  (p2_wb_data_o),
        .comp_ack_i                 (p2_comp_ack_i),
        .comp_is_fp_o               (p2_comp_is_fp_o),
        .comp_prd_fp_o              (p2_comp_prd_fp_o),
        .p2_fp_wb_valid_o           (p2_fp_wb_valid_o),
        .p2_fp_wb_paddr_o           (p2_fp_wb_paddr_o),
        .p2_fp_wb_data_o            (p2_fp_wb_data_o),

        .p3_comp_valid_o            (p3_comp_valid_o),
        .p3_comp_rob_idx_o          (p3_comp_rob_idx_o),
        .p3_comp_epoch_o            (p3_comp_epoch_o),
        .p3_comp_preg_o             (p3_comp_preg_o),
        .p3_comp_exception_o        (p3_comp_exception_o),
        .p3_comp_cause_o            (p3_comp_cause_o),
        .p3_wb_data_o               (p3_wb_data_o),
        .p3_comp_ack_i              (p3_comp_ack_i),
        .p3_comp_is_fp_o            (p3_comp_is_fp_o),
        .p3_comp_prd_fp_o           (p3_comp_prd_fp_o),
        .p3_fp_wb_valid_o           (p3_fp_wb_valid_o),
        .p3_fp_wb_paddr_o           (p3_fp_wb_paddr_o),
        .p3_fp_wb_data_o            (p3_fp_wb_data_o),

        .event_load_fwd_exact_o     (event_load_fwd_exact_o),
        .event_load_fwd_partial_o   (event_load_fwd_partial_o),
        .event_load_speculative_o   (event_load_speculative_o),
        .rob_head_is_mem_stall_o    (rob_head_is_mem_stall_o),

        .lsu_violation_valid_o      (lsu_violation_valid_o),
        .lsu_violation_rob_idx_o    (lsu_violation_rob_idx_o),
        .lsu_violation_rob_epoch_o  (lsu_violation_rob_epoch_o),
        .lsu_retire0_allow_o        (lsu_retire0_allow_o),
        .lsu_retire1_allow_o        (lsu_retire1_allow_o),

        .snoop_req_valid_i          (snoop_req_valid_i),
        .snoop_req_addr_i           (snoop_req_addr_i),
        .snoop_req_type_i           (snoop_req_type_i),
        .snoop_req_ready_i          (snoop_req_ready_o),
        .l1d_snoop_s0_valid_i       (l1d_snoop_s0_valid),
        .l1d_snoop_s0_addr_i        (l1d_snoop_s0_addr),
        .l1d_snoop_s0_do_inv_i      (l1d_snoop_s0_do_inv),
        .event_snoop_replay_o       (event_snoop_replay_o),

        .mmio_req_valid_o           (mmio_req_valid_o),
        .mmio_req_addr_o            (mmio_req_addr_o),
        .mmio_req_is_store_o        (mmio_req_is_store_o),
        .mmio_req_size_o            (mmio_req_size_o),
        .mmio_req_wdata_o           (mmio_req_wdata_o),
        .mmio_req_wstrb_o           (mmio_req_wstrb_o),
        .mmio_req_ready_i           (mmio_req_ready_i),
        .mmio_rsp_valid_i           (mmio_rsp_valid_i),
        .mmio_rsp_rdata_i           (mmio_rsp_rdata_i),
        .mmio_rsp_error_i           (mmio_rsp_error_i),
        .mmio_rsp_ready_o           (mmio_rsp_ready_o)
    );

    // =========================================================================
    // 6. Non-Speculative Single-Element Vector Memory Adapter (ROB Head)
    // =========================================================================
    wire vmem_misaligned = (vec_mem_req_size_i == MEM_SIZE_HALF   && vec_mem_req_va_i[0]) ||
                           (vec_mem_req_size_i == MEM_SIZE_WORD   && (vec_mem_req_va_i[1:0] != 2'b00)) ||
                           (vec_mem_req_size_i == MEM_SIZE_DOUBLE && (vec_mem_req_va_i[2:0] != 3'b000));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i || recover_valid_i) begin
            vmem_state_q            <= VMEM_IDLE;
            vmem_trt_alloc_q        <= 1'b0;
            vmem_pa_q               <= 56'd0;
            vec_mem_rsp_valid_o     <= 1'b0;
            vec_mem_rsp_rdata_o     <= 64'd0;
            vec_mem_rsp_exception_o <= 1'b0;
            vec_mem_rsp_cause_o     <= 5'd0;
        end else begin
            vec_mem_rsp_valid_o     <= 1'b0;
            vec_mem_rsp_exception_o <= 1'b0;

            case (vmem_state_q)
                VMEM_IDLE: begin
                    if (vec_mem_req_valid_i && !vec_mem_rsp_valid_o &&
                        sq_empty_o && l1d_quiescent && (lq_count_o == 5'd0) &&
                        !lsu_queues_port2_busy && !lsu_queues_port3_busy) begin
                        vmem_state_q <= VMEM_DTLB_CHK;
                    end
                end

                VMEM_DTLB_CHK: begin
                    if (vmem_misaligned) begin
                        vec_mem_rsp_valid_o     <= 1'b1;
                        vec_mem_rsp_exception_o <= 1'b1;
                        vec_mem_rsp_cause_o     <= vec_mem_req_is_store_i ? 5'd6 : 5'd4;
                        vmem_state_q            <= VMEM_IDLE;
                    end else if (dtlb0_hit) begin
                        if (dtlb0_page_fault || dtlb0_access_fault || !is_dram_pa(dtlb0_pa)) begin
                            vec_mem_rsp_valid_o     <= 1'b1;
                            vec_mem_rsp_exception_o <= 1'b1;
                            vec_mem_rsp_cause_o     <= dtlb0_page_fault ? (vec_mem_req_is_store_i ? 5'd15 : 5'd13)
                                                                        : (vec_mem_req_is_store_i ? 5'd7  : 5'd5);
                            vmem_state_q            <= VMEM_IDLE;
                        end else begin
                            vmem_pa_q    <= dtlb0_pa;
                            vmem_state_q <= vec_mem_req_is_store_i ? VMEM_L1D_ST_WAIT : VMEM_L1D_LD_REQ;
                        end
                    end else begin
                        vmem_trt_alloc_q <= 1'b1;
                        vmem_state_q     <= VMEM_WAIT_TRT;
                    end
                end

                VMEM_WAIT_TRT: begin
                    if (vmem_trt_alloc_q) begin
                        if (trt_alloc_ready) begin
                            vmem_trt_alloc_q <= 1'b0;
                        end
                    end else if (trt_delivery_valid) begin
                        logic [55:0] resolved_pa;
                        resolved_pa = {trt_delivery_pa[55:12], vec_mem_req_va_i[11:0]};
                        if (trt_delivery_page_fault || trt_delivery_access_fault || !is_dram_pa(resolved_pa)) begin
                            vec_mem_rsp_valid_o     <= 1'b1;
                            vec_mem_rsp_exception_o <= 1'b1;
                            vec_mem_rsp_cause_o     <= trt_delivery_page_fault ? (vec_mem_req_is_store_i ? 5'd15 : 5'd13)
                                                                               : (vec_mem_req_is_store_i ? 5'd7  : 5'd5);
                            vmem_state_q            <= VMEM_IDLE;
                        end else begin
                            vmem_pa_q    <= resolved_pa;
                            vmem_state_q <= vec_mem_req_is_store_i ? VMEM_L1D_ST_WAIT : VMEM_L1D_LD_REQ;
                        end
                    end
                end

                VMEM_L1D_LD_REQ: begin
                    if (l1d_load0_req_ready) begin
                        if (l1d_load0_rsp_valid && l1d_load0_rsp_hit) begin
                            vec_mem_rsp_valid_o <= 1'b1;
                            vec_mem_rsp_rdata_o <= l1d_load0_rsp_data;
                            vmem_state_q        <= VMEM_IDLE;
                        end else begin
                            vmem_state_q <= VMEM_L1D_LD_WAIT;
                        end
                    end
                end

                VMEM_L1D_LD_WAIT: begin
                    if (refill_comp_valid &&
                        (refill_comp_rob_idx == vec_mem_req_rob_idx_i) &&
                        (refill_comp_rob_epoch == vec_mem_req_rob_epoch_i)) begin
                        vec_mem_rsp_valid_o <= 1'b1;
                        vec_mem_rsp_rdata_o <= refill_comp_data;
                        vmem_state_q        <= VMEM_IDLE;
                    end
                end

                VMEM_L1D_ST_WAIT: begin
                    if (l1d_store_drain_done) begin
                        vec_mem_rsp_valid_o <= 1'b1;
                        vec_mem_rsp_rdata_o <= 64'd0;
                        vmem_state_q        <= VMEM_IDLE;
                    end
                end

                default: vmem_state_q <= VMEM_IDLE;
            endcase
        end
    end

endmodule

`endif // FURSOY_S1_LSU_SV
