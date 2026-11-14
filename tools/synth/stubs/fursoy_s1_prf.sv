`ifndef FURSOY_S1_PRF_SV
`define FURSOY_S1_PRF_SV

`include "fursoy_s1_pkg.sv"

module fursoy_s1_prf
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    input  preg_t             r0_paddr_i,
    output logic [63:0]       r0_data_o,

    input  preg_t             r1_paddr_i,
    output logic [63:0]       r1_data_o,

    input  preg_t             r2_paddr_i,
    output logic [63:0]       r2_data_o,

    input  preg_t             r3_paddr_i,
    output logic [63:0]       r3_data_o,

    input  preg_t             r4_paddr_i,
    output logic [63:0]       r4_data_o,

    input  preg_t             r5_paddr_i,
    output logic [63:0]       r5_data_o,

    input  preg_t             r6_paddr_i,
    output logic [63:0]       r6_data_o,

    input  logic              w0_valid_i,
    input  logic              w0_comp_ack_i,
    input  preg_t             w0_paddr_i,
    input  logic [63:0]       w0_data_i,

    input  logic              w1_valid_i,
    input  logic              w1_comp_ack_i,
    input  preg_t             w1_paddr_i,
    input  logic [63:0]       w1_data_i,

    input  logic              w2_valid_i,
    input  logic              w2_comp_ack_i,
    input  logic              w2_comp_exception_i,
    input  preg_t             w2_paddr_i,
    input  logic [63:0]       w2_data_i,

    input  logic              w3_valid_i,
    input  logic              w3_comp_ack_i,
    input  logic              w3_comp_exception_i,
    input  preg_t             w3_paddr_i,
    input  logic [63:0]       w3_data_i,

    input  preg_t             probe_paddr_i,
    output logic [63:0]       probe_pdata_o
);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            r0_data_o <= 64'd0;
            r1_data_o <= 64'd0;
            r2_data_o <= 64'd0;
            r3_data_o <= 64'd0;
            r4_data_o <= 64'd0;
            r5_data_o <= 64'd0;
            r6_data_o <= 64'd0;
            probe_pdata_o <= 64'd0;
        end else begin
            r0_data_o <= {57'd0, r0_paddr_i} ^ (w0_valid_i ? w0_data_i : 64'd0);
            r1_data_o <= {57'd0, r1_paddr_i} ^ (w1_valid_i ? w1_data_i : 64'd0);
            r2_data_o <= {57'd0, r2_paddr_i} ^ (w2_valid_i ? w2_data_i : 64'd0);
            r3_data_o <= {57'd0, r3_paddr_i} ^ (w3_valid_i ? w3_data_i : 64'd0);
            r4_data_o <= {57'd0, r4_paddr_i};
            r5_data_o <= {57'd0, r5_paddr_i};
            r6_data_o <= {57'd0, r6_paddr_i};
            probe_pdata_o <= {57'd0, probe_paddr_i};
        end
    end

endmodule
`endif
