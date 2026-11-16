`ifndef FURSOY_S1_L1D_SV
`define FURSOY_S1_L1D_SV

// =============================================================================
// Fursoy Slice-1 4-Banked Non-Blocking L1 Data Cache (L1D) Subsystem — Milestone 7
// =============================================================================
// Reference: docs/architecture/slice1-m7-multibank-l1d-v1.md Sections 6, 8, 9, 10
//
// Key Architectural Features:
// - 16 KiB 4-Way Set-Associative (64 sets x 64 B line = 4096 B/way, VIPT synonym safe).
// - 4 independent single-port 64-bit SRAM banks (Bank 0: DW0/DW4, Bank 1: DW1/DW5,
//   Bank 2: DW2/DW6, Bank 3: DW3/DW7; 4 KiB/bank, 16 KiB total data array).
// - Bank Addressing: Bank_ID = PA[4:3], Sub-DW = PA[5], Set_Index = PA[11:6], Line_Offset = PA[2:0].
// - Register-based Tag arrays (64x4x44 bits) providing multi-ported parallel read access
//   for AGU0, AGU1, and snoop without tag bank conflicts.
// - 2-Cycle Multi-Beat Refill Sequence: Beat 0 writes lower 256b (DW0..3) across Banks 0..3;
//   Beat 1 writes upper 256b (DW4..7) across Banks 0..3; pipeline stalls for exactly 2 cycles.
// - Age-Aware Dynamic Bank Conflict Resolution:
//     * Different banks: concurrent access without stall.
//     * Same bank, identical DW: broadcast read data to both AGU0 and AGU1 with zero stall.
//     * Same bank, distinct DWs: older uop wins by circular ROB distance (rob_dist),
//       younger stalls in Stage M1 and replays; replaying Port 3 has anti-starvation priority.
//     * Store drain strictly wins priority over colliding load on same bank.
// - Dual-miss MSHR arbitration: AGU0 allocates MSHR in cycle 0; AGU1 stalls in M1 and allocates in cycle 1.
// - 4 MSHRs with per-waiter active descriptors and selective waiter squash.
// - 2-entry Writeback Buffer (WBB) with pre-reservation at miss allocation time.
// - Protocol-neutral coherent snoop interface (SNOOP_INV, SNOOP_READ, SNOOP_CLEAN_INV).
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
    // Core Speculative Load Request Interface — Port 2 / AGU0 (Priority 5)
    // -------------------------------------------------------------------------
    input  logic              load0_req_valid_i,
    input  lq_idx_t           load0_req_lq_idx_i,
    input  logic [55:0]       load0_req_pa_i,
    input  mem_size_t         load0_req_size_i,
    input  logic              load0_req_sign_ext_i,
    input  preg_t             load0_req_pnew_i,
    input  rob_idx_t          load0_req_rob_idx_i,
    input  rob_epoch_t        load0_req_rob_epoch_i,
    output logic              load0_req_ready_o,

    // Immediate Hit Response for Port 2 / AGU0
    output logic              load0_rsp_valid_o,
    output lq_idx_t           load0_rsp_lq_idx_o,
    output logic              load0_rsp_hit_o,
    output logic [63:0]       load0_rsp_data_o,
    output mshr_idx_t         load0_rsp_mshr_id_o,

    // -------------------------------------------------------------------------
    // Core Speculative Load Request Interface — Port 3 / AGU1 (Priority 6)
    // -------------------------------------------------------------------------
    input  logic              load1_req_valid_i,
    input  lq_idx_t           load1_req_lq_idx_i,
    input  logic [55:0]       load1_req_pa_i,
    input  mem_size_t         load1_req_size_i,
    input  logic              load1_req_sign_ext_i,
    input  preg_t             load1_req_pnew_i,
    input  rob_idx_t          load1_req_rob_idx_i,
    input  rob_epoch_t        load1_req_rob_epoch_i,
    output logic              load1_req_ready_o,

    // Immediate Hit Response for Port 3 / AGU1
    output logic              load1_rsp_valid_o,
    output lq_idx_t           load1_rsp_lq_idx_o,
    output logic              load1_rsp_hit_o,
    output logic [63:0]       load1_rsp_data_o,
    output mshr_idx_t         load1_rsp_mshr_id_o,

    // -------------------------------------------------------------------------
    // Core Committed Store Drain Request Interface (Priority 3)
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

    // Maintenance Interface (M4 FENCE.I L1D clean-all)
    input  logic              dcache_clean_all_req_i,
    output logic              dcache_clean_all_done_o,

    // Quiescence Diagnostics (for FENCE serialization)
    output logic              l1d_quiescent_o,

    // Observability & Telemetry (Milestone 5 & Milestone 7)
    output logic              event_l1d_hit_o,
    output logic              event_l1d_miss_o,
    output logic [1:0]        event_l1d_miss_cold_o,
    output logic [1:0]        event_l1d_miss_conflict_o,
    output logic [1:0]        event_l1d_dirty_evict_o,
    output logic [2:0]        mshr_occ_o,
    output logic              wbb_full_o,
    output logic [1:0]        event_bank_access_count_o,
    output logic              event_bank_conflict_o,
    output logic              event_bank_broadcast_o,
    output logic              event_store_drain_concurrent_o,
    output logic              event_snoop_query_o,
    output logic              event_snoop_hit_o,

    // -------------------------------------------------------------------------
    // External Coherence Snoop Channels (Milestone 7 Section 8.2)
    // -------------------------------------------------------------------------
    input  logic              snoop_req_valid_i,
    input  logic [49:0]       snoop_req_addr_i,     // PA[55:6] 64-byte line address
    input  logic [1:0]        snoop_req_type_i,     // 2'b00: SNOOP_INV, 2'b01: SNOOP_READ, 2'b10: SNOOP_CLEAN_INV
    output logic              snoop_req_ready_o,

    output logic              snoop_rsp_valid_o,
    output logic              snoop_rsp_has_data_o, // 1 = Dirty line returned
    output logic [511:0]      snoop_rsp_data_o,     // 64-byte payload
    output logic              snoop_rsp_was_dirty_o,

    // Hardware PTW Coherent Dirty-Line Snoop (Read-Only, Non-Destructive)
    input  logic [55:0]       ptw_snoop_pa_i,
    output logic              ptw_snoop_dirty_hit_o,
    output logic [63:0]       ptw_snoop_data_o
);

    // =========================================================================
    // Cache Storage Arrays (16 KiB 4-Way: 64 Sets, 4 Ways, 64 B line, 8 Banks)
    // =========================================================================
    // Physical Tag: PA[55:12] (44 bits)
    // Set Index:   PA[11:6]  (6 bits)
    // Bank ID:     PA[5:3]   (3 bits: Bank 0..7 = DW0..DW7)
    // Byte Offset: PA[2:0]   (3 bits)
    logic [43:0]  tag_array   [L1D_SETS][L1D_WAYS];
    logic         valid_array [L1D_SETS][L1D_WAYS];
    logic         dirty_array [L1D_SETS][L1D_WAYS];
    logic [2:0]   lru_array   [L1D_SETS]; // 3-bit Tree-PLRU replacement state per set

    // 8 Independent Physical 64-bit SRAM Banks (Stage 2 IPC: 8 banks x 64 sets x 4 ways x 64 bits = 16 KiB)
    logic [63:0] bank_data [8][L1D_SETS][L1D_WAYS];

    // Helper: read full 512-bit cache line across all 8 banks
    function automatic logic [511:0] read_cache_line(
        input logic [5:0] set_idx,
        input logic [1:0] way_idx
    );
        logic [511:0] line;
        line[63:0]    = bank_data[0][set_idx][way_idx];
        line[127:64]  = bank_data[1][set_idx][way_idx];
        line[191:128] = bank_data[2][set_idx][way_idx];
        line[255:192] = bank_data[3][set_idx][way_idx];
        line[319:256] = bank_data[4][set_idx][way_idx];
        line[383:320] = bank_data[5][set_idx][way_idx];
        line[447:384] = bank_data[6][set_idx][way_idx];
        line[511:448] = bank_data[7][set_idx][way_idx];
        return line;
    endfunction

    // 4-way 3-bit Tree-PLRU helpers: b[2]=root (0->{0,1}, 1->{2,3}),
    // b[1]=left {0,1} (0->0, 1->1), b[0]=right {2,3} (0->2, 1->3).
    function automatic logic [1:0] tree_plru_victim(input logic [2:0] plru_bits);
        return plru_bits[2] ? (plru_bits[0] ? 2'd3 : 2'd2)
                            : (plru_bits[1] ? 2'd1 : 2'd0);
    endfunction

    function automatic logic [2:0] update_tree_plru(
        input logic [2:0] cur_plru,
        input logic [1:0] way
    );
        logic [2:0] nxt;
        nxt = cur_plru;
        case (way)
            2'd0: begin nxt[2] = 1'b1; nxt[1] = 1'b1; end
            2'd1: begin nxt[2] = 1'b1; nxt[1] = 1'b0; end
            2'd2: begin nxt[2] = 1'b0; nxt[0] = 1'b1; end
            2'd3: begin nxt[2] = 1'b0; nxt[0] = 1'b0; end
        endcase
        return nxt;
    endfunction

    // Returns {found_invalid, victim_way} preferring unreserved invalid ways first,
    // then the Tree-PLRU victim way (falling back to any unreserved way).
    function automatic logic [2:0] select_victim_way(
        input logic [5:0] set_idx,
        input logic [3:0] reserved_ways
    );
        logic [1:0] base_victim;
        logic [1:0] victim_way;
        logic       found_invalid;
        logic [1:0] cand_way;

        base_victim   = tree_plru_victim(lru_array[set_idx]);
        victim_way    = base_victim;
        found_invalid = 1'b0;
        for (int unsigned k = 0; k < 4; k++) begin
            cand_way = 2'(base_victim + 2'(k));
            if (!reserved_ways[cand_way] && !valid_array[set_idx][cand_way]) begin
                victim_way    = cand_way;
                found_invalid = 1'b1;
                break;
            end
        end
        if (!found_invalid) begin
            for (int unsigned k = 0; k < 4; k++) begin
                cand_way = 2'(base_victim + 2'(k));
                if (!reserved_ways[cand_way]) begin
                    victim_way = cand_way;
                    break;
                end
            end
        end
        return {found_invalid, victim_way};
    endfunction

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
    wire       load0_wbb_target = wbb_slot0_avail ? 1'b0 : 1'b1;
    wire       load1_wbb_target = wbb_slot0_avail ? 1'b0 : 1'b1;

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
    logic [MSHR_DEPTH-1:0] mshr_snoop_invalid_q;
    mshr_waiter_t mshr_waiters_q [MSHR_DEPTH][LQ_DEPTH];

    assign mshr_occ_o = (mshr_q[0].valid ? 3'd1 : 3'd0) +
                        (mshr_q[1].valid ? 3'd1 : 3'd0) +
                        (mshr_q[2].valid ? 3'd1 : 3'd0) +
                        (mshr_q[3].valid ? 3'd1 : 3'd0);
    assign wbb_full_o = wbb_q[0].valid && wbb_q[1].valid;

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
    // Exclude MSHR_DRAIN_WAITERS so requests never merge into a deallocating MSHR.
    function automatic logic check_mshr_match(
        input logic [49:0] line_addr,
        output mshr_idx_t  match_idx
    );
        match_idx = 2'd0;
        for (int i = 0; i < MSHR_DEPTH; i++) begin
            if (mshr_q[i].valid && (mshr_q[i].state != MSHR_DRAIN_WAITERS) && (mshr_q[i].line_addr == line_addr)) begin
                match_idx = 2'(i);
                return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    // =========================================================================
    // Clean-All Sweep Maintenance FSM (Milestone 4 FENCE.I)
    // =========================================================================
    typedef enum logic [1:0] {
        CLEAN_IDLE  = 2'd0,
        CLEAN_SWEEP = 2'd1,
        CLEAN_DRAIN = 2'd2,
        CLEAN_DONE  = 2'd3
    } clean_state_t;

    clean_state_t clean_state_q;
    logic [5:0]   clean_set_q;
    logic [1:0]   clean_way_q;

    assign dcache_clean_all_done_o = (clean_state_q == CLEAN_DONE);

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

    // Extract 64-bit word from 512-bit cache line (for WBB snooping)
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

    // Merge store byte write into 512-bit line (for WBB hits)
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

    // Format sub-word load result according to size, sign extension and byte offset
    function automatic logic [63:0] format_load_result_func(
        input logic [63:0] raw_word,
        input logic [2:0]  byte_offset,
        input mem_size_t   size,
        input logic        sign_ext
    );
        logic [63:0] shifted;
        shifted = raw_word >> (byte_offset * 8);
        case (size)
            MEM_SIZE_BYTE:   return sign_ext ? {{56{shifted[7]}}, shifted[7:0]} : {56'd0, shifted[7:0]};
            MEM_SIZE_HALF:   return sign_ext ? {{48{shifted[15]}}, shifted[15:0]} : {48'd0, shifted[15:0]};
            MEM_SIZE_WORD:   return sign_ext ? {{32{shifted[31]}}, shifted[31:0]} : {32'd0, shifted[31:0]};
            MEM_SIZE_DOUBLE: return shifted;
            default:         return shifted;
        endcase
    endfunction

    // Check natural alignment
    function automatic logic is_naturally_misaligned(
        /* verilator lint_off UNUSEDSIGNAL */
        input logic [55:0] pa,
        /* verilator lint_on UNUSEDSIGNAL */
        input mem_size_t   size
    );
        case (size)
            MEM_SIZE_HALF:   return pa[0];
            MEM_SIZE_WORD:   return (pa[1:0] != 2'b00);
            MEM_SIZE_DOUBLE: return (pa[2:0] != 3'b000);
            default:         return 1'b0;
        endcase
    endfunction

    // =========================================================================
    // 2-Cycle Multi-Beat Refill Sequence Pipeline (§6.3, P0-1, PROP_M7_16)
    // =========================================================================
    // Cycle 1 (Beat 0): Write DW0..3 (PA[5] == 0) across Banks 0..3.
    // Cycle 2 (Beat 1): Write DW4..7 (PA[5] == 1) across Banks 0..3, update tags.
    // Pipeline is interlocked for exactly 2 cycles.
    logic        refill_busy_q;
    mshr_idx_t   refill_tag_q;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [511:0]refill_data_q;
    /* verilator lint_on UNUSEDSIGNAL */

    // DRAM Refill Response Buffer (absorbs back-to-back DRAM responses)
    typedef struct packed {
        mshr_idx_t    tag;
        logic [511:0] data;
    } refill_rsp_entry_t;

    refill_rsp_entry_t rsp_fifo_q [MSHR_DEPTH];
    logic [1:0] rsp_fifo_head_q;
    logic [1:0] rsp_fifo_tail_q;
    logic [2:0] rsp_fifo_count_q;

    wire refill_arriving = bus_rd_rsp_valid_i && mshr_q[bus_rd_rsp_tag_i].valid;
    wire cache_busy_refill = (rsp_fifo_count_q != 3'd0) || refill_arriving || refill_busy_q;

    // Multi-MSHR Concurrent Waiter Drain Engine
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
                    if (!drain_found && mshr_q[m].waiter_mask[w] && mshr_waiters_q[m][w].waiter_valid &&
                        !flush_valid_i &&
                        !(recover_valid_i && (rob_dist(mshr_waiters_q[m][w].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i)))) begin
                        drain_mshr_idx   = 2'(m);
                        drain_waiter_idx = 4'(w);
                        drain_found      = 1'b1;
                    end
                end
            end
        end
    end

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
            refill_comp_data_o = format_load_result_func(
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
    // External Coherence Snoop Evaluation (§6.3, §8.2, §8.3)
    // Priority: Snoop Invalidate > Refill Install > Store Drain > Snoop Dirty Readout
    // =========================================================================
    wire [5:0]  snoop_set  = snoop_req_addr_i[5:0];
    wire [43:0] snoop_tag  = snoop_req_addr_i[49:6];
    logic [1:0] snoop_hit_way;
    wire        snoop_cache_hit = snoop_req_valid_i && check_cache_hit(snoop_set, snoop_tag, snoop_hit_way);

    wbb_idx_t   snoop_wbb_idx;
    wire        snoop_wbb_hit   = snoop_req_valid_i && check_wbb_hit(snoop_req_addr_i, snoop_wbb_idx);

    /* verilator lint_off UNUSEDSIGNAL */
    mshr_idx_t  snoop_mshr_match_idx;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        snoop_mshr_hit  = snoop_req_valid_i && check_mshr_match(snoop_req_addr_i, snoop_mshr_match_idx);

    assign event_snoop_query_o  = snoop_req_valid_i;
    assign event_snoop_hit_o    = snoop_req_valid_i && (snoop_cache_hit || snoop_wbb_hit || snoop_mshr_hit);

    wire snoop_do_read = (snoop_req_type_i[1] == 1'b1);
    wire snoop_do_inv  = (snoop_req_type_i[0] == 1'b1) || (snoop_req_type_i == 2'b00);

    wire snoop_is_dirty = (snoop_cache_hit && dirty_array[snoop_set][snoop_hit_way]) ||
                          (snoop_wbb_hit && wbb_q[snoop_wbb_idx].dirty);

    assign snoop_req_ready_o    = 1'b1; // Unthrottled acceptance per §8.2
    assign snoop_rsp_valid_o    = snoop_req_valid_i;
    assign snoop_rsp_was_dirty_o= snoop_is_dirty;
    assign snoop_rsp_has_data_o = snoop_is_dirty && snoop_do_read; // SNOOP_READ or SNOOP_CLEAN_INV

    always_comb begin
        snoop_rsp_data_o = 512'd0;
        if (snoop_cache_hit && snoop_rsp_has_data_o) begin
            snoop_rsp_data_o = read_cache_line(snoop_set, snoop_hit_way);
        end else if (snoop_wbb_hit && snoop_rsp_has_data_o) begin
            snoop_rsp_data_o = wbb_q[snoop_wbb_idx].data;
        end
    end

    // Snoop dirty readout claims all 4 banks if snoop_rsp_has_data_o from cache
    wire snoop_claims_banks = snoop_cache_hit && snoop_rsp_has_data_o;

    // Hardware PTW Coherent Dirty-Line Forwarding (Read-Only, Non-Destructive)
    /* verilator lint_off UNUSEDSIGNAL */
    wire [2:0]  unused_ptw_snoop_lo = ptw_snoop_pa_i[2:0];
    /* verilator lint_on UNUSEDSIGNAL */
    wire [5:0]  ptw_snoop_set  = ptw_snoop_pa_i[11:6];
    wire [43:0] ptw_snoop_tag  = ptw_snoop_pa_i[55:12];
    wire [49:0] ptw_snoop_line = ptw_snoop_pa_i[55:6];
    wire [2:0]  ptw_snoop_bank = ptw_snoop_pa_i[5:3];

    logic [1:0] ptw_snoop_way;
    wire        ptw_snoop_cache_hit = check_cache_hit(ptw_snoop_set, ptw_snoop_tag, ptw_snoop_way);
    wbb_idx_t   ptw_snoop_wbb_idx;
    wire        ptw_snoop_wbb_hit   = check_wbb_hit(ptw_snoop_line, ptw_snoop_wbb_idx);

    always_comb begin
        ptw_snoop_dirty_hit_o = 1'b0;
        ptw_snoop_data_o      = 64'd0;
        if (ptw_snoop_cache_hit && dirty_array[ptw_snoop_set][ptw_snoop_way]) begin
            ptw_snoop_dirty_hit_o = 1'b1;
            ptw_snoop_data_o      = bank_data[ptw_snoop_bank][ptw_snoop_set][ptw_snoop_way];
        end else if (ptw_snoop_wbb_hit && wbb_q[ptw_snoop_wbb_idx].dirty) begin
            ptw_snoop_dirty_hit_o = 1'b1;
            ptw_snoop_data_o      = wbb_q[ptw_snoop_wbb_idx].data[ptw_snoop_pa_i[5:3] * 64 +: 64];
        end
    end

    // =========================================================================
    // Store Drain Request Evaluation (Priority 3)
    // =========================================================================
    wire [5:0]  store_set     = store_drain_pa_i[11:6];
    wire [43:0] store_tag     = store_drain_pa_i[55:12];
    wire [49:0] store_line    = store_drain_pa_i[55:6];
    wire [2:0]  store_bank    = store_drain_pa_i[5:3];

    logic [1:0] store_cache_hit_way;
    wire store_cache_hit = check_cache_hit(store_set, store_tag, store_cache_hit_way);

    wbb_idx_t store_wbb_idx;
    wire store_in_wbb = check_wbb_hit(store_line, store_wbb_idx);
    wire store_wbb_draining = store_in_wbb && wbb_q[store_wbb_idx].draining;
    wire store_wbb_hit = store_in_wbb && !store_wbb_draining;

    mshr_idx_t store_mshr_match_idx;
    wire store_mshr_match = check_mshr_match(store_line, store_mshr_match_idx);

    // Reserved ways in store_set by in-flight MSHRs
    logic [3:0] store_set_mshr_reserved_ways;
    always_comb begin
        store_set_mshr_reserved_ways = 4'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr_q[m].valid && (mshr_q[m].line_addr[5:0] == store_set)) begin
                store_set_mshr_reserved_ways[mshr_q[m].victim_way] = 1'b1;
            end
        end
    end

    // Candidate victim way for store miss allocation
    logic [1:0] store_victim_way;
    logic       store_found_invalid;
    assign {store_found_invalid, store_victim_way} = select_victim_way(store_set, store_set_mshr_reserved_ways);

    wire clean_active = (clean_state_q != CLEAN_IDLE) || dcache_clean_all_req_i;

    wire store_victim_is_dirty = valid_array[store_set][store_victim_way] && dirty_array[store_set][store_victim_way];
    wire store_can_alloc_mshr  = (mshr_free_count > 0) && (store_set_mshr_reserved_ways != 4'b1111) &&
                                 !store_in_wbb &&
                                 (!store_victim_is_dirty || (wbb_avail_count > 0));

    wire store_can_drain = store_drain_valid_i && !cache_busy_refill && !snoop_claims_banks && !clean_active &&
                           (store_cache_hit || store_wbb_hit || store_mshr_match || store_can_alloc_mshr);
    wire store_alloc_mshr = store_can_drain && !store_cache_hit && !store_wbb_hit && !store_mshr_match;

    assign store_drain_ready_o = store_can_drain;
    assign store_drain_done_o  = store_can_drain && (store_cache_hit || store_wbb_hit);

    // Store Drain claims its target bank if it hits in cache
    wire store_claims_bank = store_can_drain && store_cache_hit;
    wire [2:0] store_claimed_bank = store_bank;

    // =========================================================================
    // Dual Load Evaluation (Port 2 / AGU0 & Port 3 / AGU1)
    // =========================================================================
    wire [5:0]  load0_set    = load0_req_pa_i[11:6];
    wire [43:0] load0_tag    = load0_req_pa_i[55:12];
    wire [49:0] load0_line   = load0_req_pa_i[55:6];
    wire [2:0]  load0_bank   = load0_req_pa_i[5:3];

    wire [5:0]  load1_set    = load1_req_pa_i[11:6];
    wire [43:0] load1_tag    = load1_req_pa_i[55:12];
    wire [49:0] load1_line   = load1_req_pa_i[55:6];
    wire [2:0]  load1_bank   = load1_req_pa_i[5:3];

    // Cache hit checks
    logic [1:0] load0_cache_hit_way;
    wire load0_cache_hit = check_cache_hit(load0_set, load0_tag, load0_cache_hit_way);

    logic [1:0] load1_cache_hit_way;
    wire load1_cache_hit = check_cache_hit(load1_set, load1_tag, load1_cache_hit_way);

    // WBB hit checks
    wbb_idx_t load0_wbb_idx;
    wire load0_wbb_hit = check_wbb_hit(load0_line, load0_wbb_idx);

    wbb_idx_t load1_wbb_idx;
    wire load1_wbb_hit = check_wbb_hit(load1_line, load1_wbb_idx);

    // MSHR match checks
    mshr_idx_t load0_mshr_match_idx;
    wire load0_mshr_match = check_mshr_match(load0_line, load0_mshr_match_idx);

    mshr_idx_t load1_mshr_match_idx;
    wire load1_mshr_match = check_mshr_match(load1_line, load1_mshr_match_idx);

    // Misalignment traps (§10.1, PROP_M7_19)
    wire load0_misaligned = is_naturally_misaligned(load0_req_pa_i, load0_req_size_i);
    wire load1_misaligned = is_naturally_misaligned(load1_req_pa_i, load1_req_size_i);

    // Reserved ways in load0_set
    logic [3:0] load0_set_mshr_reserved_ways;
    always_comb begin
        load0_set_mshr_reserved_ways = 4'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr_q[m].valid && (mshr_q[m].line_addr[5:0] == load0_set)) begin
                load0_set_mshr_reserved_ways[mshr_q[m].victim_way] = 1'b1;
            end
        end
    end

    // Candidate victim way for load0
    logic [1:0] load0_victim_way;
    logic       load0_found_invalid;
    assign {load0_found_invalid, load0_victim_way} = select_victim_way(load0_set, load0_set_mshr_reserved_ways);

    wire load0_victim_is_dirty = valid_array[load0_set][load0_victim_way] && dirty_array[load0_set][load0_victim_way];
    wire load0_can_alloc_mshr  = (mshr_free_count > 0) && (load0_set_mshr_reserved_ways != 4'b1111) &&
                                 (!load0_victim_is_dirty || (wbb_avail_count > 0));

    // Reserved ways in load1_set
    logic [3:0] load1_set_mshr_reserved_ways;
    always_comb begin
        load1_set_mshr_reserved_ways = 4'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr_q[m].valid && (mshr_q[m].line_addr[5:0] == load1_set)) begin
                load1_set_mshr_reserved_ways[mshr_q[m].victim_way] = 1'b1;
            end
        end
    end

    // Candidate victim way for load1
    logic [1:0] load1_victim_way;
    logic       load1_found_invalid;
    assign {load1_found_invalid, load1_victim_way} = select_victim_way(load1_set, load1_set_mshr_reserved_ways);

    wire load1_victim_is_dirty = valid_array[load1_set][load1_victim_way] && dirty_array[load1_set][load1_victim_way];
    wire load1_can_alloc_mshr  = (mshr_free_count > 0) && (load1_set_mshr_reserved_ways != 4'b1111) &&
                                 (!load1_victim_is_dirty || (wbb_avail_count > 0));

    // =========================================================================
    // Bank Conflict & Dynamic Age Priority Arbitration (§6.3, Table 6.3)
    // =========================================================================
    // 1. Store Drain vs Loads on Same Bank:
    // Store Drain takes strict priority over colliding load; colliding load stalls in M1 (PROP_M7_15).
    wire load0_collides_with_store = store_claims_bank && (load0_bank == store_claimed_bank);
    wire load1_collides_with_store = store_claims_bank && (load1_bank == store_claimed_bank);

    // 2. Dual Load Bank Collision:
    wire dual_load_active    = load0_req_valid_i && load1_req_valid_i && !load0_misaligned && !load1_misaligned;
    wire same_bank_loads     = dual_load_active && (load0_bank == load1_bank);
    wire same_dw_loads       = same_bank_loads && (load0_req_pa_i[55:3] == load1_req_pa_i[55:3]);
    wire bank_conflict_loads = same_bank_loads && !same_dw_loads;

    // Dynamic ROB Age Priority Evaluation (PROP_M7_13)
    rob_dist_t l0_dist;
    rob_dist_t l1_dist;
    assign l0_dist = rob_dist(load0_req_rob_idx_i, rob_head_i);
    assign l1_dist = rob_dist(load1_req_rob_idx_i, rob_head_i);

    // Anti-starvation register: tracks if Load 1 stalled in previous cycle on bank conflict
    logic p3_bank_stall_q;

    // Arbitration Winner for same-bank conflict:
    logic l0_wins_bank;
    always_comb begin
        if (p3_bank_stall_q) begin
            // Replaying Port 3 has anti-starvation priority over younger or equal Port 2 uop
            if (l0_dist < l1_dist) begin
                l0_wins_bank = 1'b1;
            end else begin
                l0_wins_bank = 1'b0;
            end
        end else begin
            // Strictly older uop wins; tie broken in favor of Port 2
            if (l0_dist <= l1_dist) begin
                l0_wins_bank = 1'b1;
            end else begin
                l0_wins_bank = 1'b0;
            end
        end
    end

    // 3. Dual-Miss MSHR Arbitration (§6.3 4, PROP_M7_17) & Store/Eviction Hazards:
    // - At most one MSHR/WBB allocation occurs per cycle (Store Drain > Load 0 > Load 1).
    // - A load miss cannot evict from store_set while store_can_drain updates store_set,
    //   nor read all 4 banks for a dirty eviction while another port accesses cache banks.
    wire load0_is_miss = load0_req_valid_i && !load0_misaligned && !load0_cache_hit && !load0_wbb_hit && !load0_mshr_match;
    wire load1_is_miss = load1_req_valid_i && !load1_misaligned && !load1_cache_hit && !load1_wbb_hit && !load1_mshr_match;
    wire dual_miss_collision = load0_is_miss && load1_is_miss;

    wire load0_store_hazard = (store_alloc_mshr && (load0_is_miss || (load0_set == store_set) || store_victim_is_dirty)) ||
                              (store_claims_bank && load0_is_miss && ((load0_set == store_set) || load0_victim_is_dirty)) ||
                              (store_can_drain && store_wbb_hit && load0_wbb_hit && (load0_wbb_idx == store_wbb_idx));

    wire load1_store_hazard = (store_alloc_mshr && (load1_is_miss || (load1_set == store_set) || store_victim_is_dirty)) ||
                              (store_claims_bank && load1_is_miss && ((load1_set == store_set) || load1_victim_is_dirty)) ||
                              (store_can_drain && store_wbb_hit && load1_wbb_hit && (load1_wbb_idx == store_wbb_idx)) ||
                              (load0_req_valid_i && load0_is_miss && ((load1_set == load0_set) || load0_victim_is_dirty)) ||
                              (load0_req_valid_i && load0_cache_hit && load1_is_miss && ((load1_set == load0_set) || load1_victim_is_dirty));

    wire load0_squashed = flush_valid_i ||
        (recover_valid_i && (rob_dist(load0_req_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i)));
    wire load1_squashed = flush_valid_i ||
        (recover_valid_i && (rob_dist(load1_req_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i)));

    // Load 0 Acceptance
    wire load0_accept = load0_req_valid_i && !load0_squashed && !cache_busy_refill && !snoop_claims_banks && !clean_active &&
                        !load0_misaligned &&
                        !load0_collides_with_store &&
                        !load0_store_hazard &&
                        !(bank_conflict_loads && !l0_wins_bank) &&
                        (load0_cache_hit || load0_wbb_hit || load0_mshr_match || load0_can_alloc_mshr);

    assign load0_req_ready_o = load0_accept;

    // Load 1 Acceptance
    wire load1_accept = load1_req_valid_i && !load1_squashed && !cache_busy_refill && !snoop_claims_banks && !clean_active &&
                        !load1_misaligned &&
                        !load1_collides_with_store &&
                        !load1_store_hazard &&
                        !(bank_conflict_loads && l0_wins_bank) &&
                        !dual_miss_collision &&
                        (load1_cache_hit || load1_wbb_hit || load1_mshr_match || load1_can_alloc_mshr);

    assign load1_req_ready_o = load1_accept;

    // =========================================================================
    // Load Hit Response Formatting (Concurrent Hits & Broadcast, PROP_M7_11, PROP_M7_12)
    // =========================================================================
    // Port 2 / Load 0 Response
    always_comb begin
        logic [63:0] raw_word;
        load0_rsp_valid_o   = load0_accept;
        load0_rsp_lq_idx_o  = load0_req_lq_idx_i;
        load0_rsp_hit_o     = (load0_cache_hit || load0_wbb_hit) && !load0_misaligned;
        load0_rsp_data_o    = 64'd0;
        load0_rsp_mshr_id_o = load0_mshr_match ? load0_mshr_match_idx : mshr_free_slot;
        raw_word            = 64'd0;

        if (load0_cache_hit && !load0_misaligned) begin
            raw_word = bank_data[load0_bank][load0_set][load0_cache_hit_way];
            load0_rsp_data_o = format_load_result_func(raw_word, load0_req_pa_i[2:0], load0_req_size_i, load0_req_sign_ext_i);
        end else if (load0_wbb_hit && !load0_misaligned) begin
            raw_word = extract_word_from_line(wbb_q[load0_wbb_idx].data, load0_req_pa_i[5:0]);
            load0_rsp_data_o = format_load_result_func(raw_word, load0_req_pa_i[2:0], load0_req_size_i, load0_req_sign_ext_i);
        end
    end

    // Port 3 / Load 1 Response
    always_comb begin
        logic [63:0] raw_word;
        load1_rsp_valid_o   = load1_accept;
        load1_rsp_lq_idx_o  = load1_req_lq_idx_i;
        load1_rsp_hit_o     = (load1_cache_hit || load1_wbb_hit) && !load1_misaligned;
        load1_rsp_data_o    = 64'd0;
        load1_rsp_mshr_id_o = load1_mshr_match ? load1_mshr_match_idx :
                              (load0_is_miss ? 2'(mshr_free_slot + 2'd1) : mshr_free_slot);
        raw_word            = 64'd0;

        if (load1_cache_hit && !load1_misaligned) begin
            if (same_dw_loads) begin
                // Bank Broadcast: Read data from identical bank doubleword broadcast concurrently (§6.3, PROP_M7_12)
                raw_word = bank_data[load0_bank][load0_set][load0_cache_hit_way];
            end else begin
                raw_word = bank_data[load1_bank][load1_set][load1_cache_hit_way];
            end
            load1_rsp_data_o = format_load_result_func(raw_word, load1_req_pa_i[2:0], load1_req_size_i, load1_req_sign_ext_i);
        end else if (load1_wbb_hit && !load1_misaligned) begin
            raw_word = extract_word_from_line(wbb_q[load1_wbb_idx].data, load1_req_pa_i[5:0]);
            load1_rsp_data_o = format_load_result_func(raw_word, load1_req_pa_i[2:0], load1_req_size_i, load1_req_sign_ext_i);
        end
    end

    // Observability & Telemetry Events
    assign event_l1d_hit_o  = (load0_req_valid_i && load0_accept && (load0_cache_hit || load0_wbb_hit)) ||
                              (load1_req_valid_i && load1_accept && (load1_cache_hit || load1_wbb_hit));
    assign event_l1d_miss_o = (load0_req_valid_i && load0_accept && !(load0_cache_hit || load0_wbb_hit)) ||
                              (load1_req_valid_i && load1_accept && !(load1_cache_hit || load1_wbb_hit));

    wire store_mshr_alloc_fire = store_alloc_mshr;
    wire load0_mshr_alloc_fire = load0_accept && !load0_cache_hit && !load0_wbb_hit && !load0_mshr_match && load0_can_alloc_mshr;
    wire load1_mshr_alloc_fire = load1_accept && !load1_cache_hit && !load1_wbb_hit && !load1_mshr_match && load1_can_alloc_mshr;

    assign event_l1d_miss_cold_o     = ((store_mshr_alloc_fire && store_found_invalid) ? 2'd1 : 2'd0) +
                                       ((load0_mshr_alloc_fire && load0_found_invalid) ? 2'd1 : 2'd0) +
                                       ((load1_mshr_alloc_fire && load1_found_invalid) ? 2'd1 : 2'd0);
    assign event_l1d_miss_conflict_o = ((store_mshr_alloc_fire && !store_found_invalid) ? 2'd1 : 2'd0) +
                                       ((load0_mshr_alloc_fire && !load0_found_invalid) ? 2'd1 : 2'd0) +
                                       ((load1_mshr_alloc_fire && !load1_found_invalid) ? 2'd1 : 2'd0);
    assign event_l1d_dirty_evict_o   = ((store_mshr_alloc_fire && store_victim_is_dirty) ? 2'd1 : 2'd0) +
                                       ((load0_mshr_alloc_fire && load0_victim_is_dirty) ? 2'd1 : 2'd0) +
                                       ((load1_mshr_alloc_fire && load1_victim_is_dirty) ? 2'd1 : 2'd0);

    assign event_bank_broadcast_o = dual_load_active && same_dw_loads && load0_accept && load1_accept;
    assign event_bank_conflict_o  = (dual_load_active && bank_conflict_loads) ||
                                    (load0_req_valid_i && load0_collides_with_store) ||
                                    (load1_req_valid_i && load1_collides_with_store);
    assign event_store_drain_concurrent_o = store_can_drain &&
                                           ((load0_req_valid_i && load0_accept && (load0_bank != store_bank)) ||
                                            (load1_req_valid_i && load1_accept && (load1_bank != store_bank)));

    assign event_bank_access_count_o = (store_claims_bank ? 2'd1 : 2'd0) +
                                       (load0_accept && load0_cache_hit ? 2'd1 : 2'd0) +
                                       (load1_accept && load1_cache_hit && !same_dw_loads ? 2'd1 : 2'd0);

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

    // Launch writeback for dirty WBB entry
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
    assign l1d_quiescent_o = (mshr_free_count == 3'd4) && (wbb_free_count == 2'd2) &&
                             (rsp_fifo_count_q == 3'd0) &&
                             !drain_found && !bus_wr_inflight_q && !refill_busy_q;

    // =========================================================================
    // Sequential State Management (Cache Banks, MSHRs, WBB, LRU)
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            /* verilator lint_off BLKSEQ */
            for (int s = 0; s < L1D_SETS; s++) begin
                lru_array[s] = 3'd0;
                for (int w = 0; w < L1D_WAYS; w++) begin
                    valid_array[s][w] = 1'b0;
                    dirty_array[s][w] = 1'b0;
                    tag_array[s][w]   = '0;
                    for (int b = 0; b < 8; b++) begin
                        bank_data[b][s][w] = 64'd0;
                    end
                end
            end
            /* verilator lint_on BLKSEQ */

            for (int i = 0; i < MSHR_DEPTH; i++) begin
                mshr_q[i] <= '0;
                mshr_snoop_invalid_q[i] <= 1'b0;
                for (int w = 0; w < LQ_DEPTH; w++) begin
                    mshr_waiters_q[i][w] <= '0;
                end
            end

            for (int i = 0; i < WBB_DEPTH; i++) begin
                wbb_q[i] <= '0;
            end
            bus_wr_inflight_q      <= 1'b0;
            bus_wr_inflight_slot_q <= '0;
            clean_state_q          <= CLEAN_IDLE;
            clean_set_q            <= 6'd0;
            clean_way_q            <= 2'd0;
            refill_busy_q          <= 1'b0;
            refill_tag_q           <= 2'd0;
            refill_data_q          <= 512'd0;
            rsp_fifo_head_q        <= 2'd0;
            rsp_fifo_tail_q        <= 2'd0;
            rsp_fifo_count_q       <= 3'd0;
            p3_bank_stall_q        <= 1'b0;
        end else begin
            // -----------------------------------------------------------------
            // Anti-Starvation Tracking: Track Port 3 Bank Stalls (§6.3)
            // -----------------------------------------------------------------
            if (flush_valid_i) begin
                p3_bank_stall_q <= 1'b0;
            end else begin
                p3_bank_stall_q <= load1_req_valid_i && bank_conflict_loads && l0_wins_bank;
            end

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
                    wbb_q[bus_wr_slot].valid    <= 1'b0;
                    wbb_q[bus_wr_slot].dirty    <= 1'b0;
                    wbb_q[bus_wr_slot].draining <= 1'b0;
                    bus_wr_inflight_q           <= 1'b0;
                end else begin
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
                                    mshr_q[m].waiter_mask[w]            <= 1'b0;
                                    mshr_waiters_q[m][w].waiter_valid <= 1'b0;
                                end
                            end
                        end
                    end
                end
            end

            // Full flush clears speculative load waiters
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
            // 4. External Coherence Snoop Tag / Cache / WBB / MSHR Handling (§8.3)
            // -----------------------------------------------------------------
            if (snoop_req_valid_i && snoop_do_inv) begin
                for (int m = 0; m < MSHR_DEPTH; m++) begin
                    if (mshr_q[m].valid && (mshr_q[m].line_addr == snoop_req_addr_i)) begin
                        mshr_snoop_invalid_q[m] <= 1'b1;
                    end
                end
            end

            if (snoop_cache_hit) begin
                if (snoop_do_inv) begin
                    // SNOOP_INV or SNOOP_CLEAN_INV: Invalidate cache line
                    valid_array[snoop_set][snoop_hit_way] <= 1'b0;
                    dirty_array[snoop_set][snoop_hit_way] <= 1'b0;
                end else if (snoop_do_read) begin
                    // SNOOP_READ: Mark line clean after shared readout
                    dirty_array[snoop_set][snoop_hit_way] <= 1'b0;
                end
            end

            if (snoop_wbb_hit) begin
                if (snoop_do_inv) begin
                    wbb_q[snoop_wbb_idx].valid <= 1'b0;
                end else if (snoop_do_read) begin
                    wbb_q[snoop_wbb_idx].dirty <= 1'b0;
                end
            end

            // -----------------------------------------------------------------
            // 5. 2-Cycle Multi-Beat Refill Sequence (§6.3, P0-1, PROP_M7_16, PROP_M7_34)
            // -----------------------------------------------------------------
            if (!refill_busy_q) begin
                if (rsp_fifo_count_q != 3'd0) begin
                    // Consume head of response FIFO
                    mshr_idx_t m_idx;
                    logic [5:0] set_i;
                    logic [1:0] rep_way;
                    logic [511:0] rsp_data;

                    m_idx    = rsp_fifo_q[rsp_fifo_head_q].tag;
                    rsp_data = rsp_fifo_q[rsp_fifo_head_q].data;
                    set_i    = mshr_q[m_idx].line_addr[5:0];
                    rep_way  = mshr_q[m_idx].victim_way;

                    bank_data[0][set_i][rep_way] <= rsp_data[63:0];   // DW0
                    bank_data[1][set_i][rep_way] <= rsp_data[127:64]; // DW1
                    bank_data[2][set_i][rep_way] <= rsp_data[191:128];// DW2
                    bank_data[3][set_i][rep_way] <= rsp_data[255:192];// DW3

                    refill_busy_q <= 1'b1;
                    refill_tag_q  <= m_idx;
                    refill_data_q <= rsp_data;

                    mshr_q[m_idx].victim_data <= rsp_data;

                    rsp_fifo_head_q <= rsp_fifo_head_q + 2'd1;

                    if (refill_arriving) begin
                        rsp_fifo_q[rsp_fifo_tail_q] <= '{tag: bus_rd_rsp_tag_i, data: bus_rd_rsp_data_i};
                        rsp_fifo_tail_q <= rsp_fifo_tail_q + 2'd1;
                    end else begin
                        rsp_fifo_count_q <= rsp_fifo_count_q - 3'd1;
                    end
                end else if (refill_arriving) begin
                    // Bypass FIFO directly into Beat 0
                    mshr_idx_t m_idx;
                    logic [5:0] set_i;
                    logic [1:0] rep_way;

                    m_idx   = bus_rd_rsp_tag_i;
                    set_i   = mshr_q[m_idx].line_addr[5:0];
                    rep_way = mshr_q[m_idx].victim_way;

                    bank_data[0][set_i][rep_way] <= bus_rd_rsp_data_i[63:0];   // DW0
                    bank_data[1][set_i][rep_way] <= bus_rd_rsp_data_i[127:64]; // DW1
                    bank_data[2][set_i][rep_way] <= bus_rd_rsp_data_i[191:128];// DW2
                    bank_data[3][set_i][rep_way] <= bus_rd_rsp_data_i[255:192];// DW3

                    refill_busy_q <= 1'b1;
                    refill_tag_q  <= m_idx;
                    refill_data_q <= bus_rd_rsp_data_i;

                    mshr_q[m_idx].victim_data <= bus_rd_rsp_data_i;
                end
            end else begin
                // Beat 1 (Cycle 2): Write upper 256 bits across Banks 4..7 (PA[5] == 1), update tags
                logic [5:0] set_i;
                logic [43:0] tag_i;
                logic [1:0] rep_way;
                logic refill_line_snoop_inv;

                set_i   = mshr_q[refill_tag_q].line_addr[5:0];
                tag_i   = mshr_q[refill_tag_q].line_addr[49:6];
                rep_way = mshr_q[refill_tag_q].victim_way;
                refill_line_snoop_inv = mshr_snoop_invalid_q[refill_tag_q] ||
                                        (snoop_req_valid_i && snoop_do_inv && (snoop_req_addr_i == mshr_q[refill_tag_q].line_addr));

                bank_data[4][set_i][rep_way] <= refill_data_q[319:256]; // DW4
                bank_data[5][set_i][rep_way] <= refill_data_q[383:320]; // DW5
                bank_data[6][set_i][rep_way] <= refill_data_q[447:384]; // DW6
                bank_data[7][set_i][rep_way] <= refill_data_q[511:448]; // DW7

                valid_array[set_i][rep_way] <= !refill_line_snoop_inv;
                dirty_array[set_i][rep_way] <= 1'b0;
                tag_array[set_i][rep_way]   <= tag_i;
                mshr_snoop_invalid_q[refill_tag_q] <= 1'b0;

                refill_busy_q <= 1'b0;

                if (mshr_q[refill_tag_q].waiter_mask != 16'd0) begin
                    mshr_q[refill_tag_q].state <= MSHR_DRAIN_WAITERS;
                end else begin
                    mshr_q[refill_tag_q].valid <= 1'b0;
                    mshr_q[refill_tag_q].state <= MSHR_IDLE;
                end

                // If a new response arrives during Beat 1, push into FIFO
                if (refill_arriving) begin
                    rsp_fifo_q[rsp_fifo_tail_q] <= '{tag: bus_rd_rsp_tag_i, data: bus_rd_rsp_data_i};
                    rsp_fifo_tail_q  <= rsp_fifo_tail_q + 2'd1;
                    rsp_fifo_count_q <= rsp_fifo_count_q + 3'd1;
                end
            end

            // Service active waiter step (drain to writeback bus)
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
            // 6. Committed Store Drain Execution (Priority 3)
            // -----------------------------------------------------------------
            if (store_can_drain) begin
                if (store_cache_hit) begin
                    // Write strictly to target bank and doubleword (zero conflict on other banks!)
                    logic [63:0] old_dw;
                    old_dw = bank_data[store_bank][store_set][store_cache_hit_way];
                    for (int b = 0; b < 8; b++) begin
                        if (store_drain_mask_i[b]) begin
                            old_dw[b*8 +: 8] = store_drain_data_i[b*8 +: 8];
                        end
                    end
                    bank_data[store_bank][store_set][store_cache_hit_way] <= old_dw;
                    dirty_array[store_set][store_cache_hit_way] <= 1'b1;
                    lru_array[store_set] <= update_tree_plru(lru_array[store_set], store_cache_hit_way);
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
                    mshr_snoop_invalid_q[mshr_free_slot]       <= 1'b0;
                    mshr_q[mshr_free_slot].line_addr           <= store_line;
                    mshr_q[mshr_free_slot].state               <= MSHR_WAIT_BUS;
                    mshr_q[mshr_free_slot].bus_tag             <= mshr_free_slot;
                    mshr_q[mshr_free_slot].waiter_mask         <= 16'd0;
                    mshr_q[mshr_free_slot].store_drain_mask    <= (16'd1 << store_drain_sq_idx_i);
                    mshr_q[mshr_free_slot].wbb_has_reservation <= 1'b0;
                    mshr_q[mshr_free_slot].wbb_reserved_slot   <= '0;
                    mshr_q[mshr_free_slot].victim_way          <= store_victim_way;
                    mshr_q[mshr_free_slot].victim_tag          <= tag_array[store_set][store_victim_way];
                    mshr_q[mshr_free_slot].victim_data         <= read_cache_line(store_set, store_victim_way);
                    mshr_q[mshr_free_slot].victim_dirty        <= store_victim_is_dirty;

                    // If victim is dirty, immediately move to WBB
                    if (store_victim_is_dirty) begin
                        wbb_q[store_wbb_target].valid      <= 1'b1;
                        wbb_q[store_wbb_target].dirty      <= 1'b1;
                        wbb_q[store_wbb_target].draining   <= 1'b0;
                        wbb_q[store_wbb_target].line_addr  <= {tag_array[store_set][store_victim_way], store_set};
                        wbb_q[store_wbb_target].data       <= read_cache_line(store_set, store_victim_way);
                        wbb_q[store_wbb_target].dirty_mask <= '1;
                    end
                    valid_array[store_set][store_victim_way] <= 1'b0;
                    dirty_array[store_set][store_victim_way] <= 1'b0;

                    lru_array[store_set] <= update_tree_plru(lru_array[store_set], store_victim_way);
                end
            end

            // -----------------------------------------------------------------
            // 7. Load 0 Issue Execution (Port 2 / AGU0)
            // -----------------------------------------------------------------
            if (load0_accept) begin
                if (load0_cache_hit) begin
                    lru_array[load0_set] <= update_tree_plru(lru_array[load0_set], load0_cache_hit_way);
                end else if (load0_wbb_hit) begin
                    // Hit in WBB
                end else if (load0_mshr_match) begin
                    mshr_q[load0_mshr_match_idx].waiter_mask[load0_req_lq_idx_i] <= 1'b1;
                    mshr_waiters_q[load0_mshr_match_idx][load0_req_lq_idx_i].waiter_valid <= 1'b1;
                    mshr_waiters_q[load0_mshr_match_idx][load0_req_lq_idx_i].lq_idx       <= load0_req_lq_idx_i;
                    mshr_waiters_q[load0_mshr_match_idx][load0_req_lq_idx_i].line_offset  <= load0_req_pa_i[5:0];
                    mshr_waiters_q[load0_mshr_match_idx][load0_req_lq_idx_i].size         <= load0_req_size_i;
                    mshr_waiters_q[load0_mshr_match_idx][load0_req_lq_idx_i].sign_ext     <= load0_req_sign_ext_i;
                    mshr_waiters_q[load0_mshr_match_idx][load0_req_lq_idx_i].pnew         <= load0_req_pnew_i;
                    mshr_waiters_q[load0_mshr_match_idx][load0_req_lq_idx_i].rob_idx      <= load0_req_rob_idx_i;
                    mshr_waiters_q[load0_mshr_match_idx][load0_req_lq_idx_i].rob_epoch    <= load0_req_rob_epoch_i;
                end else if (load0_can_alloc_mshr) begin
                    mshr_q[mshr_free_slot].valid               <= 1'b1;
                    mshr_snoop_invalid_q[mshr_free_slot]       <= 1'b0;
                    mshr_q[mshr_free_slot].line_addr           <= load0_line;
                    mshr_q[mshr_free_slot].state               <= MSHR_WAIT_BUS;
                    mshr_q[mshr_free_slot].bus_tag             <= mshr_free_slot;
                    mshr_q[mshr_free_slot].waiter_mask         <= (16'd1 << load0_req_lq_idx_i);
                    mshr_q[mshr_free_slot].store_drain_mask    <= 16'd0;
                    mshr_q[mshr_free_slot].wbb_has_reservation <= 1'b0;
                    mshr_q[mshr_free_slot].wbb_reserved_slot   <= '0;
                    mshr_q[mshr_free_slot].victim_way          <= load0_victim_way;
                    mshr_q[mshr_free_slot].victim_tag          <= tag_array[load0_set][load0_victim_way];
                    mshr_q[mshr_free_slot].victim_data         <= read_cache_line(load0_set, load0_victim_way);
                    mshr_q[mshr_free_slot].victim_dirty        <= load0_victim_is_dirty;

                    if (load0_victim_is_dirty) begin
                        wbb_q[load0_wbb_target].valid      <= 1'b1;
                        wbb_q[load0_wbb_target].dirty      <= 1'b1;
                        wbb_q[load0_wbb_target].draining   <= 1'b0;
                        wbb_q[load0_wbb_target].line_addr  <= {tag_array[load0_set][load0_victim_way], load0_set};
                        wbb_q[load0_wbb_target].data       <= read_cache_line(load0_set, load0_victim_way);
                        wbb_q[load0_wbb_target].dirty_mask <= '1;
                    end
                    valid_array[load0_set][load0_victim_way] <= 1'b0;
                    dirty_array[load0_set][load0_victim_way] <= 1'b0;

                    lru_array[load0_set] <= update_tree_plru(lru_array[load0_set], load0_victim_way);

                    mshr_waiters_q[mshr_free_slot][load0_req_lq_idx_i].waiter_valid <= 1'b1;
                    mshr_waiters_q[mshr_free_slot][load0_req_lq_idx_i].lq_idx       <= load0_req_lq_idx_i;
                    mshr_waiters_q[mshr_free_slot][load0_req_lq_idx_i].line_offset  <= load0_req_pa_i[5:0];
                    mshr_waiters_q[mshr_free_slot][load0_req_lq_idx_i].size         <= load0_req_size_i;
                    mshr_waiters_q[mshr_free_slot][load0_req_lq_idx_i].sign_ext     <= load0_req_sign_ext_i;
                    mshr_waiters_q[mshr_free_slot][load0_req_lq_idx_i].pnew         <= load0_req_pnew_i;
                    mshr_waiters_q[mshr_free_slot][load0_req_lq_idx_i].rob_idx      <= load0_req_rob_idx_i;
                    mshr_waiters_q[mshr_free_slot][load0_req_lq_idx_i].rob_epoch    <= load0_req_rob_epoch_i;
                end
            end

            // -----------------------------------------------------------------
            // 8. Load 1 Issue Execution (Port 3 / AGU1)
            // -----------------------------------------------------------------
            if (load1_accept) begin
                if (load1_cache_hit) begin
                    lru_array[load1_set] <= update_tree_plru(lru_array[load1_set], load1_cache_hit_way);
                end else if (load1_wbb_hit) begin
                    // Hit in WBB
                end else if (load1_mshr_match) begin
                    mshr_q[load1_mshr_match_idx].waiter_mask[load1_req_lq_idx_i] <= 1'b1;
                    mshr_waiters_q[load1_mshr_match_idx][load1_req_lq_idx_i].waiter_valid <= 1'b1;
                    mshr_waiters_q[load1_mshr_match_idx][load1_req_lq_idx_i].lq_idx       <= load1_req_lq_idx_i;
                    mshr_waiters_q[load1_mshr_match_idx][load1_req_lq_idx_i].line_offset  <= load1_req_pa_i[5:0];
                    mshr_waiters_q[load1_mshr_match_idx][load1_req_lq_idx_i].size         <= load1_req_size_i;
                    mshr_waiters_q[load1_mshr_match_idx][load1_req_lq_idx_i].sign_ext     <= load1_req_sign_ext_i;
                    mshr_waiters_q[load1_mshr_match_idx][load1_req_lq_idx_i].pnew         <= load1_req_pnew_i;
                    mshr_waiters_q[load1_mshr_match_idx][load1_req_lq_idx_i].rob_idx      <= load1_req_rob_idx_i;
                    mshr_waiters_q[load1_mshr_match_idx][load1_req_lq_idx_i].rob_epoch    <= load1_req_rob_epoch_i;
                end else if (load1_can_alloc_mshr) begin
                    // Dual miss allocation takes next free slot if load0 also allocated
                    mshr_idx_t l1_slot;
                    l1_slot = (load0_is_miss && load0_accept) ? 2'(mshr_free_slot + 2'd1) : mshr_free_slot;

                    mshr_q[l1_slot].valid               <= 1'b1;
                    mshr_snoop_invalid_q[l1_slot]       <= 1'b0;
                    mshr_q[l1_slot].line_addr           <= load1_line;
                    mshr_q[l1_slot].state               <= MSHR_WAIT_BUS;
                    mshr_q[l1_slot].bus_tag             <= l1_slot;
                    mshr_q[l1_slot].waiter_mask         <= (16'd1 << load1_req_lq_idx_i);
                    mshr_q[l1_slot].store_drain_mask    <= 16'd0;
                    mshr_q[l1_slot].wbb_has_reservation <= 1'b0;
                    mshr_q[l1_slot].wbb_reserved_slot   <= '0;
                    mshr_q[l1_slot].victim_way          <= load1_victim_way;
                    mshr_q[l1_slot].victim_tag          <= tag_array[load1_set][load1_victim_way];
                    mshr_q[l1_slot].victim_data         <= read_cache_line(load1_set, load1_victim_way);
                    mshr_q[l1_slot].victim_dirty        <= load1_victim_is_dirty;

                    if (load1_victim_is_dirty) begin
                        wbb_q[load1_wbb_target].valid      <= 1'b1;
                        wbb_q[load1_wbb_target].dirty      <= 1'b1;
                        wbb_q[load1_wbb_target].draining   <= 1'b0;
                        wbb_q[load1_wbb_target].line_addr  <= {tag_array[load1_set][load1_victim_way], load1_set};
                        wbb_q[load1_wbb_target].data       <= read_cache_line(load1_set, load1_victim_way);
                        wbb_q[load1_wbb_target].dirty_mask <= '1;
                    end
                    valid_array[load1_set][load1_victim_way] <= 1'b0;
                    dirty_array[load1_set][load1_victim_way] <= 1'b0;

                    lru_array[load1_set] <= update_tree_plru(lru_array[load1_set], load1_victim_way);

                    mshr_waiters_q[l1_slot][load1_req_lq_idx_i].waiter_valid <= 1'b1;
                    mshr_waiters_q[l1_slot][load1_req_lq_idx_i].lq_idx       <= load1_req_lq_idx_i;
                    mshr_waiters_q[l1_slot][load1_req_lq_idx_i].line_offset  <= load1_req_pa_i[5:0];
                    mshr_waiters_q[l1_slot][load1_req_lq_idx_i].size         <= load1_req_size_i;
                    mshr_waiters_q[l1_slot][load1_req_lq_idx_i].sign_ext     <= load1_req_sign_ext_i;
                    mshr_waiters_q[l1_slot][load1_req_lq_idx_i].pnew         <= load1_req_pnew_i;
                    mshr_waiters_q[l1_slot][load1_req_lq_idx_i].rob_idx      <= load1_req_rob_idx_i;
                    mshr_waiters_q[l1_slot][load1_req_lq_idx_i].rob_epoch    <= load1_req_rob_epoch_i;
                end
            end

            // -----------------------------------------------------------------
            // 9. Clean-All Maintenance Sweep (FENCE.I Dirty L1D Clean)
            // -----------------------------------------------------------------
            case (clean_state_q)
                CLEAN_IDLE: begin
                    if (dcache_clean_all_req_i) begin
                        clean_state_q <= CLEAN_SWEEP;
                        clean_set_q   <= 6'd0;
                        clean_way_q   <= 2'd0;
                    end
                end

                CLEAN_SWEEP: begin
                    if (valid_array[clean_set_q][clean_way_q] && dirty_array[clean_set_q][clean_way_q]) begin
                        if (wbb_avail_count > 0) begin
                            wbb_q[store_wbb_target].valid       <= 1'b1;
                            wbb_q[store_wbb_target].dirty       <= 1'b1;
                            wbb_q[store_wbb_target].draining    <= 1'b0;
                            wbb_q[store_wbb_target].line_addr   <= {tag_array[clean_set_q][clean_way_q], clean_set_q};
                            wbb_q[store_wbb_target].data        <= read_cache_line(clean_set_q, clean_way_q);
                            wbb_q[store_wbb_target].dirty_mask  <= '1;
                            dirty_array[clean_set_q][clean_way_q] <= 1'b0;

                            if (clean_way_q == 2'd3) begin
                                clean_way_q <= 2'd0;
                                if (clean_set_q == 6'd63) begin
                                    clean_state_q <= CLEAN_DRAIN;
                                end else begin
                                    clean_set_q <= clean_set_q + 1'b1;
                                end
                            end else begin
                                clean_way_q <= clean_way_q + 1'b1;
                            end
                        end
                    end else begin
                        if (clean_way_q == 2'd3) begin
                            clean_way_q <= 2'd0;
                            if (clean_set_q == 6'd63) begin
                                clean_state_q <= CLEAN_DRAIN;
                            end else begin
                                clean_set_q <= clean_set_q + 1'b1;
                            end
                        end else begin
                            clean_way_q <= clean_way_q + 1'b1;
                        end
                    end
                end

                CLEAN_DRAIN: begin
                    if ((wbb_free_count == 2'd2) && !bus_wr_inflight_q && (mshr_free_count == 3'd4)) begin
                        clean_state_q <= CLEAN_DONE;
                    end
                end

                CLEAN_DONE: begin
                    if (!dcache_clean_all_req_i) begin
                        clean_state_q <= CLEAN_IDLE;
                    end
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    // Simulation Assertions
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            // Assertion: MSHR must never overflow
            if (load0_req_valid_i && !load0_cache_hit && !load0_wbb_hit && !load0_mshr_match && (mshr_free_count == 0) && load0_accept) begin
                $fatal(1, "[L1D ASSERTION FAILED] MSHR overflowed on load0!");
            end
            if (load1_req_valid_i && !load1_cache_hit && !load1_wbb_hit && !load1_mshr_match && (mshr_free_count == 0) && load1_accept) begin
                $fatal(1, "[L1D ASSERTION FAILED] MSHR overflowed on load1!");
            end
            // Assertion: WBB must never overflow on load miss allocation
            if (load0_req_valid_i && load0_can_alloc_mshr && load0_victim_is_dirty && (wbb_avail_count == 0) && load0_accept) begin
                $fatal(1, "[L1D ASSERTION FAILED] WBB load0 allocation overflowed!");
            end
            if (load1_req_valid_i && load1_can_alloc_mshr && load1_victim_is_dirty && (wbb_avail_count == 0) && load1_accept) begin
                $fatal(1, "[L1D ASSERTION FAILED] WBB load1 allocation overflowed!");
            end
            // Assertion: WBB must never overflow on store miss allocation
            if (store_drain_valid_i && store_can_alloc_mshr && store_victim_is_dirty && (wbb_avail_count == 0) && store_can_drain) begin
                $fatal(1, "[L1D ASSERTION FAILED] WBB store allocation overflowed!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_L1D_SV
