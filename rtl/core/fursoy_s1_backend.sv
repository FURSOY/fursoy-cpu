`ifndef FURSOY_S1_BACKEND_SV
`define FURSOY_S1_BACKEND_SV

// =============================================================================
// Fursoy Slice-1 Integer Out-of-Order Execution Backend — Milestone 2
// =============================================================================
// Integrates:
// - 64-bit 80-entry Physical Register File (PRF) data storage.
// - 16-entry Integer Issue Queue (IntIQ) with wrap-safe age & port-aware arbiter.
// - Authoritative pipeline staging: DS -> IS -> RF -> EX -> validated WB -> CMT.
// - Port 0: 64-bit Integer ALU0 + Branch Resolution Unit.
// - Port 1: ALU1 + Pipelined Multiplier (K=3) + Iterative Radix-4 Divider.
// - Provably lossless Port 1 completion buffers (div_buf, mul_fifo, alu1_fifo).
// - Validated writeback gating & lifetime-gated branch recovery.
// Reference: docs/architecture/slice1-m2-backend-v1.md
`include "fursoy_s1_lsu.sv"
`include "fursoy_s1_fprf.sv"
`include "fursoy_s1_fp_iq.sv"
`include "fursoy_s1_fma.sv"
`include "fursoy_s1_fdiv.sv"
`include "fursoy_s1_fconv.sv"

module fursoy_s1_backend
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              frontend_en_i,

    // -------------------------------------------------------------------------
    // Substrate Flush & Recovery Handshake (M1 Interface)
    // -------------------------------------------------------------------------
    input  logic              flush_valid_i,
    input  logic              fl_reconstructing_i,
    input  logic              recovering_i,        // Active recovery walk in progress
    input  rob_idx_t          rob_head_i,
    input  rob_idx_t          rob_head_next_i,

    output logic              recover_valid_o,
    output rob_idx_t          recover_rob_idx_o,
    output chkpt_idx_t        recover_chkpt_id_o,
    output logic [63:0]       recover_target_o,
    output logic              recover_actual_taken_o,

    // -------------------------------------------------------------------------
    // Dispatch Interface (from Decode / M1 Rename Stage)
    // -------------------------------------------------------------------------
    output logic [1:0]        dispatch_ready_o,    // Ready to accept uop0, uop1
    input  logic [1:0]        rename_ack_i,        // M1 substrate dispatch permits

    // Uop 0 Payload
    input  logic              uop0_valid_i,
    input  uop_class_t        uop0_class_i,
    input  uop_subop_t        uop0_subop_i,
    input  logic [63:0]       uop0_imm_i,
    input  logic              uop0_use_imm_i,
    input  preg_t             uop0_prs1_i,
    input  logic              uop0_prs1_ready_i,
    input  preg_t             uop0_prs2_i,
    input  logic              uop0_prs2_ready_i,
    input  preg_t             uop0_pnew_i,
    input  rob_idx_t          uop0_rob_idx_i,
    input  rob_epoch_t        uop0_rob_epoch_i,
    input  logic              uop0_replay_safe_i,
    input  chkpt_idx_t        uop0_chkpt_id_i,
    input  logic [63:0]       uop0_pc_i,
    input  logic              uop0_pred_taken_i,
    input  logic [63:0]       uop0_pred_target_i,
    input  logic              uop0_is_branch_i,
    input  logic              uop0_is_jal_i,
    input  logic              uop0_is_jalr_i,
    input  branch_type_t      uop0_br_type_i,
    input  ghr_t              uop0_pre_ghr_i,
    input  logic              uop0_exception_i,
    input  logic [4:0]        uop0_exc_cause_i,
    // Milestone 8 Phase B FP Uop 0 Payload
    input  logic              uop0_is_fp_i,
    input  logic              uop0_fp_dest_valid_i,
    input  fpreg_t            uop0_prd_fp_i,
    input  fpreg_t            uop0_prs1_fp_i,
    input  logic              uop0_prs1_fp_ready_i,
    input  fpreg_t            uop0_prs2_fp_i,
    input  logic              uop0_prs2_fp_ready_i,
    input  fpreg_t            uop0_prs3_fp_i,
    input  logic              uop0_prs3_fp_ready_i,
    input  logic [2:0]        uop0_frm_i,

    // Uop 1 Payload
    input  logic              uop1_valid_i,
    input  uop_class_t        uop1_class_i,
    input  uop_subop_t        uop1_subop_i,
    input  logic [63:0]       uop1_imm_i,
    input  logic              uop1_use_imm_i,
    input  preg_t             uop1_prs1_i,
    input  logic              uop1_prs1_ready_i,
    input  preg_t             uop1_prs2_i,
    input  logic              uop1_prs2_ready_i,
    input  preg_t             uop1_pnew_i,
    input  rob_idx_t          uop1_rob_idx_i,
    input  rob_epoch_t        uop1_rob_epoch_i,
    input  logic              uop1_replay_safe_i,
    input  chkpt_idx_t        uop1_chkpt_id_i,
    input  logic [63:0]       uop1_pc_i,
    input  logic              uop1_pred_taken_i,
    input  logic [63:0]       uop1_pred_target_i,
    input  logic              uop1_is_branch_i,
    input  logic              uop1_is_jal_i,
    input  logic              uop1_is_jalr_i,
    input  branch_type_t      uop1_br_type_i,
    input  ghr_t              uop1_pre_ghr_i,
    input  logic              uop1_exception_i,
    input  logic [4:0]        uop1_exc_cause_i,
    // Milestone 8 Phase B FP Uop 1 Payload
    input  logic              uop1_is_fp_i,
    input  logic              uop1_fp_dest_valid_i,
    input  fpreg_t            uop1_prd_fp_i,
    input  fpreg_t            uop1_prs1_fp_i,
    input  logic              uop1_prs1_fp_ready_i,
    input  fpreg_t            uop1_prs2_fp_i,
    input  logic              uop1_prs2_fp_ready_i,
    input  fpreg_t            uop1_prs3_fp_i,
    input  logic              uop1_prs3_fp_ready_i,
    input  logic [2:0]        uop1_frm_i,

    input  logic [2:0]        fcsr_frm_i,

    // -------------------------------------------------------------------------
    // M1 Completion Interface (Expanded to 5 ports for Port 4 FP)
    // -------------------------------------------------------------------------
    output logic [4:0]        comp_valid_o,
    output rob_idx_t          comp_rob_idx_o       [4:0],
    output rob_epoch_t        comp_epoch_o         [4:0],
    output preg_t             comp_preg_o          [4:0],
    output logic [4:0]        comp_branch_mispred_o,
    output logic [4:0]        comp_exception_o,
    output logic [4:0]        comp_cause_o         [4:0],
    output logic [4:0]        comp_fflags_o        [4:0],
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [4:0]        comp_ack_i,
    /* verilator lint_on UNUSEDSIGNAL */

    // Substrate FPRF Status writeback notification
    output logic [2:0]        comp_fp_wb_valid_o,
    output fpreg_t            comp_fp_wb_preg_o    [2:0],

    // Testbench / Diagnostics Read Probe Port
    input  preg_t             probe_paddr_i,
    output logic [63:0]       probe_pdata_o,

    // Diagnostics
    output logic [15:0]       diag_valid_mask_o,
    output logic [15:0]       diag_ready_p0_o,
    output logic [15:0]       diag_ready_p1_o,
    output logic [15:0]       diag_prs1_rdy_o,
    output logic [15:0]       diag_prs2_rdy_o,
    output rob_idx_t          diag_rob_idx_o [16],

    input  logic              test_inject_valid_i,
    input  logic [63:0]       test_inject_data_i,
    input  preg_t             test_inject_pnew_i,
    input  rob_idx_t          test_inject_rob_idx_i,
    input  rob_epoch_t        test_inject_rob_epoch_i,
    input  logic              test_inject_mispredict_i,

    // In-Order Store Retirement Handshake at ROB Head (from Substrate / M1)
    input  logic [1:0]        retire_valid_i,
    input  preg_t             retire_pnew_i         [1:0],
    input  logic [63:0]       retire_pc_i           [1:0],
    input  rob_idx_t          retire_rob_idx_i      [1:0],
    input  rob_epoch_t        retire_epoch_i        [1:0],

    // -------------------------------------------------------------------------
    // External Memory Interconnect & Translation Interface (M3)
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

    // Predictor Training Interface (to Frontend BPU)
    output logic              train_valid_o,
    output logic [63:0]       train_pc_o,
    output logic              train_actual_taken_o,
    output logic [63:0]       train_actual_target_o,
    output branch_type_t      train_br_type_o,
    output ghr_t              train_ghr_o,

    // Privileged SYSTEM / CSR Execution Interface (Port 0)
    output logic              p0_sys_valid_o,
    output uop_subop_t        p0_sys_subop_o,
    output logic [11:0]       p0_sys_csr_addr_o,
    output logic [4:0]        p0_sys_rs1_field_o,
    output logic [63:0]       p0_sys_rs1_val_o,
    output logic [63:0]       p0_sys_rs2_val_o,
    output logic [63:0]       p0_sys_pc_o,
    output rob_idx_t          p0_sys_rob_idx_o,

    input  logic [63:0]       p0_sys_rdata_i,
    input  logic              p0_sys_illegal_i,

    // Observability & Telemetry (Milestone 5)
    output logic              event_issue_port0_o,
    output logic              event_issue_port1_alu_o,
    output logic              event_issue_port1_mul_o,
    output logic              event_issue_port1_div_o,
    output logic              event_issue_port2_agu_o,
    output logic              event_port1_wb_stall_o,
    output logic              event_intiq_empty_o,
    output logic              event_memiq_empty_o,
    output logic              event_load_issued_o,
    output logic              event_load_fwd_exact_o,
    output logic              event_load_fwd_partial_o,
    output logic              event_load_speculative_o,
    output logic              event_l1d_hits_o,
    output logic              event_l1d_misses_o,
    output logic [2:0]        event_l1d_mshr_occ_o,
    output logic              event_l1d_wbb_full_o,
    output logic              event_dtlb_misses_o,
    output logic              rob_head_is_mem_stall_o,

    // Milestone 5 Phase B1 Speculative Disambiguation Interface
    output logic              lsu_violation_valid_o,
    output rob_idx_t          lsu_violation_rob_idx_o,
    output rob_epoch_t        lsu_violation_rob_epoch_o,
    output logic              lsu_retire0_allow_o,
    output logic              lsu_retire1_allow_o,

    output logic [1:0]        int_dispatch_ready_o,
    output logic [1:0]        memiq_ready_o,
    output logic [1:0]        lq_ready_o,
    output logic [1:0]        sq_ready_o,

    // External Coherence Snoop Interface (Milestone 7 Section 8)
    input  logic              snoop_req_valid_i,
    input  logic [55:0]       snoop_req_addr_i,
    input  logic [1:0]        snoop_req_type_i,
    output logic              snoop_rsp_valid_o,
    output logic              snoop_rsp_has_data_o,
    output logic              snoop_rsp_was_dirty_o,
    output logic [511:0]      snoop_rsp_data_o,

    // Milestone 7 Telemetry Events (Section 10.2)
    output logic              event_mem_dual_issue_o,
    output logic [1:0]        event_bank_access_count_o,
    output logic              event_bank_conflict_o,
    output logic              event_bank_broadcast_o,
    output logic              event_store_drain_concurrent_o,
    output logic              event_snoop_query_o,
    output logic              event_snoop_hit_o,
    output logic              event_snoop_replay_o,

    // Milestone 8 Phase A Floating-Point Register File Interface
    /* verilator lint_off UNUSEDSIGNAL */
    input  fpreg_t            r0_fp_paddr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0]       r0_fp_data_o,
    /* verilator lint_off UNUSEDSIGNAL */
    input  fpreg_t            r1_fp_paddr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0]       r1_fp_data_o,
    /* verilator lint_off UNUSEDSIGNAL */
    input  fpreg_t            r2_fp_paddr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0]       r2_fp_data_o,
    input  fpreg_t            r3_fp_paddr_i,
    output logic [63:0]       r3_fp_data_o,

    input  logic              w0_fp_valid_i,
    input  fpreg_t            w0_fp_paddr_i,
    input  logic [63:0]       w0_fp_data_i,

    input  logic              w1_fp_valid_i,
    input  fpreg_t            w1_fp_paddr_i,
    input  logic [63:0]       w1_fp_data_i,

    input  logic              w2_fp_valid_i,
    input  fpreg_t            w2_fp_paddr_i,
    input  logic [63:0]       w2_fp_data_i,

    input  fpreg_t            probe_fp_paddr_i,
    output logic [63:0]       probe_fp_pdata_o
);

    // -------------------------------------------------------------------------
    // Signal Declarations
    // -------------------------------------------------------------------------
    // IntIQ Issue Outputs (IS -> RF)
    logic      is0_valid;
    iq_entry_t is0_uop;
    logic      is1_valid;
    iq_entry_t is1_uop;

    // PRF Read Ports
    preg_t      r0_paddr, r1_paddr, r2_paddr, r3_paddr;
    logic [63:0] r0_data,  r1_data,  r2_data,  r3_data;

    // Port 0 & 1 Writeback Signals (WB Stage)
    logic        p0_wb_valid;
    logic [63:0] p0_wb_data;
    preg_t       p0_wb_pnew;
    rob_idx_t    p0_wb_rob_idx;
    rob_epoch_t  p0_wb_rob_epoch;
    chkpt_idx_t  p0_wb_chkpt_id;
    logic        p0_wb_mispredict;

    logic        p1_wb_valid;
    logic [63:0] p1_wb_data;
    preg_t       p1_wb_pnew;
    rob_idx_t    p1_wb_rob_idx;
    rob_epoch_t  p1_wb_rob_epoch;

    // Port 1 Buffer Credit Signals
    logic        can_issue_mul;
    logic        can_issue_alu1;
    logic        can_issue_div;

    logic [1:0]  mul_in_flight;
    logic        alu1_in_flight;
    logic        divider_busy;
    rob_idx_t    active_div_rob_idx;

    // Internal Recovery Wire
    logic        internal_recover_valid;
    rob_idx_t    internal_recover_rob_idx;
    /* verilator lint_off UNUSEDSIGNAL */
    chkpt_idx_t  internal_recover_chkpt_id;
    /* verilator lint_on UNUSEDSIGNAL */

    // IntIQ and MemIQ dispatch readiness
    logic [1:0] int_dispatch_ready;
    logic [1:0] mem_dispatch_ready;

    // PRF Port 4, 5 & 6 read wires for LSU
    preg_t      r4_paddr, r5_paddr, r6_paddr;
    logic [63:0] r4_data,  r5_data,  r6_data;

    // Port 2 LSU Completion wires
    logic        p2_comp_valid;
    rob_idx_t    p2_comp_rob_idx;
    rob_epoch_t  p2_comp_epoch;
    preg_t       p2_comp_preg;
    logic        p2_comp_exception;
    logic [4:0]  p2_comp_cause;
    logic [63:0] p2_wb_data;
    logic        p2_comp_is_fp;
    /* verilator lint_off UNUSEDSIGNAL */
    fpreg_t      p2_comp_prd_fp;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        p2_fp_wb_valid;
    fpreg_t      p2_fp_wb_paddr;
    logic [63:0] p2_fp_wb_data;

    // Port 3 LSU Completion wires
    logic        p3_comp_valid;
    rob_idx_t    p3_comp_rob_idx;
    rob_epoch_t  p3_comp_epoch;
    preg_t       p3_comp_preg;
    logic        p3_comp_exception;
    logic [4:0]  p3_comp_cause;
    logic [63:0] p3_wb_data;
    logic        p3_comp_is_fp;
    /* verilator lint_off UNUSEDSIGNAL */
    fpreg_t      p3_comp_prd_fp;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        p3_fp_wb_valid;
    fpreg_t      p3_fp_wb_paddr;
    logic [63:0] p3_fp_wb_data;

    // LSU FPRF Port 3 Read Addr
    fpreg_t      lsu_r3_fp_paddr;

    // Port 0 / F2I Effective PRF Writeback Signals
    logic        p0_eff_wb_valid;
    logic [63:0] p0_eff_wb_data;
    preg_t       p0_eff_wb_pnew;
    rob_idx_t    p0_eff_wb_rob_idx;
    rob_epoch_t  p0_eff_wb_rob_epoch;
    logic        p0_eff_wb_mispredict;
    logic        p0_eff_wb_exception;
    logic [4:0]  p0_eff_wb_cause;
    logic [4:0]  p0_eff_wb_fflags;
    logic [63:0] p0_eff_wb_target;
    logic        p0_eff_wb_actual_taken;
    logic [63:0] p0_eff_wb_pc;
    branch_type_t p0_eff_wb_br_type;
    ghr_t        p0_eff_wb_ghr;
    logic        p0_eff_wb_is_ctrl;

    // Port 4 FPRF w0_fp Writeback Signals
    logic        p4_fprf_wb_valid;
    logic [63:0] p4_fprf_wb_data;
    fpreg_t      p4_fprf_wb_preg;
    rob_idx_t    p4_fprf_wb_rob_idx;
    rob_epoch_t  p4_fprf_wb_rob_epoch;
    logic [4:0]  p4_fprf_wb_fflags;

    // Dispatch Interface Readiness Combiner
    wire uop0_is_mem = (uop0_class_i == UOP_LOAD) || (uop0_class_i == UOP_STORE) ||
                       (uop0_class_i == UOP_AMO)  || (uop0_class_i == UOP_FENCE);
    wire uop1_is_mem = (uop1_class_i == UOP_LOAD) || (uop1_class_i == UOP_STORE) ||
                       (uop1_class_i == UOP_AMO)  || (uop1_class_i == UOP_FENCE);

    function automatic logic is_int2fp_op_b(input uop_subop_t op);
        case (op)
            FP_FMV_W_X, FP_FMV_D_X,
            FP_FCVT_S_W, FP_FCVT_D_W,
            FP_FCVT_S_WU, FP_FCVT_D_WU,
            FP_FCVT_S_L, FP_FCVT_D_L,
            FP_FCVT_S_LU, FP_FCVT_D_LU: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    wire uop0_is_fpiq = (uop0_class_i == UOP_FP) && uop0_is_fp_i && !uop0_is_mem && !is_int2fp_op_b(uop0_subop_i);
    wire uop1_is_fpiq = (uop1_class_i == UOP_FP) && uop1_is_fp_i && !uop1_is_mem && !is_int2fp_op_b(uop1_subop_i);

    /* verilator lint_off UNUSEDSIGNAL */
    wire uop0_is_int = !uop0_is_mem && !uop0_is_fpiq;
    wire uop1_is_int = !uop1_is_mem && !uop1_is_fpiq;
    /* verilator lint_on UNUSEDSIGNAL */

    logic [1:0] fp_dispatch_ready;

    always_comb begin
        if (uop0_is_mem) begin
            dispatch_ready_o[0] = mem_dispatch_ready[0];
        end else if (uop0_is_fpiq) begin
            dispatch_ready_o[0] = fp_dispatch_ready[0];
        end else begin
            dispatch_ready_o[0] = int_dispatch_ready[0];
        end

        if (uop1_is_mem) begin
            dispatch_ready_o[1] = uop0_is_mem ? mem_dispatch_ready[1] : mem_dispatch_ready[0];
        end else if (uop1_is_fpiq) begin
            dispatch_ready_o[1] = uop0_is_fpiq ? fp_dispatch_ready[1] : fp_dispatch_ready[0];
        end else begin
            dispatch_ready_o[1] = uop0_is_int ? int_dispatch_ready[1] : int_dispatch_ready[0];
        end
    end

    // -------------------------------------------------------------------------
    // 1. Integer Issue Queue (IntIQ)
    // -------------------------------------------------------------------------
    fursoy_s1_int_iq u_int_iq (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .flush_valid_i      (flush_valid_i),
        .recover_valid_i    (internal_recover_valid),
        .recover_rob_idx_i  (internal_recover_rob_idx),
        .rob_head_i         (rob_head_i),

        .dispatch_ready_o   (int_dispatch_ready),
        .rename_ack_i       (rename_ack_i),

        .uop0_valid_i       (uop0_valid_i),
        .uop0_class_i       (uop0_class_i),
        .uop0_subop_i       (uop0_subop_i),
        .uop0_imm_i         (uop0_imm_i),
        .uop0_use_imm_i     (uop0_use_imm_i),
        .uop0_prs1_i        (uop0_prs1_i),
        .uop0_prs1_ready_i  (uop0_prs1_ready_i),
        .uop0_prs2_i        (uop0_prs2_i),
        .uop0_prs2_ready_i  (uop0_prs2_ready_i),
        .uop0_pnew_i        (uop0_pnew_i),
        .uop0_rob_idx_i     (uop0_rob_idx_i),
        .uop0_rob_epoch_i   (uop0_rob_epoch_i),
        .uop0_chkpt_id_i    (uop0_chkpt_id_i),
        .uop0_pc_i          (uop0_pc_i),
        .uop0_pred_taken_i  (uop0_pred_taken_i),
        .uop0_pred_target_i (uop0_pred_target_i),
        .uop0_is_branch_i   (uop0_is_branch_i),
        .uop0_is_jal_i      (uop0_is_jal_i),
        .uop0_is_jalr_i     (uop0_is_jalr_i),
        .uop0_br_type_i     (uop0_br_type_i),
        .uop0_pre_ghr_i     (uop0_pre_ghr_i),
        .uop0_exception_i   (uop0_exception_i),
        .uop0_exc_cause_i   (uop0_exc_cause_i),
        .uop0_prd_fp_i      (uop0_prd_fp_i),
        .uop0_fp_dest_valid_i(uop0_fp_dest_valid_i),
        .uop0_frm_i         (uop0_frm_i),

        .uop1_valid_i       (uop1_valid_i),
        .uop1_class_i       (uop1_class_i),
        .uop1_subop_i       (uop1_subop_i),
        .uop1_imm_i         (uop1_imm_i),
        .uop1_use_imm_i     (uop1_use_imm_i),
        .uop1_prs1_i        (uop1_prs1_i),
        .uop1_prs1_ready_i  (uop1_prs1_ready_i),
        .uop1_prs2_i        (uop1_prs2_i),
        .uop1_prs2_ready_i  (uop1_prs2_ready_i),
        .uop1_pnew_i        (uop1_pnew_i),
        .uop1_rob_idx_i     (uop1_rob_idx_i),
        .uop1_rob_epoch_i   (uop1_rob_epoch_i),
        .uop1_chkpt_id_i    (uop1_chkpt_id_i),
        .uop1_pc_i          (uop1_pc_i),
        .uop1_pred_taken_i  (uop1_pred_taken_i),
        .uop1_pred_target_i (uop1_pred_target_i),
        .uop1_is_branch_i   (uop1_is_branch_i),
        .uop1_is_jal_i      (uop1_is_jal_i),
        .uop1_is_jalr_i     (uop1_is_jalr_i),
        .uop1_br_type_i     (uop1_br_type_i),
        .uop1_pre_ghr_i     (uop1_pre_ghr_i),
        .uop1_exception_i   (uop1_exception_i),
        .uop1_exc_cause_i   (uop1_exc_cause_i),
        .uop1_prd_fp_i      (uop1_prd_fp_i),
        .uop1_fp_dest_valid_i(uop1_fp_dest_valid_i),
        .uop1_frm_i         (uop1_frm_i),

        .wb0_valid_i        (p0_eff_wb_valid),
        .wb0_comp_ack_i     (comp_ack_i[0]),
        .wb0_pnew_i         (p0_eff_wb_pnew),

        .wb1_valid_i        (p1_wb_valid),
        .wb1_comp_ack_i     (comp_ack_i[1]),
        .wb1_pnew_i         (p1_wb_pnew),

        .wb2_valid_i        (p2_comp_valid),
        .wb2_comp_ack_i     (comp_ack_i[2]),
        .wb2_comp_exception_i (p2_comp_exception),
        .wb2_pnew_i         (p2_comp_preg),

        .wb3_valid_i        (p3_comp_valid),
        .wb3_comp_ack_i     (comp_ack_i[3]),
        .wb3_comp_exception_i (p3_comp_exception),
        .wb3_pnew_i         (p3_comp_preg),

        .can_issue_mul_i    (can_issue_mul),
        .can_issue_alu1_i   (can_issue_alu1),
        .can_issue_div_i    (can_issue_div),

        .issue0_valid_o     (is0_valid),
        .issue0_uop_o       (is0_uop),

        .issue1_valid_o     (is1_valid),
        .issue1_uop_o       (is1_uop),

        .diag_valid_mask_o  (diag_valid_mask_o),
        .diag_ready_p0_o    (diag_ready_p0_o),
        .diag_ready_p1_o    (diag_ready_p1_o),
        .diag_prs1_rdy_o    (diag_prs1_rdy_o),
        .diag_prs2_rdy_o    (diag_prs2_rdy_o),
        .diag_rob_idx_o     (diag_rob_idx_o)
    );

    // -------------------------------------------------------------------------
    // 1b. Floating-Point Issue Queue (FPIQ16 — Port 4, Milestone 8 Phase B)
    // -------------------------------------------------------------------------
    logic        fp_issue_valid;
    fpiq_entry_t fp_issue_uop;
    logic        fdiv_busy;
    logic        fconv_fprf_busy;
    logic        fconv_prf_busy;

    fursoy_s1_fp_iq u_fp_iq (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .flush_valid_i      (flush_valid_i),
        .recover_valid_i    (internal_recover_valid),
        .recover_rob_idx_i  (internal_recover_rob_idx),
        .rob_head_i         (rob_head_i),

        .dispatch_ready_o   (fp_dispatch_ready),
        .rename_ack_i       (rename_ack_i),

        .uop0_valid_i       (uop0_valid_i),
        .uop0_is_fp_i       (uop0_is_fp_i),
        .uop0_class_i       (uop0_class_i),
        .uop0_subop_i       (uop0_subop_i),
        .uop0_frm_i         (uop0_frm_i),
        .uop0_prs1_fp_i     (uop0_prs1_fp_i),
        .uop0_prs1_fp_ready_i(uop0_prs1_fp_ready_i),
        .uop0_prs2_fp_i     (uop0_prs2_fp_i),
        .uop0_prs2_fp_ready_i(uop0_prs2_fp_ready_i),
        .uop0_prs3_fp_i     (uop0_prs3_fp_i),
        .uop0_prs3_fp_ready_i(uop0_prs3_fp_ready_i),
        .uop0_prd_fp_i      (uop0_prd_fp_i),
        .uop0_fp_dest_valid_i(uop0_fp_dest_valid_i),
        .uop0_pnew_i        (uop0_pnew_i),
        .uop0_rob_idx_i     (uop0_rob_idx_i),
        .uop0_rob_epoch_i   (uop0_rob_epoch_i),
        .uop0_pc_i          (uop0_pc_i),

        .uop1_valid_i       (uop1_valid_i),
        .uop1_is_fp_i       (uop1_is_fp_i),
        .uop1_class_i       (uop1_class_i),
        .uop1_subop_i       (uop1_subop_i),
        .uop1_frm_i         (uop1_frm_i),
        .uop1_prs1_fp_i     (uop1_prs1_fp_i),
        .uop1_prs1_fp_ready_i(uop1_prs1_fp_ready_i),
        .uop1_prs2_fp_i     (uop1_prs2_fp_i),
        .uop1_prs2_fp_ready_i(uop1_prs2_fp_ready_i),
        .uop1_prs3_fp_i     (uop1_prs3_fp_i),
        .uop1_prs3_fp_ready_i(uop1_prs3_fp_ready_i),
        .uop1_prd_fp_i      (uop1_prd_fp_i),
        .uop1_fp_dest_valid_i(uop1_fp_dest_valid_i),
        .uop1_pnew_i        (uop1_pnew_i),
        .uop1_rob_idx_i     (uop1_rob_idx_i),
        .uop1_rob_epoch_i   (uop1_rob_epoch_i),
        .uop1_pc_i          (uop1_pc_i),

        .wb0_fp_valid_i     (p4_fprf_wb_valid),
        .wb0_fp_paddr_i     (p4_fprf_wb_preg),
        .wb1_fp_valid_i     (p2_fp_wb_valid || w1_fp_valid_i),
        .wb1_fp_paddr_i     (p2_fp_wb_valid ? p2_fp_wb_paddr : w1_fp_paddr_i),
        .wb2_fp_valid_i     (p3_fp_wb_valid || w2_fp_valid_i),
        .wb2_fp_paddr_i     (p3_fp_wb_valid ? p3_fp_wb_paddr : w2_fp_paddr_i),

        .fdiv_busy_i        (fdiv_busy),
        .fconv_fprf_busy_i  (fconv_fprf_busy),
        .fconv_prf_busy_i   (fconv_prf_busy),

        .issue_valid_o      (fp_issue_valid),
        .issue_uop_o        (fp_issue_uop)
    );

    // Port 4 Register Fetch Stage Registers
    logic        fp_rf_valid_q;
    /* verilator lint_off UNUSEDSIGNAL */
    fpiq_entry_t fp_rf_uop_q;
    /* verilator lint_on UNUSEDSIGNAL */

    wire fp_is_squashed = internal_recover_valid && (rob_dist(fp_issue_uop.rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));
    wire fp_rf_squashed = internal_recover_valid && (rob_dist(fp_rf_uop_q.rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            fp_rf_valid_q <= 1'b0;
            fp_rf_uop_q   <= '0;
        end else if (internal_recover_valid) begin
            if (fp_rf_squashed) begin
                fp_rf_valid_q <= 1'b0;
            end
            if (fp_issue_valid && !fp_is_squashed) begin
                fp_rf_valid_q <= 1'b1;
                fp_rf_uop_q   <= fp_issue_uop;
            end else if (!fp_rf_squashed) begin
                fp_rf_valid_q <= 1'b0;
            end
        end else if (fp_issue_valid) begin
            fp_rf_valid_q <= 1'b1;
            fp_rf_uop_q   <= fp_issue_uop;
        end else begin
            fp_rf_valid_q <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // 2. Register Fetch Stage Registers (IS -> RF)
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    logic      rf0_valid_q;
    iq_entry_t rf0_uop_q;
    logic      rf1_valid_q;
    iq_entry_t rf1_uop_q;
    /* verilator lint_on UNUSEDSIGNAL */

    wire is0_squashed = internal_recover_valid && (rob_dist(is0_uop.rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));
    wire is1_squashed = internal_recover_valid && (rob_dist(is1_uop.rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));

    wire rf0_squashed = internal_recover_valid && (rob_dist(rf0_uop_q.rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));
    wire rf1_squashed = internal_recover_valid && (rob_dist(rf1_uop_q.rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            rf0_valid_q <= 1'b0;
            rf0_uop_q   <= '0;
            rf1_valid_q <= 1'b0;
            rf1_uop_q   <= '0;
        end else begin
            // Port 0 RF
            if (is0_valid && !is0_squashed) begin
                rf0_valid_q <= 1'b1;
                rf0_uop_q   <= is0_uop;
            end else if (rf0_squashed) begin
                rf0_valid_q <= 1'b0;
            end else begin
                rf0_valid_q <= 1'b0;
            end

            // Port 1 RF
            if (is1_valid && !is1_squashed) begin
                rf1_valid_q <= 1'b1;
                rf1_uop_q   <= is1_uop;
            end else if (rf1_squashed) begin
                rf1_valid_q <= 1'b0;
            end else begin
                rf1_valid_q <= 1'b0;
            end
        end
    end

    // PRF Read Addresses (Driven from RF Stage)
    assign r0_paddr = rf0_uop_q.prs1;
    assign r1_paddr = rf0_uop_q.prs2;
    assign r2_paddr = rf1_uop_q.prs1;
    assign r3_paddr = rf1_uop_q.prs2;

    // -------------------------------------------------------------------------
    // 3. 64-bit Physical Register File (PRF)
    // -------------------------------------------------------------------------
    fursoy_s1_prf u_prf (
        .clk_i          (clk_i),
        .rst_i          (rst_i),

        .r0_paddr_i     (r0_paddr),
        .r0_data_o      (r0_data),
        .r1_paddr_i     (r1_paddr),
        .r1_data_o      (r1_data),
        .r2_paddr_i     (r2_paddr),
        .r2_data_o      (r2_data),
        .r3_paddr_i     (r3_paddr),
        .r3_data_o      (r3_data),

        .w0_valid_i     (p0_eff_wb_valid),
        .w0_comp_ack_i  (comp_ack_i[0]),
        .w0_paddr_i     (p0_eff_wb_pnew),
        .w0_data_i      (p0_eff_wb_data),

        .w1_valid_i     (p1_wb_valid),
        .w1_comp_ack_i  (comp_ack_i[1]),
        .w1_paddr_i     (p1_wb_pnew),
        .w1_data_i      (p1_wb_data),

        .r4_paddr_i     (r4_paddr),
        .r4_data_o      (r4_data),
        .r5_paddr_i     (r5_paddr),
        .r5_data_o      (r5_data),
        .r6_paddr_i     (r6_paddr),
        .r6_data_o      (r6_data),

        .w2_valid_i     (p2_comp_valid && !p2_comp_is_fp),
        .w2_comp_ack_i  (comp_ack_i[2]),
        .w2_comp_exception_i (p2_comp_exception),
        .w2_paddr_i     (p2_comp_preg),
        .w2_data_i      (p2_wb_data),

        .w3_valid_i     (p3_comp_valid && !p3_comp_is_fp),
        .w3_comp_ack_i  (comp_ack_i[3]),
        .w3_comp_exception_i (p3_comp_exception),
        .w3_paddr_i     (p3_comp_preg),
        .w3_data_i      (p3_wb_data),

        .probe_paddr_i  (probe_paddr_i),
        .probe_pdata_o  (probe_pdata_o)
    );

    // -------------------------------------------------------------------------
    // 3b. 64-bit Floating-Point Physical Register File (FPRF) — Milestone 8
    // -------------------------------------------------------------------------
    logic [63:0] r0_fp_data, r1_fp_data, r2_fp_data, r3_fp_data;

    fursoy_s1_fprf u_fprf (
        .clk_i          (clk_i),
        .rst_i          (rst_i),

        .raddr0_fp_i    (fp_rf_uop_q.prs1_fp),
        .rdata0_fp_o    (r0_fp_data),
        .raddr1_fp_i    (fp_rf_uop_q.prs2_fp),
        .rdata1_fp_o    (r1_fp_data),
        .raddr2_fp_i    (fp_rf_uop_q.prs3_fp),
        .rdata2_fp_o    (r2_fp_data),
        .raddr3_fp_i    (lsu_r3_fp_paddr != 6'd0 ? lsu_r3_fp_paddr : r3_fp_paddr_i),
        .rdata3_fp_o    (r3_fp_data),

        .w0_valid_i     (p4_fprf_wb_valid),
        .w0_paddr_i     (p4_fprf_wb_preg),
        .w0_data_i      (p4_fprf_wb_data),

        .w1_valid_i     (p2_fp_wb_valid || w1_fp_valid_i),
        .w1_paddr_i     (p2_fp_wb_valid ? p2_fp_wb_paddr : w1_fp_paddr_i),
        .w1_data_i      (p2_fp_wb_valid ? p2_fp_wb_data : w1_fp_data_i),

        .w2_valid_i     (p3_fp_wb_valid || w2_fp_valid_i),
        .w2_paddr_i     (p3_fp_wb_valid ? p3_fp_wb_paddr : w2_fp_paddr_i),
        .w2_data_i      (p3_fp_wb_valid ? p3_fp_wb_data : w2_fp_data_i),

        .probe_paddr_i  (probe_fp_paddr_i),
        .probe_pdata_o  (probe_fp_pdata_o)
    );

    assign r0_fp_data_o = r0_fp_data;
    assign r1_fp_data_o = r1_fp_data;
    assign r2_fp_data_o = r2_fp_data;
    assign r3_fp_data_o = r3_fp_data;

    // -------------------------------------------------------------------------
    // Validated Operand Forwarding & Muxing (RF -> EX)
    // -------------------------------------------------------------------------
    function automatic logic [63:0] get_operand(
        input preg_t       prs,
        input logic [63:0] rf_data,
        input logic        wb0_v,
        input logic        wb0_ack,
        input preg_t       wb0_p,
        input logic [63:0] wb0_d,
        input logic        wb1_v,
        input logic        wb1_ack,
        input preg_t       wb1_p,
        input logic [63:0] wb1_d,
        input logic        wb2_v,
        input logic        wb2_ack,
        input logic        wb2_exc,
        input preg_t       wb2_p,
        input logic [63:0] wb2_d,
        input logic        wb3_v,
        input logic        wb3_ack,
        input logic        wb3_exc,
        input preg_t       wb3_p,
        input logic [63:0] wb3_d
    );
        if (prs == 7'd0) begin
            return 64'd0;
        end else if (wb3_v && wb3_ack && !wb3_exc && (wb3_p == prs)) begin
            return wb3_d;
        end else if (wb2_v && wb2_ack && !wb2_exc && (wb2_p == prs)) begin
            return wb2_d;
        end else if (wb1_v && wb1_ack && (wb1_p == prs)) begin
            return wb1_d;
        end else if (wb0_v && wb0_ack && (wb0_p == prs)) begin
            return wb0_d;
        end else begin
            return rf_data;
        end
    endfunction

    // Port 0 Operands
    logic [63:0] p0_op_a, p0_op_b;
    always_comb begin
        if ((rf0_uop_q.uop_class == UOP_ALU_INT) && (rf0_uop_q.sub_op == ALU_AUIPC)) begin
            p0_op_a = rf0_uop_q.pc;
        end else begin
            p0_op_a = get_operand(rf0_uop_q.prs1, r0_data, p0_eff_wb_valid, comp_ack_i[0], p0_eff_wb_pnew, p0_eff_wb_data, p1_wb_valid, comp_ack_i[1], p1_wb_pnew, p1_wb_data, p2_comp_valid, comp_ack_i[2], p2_comp_exception, p2_comp_preg, p2_wb_data, p3_comp_valid, comp_ack_i[3], p3_comp_exception, p3_comp_preg, p3_wb_data);
        end
        if (rf0_uop_q.use_imm && (rf0_uop_q.uop_class != UOP_BRANCH)) begin
            p0_op_b = rf0_uop_q.imm;
        end else begin
            p0_op_b = get_operand(rf0_uop_q.prs2, r1_data, p0_eff_wb_valid, comp_ack_i[0], p0_eff_wb_pnew, p0_eff_wb_data, p1_wb_valid, comp_ack_i[1], p1_wb_pnew, p1_wb_data, p2_comp_valid, comp_ack_i[2], p2_comp_exception, p2_comp_preg, p2_wb_data, p3_comp_valid, comp_ack_i[3], p3_comp_exception, p3_comp_preg, p3_wb_data);
        end
    end

    // Port 1 Operands
    logic [63:0] p1_op_a, p1_op_b;
    always_comb begin
        if ((rf1_uop_q.uop_class == UOP_ALU_INT) && (rf1_uop_q.sub_op == ALU_AUIPC)) begin
            p1_op_a = rf1_uop_q.pc;
        end else begin
            p1_op_a = get_operand(rf1_uop_q.prs1, r2_data, p0_eff_wb_valid, comp_ack_i[0], p0_eff_wb_pnew, p0_eff_wb_data, p1_wb_valid, comp_ack_i[1], p1_wb_pnew, p1_wb_data, p2_comp_valid, comp_ack_i[2], p2_comp_exception, p2_comp_preg, p2_wb_data, p3_comp_valid, comp_ack_i[3], p3_comp_exception, p3_comp_preg, p3_wb_data);
        end
        if (rf1_uop_q.use_imm) begin
            p1_op_b = rf1_uop_q.imm;
        end else begin
            p1_op_b = get_operand(rf1_uop_q.prs2, r3_data, p0_eff_wb_valid, comp_ack_i[0], p0_eff_wb_pnew, p0_eff_wb_data, p1_wb_valid, comp_ack_i[1], p1_wb_pnew, p1_wb_data, p2_comp_valid, comp_ack_i[2], p2_comp_exception, p2_comp_preg, p2_wb_data, p3_comp_valid, comp_ack_i[3], p3_comp_exception, p3_comp_preg, p3_wb_data);
        end
    end

    // -------------------------------------------------------------------------
    // 4. Execution Port 0 (ALU0 + Branch Unit)
    // -------------------------------------------------------------------------
    logic [63:0] alu0_result;
    fursoy_s1_alu u_alu0 (
        .sub_op_i (rf0_uop_q.sub_op),
        .op_a_i   (p0_op_a),
        .op_b_i   (p0_op_b),
        .result_o (alu0_result)
    );

    logic [63:0] br_link_result;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        br_actual_taken;
    logic [63:0] br_actual_target;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        br_mispredict;

    fursoy_s1_branch_unit u_br_unit (
        .uop_class_i    (rf0_uop_q.uop_class),
        .sub_op_i       (rf0_uop_q.sub_op),
        .pc_i           (rf0_uop_q.pc),
        .imm_i          (rf0_uop_q.imm),
        .op_a_i         (p0_op_a),
        .op_b_i         (p0_op_b),
        .pred_taken_i   (rf0_uop_q.pred_taken),
        .pred_target_i  (rf0_uop_q.pred_target),

        .result_o       (br_link_result),
        .actual_taken_o (br_actual_taken),
        .actual_target_o(br_actual_target),
        .mispredict_o   (br_mispredict)
    );


    wire p0_is_ctrl = (rf0_uop_q.uop_class == UOP_BRANCH) ||
                      (rf0_uop_q.uop_class == UOP_JAL)    ||
                      (rf0_uop_q.uop_class == UOP_JALR);
    wire p0_is_sys  = (rf0_uop_q.uop_class == UOP_SYSTEM);

    assign p0_sys_valid_o     = rf0_valid_q && p0_is_sys;
    assign p0_sys_subop_o     = rf0_uop_q.sub_op;
    assign p0_sys_csr_addr_o  = rf0_uop_q.imm[11:0];
    assign p0_sys_rs1_field_o = rf0_uop_q.imm[16:12];
    assign p0_sys_rs1_val_o   = p0_op_a;
    assign p0_sys_rs2_val_o   = p0_op_b;
    assign p0_sys_pc_o        = rf0_uop_q.pc;
    assign p0_sys_rob_idx_o   = rf0_uop_q.rob_idx;

    wire [63:0] p0_ex_data = p0_is_ctrl ? br_link_result :
                             p0_is_sys  ? p0_sys_rdata_i :
                             alu0_result;

    wire target_misaligned = (br_actual_target[1:0] != 2'b00);
    wire cause0_fire = frontend_en_i &&
                       (rf0_uop_q.uop_class == UOP_JAL || rf0_uop_q.uop_class == UOP_JALR ||
                       (rf0_uop_q.uop_class == UOP_BRANCH && br_actual_taken)) && target_misaligned;

    logic        p0_wb_exception;
    logic [4:0]  p0_wb_cause;
    logic [63:0] p0_wb_target;
    logic        p0_wb_actual_taken;
    logic [63:0] p0_wb_pc;
    branch_type_t p0_wb_br_type;
    ghr_t        p0_wb_ghr;
    logic        p0_wb_is_ctrl;

    // Port 0 WB Pipeline Register (EX -> WB)
    wire ex0_squashed = internal_recover_valid && (rob_dist(rf0_uop_q.rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            p0_wb_valid        <= 1'b0;
            p0_wb_data         <= 64'd0;
            p0_wb_pnew         <= 7'd0;
            p0_wb_rob_idx      <= '0;
            p0_wb_rob_epoch    <= '0;
            p0_wb_chkpt_id     <= '0;
            p0_wb_mispredict   <= 1'b0;
            p0_wb_exception    <= 1'b0;
            p0_wb_cause        <= 5'd0;
            p0_wb_target       <= 64'd0;
            p0_wb_actual_taken <= 1'b0;
            p0_wb_pc           <= 64'd0;
            p0_wb_br_type      <= BR_TYPE_COND;
            p0_wb_ghr          <= '0;
            p0_wb_is_ctrl      <= 1'b0;
        end else begin
            if (rf0_valid_q && !ex0_squashed && !p0_is_int2fp) begin
                p0_wb_valid        <= 1'b1;
                p0_wb_data         <= p0_ex_data;
                p0_wb_pnew         <= rf0_uop_q.pnew;
                p0_wb_rob_idx      <= rf0_uop_q.rob_idx;
                p0_wb_rob_epoch    <= rf0_uop_q.rob_epoch;
                p0_wb_chkpt_id     <= rf0_uop_q.chkpt_id;
                p0_wb_target       <= br_actual_target;
                p0_wb_actual_taken <= br_actual_taken;
                p0_wb_pc           <= rf0_uop_q.pc;
                p0_wb_br_type      <= rf0_uop_q.br_type;
                p0_wb_ghr          <= rf0_uop_q.pre_ghr;
                p0_wb_is_ctrl      <= p0_is_ctrl;

                if (cause0_fire) begin
                    p0_wb_exception  <= 1'b1;
                    p0_wb_cause      <= 5'd0; // Instruction address misaligned
                    p0_wb_mispredict <= 1'b0;
                end else if (rf0_uop_q.exception) begin
                    p0_wb_exception  <= 1'b1;
                    p0_wb_cause      <= rf0_uop_q.exc_cause;
                    p0_wb_mispredict <= 1'b0;
                end else if (p0_is_sys && p0_sys_illegal_i) begin
                    p0_wb_exception  <= 1'b1;
                    p0_wb_cause      <= 5'd2; // Illegal Instruction
                    p0_wb_mispredict <= 1'b0;
                end else begin
                    p0_wb_exception  <= 1'b0;
                    p0_wb_cause      <= 5'd0;
                    p0_wb_mispredict <= (rf0_uop_q.uop_class == UOP_BRANCH || (frontend_en_i && rf0_uop_q.uop_class == UOP_JALR && rf0_uop_q.is_branch)) ? br_mispredict : 1'b0;
                end
            end else if (test_inject_valid_i) begin
                p0_wb_valid        <= 1'b1;
                p0_wb_data         <= test_inject_data_i;
                p0_wb_pnew         <= test_inject_pnew_i;
                p0_wb_rob_idx      <= test_inject_rob_idx_i;
                p0_wb_rob_epoch    <= test_inject_rob_epoch_i;
                p0_wb_chkpt_id     <= '0;
                p0_wb_mispredict   <= test_inject_mispredict_i;
                p0_wb_exception    <= 1'b0;
                p0_wb_cause        <= 5'd0;
                p0_wb_target       <= 64'd0;
                p0_wb_actual_taken <= 1'b0;
                p0_wb_pc           <= 64'd0;
                p0_wb_br_type      <= BR_TYPE_COND;
                p0_wb_ghr          <= '0;
                p0_wb_is_ctrl      <= 1'b0;
            end else begin
                p0_wb_valid   <= 1'b0;
                p0_wb_is_ctrl <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. Execution Port 1 (ALU1, Multiplier, Divider, Completion Queues)
    // -------------------------------------------------------------------------
    wire p1_is_mul = (rf1_uop_q.uop_class == UOP_MUL);
    wire p1_is_div = (rf1_uop_q.uop_class == UOP_DIV);
    wire p1_is_alu = !p1_is_mul && !p1_is_div;

    wire ex1_squashed = internal_recover_valid && (rob_dist(rf1_uop_q.rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));

    // ALU1
    logic [63:0] alu1_result;
    fursoy_s1_alu u_alu1 (
        .sub_op_i (rf1_uop_q.sub_op),
        .op_a_i   (p1_op_a),
        .op_b_i   (p1_op_b),
        .result_o (alu1_result)
    );

    // ALU1 Pipeline Register (1 Cycle Latency into alu1_fifo)
    logic        alu1_done_valid_q;
    logic [63:0] alu1_done_data_q;
    preg_t       alu1_done_pnew_q;
    rob_idx_t    alu1_done_rob_idx_q;
    rob_epoch_t  alu1_done_rob_epoch_q;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            alu1_done_valid_q <= 1'b0;
            alu1_done_data_q  <= 64'd0;
            alu1_done_pnew_q  <= 7'd0;
            alu1_done_rob_idx_q <= '0;
            alu1_done_rob_epoch_q <= '0;
        end else begin
            if (rf1_valid_q && p1_is_alu && !ex1_squashed) begin
                alu1_done_valid_q   <= 1'b1;
                alu1_done_data_q    <= alu1_result;
                alu1_done_pnew_q    <= rf1_uop_q.pnew;
                alu1_done_rob_idx_q <= rf1_uop_q.rob_idx;
                alu1_done_rob_epoch_q <= rf1_uop_q.rob_epoch;
            end else begin
                alu1_done_valid_q <= 1'b0;
            end
        end
    end
    assign alu1_in_flight = alu1_done_valid_q;

    // Multiplier
    logic        mul_done_valid;
    logic [63:0] mul_done_data;
    preg_t       mul_done_pnew;
    rob_idx_t    mul_done_rob_idx;
    rob_epoch_t  mul_done_rob_epoch;

    fursoy_s1_multiplier u_mul (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .flush_valid_i      (flush_valid_i),
        .recover_valid_i    (internal_recover_valid),
        .recover_rob_idx_i  (internal_recover_rob_idx),
        .rob_head_i         (rob_head_i),

        .issue_valid_i      (rf1_valid_q && p1_is_mul && !ex1_squashed),
        .sub_op_i           (rf1_uop_q.sub_op),
        .op_a_i             (p1_op_a),
        .op_b_i             (p1_op_b),
        .pnew_i             (rf1_uop_q.pnew),
        .rob_idx_i          (rf1_uop_q.rob_idx),
        .rob_epoch_i        (rf1_uop_q.rob_epoch),

        .in_flight_count_o  (mul_in_flight),
        .out_valid_o        (mul_done_valid),
        .out_data_o         (mul_done_data),
        .out_pnew_o         (mul_done_pnew),
        .out_rob_idx_o      (mul_done_rob_idx),
        .out_rob_epoch_o    (mul_done_rob_epoch)
    );

    // Divider
    wire div_squashed = divider_busy && internal_recover_valid &&
        (rob_dist(active_div_rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));

    logic        div_done_valid;
    logic [63:0] div_done_data;
    preg_t       div_done_pnew;
    rob_idx_t    div_done_rob_idx;
    rob_epoch_t  div_done_rob_epoch;

    fursoy_s1_divider u_div (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .flush_valid_i      (flush_valid_i),
        .cancel_i           (flush_valid_i || div_squashed),

        .issue_valid_i      (rf1_valid_q && p1_is_div && !ex1_squashed),
        .sub_op_i           (rf1_uop_q.sub_op),
        .op_a_i             (p1_op_a),
        .op_b_i             (p1_op_b),
        .pnew_i             (rf1_uop_q.pnew),
        .rob_idx_i          (rf1_uop_q.rob_idx),
        .rob_epoch_i        (rf1_uop_q.rob_epoch),

        .busy_o             (divider_busy),
        .active_rob_idx_o   (active_div_rob_idx),

        .out_valid_o        (div_done_valid),
        .out_data_o         (div_done_data),
        .out_pnew_o         (div_done_pnew),
        .out_rob_idx_o      (div_done_rob_idx),
        .out_rob_epoch_o    (div_done_rob_epoch)
    );

    wire mul_in_rf  = rf1_valid_q && p1_is_mul && !ex1_squashed;
    wire alu1_in_rf = rf1_valid_q && p1_is_alu && !ex1_squashed;
    wire div_in_rf  = rf1_valid_q && p1_is_div && !ex1_squashed;

    wire [2:0] total_mul_in_flight  = {1'b0, mul_in_flight} + {2'b00, mul_in_rf};
    wire [1:0] total_alu1_in_flight = {1'b0, alu1_in_flight} + {1'b0, alu1_in_rf};
    wire       total_divider_busy   = divider_busy || div_in_rf;

    // Port 1 Completion Network Buffers & Arbiter
    fursoy_s1_port1_buffers u_p1_buffers (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .flush_valid_i      (flush_valid_i),
        .recover_valid_i    (internal_recover_valid),
        .recover_rob_idx_i  (internal_recover_rob_idx),
        .rob_head_i         (rob_head_i),

        .mul_in_flight_i    (total_mul_in_flight),
        .alu1_in_flight_i   (total_alu1_in_flight),
        .divider_busy_i     (total_divider_busy),

        .can_issue_mul_o    (can_issue_mul),
        .can_issue_alu1_o   (can_issue_alu1),
        .can_issue_div_o    (can_issue_div),

        .div_valid_i        (div_done_valid),
        .div_data_i         (div_done_data),
        .div_pnew_i         (div_done_pnew),
        .div_rob_idx_i      (div_done_rob_idx),
        .div_rob_epoch_i    (div_done_rob_epoch),

        .mul_valid_i        (mul_done_valid),
        .mul_data_i         (mul_done_data),
        .mul_pnew_i         (mul_done_pnew),
        .mul_rob_idx_i      (mul_done_rob_idx),
        .mul_rob_epoch_i    (mul_done_rob_epoch),

        .alu1_valid_i       (alu1_done_valid_q),
        .alu1_data_i        (alu1_done_data_q),
        .alu1_pnew_i        (alu1_done_pnew_q),
        .alu1_rob_idx_i     (alu1_done_rob_idx_q),
        .alu1_rob_epoch_i   (alu1_done_rob_epoch_q),

        .wb_valid_o         (p1_wb_valid),
        .wb_data_o          (p1_wb_data),
        .wb_pnew_o          (p1_wb_pnew),
        .wb_rob_idx_o       (p1_wb_rob_idx),
        .wb_rob_epoch_o     (p1_wb_rob_epoch),
        .alu1_wb_stall_o    (event_port1_wb_stall_o)
    );

    // -------------------------------------------------------------------------
    // 5. Load/Store Unit (LSU) Subsystem — Milestone 3
    // -------------------------------------------------------------------------
    wire [MEM_IQ_DEPTH-1:0] memiq_diag_ready;

    fursoy_s1_lsu u_lsu (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),
        .flush_valid_i           (flush_valid_i),
        .recover_valid_i         (internal_recover_valid),
        .recover_rob_idx_i       (internal_recover_rob_idx),
        .rob_head_i              (rob_head_i),
        .rob_head_next_i         (rob_head_next_i),

        .mem_dispatch_ready_o    (mem_dispatch_ready),
        .rename_ack_i            (rename_ack_i),

        .uop0_valid_i            (uop0_valid_i),
        .uop0_class_i            (uop0_class_i),
        .uop0_subop_i            (uop0_subop_i),
        .uop0_imm_i              (uop0_imm_i),
        .uop0_prs1_i             (uop0_prs1_i),
        .uop0_prs1_ready_i       (uop0_prs1_ready_i),
        .uop0_prs2_i             (uop0_prs2_i),
        .uop0_prs2_ready_i       (uop0_prs2_ready_i),
        .uop0_pnew_i             (uop0_pnew_i),
        .uop0_rob_idx_i          (uop0_rob_idx_i),
        .uop0_rob_epoch_i        (uop0_rob_epoch_i),
        .uop0_replay_safe_i      (uop0_replay_safe_i),
        .uop0_pc_i               (uop0_pc_i),
        .uop0_is_fp_i            (uop0_is_fp_i),
        .uop0_prd_fp_i           (uop0_prd_fp_i),
        .uop0_prs2_fp_i          (uop0_prs2_fp_i),
        .uop0_prs2_fp_ready_i    (uop0_prs2_fp_ready_i),

        .uop1_valid_i            (uop1_valid_i),
        .uop1_class_i            (uop1_class_i),
        .uop1_subop_i            (uop1_subop_i),
        .uop1_imm_i              (uop1_imm_i),
        .uop1_prs1_i             (uop1_prs1_i),
        .uop1_prs1_ready_i       (uop1_prs1_ready_i),
        .uop1_prs2_i             (uop1_prs2_i),
        .uop1_prs2_ready_i       (uop1_prs2_ready_i),
        .uop1_pnew_i             (uop1_pnew_i),
        .uop1_rob_idx_i          (uop1_rob_idx_i),
        .uop1_rob_epoch_i        (uop1_rob_epoch_i),
        .uop1_replay_safe_i      (uop1_replay_safe_i),
        .uop1_pc_i               (uop1_pc_i),
        .uop1_is_fp_i            (uop1_is_fp_i),
        .uop1_prd_fp_i           (uop1_prd_fp_i),
        .uop1_prs2_fp_i          (uop1_prs2_fp_i),
        .uop1_prs2_fp_ready_i    (uop1_prs2_fp_ready_i),

        .r4_paddr_o              (r4_paddr),
        .r4_data_i               (r4_data),
        .r5_paddr_o              (r5_paddr),
        .r5_data_i               (r5_data),
        .r6_paddr_o              (r6_paddr),
        .r6_data_i               (r6_data),
        .r3_fp_paddr_o           (lsu_r3_fp_paddr),
        .r3_fp_data_i            (r3_fp_data),

        .wb0_valid_i             (p0_eff_wb_valid),
        .wb0_comp_ack_i          (comp_ack_i[0]),
        .wb0_pnew_i              (p0_eff_wb_pnew),
        .wb0_data_i              (p0_eff_wb_data),

        .wb1_valid_i             (p1_wb_valid),
        .wb1_comp_ack_i          (comp_ack_i[1]),
        .wb1_pnew_i              (p1_wb_pnew),
        .wb1_data_i              (p1_wb_data),

        .wb2_valid_i             (p2_comp_valid),
        .wb2_comp_ack_i          (comp_ack_i[2]),
        .wb2_comp_exception_i    (p2_comp_exception),
        .wb2_pnew_i              (p2_comp_preg),
        .wb2_data_i              (p2_wb_data),

        .wb3_valid_i             (p3_comp_valid),
        .wb3_comp_ack_i          (comp_ack_i[3]),
        .wb3_comp_exception_i    (p3_comp_exception),
        .wb3_pnew_i              (p3_comp_preg),
        .wb3_data_i              (p3_wb_data),

        .wb0_fp_valid_i          (p4_fprf_wb_valid),
        .wb0_fp_paddr_i          (p4_fprf_wb_preg),
        .wb0_fp_data_i           (p4_fprf_wb_data),

        .retire_valid_i          (retire_valid_i),
        .retire_pnew_i           (retire_pnew_i),
        .retire_pc_i             (retire_pc_i),
        .retire_rob_idx_i        (retire_rob_idx_i),
        .retire_epoch_i          (retire_epoch_i),

        .p2_comp_valid_o         (p2_comp_valid),
        .p2_comp_rob_idx_o       (p2_comp_rob_idx),
        .p2_comp_epoch_o         (p2_comp_epoch),
        .p2_comp_preg_o          (p2_comp_preg),
        .p2_comp_exception_o     (p2_comp_exception),
        .p2_comp_cause_o         (p2_comp_cause),
        .p2_wb_data_o            (p2_wb_data),
        .p2_comp_ack_i           (comp_ack_i[2]),
        .p2_comp_is_fp_o         (p2_comp_is_fp),
        .p2_comp_prd_fp_o        (p2_comp_prd_fp),
        .p2_fp_wb_valid_o        (p2_fp_wb_valid),
        .p2_fp_wb_paddr_o        (p2_fp_wb_paddr),
        .p2_fp_wb_data_o         (p2_fp_wb_data),

        .p3_comp_valid_o         (p3_comp_valid),
        .p3_comp_rob_idx_o       (p3_comp_rob_idx),
        .p3_comp_epoch_o         (p3_comp_epoch),
        .p3_comp_preg_o          (p3_comp_preg),
        .p3_comp_exception_o     (p3_comp_exception),
        .p3_comp_cause_o         (p3_comp_cause),
        .p3_wb_data_o            (p3_wb_data),
        .p3_comp_ack_i           (comp_ack_i[3]),
        .p3_comp_is_fp_o         (p3_comp_is_fp),
        .p3_comp_prd_fp_o        (p3_comp_prd_fp),
        .p3_fp_wb_valid_o        (p3_fp_wb_valid),
        .p3_fp_wb_paddr_o        (p3_fp_wb_paddr),
        .p3_fp_wb_data_o         (p3_fp_wb_data),

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

        .ptw_req_valid_o         (ptw_req_valid_o),
        .ptw_req_tr_id_o         (ptw_req_tr_id_o),
        .ptw_req_vpn_o           (ptw_req_vpn_o),
        .ptw_req_access_type_o   (ptw_req_access_type_o),
        .ptw_req_ready_i         (ptw_req_ready_i),
        .ptw_rsp_valid_i         (ptw_rsp_valid_i),
        .ptw_rsp_tr_id_i         (ptw_rsp_tr_id_i),
        .ptw_rsp_pa_i            (ptw_rsp_pa_i),
        .ptw_rsp_page_fault_i    (ptw_rsp_page_fault_i),
        .ptw_rsp_access_fault_i  (ptw_rsp_access_fault_i),

        .dcache_clean_all_req_i  (dcache_clean_all_req_i),
        .dcache_clean_all_done_o (dcache_clean_all_done_o),
        .sq_empty_o              (sq_empty_o),

        .event_load_issued_o     (event_load_issued_o),
        .event_load_fwd_exact_o  (event_load_fwd_exact_o),
        .event_load_fwd_partial_o(event_load_fwd_partial_o),
        .event_load_speculative_o(event_load_speculative_o),
        .event_l1d_hit_o         (event_l1d_hits_o),
        .event_l1d_miss_o        (event_l1d_misses_o),
        .event_l1d_mshr_occ_o    (event_l1d_mshr_occ_o),
        .event_l1d_wbb_full_o    (event_l1d_wbb_full_o),
        .event_dtlb_miss_o       (event_dtlb_misses_o),
        .rob_head_is_mem_stall_o (rob_head_is_mem_stall_o),

        .lsu_violation_valid_o   (lsu_violation_valid_o),
        .lsu_violation_rob_idx_o (lsu_violation_rob_idx_o),
        .lsu_violation_rob_epoch_o(lsu_violation_rob_epoch_o),
        .lsu_retire0_allow_o     (lsu_retire0_allow_o),
        .lsu_retire1_allow_o     (lsu_retire1_allow_o),

        .memiq_ready_o           (memiq_ready_o),
        .lq_ready_o              (lq_ready_o),
        .sq_ready_o              (sq_ready_o),
        /* verilator lint_off PINCONNECTEMPTY */
        .lq_count_o              (),
        /* verilator lint_on PINCONNECTEMPTY */
        .memiq_diag_ready_o      (memiq_diag_ready),

        .snoop_req_valid_i       (snoop_req_valid_i),
        .snoop_req_addr_i        (snoop_req_addr_i),
        .snoop_req_type_i        (snoop_req_type_i),
        .snoop_rsp_valid_o       (snoop_rsp_valid_o),
        .snoop_rsp_has_data_o    (snoop_rsp_has_data_o),
        .snoop_rsp_was_dirty_o   (snoop_rsp_was_dirty_o),
        .snoop_rsp_data_o        (snoop_rsp_data_o),

        .event_mem_dual_issue_o  (event_mem_dual_issue_o),
        .event_bank_access_count_o(event_bank_access_count_o),
        .event_bank_conflict_o   (event_bank_conflict_o),
        .event_bank_broadcast_o  (event_bank_broadcast_o),
        .event_store_drain_concurrent_o(event_store_drain_concurrent_o),
        .event_snoop_query_o     (event_snoop_query_o),
        .event_snoop_hit_o       (event_snoop_hit_o),
        .event_snoop_replay_o    (event_snoop_replay_o)
    );

    wire is1_is_mul = (is1_uop.uop_class == UOP_MUL);
    wire is1_is_div = (is1_uop.uop_class == UOP_DIV);

    assign event_issue_port0_o     = is0_valid && !is0_squashed;
    assign event_issue_port1_mul_o = is1_valid && !is1_squashed && is1_is_mul;
    assign event_issue_port1_div_o = is1_valid && !is1_squashed && is1_is_div;
    assign event_issue_port1_alu_o = is1_valid && !is1_squashed && !is1_is_mul && !is1_is_div;
    assign event_issue_port2_agu_o = u_lsu.memiq_issue0_valid;

    assign event_intiq_empty_o     = (diag_ready_p0_o == 16'd0) && (diag_ready_p1_o == 16'd0);
    assign event_memiq_empty_o     = (memiq_diag_ready == '0);
    assign int_dispatch_ready_o    = int_dispatch_ready;

    // -------------------------------------------------------------------------
    // 5b. Port 4 Floating-Point Execution Subsystem (FMA, FDIV/FSQRT, FCONV)
    // -------------------------------------------------------------------------
    function automatic logic is_fma_op(input uop_subop_t op);
        case (op)
            FP_FMADD_S, FP_FMADD_D,
            FP_FMSUB_S, FP_FMSUB_D,
            FP_FNMSUB_S, FP_FNMSUB_D,
            FP_FNMADD_S, FP_FNMADD_D,
            FP_FADD_S, FP_FADD_D,
            FP_FSUB_S, FP_FSUB_D,
            FP_FMUL_S, FP_FMUL_D: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    function automatic logic is_fdiv_op(input uop_subop_t op);
        case (op)
            FP_FDIV_S, FP_FDIV_D,
            FP_FSQRT_S, FP_FSQRT_D: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    function automatic logic is_fconv_p4_op(input uop_subop_t op);
        case (op)
            FP_FCVT_S_D, FP_FCVT_D_S,
            FP_FSGNJ_S, FP_FSGNJN_S, FP_FSGNJX_S,
            FP_FSGNJ_D, FP_FSGNJN_D, FP_FSGNJX_D,
            FP_FMIN_S, FP_FMAX_S,
            FP_FMIN_D, FP_FMAX_D,
            FP_FMV_X_W, FP_FMV_X_D,
            FP_FCVT_W_S, FP_FCVT_WU_S, FP_FCVT_L_S, FP_FCVT_LU_S,
            FP_FCVT_W_D, FP_FCVT_WU_D, FP_FCVT_L_D, FP_FCVT_LU_D,
            FP_FEQ_S, FP_FLT_S, FP_FLE_S,
            FP_FEQ_D, FP_FLT_D, FP_FLE_D,
            FP_FCLASS_S, FP_FCLASS_D: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    logic        fma_out_valid;
    logic [63:0] fma_out_data;
    fpreg_t      fma_out_prd_fp;
    rob_idx_t    fma_out_rob_idx;
    rob_epoch_t  fma_out_rob_epoch;
    logic [4:0]  fma_out_fflags;

    fursoy_s1_fma u_fma (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .flush_valid_i      (flush_valid_i),
        .recover_valid_i    (internal_recover_valid),
        .recover_rob_idx_i  (internal_recover_rob_idx),
        .rob_head_i         (rob_head_i),

        .fcsr_frm_i         (fcsr_frm_i),

        .req_valid_i        (fp_rf_valid_q && !fp_rf_squashed && is_fma_op(fp_rf_uop_q.sub_op)),
        .req_subop_i        (fp_rf_uop_q.sub_op),
        .req_frm_i          (fp_rf_uop_q.frm),
        .req_rs1_data_i     (r0_fp_data),
        .req_rs2_data_i     (r1_fp_data),
        .req_rs3_data_i     (r2_fp_data),
        .req_prd_fp_i       (fp_rf_uop_q.prd_fp),
        .req_rob_idx_i      (fp_rf_uop_q.rob_idx),
        .req_rob_epoch_i    (fp_rf_uop_q.rob_epoch),

        .wb_valid_o         (fma_out_valid),
        .wb_data_o          (fma_out_data),
        .wb_prd_fp_o        (fma_out_prd_fp),
        .wb_rob_idx_o       (fma_out_rob_idx),
        .wb_rob_epoch_o     (fma_out_rob_epoch),
        .wb_fflags_o        (fma_out_fflags)
    );

    logic        fdiv_out_valid;
    logic [63:0] fdiv_out_data;
    fpreg_t      fdiv_out_prd_fp;
    rob_idx_t    fdiv_out_rob_idx;
    rob_epoch_t  fdiv_out_rob_epoch;
    logic [4:0]  fdiv_out_fflags;

    fursoy_s1_fdiv u_fdiv (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .flush_valid_i      (flush_valid_i),
        .recover_valid_i    (internal_recover_valid),
        .recover_rob_idx_i  (internal_recover_rob_idx),
        .rob_head_i         (rob_head_i),

        .fcsr_frm_i         (fcsr_frm_i),

        .req_valid_i        (fp_rf_valid_q && !fp_rf_squashed && is_fdiv_op(fp_rf_uop_q.sub_op)),
        .req_subop_i        (fp_rf_uop_q.sub_op),
        .req_frm_i          (fp_rf_uop_q.frm),
        .req_rs1_data_i     (r0_fp_data),
        .req_rs2_data_i     (r1_fp_data),
        .req_prd_fp_i       (fp_rf_uop_q.prd_fp),
        .req_rob_idx_i      (fp_rf_uop_q.rob_idx),
        .req_rob_epoch_i    (fp_rf_uop_q.rob_epoch),

        .busy_o             (fdiv_busy),
        .fma_wb_valid_i     (fma_out_valid),

        .wb_valid_o         (fdiv_out_valid),
        .wb_data_o          (fdiv_out_data),
        .wb_prd_fp_o        (fdiv_out_prd_fp),
        .wb_rob_idx_o       (fdiv_out_rob_idx),
        .wb_rob_epoch_o     (fdiv_out_rob_epoch),
        .wb_fflags_o        (fdiv_out_fflags)
    );

    wire p0_is_int2fp = (rf0_uop_q.uop_class == UOP_FP) && is_int2fp_op_b(rf0_uop_q.sub_op);

    logic        fconv_fprf_wb_valid;
    logic [63:0] fconv_fprf_wb_data;
    fpreg_t      fconv_fprf_wb_prd_fp;
    rob_idx_t    fconv_fprf_wb_rob_idx;
    rob_epoch_t  fconv_fprf_wb_rob_epoch;
    logic [4:0]  fconv_fprf_wb_fflags;

    logic        fconv_prf_wb_valid;
    logic [63:0] fconv_prf_wb_data;
    preg_t       fconv_prf_wb_pnew;
    rob_idx_t    fconv_prf_wb_rob_idx;
    rob_epoch_t  fconv_prf_wb_rob_epoch;
    logic [4:0]  fconv_prf_wb_fflags;

    fursoy_s1_fconv u_fconv (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .flush_valid_i      (flush_valid_i),
        .recover_valid_i    (internal_recover_valid),
        .recover_rob_idx_i  (internal_recover_rob_idx),
        .rob_head_i         (rob_head_i),

        .fcsr_frm_i         (fcsr_frm_i),

        .p4_req_valid_i     (fp_rf_valid_q && !fp_rf_squashed && is_fconv_p4_op(fp_rf_uop_q.sub_op)),
        .p4_req_subop_i     (fp_rf_uop_q.sub_op),
        .p4_req_frm_i       (fp_rf_uop_q.frm),
        .p4_req_rs1_fp_data_i(r0_fp_data),
        .p4_req_rs2_fp_data_i(r1_fp_data),
        .p4_req_prd_fp_i    (fp_rf_uop_q.prd_fp),
        .p4_req_pnew_i      (fp_rf_uop_q.pnew),
        .p4_req_fp_dest_valid_i(fp_rf_uop_q.fp_dest_valid),
        .p4_req_rob_idx_i   (fp_rf_uop_q.rob_idx),
        .p4_req_rob_epoch_i (fp_rf_uop_q.rob_epoch),

        .int2fp_req_valid_i (rf0_valid_q && !ex0_squashed && p0_is_int2fp),
        .int2fp_req_subop_i (rf0_uop_q.sub_op),
        .int2fp_req_frm_i   (rf0_uop_q.frm),
        .int2fp_req_int_data_i(p0_op_a),
        .int2fp_req_prd_fp_i(rf0_uop_q.prd_fp),
        .int2fp_req_rob_idx_i(rf0_uop_q.rob_idx),
        .int2fp_req_rob_epoch_i(rf0_uop_q.rob_epoch),

        .int_wb_busy_i      (p0_wb_valid),
        .fprf_wb_busy_i     (fma_out_valid || fdiv_out_valid),

        .fprf_wb_valid_o    (fconv_fprf_wb_valid),
        .fprf_wb_data_o     (fconv_fprf_wb_data),
        .fprf_wb_prd_fp_o   (fconv_fprf_wb_prd_fp),
        .fprf_wb_rob_idx_o  (fconv_fprf_wb_rob_idx),
        .fprf_wb_rob_epoch_o(fconv_fprf_wb_rob_epoch),
        .fprf_wb_fflags_o   (fconv_fprf_wb_fflags),

        .prf_wb_valid_o     (fconv_prf_wb_valid),
        .prf_wb_data_o      (fconv_prf_wb_data),
        .prf_wb_pnew_o      (fconv_prf_wb_pnew),
        .prf_wb_rob_idx_o   (fconv_prf_wb_rob_idx),
        .prf_wb_rob_epoch_o (fconv_prf_wb_rob_epoch),
        .prf_wb_fflags_o    (fconv_prf_wb_fflags),

        .fprf_busy_o        (fconv_fprf_busy),
        .prf_busy_o         (fconv_prf_busy)
    );

    // Port 0 / F2I Effective PRF Writeback Arbitration (Priority: ALU0 > F2I)
    always_comb begin
        if (p0_wb_valid) begin
            p0_eff_wb_valid        = 1'b1;
            p0_eff_wb_data         = p0_wb_data;
            p0_eff_wb_pnew         = p0_wb_pnew;
            p0_eff_wb_rob_idx      = p0_wb_rob_idx;
            p0_eff_wb_rob_epoch    = p0_wb_rob_epoch;
            p0_eff_wb_mispredict   = p0_wb_mispredict;
            p0_eff_wb_exception    = p0_wb_exception;
            p0_eff_wb_cause        = p0_wb_cause;
            p0_eff_wb_fflags       = 5'd0;
            p0_eff_wb_target       = p0_wb_target;
            p0_eff_wb_actual_taken = p0_wb_actual_taken;
            p0_eff_wb_pc           = p0_wb_pc;
            p0_eff_wb_br_type      = p0_wb_br_type;
            p0_eff_wb_ghr          = p0_wb_ghr;
            p0_eff_wb_is_ctrl      = p0_wb_is_ctrl;
        end else if (fconv_prf_wb_valid) begin
            p0_eff_wb_valid        = 1'b1;
            p0_eff_wb_data         = fconv_prf_wb_data;
            p0_eff_wb_pnew         = fconv_prf_wb_pnew;
            p0_eff_wb_rob_idx      = fconv_prf_wb_rob_idx;
            p0_eff_wb_rob_epoch    = fconv_prf_wb_rob_epoch;
            p0_eff_wb_mispredict   = 1'b0;
            p0_eff_wb_exception    = 1'b0;
            p0_eff_wb_cause        = 5'd0;
            p0_eff_wb_fflags       = fconv_prf_wb_fflags;
            p0_eff_wb_target       = 64'd0;
            p0_eff_wb_actual_taken = 1'b0;
            p0_eff_wb_pc           = 64'd0;
            p0_eff_wb_br_type      = BR_TYPE_COND;
            p0_eff_wb_ghr          = '0;
            p0_eff_wb_is_ctrl      = 1'b0;
        end else begin
            p0_eff_wb_valid        = 1'b0;
            p0_eff_wb_data         = 64'd0;
            p0_eff_wb_pnew         = 7'd0;
            p0_eff_wb_rob_idx      = '0;
            p0_eff_wb_rob_epoch    = '0;
            p0_eff_wb_mispredict   = 1'b0;
            p0_eff_wb_exception    = 1'b0;
            p0_eff_wb_cause        = 5'd0;
            p0_eff_wb_fflags       = 5'd0;
            p0_eff_wb_target       = 64'd0;
            p0_eff_wb_actual_taken = 1'b0;
            p0_eff_wb_pc           = 64'd0;
            p0_eff_wb_br_type      = BR_TYPE_COND;
            p0_eff_wb_ghr          = '0;
            p0_eff_wb_is_ctrl      = 1'b0;
        end
    end

    // Port 4 FPRF Writeback Arbitration (Priority: FMA > FDIV > FCONV > test_inject)
    always_comb begin
        if (fma_out_valid) begin
            p4_fprf_wb_valid     = 1'b1;
            p4_fprf_wb_data      = fma_out_data;
            p4_fprf_wb_preg      = fma_out_prd_fp;
            p4_fprf_wb_rob_idx   = fma_out_rob_idx;
            p4_fprf_wb_rob_epoch = fma_out_rob_epoch;
            p4_fprf_wb_fflags    = fma_out_fflags;
        end else if (fdiv_out_valid) begin
            p4_fprf_wb_valid     = 1'b1;
            p4_fprf_wb_data      = fdiv_out_data;
            p4_fprf_wb_preg      = fdiv_out_prd_fp;
            p4_fprf_wb_rob_idx   = fdiv_out_rob_idx;
            p4_fprf_wb_rob_epoch = fdiv_out_rob_epoch;
            p4_fprf_wb_fflags    = fdiv_out_fflags;
        end else if (fconv_fprf_wb_valid) begin
            p4_fprf_wb_valid     = 1'b1;
            p4_fprf_wb_data      = fconv_fprf_wb_data;
            p4_fprf_wb_preg      = fconv_fprf_wb_prd_fp;
            p4_fprf_wb_rob_idx   = fconv_fprf_wb_rob_idx;
            p4_fprf_wb_rob_epoch = fconv_fprf_wb_rob_epoch;
            p4_fprf_wb_fflags    = fconv_fprf_wb_fflags;
        end else if (w0_fp_valid_i) begin
            p4_fprf_wb_valid     = 1'b1;
            p4_fprf_wb_data      = w0_fp_data_i;
            p4_fprf_wb_preg      = w0_fp_paddr_i;
            p4_fprf_wb_rob_idx   = '0;
            p4_fprf_wb_rob_epoch = '0;
            p4_fprf_wb_fflags    = '0;
        end else begin
            p4_fprf_wb_valid     = 1'b0;
            p4_fprf_wb_data      = 64'd0;
            p4_fprf_wb_preg      = 6'd0;
            p4_fprf_wb_rob_idx   = '0;
            p4_fprf_wb_rob_epoch = '0;
            p4_fprf_wb_fflags    = 5'd0;
        end
    end

    // -------------------------------------------------------------------------
    // 6. Upstream Completion Interface (to M1 Substrate)
    // -------------------------------------------------------------------------
    assign comp_valid_o[0]          = p0_eff_wb_valid && !flush_valid_i;
    assign comp_rob_idx_o[0]        = p0_eff_wb_rob_idx;
    assign comp_epoch_o[0]          = p0_eff_wb_rob_epoch;
    assign comp_preg_o[0]           = p0_eff_wb_pnew;
    assign comp_branch_mispred_o[0] = p0_eff_wb_mispredict && !p0_eff_wb_exception;
    assign comp_exception_o[0]      = p0_eff_wb_exception;
    assign comp_cause_o[0]          = p0_eff_wb_cause;
    assign comp_fflags_o[0]         = p0_eff_wb_fflags;

    assign comp_valid_o[1]          = p1_wb_valid && !flush_valid_i;
    assign comp_rob_idx_o[1]        = p1_wb_rob_idx;
    assign comp_epoch_o[1]          = p1_wb_rob_epoch;
    assign comp_preg_o[1]           = p1_wb_pnew;
    assign comp_branch_mispred_o[1] = 1'b0;
    assign comp_exception_o[1]      = 1'b0;
    assign comp_cause_o[1]          = 5'd0;
    assign comp_fflags_o[1]         = 5'd0;

    // Port 2 (LSU AGU0) Completion
    assign comp_valid_o[2]          = p2_comp_valid && !flush_valid_i;
    assign comp_rob_idx_o[2]        = p2_comp_rob_idx;
    assign comp_epoch_o[2]          = p2_comp_epoch;
    assign comp_preg_o[2]           = p2_comp_is_fp ? 7'd0 : p2_comp_preg;
    assign comp_branch_mispred_o[2] = 1'b0;
    assign comp_exception_o[2]      = p2_comp_exception;
    assign comp_cause_o[2]          = p2_comp_cause;
    assign comp_fflags_o[2]         = 5'd0;

    // Port 3 (LSU AGU1) Completion (§5.1, PROP_M7_10)
    assign comp_valid_o[3]          = p3_comp_valid && !flush_valid_i;
    assign comp_rob_idx_o[3]        = p3_comp_rob_idx;
    assign comp_epoch_o[3]          = p3_comp_epoch;
    assign comp_preg_o[3]           = p3_comp_is_fp ? 7'd0 : p3_comp_preg;
    assign comp_branch_mispred_o[3] = 1'b0;
    assign comp_exception_o[3]      = p3_comp_exception;
    assign comp_cause_o[3]          = p3_comp_cause;
    assign comp_fflags_o[3]         = 5'd0;

    // Port 4 (FP Execution Pipeline) Completion (§6.1, PROP_M8_11)
    assign comp_valid_o[4]          = p4_fprf_wb_valid && !flush_valid_i && !w0_fp_valid_i;
    assign comp_rob_idx_o[4]        = p4_fprf_wb_rob_idx;
    assign comp_epoch_o[4]          = p4_fprf_wb_rob_epoch;
    assign comp_preg_o[4]           = 7'd0;
    assign comp_branch_mispred_o[4] = 1'b0;
    assign comp_exception_o[4]      = 1'b0;
    assign comp_cause_o[4]          = 5'd0;
    assign comp_fflags_o[4]         = p4_fprf_wb_fflags;

    assign comp_fp_wb_valid_o[0]    = p4_fprf_wb_valid && comp_ack_i[4] && !w0_fp_valid_i;
    assign comp_fp_wb_preg_o[0]     = p4_fprf_wb_preg;
    assign comp_fp_wb_valid_o[1]    = p2_fp_wb_valid;
    assign comp_fp_wb_preg_o[1]     = p2_fp_wb_paddr;
    assign comp_fp_wb_valid_o[2]    = p3_fp_wb_valid;
    assign comp_fp_wb_preg_o[2]     = p3_fp_wb_paddr;

    // -------------------------------------------------------------------------
    // 7. Lifetime-Gated Branch Recovery Interface (Section 2.4.3)
    // -------------------------------------------------------------------------
    wire flush_active = flush_valid_i || fl_reconstructing_i;
    wire recover_fire = p0_wb_valid && p0_wb_mispredict && comp_ack_i[0] &&
                        !flush_active && !recovering_i;

    assign recover_valid_o           = recover_fire;
    assign recover_rob_idx_o         = p0_wb_rob_idx;
    assign recover_chkpt_id_o        = p0_wb_chkpt_id;
    assign recover_target_o          = p0_wb_target;
    assign recover_actual_taken_o    = p0_wb_actual_taken;

    assign internal_recover_valid    = recover_fire;
    assign internal_recover_rob_idx  = p0_wb_rob_idx;
    assign internal_recover_chkpt_id = p0_wb_chkpt_id;

    // -------------------------------------------------------------------------
    // 8. Predictor Training Interface (Port 0 Completion)
    // -------------------------------------------------------------------------
    assign train_valid_o         = comp_valid_o[0] && comp_ack_i[0] && !p0_eff_wb_exception && p0_eff_wb_is_ctrl;
    assign train_pc_o            = p0_eff_wb_pc;
    assign train_actual_taken_o  = p0_eff_wb_actual_taken;
    assign train_actual_target_o = p0_eff_wb_target;
    assign train_br_type_o       = p0_eff_wb_br_type;
    assign train_ghr_o           = p0_eff_wb_ghr;

    // -------------------------------------------------------------------------
    // Simulation Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    wire prf_w0_we = p0_eff_wb_valid && comp_ack_i[0] && (p0_eff_wb_pnew != 7'd0);
    wire prf_w1_we = p1_wb_valid && comp_ack_i[1] && (p1_wb_pnew != 7'd0);
    wire prf_w2_we = p2_comp_valid && comp_ack_i[2] && !p2_comp_exception && (p2_comp_preg != 7'd0) && !p2_comp_is_fp;
    logic flush_check_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            flush_check_q <= 1'b0;
        end else begin
            flush_check_q <= flush_valid_i;

            if (!flush_valid_i) begin
                // 1. Stale completion must NEVER write PRF data or trigger recovery
                if (comp_valid_o[0] && !comp_ack_i[0] && recover_valid_o) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] Stale completion on Port 0 triggered branch recovery!");
                end
                if (p0_wb_mispredict && !comp_ack_i[0] && recover_valid_o) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] Stale branch triggered recovery!");
                end
                if (prf_w0_we && !comp_ack_i[0]) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] PRF write on Port 0 without accepted completion!");
                end
                if (prf_w1_we && !comp_ack_i[1]) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] PRF write on Port 1 without accepted completion!");
                end
                if (prf_w2_we && !comp_ack_i[2]) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] PRF write on Port 2 without accepted completion!");
                end
                if (prf_w0_we && (p0_eff_wb_pnew == 7'd0)) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] PRF write to p0 on Port 0!");
                end
                if (prf_w1_we && (p1_wb_pnew == 7'd0)) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] PRF write to p0 on Port 1!");
                end
                if (prf_w2_we && (p2_comp_preg == 7'd0)) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] PRF write to p0 on Port 2!");
                end
                if (p2_comp_exception && comp_ack_i[2] && (p2_comp_preg != 7'd0) && prf_w2_we) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] Faulting load wrote PRF!");
                end

                // 2. Branch recovery must not trigger while older recovery or flush is active
                if (recover_valid_o && (recovering_i || flush_active)) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] Branch recovery fired while recovering_i or flush_active was asserted!");
                end

                // 3. Divider must never accept new op while busy
                if (divider_busy && (rf1_valid_q && p1_is_div && !ex1_squashed)) begin
                    $fatal(1, "[BACKEND ASSERTION FAILED] Divider accepted new operation while busy!");
                end

                // 4. Full flush clears backend valids
                if (flush_check_q) begin
                    if (rf0_valid_q || rf1_valid_q || p0_wb_valid || p1_wb_valid ||
                        (mul_in_flight != 2'd0) || divider_busy || alu1_in_flight ||
                        (diag_valid_mask_o != 16'd0)) begin
                        $fatal(1, "[BACKEND ASSERTION FAILED] Full flush did not clear speculative backend state!");
                    end
                end

                // 5. Accepted uop must allocate required target queue (no dropped uop)
                if (uop0_valid_i && dispatch_ready_o[0]) begin
                    if (uop0_is_mem && !mem_dispatch_ready[0]) begin
                        $fatal(1, "[BACKEND ASSERTION FAILED] Memory uop0 accepted without mem queue ready!");
                    end
                    if (!uop0_is_mem && !int_dispatch_ready[0]) begin
                        $fatal(1, "[BACKEND ASSERTION FAILED] Integer uop0 accepted without int queue ready!");
                    end
                end
                if (uop1_valid_i && dispatch_ready_o[1]) begin
                    if (uop1_is_mem && (uop0_is_mem ? !mem_dispatch_ready[1] : !mem_dispatch_ready[0])) begin
                        $fatal(1, "[BACKEND ASSERTION FAILED] Memory uop1 accepted without mem queue ready!");
                    end
                    if (!uop1_is_mem && (uop0_is_mem ? !int_dispatch_ready[0] : !int_dispatch_ready[1])) begin
                        $fatal(1, "[BACKEND ASSERTION FAILED] Integer uop1 accepted without int queue ready!");
                    end
                end
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_BACKEND_SV
