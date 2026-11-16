`ifndef FURSOY_S1_RAT_SV
`define FURSOY_S1_RAT_SV

// =============================================================================
// Fursoy Slice-1 Register Alias Table (RAT) & Checkpoint Substrate — Milestone 1
// =============================================================================
// Implements:
// - 32 committed architectural mappings (ARAT)
// - 32 speculative mappings (SRAT)
// - x0 hardwired to p0
// - 2-wide rename interface with:
//   * Intra-group RAW forwarding (uop0 Pnew -> uop1 source)
//   * Intra-group WAW resolution (uop0 Pnew -> uop1 Pold; uop1 wins in SRAT)
//   * rd=x0 destination suppression (maps to p0, 0 physical allocation)
// - Parameterized branch checkpoint array (baseline 8)
//   * Snapshot SRAT & branch ROB index
//   * Branch misprediction restoration to SRAT
//   * Invalidation of younger checkpoints on branch squash
// - Full architectural flush restoration (SRAT <= ARAT)
// - Committed mask generation for Free List reconstruction
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_rat
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned CHKPT_COUNT = NUM_CHECKPOINTS // 8 entries
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // -------------------------------------------------------------------------
    // ROB Head Pointer (for circular age comparison)
    // -------------------------------------------------------------------------
    input  rob_idx_t               rob_head_i,

    // -------------------------------------------------------------------------
    // Rename Source & Destination Query Interface (2-wide)
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    input  uop_rename_in_t         uop0_i,
    input  uop_rename_in_t         uop1_i,
    /* verilator lint_on UNUSEDSIGNAL */

    input  preg_t                  uop0_pnew_i,
    input  preg_t                  uop1_pnew_i,

    // Source physical register lookups
    output preg_t                  uop0_rs1_preg_o,
    output preg_t                  uop0_rs2_preg_o,
    output preg_t                  uop1_rs1_preg_o,
    output preg_t                  uop1_rs2_preg_o,

    // Intra-group RAW flags (for readiness determination)
    output logic                   uop1_rs1_raw_uop0_o,
    output logic                   uop1_rs2_raw_uop0_o,

    // Displaced Pold outputs (recorded into ROB entries)
    output preg_t                  uop0_pold_o,
    output preg_t                  uop1_pold_o,

    // Rename Grants (sequential SRAT update enables)
    input  logic [1:0]             rename_grant_i,

    // -------------------------------------------------------------------------
    // Branch Checkpoint Allocation Interface
    // -------------------------------------------------------------------------
    input  rob_idx_t               uop0_rob_idx_i,
    input  rob_idx_t               uop1_rob_idx_i,

    output chkpt_idx_t             chkpt0_id_o,
    output chkpt_idx_t             chkpt1_id_o,
    output logic                   chkpt0_avail_o,
    output logic                   chkpt1_avail_o,
    output logic [4:0]             chkpt_free_count_o,

    // -------------------------------------------------------------------------
    // Retirement Commit Interface (ARAT Updates & Checkpoint Release)
    // -------------------------------------------------------------------------
    input  logic [1:0]             retire_valid_i,
    input  areg_t                  retire_rd_i   [1:0],
    input  preg_t                  retire_pnew_i [1:0],
    input  logic [1:0]             retire_is_branch_i,
    input  chkpt_idx_t             retire_chkpt_id_i [1:0],

    // -------------------------------------------------------------------------
    // Branch Recovery Interface
    // -------------------------------------------------------------------------
    input  logic                   recover_valid_i,
    input  chkpt_idx_t             recover_chkpt_id_i,
    input  rob_idx_t               recover_rob_idx_i,

    // -------------------------------------------------------------------------
    // Full Architectural Flush Interface
    // -------------------------------------------------------------------------
    input  logic                   flush_valid_i,

    // -------------------------------------------------------------------------
    // Status & Diagnostic Exports
    // -------------------------------------------------------------------------
    output preg_t                  arat_o [AREG_COUNT],
    output preg_t                  srat_o [AREG_COUNT],
    output logic [PRF_SIZE-1:0]    committed_mask_o
);

    // -------------------------------------------------------------------------
    // RAT Storage Elements
    // -------------------------------------------------------------------------
    preg_t arat_q [AREG_COUNT];
    preg_t srat_q [AREG_COUNT];

    // Branch Checkpoint Table: 2D arrays for clean synthesis & simulation
    logic     chkpt_valid_q   [CHKPT_COUNT];
    rob_idx_t chkpt_rob_idx_q [CHKPT_COUNT];
    preg_t    chkpt_srat_q    [CHKPT_COUNT][AREG_COUNT];

    // -------------------------------------------------------------------------
    // Circular Age Helper Function
    // -------------------------------------------------------------------------
    function automatic rob_dist_t rob_age(input rob_idx_t idx, input rob_idx_t head);
        return rob_dist(idx, head);
    endfunction

    // -------------------------------------------------------------------------
    // Rename Source Lookup & Intra-group RAW Dependency Logic
    // -------------------------------------------------------------------------
    // uop0 sources directly read SRAT
    assign uop0_rs1_preg_o = (uop0_i.rs1 == 5'd0) ? preg_t'(0) : srat_q[uop0_i.rs1];
    assign uop0_rs2_preg_o = (uop0_i.rs2 == 5'd0) ? preg_t'(0) : srat_q[uop0_i.rs2];

    // uop0/uop1 produce a destination register?
    wire uop0_produces_rd = uop0_i.valid && (!uop0_i.fp_dest_valid) && (uop0_i.rd != 5'd0);
    wire uop1_produces_rd = uop1_i.valid && (!uop1_i.fp_dest_valid) && (uop1_i.rd != 5'd0);

    // Intra-group RAW detection for uop1
    assign uop1_rs1_raw_uop0_o = uop0_produces_rd && (uop1_i.rs1 == uop0_i.rd);
    assign uop1_rs2_raw_uop0_o = uop0_produces_rd && (uop1_i.rs2 == uop0_i.rd);

    // uop1 source resolution
    assign uop1_rs1_preg_o = (uop1_i.rs1 == 5'd0)        ? preg_t'(0) :
                             uop1_rs1_raw_uop0_o         ? uop0_pnew_i :
                                                           srat_q[uop1_i.rs1];

    assign uop1_rs2_preg_o = (uop1_i.rs2 == 5'd0)        ? preg_t'(0) :
                             uop1_rs2_raw_uop0_o         ? uop0_pnew_i :
                                                           srat_q[uop1_i.rs2];

    // -------------------------------------------------------------------------
    // Destination Pold Resolution & Intra-group WAW Handling
    // -------------------------------------------------------------------------
    // uop0 displaced Pold
    assign uop0_pold_o = ((uop0_i.rd == 5'd0) || uop0_i.fp_dest_valid) ? preg_t'(0) : srat_q[uop0_i.rd];

    // Intra-group WAW detection for uop1
    wire uop1_waw_uop0 = uop0_produces_rd && (uop1_i.rd == uop0_i.rd);

    // uop1 displaced Pold: if intra-group WAW, uop1's Pold is uop0's Pnew!
    assign uop1_pold_o = ((uop1_i.rd == 5'd0) || uop1_i.fp_dest_valid) ? preg_t'(0) :
                         uop1_waw_uop0       ? uop0_pnew_i :
                                               srat_q[uop1_i.rd];

    // -------------------------------------------------------------------------
    // Checkpoint Allocation Logic
    // -------------------------------------------------------------------------
    // Priority encoder to find first two free checkpoint IDs
    chkpt_idx_t free_chkpt0;
    chkpt_idx_t free_chkpt1;
    logic [4:0] num_free_chkpts;

    always_comb begin
        free_chkpt0      = '0;
        free_chkpt1      = '0;
        num_free_chkpts  = 5'd0;

        for (int unsigned k = 0; k < CHKPT_COUNT; k++) begin
            if (!chkpt_valid_q[k]) begin
                if (num_free_chkpts == 5'd0) begin
                    free_chkpt0 = chkpt_idx_t'(k);
                end else if (num_free_chkpts == 5'd1) begin
                    free_chkpt1 = chkpt_idx_t'(k);
                end
                num_free_chkpts = num_free_chkpts + 5'd1;
            end
        end
    end

    assign chkpt_free_count_o = num_free_chkpts;
    assign chkpt0_id_o        = free_chkpt0;
    assign chkpt1_id_o        = (uop0_i.is_branch) ? free_chkpt1 : free_chkpt0;

    assign chkpt0_avail_o     = (num_free_chkpts >= 5'd1);
    assign chkpt1_avail_o     = (uop0_i.is_branch) ? (num_free_chkpts >= 5'd2) :
                                                     (num_free_chkpts >= 5'd1);

    // Snapshots of SRAT for checkpoints
    preg_t post_uop0_srat [AREG_COUNT];
    preg_t post_uop1_srat [AREG_COUNT];
    always_comb begin
        for (int unsigned r = 0; r < AREG_COUNT; r++) begin
            if (uop0_produces_rd && (areg_t'(r) == uop0_i.rd)) begin
                post_uop0_srat[r] = uop0_pnew_i;
            end else begin
                post_uop0_srat[r] = srat_q[r];
            end
        end

        for (int unsigned r = 0; r < AREG_COUNT; r++) begin
            if (uop1_produces_rd && (areg_t'(r) == uop1_i.rd)) begin
                post_uop1_srat[r] = uop1_pnew_i;
            end else begin
                post_uop1_srat[r] = post_uop0_srat[r];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Status & Committed Mask Generation
    // -------------------------------------------------------------------------
    always_comb begin
        committed_mask_o = '0;
        committed_mask_o[0] = 1'b1; // p0 is always committed / architectural
        for (int unsigned r = 1; r < AREG_COUNT; r++) begin
            committed_mask_o[arat_q[r]] = 1'b1;
        end
    end

    assign arat_o = arat_q;
    assign srat_o = srat_q;

    // -------------------------------------------------------------------------
    // Sequential State Update (ARAT, SRAT, Checkpoints)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int unsigned r = 0; r < AREG_COUNT; r++) begin
                arat_q[r] <= preg_t'(r);
                srat_q[r] <= preg_t'(r);
            end
            for (int unsigned k = 0; k < CHKPT_COUNT; k++) begin
                chkpt_valid_q[k]   <= 1'b0;
                chkpt_rob_idx_q[k] <= '0;
                for (int unsigned r = 0; r < AREG_COUNT; r++) begin
                    chkpt_srat_q[k][r] <= preg_t'(r);
                end
            end
        end else if (flush_valid_i) begin
            // -----------------------------------------------------------------
            // Full Architectural Flush: Absolute Highest Priority
            // -----------------------------------------------------------------
            // SRAT flash-restored from ARAT
            for (int unsigned r = 0; r < AREG_COUNT; r++) begin
                srat_q[r] <= arat_q[r];
            end
            // Invalidate all branch checkpoints
            for (int unsigned k = 0; k < CHKPT_COUNT; k++) begin
                chkpt_valid_q[k] <= 1'b0;
            end
        end else begin
            // -----------------------------------------------------------------
            // 1. Retirement Update to ARAT (In-Order Commit)
            // -----------------------------------------------------------------
            if (retire_valid_i[0] && (retire_rd_i[0] != 5'd0)) begin
                arat_q[retire_rd_i[0]] <= retire_pnew_i[0];
            end
            if (retire_valid_i[1] && (retire_rd_i[1] != 5'd0)) begin
                arat_q[retire_rd_i[1]] <= retire_pnew_i[1];
            end
            // Ensure p0 is hardwired to 0
            arat_q[0] <= preg_t'(0);

            // Checkpoint release on branch retirement
            if (retire_valid_i[0] && retire_is_branch_i[0]) begin
                chkpt_valid_q[retire_chkpt_id_i[0]] <= 1'b0;
            end
            if (retire_valid_i[1] && retire_is_branch_i[1]) begin
                chkpt_valid_q[retire_chkpt_id_i[1]] <= 1'b0;
            end

            // -----------------------------------------------------------------
            // 2. Branch Misprediction Recovery
            // -----------------------------------------------------------------
            if (recover_valid_i) begin
                // Restore SRAT combinationally from the mispredicted branch's checkpoint
                for (int unsigned r = 0; r < AREG_COUNT; r++) begin
                    srat_q[r] <= chkpt_srat_q[recover_chkpt_id_i][r];
                end
                // Release the mispredicted branch's checkpoint
                chkpt_valid_q[recover_chkpt_id_i] <= 1'b0;

                // Invalidate all younger branch checkpoints
                for (int unsigned k = 0; k < CHKPT_COUNT; k++) begin
                    if (chkpt_valid_q[k] && (chkpt_idx_t'(k) != recover_chkpt_id_i)) begin
                        if (rob_age(chkpt_rob_idx_q[k], rob_head_i) > rob_age(recover_rob_idx_i, rob_head_i)) begin
                            chkpt_valid_q[k] <= 1'b0;
                        end
                    end
                end
            end else begin
                // -------------------------------------------------------------
                // 3. Normal Rename Speculative Allocation
                // -------------------------------------------------------------
                // Allocate branch checkpoints
                if (rename_grant_i[0] && uop0_i.valid && uop0_i.is_branch) begin
                    chkpt_valid_q[free_chkpt0]   <= 1'b1;
                    chkpt_rob_idx_q[free_chkpt0] <= uop0_rob_idx_i;
                    for (int unsigned r = 0; r < AREG_COUNT; r++) begin
                        chkpt_srat_q[free_chkpt0][r] <= post_uop0_srat[r];
                    end
                end

                if (rename_grant_i[1] && uop1_i.valid && uop1_i.is_branch) begin
                    chkpt_valid_q[chkpt1_id_o]   <= 1'b1;
                    chkpt_rob_idx_q[chkpt1_id_o] <= uop1_rob_idx_i;
                    for (int unsigned r = 0; r < AREG_COUNT; r++) begin
                        chkpt_srat_q[chkpt1_id_o][r] <= post_uop1_srat[r];
                    end
                end

                // Update SRAT with new destination mappings
                if (rename_grant_i[0] && uop0_produces_rd) begin
                    srat_q[uop0_i.rd] <= uop0_pnew_i;
                end
                if (rename_grant_i[1] && uop1_produces_rd) begin
                    srat_q[uop1_i.rd] <= uop1_pnew_i;
                end
                // Permanent p0 invariant
                srat_q[0] <= preg_t'(0);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Simulation Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS

    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            // x0 permanently mapped to p0
            if (arat_q[0] != preg_t'(0)) begin
                $fatal(1, "[RAT ASSERTION FAILED] ARAT[0] != p0! (p%0d)", arat_q[0]);
            end
            if (srat_q[0] != preg_t'(0)) begin
                $fatal(1, "[RAT ASSERTION FAILED] SRAT[0] != p0! (p%0d)", srat_q[0]);
            end

            // All ARAT and SRAT mappings must be valid physical registers (< PRF_SIZE)
            for (int unsigned r = 0; r < AREG_COUNT; r++) begin
                if (arat_q[r] >= PRF_SIZE[PRF_IDX_W-1:0]) begin
                    $fatal(1, "[RAT ASSERTION FAILED] ARAT[%0d] = %0d >= PRF_SIZE", r, arat_q[r]);
                end
                if (srat_q[r] >= PRF_SIZE[PRF_IDX_W-1:0]) begin
                    $fatal(1, "[RAT ASSERTION FAILED] SRAT[%0d] = %0d >= PRF_SIZE", r, srat_q[r]);
                end
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_RAT_SV
