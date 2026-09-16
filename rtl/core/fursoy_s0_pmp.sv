`ifndef FURSOY_S0_PMP_SV
`define FURSOY_S0_PMP_SV

// Physical Memory Protection (PMP) unit for Fursoy CPU (RV64, G=0, 16 entries).
// Implements PMP CSRs, lock semantics, WARL rules, and combinational access checking.
/* verilator lint_off UNUSEDSIGNAL */
`include "rtl/core/fursoy_s0_pmp_check.sv"

module fursoy_s0_pmp (
    input  logic        clk_i,
    input  logic        rst_i,

    // CSR write interface from core pipeline
    input  logic        csr_we_i,
    input  logic [11:0] csr_addr_i,
    input  logic [63:0] csr_wdata_i,

    // CSR read interface to CSR unit
    output logic [63:0] pmpcfg0_o,
    output logic [63:0] pmpcfg2_o,
    output logic [63:0] pmpaddr_o [16],

    // PMP array outputs to MMU checker instances
    output logic [7:0]  pmp_cfg_o [16],
    output logic [53:0] pmp_addr_o [16],

    // Flush strobe to L1I on PMP configuration update
    output logic        pmp_flush_o
);
    assign pmp_flush_o = !rst_i && csr_we_i && ((csr_addr_i == 12'h3a0) || (csr_addr_i == 12'h3a2) ||
                                                 ((csr_addr_i >= 12'h3b0) && (csr_addr_i <= 12'h3bf)));
    logic [7:0]  pmp_cfg_q  [16];
    logic [53:0] pmp_addr_q [16];

    // CSR read packing
    assign pmpcfg0_o = {pmp_cfg_q[7],  pmp_cfg_q[6],  pmp_cfg_q[5],  pmp_cfg_q[4],
                        pmp_cfg_q[3],  pmp_cfg_q[2],  pmp_cfg_q[1],  pmp_cfg_q[0]};

    assign pmpcfg2_o = {pmp_cfg_q[15], pmp_cfg_q[14], pmp_cfg_q[13], pmp_cfg_q[12],
                        pmp_cfg_q[11], pmp_cfg_q[10], pmp_cfg_q[9],  pmp_cfg_q[8]};

    for (genvar i = 0; i < 16; i++) begin : gen_pmp_out
        assign pmpaddr_o[i] = {10'd0, pmp_addr_q[i]};
        assign pmp_cfg_o[i] = pmp_cfg_q[i];
        assign pmp_addr_o[i] = pmp_addr_q[i];
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int i = 0; i < 16; i++) begin
                pmp_cfg_q[i]  <= 8'h00;
                pmp_addr_q[i] <= 54'd0;
            end
        end else if (csr_we_i) begin
            if (csr_addr_i == 12'h3a0) begin
                for (int i = 0; i < 8; i++) begin
                    if (!pmp_cfg_q[i][7]) begin // writable only when L=0
                        logic [7:0] wbyte;
                        wbyte = csr_wdata_i[i*8 +: 8];
                        pmp_cfg_q[i][0]   <= wbyte[0]; // R
                        pmp_cfg_q[i][1]   <= wbyte[0] ? wbyte[1] : 1'b0; // WARL: W_eff = R_written ? W_written : 0
                        pmp_cfg_q[i][2]   <= wbyte[2]; // X
                        pmp_cfg_q[i][4:3] <= wbyte[4:3]; // A
                        pmp_cfg_q[i][6:5] <= 2'b00; // Reserved RO0
                        pmp_cfg_q[i][7]   <= wbyte[7]; // L
                    end
                end
            end else if (csr_addr_i == 12'h3a2) begin
                for (int i = 0; i < 8; i++) begin
                    int idx;
                    idx = 8 + i;
                    if (!pmp_cfg_q[idx][7]) begin // writable only when L=0
                        logic [7:0] wbyte;
                        wbyte = csr_wdata_i[i*8 +: 8];
                        pmp_cfg_q[idx][0]   <= wbyte[0]; // R
                        pmp_cfg_q[idx][1]   <= wbyte[0] ? wbyte[1] : 1'b0; // WARL: W_eff = R_written ? W_written : 0
                        pmp_cfg_q[idx][2]   <= wbyte[2]; // X
                        pmp_cfg_q[idx][4:3] <= wbyte[4:3]; // A
                        pmp_cfg_q[idx][6:5] <= 2'b00; // Reserved RO0
                        pmp_cfg_q[idx][7]   <= wbyte[7]; // L
                    end
                end
            end else if (csr_addr_i >= 12'h3b0 && csr_addr_i <= 12'h3bf) begin
                int idx;
                logic locked;
                idx = 32'(csr_addr_i) - 32'h3b0;
                // Entry idx is locked if:
                // 1) entry idx itself is locked (L == 1)
                // 2) entry idx is the predecessor of a locked TOR entry (idx < 15 && entry idx+1 has L=1 && A=TOR)
                locked = pmp_cfg_q[idx][7] || ((idx < 15) && pmp_cfg_q[idx+1][7] && (pmp_cfg_q[idx+1][4:3] == 2'b01));
                if (!locked) begin
                    pmp_addr_q[idx] <= csr_wdata_i[53:0]; // [63:54] discarded (RO0)
                end
            end
        end
    end

    // High-value safety assertions
    logic [7:0]  pmp_cfg_prev_q    [16];
    logic [53:0] pmp_addr_prev_q   [16];
    logic        pmp_locked_prev_q [16];

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int i = 0; i < 16; i++) begin
                pmp_cfg_prev_q[i]    <= 8'h00;
                pmp_addr_prev_q[i]   <= 54'd0;
                pmp_locked_prev_q[i] <= 1'b0;
            end
        end else begin
            for (int i = 0; i < 16; i++) begin
                pmp_cfg_prev_q[i]    <= pmp_cfg_q[i];
                pmp_addr_prev_q[i]   <= pmp_addr_q[i];
                pmp_locked_prev_q[i] <= pmp_cfg_q[i][7];

                if (pmp_locked_prev_q[i]) begin
                    assert (pmp_cfg_q[i] == pmp_cfg_prev_q[i])
                        else $fatal(1, "Locked PMP entry %0d cfg changed without reset", i);
                    assert (pmp_addr_q[i] == pmp_addr_prev_q[i])
                        else $fatal(1, "Locked PMP entry %0d addr changed without reset", i);
                end

                if (i > 0 && pmp_locked_prev_q[i] && (pmp_cfg_prev_q[i][4:3] == 2'b01)) begin
                    assert (pmp_addr_q[i-1] == pmp_addr_prev_q[i-1])
                        else $fatal(1, "Preceding TOR PMP addr %0d changed without reset", i-1);
                end
            end
        end
    end
endmodule
`endif // FURSOY_S0_PMP_SV
