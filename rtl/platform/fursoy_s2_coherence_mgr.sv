`ifndef FURSOY_S2_COHERENCE_MGR_SV
`define FURSOY_S2_COHERENCE_MGR_SV

// =============================================================================
// Fursoy Slice-2 Directory-Backed MESI Coherence Manager — Milestone S2-M2
// =============================================================================
// Reference: docs/architecture/slice2-smp-v1.md §2, §5
// - 3-VC virtual-channel deadlock-free ordering: VC2 (Rsp) > VC1 (Snoop) > VC0 (Req).
// - VC0_WR (PutM) prioritized over VC0_RD (L1D_RD, L1I, PTW) at Stage C0.
// - Stage C0: Parallel hazard filter against active DIR_MSHRs (line_addr &
//   victim_addr) and Stage C1 set, feeding rotating RR arbiter (zero HoL block).
// - Stage C1: Inclusive L2 directory lookup via fursoy_s2_l2, atomic fast-path
//   hits & PutM (including late PutM no-op PutAck), and DIR_MSHR allocation.
// - 8-entry DIR_MSHR handles multi-hart snoops (VC1->VC2), inclusive victim
//   back-invalidation, silent E->M clean/dirty handling, Forward & Reverse
//   Upgrade-vs-Inv coherence, DRAM fill/writeback, and coherent L1I/PTW.
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s2_l2.sv"

module fursoy_s2_coherence_mgr
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned NUM_HARTS      = 2,
    parameter int unsigned L2_SETS        = 512,
    parameter int unsigned L2_WAYS        = 8,
    parameter int unsigned DIR_MSHR_DEPTH = 8,
    localparam int unsigned SET_W         = $clog2(L2_SETS),
    localparam int unsigned TAG_W         = 50 - SET_W,
    localparam int unsigned WAY_W         = $clog2(L2_WAYS),
    localparam int unsigned HART_W        = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1,
    localparam int unsigned MSHR_W        = $clog2(DIR_MSHR_DEPTH)
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // L1D Read Channels (VC0_RD Req -> VC2 Grant)
    input  logic [NUM_HARTS-1:0]   l1d_rd_req_valid_i,
    input  logic [49:0]            l1d_rd_req_addr_i     [NUM_HARTS],
    input  logic [1:0]             l1d_rd_req_tag_i      [NUM_HARTS],
    input  coh_req_op_t            l1d_rd_req_op_i       [NUM_HARTS],
    output logic [NUM_HARTS-1:0]   l1d_rd_req_ready_o,

    output logic [NUM_HARTS-1:0]   l1d_rd_rsp_valid_o,
    output logic [1:0]             l1d_rd_rsp_tag_o      [NUM_HARTS],
    output logic [511:0]           l1d_rd_rsp_data_o     [NUM_HARTS],
    output mesi_state_t            l1d_rd_rsp_state_o    [NUM_HARTS],
    output logic [NUM_HARTS-1:0]   l1d_rd_rsp_has_data_o,

    // L1D Write Channels (VC0_WR PutM -> PutAck)
    input  logic [NUM_HARTS-1:0]   l1d_wr_req_valid_i,
    input  logic [49:0]            l1d_wr_req_addr_i     [NUM_HARTS],
    input  logic [511:0]           l1d_wr_req_data_i     [NUM_HARTS],
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [NUM_HARTS-1:0]   l1d_wr_req_dirty_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [NUM_HARTS-1:0]   l1d_wr_req_ready_o,
    output logic [NUM_HARTS-1:0]   l1d_wr_rsp_valid_o,

    // L1D Snoop Channels (VC1 SnoopReq -> VC2 SnoopRsp)
    output logic [NUM_HARTS-1:0]   snoop_req_valid_o,
    output logic [49:0]            snoop_req_addr_o      [NUM_HARTS],
    output logic [1:0]             snoop_req_type_o      [NUM_HARTS],
    input  logic [NUM_HARTS-1:0]   snoop_req_ready_i,

    input  logic [NUM_HARTS-1:0]   snoop_rsp_valid_i,
    input  logic [NUM_HARTS-1:0]   snoop_rsp_has_data_i,
    input  logic [511:0]           snoop_rsp_data_i      [NUM_HARTS],
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [NUM_HARTS-1:0]   snoop_rsp_was_dirty_i,
    input  logic [NUM_HARTS-1:0]   snoop_rsp_ack_only_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [NUM_HARTS-1:0]   snoop_rsp_ready_o,

    // Coherent L1I Channels (COH_GETS_NC + Coherent L1I Line Inval Broadcast)
    input  logic [NUM_HARTS-1:0]   l1i_rd_req_valid_i,
    input  logic [49:0]            l1i_rd_req_addr_i     [NUM_HARTS],
    input  logic [1:0]             l1i_rd_req_tag_i      [NUM_HARTS],
    output logic [NUM_HARTS-1:0]   l1i_rd_req_ready_o,

    output logic [NUM_HARTS-1:0]   l1i_rd_rsp_valid_o,
    output logic [1:0]             l1i_rd_rsp_tag_o      [NUM_HARTS],
    output logic [511:0]           l1i_rd_rsp_data_o     [NUM_HARTS],
    output logic [NUM_HARTS-1:0]   l1i_rd_rsp_error_o,

    output logic                   l1i_inval_valid_o,
    output logic [49:0]            l1i_inval_addr_o,

    // Coherent PTW Channels (COH_GETS_NC)
    input  logic [NUM_HARTS-1:0]   ptw_rd_req_valid_i,
    input  logic [49:0]            ptw_rd_req_addr_i     [NUM_HARTS],
    output logic [NUM_HARTS-1:0]   ptw_rd_req_ready_o,

    output logic [NUM_HARTS-1:0]   ptw_rd_rsp_valid_o,
    output logic [511:0]           ptw_rd_rsp_data_o     [NUM_HARTS],
    output logic [NUM_HARTS-1:0]   ptw_rd_rsp_error_o,

    // External DRAM Backing Store Channel
    output logic                   dram_req_valid_o,
    input  logic                   dram_req_ready_i,
    output logic                   dram_req_write_o,
    output logic [49:0]            dram_req_addr_o,
    output logic [511:0]           dram_req_wdata_o,
    output logic [2:0]             dram_req_mid_o,
    output logic [1:0]             dram_req_tag_o,

    input  logic                   dram_rd_rsp_valid_i,
    output logic                   dram_rd_rsp_ready_o,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [2:0]             dram_rd_rsp_mid_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [1:0]             dram_rd_rsp_tag_i,
    input  logic [511:0]           dram_rd_rsp_data_i,
    input  logic                   dram_rd_rsp_error_i,

    input  logic                   dram_wr_rsp_valid_i
);

    localparam logic [1:0] DIR_I = 2'd0;
    localparam logic [1:0] DIR_S = 2'd1;
    localparam logic [1:0] DIR_E = 2'd2;
    localparam logic [1:0] DIR_M = 2'd3;

    typedef enum logic [1:0] {
        SRC_L1D_RD = 2'd0,
        SRC_L1D_WR = 2'd1,
        SRC_L1I_RD = 2'd2,
        SRC_PTW_RD = 2'd3
    } req_src_t;

    typedef enum logic [2:0] {
        DMSHR_IDLE         = 3'd0,
        DMSHR_VIC_SNOOP    = 3'd1,
        DMSHR_VIC_WB       = 3'd2,
        DMSHR_VIC_WB_WAIT  = 3'd3,
        DMSHR_DRAM_RD      = 3'd4,
        DMSHR_DRAM_RD_WAIT = 3'd5,
        DMSHR_LINE_SNOOP   = 3'd6,
        DMSHR_GRANT        = 3'd7
    } dir_mshr_state_t;

    typedef struct packed {
        logic                   valid;
        dir_mshr_state_t        state;
        req_src_t               req_src;
        logic [HART_W-1:0]      req_hart;
        logic [1:0]             req_tag;
        coh_req_op_t            req_op;
        logic                   grant_has_data;
        logic [49:0]            line_addr;
        logic [WAY_W-1:0]       l2_way;
        logic                   way_pinned;
        logic                   line_dirty;
        logic [511:0]           line_data;
        logic                   rd_error;
        logic [1:0]             cur_dir_state;
        logic [NUM_HARTS-1:0]   cur_sharers;
        logic [HART_W-1:0]      cur_owner;
        // Victim back-invalidation / writeback state (for L2 miss)
        logic                   victim_active;
        logic                   victim_dirty;
        logic [49:0]            victim_addr;
        logic [511:0]           victim_data;
        // Snoop coordination masks
        logic [1:0]             snoop_op;
        logic [NUM_HARTS-1:0]   snoop_to_send;
        logic [NUM_HARTS-1:0]   snoop_wait_mask;
    } dir_mshr_entry_t;

    dir_mshr_entry_t dir_mshr_q [DIR_MSHR_DEPTH];

    // Per-hart VC1/VC2 snoop engine state
    typedef struct packed {
        logic              active;
        logic              sent;
        logic [MSHR_W-1:0] mshr_id;
        logic              is_victim;
        logic [49:0]       addr;
        logic [1:0]        op;
    } snoop_ch_t;

    snoop_ch_t snoop_ch_q [NUM_HARTS];

    // Stage C1 register (holds 1 accepted VC0 transaction for L2 lookup/decode)
    logic              c1_valid_q;
    req_src_t          c1_src_q;
    logic [HART_W-1:0] c1_hart_q;
    logic [1:0]        c1_tag_q;
    coh_req_op_t       c1_op_q;
    logic [49:0]       c1_addr_q;
    logic [511:0]      c1_wdata_q;

    // Stage C2 pipeline registers (L2 lookup results -> fast-path VC2 / MSHR alloc)
    logic                   c2_valid_q;
    req_src_t               c2_src_q;
    logic [HART_W-1:0]      c2_hart_q;
    logic [1:0]             c2_tag_q;
    coh_req_op_t            c2_eff_op_q;
    logic [49:0]            c2_addr_q;
    logic [511:0]           c2_wdata_q;
    logic                   c2_l2_hit_q;
    logic [WAY_W-1:0]       c2_l2_way_q;
    logic                   c2_hit_dirty_q;
    logic [1:0]             c2_hit_dir_state_q;
    logic [NUM_HARTS-1:0]   c2_hit_sharers_q;
    logic [HART_W-1:0]      c2_hit_owner_q;
    logic [511:0]           c2_hit_data_q;
    logic                   c2_vic_dirty_q;
    logic [49:0]            c2_vic_addr_q;
    logic [511:0]           c2_vic_data_q;
    logic                   c2_fast_done_q;
    logic                   c2_fast_grant_rd_q;
    logic                   c2_fast_put_ack_q;
    mesi_state_t            c2_fast_grant_state_q;
    logic                   c2_fast_grant_has_data_q;
    logic                   c2_fast_l1i_inval_q;
    logic                   c2_alloc_mshr_q;
    dir_mshr_state_t        c2_alloc_state_q;
    logic                   c2_alloc_grant_has_data_q;
    logic                   c2_vic_active_q;
    logic [1:0]             c2_snoop_op_q;
    logic [NUM_HARTS-1:0]   c2_snoop_mask_q;
    logic                   c2_upd0_en_q;
    logic                   c2_upd0_valid_q;
    logic                   c2_upd0_data_en_q;
    logic                   c2_upd0_dirty_q;
    logic [1:0]             c2_upd0_dir_state_q;
    logic [NUM_HARTS-1:0]   c2_upd0_sharers_q;
    logic [HART_W-1:0]      c2_upd0_owner_q;
    logic                   c2_upd0_plru_en_q;

    // Stage C0 RR pointers
    logic [HART_W-1:0] c0_wr_rr_q;
    logic [HART_W-1:0] c0_rd_rr_q;
    logic [1:0]        c0_rd_cls_rr_q; // 0=L1D, 1=L1I, 2=PTW

    // Global DRAM single-write tracker (serializes L2 dirty victim writebacks)
    logic              dram_wr_busy_q;
    logic [49:0]       dram_wr_addr_q;

    // L2 arrays lookup / update wires
    logic [L2_WAYS-1:0]     l2_pinned_ways;
    logic                   l2_lu_hit;
    logic [WAY_W-1:0]       l2_lu_hit_way;
    logic                   l2_lu_hit_dirty;
    logic [1:0]             l2_lu_hit_dir_state;
    logic [NUM_HARTS-1:0]   l2_lu_hit_sharers;
    logic [HART_W-1:0]      l2_lu_hit_owner;
    logic [511:0]           l2_lu_hit_data;
    logic [WAY_W-1:0]       l2_lu_vic_way;
    logic                   l2_lu_vic_valid;
    logic                   l2_lu_vic_dirty;
    logic [49:0]            l2_lu_vic_addr;
    logic [1:0]             l2_lu_vic_dir_state;
    logic [NUM_HARTS-1:0]   l2_lu_vic_sharers;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [HART_W-1:0]      l2_lu_vic_owner;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [511:0]           l2_lu_vic_data;

    logic                   l2_upd0_en, l2_upd0_valid, l2_upd0_tag_en, l2_upd0_data_en, l2_upd0_dirty, l2_upd0_plru_en;
    logic [SET_W-1:0]       l2_upd0_set;
    logic [WAY_W-1:0]       l2_upd0_way;
    logic [TAG_W-1:0]       l2_upd0_tag;
    logic [511:0]           l2_upd0_data;
    logic [1:0]             l2_upd0_dir_state;
    logic [NUM_HARTS-1:0]   l2_upd0_sharers;
    logic [HART_W-1:0]      l2_upd0_owner;

    logic                   l2_upd1_en, l2_upd1_valid, l2_upd1_tag_en, l2_upd1_data_en, l2_upd1_dirty, l2_upd1_plru_en;
    logic [SET_W-1:0]       l2_upd1_set;
    logic [WAY_W-1:0]       l2_upd1_way;
    logic [TAG_W-1:0]       l2_upd1_tag;
    logic [511:0]           l2_upd1_data;
    logic [1:0]             l2_upd1_dir_state;
    logic [NUM_HARTS-1:0]   l2_upd1_sharers;
    logic [HART_W-1:0]      l2_upd1_owner;

    fursoy_s2_l2 #(
        .NUM_HARTS (NUM_HARTS),
        .L2_SETS   (L2_SETS),
        .L2_WAYS   (L2_WAYS)
    ) u_l2 (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .lu_addr_i          (c1_addr_q),
        .lu_pinned_ways_i   (l2_pinned_ways),
        .lu_hit_o           (l2_lu_hit),
        .lu_hit_way_o       (l2_lu_hit_way),
        .lu_hit_dirty_o     (l2_lu_hit_dirty),
        .lu_hit_dir_state_o (l2_lu_hit_dir_state),
        .lu_hit_sharers_o   (l2_lu_hit_sharers),
        .lu_hit_owner_o     (l2_lu_hit_owner),
        .lu_hit_data_o      (l2_lu_hit_data),
        .lu_vic_way_o       (l2_lu_vic_way),
        .lu_vic_valid_o     (l2_lu_vic_valid),
        .lu_vic_dirty_o     (l2_lu_vic_dirty),
        .lu_vic_addr_o      (l2_lu_vic_addr),
        .lu_vic_dir_state_o (l2_lu_vic_dir_state),
        .lu_vic_sharers_o   (l2_lu_vic_sharers),
        .lu_vic_owner_o     (l2_lu_vic_owner),
        .lu_vic_data_o      (l2_lu_vic_data),

        .upd0_en_i          (l2_upd0_en),
        .upd0_set_i         (l2_upd0_set),
        .upd0_way_i         (l2_upd0_way),
        .upd0_valid_i       (l2_upd0_valid),
        .upd0_tag_en_i      (l2_upd0_tag_en),
        .upd0_tag_i         (l2_upd0_tag),
        .upd0_data_en_i     (l2_upd0_data_en),
        .upd0_data_i        (l2_upd0_data),
        .upd0_dirty_i       (l2_upd0_dirty),
        .upd0_dir_state_i   (l2_upd0_dir_state),
        .upd0_sharers_i     (l2_upd0_sharers),
        .upd0_owner_i       (l2_upd0_owner),
        .upd0_plru_en_i     (l2_upd0_plru_en),

        .upd1_en_i          (l2_upd1_en),
        .upd1_set_i         (l2_upd1_set),
        .upd1_way_i         (l2_upd1_way),
        .upd1_valid_i       (l2_upd1_valid),
        .upd1_tag_en_i      (l2_upd1_tag_en),
        .upd1_tag_i         (l2_upd1_tag),
        .upd1_data_en_i     (l2_upd1_data_en),
        .upd1_data_i        (l2_upd1_data),
        .upd1_dirty_i       (l2_upd1_dirty),
        .upd1_dir_state_i   (l2_upd1_dir_state),
        .upd1_sharers_i     (l2_upd1_sharers),
        .upd1_owner_i       (l2_upd1_owner),
        .upd1_plru_en_i     (l2_upd1_plru_en)
    );

    // =========================================================================
    // Helper Functions: DIR_MSHR Hazard Check & Allocator
    // =========================================================================
    function automatic logic addr_has_hazard(input logic [49:0] addr);
        if (c1_valid_q && (c1_addr_q[SET_W-1:0] == addr[SET_W-1:0])) begin
            return 1'b1;
        end
        if (c2_valid_q && ((c2_addr_q[SET_W-1:0] == addr[SET_W-1:0]) ||
                           (c2_vic_active_q && (c2_vic_addr_q == addr)))) begin
            return 1'b1;
        end
        for (int m = 0; m < DIR_MSHR_DEPTH; m++) begin
            if (dir_mshr_q[m].valid) begin
                if (dir_mshr_q[m].line_addr == addr) return 1'b1;
                if (dir_mshr_q[m].victim_active && (dir_mshr_q[m].victim_addr == addr)) return 1'b1;
            end
        end
        return 1'b0;
    endfunction

    logic              free_mshr_found;
    logic [MSHR_W-1:0] free_mshr_idx;
    logic [3:0]        free_mshr_count;
    logic              any_dmshr_grant;

    always_comb begin
        free_mshr_found = 1'b0;
        free_mshr_idx   = '0;
        free_mshr_count = 4'd0;
        any_dmshr_grant = 1'b0;
        for (int m = 0; m < DIR_MSHR_DEPTH; m++) begin
            if (!dir_mshr_q[m].valid) begin
                free_mshr_count = free_mshr_count + 4'd1;
                if (!free_mshr_found) begin
                    free_mshr_found = 1'b1;
                    free_mshr_idx   = MSHR_W'(m);
                end
            end
            if (dir_mshr_q[m].valid && (dir_mshr_q[m].state == DMSHR_GRANT)) begin
                any_dmshr_grant = 1'b1;
            end
        end

        l2_pinned_ways = '0;
        for (int m = 0; m < DIR_MSHR_DEPTH; m++) begin
            if (dir_mshr_q[m].valid && dir_mshr_q[m].way_pinned &&
                (dir_mshr_q[m].line_addr[SET_W-1:0] == c1_addr_q[SET_W-1:0])) begin
                for (int w = 0; w < L2_WAYS; w++) begin
                    if (dir_mshr_q[m].l2_way == WAY_W'(w)) l2_pinned_ways[w] = 1'b1;
                end
            end
        end
    end

    // Reserve MSHR slots for requests already in C1 / C2 before admitting new VC0_RD
    wire [3:0] inflight_rd_stages = ((c1_valid_q && (c1_src_q != SRC_L1D_WR)) ? 4'd1 : 4'd0) +
                                    ((c2_valid_q && c2_alloc_mshr_q) ? 4'd1 : 4'd0);
    wire       c0_rd_mshr_avail   = free_mshr_found && (free_mshr_count > inflight_rd_stages);

    // =========================================================================
    // Stage C0: Parallel Per-Requester Hazard Filter & Priority/RR Arbitration
    // =========================================================================
    logic                   c0_grant_valid;
    req_src_t               c0_grant_src;
    logic [HART_W-1:0]      c0_grant_hart;
    logic [1:0]             c0_grant_tag;
    coh_req_op_t            c0_grant_op;
    logic [49:0]            c0_grant_addr;
    logic [511:0]           c0_grant_wdata;

    function automatic logic [HART_W-1:0] wrap_hart(
        input logic [HART_W-1:0] base,
        input logic [HART_W:0]   inc
    );
        logic [HART_W:0] sum;
        sum = {1'b0, base} + inc;
        if (sum >= (HART_W+1)'(NUM_HARTS))
            return HART_W'(sum - (HART_W+1)'(NUM_HARTS));
        else
            return HART_W'(sum);
    endfunction

    function automatic logic [1:0] wrap_cls3(
        input logic [1:0] base,
        input logic [1:0] inc
    );
        logic [2:0] sum3;
        sum3 = {1'b0, base} + {1'b0, inc};
        if (sum3 >= 3'd3)
            return 2'(sum3 - 3'd3);
        else
            return 2'(sum3);
    endfunction

    always_comb begin
        logic [NUM_HARTS-1:0] wr_elig;
        logic [NUM_HARTS-1:0] l1d_rd_elig;
        logic [NUM_HARTS-1:0] l1i_rd_elig;
        logic [NUM_HARTS-1:0] ptw_rd_elig;
        logic                 wr_win_valid;
        logic [HART_W-1:0]    wr_win_hart;
        logic [2:0]           cls_win_valid;
        logic [HART_W-1:0]    cls_win_hart [3];
        logic                 rd_win_valid;
        logic [1:0]           rd_win_cls;
        logic [HART_W-1:0]    rd_win_hart;
        logic [HART_W-1:0]    cand_h;
        logic [1:0]           cand_cls;

        c0_grant_valid = 1'b0;
        c0_grant_src   = SRC_L1D_RD;
        c0_grant_hart  = '0;
        c0_grant_tag   = 2'd0;
        c0_grant_op    = COH_GETS;
        c0_grant_addr  = 50'd0;
        c0_grant_wdata = 512'd0;
        wr_win_valid   = 1'b0;
        wr_win_hart    = '0;
        cls_win_valid  = 3'b000;
        for (int c = 0; c < 3; c++)
            cls_win_hart[c] = '0;
        rd_win_valid   = 1'b0;
        rd_win_cls     = 2'd0;
        rd_win_hart    = '0;
        cand_h         = '0;
        cand_cls       = 2'd0;

        for (int h = 0; h < NUM_HARTS; h++) begin
            wr_elig[h]     = l1d_wr_req_valid_i[h] && !addr_has_hazard(l1d_wr_req_addr_i[h]);
            l1d_rd_elig[h] = l1d_rd_req_valid_i[h] && !addr_has_hazard(l1d_rd_req_addr_i[h]);
            l1i_rd_elig[h] = l1i_rd_req_valid_i[h] && !addr_has_hazard(l1i_rd_req_addr_i[h]);
            ptw_rd_elig[h] = ptw_rd_req_valid_i[h] && !addr_has_hazard(ptw_rd_req_addr_i[h]);
        end

        for (int off = 0; off < NUM_HARTS; off++) begin
            cand_h = wrap_hart(c0_wr_rr_q, (HART_W+1)'(off));
            if (!wr_win_valid && wr_elig[cand_h]) begin
                wr_win_valid = 1'b1;
                wr_win_hart  = cand_h;
            end
            cand_h = wrap_hart(c0_rd_rr_q, (HART_W+1)'(off));
            if (!cls_win_valid[0] && l1d_rd_elig[cand_h]) begin
                cls_win_valid[0] = 1'b1;
                cls_win_hart[0]  = cand_h;
            end
            if (!cls_win_valid[1] && l1i_rd_elig[cand_h]) begin
                cls_win_valid[1] = 1'b1;
                cls_win_hart[1]  = cand_h;
            end
            if (!cls_win_valid[2] && ptw_rd_elig[cand_h]) begin
                cls_win_valid[2] = 1'b1;
                cls_win_hart[2]  = cand_h;
            end
        end

        for (int c_off = 0; c_off < 3; c_off++) begin
            cand_cls = wrap_cls3(c0_rd_cls_rr_q, 2'(c_off));
            if (!rd_win_valid && cls_win_valid[cand_cls]) begin
                rd_win_valid = 1'b1;
                rd_win_cls   = cand_cls;
                rd_win_hart  = cls_win_hart[cand_cls];
            end
        end

        // Defer C0 admission only while a DIR_MSHR is committing DMSHR_GRANT
        if (!any_dmshr_grant) begin
            // Strict VC0_WR (PutM) priority over VC0_RD
            if (wr_win_valid) begin
                c0_grant_valid = 1'b1;
                c0_grant_src   = SRC_L1D_WR;
                c0_grant_hart  = wr_win_hart;
                c0_grant_tag   = 2'd0;
                c0_grant_op    = COH_GETM;
                c0_grant_addr  = l1d_wr_req_addr_i[wr_win_hart];
                c0_grant_wdata = l1d_wr_req_data_i[wr_win_hart];
            end else if (c0_rd_mshr_avail && rd_win_valid) begin
                // VC0_RD requires enough free DIR_MSHR slots covering C1/C2 in-flight reads
                c0_grant_valid = 1'b1;
                c0_grant_hart  = rd_win_hart;
                if (rd_win_cls == 2'd0) begin
                    c0_grant_src  = SRC_L1D_RD;
                    c0_grant_tag  = l1d_rd_req_tag_i[rd_win_hart];
                    c0_grant_op   = l1d_rd_req_op_i[rd_win_hart];
                    c0_grant_addr = l1d_rd_req_addr_i[rd_win_hart];
                end else if (rd_win_cls == 2'd1) begin
                    c0_grant_src  = SRC_L1I_RD;
                    c0_grant_tag  = l1i_rd_req_tag_i[rd_win_hart];
                    c0_grant_op   = COH_GETS_NC;
                    c0_grant_addr = l1i_rd_req_addr_i[rd_win_hart];
                end else begin
                    c0_grant_src  = SRC_PTW_RD;
                    c0_grant_tag  = 2'd0;
                    c0_grant_op   = COH_GETS_NC;
                    c0_grant_addr = ptw_rd_req_addr_i[rd_win_hart];
                end
            end
        end

        for (int h = 0; h < NUM_HARTS; h++) begin
            l1d_wr_req_ready_o[h] = c0_grant_valid && (c0_grant_src == SRC_L1D_WR) && (c0_grant_hart == HART_W'(h));
            l1d_rd_req_ready_o[h] = c0_grant_valid && (c0_grant_src == SRC_L1D_RD) && (c0_grant_hart == HART_W'(h));
            l1i_rd_req_ready_o[h] = c0_grant_valid && (c0_grant_src == SRC_L1I_RD) && (c0_grant_hart == HART_W'(h));
            ptw_rd_req_ready_o[h] = c0_grant_valid && (c0_grant_src == SRC_PTW_RD) && (c0_grant_hart == HART_W'(h));
        end
    end

    // =========================================================================
    // Stage C1: L2 Lookup Decode (registered into Stage C2 before VC2/L2 upd0)
    // =========================================================================
    logic                   c1_fast_done;
    logic                   c1_fast_grant_rd;
    logic                   c1_fast_put_ack;
    mesi_state_t            c1_fast_grant_state;
    logic                   c1_fast_grant_has_data;
    logic                   c1_fast_l1i_inval;
    logic                   c1_alloc_mshr;
    dir_mshr_state_t        c1_alloc_state;
    coh_req_op_t            c1_eff_op;
    logic                   c1_alloc_grant_has_data;
    logic                   c1_alloc_vic_active;
    logic [1:0]             c1_alloc_snoop_op;
    logic [NUM_HARTS-1:0]   c1_alloc_snoop_mask;
    logic                   c1_upd0_en;
    logic                   c1_upd0_valid;
    logic                   c1_upd0_data_en;
    logic                   c1_upd0_dirty;
    logic [1:0]             c1_upd0_dir_state;
    logic [NUM_HARTS-1:0]   c1_upd0_sharers;
    logic [HART_W-1:0]      c1_upd0_owner;
    logic                   c1_upd0_plru_en;

    always_comb begin
        logic [NUM_HARTS-1:0] hart_bit;
        logic [NUM_HARTS-1:0] sv_others;
        logic                 owner_is_self;
        logic                 no_other_sharers;
        logic                 need_data;

        hart_bit         = (NUM_HARTS'(1) << c1_hart_q);
        sv_others        = l2_lu_hit_sharers & ~hart_bit;
        owner_is_self    = (l2_lu_hit_owner == c1_hart_q) && l2_lu_hit_sharers[c1_hart_q];
        no_other_sharers = (sv_others == '0);
        need_data        = 1'b0;

        c1_fast_done            = 1'b0;
        c1_fast_grant_rd        = 1'b0;
        c1_fast_put_ack         = 1'b0;
        c1_fast_grant_state     = MESI_S;
        c1_fast_grant_has_data  = 1'b1;
        c1_fast_l1i_inval       = 1'b0;
        c1_alloc_mshr           = 1'b0;
        c1_alloc_state          = DMSHR_IDLE;
        c1_eff_op               = c1_op_q;
        c1_alloc_grant_has_data = 1'b1;
        c1_alloc_vic_active     = 1'b0;
        c1_alloc_snoop_op       = SNOOP_INV;
        c1_alloc_snoop_mask     = '0;

        c1_upd0_en        = 1'b0;
        c1_upd0_valid     = 1'b1;
        c1_upd0_data_en   = 1'b0;
        c1_upd0_dirty     = l2_lu_hit_dirty;
        c1_upd0_dir_state = l2_lu_hit_dir_state;
        c1_upd0_sharers   = l2_lu_hit_sharers;
        c1_upd0_owner     = l2_lu_hit_owner;
        c1_upd0_plru_en   = 1'b0;

        if (c1_valid_q) begin
            if (c1_src_q == SRC_L1D_WR) begin
                c1_fast_done    = 1'b1;
                c1_fast_put_ack = 1'b1;
                if (l2_lu_hit &&
                    ((l2_lu_hit_dir_state == DIR_M) || (l2_lu_hit_dir_state == DIR_E)) &&
                    owner_is_self) begin
                    c1_upd0_en        = 1'b1;
                    c1_upd0_valid     = 1'b1;
                    c1_upd0_data_en   = 1'b1;
                    c1_upd0_dirty     = 1'b1;
                    c1_upd0_dir_state = DIR_I;
                    c1_upd0_sharers   = '0;
                    c1_upd0_owner     = '0;
                    c1_upd0_plru_en   = 1'b1;
                    c1_fast_l1i_inval = 1'b1;
                end
                // Late PutM (ownership already moved via SnoopRsp): no-op PutAck
            end else if (l2_lu_hit) begin
                if (c1_op_q == COH_GETS_NC) begin
                    if ((l2_lu_hit_dir_state == DIR_I) || (l2_lu_hit_dir_state == DIR_S)) begin
                        c1_fast_done           = 1'b1;
                        c1_fast_grant_rd       = 1'b1;
                        c1_fast_grant_state    = MESI_S;
                        c1_fast_grant_has_data = 1'b1;
                        c1_upd0_en             = 1'b1;
                        c1_upd0_plru_en        = 1'b1;
                    end else begin
                        c1_alloc_mshr           = 1'b1;
                        c1_alloc_state          = DMSHR_LINE_SNOOP;
                        c1_alloc_grant_has_data = 1'b1;
                        c1_alloc_snoop_op       = SNOOP_GETS;
                        c1_alloc_snoop_mask     = (NUM_HARTS'(1) << l2_lu_hit_owner);
                    end
                end else if (c1_op_q == COH_GETS) begin
                    if (l2_lu_hit_dir_state == DIR_I) begin
                        c1_fast_done           = 1'b1;
                        c1_fast_grant_rd       = 1'b1;
                        c1_fast_grant_state    = MESI_E;
                        c1_fast_grant_has_data = 1'b1;
                        c1_upd0_en             = 1'b1;
                        c1_upd0_dir_state      = DIR_E;
                        c1_upd0_sharers        = hart_bit;
                        c1_upd0_owner          = c1_hart_q;
                        c1_upd0_plru_en        = 1'b1;
                    end else if (l2_lu_hit_dir_state == DIR_S) begin
                        c1_fast_done           = 1'b1;
                        c1_fast_grant_rd       = 1'b1;
                        c1_fast_grant_state    = MESI_S;
                        c1_fast_grant_has_data = 1'b1;
                        c1_upd0_en             = 1'b1;
                        c1_upd0_dir_state      = DIR_S;
                        c1_upd0_sharers        = l2_lu_hit_sharers | hart_bit;
                        c1_upd0_plru_en        = 1'b1;
                    end else if (l2_lu_hit_owner == c1_hart_q) begin
                        // Previous silent E eviction by same hart
                        c1_fast_done           = 1'b1;
                        c1_fast_grant_rd       = 1'b1;
                        c1_fast_grant_state    = MESI_E;
                        c1_fast_grant_has_data = 1'b1;
                        c1_upd0_en             = 1'b1;
                        c1_upd0_dir_state      = DIR_E;
                        c1_upd0_sharers        = hart_bit;
                        c1_upd0_owner          = c1_hart_q;
                        c1_upd0_plru_en        = 1'b1;
                    end else begin
                        c1_alloc_mshr           = 1'b1;
                        c1_alloc_state          = DMSHR_LINE_SNOOP;
                        c1_alloc_grant_has_data = 1'b1;
                        c1_alloc_snoop_op       = SNOOP_GETS;
                        c1_alloc_snoop_mask     = (NUM_HARTS'(1) << l2_lu_hit_owner);
                    end
                end else begin
                    // COH_GETM or COH_UPGRADE
                    need_data = (c1_op_q == COH_GETM) || !l2_lu_hit_sharers[c1_hart_q];
                    c1_eff_op = need_data ? COH_GETM : COH_UPGRADE;

                    if ((l2_lu_hit_dir_state == DIR_I) ||
                        ((l2_lu_hit_dir_state == DIR_S) && no_other_sharers) ||
                        (((l2_lu_hit_dir_state == DIR_M) || (l2_lu_hit_dir_state == DIR_E)) && (l2_lu_hit_owner == c1_hart_q))) begin
                        c1_fast_done           = 1'b1;
                        c1_fast_grant_rd       = 1'b1;
                        c1_fast_grant_state    = MESI_M;
                        c1_fast_grant_has_data = need_data;
                        c1_fast_l1i_inval      = 1'b1;
                        c1_upd0_en             = 1'b1;
                        c1_upd0_dir_state      = DIR_M;
                        c1_upd0_sharers        = hart_bit;
                        c1_upd0_owner          = c1_hart_q;
                        c1_upd0_plru_en        = 1'b1;
                    end else if (l2_lu_hit_dir_state == DIR_S) begin
                        c1_alloc_mshr           = 1'b1;
                        c1_alloc_state          = DMSHR_LINE_SNOOP;
                        c1_alloc_grant_has_data = need_data;
                        c1_alloc_snoop_op       = SNOOP_INV;
                        c1_alloc_snoop_mask     = sv_others;
                    end else begin
                        c1_alloc_mshr           = 1'b1;
                        c1_alloc_state          = DMSHR_LINE_SNOOP;
                        c1_alloc_grant_has_data = 1'b1;
                        c1_alloc_snoop_op       = SNOOP_GETM;
                        c1_alloc_snoop_mask     = (NUM_HARTS'(1) << l2_lu_hit_owner);
                    end
                end
            end else begin
                // L2 Miss: Pin victim way (invalidate in L2 in C2; evict/back-inval if needed)
                c1_alloc_mshr           = 1'b1;
                c1_alloc_grant_has_data = 1'b1;
                c1_eff_op               = (c1_op_q == COH_UPGRADE) ? COH_GETM : c1_op_q;

                if (l2_lu_vic_valid) begin
                    c1_upd0_en        = 1'b1;
                    c1_upd0_valid     = 1'b0;
                    c1_upd0_dirty     = 1'b0;
                    c1_upd0_dir_state = DIR_I;
                    c1_upd0_sharers   = '0;
                    c1_upd0_owner     = '0;
                end

                if (l2_lu_vic_valid && (l2_lu_vic_sharers != '0)) begin
                    c1_alloc_state      = DMSHR_VIC_SNOOP;
                    c1_alloc_vic_active = 1'b1;
                    c1_alloc_snoop_op   = ((l2_lu_vic_dir_state == DIR_M) || (l2_lu_vic_dir_state == DIR_E)) ? SNOOP_GETM : SNOOP_INV;
                    c1_alloc_snoop_mask = l2_lu_vic_sharers;
                end else if (l2_lu_vic_valid && l2_lu_vic_dirty) begin
                    c1_alloc_state      = DMSHR_VIC_WB;
                    c1_alloc_vic_active = 1'b1;
                end else begin
                    c1_alloc_state      = DMSHR_DRAM_RD;
                    c1_alloc_vic_active = 1'b0;
                end
            end
        end
    end

    // Drive L2 write port 0 cleanly from Stage C2 flops (no L2_read -> L2_write path)
    assign l2_upd0_en        = c2_valid_q && c2_upd0_en_q;
    assign l2_upd0_set       = c2_addr_q[SET_W-1:0];
    assign l2_upd0_way       = c2_l2_way_q;
    assign l2_upd0_valid     = c2_upd0_valid_q;
    assign l2_upd0_tag_en    = 1'b0;
    assign l2_upd0_tag       = c2_addr_q[49:SET_W];
    assign l2_upd0_data_en   = c2_upd0_data_en_q;
    assign l2_upd0_data      = c2_wdata_q;
    assign l2_upd0_dirty     = c2_upd0_dirty_q;
    assign l2_upd0_dir_state = c2_upd0_dir_state_q;
    assign l2_upd0_sharers   = c2_upd0_sharers_q;
    assign l2_upd0_owner     = c2_upd0_owner_q;
    assign l2_upd0_plru_en   = c2_upd0_plru_en_q;

    // =========================================================================
    // DIR_MSHR Slow-Path Grant Arbitration & Stage C2 Output Driving
    // =========================================================================
    logic              grant_mshr_found;
    logic [MSHR_W-1:0] grant_mshr_idx;

    always_comb begin
        grant_mshr_found = 1'b0;
        grant_mshr_idx   = '0;
        // Stage C2 fast path wins over DMSHR_GRANT if both active in same cycle
        if (!(c2_valid_q && c2_fast_done_q)) begin
            for (int m = 0; m < DIR_MSHR_DEPTH; m++) begin
                if (!grant_mshr_found && dir_mshr_q[m].valid && (dir_mshr_q[m].state == DMSHR_GRANT)) begin
                    grant_mshr_found = 1'b1;
                    grant_mshr_idx   = MSHR_W'(m);
                end
            end
        end
    end

    // Drive L2 upd1 on DMSHR_GRANT
    always_comb begin
        l2_upd1_en        = 1'b0;
        l2_upd1_set       = dir_mshr_q[grant_mshr_idx].line_addr[SET_W-1:0];
        l2_upd1_way       = dir_mshr_q[grant_mshr_idx].l2_way;
        l2_upd1_valid     = !dir_mshr_q[grant_mshr_idx].rd_error;
        l2_upd1_tag_en    = 1'b1;
        l2_upd1_tag       = dir_mshr_q[grant_mshr_idx].line_addr[49:SET_W];
        l2_upd1_data_en   = 1'b1;
        l2_upd1_data      = dir_mshr_q[grant_mshr_idx].line_data;
        l2_upd1_dirty     = dir_mshr_q[grant_mshr_idx].line_dirty;
        l2_upd1_dir_state = dir_mshr_q[grant_mshr_idx].cur_dir_state;
        l2_upd1_sharers   = dir_mshr_q[grant_mshr_idx].cur_sharers;
        l2_upd1_owner     = dir_mshr_q[grant_mshr_idx].cur_owner;
        l2_upd1_plru_en   = !dir_mshr_q[grant_mshr_idx].rd_error;

        if (grant_mshr_found) begin
            l2_upd1_en = 1'b1;
            if (dir_mshr_q[grant_mshr_idx].req_op == COH_GETS_NC) begin
                l2_upd1_dir_state = (dir_mshr_q[grant_mshr_idx].cur_sharers != '0) ? DIR_S : DIR_I;
                l2_upd1_owner     = '0;
            end else if (dir_mshr_q[grant_mshr_idx].req_op == COH_GETS) begin
                if (dir_mshr_q[grant_mshr_idx].cur_sharers != '0) begin
                    l2_upd1_dir_state = DIR_S;
                    l2_upd1_sharers   = dir_mshr_q[grant_mshr_idx].cur_sharers |
                                        (NUM_HARTS'(1) << dir_mshr_q[grant_mshr_idx].req_hart);
                    l2_upd1_owner     = '0;
                end else begin
                    l2_upd1_dir_state = DIR_E;
                    l2_upd1_sharers   = (NUM_HARTS'(1) << dir_mshr_q[grant_mshr_idx].req_hart);
                    l2_upd1_owner     = dir_mshr_q[grant_mshr_idx].req_hart;
                end
            end else begin
                // COH_GETM / COH_UPGRADE
                l2_upd1_dir_state = DIR_M;
                l2_upd1_sharers   = (NUM_HARTS'(1) << dir_mshr_q[grant_mshr_idx].req_hart);
                l2_upd1_owner     = dir_mshr_q[grant_mshr_idx].req_hart;
            end
        end
    end

    // Drive VC2 Grants, PutAcks, and Coherent L1I Invalidation Broadcast
    always_comb begin
        mesi_state_t gm_rsp_state;

        gm_rsp_state = (dir_mshr_q[grant_mshr_idx].req_op == COH_GETS) ?
                       ((dir_mshr_q[grant_mshr_idx].cur_sharers != '0) ? MESI_S : MESI_E) : MESI_M;

        for (int h = 0; h < NUM_HARTS; h++) begin
            l1d_rd_rsp_valid_o[h]    = 1'b0;
            l1d_rd_rsp_tag_o[h]      = 2'd0;
            l1d_rd_rsp_data_o[h]     = 512'd0;
            l1d_rd_rsp_state_o[h]    = MESI_I;
            l1d_rd_rsp_has_data_o[h] = 1'b0;
            l1d_wr_rsp_valid_o[h]    = 1'b0;

            l1i_rd_rsp_valid_o[h]    = 1'b0;
            l1i_rd_rsp_tag_o[h]      = 2'd0;
            l1i_rd_rsp_data_o[h]     = 512'd0;
            l1i_rd_rsp_error_o[h]    = 1'b0;

            ptw_rd_rsp_valid_o[h]    = 1'b0;
            ptw_rd_rsp_data_o[h]     = 512'd0;
            ptw_rd_rsp_error_o[h]    = 1'b0;
        end

        l1i_inval_valid_o = 1'b0;
        l1i_inval_addr_o  = 50'd0;

        if (c2_valid_q && c2_fast_put_ack_q) begin
            for (int h = 0; h < NUM_HARTS; h++) begin
                if (c2_hart_q == HART_W'(h)) begin
                    l1d_wr_rsp_valid_o[h] = 1'b1;
                end
            end
            if (c2_fast_l1i_inval_q) begin
                l1i_inval_valid_o = 1'b1;
                l1i_inval_addr_o  = c2_addr_q;
            end
        end else if (c2_valid_q && c2_fast_grant_rd_q) begin
            for (int h = 0; h < NUM_HARTS; h++) begin
                if (c2_hart_q == HART_W'(h)) begin
                    case (c2_src_q)
                        SRC_L1D_RD: begin
                            l1d_rd_rsp_valid_o[h]    = 1'b1;
                            l1d_rd_rsp_tag_o[h]      = c2_tag_q;
                            l1d_rd_rsp_data_o[h]     = c2_hit_data_q;
                            l1d_rd_rsp_state_o[h]    = c2_fast_grant_state_q;
                            l1d_rd_rsp_has_data_o[h] = c2_fast_grant_has_data_q;
                        end
                        SRC_L1I_RD: begin
                            l1i_rd_rsp_valid_o[h] = 1'b1;
                            l1i_rd_rsp_tag_o[h]   = c2_tag_q;
                            l1i_rd_rsp_data_o[h]  = c2_hit_data_q;
                            l1i_rd_rsp_error_o[h] = 1'b0;
                        end
                        SRC_PTW_RD: begin
                            ptw_rd_rsp_valid_o[h] = 1'b1;
                            ptw_rd_rsp_data_o[h]  = c2_hit_data_q;
                            ptw_rd_rsp_error_o[h] = 1'b0;
                        end
                        default: ;
                    endcase
                end
            end
            if ((c2_src_q == SRC_L1D_RD) && c2_fast_l1i_inval_q) begin
                l1i_inval_valid_o = 1'b1;
                l1i_inval_addr_o  = c2_addr_q;
            end
        end else if (grant_mshr_found) begin
            for (int h = 0; h < NUM_HARTS; h++) begin
                if (dir_mshr_q[grant_mshr_idx].req_hart == HART_W'(h)) begin
                    case (dir_mshr_q[grant_mshr_idx].req_src)
                        SRC_L1D_RD: begin
                            l1d_rd_rsp_valid_o[h]    = 1'b1;
                            l1d_rd_rsp_tag_o[h]      = dir_mshr_q[grant_mshr_idx].req_tag;
                            l1d_rd_rsp_data_o[h]     = dir_mshr_q[grant_mshr_idx].line_data;
                            l1d_rd_rsp_state_o[h]    = gm_rsp_state;
                            l1d_rd_rsp_has_data_o[h] = dir_mshr_q[grant_mshr_idx].grant_has_data;
                        end
                        SRC_L1I_RD: begin
                            l1i_rd_rsp_valid_o[h] = 1'b1;
                            l1i_rd_rsp_tag_o[h]   = dir_mshr_q[grant_mshr_idx].req_tag;
                            l1i_rd_rsp_data_o[h]  = dir_mshr_q[grant_mshr_idx].line_data;
                            l1i_rd_rsp_error_o[h] = dir_mshr_q[grant_mshr_idx].rd_error;
                        end
                        SRC_PTW_RD: begin
                            ptw_rd_rsp_valid_o[h] = 1'b1;
                            ptw_rd_rsp_data_o[h]  = dir_mshr_q[grant_mshr_idx].line_data;
                            ptw_rd_rsp_error_o[h] = dir_mshr_q[grant_mshr_idx].rd_error;
                        end
                        default: ;
                    endcase
                end
            end
            if ((dir_mshr_q[grant_mshr_idx].req_src == SRC_L1D_RD) &&
                ((dir_mshr_q[grant_mshr_idx].req_op == COH_GETM) ||
                 (dir_mshr_q[grant_mshr_idx].req_op == COH_UPGRADE))) begin
                l1i_inval_valid_o = 1'b1;
                l1i_inval_addr_o  = dir_mshr_q[grant_mshr_idx].line_addr;
            end
        end
    end

    // =========================================================================
    // VC1 Snoop Output & VC2 Snoop Response Ready
    // =========================================================================
    always_comb begin
        for (int h = 0; h < NUM_HARTS; h++) begin
            snoop_req_valid_o[h] = snoop_ch_q[h].active && !snoop_ch_q[h].sent;
            snoop_req_addr_o[h]  = snoop_ch_q[h].addr;
            snoop_req_type_o[h]  = snoop_ch_q[h].op;
            snoop_rsp_ready_o[h] = 1'b1; // VC2 unconditionally sinkable
        end
    end

    // =========================================================================
    // DRAM Backing Memory Request Arbitration (VIC_WB > DRAM_RD)
    // =========================================================================
    logic              dram_arb_valid;
    logic              dram_arb_write;
    logic [MSHR_W-1:0] dram_arb_mshr;

    always_comb begin
        dram_arb_valid = 1'b0;
        dram_arb_write = 1'b0;
        dram_arb_mshr  = '0;

        if (!dram_wr_busy_q) begin
            for (int m = 0; m < DIR_MSHR_DEPTH; m++) begin
                if (!dram_arb_valid && dir_mshr_q[m].valid && (dir_mshr_q[m].state == DMSHR_VIC_WB)) begin
                    dram_arb_valid = 1'b1;
                    dram_arb_write = 1'b1;
                    dram_arb_mshr  = MSHR_W'(m);
                end
            end
        end

        if (!dram_arb_valid) begin
            for (int m = 0; m < DIR_MSHR_DEPTH; m++) begin
                if (!dram_arb_valid && dir_mshr_q[m].valid && (dir_mshr_q[m].state == DMSHR_DRAM_RD) &&
                    !(dram_wr_busy_q && (dram_wr_addr_q == dir_mshr_q[m].line_addr))) begin
                    dram_arb_valid = 1'b1;
                    dram_arb_write = 1'b0;
                    dram_arb_mshr  = MSHR_W'(m);
                end
            end
        end
    end

    assign dram_req_valid_o    = dram_arb_valid;
    assign dram_req_write_o    = dram_arb_write;
    assign dram_req_addr_o     = dram_arb_write ? dir_mshr_q[dram_arb_mshr].victim_addr : dir_mshr_q[dram_arb_mshr].line_addr;
    assign dram_req_wdata_o    = dir_mshr_q[dram_arb_mshr].victim_data;
    assign dram_req_mid_o      = {2'b00, dram_arb_mshr[2]};
    assign dram_req_tag_o      = dram_arb_mshr[1:0];
    assign dram_rd_rsp_ready_o = 1'b1;

    // =========================================================================
    // Sequential Coherence Manager State Machine
    // =========================================================================
    logic [NUM_HARTS-1:0]               snoop_pick_found;
    logic [NUM_HARTS-1:0][MSHR_W-1:0]   snoop_pick_m;
    always_comb begin
        for (int h = 0; h < NUM_HARTS; h++) begin
            snoop_pick_found[h] = 1'b0;
            snoop_pick_m[h]     = '0;
            for (int m = 0; m < DIR_MSHR_DEPTH; m++) begin
                if (!snoop_pick_found[h] && dir_mshr_q[m].valid && dir_mshr_q[m].snoop_to_send[h]) begin
                    snoop_pick_found[h] = 1'b1;
                    snoop_pick_m[h]     = MSHR_W'(m);
                end
            end
        end
    end

    // Per-MSHR and per-hart snoop engines split across generate instances
    // to eliminate multi-port dynamic array muxing during synthesis.
    genvar gm, gh;
    generate
        for (gm = 0; gm < DIR_MSHR_DEPTH; gm = gm + 1) begin : gen_dmshr
            always_ff @(posedge clk_i) begin
                if (rst_i) begin
                    dir_mshr_q[gm] <= '0;
                end else begin
                    // 1. DRAM Writeback Completion
                    if (dram_req_valid_o && dram_req_ready_i && dram_req_write_o && (dram_arb_mshr == MSHR_W'(gm))) begin
                        dir_mshr_q[gm].state <= dram_wr_rsp_valid_i ? DMSHR_DRAM_RD : DMSHR_VIC_WB_WAIT;
                        if (dram_wr_rsp_valid_i) begin
                            dir_mshr_q[gm].victim_active <= 1'b0;
                        end
                    end else if (!(dram_req_valid_o && dram_req_ready_i && dram_req_write_o) &&
                                 dram_wr_busy_q && dram_wr_rsp_valid_i &&
                                 dir_mshr_q[gm].valid && (dir_mshr_q[gm].state == DMSHR_VIC_WB_WAIT)) begin
                        dir_mshr_q[gm].state         <= DMSHR_DRAM_RD;
                        dir_mshr_q[gm].victim_active <= 1'b0;
                    end

                    // 2. DRAM Read Request & Response
                    if (dram_req_valid_o && dram_req_ready_i && !dram_req_write_o && (dram_arb_mshr == MSHR_W'(gm))) begin
                        dir_mshr_q[gm].state <= DMSHR_DRAM_RD_WAIT;
                    end
                    if (dram_rd_rsp_valid_i && ({dram_rd_rsp_mid_i[0], dram_rd_rsp_tag_i} == MSHR_W'(gm)) &&
                        dir_mshr_q[gm].valid && (dir_mshr_q[gm].state == DMSHR_DRAM_RD_WAIT)) begin
                        dir_mshr_q[gm].line_data     <= dram_rd_rsp_data_i;
                        dir_mshr_q[gm].rd_error      <= dram_rd_rsp_error_i;
                        dir_mshr_q[gm].line_dirty    <= 1'b0;
                        dir_mshr_q[gm].cur_dir_state <= DIR_I;
                        dir_mshr_q[gm].cur_sharers   <= '0;
                        dir_mshr_q[gm].cur_owner     <= '0;
                        dir_mshr_q[gm].state         <= DMSHR_GRANT;
                    end

                    // 3. Per-Hart Snoop Launch Clearing & Response Capture
                    for (int h = 0; h < NUM_HARTS; h++) begin
                        if (!snoop_ch_q[h].active && snoop_pick_found[h] && (snoop_pick_m[h] == MSHR_W'(gm))) begin
                            dir_mshr_q[gm].snoop_to_send[h] <= 1'b0;
                        end else if (snoop_ch_q[h].active && snoop_ch_q[h].sent && snoop_rsp_valid_i[h] &&
                                     (snoop_ch_q[h].mshr_id == MSHR_W'(gm)) && dir_mshr_q[gm].valid) begin
                            dir_mshr_q[gm].snoop_wait_mask[h] <= 1'b0;
                            if (snoop_rsp_has_data_i[h]) begin
                                if (snoop_ch_q[h].is_victim) begin
                                    dir_mshr_q[gm].victim_data  <= snoop_rsp_data_i[h];
                                    dir_mshr_q[gm].victim_dirty <= 1'b1;
                                end else begin
                                    dir_mshr_q[gm].line_data  <= snoop_rsp_data_i[h];
                                    dir_mshr_q[gm].line_dirty <= 1'b1;
                                end
                            end
                            if (!snoop_ch_q[h].is_victim) begin
                                if (snoop_ch_q[h].op == SNOOP_GETS) begin
                                    dir_mshr_q[gm].cur_dir_state <= DIR_S;
                                end else begin
                                    dir_mshr_q[gm].cur_sharers[h] <= 1'b0;
                                end
                            end
                        end
                    end

                    // 4. Advance MSHRs Waiting on Snoops (when snoop_wait_mask drains to 0)
                    if (dir_mshr_q[gm].valid) begin
                        if ((dir_mshr_q[gm].state == DMSHR_VIC_SNOOP) && (dir_mshr_q[gm].snoop_wait_mask == '0)) begin
                            if (dir_mshr_q[gm].victim_dirty) begin
                                dir_mshr_q[gm].state <= DMSHR_VIC_WB;
                            end else begin
                                dir_mshr_q[gm].state         <= DMSHR_DRAM_RD;
                                dir_mshr_q[gm].victim_active <= 1'b0;
                            end
                        end else if ((dir_mshr_q[gm].state == DMSHR_LINE_SNOOP) && (dir_mshr_q[gm].snoop_wait_mask == '0)) begin
                            dir_mshr_q[gm].state <= DMSHR_GRANT;
                        end
                    end

                    // 5. Deallocate Retiring MSHR in DMSHR_GRANT
                    if (grant_mshr_found && (grant_mshr_idx == MSHR_W'(gm))) begin
                        dir_mshr_q[gm].valid      <= 1'b0;
                        dir_mshr_q[gm].way_pinned <= 1'b0;
                        dir_mshr_q[gm].state      <= DMSHR_IDLE;
                    end

                    // 6. Stage C2 Execution (Allocate DIR_MSHR on slow path)
                    if (c2_valid_q && c2_alloc_mshr_q && (free_mshr_idx == MSHR_W'(gm))) begin
                        dir_mshr_q[gm].valid           <= 1'b1;
                        dir_mshr_q[gm].state           <= c2_alloc_state_q;
                        dir_mshr_q[gm].req_src         <= c2_src_q;
                        dir_mshr_q[gm].req_hart        <= c2_hart_q;
                        dir_mshr_q[gm].req_tag         <= c2_tag_q;
                        dir_mshr_q[gm].req_op          <= c2_eff_op_q;
                        dir_mshr_q[gm].grant_has_data  <= c2_alloc_grant_has_data_q;
                        dir_mshr_q[gm].line_addr       <= c2_addr_q;
                        dir_mshr_q[gm].l2_way          <= c2_l2_way_q;
                        dir_mshr_q[gm].way_pinned      <= 1'b1;
                        dir_mshr_q[gm].line_dirty      <= c2_l2_hit_q ? c2_hit_dirty_q : 1'b0;
                        dir_mshr_q[gm].line_data       <= c2_l2_hit_q ? c2_hit_data_q  : 512'd0;
                        dir_mshr_q[gm].rd_error        <= 1'b0;
                        dir_mshr_q[gm].cur_dir_state   <= c2_l2_hit_q ? c2_hit_dir_state_q : DIR_I;
                        dir_mshr_q[gm].cur_sharers     <= c2_l2_hit_q ? c2_hit_sharers_q   : '0;
                        dir_mshr_q[gm].cur_owner       <= c2_l2_hit_q ? c2_hit_owner_q     : '0;
                        dir_mshr_q[gm].victim_active   <= c2_vic_active_q;
                        dir_mshr_q[gm].victim_dirty    <= c2_vic_dirty_q;
                        dir_mshr_q[gm].victim_addr     <= c2_vic_addr_q;
                        dir_mshr_q[gm].victim_data     <= c2_vic_data_q;
                        dir_mshr_q[gm].snoop_op        <= c2_snoop_op_q;
                        dir_mshr_q[gm].snoop_to_send   <= c2_snoop_mask_q;
                        dir_mshr_q[gm].snoop_wait_mask <= c2_snoop_mask_q;
                    end
                end
            end
        end

        for (gh = 0; gh < NUM_HARTS; gh = gh + 1) begin : gen_snoop_ch
            always_ff @(posedge clk_i) begin
                if (rst_i) begin
                    snoop_ch_q[gh] <= '0;
                end else if (!snoop_ch_q[gh].active) begin
                    if (snoop_pick_found[gh]) begin
                        logic [MSHR_W-1:0] pm;
                        pm = snoop_pick_m[gh];
                        snoop_ch_q[gh].active    <= 1'b1;
                        snoop_ch_q[gh].sent      <= 1'b0;
                        snoop_ch_q[gh].mshr_id   <= pm;
                        snoop_ch_q[gh].is_victim <= (dir_mshr_q[pm].state == DMSHR_VIC_SNOOP);
                        snoop_ch_q[gh].addr      <= (dir_mshr_q[pm].state == DMSHR_VIC_SNOOP) ?
                                                    dir_mshr_q[pm].victim_addr : dir_mshr_q[pm].line_addr;
                        snoop_ch_q[gh].op        <= dir_mshr_q[pm].snoop_op;
                    end
                end else if (!snoop_ch_q[gh].sent) begin
                    if (snoop_req_ready_i[gh]) begin
                        snoop_ch_q[gh].sent <= 1'b1;
                    end
                end else if (snoop_rsp_valid_i[gh]) begin
                    snoop_ch_q[gh].active <= 1'b0;
                    snoop_ch_q[gh].sent   <= 1'b0;
                end
            end
        end
    endgenerate

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            c1_valid_q                <= 1'b0;
            c1_src_q                  <= SRC_L1D_RD;
            c1_hart_q                 <= '0;
            c1_tag_q                  <= 2'd0;
            c1_op_q                   <= COH_GETS;
            c1_addr_q                 <= 50'd0;
            c1_wdata_q                <= 512'd0;
            c2_valid_q                <= 1'b0;
            c2_src_q                  <= SRC_L1D_RD;
            c2_hart_q                 <= '0;
            c2_tag_q                  <= 2'd0;
            c2_eff_op_q               <= COH_GETS;
            c2_addr_q                 <= 50'd0;
            c2_wdata_q                <= 512'd0;
            c2_l2_hit_q               <= 1'b0;
            c2_l2_way_q               <= '0;
            c2_hit_dirty_q            <= 1'b0;
            c2_hit_dir_state_q        <= DIR_I;
            c2_hit_sharers_q          <= '0;
            c2_hit_owner_q            <= '0;
            c2_hit_data_q             <= 512'd0;
            c2_vic_dirty_q            <= 1'b0;
            c2_vic_addr_q             <= 50'd0;
            c2_vic_data_q             <= 512'd0;
            c2_fast_done_q            <= 1'b0;
            c2_fast_grant_rd_q        <= 1'b0;
            c2_fast_put_ack_q         <= 1'b0;
            c2_fast_grant_state_q     <= MESI_S;
            c2_fast_grant_has_data_q  <= 1'b0;
            c2_fast_l1i_inval_q       <= 1'b0;
            c2_alloc_mshr_q           <= 1'b0;
            c2_alloc_state_q          <= DMSHR_IDLE;
            c2_alloc_grant_has_data_q <= 1'b0;
            c2_vic_active_q           <= 1'b0;
            c2_snoop_op_q             <= SNOOP_INV;
            c2_snoop_mask_q           <= '0;
            c2_upd0_en_q              <= 1'b0;
            c2_upd0_valid_q           <= 1'b0;
            c2_upd0_data_en_q         <= 1'b0;
            c2_upd0_dirty_q           <= 1'b0;
            c2_upd0_dir_state_q       <= DIR_I;
            c2_upd0_sharers_q         <= '0;
            c2_upd0_owner_q           <= '0;
            c2_upd0_plru_en_q         <= 1'b0;
            c0_wr_rr_q                <= '0;
            c0_rd_rr_q                <= '0;
            c0_rd_cls_rr_q            <= 2'd0;
            dram_wr_busy_q            <= 1'b0;
            dram_wr_addr_q            <= 50'd0;
        end else begin
            // 1. DRAM Writeback Busy Flag
            if (dram_req_valid_o && dram_req_ready_i && dram_req_write_o) begin
                if (!dram_wr_rsp_valid_i) begin
                    dram_wr_busy_q <= 1'b1;
                    dram_wr_addr_q <= dir_mshr_q[dram_arb_mshr].victim_addr;
                end
            end else if (dram_wr_busy_q && dram_wr_rsp_valid_i) begin
                dram_wr_busy_q <= 1'b0;
            end

            // Stage C1 -> Stage C2 pipeline capture
            if (c1_valid_q) begin
                c2_valid_q                <= 1'b1;
                c2_src_q                  <= c1_src_q;
                c2_hart_q                 <= c1_hart_q;
                c2_tag_q                  <= c1_tag_q;
                c2_eff_op_q               <= c1_eff_op;
                c2_addr_q                 <= c1_addr_q;
                c2_wdata_q                <= c1_wdata_q;
                c2_l2_hit_q               <= l2_lu_hit;
                c2_l2_way_q               <= l2_lu_hit ? l2_lu_hit_way : l2_lu_vic_way;
                c2_hit_dirty_q            <= l2_lu_hit_dirty;
                c2_hit_dir_state_q        <= l2_lu_hit_dir_state;
                c2_hit_sharers_q          <= l2_lu_hit_sharers;
                c2_hit_owner_q            <= l2_lu_hit_owner;
                c2_hit_data_q             <= l2_lu_hit_data;
                c2_vic_dirty_q            <= l2_lu_vic_dirty;
                c2_vic_addr_q             <= l2_lu_vic_addr;
                c2_vic_data_q             <= l2_lu_vic_data;
                c2_fast_done_q            <= c1_fast_done;
                c2_fast_grant_rd_q        <= c1_fast_grant_rd;
                c2_fast_put_ack_q         <= c1_fast_put_ack;
                c2_fast_grant_state_q     <= c1_fast_grant_state;
                c2_fast_grant_has_data_q  <= c1_fast_grant_has_data;
                c2_fast_l1i_inval_q       <= c1_fast_l1i_inval;
                c2_alloc_mshr_q           <= c1_alloc_mshr;
                c2_alloc_state_q          <= c1_alloc_state;
                c2_alloc_grant_has_data_q <= c1_alloc_grant_has_data;
                c2_vic_active_q           <= c1_alloc_vic_active;
                c2_snoop_op_q             <= c1_alloc_snoop_op;
                c2_snoop_mask_q           <= c1_alloc_snoop_mask;
                c2_upd0_en_q              <= c1_upd0_en;
                c2_upd0_valid_q           <= c1_upd0_valid;
                c2_upd0_data_en_q         <= c1_upd0_data_en;
                c2_upd0_dirty_q           <= c1_upd0_dirty;
                c2_upd0_dir_state_q       <= c1_upd0_dir_state;
                c2_upd0_sharers_q         <= c1_upd0_sharers;
                c2_upd0_owner_q           <= c1_upd0_owner;
                c2_upd0_plru_en_q         <= c1_upd0_plru_en;
            end else begin
                c2_valid_q      <= 1'b0;
                c2_fast_done_q  <= 1'b0;
                c2_alloc_mshr_q <= 1'b0;
                c2_vic_active_q <= 1'b0;
                c2_upd0_en_q    <= 1'b0;
            end

            if (c0_grant_valid) begin
                c1_valid_q <= 1'b1;
                c1_src_q   <= c0_grant_src;
                c1_hart_q  <= c0_grant_hart;
                c1_tag_q   <= c0_grant_tag;
                c1_op_q    <= c0_grant_op;
                c1_addr_q  <= c0_grant_addr;
                c1_wdata_q <= c0_grant_wdata;

                if (c0_grant_src == SRC_L1D_WR) begin
                    c0_wr_rr_q <= wrap_hart(c0_grant_hart, (HART_W+1)'(1));
                end else begin
                    c0_rd_rr_q     <= wrap_hart(c0_grant_hart, (HART_W+1)'(1));
                    c0_rd_cls_rr_q <= (c0_rd_cls_rr_q == 2'd2) ? 2'd0 : (c0_rd_cls_rr_q + 2'd1);
                end
            end else begin
                c1_valid_q <= 1'b0;
            end
        end
    end

endmodule

`endif // FURSOY_S2_COHERENCE_MGR_SV
