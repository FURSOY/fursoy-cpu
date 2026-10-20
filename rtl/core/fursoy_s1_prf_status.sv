`ifndef FURSOY_S1_PRF_STATUS_SV
`define FURSOY_S1_PRF_STATUS_SV

// =============================================================================
// Fursoy Slice-1 PRF Readiness & Allocation Metadata Module — Milestone 1
// =============================================================================
// Maintains readiness metadata for all 80 physical registers (p0..p79).
// - p0 is hardwired permanently ready.
// - Destination allocation clears readiness bit.
// - Up to 3 execution writeback ports set readiness bit.
// - Reclamation / flush marks restored registers ready.
// - Combinational readiness query for 2-wide rename stage.
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_prf_status
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned PRF_CAPACITY = PRF_SIZE // 80 registers
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // -------------------------------------------------------------------------
    // Allocation Interface (Clears Readiness)
    // -------------------------------------------------------------------------
    input  logic [1:0]             alloc_valid_i,
    input  preg_t                  alloc_preg_i [1:0],

    // -------------------------------------------------------------------------
    // Execution Writeback Completion Interface (Sets Readiness)
    // -------------------------------------------------------------------------
    // 4 writeback ports corresponding to Port 0, Port 1, Port 2, Port 3
    input  logic [3:0]             wb_valid_i,
    input  preg_t                  wb_preg_i [3:0],

    // -------------------------------------------------------------------------
    // Reclamation Interface (Squash Pnew & Flush restore readiness)
    // -------------------------------------------------------------------------
    input  logic [1:0]             reclaim_valid_i,
    input  preg_t                  reclaim_preg_i [1:0],
    input  logic                   flush_valid_i,

    // -------------------------------------------------------------------------
    // Rename Source Readiness Query Interface
    // -------------------------------------------------------------------------
    input  preg_t                  uop0_rs1_preg_i,
    input  preg_t                  uop0_rs2_preg_i,
    input  preg_t                  uop1_rs1_preg_i,
    input  preg_t                  uop1_rs2_preg_i,

    input  logic                   uop1_rs1_raw_uop0_i,
    input  logic                   uop1_rs2_raw_uop0_i,

    output logic                   uop0_rs1_ready_o,
    output logic                   uop0_rs2_ready_o,
    output logic                   uop1_rs1_ready_o,
    output logic                   uop1_rs2_ready_o,

    // -------------------------------------------------------------------------
    // Diagnostics & Full Status Export
    // -------------------------------------------------------------------------
    output logic [PRF_CAPACITY-1:0] prf_ready_o
);

    // -------------------------------------------------------------------------
    // Readiness Bitmask
    // -------------------------------------------------------------------------
    logic [PRF_CAPACITY-1:0] ready_q;

    // -------------------------------------------------------------------------
    // Combinational Source Readiness Lookups
    // -------------------------------------------------------------------------
    assign uop0_rs1_ready_o = (uop0_rs1_preg_i == 7'd0) || ready_q[uop0_rs1_preg_i];
    assign uop0_rs2_ready_o = (uop0_rs2_preg_i == 7'd0) || ready_q[uop0_rs2_preg_i];

    // uop1: if intra-group RAW from uop0, uop0 was just allocated this cycle
    // and cannot be completed, so readiness is strictly 0!
    assign uop1_rs1_ready_o = uop1_rs1_raw_uop0_i ? 1'b0 :
                              (uop1_rs1_preg_i == 7'd0) || ready_q[uop1_rs1_preg_i];

    assign uop1_rs2_ready_o = uop1_rs2_raw_uop0_i ? 1'b0 :
                              (uop1_rs2_preg_i == 7'd0) || ready_q[uop1_rs2_preg_i];

    assign prf_ready_o      = ready_q;

    // -------------------------------------------------------------------------
    // Sequential Readiness Update
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ready_q <= '1; // Reset: all registers marked ready; p0 permanently ready
        end else if (flush_valid_i) begin
            // On full flush, all registers marked ready
            ready_q <= '1;
        end else begin
            // 1. Reclaimed registers marked ready
            if (reclaim_valid_i[0] && (reclaim_preg_i[0] != 7'd0)) begin
                ready_q[reclaim_preg_i[0]] <= 1'b1;
            end
            if (reclaim_valid_i[1] && (reclaim_preg_i[1] != 7'd0)) begin
                ready_q[reclaim_preg_i[1]] <= 1'b1;
            end

            // 2. Execution writeback completion sets ready
            for (int unsigned w = 0; w < 4; w++) begin
                if (wb_valid_i[w] && (wb_preg_i[w] != 7'd0)) begin
                    ready_q[wb_preg_i[w]] <= 1'b1;
                end
            end

            // 3. New allocations clear ready bit
            if (alloc_valid_i[0] && (alloc_preg_i[0] != 7'd0)) begin
                ready_q[alloc_preg_i[0]] <= 1'b0;
            end
            if (alloc_valid_i[1] && (alloc_preg_i[1] != 7'd0)) begin
                ready_q[alloc_preg_i[1]] <= 1'b0;
            end

            // p0 is permanently ready
            ready_q[0] <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Simulation Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            if (ready_q[0] != 1'b1) begin
                $fatal(1, "[PRF ASSERTION FAILED] p0 readiness bit cleared!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_PRF_STATUS_SV
