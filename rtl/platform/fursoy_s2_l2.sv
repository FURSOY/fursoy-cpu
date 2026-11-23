`ifndef FURSOY_S2_L2_SV
`define FURSOY_S2_L2_SV

`ifdef FURSOY_SYNTH_SRAM_BB
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
(* blackbox *)
module fursoy_s2_l2_data_sram (
    input  logic          clk_i,
    input  logic [8:0]    lu_set_i,
    output logic [4095:0] lu_set_data_o,
    input  logic          upd0_wen_i,
    input  logic [8:0]    upd0_set_i,
    input  logic [2:0]    upd0_way_i,
    input  logic [511:0]  upd0_data_i,
    input  logic          upd1_wen_i,
    input  logic [8:0]    upd1_set_i,
    input  logic [2:0]    upd1_way_i,
    input  logic [511:0]  upd1_data_i
);
endmodule
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
`endif

// =============================================================================
// Fursoy Slice-2 Inclusive Shared L2 Cache & Directory Arrays — Milestone S2-M2
// =============================================================================
// Reference: docs/architecture/slice2-smp-v1.md §2, §5
// - Geometry: 256 KiB, 8-way set-associative, 512 sets, 64 B lines.
// - PA[55:6] (50 bits) = {tag[40:0], set[8:0]}.
// - Per-way metadata: valid, l2_dirty, dir_state (DIR_I/S/E/M), sharer_vec,
//   owner_id; 7-bit Tree-PLRU per set.
// - Combinational read port for Stage C1 + dual non-conflicting write ports
//   (upd0 from Stage C1, upd1 from DIR_MSHR completion).
// =============================================================================

module fursoy_s2_l2 #(
    parameter int unsigned NUM_HARTS = 2,
    parameter int unsigned L2_SETS   = 512,
    parameter int unsigned L2_WAYS   = 8,
    localparam int unsigned SET_W    = $clog2(L2_SETS),
    localparam int unsigned TAG_W    = 50 - SET_W,
    localparam int unsigned WAY_W    = $clog2(L2_WAYS),
    localparam int unsigned HART_W   = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // Lookup Port (Stage C1)
    input  logic [49:0]            lu_addr_i,
    input  logic [L2_WAYS-1:0]     lu_pinned_ways_i,
    output logic                   lu_hit_o,
    output logic [WAY_W-1:0]       lu_hit_way_o,
    output logic                   lu_hit_dirty_o,
    output logic [1:0]             lu_hit_dir_state_o,
    output logic [NUM_HARTS-1:0]   lu_hit_sharers_o,
    output logic [HART_W-1:0]      lu_hit_owner_o,
    output logic [511:0]           lu_hit_data_o,

    output logic [WAY_W-1:0]       lu_vic_way_o,
    output logic                   lu_vic_valid_o,
    output logic                   lu_vic_dirty_o,
    output logic [49:0]            lu_vic_addr_o,
    output logic [1:0]             lu_vic_dir_state_o,
    output logic [NUM_HARTS-1:0]   lu_vic_sharers_o,
    output logic [HART_W-1:0]      lu_vic_owner_o,
    output logic [511:0]           lu_vic_data_o,

    // Write Port 0 (Stage C1 atomic hits / PutM / victim pin invalidation)
    input  logic                   upd0_en_i,
    input  logic [SET_W-1:0]       upd0_set_i,
    input  logic [WAY_W-1:0]       upd0_way_i,
    input  logic                   upd0_valid_i,
    input  logic                   upd0_tag_en_i,
    input  logic [TAG_W-1:0]       upd0_tag_i,
    input  logic                   upd0_data_en_i,
    input  logic [511:0]           upd0_data_i,
    input  logic                   upd0_dirty_i,
    input  logic [1:0]             upd0_dir_state_i,
    input  logic [NUM_HARTS-1:0]   upd0_sharers_i,
    input  logic [HART_W-1:0]      upd0_owner_i,
    input  logic                   upd0_plru_en_i,

    // Write Port 1 (DIR_MSHR slow-path resolution / L2 fill)
    input  logic                   upd1_en_i,
    input  logic [SET_W-1:0]       upd1_set_i,
    input  logic [WAY_W-1:0]       upd1_way_i,
    input  logic                   upd1_valid_i,
    input  logic                   upd1_tag_en_i,
    input  logic [TAG_W-1:0]       upd1_tag_i,
    input  logic                   upd1_data_en_i,
    input  logic [511:0]           upd1_data_i,
    input  logic                   upd1_dirty_i,
    input  logic [1:0]             upd1_dir_state_i,
    input  logic [NUM_HARTS-1:0]   upd1_sharers_i,
    input  logic [HART_W-1:0]      upd1_owner_i,
    input  logic                   upd1_plru_en_i
);

    // =========================================================================
    // Storage Arrays (Inspectable by Verilator C++ Coherence Scoreboard)
    // =========================================================================
`ifndef SYNTHESIS
    /* verilator lint_off UNUSEDSIGNAL */
    logic [TAG_W-1:0]     tag_arr       [L2_SETS][L2_WAYS] /* verilator public_flat_rd */;
    logic                 valid_arr     [L2_SETS][L2_WAYS] /* verilator public_flat_rd */;
    logic                 l2_dirty_arr  [L2_SETS][L2_WAYS] /* verilator public_flat_rd */;
    logic [1:0]           dir_state_arr [L2_SETS][L2_WAYS] /* verilator public_flat_rd */;
    logic [NUM_HARTS-1:0] sharer_arr    [L2_SETS][L2_WAYS] /* verilator public_flat_rd */;
    logic [HART_W-1:0]    owner_arr     [L2_SETS][L2_WAYS] /* verilator public_flat_rd */;
    logic [6:0]           plru_arr      [L2_SETS] /* verilator public_flat_rd */;
    /* verilator lint_on UNUSEDSIGNAL */
`endif

    typedef struct packed {
        logic [L2_WAYS-1:0][TAG_W-1:0]     tag;
        logic [L2_WAYS-1:0]                valid;
        logic [L2_WAYS-1:0]                dirty;
        logic [L2_WAYS-1:0][1:0]           dir;
        logic [L2_WAYS-1:0][NUM_HARTS-1:0] sharers;
        logic [L2_WAYS-1:0][HART_W-1:0]    owner;
        logic [6:0]                        plru;
    } l2_set_snap_t;

    l2_set_snap_t [L2_SETS-1:0] set_snap;

    function automatic l2_set_snap_t read_l2_set(input logic [SET_W-1:0] s);
        if (L2_SETS == 512) begin
            logic [255:0][$bits(l2_set_snap_t)-1:0] t8;
            logic [127:0][$bits(l2_set_snap_t)-1:0] t7;
            logic [63:0][$bits(l2_set_snap_t)-1:0]  t6;
            logic [31:0][$bits(l2_set_snap_t)-1:0]  t5;
            logic [15:0][$bits(l2_set_snap_t)-1:0]  t4;
            logic [7:0][$bits(l2_set_snap_t)-1:0]   t3;
            logic [3:0][$bits(l2_set_snap_t)-1:0]   t2;
            logic [1:0][$bits(l2_set_snap_t)-1:0]   t1;
            for (int k = 0; k < 256; k++) t8[k] = s[0] ? set_snap[2*k+1] : set_snap[2*k];
            for (int k = 0; k < 128; k++) t7[k] = s[1] ? t8[2*k+1]       : t8[2*k];
            for (int k = 0; k < 64;  k++) t6[k] = s[2] ? t7[2*k+1]       : t7[2*k];
            for (int k = 0; k < 32;  k++) t5[k] = s[3] ? t6[2*k+1]       : t6[2*k];
            for (int k = 0; k < 16;  k++) t4[k] = s[4] ? t5[2*k+1]       : t5[2*k];
            for (int k = 0; k < 8;   k++) t3[k] = s[5] ? t4[2*k+1]       : t4[2*k];
            for (int k = 0; k < 4;   k++) t2[k] = s[6] ? t3[2*k+1]       : t3[2*k];
            for (int k = 0; k < 2;   k++) t1[k] = s[7] ? t2[2*k+1]       : t2[2*k];
            return l2_set_snap_t'(s[8] ? t1[1] : t1[0]);
        end else begin
            return set_snap[s];
        end
    endfunction

`ifndef FURSOY_SYNTH_SRAM_BB
    logic [511:0]         data_arr      [L2_SETS][L2_WAYS];
`ifndef SYNTHESIS
    initial begin
        for (int s = 0; s < L2_SETS; s++) begin
            for (int w = 0; w < L2_WAYS; w++) begin
                data_arr[s][w] = 512'd0;
            end
        end
    end
`endif
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            if (upd0_en_i && upd0_data_en_i) begin
                data_arr[upd0_set_i][upd0_way_i] <= upd0_data_i;
            end
            if (upd1_en_i && upd1_data_en_i) begin
                data_arr[upd1_set_i][upd1_way_i] <= upd1_data_i;
            end
        end
    end
`else
    logic [4095:0] sram_lu_set_data;
    fursoy_s2_l2_data_sram u_data_sram (
        .clk_i(clk_i),
        .lu_set_i(9'(lu_addr_i[SET_W-1:0])),
        .lu_set_data_o(sram_lu_set_data),
        .upd0_wen_i(upd0_en_i && upd0_data_en_i),
        .upd0_set_i(9'(upd0_set_i)),
        .upd0_way_i(3'(upd0_way_i)),
        .upd0_data_i(upd0_data_i),
        .upd1_wen_i(upd1_en_i && upd1_data_en_i),
        .upd1_set_i(9'(upd1_set_i)),
        .upd1_way_i(3'(upd1_way_i)),
        .upd1_data_i(upd1_data_i)
    );
`endif

    // =========================================================================
    // 8-Way 7-Bit Tree-PLRU Helpers
    // =========================================================================
    function automatic logic [WAY_W-1:0] plru8_victim(input logic [6:0] bits);
        if (bits[6] == 1'b0) begin
            return bits[5] ? (bits[2] ? 3'd3 : 3'd2) : (bits[3] ? 3'd1 : 3'd0);
        end else begin
            return bits[4] ? (bits[0] ? 3'd7 : 3'd6) : (bits[1] ? 3'd5 : 3'd4);
        end
    endfunction

    function automatic logic [6:0] plru8_update(
        input logic [6:0]       cur,
        input logic [WAY_W-1:0] way
    );
        logic [6:0] nxt;
        nxt = cur;
        case (way)
            3'd0: begin nxt[6] = 1'b1; nxt[5] = 1'b1; nxt[3] = 1'b1; end
            3'd1: begin nxt[6] = 1'b1; nxt[5] = 1'b1; nxt[3] = 1'b0; end
            3'd2: begin nxt[6] = 1'b1; nxt[5] = 1'b0; nxt[2] = 1'b1; end
            3'd3: begin nxt[6] = 1'b1; nxt[5] = 1'b0; nxt[2] = 1'b0; end
            3'd4: begin nxt[6] = 1'b0; nxt[4] = 1'b1; nxt[1] = 1'b1; end
            3'd5: begin nxt[6] = 1'b0; nxt[4] = 1'b1; nxt[1] = 1'b0; end
            3'd6: begin nxt[6] = 1'b0; nxt[4] = 1'b0; nxt[0] = 1'b1; end
            3'd7: begin nxt[6] = 1'b0; nxt[4] = 1'b0; nxt[0] = 1'b0; end
        endcase
        return nxt;
    endfunction

    // =========================================================================
    // Combinational Lookup & Victim Selection
    // =========================================================================
    wire [SET_W-1:0] lu_set = lu_addr_i[SET_W-1:0];
    wire [TAG_W-1:0] lu_tag = lu_addr_i[49:SET_W];
    l2_set_snap_t    lu_snap;
    assign lu_snap = read_l2_set(lu_set);

    localparam int L2_HIT_PACK_W = WAY_W + 1 + 2 + NUM_HARTS + HART_W;
    localparam int L2_VIC_PACK_W = WAY_W + 1 + 1 + TAG_W + 2 + NUM_HARTS + HART_W;

    function automatic logic [L2_HIT_PACK_W-1:0] or_tree8_hit(
        input logic [L2_WAYS-1:0][L2_HIT_PACK_W-1:0] v
    );
        logic [3:0][L2_HIT_PACK_W-1:0] s1;
        logic [1:0][L2_HIT_PACK_W-1:0] s2;
        for (int i = 0; i < 4; i++) s1[i] = v[2*i] | v[2*i+1];
        for (int i = 0; i < 2; i++) s2[i] = s1[2*i] | s1[2*i+1];
        return s2[0] | s2[1];
    endfunction

    function automatic logic [L2_VIC_PACK_W-1:0] or_tree8_vic(
        input logic [L2_WAYS-1:0][L2_VIC_PACK_W-1:0] v
    );
        logic [3:0][L2_VIC_PACK_W-1:0] s1;
        logic [1:0][L2_VIC_PACK_W-1:0] s2;
        for (int i = 0; i < 4; i++) s1[i] = v[2*i] | v[2*i+1];
        for (int i = 0; i < 2; i++) s2[i] = s1[2*i] | s1[2*i+1];
        return s2[0] | s2[1];
    endfunction

    function automatic logic [511:0] or_tree8_data(
        input logic [L2_WAYS-1:0][511:0] v
    );
        logic [3:0][511:0] s1;
        logic [1:0][511:0] s2;
        for (int i = 0; i < 4; i++) s1[i] = v[2*i] | v[2*i+1];
        for (int i = 0; i < 2; i++) s2[i] = s1[2*i] | s1[2*i+1];
        return s2[0] | s2[1];
    endfunction

    function automatic logic [L2_WAYS-1:0] first_bit8_oh(input logic [L2_WAYS-1:0] m);
        logic [L2_WAYS-1:0] oh;
        oh = '0;
        if      (m[0]) oh[0] = 1'b1;
        else if (m[1]) oh[1] = 1'b1;
        else if (m[2]) oh[2] = 1'b1;
        else if (m[3]) oh[3] = 1'b1;
        else if (m[4]) oh[4] = 1'b1;
        else if (m[5]) oh[5] = 1'b1;
        else if (m[6]) oh[6] = 1'b1;
        else if (m[7]) oh[7] = 1'b1;
        return oh;
    endfunction

    always_comb begin
        logic [L2_WAYS-1:0][511:0]              set_data;
        logic [L2_WAYS-1:0]                     hit_oh;
        logic [L2_WAYS-1:0]                     inv_unpinned_oh;
        logic [L2_WAYS-1:0]                     unpinned_oh;
        logic [L2_WAYS-1:0]                     first_inv_oh;
        logic [L2_WAYS-1:0]                     first_unpin_oh;
        logic [L2_WAYS-1:0]                     base_vic_oh;
        logic [L2_WAYS-1:0]                     vic_oh;
        logic [WAY_W-1:0]                       base_vic;
        logic [L2_WAYS-1:0][L2_HIT_PACK_W-1:0]  hit_masked;
        logic [L2_WAYS-1:0][L2_VIC_PACK_W-1:0]  vic_masked;
        logic [L2_WAYS-1:0][511:0]              hit_data_masked;
        logic [L2_WAYS-1:0][511:0]              vic_data_masked;
        logic [TAG_W-1:0]                       vic_tag_mux;

        for (int w = 0; w < L2_WAYS; w++) begin
`ifndef FURSOY_SYNTH_SRAM_BB
            set_data[w]        = data_arr[lu_set][w];
`else
            set_data[w]        = sram_lu_set_data[w*512 +: 512];
`endif
            hit_oh[w]          = lu_snap.valid[w] && (lu_snap.tag[w] == lu_tag);
            inv_unpinned_oh[w] = !lu_pinned_ways_i[w] && !lu_snap.valid[w];
            unpinned_oh[w]     = !lu_pinned_ways_i[w];
        end

        lu_hit_o = |hit_oh;
        for (int w = 0; w < L2_WAYS; w++) begin
            hit_masked[w]      = hit_oh[w] ? {WAY_W'(w), lu_snap.dirty[w], lu_snap.dir[w], lu_snap.sharers[w], lu_snap.owner[w]} : '0;
            hit_data_masked[w] = hit_oh[w] ? set_data[w] : 512'd0;
        end
        {lu_hit_way_o, lu_hit_dirty_o, lu_hit_dir_state_o, lu_hit_sharers_o, lu_hit_owner_o} = or_tree8_hit(hit_masked);
        lu_hit_data_o = or_tree8_data(hit_data_masked);

        base_vic       = plru8_victim(lu_snap.plru);
        first_inv_oh   = first_bit8_oh(inv_unpinned_oh);
        first_unpin_oh = first_bit8_oh(unpinned_oh);
        for (int w = 0; w < L2_WAYS; w++) begin
            base_vic_oh[w] = (base_vic == WAY_W'(w));
        end
        vic_oh = (|inv_unpinned_oh)       ? first_inv_oh :
                 (!lu_pinned_ways_i[base_vic] ? base_vic_oh : first_unpin_oh);

        for (int w = 0; w < L2_WAYS; w++) begin
            vic_masked[w]      = vic_oh[w] ? {WAY_W'(w), lu_snap.valid[w], lu_snap.dirty[w], lu_snap.tag[w], lu_snap.dir[w], lu_snap.sharers[w], lu_snap.owner[w]} : '0;
            vic_data_masked[w] = vic_oh[w] ? set_data[w] : 512'd0;
        end
        {lu_vic_way_o, lu_vic_valid_o, lu_vic_dirty_o, vic_tag_mux, lu_vic_dir_state_o, lu_vic_sharers_o, lu_vic_owner_o} = or_tree8_vic(vic_masked);
        lu_vic_addr_o = {vic_tag_mux, lu_set};
        lu_vic_data_o = or_tree8_data(vic_data_masked);
    end

    // Pre-decode update way one-hot selects once instead of duplicating 512x comparators
    logic [L2_WAYS-1:0] upd0_way_oh;
    logic [L2_WAYS-1:0] upd1_way_oh;
    always_comb begin
        for (int w = 0; w < L2_WAYS; w++) begin
            upd0_way_oh[w] = (upd0_way_i == WAY_W'(w));
            upd1_way_oh[w] = (upd1_way_i == WAY_W'(w));
        end
    end

    // =========================================================================
    // Sequential Array & Directory Updates (Per-Set Generate for Clean Synth)
    // =========================================================================
    genvar gs;
    generate
        for (gs = 0; gs < L2_SETS; gs = gs + 1) begin : gen_l2_sets
            logic [L2_WAYS-1:0][TAG_W-1:0]     gs_tag_q;
            logic [L2_WAYS-1:0]                gs_valid_q;
            logic [L2_WAYS-1:0]                gs_dirty_q;
            logic [L2_WAYS-1:0][1:0]           gs_dir_q;
            logic [L2_WAYS-1:0][NUM_HARTS-1:0] gs_sharers_q;
            logic [L2_WAYS-1:0][HART_W-1:0]    gs_owner_q;
            logic [6:0]                        gs_plru_q;

            always_comb begin
                set_snap[gs].tag     = gs_tag_q;
                set_snap[gs].valid   = gs_valid_q;
                set_snap[gs].dirty   = gs_dirty_q;
                set_snap[gs].dir     = gs_dir_q;
                set_snap[gs].sharers = gs_sharers_q;
                set_snap[gs].owner   = gs_owner_q;
                set_snap[gs].plru    = gs_plru_q;
`ifndef SYNTHESIS
                for (int w = 0; w < L2_WAYS; w++) begin
                    tag_arr[gs][w]       = gs_tag_q[w];
                    valid_arr[gs][w]     = gs_valid_q[w];
                    l2_dirty_arr[gs][w]  = gs_dirty_q[w];
                    dir_state_arr[gs][w] = gs_dir_q[w];
                    sharer_arr[gs][w]    = gs_sharers_q[w];
                    owner_arr[gs][w]     = gs_owner_q[w];
                end
                plru_arr[gs] = gs_plru_q;
`endif
            end

            wire upd0_set_hit = upd0_en_i && (upd0_set_i == SET_W'(gs));
            wire upd1_set_hit = upd1_en_i && (upd1_set_i == SET_W'(gs));
            wire [L2_WAYS-1:0] u0_way_hit = {L2_WAYS{upd0_set_hit}} & upd0_way_oh;
            wire [L2_WAYS-1:0] u1_way_hit = {L2_WAYS{upd1_set_hit}} & upd1_way_oh;

            always_ff @(posedge clk_i) begin
                if (rst_i) begin
                    gs_plru_q    <= 7'd0;
                    gs_tag_q     <= '0;
                    gs_valid_q   <= '0;
                    gs_dirty_q   <= '0;
                    gs_dir_q     <= '0;
                    gs_sharers_q <= '0;
                    gs_owner_q   <= '0;
                end else begin
                    for (int w = 0; w < L2_WAYS; w++) begin
                        if (u1_way_hit[w]) begin
                            gs_valid_q[w]   <= upd1_valid_i;
                            gs_dirty_q[w]   <= upd1_dirty_i;
                            gs_dir_q[w]     <= upd1_dir_state_i;
                            gs_sharers_q[w] <= upd1_sharers_i;
                            gs_owner_q[w]   <= upd1_owner_i;
                            if (upd1_tag_en_i) begin
                                gs_tag_q[w] <= upd1_tag_i;
                            end else if (u0_way_hit[w] && upd0_tag_en_i) begin
                                gs_tag_q[w] <= upd0_tag_i;
                            end
                        end else if (u0_way_hit[w]) begin
                            gs_valid_q[w]   <= upd0_valid_i;
                            gs_dirty_q[w]   <= upd0_dirty_i;
                            gs_dir_q[w]     <= upd0_dir_state_i;
                            gs_sharers_q[w] <= upd0_sharers_i;
                            gs_owner_q[w]   <= upd0_owner_i;
                            if (upd0_tag_en_i) begin
                                gs_tag_q[w] <= upd0_tag_i;
                            end
                        end
                    end

                    if (upd0_set_hit && upd0_plru_en_i && upd1_set_hit && upd1_plru_en_i) begin
                        gs_plru_q <= plru8_update(plru8_update(gs_plru_q, upd0_way_i), upd1_way_i);
                    end else begin
                        if (upd0_set_hit && upd0_plru_en_i) begin
                            gs_plru_q <= plru8_update(gs_plru_q, upd0_way_i);
                        end
                        if (upd1_set_hit && upd1_plru_en_i) begin
                            gs_plru_q <= plru8_update(gs_plru_q, upd1_way_i);
                        end
                    end
                end
            end
        end
    endgenerate

endmodule

`endif // FURSOY_S2_L2_SV
