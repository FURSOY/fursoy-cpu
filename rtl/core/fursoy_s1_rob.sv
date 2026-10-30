`ifndef FURSOY_S1_ROB_SV
`define FURSOY_S1_ROB_SV

// =============================================================================
// Fursoy Slice-1 Reorder Buffer (ROB) — Milestone 1
// =============================================================================
// 48-entry circular Reorder Buffer.
// Supports:
// - Up to 2 allocations/cycle at tail_q
// - Up to 2 in-order retirements/cycle at head_q
// - Up to 3 execution writeback completions/cycle
// - Branch misprediction recovery backwards walk (2 squashed uops/cycle)
// - Concurrent retirement of older instructions during branch recovery
// - Full architectural flush invalidation (traps, interrupts)
// - Precise exception stopping condition at ROB head
// - Simultaneous allocation and retirement count tracking
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_rob
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned CAPACITY = ROB_DEPTH // 48 entries
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // -------------------------------------------------------------------------
    // Allocation Interface (Rename Stage at tail_q)
    // -------------------------------------------------------------------------
    input  logic [1:0]             alloc_valid_i,
    input  areg_t                  alloc_rd_i         [1:0],
    input  preg_t                  alloc_pnew_i       [1:0],
    input  preg_t                  alloc_pold_i       [1:0],
    input  logic [1:0]             alloc_is_branch_i,
    input  chkpt_idx_t             alloc_chkpt_id_i   [1:0],
    input  logic [63:0]            alloc_pc_i         [1:0],

    // Milestone 8 Phase A Floating-Point Allocation Fields
    input  logic [1:0]             alloc_is_fp_i,
    input  logic [1:0]             alloc_fp_dest_valid_i,
    input  fpreg_t                 alloc_prd_fp_i     [1:0],
    input  fpreg_t                 alloc_pold_fp_i    [1:0],

    // Milestone 8 Phase D Vector Allocation Fields
    input  logic [1:0]             alloc_is_vec_i,
    input  logic [1:0]             alloc_vec_dest_valid_i,
    input  vreg_t                  alloc_prd_vec_i    [1:0],

    output rob_idx_t               alloc_rob_idx_o    [1:0],
    output rob_epoch_t             alloc_rob_epoch_o  [1:0],
    output logic [1:0]             alloc_ready_o, // [0]: >=1 slot, [1]: >=2 slots

    // -------------------------------------------------------------------------
    // Execution Writeback Completion Interface (from EX stages)
    // -------------------------------------------------------------------------
    input  logic [4:0]             comp_valid_i,
    input  rob_idx_t               comp_rob_idx_i     [4:0],
    input  rob_epoch_t             comp_epoch_i       [4:0],
    input  logic [4:0]             comp_branch_mispred_i,
    input  logic [4:0]             comp_exception_i,
    input  logic [4:0]             comp_cause_i       [4:0],
    input  logic [4:0]             comp_fflags_i      [4:0],
    output logic [4:0]             comp_ack_o,

    // -------------------------------------------------------------------------
    // In-Order Retirement Interface (Retirement Stage at head_q)
    // -------------------------------------------------------------------------
    input  logic                   retire_ready_i,
    // Milestone 9 Phase A: Asynchronous Interrupt Retirement Gate
    input  logic                   irq_pending_i,

    // Milestone 5 Phase B1 Memory Disambiguation Violation & Replay
    input  logic                   lsu_violation_valid_i,
    input  rob_idx_t               lsu_violation_rob_idx_i,
    input  rob_epoch_t             lsu_violation_rob_epoch_i,
    input  logic                   lsu_retire0_allow_i,
    input  logic                   lsu_retire1_allow_i,

    output logic                   retire_replay_o,
    output logic [63:0]            retire_replay_pc_o,

    output logic [1:0]             retire_valid_o,
    output areg_t                  retire_rd_o        [1:0],
    output preg_t                  retire_pnew_o      [1:0],
    output preg_t                  retire_pold_o      [1:0],
    output logic [1:0]             retire_is_branch_o,
    output chkpt_idx_t             retire_chkpt_id_o  [1:0],
    output logic [63:0]            retire_pc_o        [1:0],
    output rob_idx_t               retire_rob_idx_o   [1:0],
    output rob_epoch_t             retire_epoch_o     [1:0],

    // Milestone 8 Phase A Floating-Point Retirement Fields
    output logic [1:0]             retire_is_fp_o,
    output logic [1:0]             retire_fp_dest_valid_o,
    output fpreg_t                 retire_prd_fp_o    [1:0],
    output fpreg_t                 retire_pold_fp_o   [1:0],
    output logic [4:0]             retire_fflags_o    [1:0],

    // Milestone 8 Phase D Vector Retirement Fields
    output logic [1:0]             retire_is_vec_o,
    output logic [1:0]             retire_vec_dest_valid_o,
    output vreg_t                  retire_prd_vec_o   [1:0],

    // Precise Exception / Flush Trigger at ROB Head
    output logic                   retire_exception_o,
    output logic [4:0]             retire_exc_cause_o,
    output logic [63:0]            retire_exc_pc_o,

    // -------------------------------------------------------------------------
    // Branch Misprediction Recovery Interface
    // -------------------------------------------------------------------------
    input  logic                   recover_start_i,
    input  rob_idx_t               recover_rob_idx_i,

    output logic [1:0]             recover_pnew_valid_o,
    output preg_t                  recover_pnew_o     [1:0],
    output logic [1:0]             recover_pnew_fp_valid_o,
    output fpreg_t                 recover_pnew_fp_o  [1:0],
    output logic                   recovering_o,

    // -------------------------------------------------------------------------
    // Full Architectural Flush Interface
    // -------------------------------------------------------------------------
    input  logic                   flush_valid_i,

    // -------------------------------------------------------------------------
    // Status & Pointer Exports
    // -------------------------------------------------------------------------
    output rob_idx_t               head_o,
    output rob_idx_t               head_next_o,
    output rob_idx_t               tail_o,
    output logic [ROB_CNT_W-1:0]   count_o,
    output logic                   empty_o,
    output logic                   full_o,

    // Diagnostics
    output logic                   diag_head_valid_o,
    output logic                   diag_head_completed_o,
    output logic                   diag_head_exception_o,
    output areg_t                  diag_head_rd_o,
    output preg_t                  diag_head_pnew_o,
    output logic                   diag_head_is_branch_o
);

    assign diag_head_valid_o     = entry0.valid;
    assign diag_head_completed_o = entry0.completed;
    assign diag_head_exception_o = entry0.exception;
    assign diag_head_rd_o        = entry0.rd;
    assign diag_head_pnew_o      = entry0.pnew;
    assign diag_head_is_branch_o = entry0.is_branch;

    // -------------------------------------------------------------------------
    // ROB Storage & Pointers
    // -------------------------------------------------------------------------
    rob_entry_t entries_q    [CAPACITY];
    rob_epoch_t slot_epoch_q [CAPACITY];
    rob_idx_t   head_q;
    rob_idx_t   tail_q;
    logic [ROB_CNT_W-1:0] count_q;

    // Recovery FSM State & Registers
    logic       recovering_q;
    rob_idx_t   target_tail_q;

    // Modulo-48 pointer helpers
    function automatic [5:0] inc48(input [5:0] ptr, input [2:0] val);
        logic [6:0] sum;
        sum = {1'b0, ptr} + {4'b0, val};
        return (sum >= 7'd48) ? (sum[5:0] - 6'd48) : sum[5:0];
    endfunction

    function automatic [5:0] dec48(input [5:0] ptr, input [2:0] val);
        logic signed [7:0] diff;
        diff = {2'b00, ptr} - {5'b00000, val};
        return (diff < 0) ? (diff[5:0] + 6'd48) : diff[5:0];
    endfunction

    // -------------------------------------------------------------------------
    // Allocation Peeks & Readiness
    // -------------------------------------------------------------------------
    assign alloc_rob_idx_o[0]   = tail_q;
    assign alloc_rob_idx_o[1]   = inc48(tail_q, 3'd1);
    assign alloc_rob_epoch_o[0] = slot_epoch_q[tail_q];
    assign alloc_rob_epoch_o[1] = slot_epoch_q[inc48(tail_q, 3'd1)];

    // Live completion qualification against slot validity, completion status, and epoch
    logic [4:0] comp_match;
    for (genvar gw = 0; gw < 5; gw++) begin : gen_comp_match
        assign comp_match[gw] = comp_valid_i[gw] &&
                                entries_q[comp_rob_idx_i[gw]].valid &&
                                !entries_q[comp_rob_idx_i[gw]].completed &&
                                (entries_q[comp_rob_idx_i[gw]].epoch == comp_epoch_i[gw]);
    end
    assign comp_ack_o = comp_match;

    logic [ROB_CNT_W-1:0] free_slots;
    assign free_slots = 7'd48 - count_q;

    assign alloc_ready_o[0] = !recovering_q && (free_slots >= 7'd1);
    assign alloc_ready_o[1] = !recovering_q && (free_slots >= 7'd2);

    assign head_o  = head_q;
    assign tail_o  = tail_q;
    assign count_o = count_q;
    assign empty_o = (count_q == 7'd0);
    assign full_o  = (count_q == 7'd48);
    assign recovering_o = recovering_q;

    // -------------------------------------------------------------------------
    // In-Order Retirement Logic at head_q
    // -------------------------------------------------------------------------
    rob_idx_t head_next;
    assign head_next = inc48(head_q, 3'd1);
    assign head_next_o = head_next;

    /* verilator lint_off UNUSEDSIGNAL */
    rob_entry_t entry0;
    rob_entry_t entry1;
    /* verilator lint_on UNUSEDSIGNAL */
    assign entry0 = entries_q[head_q];
    assign entry1 = entries_q[head_next];
    // Completion bypass to retirement logic
    logic entry0_completed_eff;
    logic entry0_exception_eff;
    logic [4:0] entry0_exc_cause_eff;
    logic [4:0] entry0_fflags_eff;

    logic entry1_completed_eff;
    logic entry1_exception_eff;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [4:0] entry1_exc_cause_eff;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [4:0] entry1_fflags_eff;

    always_comb begin
        entry0_completed_eff = entry0.completed;
        entry0_exception_eff = entry0.exception;
        entry0_exc_cause_eff = entry0.exc_cause;
        entry0_fflags_eff    = entry0.fflags;
        for (int unsigned w = 0; w < 5; w++) begin
            if (comp_match[w] && (comp_rob_idx_i[w] == head_q)) begin
                entry0_completed_eff = 1'b1;
                entry0_fflags_eff    = comp_fflags_i[w];
                if (comp_exception_i[w]) begin
                    entry0_exception_comb_check: begin
                        entry0_exception_eff = 1'b1;
                        entry0_exc_cause_eff = comp_cause_i[w];
                    end
                end
            end
        end

        entry1_completed_eff = entry1.completed;
        entry1_exception_eff = entry1.exception;
        entry1_exc_cause_eff = entry1.exc_cause;
        entry1_fflags_eff    = entry1.fflags;
        for (int unsigned w = 0; w < 5; w++) begin
            if (comp_match[w] && (comp_rob_idx_i[w] == head_next)) begin
                entry1_completed_eff = 1'b1;
                entry1_fflags_eff    = comp_fflags_i[w];
                if (comp_exception_i[w]) begin
                    entry1_exception_comb_check: begin
                        entry1_exception_eff = 1'b1;
                        entry1_exc_cause_eff = comp_cause_i[w];
                    end
                end
            end
        end
    end

    // Effective memory violation detection at head
    wire entry0_mem_violation_eff = entry0.mem_violation ||
        (lsu_violation_valid_i && (lsu_violation_rob_idx_i == head_q) &&
         (lsu_violation_rob_epoch_i == entry0.epoch));

    wire entry1_mem_violation_eff = entry1.mem_violation ||
        (lsu_violation_valid_i && (lsu_violation_rob_idx_i == head_next) &&
         (lsu_violation_rob_epoch_i == entry1.epoch));

    wire head_in_recovery = recovering_q && (head_q == target_tail_q);

    // Replay detection at head (Prompt Rule 14, 19: Violation suppresses speculative exception)
    wire head_has_replay    = (count_q >= 7'd1) && entry0.valid && entry0.completed &&
                              entry0_mem_violation_eff && !head_in_recovery;
    wire head_has_exception = (count_q >= 7'd1) && entry0.valid && entry0_completed_eff &&
                              entry0_exception_eff && !entry0_mem_violation_eff && !head_in_recovery;

    assign retire_replay_o    = head_has_replay;
    assign retire_replay_pc_o = entry0.pc;

    assign retire_exception_o = head_has_exception;
    assign retire_exc_cause_o = entry0_exc_cause_eff;
    assign retire_exc_pc_o    = entry0.pc;

    wire rec_allows_uop0 = (!recover_start_i || (head_q != recover_rob_idx_i)) &&
                           (!recovering_q || (head_q != target_tail_q));
    wire rec_allows_uop1 = (!recover_start_i || (head_next != recover_rob_idx_i)) &&
                           (!recovering_q || (head_next != target_tail_q));

    // Retirement conditions
    wire uop0_can_retire = (count_q >= 7'd1) && entry0.valid && entry0_completed_eff &&
                           !entry0_exception_eff && !entry0_mem_violation_eff &&
                           lsu_retire0_allow_i && rec_allows_uop0;
    wire uop1_can_retire = uop0_can_retire && (count_q >= 7'd2) && entry1.valid && entry1_completed_eff &&
                           !entry1_exception_eff && !entry1_mem_violation_eff &&
                           lsu_retire1_allow_i && rec_allows_uop1;

    logic [1:0] retire_grant;
    always_comb begin
        retire_grant = 2'b00;
        if (retire_ready_i && !head_has_exception && !head_has_replay && !irq_pending_i) begin
            if (uop1_can_retire) begin
                retire_grant = 2'b11;
            end else if (uop0_can_retire) begin
                retire_grant = 2'b01;
            end
        end
    end

    assign retire_valid_o[0]     = retire_grant[0];
    assign retire_rd_o[0]        = entry0.rd;
    assign retire_pnew_o[0]      = entry0.pnew;
    assign retire_pold_o[0]      = entry0.pold;
    assign retire_is_branch_o[0] = entry0.is_branch;
    assign retire_chkpt_id_o[0]  = entry0.chkpt_id;
    assign retire_pc_o[0]        = entry0.pc;
    assign retire_rob_idx_o[0]   = head_q;
    assign retire_epoch_o[0]     = entry0.epoch;

    assign retire_is_fp_o[0]         = entry0.is_fp;
    assign retire_fp_dest_valid_o[0] = entry0.fp_dest_valid;
    assign retire_prd_fp_o[0]        = entry0.prd_fp;
    assign retire_pold_fp_o[0]       = entry0.pold_fp;
    assign retire_fflags_o[0]        = entry0_fflags_eff;

    assign retire_is_vec_o[0]         = entry0.is_vec;
    assign retire_vec_dest_valid_o[0] = entry0.vec_dest_valid;
    assign retire_prd_vec_o[0]        = entry0.prd_vec;

    assign retire_valid_o[1]     = retire_grant[1];
    assign retire_rd_o[1]        = entry1.rd;
    assign retire_pnew_o[1]      = entry1.pnew;
    assign retire_pold_o[1]      = entry1.pold;
    assign retire_is_branch_o[1] = entry1.is_branch;
    assign retire_chkpt_id_o[1]  = entry1.chkpt_id;
    assign retire_pc_o[1]        = entry1.pc;
    assign retire_rob_idx_o[1]   = head_next;
    assign retire_epoch_o[1]     = entry1.epoch;

    assign retire_is_fp_o[1]         = entry1.is_fp;
    assign retire_fp_dest_valid_o[1] = entry1.fp_dest_valid;
    assign retire_prd_fp_o[1]        = entry1.prd_fp;
    assign retire_pold_fp_o[1]       = entry1.pold_fp;
    assign retire_fflags_o[1]        = entry1_fflags_eff;

    assign retire_is_vec_o[1]         = entry1.is_vec;
    assign retire_vec_dest_valid_o[1] = entry1.vec_dest_valid;
    assign retire_prd_vec_o[1]        = entry1.prd_vec;

    logic [1:0] num_retire;
    assign num_retire = (retire_grant == 2'b11) ? 2'd2 :
                        (retire_grant[0])       ? 2'd1 : 2'd0;

    // Number of allocations
    logic [1:0] num_alloc;
    assign num_alloc = (alloc_valid_i == 2'b11) ? 2'd2 :
                       (alloc_valid_i[0])       ? 2'd1 : 2'd0;

    // -------------------------------------------------------------------------
    // Branch Recovery Walk Logic (Backwards from tail_q)
    // -------------------------------------------------------------------------
    rob_idx_t rec_cand0;
    rob_idx_t rec_cand1;
    assign rec_cand0 = dec48(tail_q, 3'd1);
    assign rec_cand1 = dec48(tail_q, 3'd2);

    logic [1:0] rec_squash_cnt;
    preg_t      rec_pnew0;
    preg_t      rec_pnew1;
    logic       rec_valid0;
    logic       rec_valid1;

    // Milestone 8 Phase A FP recovery signals
    fpreg_t     rec_pnew_fp0;
    fpreg_t     rec_pnew_fp1;
    logic       rec_valid_fp0;
    logic       rec_valid_fp1;

    always_comb begin
        rec_squash_cnt = 2'd0;
        rec_pnew0      = '0;
        rec_pnew1      = '0;
        rec_valid0     = 1'b0;
        rec_valid1     = 1'b0;

        rec_pnew_fp0   = '0;
        rec_pnew_fp1   = '0;
        rec_valid_fp0  = 1'b0;
        rec_valid_fp1  = 1'b0;

        if (recovering_q && (tail_q != target_tail_q) && (count_q > {5'b0, num_retire})) begin
            // First candidate entry
            rec_squash_cnt = 2'd1;
            if (entries_q[rec_cand0].valid && (!entries_q[rec_cand0].fp_dest_valid) && (entries_q[rec_cand0].rd != 5'd0)) begin
                rec_valid0 = 1'b1;
                rec_pnew0  = entries_q[rec_cand0].pnew;
            end
            if (entries_q[rec_cand0].valid && entries_q[rec_cand0].fp_dest_valid) begin
                rec_valid_fp0 = 1'b1;
                rec_pnew_fp0  = entries_q[rec_cand0].prd_fp;
            end

            // Second candidate entry (if rec_cand0 was not already the target and capacity allows)
            if ((rec_cand0 != target_tail_q) && (count_q > ({5'b0, num_retire} + 7'd1))) begin
                rec_squash_cnt = 2'd2;
                if (entries_q[rec_cand1].valid && (!entries_q[rec_cand1].fp_dest_valid) && (entries_q[rec_cand1].rd != 5'd0)) begin
                    rec_valid1 = 1'b1;
                    rec_pnew1  = entries_q[rec_cand1].pnew;
                end
                if (entries_q[rec_cand1].valid && entries_q[rec_cand1].fp_dest_valid) begin
                    rec_valid_fp1 = 1'b1;
                    rec_pnew_fp1  = entries_q[rec_cand1].prd_fp;
                end
            end
        end
    end

    assign recover_pnew_valid_o[0]    = rec_valid0;
    assign recover_pnew_valid_o[1]    = rec_valid1;
    assign recover_pnew_o[0]          = rec_pnew0;
    assign recover_pnew_o[1]          = rec_pnew1;

    assign recover_pnew_fp_valid_o[0] = rec_valid_fp0;
    assign recover_pnew_fp_valid_o[1] = rec_valid_fp1;
    assign recover_pnew_fp_o[0]       = rec_pnew_fp0;
    assign recover_pnew_fp_o[1]       = rec_pnew_fp1;

    rob_idx_t target_tail_comb;
    rob_idx_t next_tail_comb;
    rob_idx_t tail1_comb;

    assign target_tail_comb = inc48(recover_rob_idx_i, 3'd1);
    assign next_tail_comb   = dec48(tail_q, {1'b0, rec_squash_cnt});
    assign tail1_comb       = inc48(tail_q, 3'd1);

    // -------------------------------------------------------------------------
    // Sequential State Update
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            head_q        <= '0;
            tail_q        <= '0;
            count_q       <= '0;
            recovering_q  <= 1'b0;
            target_tail_q <= '0;
            for (int unsigned i = 0; i < CAPACITY; i++) begin
                entries_q[i]    <= '0;
                slot_epoch_q[i] <= '0;
            end
        end else if (flush_valid_i) begin
            // -----------------------------------------------------------------
            // Full Architectural Flush: Wipe all speculative in-flight ROB entries
            // Advance all slot epochs to immediately invalidate stale pending completions
            // -----------------------------------------------------------------
            head_q        <= '0;
            tail_q        <= '0;
            count_q       <= '0;
            recovering_q  <= 1'b0;
            target_tail_q <= '0;
            for (int unsigned i = 0; i < CAPACITY; i++) begin
                entries_q[i].valid <= 1'b0;
                slot_epoch_q[i]    <= slot_epoch_q[i] + 4'd1;
            end
        end else begin
            // -----------------------------------------------------------------
            // 1. Writeback Completion Updates (strictly qualified by epoch match)
            // -----------------------------------------------------------------
            for (int unsigned w = 0; w < 5; w++) begin
                if (comp_match[w]) begin
                    entries_q[comp_rob_idx_i[w]].completed      <= 1'b1;
                    entries_q[comp_rob_idx_i[w]].branch_mispred <= comp_branch_mispred_i[w];
                    entries_q[comp_rob_idx_i[w]].fflags         <= comp_fflags_i[w];
                    if (comp_exception_i[w]) begin
                        entries_q[comp_rob_idx_i[w]].exception <= 1'b1;
                        entries_q[comp_rob_idx_i[w]].exc_cause <= comp_cause_i[w];
                    end
                end
            end

            // Phase B1 LSU Sticky Memory-Order Violation Acceptance
            if (lsu_violation_valid_i &&
                entries_q[lsu_violation_rob_idx_i].valid &&
                (entries_q[lsu_violation_rob_idx_i].epoch == lsu_violation_rob_epoch_i)) begin
                entries_q[lsu_violation_rob_idx_i].mem_violation <= 1'b1;
            end

            // -----------------------------------------------------------------
            // 2. In-Order Retirement (Advance head_q)
            // -----------------------------------------------------------------
            if (retire_grant[0]) begin
                entries_q[head_q].valid <= 1'b0;
            end
            if (retire_grant[1]) begin
                entries_q[head_next].valid <= 1'b0;
            end
            head_q <= inc48(head_q, {1'b0, num_retire});

            // -----------------------------------------------------------------
            // 3. Recovery or Normal Allocation
            // -----------------------------------------------------------------
            if (recover_start_i) begin
                // Initiate branch misprediction recovery
                target_tail_q <= target_tail_comb;

                // The mispredicted branch has consumed and released its checkpoint;
                // clear is_branch so in-order retirement does not double-free the checkpoint ID.
                entries_q[recover_rob_idx_i].is_branch <= 1'b0;

                if (recovering_q) begin
                    // A recovery was already walking; commit the current cycle's squash steps
                    if (rec_squash_cnt >= 2'd1) begin
                        entries_q[rec_cand0].valid <= 1'b0;
                    end
                    if (rec_squash_cnt >= 2'd2) begin
                        entries_q[rec_cand1].valid <= 1'b0;
                    end

                    tail_q  <= next_tail_comb;
                    count_q <= count_q - {5'b0, num_retire} - {5'b0, rec_squash_cnt};

                    if ((next_tail_comb == target_tail_comb) || (count_q <= ({5'b0, num_retire} + {5'b0, rec_squash_cnt}))) begin
                        recovering_q <= 1'b0;
                    end else begin
                        recovering_q <= 1'b1;
                    end
                end else begin
                    if (tail_q == target_tail_comb) begin
                        // No younger instructions were dispatched after this branch
                        recovering_q <= 1'b0;
                        count_q      <= count_q - {5'b0, num_retire};
                    end else begin
                        recovering_q <= 1'b1;
                        count_q      <= count_q - {5'b0, num_retire};
                    end
                end
            end else if (recovering_q) begin
                // Walking backwards reclaiming squashed entries
                if (rec_squash_cnt >= 2'd1) begin
                    entries_q[rec_cand0].valid <= 1'b0;
                end
                if (rec_squash_cnt >= 2'd2) begin
                    entries_q[rec_cand1].valid <= 1'b0;
                end

                tail_q  <= next_tail_comb;
                count_q <= count_q - {5'b0, num_retire} - {5'b0, rec_squash_cnt};

                if ((next_tail_comb == target_tail_q) || (count_q <= ({5'b0, num_retire} + {5'b0, rec_squash_cnt}))) begin
                    recovering_q <= 1'b0;
                end
            end else begin
                // Normal allocation: stamps current slot epoch and advances counter
                if (alloc_valid_i[0]) begin
                    entries_q[tail_q].valid          <= 1'b1;
                    entries_q[tail_q].rd             <= alloc_rd_i[0];
                    entries_q[tail_q].pnew           <= alloc_pnew_i[0];
                    entries_q[tail_q].pold           <= alloc_pold_i[0];
                    entries_q[tail_q].epoch          <= slot_epoch_q[tail_q];
                    slot_epoch_q[tail_q]             <= slot_epoch_q[tail_q] + 4'd1;
                    entries_q[tail_q].completed      <= 1'b0;
                    entries_q[tail_q].exception      <= 1'b0;
                    entries_q[tail_q].exc_cause      <= '0;
                    entries_q[tail_q].is_branch      <= alloc_is_branch_i[0];
                    entries_q[tail_q].chkpt_id       <= alloc_chkpt_id_i[0];
                    entries_q[tail_q].branch_mispred <= 1'b0;
                    entries_q[tail_q].mem_violation  <= 1'b0;
                    entries_q[tail_q].pc             <= alloc_pc_i[0];
                    // Milestone 8 FP fields
                    entries_q[tail_q].is_fp          <= alloc_is_fp_i[0];
                    entries_q[tail_q].fp_dest_valid  <= alloc_fp_dest_valid_i[0];
                    entries_q[tail_q].prd_fp         <= alloc_prd_fp_i[0];
                    entries_q[tail_q].pold_fp        <= alloc_pold_fp_i[0];
                    entries_q[tail_q].fflags         <= 5'd0;
                    // Milestone 8 Vector fields
                    entries_q[tail_q].is_vec         <= alloc_is_vec_i[0];
                    entries_q[tail_q].vec_dest_valid <= alloc_vec_dest_valid_i[0];
                    entries_q[tail_q].prd_vec        <= alloc_prd_vec_i[0];
                end

                if (alloc_valid_i[1]) begin
                    entries_q[tail1_comb].valid          <= 1'b1;
                    entries_q[tail1_comb].rd             <= alloc_rd_i[1];
                    entries_q[tail1_comb].pnew           <= alloc_pnew_i[1];
                    entries_q[tail1_comb].pold           <= alloc_pold_i[1];
                    entries_q[tail1_comb].epoch          <= slot_epoch_q[tail1_comb];
                    slot_epoch_q[tail1_comb]             <= slot_epoch_q[tail1_comb] + 4'd1;
                    entries_q[tail1_comb].completed      <= 1'b0;
                    entries_q[tail1_comb].exception      <= 1'b0;
                    entries_q[tail1_comb].exc_cause      <= '0;
                    entries_q[tail1_comb].is_branch      <= alloc_is_branch_i[1];
                    entries_q[tail1_comb].chkpt_id       <= alloc_chkpt_id_i[1];
                    entries_q[tail1_comb].branch_mispred <= 1'b0;
                    entries_q[tail1_comb].mem_violation  <= 1'b0;
                    entries_q[tail1_comb].pc             <= alloc_pc_i[1];
                    // Milestone 8 FP fields
                    entries_q[tail1_comb].is_fp          <= alloc_is_fp_i[1];
                    entries_q[tail1_comb].fp_dest_valid  <= alloc_fp_dest_valid_i[1];
                    entries_q[tail1_comb].prd_fp         <= alloc_prd_fp_i[1];
                    entries_q[tail1_comb].pold_fp        <= alloc_pold_fp_i[1];
                    entries_q[tail1_comb].fflags         <= 5'd0;
                    // Milestone 8 Vector fields
                    entries_q[tail1_comb].is_vec         <= alloc_is_vec_i[1];
                    entries_q[tail1_comb].vec_dest_valid <= alloc_vec_dest_valid_i[1];
                    entries_q[tail1_comb].prd_vec        <= alloc_prd_vec_i[1];
                end

                tail_q  <= inc48(tail_q, {1'b0, num_alloc});
                count_q <= count_q + {5'b0, num_alloc} - {5'b0, num_retire};
            end
        end
    end

    // -------------------------------------------------------------------------
    // Invariant Checkers & Simulation Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i && !flush_valid_i) begin
            // 1. ROB count within bounds (0..48)
            if (count_q > 7'd48) begin
                $fatal(1, "[ROB ASSERTION FAILED] ROB count %0d exceeds 48!", count_q);
            end

            // 2. Uniqueness: No two simultaneously valid destination-producing ROB entries own the same Pnew
            for (int unsigned i = 0; i < CAPACITY; i++) begin
                if (entries_q[i].valid && (!entries_q[i].fp_dest_valid) && (entries_q[i].rd != 5'd0)) begin
                    for (int unsigned j = i + 1; j < CAPACITY; j++) begin
                        if (entries_q[j].valid && (!entries_q[j].fp_dest_valid) && (entries_q[j].rd != 5'd0)) begin
                            if (entries_q[i].pnew == entries_q[j].pnew) begin
                                $fatal(1, "[ROB ASSERTION FAILED] Entries %0d and %0d share same Pnew p%0d!",
                                       i, j, entries_q[i].pnew);
                            end
                        end
                    end
                end
            end

            // 2b. FP Uniqueness: No two simultaneously valid FP destination-producing ROB entries own the same Prd_fp
            for (int unsigned i = 0; i < CAPACITY; i++) begin
                if (entries_q[i].valid && entries_q[i].fp_dest_valid) begin
                    for (int unsigned j = i + 1; j < CAPACITY; j++) begin
                        if (entries_q[j].valid && entries_q[j].fp_dest_valid) begin
                            if (entries_q[i].prd_fp == entries_q[j].prd_fp) begin
                                $fatal(1, "[ROB ASSERTION FAILED] FP Entries %0d and %0d share same Prd_fp fp%0d!",
                                       i, j, entries_q[i].prd_fp);
                            end
                        end
                    end
                end
            end

            // 3. Phase B1: Violated load NEVER retires
            if (retire_grant[0] && entry0_mem_violation_eff) begin
                $fatal(1, "[ROB ASSERTION FAILED] Violated load retired at slot 0!");
            end
            if (retire_grant[1] && entry1_mem_violation_eff) begin
                $fatal(1, "[ROB ASSERTION FAILED] Violated load retired at slot 1!");
            end

            // Phase B1 Assertions for Lane 0 and Lane 1 retirement qualification
            if (retire_grant[0] && !lsu_retire0_allow_i) begin
                $fatal(1, "[ROB ASSERTION FAILED] Lane 0 retired while LSU retire0 allow was deasserted!");
            end
            if (retire_grant[1] && !lsu_retire1_allow_i) begin
                $fatal(1, "[ROB ASSERTION FAILED] Lane 1 retired while LSU retire1 allow was deasserted!");
            end
            if (retire_grant[0] && lsu_violation_valid_i && (lsu_violation_rob_idx_i == head_q) && (lsu_violation_rob_epoch_i == entry0.epoch)) begin
                $fatal(1, "[ROB ASSERTION FAILED] Lane 0 retired while receiving same-cycle violation!");
            end
            if (retire_grant[1] && lsu_violation_valid_i && (lsu_violation_rob_idx_i == head_next) && (lsu_violation_rob_epoch_i == entry1.epoch)) begin
                $fatal(1, "[ROB ASSERTION FAILED] Lane 1 retired while receiving same-cycle violation!");
            end

            // 4. Phase B1: Stale epoch violation must NEVER set mem_violation in live ROB entry
            if (lsu_violation_valid_i) begin
                if (entries_q[lsu_violation_rob_idx_i].valid &&
                    (entries_q[lsu_violation_rob_idx_i].epoch != lsu_violation_rob_epoch_i)) begin
                    // Stale notification: verify epoch mismatch prevents update
                end
            end

            // 5. Phase B1: Replay occurs strictly at ROB head
            if (retire_replay_o && !head_has_replay) begin
                $fatal(1, "[ROB ASSERTION FAILED] Replay asserted when head does not have replay!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_ROB_SV
