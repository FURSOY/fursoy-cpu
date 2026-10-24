`ifndef FURSOY_S1_SUBSTRATE_SV
`define FURSOY_S1_SUBSTRATE_SV

// =============================================================================
// Fursoy Slice-1 Core Architectural Substrate Top-Level — Milestone 1
// =============================================================================
// Integrates:
// - 2-wide Rename stage with intra-group RAW/WAW resolution and backpressure
// - 48-entry Free List with circular FIFO wrap, commit Pold & squash Pnew reclamation
// - Architectural & Speculative RATs (ARAT & SRAT) + 8 Branch Checkpoints
// - 80-entry Physical Register File (PRF) readiness metadata
// - 48-entry circular Reorder Buffer (ROB) with backwards squash recovery walk
// - Deterministic arbitration: Flush > Misprediction Recovery > In-Order Retirement > Rename
// - Comprehensive hardware ownership and state invariant assertions
// Reference: docs/architecture/slice1-core-v1.md
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_freelist.sv"
`include "fursoy_s1_rat.sv"
`include "fursoy_s1_prf_status.sv"
`include "fursoy_s1_rob.sv"
`include "fursoy_s1_frat.sv"
`include "fursoy_s1_fprf_status.sv"

module fursoy_s1_substrate
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
    input  logic                   uop0_valid_i,
    input  areg_t                  uop0_rs1_i,
    input  areg_t                  uop0_rs2_i,
    input  areg_t                  uop0_rd_i,
    input  logic                   uop0_is_branch_i,
    input  logic [63:0]            uop0_pc_i,
    // Milestone 8 Phase A FP Renaming Inputs
    input  logic                   uop0_is_fp_i,
    input  logic                   uop0_fp_dest_valid_i,
    input  fareg_t                 uop0_fs3_i,
    input  logic [2:0]             uop0_frm_i,
    // Milestone 8 Phase D Vector Renaming Inputs
    input  logic                   uop0_is_vec_i,
    input  logic                   uop0_vec_dest_valid_i,
    input  vreg_t                  uop0_prd_vec_i,

    input  logic                   uop1_valid_i,
    input  areg_t                  uop1_rs1_i,
    input  areg_t                  uop1_rs2_i,
    input  areg_t                  uop1_rd_i,
    input  logic                   uop1_is_branch_i,
    input  logic [63:0]            uop1_pc_i,
    // Milestone 8 Phase A FP Renaming Inputs
    input  logic                   uop1_is_fp_i,
    input  logic                   uop1_fp_dest_valid_i,
    input  fareg_t                 uop1_fs3_i,
    input  logic [2:0]             uop1_frm_i,
    // Milestone 8 Phase D Vector Renaming Inputs
    input  logic                   uop1_is_vec_i,
    input  logic                   uop1_vec_dest_valid_i,
    input  vreg_t                  uop1_prd_vec_i,

    // Downstream backpressure (e.g. from Issue Queues)
    input  logic [1:0]             dispatch_ready_i,

    // Acknowledged / dispatched uops
    output logic [1:0]             rename_ack_o,
    output uop_renamed_t           uop0_renamed_o,
    output uop_renamed_t           uop1_renamed_o,

    // Discrete Renamed Outputs for Direct Interface & Verification
    output logic                   uop0_ack_o,
    output preg_t                  uop0_pnew_o,
    output preg_t                  uop0_pold_o,
    output preg_t                  uop0_rs1_preg_o,
    output logic                   uop0_rs1_ready_o,
    output preg_t                  uop0_rs2_preg_o,
    output logic                   uop0_rs2_ready_o,
    output rob_idx_t               uop0_rob_idx_o,
    output rob_epoch_t             uop0_rob_epoch_o,
    output chkpt_idx_t             uop0_chkpt_id_o,
    // Milestone 8 Phase A FP Renamed Outputs
    output fpreg_t                 uop0_prd_fp_o,
    output fpreg_t                 uop0_pold_fp_o,
    output fpreg_t                 uop0_prs1_fp_o,
    output logic                   uop0_prs1_fp_ready_o,
    output fpreg_t                 uop0_prs2_fp_o,
    output logic                   uop0_prs2_fp_ready_o,
    output fpreg_t                 uop0_prs3_fp_o,
    output logic                   uop0_prs3_fp_ready_o,

    output logic                   uop1_ack_o,
    output preg_t                  uop1_pnew_o,
    output preg_t                  uop1_pold_o,
    output preg_t                  uop1_rs1_preg_o,
    output logic                   uop1_rs1_ready_o,
    output preg_t                  uop1_rs2_preg_o,
    output logic                   uop1_rs2_ready_o,
    output rob_idx_t               uop1_rob_idx_o,
    output rob_epoch_t             uop1_rob_epoch_o,
    output chkpt_idx_t             uop1_chkpt_id_o,
    // Milestone 8 Phase A FP Renamed Outputs
    output fpreg_t                 uop1_prd_fp_o,
    output fpreg_t                 uop1_pold_fp_o,
    output fpreg_t                 uop1_prs1_fp_o,
    output logic                   uop1_prs1_fp_ready_o,
    output fpreg_t                 uop1_prs2_fp_o,
    output logic                   uop1_prs2_fp_ready_o,
    output fpreg_t                 uop1_prs3_fp_o,
    output logic                   uop1_prs3_fp_ready_o,

    // -------------------------------------------------------------------------
    // Execution Units Writeback / Completion Interface
    // -------------------------------------------------------------------------
    // 5 ports (Port 0: ALU0/BR, Port 1: ALU1/MULDIV, Port 2: AGU0/LSU, Port 3: AGU1/Load, Port 4: FP Pipeline)
    input  logic [4:0]             comp_valid_i,
    input  rob_idx_t               comp_rob_idx_i        [4:0],
    input  rob_epoch_t             comp_epoch_i          [4:0],
    input  preg_t                  comp_preg_i           [4:0],
    input  logic [4:0]             comp_branch_mispred_i,
    input  logic [4:0]             comp_exception_i,
    input  logic [4:0]             comp_cause_i          [4:0],
    input  logic [4:0]             comp_fflags_i         [4:0],
    output logic [4:0]             comp_ack_o,

    // Dedicated Floating-Point Writeback Completion Interface (w0: P4, w1: P2, w2: P3)
    input  logic [2:0]             comp_fp_wb_valid_i,
    input  fpreg_t                 comp_fp_wb_preg_i     [2:0],

    // -------------------------------------------------------------------------
    // Branch Misprediction Recovery Request Interface
    // -------------------------------------------------------------------------
    input  logic                   recover_valid_i,
    input  rob_idx_t               recover_rob_idx_i,
    input  chkpt_idx_t             recover_chkpt_id_i,

    // -------------------------------------------------------------------------
    // Full Architectural Flush Request Interface (Traps, Interrupts)
    // -------------------------------------------------------------------------
    input  logic                   flush_valid_i,

    // -------------------------------------------------------------------------
    // In-Order Retirement Interface
    // -------------------------------------------------------------------------
    input  logic                   retire_ready_i,
    // Milestone 9 Phase A: Asynchronous Interrupt Retirement Gate
    input  logic                   irq_pending_i,

    // Milestone 5 Phase B1 Memory Disambiguation Violation & Replay
    input  logic                   lsu_violation_valid_i,
    input  rob_idx_t               lsu_violation_rob_idx_i,
    input  rob_epoch_t             lsu_violation_rob_epoch_i,
    input  logic                   lsu_retire0_allow_i,
    input  logic                   lsu_retire1_allow_i,

    output logic                   retire_replay_o,
    output logic [63:0]            retire_replay_pc_o,

    output logic [1:0]             retire_valid_o,
    output areg_t                  retire_rd_o           [1:0],
    output preg_t                  retire_pnew_o         [1:0],
    output preg_t                  retire_pold_o         [1:0],
    output logic [1:0]             retire_is_branch_o,
    output chkpt_idx_t             retire_chkpt_id_o     [1:0],
    output logic [63:0]            retire_pc_o           [1:0],
    output rob_idx_t               retire_rob_idx_o      [1:0],
    output rob_epoch_t             retire_epoch_o        [1:0],

    // Milestone 8 Phase A Floating-Point Retirement Fields
    output logic [1:0]             retire_is_fp_o,
    output logic [1:0]             retire_fp_dest_valid_o,
    output fpreg_t                 retire_prd_fp_o       [1:0],
    output fpreg_t                 retire_pold_fp_o      [1:0],
    output logic [4:0]             retire_fflags_o       [1:0],

    // Milestone 8 Phase D Vector Retirement Fields
    output logic [1:0]             retire_is_vec_o,
    output logic [1:0]             retire_vec_dest_valid_o,
    output vreg_t                  retire_prd_vec_o      [1:0],

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
    output rob_idx_t               rob_head_next_o,
    output rob_idx_t               rob_tail_o,
    output logic [FL_CNT_W-1:0]    freelist_count_o,
    output logic [ROB_CNT_W-1:0]   rob_count_o,
    output logic [3:0]             chkpt_free_count_o,
    output preg_t                  arat_map_o            [AREG_NUM],
    output preg_t                  srat_map_o            [AREG_NUM],
    output logic [PRF_COUNT-1:0]   prf_ready_o,

    // Milestone 8 Phase A FP Diagnostics
    output logic [FL_FP_CNT_W-1:0] fl_fp_count_o,
    output logic [1:0]             fl_fp_ready_o,
    output logic                   fl_fp_reconstructing_o,
    output fpreg_t                 arat_fp_map_o         [FAREG_COUNT],
    output fpreg_t                 srat_fp_map_o         [FAREG_COUNT],
    output logic [FPRF_SIZE-1:0]   prf_fp_ready_o,

    // Head entry diagnostics
    output logic                   diag_head_valid_o,
    output logic                   diag_head_completed_o,
    output logic                   diag_head_exception_o,
    output areg_t                  diag_head_rd_o,
    output preg_t                  diag_head_pnew_o,
    output logic                   diag_head_is_branch_o
);

    // =========================================================================
    // Internal Signals & Interconnect
    // =========================================================================

    // Free List signals
    logic [1:0]      fl_alloc_grant;
    preg_t           fl_alloc_preg [1:0];
    logic [1:0]      fl_alloc_ready;
    logic [FL_CNT_W-1:0] fl_count;
    /* verilator lint_off UNUSEDSIGNAL */
    logic            fl_empty;
    logic            fl_full;
    /* verilator lint_on UNUSEDSIGNAL */
    logic            fl_reconstructing;

    // RAT signals
    uop_rename_in_t  uop0_rename_in;
    uop_rename_in_t  uop1_rename_in;
    preg_t           uop0_pnew_cand;
    preg_t           uop1_pnew_cand;
    preg_t           uop0_rs1_preg;
    preg_t           uop0_rs2_preg;
    preg_t           uop1_rs1_preg;
    preg_t           uop1_rs2_preg;
    logic            uop1_rs1_raw_uop0;
    logic            uop1_rs2_raw_uop0;
    preg_t           uop0_pold_cand;
    preg_t           uop1_pold_cand;
    logic [1:0]      rat_rename_grant;
    chkpt_idx_t      chkpt0_id;
    chkpt_idx_t      chkpt1_id;
    logic            chkpt0_avail;
    logic            chkpt1_avail;
    logic [3:0]      chkpt_free_cnt;
    preg_t           arat_internal [AREG_NUM];
    preg_t           srat_internal [AREG_NUM];
    logic [PRF_COUNT-1:0] committed_mask;

    // PRF Status signals
    logic [1:0]      prf_alloc_valid;
    preg_t           prf_alloc_preg [1:0];
    logic            uop0_rs1_ready;
    logic            uop0_rs2_ready;
    logic            uop1_rs1_ready;
    logic            uop1_rs2_ready;
    logic [PRF_COUNT-1:0] prf_ready_internal;

    // FRAT & FPRF Status signals
    fpreg_t          uop0_pnew_fp_cand;
    fpreg_t          uop1_pnew_fp_cand;
    fpreg_t          uop0_pold_fp_cand;
    fpreg_t          uop1_pold_fp_cand;
    fpreg_t          uop0_prs1_fp;
    fpreg_t          uop0_prs2_fp;
    fpreg_t          uop0_prs3_fp;
    fpreg_t          uop1_prs1_fp;
    fpreg_t          uop1_prs2_fp;
    fpreg_t          uop1_prs3_fp;
    logic            uop1_fs1_raw_uop0;
    logic            uop1_fs2_raw_uop0;
    logic            uop1_fs3_raw_uop0;
    logic [1:0]      fl_fp_ready_internal;
    logic [FL_FP_CNT_W-1:0] fl_fp_count_internal;
    logic            fl_fp_reconstructing_internal;
    fpreg_t          arat_fp_internal [FAREG_COUNT];
    fpreg_t          srat_fp_internal [FAREG_COUNT];
    /* verilator lint_off UNUSEDSIGNAL */
    logic [FPRF_SIZE-1:0] committed_mask_fp_internal;
    /* verilator lint_on UNUSEDSIGNAL */

    logic [1:0]      fprf_alloc_valid;
    fpreg_t          fprf_alloc_preg [1:0];
    logic            uop0_prs1_fp_ready;
    logic            uop0_prs2_fp_ready;
    logic            uop0_prs3_fp_ready;
    logic            uop1_prs1_fp_ready;
    logic            uop1_prs2_fp_ready;
    logic            uop1_prs3_fp_ready;
    logic [FPRF_SIZE-1:0] prf_fp_ready_internal;

    // ROB FP signals
    logic [1:0]      rob_alloc_is_fp;
    logic [1:0]      rob_alloc_fp_dest_valid;
    fpreg_t          rob_alloc_prd_fp [1:0];
    fpreg_t          rob_alloc_pold_fp [1:0];
    logic [1:0]      rob_retire_is_fp;
    logic [1:0]      rob_retire_fp_dest_valid;
    fpreg_t          rob_retire_prd_fp [1:0];
    fpreg_t          rob_retire_pold_fp [1:0];
    logic [4:0]      rob_retire_fflags [1:0];
    logic [1:0]      rob_rec_pnew_fp_valid;
    fpreg_t          rob_rec_pnew_fp [1:0];

    // ROB Vector signals
    logic [1:0]      rob_alloc_is_vec;
    logic [1:0]      rob_alloc_vec_dest_valid;
    vreg_t           rob_alloc_prd_vec [1:0];
    logic [1:0]      rob_retire_is_vec;
    logic [1:0]      rob_retire_vec_dest_valid;
    vreg_t           rob_retire_prd_vec [1:0];

    assign rob_alloc_is_vec[0]         = uop0_is_vec_i;
    assign rob_alloc_is_vec[1]         = uop1_is_vec_i;
    assign rob_alloc_vec_dest_valid[0] = uop0_vec_dest_valid_i;
    assign rob_alloc_vec_dest_valid[1] = uop1_vec_dest_valid_i;
    assign rob_alloc_prd_vec[0]        = uop0_prd_vec_i;
    assign rob_alloc_prd_vec[1]        = uop1_prd_vec_i;

    assign retire_is_vec_o             = rob_retire_is_vec;
    assign retire_vec_dest_valid_o     = rob_retire_vec_dest_valid;
    assign retire_prd_vec_o            = rob_retire_prd_vec;

    // ROB signals
    logic [1:0]      rob_alloc_valid;
    areg_t           rob_alloc_rd [1:0];
    preg_t           rob_alloc_pnew [1:0];
    preg_t           rob_alloc_pold [1:0];
    logic [1:0]      rob_alloc_is_br;
    chkpt_idx_t      rob_alloc_chkpt_id [1:0];
    logic [63:0]     rob_alloc_pc [1:0];
    rob_idx_t        rob_alloc_idx [1:0];
    rob_epoch_t      rob_alloc_epoch [1:0];
    logic [1:0]      rob_alloc_ready;
    logic [4:0]      rob_comp_ack;
    rob_idx_t        rob_head;
    /* verilator lint_off UNUSEDSIGNAL */
    rob_idx_t        rob_tail;
    logic            rob_empty;
    logic            rob_full;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [ROB_CNT_W-1:0] rob_count;
    logic            rob_recovering;

    // ROB Retirement outputs
    logic [1:0]      rob_retire_valid;
    areg_t           rob_retire_rd [1:0];
    preg_t           rob_retire_pnew [1:0];
    preg_t           rob_retire_pold [1:0];
    logic [1:0]      rob_retire_is_br;
    chkpt_idx_t      rob_retire_chkpt_id [1:0];
    logic [63:0]     rob_retire_pc [1:0];
    rob_idx_t        rob_retire_idx [1:0];
    rob_epoch_t      rob_retire_epoch [1:0];

    // ROB Recovery Squash outputs
    logic [1:0]      rob_rec_pnew_valid;
    preg_t           rob_rec_pnew [1:0];

    // =========================================================================
    // 1. Rename Resource & Dependency Control
    // =========================================================================
    assign uop0_rename_in.valid         = uop0_valid_i;
    assign uop0_rename_in.rs1           = uop0_rs1_i;
    assign uop0_rename_in.rs2           = uop0_rs2_i;
    assign uop0_rename_in.rd            = uop0_rd_i;
    assign uop0_rename_in.is_branch     = uop0_is_branch_i;
    assign uop0_rename_in.pc            = uop0_pc_i;
    assign uop0_rename_in.is_fp         = uop0_is_fp_i;
    assign uop0_rename_in.fp_dest_valid = uop0_fp_dest_valid_i;
    assign uop0_rename_in.fs3           = uop0_fs3_i;
    assign uop0_rename_in.frm           = uop0_frm_i;

    assign uop1_rename_in.valid         = uop1_valid_i;
    assign uop1_rename_in.rs1           = uop1_rs1_i;
    assign uop1_rename_in.rs2           = uop1_rs2_i;
    assign uop1_rename_in.rd            = uop1_rd_i;
    assign uop1_rename_in.is_branch     = uop1_is_branch_i;
    assign uop1_rename_in.pc            = uop1_pc_i;
    assign uop1_rename_in.is_fp         = uop1_is_fp_i;
    assign uop1_rename_in.fp_dest_valid = uop1_fp_dest_valid_i;
    assign uop1_rename_in.fs3           = uop1_fs3_i;
    assign uop1_rename_in.frm           = uop1_frm_i;

    // Destination register requirement:
    // Integer: requires physical register if valid, not FP, and rd != 0 (x0 hardwired to 0).
    // Floating-Point: requires physical register if valid and writes FP dest (f0 is fully writable).
    wire uop0_needs_preg  = uop0_valid_i && (!uop0_fp_dest_valid_i) && (uop0_rd_i != 5'd0);
    wire uop1_needs_preg  = uop1_valid_i && (!uop1_fp_dest_valid_i) && (uop1_rd_i != 5'd0);

    wire uop0_needs_fpreg = uop0_valid_i && uop0_fp_dest_valid_i;
    wire uop1_needs_fpreg = uop1_valid_i && uop1_fp_dest_valid_i;

    // Speculative candidate Pnew assignments from Free List peek ports
    assign uop0_pnew_cand = !uop0_needs_preg ? 7'd0 : fl_alloc_preg[0];
    assign uop1_pnew_cand = !uop1_needs_preg ? 7'd0 :
                            (uop0_needs_preg ? fl_alloc_preg[1] : fl_alloc_preg[0]);

    // Resource availability checks
    wire sys_blocked = rst_i || flush_valid_i || fl_reconstructing || fl_fp_reconstructing_internal ||
                       rob_recovering || recover_valid_i;

    // Integer Free List availability
    wire uop0_fl_ok = !uop0_needs_preg || fl_alloc_ready[0];
    wire uop1_fl_ok = !uop1_needs_preg || (uop0_needs_preg ? fl_alloc_ready[1] : fl_alloc_ready[0]);

    // Floating-Point Free List availability
    wire uop0_fl_fp_ok = !uop0_needs_fpreg || fl_fp_ready_internal[0];
    wire uop1_fl_fp_ok = !uop1_needs_fpreg || (uop0_needs_fpreg ? fl_fp_ready_internal[1] : fl_fp_ready_internal[0]);

    // ROB slot availability
    wire uop0_rob_ok = rob_alloc_ready[0];
    wire uop1_rob_ok = rob_alloc_ready[1];

    // Branch Checkpoint availability
    wire uop0_chkpt_ok = !uop0_is_branch_i || chkpt0_avail;
    wire uop1_chkpt_ok = !uop1_is_branch_i || chkpt1_avail;

    // Dispatch permits
    wire uop0_can_dispatch = !sys_blocked && uop0_valid_i && dispatch_ready_i[0] &&
                             uop0_fl_ok && uop0_fl_fp_ok && uop0_rob_ok && uop0_chkpt_ok;

    wire uop1_can_dispatch = uop0_can_dispatch && uop1_valid_i && dispatch_ready_i[1] &&
                             uop1_fl_ok && uop1_fl_fp_ok && uop1_rob_ok && uop1_chkpt_ok;

    assign rename_ack_o[0] = uop0_can_dispatch;
    assign rename_ack_o[1] = uop1_can_dispatch;

    // Free List Pop Grants (Integer)
    always_comb begin
        fl_alloc_grant = 2'b00;
        if (uop0_can_dispatch && uop0_needs_preg && uop1_can_dispatch && uop1_needs_preg) begin
            fl_alloc_grant = 2'b11;
        end else if ((uop0_can_dispatch && uop0_needs_preg) || (uop1_can_dispatch && uop1_needs_preg)) begin
            fl_alloc_grant = 2'b01;
        end
    end

    // RAT Update Grants (Integer)
    assign rat_rename_grant[0] = uop0_can_dispatch;
    assign rat_rename_grant[1] = uop1_can_dispatch;

    // ROB Allocation Inputs
    assign rob_alloc_valid[0]         = uop0_can_dispatch;
    assign rob_alloc_rd[0]            = uop0_rd_i;
    assign rob_alloc_pnew[0]          = uop0_pnew_cand;
    assign rob_alloc_pold[0]          = uop0_pold_cand;
    assign rob_alloc_is_br[0]         = uop0_is_branch_i;
    assign rob_alloc_chkpt_id[0]      = chkpt0_id;
    assign rob_alloc_pc[0]            = uop0_pc_i;
    assign rob_alloc_is_fp[0]         = uop0_is_fp_i;
    assign rob_alloc_fp_dest_valid[0] = uop0_fp_dest_valid_i;
    assign rob_alloc_prd_fp[0]        = uop0_pnew_fp_cand;
    assign rob_alloc_pold_fp[0]       = uop0_pold_fp_cand;

    assign rob_alloc_valid[1]         = uop1_can_dispatch;
    assign rob_alloc_rd[1]            = uop1_rd_i;
    assign rob_alloc_pnew[1]          = uop1_pnew_cand;
    assign rob_alloc_pold[1]          = uop1_pold_cand;
    assign rob_alloc_is_br[1]         = uop1_is_branch_i;
    assign rob_alloc_chkpt_id[1]      = chkpt1_id;
    assign rob_alloc_pc[1]            = uop1_pc_i;
    assign rob_alloc_is_fp[1]         = uop1_is_fp_i;
    assign rob_alloc_fp_dest_valid[1] = uop1_fp_dest_valid_i;
    assign rob_alloc_prd_fp[1]        = uop1_pnew_fp_cand;
    assign rob_alloc_pold_fp[1]       = uop1_pold_fp_cand;

    // PRF Readiness Allocation Inputs (Integer)
    assign prf_alloc_valid[0]     = uop0_can_dispatch && uop0_needs_preg;
    assign prf_alloc_preg[0]      = uop0_pnew_cand;
    assign prf_alloc_valid[1]     = uop1_can_dispatch && uop1_needs_preg;
    assign prf_alloc_preg[1]      = uop1_pnew_cand;

    // FPRF Readiness Allocation Inputs
    assign fprf_alloc_valid[0]    = uop0_can_dispatch && uop0_needs_fpreg;
    assign fprf_alloc_preg[0]     = uop0_pnew_fp_cand;
    assign fprf_alloc_valid[1]    = uop1_can_dispatch && uop1_needs_fpreg;
    assign fprf_alloc_preg[1]     = uop1_pnew_fp_cand;

    // Renamed Output Packaging
    assign uop0_renamed_o.valid         = uop0_can_dispatch;
    assign uop0_renamed_o.rd            = uop0_rd_i;
    assign uop0_renamed_o.pnew          = uop0_pnew_cand;
    assign uop0_renamed_o.pold          = uop0_pold_cand;
    assign uop0_renamed_o.rs1           = uop0_rs1_i;
    assign uop0_renamed_o.rs1_preg      = uop0_rs1_preg;
    assign uop0_renamed_o.rs1_ready     = uop0_rs1_ready;
    assign uop0_renamed_o.rs2           = uop0_rs2_i;
    assign uop0_renamed_o.rs2_preg      = uop0_rs2_preg;
    assign uop0_renamed_o.rs2_ready     = uop0_rs2_ready;
    assign uop0_renamed_o.is_branch     = uop0_is_branch_i;
    assign uop0_renamed_o.chkpt_id      = chkpt0_id;
    assign uop0_renamed_o.rob_idx       = rob_alloc_idx[0];
    assign uop0_renamed_o.rob_epoch     = rob_alloc_epoch[0];
    assign uop0_renamed_o.pc            = uop0_pc_i;
    assign uop0_renamed_o.is_fp         = uop0_is_fp_i;
    assign uop0_renamed_o.fp_dest_valid = uop0_fp_dest_valid_i;
    assign uop0_renamed_o.prd_fp        = uop0_pnew_fp_cand;
    assign uop0_renamed_o.pold_fp       = uop0_pold_fp_cand;
    assign uop0_renamed_o.prs1_fp       = uop0_prs1_fp;
    assign uop0_renamed_o.prs1_fp_ready = uop0_prs1_fp_ready;
    assign uop0_renamed_o.prs2_fp       = uop0_prs2_fp;
    assign uop0_renamed_o.prs2_fp_ready = uop0_prs2_fp_ready;
    assign uop0_renamed_o.prs3_fp       = uop0_prs3_fp;
    assign uop0_renamed_o.prs3_fp_ready = uop0_prs3_fp_ready;
    assign uop0_renamed_o.frm           = uop0_frm_i;

    assign uop1_renamed_o.valid         = uop1_can_dispatch;
    assign uop1_renamed_o.rd            = uop1_rd_i;
    assign uop1_renamed_o.pnew          = uop1_pnew_cand;
    assign uop1_renamed_o.pold          = uop1_pold_cand;
    assign uop1_renamed_o.rs1           = uop1_rs1_i;
    assign uop1_renamed_o.rs1_preg      = uop1_rs1_preg;
    assign uop1_renamed_o.rs1_ready     = uop1_rs1_ready;
    assign uop1_renamed_o.rs2           = uop1_rs2_i;
    assign uop1_renamed_o.rs2_preg      = uop1_rs2_preg;
    assign uop1_renamed_o.rs2_ready     = uop1_rs2_ready;
    assign uop1_renamed_o.is_branch     = uop1_is_branch_i;
    assign uop1_renamed_o.chkpt_id      = chkpt1_id;
    assign uop1_renamed_o.rob_idx       = rob_alloc_idx[1];
    assign uop1_renamed_o.rob_epoch     = rob_alloc_epoch[1];
    assign uop1_renamed_o.pc            = uop1_pc_i;
    assign uop1_renamed_o.is_fp         = uop1_is_fp_i;
    assign uop1_renamed_o.fp_dest_valid = uop1_fp_dest_valid_i;
    assign uop1_renamed_o.prd_fp        = uop1_pnew_fp_cand;
    assign uop1_renamed_o.pold_fp       = uop1_pold_fp_cand;
    assign uop1_renamed_o.prs1_fp       = uop1_prs1_fp;
    assign uop1_renamed_o.prs1_fp_ready = uop1_prs1_fp_ready;
    assign uop1_renamed_o.prs2_fp       = uop1_prs2_fp;
    assign uop1_renamed_o.prs2_fp_ready = uop1_prs2_fp_ready;
    assign uop1_renamed_o.prs3_fp       = uop1_prs3_fp;
    assign uop1_renamed_o.prs3_fp_ready = uop1_prs3_fp_ready;
    assign uop1_renamed_o.frm           = uop1_frm_i;

    // =========================================================================
    // 2. Submodule Instantiations
    // =========================================================================

    // Free List retirement push qualification (rd=x0 or pold=p0 never freed)
    logic [1:0] fl_retire_push_valid;
    assign fl_retire_push_valid[0] = rob_retire_valid[0] && (!rob_retire_fp_dest_valid[0]) && (rob_retire_rd[0] != 5'd0) && (rob_retire_pold[0] != 7'd0);
    assign fl_retire_push_valid[1] = rob_retire_valid[1] && (!rob_retire_fp_dest_valid[1]) && (rob_retire_rd[1] != 5'd0) && (rob_retire_pold[1] != 7'd0);

    // Gated retirement rd for Integer RAT (FP instructions writing FP dest do not update integer ARAT)
    logic [4:0] rat_retire_rd [1:0];
    assign rat_retire_rd[0] = rob_retire_fp_dest_valid[0] ? 5'd0 : rob_retire_rd[0];
    assign rat_retire_rd[1] = rob_retire_fp_dest_valid[1] ? 5'd0 : rob_retire_rd[1];

    // Free List (Integer)
    fursoy_s1_freelist #(
        .FL_CAPACITY(FL_DEPTH)
    ) u_freelist (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .alloc_req_i         ({uop1_needs_preg, uop0_needs_preg}),
        .alloc_grant_i       (fl_alloc_grant),
        .alloc_preg_o        (fl_alloc_preg),
        .alloc_ready_o       (fl_alloc_ready),
        .retire_push_valid_i (fl_retire_push_valid),
        .retire_push_preg_i  (rob_retire_pold),
        .recover_push_valid_i(rob_rec_pnew_valid),
        .recover_push_preg_i (rob_rec_pnew),
        .reconstruct_req_i   (flush_valid_i),
        .committed_mask_i    (committed_mask),
        .reconstructing_o    (fl_reconstructing),
        .count_o             (fl_count),
        .empty_o             (fl_empty),
        .full_o              (fl_full)
    );

    // Register Alias Table (ARAT, SRAT, Checkpoints) - Integer
    fursoy_s1_rat #(
        .CHKPT_COUNT(CHKPT_NUM)
    ) u_rat (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .rob_head_i          (rob_head),
        .uop0_i              (uop0_rename_in),
        .uop1_i              (uop1_rename_in),
        .uop0_pnew_i         (uop0_pnew_cand),
        .uop1_pnew_i         (uop1_pnew_cand),
        .uop0_rs1_preg_o     (uop0_rs1_preg),
        .uop0_rs2_preg_o     (uop0_rs2_preg),
        .uop1_rs1_preg_o     (uop1_rs1_preg),
        .uop1_rs2_preg_o     (uop1_rs2_preg),
        .uop1_rs1_raw_uop0_o (uop1_rs1_raw_uop0),
        .uop1_rs2_raw_uop0_o (uop1_rs2_raw_uop0),
        .uop0_pold_o         (uop0_pold_cand),
        .uop1_pold_o         (uop1_pold_cand),
        .rename_grant_i      (rat_rename_grant),
        .uop0_rob_idx_i      (rob_alloc_idx[0]),
        .uop1_rob_idx_i      (rob_alloc_idx[1]),
        .chkpt0_id_o         (chkpt0_id),
        .chkpt1_id_o         (chkpt1_id),
        .chkpt0_avail_o      (chkpt0_avail),
        .chkpt1_avail_o      (chkpt1_avail),
        .chkpt_free_count_o  (chkpt_free_cnt),
        .retire_valid_i      (rob_retire_valid),
        .retire_rd_i         (rat_retire_rd),
        .retire_pnew_i       (rob_retire_pnew),
        .retire_is_branch_i  (rob_retire_is_br),
        .retire_chkpt_id_i   (rob_retire_chkpt_id),
        .recover_valid_i     (recover_valid_i),
        .recover_chkpt_id_i  (recover_chkpt_id_i),
        .recover_rob_idx_i   (recover_rob_idx_i),
        .flush_valid_i       (flush_valid_i),
        .arat_o              (arat_internal),
        .srat_o              (srat_internal),
        .committed_mask_o    (committed_mask)
    );

    // Floating-Point Register Alias Table (FRAT, SRAT_FP, Free List FP)
    fursoy_s1_frat #(
        .CHKPT_COUNT(CHKPT_NUM)
    ) u_frat (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .rob_head_i          (rob_head),

        .uop0_valid_i        (uop0_can_dispatch),
        .uop0_fp_dest_valid_i(uop0_fp_dest_valid_i),
        .uop0_fd_i           (uop0_rd_i),
        .uop0_fs1_i          (uop0_rs1_i),
        .uop0_fs2_i          (uop0_rs2_i),
        .uop0_fs3_i          (uop0_fs3_i),
        .uop0_is_branch_i    (uop0_is_branch_i),
        .uop0_rob_idx_i      (rob_alloc_idx[0]),

        .uop1_valid_i        (uop1_can_dispatch),
        .uop1_fp_dest_valid_i(uop1_fp_dest_valid_i),
        .uop1_fd_i           (uop1_rd_i),
        .uop1_fs1_i          (uop1_rs1_i),
        .uop1_fs2_i          (uop1_rs2_i),
        .uop1_fs3_i          (uop1_fs3_i),
        .uop1_is_branch_i    (uop1_is_branch_i),
        .uop1_rob_idx_i      (rob_alloc_idx[1]),

        .rename_grant_i      ({uop1_can_dispatch, uop0_can_dispatch}),
        .uop0_pnew_fp_o      (uop0_pnew_fp_cand),
        .uop1_pnew_fp_o      (uop1_pnew_fp_cand),
        .uop0_pold_fp_o      (uop0_pold_fp_cand),
        .uop1_pold_fp_o      (uop1_pold_fp_cand),

        .uop0_prs1_fp_o      (uop0_prs1_fp),
        .uop0_prs2_fp_o      (uop0_prs2_fp),
        .uop0_prs3_fp_o      (uop0_prs3_fp),
        .uop1_prs1_fp_o      (uop1_prs1_fp),
        .uop1_prs2_fp_o      (uop1_prs2_fp),
        .uop1_prs3_fp_o      (uop1_prs3_fp),

        .uop1_fs1_raw_uop0_o (uop1_fs1_raw_uop0),
        .uop1_fs2_raw_uop0_o (uop1_fs2_raw_uop0),
        .uop1_fs3_raw_uop0_o (uop1_fs3_raw_uop0),

        .fl_fp_ready_o       (fl_fp_ready_internal),
        .fl_fp_count_o       (fl_fp_count_internal),

        .chkpt0_id_i         (chkpt0_id),
        .chkpt1_id_i         (chkpt1_id),

        .retire_valid_i      (rob_retire_valid),
        .retire_fp_dest_valid_i(rob_retire_fp_dest_valid),
        .retire_fd_i         (rob_retire_rd),
        .retire_pnew_fp_i    (rob_retire_prd_fp),
        .retire_pold_fp_i    (rob_retire_pold_fp),
        .retire_is_branch_i  (rob_retire_is_br),
        .retire_chkpt_id_i   (rob_retire_chkpt_id),

        .recover_valid_i     (recover_valid_i),
        .recover_chkpt_id_i  (recover_chkpt_id_i),
        .recover_rob_idx_i   (recover_rob_idx_i),
        .recover_pnew_valid_i(rob_rec_pnew_fp_valid),
        .recover_pnew_fp_i   (rob_rec_pnew_fp),

        .flush_valid_i       (flush_valid_i),
        .reconstructing_o    (fl_fp_reconstructing_internal),
        .arat_fp_o           (arat_fp_internal),
        .srat_fp_o           (srat_fp_internal),
        .committed_mask_fp_o (committed_mask_fp_internal)
    );

    // PRF Readiness Metadata (Integer)
    fursoy_s1_prf_status #(
        .PRF_CAPACITY(PRF_COUNT)
    ) u_prf_status (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .alloc_valid_i       (prf_alloc_valid),
        .alloc_preg_i        (prf_alloc_preg),
        .wb_valid_i          (rob_comp_ack),
        .wb_preg_i           (comp_preg_i),
        .reclaim_valid_i     (rob_rec_pnew_valid),
        .reclaim_preg_i      (rob_rec_pnew),
        .flush_valid_i       (flush_valid_i),
        .uop0_rs1_preg_i     (uop0_rs1_preg),
        .uop0_rs2_preg_i     (uop0_rs2_preg),
        .uop1_rs1_preg_i     (uop1_rs1_preg),
        .uop1_rs2_preg_i     (uop1_rs2_preg),
        .uop1_rs1_raw_uop0_i (uop1_rs1_raw_uop0),
        .uop1_rs2_raw_uop0_i (uop1_rs2_raw_uop0),
        .uop0_rs1_ready_o    (uop0_rs1_ready),
        .uop0_rs2_ready_o    (uop0_rs2_ready),
        .uop1_rs1_ready_o    (uop1_rs1_ready),
        .uop1_rs2_ready_o    (uop1_rs2_ready),
        .prf_ready_o         (prf_ready_internal)
    );

    // Floating-Point PRF Readiness Metadata (FPRF)
    fursoy_s1_fprf_status #(
        .PRF_CAPACITY(FPRF_SIZE)
    ) u_fprf_status (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .alloc_valid_i       (fprf_alloc_valid),
        .alloc_preg_i        (fprf_alloc_preg),
        .wb_valid_i          (comp_fp_wb_valid_i),
        .wb_preg_i           (comp_fp_wb_preg_i),
        .reclaim_valid_i     (rob_rec_pnew_fp_valid),
        .reclaim_preg_i      (rob_rec_pnew_fp),
        .flush_valid_i       (flush_valid_i),
        .uop0_fs1_preg_i     (uop0_prs1_fp),
        .uop0_fs2_preg_i     (uop0_prs2_fp),
        .uop0_fs3_preg_i     (uop0_prs3_fp),
        .uop1_fs1_preg_i     (uop1_prs1_fp),
        .uop1_fs2_preg_i     (uop1_prs2_fp),
        .uop1_fs3_preg_i     (uop1_prs3_fp),
        .uop1_fs1_raw_uop0_i (uop1_fs1_raw_uop0),
        .uop1_fs2_raw_uop0_i (uop1_fs2_raw_uop0),
        .uop1_fs3_raw_uop0_i (uop1_fs3_raw_uop0),
        .uop0_fs1_ready_o    (uop0_prs1_fp_ready),
        .uop0_fs2_ready_o    (uop0_prs2_fp_ready),
        .uop0_fs3_ready_o    (uop0_prs3_fp_ready),
        .uop1_fs1_ready_o    (uop1_prs1_fp_ready),
        .uop1_fs2_ready_o    (uop1_prs2_fp_ready),
        .uop1_fs3_ready_o    (uop1_prs3_fp_ready),
        .ready_mask_fp_o     (prf_fp_ready_internal)
    );

    // Reorder Buffer
    fursoy_s1_rob #(
        .CAPACITY(ROB_NUM)
    ) u_rob (
        .clk_i                (clk_i),
        .rst_i                (rst_i),
        .alloc_valid_i        (rob_alloc_valid),
        .alloc_rd_i           (rob_alloc_rd),
        .alloc_pnew_i         (rob_alloc_pnew),
        .alloc_pold_i         (rob_alloc_pold),
        .alloc_is_branch_i    (rob_alloc_is_br),
        .alloc_chkpt_id_i     (rob_alloc_chkpt_id),
        .alloc_pc_i           (rob_alloc_pc),
        .alloc_is_fp_i        (rob_alloc_is_fp),
        .alloc_fp_dest_valid_i(rob_alloc_fp_dest_valid),
        .alloc_prd_fp_i       (rob_alloc_prd_fp),
        .alloc_pold_fp_i      (rob_alloc_pold_fp),
        .alloc_is_vec_i       (rob_alloc_is_vec),
        .alloc_vec_dest_valid_i(rob_alloc_vec_dest_valid),
        .alloc_prd_vec_i      (rob_alloc_prd_vec),
        .alloc_rob_idx_o      (rob_alloc_idx),
        .alloc_rob_epoch_o    (rob_alloc_epoch),
        .alloc_ready_o        (rob_alloc_ready),
        .comp_valid_i         (comp_valid_i),
        .comp_rob_idx_i       (comp_rob_idx_i),
        .comp_epoch_i         (comp_epoch_i),
        .comp_branch_mispred_i(comp_branch_mispred_i),
        .comp_exception_i     (comp_exception_i),
        .comp_cause_i         (comp_cause_i),
        .comp_fflags_i        (comp_fflags_i),
        .comp_ack_o           (rob_comp_ack),
        .retire_ready_i       (retire_ready_i),
        .irq_pending_i        (irq_pending_i),
        .lsu_violation_valid_i(lsu_violation_valid_i),
        .lsu_violation_rob_idx_i(lsu_violation_rob_idx_i),
        .lsu_violation_rob_epoch_i(lsu_violation_rob_epoch_i),
        .lsu_retire0_allow_i  (lsu_retire0_allow_i),
        .lsu_retire1_allow_i  (lsu_retire1_allow_i),
        .retire_replay_o      (retire_replay_o),
        .retire_replay_pc_o   (retire_replay_pc_o),
        .retire_valid_o       (rob_retire_valid),
        .retire_rd_o          (rob_retire_rd),
        .retire_pnew_o        (rob_retire_pnew),
        .retire_pold_o        (rob_retire_pold),
        .retire_is_branch_o   (rob_retire_is_br),
        .retire_chkpt_id_o    (rob_retire_chkpt_id),
        .retire_pc_o          (rob_retire_pc),
        .retire_rob_idx_o     (rob_retire_idx),
        .retire_epoch_o       (rob_retire_epoch),
        .retire_is_fp_o       (rob_retire_is_fp),
        .retire_fp_dest_valid_o(rob_retire_fp_dest_valid),
        .retire_prd_fp_o      (rob_retire_prd_fp),
        .retire_pold_fp_o     (rob_retire_pold_fp),
        .retire_fflags_o      (rob_retire_fflags),
        .retire_is_vec_o      (rob_retire_is_vec),
        .retire_vec_dest_valid_o(rob_retire_vec_dest_valid),
        .retire_prd_vec_o     (rob_retire_prd_vec),
        .retire_exception_o   (retire_exception_o),
        .retire_exc_cause_o   (retire_exc_cause_o),
        .retire_exc_pc_o      (retire_exc_pc_o),
        .recover_start_i      (recover_valid_i),
        .recover_rob_idx_i    (recover_rob_idx_i),
        .recover_pnew_valid_o (rob_rec_pnew_valid),
        .recover_pnew_o       (rob_rec_pnew),
        .recover_pnew_fp_valid_o(rob_rec_pnew_fp_valid),
        .recover_pnew_fp_o    (rob_rec_pnew_fp),
        .recovering_o         (rob_recovering),
        .flush_valid_i        (flush_valid_i),
        .head_o               (rob_head),
        .head_next_o          (rob_head_next_o),
        .tail_o               (rob_tail),
        .count_o              (rob_count),
        .empty_o              (rob_empty),
        .full_o               (rob_full),
        .diag_head_valid_o    (diag_head_valid_o),
        .diag_head_completed_o(diag_head_completed_o),
        .diag_head_exception_o(diag_head_exception_o),
        .diag_head_rd_o       (diag_head_rd_o),
        .diag_head_pnew_o     (diag_head_pnew_o),
        .diag_head_is_branch_o(diag_head_is_branch_o)
    );

    // =========================================================================
    // 3. Status Outputs & Diagnostic Exports
    // =========================================================================
    assign uop0_ack_o         = uop0_can_dispatch;
    assign uop0_pnew_o        = uop0_pnew_cand;
    assign uop0_pold_o        = uop0_pold_cand;
    assign uop0_rs1_preg_o    = uop0_rs1_preg;
    assign uop0_rs1_ready_o   = uop0_rs1_ready;
    assign uop0_rs2_preg_o    = uop0_rs2_preg;
    assign uop0_rs2_ready_o   = uop0_rs2_ready;
    assign uop0_rob_idx_o     = rob_alloc_idx[0];
    assign uop0_rob_epoch_o   = rob_alloc_epoch[0];
    assign uop0_chkpt_id_o    = chkpt0_id;

    assign uop0_prd_fp_o        = uop0_pnew_fp_cand;
    assign uop0_pold_fp_o       = uop0_pold_fp_cand;
    assign uop0_prs1_fp_o       = uop0_prs1_fp;
    assign uop0_prs1_fp_ready_o = uop0_prs1_fp_ready;
    assign uop0_prs2_fp_o       = uop0_prs2_fp;
    assign uop0_prs2_fp_ready_o = uop0_prs2_fp_ready;
    assign uop0_prs3_fp_o       = uop0_prs3_fp;
    assign uop0_prs3_fp_ready_o = uop0_prs3_fp_ready;

    assign uop1_ack_o         = uop1_can_dispatch;
    assign uop1_pnew_o        = uop1_pnew_cand;
    assign uop1_pold_o        = uop1_pold_cand;
    assign uop1_rs1_preg_o    = uop1_rs1_preg;
    assign uop1_rs1_ready_o   = uop1_rs1_ready;
    assign uop1_rs2_preg_o    = uop1_rs2_preg;
    assign uop1_rs2_ready_o   = uop1_rs2_ready;
    assign uop1_rob_idx_o     = rob_alloc_idx[1];
    assign uop1_rob_epoch_o   = rob_alloc_epoch[1];
    assign uop1_chkpt_id_o    = chkpt1_id;

    assign uop1_prd_fp_o        = uop1_pnew_fp_cand;
    assign uop1_pold_fp_o       = uop1_pold_fp_cand;
    assign uop1_prs1_fp_o       = uop1_prs1_fp;
    assign uop1_prs1_fp_ready_o = uop1_prs1_fp_ready;
    assign uop1_prs2_fp_o       = uop1_prs2_fp;
    assign uop1_prs2_fp_ready_o = uop1_prs2_fp_ready;
    assign uop1_prs3_fp_o       = uop1_prs3_fp;
    assign uop1_prs3_fp_ready_o = uop1_prs3_fp_ready;

    assign comp_ack_o         = rob_comp_ack;

    assign rob_head_o         = rob_head;
    assign rob_tail_o         = rob_tail;

    assign recovering_o       = rob_recovering;
    assign reconstructing_o   = fl_reconstructing;
    assign freelist_count_o   = fl_count;
    assign rob_count_o        = rob_count;
    assign chkpt_free_count_o = chkpt_free_cnt;
    assign arat_map_o         = arat_internal;
    assign srat_map_o         = srat_internal;
    assign prf_ready_o        = prf_ready_internal;

    assign fl_fp_count_o          = fl_fp_count_internal;
    assign fl_fp_ready_o          = fl_fp_ready_internal;
    assign fl_fp_reconstructing_o = fl_fp_reconstructing_internal;
    assign arat_fp_map_o          = arat_fp_internal;
    assign srat_fp_map_o          = srat_fp_internal;
    assign prf_fp_ready_o         = prf_fp_ready_internal;

    assign retire_valid_o         = rob_retire_valid;
    assign retire_rd_o            = rob_retire_rd;
    assign retire_pnew_o          = rob_retire_pnew;
    assign retire_pold_o          = rob_retire_pold;
    assign retire_is_branch_o     = rob_retire_is_br;
    assign retire_chkpt_id_o      = rob_retire_chkpt_id;
    assign retire_pc_o            = rob_retire_pc;
    assign retire_rob_idx_o       = rob_retire_idx;
    assign retire_epoch_o         = rob_retire_epoch;

    assign retire_is_fp_o         = rob_retire_is_fp;
    assign retire_fp_dest_valid_o = rob_retire_fp_dest_valid;
    assign retire_prd_fp_o        = rob_retire_prd_fp;
    assign retire_pold_fp_o       = rob_retire_pold_fp;
    assign retire_fflags_o        = rob_retire_fflags;

    // =========================================================================
    // 4. Invariant Verification Engine (Simulation Assertions)
    // =========================================================================
`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (!rst_i && !flush_valid_i && !fl_reconstructing && !fl_fp_reconstructing_internal &&
            !rob_recovering && !recover_valid_i) begin
            // 1. p0 hardwired invariant (Integer only)
            if (arat_internal[0] != 7'd0) begin
                $fatal(1, "[SUBSTRATE ASSERTION FAILED] ARAT[0] != p0 (p%0d)", arat_internal[0]);
            end
            if (srat_internal[0] != 7'd0) begin
                $fatal(1, "[SUBSTRATE ASSERTION FAILED] SRAT[0] != p0 (p%0d)", srat_internal[0]);
            end
            if (prf_ready_internal[0] != 1'b1) begin
                $fatal(1, "[SUBSTRATE ASSERTION FAILED] p0 is not ready!");
            end

            // 2. Committed ARAT registers not present in Free List
            for (int unsigned r = 1; r < AREG_NUM; r++) begin
                preg_t comm_p;
                comm_p = arat_internal[r];
                for (int unsigned f = 0; f < 48; f++) begin
                    if (f < fl_count) begin
                        logic [5:0] fl_peek_idx;
                        fl_peek_idx = (u_freelist.head_q + f[5:0] >= 6'd48) ?
                                      (u_freelist.head_q + f[5:0] - 6'd48) :
                                      (u_freelist.head_q + f[5:0]);
                        if (u_freelist.mem_q[fl_peek_idx] == comm_p) begin
                            $fatal(1, "[SUBSTRATE ASSERTION FAILED] Committed ARAT register p%0d (x%0d) found in Free List!",
                                   comm_p, r);
                        end
                    end
                end
            end

            // 3. Active valid ROB Pnew must not appear in Free List
            for (int unsigned i = 0; i < ROB_NUM; i++) begin
                if (u_rob.entries_q[i].valid && (!u_rob.entries_q[i].fp_dest_valid) && (u_rob.entries_q[i].rd != 5'd0)) begin
                    preg_t rob_pnew;
                    rob_pnew = u_rob.entries_q[i].pnew;
                    for (int unsigned f = 0; f < 48; f++) begin
                        if (f < fl_count) begin
                            logic [5:0] fl_peek_idx;
                            fl_peek_idx = (u_freelist.head_q + f[5:0] >= 6'd48) ?
                                          (u_freelist.head_q + f[5:0] - 6'd48) :
                                          (u_freelist.head_q + f[5:0]);
                            if (u_freelist.mem_q[fl_peek_idx] == rob_pnew) begin
                                $fatal(1, "[SUBSTRATE ASSERTION FAILED] Live ROB entry %0d Pnew p%0d found in Free List!",
                                       i, rob_pnew);
                            end
                        end
                    end
                end
            end

            // 4. No two distinct live ROB destination entries own the same Pnew
            for (int unsigned i = 0; i < ROB_NUM; i++) begin
                if (u_rob.entries_q[i].valid && (!u_rob.entries_q[i].fp_dest_valid) && (u_rob.entries_q[i].rd != 5'd0)) begin
                    for (int unsigned j = i + 1; j < ROB_NUM; j++) begin
                        if (u_rob.entries_q[j].valid && (!u_rob.entries_q[j].fp_dest_valid) && (u_rob.entries_q[j].rd != 5'd0)) begin
                            if (u_rob.entries_q[i].pnew == u_rob.entries_q[j].pnew) begin
                                $fatal(1, "[SUBSTRATE ASSERTION FAILED] Distinct live ROB entries %0d and %0d share same Pnew p%0d!",
                                       i, j, u_rob.entries_q[i].pnew);
                            end
                        end
                    end
                end
            end

            // 5. Live checkpoint mappings must not reference Free List registers
            for (int unsigned k = 0; k < CHKPT_NUM; k++) begin
                if (u_rat.chkpt_valid_q[k]) begin
                    for (int unsigned r = 1; r < AREG_NUM; r++) begin
                        preg_t chk_p;
                        chk_p = u_rat.chkpt_srat_q[k][r];
                        for (int unsigned f = 0; f < 48; f++) begin
                            if (f < fl_count) begin
                                logic [5:0] fl_peek_idx;
                                fl_peek_idx = (u_freelist.head_q + f[5:0] >= 6'd48) ?
                                              (u_freelist.head_q + f[5:0] - 6'd48) :
                                              (u_freelist.head_q + f[5:0]);
                                if (u_freelist.mem_q[fl_peek_idx] == chk_p) begin
                                    $fatal(1, "[SUBSTRATE ASSERTION FAILED] Live Checkpoint %0d map x%0d -> p%0d found in Free List!",
                                           k, r, chk_p);
                                end
                            end
                        end
                    end
                end
            end

            // 5b. Active SRAT mappings must not reference Free List registers
            for (int unsigned r = 1; r < AREG_NUM; r++) begin
                preg_t srat_p;
                srat_p = srat_internal[r];
                for (int unsigned f = 0; f < 48; f++) begin
                    if (f < fl_count) begin
                        logic [5:0] fl_peek_idx;
                        fl_peek_idx = (u_freelist.head_q + f[5:0] >= 6'd48) ?
                                      (u_freelist.head_q + f[5:0] - 6'd48) :
                                      (u_freelist.head_q + f[5:0]);
                        if (u_freelist.mem_q[fl_peek_idx] == srat_p) begin
                            $fatal(1, "[SUBSTRATE ASSERTION FAILED] Active SRAT map x%0d -> p%0d found in Free List!",
                                   r, srat_p);
                        end
                    end
                end
            end

            // 6. Count limits
            if (fl_count > 7'd48) begin
                $fatal(1, "[SUBSTRATE ASSERTION FAILED] Free List count %0d exceeds 48!", fl_count);
            end
            if (rob_count > 7'd48) begin
                $fatal(1, "[SUBSTRATE ASSERTION FAILED] ROB count %0d exceeds 48!", rob_count);
            end
            if (fl_fp_count_internal > 6'd32) begin
                $fatal(1, "[SUBSTRATE ASSERTION FAILED] FL_FP count %0d exceeds 32!", fl_fp_count_internal);
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_SUBSTRATE_SV
