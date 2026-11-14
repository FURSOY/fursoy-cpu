`ifndef FURSOY_S1_VEC_IQ_SV
`define FURSOY_S1_VEC_IQ_SV

// =============================================================================
// Fursoy Slice-1 Decoupled Vector Issue Queue (VIQ8) — Milestone 8 Phase D
// =============================================================================
// 8-entry dedicated decoupled Vector Issue Queue.
// Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 8.2, Section 10
//
// Invariants:
// - Capacity: 8 entries (VIQ_DEPTH = 8).
// - Multi-beat Micro-op Beat Expansion (PROP_M8_29):
//     * Automatically expands multi-cycle vector operations across LMUL into sequential
//       execution beats (e.g., LMUL=1: 2 beats of 128-bit SIMD slices; LMUL=2: 4 beats;
//       LMUL=4: 8 beats; LMUL=8: 16 beats; fractional LMUL: 1 beat) without stalling
//       the scalar backend.
// - Age-based circular ROB arbitration: oldest ready entry by rob_dist wins issue.
// - Branch recovery squashes younger entries on recover_valid_i (Section 5.4).
// - Pipeline flush clears all entries on flush_valid_i.
// - Capacity backpressure viq_full_o (HPM event 0x3F: EV_VEC_VIQ_FULL).
// =============================================================================

`include "fursoy_s1_pkg.sv"

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
    // Allocation / Dispatch Interface (from Dispatch/Rename)
    // -------------------------------------------------------------------------
    input  logic              alloc_valid_i,
    input  rob_idx_t          alloc_rob_idx_i,
    input  rob_epoch_t        alloc_rob_epoch_i,
    input  uop_class_t        alloc_uop_class_i,
    input  uop_subop_t        alloc_sub_op_i,
    input  vreg_t             alloc_vd_i,
    input  vreg_t             alloc_vs1_i,
    input  vreg_t             alloc_vs2_i,
    input  logic              alloc_vm_i,       // 0=masked by v0, 1=unmasked
    input  logic              alloc_vs1_ready_i,
    input  logic              alloc_vs2_ready_i,
    input  logic              alloc_vm_ready_i,
    input  vtype_bundle_t     alloc_vtype_i,
    input  logic [8:0]        alloc_vl_i,
    input  logic [8:0]        alloc_vstart_i,
    input  logic [63:0]       alloc_imm_i,
    output logic              alloc_ready_o,

    // -------------------------------------------------------------------------
    // Operand Wakeup / Writeback Snooping Interface
    // -------------------------------------------------------------------------
    input  logic              wb_v_valid_i,
    input  vreg_t             wb_v_paddr_i,

    // -------------------------------------------------------------------------
    // Vector Execution Issue Interface (To SIMD Execution Slices / VMU)
    // -------------------------------------------------------------------------
    input  logic              issue_ready_i,
    output logic              issue_valid_o,
    output rob_idx_t          issue_rob_idx_o,
    output rob_epoch_t        issue_rob_epoch_o,
    output uop_class_t        issue_uop_class_o,
    output uop_subop_t        issue_sub_op_o,
    output vreg_t             issue_vd_o,
    output vreg_t             issue_vs1_o,
    output vreg_t             issue_vs2_o,
    output logic              issue_vm_o,
    output logic [4:0]        issue_beat_idx_o,
    output logic [4:0]        issue_total_beats_o,
    output logic              issue_is_last_beat_o,
    output logic [3:0]        issue_bank_mask_o,
    output vtype_bundle_t     issue_vtype_o,
    output logic [8:0]        issue_vl_o,
    output logic [8:0]        issue_vstart_o,
    output logic [63:0]       issue_imm_o,

    // -------------------------------------------------------------------------
    // Status & Telemetry
    // -------------------------------------------------------------------------
    output logic              viq_full_o,
    output logic [3:0]        viq_count_o
);

    // -------------------------------------------------------------------------
    // VIQ8 Entry Storage Structure
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic           valid;
        rob_idx_t       rob_idx;
        rob_epoch_t     rob_epoch;
        uop_class_t     uop_class;
        uop_subop_t     sub_op;
        vreg_t          vd;
        vreg_t          vs1;
        vreg_t          vs2;
        logic           vm;
        logic           vs1_ready;
        logic           vs2_ready;
        logic           vm_ready;
        vtype_bundle_t  vtype;
        logic [8:0]     vl;
        logic [8:0]     vstart;
        logic [63:0]    imm;
        logic [4:0]     current_beat;
        logic [4:0]     total_beats;
    } viq_entry_t;

    viq_entry_t entries_q [VIQ_DEPTH];

    // Helper: Compute total execution beats based on LMUL and SEW
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [4:0] compute_total_beats(
        input vtype_bundle_t vt,
        input logic [8:0]    vl
    );
        begin
            if (vt.vill || (vl == 9'd0)) begin
                compute_total_beats = 5'd1;
            end else begin
                case (vt.vlmul)
                    VLMUL_1:  compute_total_beats = 5'd2;  // 2 beats of 128-bit slice
                    VLMUL_2:  compute_total_beats = 5'd4;  // 2 registers x 2 beats
                    VLMUL_4:  compute_total_beats = 5'd8;  // 4 registers x 2 beats
                    VLMUL_8:  compute_total_beats = 5'd16; // 8 registers x 2 beats
                    VLMUL_F2,
                    VLMUL_F4,
                    VLMUL_F8: compute_total_beats = 5'd1;  // Fractional LMUL fits in 1 beat
                    default:  compute_total_beats = 5'd1;
                endcase
            end
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // Capacity & Allocation Management
    // -------------------------------------------------------------------------
    logic [3:0] count_q;
    assign viq_count_o = count_q;
    assign viq_full_o  = (count_q == 4'(VIQ_DEPTH));
    assign alloc_ready_o = !viq_full_o;

    // Find first free slot for allocation
    logic [2:0] free_slot;
    logic       has_free_slot;
    always_comb begin
        free_slot     = 3'd0;
        has_free_slot = 1'b0;
        for (int i = 0; i < VIQ_DEPTH; i++) begin
            if (!entries_q[i].valid) begin
                free_slot     = 3'(i);
                has_free_slot = 1'b1;
                break;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Age-Based Arbitration for Issue Selection
    // -------------------------------------------------------------------------
    logic [2:0] sel_slot;
    logic       sel_valid;
    rob_dist_t  oldest_dist;

    always_comb begin
        rob_dist_t d;
        sel_slot    = 3'd0;
        sel_valid   = 1'b0;
        oldest_dist = rob_dist_t'(ROB_DEPTH - 1);
        d           = '0;

        for (int i = 0; i < VIQ_DEPTH; i++) begin
            if (entries_q[i].valid &&
                entries_q[i].vs1_ready &&
                entries_q[i].vs2_ready &&
                entries_q[i].vm_ready) begin
                d = rob_dist(entries_q[i].rob_idx, rob_head_i);
                if (!sel_valid || (d < oldest_dist)) begin
                    sel_slot    = 3'(i);
                    sel_valid   = 1'b1;
                    oldest_dist = d;
                end
            end
        end
    end

    // Drive Issue Interface
    /* verilator lint_off UNUSEDSIGNAL */
    viq_entry_t sel_entry;
    /* verilator lint_on UNUSEDSIGNAL */
    assign sel_entry = entries_q[sel_slot];

    assign issue_valid_o        = sel_valid;
    assign issue_rob_idx_o      = sel_entry.rob_idx;
    assign issue_rob_epoch_o    = sel_entry.rob_epoch;
    assign issue_uop_class_o    = sel_entry.uop_class;
    assign issue_sub_op_o       = sel_entry.sub_op;

    // Multi-beat register indexing across LMUL groups
    assign issue_vd_o           = sel_entry.vd  + vreg_t'({2'b00, sel_entry.current_beat[4:1]});
    assign issue_vs1_o          = sel_entry.vs1 + vreg_t'({2'b00, sel_entry.current_beat[4:1]});
    assign issue_vs2_o          = sel_entry.vs2 + vreg_t'({2'b00, sel_entry.current_beat[4:1]});
    assign issue_vm_o           = sel_entry.vm;

    assign issue_beat_idx_o     = sel_entry.current_beat;
    assign issue_total_beats_o  = sel_entry.total_beats;
    assign issue_is_last_beat_o = (sel_entry.current_beat == (sel_entry.total_beats - 5'd1));

    // Bank masking: Even beats target Banks [1:0] (bits [127:0]), odd beats target Banks [3:2] (bits [255:128])
    assign issue_bank_mask_o    = (sel_entry.current_beat[0] == 1'b0) ? 4'b0011 : 4'b1100;

    assign issue_vtype_o        = sel_entry.vtype;
    assign issue_vl_o           = sel_entry.vl;
    assign issue_vstart_o       = sel_entry.vstart;
    assign issue_imm_o          = sel_entry.imm;

    wire issue_fire = sel_valid && issue_ready_i;

    // -------------------------------------------------------------------------
    // Sequential State Updates
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            for (int i = 0; i < VIQ_DEPTH; i++) begin
                entries_q[i] <= '0;
            end
            count_q <= 4'd0;
        end else begin
            // 1. Branch Misprediction Squash (Recovery)
            if (recover_valid_i) begin
                for (int i = 0; i < VIQ_DEPTH; i++) begin
                    if (entries_q[i].valid) begin
                        if (rob_dist(entries_q[i].rob_idx, rob_head_i) >
                            rob_dist(recover_rob_idx_i, rob_head_i)) begin
                            entries_q[i].valid <= 1'b0;
                        end
                    end
                end
            end

            // 2. Operand Wakeup Snooping
            if (wb_v_valid_i) begin
                for (int i = 0; i < VIQ_DEPTH; i++) begin
                    if (entries_q[i].valid) begin
                        if (entries_q[i].vs1 == wb_v_paddr_i) entries_q[i].vs1_ready <= 1'b1;
                        if (entries_q[i].vs2 == wb_v_paddr_i) entries_q[i].vs2_ready <= 1'b1;
                        if (entries_q[i].vm == 1'b0 && (6'd0 == wb_v_paddr_i)) entries_q[i].vm_ready <= 1'b1;
                    end
                end
            end

            // 3. Issue Beat Execution & Retirement from Queue
            if (issue_fire) begin
                if (sel_entry.current_beat == (sel_entry.total_beats - 5'd1)) begin
                    // Completed last beat: Deallocate entry
                    entries_q[sel_slot].valid <= 1'b0;
                end else begin
                    // Advance to next beat in multi-beat expansion
                    entries_q[sel_slot].current_beat <= sel_entry.current_beat + 5'd1;
                end
            end

            // 4. Allocation of New Micro-ops
            if (alloc_valid_i && has_free_slot && (!recover_valid_i ||
                (rob_dist(alloc_rob_idx_i, rob_head_i) <= rob_dist(recover_rob_idx_i, rob_head_i)))) begin
                entries_q[free_slot].valid        <= 1'b1;
                entries_q[free_slot].rob_idx      <= alloc_rob_idx_i;
                entries_q[free_slot].rob_epoch    <= alloc_rob_epoch_i;
                entries_q[free_slot].uop_class    <= alloc_uop_class_i;
                entries_q[free_slot].sub_op       <= alloc_sub_op_i;
                entries_q[free_slot].vd           <= alloc_vd_i;
                entries_q[free_slot].vs1          <= alloc_vs1_i;
                entries_q[free_slot].vs2          <= alloc_vs2_i;
                entries_q[free_slot].vm           <= alloc_vm_i;
                entries_q[free_slot].vs1_ready    <= alloc_vs1_ready_i;
                entries_q[free_slot].vs2_ready    <= alloc_vs2_ready_i;
                entries_q[free_slot].vm_ready     <= alloc_vm_ready_i;
                entries_q[free_slot].vtype        <= alloc_vtype_i;
                entries_q[free_slot].vl           <= alloc_vl_i;
                entries_q[free_slot].vstart       <= alloc_vstart_i;
                entries_q[free_slot].imm          <= alloc_imm_i;
                entries_q[free_slot].current_beat <= 5'd0;
                entries_q[free_slot].total_beats  <= compute_total_beats(alloc_vtype_i, alloc_vl_i);
            end

            // 5. Active Queue Count Tracking
            begin : count_eval
                logic [3:0] next_count;
                next_count = 4'd0;
                for (int i = 0; i < VIQ_DEPTH; i++) begin
                    logic entry_survives;
                    entry_survives = entries_q[i].valid;
                    if (recover_valid_i && entries_q[i].valid &&
                        (rob_dist(entries_q[i].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        entry_survives = 1'b0;
                    end
                    if (issue_fire && (3'(i) == sel_slot) && (sel_entry.current_beat == (sel_entry.total_beats - 5'd1))) begin
                        entry_survives = 1'b0;
                    end
                    if (entry_survives) next_count = next_count + 4'd1;
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

`endif // FURSOY_S1_VEC_IQ_SV
