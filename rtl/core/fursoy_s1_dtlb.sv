`ifndef FURSOY_S1_DTLB_SV
`define FURSOY_S1_DTLB_SV

// =============================================================================
// Fursoy Slice-1 Data Translation Lookaside Buffer (DTLB)
// =============================================================================
// Architectural Sv39 Dual-Port Data Translation Lookaside Buffer:
// - Serves Port 2 AGU (loads, stores, AMOs) and Port 3 AGU (loads strictly).
// - 64-Entry 4-Way Set-Associative Base-Page TLB (16 sets, 4 KiB pages).
// - 8-Entry Fully-Associative Superpage CAM (2 MiB and 1 GiB Sv39 superpages).
// - Tree-PLRU replacement policy per set with victim selection.
// - Canonical Sv39 sign-extension check: bits [63:38] must match bit [38].
// - Privilege mode & permission enforcement:
//     * User mode (U): perm_u == 1 required.
//     * Supervisor mode (S): perm_u == 1 only permitted if sstatus.SUM == 1.
//     * Read: perm_r == 1, or (perm_x == 1 && sstatus.MXR == 1).
//     * Write/Store/AMO: perm_w == 1 and perm_d == 1 (dirty bit set).
//     * Accessed bit: perm_a == 1 required (Svade fault-on-clear).
// - satp.MODE check: Bare (MODE=0) or M-mode without MPRV disables translation
//   (identity mapped PA = VA[55:0], hit = 1, no page faults).
// - SFENCE.VMA invalidation: selectively invalidates matching ASID and VA entries,
//   or all entries on ASID=0/VA=0.
// - Dynamic PTW refill installation from completed page table walks.
// =============================================================================

`include "fursoy_s1_pkg.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_dtlb
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Architectural System State
    input  logic [1:0]        priv_mode_i,       // 00=U, 01=S, 11=M
    input  logic [63:0]       satp_i,
    input  logic [63:0]       mstatus_i,

    // Port 0 Translation Request & Response (Port 2 AGU: Loads, Stores, AMOs)
    input  logic              p0_req_valid_i,
    input  logic [63:0]       p0_req_va_i,
    input  logic              p0_req_is_store_i,
    input  logic              p0_req_is_amo_i,
    output logic              p0_rsp_hit_o,
    output logic [55:0]       p0_rsp_pa_o,
    output logic              p0_rsp_page_fault_o,
    output logic              p0_rsp_access_fault_o,

    // Port 1 Translation Request & Response (Port 3 AGU: Loads strictly)
    input  logic              p1_req_valid_i,
    input  logic [63:0]       p1_req_va_i,
    output logic              p1_rsp_hit_o,
    output logic [55:0]       p1_rsp_pa_o,
    output logic              p1_rsp_page_fault_o,
    output logic              p1_rsp_access_fault_o,

    // SFENCE.VMA Invalidation Interface
    input  logic              sfence_vma_valid_i,
    input  logic [63:0]       sfence_vma_va_i,
    input  logic [15:0]       sfence_vma_asid_i,
    input  logic              sfence_vma_rs1_zero_i,
    input  logic              sfence_vma_rs2_zero_i,

    // Refill Interface from PTW / TRT
    input  logic              refill_valid_i,
    input  logic [26:0]       refill_vpn_i,
    input  logic [1:0]        refill_level_i,    // 0=4K, 1=2M, 2=1G
    input  logic [63:0]       refill_pte_i,
    input  logic [55:0]       refill_pa_i
);

    // =========================================================================
    // Architectural Privilege & Mode Decoding
    // =========================================================================
    wire        mstatus_mprv   = mstatus_i[17];
    wire [1:0]  mstatus_mpp    = mstatus_i[12:11];
    wire        sstatus_sum    = mstatus_i[18];
    wire        sstatus_mxr    = mstatus_i[19];

    // Effective privilege mode for data translation:
    // If MPRV == 1 in M-mode, translation and permissions evaluate as MPP.
    wire [1:0] eff_priv = (priv_mode_i == 2'b11 && mstatus_mprv) ? mstatus_mpp : priv_mode_i;

    // Translation enabled when satp.MODE == 8 (Sv39) and effective mode is not M-mode
    wire satp_mode_sv39 = (satp_i[63:60] == 4'd8) && (eff_priv != 2'b11);
    wire [15:0] satp_asid = satp_i[59:44];

    // Canonical virtual address check for Sv39: bits [63:38] must match bit [38]
    function automatic logic check_canonical(input logic [63:0] va);
        return (va[63:38] == 26'd0) || (va[63:38] == 26'h3FFFFFF);
    endfunction

    // Data permission evaluation function
    function automatic logic check_data_perm(
        input logic [1:0] priv,
        input logic       sum,
        input logic       mxr,
        input logic       is_store,
        input logic       perm_r,
        input logic       perm_w,
        input logic       perm_x,
        input logic       perm_u,
        input logic       flag_a,
        input logic       flag_d
    );
        // User page access rule:
        // User mode can ONLY access U=1 pages
        if (priv == 2'b00 && !perm_u) return 1'b0;
        // Supervisor mode can ONLY access U=1 pages if SUM=1
        if (priv == 2'b01 && perm_u && !sum) return 1'b0;

        // Type permissions:
        if (is_store) begin
            if (!perm_w) return 1'b0;
            if (!flag_d) return 1'b0; // Dirty bit must be set (Svade)
        end else begin
            if (!perm_r && !(mxr && perm_x)) return 1'b0;
        end

        // Accessed bit must be set (Svade)
        if (!flag_a) return 1'b0;

        return 1'b1;
    endfunction

    // =========================================================================
    // 1. Base-Page TLB Array (64 Entries, 4-Way Set-Associative, 16 Sets)
    // =========================================================================
    localparam int BASE_SETS = 16;
    localparam int BASE_WAYS = 4;

    typedef struct packed {
        logic        valid;
        logic [22:0] tag;         // VPN[26:4] (23 bits)
        logic [43:0] ppn;         // PPN[43:0]
        logic [15:0] asid;
        logic        global_map;  // PTE.G
        logic        perm_r;      // PTE.R
        logic        perm_w;      // PTE.W
        logic        perm_x;      // PTE.X
        logic        perm_u;      // PTE.U
        logic        flag_a;      // PTE.A
        logic        flag_d;      // PTE.D
    } base_tlb_entry_t;

    base_tlb_entry_t base_tlb [BASE_SETS][BASE_WAYS];
    logic [BASE_SETS-1:0][2:0] base_plru;

    // 3-bit Tree-PLRU helper functions
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
        logic        perm_r;
        logic        perm_w;
        logic        perm_x;
        logic        perm_u;
        logic        flag_a;
        logic        flag_d;
    } super_tlb_entry_t;

    super_tlb_entry_t super_tlb [SUPER_ENTRIES];
    logic [2:0]       super_round_robin;

    // =========================================================================
    // 3. Port 0 Concurrent Lookup Evaluation (Port 2 AGU: Load / Store / AMO)
    // =========================================================================
    wire [26:0] p0_vpn      = p0_req_va_i[38:12];
    wire [3:0]  p0_base_set = p0_vpn[3:0];
    wire [22:0] p0_base_tag = p0_vpn[26:4];
    wire        p0_canonical= check_canonical(p0_req_va_i);

    logic [BASE_WAYS-1:0] p0_base_hit_vec;
    base_tlb_entry_t      p0_base_hit_entry;
    logic [1:0]           p0_base_hit_way;

    always_comb begin
        p0_base_hit_vec   = '0;
        p0_base_hit_entry = '0;
        p0_base_hit_way   = '0;
        for (int w = 0; w < BASE_WAYS; w++) begin
            if (base_tlb[p0_base_set][w].valid &&
                (base_tlb[p0_base_set][w].tag == p0_base_tag) &&
                (base_tlb[p0_base_set][w].global_map || (base_tlb[p0_base_set][w].asid == satp_asid))) begin
                p0_base_hit_vec[w] = 1'b1;
                p0_base_hit_entry  = base_tlb[p0_base_set][w];
                p0_base_hit_way    = 2'(w);
            end
        end
    end

    wire p0_base_hit = |p0_base_hit_vec;

    logic [SUPER_ENTRIES-1:0] p0_super_hit_vec;
    super_tlb_entry_t         p0_super_hit_entry;

    always_comb begin
        p0_super_hit_vec   = '0;
        p0_super_hit_entry = '0;
        for (int i = 0; i < SUPER_ENTRIES; i++) begin
            if (super_tlb[i].valid &&
                (super_tlb[i].global_map || (super_tlb[i].asid == satp_asid))) begin
                if (super_tlb[i].is_1g) begin
                    if (super_tlb[i].vpn[26:18] == p0_vpn[26:18]) begin
                        p0_super_hit_vec[i] = 1'b1;
                        p0_super_hit_entry  = super_tlb[i];
                    end
                end else begin
                    if (super_tlb[i].vpn[26:9] == p0_vpn[26:9]) begin
                        p0_super_hit_vec[i] = 1'b1;
                        p0_super_hit_entry  = super_tlb[i];
                    end
                end
            end
        end
    end

    wire p0_super_hit = |p0_super_hit_vec;
    wire p0_tlb_hit   = p0_base_hit || p0_super_hit;

    logic [55:0] p0_trans_pa;
    logic        p0_perm_ok;

    always_comb begin
        p0_trans_pa = '0;
        p0_perm_ok  = 1'b1;

        if (p0_super_hit) begin
            if (p0_super_hit_entry.is_1g) begin
                p0_trans_pa = {p0_super_hit_entry.ppn[43:18], p0_vpn[17:0], p0_req_va_i[11:0]};
            end else begin
                p0_trans_pa = {p0_super_hit_entry.ppn[43:9], p0_vpn[8:0], p0_req_va_i[11:0]};
            end
            p0_perm_ok = check_data_perm(
                eff_priv, sstatus_sum, sstatus_mxr,
                p0_req_is_store_i || p0_req_is_amo_i,
                p0_super_hit_entry.perm_r,
                p0_super_hit_entry.perm_w,
                p0_super_hit_entry.perm_x,
                p0_super_hit_entry.perm_u,
                p0_super_hit_entry.flag_a,
                p0_super_hit_entry.flag_d
            );
        end else if (p0_base_hit) begin
            p0_trans_pa = {p0_base_hit_entry.ppn, p0_req_va_i[11:0]};
            p0_perm_ok = check_data_perm(
                eff_priv, sstatus_sum, sstatus_mxr,
                p0_req_is_store_i || p0_req_is_amo_i,
                p0_base_hit_entry.perm_r,
                p0_base_hit_entry.perm_w,
                p0_base_hit_entry.perm_x,
                p0_base_hit_entry.perm_u,
                p0_base_hit_entry.flag_a,
                p0_base_hit_entry.flag_d
            );
        end
    end

    always_comb begin
        p0_rsp_hit_o          = 1'b0;
        p0_rsp_pa_o           = 56'd0;
        p0_rsp_page_fault_o   = 1'b0;
        p0_rsp_access_fault_o = 1'b0;

        if (!satp_mode_sv39) begin
            // Bare Mode: Identity mapping (PA = VA[55:0])
            p0_rsp_hit_o = 1'b1;
            p0_rsp_pa_o  = p0_req_va_i[55:0];
        end else if (!p0_canonical) begin
            // Non-canonical Sv39 VA: Immediate page fault
            p0_rsp_hit_o        = 1'b1;
            p0_rsp_page_fault_o = 1'b1;
        end else if (p0_tlb_hit) begin
            // TLB Hit: Provide translated PA and permissions
            p0_rsp_hit_o        = 1'b1;
            p0_rsp_pa_o         = p0_trans_pa;
            p0_rsp_page_fault_o = !p0_perm_ok;
        end else begin
            // TLB Miss: PTW walk required
            p0_rsp_hit_o = 1'b0;
        end
    end

    // =========================================================================
    // 4. Port 1 Concurrent Lookup Evaluation (Port 3 AGU: Loads Strictly)
    // =========================================================================
    wire [26:0] p1_vpn      = p1_req_va_i[38:12];
    wire [3:0]  p1_base_set = p1_vpn[3:0];
    wire [22:0] p1_base_tag = p1_vpn[26:4];
    wire        p1_canonical= check_canonical(p1_req_va_i);

    logic [BASE_WAYS-1:0] p1_base_hit_vec;
    base_tlb_entry_t      p1_base_hit_entry;
    logic [1:0]           p1_base_hit_way;

    always_comb begin
        p1_base_hit_vec   = '0;
        p1_base_hit_entry = '0;
        p1_base_hit_way   = '0;
        for (int w = 0; w < BASE_WAYS; w++) begin
            if (base_tlb[p1_base_set][w].valid &&
                (base_tlb[p1_base_set][w].tag == p1_base_tag) &&
                (base_tlb[p1_base_set][w].global_map || (base_tlb[p1_base_set][w].asid == satp_asid))) begin
                p1_base_hit_vec[w] = 1'b1;
                p1_base_hit_entry  = base_tlb[p1_base_set][w];
                p1_base_hit_way    = 2'(w);
            end
        end
    end

    wire p1_base_hit = |p1_base_hit_vec;

    logic [SUPER_ENTRIES-1:0] p1_super_hit_vec;
    super_tlb_entry_t         p1_super_hit_entry;

    always_comb begin
        p1_super_hit_vec   = '0;
        p1_super_hit_entry = '0;
        for (int i = 0; i < SUPER_ENTRIES; i++) begin
            if (super_tlb[i].valid &&
                (super_tlb[i].global_map || (super_tlb[i].asid == satp_asid))) begin
                if (super_tlb[i].is_1g) begin
                    if (super_tlb[i].vpn[26:18] == p1_vpn[26:18]) begin
                        p1_super_hit_vec[i] = 1'b1;
                        p1_super_hit_entry  = super_tlb[i];
                    end
                end else begin
                    if (super_tlb[i].vpn[26:9] == p1_vpn[26:9]) begin
                        p1_super_hit_vec[i] = 1'b1;
                        p1_super_hit_entry  = super_tlb[i];
                    end
                end
            end
        end
    end

    wire p1_super_hit = |p1_super_hit_vec;
    wire p1_tlb_hit   = p1_base_hit || p1_super_hit;

    logic [55:0] p1_trans_pa;
    logic        p1_perm_ok;

    always_comb begin
        p1_trans_pa = '0;
        p1_perm_ok  = 1'b1;

        if (p1_super_hit) begin
            if (p1_super_hit_entry.is_1g) begin
                p1_trans_pa = {p1_super_hit_entry.ppn[43:18], p1_vpn[17:0], p1_req_va_i[11:0]};
            end else begin
                p1_trans_pa = {p1_super_hit_entry.ppn[43:9], p1_vpn[8:0], p1_req_va_i[11:0]};
            end
            p1_perm_ok = check_data_perm(
                eff_priv, sstatus_sum, sstatus_mxr,
                1'b0, // Port 3 is loads strictly
                p1_super_hit_entry.perm_r,
                p1_super_hit_entry.perm_w,
                p1_super_hit_entry.perm_x,
                p1_super_hit_entry.perm_u,
                p1_super_hit_entry.flag_a,
                p1_super_hit_entry.flag_d
            );
        end else if (p1_base_hit) begin
            p1_trans_pa = {p1_base_hit_entry.ppn, p1_req_va_i[11:0]};
            p1_perm_ok = check_data_perm(
                eff_priv, sstatus_sum, sstatus_mxr,
                1'b0, // Port 3 is loads strictly
                p1_base_hit_entry.perm_r,
                p1_base_hit_entry.perm_w,
                p1_base_hit_entry.perm_x,
                p1_base_hit_entry.perm_u,
                p1_base_hit_entry.flag_a,
                p1_base_hit_entry.flag_d
            );
        end
    end

    always_comb begin
        p1_rsp_hit_o          = 1'b0;
        p1_rsp_pa_o           = 56'd0;
        p1_rsp_page_fault_o   = 1'b0;
        p1_rsp_access_fault_o = 1'b0;

        if (!satp_mode_sv39) begin
            // Bare Mode: Identity mapping
            p1_rsp_hit_o = 1'b1;
            p1_rsp_pa_o  = p1_req_va_i[55:0];
        end else if (!p1_canonical) begin
            // Non-canonical Sv39 VA: Immediate page fault
            p1_rsp_hit_o        = 1'b1;
            p1_rsp_page_fault_o = 1'b1;
        end else if (p1_tlb_hit) begin
            // TLB Hit: Provide translated PA and permissions
            p1_rsp_hit_o        = 1'b1;
            p1_rsp_pa_o         = p1_trans_pa;
            p1_rsp_page_fault_o = !p1_perm_ok;
        end else begin
            // TLB Miss: PTW walk required
            p1_rsp_hit_o = 1'b0;
        end
    end

    // =========================================================================
    // 5. Refill & Maintenance Sequential Updates
    // =========================================================================
    wire [3:0] refill_set = refill_vpn_i[3:0];
    wire [3:0] refill_set_valids = {
        base_tlb[refill_set][3].valid,
        base_tlb[refill_set][2].valid,
        base_tlb[refill_set][1].valid,
        base_tlb[refill_set][0].valid
    };
    logic       refill_base_dup_hit;
    logic [1:0] refill_base_dup_way;
    always_comb begin
        refill_base_dup_hit = 1'b0;
        refill_base_dup_way = 2'd0;
        for (int w = 0; w < BASE_WAYS; w++) begin
            if (base_tlb[refill_set][w].valid &&
                (base_tlb[refill_set][w].tag == refill_vpn_i[26:4]) &&
                (base_tlb[refill_set][w].global_map || refill_pte_i[5] || (base_tlb[refill_set][w].asid == satp_asid))) begin
                refill_base_dup_hit = 1'b1;
                refill_base_dup_way = 2'(w);
            end
        end
    end
    wire [1:0] base_victim_way = refill_base_dup_hit ? refill_base_dup_way : plru_victim(base_plru[refill_set], refill_set_valids);

    logic       refill_super_dup_hit;
    logic [2:0] refill_super_dup_idx;
    always_comb begin
        refill_super_dup_hit = 1'b0;
        refill_super_dup_idx = 3'd0;
        for (int i = 0; i < SUPER_ENTRIES; i++) begin
            if (super_tlb[i].valid &&
                (super_tlb[i].global_map || refill_pte_i[5] || (super_tlb[i].asid == satp_asid))) begin
                if (super_tlb[i].is_1g ? (super_tlb[i].vpn[26:18] == refill_vpn_i[26:18])
                                       : (super_tlb[i].vpn[26:9]  == refill_vpn_i[26:9])) begin
                    refill_super_dup_hit = 1'b1;
                    refill_super_dup_idx = 3'(i);
                end
            end
        end
    end
    wire [2:0] super_install_idx = refill_super_dup_hit ? refill_super_dup_idx : super_round_robin;

    // -------------------------------------------------------------------------
    // Deferred Tree-PLRU hit update (PPA Stage 1 timing decoupling)
    // -------------------------------------------------------------------------
    // The lookup tag-compare / hit-way result is registered here and applied
    // to base_plru one cycle later, so the timing-critical VA tag comparison
    // never feeds the PLRU state flops in the same cycle. PLRU is a
    // replacement hint only; translation results are unaffected.
    wire p0_plru_upd_d = !sfence_vma_valid_i && !(refill_valid_i && satp_mode_sv39) &&
                         p0_req_valid_i && satp_mode_sv39 && p0_canonical && p0_base_hit;
    wire p1_plru_upd_d = !sfence_vma_valid_i && !(refill_valid_i && satp_mode_sv39) &&
                         p1_req_valid_i && satp_mode_sv39 && p1_canonical && p1_base_hit &&
                         !(p0_req_valid_i && (p0_base_set == p1_base_set));

    logic       p0_plru_upd_q, p1_plru_upd_q;
    logic [3:0] p0_plru_set_q, p1_plru_set_q;
    logic [1:0] p0_plru_way_q, p1_plru_way_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            p0_plru_upd_q <= 1'b0;
            p1_plru_upd_q <= 1'b0;
            p0_plru_set_q <= '0;
            p1_plru_set_q <= '0;
            p0_plru_way_q <= '0;
            p1_plru_way_q <= '0;
        end else begin
            p0_plru_upd_q <= p0_plru_upd_d;
            p1_plru_upd_q <= p1_plru_upd_d;
            p0_plru_set_q <= p0_base_set;
            p1_plru_set_q <= p1_base_set;
            p0_plru_way_q <= p0_base_hit_way;
            p1_plru_way_q <= p1_base_hit_way;
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int s = 0; s < BASE_SETS; s++) begin
                for (int w = 0; w < BASE_WAYS; w++) begin
                    base_tlb[s][w] <= '0;
                end
                base_plru[s] <= 3'd0;
            end
            for (int i = 0; i < SUPER_ENTRIES; i++) begin
                super_tlb[i] <= '0;
            end
            super_round_robin <= 3'd0;
        end else begin
            // -----------------------------------------------------------------
            // C. Deferred PLRU Updates from the previous cycle's lookup hits.
            //    Issued first so a same-cycle refill PLRU update (below) to the
            //    same set takes priority. p0/p1 sets are distinct by capture.
            // -----------------------------------------------------------------
            if (p0_plru_upd_q) begin
                base_plru[p0_plru_set_q] <= plru_update(base_plru[p0_plru_set_q], p0_plru_way_q);
            end
            if (p1_plru_upd_q) begin
                base_plru[p1_plru_set_q] <= plru_update(base_plru[p1_plru_set_q], p1_plru_way_q);
            end

            // -----------------------------------------------------------------
            // A. SFENCE.VMA Invalidation
            // -----------------------------------------------------------------
            if (sfence_vma_valid_i) begin
                logic rs1_zero;
                logic rs2_zero;
                rs1_zero = sfence_vma_rs1_zero_i;
                rs2_zero = sfence_vma_rs2_zero_i;

                for (int s = 0; s < BASE_SETS; s++) begin
                    for (int w = 0; w < BASE_WAYS; w++) begin
                        if (base_tlb[s][w].valid) begin
                            logic match_va;
                            logic match_asid;
                            match_va   = rs1_zero || ({base_tlb[s][w].tag, s[3:0]} == sfence_vma_va_i[38:12]);
                            match_asid = rs2_zero ? 1'b1 : (!base_tlb[s][w].global_map && (base_tlb[s][w].asid == sfence_vma_asid_i));
                            if (match_va && match_asid) begin
                                base_tlb[s][w].valid <= 1'b0;
                            end
                        end
                    end
                end

                for (int i = 0; i < SUPER_ENTRIES; i++) begin
                    if (super_tlb[i].valid) begin
                        logic match_va;
                        logic match_asid;
                        if (super_tlb[i].is_1g) begin
                            match_va = rs1_zero || (super_tlb[i].vpn[26:18] == sfence_vma_va_i[38:30]);
                        end else begin
                            match_va = rs1_zero || (super_tlb[i].vpn[26:9] == sfence_vma_va_i[38:21]);
                        end
                        match_asid = rs2_zero ? 1'b1 : (!super_tlb[i].global_map && (super_tlb[i].asid == sfence_vma_asid_i));
                        if (match_va && match_asid) begin
                            super_tlb[i].valid <= 1'b0;
                        end
                    end
                end
            end
            // -----------------------------------------------------------------
            // B. PTW Translation Refill Installation
            // -----------------------------------------------------------------
            else if (refill_valid_i && satp_mode_sv39) begin
                if (refill_level_i == 2'd0) begin
                    // Base 4 KiB Page Installation
                    base_tlb[refill_set][base_victim_way].valid      <= 1'b1;
                    base_tlb[refill_set][base_victim_way].tag        <= refill_vpn_i[26:4];
                    base_tlb[refill_set][base_victim_way].ppn        <= refill_pte_i[53:10];
                    base_tlb[refill_set][base_victim_way].asid       <= satp_asid;
                    base_tlb[refill_set][base_victim_way].global_map <= refill_pte_i[5];
                    base_tlb[refill_set][base_victim_way].perm_r     <= refill_pte_i[1];
                    base_tlb[refill_set][base_victim_way].perm_w     <= refill_pte_i[2];
                    base_tlb[refill_set][base_victim_way].perm_x     <= refill_pte_i[3];
                    base_tlb[refill_set][base_victim_way].perm_u     <= refill_pte_i[4];
                    base_tlb[refill_set][base_victim_way].flag_a     <= refill_pte_i[6];
                    base_tlb[refill_set][base_victim_way].flag_d     <= refill_pte_i[7];

                    base_plru[refill_set] <= plru_update(base_plru[refill_set], base_victim_way);
                end else begin
                    // Superpage (2 MiB / 1 GiB) Installation
                    super_tlb[super_install_idx].valid      <= 1'b1;
                    super_tlb[super_install_idx].is_1g      <= (refill_level_i == 2'd2);
                    super_tlb[super_install_idx].vpn        <= refill_vpn_i;
                    super_tlb[super_install_idx].ppn        <= refill_pte_i[53:10];
                    super_tlb[super_install_idx].asid       <= satp_asid;
                    super_tlb[super_install_idx].global_map <= refill_pte_i[5];
                    super_tlb[super_install_idx].perm_r     <= refill_pte_i[1];
                    super_tlb[super_install_idx].perm_w     <= refill_pte_i[2];
                    super_tlb[super_install_idx].perm_x     <= refill_pte_i[3];
                    super_tlb[super_install_idx].perm_u     <= refill_pte_i[4];
                    super_tlb[super_install_idx].flag_a     <= refill_pte_i[6];
                    super_tlb[super_install_idx].flag_d     <= refill_pte_i[7];

                    if (!refill_super_dup_hit) begin
                        super_round_robin <= super_round_robin + 1'b1;
                    end
                end
            end
            // Lookup-hit PLRU updates are captured into p*_plru_upd_q above and
            // applied in section C of the following cycle.
        end
    end

endmodule
/* verilator lint_on UNUSEDSIGNAL */

`endif // FURSOY_S1_DTLB_SV
