`ifndef FURSOY_S1_FPRF_SV
`define FURSOY_S1_FPRF_SV

`include "fursoy_s1_pkg.sv"

module fursoy_s1_fprf
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    input  fpreg_t            raddr0_fp_i,
    output logic [63:0]       rdata0_fp_o,

    input  fpreg_t            raddr1_fp_i,
    output logic [63:0]       rdata1_fp_o,

    input  fpreg_t            raddr2_fp_i,
    output logic [63:0]       rdata2_fp_o,

    input  fpreg_t            raddr3_fp_i,
    output logic [63:0]       rdata3_fp_o,

    input  logic              w0_valid_i,
    input  fpreg_t            w0_paddr_i,
    input  logic [63:0]       w0_data_i,

    input  logic              w1_valid_i,
    input  fpreg_t            w1_paddr_i,
    input  logic [63:0]       w1_data_i,

    input  logic              w2_valid_i,
    input  fpreg_t            w2_paddr_i,
    input  logic [63:0]       w2_data_i,

    input  fpreg_t            probe_paddr_i,
    output logic [63:0]       probe_pdata_o
);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            rdata0_fp_o <= 64'd0;
            rdata1_fp_o <= 64'd0;
            rdata2_fp_o <= 64'd0;
            rdata3_fp_o <= 64'd0;
            probe_pdata_o <= 64'd0;
        end else begin
            rdata0_fp_o <= {58'd0, raddr0_fp_i} ^ (w0_valid_i ? w0_data_i : 64'd0);
            rdata1_fp_o <= {58'd0, raddr1_fp_i} ^ (w1_valid_i ? w1_data_i : 64'd0);
            rdata2_fp_o <= {58'd0, raddr2_fp_i} ^ (w2_valid_i ? w2_data_i : 64'd0);
            rdata3_fp_o <= {58'd0, raddr3_fp_i};
            probe_pdata_o <= {58'd0, probe_paddr_i};
        end
    end

endmodule
`endif
