`ifndef FURSOY_S1_VRF_SV
`define FURSOY_S1_VRF_SV

`include "fursoy_s1_pkg.sv"

module fursoy_s1_vrf
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    input  vreg_t             raddr0_v_i,
    input  logic [3:0]        ren0_bank_i,
    output logic [255:0]      rdata0_v_o,

    input  vreg_t             raddr1_v_i,
    input  logic [3:0]        ren1_bank_i,
    output logic [255:0]      rdata1_v_o,

    input  vreg_t             raddr2_v_i,
    input  logic [3:0]        ren2_bank_i,
    output logic [255:0]      rdata2_v_o,

    input  logic              w0_valid_i,
    input  vreg_t             w0_paddr_i,
    input  logic [3:0]        w0_bank_mask_i,
    input  logic [31:0]       w0_byte_mask_i,
    input  logic [255:0]      w0_data_i,

    output logic [3:0]        bank_collision_o,

    input  logic              test_w_valid_i,
    input  vreg_t             test_w_paddr_i,
    input  logic [31:0]       test_w_byte_mask_i,
    input  logic [255:0]      test_w_data_i,

    input  vreg_t             probe_paddr_i,
    output logic [255:0]      probe_pdata_o
);

    assign bank_collision_o = 4'd0;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            rdata0_v_o <= 256'd0;
            rdata1_v_o <= 256'd0;
            rdata2_v_o <= 256'd0;
            probe_pdata_o <= 256'd0;
        end else begin
            rdata0_v_o <= {250'd0, raddr0_v_i} ^ (w0_valid_i ? w0_data_i : 256'd0);
            rdata1_v_o <= {250'd0, raddr1_v_i};
            rdata2_v_o <= {250'd0, raddr2_v_i};
            probe_pdata_o <= {250'd0, probe_paddr_i};
        end
    end

endmodule
`endif
