`ifndef FURSOY_S1_VRAT_SV
`define FURSOY_S1_VRAT_SV

// =============================================================================
// Fursoy Slice-1 Vector Register Alias Table (VRAT) & Bitmap Freelist
// =============================================================================
// Features:
// - 32 architectural vector registers (v0..v31) mapped onto 64 physical vector
//   registers (p0..p31 reset architectural baseline, p32..p63 speculative pool).
// - Supports variable LMUL/EMUL register group renaming (1, 2, 4, or 8 physical
//   registers per instruction) in a single cycle via 32-bit parallel-prefix
//   popcount bitmap allocation without fragmentation deadlocks.
// - 16-checkpoint SRAT snapshot/restore tied to ROB branch checkpoints.
// - 128-entry ROB vector-rename metadata table for in-order ARAT update and
//   pold reclamation on commit, plus 2-wide ROB-walk pnew reclamation on squash.
// - 64-bit VRF physical register scoreboard (vrf_ready_q) with combinational
//   writeback bypass into VIQ allocation.
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_vrat
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned PREG_COUNT  = VRF_NUM_PREGS,
    parameter int unsigned CHKPT_COUNT = NUM_CHECKPOINTS,
    parameter int unsigned ROB_DEPTH_P = ROB_DEPTH
) (
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              flush_valid_i,

    // Single-Vector-Dispatch Rename Channel (dual-VEC serialized at dispatch)
    input  logic              alloc_valid_i,
    input  logic              alloc_dest_valid_i,
    input  areg_v_t           alloc_vd_i,
    input  areg_v_t           alloc_vs1_i,
    input  areg_v_t           alloc_vs2_i,
    input  logic [3:0]        alloc_vd_cnt_i,   // 1, 2, 4, or 8
    input  logic [3:0]        alloc_vs1_cnt_i,  // 1, 2, 4, or 8
    input  logic [3:0]        alloc_vs2_cnt_i,  // 1, 2, 4, or 8
    input  rob_idx_t          alloc_rob_idx_i,

    output logic              alloc_ready_o,
    output vreg_t             alloc_vd_map_o      [8],
    output vreg_t             alloc_old_vd_map_o  [8],
    output vreg_t             alloc_vs1_map_o     [8],
    output vreg_t             alloc_vs2_map_o     [8],
    output vreg_t             alloc_vm_preg_o,
    output logic [7:0]        alloc_old_vd_ready_o,
    output logic [7:0]        alloc_vs1_ready_o,
    output logic [7:0]        alloc_vs2_ready_o,
    output logic              alloc_vm_ready_o,

    // Same-Cycle Branch Checkpoint Capture (up to 2 slots; at most 1 vector op)
    input  logic              alloc_slot_is_1_i,
    input  logic [1:0]        chkpt_alloc_valid_i,
    input  chkpt_idx_t        chkpt_alloc_id_i    [1:0],

    // Writeback Completion Wakeup Mask (bits [63:0] for completed physical pregs)
    input  logic [PREG_COUNT-1:0] wb_v_mask_i,

    // In-Order ROB Retirement Channel (2-wide)
    input  logic [1:0]        retire_valid_i,
    input  rob_idx_t          retire_rob_idx_i    [1:0],

    // Branch Misprediction Recovery (SRAT checkpoint + ROB backwards walk)
    input  logic              recover_valid_i,
    input  chkpt_idx_t        recover_chkpt_id_i,
    input  logic [1:0]        recover_rob_valid_i,
    input  rob_idx_t          recover_rob_idx_i   [1:0],

    // Observability / Probe Outputs
    output vreg_t             arat_vec_o          [AREG_COUNT],
    output logic [5:0]        fl_free_count_o
);

    localparam int unsigned POOL_SIZE = PREG_COUNT - AREG_COUNT; // 32 (p32..p63)

    // -------------------------------------------------------------------------
    // 1. Storage Arrays: SRAT, ARAT, Checkpoints, Bitmap Freelist, ROB Meta
    // -------------------------------------------------------------------------
    vreg_t srat_q [AREG_COUNT];
    vreg_t arat_q [AREG_COUNT];

    vreg_t chkpt_srat_q [CHKPT_COUNT][AREG_COUNT];

    // Bit i (0..31) corresponds to physical vector register 32 + i (1 = free)
    logic [POOL_SIZE-1:0]  fl_free_q;
    logic [PREG_COUNT-1:0] vrf_ready_q;

    logic [ROB_DEPTH_P-1:0] rob_meta_dest_valid_q;
    areg_v_t                rob_meta_vd_q         [ROB_DEPTH_P];
    logic [3:0]             rob_meta_ngroups_q    [ROB_DEPTH_P];
    logic [47:0]            rob_meta_pnew_q       [ROB_DEPTH_P]; // 8 x 6-bit pnew
    logic [47:0]            rob_meta_pold_q       [ROB_DEPTH_P]; // 8 x 6-bit pold

    // -------------------------------------------------------------------------
    // 2. Parallel-Prefix Popcount Bitmap Allocator (allocates 1..8 regs in 1 cyc)
    // -------------------------------------------------------------------------
    logic [2:0] nibble_sum  [8];
    logic [1:0] intra_rank  [POOL_SIZE];
    logic [5:0] nibble_base [8];
    logic [5:0] bit_rank    [POOL_SIZE];
    logic [5:0] fl_free_count;

    always_comb begin
        // Nibble sums and local bit offsets within each 4-bit chunk
        for (int n = 0; n < 8; n++) begin
            logic b0, b1, b2, b3;
            b0 = fl_free_q[n*4 + 0];
            b1 = fl_free_q[n*4 + 1];
            b2 = fl_free_q[n*4 + 2];
            b3 = fl_free_q[n*4 + 3];
            nibble_sum[n]       = {2'b00, b0} + {2'b00, b1} + {2'b00, b2} + {2'b00, b3};
            intra_rank[n*4 + 0] = 2'd0;
            intra_rank[n*4 + 1] = {1'b0, b0};
            intra_rank[n*4 + 2] = {1'b0, b0} + {1'b0, b1};
            intra_rank[n*4 + 3] = {1'b0, b0} + {1'b0, b1} + {1'b0, b2};
        end

        // Balanced prefix addition across the 8 nibbles
        nibble_base[0] = 6'd0;
        for (int n = 1; n < 8; n++) begin
            nibble_base[n] = nibble_base[n-1] + {3'b000, nibble_sum[n-1]};
        end
        fl_free_count = nibble_base[7] + {3'b000, nibble_sum[7]};

        for (int i = 0; i < POOL_SIZE; i++) begin
            bit_rank[i] = nibble_base[i >> 2] + {4'b0000, intra_rank[i]};
        end
    end

    assign fl_free_count_o = fl_free_count;

    // Select k-th free slot (k = 0..7)
    logic [4:0]           alloc_slot_idx  [8];
    logic [POOL_SIZE-1:0] alloc_slot_oh   [8];
    logic [POOL_SIZE-1:0] alloc_free_mask;

    always_comb begin
        alloc_free_mask = '0;
        for (int k = 0; k < 8; k++) begin
            alloc_slot_idx[k] = 5'd0;
            alloc_slot_oh[k]  = '0;
            for (int i = 0; i < POOL_SIZE; i++) begin
                if (fl_free_q[i] && (bit_rank[i] == 6'(k))) begin
                    alloc_slot_oh[k][i] = 1'b1;
                    alloc_slot_idx[k]   = 5'(i);
                end
            end
            if (alloc_valid_i && alloc_dest_valid_i && (4'(k) < alloc_vd_cnt_i)) begin
                alloc_free_mask = alloc_free_mask | alloc_slot_oh[k];
            end
        end
    end

    wire [3:0] req_alloc_cnt = alloc_dest_valid_i ? alloc_vd_cnt_i : 4'd0;
    assign alloc_ready_o     = !flush_valid_i && (fl_free_count >= {2'b00, req_alloc_cnt});

    // -------------------------------------------------------------------------
    // 3. Combinational Rename Lookup & Readiness Outputs
    // -------------------------------------------------------------------------
    wire [PREG_COUNT-1:0] eff_vrf_ready = vrf_ready_q | wb_v_mask_i;

    always_comb begin
        for (int g = 0; g < 8; g++) begin
            areg_v_t vd_a, vs1_a, vs2_a;
            vd_a  = alloc_vd_i  + 5'(g);
            vs1_a = alloc_vs1_i + 5'(g);
            vs2_a = alloc_vs2_i + 5'(g);

            alloc_old_vd_map_o[g] = srat_q[vd_a];
            alloc_vs1_map_o[g]    = srat_q[vs1_a];
            alloc_vs2_map_o[g]    = srat_q[vs2_a];

            if (alloc_dest_valid_i && (4'(g) < alloc_vd_cnt_i)) begin
                alloc_vd_map_o[g] = vreg_t'(6'd32 + {1'b0, alloc_slot_idx[g]});
            end else if (!alloc_dest_valid_i && (4'(g) < alloc_vd_cnt_i)) begin
                // Vector store reads vs3 using vd_map slots
                alloc_vd_map_o[g] = srat_q[vd_a];
            end else begin
                alloc_vd_map_o[g] = vreg_t'(0);
            end

            alloc_old_vd_ready_o[g] = (4'(g) < alloc_vd_cnt_i)  ? eff_vrf_ready[alloc_old_vd_map_o[g]] : 1'b1;
            alloc_vs1_ready_o[g]    = (4'(g) < alloc_vs1_cnt_i) ? eff_vrf_ready[alloc_vs1_map_o[g]]    : 1'b1;
            alloc_vs2_ready_o[g]    = (4'(g) < alloc_vs2_cnt_i) ? eff_vrf_ready[alloc_vs2_map_o[g]]    : 1'b1;
        end
        alloc_vm_preg_o  = srat_q[0];
        alloc_vm_ready_o = eff_vrf_ready[alloc_vm_preg_o];
    end

    // -------------------------------------------------------------------------
    // 4. Next-State Computation: Post-Alloc SRAT, Retire ARAT, & Recover Masks
    // -------------------------------------------------------------------------
    vreg_t post_uop0_srat [AREG_COUNT];
    vreg_t post_both_srat [AREG_COUNT];
    vreg_t arat_next      [AREG_COUNT];
    logic       uop_writes_vec_c;
    logic [3:0] grp_idx_c;
    areg_v_t    dst_a_c;

    always_comb begin
        uop_writes_vec_c = alloc_valid_i && alloc_dest_valid_i;
        grp_idx_c        = 4'd0;
        dst_a_c          = '0;

        for (int r = 0; r < AREG_COUNT; r++) begin
            post_uop0_srat[r] = srat_q[r];
            post_both_srat[r] = srat_q[r];
            arat_next[r]      = arat_q[r];
        end

        if (uop_writes_vec_c) begin
            for (int g = 0; g < 8; g++) begin
                grp_idx_c = 4'(g);
                if (grp_idx_c < alloc_vd_cnt_i) begin
                    dst_a_c = alloc_vd_i + 5'(g);
                    if (!alloc_slot_is_1_i) begin
                        post_uop0_srat[dst_a_c] = alloc_vd_map_o[g];
                    end
                    post_both_srat[dst_a_c] = alloc_vd_map_o[g];
                end
            end
        end

        // Next architectural mapping including same-cycle retirements
        for (int s = 0; s < 2; s++) begin
            if (retire_valid_i[s] && rob_meta_dest_valid_q[retire_rob_idx_i[s]]) begin
                for (int g = 0; g < 8; g++) begin
                    if (4'(g) < rob_meta_ngroups_q[retire_rob_idx_i[s]]) begin
                        arat_next[rob_meta_vd_q[retire_rob_idx_i[s]] + 5'(g)] =
                            rob_meta_pnew_q[retire_rob_idx_i[s]][g*6 +: 6];
                    end
                end
            end
        end
    end

    // Freelist reclamation bitmasks from Commit & Recovery ROB walk
    logic [POOL_SIZE-1:0]  retire_free_mask;
    logic [POOL_SIZE-1:0]  rec_free_mask;
    logic [POOL_SIZE-1:0]  flush_free_mask;
    logic [PREG_COUNT-1:0] rec_ready_mask;
    vreg_t po_c;
    vreg_t pn_c;

    always_comb begin
        retire_free_mask = '0;
        rec_free_mask    = '0;
        rec_ready_mask   = '0;
        po_c             = '0;
        pn_c             = '0;

        for (int s = 0; s < 2; s++) begin
            if (retire_valid_i[s] && rob_meta_dest_valid_q[retire_rob_idx_i[s]]) begin
                for (int g = 0; g < 8; g++) begin
                    if (4'(g) < rob_meta_ngroups_q[retire_rob_idx_i[s]]) begin
                        po_c = rob_meta_pold_q[retire_rob_idx_i[s]][g*6 +: 6];
                        if (po_c[5]) begin
                            retire_free_mask[po_c[4:0]] = 1'b1;
                        end
                    end
                end
            end

            if (recover_rob_valid_i[s] && rob_meta_dest_valid_q[recover_rob_idx_i[s]]) begin
                for (int g = 0; g < 8; g++) begin
                    if (4'(g) < rob_meta_ngroups_q[recover_rob_idx_i[s]]) begin
                        pn_c = rob_meta_pnew_q[recover_rob_idx_i[s]][g*6 +: 6];
                        if (pn_c[5]) begin
                            rec_free_mask[pn_c[4:0]] = 1'b1;
                            rec_ready_mask[pn_c]     = 1'b1;
                        end
                    end
                end
            end
        end

        // 1-cycle flush reconstruction from ARAT
        flush_free_mask = {POOL_SIZE{1'b1}};
        for (int r = 0; r < AREG_COUNT; r++) begin
            if (arat_next[r][5]) begin
                flush_free_mask[arat_next[r][4:0]] = 1'b0;
            end
        end
    end

    assign arat_vec_o = arat_q;

    // -------------------------------------------------------------------------
    // 5. Sequential Architectural & Speculative State Updates
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int r = 0; r < AREG_COUNT; r++) begin
                srat_q[r] <= vreg_t'(r);
                arat_q[r] <= vreg_t'(r);
                for (int c = 0; c < CHKPT_COUNT; c++) begin
                    chkpt_srat_q[c][r] <= vreg_t'(r);
                end
            end
            fl_free_q             <= {POOL_SIZE{1'b1}};
            vrf_ready_q           <= {PREG_COUNT{1'b1}};
            rob_meta_dest_valid_q <= '0;
        end else begin
            // Always advance ARAT on in-order retirement
            for (int r = 0; r < AREG_COUNT; r++) begin
                arat_q[r] <= arat_next[r];
            end

            if (flush_valid_i) begin
                for (int r = 0; r < AREG_COUNT; r++) begin
                    srat_q[r] <= arat_next[r];
                end
                fl_free_q             <= flush_free_mask;
                vrf_ready_q           <= {PREG_COUNT{1'b1}};
                rob_meta_dest_valid_q <= '0;
            end else begin
                // Update freelist bitmap and readiness scoreboard
                fl_free_q   <= (fl_free_q & ~alloc_free_mask) | retire_free_mask | rec_free_mask;

                begin : blk_vrf_ready
                    logic [PREG_COUNT-1:0] nxt_rdy;
                    nxt_rdy = vrf_ready_q | wb_v_mask_i | rec_ready_mask;
                    if (alloc_valid_i && alloc_dest_valid_i) begin
                        for (int g = 0; g < 8; g++) begin
                            if (4'(g) < alloc_vd_cnt_i) begin
                                nxt_rdy[alloc_vd_map_o[g]] = 1'b0;
                            end
                        end
                    end
                    vrf_ready_q <= nxt_rdy;
                end

                // Clear retired / squashed ROB meta entries
                for (int s = 0; s < 2; s++) begin
                    if (retire_valid_i[s]) begin
                        rob_meta_dest_valid_q[retire_rob_idx_i[s]] <= 1'b0;
                    end
                    if (recover_rob_valid_i[s]) begin
                        rob_meta_dest_valid_q[recover_rob_idx_i[s]] <= 1'b0;
                    end
                end

                if (recover_valid_i) begin
                    for (int r = 0; r < AREG_COUNT; r++) begin
                        srat_q[r] <= chkpt_srat_q[recover_chkpt_id_i][r];
                    end
                end else begin
                    for (int r = 0; r < AREG_COUNT; r++) begin
                        srat_q[r] <= post_both_srat[r];
                    end

                    if (alloc_valid_i) begin
                        rob_meta_dest_valid_q[alloc_rob_idx_i] <= alloc_dest_valid_i;
                        rob_meta_vd_q[alloc_rob_idx_i]         <= alloc_vd_i;
                        rob_meta_ngroups_q[alloc_rob_idx_i]    <= alloc_vd_cnt_i;
                        for (int g = 0; g < 8; g++) begin
                            rob_meta_pnew_q[alloc_rob_idx_i][g*6 +: 6] <= alloc_vd_map_o[g];
                            rob_meta_pold_q[alloc_rob_idx_i][g*6 +: 6] <= alloc_old_vd_map_o[g];
                        end
                    end

                    // Checkpoint snapshot captures
                    if (chkpt_alloc_valid_i[0]) begin
                        for (int r = 0; r < AREG_COUNT; r++) begin
                            chkpt_srat_q[chkpt_alloc_id_i[0]][r] <= post_uop0_srat[r];
                        end
                    end
                    if (chkpt_alloc_valid_i[1]) begin
                        for (int r = 0; r < AREG_COUNT; r++) begin
                            chkpt_srat_q[chkpt_alloc_id_i[1]][r] <= post_uop0_srat[r];
                        end
                    end
                end
            end
        end
    end

endmodule

`endif // FURSOY_S1_VRAT_SV
