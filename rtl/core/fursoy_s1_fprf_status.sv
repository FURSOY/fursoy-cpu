`ifndef FURSOY_S1_FPRF_STATUS_SV
`define FURSOY_S1_FPRF_STATUS_SV

// =============================================================================
// Fursoy Slice-1 FPRF Readiness & Allocation Metadata Module — Milestone 8
// =============================================================================
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 5.2
//
// Maintains readiness metadata for all 64 floating-point physical registers (fp0..fp63).
// - Destination allocation clears readiness bit.
// - Up to 3 execution writeback ports set readiness bit (w0_fp, w1_fp, w2_fp).
// - Reclamation / flush marks restored registers ready.
// - Combinational readiness query for 2-wide rename stage (fs1, fs2, fs3 per uop).
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_fprf_status
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned PRF_CAPACITY = FPRF_SIZE // 64 registers
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // -------------------------------------------------------------------------
    // Allocation Interface (Clears Readiness)
    // -------------------------------------------------------------------------
    input  logic [1:0]             alloc_valid_i,
    input  fpreg_t                 alloc_preg_i [1:0],

    // -------------------------------------------------------------------------
    // Execution Writeback Completion Interface (Sets Readiness)
    // -------------------------------------------------------------------------
    // 3 writeback ports corresponding to w0_fp (P4 FMA/FDIV), w1_fp (P2 AGU0), w2_fp (P3 AGU1)
    input  logic [2:0]             wb_valid_i,
    input  fpreg_t                 wb_preg_i [2:0],

    // -------------------------------------------------------------------------
    // Reclamation Interface (Squash Pnew & Flush restore readiness)
    // -------------------------------------------------------------------------
    input  logic [1:0]             reclaim_valid_i,
    input  fpreg_t                 reclaim_preg_i [1:0],
    input  logic                   flush_valid_i,

    // -------------------------------------------------------------------------
    // Rename Source Readiness Query Interface
    // -------------------------------------------------------------------------
    input  fpreg_t                 uop0_fs1_preg_i,
    input  fpreg_t                 uop0_fs2_preg_i,
    input  fpreg_t                 uop0_fs3_preg_i,

    input  fpreg_t                 uop1_fs1_preg_i,
    input  fpreg_t                 uop1_fs2_preg_i,
    input  fpreg_t                 uop1_fs3_preg_i,

    input  logic                   uop1_fs1_raw_uop0_i,
    input  logic                   uop1_fs2_raw_uop0_i,
    input  logic                   uop1_fs3_raw_uop0_i,

    output logic                   uop0_fs1_ready_o,
    output logic                   uop0_fs2_ready_o,
    output logic                   uop0_fs3_ready_o,

    output logic                   uop1_fs1_ready_o,
    output logic                   uop1_fs2_ready_o,
    output logic                   uop1_fs3_ready_o,

    // -------------------------------------------------------------------------
    // Diagnostics & Full Status Export
    // -------------------------------------------------------------------------
    output logic [PRF_CAPACITY-1:0] ready_mask_fp_o
);

    // -------------------------------------------------------------------------
    // Readiness Bitmask
    // -------------------------------------------------------------------------
    logic [PRF_CAPACITY-1:0] ready_q;

    // -------------------------------------------------------------------------
    // Combinational Source Readiness Lookups
    // -------------------------------------------------------------------------
    assign uop0_fs1_ready_o = ready_q[uop0_fs1_preg_i];
    assign uop0_fs2_ready_o = ready_q[uop0_fs2_preg_i];
    assign uop0_fs3_ready_o = ready_q[uop0_fs3_preg_i];

    // uop1: if intra-group RAW from uop0, uop0 was just allocated this cycle
    // and cannot be completed, so readiness is strictly 0!
    assign uop1_fs1_ready_o = uop1_fs1_raw_uop0_i ? 1'b0 : ready_q[uop1_fs1_preg_i];
    assign uop1_fs2_ready_o = uop1_fs2_raw_uop0_i ? 1'b0 : ready_q[uop1_fs2_preg_i];
    assign uop1_fs3_ready_o = uop1_fs3_raw_uop0_i ? 1'b0 : ready_q[uop1_fs3_preg_i];

    assign ready_mask_fp_o  = ready_q;

    // -------------------------------------------------------------------------
    // Sequential Readiness Update
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ready_q <= '1; // Reset: all 64 registers marked ready
        end else if (flush_valid_i) begin
            ready_q <= '1; // On full flush, all registers restored ready
        end else begin
            // 1. Reclaimed registers marked ready (from squashed allocations)
            if (reclaim_valid_i[0]) begin
                ready_q[reclaim_preg_i[0]] <= 1'b1;
            end
            if (reclaim_valid_i[1]) begin
                ready_q[reclaim_preg_i[1]] <= 1'b1;
            end

            // 2. Writebacks mark completing registers ready
            if (wb_valid_i[0]) begin
                ready_q[wb_preg_i[0]] <= 1'b1;
            end
            if (wb_valid_i[1]) begin
                ready_q[wb_preg_i[1]] <= 1'b1;
            end
            if (wb_valid_i[2]) begin
                ready_q[wb_preg_i[2]] <= 1'b1;
            end

            // 3. New allocations mark destination registers not ready (busy)
            if (alloc_valid_i[0]) begin
                ready_q[alloc_preg_i[0]] <= 1'b0;
            end
            if (alloc_valid_i[1]) begin
                ready_q[alloc_preg_i[1]] <= 1'b0;
            end
        end
    end

endmodule

`endif // FURSOY_S1_FPRF_STATUS_SV
