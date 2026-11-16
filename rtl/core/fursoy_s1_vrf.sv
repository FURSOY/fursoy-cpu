`ifndef FURSOY_S1_VRF_SV
`define FURSOY_S1_VRF_SV

// =============================================================================
// Fursoy Slice-1 256-bit Vector Register File (VRF) — Milestone 8 Phase D
// =============================================================================
// Sizing: 64 physical vector registers x 256 bits (VLEN = 256, ELEN = 64, total 2.0 KiB).
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 8.1, Section 10
//
// Invariants:
// - Physical register array: 64 entries x 256 bits (VRF_NUM_PREGS = 64).
// - 4 Independent 64-bit Banks per physical register:
//     * Bank 0: Elements [63:0]
//     * Bank 1: Elements [127:64]
//     * Bank 2: Elements [191:128]
//     * Bank 3: Elements [255:192]
// - Independent bank addressing eliminates SIMD lane read/write conflicts across
//   different 64-bit execution slices (PROP_M8_27).
// - Synchronous write on posedge clk_i with per-byte write mask.
// - Combinational read with internal same-cycle writeback bypassing.
// - 3 Read Ports:
//     * Read Port 0: vs1 (Source 1 operand)
//     * Read Port 1: vs2 (Source 2 operand)
//     * Read Port 2: vs3 / v0 (Source 3 or Vector Mask operand)
// - 1 Execution Writeback Port (Vector SIMD / VMU Load):
//     * w0_valid_i, w0_paddr_i, w0_bank_mask_i, w0_byte_mask_i, w0_data_i
// - Test/Debug Write Port & Non-Destructive Probe Read Port.
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_vrf
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // -------------------------------------------------------------------------
    // 3 Read Ports (Register Fetch Stage: RF)
    // -------------------------------------------------------------------------
    // Read Port 0: vs1
    input  vreg_t             raddr0_v_i,
    input  logic [3:0]        ren0_bank_i,
    output logic [255:0]      rdata0_v_o,

    // Read Port 1: vs2
    input  vreg_t             raddr1_v_i,
    input  logic [3:0]        ren1_bank_i,
    output logic [255:0]      rdata1_v_o,

    // Read Port 2: vs3 / v0 (Mask)
    input  vreg_t             raddr2_v_i,
    input  logic [3:0]        ren2_bank_i,
    output logic [255:0]      rdata2_v_o,

    // Read Port 3: old_vd (Mask/Tail/vstart Undisturbed Merge Source)
    input  vreg_t             raddr3_v_i,
    input  logic [3:0]        ren3_bank_i,
    output logic [255:0]      rdata3_v_o,

    // -------------------------------------------------------------------------
    // 1 Execution Writeback Port (Validated Writeback Stage: WB)
    // -------------------------------------------------------------------------
    input  logic              w0_valid_i,
    input  vreg_t             w0_paddr_i,
    input  logic [3:0]        w0_bank_mask_i,
    input  logic [31:0]       w0_byte_mask_i,
    input  logic [255:0]      w0_data_i,

    // -------------------------------------------------------------------------
    // Diagnostic Multi-Bank Collision Detection Outputs
    // Asserted when a concurrent read and write access the same bank on same preg
    // -------------------------------------------------------------------------
    output logic [3:0]        bank_collision_o,

    // -------------------------------------------------------------------------
    // Testbench / Debug Direct Initialization Write Port
    // -------------------------------------------------------------------------
    input  logic              test_w_valid_i,
    input  vreg_t             test_w_paddr_i,
    input  logic [31:0]       test_w_byte_mask_i,
    input  logic [255:0]      test_w_data_i,

    // -------------------------------------------------------------------------
    // Testbench / Diagnostics Read Probe Port
    // -------------------------------------------------------------------------
    input  vreg_t             probe_paddr_i,
    output logic [255:0]      probe_pdata_o
);

    // -------------------------------------------------------------------------
    // 4-Bank Storage Arrays (48 entries x 64 bits each)
    // -------------------------------------------------------------------------
    logic [63:0] bank0_q [VRF_NUM_PREGS]; // [63:0]
    logic [63:0] bank1_q [VRF_NUM_PREGS]; // [127:64]
    logic [63:0] bank2_q [VRF_NUM_PREGS]; // [191:128]
    logic [63:0] bank3_q [VRF_NUM_PREGS]; // [255:192]

    // -------------------------------------------------------------------------
    // Synchronous Array Write (Posedge clk_i)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            /* verilator lint_off BLKSEQ */
            for (int unsigned i = 0; i < VRF_NUM_PREGS; i++) begin
                bank0_q[i] = 64'd0;
                bank1_q[i] = 64'd0;
                bank2_q[i] = 64'd0;
                bank3_q[i] = 64'd0;
            end
            /* verilator lint_on BLKSEQ */
        end else begin
            // Testbench direct write (highest precedence during setup)
            if (test_w_valid_i) begin
                for (int b = 0; b < 8; b++) begin
                    if (test_w_byte_mask_i[b])      bank0_q[test_w_paddr_i][b*8 +: 8] <= test_w_data_i[b*8 +: 8];
                    if (test_w_byte_mask_i[b + 8])  bank1_q[test_w_paddr_i][b*8 +: 8] <= test_w_data_i[(b+8)*8 +: 8];
                    if (test_w_byte_mask_i[b + 16]) bank2_q[test_w_paddr_i][b*8 +: 8] <= test_w_data_i[(b+16)*8 +: 8];
                    if (test_w_byte_mask_i[b + 24]) bank3_q[test_w_paddr_i][b*8 +: 8] <= test_w_data_i[(b+24)*8 +: 8];
                end
            end else if (w0_valid_i) begin
                // Bank 0 write
                if (w0_bank_mask_i[0]) begin
                    for (int b = 0; b < 8; b++) begin
                        if (w0_byte_mask_i[b]) begin
                            bank0_q[w0_paddr_i][b*8 +: 8] <= w0_data_i[b*8 +: 8];
                        end
                    end
                end
                // Bank 1 write
                if (w0_bank_mask_i[1]) begin
                    for (int b = 0; b < 8; b++) begin
                        if (w0_byte_mask_i[b + 8]) begin
                            bank1_q[w0_paddr_i][b*8 +: 8] <= w0_data_i[(b+8)*8 +: 8];
                        end
                    end
                end
                // Bank 2 write
                if (w0_bank_mask_i[2]) begin
                    for (int b = 0; b < 8; b++) begin
                        if (w0_byte_mask_i[b + 16]) begin
                            bank2_q[w0_paddr_i][b*8 +: 8] <= w0_data_i[(b+16)*8 +: 8];
                        end
                    end
                end
                // Bank 3 write
                if (w0_bank_mask_i[3]) begin
                    for (int b = 0; b < 8; b++) begin
                        if (w0_byte_mask_i[b + 24]) begin
                            bank3_q[w0_paddr_i][b*8 +: 8] <= w0_data_i[(b+24)*8 +: 8];
                        end
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Combinational Read with Same-Cycle Writeback Bypassing
    // -------------------------------------------------------------------------
    // Helper function for bank read data with write forwarding
    function automatic logic [63:0] read_bank_data(
        input int unsigned bank_idx,
        input vreg_t       raddr,
        input logic [63:0] bank_data_q
    );
        logic [63:0] res;
        begin
            res = bank_data_q;
            if (w0_valid_i && (w0_paddr_i == raddr) && w0_bank_mask_i[bank_idx]) begin
                for (int b = 0; b < 8; b++) begin
                    if (w0_byte_mask_i[bank_idx*8 + b]) begin
                        res[b*8 +: 8] = w0_data_i[(bank_idx*8 + b)*8 +: 8];
                    end
                end
            end
            read_bank_data = res;
        end
    endfunction

    // Read Port 0 (vs1)
    assign rdata0_v_o[63:0]    = read_bank_data(0, raddr0_v_i, bank0_q[raddr0_v_i]);
    assign rdata0_v_o[127:64]  = read_bank_data(1, raddr0_v_i, bank1_q[raddr0_v_i]);
    assign rdata0_v_o[191:128] = read_bank_data(2, raddr0_v_i, bank2_q[raddr0_v_i]);
    assign rdata0_v_o[255:192] = read_bank_data(3, raddr0_v_i, bank3_q[raddr0_v_i]);

    // Read Port 1 (vs2)
    assign rdata1_v_o[63:0]    = read_bank_data(0, raddr1_v_i, bank0_q[raddr1_v_i]);
    assign rdata1_v_o[127:64]  = read_bank_data(1, raddr1_v_i, bank1_q[raddr1_v_i]);
    assign rdata1_v_o[191:128] = read_bank_data(2, raddr1_v_i, bank2_q[raddr1_v_i]);
    assign rdata1_v_o[255:192] = read_bank_data(3, raddr1_v_i, bank3_q[raddr1_v_i]);

    // Read Port 2 (vs3 / v0)
    assign rdata2_v_o[63:0]    = read_bank_data(0, raddr2_v_i, bank0_q[raddr2_v_i]);
    assign rdata2_v_o[127:64]  = read_bank_data(1, raddr2_v_i, bank1_q[raddr2_v_i]);
    assign rdata2_v_o[191:128] = read_bank_data(2, raddr2_v_i, bank2_q[raddr2_v_i]);
    assign rdata2_v_o[255:192] = read_bank_data(3, raddr2_v_i, bank3_q[raddr2_v_i]);

    // Read Port 3 (old_vd)
    assign rdata3_v_o[63:0]    = read_bank_data(0, raddr3_v_i, bank0_q[raddr3_v_i]);
    assign rdata3_v_o[127:64]  = read_bank_data(1, raddr3_v_i, bank1_q[raddr3_v_i]);
    assign rdata3_v_o[191:128] = read_bank_data(2, raddr3_v_i, bank2_q[raddr3_v_i]);
    assign rdata3_v_o[255:192] = read_bank_data(3, raddr3_v_i, bank3_q[raddr3_v_i]);

    // Non-destructive probe read
    assign probe_pdata_o[63:0]    = bank0_q[probe_paddr_i];
    assign probe_pdata_o[127:64]  = bank1_q[probe_paddr_i];
    assign probe_pdata_o[191:128] = bank2_q[probe_paddr_i];
    assign probe_pdata_o[255:192] = bank3_q[probe_paddr_i];

    // Bank Collision Monitoring: Asserted if concurrent read & write target the same bank
    always_comb begin
        for (int b = 0; b < 4; b++) begin
            bank_collision_o[b] = w0_valid_i && w0_bank_mask_i[b] && (
                (ren0_bank_i[b] && (raddr0_v_i == w0_paddr_i)) ||
                (ren1_bank_i[b] && (raddr1_v_i == w0_paddr_i)) ||
                (ren2_bank_i[b] && (raddr2_v_i == w0_paddr_i)) ||
                (ren3_bank_i[b] && (raddr3_v_i == w0_paddr_i))
            );
        end
    end

endmodule

`endif // FURSOY_S1_VRF_SV
