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

module fursoy_s1_backend
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // -------------------------------------------------------------------------
    // Substrate Flush & Recovery Handshake (M1 Interface)
    // -------------------------------------------------------------------------
    input  logic              flush_valid_i,
    input  logic              fl_reconstructing_i,
    input  logic              recovering_i,        // Active recovery walk in progress
    input  rob_idx_t          rob_head_i,

    // Branch recovery initiation (from Port 0 Branch Unit to M1 Substrate)
    output logic              recover_valid_o,
    output rob_idx_t          recover_rob_idx_o,
    output chkpt_idx_t        recover_chkpt_id_o,

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
    input  chkpt_idx_t        uop0_chkpt_id_i,
    input  logic [63:0]       uop0_pc_i,
    input  logic              uop0_pred_taken_i,
    input  logic [63:0]       uop0_pred_target_i,
    input  logic              uop0_is_branch_i,
    input  logic              uop0_is_jal_i,
    input  logic              uop0_is_jalr_i,

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
    input  chkpt_idx_t        uop1_chkpt_id_i,
    input  logic [63:0]       uop1_pc_i,
    input  logic              uop1_pred_taken_i,
    input  logic [63:0]       uop1_pred_target_i,
    input  logic              uop1_is_branch_i,
    input  logic              uop1_is_jal_i,
    input  logic              uop1_is_jalr_i,

    // -------------------------------------------------------------------------
    // M1 Completion Interface
    // -------------------------------------------------------------------------
    output logic [2:0]        comp_valid_o,
    output rob_idx_t          comp_rob_idx_o       [2:0],
    output rob_epoch_t        comp_epoch_o         [2:0],
    output preg_t             comp_preg_o          [2:0],
    output logic [2:0]        comp_branch_mispred_o,
    output logic [2:0]        comp_exception_o,
    output logic [4:0]        comp_cause_o         [2:0],
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [2:0]        comp_ack_i,
    /* verilator lint_on UNUSEDSIGNAL */

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
    input  logic              ptw_rsp_access_fault_i
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

    // PRF Port 4 & 5 read wires for LSU
    preg_t      r4_paddr, r5_paddr;
    logic [63:0] r4_data,  r5_data;

    // Port 2 LSU Completion wires
    logic        p2_comp_valid;
    rob_idx_t    p2_comp_rob_idx;
    rob_epoch_t  p2_comp_epoch;
    preg_t       p2_comp_preg;
    logic        p2_comp_exception;
    logic [4:0]  p2_comp_cause;
    logic [63:0] p2_wb_data;

    // Dispatch Interface Readiness Combiner
    wire uop0_is_mem = (uop0_class_i == UOP_LOAD) || (uop0_class_i == UOP_STORE) ||
                       (uop0_class_i == UOP_AMO)  || (uop0_class_i == UOP_FENCE);
    wire uop1_is_mem = (uop1_class_i == UOP_LOAD) || (uop1_class_i == UOP_STORE) ||
                       (uop1_class_i == UOP_AMO)  || (uop1_class_i == UOP_FENCE);

    always_comb begin
        dispatch_ready_o[0] = uop0_is_mem ? mem_dispatch_ready[0] : int_dispatch_ready[0];

        if (uop1_is_mem) begin
            dispatch_ready_o[1] = mem_dispatch_ready[1];
        end else begin
            // uop1 is INT: if uop0 is MEM, uop1 is local INT #0, else local INT #1
            dispatch_ready_o[1] = uop0_is_mem ? int_dispatch_ready[0] : int_dispatch_ready[1];
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

        .wb0_valid_i        (p0_wb_valid),
        .wb0_comp_ack_i     (comp_ack_i[0]),
        .wb0_pnew_i         (p0_wb_pnew),

        .wb1_valid_i        (p1_wb_valid),
        .wb1_comp_ack_i     (comp_ack_i[1]),
        .wb1_pnew_i         (p1_wb_pnew),

        .wb2_valid_i        (p2_comp_valid),
        .wb2_comp_ack_i     (comp_ack_i[2]),
        .wb2_comp_exception_i (p2_comp_exception),
        .wb2_pnew_i         (p2_comp_preg),

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

        .w0_valid_i     (p0_wb_valid),
        .w0_comp_ack_i  (comp_ack_i[0]),
        .w0_paddr_i     (p0_wb_pnew),
        .w0_data_i      (p0_wb_data),

        .w1_valid_i     (p1_wb_valid),
        .w1_comp_ack_i  (comp_ack_i[1]),
        .w1_paddr_i     (p1_wb_pnew),
        .w1_data_i      (p1_wb_data),

        .r4_paddr_i     (r4_paddr),
        .r4_data_o      (r4_data),
        .r5_paddr_i     (r5_paddr),
        .r5_data_o      (r5_data),

        .w2_valid_i     (p2_comp_valid),
        .w2_comp_ack_i  (comp_ack_i[2]),
        .w2_comp_exception_i (p2_comp_exception),
        .w2_paddr_i     (p2_comp_preg),
        .w2_data_i      (p2_wb_data),

        .probe_paddr_i  (probe_paddr_i),
        .probe_pdata_o  (probe_pdata_o)
    );

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
        input logic [63:0] wb2_d
    );
        if (prs == 7'd0) begin
            return 64'd0;
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
            p0_op_a = get_operand(rf0_uop_q.prs1, r0_data, p0_wb_valid, comp_ack_i[0], p0_wb_pnew, p0_wb_data, p1_wb_valid, comp_ack_i[1], p1_wb_pnew, p1_wb_data, p2_comp_valid, comp_ack_i[2], p2_comp_exception, p2_comp_preg, p2_wb_data);
        end
        if (rf0_uop_q.use_imm && (rf0_uop_q.uop_class != UOP_BRANCH)) begin
            p0_op_b = rf0_uop_q.imm;
        end else begin
            p0_op_b = get_operand(rf0_uop_q.prs2, r1_data, p0_wb_valid, comp_ack_i[0], p0_wb_pnew, p0_wb_data, p1_wb_valid, comp_ack_i[1], p1_wb_pnew, p1_wb_data, p2_comp_valid, comp_ack_i[2], p2_comp_exception, p2_comp_preg, p2_wb_data);
        end
    end

    // Port 1 Operands
    logic [63:0] p1_op_a, p1_op_b;
    always_comb begin
        if ((rf1_uop_q.uop_class == UOP_ALU_INT) && (rf1_uop_q.sub_op == ALU_AUIPC)) begin
            p1_op_a = rf1_uop_q.pc;
        end else begin
            p1_op_a = get_operand(rf1_uop_q.prs1, r2_data, p0_wb_valid, comp_ack_i[0], p0_wb_pnew, p0_wb_data, p1_wb_valid, comp_ack_i[1], p1_wb_pnew, p1_wb_data, p2_comp_valid, comp_ack_i[2], p2_comp_exception, p2_comp_preg, p2_wb_data);
        end
        if (rf1_uop_q.use_imm) begin
            p1_op_b = rf1_uop_q.imm;
        end else begin
            p1_op_b = get_operand(rf1_uop_q.prs2, r3_data, p0_wb_valid, comp_ack_i[0], p0_wb_pnew, p0_wb_data, p1_wb_valid, comp_ack_i[1], p1_wb_pnew, p1_wb_data, p2_comp_valid, comp_ack_i[2], p2_comp_exception, p2_comp_preg, p2_wb_data);
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

    wire [63:0] p0_ex_data = p0_is_ctrl ? br_link_result : alu0_result;

    // Port 0 WB Pipeline Register (EX -> WB)
    wire ex0_squashed = internal_recover_valid && (rob_dist(rf0_uop_q.rob_idx, rob_head_i) > rob_dist(internal_recover_rob_idx, rob_head_i));

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            p0_wb_valid      <= 1'b0;
            p0_wb_data       <= 64'd0;
            p0_wb_pnew       <= 7'd0;
            p0_wb_rob_idx    <= '0;
            p0_wb_rob_epoch  <= '0;
            p0_wb_chkpt_id   <= '0;
            p0_wb_mispredict <= 1'b0;
        end else begin
            if (rf0_valid_q && !ex0_squashed) begin
                p0_wb_valid      <= 1'b1;
                p0_wb_data       <= p0_ex_data;
                p0_wb_pnew       <= rf0_uop_q.pnew;
                p0_wb_rob_idx    <= rf0_uop_q.rob_idx;
                p0_wb_rob_epoch  <= rf0_uop_q.rob_epoch;
                p0_wb_chkpt_id   <= rf0_uop_q.chkpt_id;
                p0_wb_mispredict <= (rf0_uop_q.uop_class == UOP_BRANCH) ? br_mispredict : 1'b0;
            end else if (test_inject_valid_i) begin
                p0_wb_valid      <= 1'b1;
                p0_wb_data       <= test_inject_data_i;
                p0_wb_pnew       <= test_inject_pnew_i;
                p0_wb_rob_idx    <= test_inject_rob_idx_i;
                p0_wb_rob_epoch  <= test_inject_rob_epoch_i;
                p0_wb_chkpt_id   <= '0;
                p0_wb_mispredict <= test_inject_mispredict_i;
            end else begin
                p0_wb_valid <= 1'b0;
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
        .wb_rob_epoch_o     (p1_wb_rob_epoch)
    );

    // -------------------------------------------------------------------------
    // 5. Load/Store Unit (LSU) Subsystem — Milestone 3
    // -------------------------------------------------------------------------
    fursoy_s1_lsu u_lsu (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),
        .flush_valid_i           (flush_valid_i),
        .recover_valid_i         (internal_recover_valid),
        .recover_rob_idx_i       (internal_recover_rob_idx),
        .rob_head_i              (rob_head_i),

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
        .uop0_pc_i               (uop0_pc_i),

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
        .uop1_pc_i               (uop1_pc_i),

        .r4_paddr_o              (r4_paddr),
        .r4_data_i               (r4_data),
        .r5_paddr_o              (r5_paddr),
        .r5_data_i               (r5_data),

        .wb0_valid_i             (p0_wb_valid),
        .wb0_comp_ack_i          (comp_ack_i[0]),
        .wb0_pnew_i              (p0_wb_pnew),
        .wb0_data_i              (p0_wb_data),

        .wb1_valid_i             (p1_wb_valid),
        .wb1_comp_ack_i          (comp_ack_i[1]),
        .wb1_pnew_i              (p1_wb_pnew),
        .wb1_data_i              (p1_wb_data),

        .wb2_valid_i             (p2_comp_valid),
        .wb2_comp_ack_i          (comp_ack_i[2]),
        .wb2_comp_exception_i    (p2_comp_exception),
        .wb2_pnew_i              (p2_comp_preg),
        .wb2_data_i              (p2_wb_data),

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
        .ptw_rsp_access_fault_i  (ptw_rsp_access_fault_i)
    );

    // -------------------------------------------------------------------------
    // 6. Upstream Completion Interface (to M1 Substrate)
    // -------------------------------------------------------------------------
    assign comp_valid_o[0]          = p0_wb_valid && !flush_valid_i;
    assign comp_rob_idx_o[0]        = p0_wb_rob_idx;
    assign comp_epoch_o[0]          = p0_wb_rob_epoch;
    assign comp_preg_o[0]           = p0_wb_pnew;
    assign comp_branch_mispred_o[0] = p0_wb_mispredict;
    assign comp_exception_o[0]      = 1'b0;
    assign comp_cause_o[0]          = 5'd0;

    assign comp_valid_o[1]          = p1_wb_valid && !flush_valid_i;
    assign comp_rob_idx_o[1]        = p1_wb_rob_idx;
    assign comp_epoch_o[1]          = p1_wb_rob_epoch;
    assign comp_preg_o[1]           = p1_wb_pnew;
    assign comp_branch_mispred_o[1] = 1'b0;
    assign comp_exception_o[1]      = 1'b0;
    assign comp_cause_o[1]          = 5'd0;

    // Port 2 (LSU) Completion
    assign comp_valid_o[2]          = p2_comp_valid && !flush_valid_i;
    assign comp_rob_idx_o[2]        = p2_comp_rob_idx;
    assign comp_epoch_o[2]          = p2_comp_epoch;
    assign comp_preg_o[2]           = p2_comp_preg;
    assign comp_branch_mispred_o[2] = 1'b0;
    assign comp_exception_o[2]      = p2_comp_exception;
    assign comp_cause_o[2]          = p2_comp_cause;

    // -------------------------------------------------------------------------
    // 7. Lifetime-Gated Branch Recovery Interface (Section 2.4.3)
    // -------------------------------------------------------------------------
    wire flush_active = flush_valid_i || fl_reconstructing_i;
    wire recover_fire = comp_valid_o[0] && comp_branch_mispred_o[0] && comp_ack_i[0] &&
                        !flush_active && !recovering_i;

    assign recover_valid_o           = recover_fire;
    assign recover_rob_idx_o         = p0_wb_rob_idx;
    assign recover_chkpt_id_o        = p0_wb_chkpt_id;

    assign internal_recover_valid    = recover_fire;
    assign internal_recover_rob_idx  = p0_wb_rob_idx;
    assign internal_recover_chkpt_id = p0_wb_chkpt_id;

    // -------------------------------------------------------------------------
    // Simulation Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    wire prf_w0_we = p0_wb_valid && comp_ack_i[0] && (p0_wb_pnew != 7'd0);
    wire prf_w1_we = p1_wb_valid && comp_ack_i[1] && (p1_wb_pnew != 7'd0);
    wire prf_w2_we = p2_comp_valid && comp_ack_i[2] && !p2_comp_exception && (p2_comp_preg != 7'd0);
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
                if (prf_w0_we && (p0_wb_pnew == 7'd0)) begin
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
