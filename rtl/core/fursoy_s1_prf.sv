`ifndef FURSOY_S1_PRF_SV
`define FURSOY_S1_PRF_SV

// =============================================================================
// Fursoy Slice-1 64-bit Physical Register File (PRF) Data Storage — Milestone 2
// =============================================================================
// Logical 4R2W Physical Register File array (80 x 64-bit registers).
// Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.1
//
// Invariants:
// - Physical register p0 unconditionally evaluates to 64'd0.
// - Writes to p0 are strictly suppressed.
// - PRF data write enable is strictly lifetime-gated by M1 completion ack:
//     prf_we[w] = wb_valid[w] && comp_ack[w] && (wb_pnew[w] != p0)
// - Stale completions rejected by M1 (comp_ack == 0) never modify PRF data.
// =============================================================================

module fursoy_s1_prf
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // -------------------------------------------------------------------------
    // 6 Read Ports (Register Fetch Stage: RF)
    // -------------------------------------------------------------------------
    // Port 0 Operand A & B
    input  preg_t             r0_paddr_i,
    output logic [63:0]       r0_data_o,

    input  preg_t             r1_paddr_i,
    output logic [63:0]       r1_data_o,

    // Port 1 Operand A & B
    input  preg_t             r2_paddr_i,
    output logic [63:0]       r2_data_o,

    input  preg_t             r3_paddr_i,
    output logic [63:0]       r3_data_o,

    // Port 2 Base Address (R4) & Store Data (R5)
    input  preg_t             r4_paddr_i,
    output logic [63:0]       r4_data_o,

    input  preg_t             r5_paddr_i,
    output logic [63:0]       r5_data_o,

    // Port 3 Base Address (R6 — Milestone 7 Phase A)
    input  preg_t             r6_paddr_i,
    output logic [63:0]       r6_data_o,

    // -------------------------------------------------------------------------
    // 4 Writeback Ports (Validated Writeback Stage: WB)
    // -------------------------------------------------------------------------
    // Port 0 Result Writeback
    input  logic              w0_valid_i,
    input  logic              w0_comp_ack_i,
    input  preg_t             w0_paddr_i,
    input  logic [63:0]       w0_data_i,

    // Port 1 Result Writeback
    input  logic              w1_valid_i,
    input  logic              w1_comp_ack_i,
    input  preg_t             w1_paddr_i,
    input  logic [63:0]       w1_data_i,

    // Port 2 Load Result Writeback (Section 1.2, Section 3.2)
    input  logic              w2_valid_i,
    input  logic              w2_comp_ack_i,
    input  logic              w2_comp_exception_i,
    input  preg_t             w2_paddr_i,
    input  logic [63:0]       w2_data_i,

    // Port 3 Load Result Writeback (Milestone 7 Phase A)
    input  logic              w3_valid_i,
    input  logic              w3_comp_ack_i,
    input  logic              w3_comp_exception_i,
    input  preg_t             w3_paddr_i,
    input  logic [63:0]       w3_data_i,

    // Testbench / Diagnostics Read Probe Port
    input  preg_t             probe_paddr_i,
    output logic [63:0]       probe_pdata_o
);

    // -------------------------------------------------------------------------
    // Storage Array (80 x 64-bit)
    // -------------------------------------------------------------------------
    logic [63:0] mem_q [PRF_SIZE];

    // Gated Write Enables: Strictly lifetime-gated by M1 comp_ack.
    // Faulting loads (w2_comp_exception_i / w3_comp_exception_i == 1) MUST NOT write PRF data (Section 3.2).
    wire w0_we = w0_valid_i && w0_comp_ack_i && (w0_paddr_i != 7'd0) && (w0_paddr_i < PRF_SIZE[6:0]);
    wire w1_we = w1_valid_i && w1_comp_ack_i && (w1_paddr_i != 7'd0) && (w1_paddr_i < PRF_SIZE[6:0]);
    wire w2_we = w2_valid_i && w2_comp_ack_i && !w2_comp_exception_i && (w2_paddr_i != 7'd0) && (w2_paddr_i < PRF_SIZE[6:0]);
    wire w3_we = w3_valid_i && w3_comp_ack_i && !w3_comp_exception_i && (w3_paddr_i != 7'd0) && (w3_paddr_i < PRF_SIZE[6:0]);

    // -------------------------------------------------------------------------
    // Synchronous Array Write
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            /* verilator lint_off BLKSEQ */
            for (int unsigned i = 0; i < PRF_SIZE; i++) begin
                mem_q[i] = 64'd0;
            end
            /* verilator lint_on BLKSEQ */
        end else begin
            // Port 0 write
            if (w0_we) begin
                mem_q[w0_paddr_i] <= w0_data_i;
            end
            // Port 1 write
            if (w1_we) begin
                mem_q[w1_paddr_i] <= w1_data_i;
            end
            // Port 2 write (Load completion)
            if (w2_we) begin
                mem_q[w2_paddr_i] <= w2_data_i;
            end
            // Port 3 write (AGU1 Load completion — Milestone 7 Phase A)
            if (w3_we) begin
                mem_q[w3_paddr_i] <= w3_data_i;
            end
            // Hardwire p0
            mem_q[0] <= 64'd0;
        end
    end

    // -------------------------------------------------------------------------
    // Read Logic with Same-Cycle Bypass from Active Validated Writes
    // -------------------------------------------------------------------------
    function automatic logic [63:0] read_prf(
        input preg_t       raddr,
        input logic        we0,
        input preg_t       waddr0,
        input logic [63:0] wdata0,
        input logic        we1,
        input preg_t       waddr1,
        input logic [63:0] wdata1,
        input logic        we2,
        input preg_t       waddr2,
        input logic [63:0] wdata2,
        input logic        we3,
        input preg_t       waddr3,
        input logic [63:0] wdata3
    );
        if (raddr == 7'd0) begin
            return 64'd0;
        end else if (we3 && (waddr3 == raddr)) begin
            return wdata3;
        end else if (we2 && (waddr2 == raddr)) begin
            return wdata2;
        end else if (we1 && (waddr1 == raddr)) begin
            return wdata1;
        end else if (we0 && (waddr0 == raddr)) begin
            return wdata0;
        end else begin
            return mem_q[raddr];
        end
    endfunction

    assign r0_data_o    = read_prf(r0_paddr_i, w0_we, w0_paddr_i, w0_data_i, w1_we, w1_paddr_i, w1_data_i, w2_we, w2_paddr_i, w2_data_i, w3_we, w3_paddr_i, w3_data_i);
    assign r1_data_o    = read_prf(r1_paddr_i, w0_we, w0_paddr_i, w0_data_i, w1_we, w1_paddr_i, w1_data_i, w2_we, w2_paddr_i, w2_data_i, w3_we, w3_paddr_i, w3_data_i);
    assign r2_data_o    = read_prf(r2_paddr_i, w0_we, w0_paddr_i, w0_data_i, w1_we, w1_paddr_i, w1_data_i, w2_we, w2_paddr_i, w2_data_i, w3_we, w3_paddr_i, w3_data_i);
    assign r3_data_o    = read_prf(r3_paddr_i, w0_we, w0_paddr_i, w0_data_i, w1_we, w1_paddr_i, w1_data_i, w2_we, w2_paddr_i, w2_data_i, w3_we, w3_paddr_i, w3_data_i);
    assign r4_data_o    = read_prf(r4_paddr_i, w0_we, w0_paddr_i, w0_data_i, w1_we, w1_paddr_i, w1_data_i, w2_we, w2_paddr_i, w2_data_i, w3_we, w3_paddr_i, w3_data_i);
    assign r5_data_o    = read_prf(r5_paddr_i, w0_we, w0_paddr_i, w0_data_i, w1_we, w1_paddr_i, w1_data_i, w2_we, w2_paddr_i, w2_data_i, w3_we, w3_paddr_i, w3_data_i);
    assign r6_data_o    = read_prf(r6_paddr_i, w0_we, w0_paddr_i, w0_data_i, w1_we, w1_paddr_i, w1_data_i, w2_we, w2_paddr_i, w2_data_i, w3_we, w3_paddr_i, w3_data_i);
    assign probe_pdata_o = read_prf(probe_paddr_i, w0_we, w0_paddr_i, w0_data_i, w1_we, w1_paddr_i, w1_data_i, w2_we, w2_paddr_i, w2_data_i, w3_we, w3_paddr_i, w3_data_i);

    // -------------------------------------------------------------------------
    // Simulation Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            // 1. p0 must always evaluate to 64'd0
            if (mem_q[0] != 64'd0) begin
                $fatal(1, "[PRF ASSERTION FAILED] mem_q[0] != 0! (%016h)", mem_q[0]);
            end
            if (r0_paddr_i == 7'd0 && r0_data_o != 64'd0) begin
                $fatal(1, "[PRF ASSERTION FAILED] Read Port 0 returned non-zero for p0: %016h", r0_data_o);
            end
            if (r1_paddr_i == 7'd0 && r1_data_o != 64'd0) begin
                $fatal(1, "[PRF ASSERTION FAILED] Read Port 1 returned non-zero for p0: %016h", r1_data_o);
            end
            if (r2_paddr_i == 7'd0 && r2_data_o != 64'd0) begin
                $fatal(1, "[PRF ASSERTION FAILED] Read Port 2 returned non-zero for p0: %016h", r2_data_o);
            end
            if (r3_paddr_i == 7'd0 && r3_data_o != 64'd0) begin
                $fatal(1, "[PRF ASSERTION FAILED] Read Port 3 returned non-zero for p0: %016h", r3_data_o);
            end
            if (r4_paddr_i == 7'd0 && r4_data_o != 64'd0) begin
                $fatal(1, "[PRF ASSERTION FAILED] Read Port 4 returned non-zero for p0: %016h", r4_data_o);
            end
            if (r5_paddr_i == 7'd0 && r5_data_o != 64'd0) begin
                $fatal(1, "[PRF ASSERTION FAILED] Read Port 5 returned non-zero for p0: %016h", r5_data_o);
            end
            if (r6_paddr_i == 7'd0 && r6_data_o != 64'd0) begin
                $fatal(1, "[PRF ASSERTION FAILED] Read Port 6 returned non-zero for p0: %016h", r6_data_o);
            end

            // 2. Stale completions must NEVER assert write enable
            if (w0_valid_i && !w0_comp_ack_i && w0_we) begin
                $fatal(1, "[PRF ASSERTION FAILED] Stale completion on Port 0 asserted PRF write enable!");
            end
            if (w1_valid_i && !w1_comp_ack_i && w1_we) begin
                $fatal(1, "[PRF ASSERTION FAILED] Stale completion on Port 1 asserted PRF write enable!");
            end
            if (w2_valid_i && !w2_comp_ack_i && w2_we) begin
                $fatal(1, "[PRF ASSERTION FAILED] Stale completion on Port 2 asserted PRF write enable!");
            end
            if (w3_valid_i && !w3_comp_ack_i && w3_we) begin
                $fatal(1, "[PRF ASSERTION FAILED] Stale completion on Port 3 asserted PRF write enable!");
            end

            // 3. Faulting load must NEVER assert write enable (Section 3.2, 17.3)
            if (w2_valid_i && w2_comp_exception_i && w2_we) begin
                $fatal(1, "[PRF ASSERTION FAILED] Faulting load on Port 2 asserted PRF write enable!");
            end
            if (w3_valid_i && w3_comp_exception_i && w3_we) begin
                $fatal(1, "[PRF ASSERTION FAILED] Faulting load on Port 3 asserted PRF write enable!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_PRF_SV
