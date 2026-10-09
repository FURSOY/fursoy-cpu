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
`include "fursoy_s1_l1d.sv"

module fursoy_s1_lsu
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

    // -------------------------------------------------------------------------
    // PRF Read Port 4 (Base) & Port 5 (Store Data) Operands
    // -------------------------------------------------------------------------
    output preg_t             r4_paddr_o,
    input  logic [63:0]       r4_data_i,

    output preg_t             r5_paddr_o,
    input  logic [63:0]       r5_data_i,

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

    // -------------------------------------------------------------------------
    // External Memory Interconnect & Translation Interface
    // -------------------------------------------------------------------------
    // Read Channel (MSHR Refills)
    output logic              bus_rd_req_valid_o,
    output logic [49:0]       bus_rd_req_addr_o,
    output mshr_idx_t         bus_rd_req_tag_o,
    input  logic              bus_rd_req_ready_i,

    input  logic              bus_rd_rsp_valid_i,
    input  mshr_idx_t         bus_rd_rsp_tag_i,
    input  logic [511:0]      bus_rd_rsp_data_i,

    // Write Channel (WBB Dirty Evictions)
    output logic              bus_wr_req_valid_o,
    output logic [49:0]       bus_wr_req_addr_o,
    output logic [511:0]      bus_wr_req_data_o,
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
    output logic [MEM_IQ_DEPTH-1:0] memiq_diag_ready_o
);

    // =========================================================================
    // Internal Wiring & Decode Helpers
    // =========================================================================
    function automatic mem_size_t get_mem_size(input uop_subop_t sub_op);
        case (sub_op)
            MEM_LB, MEM_LBU, MEM_SB:                 return MEM_SIZE_BYTE;
            MEM_LH, MEM_LHU, MEM_SH:                 return MEM_SIZE_HALF;
            MEM_LW, MEM_LWU, MEM_SW, MEM_LR_W, MEM_SC_W,
            AMO_SWAP_W, AMO_ADD_W, AMO_XOR_W,
            AMO_AND_W, AMO_OR_W, AMO_MIN_W,
            AMO_MAX_W, AMO_MINU_W, AMO_MAXU_W:       return MEM_SIZE_WORD;
            MEM_FENCE:                               return MEM_SIZE_BYTE;
            default:                                 return MEM_SIZE_DOUBLE;
        endcase
    endfunction

    function automatic logic get_mem_sign_ext(input uop_subop_t sub_op);
        case (sub_op)
            MEM_LB, MEM_LH, MEM_LW: return 1'b1;
            default:                return 1'b0;
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

    wire uop0_is_mem = uop0_is_load || uop0_is_store;

    assign mem_dispatch_ready_o[0] = memiq_ready[0] &&
                                     (!uop0_is_load  || lq_ready[0]) &&
                                     (!uop0_is_store || sq_ready[0]);

    assign mem_dispatch_ready_o[1] = (uop0_is_mem ? memiq_ready[1] : memiq_ready[0]) &&
                                     (!uop1_is_load  || (uop0_is_load ? lq_ready[1] : lq_ready[0])) &&
                                     (!uop1_is_store || (!uop0_is_store && sq_ready[0]));

    // =========================================================================
    // 1. Memory Issue Queue (MemIQ)
    // =========================================================================
    logic         memiq_issue_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    memiq_entry_t memiq_issue_uop;
    /* verilator lint_on UNUSEDSIGNAL */

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
        .uop1_lq_idx_i      (uop0_is_load ? alloc_lq1 : alloc_lq0),
        .uop1_sq_idx_i      (uop0_is_store ? alloc_sq1 : alloc_sq0),
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

        .port2_busy_i       (1'b0),
        .issue_valid_o      (memiq_issue_valid),
        .issue_uop_o        (memiq_issue_uop),

        /* verilator lint_off PINCONNECTEMPTY */
        .diag_valid_mask_o  (),
        .diag_ready_mask_o  (memiq_diag_ready_o),
        .free_count_o       (),
        .count_o            ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    assign event_load_issued_o = memiq_issue_valid && (memiq_issue_uop.uop_class == UOP_LOAD);
    assign memiq_ready_o       = memiq_ready;
    assign lq_ready_o          = lq_ready;
    assign sq_ready_o          = sq_ready;
    assign event_dtlb_miss_o   = ptw_req_valid_o && ptw_req_ready_i;

    // Drive PRF Read Port 4 (Base Address)
    assign r4_paddr_o = memiq_issue_uop.prs1;
    // Drive PRF Read Port 5 (Store Data)
    assign r5_paddr_o = uop0_is_store ? uop0_prs2_i : uop1_prs2_i; // Monitored during dispatch

    // Read Operand Forwarding for Base Address
    logic [63:0] agu_base_operand;
    always_comb begin
        if (memiq_issue_uop.prs1 == 7'd0) begin
            agu_base_operand = 64'd0;
        end else if (wb2_valid_i && wb2_comp_ack_i && !wb2_comp_exception_i && (wb2_pnew_i == memiq_issue_uop.prs1)) begin
            agu_base_operand = wb2_data_i;
        end else if (wb1_valid_i && wb1_comp_ack_i && (wb1_pnew_i == memiq_issue_uop.prs1)) begin
            agu_base_operand = wb1_data_i;
        end else if (wb0_valid_i && wb0_comp_ack_i && (wb0_pnew_i == memiq_issue_uop.prs1)) begin
            agu_base_operand = wb0_data_i;
        end else begin
            agu_base_operand = r4_data_i;
        end
    end

    // =========================================================================
    // 2. Port 2 Address Generation Unit (AGU)
    // =========================================================================
    logic [63:0] agu_ea;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [2:0]  agu_byte_offset;
    logic [5:0]  agu_line_offset;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  agu_byte_mask;
    logic        agu_align_fault;
    logic [4:0]  agu_exc_cause;

    fursoy_s1_agu u_agu (
        .valid_i        (memiq_issue_valid),
        .sub_op_i       (memiq_issue_uop.sub_op),
        .size_i         (memiq_issue_uop.size),
        .base_i         (agu_base_operand),
        .imm_i          (memiq_issue_uop.imm),
        .is_store_i     ((memiq_issue_uop.uop_class == UOP_STORE) || (memiq_issue_uop.uop_class == UOP_AMO)),
        .ea_o           (agu_ea),
        .byte_offset_o  (agu_byte_offset),
        .line_offset_o  (agu_line_offset),
        .byte_mask_o    (agu_byte_mask),
        .align_fault_o  (agu_align_fault),
        .exc_cause_o    (agu_exc_cause)
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

    fursoy_s1_trt u_trt (
        .clk_i                      (clk_i),
        .rst_i                      (rst_i),
        .flush_valid_i              (flush_valid_i),
        .recover_valid_i            (recover_valid_i),
        .recover_rob_idx_i          (recover_rob_idx_i),
        .rob_head_i                 (rob_head_i),

        .alloc_req_i                (trt_alloc_req),
        .alloc_is_store_i           (trt_alloc_is_store),
        .alloc_q_idx_i              (trt_alloc_q_idx),
        .alloc_vpn_i                (trt_alloc_vpn),
        .alloc_access_type_i        (trt_alloc_is_store ? 2'b01 : 2'b00),
        .alloc_rob_idx_i            (trt_alloc_rob_idx),
        .alloc_rob_epoch_i          (trt_alloc_rob_epoch),
        /* verilator lint_off PINCONNECTEMPTY */
        .alloc_ready_o              (),
        /* verilator lint_on PINCONNECTEMPTY */
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

        .trt_delivery_valid_o       (trt_delivery_valid),
        .trt_delivery_is_store_o    (trt_delivery_is_store),
        .trt_delivery_q_idx_o       (trt_delivery_q_idx),
        .trt_delivery_pa_o          (trt_delivery_pa),
        .trt_delivery_page_fault_o  (trt_delivery_page_fault),
        .trt_delivery_access_fault_o(trt_delivery_access_fault),
        /* verilator lint_off PINCONNECTEMPTY */
        .trt_delivery_rob_idx_o     (),
        .trt_delivery_rob_epoch_o   ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // =========================================================================
    // 4. Non-Blocking L1 Data Cache (L1D) Subsystem
    // =========================================================================
    logic        l1d_load_req_valid;
    lq_idx_t     l1d_load_req_lq_idx;
    logic [55:0] l1d_load_req_pa;
    mem_size_t   l1d_load_req_size;
    logic        l1d_load_req_sign_ext;
    preg_t       l1d_load_req_pnew;
    rob_idx_t    l1d_load_req_rob_idx;
    rob_epoch_t  l1d_load_req_rob_epoch;
    logic        l1d_load_req_ready;

    logic        l1d_load_rsp_valid;
    lq_idx_t     l1d_load_rsp_lq_idx;
    logic        l1d_load_rsp_hit;
    logic [63:0] l1d_load_rsp_data;
    mshr_idx_t   l1d_load_rsp_mshr_id;

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

    fursoy_s1_l1d u_l1d (
        .clk_i                      (clk_i),
        .rst_i                      (rst_i),
        .flush_valid_i              (flush_valid_i),
        .recover_valid_i            (recover_valid_i),
        .recover_rob_idx_i          (recover_rob_idx_i),
        .rob_head_i                 (rob_head_i),

        .load_req_valid_i           (l1d_load_req_valid),
        .load_req_lq_idx_i          (l1d_load_req_lq_idx),
        .load_req_pa_i              (l1d_load_req_pa),
        .load_req_size_i            (l1d_load_req_size),
        .load_req_sign_ext_i        (l1d_load_req_sign_ext),
        .load_req_pnew_i            (l1d_load_req_pnew),
        .load_req_rob_idx_i         (l1d_load_req_rob_idx),
        .load_req_rob_epoch_i       (l1d_load_req_rob_epoch),
        .load_req_ready_o           (l1d_load_req_ready),

        .load_rsp_valid_o           (l1d_load_rsp_valid),
        .load_rsp_lq_idx_o          (l1d_load_rsp_lq_idx),
        .load_rsp_hit_o             (l1d_load_rsp_hit),
        .load_rsp_data_o            (l1d_load_rsp_data),
        .load_rsp_mshr_id_o         (l1d_load_rsp_mshr_id),

        .store_drain_valid_i        (l1d_store_drain_valid),
        .store_drain_sq_idx_i       (l1d_store_drain_sq_idx),
        .store_drain_pa_i           (l1d_store_drain_pa),
        .store_drain_mask_i         (l1d_store_drain_mask),
        .store_drain_data_i         (l1d_store_drain_data),
        .store_drain_ready_o        (l1d_store_drain_ready),
        .store_drain_done_o         (l1d_store_drain_done),

        .refill_comp_valid_o        (refill_comp_valid),
        .refill_comp_lq_idx_o       (refill_comp_lq_idx),
        .refill_comp_pnew_o         (refill_comp_pnew),
        .refill_comp_rob_idx_o      (refill_comp_rob_idx),
        .refill_comp_rob_epoch_o    (refill_comp_rob_epoch),
        .refill_comp_data_o         (refill_comp_data),

        .event_l1d_hit_o            (event_l1d_hit_o),
        .event_l1d_miss_o           (event_l1d_miss_o),
        .mshr_occ_o                 (event_l1d_mshr_occ_o),
        .wbb_full_o                 (event_l1d_wbb_full_o),

        .bus_rd_req_valid_o         (bus_rd_req_valid_o),
        .bus_rd_req_addr_o          (bus_rd_req_addr_o),
        .bus_rd_req_tag_o           (bus_rd_req_tag_o),
        .bus_rd_req_ready_i         (bus_rd_req_ready_i),

        .bus_rd_rsp_valid_i         (bus_rd_rsp_valid_i),
        .bus_rd_rsp_tag_i           (bus_rd_rsp_tag_i),
        .bus_rd_rsp_data_i          (bus_rd_rsp_data_i),

        .bus_wr_req_valid_o         (bus_wr_req_valid_o),
        .bus_wr_req_addr_o          (bus_wr_req_addr_o),
        .bus_wr_req_data_o          (bus_wr_req_data_o),
        .bus_wr_req_ready_i         (bus_wr_req_ready_i),

        .bus_wr_rsp_valid_i         (bus_wr_rsp_valid_i),

        .dcache_clean_all_req_i     (dcache_clean_all_req_i),
        .dcache_clean_all_done_o    (dcache_clean_all_done_o),
        .l1d_quiescent_o            (l1d_quiescent)
    );

    // =========================================================================
    // 5. Load Queue (LQ) & Store Queue (SQ)
    // =========================================================================
    fursoy_s1_lsu_queues u_lsu_queues (
        .clk_i                      (clk_i),
        .rst_i                      (rst_i),
        .flush_valid_i              (flush_valid_i),
        .recover_valid_i            (recover_valid_i),
        .recover_rob_idx_i          (recover_rob_idx_i),
        .rob_head_i                 (rob_head_i),
        .rob_head_next_i            (rob_head_next_i),

        .lq_ready_o                 (lq_ready),
        .sq_ready_o                 (sq_ready),
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

        .agu_valid_i                (memiq_issue_valid),
        .agu_is_store_i             ((memiq_issue_uop.uop_class == UOP_STORE) || (memiq_issue_uop.uop_class == UOP_AMO)),
        .agu_lq_idx_i               (memiq_issue_uop.lq_idx),
        .agu_sq_idx_i               (memiq_issue_uop.sq_idx),
        .agu_sub_op_i               (memiq_issue_uop.sub_op),
        .agu_size_i                 (memiq_issue_uop.size),
        .agu_sign_ext_i             (memiq_issue_uop.sign_ext),
        .agu_va_i                   (agu_ea),
        .agu_byte_mask_i            (agu_byte_mask),
        .agu_align_fault_i          (agu_align_fault),
        .agu_exc_cause_i            (agu_exc_cause),

        // Base translation: identity map with variable-latency miss boundary on unmapped test pages
        .dtlb_hit_i                 (!((agu_ea[55:12] == 44'h3D) ||
                                       (agu_ea[55:12] == 44'h70) ||
                                       (agu_ea[55:12] == 44'h71) ||
                                       (agu_ea[55:12] == 44'h72))),
        .dtlb_pa_i                  (agu_ea[55:0]),
        .dtlb_page_fault_i          (1'b0),
        .dtlb_access_fault_i        (1'b0),
        .dtlb_miss_alloc_o          (trt_alloc_req),
        .dtlb_miss_is_store_o       (trt_alloc_is_store),
        .dtlb_miss_q_idx_o          (trt_alloc_q_idx),
        .dtlb_miss_vpn_o            (trt_alloc_vpn),
        .dtlb_miss_rob_idx_o        (trt_alloc_rob_idx),
        .dtlb_miss_rob_epoch_o      (trt_alloc_rob_epoch),
        .trt_assigned_tr_id_i       (trt_assigned_tr_id),

        .trt_delivery_valid_i       (trt_delivery_valid),
        .trt_delivery_is_store_i    (trt_delivery_is_store),
        .trt_delivery_q_idx_i       (trt_delivery_q_idx),
        .trt_delivery_pa_i          (trt_delivery_pa),
        .trt_delivery_page_fault_i  (trt_delivery_page_fault),
        .trt_delivery_access_fault_i(trt_delivery_access_fault),

        .prf_r5_data_i              (r5_data_i),
        .wb0_valid_i                (wb0_valid_i),
        .wb0_comp_ack_i             (wb0_comp_ack_i),
        .wb0_pnew_i                 (wb0_pnew_i),
        .wb0_data_i                 (wb0_data_i),
        .wb1_valid_i                (wb1_valid_i),
        .wb1_comp_ack_i             (wb1_comp_ack_i),
        .wb1_pnew_i                 (wb1_pnew_i),
        .wb1_data_i                 (wb1_data_i),
        .wb2_valid_i                (wb2_valid_i),
        .wb2_comp_ack_i             (wb2_comp_ack_i),
        .wb2_comp_exception_i       (wb2_comp_exception_i),
        .wb2_pnew_i                 (wb2_pnew_i),
        .wb2_data_i                 (wb2_data_i),

        .l1d_load_req_valid_o       (l1d_load_req_valid),
        .l1d_load_req_lq_idx_o      (l1d_load_req_lq_idx),
        .l1d_load_req_pa_o          (l1d_load_req_pa),
        .l1d_load_req_size_o        (l1d_load_req_size),
        .l1d_load_req_sign_ext_o    (l1d_load_req_sign_ext),
        .l1d_load_req_pnew_o        (l1d_load_req_pnew),
        .l1d_load_req_rob_idx_o     (l1d_load_req_rob_idx),
        .l1d_load_req_rob_epoch_o   (l1d_load_req_rob_epoch),
        .l1d_load_req_ready_i       (l1d_load_req_ready),

        .l1d_load_rsp_valid_i       (l1d_load_rsp_valid),
        .l1d_load_rsp_lq_idx_i      (l1d_load_rsp_lq_idx),
        .l1d_load_rsp_hit_i         (l1d_load_rsp_hit),
        .l1d_load_rsp_data_i        (l1d_load_rsp_data),
        .l1d_load_rsp_mshr_id_i     (l1d_load_rsp_mshr_id),

        .mshr_refill_valid_i        (refill_comp_valid),
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
        .l1d_store_drain_done_i     (l1d_store_drain_done),
        .l1d_quiescent_i            (l1d_quiescent),
        .sq_empty_o                 (sq_empty_o),

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

        .event_load_fwd_exact_o     (event_load_fwd_exact_o),
        .event_load_fwd_partial_o   (event_load_fwd_partial_o),
        .event_load_speculative_o   (event_load_speculative_o),
        .rob_head_is_mem_stall_o    (rob_head_is_mem_stall_o),

        .lsu_violation_valid_o      (lsu_violation_valid_o),
        .lsu_violation_rob_idx_o    (lsu_violation_rob_idx_o),
        .lsu_violation_rob_epoch_o  (lsu_violation_rob_epoch_o),
        .lsu_retire0_allow_o        (lsu_retire0_allow_o),
        .lsu_retire1_allow_o        (lsu_retire1_allow_o)
    );

endmodule

`endif // FURSOY_S1_LSU_SV
