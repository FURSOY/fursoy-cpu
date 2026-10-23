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
`include "fursoy_s1_hpm.sv"

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
    // Milestone 8 Phase A FP Renaming Inputs
    input  logic                   uop0_is_fp_i,
    input  logic                   uop0_fp_dest_valid_i,
    input  fareg_t                 uop0_fs3_i,
    input  logic [2:0]             uop0_frm_i,

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
    // Milestone 8 Phase A FP Renaming Inputs
    input  logic                   uop1_is_fp_i,
    input  logic                   uop1_fp_dest_valid_i,
    input  fareg_t                 uop1_fs3_i,
    input  logic [2:0]             uop1_frm_i,

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
    output logic [4:0]             comp_valid_o,
    output rob_idx_t               comp_rob_idx_o       [4:0],
    output rob_epoch_t             comp_epoch_o         [4:0],
    output preg_t                  comp_preg_o          [4:0],
    output logic [4:0]             comp_ack_o,
    output logic [4:0]             comp_fflags_o        [4:0],

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

    // Milestone 8 Phase A Floating-Point Direct Test Injection & Observability
    input  logic [2:0]             comp_fp_wb_valid_i,
    input  fpreg_t                 comp_fp_wb_preg_i     [2:0],
    input  logic [4:0]             comp_fflags_i         [4:0],

    input  logic                   test_fp_w0_valid_i,
    input  fpreg_t                 test_fp_w0_paddr_i,
    input  logic [63:0]            test_fp_w0_data_i,

    input  logic                   test_fp_w1_valid_i,
    input  fpreg_t                 test_fp_w1_paddr_i,
    input  logic [63:0]            test_fp_w1_data_i,

    input  logic                   test_fp_w2_valid_i,
    input  fpreg_t                 test_fp_w2_paddr_i,
    input  logic [63:0]            test_fp_w2_data_i,

    // Direct Read Probe Port into FPRF Data Storage
    input  fpreg_t                 probe_fp_paddr_i,
    output logic [63:0]            probe_fp_pdata_o,

    // Milestone 8 Phase A FP Renamed Discrete Outputs
    output fpreg_t                 uop0_prd_fp_o,
    output fpreg_t                 uop0_pold_fp_o,
    output fpreg_t                 uop0_prs1_fp_o,
    output logic                   uop0_prs1_fp_ready_o,
    output fpreg_t                 uop0_prs2_fp_o,
    output logic                   uop0_prs2_fp_ready_o,
    output fpreg_t                 uop0_prs3_fp_o,
    output logic                   uop0_prs3_fp_ready_o,

    output fpreg_t                 uop1_prd_fp_o,
    output fpreg_t                 uop1_pold_fp_o,
    output fpreg_t                 uop1_prs1_fp_o,
    output logic                   uop1_prs1_fp_ready_o,
    output fpreg_t                 uop1_prs2_fp_o,
    output logic                   uop1_prs2_fp_ready_o,
    output fpreg_t                 uop1_prs3_fp_o,
    output logic                   uop1_prs3_fp_ready_o,

    // Milestone 8 Phase A FP Retirement Outputs
    output logic [1:0]             retire_is_fp_o,
    output logic [1:0]             retire_fp_dest_valid_o,
    output fpreg_t                 retire_prd_fp_o       [1:0],
    output fpreg_t                 retire_pold_fp_o      [1:0],
    output logic [4:0]             retire_fflags_o       [1:0],

    // Milestone 8 Phase A FP Free List & Status Observability
    output logic [FL_FP_CNT_W-1:0] fl_fp_count_o,
    output logic [1:0]             fl_fp_ready_o,
    output logic                   fl_fp_reconstructing_o,
    output fpreg_t                 arat_fp_map_o         [FAREG_COUNT],
    output fpreg_t                 srat_fp_map_o         [FAREG_COUNT],
    output logic [FPRF_SIZE-1:0]   prf_fp_ready_o,
    output logic [1:0]             mstatus_fs_o,
    output logic [2:0]             fcsr_frm_o,
    output logic [4:0]             fcsr_fflags_o,

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
    output logic [4:0]             fe_fetch_queue_count_o,
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

    output logic [2:0]             ptw_dtlb_grants_since_itlb_o,

    // -------------------------------------------------------------------------
    // External Coherent Caching-Agent Snoop Interface (Milestone 7 Section 8)
    // -------------------------------------------------------------------------
    input  logic                   snoop_req_valid_i,
    input  logic [55:0]            snoop_req_addr_i,
    input  logic [1:0]             snoop_req_type_i,
    output logic                   snoop_rsp_valid_o,
    output logic                   snoop_rsp_has_data_o,
    output logic                   snoop_rsp_was_dirty_o,
    output logic [511:0]           snoop_rsp_data_o,

    // -------------------------------------------------------------------------
    // Milestone 5 Hardware Performance Monitoring (HPM) & Profiling
    // -------------------------------------------------------------------------
    output logic [63:0]            mcycle_o,
    output logic [63:0]            minstret_o,
    output logic [63:0]            mhpmcounter_o         [32],
    output logic [63:0]            cpi_category_o        [8],
    output logic [7:0]             cpi_active_owner_o,
    output logic [56:1]            raw_event_pulse_o
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
    logic [4:0]     int_comp_valid;
    rob_idx_t       int_comp_rob_idx       [4:0];
    rob_epoch_t     int_comp_epoch         [4:0];
    preg_t          int_comp_preg          [4:0];
    logic [4:0]     int_comp_branch_mispred;
    logic [4:0]     int_comp_exception;
    logic [4:0]     int_comp_cause         [4:0];
    logic [4:0]     int_comp_fflags        [4:0];
    logic [4:0]     int_comp_ack;
    logic [4:0]     be_comp_fflags         [4:0];
    logic [2:0]     be_comp_fp_wb_valid;
    fpreg_t         be_comp_fp_wb_preg     [2:0];

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
    rob_idx_t       int_rob_head_next;

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
    assign comp_fflags_o      = int_comp_fflags;

    for (genvar gi = 0; gi < 5; gi++) begin : gen_comp_fflags
        assign int_comp_fflags[gi] = be_comp_fflags[gi] | comp_fflags_i[gi];
    end

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

    // Milestone 5 Phase B1: Speculative Disambiguation Interconnect Signals
    logic        retire_replay;
    logic [63:0] retire_replay_pc;
    logic        lsu_violation_valid;
    rob_idx_t    lsu_violation_rob_idx;
    rob_epoch_t  lsu_violation_rob_epoch;
    logic        lsu_retire0_allow;
    logic        lsu_retire1_allow;
    logic        be_event_load_speculative;

    wire        core_flush_valid = flush_valid_i || csr_flush_valid || retire_replay;

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
    ghr_t             fe_uop0_pre_ghr;
    ras_chkpt_t       fe_uop0_ras_chkpt;
    tage_csr_bundle_t fe_uop0_csr_chkpt;
    uop_decoded_t     fe_uop1;
    ghr_t             fe_uop1_pre_ghr;
    ras_chkpt_t       fe_uop1_ras_chkpt;
    tage_csr_bundle_t fe_uop1_csr_chkpt;
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
    wire        sub_uop0_is_fp         = frontend_en_i ? 1'b0 : uop0_is_fp_i;
    wire        sub_uop0_fp_dest_valid = frontend_en_i ? 1'b0 : uop0_fp_dest_valid_i;
    wire fareg_t sub_uop0_fs3          = frontend_en_i ? 5'd0 : uop0_fs3_i;

    wire        sub_uop1_valid     = frontend_en_i ? fe_uop1_valid     : uop1_valid_i;
    wire areg_t sub_uop1_rs1       = frontend_en_i ? fe_uop1.rs1       : uop1_rs1_i;
    wire areg_t sub_uop1_rs2       = frontend_en_i ? fe_uop1.rs2       : uop1_rs2_i;
    wire areg_t sub_uop1_rd        = frontend_en_i ? fe_uop1.rd        : uop1_rd_i;
    wire        sub_uop1_is_branch = frontend_en_i ? (fe_uop1.is_branch || fe_uop1.is_jalr) : uop1_is_branch_i;
    wire [63:0] sub_uop1_pc        = frontend_en_i ? fe_uop1.pc        : uop1_pc_i;
    wire        sub_uop1_is_fp         = frontend_en_i ? 1'b0 : uop1_is_fp_i;
    wire        sub_uop1_fp_dest_valid = frontend_en_i ? 1'b0 : uop1_fp_dest_valid_i;
    wire fareg_t sub_uop1_fs3          = frontend_en_i ? 5'd0 : uop1_fs3_i;

    // Substrate to CSR / Core FP retirement wires
    logic [1:0] sub_retire_is_fp;
    logic [1:0] sub_retire_fp_dest_valid;
    fpreg_t     sub_retire_prd_fp [1:0];
    fpreg_t     sub_retire_pold_fp [1:0];
    logic [4:0] sub_retire_fflags [1:0];

    assign retire_is_fp_o         = sub_retire_is_fp;
    assign retire_fp_dest_valid_o = sub_retire_fp_dest_valid;
    assign retire_prd_fp_o        = sub_retire_prd_fp;
    assign retire_pold_fp_o       = sub_retire_pold_fp;
    assign retire_fflags_o        = sub_retire_fflags;

    // Combined FP writeback completion bus for substrate
    wire [2:0]   int_comp_fp_wb_valid = be_comp_fp_wb_valid | comp_fp_wb_valid_i | {test_fp_w2_valid_i, test_fp_w1_valid_i, test_fp_w0_valid_i};
    wire fpreg_t int_comp_fp_wb_preg [2:0];
    assign int_comp_fp_wb_preg[0] = be_comp_fp_wb_valid[0] ? be_comp_fp_wb_preg[0] : (comp_fp_wb_valid_i[0] ? comp_fp_wb_preg_i[0] : test_fp_w0_paddr_i);
    assign int_comp_fp_wb_preg[1] = be_comp_fp_wb_valid[1] ? be_comp_fp_wb_preg[1] : (comp_fp_wb_valid_i[1] ? comp_fp_wb_preg_i[1] : test_fp_w1_paddr_i);
    assign int_comp_fp_wb_preg[2] = be_comp_fp_wb_valid[2] ? be_comp_fp_wb_preg[2] : (comp_fp_wb_valid_i[2] ? comp_fp_wb_preg_i[2] : test_fp_w2_paddr_i);

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
    wire             be_uop0_replay_safe = frontend_en_i ? fe_uop0.replay_safe : 1'b0;

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
    wire             be_uop1_replay_safe = frontend_en_i ? fe_uop1.replay_safe : 1'b0;

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
        .uop0_is_fp_i            (sub_uop0_is_fp),
        .uop0_fp_dest_valid_i    (sub_uop0_fp_dest_valid),
        .uop0_fs3_i              (sub_uop0_fs3),
        .uop0_frm_i              (uop0_frm_i),

        .uop1_valid_i            (sub_uop1_valid),
        .uop1_rs1_i              (sub_uop1_rs1),
        .uop1_rs2_i              (sub_uop1_rs2),
        .uop1_rd_i               (sub_uop1_rd),
        .uop1_is_branch_i        (sub_uop1_is_branch),
        .uop1_pc_i               (sub_uop1_pc),
        .uop1_is_fp_i            (sub_uop1_is_fp),
        .uop1_fp_dest_valid_i    (sub_uop1_fp_dest_valid),
        .uop1_fs3_i              (sub_uop1_fs3),
        .uop1_frm_i              (uop1_frm_i),

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

        .uop0_prd_fp_o           (uop0_prd_fp_o),
        .uop0_pold_fp_o          (uop0_pold_fp_o),
        .uop0_prs1_fp_o          (uop0_prs1_fp_o),
        .uop0_prs1_fp_ready_o    (uop0_prs1_fp_ready_o),
        .uop0_prs2_fp_o          (uop0_prs2_fp_o),
        .uop0_prs2_fp_ready_o    (uop0_prs2_fp_ready_o),
        .uop0_prs3_fp_o          (uop0_prs3_fp_o),
        .uop0_prs3_fp_ready_o    (uop0_prs3_fp_ready_o),

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

        .uop1_prd_fp_o           (uop1_prd_fp_o),
        .uop1_pold_fp_o          (uop1_pold_fp_o),
        .uop1_prs1_fp_o          (uop1_prs1_fp_o),
        .uop1_prs1_fp_ready_o    (uop1_prs1_fp_ready_o),
        .uop1_prs2_fp_o          (uop1_prs2_fp_o),
        .uop1_prs2_fp_ready_o    (uop1_prs2_fp_ready_o),
        .uop1_prs3_fp_o          (uop1_prs3_fp_o),
        .uop1_prs3_fp_ready_o    (uop1_prs3_fp_ready_o),

        // Writeback / Completion
        .comp_valid_i            (int_comp_valid),
        .comp_rob_idx_i          (int_comp_rob_idx),
        .comp_epoch_i            (int_comp_epoch),
        .comp_preg_i             (int_comp_preg),
        .comp_branch_mispred_i   (int_comp_branch_mispred),
        .comp_exception_i        (int_comp_exception),
        .comp_cause_i            (int_comp_cause),
        .comp_fflags_i           (int_comp_fflags),
        .comp_ack_o              (int_comp_ack),

        .comp_fp_wb_valid_i      (int_comp_fp_wb_valid),
        .comp_fp_wb_preg_i       (int_comp_fp_wb_preg),

        // Branch recovery
        .recover_valid_i         (int_recover_valid),
        .recover_rob_idx_i       (int_recover_rob_idx),
        .recover_chkpt_id_i      (int_recover_chkpt_id),

        // Flush
        .flush_valid_i           (core_flush_valid),

        // Retirement (Serialization controller gates retire_ready_i when FENCE.I is at head, LSU gates when store check pending)
        .retire_ready_i          (frontend_en_i ? (retire_ready_i && fe_retire_ready) : retire_ready_i),
        .lsu_retire0_allow_i     (lsu_retire0_allow),
        .lsu_retire1_allow_i     (lsu_retire1_allow),

        // Milestone 5 Phase B1 Memory Disambiguation Violation & Replay
        .lsu_violation_valid_i   (lsu_violation_valid),
        .lsu_violation_rob_idx_i (lsu_violation_rob_idx),
        .lsu_violation_rob_epoch_i(lsu_violation_rob_epoch),

        .retire_replay_o         (retire_replay),
        .retire_replay_pc_o      (retire_replay_pc),

        .retire_valid_o          (retire_valid_o),
        .retire_rd_o             (retire_rd_o),
        .retire_pnew_o           (retire_pnew_o),
        .retire_pold_o           (retire_pold_o),
        .retire_is_branch_o      (retire_is_branch_o),
        .retire_chkpt_id_o       (retire_chkpt_id_o),
        .retire_pc_o             (retire_pc_o),
        .retire_rob_idx_o        (int_retire_rob_idx),
        .retire_epoch_o          (int_retire_epoch),

        .retire_is_fp_o          (sub_retire_is_fp),
        .retire_fp_dest_valid_o  (sub_retire_fp_dest_valid),
        .retire_prd_fp_o         (sub_retire_prd_fp),
        .retire_pold_fp_o        (sub_retire_pold_fp),
        .retire_fflags_o         (sub_retire_fflags),

        .retire_exception_o      (retire_exception_o),
        .retire_exc_cause_o      (retire_exc_cause_o),
        .retire_exc_pc_o         (retire_exc_pc_o),

        // Diagnostics
        .recovering_o            (int_recovering),
        .reconstructing_o        (int_reconstructing),
        .rob_head_o              (int_rob_head),
        .rob_head_next_o         (int_rob_head_next),
        .rob_tail_o              (rob_tail_o),
        .freelist_count_o        (freelist_count_o),
        .rob_count_o             (rob_count_o),
        .chkpt_free_count_o      (chkpt_free_count_o),
        .arat_map_o              (arat_map_o),
        .srat_map_o              (srat_map_o),
        .prf_ready_o             (prf_ready_o),

        .fl_fp_count_o           (fl_fp_count_o),
        .fl_fp_ready_o           (fl_fp_ready_o),
        .fl_fp_reconstructing_o (fl_fp_reconstructing_o),
        .arat_fp_map_o           (arat_fp_map_o),
        .srat_fp_map_o           (srat_fp_map_o),
        .prf_fp_ready_o          (prf_fp_ready_o),

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
        .rob_head_next_i         (int_rob_head_next),

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
        .uop0_replay_safe_i      (be_uop0_replay_safe),
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
        .uop0_is_fp_i            (sub_uop0_is_fp),
        .uop0_fp_dest_valid_i    (sub_uop0_fp_dest_valid),
        .uop0_prd_fp_i           (uop0_prd_fp_o),
        .uop0_prs1_fp_i          (uop0_prs1_fp_o),
        .uop0_prs1_fp_ready_i    (uop0_prs1_fp_ready_o),
        .uop0_prs2_fp_i          (uop0_prs2_fp_o),
        .uop0_prs2_fp_ready_i    (uop0_prs2_fp_ready_o),
        .uop0_prs3_fp_i          (uop0_prs3_fp_o),
        .uop0_prs3_fp_ready_i    (uop0_prs3_fp_ready_o),
        .uop0_frm_i              (uop0_frm_i),

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
        .uop1_replay_safe_i      (be_uop1_replay_safe),
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
        .uop1_is_fp_i            (sub_uop1_is_fp),
        .uop1_fp_dest_valid_i    (sub_uop1_fp_dest_valid),
        .uop1_prd_fp_i           (uop1_prd_fp_o),
        .uop1_prs1_fp_i          (uop1_prs1_fp_o),
        .uop1_prs1_fp_ready_i    (uop1_prs1_fp_ready_o),
        .uop1_prs2_fp_i          (uop1_prs2_fp_o),
        .uop1_prs2_fp_ready_i    (uop1_prs2_fp_ready_o),
        .uop1_prs3_fp_i          (uop1_prs3_fp_o),
        .uop1_prs3_fp_ready_i    (uop1_prs3_fp_ready_o),
        .uop1_frm_i              (uop1_frm_i),

        .fcsr_frm_i              (fcsr_frm_o),

        // Completion
        .comp_valid_o            (int_comp_valid),
        .comp_rob_idx_o          (int_comp_rob_idx),
        .comp_epoch_o            (int_comp_epoch),
        .comp_preg_o             (int_comp_preg),
        .comp_branch_mispred_o   (int_comp_branch_mispred),
        .comp_exception_o        (int_comp_exception),
        .comp_cause_o            (int_comp_cause),
        .comp_fflags_o           (be_comp_fflags),
        .comp_ack_i              (int_comp_ack),

        .comp_fp_wb_valid_o      (be_comp_fp_wb_valid),
        .comp_fp_wb_preg_o       (be_comp_fp_wb_preg),

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
        .p0_sys_illegal_i        (backend_p0_sys_illegal),

        // Observability & Telemetry (Milestone 5)
        .event_issue_port0_o     (be_event_issue_p0),
        .event_issue_port1_alu_o (be_event_issue_p1_alu),
        .event_issue_port1_mul_o (be_event_issue_p1_mul),
        .event_issue_port1_div_o (be_event_issue_p1_div),
        .event_issue_port2_agu_o (be_event_issue_p2_agu),
        .event_port1_wb_stall_o  (be_event_p1_wb_stall),
        .event_intiq_empty_o     (be_event_intiq_empty),
        .event_memiq_empty_o     (be_event_memiq_empty),
        .event_load_issued_o     (be_event_load_issued),
        .event_load_fwd_exact_o  (be_event_load_fwd_exact),
        .event_load_fwd_partial_o(be_event_load_fwd_partial),
        .event_load_speculative_o(be_event_load_speculative),
        .event_l1d_hits_o        (be_event_l1d_hits),
        .event_l1d_misses_o      (be_event_l1d_misses),
        .event_l1d_mshr_occ_o    (be_event_l1d_mshr_occ),
        .event_l1d_wbb_full_o    (be_event_l1d_wbb_full),
        .event_dtlb_misses_o     (be_event_dtlb_misses),
        .rob_head_is_mem_stall_o (be_rob_head_is_mem_stall),

        .lsu_violation_valid_o   (lsu_violation_valid),
        .lsu_violation_rob_idx_o (lsu_violation_rob_idx),
        .lsu_violation_rob_epoch_o(lsu_violation_rob_epoch),
        .lsu_retire0_allow_o     (lsu_retire0_allow),
        .lsu_retire1_allow_o     (lsu_retire1_allow),

        .int_dispatch_ready_o    (backend_int_dispatch_ready),
        .memiq_ready_o           (backend_memiq_ready),
        .lq_ready_o              (backend_lq_ready),
        .sq_ready_o              (backend_sq_ready),

        .snoop_req_valid_i       (snoop_req_valid_i),
        .snoop_req_addr_i        (snoop_req_addr_i),
        .snoop_req_type_i        (snoop_req_type_i),
        .snoop_rsp_valid_o       (snoop_rsp_valid_o),
        .snoop_rsp_has_data_o    (snoop_rsp_has_data_o),
        .snoop_rsp_was_dirty_o   (snoop_rsp_was_dirty_o),
        .snoop_rsp_data_o        (snoop_rsp_data_o),

        .event_mem_dual_issue_o  (be_event_mem_dual_issue),
        .event_bank_access_count_o(be_event_bank_access_count),
        .event_bank_conflict_o   (be_event_bank_conflict),
        .event_bank_broadcast_o  (be_event_bank_broadcast),
        .event_store_drain_concurrent_o(be_event_store_drain_concurrent),
        .event_snoop_query_o     (be_event_snoop_query),
        .event_snoop_hit_o       (be_event_snoop_hit),
        .event_snoop_replay_o    (be_event_snoop_replay),

        // Milestone 8 Phase A Floating-Point Register File Interface
        .r0_fp_paddr_i           ('0),
        .r0_fp_data_o            (unused_rf_fp_data[0]),
        .r1_fp_paddr_i           ('0),
        .r1_fp_data_o            (unused_rf_fp_data[1]),
        .r2_fp_paddr_i           ('0),
        .r2_fp_data_o            (unused_rf_fp_data[2]),
        .r3_fp_paddr_i           ('0),
        .r3_fp_data_o            (unused_rf_fp_data[3]),

        .w0_fp_valid_i           (test_fp_w0_valid_i),
        .w0_fp_paddr_i           (test_fp_w0_paddr_i),
        .w0_fp_data_i            (test_fp_w0_data_i),

        .w1_fp_valid_i           (test_fp_w1_valid_i),
        .w1_fp_paddr_i           (test_fp_w1_paddr_i),
        .w1_fp_data_i            (test_fp_w1_data_i),

        .w2_fp_valid_i           (test_fp_w2_valid_i),
        .w2_fp_paddr_i           (test_fp_w2_paddr_i),
        .w2_fp_data_i            (test_fp_w2_data_i),

        .probe_fp_paddr_i        (probe_fp_paddr_i),
        .probe_fp_pdata_o        (probe_fp_pdata_o)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] unused_rf_fp_data [4];
    /* verilator lint_on UNUSEDSIGNAL */

    logic              be_event_mem_dual_issue;
    logic [1:0]        be_event_bank_access_count;
    logic              be_event_bank_conflict;
    logic              be_event_bank_broadcast;
    logic              be_event_store_drain_concurrent;
    logic              be_event_snoop_query;
    logic              be_event_snoop_hit;
    logic              be_event_snoop_replay;

    logic              be_event_issue_p0;
    logic              be_event_issue_p1_alu;
    logic              be_event_issue_p1_mul;
    logic              be_event_issue_p1_div;
    logic              be_event_issue_p2_agu;
    logic              be_event_p1_wb_stall;
    logic              be_event_intiq_empty;
    logic              be_event_memiq_empty;
    logic              be_event_load_issued;
    logic              be_event_load_fwd_exact;
    logic              be_event_load_fwd_partial;
    logic              be_event_l1d_hits;
    logic              be_event_l1d_misses;
    logic [2:0]        be_event_l1d_mshr_occ;
    logic              be_event_l1d_wbb_full;
    logic              be_event_dtlb_misses;
    logic              be_rob_head_is_mem_stall;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0]        backend_int_dispatch_ready;
    logic [1:0]        backend_memiq_ready;
    logic [1:0]        backend_lq_ready;
    logic [1:0]        backend_sq_ready;
    /* verilator lint_on UNUSEDSIGNAL */

    logic [11:0]       hpm_csr_raddr;
    logic [63:0]       hpm_csr_rdata;
    logic              hpm_csr_hit;
    logic              hpm_we;
    logic [11:0]       hpm_waddr;
    logic [63:0]       hpm_wdata;

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

        // Milestone 8 Phase A Floating-Point Retirement Interface
        .retire_fp_dest_valid_i  (sub_retire_fp_dest_valid),
        .retire_fflags_i         (sub_retire_fflags),

        // Architectural State Outputs
        .priv_mode_o             (csr_priv_mode),
        .mstatus_o               (csr_mstatus),
        .satp_o                  (csr_satp),

        // Milestone 8 Floating-Point Context Outputs
        .mstatus_fs_o            (mstatus_fs_o),
        .frm_o                   (fcsr_frm_o),
        .fflags_o                (fcsr_fflags_o),

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
        .csr_stvec_o             (csr_stvec_o),

        // HPM Interface (Milestone 5)
        .hpm_csr_raddr_o         (hpm_csr_raddr),
        .hpm_csr_rdata_i         (hpm_csr_rdata),
        .hpm_csr_hit_i           (hpm_csr_hit),
        .hpm_we_o                (hpm_we),
        .hpm_waddr_o             (hpm_waddr),
        .hpm_wdata_o             (hpm_wdata)
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
        .mem_replay_valid_i      (retire_replay),
        .mem_replay_pc_i         (retire_replay_pc),

        // SFENCE.VMA
        .sfence_vma_valid_i      (eff_sfence_valid),
        .sfence_vma_va_i         (eff_sfence_va),
        .sfence_vma_asid_i       (eff_sfence_asid),

        // Checkpoint capture at Rename
        .chkpt_alloc_valid0_i    (sub_uop0_ack && frontend_en_i && (fe_uop0.is_branch || fe_uop0.is_jalr)),
        .chkpt_alloc_id0_i       (sub_uop0_chkpt_id),
        .chkpt_alloc_ghr0_i      (fe_uop0_pre_ghr),
        .chkpt_alloc_ras0_i      (fe_uop0_ras_chkpt),
        .chkpt_alloc_csr0_i      (fe_uop0_csr_chkpt),

        .chkpt_alloc_valid1_i    (sub_uop1_ack && frontend_en_i && (fe_uop1.is_branch || fe_uop1.is_jalr)),
        .chkpt_alloc_id1_i       (sub_uop1_chkpt_id),
        .chkpt_alloc_ghr1_i      (fe_uop1_pre_ghr),
        .chkpt_alloc_ras1_i      (fe_uop1_ras_chkpt),
        .chkpt_alloc_csr1_i      (fe_uop1_csr_chkpt),

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
        .uop0_csr_chkpt_o        (fe_uop0_csr_chkpt),

        .uop1_valid_o            (fe_uop1_valid),
        .uop1_o                  (fe_uop1),
        .uop1_pre_ghr_o          (fe_uop1_pre_ghr),
        .uop1_ras_chkpt_o        (fe_uop1_ras_chkpt),
        .uop1_csr_chkpt_o        (fe_uop1_csr_chkpt),

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
        .diag_grants_since_itlb_o(core_diag_grants_since_itlb),

        // Observability & Telemetry (Milestone 5)
        .event_fetch_cycles_o    (fe_event_fetch_cycles),
        .event_fetch_blocks_o    (fe_event_fetch_blocks),
        .event_fetch_uops_o      (fe_event_fetch_uops),
        .event_fetch_fq_starved_o(fe_event_fetch_fq_starved),
        .event_fetch_fq_full_o   (fe_event_fetch_fq_full),
        .event_fetch_odd_slot_o  (fe_event_fetch_odd_slot),
        .event_l1i_hits_o        (fe_event_l1i_hits),
        .event_l1i_misses_o      (fe_event_l1i_misses),
        .event_l1i_imshr_occ_o   (fe_event_l1i_imshr_occ),
        .event_itlb_misses_o     (fe_event_itlb_misses),
        .event_btb_queries_o     (fe_event_btb_queries),
        .event_btb_hits_o        (fe_event_btb_hits),
        .event_bpu_cond_pred_o   (fe_event_bpu_cond_pred),
        .event_ras_call_push_o   (fe_event_ras_call_push),
        .event_ras_ret_pop_o     (fe_event_ras_ret_pop)
    );

    logic              fe_event_fetch_cycles;
    logic              fe_event_fetch_blocks;
    logic [1:0]        fe_event_fetch_uops;
    logic              fe_event_fetch_fq_starved;
    logic              fe_event_fetch_fq_full;
    logic              fe_event_fetch_odd_slot;
    logic              fe_event_l1i_hits;
    logic              fe_event_l1i_misses;
    logic [1:0]        fe_event_l1i_imshr_occ;
    logic              fe_event_itlb_misses;
    logic              fe_event_btb_queries;
    logic              fe_event_btb_hits;
    logic              fe_event_bpu_cond_pred;
    logic              fe_event_ras_call_push;
    logic              fe_event_ras_ret_pop;

    // =========================================================================
    // 4. Milestone 5 Hardware Performance Monitoring (HPM) Subsystem
    // =========================================================================
    wire rename_stalled = sub_uop0_valid && (int_rename_ack[0] == 1'b0);
    wire uop0_is_mem_type = (be_uop0_class == UOP_LOAD) || (be_uop0_class == UOP_STORE) ||
                            (be_uop0_class == UOP_AMO)  || (be_uop0_class == UOP_FENCE);
    wire uop0_is_load_type = (be_uop0_class == UOP_LOAD);
    wire uop0_is_store_type = (be_uop0_class == UOP_STORE) || (be_uop0_class == UOP_AMO);

    wire ev_stall_rob_full   = rename_stalled && (rob_count_o >= 7'd48);
    wire ev_stall_intiq_full = rename_stalled && !uop0_is_mem_type && !backend_int_dispatch_ready[0];
    wire ev_stall_memiq_full = rename_stalled && uop0_is_mem_type && !backend_memiq_ready[0];
    wire ev_stall_lq_full    = rename_stalled && uop0_is_load_type && !backend_lq_ready[0];
    wire ev_stall_sq_full    = rename_stalled && uop0_is_store_type && !backend_sq_ready[0];
    wire ev_stall_chkpt_full = rename_stalled && (chkpt_free_count_o == 4'd0) && (sub_uop0_is_branch || sub_uop1_is_branch);
    wire ev_stall_recovery   = rename_stalled && int_recovering;

    // Retire Density and Serialization Events
    wire ev_retire_cycles_0  = (rob_count_o > 7'd0) && (retire_valid_o == 2'b00);
    wire ev_retire_cycles_1  = (retire_valid_o[0] ^ retire_valid_o[1]);
    wire ev_retire_cycles_2  = (retire_valid_o[0] && retire_valid_o[1]);
    wire ev_serialize_cycles = !fe_retire_ready || csr_flush_valid;

    // CPI Single-Owner Deterministic Accounting Predicates (Section 9.1)
    wire cpi_serialize   = !fe_retire_ready || csr_flush_valid;
    wire cpi_br_recover  = int_recovering || retire_replay;
    wire cpi_productive  = (retire_valid_o != 2'b00);
    wire cpi_mem_stall   = be_rob_head_is_mem_stall;
    wire cpi_be_rename   = !fe_fetch_queue_empty_o && (int_rename_ack == 2'b00);
    wire cpi_be_sched    = (rob_count_o > 7'd0) && be_event_intiq_empty && be_event_memiq_empty;
    wire cpi_fe_starve   = fe_fetch_queue_empty_o && frontend_en_i && !rst_i;

    fursoy_s1_hpm u_hpm (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),

        .csr_raddr_i             (hpm_csr_raddr),
        .csr_rdata_o             (hpm_csr_rdata),
        .csr_hit_o               (hpm_csr_hit),
        .csr_we_i                (hpm_we),
        .csr_waddr_i             (hpm_waddr),
        .csr_wdata_i             (hpm_wdata),

        .retire_valid_i          (retire_valid_o),
        .retire_rob_idx_i        (int_retire_rob_idx),

        .recover_valid_i         (int_recover_valid),
        .recover_rob_idx_i       (int_recover_rob_idx),
        .recover_br_type_i       (int_train_br_type),
        .flush_valid_i           (core_flush_valid),

        .ev_fetch_cycles_i       (fe_event_fetch_cycles),
        .ev_fetch_blocks_i       (fe_event_fetch_blocks),
        .ev_fetch_uops_i         (fe_event_fetch_uops),
        .ev_fetch_fq_starved_i   (fe_event_fetch_fq_starved),
        .ev_fetch_fq_full_i      (fe_event_fetch_fq_full),
        .ev_fetch_odd_slot_i     (fe_event_fetch_odd_slot),
        .ev_l1i_hits_i           (fe_event_l1i_hits),
        .ev_l1i_misses_i         (fe_event_l1i_misses),
        .ev_l1i_imshr_occ_i      (fe_event_l1i_imshr_occ),
        .ev_itlb_misses_i        (fe_event_itlb_misses),
        .ev_btb_queries_i        (fe_event_btb_queries),
        .ev_btb_hits_i           (fe_event_btb_hits),
        .ev_bpu_cond_pred_i      (fe_event_bpu_cond_pred),
        .ev_ras_call_push_i      (fe_event_ras_call_push),
        .ev_ras_ret_pop_i        (fe_event_ras_ret_pop),
        .ev_rename_uops_i        ((sub_uop0_ack ? 2'd1 : 2'd0) + (sub_uop1_ack ? 2'd1 : 2'd0)),
        .ev_stall_rob_full_i     (ev_stall_rob_full),
        .ev_stall_intiq_full_i   (ev_stall_intiq_full),
        .ev_stall_memiq_full_i   (ev_stall_memiq_full),
        .ev_stall_lq_full_i      (ev_stall_lq_full),
        .ev_stall_sq_full_i      (ev_stall_sq_full),
        .ev_stall_chkpt_full_i   (ev_stall_chkpt_full),
        .ev_stall_recovery_i     (ev_stall_recovery),
        .ev_issue_port0_i        (be_event_issue_p0),
        .ev_issue_port1_alu_i    (be_event_issue_p1_alu),
        .ev_issue_port1_mul_i    (be_event_issue_p1_mul),
        .ev_issue_port1_div_i    (be_event_issue_p1_div),
        .ev_issue_port2_agu_i    (be_event_issue_p2_agu),
        .ev_port1_wb_stall_i     (be_event_p1_wb_stall),
        .ev_intiq_empty_i        (be_event_intiq_empty),
        .ev_memiq_empty_i        (be_event_memiq_empty),
        .ev_load_issued_i        (be_event_load_issued),
        .ev_load_speculative_i   (be_event_load_speculative),
        .ev_load_fwd_exact_i     (be_event_load_fwd_exact),
        .ev_load_fwd_partial_i   (be_event_load_fwd_partial),
        .ev_load_raw_violat_i    (retire_replay),
        .ev_l1d_hits_i           (be_event_l1d_hits),
        .ev_l1d_misses_i         (be_event_l1d_misses),
        .ev_l1d_mshr_occ_i       (be_event_l1d_mshr_occ),
        .ev_l1d_wbb_full_i       (be_event_l1d_wbb_full),
        .ev_dtlb_misses_i        (be_event_dtlb_misses),
        .ev_retire_cycles_0_i    (ev_retire_cycles_0),
        .ev_retire_cycles_1_i    (ev_retire_cycles_1),
        .ev_retire_cycles_2_i    (ev_retire_cycles_2),
        .ev_serialize_cycles_i   (ev_serialize_cycles),
        .ev_mem_dual_issue_i     (be_event_mem_dual_issue),
        .ev_l1d_bank_access_i    (be_event_bank_access_count),
        .ev_l1d_bank_conflict_i  (be_event_bank_conflict),
        .ev_l1d_bank_broadcast_i (be_event_bank_broadcast),
        .ev_store_drain_concurrent_i(be_event_store_drain_concurrent),
        .ev_snoop_queries_i      (be_event_snoop_query),
        .ev_snoop_hits_i         (be_event_snoop_hit),
        .ev_snoop_replays_i      (be_event_snoop_replay),

        .cpi_serialize_i         (cpi_serialize),
        .cpi_br_recover_i        (cpi_br_recover),
        .cpi_productive_i        (cpi_productive),
        .cpi_mem_stall_i         (cpi_mem_stall),
        .cpi_be_rename_i         (cpi_be_rename),
        .cpi_be_sched_i          (cpi_be_sched),
        .cpi_fe_starve_i         (cpi_fe_starve),

        .mcycle_o                (mcycle_o),
        .minstret_o              (minstret_o),
        .mhpmcounter_o           (mhpmcounter_o),
        .cpi_category_o          (cpi_category_o),
        .cpi_active_owner_o      (cpi_active_owner_o),
        .raw_event_pulse_o       (raw_event_pulse_o)
    );

endmodule

`endif // FURSOY_S1_CORE_SV
