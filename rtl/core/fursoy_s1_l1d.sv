`ifndef FURSOY_S1_L1D_SV
`define FURSOY_S1_L1D_SV

// =============================================================================
// Fursoy Slice-1 Non-Blocking L1 Data Cache (L1D) Subsystem — Milestone 3
// =============================================================================
// Reference: docs/architecture/slice1-m3-memory-v1.md Sections 8, 9, 10, 11
//
// Key Architectural Features:
// - 16 KiB 4-Way Set-Associative (64 sets x 64 B line = 4096 B/way, VIPT synonym safe).
// - Physically tagged, write-back, write-allocate, non-blocking.
// - Strict Arbitration Priority: Refill Install > Committed Store Drain > Speculative Load Issue.
// - 4 MSHRs with per-waiter active descriptors and selective waiter squash.
// - Multi-waiter secondary load miss and committed store drain merging.
// - 2-entry Writeback Buffer (WBB) with pre-reservation at miss allocation time.
// - Authoritative newest dirty copy owner in WBB with associative snooping.
// =============================================================================

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

    // -------------------------------------------------------------------------
    // Core Speculative Load Request Interface (Priority 3)
    // -------------------------------------------------------------------------
    input  logic              load_req_valid_i,
    input  lq_idx_t           load_req_lq_idx_i,
    input  logic [55:0]       load_req_pa_i,
    input  mem_size_t         load_req_size_i,
    input  logic              load_req_sign_ext_i,
    input  preg_t             load_req_pnew_i,
    input  rob_idx_t          load_req_rob_idx_i,
    input  rob_epoch_t        load_req_rob_epoch_i,
    output logic              load_req_ready_o,

    // Immediate Hit Response on Same/Next Cycle
    output logic              load_rsp_valid_o,
    output lq_idx_t           load_rsp_lq_idx_o,
    output logic              load_rsp_hit_o,
    output logic [63:0]       load_rsp_data_o,
    output mshr_idx_t         load_rsp_mshr_id_o,

    // -------------------------------------------------------------------------
    // Core Committed Store Drain Request Interface (Priority 2)
    // -------------------------------------------------------------------------
    input  logic              store_drain_valid_i,
    input  sq_idx_t           store_drain_sq_idx_i,
    input  logic [55:0]       store_drain_pa_i,
    input  logic [7:0]        store_drain_mask_i,
    input  logic [63:0]       store_drain_data_i,
    output logic              store_drain_ready_o,
    output logic              store_drain_done_o,

    // -------------------------------------------------------------------------
    // Port 2 MSHR Refill Completion Delivery (to Load Queue / PRF W2)
    // -------------------------------------------------------------------------
    output logic              refill_comp_valid_o,
    output lq_idx_t           refill_comp_lq_idx_o,
    output preg_t             refill_comp_pnew_o,
    output rob_idx_t          refill_comp_rob_idx_o,
    output rob_epoch_t        refill_comp_rob_epoch_o,
    output logic [63:0]       refill_comp_data_o,

    // -------------------------------------------------------------------------
    // External Memory Interconnect / Bus Interface
    // -------------------------------------------------------------------------
    // Read Channel (MSHR Refill)
    output logic              bus_rd_req_valid_o,
    output logic [49:0]       bus_rd_req_addr_o,  // PA[55:6]
    output mshr_idx_t         bus_rd_req_tag_o,
    input  logic              bus_rd_req_ready_i,

    input  logic              bus_rd_rsp_valid_i,
    input  mshr_idx_t         bus_rd_rsp_tag_i,
    input  logic [511:0]      bus_rd_rsp_data_i,

    // Write Channel (WBB Dirty Line Eviction)
    output logic              bus_wr_req_valid_o,
    output logic [49:0]       bus_wr_req_addr_o,
    output logic [511:0]      bus_wr_req_data_o,
    input  logic              bus_wr_req_ready_i,

    input  logic              bus_wr_rsp_valid_i,

    // Quiescence Diagnostics (for FENCE serialization)
    output logic              l1d_quiescent_o
);

    // =========================================================================
    // Cache Storage Arrays (16 KiB 4-Way: 64 Sets, 4 Ways, 64 B line)
    // =========================================================================
    // Physical Tag: PA[55:12] (44 bits)
    // Set Index:   PA[11:6]  (6 bits)
    // Line Offset: PA[5:0]   (6 bits)
    logic [43:0]  tag_array   [L1D_SETS][L1D_WAYS];
    logic         valid_array [L1D_SETS][L1D_WAYS];
    logic         dirty_array [L1D_SETS][L1D_WAYS];
    logic [511:0] data_array  [L1D_SETS][L1D_WAYS];
    logic [1:0]   lru_array   [L1D_SETS]; // Pseudo-LRU replacement pointer

    // =========================================================================
    // Writeback Buffer (WBB, 2 Entries) — Section 10
    // =========================================================================
    wbb_entry_t wbb_q [WBB_DEPTH];

    // WBB Available Slots
    wire wbb_slot0_avail = !wbb_q[0].valid;
    wire wbb_slot1_avail = !wbb_q[1].valid;
    wire [1:0] wbb_avail_count = (wbb_slot0_avail ? 2'd1 : 2'd0) + (wbb_slot1_avail ? 2'd1 : 2'd0);
    wire [1:0] wbb_free_count  = (!wbb_q[0].valid ? 2'd1 : 2'd0) + (!wbb_q[1].valid ? 2'd1 : 2'd0);
    wire       store_wbb_target = wbb_slot0_avail ? 1'b0 : 1'b1;
    wire       load_wbb_target  = wbb_slot0_avail ? 1'b0 : 1'b1;

    // WBB Associative Snoop for Loads and Stores (Section 10.2)
    function automatic logic check_wbb_hit(
        input logic [49:0] line_addr,
        output wbb_idx_t   hit_idx
    );
        hit_idx = 1'b0;
        for (int i = 0; i < WBB_DEPTH; i++) begin
            if (wbb_q[i].valid && (wbb_q[i].line_addr == line_addr)) begin
                hit_idx = 1'(i);
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    // =========================================================================
    // MSHR Subsystem (4 Entries) — Section 9
    // =========================================================================
    mshr_entry_t mshr_q [MSHR_DEPTH];
    mshr_waiter_t mshr_waiters_q [MSHR_DEPTH][LQ_DEPTH];

    // MSHR Free Count & Slot Allocator
    logic [2:0] mshr_free_count;
    logic [1:0] mshr_free_slot;
    logic       mshr_free_found;

    always_comb begin
        mshr_free_count = 3'd0;
        mshr_free_slot  = 2'd0;
        mshr_free_found = 1'b0;
        for (int i = 0; i < MSHR_DEPTH; i++) begin
            if (!mshr_q[i].valid) begin
                mshr_free_count = mshr_free_count + 3'd1;
                if (!mshr_free_found) begin
                    mshr_free_slot  = 2'(i);
                    mshr_free_found = 1'b1;
                end
            end
        end
    end

    // Check if a line is already pending in an active MSHR (Line Merging)
    function automatic logic check_mshr_match(
        input logic [49:0] line_addr,
        output mshr_idx_t  match_idx
    );
        match_idx = 2'd0;
        for (int i = 0; i < MSHR_DEPTH; i++) begin
            if (mshr_q[i].valid && (mshr_q[i].line_addr == line_addr)) begin
                match_idx = 2'(i);
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    // =========================================================================
    // Cache Lookup Helper Functions
    // =========================================================================
    function automatic logic check_cache_hit(
        input logic [5:0]  set_idx,
        input logic [43:0] tag,
        output logic [1:0] hit_way
    );
        hit_way = 2'd0;
        for (int w = 0; w < L1D_WAYS; w++) begin
            if (valid_array[set_idx][w] && (tag_array[set_idx][w] == tag)) begin
                hit_way = 2'(w);
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    // Extract 64-bit word from 512-bit cache line
    function automatic logic [63:0] extract_word_from_line(
        input logic [511:0] line_data,
        /* verilator lint_off UNUSEDSIGNAL */
        input logic [5:0]   byte_offset
        /* verilator lint_on UNUSEDSIGNAL */
    );
        logic [2:0] word_idx;
        word_idx = byte_offset[5:3];
        case (word_idx)
            3'd0: return line_data[63:0];
            3'd1: return line_data[127:64];
            3'd2: return line_data[191:128];
            3'd3: return line_data[255:192];
            3'd4: return line_data[319:256];
            3'd5: return line_data[383:320];
            3'd6: return line_data[447:384];
            3'd7: return line_data[511:448];
        endcase
    endfunction

    // Merge store byte write into 512-bit cache line
    function automatic logic [511:0] merge_store_to_line(
        input logic [511:0] old_line,
        input logic [5:0]   byte_offset,
        input logic [7:0]   byte_mask,
        input logic [63:0]  store_data
    );
        logic [511:0] new_line;
        logic [2:0]   word_idx;
        logic [63:0]  old_word;
        logic [63:0]  updated_word;

        word_idx = byte_offset[5:3];
        old_word = extract_word_from_line(old_line, byte_offset);

        for (int b = 0; b < 8; b++) begin
            if (byte_mask[b]) begin
                updated_word[b*8 +: 8] = store_data[b*8 +: 8];
            end else begin
                updated_word[b*8 +: 8] = old_word[b*8 +: 8];
            end
        end

        new_line = old_line;
        case (word_idx)
            3'd0: new_line[63:0]    = updated_word;
            3'd1: new_line[127:64]  = updated_word;
            3'd2: new_line[191:128] = updated_word;
            3'd3: new_line[255:192] = updated_word;
            3'd4: new_line[319:256] = updated_word;
            3'd5: new_line[383:320] = updated_word;
            3'd6: new_line[447:384] = updated_word;
            3'd7: new_line[511:448] = updated_word;
        endcase
        return new_line;
    endfunction

    // =========================================================================
    // Refill Service Pipeline & Multi-Waiter Drain Engine
    // =========================================================================
    // When refill returns from bus:
    // 1. Installs line into cache set and replacement way.
    // Multi-MSHR Concurrent Waiter Drain Engine
    // Each MSHR stores its refill line in mshr_q[m].victim_data upon bus response arrival.
    // Combinational arbiter selects the first MSHR in MSHR_DRAIN_WAITERS with an active waiter.
    logic [1:0] drain_mshr_idx;
    logic [3:0] drain_waiter_idx;
    logic       drain_found;

    always_comb begin
        drain_mshr_idx   = 2'd0;
        drain_waiter_idx = 4'd0;
        drain_found      = 1'b0;

        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (!drain_found && mshr_q[m].valid && (mshr_q[m].state == MSHR_DRAIN_WAITERS)) begin
                for (int w = 0; w < LQ_DEPTH; w++) begin
                    if (!drain_found && mshr_q[m].waiter_mask[w] && mshr_waiters_q[m][w].waiter_valid) begin
                        drain_mshr_idx   = 2'(m);
                        drain_waiter_idx = 4'(w);
                        drain_found      = 1'b1;
                    end
                end
            end
        end
    end

    // Refill Arriving
    wire refill_arriving = bus_rd_rsp_valid_i && mshr_q[bus_rd_rsp_tag_i].valid;

    // Drain Engine State Delivery
    always_comb begin
        logic [63:0] raw_word;
        refill_comp_valid_o     = drain_found;
        refill_comp_lq_idx_o    = drain_waiter_idx;
        refill_comp_pnew_o      = mshr_waiters_q[drain_mshr_idx][drain_waiter_idx].pnew;
        refill_comp_rob_idx_o   = mshr_waiters_q[drain_mshr_idx][drain_waiter_idx].rob_idx;
        refill_comp_rob_epoch_o = mshr_waiters_q[drain_mshr_idx][drain_waiter_idx].rob_epoch;
        raw_word                = 64'd0;

        if (drain_found) begin
            raw_word = extract_word_from_line(mshr_q[drain_mshr_idx].victim_data,
                                              mshr_waiters_q[drain_mshr_idx][drain_waiter_idx].line_offset);
            refill_comp_data_o = format_load_result(
                raw_word,
                mshr_waiters_q[drain_mshr_idx][drain_waiter_idx].line_offset[2:0],
                mshr_waiters_q[drain_mshr_idx][drain_waiter_idx].size,
                mshr_waiters_q[drain_mshr_idx][drain_waiter_idx].sign_ext
            );
        end else begin
            refill_comp_data_o = 64'd0;
        end
    end

    // =========================================================================
    // Arbitration Priority Implementation (Section 8.2)
    // Priority 1: Refill Install
    // Priority 2: Committed Store Drain
    // Priority 3: Speculative Load Issue
    // =========================================================================

    // Refill Install has top priority (1-cycle cache write array occupancy)
    wire cache_busy_refill = refill_arriving;

    // Store Drain Evaluation (Priority 2)
    wire [5:0]  store_set  = store_drain_pa_i[11:6];
    wire [43:0] store_tag  = store_drain_pa_i[55:12];
    wire [49:0] store_line = store_drain_pa_i[55:6];

    logic [1:0] store_cache_hit_way;
    wire store_cache_hit = check_cache_hit(store_set, store_tag, store_cache_hit_way);

    wbb_idx_t store_wbb_idx;
    wire store_in_wbb = check_wbb_hit(store_line, store_wbb_idx);
    wire store_wbb_draining = store_in_wbb && wbb_q[store_wbb_idx].draining;
    wire store_wbb_hit = store_in_wbb && !store_wbb_draining;

    mshr_idx_t store_mshr_match_idx;
    wire store_mshr_match = check_mshr_match(store_line, store_mshr_match_idx);

    // Check for ways in store_set currently reserved by in-flight MSHRs
    logic [3:0] store_set_mshr_reserved_ways;
    always_comb begin
        store_set_mshr_reserved_ways = 4'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr_q[m].valid && (mshr_q[m].line_addr[5:0] == store_set)) begin
                store_set_mshr_reserved_ways[mshr_q[m].victim_way] = 1'b1;
            end
        end
    end

    // Select candidate victim way starting from LRU pointer, skipping in-flight reserved ways
    logic [1:0] store_victim_way;
    always_comb begin
        logic       found_invalid;
        logic [1:0] cand_way;
        store_victim_way = lru_array[store_set];
        found_invalid    = 1'b0;
        cand_way         = 2'd0;
        for (int unsigned k = 0; k < 4; k++) begin
            cand_way = 2'(lru_array[store_set] + 2'(k));
            if (!store_set_mshr_reserved_ways[cand_way] && !valid_array[store_set][cand_way]) begin
                store_victim_way = cand_way;
                found_invalid    = 1'b1;
                break;
            end
        end
        if (!found_invalid) begin
            for (int unsigned k = 0; k < 4; k++) begin
                cand_way = 2'(lru_array[store_set] + 2'(k));
                if (!store_set_mshr_reserved_ways[cand_way]) begin
                    store_victim_way = cand_way;
                    break;
                end
            end
        end
    end

    wire store_victim_is_dirty = valid_array[store_set][store_victim_way] && dirty_array[store_set][store_victim_way];
    wire store_can_alloc_mshr  = (mshr_free_count > 0) && (store_set_mshr_reserved_ways != 4'b1111) &&
                                 !store_in_wbb &&
                                 (!store_victim_is_dirty || (wbb_avail_count > 0));

    // Store can drain if cache hit, WBB hit, matching MSHR, or can allocate MSHR
    wire store_can_drain = store_drain_valid_i && !cache_busy_refill &&
                           (store_cache_hit || store_wbb_hit || store_mshr_match || store_can_alloc_mshr);

    assign store_drain_ready_o = store_can_drain;
    assign store_drain_done_o  = store_drain_valid_i && !cache_busy_refill && (store_cache_hit || store_wbb_hit);

    // Load Request Evaluation (Priority 3)
    wire [5:0]  load_set  = load_req_pa_i[11:6];
    wire [43:0] load_tag  = load_req_pa_i[55:12];
    wire [49:0] load_line = load_req_pa_i[55:6];

    logic [1:0] load_cache_hit_way;
    wire load_cache_hit = check_cache_hit(load_set, load_tag, load_cache_hit_way);

    wbb_idx_t load_wbb_idx;
    wire load_wbb_hit = check_wbb_hit(load_line, load_wbb_idx);

    mshr_idx_t load_mshr_match_idx;
    wire load_mshr_match = check_mshr_match(load_line, load_mshr_match_idx);

    // Check for ways in load_set currently reserved by in-flight MSHRs
    logic [3:0] load_set_mshr_reserved_ways;
    always_comb begin
        load_set_mshr_reserved_ways = 4'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr_q[m].valid && (mshr_q[m].line_addr[5:0] == load_set)) begin
                load_set_mshr_reserved_ways[mshr_q[m].victim_way] = 1'b1;
            end
        end
    end

    // Select candidate victim way starting from LRU pointer, skipping in-flight reserved ways
    logic [1:0] load_victim_way;
    always_comb begin
        logic       found_invalid;
        logic [1:0] cand_way;
        load_victim_way = lru_array[load_set];
        found_invalid   = 1'b0;
        cand_way        = 2'd0;
        for (int unsigned k = 0; k < 4; k++) begin
            cand_way = 2'(lru_array[load_set] + 2'(k));
            if (!load_set_mshr_reserved_ways[cand_way] && !valid_array[load_set][cand_way]) begin
                load_victim_way = cand_way;
                found_invalid   = 1'b1;
                break;
            end
        end
        if (!found_invalid) begin
            for (int unsigned k = 0; k < 4; k++) begin
                cand_way = 2'(lru_array[load_set] + 2'(k));
                if (!load_set_mshr_reserved_ways[cand_way]) begin
                    load_victim_way = cand_way;
                    break;
                end
            end
        end
    end

    // Can allocate new MSHR: requires free MSHR slot, unreserved way in set.
    // If replacement victim is dirty, ALSO requires free unreserved WBB slot for pre-reservation (Section 10.1)!
    wire load_victim_is_dirty = valid_array[load_set][load_victim_way] && dirty_array[load_set][load_victim_way];
    wire load_can_alloc_mshr = (mshr_free_count > 0) && (load_set_mshr_reserved_ways != 4'b1111) &&
                               (!load_victim_is_dirty || (wbb_avail_count > 0));

    // Load can accept if no higher priority request blocks and either hits or can merge/allocate MSHR
    wire load_accept = load_req_valid_i && !cache_busy_refill && !store_can_drain &&
                       (load_cache_hit || load_wbb_hit || load_mshr_match || load_can_alloc_mshr);

    assign load_req_ready_o = load_accept;

    // Load Hit Response Formatting
    always_comb begin
        logic [63:0] raw_word;
        load_rsp_valid_o   = load_accept;
        load_rsp_lq_idx_o  = load_req_lq_idx_i;
        load_rsp_hit_o     = load_cache_hit || load_wbb_hit;
        load_rsp_data_o    = 64'd0;
        load_rsp_mshr_id_o = load_mshr_match ? load_mshr_match_idx : mshr_free_slot;
        raw_word           = 64'd0;

        if (load_cache_hit) begin
            raw_word = extract_word_from_line(data_array[load_set][load_cache_hit_way], load_req_pa_i[5:0]);
            load_rsp_data_o = format_load_result(raw_word, load_req_pa_i[2:0], load_req_size_i, load_req_sign_ext_i);
        end else if (load_wbb_hit) begin
            // Read directly from WBB payload buffer (Section 10.2)
            raw_word = extract_word_from_line(wbb_q[load_wbb_idx].data, load_req_pa_i[5:0]);
            load_rsp_data_o = format_load_result(raw_word, load_req_pa_i[2:0], load_req_size_i, load_req_sign_ext_i);
        end
    end

    // =========================================================================
    // External Bus Interface Logic
    // =========================================================================
    // Launch read request for MSHRs in WAIT_BUS state
    logic [1:0] bus_req_mshr_idx;
    logic       bus_req_mshr_found;

    always_comb begin
        bus_req_mshr_idx   = 2'd0;
        bus_req_mshr_found = 1'b0;
        for (int i = 0; i < MSHR_DEPTH; i++) begin
            if (mshr_q[i].valid && (mshr_q[i].state == MSHR_WAIT_BUS)) begin
                if (!bus_req_mshr_found) begin
                    bus_req_mshr_idx   = 2'(i);
                    bus_req_mshr_found = 1'b1;
                end
            end
        end
    end

    assign bus_rd_req_valid_o = bus_req_mshr_found;
    assign bus_rd_req_addr_o  = mshr_q[bus_req_mshr_idx].line_addr;
    assign bus_rd_req_tag_o   = bus_req_mshr_idx;

    // In-flight bus write tracking
    logic       bus_wr_inflight_q;
    wbb_idx_t   bus_wr_inflight_slot_q;

    // Launch writeback for dirty WBB entry (only if no bus write is currently in-flight)
    logic bus_wr_valid;
    wbb_idx_t bus_wr_slot;

    always_comb begin
        bus_wr_valid = 1'b0;
        bus_wr_slot  = 1'b0;
        if (!bus_wr_inflight_q) begin
            for (int i = 0; i < WBB_DEPTH; i++) begin
                if (wbb_q[i].valid && wbb_q[i].dirty && !wbb_q[i].draining) begin
                    if (store_drain_valid_i && store_wbb_hit && (store_wbb_idx == 1'(i))) begin
                        continue;
                    end
                    bus_wr_valid = 1'b1;
                    bus_wr_slot  = 1'(i);
                    break;
                end
            end
        end
    end

    assign bus_wr_req_valid_o = bus_wr_valid;
    assign bus_wr_req_addr_o  = wbb_q[bus_wr_slot].line_addr;
    assign bus_wr_req_data_o  = wbb_q[bus_wr_slot].data;

    // Quiescence Diagnostics
    assign l1d_quiescent_o = (mshr_free_count == 3'd4) && (wbb_free_count == 2'd2) && !drain_found && !bus_wr_inflight_q;

    // =========================================================================
    // Sequential State Management (Cache Arrays, MSHRs, WBB, LRU)
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int s = 0; s < L1D_SETS; s++) begin
                lru_array[s] <= 2'd0;
                for (int w = 0; w < L1D_WAYS; w++) begin
                    valid_array[s][w] <= 1'b0;
                    dirty_array[s][w] <= 1'b0;
                    tag_array[s][w]   <= '0;
                    data_array[s][w]  <= '0;
                end
            end

            for (int i = 0; i < MSHR_DEPTH; i++) begin
                mshr_q[i] <= '0;
                for (int w = 0; w < LQ_DEPTH; w++) begin
                    mshr_waiters_q[i][w] <= '0;
                end
            end

            for (int i = 0; i < WBB_DEPTH; i++) begin
                wbb_q[i] <= '0;
            end
            bus_wr_inflight_q      <= 1'b0;
            bus_wr_inflight_slot_q <= '0;
        end else begin
            // -----------------------------------------------------------------
            // 1. Bus Writeback Response Handshake
            // -----------------------------------------------------------------
            if (bus_wr_inflight_q) begin
                if (bus_wr_rsp_valid_i) begin
                    wbb_q[bus_wr_inflight_slot_q].valid    <= 1'b0;
                    wbb_q[bus_wr_inflight_slot_q].dirty    <= 1'b0;
                    wbb_q[bus_wr_inflight_slot_q].draining <= 1'b0;
                    bus_wr_inflight_q                      <= 1'b0;
                end
            end else if (bus_wr_req_valid_o && bus_wr_req_ready_i) begin
                if (bus_wr_rsp_valid_i) begin
                    // Immediate single-cycle writeback response
                    wbb_q[bus_wr_slot].valid    <= 1'b0;
                    wbb_q[bus_wr_slot].dirty    <= 1'b0;
                    wbb_q[bus_wr_slot].draining <= 1'b0;
                    bus_wr_inflight_q           <= 1'b0;
                end else begin
                    // Multi-cycle writeback in-flight
                    wbb_q[bus_wr_slot].draining <= 1'b1;
                    bus_wr_inflight_q           <= 1'b1;
                    bus_wr_inflight_slot_q      <= bus_wr_slot;
                end
            end

            // -----------------------------------------------------------------
            // 2. Bus Read Request Handshake
            // -----------------------------------------------------------------
            if (bus_rd_req_valid_o && bus_rd_req_ready_i) begin
                mshr_q[bus_req_mshr_idx].state <= MSHR_REQ_SENT;
            end

            // -----------------------------------------------------------------
            // 3. Selective Waiter Squash on Branch Recovery (Section 9.1)
            // -----------------------------------------------------------------
            if (recover_valid_i) begin
                for (int m = 0; m < MSHR_DEPTH; m++) begin
                    if (mshr_q[m].valid) begin
                        for (int w = 0; w < LQ_DEPTH; w++) begin
                            if (mshr_q[m].waiter_mask[w] && mshr_waiters_q[m][w].waiter_valid) begin
                                if (rob_dist(mshr_waiters_q[m][w].rob_idx, rob_head_i) >
                                    rob_dist(recover_rob_idx_i, rob_head_i)) begin
                                    mshr_q[m].waiter_mask[w]              <= 1'b0;
                                    mshr_waiters_q[m][w].waiter_valid   <= 1'b0;
                                end
                            end
                        end
                    end
                end
            end

            // Full flush clears speculative load waiters (preserves committed store drains)
            if (flush_valid_i) begin
                for (int m = 0; m < MSHR_DEPTH; m++) begin
                    if (mshr_q[m].valid) begin
                        mshr_q[m].waiter_mask <= 16'd0;
                        for (int w = 0; w < LQ_DEPTH; w++) begin
                            mshr_waiters_q[m][w].waiter_valid <= 1'b0;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            // 4. Refill Arriving & Cache Installation (Priority 1)
            // -----------------------------------------------------------------
            if (refill_arriving) begin
                mshr_idx_t m_idx;
                logic [5:0] set_i;
                logic [43:0] tag_i;
                logic [1:0] rep_way;

                m_idx = bus_rd_rsp_tag_i;
                set_i = mshr_q[m_idx].line_addr[5:0];
                tag_i = mshr_q[m_idx].line_addr[49:6];
                rep_way = mshr_q[m_idx].victim_way; // P0-4: Frozen victim way captured at miss allocation!

                // Install newly arrived line into cache at frozen rep_way
                valid_array[set_i][rep_way] <= 1'b1;
                dirty_array[set_i][rep_way] <= 1'b0;
                tag_array[set_i][rep_way]   <= tag_i;
                data_array[set_i][rep_way]  <= bus_rd_rsp_data_i;

                // Capture line data into MSHR storage for waiter draining
                mshr_q[m_idx].victim_data <= bus_rd_rsp_data_i;

                if (mshr_q[m_idx].waiter_mask != 16'd0) begin
                    mshr_q[m_idx].state <= MSHR_DRAIN_WAITERS;
                end else begin
                    // No waiters to drain (e.g. store write-allocate or all waiters squashed)
                    mshr_q[m_idx].valid <= 1'b0;
                    mshr_q[m_idx].state <= MSHR_IDLE;
                end
            end

            // Service active waiter step (drain to Port 2 writeback)
            if (drain_found) begin
                logic [15:0] remaining_waiters;
                remaining_waiters = mshr_q[drain_mshr_idx].waiter_mask & ~(16'h1 << drain_waiter_idx);
                mshr_q[drain_mshr_idx].waiter_mask[drain_waiter_idx] <= 1'b0;
                mshr_waiters_q[drain_mshr_idx][drain_waiter_idx].waiter_valid <= 1'b0;
                if (remaining_waiters == 16'd0) begin
                    mshr_q[drain_mshr_idx].valid <= 1'b0;
                    mshr_q[drain_mshr_idx].state <= MSHR_IDLE;
                end
            end

            // Clean up any MSHRs in MSHR_DRAIN_WAITERS whose waiters were completely squashed
            for (int m = 0; m < MSHR_DEPTH; m++) begin
                if (mshr_q[m].valid && (mshr_q[m].state == MSHR_DRAIN_WAITERS)) begin
                    if ((mshr_q[m].waiter_mask == 16'd0) ||
                        (flush_valid_i) ||
                        (drain_found && (drain_mshr_idx == 2'(m)) &&
                         ((mshr_q[m].waiter_mask & ~(16'h1 << drain_waiter_idx)) == 16'd0))) begin
                        mshr_q[m].valid <= 1'b0;
                        mshr_q[m].state <= MSHR_IDLE;
                    end
                end
            end

            // -----------------------------------------------------------------
            // 5. Committed Store Drain Execution (Priority 2)
            // -----------------------------------------------------------------
            if (store_can_drain) begin
                if (store_cache_hit) begin
                    data_array[store_set][store_cache_hit_way]  <= merge_store_to_line(
                        data_array[store_set][store_cache_hit_way],
                        store_drain_pa_i[5:0],
                        store_drain_mask_i,
                        store_drain_data_i
                    );
                    dirty_array[store_set][store_cache_hit_way] <= 1'b1;
                end else if (store_wbb_hit) begin
                    wbb_q[store_wbb_idx].data <= merge_store_to_line(
                        wbb_q[store_wbb_idx].data,
                        store_drain_pa_i[5:0],
                        store_drain_mask_i,
                        store_drain_data_i
                    );
                    wbb_q[store_wbb_idx].dirty <= 1'b1;
                end else if (store_mshr_match) begin
                    mshr_q[store_mshr_match_idx].store_drain_mask[store_drain_sq_idx_i] <= 1'b1;
                end else if (store_can_alloc_mshr) begin
                    // Allocate write-allocate MSHR for store
                    mshr_q[mshr_free_slot].valid               <= 1'b1;
                    mshr_q[mshr_free_slot].line_addr           <= store_line;
                    mshr_q[mshr_free_slot].state               <= MSHR_WAIT_BUS;
                    mshr_q[mshr_free_slot].bus_tag             <= mshr_free_slot;
                    mshr_q[mshr_free_slot].waiter_mask         <= 16'd0;
                    mshr_q[mshr_free_slot].store_drain_mask    <= (16'd1 << store_drain_sq_idx_i);
                    mshr_q[mshr_free_slot].wbb_has_reservation <= 1'b0;
                    mshr_q[mshr_free_slot].wbb_reserved_slot   <= '0;
                    mshr_q[mshr_free_slot].victim_way          <= store_victim_way;
                    mshr_q[mshr_free_slot].victim_tag          <= tag_array[store_set][store_victim_way];
                    mshr_q[mshr_free_slot].victim_data         <= data_array[store_set][store_victim_way];
                    mshr_q[mshr_free_slot].victim_dirty        <= store_victim_is_dirty;

                    // If victim is dirty, immediately move to WBB (authoritative dirty owner, Section 10.1 & 10.2)
                    if (store_victim_is_dirty) begin
                        wbb_q[store_wbb_target].valid      <= 1'b1;
                        wbb_q[store_wbb_target].dirty      <= 1'b1;
                        wbb_q[store_wbb_target].draining   <= 1'b0;
                        wbb_q[store_wbb_target].line_addr  <= {tag_array[store_set][store_victim_way], store_set};
                        wbb_q[store_wbb_target].data       <= data_array[store_set][store_victim_way];
                        wbb_q[store_wbb_target].dirty_mask <= '1;
                    end
                    // Invalidate victim way in L1D immediately to isolate replacement way from subsequent writes
                    valid_array[store_set][store_victim_way] <= 1'b0;
                    dirty_array[store_set][store_victim_way] <= 1'b0;

                    lru_array[store_set] <= store_victim_way + 2'd1;
                end
            end

            // -----------------------------------------------------------------
            // 6. Speculative Load Issue Execution (Priority 3)
            // -----------------------------------------------------------------
            if (load_accept) begin
                if (load_cache_hit) begin
                    // Hit: update LRU
                    lru_array[load_set] <= load_cache_hit_way + 2'd1;
                end else if (load_wbb_hit) begin
                    // Hit in WBB: no state change needed
                end else if (load_mshr_match) begin
                    // Merge into active MSHR (Section 9.2)
                    mshr_q[load_mshr_match_idx].waiter_mask[load_req_lq_idx_i] <= 1'b1;
                    mshr_waiters_q[load_mshr_match_idx][load_req_lq_idx_i].waiter_valid <= 1'b1;
                    mshr_waiters_q[load_mshr_match_idx][load_req_lq_idx_i].lq_idx       <= load_req_lq_idx_i;
                    mshr_waiters_q[load_mshr_match_idx][load_req_lq_idx_i].line_offset  <= load_req_pa_i[5:0];
                    mshr_waiters_q[load_mshr_match_idx][load_req_lq_idx_i].size         <= load_req_size_i;
                    mshr_waiters_q[load_mshr_match_idx][load_req_lq_idx_i].sign_ext     <= load_req_sign_ext_i;
                    mshr_waiters_q[load_mshr_match_idx][load_req_lq_idx_i].pnew         <= load_req_pnew_i;
                    mshr_waiters_q[load_mshr_match_idx][load_req_lq_idx_i].rob_idx      <= load_req_rob_idx_i;
                    mshr_waiters_q[load_mshr_match_idx][load_req_lq_idx_i].rob_epoch    <= load_req_rob_epoch_i;
                end else if (load_can_alloc_mshr) begin
                    // Allocate new MSHR (Section 9)
                    mshr_q[mshr_free_slot].valid               <= 1'b1;
                    mshr_q[mshr_free_slot].line_addr           <= load_line;
                    mshr_q[mshr_free_slot].state               <= MSHR_WAIT_BUS;
                    mshr_q[mshr_free_slot].bus_tag             <= mshr_free_slot;
                    mshr_q[mshr_free_slot].waiter_mask         <= (16'd1 << load_req_lq_idx_i);
                    mshr_q[mshr_free_slot].store_drain_mask    <= 16'd0;
                    mshr_q[mshr_free_slot].wbb_has_reservation <= 1'b0;
                    mshr_q[mshr_free_slot].wbb_reserved_slot   <= '0;
                    mshr_q[mshr_free_slot].victim_way          <= load_victim_way;
                    mshr_q[mshr_free_slot].victim_tag          <= tag_array[load_set][load_victim_way];
                    mshr_q[mshr_free_slot].victim_data         <= data_array[load_set][load_victim_way];
                    mshr_q[mshr_free_slot].victim_dirty        <= load_victim_is_dirty;

                    // If victim is dirty, immediately move to WBB (authoritative dirty owner, Section 10.1 & 10.2)
                    if (load_victim_is_dirty) begin
                        wbb_q[load_wbb_target].valid      <= 1'b1;
                        wbb_q[load_wbb_target].dirty      <= 1'b1;
                        wbb_q[load_wbb_target].draining   <= 1'b0;
                        wbb_q[load_wbb_target].line_addr  <= {tag_array[load_set][load_victim_way], load_set};
                        wbb_q[load_wbb_target].data       <= data_array[load_set][load_victim_way];
                        wbb_q[load_wbb_target].dirty_mask <= '1;
                    end
                    // Invalidate victim way in L1D immediately to isolate replacement way from subsequent writes
                    valid_array[load_set][load_victim_way] <= 1'b0;
                    dirty_array[load_set][load_victim_way] <= 1'b0;

                    lru_array[load_set] <= load_victim_way + 2'd1;

                    mshr_waiters_q[mshr_free_slot][load_req_lq_idx_i].waiter_valid <= 1'b1;
                    mshr_waiters_q[mshr_free_slot][load_req_lq_idx_i].lq_idx       <= load_req_lq_idx_i;
                    mshr_waiters_q[mshr_free_slot][load_req_lq_idx_i].line_offset  <= load_req_pa_i[5:0];
                    mshr_waiters_q[mshr_free_slot][load_req_lq_idx_i].size         <= load_req_size_i;
                    mshr_waiters_q[mshr_free_slot][load_req_lq_idx_i].sign_ext     <= load_req_sign_ext_i;
                    mshr_waiters_q[mshr_free_slot][load_req_lq_idx_i].pnew         <= load_req_pnew_i;
                    mshr_waiters_q[mshr_free_slot][load_req_lq_idx_i].rob_idx      <= load_req_rob_idx_i;
                    mshr_waiters_q[mshr_free_slot][load_req_lq_idx_i].rob_epoch    <= load_req_rob_epoch_i;
                end
            end
        end
    end
`ifndef SYNTHESIS
    // Simulation Assertions (Section 17.3)
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            // Assertion 6: MSHR must never overflow
            if (load_req_valid_i && !load_cache_hit && !load_wbb_hit && !load_mshr_match && (mshr_free_count == 0) && load_accept) begin
                $fatal(1, "[L1D ASSERTION FAILED] MSHR overflowed!");
            end
            // Assertion 7: WBB must never overflow on load miss allocation
            if (load_req_valid_i && load_can_alloc_mshr && load_victim_is_dirty && (wbb_avail_count == 0) && load_accept) begin
                $fatal(1, "[L1D ASSERTION FAILED] WBB load allocation overflowed!");
            end
            // Assertion 7b: WBB must never overflow on store miss allocation
            if (store_drain_valid_i && store_can_alloc_mshr && store_victim_is_dirty && (wbb_avail_count == 0) && store_can_drain) begin
                $fatal(1, "[L1D ASSERTION FAILED] WBB store allocation overflowed!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_L1D_SV
