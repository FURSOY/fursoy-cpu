`ifndef FURSOY_S1_TRT_SV
`define FURSOY_S1_TRT_SV

// =============================================================================
// Fursoy Slice-1 Translation Request Table (TRT) — Milestone 3
// =============================================================================
// Reference: docs/architecture/slice1-m3-memory-v1.md Section 11 & Section 12
//
// Provides structural non-aliasing for long-latency translation (DTLB miss / PTW).
// Out-of-order translation transactions are owned by persistent TRT entries.
// Returning PTW responses route strictly to tr_id; squashed waiters have
// waiter_valid cleared, dropping late responses with zero side effects on
// reused LQ/SQ slots.
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_trt
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    // Allocation Interface (from AGU/DTLB miss)
    input  logic              alloc_req_i,
    input  logic              alloc_is_store_i,
    input  logic [3:0]        alloc_q_idx_i,
    input  logic [26:0]       alloc_vpn_i,
    input  logic [1:0]        alloc_access_type_i,
    input  rob_idx_t          alloc_rob_idx_i,
    input  rob_epoch_t        alloc_rob_epoch_i,

    output logic              alloc_ready_o,
    output tr_id_t            alloc_tr_id_o,

    // External Translation Engine / PTW Query Interface
    output logic              ptw_req_valid_o,
    output tr_id_t            ptw_req_tr_id_o,
    output logic [26:0]       ptw_req_vpn_o,
    output logic [1:0]        ptw_req_access_type_o,
    input  logic              ptw_req_ready_i,

    // External Translation Engine / PTW Response Interface
    input  logic              ptw_rsp_valid_i,
    input  tr_id_t            ptw_rsp_tr_id_i,
    input  logic [55:0]       ptw_rsp_pa_i,
    input  logic              ptw_rsp_page_fault_i,
    input  logic              ptw_rsp_access_fault_i,
    input  logic [1:0]        ptw_rsp_level_i,
    input  logic [63:0]       ptw_rsp_pte_i,

    // DTLB Refill Interface (P0-2)
    output logic              dtlb_refill_valid_o,
    output logic [26:0]       dtlb_refill_vpn_o,
    output logic [1:0]        dtlb_refill_level_o,
    output logic [63:0]       dtlb_refill_pte_o,
    output logic [55:0]       dtlb_refill_pa_o,

    // Translation Delivery to LQ / SQ
    output logic              trt_delivery_valid_o,
    output logic              trt_delivery_is_store_o,
    output logic [3:0]        trt_delivery_q_idx_o,
    output logic [55:0]       trt_delivery_pa_o,
    output logic              trt_delivery_page_fault_o,
    output logic              trt_delivery_access_fault_o,
    output rob_idx_t          trt_delivery_rob_idx_o,
    output rob_epoch_t        trt_delivery_rob_epoch_o
);

    // -------------------------------------------------------------------------
    // 4 Persistent Request Entries
    // -------------------------------------------------------------------------
    trt_entry_t entries_q [TRT_DEPTH];
    logic [TRT_DEPTH-1:0] ptw_pending_q;
    logic [TRT_DEPTH-1:0] ptw_inflight_q;

    // Find free slot
    tr_id_t     free_slot;
    logic       free_found;

    always_comb begin
        free_slot  = '0;
        free_found = 1'b0;
        for (int i = 0; i < TRT_DEPTH; i++) begin
            if (!entries_q[i].valid) begin
                if (!free_found) begin
                    free_slot  = tr_id_t'(i);
                    free_found = 1'b1;
                end
            end
        end
    end

    assign alloc_ready_o = free_found && !flush_valid_i;
    assign alloc_tr_id_o = free_slot;

    // -------------------------------------------------------------------------
    // PTW Request Arbitration & Launch
    // -------------------------------------------------------------------------
    tr_id_t      ptw_cand_slot;
    logic        ptw_cand_valid;
    logic [26:0] ptw_cand_vpn;
    logic [1:0]  ptw_cand_access_type;
    wire alloc_squashed = recover_valid_i && (rob_dist(alloc_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    always_comb begin
        ptw_cand_slot        = '0;
        ptw_cand_valid       = 1'b0;
        ptw_cand_vpn         = '0;
        ptw_cand_access_type = '0;

        for (int i = 0; i < TRT_DEPTH; i++) begin
            if (entries_q[i].valid && entries_q[i].waiter_valid && ptw_pending_q[i]) begin
                if (!ptw_cand_valid) begin
                    ptw_cand_slot        = tr_id_t'(i);
                    ptw_cand_valid       = 1'b1;
                    ptw_cand_vpn         = entries_q[i].vpn;
                    ptw_cand_access_type = entries_q[i].access_type;
                end
            end
        end

        // If no registered entry is pending, check if a new allocation arrives now
        if (!ptw_cand_valid && alloc_req_i && free_found && !flush_valid_i && !alloc_squashed) begin
            ptw_cand_slot        = free_slot;
            ptw_cand_valid       = 1'b1;
            ptw_cand_vpn         = alloc_vpn_i;
            ptw_cand_access_type = alloc_access_type_i;
        end
    end

    assign ptw_req_valid_o       = ptw_cand_valid;
    assign ptw_req_tr_id_o       = ptw_cand_slot;
    assign ptw_req_vpn_o         = ptw_cand_vpn;
    assign ptw_req_access_type_o = ptw_cand_access_type;

    // Delivery to Queues
    wire rsp_valid = ptw_rsp_valid_i && entries_q[ptw_rsp_tr_id_i].valid;
    wire rsp_live  = rsp_valid && entries_q[ptw_rsp_tr_id_i].waiter_valid;

    assign trt_delivery_valid_o        = rsp_live;
    assign trt_delivery_is_store_o     = entries_q[ptw_rsp_tr_id_i].is_store;
    assign trt_delivery_q_idx_o        = entries_q[ptw_rsp_tr_id_i].q_idx;
    assign trt_delivery_pa_o           = ptw_rsp_pa_i;
    assign trt_delivery_page_fault_o   = ptw_rsp_page_fault_i;
    assign trt_delivery_access_fault_o = ptw_rsp_access_fault_i;
    assign trt_delivery_rob_idx_o      = entries_q[ptw_rsp_tr_id_i].rob_idx;
    assign trt_delivery_rob_epoch_o    = entries_q[ptw_rsp_tr_id_i].rob_epoch;

    assign dtlb_refill_valid_o = ptw_rsp_valid_i && entries_q[ptw_rsp_tr_id_i].valid &&
                                 !ptw_rsp_page_fault_i && !ptw_rsp_access_fault_i;
    assign dtlb_refill_vpn_o   = entries_q[ptw_rsp_tr_id_i].vpn;
    assign dtlb_refill_level_o = ptw_rsp_level_i;
    assign dtlb_refill_pte_o   = ptw_rsp_pte_i;
    assign dtlb_refill_pa_o    = ptw_rsp_pa_i;

    // -------------------------------------------------------------------------
    // Sequential State Management
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int i = 0; i < TRT_DEPTH; i++) begin
                entries_q[i] <= '0;
            end
            ptw_pending_q  <= '0;
            ptw_inflight_q <= '0;
        end else begin
            // Track in-flight PTW requests
            if (ptw_req_valid_o && ptw_req_ready_i) begin
                ptw_pending_q[ptw_cand_slot]  <= 1'b0;
                ptw_inflight_q[ptw_cand_slot] <= 1'b1;
            end

            // 1. Service arriving response: terminate transaction and free TRT entry
            if (ptw_rsp_valid_i && entries_q[ptw_rsp_tr_id_i].valid) begin
                entries_q[ptw_rsp_tr_id_i].valid <= 1'b0;
                ptw_pending_q[ptw_rsp_tr_id_i]   <= 1'b0;
                ptw_inflight_q[ptw_rsp_tr_id_i]  <= 1'b0;
            end

            // 2. Full architectural flush
            if (flush_valid_i) begin
                for (int i = 0; i < TRT_DEPTH; i++) begin
                    if (entries_q[i].valid) begin
                        if (ptw_inflight_q[i] || (ptw_req_valid_o && ptw_req_ready_i && (ptw_cand_slot == tr_id_t'(i)))) begin
                            entries_q[i].waiter_valid <= 1'b0;
                            ptw_pending_q[i]          <= 1'b0;
                        end else begin
                            entries_q[i].valid        <= 1'b0;
                            entries_q[i].waiter_valid <= 1'b0;
                            ptw_pending_q[i]          <= 1'b0;
                            ptw_inflight_q[i]         <= 1'b0;
                        end
                    end
                end
            end

            // 3. Branch recovery squash: invalidate younger waiters
            if (recover_valid_i) begin
                for (int i = 0; i < TRT_DEPTH; i++) begin
                    if (entries_q[i].valid && entries_q[i].waiter_valid) begin
                        if (rob_dist(entries_q[i].rob_idx, rob_head_i) >
                            rob_dist(recover_rob_idx_i, rob_head_i)) begin
                            if (ptw_inflight_q[i] || (ptw_req_valid_o && ptw_req_ready_i && (ptw_cand_slot == tr_id_t'(i)))) begin
                                entries_q[i].waiter_valid <= 1'b0;
                                ptw_pending_q[i]          <= 1'b0;
                            end else begin
                                entries_q[i].valid        <= 1'b0;
                                entries_q[i].waiter_valid <= 1'b0;
                                ptw_pending_q[i]          <= 1'b0;
                                ptw_inflight_q[i]         <= 1'b0;
                            end
                        end
                    end
                end
            end

            // 4. New Allocation
            if (alloc_req_i && free_found && !flush_valid_i && !alloc_squashed) begin
                entries_q[free_slot].valid        <= 1'b1;
                entries_q[free_slot].is_store     <= alloc_is_store_i;
                entries_q[free_slot].q_idx        <= alloc_q_idx_i;
                entries_q[free_slot].vpn          <= alloc_vpn_i;
                entries_q[free_slot].access_type  <= alloc_access_type_i;
                entries_q[free_slot].waiter_valid <= 1'b1;
                entries_q[free_slot].rob_idx      <= alloc_rob_idx_i;
                entries_q[free_slot].rob_epoch    <= alloc_rob_epoch_i;

                if (ptw_req_valid_o && ptw_req_ready_i && (ptw_cand_slot == free_slot)) begin
                    ptw_pending_q[free_slot]  <= 1'b0;
                    ptw_inflight_q[free_slot] <= 1'b1;
                end else begin
                    ptw_pending_q[free_slot]  <= 1'b1;
                    ptw_inflight_q[free_slot] <= 1'b0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Assertion 12: Squashed translation responses must NEVER modify any LQ or SQ entry (Section 17.3)
    always_ff @(posedge clk_i) begin
        if (!rst_i && ptw_rsp_valid_i) begin
            if (entries_q[ptw_rsp_tr_id_i].valid && !entries_q[ptw_rsp_tr_id_i].waiter_valid) begin
                if (trt_delivery_valid_o) begin
                    $fatal(1, "[TRT ASSERTION FAILED] Squashed translation response was delivered to queue!");
                end
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_TRT_SV
