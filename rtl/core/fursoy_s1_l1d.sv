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

`ifdef FURSOY_SYNTH_SRAM_BB
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
(* blackbox *)
module fursoy_s1_l1d_bank_sram (
    input  logic        clk_i,
    input  logic [5:0]  rd_snoop_set_i,  input  logic [1:0]  rd_snoop_way_i,  output logic [511:0] rd_snoop_line_o,
    input  logic [2:0]  rd_ptw_bank_i,   input  logic [5:0]  rd_ptw_set_i,    input  logic [1:0]   rd_ptw_way_i,    output logic [63:0] rd_ptw_dw_o,
    input  logic [2:0]  rd_l0_bank_i,    input  logic [5:0]  rd_l0_set_i,     input  logic [1:0]   rd_l0_way_i,     output logic [63:0] rd_l0_dw_o,
    input  logic [2:0]  rd_l1_bank_i,    input  logic [5:0]  rd_l1_set_i,     input  logic [1:0]   rd_l1_way_i,     output logic [63:0] rd_l1_dw_o,
    input  logic [5:0]  rd_vic0_set_i,   input  logic [1:0]  rd_vic0_way_i,   output logic [511:0] rd_vic0_line_o,
    input  logic [5:0]  rd_vic1_set_i,   input  logic [1:0]  rd_vic1_way_i,   output logic [511:0] rd_vic1_line_o,
    input  logic        wr_b0_en_i,      input  logic [5:0]  wr_b0_set_i,     input  logic [1:0]   wr_b0_way_i,     input  logic [255:0] wr_b0_data_i,
    input  logic        wr_b1_en_i,      input  logic [5:0]  wr_b1_set_i,     input  logic [1:0]   wr_b1_way_i,     input  logic [255:0] wr_b1_data_i,
    input  logic        wr_dw_en_i,      input  logic [2:0]  wr_dw_bank_i,    input  logic [5:0]   wr_dw_set_i,     input  logic [1:0]   wr_dw_way_i,
    input  logic [7:0]  wr_dw_mask_i,    input  logic [63:0] wr_dw_data_i
);
endmodule
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
`endif

module fursoy_s1_l1d
    import fursoy_s1_pkg::*;
#(
    /* verilator lint_off UNUSEDPARAM */
    parameter bit SMP_COHERENCE_EN = 1'b0,
    parameter int L1D_SETS_PARAM   = L1D_SETS
    /* verilator lint_on UNUSEDPARAM */
) (
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
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic              load0_req_is_amo_i,
    /* verilator lint_on UNUSEDSIGNAL */
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

    // Slice-2 Coherence-Point SC Acquire Channel
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic              sc_acquire_valid_i,
    input  logic [55:0]       sc_acquire_pa_i,
    input  logic [7:0]        sc_acquire_mask_i,
    input  logic [63:0]       sc_acquire_data_i,
    input  logic              sc_res_valid_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic              sc_acquire_accepted_o,
    output logic              sc_acquire_done_o,
    output logic              sc_acquire_ok_o,

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
    output coh_req_op_t       bus_rd_req_op_o,
    input  logic              bus_rd_req_ready_i,

    input  logic              bus_rd_rsp_valid_i,
    input  mshr_idx_t         bus_rd_rsp_tag_i,
    input  logic [511:0]      bus_rd_rsp_data_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  mesi_state_t       bus_rd_rsp_state_i,
    input  logic              bus_rd_rsp_has_data_i,
    /* verilator lint_on UNUSEDSIGNAL */

    // Write Channel (WBB Dirty Line Eviction)
    output logic              bus_wr_req_valid_o,
    output logic [49:0]       bus_wr_req_addr_o,
    output logic [511:0]      bus_wr_req_data_o,
    output logic              bus_wr_req_dirty_o,
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
    input  logic [1:0]        snoop_req_type_i,     // 2'b01: SNOOP_INV, 2'b10: SNOOP_GETS, 2'b11: SNOOP_GETM
    output logic              snoop_req_ready_o,

    output logic              snoop_rsp_valid_o,
    output logic              snoop_rsp_has_data_o, // 1 = Dirty line returned
    output logic [511:0]      snoop_rsp_data_o,     // 64-byte payload
    output logic              snoop_rsp_was_dirty_o,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic              snoop_rsp_ready_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic              snoop_rsp_ack_only_o,

    // S0 Snoop Activity Exports (to LSU Queues for S0/S1 LQ Replay Window)
    output logic              snoop_s0_valid_o,
    output logic [49:0]       snoop_s0_addr_o,
    output logic              snoop_s0_do_inv_o,

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
    localparam int L1D_SET_W = (L1D_SETS_PARAM > 1) ? $clog2(L1D_SETS_PARAM) : 1;

`ifndef SYNTHESIS
    /* verilator lint_off UNUSEDSIGNAL */
    logic [43:0]  tag_array       [L1D_SETS_PARAM][L1D_WAYS] /* verilator public_flat_rd */;
    logic         valid_array     [L1D_SETS_PARAM][L1D_WAYS] /* verilator public_flat_rd */;
    logic         dirty_array     [L1D_SETS_PARAM][L1D_WAYS] /* verilator public_flat_rd */;
    mesi_state_t  coh_state_array [L1D_SETS_PARAM][L1D_WAYS] /* verilator public_flat_rd */;
    logic [2:0]   lru_array       [L1D_SETS_PARAM] /* verilator public_flat_rd */; // 3-bit Tree-PLRU replacement state per set
    /* verilator lint_on UNUSEDSIGNAL */
`endif

    typedef struct packed {
        logic [3:0][43:0] tag;
        logic [3:0]       valid;
        logic [3:0]       dirty;
        logic [3:0][1:0]  coh;
        logic [2:0]       lru;
    } l1d_set_snap_t;

    l1d_set_snap_t [L1D_SETS_PARAM-1:0] set_snap;

    function automatic logic [3:0] way_oh4(input logic [1:0] way);
        return {(way == 2'd3), (way == 2'd2), (way == 2'd1), (way == 2'd0)};
    endfunction

    function automatic l1d_set_snap_t read_l1d_set(input logic [5:0] set_idx);
        if (L1D_SETS_PARAM == 64) begin
            logic [31:0][$bits(l1d_set_snap_t)-1:0] m5;
            logic [15:0][$bits(l1d_set_snap_t)-1:0] m4;
            logic [7:0][$bits(l1d_set_snap_t)-1:0]  m3;
            logic [3:0][$bits(l1d_set_snap_t)-1:0]  m2;
            logic [1:0][$bits(l1d_set_snap_t)-1:0]  m1;
            for (int k = 0; k < 32; k++) m5[k] = set_idx[0] ? set_snap[2*k+1] : set_snap[2*k];
            for (int k = 0; k < 16; k++) m4[k] = set_idx[1] ? m5[2*k+1]       : m5[2*k];
            for (int k = 0; k < 8;  k++) m3[k] = set_idx[2] ? m4[2*k+1]       : m4[2*k];
            for (int k = 0; k < 4;  k++) m2[k] = set_idx[3] ? m3[2*k+1]       : m3[2*k];
            for (int k = 0; k < 2;  k++) m1[k] = set_idx[4] ? m2[2*k+1]       : m2[2*k];
            return l1d_set_snap_t'(set_idx[5] ? m1[1] : m1[0]);
        end else begin
            /* verilator lint_off UNUSEDSIGNAL */
            logic [5:0] unused_hi = set_idx;
            /* verilator lint_on UNUSEDSIGNAL */
            return set_snap[set_idx[L1D_SET_W-1:0]];
        end
    endfunction

    function automatic logic [3:0] read_l1d_valid(input logic [5:0] set_idx);
        if (L1D_SETS_PARAM == 64) begin
            logic [31:0][3:0] v5;
            logic [15:0][3:0] v4;
            logic [7:0][3:0]  v3;
            logic [3:0][3:0]  v2;
            logic [1:0][3:0]  v1;
            for (int k = 0; k < 32; k++) v5[k] = set_idx[0] ? set_snap[2*k+1].valid : set_snap[2*k].valid;
            for (int k = 0; k < 16; k++) v4[k] = set_idx[1] ? v5[2*k+1]             : v5[2*k];
            for (int k = 0; k < 8;  k++) v3[k] = set_idx[2] ? v4[2*k+1]             : v4[2*k];
            for (int k = 0; k < 4;  k++) v2[k] = set_idx[3] ? v3[2*k+1]             : v3[2*k];
            for (int k = 0; k < 2;  k++) v1[k] = set_idx[4] ? v2[2*k+1]             : v2[2*k];
            return set_idx[5] ? v1[1] : v1[0];
        end else begin
            /* verilator lint_off UNUSEDSIGNAL */
            logic [5:0] unused_hi = set_idx;
            /* verilator lint_on UNUSEDSIGNAL */
            return set_snap[set_idx[L1D_SET_W-1:0]].valid;
        end
    endfunction

`ifndef FURSOY_SYNTH_SRAM_BB
    // 8 Independent Physical 64-bit SRAM Banks (Stage 2 IPC: 8 banks x 64 sets x 4 ways x 64 bits = 16 KiB)
    logic [63:0] bank_data [8][L1D_SETS_PARAM][L1D_WAYS];

    // Helper: read full 512-bit cache line across all 8 banks
    function automatic logic [511:0] read_cache_line(
        input logic [5:0] set_idx,
        input logic [1:0] way_idx
    );
        logic [511:0] line;
        line[63:0]    = bank_data[0][set_idx[L1D_SET_W-1:0]][way_idx];
        line[127:64]  = bank_data[1][set_idx[L1D_SET_W-1:0]][way_idx];
        line[191:128] = bank_data[2][set_idx[L1D_SET_W-1:0]][way_idx];
        line[255:192] = bank_data[3][set_idx[L1D_SET_W-1:0]][way_idx];
        line[319:256] = bank_data[4][set_idx[L1D_SET_W-1:0]][way_idx];
        line[383:320] = bank_data[5][set_idx[L1D_SET_W-1:0]][way_idx];
        line[447:384] = bank_data[6][set_idx[L1D_SET_W-1:0]][way_idx];
        line[511:448] = bank_data[7][set_idx[L1D_SET_W-1:0]][way_idx];
        return line;
    endfunction
`else
    logic [511:0] sram_snoop_line, sram_vic0_line, sram_vic1_line;
    logic [63:0]  sram_ptw_dw, sram_l0_dw, sram_l1_dw;
    logic         sram_b0_en, sram_b1_en, sram_dw_en;
    logic [5:0]   sram_b0_set, sram_b1_set, sram_dw_set;
    logic [1:0]   sram_b0_way, sram_b1_way, sram_dw_way;
    logic [255:0] sram_b0_data, sram_b1_data;
    logic [2:0]   sram_dw_bank;
    logic [7:0]   sram_dw_mask;
    logic [63:0]  sram_dw_data;
`endif

    // 4-way 3-bit Tree-PLRU helpers: b[2]=root (0->{0,1}, 1->{2,3}),
    // b[1]=left {0,1} (0->0, 1->1), b[0]=right {2,3} (0->2, 1->3).
    function automatic logic [1:0] tree_plru_victim(input logic [2:0] plru_bits);
        return plru_bits[2] ? (plru_bits[0] ? 2'd3 : 2'd2)
                            : (plru_bits[1] ? 2'd1 : 2'd0);
    endfunction

    // Returns {found_invalid, victim_way} from a pre-read set snapshot
    function automatic logic [2:0] select_victim_way_meta(
        input logic [3:0] set_valid,
        input logic [2:0] set_lru,
        input logic [3:0] reserved_ways
    );
        logic [1:0] base;
        logic [3:0] inv_ok;
        logic [3:0] unres_ok;
        logic [3:0] rot_inv;
        logic [3:0] rot_unres;
        logic [1:0] inv_off;
        logic [1:0] unres_off;
        logic       found_invalid;
        logic [1:0] victim_way;

        base     = tree_plru_victim(set_lru);
        inv_ok   = (~reserved_ways) & (~set_valid);
        unres_ok = ~reserved_ways;

        case (base)
            2'd0:    begin rot_inv = inv_ok;                      rot_unres = unres_ok;                      end
            2'd1:    begin rot_inv = {inv_ok[0],   inv_ok[3:1]};  rot_unres = {unres_ok[0],   unres_ok[3:1]}; end
            2'd2:    begin rot_inv = {inv_ok[1:0], inv_ok[3:2]};  rot_unres = {unres_ok[1:0], unres_ok[3:2]}; end
            default: begin rot_inv = {inv_ok[2:0], inv_ok[3]};    rot_unres = {unres_ok[2:0], unres_ok[3]};   end
        endcase

        found_invalid = |rot_inv;
        inv_off   = rot_inv[0]   ? 2'd0 : (rot_inv[1]   ? 2'd1 : (rot_inv[2]   ? 2'd2 : 2'd3));
        unres_off = rot_unres[0] ? 2'd0 : (rot_unres[1] ? 2'd1 : (rot_unres[2] ? 2'd2 : (rot_unres[3] ? 2'd3 : 2'd0)));
        victim_way = base + (found_invalid ? inv_off : unres_off);
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

    function automatic logic check_hit_meta(
        /* verilator lint_off UNUSEDSIGNAL */
        input  l1d_set_snap_t snap,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [43:0]   tag,
        output logic [1:0]    hit_way
    );
        logic [3:0] match_oh;
        for (int w = 0; w < L1D_WAYS; w++) begin
            match_oh[w] = snap.valid[w] && (snap.tag[w] == tag);
        end
        hit_way = match_oh[0] ? 2'd0 : (match_oh[1] ? 2'd1 : (match_oh[2] ? 2'd2 : 2'd3));
        return |match_oh;
    endfunction

    function automatic logic [2:0] check_hit_coh_meta(
        /* verilator lint_off UNUSEDSIGNAL */
        input  l1d_set_snap_t snap,
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [43:0]   tag,
        output logic [1:0]    hit_way
    );
        logic [3:0] match_oh, em_oh, s_oh;
        for (int w = 0; w < L1D_WAYS; w++) begin
            match_oh[w] = snap.valid[w] && (snap.tag[w] == tag);
            em_oh[w]    = snap.coh[w][1];
            s_oh[w]     = (snap.coh[w] == 2'd1);
        end
        hit_way = {match_oh[2] | match_oh[3], match_oh[1] | match_oh[3]};
        return {|match_oh, |(match_oh & em_oh), |(match_oh & s_oh)};
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

    // Merge byte-masked store/SC write into a 64-bit word
    function automatic logic [63:0] merge_word(
        input logic [63:0] old_w,
        input logic [7:0]  byte_mask,
        input logic [63:0] new_w
    );
        logic [63:0] res;
        res = old_w;
        for (int b = 0; b < 8; b++) begin
            if (byte_mask[b]) res[b*8 +: 8] = new_w[b*8 +: 8];
        end
        return res;
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

    // Format sub-word load result according to size, sign extension and byte offset.
    // Pre-decodes 1-hot sign-bit selector from early (byte_offset, size, sign_ext)
    // in parallel with byte shifting to minimize post-SRAM combinational depth.
    function automatic logic [63:0] format_load_result_func(
        input logic [63:0] raw_word,
        input logic [2:0]  byte_offset,
        input mem_size_t   size,
        input logic        sign_ext
    );
        logic [7:0]  sign_msbs;
        logic [3:0]  sign_byte_idx;
        logic [3:0]  sb_l1;
        logic [1:0]  sb_l2;
        logic        sb_raw;
        logic        sign_bit;
        logic [63:0] shifted;

        for (int b = 0; b < 8; b++) begin
            sign_msbs[b] = raw_word[b*8 + 7];
        end

        case (size)
            MEM_SIZE_BYTE: sign_byte_idx = {1'b0, byte_offset};
            MEM_SIZE_HALF: sign_byte_idx = {1'b0, byte_offset} + 4'd1;
            MEM_SIZE_WORD: sign_byte_idx = {1'b0, byte_offset} + 4'd3;
            default:       sign_byte_idx = 4'd8;
        endcase
        for (int k = 0; k < 4; k++) begin
            sb_l1[k] = sign_byte_idx[0] ? sign_msbs[2*k+1] : sign_msbs[2*k];
        end
        for (int k = 0; k < 2; k++) begin
            sb_l2[k] = sign_byte_idx[1] ? sb_l1[2*k+1] : sb_l1[2*k];
        end
        sb_raw   = sign_byte_idx[2] ? sb_l2[1] : sb_l2[0];
        sign_bit = sign_ext && !sign_byte_idx[3] && sb_raw;

        case (byte_offset)
            3'd0: shifted = raw_word;
            3'd1: shifted = {8'd0,  raw_word[63:8]};
            3'd2: shifted = {16'd0, raw_word[63:16]};
            3'd3: shifted = {24'd0, raw_word[63:24]};
            3'd4: shifted = {32'd0, raw_word[63:32]};
            3'd5: shifted = {40'd0, raw_word[63:40]};
            3'd6: shifted = {48'd0, raw_word[63:48]};
            3'd7: shifted = {56'd0, raw_word[63:56]};
        endcase

        case (size)
            MEM_SIZE_BYTE:   return {{56{sign_bit}}, shifted[7:0]};
            MEM_SIZE_HALF:   return {{48{sign_bit}}, shifted[15:0]};
            MEM_SIZE_WORD:   return {{32{sign_bit}}, shifted[31:0]};
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
    mesi_state_t refill_state_q;
    logic        refill_has_data_q;

    // 2-Stage Coherence Snoop Pipeline Registers (active when SMP_COHERENCE_EN=1)
    logic        snoop_s0_valid_q;
    logic [49:0] snoop_s0_addr_q;
    logic [1:0]  snoop_s0_type_q;
    logic        snoop_rsp_valid_q;
    logic [49:0] snoop_rsp_addr_q;
    logic        snoop_rsp_has_data_q;
    logic [511:0] snoop_rsp_data_q;
    logic        snoop_rsp_was_dirty_q;

    // 1-Cycle Pipelined WBB Victim SRAM Read Descriptors
    logic        wbb_data_pend_q [WBB_DEPTH];
    logic [5:0]  wbb_rd_set_q    [WBB_DEPTH];
    logic [1:0]  wbb_rd_way_q    [WBB_DEPTH];

    // Slice-2 Line-Locked AMO & Coherence-Point SC Acquire Registers
    logic        amo_line_lock_q;
    logic [49:0] amo_lock_addr_q;
    logic        sc_busy_q;
    mshr_idx_t   sc_mshr_idx_q;
    logic        sc_aborted_q;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [55:0] sc_pend_pa_q;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  sc_pend_mask_q;
    logic [63:0] sc_pend_data_q;

    // DRAM Refill Response Buffer (absorbs back-to-back DRAM responses)
    typedef struct packed {
        mshr_idx_t    tag;
        logic [511:0] data;
        mesi_state_t  state;
        logic         has_data;
    } refill_rsp_entry_t;

    refill_rsp_entry_t rsp_fifo_q [MSHR_DEPTH];
    logic [1:0] rsp_fifo_head_q;
    logic [1:0] rsp_fifo_tail_q;
    logic [2:0] rsp_fifo_count_q;

    wire refill_arriving = bus_rd_rsp_valid_i && mshr_q[bus_rd_rsp_tag_i].valid;
    wire cache_busy_refill = (rsp_fifo_count_q != 3'd0) || refill_arriving || refill_busy_q;
    wire refill_beat0_active = !refill_busy_q && !(SMP_COHERENCE_EN && snoop_s0_valid_q) &&
                               ((rsp_fifo_count_q != 3'd0) || refill_arriving);

    // Multi-MSHR Concurrent Waiter Drain Engine
    logic [1:0] drain_mshr_idx;
    logic [3:0] drain_waiter_idx;
    logic       raw_drain_found;
    logic       drain_found;

    function automatic logic [4:0] prio16_tree(input logic [15:0] v);
        logic [3:0] grp_v;
        logic [1:0] g_idx, b_idx;
        grp_v[0] = |v[3:0];   grp_v[1] = |v[7:4];
        grp_v[2] = |v[11:8];  grp_v[3] = |v[15:12];
        if      (grp_v[0]) g_idx = 2'd0;
        else if (grp_v[1]) g_idx = 2'd1;
        else if (grp_v[2]) g_idx = 2'd2;
        else               g_idx = 2'd3;
        case (g_idx)
            2'd0: b_idx = v[0]  ? 2'd0 : (v[1]  ? 2'd1 : (v[2]  ? 2'd2 : 2'd3));
            2'd1: b_idx = v[4]  ? 2'd0 : (v[5]  ? 2'd1 : (v[6]  ? 2'd2 : 2'd3));
            2'd2: b_idx = v[8]  ? 2'd0 : (v[9]  ? 2'd1 : (v[10] ? 2'd2 : 2'd3));
            default: b_idx = v[12] ? 2'd0 : (v[13] ? 2'd1 : (v[14] ? 2'd2 : 2'd3));
        endcase
        return {|grp_v, g_idx, b_idx};
    endfunction

    always_comb begin
        logic [MSHR_DEPTH-1:0] m_has_waiter;
        logic [3:0]            m_first_w [MSHR_DEPTH];
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            logic [15:0] w_elig;
            logic [4:0]  enc;
            logic        m_draining;
            m_draining = mshr_q[m].valid && (mshr_q[m].state == MSHR_DRAIN_WAITERS);
            for (int w = 0; w < LQ_DEPTH; w++) begin
                w_elig[w] = mshr_q[m].waiter_mask[w] && mshr_waiters_q[m][w].waiter_valid;
            end
            enc = prio16_tree(w_elig);
            m_has_waiter[m] = m_draining && enc[4];
            m_first_w[m]    = enc[3:0];
        end
        raw_drain_found = |m_has_waiter;
        if      (m_has_waiter[0]) drain_mshr_idx = 2'd0;
        else if (m_has_waiter[1]) drain_mshr_idx = 2'd1;
        else if (m_has_waiter[2]) drain_mshr_idx = 2'd2;
        else                      drain_mshr_idx = 2'd3;
        drain_waiter_idx = m_first_w[drain_mshr_idx];
        drain_found      = raw_drain_found && !flush_valid_i && !recover_valid_i;
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

        if (raw_drain_found) begin
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
    // When SMP_COHERENCE_EN=0: 0-cycle combinational Slice-1 protocol.
    // When SMP_COHERENCE_EN=1: 2-stage pipeline (S0 tag/WBB/bank read -> S1 rsp).
    // =========================================================================
    wire        eff_snoop_valid = SMP_COHERENCE_EN ? snoop_s0_valid_q : snoop_req_valid_i;
    wire [49:0] eff_snoop_addr  = SMP_COHERENCE_EN ? snoop_s0_addr_q  : snoop_req_addr_i;
    wire [1:0]  eff_snoop_type  = SMP_COHERENCE_EN ? snoop_s0_type_q  : snoop_req_type_i;

    wire [5:0]  snoop_set  = eff_snoop_addr[5:0];
    wire [43:0] snoop_tag  = eff_snoop_addr[49:6];
    l1d_set_snap_t snoop_meta;
    assign snoop_meta = read_l1d_set(snoop_set);
    logic [1:0] snoop_hit_way;
    wire        snoop_cache_hit = eff_snoop_valid && check_hit_meta(snoop_meta, snoop_tag, snoop_hit_way);

    wbb_idx_t   snoop_wbb_idx;
    wire        snoop_wbb_hit   = eff_snoop_valid && check_wbb_hit(eff_snoop_addr, snoop_wbb_idx);

    /* verilator lint_off UNUSEDSIGNAL */
    mshr_idx_t  snoop_mshr_match_idx;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        snoop_mshr_hit  = eff_snoop_valid && check_mshr_match(eff_snoop_addr, snoop_mshr_match_idx);

    assign event_snoop_query_o  = eff_snoop_valid;
    assign event_snoop_hit_o    = eff_snoop_valid && (snoop_cache_hit || snoop_wbb_hit || snoop_mshr_hit);

    wire snoop_do_read = (eff_snoop_type[1] == 1'b1);
    wire snoop_do_inv  = (eff_snoop_type[0] == 1'b1) || (eff_snoop_type == 2'b00);

    wire snoop_is_dirty = (snoop_cache_hit && snoop_meta.dirty[snoop_hit_way]) ||
                          (snoop_wbb_hit && wbb_q[snoop_wbb_idx].dirty);

    wire snoop_s0_has_data  = eff_snoop_valid && snoop_is_dirty && snoop_do_read;
    wire snoop_s0_was_dirty = eff_snoop_valid && snoop_is_dirty;

    logic [511:0] snoop_s0_data;
    always_comb begin
        snoop_s0_data = 512'd0;
        if (snoop_cache_hit && snoop_s0_has_data) begin
`ifndef FURSOY_SYNTH_SRAM_BB
            snoop_s0_data = read_cache_line(snoop_set, snoop_hit_way);
`else
            snoop_s0_data = sram_snoop_line;
`endif
        end else if (snoop_wbb_hit && snoop_s0_has_data) begin
            if (wbb_data_pend_q[snoop_wbb_idx]) begin
`ifndef FURSOY_SYNTH_SRAM_BB
                snoop_s0_data = read_cache_line(wbb_rd_set_q[snoop_wbb_idx], wbb_rd_way_q[snoop_wbb_idx]);
`else
                snoop_s0_data = (snoop_wbb_idx == 1'b0) ? sram_vic0_line : sram_vic1_line;
`endif
            end else begin
                snoop_s0_data = wbb_q[snoop_wbb_idx].data;
            end
        end
    end

    wire snoop_s1_blocking = snoop_rsp_valid_q && !snoop_rsp_ready_i;
    logic sc_case_a_fire;
    logic sc_alloc_fire;
    logic load0_accept;
    assign snoop_req_ready_o    = SMP_COHERENCE_EN ?
                                  (!snoop_s0_valid_q && !snoop_s1_blocking && !refill_busy_q &&
                                   !refill_beat0_active && !amo_line_lock_q &&
                                   !sc_case_a_fire && !(load0_accept && load0_req_is_amo_i)) :
                                  1'b1;

    assign snoop_rsp_valid_o     = SMP_COHERENCE_EN ? snoop_rsp_valid_q     : eff_snoop_valid;
    assign snoop_rsp_was_dirty_o = SMP_COHERENCE_EN ? snoop_rsp_was_dirty_q : snoop_s0_was_dirty;
    assign snoop_rsp_has_data_o  = SMP_COHERENCE_EN ? snoop_rsp_has_data_q  : snoop_s0_has_data;
    assign snoop_rsp_data_o      = SMP_COHERENCE_EN ? snoop_rsp_data_q      : snoop_s0_data;
    assign snoop_rsp_ack_only_o  = snoop_rsp_valid_o && !snoop_rsp_has_data_o;

    assign snoop_s0_valid_o  = SMP_COHERENCE_EN && snoop_s0_valid_q;
    assign snoop_s0_addr_o   = snoop_s0_addr_q;
    assign snoop_s0_do_inv_o = SMP_COHERENCE_EN && snoop_s0_valid_q && snoop_do_inv;

    // Snoop dirty readout claims all 8 banks if cache line must be read out
    // (In SMP mode, qualify purely from registered S0 valid + read type to keep tag CAM off load/store critical paths)
    wire snoop_claims_banks = SMP_COHERENCE_EN ? (snoop_s0_valid_q && snoop_do_read)
                                               : (snoop_cache_hit && snoop_s0_has_data);

    // Hardware PTW Coherent Dirty-Line Forwarding (Read-Only, Non-Destructive)
    /* verilator lint_off UNUSEDSIGNAL */
    wire [2:0]  unused_ptw_snoop_lo = ptw_snoop_pa_i[2:0];
    /* verilator lint_on UNUSEDSIGNAL */
    wire [5:0]  ptw_snoop_set  = ptw_snoop_pa_i[11:6];
    wire [43:0] ptw_snoop_tag  = ptw_snoop_pa_i[55:12];
    wire [49:0] ptw_snoop_line = ptw_snoop_pa_i[55:6];
    wire [2:0]  ptw_snoop_bank = ptw_snoop_pa_i[5:3];

    l1d_set_snap_t ptw_meta;
    assign ptw_meta = read_l1d_set(ptw_snoop_set);
    logic [1:0] ptw_snoop_way;
    wire        ptw_snoop_cache_hit = check_hit_meta(ptw_meta, ptw_snoop_tag, ptw_snoop_way);
    wbb_idx_t   ptw_snoop_wbb_idx;
    wire        ptw_snoop_in_wbb    = check_wbb_hit(ptw_snoop_line, ptw_snoop_wbb_idx);
    wire        ptw_snoop_wbb_hit   = ptw_snoop_in_wbb && !(SMP_COHERENCE_EN && wbb_q[ptw_snoop_wbb_idx].draining);

    always_comb begin
        ptw_snoop_dirty_hit_o = 1'b0;
        ptw_snoop_data_o      = 64'd0;
        if (ptw_snoop_cache_hit && ptw_meta.dirty[ptw_snoop_way]) begin
            ptw_snoop_dirty_hit_o = 1'b1;
`ifndef FURSOY_SYNTH_SRAM_BB
            ptw_snoop_data_o      = bank_data[ptw_snoop_bank][ptw_snoop_set[L1D_SET_W-1:0]][ptw_snoop_way];
`else
            ptw_snoop_data_o      = sram_ptw_dw;
`endif
        end else if (ptw_snoop_wbb_hit && wbb_q[ptw_snoop_wbb_idx].dirty) begin
            ptw_snoop_dirty_hit_o = 1'b1;
            if (wbb_data_pend_q[ptw_snoop_wbb_idx]) begin
`ifndef FURSOY_SYNTH_SRAM_BB
                ptw_snoop_data_o  = bank_data[ptw_snoop_bank][wbb_rd_set_q[ptw_snoop_wbb_idx][L1D_SET_W-1:0]][wbb_rd_way_q[ptw_snoop_wbb_idx]];
`else
                ptw_snoop_data_o  = (ptw_snoop_wbb_idx == 1'b0) ? sram_vic0_line[ptw_snoop_pa_i[5:3] * 64 +: 64]
                                                                : sram_vic1_line[ptw_snoop_pa_i[5:3] * 64 +: 64];
`endif
            end else begin
                ptw_snoop_data_o  = wbb_q[ptw_snoop_wbb_idx].data[ptw_snoop_pa_i[5:3] * 64 +: 64];
            end
        end
    end

    // =========================================================================
    // Store Drain Request Evaluation (Priority 3)
    // =========================================================================
    wire [5:0]  store_set     = store_drain_pa_i[11:6];
    wire [43:0] store_tag     = store_drain_pa_i[55:12];
    wire [49:0] store_line    = store_drain_pa_i[55:6];
    wire [2:0]  store_bank    = store_drain_pa_i[5:3];

    l1d_set_snap_t store_meta;
    assign store_meta = read_l1d_set(store_set);
    logic [1:0] store_cache_hit_way;
    logic       store_cache_hit, store_hit_em, store_hit_s;
    assign {store_cache_hit, store_hit_em, store_hit_s} = check_hit_coh_meta(store_meta, store_tag, store_cache_hit_way);
    wire store_cache_writable      = SMP_COHERENCE_EN ? store_hit_em : store_cache_hit;
    wire store_cache_needs_upgrade = SMP_COHERENCE_EN && store_hit_s;

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
                store_set_mshr_reserved_ways |= way_oh4(mshr_q[m].victim_way);
            end
        end
    end

    // Candidate victim way for store miss allocation
    logic [1:0] store_victim_way;
    logic       store_found_invalid;
    assign {store_found_invalid, store_victim_way} = select_victim_way_meta(store_meta.valid, store_meta.lru, store_set_mshr_reserved_ways);

    wire clean_active = (clean_state_q != CLEAN_IDLE) || dcache_clean_all_req_i;

    wire store_victim_is_dirty = store_meta.valid[store_victim_way] && store_meta.dirty[store_victim_way];
    wire store_can_alloc_miss  = (mshr_free_count > 0) && (store_set_mshr_reserved_ways != 4'b1111) &&
                                 !store_in_wbb &&
                                 (!store_victim_is_dirty || (wbb_avail_count > 0));
    wire store_can_alloc_upgrade = store_cache_needs_upgrade && !store_mshr_match && (mshr_free_count > 0);
    wire store_can_alloc_mshr  = store_cache_needs_upgrade ? store_can_alloc_upgrade : store_can_alloc_miss;

    wire snoop_hazard_store = SMP_COHERENCE_EN && (
        (snoop_s0_valid_q  && (snoop_s0_addr_q  == store_line)) ||
        (snoop_rsp_valid_q && (snoop_rsp_addr_q == store_line))
    );

    wire store_can_drain = store_drain_valid_i && !cache_busy_refill && !snoop_claims_banks && !clean_active &&
                           !snoop_hazard_store && !(store_wbb_hit && wbb_data_pend_q[store_wbb_idx]) &&
                           (store_cache_writable || store_wbb_hit || store_mshr_match || store_can_alloc_mshr);
    wire store_alloc_mshr    = store_can_drain && !store_cache_writable && !store_wbb_hit && !store_mshr_match;
    wire store_alloc_upgrade = store_alloc_mshr && store_cache_needs_upgrade;
    wire store_alloc_miss    = store_alloc_mshr && !store_cache_needs_upgrade;

    assign store_drain_ready_o = store_can_drain;
    assign store_drain_done_o  = store_can_drain && (store_cache_writable || store_wbb_hit);

    // Store Drain claims its target bank if it writes in cache
    wire store_claims_bank = store_can_drain && store_cache_writable;
    wire [2:0] store_claimed_bank = store_bank;

    // =========================================================================
    // Coherence-Point SC Acquire Evaluation (Priority 3b, Slice-2)
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    wire [5:0]  sc_set  = sc_acquire_pa_i[11:6];
    wire [43:0] sc_tag  = sc_acquire_pa_i[55:12];
    wire [49:0] sc_line = sc_acquire_pa_i[55:6];
    wire [2:0]  sc_bank = sc_acquire_pa_i[5:3];
    /* verilator lint_on UNUSEDSIGNAL */

    l1d_set_snap_t sc_meta;
    assign sc_meta = read_l1d_set(sc_set);
    logic [1:0] sc_cache_hit_way;
    /* verilator lint_off UNUSEDSIGNAL */
    logic       sc_cache_hit;
    /* verilator lint_on UNUSEDSIGNAL */
    logic       sc_cache_writable, sc_needs_upgrade;
    assign {sc_cache_hit, sc_cache_writable, sc_needs_upgrade} = check_hit_coh_meta(sc_meta, sc_tag, sc_cache_hit_way);

    /* verilator lint_off UNUSEDSIGNAL */
    wbb_idx_t   sc_wbb_idx;
    mshr_idx_t  sc_mshr_match_idx;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        sc_in_wbb         = check_wbb_hit(sc_line, sc_wbb_idx);
    wire        sc_mshr_match     = check_mshr_match(sc_line, sc_mshr_match_idx);

    logic [3:0] sc_set_mshr_reserved_ways;
    always_comb begin
        sc_set_mshr_reserved_ways = 4'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr_q[m].valid && (mshr_q[m].line_addr[5:0] == sc_set)) begin
                sc_set_mshr_reserved_ways |= way_oh4(mshr_q[m].victim_way);
            end
        end
    end
    logic [1:0] sc_victim_way;
    /* verilator lint_off UNUSEDSIGNAL */
    logic       sc_found_invalid;
    /* verilator lint_on UNUSEDSIGNAL */
    assign {sc_found_invalid, sc_victim_way} = select_victim_way_meta(sc_meta.valid, sc_meta.lru, sc_set_mshr_reserved_ways);
    wire sc_victim_is_dirty = sc_meta.valid[sc_victim_way] && sc_meta.dirty[sc_victim_way];
    wire sc_can_alloc_miss  = (mshr_free_count > 0) && (sc_set_mshr_reserved_ways != 4'b1111) &&
                              (!sc_victim_is_dirty || (wbb_avail_count > 0));
    wire sc_can_alloc_upg   = sc_needs_upgrade && (mshr_free_count > 0);
    wire sc_can_eval        = SMP_COHERENCE_EN && sc_acquire_valid_i && !sc_busy_q &&
                              !cache_busy_refill && !snoop_claims_banks && !clean_active &&
                              !snoop_req_valid_i && !snoop_s0_valid_q && !snoop_rsp_valid_q &&
                              !store_can_drain && !sc_in_wbb && !sc_mshr_match;

    assign sc_case_a_fire = sc_can_eval && sc_cache_writable && sc_res_valid_i;
    assign sc_alloc_fire  = sc_can_eval && !sc_cache_writable && sc_res_valid_i &&
                            (sc_needs_upgrade ? sc_can_alloc_upg : sc_can_alloc_miss);

    wire [3:0] beat1_valid_set = read_l1d_valid(mshr_q[refill_tag_q].line_addr[5:0]);
    wire sc_reissue_now = SMP_COHERENCE_EN && refill_busy_q &&
                          (mshr_q[refill_tag_q].req_op == COH_UPGRADE) &&
                          !refill_has_data_q &&
                          (mshr_q[refill_tag_q].snoop_inv_seen || !beat1_valid_set[mshr_q[refill_tag_q].upgrade_way]);
    wire sc_beat1_finish = SMP_COHERENCE_EN && refill_busy_q && !sc_reissue_now &&
                           sc_busy_q && (refill_tag_q == sc_mshr_idx_q) && mshr_q[refill_tag_q].is_sc;
    wire sc_beat1_win    = sc_beat1_finish && !sc_aborted_q && sc_res_valid_i;

    assign sc_acquire_accepted_o = sc_alloc_fire;
    assign sc_acquire_done_o     = sc_case_a_fire || sc_beat1_finish;
    assign sc_acquire_ok_o       = sc_case_a_fire || sc_beat1_win;

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
    l1d_set_snap_t load0_meta;
    assign load0_meta = read_l1d_set(load0_set);
    logic [1:0] load0_cache_hit_way;
    logic       load0_raw_cache_hit, load0_hit_em, load0_hit_s;
    assign {load0_raw_cache_hit, load0_hit_em, load0_hit_s} = check_hit_coh_meta(load0_meta, load0_tag, load0_cache_hit_way);
    wire load0_amo_own_ok = !SMP_COHERENCE_EN || !load0_req_is_amo_i || load0_hit_em;
    wire load0_cache_hit = load0_raw_cache_hit && load0_amo_own_ok;
    wire load0_amo_needs_upgrade = SMP_COHERENCE_EN && load0_req_is_amo_i && load0_hit_s;

    l1d_set_snap_t load1_meta;
    assign load1_meta = read_l1d_set(load1_set);
    logic [1:0] load1_cache_hit_way;
    wire load1_cache_hit = check_hit_meta(load1_meta, load1_tag, load1_cache_hit_way);

    // WBB hit checks (ignore draining entries when SMP_COHERENCE_EN=1)
    wbb_idx_t load0_wbb_idx;
    wire load0_in_wbb       = check_wbb_hit(load0_line, load0_wbb_idx);
    wire load0_wbb_draining = SMP_COHERENCE_EN && load0_in_wbb && wbb_q[load0_wbb_idx].draining;
    wire load0_wbb_hit      = load0_in_wbb && !load0_wbb_draining;

    wbb_idx_t load1_wbb_idx;
    wire load1_in_wbb       = check_wbb_hit(load1_line, load1_wbb_idx);
    wire load1_wbb_draining = SMP_COHERENCE_EN && load1_in_wbb && wbb_q[load1_wbb_idx].draining;
    wire load1_wbb_hit      = load1_in_wbb && !load1_wbb_draining;

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
                load0_set_mshr_reserved_ways |= way_oh4(mshr_q[m].victim_way);
            end
        end
    end

    // Candidate victim way for load0
    logic [1:0] load0_victim_way;
    logic       load0_found_invalid;
    assign {load0_found_invalid, load0_victim_way} = select_victim_way_meta(load0_meta.valid, load0_meta.lru, load0_set_mshr_reserved_ways);

    wire load0_victim_is_dirty = load0_meta.valid[load0_victim_way] && load0_meta.dirty[load0_victim_way];
    wire load0_can_alloc_upg  = load0_amo_needs_upgrade && (mshr_free_count > 0) && !load0_mshr_match;
    wire load0_can_alloc_miss = (mshr_free_count > 0) && (load0_set_mshr_reserved_ways != 4'b1111) &&
                                (!load0_victim_is_dirty || (wbb_avail_count > 0));
    wire load0_can_alloc_mshr = load0_amo_needs_upgrade ? load0_can_alloc_upg : load0_can_alloc_miss;

    // Reserved ways in load1_set
    logic [3:0] load1_set_mshr_reserved_ways;
    always_comb begin
        load1_set_mshr_reserved_ways = 4'b0;
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            if (mshr_q[m].valid && (mshr_q[m].line_addr[5:0] == load1_set)) begin
                load1_set_mshr_reserved_ways |= way_oh4(mshr_q[m].victim_way);
            end
        end
    end

    // Candidate victim way for load1
    logic [1:0] load1_victim_way;
    logic       load1_found_invalid;
    assign {load1_found_invalid, load1_victim_way} = select_victim_way_meta(load1_meta.valid, load1_meta.lru, load1_set_mshr_reserved_ways);

    wire load1_victim_is_dirty = load1_meta.valid[load1_victim_way] && load1_meta.dirty[load1_victim_way];
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

    wire snoop_hazard_load0 = SMP_COHERENCE_EN && (
        (snoop_s0_valid_q  && (snoop_s0_addr_q  == load0_line)) ||
        (snoop_rsp_valid_q && (snoop_rsp_addr_q == load0_line))
    );
    wire snoop_hazard_load1 = SMP_COHERENCE_EN && (
        (snoop_s0_valid_q  && (snoop_s0_addr_q  == load1_line)) ||
        (snoop_rsp_valid_q && (snoop_rsp_addr_q == load1_line))
    );

    // Load 0 Acceptance
    wire load0_amo_snoop_stall = SMP_COHERENCE_EN && load0_req_is_amo_i && (snoop_req_valid_i || snoop_s0_valid_q || snoop_rsp_valid_q);
    assign load0_accept = load0_req_valid_i && !load0_squashed && !cache_busy_refill && !snoop_claims_banks && !clean_active &&
                          !load0_wbb_draining && !(load0_wbb_hit && wbb_data_pend_q[load0_wbb_idx]) && !snoop_hazard_load0 && !load0_amo_snoop_stall &&
                          !(sc_case_a_fire || sc_alloc_fire) &&
                          !load0_misaligned &&
                          !load0_collides_with_store &&
                          !load0_store_hazard &&
                          !(bank_conflict_loads && !l0_wins_bank) &&
                          (load0_cache_hit || load0_wbb_hit || load0_mshr_match || load0_can_alloc_mshr);

    assign load0_req_ready_o = load0_accept;

    // Load 1 Acceptance
    wire load1_accept = load1_req_valid_i && !load1_squashed && !cache_busy_refill && !snoop_claims_banks && !clean_active &&
                        !load1_wbb_draining && !(load1_wbb_hit && wbb_data_pend_q[load1_wbb_idx]) && !snoop_hazard_load1 &&
                        !(sc_case_a_fire || sc_alloc_fire) &&
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
        logic [63:0] cache_dw, wbb_dw;
        load0_rsp_valid_o   = load0_accept;
        load0_rsp_lq_idx_o  = load0_req_lq_idx_i;
        load0_rsp_hit_o     = (load0_cache_hit || load0_wbb_hit) && !load0_misaligned;
        load0_rsp_mshr_id_o = load0_mshr_match ? load0_mshr_match_idx : mshr_free_slot;
`ifndef FURSOY_SYNTH_SRAM_BB
        cache_dw = bank_data[load0_bank][load0_set[L1D_SET_W-1:0]][load0_cache_hit_way];
`else
        cache_dw = sram_l0_dw;
`endif
        wbb_dw = extract_word_from_line(wbb_q[load0_wbb_idx].data, load0_req_pa_i[5:0]);
        load0_rsp_data_o = load0_wbb_hit
            ? format_load_result_func(wbb_dw,   load0_req_pa_i[2:0], load0_req_size_i, load0_req_sign_ext_i)
            : format_load_result_func(cache_dw, load0_req_pa_i[2:0], load0_req_size_i, load0_req_sign_ext_i);
    end

    // Port 3 / Load 1 Response
    always_comb begin
        logic [63:0] cache_dw, wbb_dw;
        load1_rsp_valid_o   = load1_accept;
        load1_rsp_lq_idx_o  = load1_req_lq_idx_i;
        load1_rsp_hit_o     = (load1_cache_hit || load1_wbb_hit) && !load1_misaligned;
        load1_rsp_mshr_id_o = load1_mshr_match ? load1_mshr_match_idx :
                              (load0_is_miss ? 2'(mshr_free_slot + 2'd1) : mshr_free_slot);
`ifndef FURSOY_SYNTH_SRAM_BB
        if (same_dw_loads) begin
            // Bank Broadcast: Read data from identical bank doubleword broadcast concurrently (§6.3, PROP_M7_12)
            cache_dw = bank_data[load0_bank][load0_set[L1D_SET_W-1:0]][load0_cache_hit_way];
        end else begin
            cache_dw = bank_data[load1_bank][load1_set[L1D_SET_W-1:0]][load1_cache_hit_way];
        end
`else
        // Bank broadcast for same_dw_loads occurs inside u_bank_sram (rd_l1_* == rd_l0_*)
        cache_dw = sram_l1_dw;
`endif
        wbb_dw = extract_word_from_line(wbb_q[load1_wbb_idx].data, load1_req_pa_i[5:0]);
        load1_rsp_data_o = load1_wbb_hit
            ? format_load_result_func(wbb_dw,   load1_req_pa_i[2:0], load1_req_size_i, load1_req_sign_ext_i)
            : format_load_result_func(cache_dw, load1_req_pa_i[2:0], load1_req_size_i, load1_req_sign_ext_i);
    end

    // Observability & Telemetry Events
    assign event_l1d_hit_o  = (load0_req_valid_i && load0_accept && (load0_cache_hit || load0_wbb_hit)) ||
                              (load1_req_valid_i && load1_accept && (load1_cache_hit || load1_wbb_hit));
    assign event_l1d_miss_o = (load0_req_valid_i && load0_accept && !(load0_cache_hit || load0_wbb_hit)) ||
                              (load1_req_valid_i && load1_accept && !(load1_cache_hit || load1_wbb_hit));

    wire store_mshr_alloc_fire = store_alloc_miss;
    wire load0_mshr_alloc_fire = load0_alloc_new;
    wire load1_mshr_alloc_fire = load1_alloc_new;

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
    assign bus_rd_req_op_o    = SMP_COHERENCE_EN ? mshr_q[bus_req_mshr_idx].req_op : COH_GETS;

    // Effective response attributes (masking legacy Slice-1 tie-offs when SMP_COHERENCE_EN=0)
    wire mesi_state_t eff_rsp_state = SMP_COHERENCE_EN ? bus_rd_rsp_state_i : MESI_S;
    wire              eff_rsp_has_data = SMP_COHERENCE_EN ? bus_rd_rsp_has_data_i : 1'b1;

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
                if (wbb_q[i].valid && wbb_q[i].dirty && !wbb_q[i].draining && !wbb_data_pend_q[i]) begin
                    if (store_drain_valid_i && store_wbb_hit && (store_wbb_idx == 1'(i))) begin
                        continue;
                    end
                    if (SMP_COHERENCE_EN && snoop_s0_valid_q && snoop_wbb_hit && (snoop_wbb_idx == 1'(i))) begin
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
    assign bus_wr_req_dirty_o = 1'b1;

    // Quiescence Diagnostics
    assign l1d_quiescent_o = (mshr_free_count == 3'd4) && (wbb_free_count == 2'd2) &&
                             (rsp_fifo_count_q == 3'd0) &&
                             !(SMP_COHERENCE_EN && (snoop_s0_valid_q || snoop_rsp_valid_q || amo_line_lock_q || sc_busy_q)) &&
                             !drain_found && !bus_wr_inflight_q && !refill_busy_q;

    // =========================================================================
    // Shared Sequential Control Helpers & Generated Per-Slot Queues
    // =========================================================================
    wire              beat0_fifo_fire   = !refill_busy_q && !(SMP_COHERENCE_EN && snoop_s0_valid_q) && (rsp_fifo_count_q != 3'd0);
    wire              beat0_bypass_fire = !refill_busy_q && !(SMP_COHERENCE_EN && snoop_s0_valid_q) && (rsp_fifo_count_q == 3'd0) && refill_arriving;
    wire mshr_idx_t   beat0_m_idx       = beat0_fifo_fire ? rsp_fifo_q[rsp_fifo_head_q].tag : bus_rd_rsp_tag_i;
    wire [511:0]      beat0_data        = beat0_fifo_fire ? rsp_fifo_q[rsp_fifo_head_q].data : bus_rd_rsp_data_i;
    wire              beat0_has_data    = beat0_fifo_fire ? rsp_fifo_q[rsp_fifo_head_q].has_data : eff_rsp_has_data;

    wire [5:0]        beat1_set_i       = mshr_q[refill_tag_q].line_addr[5:0];
    wire              beat1_reissue     = SMP_COHERENCE_EN &&
                                          (mshr_q[refill_tag_q].req_op == COH_UPGRADE) &&
                                          !refill_has_data_q &&
                                          (mshr_q[refill_tag_q].snoop_inv_seen ||
                                           !beat1_valid_set[mshr_q[refill_tag_q].upgrade_way]);
    wire              beat1_line_snoop_inv = SMP_COHERENCE_EN ? 1'b0 :
                                             (mshr_snoop_invalid_q[refill_tag_q] ||
                                              (snoop_req_valid_i && snoop_do_inv &&
                                               (snoop_req_addr_i == mshr_q[refill_tag_q].line_addr)));
    wire mesi_state_t beat1_final_state = beat1_line_snoop_inv ? MESI_I : refill_state_q;

    wire              load0_join_mshr   = load0_accept && !load0_cache_hit && !load0_wbb_hit && load0_mshr_match;
    wire              load0_alloc_upg   = load0_accept && !load0_cache_hit && !load0_wbb_hit && !load0_mshr_match &&
                                          load0_amo_needs_upgrade && load0_can_alloc_mshr;
    wire              load0_alloc_new   = load0_accept && !load0_cache_hit && !load0_wbb_hit && !load0_mshr_match &&
                                          !load0_amo_needs_upgrade && load0_can_alloc_mshr;
    wire              load1_join_mshr   = load1_accept && !load1_cache_hit && !load1_wbb_hit && load1_mshr_match;
    wire              load1_alloc_new   = load1_accept && !load1_cache_hit && !load1_wbb_hit && !load1_mshr_match &&
                                          load1_can_alloc_mshr;
    wire mshr_idx_t   load1_alloc_slot  = (load0_is_miss && load0_accept) ? 2'(mshr_free_slot + 2'd1) : mshr_free_slot;

    // Share one ROB distance subtraction per waiter across MSHR mask & waiter descriptor updates
    wire rob_dist_t   rec_rob_dist      = rob_dist(recover_rob_idx_i, rob_head_i);
    logic [LQ_DEPTH-1:0] waiter_younger [MSHR_DEPTH];
    always_comb begin
        for (int m = 0; m < MSHR_DEPTH; m++) begin
            for (int w = 0; w < LQ_DEPTH; w++) begin
                waiter_younger[m][w] = rob_dist(mshr_waiters_q[m][w].rob_idx, rob_head_i) > rec_rob_dist;
            end
        end
    end

`ifdef FURSOY_SYNTH_SRAM_BB
    assign sram_b0_en   = (beat0_fifo_fire || beat0_bypass_fire) && (!SMP_COHERENCE_EN || beat0_has_data);
    assign sram_b0_set  = mshr_q[beat0_m_idx].line_addr[5:0];
    assign sram_b0_way  = mshr_q[beat0_m_idx].victim_way;
    assign sram_b0_data = beat0_data[255:0];
    assign sram_b1_en   = refill_busy_q && !beat1_reissue && !(SMP_COHERENCE_EN && !refill_has_data_q);
    assign sram_b1_set  = beat1_set_i;
    assign sram_b1_way  = mshr_q[refill_tag_q].victim_way;
    assign sram_b1_data = refill_data_q[511:256];
    assign sram_dw_en   = (store_can_drain && store_cache_writable) || sc_case_a_fire ||
                          (refill_busy_q && !beat1_reissue && SMP_COHERENCE_EN && sc_beat1_win);
    assign sram_dw_bank = (store_can_drain && store_cache_writable) ? store_bank :
                          (sc_case_a_fire ? sc_bank : sc_pend_pa_q[5:3]);
    assign sram_dw_set  = (store_can_drain && store_cache_writable) ? store_set :
                          (sc_case_a_fire ? sc_set : beat1_set_i);
    assign sram_dw_way  = (store_can_drain && store_cache_writable) ? store_cache_hit_way :
                          (sc_case_a_fire ? sc_cache_hit_way :
                           (!refill_has_data_q ? mshr_q[refill_tag_q].upgrade_way : mshr_q[refill_tag_q].victim_way));
    assign sram_dw_mask = (store_can_drain && store_cache_writable) ? store_drain_mask_i :
                          (sc_case_a_fire ? sc_acquire_mask_i : sc_pend_mask_q);
    assign sram_dw_data = (store_can_drain && store_cache_writable) ? store_drain_data_i :
                          (sc_case_a_fire ? sc_acquire_data_i : sc_pend_data_q);

    wire [5:0] sram_snoop_rd_set = (SMP_COHERENCE_EN && !snoop_s0_valid_q) ? mshr_q[beat0_m_idx].line_addr[5:0] : snoop_set;
    wire [1:0] sram_snoop_rd_way = (SMP_COHERENCE_EN && !snoop_s0_valid_q) ? mshr_q[beat0_m_idx].upgrade_way    : snoop_hit_way;

    fursoy_s1_l1d_bank_sram u_bank_sram (
        .clk_i(clk_i),
        .rd_snoop_set_i(sram_snoop_rd_set), .rd_snoop_way_i(sram_snoop_rd_way), .rd_snoop_line_o(sram_snoop_line),
        .rd_ptw_bank_i(ptw_snoop_bank), .rd_ptw_set_i(ptw_snoop_set), .rd_ptw_way_i(ptw_snoop_way), .rd_ptw_dw_o(sram_ptw_dw),
        .rd_l0_bank_i(load0_bank), .rd_l0_set_i(load0_set), .rd_l0_way_i(load0_cache_hit_way), .rd_l0_dw_o(sram_l0_dw),
        .rd_l1_bank_i(load1_bank), .rd_l1_set_i(load1_set), .rd_l1_way_i(load1_cache_hit_way), .rd_l1_dw_o(sram_l1_dw),
        .rd_vic0_set_i(wbb_rd_set_q[0]), .rd_vic0_way_i(wbb_rd_way_q[0]), .rd_vic0_line_o(sram_vic0_line),
        .rd_vic1_set_i(wbb_rd_set_q[1]), .rd_vic1_way_i(wbb_rd_way_q[1]), .rd_vic1_line_o(sram_vic1_line),
        .wr_b0_en_i(sram_b0_en), .wr_b0_set_i(sram_b0_set), .wr_b0_way_i(sram_b0_way), .wr_b0_data_i(sram_b0_data),
        .wr_b1_en_i(sram_b1_en), .wr_b1_set_i(sram_b1_set), .wr_b1_way_i(sram_b1_way), .wr_b1_data_i(sram_b1_data),
        .wr_dw_en_i(sram_dw_en), .wr_dw_bank_i(sram_dw_bank), .wr_dw_set_i(sram_dw_set), .wr_dw_way_i(sram_dw_way),
        .wr_dw_mask_i(sram_dw_mask), .wr_dw_data_i(sram_dw_data)
    );
`endif

    /* verilator lint_off UNUSEDSIGNAL */
    l1d_set_snap_t clean_meta;
    assign clean_meta = read_l1d_set(clean_set_q);
    /* verilator lint_on UNUSEDSIGNAL */

    // Precompute PLRU update ways/enables outside per-set generate loop to minimize fanout and logic depth
    wire       stsc_any_en   = (store_can_drain && (store_cache_writable || store_alloc_miss)) ||
                               (!store_can_drain && (sc_case_a_fire || (sc_alloc_fire && !sc_needs_upgrade)));
    /* verilator lint_off UNUSEDSIGNAL */
    wire [5:0] stsc_any_set  = store_can_drain ? store_set : sc_set;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [1:0] stsc_any_way  = store_can_drain ? (store_cache_writable ? store_cache_hit_way : store_victim_way)
                                               : (sc_case_a_fire ? sc_cache_hit_way : sc_victim_way);
    wire       l0_any_en     = load0_accept && (load0_cache_hit || load0_alloc_new);
    wire [1:0] l0_any_way    = load0_cache_hit ? load0_cache_hit_way : load0_victim_way;
    wire       l1_any_en     = load1_accept && (load1_cache_hit || load1_alloc_new);
    wire [1:0] l1_any_way    = load1_cache_hit ? load1_cache_hit_way : load1_victim_way;

    genvar gm, gw, gs;
    generate
        for (gm = 0; gm < MSHR_DEPTH; gm = gm + 1) begin : gen_mshr
            always_ff @(posedge clk_i) begin
                if (rst_i) begin
                    mshr_q[gm]               <= '0;
                    mshr_snoop_invalid_q[gm] <= 1'b0;
                end else begin
                    if (bus_rd_req_valid_o && bus_rd_req_ready_i && (bus_req_mshr_idx == mshr_idx_t'(gm))) begin
                        mshr_q[gm].state <= MSHR_REQ_SENT;
                    end

                    if (recover_valid_i && mshr_q[gm].valid) begin
                        for (int w = 0; w < LQ_DEPTH; w++) begin
                            if (mshr_q[gm].waiter_mask[w] && mshr_waiters_q[gm][w].waiter_valid &&
                                waiter_younger[gm][w]) begin
                                mshr_q[gm].waiter_mask[w] <= 1'b0;
                            end
                        end
                    end

                    if (flush_valid_i && mshr_q[gm].valid) begin
                        mshr_q[gm].waiter_mask <= 16'd0;
                    end

                    if (eff_snoop_valid && mshr_q[gm].valid && (mshr_q[gm].state != MSHR_DRAIN_WAITERS) &&
                        !mshr_q[gm].grant_committed && (mshr_q[gm].line_addr == eff_snoop_addr)) begin
                        if (SMP_COHERENCE_EN) begin
                            if (snoop_do_inv && (mshr_q[gm].req_op == COH_UPGRADE)) begin
                                mshr_q[gm].snoop_inv_seen <= 1'b1;
                            end
                        end else if (snoop_do_inv) begin
                            mshr_snoop_invalid_q[gm] <= 1'b1;
                        end
                    end

                    if ((beat0_fifo_fire || beat0_bypass_fire) && (beat0_m_idx == mshr_idx_t'(gm))) begin
                        if (!SMP_COHERENCE_EN || beat0_has_data) begin
                            mshr_q[gm].victim_data <= beat0_data;
                        end else begin
`ifndef FURSOY_SYNTH_SRAM_BB
                            mshr_q[gm].victim_data <= read_cache_line(mshr_q[beat0_m_idx].line_addr[5:0], mshr_q[beat0_m_idx].upgrade_way);
`else
                            mshr_q[gm].victim_data <= sram_snoop_line;
`endif
                        end
                    end

                    if (refill_busy_q && (refill_tag_q == mshr_idx_t'(gm))) begin
                        if (beat1_reissue) begin
                            mshr_q[gm].state           <= MSHR_WAIT_BUS;
                            mshr_q[gm].req_op          <= COH_GETM;
                            mshr_q[gm].snoop_inv_seen  <= 1'b0;
                            mshr_q[gm].grant_committed <= 1'b0;
                            mshr_snoop_invalid_q[gm]   <= 1'b0;
                        end else if (SMP_COHERENCE_EN && !refill_has_data_q) begin
                            mshr_snoop_invalid_q[gm] <= 1'b0;
                            if (mshr_q[gm].is_sc && sc_busy_q && (refill_tag_q == sc_mshr_idx_q)) begin
                                mshr_q[gm].valid <= 1'b0;
                                mshr_q[gm].state <= MSHR_IDLE;
                            end else if (mshr_q[gm].is_amo && !flush_valid_i && (mshr_q[gm].waiter_mask != 16'd0)) begin
                                mshr_q[gm].grant_committed <= 1'b1;
                                mshr_q[gm].state           <= MSHR_DRAIN_WAITERS;
                            end else begin
                                mshr_q[gm].valid <= 1'b0;
                                mshr_q[gm].state <= MSHR_IDLE;
                            end
                        end else begin
                            mshr_snoop_invalid_q[gm] <= 1'b0;
                            if (mshr_q[gm].waiter_mask != 16'd0) begin
                                mshr_q[gm].grant_committed <= 1'b1;
                                mshr_q[gm].state           <= MSHR_DRAIN_WAITERS;
                            end else begin
                                mshr_q[gm].valid <= 1'b0;
                                mshr_q[gm].state <= MSHR_IDLE;
                            end
                        end
                    end

                    if (drain_found && (drain_mshr_idx == mshr_idx_t'(gm))) begin
                        mshr_q[gm].waiter_mask[drain_waiter_idx] <= 1'b0;
                        if ((mshr_q[gm].waiter_mask & ~(16'h1 << drain_waiter_idx)) == 16'd0) begin
                            mshr_q[gm].valid <= 1'b0;
                            mshr_q[gm].state <= MSHR_IDLE;
                        end
                    end

                    if (mshr_q[gm].valid && (mshr_q[gm].state == MSHR_DRAIN_WAITERS)) begin
                        if ((mshr_q[gm].waiter_mask == 16'd0) || flush_valid_i ||
                            (drain_found && (drain_mshr_idx == mshr_idx_t'(gm)) &&
                             ((mshr_q[gm].waiter_mask & ~(16'h1 << drain_waiter_idx)) == 16'd0))) begin
                            mshr_q[gm].valid <= 1'b0;
                            mshr_q[gm].state <= MSHR_IDLE;
                        end
                    end

                    if (store_can_drain) begin
                        if (!store_cache_writable && !store_wbb_hit && store_mshr_match &&
                            (store_mshr_match_idx == mshr_idx_t'(gm))) begin
                            mshr_q[gm].store_drain_mask[store_drain_sq_idx_i] <= 1'b1;
                        end else if (store_alloc_upgrade && (mshr_free_slot == mshr_idx_t'(gm))) begin
                            mshr_q[gm].valid               <= 1'b1;
                            mshr_snoop_invalid_q[gm]       <= 1'b0;
                            mshr_q[gm].line_addr           <= store_line;
                            mshr_q[gm].state               <= MSHR_WAIT_BUS;
                            mshr_q[gm].bus_tag             <= mshr_free_slot;
                            mshr_q[gm].waiter_mask         <= 16'd0;
                            mshr_q[gm].store_drain_mask    <= (16'd1 << store_drain_sq_idx_i);
                            mshr_q[gm].wbb_has_reservation <= 1'b0;
                            mshr_q[gm].wbb_reserved_slot   <= '0;
                            mshr_q[gm].victim_way          <= store_cache_hit_way;
                            mshr_q[gm].victim_tag          <= 44'd0;
                            mshr_q[gm].victim_data         <= 512'd0;
                            mshr_q[gm].victim_dirty        <= 1'b0;
                            mshr_q[gm].req_op              <= COH_UPGRADE;
                            mshr_q[gm].upgrade_way         <= store_cache_hit_way;
                            mshr_q[gm].grant_state         <= MESI_I;
                            mshr_q[gm].grant_has_data      <= 1'b0;
                            mshr_q[gm].grant_committed     <= 1'b0;
                            mshr_q[gm].snoop_inv_seen      <= 1'b0;
                            mshr_q[gm].is_amo              <= 1'b0;
                            mshr_q[gm].is_sc               <= 1'b0;
                        end else if (store_alloc_miss && (mshr_free_slot == mshr_idx_t'(gm))) begin
                            mshr_q[gm].valid               <= 1'b1;
                            mshr_snoop_invalid_q[gm]       <= 1'b0;
                            mshr_q[gm].line_addr           <= store_line;
                            mshr_q[gm].state               <= MSHR_WAIT_BUS;
                            mshr_q[gm].bus_tag             <= mshr_free_slot;
                            mshr_q[gm].waiter_mask         <= 16'd0;
                            mshr_q[gm].store_drain_mask    <= (16'd1 << store_drain_sq_idx_i);
                            mshr_q[gm].wbb_has_reservation <= 1'b0;
                            mshr_q[gm].wbb_reserved_slot   <= '0;
                            mshr_q[gm].victim_way          <= store_victim_way;
                            mshr_q[gm].victim_tag          <= 44'd0;
                            mshr_q[gm].victim_data         <= 512'd0;
                            mshr_q[gm].victim_dirty        <= store_victim_is_dirty;
                            mshr_q[gm].req_op              <= COH_GETM;
                            mshr_q[gm].upgrade_way         <= 2'd0;
                            mshr_q[gm].grant_state         <= MESI_I;
                            mshr_q[gm].grant_has_data      <= 1'b0;
                            mshr_q[gm].grant_committed     <= 1'b0;
                            mshr_q[gm].snoop_inv_seen      <= 1'b0;
                            mshr_q[gm].is_amo              <= 1'b0;
                            mshr_q[gm].is_sc               <= 1'b0;
                        end
                    end else if (sc_alloc_fire && (mshr_free_slot == mshr_idx_t'(gm))) begin
                        mshr_q[gm].valid               <= 1'b1;
                        mshr_snoop_invalid_q[gm]       <= 1'b0;
                        mshr_q[gm].line_addr           <= sc_line;
                        mshr_q[gm].state               <= MSHR_WAIT_BUS;
                        mshr_q[gm].bus_tag             <= mshr_free_slot;
                        mshr_q[gm].waiter_mask         <= 16'd0;
                        mshr_q[gm].store_drain_mask    <= 16'd0;
                        mshr_q[gm].wbb_has_reservation <= 1'b0;
                        mshr_q[gm].wbb_reserved_slot   <= '0;
                        mshr_q[gm].victim_way          <= sc_needs_upgrade ? sc_cache_hit_way : sc_victim_way;
                        mshr_q[gm].victim_tag          <= 44'd0;
                        mshr_q[gm].victim_data         <= 512'd0;
                        mshr_q[gm].victim_dirty        <= sc_needs_upgrade ? 1'b0 : sc_victim_is_dirty;
                        mshr_q[gm].req_op              <= sc_needs_upgrade ? COH_UPGRADE : COH_GETM;
                        mshr_q[gm].upgrade_way         <= sc_needs_upgrade ? sc_cache_hit_way : 2'd0;
                        mshr_q[gm].grant_state         <= MESI_I;
                        mshr_q[gm].grant_has_data      <= 1'b0;
                        mshr_q[gm].grant_committed     <= 1'b0;
                        mshr_q[gm].snoop_inv_seen      <= 1'b0;
                        mshr_q[gm].is_amo              <= 1'b0;
                        mshr_q[gm].is_sc               <= 1'b1;
                    end

                    if (load0_join_mshr && (load0_mshr_match_idx == mshr_idx_t'(gm))) begin
                        mshr_q[gm].waiter_mask[load0_req_lq_idx_i] <= 1'b1;
                    end else if (load0_alloc_upg && (mshr_free_slot == mshr_idx_t'(gm))) begin
                        mshr_q[gm].valid               <= 1'b1;
                        mshr_snoop_invalid_q[gm]       <= 1'b0;
                        mshr_q[gm].line_addr           <= load0_line;
                        mshr_q[gm].state               <= MSHR_WAIT_BUS;
                        mshr_q[gm].bus_tag             <= mshr_free_slot;
                        mshr_q[gm].waiter_mask         <= (16'd1 << load0_req_lq_idx_i);
                        mshr_q[gm].store_drain_mask    <= 16'd0;
                        mshr_q[gm].wbb_has_reservation <= 1'b0;
                        mshr_q[gm].wbb_reserved_slot   <= '0;
                        mshr_q[gm].victim_way          <= load0_cache_hit_way;
                        mshr_q[gm].victim_tag          <= 44'd0;
                        mshr_q[gm].victim_data         <= 512'd0;
                        mshr_q[gm].victim_dirty        <= 1'b0;
                        mshr_q[gm].req_op              <= COH_UPGRADE;
                        mshr_q[gm].upgrade_way         <= load0_cache_hit_way;
                        mshr_q[gm].grant_state         <= MESI_I;
                        mshr_q[gm].grant_has_data      <= 1'b0;
                        mshr_q[gm].grant_committed     <= 1'b0;
                        mshr_q[gm].snoop_inv_seen      <= 1'b0;
                        mshr_q[gm].is_amo              <= 1'b1;
                        mshr_q[gm].is_sc               <= 1'b0;
                    end else if (load0_alloc_new && (mshr_free_slot == mshr_idx_t'(gm))) begin
                        mshr_q[gm].valid               <= 1'b1;
                        mshr_snoop_invalid_q[gm]       <= 1'b0;
                        mshr_q[gm].line_addr           <= load0_line;
                        mshr_q[gm].state               <= MSHR_WAIT_BUS;
                        mshr_q[gm].bus_tag             <= mshr_free_slot;
                        mshr_q[gm].waiter_mask         <= (16'd1 << load0_req_lq_idx_i);
                        mshr_q[gm].store_drain_mask    <= 16'd0;
                        mshr_q[gm].wbb_has_reservation <= 1'b0;
                        mshr_q[gm].wbb_reserved_slot   <= '0;
                        mshr_q[gm].victim_way          <= load0_victim_way;
                        mshr_q[gm].victim_tag          <= 44'd0;
                        mshr_q[gm].victim_data         <= 512'd0;
                        mshr_q[gm].victim_dirty        <= load0_victim_is_dirty;
                        mshr_q[gm].req_op              <= (SMP_COHERENCE_EN && load0_req_is_amo_i) ? COH_GETM : COH_GETS;
                        mshr_q[gm].upgrade_way         <= 2'd0;
                        mshr_q[gm].grant_state         <= MESI_I;
                        mshr_q[gm].grant_has_data      <= 1'b0;
                        mshr_q[gm].grant_committed     <= 1'b0;
                        mshr_q[gm].snoop_inv_seen      <= 1'b0;
                        mshr_q[gm].is_amo              <= SMP_COHERENCE_EN && load0_req_is_amo_i;
                        mshr_q[gm].is_sc               <= 1'b0;
                    end

                    if (load1_join_mshr && (load1_mshr_match_idx == mshr_idx_t'(gm))) begin
                        mshr_q[gm].waiter_mask[load1_req_lq_idx_i] <= 1'b1;
                    end else if (load1_alloc_new && (load1_alloc_slot == mshr_idx_t'(gm))) begin
                        mshr_q[gm].valid               <= 1'b1;
                        mshr_snoop_invalid_q[gm]       <= 1'b0;
                        mshr_q[gm].line_addr           <= load1_line;
                        mshr_q[gm].state               <= MSHR_WAIT_BUS;
                        mshr_q[gm].bus_tag             <= load1_alloc_slot;
                        mshr_q[gm].waiter_mask         <= (16'd1 << load1_req_lq_idx_i);
                        mshr_q[gm].store_drain_mask    <= 16'd0;
                        mshr_q[gm].wbb_has_reservation <= 1'b0;
                        mshr_q[gm].wbb_reserved_slot   <= '0;
                        mshr_q[gm].victim_way          <= load1_victim_way;
                        mshr_q[gm].victim_tag          <= 44'd0;
                        mshr_q[gm].victim_data         <= 512'd0;
                        mshr_q[gm].victim_dirty        <= load1_victim_is_dirty;
                        mshr_q[gm].req_op              <= COH_GETS;
                        mshr_q[gm].upgrade_way         <= 2'd0;
                        mshr_q[gm].grant_state         <= MESI_I;
                        mshr_q[gm].grant_has_data      <= 1'b0;
                        mshr_q[gm].grant_committed     <= 1'b0;
                        mshr_q[gm].snoop_inv_seen      <= 1'b0;
                        mshr_q[gm].is_amo              <= 1'b0;
                        mshr_q[gm].is_sc               <= 1'b0;
                    end
                end
            end

            for (gw = 0; gw < LQ_DEPTH; gw = gw + 1) begin : gen_waiter
                always_ff @(posedge clk_i) begin
                    if (rst_i) begin
                        mshr_waiters_q[gm][gw] <= '0;
                    end else begin
                        if (recover_valid_i && mshr_q[gm].valid && mshr_q[gm].waiter_mask[gw] &&
                            mshr_waiters_q[gm][gw].waiter_valid && waiter_younger[gm][gw]) begin
                            mshr_waiters_q[gm][gw].waiter_valid <= 1'b0;
                        end
                        if (flush_valid_i && mshr_q[gm].valid) begin
                            mshr_waiters_q[gm][gw].waiter_valid <= 1'b0;
                        end
                        if (drain_found && (drain_mshr_idx == mshr_idx_t'(gm)) && (drain_waiter_idx == 4'(gw))) begin
                            mshr_waiters_q[gm][gw].waiter_valid <= 1'b0;
                        end
                        if (((load0_join_mshr && (load0_mshr_match_idx == mshr_idx_t'(gm))) ||
                             ((load0_alloc_upg || load0_alloc_new) && (mshr_free_slot == mshr_idx_t'(gm)))) &&
                            (load0_req_lq_idx_i == 4'(gw))) begin
                            mshr_waiters_q[gm][gw].waiter_valid <= 1'b1;
                            mshr_waiters_q[gm][gw].lq_idx       <= load0_req_lq_idx_i;
                            mshr_waiters_q[gm][gw].line_offset  <= load0_req_pa_i[5:0];
                            mshr_waiters_q[gm][gw].size         <= load0_req_size_i;
                            mshr_waiters_q[gm][gw].sign_ext     <= load0_req_sign_ext_i;
                            mshr_waiters_q[gm][gw].pnew         <= load0_req_pnew_i;
                            mshr_waiters_q[gm][gw].rob_idx      <= load0_req_rob_idx_i;
                            mshr_waiters_q[gm][gw].rob_epoch    <= load0_req_rob_epoch_i;
                        end
                        if (((load1_join_mshr && (load1_mshr_match_idx == mshr_idx_t'(gm))) ||
                             (load1_alloc_new && (load1_alloc_slot == mshr_idx_t'(gm)))) &&
                            (load1_req_lq_idx_i == 4'(gw))) begin
                            mshr_waiters_q[gm][gw].waiter_valid <= 1'b1;
                            mshr_waiters_q[gm][gw].lq_idx       <= load1_req_lq_idx_i;
                            mshr_waiters_q[gm][gw].line_offset  <= load1_req_pa_i[5:0];
                            mshr_waiters_q[gm][gw].size         <= load1_req_size_i;
                            mshr_waiters_q[gm][gw].sign_ext     <= load1_req_sign_ext_i;
                            mshr_waiters_q[gm][gw].pnew         <= load1_req_pnew_i;
                            mshr_waiters_q[gm][gw].rob_idx      <= load1_req_rob_idx_i;
                            mshr_waiters_q[gm][gw].rob_epoch    <= load1_req_rob_epoch_i;
                        end
                    end
                end
            end
        end

        for (gw = 0; gw < WBB_DEPTH; gw = gw + 1) begin : gen_wbb
            always_ff @(posedge clk_i) begin
                if (rst_i) begin
                    wbb_q[gw]           <= '0;
                    wbb_data_pend_q[gw] <= 1'b0;
                    wbb_rd_set_q[gw]    <= 6'd0;
                    wbb_rd_way_q[gw]    <= 2'd0;
                end else begin
                    if (wbb_data_pend_q[gw]) begin
                        wbb_data_pend_q[gw] <= 1'b0;
`ifndef FURSOY_SYNTH_SRAM_BB
                        wbb_q[gw].data      <= read_cache_line(wbb_rd_set_q[gw], wbb_rd_way_q[gw]);
`else
                        wbb_q[gw].data      <= (gw == 0) ? sram_vic0_line : sram_vic1_line;
`endif
                    end

                    if (bus_wr_inflight_q) begin
                        if (bus_wr_rsp_valid_i && (bus_wr_inflight_slot_q == wbb_idx_t'(gw))) begin
                            wbb_q[gw].valid    <= 1'b0;
                            wbb_q[gw].dirty    <= 1'b0;
                            wbb_q[gw].draining <= 1'b0;
                        end
                    end else if (bus_wr_req_valid_o && bus_wr_req_ready_i && (bus_wr_slot == wbb_idx_t'(gw))) begin
                        if (bus_wr_rsp_valid_i) begin
                            wbb_q[gw].valid    <= 1'b0;
                            wbb_q[gw].dirty    <= 1'b0;
                            wbb_q[gw].draining <= 1'b0;
                        end else begin
                            wbb_q[gw].draining <= 1'b1;
                        end
                    end

                    if (snoop_wbb_hit && (snoop_wbb_idx == wbb_idx_t'(gw))) begin
                        if (SMP_COHERENCE_EN) begin
                            if (snoop_do_inv || snoop_do_read) begin
                                wbb_q[gw].dirty <= 1'b0;
                                if (!wbb_q[gw].draining) wbb_q[gw].valid <= 1'b0;
                            end
                        end else begin
                            if (snoop_do_inv) wbb_q[gw].valid <= 1'b0;
                            else if (snoop_do_read) wbb_q[gw].dirty <= 1'b0;
                        end
                    end

                    if (store_can_drain) begin
                        if (!store_cache_writable && store_wbb_hit && (store_wbb_idx == wbb_idx_t'(gw))) begin
                            wbb_q[gw].data  <= merge_store_to_line(wbb_q[gw].data, store_drain_pa_i[5:0], store_drain_mask_i, store_drain_data_i);
                            wbb_q[gw].dirty <= 1'b1;
                        end else if (store_alloc_miss && store_victim_is_dirty && (store_wbb_target == wbb_idx_t'(gw))) begin
                            wbb_q[gw].valid      <= 1'b1;
                            wbb_q[gw].dirty      <= 1'b1;
                            wbb_q[gw].draining   <= 1'b0;
                            wbb_q[gw].line_addr  <= {store_meta.tag[store_victim_way], store_set};
                            wbb_q[gw].dirty_mask <= '1;
                            wbb_data_pend_q[gw]  <= 1'b1;
                            wbb_rd_set_q[gw]     <= store_set;
                            wbb_rd_way_q[gw]     <= store_victim_way;
                        end
                    end else if (!sc_case_a_fire && sc_alloc_fire && !sc_needs_upgrade && sc_victim_is_dirty &&
                                 (store_wbb_target == wbb_idx_t'(gw))) begin
                        wbb_q[gw].valid      <= 1'b1;
                        wbb_q[gw].dirty      <= 1'b1;
                        wbb_q[gw].draining   <= 1'b0;
                        wbb_q[gw].line_addr  <= {sc_meta.tag[sc_victim_way], sc_set};
                        wbb_q[gw].dirty_mask <= '1;
                        wbb_data_pend_q[gw]  <= 1'b1;
                        wbb_rd_set_q[gw]     <= sc_set;
                        wbb_rd_way_q[gw]     <= sc_victim_way;
                    end

                    if (load0_alloc_new && load0_victim_is_dirty && (load0_wbb_target == wbb_idx_t'(gw))) begin
                        wbb_q[gw].valid      <= 1'b1;
                        wbb_q[gw].dirty      <= 1'b1;
                        wbb_q[gw].draining   <= 1'b0;
                        wbb_q[gw].line_addr  <= {load0_meta.tag[load0_victim_way], load0_set};
                        wbb_q[gw].dirty_mask <= '1;
                        wbb_data_pend_q[gw]  <= 1'b1;
                        wbb_rd_set_q[gw]     <= load0_set;
                        wbb_rd_way_q[gw]     <= load0_victim_way;
                    end

                    if (load1_alloc_new && load1_victim_is_dirty && (load1_wbb_target == wbb_idx_t'(gw))) begin
                        wbb_q[gw].valid      <= 1'b1;
                        wbb_q[gw].dirty      <= 1'b1;
                        wbb_q[gw].draining   <= 1'b0;
                        wbb_q[gw].line_addr  <= {load1_meta.tag[load1_victim_way], load1_set};
                        wbb_q[gw].dirty_mask <= '1;
                        wbb_data_pend_q[gw]  <= 1'b1;
                        wbb_rd_set_q[gw]     <= load1_set;
                        wbb_rd_way_q[gw]     <= load1_victim_way;
                    end

                    if ((clean_state_q == CLEAN_SWEEP) && !(SMP_COHERENCE_EN && snoop_s0_valid_q) &&
                        clean_meta.valid[clean_way_q] &&
                        clean_meta.dirty[clean_way_q] &&
                        (wbb_avail_count > 0) && (store_wbb_target == wbb_idx_t'(gw))) begin
                        wbb_q[gw].valid      <= 1'b1;
                        wbb_q[gw].dirty      <= 1'b1;
                        wbb_q[gw].draining   <= 1'b0;
                        wbb_q[gw].line_addr  <= {clean_meta.tag[clean_way_q], clean_set_q};
                        wbb_q[gw].dirty_mask <= '1;
                        wbb_data_pend_q[gw]  <= 1'b1;
                        wbb_rd_set_q[gw]     <= clean_set_q;
                        wbb_rd_way_q[gw]     <= clean_way_q;
                    end
                end
            end
        end

        for (gs = 0; gs < L1D_SETS_PARAM; gs = gs + 1) begin : gen_l1d_sets
            logic [3:0][43:0] gs_tag_q;
            logic [3:0]       gs_valid_q;
            logic [3:0]       gs_dirty_q;
            logic [3:0][1:0]  gs_coh_q;
            logic [2:0]       gs_lru_q;

            always_comb begin
                set_snap[gs].tag   = gs_tag_q;
                set_snap[gs].valid = gs_valid_q;
                set_snap[gs].dirty = gs_dirty_q;
                set_snap[gs].coh   = gs_coh_q;
                set_snap[gs].lru   = gs_lru_q;
`ifndef SYNTHESIS
                for (int w = 0; w < L1D_WAYS; w++) begin
                    tag_array[gs][w]       = gs_tag_q[w];
                    valid_array[gs][w]     = gs_valid_q[w];
                    dirty_array[gs][w]     = gs_dirty_q[w];
                    coh_state_array[gs][w] = mesi_state_t'(gs_coh_q[w]);
                end
                lru_array[gs] = gs_lru_q;
`endif
            end

            wire snoop_hit_gs     = snoop_cache_hit && (snoop_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire beat1_gs         = refill_busy_q && !beat1_reissue && (beat1_set_i[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire store_wr_gs      = store_can_drain && store_cache_writable && (store_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire store_mis_gs     = store_can_drain && !store_cache_writable && store_alloc_miss && (store_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire sc_hit_gs        = !store_can_drain && sc_case_a_fire && (sc_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire sc_mis_gs        = !store_can_drain && !sc_case_a_fire && sc_alloc_fire && !sc_needs_upgrade && (sc_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire l0_mis_gs        = load0_accept && !load0_cache_hit && load0_alloc_new && (load0_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire l1_mis_gs        = load1_accept && !load1_cache_hit && load1_alloc_new && (load1_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire clean_gs         = (clean_state_q == CLEAN_SWEEP) && !(SMP_COHERENCE_EN && snoop_s0_valid_q) &&
                                    clean_meta.valid[clean_way_q] && clean_meta.dirty[clean_way_q] &&
                                    (wbb_avail_count > 0) && (clean_set_q[L1D_SET_W-1:0] == L1D_SET_W'(gs));

            wire stsc_plru_gs = stsc_any_en && (stsc_any_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire l0_plru_gs   = l0_any_en && (load0_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire l1_plru_gs   = l1_any_en && (load1_set[L1D_SET_W-1:0] == L1D_SET_W'(gs));
            wire [2:0] nxt_lru_gs = {
                l1_plru_gs ? ~l1_any_way[1] : (l0_plru_gs ? ~l0_any_way[1] : (stsc_plru_gs ? ~stsc_any_way[1] : gs_lru_q[2])),
                (l1_plru_gs && !l1_any_way[1]) ? ~l1_any_way[0] : ((l0_plru_gs && !l0_any_way[1]) ? ~l0_any_way[0] : ((stsc_plru_gs && !stsc_any_way[1]) ? ~stsc_any_way[0] : gs_lru_q[1])),
                (l1_plru_gs &&  l1_any_way[1]) ? ~l1_any_way[0] : ((l0_plru_gs &&  l0_any_way[1]) ? ~l0_any_way[0] : ((stsc_plru_gs &&  stsc_any_way[1]) ? ~stsc_any_way[0] : gs_lru_q[0]))
            };

            always_ff @(posedge clk_i) begin
                if (rst_i) begin
                    gs_lru_q   <= 3'd0;
                    gs_valid_q <= 4'd0;
                    gs_dirty_q <= 4'd0;
                    gs_coh_q   <= '0;
                    gs_tag_q   <= '0;
                end else begin

                    if (snoop_hit_gs) begin
                        for (int w = 0; w < L1D_WAYS; w++) begin
                            if (snoop_hit_way == 2'(w)) begin
                                if (snoop_do_inv) begin
                                    gs_valid_q[w] <= 1'b0;
                                    gs_dirty_q[w] <= 1'b0;
                                    gs_coh_q[w]   <= 2'(MESI_I);
                                end else if (snoop_do_read) begin
                                    gs_dirty_q[w] <= 1'b0;
                                    gs_coh_q[w]   <= 2'(MESI_S);
                                end
                            end
                        end
                    end

                    if (beat1_gs) begin
                        logic [43:0] tag_i;
                        logic [1:0]  rep_way;
                        tag_i   = mshr_q[refill_tag_q].line_addr[49:6];
                        rep_way = mshr_q[refill_tag_q].victim_way;
                        if (SMP_COHERENCE_EN && !refill_has_data_q) begin
                            logic [1:0] upg_way;
                            upg_way = mshr_q[refill_tag_q].upgrade_way;
                            for (int w = 0; w < L1D_WAYS; w++) begin
                                if (upg_way == 2'(w)) begin
                                    gs_valid_q[w] <= !beat1_line_snoop_inv;
                                    if (mshr_q[refill_tag_q].is_sc && sc_busy_q && (refill_tag_q == sc_mshr_idx_q) && sc_beat1_win) begin
                                        gs_dirty_q[w] <= 1'b1;
                                        gs_coh_q[w]   <= 2'(MESI_M);
                                    end else begin
                                        gs_dirty_q[w] <= (beat1_final_state == MESI_M);
                                        gs_coh_q[w]   <= 2'(beat1_final_state);
                                    end
                                end
                            end
                        end else begin
                            for (int w = 0; w < L1D_WAYS; w++) begin
                                if (rep_way == 2'(w)) begin
                                    gs_valid_q[w] <= !beat1_line_snoop_inv;
                                    gs_dirty_q[w] <= SMP_COHERENCE_EN ? (sc_beat1_win || (beat1_final_state == MESI_M)) : 1'b0;
                                    gs_coh_q[w]   <= SMP_COHERENCE_EN ? (sc_beat1_win ? 2'(MESI_M) : 2'(beat1_final_state)) : 2'(MESI_I);
                                    gs_tag_q[w]   <= tag_i;
                                end
                            end
                        end
                    end

                    if (store_wr_gs) begin
                        for (int w = 0; w < L1D_WAYS; w++) begin
                            if (store_cache_hit_way == 2'(w)) begin
                                gs_dirty_q[w] <= 1'b1;
                                if (SMP_COHERENCE_EN) begin
                                    gs_coh_q[w] <= 2'(MESI_M);
                                end
                            end
                        end
                    end else if (store_mis_gs) begin
                        for (int w = 0; w < L1D_WAYS; w++) begin
                            if (store_victim_way == 2'(w)) begin
                                gs_valid_q[w] <= 1'b0;
                                gs_dirty_q[w] <= 1'b0;
                                gs_coh_q[w]   <= 2'(MESI_I);
                            end
                        end
                    end else if (sc_hit_gs) begin
                        for (int w = 0; w < L1D_WAYS; w++) begin
                            if (sc_cache_hit_way == 2'(w)) begin
                                gs_dirty_q[w] <= 1'b1;
                                gs_coh_q[w]   <= 2'(MESI_M);
                            end
                        end
                    end else if (sc_mis_gs) begin
                        for (int w = 0; w < L1D_WAYS; w++) begin
                            if (sc_victim_way == 2'(w)) begin
                                gs_valid_q[w] <= 1'b0;
                                gs_dirty_q[w] <= 1'b0;
                                gs_coh_q[w]   <= 2'(MESI_I);
                            end
                        end
                    end

                    if (l0_mis_gs) begin
                        for (int w = 0; w < L1D_WAYS; w++) begin
                            if (load0_victim_way == 2'(w)) begin
                                gs_valid_q[w] <= 1'b0;
                                gs_dirty_q[w] <= 1'b0;
                                gs_coh_q[w]   <= 2'(MESI_I);
                            end
                        end
                    end

                    if (l1_mis_gs) begin
                        for (int w = 0; w < L1D_WAYS; w++) begin
                            if (load1_victim_way == 2'(w)) begin
                                gs_valid_q[w] <= 1'b0;
                                gs_dirty_q[w] <= 1'b0;
                                gs_coh_q[w]   <= 2'(MESI_I);
                            end
                        end
                    end

                    if (clean_gs) begin
                        for (int w = 0; w < L1D_WAYS; w++) begin
                            if (clean_way_q == 2'(w)) begin
                                gs_dirty_q[w] <= 1'b0;
                                if (SMP_COHERENCE_EN) begin
                                    gs_valid_q[w] <= 1'b0;
                                    gs_coh_q[w]   <= 2'(MESI_I);
                                end
                            end
                        end
                    end

                    gs_lru_q <= nxt_lru_gs;
                end
            end
        end
    endgenerate

    // =========================================================================
    // Sequential State Management (Bank Data Arrays, Refill, Snoop, SC, Clean)
    // =========================================================================
`ifndef FURSOY_SYNTH_SRAM_BB
`ifndef SYNTHESIS
    initial begin
        for (int s = 0; s < L1D_SETS_PARAM; s++) begin
            for (int w = 0; w < L1D_WAYS; w++) begin
                for (int b = 0; b < 8; b++) begin
                    bank_data[b][s][w] = 64'd0;
                end
            end
        end
    end
`endif
`endif

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            bus_wr_inflight_q      <= 1'b0;
            bus_wr_inflight_slot_q <= '0;
            clean_state_q          <= CLEAN_IDLE;
            clean_set_q            <= 6'd0;
            clean_way_q            <= 2'd0;
            refill_busy_q          <= 1'b0;
            refill_tag_q           <= 2'd0;
            refill_data_q          <= 512'd0;
            refill_state_q         <= MESI_I;
            refill_has_data_q      <= 1'b0;
            snoop_s0_valid_q       <= 1'b0;
            snoop_s0_addr_q        <= 50'd0;
            snoop_s0_type_q        <= 2'd0;
            snoop_rsp_valid_q      <= 1'b0;
            snoop_rsp_addr_q       <= 50'd0;
            snoop_rsp_has_data_q   <= 1'b0;
            snoop_rsp_data_q       <= 512'd0;
            snoop_rsp_was_dirty_q  <= 1'b0;
            rsp_fifo_head_q        <= 2'd0;
            rsp_fifo_tail_q        <= 2'd0;
            rsp_fifo_count_q       <= 3'd0;
            p3_bank_stall_q        <= 1'b0;
            amo_line_lock_q        <= 1'b0;
            amo_lock_addr_q        <= 50'd0;
            sc_busy_q              <= 1'b0;
            sc_mshr_idx_q          <= 2'd0;
            sc_aborted_q           <= 1'b0;
            sc_pend_pa_q           <= 56'd0;
            sc_pend_mask_q         <= 8'd0;
            sc_pend_data_q         <= 64'd0;
        end else begin
            if (flush_valid_i) begin
                p3_bank_stall_q <= 1'b0;
                amo_line_lock_q <= 1'b0;
            end else begin
                p3_bank_stall_q <= load1_req_valid_i && bank_conflict_loads && l0_wins_bank;
            end
            if (SMP_COHERENCE_EN && sc_busy_q && !sc_res_valid_i) begin
                sc_aborted_q <= 1'b1;
            end

            if (bus_wr_inflight_q) begin
                if (bus_wr_rsp_valid_i) begin
                    bus_wr_inflight_q <= 1'b0;
                end
            end else if (bus_wr_req_valid_o && bus_wr_req_ready_i) begin
                if (bus_wr_rsp_valid_i) begin
                    bus_wr_inflight_q <= 1'b0;
                end else begin
                    bus_wr_inflight_q      <= 1'b1;
                    bus_wr_inflight_slot_q <= bus_wr_slot;
                end
            end

            if (SMP_COHERENCE_EN) begin
                if (snoop_s0_valid_q) begin
                    snoop_s0_valid_q      <= 1'b0;
                    snoop_rsp_valid_q     <= 1'b1;
                    snoop_rsp_addr_q      <= snoop_s0_addr_q;
                    snoop_rsp_has_data_q  <= snoop_s0_has_data;
                    snoop_rsp_data_q      <= snoop_s0_data;
                    snoop_rsp_was_dirty_q <= snoop_s0_was_dirty;
                end else if (snoop_rsp_valid_q && snoop_rsp_ready_i) begin
                    snoop_rsp_valid_q <= 1'b0;
                end

                if (snoop_req_valid_i && snoop_req_ready_o) begin
                    snoop_s0_valid_q <= 1'b1;
                    snoop_s0_addr_q  <= snoop_req_addr_i;
                    snoop_s0_type_q  <= snoop_req_type_i;
                end
            end

            if (!refill_busy_q) begin
                if (SMP_COHERENCE_EN && snoop_s0_valid_q) begin
                    if (refill_arriving) begin
                        rsp_fifo_q[rsp_fifo_tail_q] <= '{
                            tag:      bus_rd_rsp_tag_i,
                            data:     bus_rd_rsp_data_i,
                            state:    eff_rsp_state,
                            has_data: eff_rsp_has_data
                        };
                        rsp_fifo_tail_q  <= rsp_fifo_tail_q + 2'd1;
                        rsp_fifo_count_q <= rsp_fifo_count_q + 3'd1;
                    end
                end else if (rsp_fifo_count_q != 3'd0) begin
`ifndef FURSOY_SYNTH_SRAM_BB
                    logic [5:0] set_i;
                    logic [1:0] rep_way;
                    set_i   = mshr_q[beat0_m_idx].line_addr[5:0];
                    rep_way = mshr_q[beat0_m_idx].victim_way;

                    if (!SMP_COHERENCE_EN || beat0_has_data) begin
                        bank_data[0][set_i[L1D_SET_W-1:0]][rep_way] <= beat0_data[63:0];
                        bank_data[1][set_i[L1D_SET_W-1:0]][rep_way] <= beat0_data[127:64];
                        bank_data[2][set_i[L1D_SET_W-1:0]][rep_way] <= beat0_data[191:128];
                        bank_data[3][set_i[L1D_SET_W-1:0]][rep_way] <= beat0_data[255:192];
                    end
`endif
                    refill_busy_q     <= 1'b1;
                    refill_tag_q      <= beat0_m_idx;
                    refill_data_q     <= beat0_data;
                    refill_state_q    <= rsp_fifo_q[rsp_fifo_head_q].state;
                    refill_has_data_q <= beat0_has_data;
                    rsp_fifo_head_q   <= rsp_fifo_head_q + 2'd1;

                    if (refill_arriving) begin
                        rsp_fifo_q[rsp_fifo_tail_q] <= '{
                            tag:      bus_rd_rsp_tag_i,
                            data:     bus_rd_rsp_data_i,
                            state:    eff_rsp_state,
                            has_data: eff_rsp_has_data
                        };
                        rsp_fifo_tail_q <= rsp_fifo_tail_q + 2'd1;
                    end else begin
                        rsp_fifo_count_q <= rsp_fifo_count_q - 3'd1;
                    end
                end else if (refill_arriving) begin
`ifndef FURSOY_SYNTH_SRAM_BB
                    logic [5:0] set_i;
                    logic [1:0] rep_way;
                    set_i   = mshr_q[beat0_m_idx].line_addr[5:0];
                    rep_way = mshr_q[beat0_m_idx].victim_way;

                    if (!SMP_COHERENCE_EN || eff_rsp_has_data) begin
                        bank_data[0][set_i[L1D_SET_W-1:0]][rep_way] <= bus_rd_rsp_data_i[63:0];
                        bank_data[1][set_i[L1D_SET_W-1:0]][rep_way] <= bus_rd_rsp_data_i[127:64];
                        bank_data[2][set_i[L1D_SET_W-1:0]][rep_way] <= bus_rd_rsp_data_i[191:128];
                        bank_data[3][set_i[L1D_SET_W-1:0]][rep_way] <= bus_rd_rsp_data_i[255:192];
                    end
`endif
                    refill_busy_q     <= 1'b1;
                    refill_tag_q      <= beat0_m_idx;
                    refill_data_q     <= bus_rd_rsp_data_i;
                    refill_state_q    <= eff_rsp_state;
                    refill_has_data_q <= eff_rsp_has_data;
                end
            end else begin
`ifndef FURSOY_SYNTH_SRAM_BB
                logic [5:0]  set_i;
                logic [1:0]  rep_way;
                set_i   = beat1_set_i;
                rep_way = mshr_q[refill_tag_q].victim_way;
`endif
                refill_busy_q <= 1'b0;

                if (!beat1_reissue) begin
                    if (SMP_COHERENCE_EN && !refill_has_data_q) begin
                        if (mshr_q[refill_tag_q].is_sc && sc_busy_q && (refill_tag_q == sc_mshr_idx_q)) begin
                            sc_busy_q    <= 1'b0;
                            sc_aborted_q <= 1'b0;
                            if (sc_beat1_win) begin
`ifndef FURSOY_SYNTH_SRAM_BB
                                logic [1:0] upg_way;
                                logic [63:0] sc_old_dw;
                                upg_way = mshr_q[refill_tag_q].upgrade_way;
                                sc_old_dw = bank_data[sc_pend_pa_q[5:3]][set_i[L1D_SET_W-1:0]][upg_way];
                                for (int b = 0; b < 8; b++) begin
                                    if (sc_pend_mask_q[b]) sc_old_dw[b*8 +: 8] = sc_pend_data_q[b*8 +: 8];
                                end
                                bank_data[sc_pend_pa_q[5:3]][set_i[L1D_SET_W-1:0]][upg_way] <= sc_old_dw;
`endif
                            end
                        end else begin
                            if (mshr_q[refill_tag_q].is_amo && !flush_valid_i && (mshr_q[refill_tag_q].waiter_mask != 16'd0)) begin
                                amo_line_lock_q <= 1'b1;
                                amo_lock_addr_q <= mshr_q[refill_tag_q].line_addr;
                            end
                        end
                    end else begin
`ifndef FURSOY_SYNTH_SRAM_BB
                        if (SMP_COHERENCE_EN && sc_beat1_win && !sc_pend_pa_q[5]) begin
                            logic [63:0] sc_lo_dw;
                            sc_lo_dw = bank_data[sc_pend_pa_q[5:3]][set_i[L1D_SET_W-1:0]][rep_way];
                            for (int b = 0; b < 8; b++) begin
                                if (sc_pend_mask_q[b]) sc_lo_dw[b*8 +: 8] = sc_pend_data_q[b*8 +: 8];
                            end
                            bank_data[sc_pend_pa_q[5:3]][set_i[L1D_SET_W-1:0]][rep_way] <= sc_lo_dw;
                        end
                        bank_data[4][set_i[L1D_SET_W-1:0]][rep_way] <= (SMP_COHERENCE_EN && sc_beat1_win && (sc_pend_pa_q[5:3] == 3'd4)) ?
                            merge_word(refill_data_q[319:256], sc_pend_mask_q, sc_pend_data_q) : refill_data_q[319:256];
                        bank_data[5][set_i[L1D_SET_W-1:0]][rep_way] <= (SMP_COHERENCE_EN && sc_beat1_win && (sc_pend_pa_q[5:3] == 3'd5)) ?
                            merge_word(refill_data_q[383:320], sc_pend_mask_q, sc_pend_data_q) : refill_data_q[383:320];
                        bank_data[6][set_i[L1D_SET_W-1:0]][rep_way] <= (SMP_COHERENCE_EN && sc_beat1_win && (sc_pend_pa_q[5:3] == 3'd6)) ?
                            merge_word(refill_data_q[447:384], sc_pend_mask_q, sc_pend_data_q) : refill_data_q[447:384];
                        bank_data[7][set_i[L1D_SET_W-1:0]][rep_way] <= (SMP_COHERENCE_EN && sc_beat1_win && (sc_pend_pa_q[5:3] == 3'd7)) ?
                            merge_word(refill_data_q[511:448], sc_pend_mask_q, sc_pend_data_q) : refill_data_q[511:448];
`endif
                        if (SMP_COHERENCE_EN && mshr_q[refill_tag_q].is_sc && sc_busy_q && (refill_tag_q == sc_mshr_idx_q)) begin
                            sc_busy_q    <= 1'b0;
                            sc_aborted_q <= 1'b0;
                        end
                        if (SMP_COHERENCE_EN && mshr_q[refill_tag_q].is_amo && !flush_valid_i &&
                            (mshr_q[refill_tag_q].waiter_mask != 16'd0)) begin
                            amo_line_lock_q <= 1'b1;
                            amo_lock_addr_q <= mshr_q[refill_tag_q].line_addr;
                        end
                    end
                end

                if (refill_arriving) begin
                    rsp_fifo_q[rsp_fifo_tail_q] <= '{
                        tag:      bus_rd_rsp_tag_i,
                        data:     bus_rd_rsp_data_i,
                        state:    eff_rsp_state,
                        has_data: eff_rsp_has_data
                    };
                    rsp_fifo_tail_q  <= rsp_fifo_tail_q + 2'd1;
                    rsp_fifo_count_q <= rsp_fifo_count_q + 3'd1;
                end
            end

            if (store_can_drain) begin
                if (store_cache_writable) begin
`ifndef FURSOY_SYNTH_SRAM_BB
                    bank_data[store_bank][store_set[L1D_SET_W-1:0]][store_cache_hit_way] <= merge_word(
                        bank_data[store_bank][store_set[L1D_SET_W-1:0]][store_cache_hit_way],
                        store_drain_mask_i,
                        store_drain_data_i
                    );
`endif
                    if (SMP_COHERENCE_EN && amo_line_lock_q && (store_line == amo_lock_addr_q)) begin
                        amo_line_lock_q <= 1'b0;
                    end
                end
            end else if (sc_case_a_fire) begin
`ifndef FURSOY_SYNTH_SRAM_BB
                bank_data[sc_bank][sc_set[L1D_SET_W-1:0]][sc_cache_hit_way] <= merge_word(
                    bank_data[sc_bank][sc_set[L1D_SET_W-1:0]][sc_cache_hit_way],
                    sc_acquire_mask_i,
                    sc_acquire_data_i
                );
`endif
            end else if (sc_alloc_fire) begin
                sc_busy_q      <= 1'b1;
                sc_mshr_idx_q  <= mshr_free_slot;
                sc_aborted_q   <= 1'b0;
                sc_pend_pa_q   <= sc_acquire_pa_i;
                sc_pend_mask_q <= sc_acquire_mask_i;
                sc_pend_data_q <= sc_acquire_data_i;
            end

            if (load0_accept && load0_cache_hit && SMP_COHERENCE_EN && load0_req_is_amo_i) begin
                amo_line_lock_q <= 1'b1;
                amo_lock_addr_q <= load0_line;
            end

            case (clean_state_q)
                CLEAN_IDLE: begin
                    if (dcache_clean_all_req_i) begin
                        clean_state_q <= SMP_COHERENCE_EN ? CLEAN_DRAIN : CLEAN_SWEEP;
                        clean_set_q   <= 6'd0;
                        clean_way_q   <= 2'd0;
                    end
                end

                CLEAN_SWEEP: begin
                    if (SMP_COHERENCE_EN && snoop_s0_valid_q) begin
                    end else if (clean_meta.valid[clean_way_q] &&
                                 clean_meta.dirty[clean_way_q]) begin
                        if (wbb_avail_count > 0) begin
                            if (clean_way_q == 2'd3) begin
                                clean_way_q <= 2'd0;
                                if (clean_set_q == 6'(L1D_SETS_PARAM - 1)) begin
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
                            if (clean_set_q == 6'(L1D_SETS_PARAM - 1)) begin
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
                    if ((wbb_free_count == 2'd2) && !bus_wr_inflight_q && (mshr_free_count == 3'd4) &&
                        !refill_busy_q && (rsp_fifo_count_q == 3'd0)) begin
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
            if (load0_req_valid_i && load0_can_alloc_mshr && !load0_amo_needs_upgrade && load0_victim_is_dirty && (wbb_avail_count == 0) && load0_accept) begin
                $fatal(1, "[L1D ASSERTION FAILED] WBB load0 allocation overflowed!");
            end
            if (load1_req_valid_i && load1_can_alloc_mshr && load1_victim_is_dirty && (wbb_avail_count == 0) && load1_accept) begin
                $fatal(1, "[L1D ASSERTION FAILED] WBB load1 allocation overflowed!");
            end
            // Assertion: WBB must never overflow on store miss allocation
            if (store_drain_valid_i && store_can_alloc_miss && !store_cache_needs_upgrade && store_victim_is_dirty && (wbb_avail_count == 0) && store_can_drain) begin
                $fatal(1, "[L1D ASSERTION FAILED] WBB store allocation overflowed!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_L1D_SV
