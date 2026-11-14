`ifndef FURSOY_S1_ITLB_SV
`define FURSOY_S1_ITLB_SV

// =============================================================================
// Fursoy Slice-1 Instruction Translation Lookaside Buffer (ITLB) & ITRT — M4
// =============================================================================
// Features:
// - 64-Entry 4-Way Set-Associative Base-Page TLB (16 sets, 4 KiB pages).
// - 8-Entry Fully-Associative Superpage CAM (2 MiB and 1 GiB Sv39 superpages).
// - Persistent Instruction Translation Request Table (ITRT) with stale-response suppression.
// - Sv39 execute permission (X), privilege mode (U/S), and PMP authorization checks.
// - SFENCE.VMA address and ASID invalidation filtering.
// Reference: docs/architecture/slice1-m4-frontend-v1.md Sections 9, 12, 19, 20
// =============================================================================

`include "fursoy_s1_pkg.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_itlb
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Architectural System State
    input  logic [1:0]        priv_mode_i,       // 00=U, 01=S, 11=M
    input  logic [63:0]       satp_i,
    input  logic              pmp_allow_i,       // PMP execution permission for physical address

    // Frontend Translation Request (from Stage F1)
    input  logic              trans_req_valid_i,
    input  logic [63:0]       trans_req_va_i,
    output logic              trans_rsp_valid_o,
    output logic [55:0]       trans_rsp_pa_o,
    output logic              trans_rsp_page_fault_o,
    output logic              trans_rsp_access_fault_o,
    output logic              trans_busy_o,      // Asserted when miss is walking page table

    // Pipeline Flush / Redirect (Clears ITRT active waiter)
    input  logic              redirect_flush_i,

    // SFENCE.VMA Interface
    input  logic              sfence_vma_valid_i,
    input  logic [63:0]       sfence_vma_va_i,
    input  logic [15:0]       sfence_vma_asid_i,

    // -------------------------------------------------------------------------
    // PTW Request & Response Interface (to Shared PTW)
    // -------------------------------------------------------------------------
    output logic              ptw_req_valid_o,
    output logic              ptw_req_itrt_id_o,
    output logic [26:0]       ptw_req_vpn_o,
    input  logic              ptw_req_ready_i,

    input  logic              ptw_rsp_valid_i,
    input  logic              ptw_rsp_itrt_id_i,
    input  logic [55:0]       ptw_rsp_pa_i,
    input  logic              ptw_rsp_page_fault_i,
    input  logic              ptw_rsp_access_fault_i,
    input  logic [1:0]        ptw_rsp_level_i,
    input  logic [63:0]       ptw_rsp_pte_i,

    // Diagnostics / Events
    output logic              event_itlb_hit_o,
    output logic              event_itlb_miss_o
);

    wire        satp_mode_sv39 = (satp_i[63:60] == 4'd8) && (priv_mode_i != 2'b11);
    wire [15:0] satp_asid      = satp_i[59:44];

    // Canonical virtual address check for Sv39: bits [63:39] must match bit [38]
    wire va_canonical = (trans_req_va_i[63:38] == 26'd0) || (trans_req_va_i[63:38] == 26'h3FFFFFF);
    wire [26:0] vpn   = trans_req_va_i[38:12];

    // =========================================================================
    // 1. Base-Page TLB Array (64 Entries, 4-Way, 16 Sets)
    // =========================================================================
    localparam int BASE_SETS = 16;
    localparam int BASE_WAYS = 4;

    typedef struct packed {
        logic        valid;
        logic [22:0] tag;         // VPN[26:4] (23 bits)
        logic [43:0] ppn;         // PPN[43:0]
        logic [15:0] asid;
        logic        global_map;
        logic        perm_x;
        logic        perm_u;
    } base_tlb_entry_t;

    base_tlb_entry_t base_tlb [BASE_SETS][BASE_WAYS];
    logic [BASE_SETS-1:0][2:0] base_plru;

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

    wire [3:0]  base_set = vpn[3:0];
    wire [22:0] base_tag = vpn[26:4];

    logic [BASE_WAYS-1:0] base_way_hit;
    base_tlb_entry_t      base_hit_entry;
    logic [1:0]           base_hit_way;

    always_comb begin
        base_way_hit   = '0;
        base_hit_entry = '0;
        base_hit_way   = '0;
        for (int w = 0; w < BASE_WAYS; w++) begin
            if (base_tlb[base_set][w].valid &&
                (base_tlb[base_set][w].tag == base_tag) &&
                (base_tlb[base_set][w].global_map || (base_tlb[base_set][w].asid == satp_asid))) begin
                base_way_hit[w] = 1'b1;
                base_hit_entry  = base_tlb[base_set][w];
                base_hit_way    = 2'(w);
            end
        end
    end

    wire base_hit = |base_way_hit;

    // Deferred PLRU hit-update state (see sequential block below).
    logic       plru_upd_q;
    logic [3:0] plru_set_q;
    logic [1:0] plru_way_q;

    // =========================================================================
    // 2. Superpage Fully-Associative CAM (8 Entries: 2 MiB / 1 GiB)
    // =========================================================================
    localparam int SUPER_ENTRIES = 8;

    typedef struct packed {
        logic        valid;
        logic        is_1g;       // 1 = 1 GiB page, 0 = 2 MiB page
        logic [26:0] vpn;         // VPN base
        logic [43:0] ppn;
        logic [15:0] asid;
        logic        global_map;
        logic        perm_x;
        logic        perm_u;
    } super_tlb_entry_t;

    super_tlb_entry_t super_tlb [SUPER_ENTRIES];
    logic [2:0]       super_round_robin;

    logic [SUPER_ENTRIES-1:0] super_hit_vec;
    super_tlb_entry_t         super_hit_entry;

    always_comb begin
        super_hit_vec   = '0;
        super_hit_entry = '0;
        for (int i = 0; i < SUPER_ENTRIES; i++) begin
            if (super_tlb[i].valid &&
                (super_tlb[i].global_map || (super_tlb[i].asid == satp_asid))) begin
                if (super_tlb[i].is_1g) begin
                    // 1 GiB matches VPN[26:18]
                    if (super_tlb[i].vpn[26:18] == vpn[26:18]) begin
                        super_hit_vec[i] = 1'b1;
                        super_hit_entry  = super_tlb[i];
                    end
                end else begin
                    // 2 MiB matches VPN[26:9]
                    if (super_tlb[i].vpn[26:9] == vpn[26:9]) begin
                        super_hit_vec[i] = 1'b1;
                        super_hit_entry  = super_tlb[i];
                    end
                end
            end
        end
    end

    wire super_hit = |super_hit_vec;

    // Combined Hit & Address Formation
    wire tlb_hit = base_hit || super_hit;
    assign event_itlb_hit_o  = trans_req_valid_i && satp_mode_sv39 && tlb_hit;
    assign event_itlb_miss_o = trans_req_valid_i && satp_mode_sv39 && !tlb_hit;

    logic [55:0] hit_pa;
    logic        hit_perm_ok;

    always_comb begin
        hit_pa      = '0;
        hit_perm_ok = 1'b1;

        if (super_hit) begin
            if (super_hit_entry.is_1g) begin
                hit_pa = {super_hit_entry.ppn[43:18], vpn[17:0], trans_req_va_i[11:0]};
            end else begin
                hit_pa = {super_hit_entry.ppn[43:9], vpn[8:0], trans_req_va_i[11:0]};
            end
            if (priv_mode_i == 2'b00 && !super_hit_entry.perm_u) hit_perm_ok = 1'b0;
            if (priv_mode_i == 2'b01 && super_hit_entry.perm_u)  hit_perm_ok = 1'b0;
            if (!super_hit_entry.perm_x)                         hit_perm_ok = 1'b0;
        end else if (base_hit) begin
            hit_pa = {base_hit_entry.ppn, trans_req_va_i[11:0]};
            if (priv_mode_i == 2'b00 && !base_hit_entry.perm_u) hit_perm_ok = 1'b0;
            if (priv_mode_i == 2'b01 && base_hit_entry.perm_u)  hit_perm_ok = 1'b0;
            if (!base_hit_entry.perm_x)                         hit_perm_ok = 1'b0;
        end
    end

    // =========================================================================
    // 3. Persistent Instruction Translation Request Table (ITRT) — Section 9.3
    // =========================================================================
    typedef struct packed {
        logic        valid;
        logic        waiter_valid;
        logic [26:0] vpn;
        logic [63:0] orig_va;
    } itrt_entry_t;

    itrt_entry_t itrt_q;
    logic        pending_miss_q;
    logic [26:0] pending_vpn_q;
    logic [63:0] pending_orig_va_q;

    wire itrt_busy = itrt_q.valid;
    assign trans_busy_o = itrt_busy || pending_miss_q;

    // PTW Request Launch
    wire need_ptw_walk = trans_req_valid_i && !redirect_flush_i && satp_mode_sv39 && va_canonical && !tlb_hit && !itrt_busy && !pending_miss_q;
    assign ptw_req_valid_o   = need_ptw_walk || pending_miss_q;
    assign ptw_req_itrt_id_o = 1'b0;
    assign ptw_req_vpn_o     = pending_miss_q ? pending_vpn_q : vpn;

    // Response Muxing
    always_comb begin
        trans_rsp_valid_o        = 1'b0;
        trans_rsp_pa_o           = '0;
        trans_rsp_page_fault_o   = 1'b0;
        trans_rsp_access_fault_o = 1'b0;

        if (trans_req_valid_i) begin
            if (!satp_mode_sv39) begin
                // Bare mode (direct identity mapping)
                trans_rsp_valid_o        = 1'b1;
                trans_rsp_pa_o           = trans_req_va_i[55:0];
                trans_rsp_page_fault_o   = 1'b0;
                trans_rsp_access_fault_o = !pmp_allow_i;
            end else if (!va_canonical) begin
                // Non-canonical virtual address generates immediate Instruction Page Fault (Cause 12)
                trans_rsp_valid_o        = 1'b1;
                trans_rsp_pa_o           = '0;
                trans_rsp_page_fault_o   = 1'b1;
                trans_rsp_access_fault_o = 1'b0;
            end else if (tlb_hit) begin
                // Single-cycle TLB Hit!
                trans_rsp_valid_o        = 1'b1;
                trans_rsp_pa_o           = hit_pa;
                trans_rsp_page_fault_o   = !hit_perm_ok;
                trans_rsp_access_fault_o = hit_perm_ok && !pmp_allow_i;
            end
        end

        // Deliver PTW Refill Response to Active Waiter
        if (ptw_rsp_valid_i && itrt_q.valid && itrt_q.waiter_valid) begin
            trans_rsp_valid_o        = 1'b1;
            trans_rsp_pa_o           = {ptw_rsp_pa_i[55:12], itrt_q.orig_va[11:0]};
            trans_rsp_page_fault_o   = ptw_rsp_page_fault_i;
            trans_rsp_access_fault_o = ptw_rsp_access_fault_i || (!ptw_rsp_page_fault_i && !pmp_allow_i);
        end
    end

    // =========================================================================
    // 4. Sequential TLB State Updates & Refill Installation
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            itrt_q            <= '0;
            pending_miss_q    <= 1'b0;
            pending_vpn_q     <= '0;
            pending_orig_va_q <= '0;
            base_plru         <= '0;
            super_round_robin <= '0;

            for (int s = 0; s < BASE_SETS; s++) begin
                for (int w = 0; w < BASE_WAYS; w++) begin
                    base_tlb[s][w] <= '0;
                end
            end

            for (int i = 0; i < SUPER_ENTRIES; i++) begin
                super_tlb[i] <= '0;
            end
        end else begin
            // -----------------------------------------------------------------
            // A. SFENCE.VMA Invalidation Processing
            // -----------------------------------------------------------------
            if (sfence_vma_valid_i) begin
                for (int s = 0; s < BASE_SETS; s++) begin
                    for (int w = 0; w < BASE_WAYS; w++) begin
                        if (base_tlb[s][w].valid) begin
                            logic match_va, match_asid;
                            match_va   = (sfence_vma_va_i == 64'd0) || ({base_tlb[s][w].tag, s[3:0]} == sfence_vma_va_i[38:12]);
                            match_asid = (sfence_vma_asid_i == 16'd0) || (base_tlb[s][w].asid == sfence_vma_asid_i);
                            if (match_va && (match_asid || base_tlb[s][w].global_map)) begin
                                base_tlb[s][w].valid <= 1'b0;
                            end
                        end
                    end
                end

                for (int i = 0; i < SUPER_ENTRIES; i++) begin
                    if (super_tlb[i].valid) begin
                        logic match_asid;
                        match_asid = (sfence_vma_asid_i == 16'd0) || (super_tlb[i].asid == sfence_vma_asid_i);
                        if (match_asid || super_tlb[i].global_map) begin
                            super_tlb[i].valid <= 1'b0;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            // B. ITRT Lifetime Tracking & Stale Waiter Suppression
            // -----------------------------------------------------------------
            if (redirect_flush_i) begin
                // On pipeline redirect, clear waiter flag but keep transaction identity allocated!
                itrt_q.waiter_valid <= 1'b0;
                pending_miss_q      <= 1'b0;
            end else begin
                if (need_ptw_walk && ptw_req_ready_i) begin
                    itrt_q.valid        <= 1'b1;
                    itrt_q.waiter_valid <= 1'b1;
                    itrt_q.vpn          <= vpn;
                    itrt_q.orig_va      <= trans_req_va_i;
                end else if (need_ptw_walk && !ptw_req_ready_i) begin
                    pending_miss_q      <= 1'b1;
                    pending_vpn_q       <= vpn;
                    pending_orig_va_q   <= trans_req_va_i;
                end else if (pending_miss_q && ptw_req_ready_i) begin
                    pending_miss_q      <= 1'b0;
                    itrt_q.valid        <= 1'b1;
                    itrt_q.waiter_valid <= 1'b1;
                    itrt_q.vpn          <= pending_vpn_q;
                    itrt_q.orig_va      <= pending_orig_va_q;
                end
            end

            // -----------------------------------------------------------------
            // C. PTW Refill Installation into TLB Array
            // -----------------------------------------------------------------
            if (ptw_rsp_valid_i && itrt_q.valid) begin
                itrt_q.valid <= 1'b0; // Deallocate transaction

                if (!ptw_rsp_page_fault_i && !ptw_rsp_access_fault_i) begin
                    if (ptw_rsp_level_i == 2'd2 || ptw_rsp_level_i == 2'd1) begin
                        // Section 4: Superpage translation (1 GiB or 2 MiB) installed into super_tlb CAM
                        super_tlb[super_round_robin].valid      <= 1'b1;
                        super_tlb[super_round_robin].is_1g      <= (ptw_rsp_level_i == 2'd2);
                        super_tlb[super_round_robin].vpn        <= itrt_q.vpn;
                        super_tlb[super_round_robin].ppn        <= ptw_rsp_pte_i[53:10];
                        super_tlb[super_round_robin].asid       <= satp_asid;
                        super_tlb[super_round_robin].global_map <= ptw_rsp_pte_i[5]; // G bit
                        super_tlb[super_round_robin].perm_x     <= ptw_rsp_pte_i[3]; // X bit
                        super_tlb[super_round_robin].perm_u     <= ptw_rsp_pte_i[4]; // U bit
                        super_round_robin                       <= super_round_robin + 3'd1;
                    end else begin
                        // 4 KiB base page installed into Base TLB using 3-bit Tree-PLRU
                        logic [1:0] victim_way;
                        logic [3:0] valids;
                        for (int w = 0; w < 4; w++) valids[w] = base_tlb[itrt_q.vpn[3:0]][w].valid;
                        victim_way = plru_victim(base_plru[itrt_q.vpn[3:0]], valids);

                        base_tlb[itrt_q.vpn[3:0]][victim_way].valid      <= 1'b1;
                        base_tlb[itrt_q.vpn[3:0]][victim_way].tag        <= itrt_q.vpn[26:4];
                        base_tlb[itrt_q.vpn[3:0]][victim_way].ppn        <= ptw_rsp_pte_i[53:10];
                        base_tlb[itrt_q.vpn[3:0]][victim_way].asid       <= satp_asid;
                        base_tlb[itrt_q.vpn[3:0]][victim_way].global_map <= ptw_rsp_pte_i[5]; // G bit
                        base_tlb[itrt_q.vpn[3:0]][victim_way].perm_x     <= ptw_rsp_pte_i[3]; // X bit
                        base_tlb[itrt_q.vpn[3:0]][victim_way].perm_u     <= ptw_rsp_pte_i[4]; // U bit

                        base_plru[itrt_q.vpn[3:0]] <= plru_update(base_plru[itrt_q.vpn[3:0]], victim_way);
                    end
                end
            end

            // Deferred Tree-PLRU update from the previous cycle's Base TLB hit
            // (PPA Stage 1: registered so the VA tag compare does not drive the
            // PLRU state flops in the same cycle). Kept last so it retains the
            // original priority over a same-cycle refill PLRU update.
            if (plru_upd_q) begin
                base_plru[plru_set_q] <= plru_update(base_plru[plru_set_q], plru_way_q);
            end
        end
    end

    // Capture registers for the deferred PLRU hit update.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            plru_upd_q <= 1'b0;
            plru_set_q <= '0;
            plru_way_q <= '0;
        end else begin
            plru_upd_q <= trans_req_valid_i && satp_mode_sv39 && base_hit;
            plru_set_q <= base_set;
            plru_way_q <= base_hit_way;
        end
    end

endmodule

`endif // FURSOY_S1_ITLB_SV
