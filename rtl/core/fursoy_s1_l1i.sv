`ifndef FURSOY_S1_L1I_SV
`define FURSOY_S1_L1I_SV

// =============================================================================
// Fursoy Slice-1 Non-Blocking Level-1 Instruction Cache (L1I) — Milestone 6 Phase C
// =============================================================================
// Features:
// - 16 KiB 4-Way Set-Associative (64 Sets, 4 Ways, 64-Byte Lines, VIPT-Safe).
// - Tree Pseudo-LRU Replacement Policy per Set.
// - Conservative VIPT-Safe Next-Line Instruction Prefetcher (L1I NLP):
//   * Dual Instruction MSHRs (IMSHR_DEPTH = 2: MSHR0 and MSHR1).
//   * MSHR0 is strictly reserved for authoritative demand instruction misses.
//   * MSHR1 is utilized for speculative next-line prefetching (Line_N+1 = Line_demand + 1).
// - Gating Invariants:
//   1. MSHR1 is completely idle (!imshr_q[1].valid);
//   2. MSHR0 is either idle or has already completed its request handshake;
//   3. Fetch Queue capacity is available (fq_free_count >= 2);
//   4. Strict Same-Page Invariant: demand_paddr[11:6] != 6'b111111 (line 63 silent abort);
//   5. Candidate line must miss in L1I tag directory (!tag_hit) before emitting bus read.
// - Demand Collision & Promotion Invariant (§7.2, Rule P2-5):
//   * Demand fetch matching in-flight MSHR1 promotes MSHR1 to demand without duplicate bus read.
//   * Forwards returning DRAM burst data directly to Stage F3 / Fetch Queue upon arrival.
// - Pipeline Redirect & Flush Safety (§7.2):
//   * Redirect flush marks in-flight prefetch as dead refill (suppresses F3 push; installs to L1I).
//   * FENCE.I immediately purges all I-MSHR tracking and flash-invalidates L1I tags.
//   * SFENCE.VMA / satp CSR writes invalidate active prefetch tracking cleanly.
//   * Shared PTW walk requests take strict priority over prefetch bus requests.
// Reference: docs/architecture/slice1-m6-frontend-opt-v1.md Section 7 & Section 10
// =============================================================================

`include "fursoy_s1_pkg.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_l1i
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // -------------------------------------------------------------------------
    // Stage F1 Request Interface (from GenPC & ITLB)
    // -------------------------------------------------------------------------
    input  logic              f1_req_valid_i,
    input  logic [63:0]       f1_req_pc_i,          // 64-bit fetch PC
    input  logic [55:0]       f1_req_pa_i,          // Translated physical address
    input  logic              f1_req_page_fault_i,  // Translation exception
    input  logic              f1_req_access_fault_i,// PMP access fault
    output logic              l1i_ready_o,          // Ready to accept F1 request

    // Downstream Backpressure & Flush Controls
    input  logic              stall_f3_i,           // Downstream Fetch Queue backpressure
    input  logic              redirect_flush_i,     // Pipeline flush / redirect pulse
    input  logic              l1i_inval_all_i,      // FENCE.I flash tag invalidation
    input  logic              sfence_vma_i,         // SFENCE.VMA or satp write address translation purge
    input  logic [4:0]        fq_free_count_i,      // Downstream Fetch Queue free slot count
    input  logic              ptw_req_active_i,     // Shared PTW memory activity priority

    // -------------------------------------------------------------------------
    // Stage F3 Delivery Interface (to Instruction Alignment Stage)
    // -------------------------------------------------------------------------
    output logic              f3_valid_o,
    output logic [63:0]       f3_pc_o,
    output logic [63:0]       f3_data_o,            // 64-bit fetch block (two 32-bit instructions)
    output logic              f3_exception_valid_o,
    output logic [4:0]        f3_exception_cause_o,
    output logic [63:0]       f3_fault_addr_o,

    // Pipeline Freeze Output to F0/F1
    output logic              f2_stall_f0_o,
    output logic              f2_stall_f1_o,

    // -------------------------------------------------------------------------
    // External Memory Refill Bus (Coherent Interconnect Interface)
    // -------------------------------------------------------------------------
    output logic              bus_rd_req_valid_o,
    output logic [49:0]       bus_rd_req_addr_o,    // PA[55:6]
    output logic [1:0]        bus_rd_req_tag_o,     // I-MSHR ID (0 or 1)
    input  logic              bus_rd_req_ready_i,

    input  logic              bus_rd_rsp_valid_i,
    input  logic [1:0]        bus_rd_rsp_tag_i,
    input  logic [511:0]      bus_rd_rsp_data_i,
    input  logic              bus_rd_rsp_error_i,

    // -------------------------------------------------------------------------
    // Observability & Diagnostics
    // -------------------------------------------------------------------------
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

    // =========================================================================
    // 1. Cache Storage Arrays (16 KiB 4-Way: 64 Sets, 4 Ways, 64-Byte Line)
    // =========================================================================
    // Physical Tag: PA[55:12] (44 bits)
    // Set Index:   PA[11:6]  (6 bits)
    // Line Offset: PA[5:0]   (6 bits)
    logic [43:0]  tag_array   [L1I_SETS][L1I_WAYS];
    logic         valid_array [L1I_SETS][L1I_WAYS];
    logic [511:0] data_array  [L1I_SETS][L1I_WAYS];
    logic [L1I_SETS-1:0][2:0] plru_array;

    // -------------------------------------------------------------------------
    // 3-bit Tree-PLRU Helper Functions
    // -------------------------------------------------------------------------
    function automatic logic [1:0] plru_victim(input logic [2:0] plru, input logic [3:0] valids);
        for (int w = 0; w < 4; w++) begin
            if (!valids[w]) return 2'(w);
        end
        if (!plru[0]) return plru[1] ? 2'd1 : 2'd0;
        else          return plru[2] ? 2'd3 : 2'd2;
    endfunction

    function automatic logic [2:0] plru_update(input logic [2:0] plru, input logic [1:0] way);
        logic [2:0] next_plru;
        next_plru = plru;
        case (way)
            2'd0: begin next_plru[0] = 1'b1; next_plru[1] = 1'b1; end
            2'd1: begin next_plru[0] = 1'b1; next_plru[1] = 1'b0; end
            2'd2: begin next_plru[0] = 1'b0; next_plru[2] = 1'b1; end
            2'd3: begin next_plru[0] = 1'b0; next_plru[2] = 1'b0; end
        endcase
        return next_plru;
    endfunction

    // F1 Pipeline Registers (F1 -> F2 synchronous lookup)
    logic        f2_valid_q;
    logic [63:0] f2_pc_q;
    logic [55:0] f2_pa_q;
    logic        f2_page_fault_q;
    logic        f2_access_fault_q;

    wire [5:0]  f2_set       = f2_pa_q[11:6];
    wire [43:0] f2_tag       = f2_pa_q[55:12];
    wire [2:0]  f2_word_idx  = f2_pa_q[5:3]; // 64-bit word index within 512-bit cache line
    wire [49:0] f2_line_addr = f2_pa_q[55:6];

    // Tag comparison across all 4 ways for Stage F2 access
    logic [L1I_WAYS-1:0] way_hit;
    always_comb begin
        for (int w = 0; w < L1I_WAYS; w++) begin
            way_hit[w] = valid_array[f2_set][w] && (tag_array[f2_set][w] == f2_tag);
        end
    end

    wire cache_hit = |way_hit;
    logic [1:0] hit_way;
    always_comb begin
        hit_way = 2'd0;
        for (int w = 0; w < L1I_WAYS; w++) begin
            if (way_hit[w]) hit_way = 2'(w);
        end
    end

    // Extract 64-bit instruction block from 512-bit cache line
    function automatic logic [63:0] extract_fetch_block(
        input logic [511:0] line_data,
        input logic [2:0]   word_idx
    );
        return line_data[word_idx*64 +: 64];
    endfunction

    wire [63:0] hit_data = extract_fetch_block(data_array[f2_set][hit_way], f2_word_idx);

    // =========================================================================
    // 2. Dual Instruction MSHRs (2 Entries) & NLP Arbitration — Section 7.2
    // =========================================================================
    typedef struct packed {
        logic        valid;
        logic [49:0] line_addr;     // PA[55:6]
        logic        waiter_valid;  // Cleared on redirect/flush
        logic [63:0] orig_pc;
        logic [2:0]  word_idx;
        logic [5:0]  set_idx;
        logic [43:0] tag;
        logic        req_sent;      // Bus request was granted/sent
        logic        is_prefetch;   // Speculative NLP prefetch
        logic        suppress_push; // Suppress pipeline delivery to Stage F3
    } imshr_entry_t;

    imshr_entry_t imshr_q [IMSHR_DEPTH];

    assign imshr_occ_o = (imshr_q[0].valid ? 2'd1 : 2'd0) + (imshr_q[1].valid ? 2'd1 : 2'd0);

    // Matching in-flight I-MSHR evaluation for Stage F2 access
    wire mshr0_match = imshr_q[0].valid && (imshr_q[0].line_addr == f2_line_addr);
    wire mshr1_match = imshr_q[1].valid && (imshr_q[1].line_addr == f2_line_addr);

    wire f2_miss = f2_valid_q && !cache_hit && !f2_page_fault_q && !f2_access_fault_q;
    wire mshr1_collision = f2_miss && mshr1_match;

    // -------------------------------------------------------------------------
    // Next-Line Prefetch Candidate Evaluation (§7.1, §7.2, §7.3)
    // -------------------------------------------------------------------------
    // Base line address for next-line prefetch: either in-flight MSHR0 demand miss or active F2 demand access
    wire [49:0] nlp_base_line_addr = (imshr_q[0].valid && imshr_q[0].req_sent) ? imshr_q[0].line_addr : f2_line_addr;
    wire        nlp_trigger_valid  = (imshr_q[0].valid && imshr_q[0].req_sent) || (f2_valid_q && !f2_page_fault_q && !f2_access_fault_q);

    // Strict same-page boundary: line 63 of 4 KiB page aborts silently (§7.3)
    wire nlp_page_boundary_abort = (nlp_base_line_addr[5:0] == 6'b111111);

    wire [49:0] cand_line_addr = nlp_base_line_addr + 50'd1;
    wire [5:0]  cand_set       = cand_line_addr[5:0];
    wire [43:0] cand_tag       = cand_line_addr[49:6]; // Same tag within same page!

    // Check candidate residency in L1I tag array
    logic cand_tag_hit;
    always_comb begin
        cand_tag_hit = 1'b0;
        for (int w = 0; w < L1I_WAYS; w++) begin
            if (valid_array[cand_set][w] && (tag_array[cand_set][w] == cand_tag)) begin
                cand_tag_hit = 1'b1;
            end
        end
    end

    wire cand_mshr0_match = imshr_q[0].valid && (imshr_q[0].line_addr == cand_line_addr);
    wire cand_mshr1_match = imshr_q[1].valid && (imshr_q[1].line_addr == cand_line_addr);
    wire cand_already_resident = cand_tag_hit || cand_mshr0_match || cand_mshr1_match;

    // Gating conditions for MSHR1 prefetch allocation (§7.2)
    wire mshr0_idle_or_sent = !imshr_q[0].valid || imshr_q[0].req_sent;

    // Bus request triggers
    wire mshr0_fresh_req = !redirect_flush_i && f2_miss && !mshr0_match && !mshr1_match && !imshr_q[0].valid;
    wire mshr0_retry_req = !redirect_flush_i && imshr_q[0].valid && !imshr_q[0].req_sent;

    wire nlp_alloc_eligible = nlp_trigger_valid &&
                              !nlp_page_boundary_abort && !cand_already_resident &&
                              !imshr_q[1].valid && mshr0_idle_or_sent &&
                              (fq_free_count_i >= 5'd2) &&
                              !redirect_flush_i && !l1i_inval_all_i && !sfence_vma_i &&
                              !ptw_req_active_i &&
                              !mshr0_fresh_req;

    wire mshr1_retry_req = !redirect_flush_i && !sfence_vma_i && imshr_q[1].valid && !imshr_q[1].req_sent && !ptw_req_active_i && !mshr0_fresh_req && !mshr0_retry_req;
    wire mshr1_fresh_req = !redirect_flush_i && !sfence_vma_i && nlp_alloc_eligible;

    // -------------------------------------------------------------------------
    // External Bus Read Request Arbitration (Strict Demand Prioritization)
    // -------------------------------------------------------------------------
    logic        bus_req_valid;
    logic [49:0] bus_req_addr;
    logic [1:0]  bus_req_tag;

    always_comb begin
        bus_req_valid = 1'b0;
        bus_req_addr  = '0;
        bus_req_tag   = 2'd0;

        if (mshr0_fresh_req) begin
            bus_req_valid = 1'b1;
            bus_req_addr  = f2_line_addr;
            bus_req_tag   = 2'd0;
        end else if (mshr0_retry_req) begin
            bus_req_valid = 1'b1;
            bus_req_addr  = imshr_q[0].line_addr;
            bus_req_tag   = 2'd0;
        end else if (mshr1_retry_req) begin
            bus_req_valid = 1'b1;
            bus_req_addr  = imshr_q[1].line_addr;
            bus_req_tag   = 2'd1;
        end else if (mshr1_fresh_req) begin
            bus_req_valid = 1'b1;
            bus_req_addr  = cand_line_addr;
            bus_req_tag   = 2'd1;
        end
    end

    assign bus_rd_req_valid_o = bus_req_valid;
    assign bus_rd_req_addr_o  = bus_req_addr;
    assign bus_rd_req_tag_o   = bus_req_tag;

    // -------------------------------------------------------------------------
    // Pipeline Stall & Hold Generation
    // -------------------------------------------------------------------------
    wire secondary_miss_stall = f2_miss && (mshr0_match || mshr1_match);
    wire mshr_exhausted_stall = f2_miss && !mshr0_match && !mshr1_match && imshr_q[0].valid;
    wire bus_not_ready_stall  = mshr0_fresh_req && !bus_rd_req_ready_i;
    wire f2_stall_condition   = secondary_miss_stall || mshr_exhausted_stall || bus_not_ready_stall;

    // =========================================================================
    // 3. Stage F2 Synchronous Skid Buffer (Section 3.2 & 17)
    // =========================================================================
    typedef struct packed {
        logic        valid;
        logic [63:0] pc;
        logic [63:0] data;
        logic        exception_valid;
        logic [4:0]  exception_cause;
        logic [63:0] fault_addr;
    } skid_entry_t;

    skid_entry_t f2_skid_q;
    assign diag_f2_skid_valid_o = f2_skid_q.valid;

    wire f2_hold           = f2_skid_q.valid || f2_stall_condition;
    wire f2_stall_upstream = f2_skid_q.valid || stall_f3_i || f2_stall_condition;
    assign f2_stall_f0_o   = f2_stall_upstream;
    assign f2_stall_f1_o   = f2_stall_upstream;

    assign l1i_ready_o     = !f2_stall_upstream;

    // Delivery Candidate: either from F2 Skid Buffer, from F2 cache hit, or from arriving refill
    logic        emerging_valid;
    logic [63:0] emerging_pc;
    logic [63:0] emerging_data;
    logic        emerging_exc_valid;
    logic [4:0]  emerging_exc_cause;
    logic [63:0] emerging_fault_addr;

    always_comb begin
        emerging_valid      = 1'b0;
        emerging_pc         = '0;
        emerging_data       = '0;
        emerging_exc_valid  = 1'b0;
        emerging_exc_cause  = 5'd0;
        emerging_fault_addr = '0;

        if (f2_valid_q) begin
            if (f2_page_fault_q) begin
                // Instruction Page Fault (Cause 12)
                emerging_valid      = 1'b1;
                emerging_pc         = f2_pc_q;
                emerging_data       = 64'd0;
                emerging_exc_valid  = 1'b1;
                emerging_exc_cause  = 5'd12;
                emerging_fault_addr = f2_pc_q;
            end else if (f2_access_fault_q) begin
                // Instruction Access Fault (Cause 1)
                emerging_valid      = 1'b1;
                emerging_pc         = f2_pc_q;
                emerging_data       = 64'd0;
                emerging_exc_valid  = 1'b1;
                emerging_exc_cause  = 5'd1;
                emerging_fault_addr = f2_pc_q;
            end else if (cache_hit) begin
                // Cache hit
                emerging_valid      = 1'b1;
                emerging_pc         = f2_pc_q;
                emerging_data       = hit_data;
                emerging_exc_valid  = 1'b0;
                emerging_exc_cause  = 5'd0;
                emerging_fault_addr = 64'd0;
            end
        end

        // Check if arriving refill has live waiter or matches demand collision
        if (bus_rd_rsp_valid_i && imshr_q[bus_rd_rsp_tag_i[0]].valid) begin
            if (bus_rd_rsp_tag_i[0] == 1'b0) begin
                if (imshr_q[0].waiter_valid) begin
                    emerging_valid      = 1'b1;
                    emerging_pc         = imshr_q[0].orig_pc;
                    emerging_data       = extract_fetch_block(bus_rd_rsp_data_i, imshr_q[0].word_idx);
                    emerging_exc_valid  = bus_rd_rsp_error_i;
                    emerging_exc_cause  = bus_rd_rsp_error_i ? 5'd1 : 5'd0;
                    emerging_fault_addr = imshr_q[0].orig_pc;
                end
            end else begin
                // MSHR1: delivers if waiter_valid is set (promoted) OR collision occurs on same cycle
                if ((imshr_q[1].waiter_valid && !imshr_q[1].suppress_push) || mshr1_collision) begin
                    emerging_valid      = 1'b1;
                    emerging_pc         = imshr_q[1].waiter_valid ? imshr_q[1].orig_pc : f2_pc_q;
                    emerging_data       = extract_fetch_block(bus_rd_rsp_data_i, imshr_q[1].waiter_valid ? imshr_q[1].word_idx : f2_word_idx);
                    emerging_exc_valid  = (!imshr_q[1].is_prefetch || mshr1_collision) ? bus_rd_rsp_error_i : 1'b0;
                    emerging_exc_cause  = emerging_exc_valid ? 5'd1 : 5'd0;
                    emerging_fault_addr = emerging_pc;
                end
            end
        end
    end

    // Multiplex F3 Outputs (Skid buffer has priority!)
    always_comb begin
        if (f2_skid_q.valid) begin
            f3_valid_o           = 1'b1;
            f3_pc_o              = f2_skid_q.pc;
            f3_data_o            = f2_skid_q.data;
            f3_exception_valid_o = f2_skid_q.exception_valid;
            f3_exception_cause_o = f2_skid_q.exception_cause;
            f3_fault_addr_o      = f2_skid_q.fault_addr;
        end else begin
            f3_valid_o           = emerging_valid;
            f3_pc_o              = emerging_pc;
            f3_data_o            = emerging_data;
            f3_exception_valid_o = emerging_exc_valid;
            f3_exception_cause_o = emerging_exc_cause;
            f3_fault_addr_o      = emerging_fault_addr;
        end
    end

    // Observability & Diagnostics
    assign event_l1i_hit_o          = f2_valid_q && !f2_page_fault_q && !f2_access_fault_q && cache_hit;
    assign event_l1i_miss_o         = f2_valid_q && !f2_page_fault_q && !f2_access_fault_q && !cache_hit;
    assign diag_nlp_alloc_o         = mshr1_fresh_req;
    assign diag_nlp_hit_o           = event_l1i_hit_o;
    assign diag_nlp_promote_o       = mshr1_collision && imshr_q[1].is_prefetch;
    assign diag_nlp_abort_page_o    = nlp_trigger_valid && nlp_page_boundary_abort && !imshr_q[1].valid;
    assign diag_nlp_drop_resident_o = nlp_trigger_valid && !nlp_page_boundary_abort && cand_already_resident && !imshr_q[1].valid;

    // =========================================================================
    // 4. Sequential State Management (Arrays, MSHRs, Skid Buffer)
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            f2_valid_q        <= 1'b0;
            f2_pc_q           <= '0;
            f2_pa_q           <= '0;
            f2_page_fault_q   <= 1'b0;
            f2_access_fault_q <= 1'b0;
            f2_skid_q         <= '0;
            plru_array        <= '0;

            for (int s = 0; s < L1I_SETS; s++) begin
                for (int w = 0; w < L1I_WAYS; w++) begin
                    valid_array[s][w] <= 1'b0;
                    tag_array[s][w]   <= '0;
                    data_array[s][w]  <= '0;
                end
            end

            for (int i = 0; i < IMSHR_DEPTH; i++) begin
                imshr_q[i] <= '0;
            end
        end else begin
            // -----------------------------------------------------------------
            // A. FENCE.I Flash Invalidation & SFENCE.VMA Translation Purge
            // -----------------------------------------------------------------
            if (l1i_inval_all_i) begin
                for (int s = 0; s < L1I_SETS; s++) begin
                    for (int w = 0; w < L1I_WAYS; w++) begin
                        valid_array[s][w] <= 1'b0;
                    end
                end
                imshr_q[0].valid <= 1'b0;
                imshr_q[1].valid <= 1'b0;
            end else begin
                if (sfence_vma_i) begin
                    // SFENCE.VMA purges active speculative prefetch tracking (§7.4)
                    if (imshr_q[1].valid && imshr_q[1].is_prefetch) begin
                        imshr_q[1].valid <= 1'b0;
                    end
                end
                if (redirect_flush_i) begin
                    imshr_q[0].waiter_valid  <= 1'b0;
                    imshr_q[1].waiter_valid  <= 1'b0;
                    imshr_q[1].suppress_push <= 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // B. Skid Buffer Operation & Backpressure Management
            // -----------------------------------------------------------------
            if (redirect_flush_i) begin
                f2_skid_q  <= '0;
                f2_valid_q <= 1'b0;
            end else begin
                // If refill arrives on the same cycle as an F2 hit, capture hit in skid buffer
                if (bus_rd_rsp_valid_i && imshr_q[bus_rd_rsp_tag_i[0]].valid &&
                    (imshr_q[bus_rd_rsp_tag_i[0]].waiter_valid || (bus_rd_rsp_tag_i[0] == 1'b1 && mshr1_collision)) &&
                    f2_valid_q && cache_hit && !f2_skid_q.valid) begin
                    f2_skid_q.valid           <= 1'b1;
                    f2_skid_q.pc              <= f2_pc_q;
                    f2_skid_q.data            <= hit_data;
                    f2_skid_q.exception_valid <= 1'b0;
                    f2_skid_q.exception_cause <= 5'd0;
                    f2_skid_q.fault_addr      <= 64'd0;
                end else if (stall_f3_i) begin
                    if (emerging_valid && !f2_skid_q.valid) begin
                        f2_skid_q.valid           <= 1'b1;
                        f2_skid_q.pc              <= emerging_pc;
                        f2_skid_q.data            <= emerging_data;
                        f2_skid_q.exception_valid <= emerging_exc_valid;
                        f2_skid_q.exception_cause <= emerging_exc_cause;
                        f2_skid_q.fault_addr      <= emerging_fault_addr;
                    end
                end else begin
                    if (f2_skid_q.valid) begin
                        f2_skid_q <= '0;
                    end
                end
            end

            // -----------------------------------------------------------------
            // C. F1 -> F2 Pipeline Register Advance
            // -----------------------------------------------------------------
            if (redirect_flush_i) begin
                f2_valid_q <= 1'b0;
            end else if (!f2_hold) begin
                f2_valid_q        <= f1_req_valid_i;
                f2_pc_q           <= f1_req_pc_i;
                f2_pa_q           <= f1_req_pa_i;
                f2_page_fault_q   <= f1_req_page_fault_i;
                f2_access_fault_q <= f1_req_access_fault_i;
            end

            // -----------------------------------------------------------------
            // D. MSHR0 Allocation & Request Handshake (Demand Miss)
            // -----------------------------------------------------------------
            if (mshr0_fresh_req) begin
                imshr_q[0].valid         <= 1'b1;
                imshr_q[0].line_addr     <= f2_line_addr;
                imshr_q[0].waiter_valid  <= 1'b1;
                imshr_q[0].orig_pc       <= f2_pc_q;
                imshr_q[0].word_idx      <= f2_word_idx;
                imshr_q[0].set_idx       <= f2_set;
                imshr_q[0].tag           <= f2_tag;
                imshr_q[0].req_sent      <= bus_rd_req_ready_i;
                imshr_q[0].is_prefetch   <= 1'b0;
                imshr_q[0].suppress_push <= 1'b0;
            end else if (mshr0_retry_req && bus_rd_req_ready_i) begin
                imshr_q[0].req_sent      <= 1'b1;
            end

            // -----------------------------------------------------------------
            // E. MSHR1 Allocation, Handshake, & Demand Promotion (NLP Prefetch)
            // -----------------------------------------------------------------
            if (mshr1_collision && imshr_q[1].is_prefetch) begin
                // Demand Miss Collision: promote speculative prefetch to demand status (§7.2, Rule P2-5)
                imshr_q[1].is_prefetch   <= 1'b0;
                imshr_q[1].suppress_push <= 1'b0;
                imshr_q[1].waiter_valid  <= 1'b1;
                imshr_q[1].orig_pc       <= f2_pc_q;
                imshr_q[1].word_idx      <= f2_word_idx;
            end else if (mshr1_fresh_req) begin
                imshr_q[1].valid         <= 1'b1;
                imshr_q[1].line_addr     <= cand_line_addr;
                imshr_q[1].waiter_valid  <= 1'b0;
                imshr_q[1].orig_pc       <= 64'd0;
                imshr_q[1].word_idx      <= 3'd0;
                imshr_q[1].set_idx       <= cand_set;
                imshr_q[1].tag           <= cand_tag;
                imshr_q[1].req_sent      <= bus_rd_req_ready_i;
                imshr_q[1].is_prefetch   <= 1'b1;
                imshr_q[1].suppress_push <= 1'b1;
            end else if (mshr1_retry_req && bus_rd_req_ready_i) begin
                imshr_q[1].req_sent      <= 1'b1;
            end

            // -----------------------------------------------------------------
            // F. Handle Memory Refill Arrival
            // -----------------------------------------------------------------
            if (bus_rd_rsp_valid_i && imshr_q[bus_rd_rsp_tag_i[0]].valid) begin
                imshr_q[bus_rd_rsp_tag_i[0]].valid <= 1'b0; // Deallocate MSHR

                if (!bus_rd_rsp_error_i) begin
                    // Install line into L1I Cache Array using 3-bit Tree-PLRU
                    logic [1:0] victim_way;
                    logic [3:0] valids;
                    for (int w = 0; w < L1I_WAYS; w++) begin
                        valids[w] = valid_array[imshr_q[bus_rd_rsp_tag_i[0]].set_idx][w];
                    end
                    victim_way = plru_victim(plru_array[imshr_q[bus_rd_rsp_tag_i[0]].set_idx], valids);

                    valid_array[imshr_q[bus_rd_rsp_tag_i[0]].set_idx][victim_way] <= 1'b1;
                    tag_array[imshr_q[bus_rd_rsp_tag_i[0]].set_idx][victim_way]   <= imshr_q[bus_rd_rsp_tag_i[0]].tag;
                    data_array[imshr_q[bus_rd_rsp_tag_i[0]].set_idx][victim_way]  <= bus_rd_rsp_data_i;

                    plru_array[imshr_q[bus_rd_rsp_tag_i[0]].set_idx] <= plru_update(plru_array[imshr_q[bus_rd_rsp_tag_i[0]].set_idx], victim_way);
                end
            end

            // Update Tree-PLRU on cache hit
            if (f2_valid_q && cache_hit && !f2_page_fault_q && !f2_access_fault_q) begin
                plru_array[f2_set] <= plru_update(plru_array[f2_set], hit_way);
            end
        end
    end

endmodule

`endif // FURSOY_S1_L1I_SV
