`ifndef FURSOY_S1_CORE_SV
`define FURSOY_S1_CORE_SV

// =============================================================================
// Fursoy Slice-1 Core Top-Level — Milestone 2 (Integrated Backend & Substrate)
// =============================================================================
// Integrates:
// - Milestone 1 Architectural Substrate: Rename, Free List, RATs, PRF Readiness,
//   ROB48, Epoch Tracking, In-Order Retirement, and Checkpoint Recovery.
// - Milestone 2 Integer Execution Backend: IntIQ 16-entry, wrap-safe ROB age arbiter,
//   64-bit 80-entry PRF data array, Port 0 (ALU0/Branch), Port 1 (ALU1/MUL/DIV),
//   lossless Port 1 completion buffers, writeback validation, and lifetime-gated recovery.
// Reference: docs/architecture/slice1-core-v1.md
//            docs/architecture/slice1-m2-backend-v1.md
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_substrate.sv"
`include "fursoy_s1_backend.sv"

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
    // 2-Wide Rename / Dispatch Input Interface
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

    // Testbench Injection Port on Port 0 WB (for Directed Stale Completion Verification)
    input  logic                   test_inject_valid_i,
    input  logic [63:0]            test_inject_data_i,
    input  preg_t                  test_inject_pnew_i,
    input  rob_idx_t               test_inject_rob_idx_i,
    input  rob_epoch_t             test_inject_rob_epoch_i,
    input  logic                   test_inject_mispredict_i
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
        .uop0_valid_i            (uop0_valid_i),
        .uop0_rs1_i              (uop0_rs1_i),
        .uop0_rs2_i              (uop0_rs2_i),
        .uop0_rd_i               (uop0_rd_i),
        .uop0_is_branch_i        (uop0_is_branch_i),
        .uop0_pc_i               (uop0_pc_i),

        .uop1_valid_i            (uop1_valid_i),
        .uop1_rs1_i              (uop1_rs1_i),
        .uop1_rs2_i              (uop1_rs2_i),
        .uop1_rd_i               (uop1_rd_i),
        .uop1_is_branch_i        (uop1_is_branch_i),
        .uop1_pc_i               (uop1_pc_i),

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
        .flush_valid_i           (flush_valid_i),

        // Retirement
        .retire_ready_i          (retire_ready_i),
        .retire_valid_o          (retire_valid_o),
        .retire_rd_o             (retire_rd_o),
        .retire_pnew_o           (retire_pnew_o),
        .retire_pold_o           (retire_pold_o),
        .retire_is_branch_o      (retire_is_branch_o),
        .retire_chkpt_id_o       (retire_chkpt_id_o),
        .retire_pc_o             (retire_pc_o),

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
    // 2. Milestone 2 Integer Out-of-Order Execution Backend
    // =========================================================================
    fursoy_s1_backend u_backend (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),

        // Handshake
        .flush_valid_i           (flush_valid_i),
        .fl_reconstructing_i     (int_reconstructing),
        .recovering_i            (int_recovering),
        .rob_head_i              (int_rob_head),

        .recover_valid_o         (int_recover_valid),
        .recover_rob_idx_o       (int_recover_rob_idx),
        .recover_chkpt_id_o      (int_recover_chkpt_id),

        // Dispatch
        .dispatch_ready_o        (int_dispatch_ready),
        .rename_ack_i            (int_rename_ack),

        // Uop 0 Payload
        .uop0_valid_i            (uop0_valid_i),
        .uop0_class_i            (uop0_class_i),
        .uop0_subop_i            (uop0_subop_i),
        .uop0_imm_i              (uop0_imm_i),
        .uop0_use_imm_i          (uop0_use_imm_i),
        .uop0_prs1_i             (sub_uop0_rs1_preg),
        .uop0_prs1_ready_i       (sub_uop0_rs1_ready),
        .uop0_prs2_i             (sub_uop0_rs2_preg),
        .uop0_prs2_ready_i       (sub_uop0_rs2_ready),
        .uop0_pnew_i             (sub_uop0_pnew),
        .uop0_rob_idx_i          (sub_uop0_rob_idx),
        .uop0_rob_epoch_i        (sub_uop0_rob_epoch),
        .uop0_chkpt_id_i         (sub_uop0_chkpt_id),
        .uop0_pc_i               (uop0_pc_i),
        .uop0_pred_taken_i       (uop0_pred_taken_i),
        .uop0_pred_target_i      (uop0_pred_target_i),
        .uop0_is_branch_i        (uop0_is_branch_i),
        .uop0_is_jal_i           (uop0_is_jal_i),
        .uop0_is_jalr_i          (uop0_is_jalr_i),

        // Uop 1 Payload
        .uop1_valid_i            (uop1_valid_i),
        .uop1_class_i            (uop1_class_i),
        .uop1_subop_i            (uop1_subop_i),
        .uop1_imm_i              (uop1_imm_i),
        .uop1_use_imm_i          (uop1_use_imm_i),
        .uop1_prs1_i             (sub_uop1_rs1_preg),
        .uop1_prs1_ready_i       (sub_uop1_rs1_ready),
        .uop1_prs2_i             (sub_uop1_rs2_preg),
        .uop1_prs2_ready_i       (sub_uop1_rs2_ready),
        .uop1_pnew_i             (sub_uop1_pnew),
        .uop1_rob_idx_i          (sub_uop1_rob_idx),
        .uop1_rob_epoch_i        (sub_uop1_rob_epoch),
        .uop1_chkpt_id_i         (sub_uop1_chkpt_id),
        .uop1_pc_i               (uop1_pc_i),
        .uop1_pred_taken_i       (uop1_pred_taken_i),
        .uop1_pred_target_i      (uop1_pred_target_i),
        .uop1_is_branch_i        (uop1_is_branch_i),
        .uop1_is_jal_i           (uop1_is_jal_i),
        .uop1_is_jalr_i          (uop1_is_jalr_i),

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
        .test_inject_mispredict_i(test_inject_mispredict_i)
    );

endmodule

`endif // FURSOY_S1_CORE_SV
