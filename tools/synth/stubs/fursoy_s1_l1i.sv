`ifndef FURSOY_S1_L1I_SV
`define FURSOY_S1_L1I_SV

`include "fursoy_s1_pkg.sv"

module fursoy_s1_l1i
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    input  logic              f1_req_valid_i,
    input  logic [63:0]       f1_req_pc_i,
    input  logic [55:0]       f1_req_pa_i,
    input  logic              f1_req_page_fault_i,
    input  logic              f1_req_access_fault_i,
    output logic              l1i_ready_o,

    input  logic              stall_f3_i,
    input  logic              redirect_flush_i,
    input  logic              l1i_inval_all_i,
    input  logic              sfence_vma_i,
    input  logic [4:0]        fq_free_count_i,
    input  logic              ptw_req_active_i,

    output logic              f3_valid_o,
    output logic [63:0]       f3_pc_o,
    output logic [63:0]       f3_data_o,
    output logic              f3_exception_valid_o,
    output logic [4:0]        f3_exception_cause_o,
    output logic [63:0]       f3_fault_addr_o,

    output logic              f2_stall_f0_o,
    output logic              f2_stall_f1_o,

    output logic              bus_rd_req_valid_o,
    output logic [49:0]       bus_rd_req_addr_o,
    output logic [1:0]        bus_rd_req_tag_o,
    input  logic              bus_rd_req_ready_i,

    input  logic              bus_rd_rsp_valid_i,
    input  logic [1:0]        bus_rd_rsp_tag_i,
    input  logic [511:0]      bus_rd_rsp_data_i,
    input  logic              bus_rd_rsp_error_i,

    output logic              event_l1i_hit_o,
    output logic              event_l1i_miss_o,
    output logic [1:0]        imshr_occ_o,
    output logic              diag_f2_skid_valid_o,
    output logic              diag_nlp_alloc_o,
    output logic              diag_nlp_hit_o,
    output logic              diag_nlp_promote_o,
    output logic              diag_nlp_abort_page_o,
    output logic              diag_nlp_drop_resident_o
);

    assign l1i_ready_o          = 1'b1;
    assign f2_stall_f0_o        = 1'b0;
    assign f2_stall_f1_o        = 1'b0;
    assign bus_rd_req_valid_o   = 1'b0;
    assign bus_rd_req_addr_o    = 50'd0;
    assign bus_rd_req_tag_o     = 2'd0;
    assign event_l1i_hit_o      = 1'b0;
    assign event_l1i_miss_o     = 1'b0;
    assign imshr_occ_o          = 2'd0;
    assign diag_f2_skid_valid_o = 1'b0;
    assign diag_nlp_alloc_o     = 1'b0;
    assign diag_nlp_hit_o       = 1'b0;
    assign diag_nlp_promote_o   = 1'b0;
    assign diag_nlp_abort_page_o = 1'b0;
    assign diag_nlp_drop_resident_o = 1'b0;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            f3_valid_o           <= 1'b0;
            f3_pc_o              <= 64'd0;
            f3_data_o            <= 64'd0;
            f3_exception_valid_o <= 1'b0;
            f3_exception_cause_o <= 5'd0;
            f3_fault_addr_o      <= 64'd0;
        end else begin
            f3_valid_o           <= f1_req_valid_i && !redirect_flush_i && !stall_f3_i;
            f3_pc_o              <= f1_req_pc_i;
            f3_data_o            <= 64'h00000013_00000013; // nop, nop
            f3_exception_valid_o <= f1_req_page_fault_i || f1_req_access_fault_i;
            f3_exception_cause_o <= f1_req_page_fault_i ? 5'd12 : 5'd1;
            f3_fault_addr_o      <= f1_req_pc_i;
        end
    end

endmodule
`endif
