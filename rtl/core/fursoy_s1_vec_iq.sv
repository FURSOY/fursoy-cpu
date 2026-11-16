`ifndef FURSOY_S1_VEC_IQ_SV
`define FURSOY_S1_VEC_IQ_SV

// =============================================================================
// Fursoy Slice-1 Decoupled Out-of-Order Vector Issue Queue (VIQ8)
// =============================================================================
// Features:
// - 8-entry decoupled Vector Issue Queue fed by fursoy_s1_vrat (64 physical
//   vector registers) and fursoy_s1_rat scalar register readiness.
// - Independent per-operand physical register dependency tracking across LMUL<=8
//   register groups (vs1[0..7], vs2[0..7], old_vd[0..7], vs3[0..7], v0, rs1, rs2).
// - True Out-of-Order age-based arbitration (minimum rob_dist) for Vector ALU
//   instructions; strict ROB-head serialization for Vector Memory instructions.
// - Full branch misprediction squash and full architectural flush support.
// =============================================================================

`include "fursoy_s1_pkg.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_vec_iq
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Pipeline Flush & Branch Misprediction Recovery
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    // -------------------------------------------------------------------------
    // Allocation / Dispatch Interface (from Decode + VRAT/RAT)
    // -------------------------------------------------------------------------
    input  logic              alloc_valid_i,
    input  rob_idx_t          alloc_rob_idx_i,
    input  rob_epoch_t        alloc_rob_epoch_i,
    input  uop_class_t        alloc_uop_class_i,
    input  uop_subop_t        alloc_sub_op_i,
    input  logic              alloc_dest_valid_i,
    input  logic              alloc_is_mem_i,
    input  logic              alloc_uses_vs1_i,
    input  logic              alloc_uses_vs2_i,
    input  logic              alloc_vm_i,
    input  logic              alloc_uses_rs1_i,
    input  logic              alloc_uses_rs2_i,
    input  logic              alloc_use_imm_i,
    input  preg_t             alloc_prs1_i,
    input  logic              alloc_prs1_ready_i,
    input  preg_t             alloc_prs2_i,
    input  logic              alloc_prs2_ready_i,
    input  logic [3:0]        alloc_vd_ngroups_i,
    input  logic [3:0]        alloc_vs1_ngroups_i,
    input  logic [3:0]        alloc_vs2_ngroups_i,
    input  vreg_t             alloc_vd_map_i      [8],
    input  vreg_t             alloc_old_vd_map_i  [8],
    input  vreg_t             alloc_vs1_map_i     [8],
    input  vreg_t             alloc_vs2_map_i     [8],
    input  vreg_t             alloc_vm_preg_i,
    input  logic [7:0]        alloc_old_vd_ready_i,
    input  logic [7:0]        alloc_vs1_ready_i,
    input  logic [7:0]        alloc_vs2_ready_i,
    input  logic              alloc_vm_ready_i,
    input  logic              alloc_need_old_vd_i,
    input  vtype_bundle_t     alloc_vtype_i,
    input  logic [8:0]        alloc_vl_i,
    input  logic [8:0]        alloc_vstart_i,
    input  logic [2:0]        alloc_eew_i,
    input  logic [63:0]       alloc_imm_i,
    output logic              alloc_ready_o,

    // -------------------------------------------------------------------------
    // Operand Wakeup / Writeback Snooping Interface
    // -------------------------------------------------------------------------
    input  logic [VRF_NUM_PREGS-1:0] wb_v_mask_i,
    input  logic [4:0]        wb_s_valid_i,
    input  preg_t             wb_s_paddr_i        [4:0],

    // -------------------------------------------------------------------------
    // Vector Execution Issue Interface (To Parallel SIMD / VMU Execution Unit)
    // -------------------------------------------------------------------------
    input  logic              issue_ready_i,
    output logic              issue_valid_o,
    output rob_idx_t          issue_rob_idx_o,
    output rob_epoch_t        issue_rob_epoch_o,
    output uop_class_t        issue_uop_class_o,
    output uop_subop_t        issue_sub_op_o,
    output logic              issue_dest_valid_o,
    output logic              issue_is_mem_o,
    output logic              issue_uses_vs1_o,
    output logic              issue_uses_vs2_o,
    output logic              issue_vm_o,
    output logic              issue_uses_rs1_o,
    output logic              issue_uses_rs2_o,
    output logic              issue_use_imm_o,
    output preg_t             issue_prs1_o,
    output preg_t             issue_prs2_o,
    output logic [3:0]        issue_vd_ngroups_o,
    output logic [3:0]        issue_vs1_ngroups_o,
    output logic [3:0]        issue_vs2_ngroups_o,
    output vreg_t             issue_vd_map_o      [8],
    output vreg_t             issue_old_vd_map_o  [8],
    output vreg_t             issue_vs1_map_o     [8],
    output vreg_t             issue_vs2_map_o     [8],
    output vreg_t             issue_vm_preg_o,
    output logic              issue_need_old_vd_o,
    output vtype_bundle_t     issue_vtype_o,
    output logic [8:0]        issue_vl_o,
    output logic [8:0]        issue_vstart_o,
    output logic [2:0]        issue_eew_o,
    output logic [63:0]       issue_imm_o,

    // -------------------------------------------------------------------------
    // Status & Telemetry
    // -------------------------------------------------------------------------
    output logic              viq_full_o,
    output logic [3:0]        viq_count_o,
    output logic              viq_has_mem_o
);

    typedef struct packed {
        logic           valid;
        rob_idx_t       rob_idx;
        rob_epoch_t     rob_epoch;
        uop_class_t     uop_class;
        uop_subop_t     sub_op;
        logic           dest_valid;
        logic           is_mem;
        logic           uses_vs1;
        logic           uses_vs2;
        logic           vm;
        logic           uses_rs1;
        logic           uses_rs2;
        logic           use_imm;
        preg_t          prs1;
        logic           prs1_ready;
        preg_t          prs2;
        logic           prs2_ready;
        logic [3:0]     vd_ngroups;
        logic [3:0]     vs1_ngroups;
        logic [3:0]     vs2_ngroups;
        logic [47:0]    vd_map_flat;
        logic [47:0]    old_vd_map_flat;
        logic [47:0]    vs1_map_flat;
        logic [47:0]    vs2_map_flat;
        vreg_t          vm_preg;
        logic [7:0]     old_vd_ready;
        logic [7:0]     vs3_ready;
        logic [7:0]     vs1_ready;
        logic [7:0]     vs2_ready;
        logic           vm_ready;
        logic           need_old_vd;
        vtype_bundle_t  vtype;
        logic [8:0]     vl;
        logic [8:0]     vstart;
        logic [2:0]     eew;
        logic [63:0]    imm;
    } viq_entry_t;

    viq_entry_t entries_q [VIQ_DEPTH];

    logic [3:0] count_q;
    assign viq_count_o   = count_q;
    assign viq_full_o    = (count_q == 4'(VIQ_DEPTH));
    assign alloc_ready_o = !viq_full_o;

    // -------------------------------------------------------------------------
    // Free Slot Lookup & Active Memory Tracking
    // -------------------------------------------------------------------------
    logic [2:0] free_slot;
    logic       has_free_slot;
    logic       has_mem_q;

    always_comb begin
        free_slot     = 3'd0;
        has_free_slot = 1'b0;
        has_mem_q     = 1'b0;
        for (int i = 0; i < VIQ_DEPTH; i++) begin
            if (!entries_q[i].valid && !has_free_slot) begin
                free_slot     = 3'(i);
                has_free_slot = 1'b1;
            end
            if (entries_q[i].valid && entries_q[i].is_mem) begin
                has_mem_q = 1'b1;
            end
        end
    end

    assign viq_has_mem_o = has_mem_q;

    // -------------------------------------------------------------------------
    // Operand Readiness & Age-Based Issue Arbitration
    // -------------------------------------------------------------------------
    logic [VIQ_DEPTH-1:0] entry_ready;
    logic [2:0]           sel_slot;
    logic                 sel_valid;
    rob_dist_t            oldest_dist;

    always_comb begin
        rob_dist_t d;
        sel_slot    = 3'd0;
        sel_valid   = 1'b0;
        oldest_dist = rob_dist_t'(ROB_DEPTH - 1);
        d           = '0;

        for (int i = 0; i < VIQ_DEPTH; i++) begin
            logic vs1_ok, vs2_ok, old_vd_ok, vs3_ok, vm_ok, s1_ok, s2_ok, mem_ok;
            vs1_ok    = !entries_q[i].uses_vs1 || (&entries_q[i].vs1_ready);
            vs2_ok    = !entries_q[i].uses_vs2 || (&entries_q[i].vs2_ready);
            old_vd_ok = !entries_q[i].need_old_vd || (&entries_q[i].old_vd_ready);
            vs3_ok    = !(entries_q[i].is_mem && !entries_q[i].dest_valid) || (&entries_q[i].vs3_ready);
            vm_ok     = entries_q[i].vm || entries_q[i].vm_ready;
            s1_ok     = !entries_q[i].uses_rs1 || entries_q[i].prs1_ready;
            s2_ok     = !entries_q[i].uses_rs2 || entries_q[i].prs2_ready;
            mem_ok    = !entries_q[i].is_mem || (entries_q[i].rob_idx == rob_head_i);

            entry_ready[i] = entries_q[i].valid &&
                             vs1_ok && vs2_ok && old_vd_ok && vs3_ok && vm_ok &&
                             s1_ok && s2_ok && mem_ok;

            if (entry_ready[i]) begin
                d = rob_dist(entries_q[i].rob_idx, rob_head_i);
                if (!sel_valid || (d < oldest_dist)) begin
                    sel_slot    = 3'(i);
                    sel_valid   = 1'b1;
                    oldest_dist = d;
                end
            end
        end
    end

    viq_entry_t sel_entry;
    assign sel_entry = entries_q[sel_slot];

    assign issue_valid_o       = sel_valid;
    assign issue_rob_idx_o     = sel_entry.rob_idx;
    assign issue_rob_epoch_o   = sel_entry.rob_epoch;
    assign issue_uop_class_o   = sel_entry.uop_class;
    assign issue_sub_op_o      = sel_entry.sub_op;
    assign issue_dest_valid_o  = sel_entry.dest_valid;
    assign issue_is_mem_o      = sel_entry.is_mem;
    assign issue_uses_vs1_o    = sel_entry.uses_vs1;
    assign issue_uses_vs2_o    = sel_entry.uses_vs2;
    assign issue_vm_o          = sel_entry.vm;
    assign issue_uses_rs1_o    = sel_entry.uses_rs1;
    assign issue_uses_rs2_o    = sel_entry.uses_rs2;
    assign issue_use_imm_o     = sel_entry.use_imm;
    assign issue_prs1_o        = sel_entry.prs1;
    assign issue_prs2_o        = sel_entry.prs2;
    assign issue_vd_ngroups_o  = sel_entry.vd_ngroups;
    assign issue_vs1_ngroups_o = sel_entry.vs1_ngroups;
    assign issue_vs2_ngroups_o = sel_entry.vs2_ngroups;
    assign issue_vm_preg_o     = sel_entry.vm_preg;
    assign issue_need_old_vd_o = sel_entry.need_old_vd;
    assign issue_vtype_o       = sel_entry.vtype;
    assign issue_vl_o          = sel_entry.vl;
    assign issue_vstart_o      = sel_entry.vstart;
    assign issue_eew_o         = sel_entry.eew;
    assign issue_imm_o         = sel_entry.imm;

    always_comb begin
        for (int g = 0; g < 8; g++) begin
            issue_vd_map_o[g]     = sel_entry.vd_map_flat[g*6 +: 6];
            issue_old_vd_map_o[g] = sel_entry.old_vd_map_flat[g*6 +: 6];
            issue_vs1_map_o[g]    = sel_entry.vs1_map_flat[g*6 +: 6];
            issue_vs2_map_o[g]    = sel_entry.vs2_map_flat[g*6 +: 6];
        end
    end

    wire issue_fire = sel_valid && issue_ready_i;

    // Helper: scalar writeback match across P0..P4
    function automatic logic scalar_wb_hit(
        input preg_t      p,
        input logic [4:0] wb_v,
        input preg_t      wb_p [4:0]
    );
        logic hit;
        hit = 1'b0;
        for (int w = 0; w < 5; w++) begin
            if (wb_v[w] && (wb_p[w] == p)) hit = 1'b1;
        end
        return hit;
    endfunction

    // -------------------------------------------------------------------------
    // Sequential State Maintenance
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            for (int i = 0; i < VIQ_DEPTH; i++) begin
                entries_q[i] <= '0;
            end
            count_q <= 4'd0;
        end else begin
            // 1. Branch Misprediction Squash + Wakeup Updates
            for (int i = 0; i < VIQ_DEPTH; i++) begin
                if (entries_q[i].valid) begin
                    if (recover_valid_i &&
                        (rob_dist(entries_q[i].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        entries_q[i].valid <= 1'b0;
                    end else if (issue_fire && (3'(i) == sel_slot)) begin
                        entries_q[i].valid <= 1'b0;
                    end else begin
                        // Vector physical register wakeup across all 8 map slots
                        for (int g = 0; g < 8; g++) begin
                            if (wb_v_mask_i[entries_q[i].old_vd_map_flat[g*6 +: 6]])
                                entries_q[i].old_vd_ready[g] <= 1'b1;
                            if (wb_v_mask_i[entries_q[i].vd_map_flat[g*6 +: 6]])
                                entries_q[i].vs3_ready[g] <= 1'b1;
                            if (wb_v_mask_i[entries_q[i].vs1_map_flat[g*6 +: 6]])
                                entries_q[i].vs1_ready[g] <= 1'b1;
                            if (wb_v_mask_i[entries_q[i].vs2_map_flat[g*6 +: 6]])
                                entries_q[i].vs2_ready[g] <= 1'b1;
                        end
                        if (wb_v_mask_i[entries_q[i].vm_preg]) begin
                            entries_q[i].vm_ready <= 1'b1;
                        end

                        // Scalar physical register wakeup
                        if (scalar_wb_hit(entries_q[i].prs1, wb_s_valid_i, wb_s_paddr_i))
                            entries_q[i].prs1_ready <= 1'b1;
                        if (scalar_wb_hit(entries_q[i].prs2, wb_s_valid_i, wb_s_paddr_i))
                            entries_q[i].prs2_ready <= 1'b1;
                    end
                end
            end

            // 2. Allocation of New Vector Micro-op
            if (alloc_valid_i && has_free_slot && (!recover_valid_i ||
                (rob_dist(alloc_rob_idx_i, rob_head_i) <= rob_dist(recover_rob_idx_i, rob_head_i)))) begin
                entries_q[free_slot].valid       <= 1'b1;
                entries_q[free_slot].rob_idx     <= alloc_rob_idx_i;
                entries_q[free_slot].rob_epoch   <= alloc_rob_epoch_i;
                entries_q[free_slot].uop_class   <= alloc_uop_class_i;
                entries_q[free_slot].sub_op      <= alloc_sub_op_i;
                entries_q[free_slot].dest_valid  <= alloc_dest_valid_i;
                entries_q[free_slot].is_mem      <= alloc_is_mem_i;
                entries_q[free_slot].uses_vs1    <= alloc_uses_vs1_i;
                entries_q[free_slot].uses_vs2    <= alloc_uses_vs2_i;
                entries_q[free_slot].vm          <= alloc_vm_i;
                entries_q[free_slot].uses_rs1    <= alloc_uses_rs1_i;
                entries_q[free_slot].uses_rs2    <= alloc_uses_rs2_i;
                entries_q[free_slot].use_imm     <= alloc_use_imm_i;
                entries_q[free_slot].prs1        <= alloc_prs1_i;
                entries_q[free_slot].prs1_ready  <= alloc_prs1_ready_i || scalar_wb_hit(alloc_prs1_i, wb_s_valid_i, wb_s_paddr_i);
                entries_q[free_slot].prs2        <= alloc_prs2_i;
                entries_q[free_slot].prs2_ready  <= alloc_prs2_ready_i || scalar_wb_hit(alloc_prs2_i, wb_s_valid_i, wb_s_paddr_i);
                entries_q[free_slot].vd_ngroups  <= alloc_vd_ngroups_i;
                entries_q[free_slot].vs1_ngroups <= alloc_vs1_ngroups_i;
                entries_q[free_slot].vs2_ngroups <= alloc_vs2_ngroups_i;
                for (int g = 0; g < 8; g++) begin
                    entries_q[free_slot].vd_map_flat[g*6 +: 6]     <= alloc_vd_map_i[g];
                    entries_q[free_slot].old_vd_map_flat[g*6 +: 6] <= alloc_old_vd_map_i[g];
                    entries_q[free_slot].vs1_map_flat[g*6 +: 6]    <= alloc_vs1_map_i[g];
                    entries_q[free_slot].vs2_map_flat[g*6 +: 6]    <= alloc_vs2_map_i[g];
                    entries_q[free_slot].old_vd_ready[g]           <= alloc_old_vd_ready_i[g] || wb_v_mask_i[alloc_old_vd_map_i[g]];
                    entries_q[free_slot].vs3_ready[g]              <= (alloc_dest_valid_i || (4'(g) >= alloc_vd_ngroups_i)) ? 1'b1
                                                                      : (alloc_old_vd_ready_i[g] || wb_v_mask_i[alloc_vd_map_i[g]]);
                    entries_q[free_slot].vs1_ready[g]              <= alloc_vs1_ready_i[g] || wb_v_mask_i[alloc_vs1_map_i[g]];
                    entries_q[free_slot].vs2_ready[g]              <= alloc_vs2_ready_i[g] || wb_v_mask_i[alloc_vs2_map_i[g]];
                end
                entries_q[free_slot].vm_preg     <= alloc_vm_preg_i;
                entries_q[free_slot].vm_ready    <= alloc_vm_ready_i || wb_v_mask_i[alloc_vm_preg_i];
                entries_q[free_slot].need_old_vd <= alloc_need_old_vd_i;
                entries_q[free_slot].vtype       <= alloc_vtype_i;
                entries_q[free_slot].vl          <= alloc_vl_i;
                entries_q[free_slot].vstart      <= alloc_vstart_i;
                entries_q[free_slot].eew         <= alloc_eew_i;
                entries_q[free_slot].imm         <= alloc_imm_i;
            end

            // 3. Active Count Update
            begin : blk_cnt
                logic [3:0] next_count;
                next_count = 4'd0;
                for (int i = 0; i < VIQ_DEPTH; i++) begin
                    logic surv;
                    surv = entries_q[i].valid;
                    if (recover_valid_i && entries_q[i].valid &&
                        (rob_dist(entries_q[i].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        surv = 1'b0;
                    end
                    if (issue_fire && (3'(i) == sel_slot)) begin
                        surv = 1'b0;
                    end
                    if (surv) next_count = next_count + 4'd1;
                end
                if (alloc_valid_i && has_free_slot && (!recover_valid_i ||
                    (rob_dist(alloc_rob_idx_i, rob_head_i) <= rob_dist(recover_rob_idx_i, rob_head_i)))) begin
                    next_count = next_count + 4'd1;
                end
                count_q <= next_count;
            end
        end
    end

endmodule
/* verilator lint_on UNUSEDSIGNAL */

`endif // FURSOY_S1_VEC_IQ_SV
