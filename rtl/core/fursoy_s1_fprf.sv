`ifndef FURSOY_S1_FPRF_SV
`define FURSOY_S1_FPRF_SV

// =============================================================================
// Fursoy Slice-1 64-bit Floating-Point Physical Register File (FPRF) — Milestone 8
// =============================================================================
// Dedicated 64-entry x 64-bit Floating-Point Physical Register File array.
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 5.1, Section 9.1
//
// Invariants:
// - Physical register array: 64 entries x 64 bits (FPRF_SIZE = 64).
// - f0 is NOT hardwired to zero; it is a general-purpose register holding arbitrary values (PROP_M8_02, PROP_M8_06).
// - 4 Read Ports:
//     * Read Port 0: Port 4 FMA rs1
//     * Read Port 1: Port 4 FMA rs2 / FDIV rs1
//     * Read Port 2: Port 4 FMA rs3 / FDIV rs2
//     * Read Port 3: Port 2 Store Data (FSW/FSD) / Cross-domain Move
// - 3 Writeback Ports:
//     * Write Port 0: Port 4 FMA / FDIV / FCONV writeback
//     * Write Port 1: Port 2 AGU0 / L1D Load Data writeback (FLW/FLD)
//     * Write Port 2: Port 3 AGU1 / L1D Load Data writeback (FLW/FLD)
// - Synchronous write on posedge clk_i.
// - Combinational read with internal same-cycle writeback bypassing (w0 > w1 > w2).
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_fprf
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // -------------------------------------------------------------------------
    // 4 Read Ports (Register Fetch Stage: RF)
    // -------------------------------------------------------------------------
    // Read Port 0: Port 4 FMA rs1
    input  fpreg_t            raddr0_fp_i,
    output logic [63:0]       rdata0_fp_o,

    // Read Port 1: Port 4 FMA rs2 / FDIV rs1
    input  fpreg_t            raddr1_fp_i,
    output logic [63:0]       rdata1_fp_o,

    // Read Port 2: Port 4 FMA rs3 / FDIV rs2
    input  fpreg_t            raddr2_fp_i,
    output logic [63:0]       rdata2_fp_o,

    // Read Port 3: Port 2 Store Data (FSW/FSD) / Cross-domain Move
    input  fpreg_t            raddr3_fp_i,
    output logic [63:0]       rdata3_fp_o,

    // -------------------------------------------------------------------------
    // 3 Writeback Ports (Validated Writeback Stage: WB)
    // -------------------------------------------------------------------------
    // Port 4 Execution Writeback (FMA / FDIV / FCONV)
    input  logic              w0_valid_i,
    input  fpreg_t            w0_paddr_i,
    input  logic [63:0]       w0_data_i,

    // Port 2 AGU0 / L1D Load Writeback (FLW / FLD)
    input  logic              w1_valid_i,
    input  fpreg_t            w1_paddr_i,
    input  logic [63:0]       w1_data_i,

    // Port 3 AGU1 / L1D Load Writeback (FLW / FLD)
    input  logic              w2_valid_i,
    input  fpreg_t            w2_paddr_i,
    input  logic [63:0]       w2_data_i,

    // -------------------------------------------------------------------------
    // Testbench / Diagnostics Read Probe Port
    // -------------------------------------------------------------------------
    input  fpreg_t            probe_paddr_i,
    output logic [63:0]       probe_pdata_o
);

    // -------------------------------------------------------------------------
    // Storage Array (64 entries x 64 bits)
    // -------------------------------------------------------------------------
    logic [63:0] mem_q [FPRF_SIZE];

    // -------------------------------------------------------------------------
    // Synchronous Array Write
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            /* verilator lint_off BLKSEQ */
            for (int unsigned i = 0; i < FPRF_SIZE; i++) begin
                mem_q[i] = 64'd0;
            end
            /* verilator lint_on BLKSEQ */
        end else begin
            // Port 4 Execution writeback
            if (w0_valid_i) begin
                mem_q[w0_paddr_i] <= w0_data_i;
            end
            // Port 2 AGU0 Load writeback
            if (w1_valid_i) begin
                mem_q[w1_paddr_i] <= w1_data_i;
            end
            // Port 3 AGU1 Load writeback
            if (w2_valid_i) begin
                mem_q[w2_paddr_i] <= w2_data_i;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read Logic with Internal Same-Cycle Bypass from Active Writebacks
    // Bypass priority: w0 (Port 4 execution) > w1 (AGU0 load) > w2 (AGU1 load)
    // -------------------------------------------------------------------------
    function automatic logic [63:0] read_fprf(
        input fpreg_t      raddr,
        input logic        we0,
        input fpreg_t      waddr0,
        input logic [63:0] wdata0,
        input logic        we1,
        input fpreg_t      waddr1,
        input logic [63:0] wdata1,
        input logic        we2,
        input fpreg_t      waddr2,
        input logic [63:0] wdata2
    );
        if (we0 && (waddr0 == raddr)) begin
            return wdata0;
        end else if (we1 && (waddr1 == raddr)) begin
            return wdata1;
        end else if (we2 && (waddr2 == raddr)) begin
            return wdata2;
        end else begin
            return mem_q[raddr];
        end
    endfunction

    assign rdata0_fp_o = read_fprf(raddr0_fp_i, w0_valid_i, w0_paddr_i, w0_data_i, w1_valid_i, w1_paddr_i, w1_data_i, w2_valid_i, w2_paddr_i, w2_data_i);
    assign rdata1_fp_o = read_fprf(raddr1_fp_i, w0_valid_i, w0_paddr_i, w0_data_i, w1_valid_i, w1_paddr_i, w1_data_i, w2_valid_i, w2_paddr_i, w2_data_i);
    assign rdata2_fp_o = read_fprf(raddr2_fp_i, w0_valid_i, w0_paddr_i, w0_data_i, w1_valid_i, w1_paddr_i, w1_data_i, w2_valid_i, w2_paddr_i, w2_data_i);
    assign rdata3_fp_o = read_fprf(raddr3_fp_i, w0_valid_i, w0_paddr_i, w0_data_i, w1_valid_i, w1_paddr_i, w1_data_i, w2_valid_i, w2_paddr_i, w2_data_i);

    assign probe_pdata_o = read_fprf(probe_paddr_i, w0_valid_i, w0_paddr_i, w0_data_i, w1_valid_i, w1_paddr_i, w1_data_i, w2_valid_i, w2_paddr_i, w2_data_i);

endmodule

`endif // FURSOY_S1_FPRF_SV
