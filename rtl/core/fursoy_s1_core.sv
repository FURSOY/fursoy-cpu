`ifndef FURSOY_S1_CORE_SV
`define FURSOY_S1_CORE_SV

// =============================================================================
// Fursoy Slice-1 Core Top-Level — Milestone 4 (Integrated Frontend & Backend)
// =============================================================================
// Integrates:
// - Milestone 1 Architectural Substrate: Rename, Free List, RATs, PRF Readiness,
//   ROB48, Epoch Tracking, In-Order Retirement, and Checkpoint Recovery.
// - Milestone 2 Integer Execution Backend: IntIQ 16-entry, wrap-safe ROB age arbiter,
//   64-bit 80-entry PRF data array, Port 0 (ALU0/Branch), Port 1 (ALU1/MUL/DIV),
//   lossless Port 1 completion buffers, writeback validation, and lifetime-gated recovery.
// - Milestone 3 Out-of-Order Memory Subsystem: MemIQ, Port 2 AGU, TRT, LQ16, SQ16,
//   Non-blocking L1D Cache (16 KiB 4-way, 4 MSHRs, 2 WBBs), LR/SC & FENCE.
// - Milestone 4 Complete Frontend Subsystem: F0-D0 64-bit fetch pipeline, 512-entry
//   2-way BTB, 4096-entry Gshare direction predictor with 12-bit GHR, 16-entry circular
//   RAS with full 16x64-bit checkpointing, 12-entry Decoupled Fetch Queue, 16 KiB 4-way
//   VIPT L1I with dual I-MSHRs, F2 skid buffer, 72-entry ITLB (64 base + 8 superpage CAM),
//   persistent 2-entry ITRT, centralized shared Sv39 3-level PTW with 4:1 bounded fairness,
//   real FENCE.I system serialization controller with L1D clean-all maintenance sweep.
// Reference: docs/architecture/slice1-core-v1.md
//            docs/architecture/slice1-m2-backend-v1.md
//            docs/architecture/slice1-m3-memory-v1.md
//            docs/architecture/slice1-m4-frontend-v1.md
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_substrate.sv"
`include "fursoy_s1_backend.sv"
`include "fursoy_s1_frontend.sv"
`include "fursoy_s1_csr.sv"

module fursoy_s1_core
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned PRF_COUNT   = PRF_SIZE,       // 80
    parameter int unsigned AREG_NUM    = AREG_COUNT,      // 32
    parameter int unsigned ROB_NUM     = ROB_DEPTH,       // 48
    parameter int unsigned CHKPT_NUM   = NUM_CHECKPOINTS  // 8
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // -------------------------------------------------------------------------
    // Milestone 4 Frontend Mode Control
    // -------------------------------------------------------------------------
    // When frontend_en_i == 1'b1, frontend autonomously fetches, predicts,
    // and decodes RV64 instructions, feeding Rename/Dispatch directly.
    // When frontend_en_i == 1'b0, legacy testbench ports (uop0/uop1) feed Rename/Dispatch.
    input  logic                   frontend_en_i,
    input  logic [1:0]             priv_mode_i,
    input  logic [63:0]            mstatus_i,
    input  logic [63:0]            satp_i,
    input  logic                   pmp_allow_i,

    input  logic                   trap_valid_i,
    input  logic [63:0]            trap_target_i,
    input  logic                   mret_valid_i,
    input  logic [63:0]            mret_target_i,

    input  logic                   sfence_vma_valid_i,
    input  logic [63:0]            sfence_vma_va_i,
    input  logic [15:0]            sfence_vma_asid_i,

    // -------------------------------------------------------------------------
    // 2-Wide Rename / Dispatch Legacy Input Interface (M1/M2/M3 TB Compatibility)
    // -------------------------------------------------------------------------
    // Uop 0 Input
    input  logic                   uop0_valid_i,
    input  areg_t                  uop0_rs1_i,
    input  areg_t                  uop0_rs2_i,
    input  areg_t                  uop0_rd_i,
    input  uop_class_t             uop0_class_i,
    input  uop_subop_t             uop0_subop_i,
    input  logic [63:0]            uop0_imm_i,
    input  logic                   uop0_use_imm_i,
    input  logic [63:0]            uop0_pc_i,
    input  logic                   uop0_pred_taken_i,
    input  logic [63:0]            uop0_pred_target_i,
    input  logic                   uop0_is_branch_i,
    input  logic                   uop0_is_jal_i,
    input  logic                   uop0_is_jalr_i,

    // Uop 1 Input
    input  logic                   uop1_valid_i,
    input  areg_t                  uop1_rs1_i,
    input  areg_t                  uop1_rs2_i,
    input  areg_t                  uop1_rd_i,
    input  uop_class_t             uop1_class_i,
    input  uop_subop_t             uop1_subop_i,
    input  logic [63:0]            uop1_imm_i,
    input  logic                   uop1_use_imm_i,
    input  logic [63:0]            uop1_pc_i,
    input  logic                   uop1_pred_taken_i,
    input  logic [63:0]            uop1_pred_target_i,
    input  logic                   uop1_is_branch_i,
    input  logic                   uop1_is_jal_i,
    input  logic                   uop1_is_jalr_i,

    // Acceptance Acknowledgment to Decode / Frontend
    output logic [1:0]             rename_ack_o,

    // -------------------------------------------------------------------------
    // Full Architectural Flush Interface (Traps, Interrupts)
    // -------------------------------------------------------------------------
    input  logic                   flush_valid_i,

    // -------------------------------------------------------------------------
    // In-Order Retirement Interface
    // -------------------------------------------------------------------------
    input  logic                   retire_ready_i,

    output logic [1:0]             retire_valid_o,
    output areg_t                  retire_rd_o           [1:0],
    output preg_t                  retire_pnew_o         [1:0],
    output preg_t                  retire_pold_o         [1:0],
    output logic [1:0]             retire_is_branch_o,
    output chkpt_idx_t             retire_chkpt_id_o     [1:0],
    output logic [63:0]            retire_pc_o           [1:0],

    // Precise Exception Signaled at ROB Head
    output logic                   retire_exception_o,
    output logic [4:0]             retire_exc_cause_o,
    output logic [63:0]            retire_exc_pc_o,

    // -------------------------------------------------------------------------
    // Diagnostics & Observability Exports
    // -------------------------------------------------------------------------
    output logic                   recovering_o,
    output logic                   reconstructing_o,
    output rob_idx_t               rob_head_o,
    output rob_idx_t               rob_tail_o,
    output logic [FL_CNT_W-1:0]    freelist_count_o,
    output logic [ROB_CNT_W-1:0]   rob_count_o,
    output logic [3:0]             chkpt_free_count_o,
    output logic [1:0]             dispatch_ready_o,
    output preg_t                  arat_map_o            [AREG_NUM],
    output preg_t                  srat_map_o            [AREG_NUM],
    output logic [PRF_COUNT-1:0]   prf_ready_o,

    // Writeback Probes for Verification Observability
    output logic [2:0]             comp_valid_o,
    output rob_idx_t               comp_rob_idx_o       [2:0],
    output rob_epoch_t             comp_epoch_o         [2:0],
    output preg_t                  comp_preg_o          [2:0],
    output logic [2:0]             comp_ack_o,

    // Direct Read Probe Port into PRF Data Storage (for Testbench Assertions)
    input  preg_t                  probe_paddr_i,
    output logic [63:0]            probe_pdata_o,

    // Backend Diagnostics
    output logic [15:0]            diag_valid_mask_o,
    output logic [15:0]            diag_ready_p0_o,
    output logic [15:0]            diag_ready_p1_o,
    output logic [15:0]            diag_prs1_rdy_o,
    output logic [15:0]            diag_prs2_rdy_o,
    output rob_idx_t               diag_rob_idx_o       [16],

    // ROB Head diagnostics
    output logic                   diag_head_valid_o,
    output logic                   diag_head_completed_o,
    output logic                   diag_head_exception_o,
    output areg_t                  diag_head_rd_o,
    output preg_t                  diag_head_pnew_o,
    output logic                   diag_head_is_branch_o,

    // Branch Recovery Diagnostics
    output logic                   diag_recover_valid_o,
    output rob_idx_t               diag_recover_rob_idx_o,

    input  logic                   test_inject_valid_i,
    input  logic [63:0]            test_inject_data_i,
    input  preg_t                  test_inject_pnew_i,
    input  rob_idx_t               test_inject_rob_idx_i,
    input  rob_epoch_t             test_inject_rob_epoch_i,
    input  logic                   test_inject_mispredict_i,

    // -------------------------------------------------------------------------
    // External Memory Interconnect & Translation Interface (M3 L1D Channels)
    // -------------------------------------------------------------------------
    // Read Channel (L1D MSHR Refills)
    output logic                   bus_rd_req_valid_o,
    output logic [49:0]            bus_rd_req_addr_o,
    output mshr_idx_t              bus_rd_req_tag_o,
    input  logic                   bus_rd_req_ready_i,

    input  logic                   bus_rd_rsp_valid_i,
    input  mshr_idx_t              bus_rd_rsp_tag_i,
    input  logic [511:0]           bus_rd_rsp_data_i,

    // Write Channel (L1D WBB Dirty Evictions)
    output logic                   bus_wr_req_valid_o,
    output logic [49:0]            bus_wr_req_addr_o,
    output logic [511:0]           bus_wr_req_data_o,
    input  logic                   bus_wr_req_ready_i,

    input  logic                   bus_wr_rsp_valid_i,

    // DTLB / PTW Interface (Direct M3 TB Passthrough when frontend_en_i == 0)
    output logic                   ptw_req_valid_o,
    output tr_id_t                 ptw_req_tr_id_o,
    output logic [26:0]            ptw_req_vpn_o,
    output logic [1:0]             ptw_req_access_type_o,
    input  logic                   ptw_req_ready_i,

    input  logic                   ptw_rsp_valid_i,
    input  tr_id_t                 ptw_rsp_tr_id_i,
    input  logic [55:0]            ptw_rsp_pa_i,
    input  logic                   ptw_rsp_page_fault_i,
    input  logic                   ptw_rsp_access_fault_i,

    // -------------------------------------------------------------------------
    // Milestone 4 Dedicated L1I & Shared PTW External Memory Channels
    // -------------------------------------------------------------------------
    // L1I External Bus Read Channel (Refills)
    output logic                   l1i_bus_rd_req_valid_o,
    output logic [49:0]            l1i_bus_rd_req_addr_o,
    output logic [1:0]             l1i_bus_rd_req_tag_o,
    input  logic                   l1i_bus_rd_req_ready_i,

    input  logic                   l1i_bus_rd_rsp_valid_i,
    input  logic [1:0]             l1i_bus_rd_rsp_tag_i,
    input  logic [511:0]           l1i_bus_rd_rsp_data_i,
    input  logic                   l1i_bus_rd_rsp_error_i,

    // Shared PTW External Memory Read Channel (PTE Walk Reads)
    output logic                   ptw_mem_req_valid_o,
    output logic [55:0]            ptw_mem_req_addr_o,
    input  logic                   ptw_mem_req_ready_i,

    input  logic                   ptw_mem_rsp_valid_i,
    input  logic [63:0]            ptw_mem_rsp_data_i,
    input  logic                   ptw_mem_rsp_error_i,

    // -------------------------------------------------------------------------
    // Frontend Diagnostics & Performance Instrumentation Counters (18 counters)
    // -------------------------------------------------------------------------
    output logic [3:0]             fe_fetch_queue_count_o,
    output logic                   fe_fetch_queue_full_o,
    output logic                   fe_fetch_queue_empty_o,
    output logic [63:0]            hpm_fetch_words_o,
    output logic [63:0]            hpm_fetch_uops_o,
    output logic [63:0]            hpm_fetch_empty_cyc_o,
    output logic [63:0]            hpm_fetch_full_cyc_o,
    output logic [63:0]            hpm_l1i_hits_o,
    output logic [63:0]            hpm_l1i_misses_o,
    output logic [63:0]            hpm_itlb_hits_o,
    output logic [63:0]            hpm_itlb_misses_o,
    output logic [63:0]            hpm_btb_hits_o,
    output logic [63:0]            hpm_btb_misses_o,
    output logic [63:0]            hpm_bpu_cond_pred_o,
    output logic [63:0]            hpm_ras_calls_o,
    output logic [63:0]            hpm_ras_returns_o,
    output logic [63:0]            hpm_fence_i_flushes_o,
    output logic [63:0]            hpm_redirect_cyc_o,

    // -------------------------------------------------------------------------
    // Privileged Architecture & CSR Observability
    // -------------------------------------------------------------------------
    output logic [1:0]             csr_priv_mode_o,
    output logic [63:0]            csr_mstatus_o,
    output logic [63:0]            csr_satp_o,
    output logic [63:0]            csr_mepc_o,
    output logic [63:0]            csr_mcause_o,
    output logic [63:0]            csr_mtval_o,
    output logic [63:0]            csr_sepc_o,
    output logic [63:0]            csr_scause_o,
    output logic [63:0]            csr_stval_o,
    output logic [63:0]            csr_mtvec_o,
    output logic [63:0]            csr_stvec_o,

    // -------------------------------------------------------------------------
    // Milestone 4 DTLB Test Injection & PTW Diagnostics
    // -------------------------------------------------------------------------
    input  logic                   test_dtlb_req_valid_i,
    input  tr_id_t                 test_dtlb_req_tr_id_i,
    input  logic [26:0]            test_dtlb_req_vpn_i,
    input  logic                   test_dtlb_req_is_store_i,
    input  logic                   test_dtlb_req_is_amo_i,
    output logic                   test_dtlb_req_ready_o,

    output logic                   test_dtlb_rsp_valid_o,
    output tr_id_t                 test_dtlb_rsp_tr_id_o,
    output logic [55:0]            test_dtlb_rsp_pa_o,
    output logic                   test_dtlb_rsp_page_fault_o,
    output logic                   test_dtlb_rsp_access_fault_o,

    output logic [2:0]             ptw_dtlb_grants_since_itlb_o
);

    // =========================================================================
    // Internal Interconnect Wires
    // =========================================================================

    // Renamed Uop signals from Substrate to Backend
    /* verilator lint_off UNUSEDSIGNAL */
    uop_renamed_t   sub_uop0_renamed;
    uop_renamed_t   sub_uop1_renamed;
    logic           sub_uop0_ack;
    logic           sub_uop1_ack;
    preg_t          sub_uop0_pold;
    preg_t          sub_uop1_pold;
    /* verilator lint_on UNUSEDSIGNAL */

    preg_t          sub_uop0_pnew;
    preg_t          sub_uop0_rs1_preg;
    logic           sub_uop0_rs1_ready;
    preg_t          sub_uop0_rs2_preg;
    logic           sub_uop0_rs2_ready;
    rob_idx_t       sub_uop0_rob_idx;
    rob_epoch_t     sub_uop0_rob_epoch;
    chkpt_idx_t     sub_uop0_chkpt_id;

    preg_t          sub_uop1_pnew;
    preg_t          sub_uop1_rs1_preg;
    logic           sub_uop1_rs1_ready;
    preg_t          sub_uop1_rs2_preg;
    logic           sub_uop1_rs2_ready;
    rob_idx_t       sub_uop1_rob_idx;
    rob_epoch_t     sub_uop1_rob_epoch;
    chkpt_idx_t     sub_uop1_chkpt_id;

    // Dispatch backpressure & permits
    logic [1:0]     int_dispatch_ready;
    logic [1:0]     int_rename_ack;

    // Writeback & Completion Bus
    logic [2:0]     int_comp_valid;
    rob_idx_t       int_comp_rob_idx       [2:0];
    rob_epoch_t     int_comp_epoch         [2:0];
    preg_t          int_comp_preg          [2:0];
    logic [2:0]     int_comp_branch_mispred;
    logic [2:0]     int_comp_exception;
    logic [4:0]     int_comp_cause         [2:0];
    logic [2:0]     int_comp_ack;

    // Branch Recovery Handshake
    logic           int_recover_valid;
    rob_idx_t       int_recover_rob_idx;
    chkpt_idx_t     int_recover_chkpt_id;
    logic [63:0]    int_recover_target;
    logic           int_recover_actual_taken;

    // Substrate Diagnostics
    logic           int_recovering;
    logic           int_reconstructing;
    rob_idx_t       int_rob_head;

    // Assign Output Diagnostics
    assign rename_ack_o       = int_rename_ack;
    assign dispatch_ready_o   = int_dispatch_ready;
    assign recovering_o       = int_recovering;
    assign reconstructing_o   = int_reconstructing;
    assign rob_head_o         = int_rob_head;

    assign comp_valid_o       = int_comp_valid;
    assign comp_rob_idx_o     = int_comp_rob_idx;
    assign comp_epoch_o       = int_comp_epoch;
    assign comp_preg_o        = int_comp_preg;
    assign comp_ack_o         = int_comp_ack;

    assign diag_recover_valid_o   = int_recover_valid;
    assign diag_recover_rob_idx_o = int_recover_rob_idx;

    rob_idx_t   int_retire_rob_idx [1:0];
    rob_epoch_t int_retire_epoch   [1:0];

    // L1D Maintenance and Store Quiescence
    logic       backend_dcache_clean_all_req;
    logic       backend_dcache_clean_all_done;
    logic       backend_sq_empty;

    // DTLB to PTW interconnect
    logic       backend_ptw_req_valid;
    tr_id_t     backend_ptw_req_tr_id;
    logic [26:0]backend_ptw_req_vpn;
    logic [1:0] backend_ptw_req_access_type;
    logic       backend_ptw_req_ready;
    logic       backend_ptw_rsp_valid;
    tr_id_t     backend_ptw_rsp_tr_id;
    logic [55:0]backend_ptw_rsp_pa;
    logic       backend_ptw_rsp_page_fault;
    logic       backend_ptw_rsp_access_fault;

    logic       frontend_dtlb_req_ready;
    logic       frontend_dtlb_rsp_valid;
    tr_id_t     frontend_dtlb_rsp_tr_id;
    logic [55:0]frontend_dtlb_rsp_pa;
    logic       frontend_dtlb_rsp_page_fault;
    logic       frontend_dtlb_rsp_access_fault;

    // CSR & Privileged Architecture Interconnect Wires
    logic [1:0]        csr_priv_mode;
    logic [63:0]       csr_mstatus;
    logic [63:0]       csr_satp;
    logic              csr_redirect_valid;
    logic [63:0]       csr_redirect_target;
    logic              csr_flush_valid;
    logic              csr_sfence_vma_valid;
    logic [63:0]       csr_sfence_vma_va;
    logic [15:0]       csr_sfence_vma_asid;

    logic [63:0]       backend_p0_sys_rdata;
    logic              backend_p0_sys_illegal;
    logic              backend_p0_sys_valid;
    uop_subop_t        backend_p0_sys_subop;
    logic [11:0]       backend_p0_sys_csr_addr;
    logic [4:0]        backend_p0_sys_rs1_field;
    logic [63:0]       backend_p0_sys_rs1_val;
    logic [63:0]       backend_p0_sys_rs2_val;
    logic [63:0]       backend_p0_sys_pc;
    rob_idx_t          backend_p0_sys_rob_idx;

    wire [1:0]  eff_priv_mode    = (priv_mode_i != 2'b11) ? priv_mode_i : csr_priv_mode;
    wire [63:0] eff_mstatus      = (mstatus_i != 64'd0) ? mstatus_i : csr_mstatus;
    wire [63:0] eff_satp         = (satp_i != 64'd0) ? satp_i : csr_satp;

    assign csr_priv_mode_o = eff_priv_mode;
    assign csr_mstatus_o   = eff_mstatus;
    assign csr_satp_o      = eff_satp;

    wire        eff_trap_valid   = csr_redirect_valid || trap_valid_i;
    wire [63:0] eff_trap_target  = csr_redirect_valid ? csr_redirect_target : trap_target_i;
    wire        eff_mret_valid   = mret_valid_i;
    wire [63:0] eff_mret_target  = mret_target_i;
    wire        eff_sfence_valid = csr_sfence_vma_valid || sfence_vma_valid_i;
    wire [63:0] eff_sfence_va    = csr_sfence_vma_valid ? csr_sfence_vma_va : sfence_vma_va_i;
    wire [15:0] eff_sfence_asid  = csr_sfence_vma_valid ? csr_sfence_vma_asid : sfence_vma_asid_i;
    wire        core_flush_valid = flush_valid_i || csr_flush_valid;

    // DTLB Test Injection Muxing
    logic [2:0] core_diag_grants_since_itlb;
    wire        ptw_dtlb_req_valid_w    = test_dtlb_req_valid_i ? 1'b1 : backend_ptw_req_valid;
    wire tr_id_t ptw_dtlb_req_tr_id_w   = test_dtlb_req_valid_i ? test_dtlb_req_tr_id_i : backend_ptw_req_tr_id;
    wire [26:0] ptw_dtlb_req_vpn_w      = test_dtlb_req_valid_i ? test_dtlb_req_vpn_i : backend_ptw_req_vpn;
    wire        ptw_dtlb_req_is_store_w = test_dtlb_req_valid_i ? test_dtlb_req_is_store_i : (backend_ptw_req_access_type == 2'b01);
    wire        ptw_dtlb_req_is_amo_w   = test_dtlb_req_valid_i ? test_dtlb_req_is_amo_i : (backend_ptw_req_access_type == 2'b11);

    assign test_dtlb_req_ready_o        = frontend_dtlb_req_ready;
    assign test_dtlb_rsp_valid_o        = frontend_dtlb_rsp_valid;
    assign test_dtlb_rsp_tr_id_o        = frontend_dtlb_rsp_tr_id;
    assign test_dtlb_rsp_pa_o           = frontend_dtlb_rsp_pa;
    assign test_dtlb_rsp_page_fault_o   = frontend_dtlb_rsp_page_fault;
    assign test_dtlb_rsp_access_fault_o = frontend_dtlb_rsp_access_fault;
    assign ptw_dtlb_grants_since_itlb_o = core_diag_grants_since_itlb;

    // Frontend decoded UOPs
    /* verilator lint_off UNUSEDSIGNAL */
    logic         fe_uop0_valid;
    logic         fe_uop1_valid;
    uop_decoded_t fe_uop0;
    ghr_t         fe_uop0_pre_ghr;
    ras_chkpt_t   fe_uop0_ras_chkpt;
    uop_decoded_t fe_uop1;
    ghr_t         fe_uop1_pre_ghr;
    ras_chkpt_t   fe_uop1_ras_chkpt;
    /* verilator lint_on UNUSEDSIGNAL */

    logic         fe_retire_ready;
    logic         fe_dcache_clean_all_req;

    // Substrate Rename MUX
    wire        sub_uop0_valid     = frontend_en_i ? fe_uop0_valid     : uop0_valid_i;
    wire areg_t sub_uop0_rs1       = frontend_en_i ? fe_uop0.rs1       : uop0_rs1_i;
    wire areg_t sub_uop0_rs2       = frontend_en_i ? fe_uop0.rs2       : uop0_rs2_i;
    wire areg_t sub_uop0_rd        = frontend_en_i ? fe_uop0.rd        : uop0_rd_i;
    wire        sub_uop0_is_branch = frontend_en_i ? (fe_uop0.is_branch || fe_uop0.is_jalr) : uop0_is_branch_i;
    wire [63:0] sub_uop0_pc        = frontend_en_i ? fe_uop0.pc        : uop0_pc_i;

    wire        sub_uop1_valid     = frontend_en_i ? fe_uop1_valid     : uop1_valid_i;
    wire areg_t sub_uop1_rs1       = frontend_en_i ? fe_uop1.rs1       : uop1_rs1_i;
    wire areg_t sub_uop1_rs2       = frontend_en_i ? fe_uop1.rs2       : uop1_rs2_i;
    wire areg_t sub_uop1_rd        = frontend_en_i ? fe_uop1.rd        : uop1_rd_i;
    wire        sub_uop1_is_branch = frontend_en_i ? (fe_uop1.is_branch || fe_uop1.is_jalr) : uop1_is_branch_i;
    wire [63:0] sub_uop1_pc        = frontend_en_i ? fe_uop1.pc        : uop1_pc_i;

    // Backend Dispatch MUX
    wire             be_uop0_valid       = frontend_en_i ? fe_uop0_valid       : uop0_valid_i;
    wire uop_class_t be_uop0_class       = frontend_en_i ? fe_uop0.uop_class   : uop0_class_i;
    wire uop_subop_t be_uop0_subop       = frontend_en_i ? fe_uop0.sub_op      : uop0_subop_i;
    wire [63:0]      be_uop0_imm         = frontend_en_i ? fe_uop0.imm         : uop0_imm_i;
    wire             be_uop0_use_imm     = frontend_en_i ? fe_uop0.use_imm     : uop0_use_imm_i;
    wire [63:0]      be_uop0_pc          = frontend_en_i ? fe_uop0.pc          : uop0_pc_i;
    wire             be_uop0_pred_taken  = frontend_en_i ? fe_uop0.pred_taken  : uop0_pred_taken_i;
    wire [63:0]      be_uop0_pred_target = frontend_en_i ? fe_uop0.pred_target : uop0_pred_target_i;
    wire             be_uop0_is_branch   = frontend_en_i ? fe_uop0.is_branch   : uop0_is_branch_i;
    wire             be_uop0_is_jal      = frontend_en_i ? fe_uop0.is_jal      : uop0_is_jal_i;
    wire             be_uop0_is_jalr     = frontend_en_i ? fe_uop0.is_jalr     : uop0_is_jalr_i;
    wire branch_type_t be_uop0_br_type   = frontend_en_i ? fe_uop0.br_type     : BR_TYPE_COND;
    wire ghr_t         be_uop0_pre_ghr   = frontend_en_i ? fe_uop0.pre_ghr     : '0;
    wire             be_uop0_exception   = frontend_en_i ? fe_uop0.exception   : 1'b0;
    wire [4:0]       be_uop0_exc_cause   = frontend_en_i ? fe_uop0.exc_cause   : 5'd0;

    wire             be_uop1_valid       = frontend_en_i ? fe_uop1_valid       : uop1_valid_i;
    wire uop_class_t be_uop1_class       = frontend_en_i ? fe_uop1.uop_class   : uop1_class_i;
    wire uop_subop_t be_uop1_subop       = frontend_en_i ? fe_uop1.sub_op      : uop1_subop_i;
    wire [63:0]      be_uop1_imm         = frontend_en_i ? fe_uop1.imm         : uop1_imm_i;
    wire             be_uop1_use_imm     = frontend_en_i ? fe_uop1.use_imm     : uop1_use_imm_i;
    wire [63:0]      be_uop1_pc          = frontend_en_i ? fe_uop1.pc          : uop1_pc_i;
    wire             be_uop1_pred_taken  = frontend_en_i ? fe_uop1.pred_taken  : uop1_pred_taken_i;
    wire [63:0]      be_uop1_pred_target = frontend_en_i ? fe_uop1.pred_target : uop1_pred_target_i;
    wire             be_uop1_is_branch   = frontend_en_i ? fe_uop1.is_branch   : uop1_is_branch_i;
    wire             be_uop1_is_jal      = frontend_en_i ? fe_uop1.is_jal      : uop1_is_jal_i;
    wire             be_uop1_is_jalr     = frontend_en_i ? fe_uop1.is_jalr     : uop1_is_jalr_i;
    wire branch_type_t be_uop1_br_type   = frontend_en_i ? fe_uop1.br_type     : BR_TYPE_COND;
    wire ghr_t         be_uop1_pre_ghr   = frontend_en_i ? fe_uop1.pre_ghr     : '0;
    wire             be_uop1_exception   = frontend_en_i ? fe_uop1.exception   : 1'b0;
    wire [4:0]       be_uop1_exc_cause   = frontend_en_i ? fe_uop1.exc_cause   : 5'd0;

    // FENCE.I detection at allocation
    wire alloc0_is_fence_i = sub_uop0_ack && frontend_en_i && (fe_uop0.sub_op == MEM_FENCE_I);
    wire alloc1_is_fence_i = sub_uop1_ack && frontend_en_i && (fe_uop1.sub_op == MEM_FENCE_I);

    // DTLB / PTW Multiplexing
    always_comb begin
        if (frontend_en_i) begin
            backend_ptw_req_ready        = frontend_dtlb_req_ready;
            backend_ptw_rsp_valid        = frontend_dtlb_rsp_valid;
            backend_ptw_rsp_tr_id        = frontend_dtlb_rsp_tr_id;
            backend_ptw_rsp_pa           = frontend_dtlb_rsp_pa;
            backend_ptw_rsp_page_fault   = frontend_dtlb_rsp_page_fault;
            backend_ptw_rsp_access_fault = frontend_dtlb_rsp_access_fault;

            ptw_req_valid_o              = 1'b0;
            ptw_req_tr_id_o              = 2'd0;
            ptw_req_vpn_o                = 27'd0;
            ptw_req_access_type_o        = 2'd0;
        end else begin
            ptw_req_valid_o              = backend_ptw_req_valid;
            ptw_req_tr_id_o              = backend_ptw_req_tr_id;
            ptw_req_vpn_o                = backend_ptw_req_vpn;
            ptw_req_access_type_o        = backend_ptw_req_access_type;

            backend_ptw_req_ready        = ptw_req_ready_i;
            backend_ptw_rsp_valid        = ptw_rsp_valid_i;
            backend_ptw_rsp_tr_id        = ptw_rsp_tr_id_i;
            backend_ptw_rsp_pa           = ptw_rsp_pa_i;
            backend_ptw_rsp_page_fault   = ptw_rsp_page_fault_i;
            backend_ptw_rsp_access_fault = ptw_rsp_access_fault_i;
        end
    end

    assign backend_dcache_clean_all_req = frontend_en_i ? fe_dcache_clean_all_req : 1'b0;

    // =========================================================================
    // 1. Milestone 1 Architectural Substrate
    // =========================================================================
    fursoy_s1_substrate #(
        .PRF_COUNT   (PRF_COUNT),
        .AREG_NUM    (AREG_NUM),
        .ROB_NUM     (ROB_NUM),
        .CHKPT_NUM   (CHKPT_NUM)
    ) u_substrate (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),

        // Rename input
        .uop0_valid_i            (sub_uop0_valid),
        .uop0_rs1_i              (sub_uop0_rs1),
        .uop0_rs2_i              (sub_uop0_rs2),
        .uop0_rd_i               (sub_uop0_rd),
        .uop0_is_branch_i        (sub_uop0_is_branch),
        .uop0_pc_i               (sub_uop0_pc),

        .uop1_valid_i            (sub_uop1_valid),
        .uop1_rs1_i              (sub_uop1_rs1),
        .uop1_rs2_i              (sub_uop1_rs2),
        .uop1_rd_i               (sub_uop1_rd),
        .uop1_is_branch_i        (sub_uop1_is_branch),
        .uop1_pc_i               (sub_uop1_pc),

        .dispatch_ready_i        (int_dispatch_ready),
        .rename_ack_o            (int_rename_ack),

        .uop0_renamed_o          (sub_uop0_renamed),
        .uop1_renamed_o          (sub_uop1_renamed),

        .uop0_ack_o              (sub_uop0_ack),
        .uop0_pnew_o             (sub_uop0_pnew),
        .uop0_pold_o             (sub_uop0_pold),
        .uop0_rs1_preg_o         (sub_uop0_rs1_preg),
        .uop0_rs1_ready_o        (sub_uop0_rs1_ready),
        .uop0_rs2_preg_o         (sub_uop0_rs2_preg),
        .uop0_rs2_ready_o        (sub_uop0_rs2_ready),
        .uop0_rob_idx_o          (sub_uop0_rob_idx),
        .uop0_rob_epoch_o        (sub_uop0_rob_epoch),
        .uop0_chkpt_id_o         (sub_uop0_chkpt_id),

        .uop1_ack_o              (sub_uop1_ack),
        .uop1_pnew_o             (sub_uop1_pnew),
        .uop1_pold_o             (sub_uop1_pold),
        .uop1_rs1_preg_o         (sub_uop1_rs1_preg),
        .uop1_rs1_ready_o        (sub_uop1_rs1_ready),
        .uop1_rs2_preg_o         (sub_uop1_rs2_preg),
        .uop1_rs2_ready_o        (sub_uop1_rs2_ready),
        .uop1_rob_idx_o          (sub_uop1_rob_idx),
        .uop1_rob_epoch_o        (sub_uop1_rob_epoch),
        .uop1_chkpt_id_o         (sub_uop1_chkpt_id),

        // Writeback / Completion
        .comp_valid_i            (int_comp_valid),
        .comp_rob_idx_i          (int_comp_rob_idx),
        .comp_epoch_i            (int_comp_epoch),
        .comp_preg_i             (int_comp_preg),
        .comp_branch_mispred_i   (int_comp_branch_mispred),
        .comp_exception_i        (int_comp_exception),
        .comp_cause_i            (int_comp_cause),
        .comp_ack_o              (int_comp_ack),

        // Branch recovery
        .recover_valid_i         (int_recover_valid),
        .recover_rob_idx_i       (int_recover_rob_idx),
        .recover_chkpt_id_i      (int_recover_chkpt_id),

        // Flush
        .flush_valid_i           (core_flush_valid),

        // Retirement (Serialization controller gates retire_ready_i when FENCE.I is at head)
        .retire_ready_i          (frontend_en_i ? (retire_ready_i && fe_retire_ready) : retire_ready_i),
        .retire_valid_o          (retire_valid_o),
        .retire_rd_o             (retire_rd_o),
        .retire_pnew_o           (retire_pnew_o),
        .retire_pold_o           (retire_pold_o),
        .retire_is_branch_o      (retire_is_branch_o),
        .retire_chkpt_id_o       (retire_chkpt_id_o),
        .retire_pc_o             (retire_pc_o),
        .retire_rob_idx_o        (int_retire_rob_idx),
        .retire_epoch_o          (int_retire_epoch),

        .retire_exception_o      (retire_exception_o),
        .retire_exc_cause_o      (retire_exc_cause_o),
        .retire_exc_pc_o         (retire_exc_pc_o),

        // Diagnostics
        .recovering_o            (int_recovering),
        .reconstructing_o        (int_reconstructing),
        .rob_head_o              (int_rob_head),
        .rob_tail_o              (rob_tail_o),
        .freelist_count_o        (freelist_count_o),
        .rob_count_o             (rob_count_o),
        .chkpt_free_count_o      (chkpt_free_count_o),
        .arat_map_o              (arat_map_o),
        .srat_map_o              (srat_map_o),
        .prf_ready_o             (prf_ready_o),
        .diag_head_valid_o       (diag_head_valid_o),
        .diag_head_completed_o   (diag_head_completed_o),
        .diag_head_exception_o   (diag_head_exception_o),
        .diag_head_rd_o          (diag_head_rd_o),
        .diag_head_pnew_o        (diag_head_pnew_o),
        .diag_head_is_branch_o   (diag_head_is_branch_o)
    );

    // =========================================================================
    // 2. Milestone 2 & 3 Execution Backend
    // =========================================================================
    fursoy_s1_backend u_backend (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),
        .frontend_en_i           (frontend_en_i),

        // Handshake
        .flush_valid_i           (core_flush_valid),
        .fl_reconstructing_i     (int_reconstructing),
        .recovering_i            (int_recovering),
        .rob_head_i              (int_rob_head),

        .recover_valid_o         (int_recover_valid),
        .recover_rob_idx_o       (int_recover_rob_idx),
        .recover_chkpt_id_o      (int_recover_chkpt_id),
        .recover_target_o        (int_recover_target),
        .recover_actual_taken_o  (int_recover_actual_taken),

        // Dispatch
        .dispatch_ready_o        (int_dispatch_ready),
        .rename_ack_i            (int_rename_ack),

        // Uop 0 Payload
        .uop0_valid_i            (be_uop0_valid),
        .uop0_class_i            (be_uop0_class),
        .uop0_subop_i            (be_uop0_subop),
        .uop0_imm_i              (be_uop0_imm),
        .uop0_use_imm_i          (be_uop0_use_imm),
        .uop0_prs1_i             (sub_uop0_rs1_preg),
        .uop0_prs1_ready_i       (sub_uop0_rs1_ready),
        .uop0_prs2_i             (sub_uop0_rs2_preg),
        .uop0_prs2_ready_i       (sub_uop0_rs2_ready),
        .uop0_pnew_i             (sub_uop0_pnew),
        .uop0_rob_idx_i          (sub_uop0_rob_idx),
        .uop0_rob_epoch_i        (sub_uop0_rob_epoch),
        .uop0_chkpt_id_i         (sub_uop0_chkpt_id),
        .uop0_pc_i               (be_uop0_pc),
        .uop0_pred_taken_i       (be_uop0_pred_taken),
        .uop0_pred_target_i      (be_uop0_pred_target),
        .uop0_is_branch_i        (be_uop0_is_branch),
        .uop0_is_jal_i           (be_uop0_is_jal),
        .uop0_is_jalr_i          (be_uop0_is_jalr),
        .uop0_br_type_i          (be_uop0_br_type),
        .uop0_pre_ghr_i          (be_uop0_pre_ghr),
        .uop0_exception_i        (be_uop0_exception),
        .uop0_exc_cause_i        (be_uop0_exc_cause),

        // Uop 1 Payload
        .uop1_valid_i            (be_uop1_valid),
        .uop1_class_i            (be_uop1_class),
        .uop1_subop_i            (be_uop1_subop),
        .uop1_imm_i              (be_uop1_imm),
        .uop1_use_imm_i          (be_uop1_use_imm),
        .uop1_prs1_i             (sub_uop1_rs1_preg),
        .uop1_prs1_ready_i       (sub_uop1_rs1_ready),
        .uop1_prs2_i             (sub_uop1_rs2_preg),
        .uop1_prs2_ready_i       (sub_uop1_rs2_ready),
        .uop1_pnew_i             (sub_uop1_pnew),
        .uop1_rob_idx_i          (sub_uop1_rob_idx),
        .uop1_rob_epoch_i        (sub_uop1_rob_epoch),
        .uop1_chkpt_id_i         (sub_uop1_chkpt_id),
        .uop1_pc_i               (be_uop1_pc),
        .uop1_pred_taken_i       (be_uop1_pred_taken),
        .uop1_pred_target_i      (be_uop1_pred_target),
        .uop1_is_branch_i        (be_uop1_is_branch),
        .uop1_is_jal_i           (be_uop1_is_jal),
        .uop1_is_jalr_i          (be_uop1_is_jalr),
        .uop1_br_type_i          (be_uop1_br_type),
        .uop1_pre_ghr_i          (be_uop1_pre_ghr),
        .uop1_exception_i        (be_uop1_exception),
        .uop1_exc_cause_i        (be_uop1_exc_cause),

        // Completion
        .comp_valid_o            (int_comp_valid),
        .comp_rob_idx_o          (int_comp_rob_idx),
        .comp_epoch_o            (int_comp_epoch),
        .comp_preg_o             (int_comp_preg),
        .comp_branch_mispred_o   (int_comp_branch_mispred),
        .comp_exception_o        (int_comp_exception),
        .comp_cause_o            (int_comp_cause),
        .comp_ack_i              (int_comp_ack),

        // Probe
        .probe_paddr_i           (probe_paddr_i),
        .probe_pdata_o           (probe_pdata_o),

        // Diagnostics
        .diag_valid_mask_o       (diag_valid_mask_o),
        .diag_ready_p0_o         (diag_ready_p0_o),
        .diag_ready_p1_o         (diag_ready_p1_o),
        .diag_prs1_rdy_o         (diag_prs1_rdy_o),
        .diag_prs2_rdy_o         (diag_prs2_rdy_o),
        .diag_rob_idx_o          (diag_rob_idx_o),

        // Testbench Injection Port
        .test_inject_valid_i     (test_inject_valid_i),
        .test_inject_data_i      (test_inject_data_i),
        .test_inject_pnew_i      (test_inject_pnew_i),
        .test_inject_rob_idx_i   (test_inject_rob_idx_i),
        .test_inject_rob_epoch_i (test_inject_rob_epoch_i),
        .test_inject_mispredict_i(test_inject_mispredict_i),

        // In-Order Store Retirement Handshake at ROB Head
        .retire_valid_i          (retire_valid_o),
        .retire_pnew_i           (retire_pnew_o),
        .retire_pc_i             (retire_pc_o),
        .retire_rob_idx_i        (int_retire_rob_idx),
        .retire_epoch_i          (int_retire_epoch),

        // External Memory Interconnect & Translation Interface (M3)
        .bus_rd_req_valid_o      (bus_rd_req_valid_o),
        .bus_rd_req_addr_o       (bus_rd_req_addr_o),
        .bus_rd_req_tag_o        (bus_rd_req_tag_o),
        .bus_rd_req_ready_i      (bus_rd_req_ready_i),
        .bus_rd_rsp_valid_i      (bus_rd_rsp_valid_i),
        .bus_rd_rsp_tag_i        (bus_rd_rsp_tag_i),
        .bus_rd_rsp_data_i       (bus_rd_rsp_data_i),

        .bus_wr_req_valid_o      (bus_wr_req_valid_o),
        .bus_wr_req_addr_o       (bus_wr_req_addr_o),
        .bus_wr_req_data_o       (bus_wr_req_data_o),
        .bus_wr_req_ready_i      (bus_wr_req_ready_i),
        .bus_wr_rsp_valid_i      (bus_wr_rsp_valid_i),

        .ptw_req_valid_o         (backend_ptw_req_valid),
        .ptw_req_tr_id_o         (backend_ptw_req_tr_id),
        .ptw_req_vpn_o           (backend_ptw_req_vpn),
        .ptw_req_access_type_o   (backend_ptw_req_access_type),
        .ptw_req_ready_i         (backend_ptw_req_ready),
        .ptw_rsp_valid_i         (backend_ptw_rsp_valid),
        .ptw_rsp_tr_id_i         (backend_ptw_rsp_tr_id),
        .ptw_rsp_pa_i            (backend_ptw_rsp_pa),
        .ptw_rsp_page_fault_i    (backend_ptw_rsp_page_fault),
        .ptw_rsp_access_fault_i  (backend_ptw_rsp_access_fault),

        // L1D Maintenance & Serialization
        .dcache_clean_all_req_i  (backend_dcache_clean_all_req),
        .dcache_clean_all_done_o (backend_dcache_clean_all_done),
        .sq_empty_o              (backend_sq_empty),

        // Predictor Training Output
        .train_valid_o           (int_train_valid),
        .train_pc_o              (int_train_pc),
        .train_actual_taken_o    (int_train_actual_taken),
        .train_actual_target_o   (int_train_actual_target),
        .train_br_type_o         (int_train_br_type),
        .train_ghr_o             (int_train_ghr),

        // Privileged SYSTEM / CSR Execution Interface (Port 0)
        .p0_sys_valid_o          (backend_p0_sys_valid),
        .p0_sys_subop_o          (backend_p0_sys_subop),
        .p0_sys_csr_addr_o       (backend_p0_sys_csr_addr),
        .p0_sys_rs1_field_o      (backend_p0_sys_rs1_field),
        .p0_sys_rs1_val_o        (backend_p0_sys_rs1_val),
        .p0_sys_rs2_val_o        (backend_p0_sys_rs2_val),
        .p0_sys_pc_o             (backend_p0_sys_pc),
        .p0_sys_rob_idx_o        (backend_p0_sys_rob_idx),
        .p0_sys_rdata_i          (backend_p0_sys_rdata),
        .p0_sys_illegal_i        (backend_p0_sys_illegal)
    );

    // =========================================================================
    // 3. Privileged CSR & System Execution Subsystem
    // =========================================================================
    fursoy_s1_csr #(
        .RESET_MTVEC             (64'h0000_0000_8000_0000),
        .RESET_STVEC             (64'h0000_0000_8000_0000)
    ) u_csr (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),
        .priv_mode_i             (priv_mode_i),
        .mstatus_i               (mstatus_i),

        // Execution Interface (Port 0)
        .p0_sys_valid_i          (backend_p0_sys_valid),
        .p0_sys_subop_i          (backend_p0_sys_subop),
        .p0_sys_csr_addr_i       (backend_p0_sys_csr_addr),
        .p0_sys_rs1_field_i      (backend_p0_sys_rs1_field),
        .p0_sys_rs1_val_i        (backend_p0_sys_rs1_val),
        .p0_sys_rs2_val_i        (backend_p0_sys_rs2_val),
        .p0_sys_pc_i             (backend_p0_sys_pc),
        .p0_sys_rob_idx_i        (backend_p0_sys_rob_idx),

        .p0_sys_rdata_o          (backend_p0_sys_rdata),
        .p0_sys_illegal_o        (backend_p0_sys_illegal),

        // Retirement Interface
        .retire_valid_i          (retire_valid_o),
        .retire_rob_idx_i        (int_retire_rob_idx),
        .retire_pc_i             (retire_pc_o),
        .retire_exception_i      (retire_exception_o),
        .retire_exc_cause_i      (retire_exc_cause_o),
        .retire_exc_pc_i         (retire_exc_pc_o),

        // Architectural State Outputs
        .priv_mode_o             (csr_priv_mode),
        .mstatus_o               (csr_mstatus),
        .satp_o                  (csr_satp),

        // Redirect & Flush Outputs
        .sys_redirect_valid_o    (csr_redirect_valid),
        .sys_redirect_target_o   (csr_redirect_target),
        .sys_flush_valid_o       (csr_flush_valid),

        // SFENCE.VMA
        .sfence_vma_valid_o      (csr_sfence_vma_valid),
        .sfence_vma_va_o         (csr_sfence_vma_va),
        .sfence_vma_asid_o       (csr_sfence_vma_asid),

        // Observability
        .csr_mepc_o              (csr_mepc_o),
        .csr_mcause_o            (csr_mcause_o),
        .csr_mtval_o             (csr_mtval_o),
        .csr_sepc_o              (csr_sepc_o),
        .csr_scause_o            (csr_scause_o),
        .csr_stval_o             (csr_stval_o),
        .csr_mtvec_o             (csr_mtvec_o),
        .csr_stvec_o             (csr_stvec_o)
    );

    logic              int_train_valid;
    logic [63:0]       int_train_pc;
    logic              int_train_actual_taken;
    logic [63:0]       int_train_actual_target;
    branch_type_t      int_train_br_type;
    ghr_t              int_train_ghr;

    // =========================================================================
    // 3. Milestone 4 Complete Frontend Subsystem
    // =========================================================================
    fursoy_s1_frontend #(
        .RESET_PC                (64'h0000_0000_8000_0000)
    ) u_frontend (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),
        .frontend_en_i           (frontend_en_i),

        // Architectural System State & Privilege Mode
        .priv_mode_i             (eff_priv_mode),
        .mstatus_i               (eff_mstatus),
        .satp_i                  (eff_satp),
        .pmp_allow_i             (pmp_allow_i),

        // Redirects
        .trap_valid_i            (eff_trap_valid),
        .trap_target_i           (eff_trap_target),
        .mret_valid_i            (eff_mret_valid),
        .mret_target_i           (eff_mret_target),

        .recover_valid_i         (int_recover_valid),
        .recover_chkpt_id_i      (int_recover_chkpt_id),
        .recover_actual_taken_i  (int_recover_actual_taken),
        .recover_target_i        (int_recover_target),
        .flush_valid_i           (core_flush_valid),

        // SFENCE.VMA
        .sfence_vma_valid_i      (eff_sfence_valid),
        .sfence_vma_va_i         (eff_sfence_va),
        .sfence_vma_asid_i       (eff_sfence_asid),

        // Checkpoint capture at Rename
        .chkpt_alloc_valid0_i    (sub_uop0_ack && frontend_en_i && (fe_uop0.is_branch || fe_uop0.is_jalr)),
        .chkpt_alloc_id0_i       (sub_uop0_chkpt_id),
        .chkpt_alloc_ghr0_i      (fe_uop0_pre_ghr),
        .chkpt_alloc_ras0_i      (fe_uop0_ras_chkpt),

        .chkpt_alloc_valid1_i    (sub_uop1_ack && frontend_en_i && (fe_uop1.is_branch || fe_uop1.is_jalr)),
        .chkpt_alloc_id1_i       (sub_uop1_chkpt_id),
        .chkpt_alloc_ghr1_i      (fe_uop1_pre_ghr),
        .chkpt_alloc_ras1_i      (fe_uop1_ras_chkpt),

        // Predictor training from resolved branches
        .train_valid_i           (int_train_valid),
        .train_pc_i              (int_train_pc),
        .train_actual_taken_i    (int_train_actual_taken),
        .train_actual_target_i   (int_train_actual_target),
        .train_br_type_i         (int_train_br_type),
        .train_ghr_i             (int_train_ghr),

        // Decoded Micro-ops Handoff to Rename / Dispatch
        .uop0_valid_o            (fe_uop0_valid),
        .uop0_o                  (fe_uop0),
        .uop0_pre_ghr_o          (fe_uop0_pre_ghr),
        .uop0_ras_chkpt_o        (fe_uop0_ras_chkpt),

        .uop1_valid_o            (fe_uop1_valid),
        .uop1_o                  (fe_uop1),
        .uop1_pre_ghr_o          (fe_uop1_pre_ghr),
        .uop1_ras_chkpt_o        (fe_uop1_ras_chkpt),

        .rename_ack_i            (int_rename_ack),

        // System Serialization Controller (FENCE.I)
        .rob_head_i              (int_rob_head),
        .retire_epoch_i          (int_retire_epoch[0]),
        .rob_retire_valid_i      (retire_valid_o[0]),
        .retire_ready_o          (fe_retire_ready),

        .sq_empty_i              (backend_sq_empty),
        .dcache_clean_all_req_o  (fe_dcache_clean_all_req),
        .dcache_clean_all_done_i (backend_dcache_clean_all_done),

        .alloc0_fence_i_i        (alloc0_is_fence_i),
        .alloc0_rob_idx_i        (sub_uop0_rob_idx),
        .alloc0_rob_epoch_i      (sub_uop0_rob_epoch),
        .alloc0_pc_i             (fe_uop0.pc),

        .alloc1_fence_i_i        (alloc1_is_fence_i),
        .alloc1_rob_idx_i        (sub_uop1_rob_idx),
        .alloc1_rob_epoch_i      (sub_uop1_rob_epoch),
        .alloc1_pc_i             (fe_uop1.pc),

        // L1I Memory Refill Bus
        .l1i_bus_rd_req_valid_o  (l1i_bus_rd_req_valid_o),
        .l1i_bus_rd_req_addr_o   (l1i_bus_rd_req_addr_o),
        .l1i_bus_rd_req_tag_o    (l1i_bus_rd_req_tag_o),
        .l1i_bus_rd_req_ready_i  (l1i_bus_rd_req_ready_i),

        .l1i_bus_rd_rsp_valid_i  (l1i_bus_rd_rsp_valid_i),
        .l1i_bus_rd_rsp_tag_i    (l1i_bus_rd_rsp_tag_i),
        .l1i_bus_rd_rsp_data_i   (l1i_bus_rd_rsp_data_i),
        .l1i_bus_rd_rsp_error_i  (l1i_bus_rd_rsp_error_i),

        // Shared PTW Memory Read Bus
        .ptw_mem_req_valid_o     (ptw_mem_req_valid_o),
        .ptw_mem_req_addr_o      (ptw_mem_req_addr_o),
        .ptw_mem_req_ready_i     (ptw_mem_req_ready_i),

        .ptw_mem_rsp_valid_i     (ptw_mem_rsp_valid_i),
        .ptw_mem_rsp_data_i      (ptw_mem_rsp_data_i),
        .ptw_mem_rsp_error_i     (ptw_mem_rsp_error_i),

        // M3 DTLB Request / Response to Shared PTW
        .dtlb_req_valid_i        (ptw_dtlb_req_valid_w),
        .dtlb_req_tr_id_i        (ptw_dtlb_req_tr_id_w),
        .dtlb_req_vpn_i          (ptw_dtlb_req_vpn_w),
        .dtlb_req_is_store_i     (ptw_dtlb_req_is_store_w),
        .dtlb_req_is_amo_i       (ptw_dtlb_req_is_amo_w),
        .dtlb_req_ready_o        (frontend_dtlb_req_ready),

        .dtlb_rsp_valid_o        (frontend_dtlb_rsp_valid),
        .dtlb_rsp_tr_id_o        (frontend_dtlb_rsp_tr_id),
        .dtlb_rsp_pa_o           (frontend_dtlb_rsp_pa),
        .dtlb_rsp_page_fault_o   (frontend_dtlb_rsp_page_fault),
        .dtlb_rsp_access_fault_o (frontend_dtlb_rsp_access_fault),

        // Diagnostics & Instrumentation
        .fetch_queue_count_o     (fe_fetch_queue_count_o),
        .fetch_queue_full_o      (fe_fetch_queue_full_o),
        .fetch_queue_empty_o     (fe_fetch_queue_empty_o),

        .hpm_fetch_words_o       (hpm_fetch_words_o),
        .hpm_fetch_uops_o        (hpm_fetch_uops_o),
        .hpm_fetch_empty_cyc_o   (hpm_fetch_empty_cyc_o),
        .hpm_fetch_full_cyc_o    (hpm_fetch_full_cyc_o),
        .hpm_l1i_hits_o          (hpm_l1i_hits_o),
        .hpm_l1i_misses_o        (hpm_l1i_misses_o),
        .hpm_itlb_hits_o         (hpm_itlb_hits_o),
        .hpm_itlb_misses_o       (hpm_itlb_misses_o),
        .hpm_btb_hits_o          (hpm_btb_hits_o),
        .hpm_btb_misses_o        (hpm_btb_misses_o),
        .hpm_bpu_cond_pred_o     (hpm_bpu_cond_pred_o),
        .hpm_ras_calls_o         (hpm_ras_calls_o),
        .hpm_ras_returns_o       (hpm_ras_returns_o),
        .hpm_fence_i_flushes_o   (hpm_fence_i_flushes_o),
        .hpm_redirect_cyc_o      (hpm_redirect_cyc_o),
        .diag_grants_since_itlb_o(core_diag_grants_since_itlb)
    );

endmodule

`endif // FURSOY_S1_CORE_SV
