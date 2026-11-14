`ifndef FURSOY_S1_L1D_SV
`define FURSOY_S1_L1D_SV

`include "fursoy_s1_pkg.sv"

module fursoy_s1_l1d
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    input  logic              load0_req_valid_i,
    input  lq_idx_t           load0_req_lq_idx_i,
    input  logic [55:0]       load0_req_pa_i,
    input  mem_size_t         load0_req_size_i,
    input  logic              load0_req_sign_ext_i,
    input  preg_t             load0_req_pnew_i,
    input  rob_idx_t          load0_req_rob_idx_i,
    input  rob_epoch_t        load0_req_rob_epoch_i,
    output logic              load0_req_ready_o,

    output logic              load0_rsp_valid_o,
    output lq_idx_t           load0_rsp_lq_idx_o,
    output logic              load0_rsp_hit_o,
    output logic [63:0]       load0_rsp_data_o,
    output mshr_idx_t         load0_rsp_mshr_id_o,

    input  logic              load1_req_valid_i,
    input  lq_idx_t           load1_req_lq_idx_i,
    input  logic [55:0]       load1_req_pa_i,
    input  mem_size_t         load1_req_size_i,
    input  logic              load1_req_sign_ext_i,
    input  preg_t             load1_req_pnew_i,
    input  rob_idx_t          load1_req_rob_idx_i,
    input  rob_epoch_t        load1_req_rob_epoch_i,
    output logic              load1_req_ready_o,

    output logic              load1_rsp_valid_o,
    output lq_idx_t           load1_rsp_lq_idx_o,
    output logic              load1_rsp_hit_o,
    output logic [63:0]       load1_rsp_data_o,
    output mshr_idx_t         load1_rsp_mshr_id_o,

    input  logic              store_drain_valid_i,
    input  sq_idx_t           store_drain_sq_idx_i,
    input  logic [55:0]       store_drain_pa_i,
    input  logic [7:0]        store_drain_mask_i,
    input  logic [63:0]       store_drain_data_i,
    output logic              store_drain_ready_o,
    output logic              store_drain_done_o,

    output logic              refill_comp_valid_o,
    output lq_idx_t           refill_comp_lq_idx_o,
    output preg_t             refill_comp_pnew_o,
    output rob_idx_t          refill_comp_rob_idx_o,
    output rob_epoch_t        refill_comp_rob_epoch_o,
    output logic [63:0]       refill_comp_data_o,

    output logic              bus_rd_req_valid_o,
    output logic [49:0]       bus_rd_req_addr_o,
    output mshr_idx_t         bus_rd_req_tag_o,
    input  logic              bus_rd_req_ready_i,

    input  logic              bus_rd_rsp_valid_i,
    input  mshr_idx_t         bus_rd_rsp_tag_i,
    input  logic [511:0]      bus_rd_rsp_data_i,

    output logic              bus_wr_req_valid_o,
    output logic [49:0]       bus_wr_req_addr_o,
    output logic [511:0]      bus_wr_req_data_o,
    input  logic              bus_wr_req_ready_i,

    input  logic              bus_wr_rsp_valid_i,

    input  logic              dcache_clean_all_req_i,
    output logic              dcache_clean_all_done_o,

    output logic              l1d_quiescent_o,

    output logic              event_l1d_hit_o,
    output logic              event_l1d_miss_o,
    output logic [2:0]        mshr_occ_o,
    output logic              wbb_full_o,
    output logic [1:0]        event_bank_access_count_o,
    output logic              event_bank_conflict_o,
    output logic              event_bank_broadcast_o,
    output logic              event_store_drain_concurrent_o,
    output logic              event_snoop_query_o,
    output logic              event_snoop_hit_o,

    input  logic              snoop_req_valid_i,
    input  logic [49:0]       snoop_req_addr_i,
    input  logic [1:0]        snoop_req_type_i,
    output logic              snoop_req_ready_o,

    output logic              snoop_rsp_valid_o,
    output logic              snoop_rsp_has_data_o,
    output logic [511:0]      snoop_rsp_data_o,
    output logic              snoop_rsp_was_dirty_o,

    input  logic [55:0]       ptw_snoop_pa_i,
    output logic              ptw_snoop_dirty_hit_o,
    output logic [63:0]       ptw_snoop_data_o
);

    assign load0_req_ready_o       = 1'b1;
    assign load1_req_ready_o       = 1'b1;
    assign store_drain_ready_o     = 1'b1;
    assign store_drain_done_o      = store_drain_valid_i;
    assign refill_comp_valid_o     = 1'b0;
    assign refill_comp_lq_idx_o    = '0;
    assign refill_comp_pnew_o      = '0;
    assign refill_comp_rob_idx_o   = '0;
    assign refill_comp_rob_epoch_o = '0;
    assign refill_comp_data_o      = 64'd0;

    assign bus_rd_req_valid_o      = 1'b0;
    assign bus_rd_req_addr_o       = 50'd0;
    assign bus_rd_req_tag_o        = '0;
    assign bus_wr_req_valid_o      = 1'b0;
    assign bus_wr_req_addr_o       = 50'd0;
    assign bus_wr_req_data_o       = 512'd0;

    assign dcache_clean_all_done_o = dcache_clean_all_req_i;
    assign l1d_quiescent_o         = 1'b1;
    assign event_l1d_hit_o         = 1'b0;
    assign event_l1d_miss_o        = 1'b0;
    assign mshr_occ_o              = 3'd0;
    assign wbb_full_o              = 1'b0;
    assign event_bank_access_count_o = 2'd0;
    assign event_bank_conflict_o   = 1'b0;
    assign event_bank_broadcast_o  = 1'b0;
    assign event_store_drain_concurrent_o = 1'b0;
    assign event_snoop_query_o     = 1'b0;
    assign event_snoop_hit_o       = 1'b0;

    assign snoop_req_ready_o       = 1'b1;
    assign snoop_rsp_valid_o       = 1'b0;
    assign snoop_rsp_has_data_o    = 1'b0;
    assign snoop_rsp_data_o        = 512'd0;
    assign snoop_rsp_was_dirty_o   = 1'b0;
    assign ptw_snoop_dirty_hit_o   = 1'b0;
    assign ptw_snoop_data_o        = 64'd0;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            load0_rsp_valid_o   <= 1'b0;
            load0_rsp_lq_idx_o  <= '0;
            load0_rsp_hit_o     <= 1'b0;
            load0_rsp_data_o    <= 64'd0;
            load0_rsp_mshr_id_o <= '0;

            load1_rsp_valid_o   <= 1'b0;
            load1_rsp_lq_idx_o  <= '0;
            load1_rsp_hit_o     <= 1'b0;
            load1_rsp_data_o    <= 64'd0;
            load1_rsp_mshr_id_o <= '0;
        end else begin
            load0_rsp_valid_o   <= load0_req_valid_i && !flush_valid_i;
            load0_rsp_lq_idx_o  <= load0_req_lq_idx_i;
            load0_rsp_hit_o     <= 1'b1;
            load0_rsp_data_o    <= {8'd0, load0_req_pa_i};
            load0_rsp_mshr_id_o <= '0;

            load1_rsp_valid_o   <= load1_req_valid_i && !flush_valid_i;
            load1_rsp_lq_idx_o  <= load1_req_lq_idx_i;
            load1_rsp_hit_o     <= 1'b1;
            load1_rsp_data_o    <= {8'd0, load1_req_pa_i};
            load1_rsp_mshr_id_o <= '0;
        end
    end

endmodule
`endif
