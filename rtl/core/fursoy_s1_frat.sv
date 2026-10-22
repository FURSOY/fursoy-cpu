`ifndef FURSOY_S1_FRAT_SV
`define FURSOY_S1_FRAT_SV

// =============================================================================
// Fursoy Slice-1 Floating-Point Register Alias Table (FRAT) — Milestone 8
// =============================================================================
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 5.2
//
// Implements:
// - 32-entry Committed Architectural RAT (ARAT_FP[32])
// - 32-entry Speculative Working RAT (SRAT_FP[32])
// - 32-entry Free List for FP physical registers (FL_FP[32], managing fp32..fp63 at reset)
// - f0 is fully writable and allocates physical registers normally (PROP_M8_02, PROP_M8_06)
// - 2-wide Rename Interface with:
//     * Intra-group RAW forwarding (uop0 Pnew_fp -> uop1 source) (PROP_M8_02)
//     * Intra-group WAW resolution (uop0 Pnew_fp -> uop1 Pold_fp; uop1 wins in SRAT_FP) (PROP_M8_03)
// - 8 Branch Checkpoints capturing SRAT_FP snapshots (PROP_M8_04, PROP_M8_05)
//     * 1-cycle rollback on misprediction redirect without register leakage
// - Retirement commit updating ARAT_FP and returning Pold_fp to FL_FP (PROP_M8_04)
// - Full architectural flush FSM restoring SRAT_FP <= ARAT_FP and reconstructing FL_FP (PROP_M8_06)
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_frat
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned CHKPT_COUNT = NUM_CHECKPOINTS // 8 checkpoints
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // -------------------------------------------------------------------------
    // ROB Head Pointer (for circular age comparison of checkpoints)
    // -------------------------------------------------------------------------
    input  rob_idx_t               rob_head_i,

    // -------------------------------------------------------------------------
    // 2-Wide Rename Interface
    // -------------------------------------------------------------------------
    input  logic                   uop0_valid_i,
    input  logic                   uop0_fp_dest_valid_i,
    input  fareg_t                 uop0_fd_i,
    input  fareg_t                 uop0_fs1_i,
    input  fareg_t                 uop0_fs2_i,
    input  fareg_t                 uop0_fs3_i,
    input  logic                   uop0_is_branch_i,
    input  rob_idx_t               uop0_rob_idx_i,

    input  logic                   uop1_valid_i,
    input  logic                   uop1_fp_dest_valid_i,
    input  fareg_t                 uop1_fd_i,
    input  fareg_t                 uop1_fs1_i,
    input  fareg_t                 uop1_fs2_i,
    input  fareg_t                 uop1_fs3_i,
    input  logic                   uop1_is_branch_i,
    input  rob_idx_t               uop1_rob_idx_i,

    // Rename Grants from dispatch arbitration
    input  logic [1:0]             rename_grant_i,

    // Candidate allocated Pnew_fp from Free List
    output fpreg_t                 uop0_pnew_fp_o,
    output fpreg_t                 uop1_pnew_fp_o,

    // Displaced Pold_fp for ROB entry recording
    output fpreg_t                 uop0_pold_fp_o,
    output fpreg_t                 uop1_pold_fp_o,

    // Source physical register lookups
    output fpreg_t                 uop0_prs1_fp_o,
    output fpreg_t                 uop0_prs2_fp_o,
    output fpreg_t                 uop0_prs3_fp_o,

    output fpreg_t                 uop1_prs1_fp_o,
    output fpreg_t                 uop1_prs2_fp_o,
    output fpreg_t                 uop1_prs3_fp_o,

    // Intra-group RAW detection outputs (for readiness gating)
    output logic                   uop1_fs1_raw_uop0_o,
    output logic                   uop1_fs2_raw_uop0_o,
    output logic                   uop1_fs3_raw_uop0_o,

    // Free List readiness: [0] >= 1 available, [1] >= 2 available
    output logic [1:0]             fl_fp_ready_o,
    output logic [FL_FP_CNT_W-1:0] fl_fp_count_o,

    // Checkpoint allocation outputs
    input  chkpt_idx_t             chkpt0_id_i,
    input  chkpt_idx_t             chkpt1_id_i,

    // -------------------------------------------------------------------------
    // Retirement Commit Interface (ARAT updates & Pold deallocation)
    // -------------------------------------------------------------------------
    input  logic [1:0]             retire_valid_i,
    input  logic [1:0]             retire_fp_dest_valid_i,
    input  fareg_t                 retire_fd_i       [1:0],
    input  fpreg_t                 retire_pnew_fp_i  [1:0],
    input  fpreg_t                 retire_pold_fp_i  [1:0],

    // Checkpoint release on branch retirement
    input  logic [1:0]             retire_is_branch_i,
    input  chkpt_idx_t             retire_chkpt_id_i [1:0],

    // -------------------------------------------------------------------------
    // Branch Misprediction Recovery Interface (Single-Cycle Snapshot Restore)
    // -------------------------------------------------------------------------
    input  logic                   recover_valid_i,
    input  chkpt_idx_t             recover_chkpt_id_i,
    input  rob_idx_t               recover_rob_idx_i,

    // Squash Pnew deallocation from ROB recovery walk
    input  logic [1:0]             recover_pnew_valid_i,
    input  fpreg_t                 recover_pnew_fp_i [1:0],

    // -------------------------------------------------------------------------
    // Full Architectural Flush Interface
    // -------------------------------------------------------------------------
    input  logic                   flush_valid_i,
    output logic                   reconstructing_o,

    // Diagnostics / Observability
    output fpreg_t                 arat_fp_o [FAREG_COUNT],
    output fpreg_t                 srat_fp_o [FAREG_COUNT],
    output logic [FPRF_SIZE-1:0]   committed_mask_fp_o
);

    // -------------------------------------------------------------------------
    // Storage Elements: ARAT_FP & SRAT_FP
    // -------------------------------------------------------------------------
    fpreg_t arat_q [FAREG_COUNT];
    fpreg_t srat_q [FAREG_COUNT];

    // Branch Checkpoint Table for FP
    logic     chkpt_valid_q   [CHKPT_COUNT];
    rob_idx_t chkpt_rob_idx_q [CHKPT_COUNT];
    fpreg_t   chkpt_srat_q    [CHKPT_COUNT][FAREG_COUNT];

    // -------------------------------------------------------------------------
    // Internal Circular FIFO Free List (32 entries: fp32..fp63 at reset)
    // -------------------------------------------------------------------------
    fpreg_t fl_mem_q [FL_FP_DEPTH];
    logic [4:0] fl_head_q;
    logic [4:0] fl_tail_q;
    logic [FL_FP_CNT_W-1:0] fl_count_q;

    // Flush reconstruction FSM state
    logic       reconstructing_q;
    logic [5:0] scan_idx_q;

    // -------------------------------------------------------------------------
    // Circular ROB Age Helper Function
    // -------------------------------------------------------------------------
    function automatic logic [5:0] rob_age(input [5:0] idx, input [5:0] head);
        logic [6:0] diff;
        diff = {1'b0, idx} + 7'd48 - {1'b0, head};
        return (diff >= 7'd48) ? (diff[5:0] - 6'd48) : diff[5:0];
    endfunction

    // -------------------------------------------------------------------------
    // Candidate Free List Allocations
    // -------------------------------------------------------------------------
    assign uop0_pnew_fp_o = fl_mem_q[fl_head_q];
    assign uop1_pnew_fp_o = uop0_fp_dest_valid_i ? fl_mem_q[fl_head_q + 5'd1] :
                                                  fl_mem_q[fl_head_q];

    assign fl_fp_ready_o[0] = !reconstructing_q && (fl_count_q >= 6'd1);
    assign fl_fp_ready_o[1] = !reconstructing_q && (fl_count_q >= 6'd2);
    assign fl_fp_count_o    = fl_count_q;
    assign reconstructing_o = reconstructing_q;

    // -------------------------------------------------------------------------
    // Rename Source Lookups & Intra-group RAW Dependency Logic
    // -------------------------------------------------------------------------
    // uop0 sources directly read SRAT_FP
    assign uop0_prs1_fp_o = srat_q[uop0_fs1_i];
    assign uop0_prs2_fp_o = srat_q[uop0_fs2_i];
    assign uop0_prs3_fp_o = srat_q[uop0_fs3_i];

    // Intra-group RAW detection for uop1
    wire uop0_produces_fp = uop0_valid_i && uop0_fp_dest_valid_i;
    assign uop1_fs1_raw_uop0_o = uop0_produces_fp && (uop1_fs1_i == uop0_fd_i);
    assign uop1_fs2_raw_uop0_o = uop0_produces_fp && (uop1_fs2_i == uop0_fd_i);
    assign uop1_fs3_raw_uop0_o = uop0_produces_fp && (uop1_fs3_i == uop0_fd_i);

    // uop1 source resolution with intra-group forwarding
    assign uop1_prs1_fp_o = uop1_fs1_raw_uop0_o ? uop0_pnew_fp_o : srat_q[uop1_fs1_i];
    assign uop1_prs2_fp_o = uop1_fs2_raw_uop0_o ? uop0_pnew_fp_o : srat_q[uop1_fs2_i];
    assign uop1_prs3_fp_o = uop1_fs3_raw_uop0_o ? uop0_pnew_fp_o : srat_q[uop1_fs3_i];

    // -------------------------------------------------------------------------
    // Destination Pold Resolution & Intra-group WAW Handling
    // -------------------------------------------------------------------------
    assign uop0_pold_fp_o = srat_q[uop0_fd_i];

    // Intra-group WAW detection for uop1
    wire uop1_waw_uop0 = uop0_produces_fp && uop1_valid_i && uop1_fp_dest_valid_i && (uop1_fd_i == uop0_fd_i);
    assign uop1_pold_fp_o = uop1_waw_uop0 ? uop0_pnew_fp_o : srat_q[uop1_fd_i];

    // -------------------------------------------------------------------------
    // SRAT Snapshots for Checkpoints
    // -------------------------------------------------------------------------
    fpreg_t post_uop0_srat [FAREG_COUNT];
    fpreg_t post_uop1_srat [FAREG_COUNT];
    always_comb begin
        for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
            if (uop0_produces_fp && (fareg_t'(r) == uop0_fd_i)) begin
                post_uop0_srat[r] = uop0_pnew_fp_o;
            end else begin
                post_uop0_srat[r] = srat_q[r];
            end
        end

        for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
            if (uop1_valid_i && uop1_fp_dest_valid_i && (fareg_t'(r) == uop1_fd_i)) begin
                post_uop1_srat[r] = uop1_pnew_fp_o;
            end else begin
                post_uop1_srat[r] = post_uop0_srat[r];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Committed Mask Generation
    // -------------------------------------------------------------------------
    logic [FPRF_SIZE-1:0] committed_mask;
    always_comb begin
        committed_mask = '0;
        for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
            committed_mask[arat_q[r]] = 1'b1;
        end
    end
    assign committed_mask_fp_o = committed_mask;
    assign arat_fp_o           = arat_q;
    assign srat_fp_o           = srat_q;

    // -------------------------------------------------------------------------
    // Reclamation Push Preparation (up to 4 pushes per cycle: 2 retire + 2 recover)
    // -------------------------------------------------------------------------
    logic [2:0] push_count;
    fpreg_t     push_pregs [4];

    always_comb begin
        push_count = 3'd0;
        for (int unsigned k = 0; k < 4; k++) begin
            push_pregs[k] = '0;
        end

        // Retirement Pold pushes
        if (retire_valid_i[0] && retire_fp_dest_valid_i[0]) begin
            push_pregs[push_count[1:0]] = retire_pold_fp_i[0];
            push_count = push_count + 3'd1;
        end
        if (retire_valid_i[1] && retire_fp_dest_valid_i[1]) begin
            push_pregs[push_count[1:0]] = retire_pold_fp_i[1];
            push_count = push_count + 3'd1;
        end

        // Recovery Squash Pnew pushes
        if (recover_pnew_valid_i[0]) begin
            push_pregs[push_count[1:0]] = recover_pnew_fp_i[0];
            push_count = push_count + 3'd1;
        end
        if (recover_pnew_valid_i[1]) begin
            push_pregs[push_count[1:0]] = recover_pnew_fp_i[1];
            push_count = push_count + 3'd1;
        end
    end

    // Allocation Pop count
    logic [1:0] alloc_count;
    always_comb begin
        alloc_count = 2'd0;
        if (rename_grant_i[0] && uop0_produces_fp) begin
            alloc_count = alloc_count + 2'd1;
        end
        if (rename_grant_i[1] && uop1_valid_i && uop1_fp_dest_valid_i) begin
            alloc_count = alloc_count + 2'd1;
        end
    end

    // -------------------------------------------------------------------------
    // Flush Reconstruction Scan Combinational Logic (8 candidates/cycle)
    // -------------------------------------------------------------------------
    logic [3:0] recon_pushes_comb;
    fpreg_t     recon_p_comb [8];

    always_comb begin
        recon_pushes_comb = 4'd0;
        for (int unsigned k = 0; k < 8; k++) begin
            recon_p_comb[k] = '0;
        end
        for (int unsigned c = 0; c < 8; c++) begin
            logic [5:0] cand_p;
            cand_p = scan_idx_q + c[5:0];
            if (!committed_mask[cand_p]) begin
                recon_p_comb[recon_pushes_comb[2:0]] = fpreg_t'(cand_p);
                recon_pushes_comb = recon_pushes_comb + 4'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sequential State Update (ARAT, SRAT, Checkpoints & Free List)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            // Reset ARAT_FP and SRAT_FP: f0..f31 map 1:1 to fp0..fp31
            for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
                arat_q[r] <= fpreg_t'(r);
                srat_q[r] <= fpreg_t'(r);
            end

            // Reset branch checkpoints
            for (int unsigned k = 0; k < CHKPT_COUNT; k++) begin
                chkpt_valid_q[k]   <= 1'b0;
                chkpt_rob_idx_q[k] <= '0;
                for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
                    chkpt_srat_q[k][r] <= fpreg_t'(r);
                end
            end

            // Reset Free List: holds exactly fp32..fp63 (32 entries)
            fl_head_q        <= 5'd0;
            fl_tail_q        <= 5'd0;
            fl_count_q       <= 6'd32;
            reconstructing_q <= 1'b0;
            scan_idx_q       <= 6'd0;
            for (int unsigned i = 0; i < FL_FP_DEPTH; i++) begin
                fl_mem_q[i] <= fpreg_t'(6'd32 + 6'(i));
            end
        end else if (flush_valid_i) begin
            // -----------------------------------------------------------------
            // Full Architectural Flush: Flash-restore SRAT_FP <= ARAT_FP
            // Invalidate checkpoints and trigger Free List reconstruction FSM
            // -----------------------------------------------------------------
            for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
                srat_q[r] <= arat_q[r];
            end
            for (int unsigned k = 0; k < CHKPT_COUNT; k++) begin
                chkpt_valid_q[k] <= 1'b0;
            end

            // Initiate Free List reconstruction
            fl_head_q        <= 5'd0;
            fl_tail_q        <= 5'd0;
            fl_count_q       <= 6'd0;
            scan_idx_q       <= 6'd0;
            reconstructing_q <= 1'b1;
        end else if (reconstructing_q) begin
            // -----------------------------------------------------------------
            // Free List Reconstruction FSM (scans 8 physical registers per cycle)
            // -----------------------------------------------------------------
            for (int unsigned c = 0; c < 8; c++) begin
                if (c < recon_pushes_comb) begin
                    fl_mem_q[fl_tail_q + c[4:0]] <= recon_p_comb[c];
                end
            end
            fl_tail_q  <= fl_tail_q + {1'b0, recon_pushes_comb};
            fl_count_q <= fl_count_q + {2'b00, recon_pushes_comb};

            if (scan_idx_q == 6'd56) begin
                reconstructing_q <= 1'b0;
                scan_idx_q       <= 6'd0;
            end else begin
                scan_idx_q <= scan_idx_q + 6'd8;
            end
        end else begin
            // -----------------------------------------------------------------
            // 1. Retirement Update to ARAT_FP (In-Order Commit)
            // -----------------------------------------------------------------
            for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
                if (retire_valid_i[1] && retire_fp_dest_valid_i[1] && (retire_fd_i[1] == fareg_t'(r))) begin
                    arat_q[r] <= retire_pnew_fp_i[1];
                end else if (retire_valid_i[0] && retire_fp_dest_valid_i[0] && (retire_fd_i[0] == fareg_t'(r))) begin
                    arat_q[r] <= retire_pnew_fp_i[0];
                end
            end

            // Release checkpoints upon branch retirement
            if (retire_valid_i[0] && retire_is_branch_i[0]) begin
                chkpt_valid_q[retire_chkpt_id_i[0]] <= 1'b0;
            end
            if (retire_valid_i[1] && retire_is_branch_i[1]) begin
                chkpt_valid_q[retire_chkpt_id_i[1]] <= 1'b0;
            end

            // -----------------------------------------------------------------
            // 2. Branch Misprediction Recovery (Single-Cycle Snapshot Restore)
            // -----------------------------------------------------------------
            if (recover_valid_i) begin
                for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
                    srat_q[r] <= chkpt_srat_q[recover_chkpt_id_i][r];
                end
                chkpt_valid_q[recover_chkpt_id_i] <= 1'b0;

                // Invalidate younger checkpoints
                for (int unsigned k = 0; k < CHKPT_COUNT; k++) begin
                    if (chkpt_valid_q[k] && (chkpt_idx_t'(k) != recover_chkpt_id_i)) begin
                        if (rob_age(chkpt_rob_idx_q[k], rob_head_i) > rob_age(recover_rob_idx_i, rob_head_i)) begin
                            chkpt_valid_q[k] <= 1'b0;
                        end
                    end
                end
            end else begin
                // -------------------------------------------------------------
                // 3. Normal Speculative Rename Allocation
                // -------------------------------------------------------------
                // Allocate branch checkpoints
                if (rename_grant_i[0] && uop0_valid_i && uop0_is_branch_i) begin
                    chkpt_valid_q[chkpt0_id_i]   <= 1'b1;
                    chkpt_rob_idx_q[chkpt0_id_i] <= uop0_rob_idx_i;
                    for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
                        chkpt_srat_q[chkpt0_id_i][r] <= post_uop0_srat[r];
                    end
                end

                if (rename_grant_i[1] && uop1_valid_i && uop1_is_branch_i) begin
                    chkpt_valid_q[chkpt1_id_i]   <= 1'b1;
                    chkpt_rob_idx_q[chkpt1_id_i] <= uop1_rob_idx_i;
                    for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
                        chkpt_srat_q[chkpt1_id_i][r] <= post_uop1_srat[r];
                    end
                end

                // Update SRAT_FP with new destination mappings (uop1 strictly wins over uop0 on WAW)
                for (int unsigned r = 0; r < FAREG_COUNT; r++) begin
                    if (rename_grant_i[1] && uop1_valid_i && uop1_fp_dest_valid_i && (fareg_t'(r) == uop1_fd_i)) begin
                        srat_q[r] <= uop1_pnew_fp_o;
                    end else if (rename_grant_i[0] && uop0_produces_fp && (fareg_t'(r) == uop0_fd_i)) begin
                        srat_q[r] <= uop0_pnew_fp_o;
                    end
                end
            end

            // -----------------------------------------------------------------
            // Free List Update: Simultaneous Pops and Pushes
            // -----------------------------------------------------------------
            // Handle pushes (from retirement and recovery squashes)
            for (int unsigned p = 0; p < 4; p++) begin
                if (p < push_count) begin
                    fl_mem_q[fl_tail_q + p[4:0]] <= push_pregs[p];
                end
            end
            fl_tail_q <= fl_tail_q + {2'b00, push_count};

            // Handle pops (from rename grants)
            fl_head_q <= fl_head_q + {3'b000, alloc_count};

            // Count update
            fl_count_q <= fl_count_q + {3'b000, push_count} - {4'b0000, alloc_count};
        end
    end

endmodule

`endif // FURSOY_S1_FRAT_SV
