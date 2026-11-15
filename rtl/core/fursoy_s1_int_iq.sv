`ifndef FURSOY_S1_INT_IQ_SV
`define FURSOY_S1_INT_IQ_SV

// =============================================================================
// Fursoy Slice-1 16-Entry Integer Issue Queue (IntIQ) — Milestone 2
// =============================================================================
// Out-of-order issue queue with:
// - 2-wide dispatch acceptance gated strictly by M1 rename_ack_o.
// - Wrap-safe ROB-head-relative circular distance age ordering.
// - Port-aware bipartite scheduler matching eliminating flexible ALU + branch serialization.
// - Validated writeback tag wakeup snoop.
// - Single-cycle squash on branch recovery and complete flush.
// Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.2
// =============================================================================

module fursoy_s1_int_iq
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Flush and recovery
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,

    // Dispatch Interface (from Rename / M1 Substrate)
    output logic [1:0]        dispatch_ready_o, // Ready for uop0, uop1
    input  logic [1:0]        rename_ack_i,     // M1 dispatch permit

    // Uop 0 Dispatch Payload
    input  logic              uop0_valid_i,
    input  uop_class_t        uop0_class_i,
    input  uop_subop_t        uop0_subop_i,
    input  logic [63:0]       uop0_imm_i,
    input  logic              uop0_use_imm_i,
    input  preg_t             uop0_prs1_i,
    input  logic              uop0_prs1_ready_i,
    input  preg_t             uop0_prs2_i,
    input  logic              uop0_prs2_ready_i,
    input  preg_t             uop0_pnew_i,
    input  rob_idx_t          uop0_rob_idx_i,
    input  rob_epoch_t        uop0_rob_epoch_i,
    input  chkpt_idx_t        uop0_chkpt_id_i,
    input  logic [63:0]       uop0_pc_i,
    input  logic              uop0_pred_taken_i,
    input  logic [63:0]       uop0_pred_target_i,
    input  logic              uop0_is_branch_i,
    input  logic              uop0_is_jal_i,
    input  logic              uop0_is_jalr_i,
    input  branch_type_t      uop0_br_type_i,
    input  ghr_t              uop0_pre_ghr_i,
    input  logic              uop0_exception_i,
    input  logic [4:0]        uop0_exc_cause_i,
    input  fpreg_t            uop0_prd_fp_i,
    input  logic              uop0_fp_dest_valid_i,
    input  logic [2:0]        uop0_frm_i,

    // Uop 1 Dispatch Payload
    input  logic              uop1_valid_i,
    input  uop_class_t        uop1_class_i,
    input  uop_subop_t        uop1_subop_i,
    input  logic [63:0]       uop1_imm_i,
    input  logic              uop1_use_imm_i,
    input  preg_t             uop1_prs1_i,
    input  logic              uop1_prs1_ready_i,
    input  preg_t             uop1_prs2_i,
    input  logic              uop1_prs2_ready_i,
    input  preg_t             uop1_pnew_i,
    input  rob_idx_t          uop1_rob_idx_i,
    input  rob_epoch_t        uop1_rob_epoch_i,
    input  chkpt_idx_t        uop1_chkpt_id_i,
    input  logic [63:0]       uop1_pc_i,
    input  logic              uop1_pred_taken_i,
    input  logic [63:0]       uop1_pred_target_i,
    input  logic              uop1_is_branch_i,
    input  logic              uop1_is_jal_i,
    input  logic              uop1_is_jalr_i,
    input  branch_type_t      uop1_br_type_i,
    input  ghr_t              uop1_pre_ghr_i,
    input  logic              uop1_exception_i,
    input  logic [4:0]        uop1_exc_cause_i,
    input  fpreg_t            uop1_prd_fp_i,
    input  logic              uop1_fp_dest_valid_i,
    input  logic [2:0]        uop1_frm_i,

    // Validated Writeback Snoop for Wakeup (from Validated WB stage)
    input  logic              wb0_valid_i,
    input  logic              wb0_comp_ack_i,
    input  preg_t             wb0_pnew_i,

    input  logic              wb1_valid_i,
    input  logic              wb1_comp_ack_i,
    input  preg_t             wb1_pnew_i,

    input  logic              wb2_valid_i,
    input  logic              wb2_comp_ack_i,
    input  logic              wb2_comp_exception_i,
    input  preg_t             wb2_pnew_i,

    input  logic              wb3_valid_i,
    input  logic              wb3_comp_ack_i,
    input  logic              wb3_comp_exception_i,
    input  preg_t             wb3_pnew_i,

    // Port 1 Downstream Credit Availability
    input  logic              can_issue_mul_i,
    input  logic              can_issue_alu1_i,
    input  logic              can_issue_div_i,

    // Issue Outputs to Register Fetch (RF Stage)
    output logic              issue0_valid_o,
    output iq_entry_t         issue0_uop_o,

    output logic              issue1_valid_o,
    output iq_entry_t         issue1_uop_o,

    // Diagnostics
    output logic [INT_IQ_DEPTH-1:0] diag_valid_mask_o,
    output logic [INT_IQ_DEPTH-1:0] diag_ready_p0_o,
    output logic [INT_IQ_DEPTH-1:0] diag_ready_p1_o,
    output logic [INT_IQ_DEPTH-1:0] diag_prs1_rdy_o,
    output logic [INT_IQ_DEPTH-1:0] diag_prs2_rdy_o,
    output rob_idx_t                diag_rob_idx_o [INT_IQ_DEPTH]
);

    always_comb begin
        for (int i = 0; i < INT_IQ_DEPTH; i++) begin
            diag_valid_mask_o[i] = entries_q[i].valid;
            diag_ready_p0_o[i]   = ready_p0[i];
            diag_ready_p1_o[i]   = ready_p1[i];
            diag_prs1_rdy_o[i]   = entries_q[i].valid && entries_q[i].prs1_ready;
            diag_prs2_rdy_o[i]   = entries_q[i].valid && entries_q[i].prs2_ready;
            diag_rob_idx_o[i]    = entries_q[i].rob_idx;
        end
    end

    // -------------------------------------------------------------------------
    // Issue Queue Entries & Dimensions
    // -------------------------------------------------------------------------
    localparam int unsigned IQ_CNT_W = INT_IQ_IDX_W + 1;
    typedef logic [INT_IQ_IDX_W-1:0] iq_idx_t;

    iq_entry_t entries_q [INT_IQ_DEPTH];

    // -------------------------------------------------------------------------
    // Allocation Logic
    // -------------------------------------------------------------------------
    function automatic logic is_int2fp_op(input uop_subop_t op);
        case (op)
            FP_FMV_W_X, FP_FMV_D_X,
            FP_FCVT_S_W, FP_FCVT_D_W,
            FP_FCVT_S_WU, FP_FCVT_D_WU,
            FP_FCVT_S_L, FP_FCVT_D_L,
            FP_FCVT_S_LU, FP_FCVT_D_LU: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    wire uop0_is_mem = (uop0_class_i == UOP_LOAD) || (uop0_class_i == UOP_STORE) ||
                       (uop0_class_i == UOP_AMO)  || (uop0_class_i == UOP_FENCE);
    wire uop1_is_mem = (uop1_class_i == UOP_LOAD) || (uop1_class_i == UOP_STORE) ||
                       (uop1_class_i == UOP_AMO)  || (uop1_class_i == UOP_FENCE);

    wire uop0_is_fpiq = !uop0_exception_i && (uop0_class_i == UOP_FP) && !is_int2fp_op(uop0_subop_i);
    wire uop1_is_fpiq = !uop1_exception_i && (uop1_class_i == UOP_FP) && !is_int2fp_op(uop1_subop_i);

    wire uop0_for_intiq = !uop0_is_mem && !uop0_is_fpiq && (uop0_class_i != UOP_VEC);
    wire uop1_for_intiq = !uop1_is_mem && !uop1_is_fpiq && (uop1_class_i != UOP_VEC);

    // Count free entries
    logic [IQ_CNT_W-1:0] free_count;
    always_comb begin
        free_count = '0;
        for (int i = 0; i < INT_IQ_DEPTH; i++) begin
            if (!entries_q[i].valid) free_count = free_count + IQ_CNT_W'(1);
        end
    end

    assign dispatch_ready_o[0] = (free_count >= IQ_CNT_W'(1)) && !flush_valid_i;
    assign dispatch_ready_o[1] = (free_count >= IQ_CNT_W'(2)) && !flush_valid_i;

    // Find two free slots for allocation
    iq_idx_t alloc_slot0, alloc_slot1;
    logic    slot0_found, slot1_found;

    always_comb begin
        alloc_slot0 = '0;
        alloc_slot1 = '0;
        slot0_found = 1'b0;
        slot1_found = 1'b0;

        for (int i = 0; i < INT_IQ_DEPTH; i++) begin
            if (!entries_q[i].valid) begin
                if (!slot0_found) begin
                    alloc_slot0 = iq_idx_t'(i);
                    slot0_found = 1'b1;
                end else if (!slot1_found) begin
                    alloc_slot1 = iq_idx_t'(i);
                    slot1_found = 1'b1;
                end
            end
        end
    end

    wire uop0_v_intiq = uop0_valid_i && uop0_for_intiq;

    iq_idx_t alloc_slot1_eff;
    assign alloc_slot1_eff     = uop0_v_intiq ? alloc_slot1 : alloc_slot0;
    wire   slot1_found_eff     = uop0_v_intiq ? slot1_found : slot0_found;

    wire alloc0_fire = uop0_v_intiq && rename_ack_i[0] && !flush_valid_i && slot0_found;
    wire alloc1_fire = uop1_valid_i && uop1_for_intiq && rename_ack_i[1] && !flush_valid_i && slot1_found_eff;

    // Port Mask Generation for Dispatch Uops
    function automatic logic [1:0] get_port_mask(input uop_class_t uclass, input logic exception);
        if (exception) return 2'b01; // Port 0 only (Port 1 cannot report exceptions)
        case (uclass)
            UOP_BRANCH, UOP_JAL, UOP_JALR, UOP_SYSTEM, UOP_FP: return 2'b01; // Port 0 only (including Int2FP)
            UOP_MUL, UOP_DIV:                                   return 2'b10; // Port 1 only
            default:                                            return 2'b11; // Symmetric flexible ALU
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Wakeup Detection
    // -------------------------------------------------------------------------
    wire wb0_wake = wb0_valid_i && wb0_comp_ack_i && (wb0_pnew_i != preg_t'(0));
    wire wb1_wake = wb1_valid_i && wb1_comp_ack_i && (wb1_pnew_i != preg_t'(0));
    wire wb2_wake = wb2_valid_i && wb2_comp_ack_i && !wb2_comp_exception_i && (wb2_pnew_i != preg_t'(0));
    wire wb3_wake = wb3_valid_i && wb3_comp_ack_i && !wb3_comp_exception_i && (wb3_pnew_i != preg_t'(0));

    // -------------------------------------------------------------------------
    // Readiness Evaluation for Each Queue Entry (Frozen loop-free timing:
    // selection strictly observes REGISTERED ready bits; NO same-cycle WB bypass)
    // -------------------------------------------------------------------------
    logic [INT_IQ_DEPTH-1:0] ready_p0;
    logic [INT_IQ_DEPTH-1:0] ready_p1;
    logic [INT_IQ_DEPTH-1:0] is_p0_only;
    logic [INT_IQ_DEPTH-1:0] is_p1_only;
    logic [INT_IQ_DEPTH-1:0] is_flex;

    always_comb begin
        for (int i = 0; i < INT_IQ_DEPTH; i++) begin
            logic prs1_r, prs2_r;
            logic ops_ready;
            logic p1_credit_ok;
            logic is_sys;
            logic sys_ready;

            prs1_r = entries_q[i].prs1_ready || (entries_q[i].prs1 == preg_t'(0));

            prs2_r = (entries_q[i].use_imm && (entries_q[i].uop_class != UOP_BRANCH)) ||
                     entries_q[i].prs2_ready || (entries_q[i].prs2 == preg_t'(0));

            ops_ready = entries_q[i].valid && prs1_r && prs2_r;

            is_sys    = (entries_q[i].uop_class == UOP_SYSTEM);
            sys_ready = !is_sys || (entries_q[i].rob_idx == rob_head_i);

            // Classify eligibility
            is_p0_only[i] = entries_q[i].valid && (entries_q[i].port_mask == 2'b01);
            is_p1_only[i] = entries_q[i].valid && (entries_q[i].port_mask == 2'b10);
            is_flex[i]    = entries_q[i].valid && (entries_q[i].port_mask == 2'b11);

            // Ready for Port 0 (ALU0, Branch, or Serialized System at ROB Head)
            ready_p0[i] = ops_ready && entries_q[i].port_mask[0] && sys_ready;

            // Ready for Port 1 (ALU1, Multiplier, or Divider)
            p1_credit_ok = 1'b0;
            if (entries_q[i].uop_class == UOP_MUL) begin
                p1_credit_ok = can_issue_mul_i;
            end else if (entries_q[i].uop_class == UOP_DIV) begin
                p1_credit_ok = can_issue_div_i;
            end else begin
                // Symmetric ALU
                p1_credit_ok = can_issue_alu1_i;
            end

            ready_p1[i] = ops_ready && entries_q[i].port_mask[1] && p1_credit_ok;
        end
    end

    // -------------------------------------------------------------------------
    // Wrap-Safe Age Comparison & Port-Aware Bipartite Arbiter (Phase B4)
    // Reference: docs/architecture/slice1-m5-performance-v1.md Section 7.4
    // -------------------------------------------------------------------------
    iq_idx_t sel_p0_idx;
    iq_idx_t sel_p1_idx;
    logic    sel_p0_valid;
    logic    sel_p1_valid;

    // Strict oldest-ready-first priority with Section 7.4 tie-breaking:
    // 1. Primary rule: wrap-safe circular ROB age (strictly smaller rob_dist).
    // 2. Equal age tie-break: branch priority (branch uop takes precedence over non-branch).
    // 3. Both branches or neither branch: lower slot index (Slot 0 precedence).
    function automatic logic is_older_or_tiebreak(
        input rob_dist_t cand_dist,
        input logic      cand_is_br,
        input iq_idx_t   cand_idx,
        input rob_dist_t curr_dist,
        input logic      curr_is_br,
        input iq_idx_t   curr_idx
    );
        if (cand_dist < curr_dist) begin
            return 1'b1;
        end else if (cand_dist == curr_dist) begin
            if (cand_is_br && !curr_is_br) begin
                return 1'b1;
            end else if (!cand_is_br && curr_is_br) begin
                return 1'b0;
            end else begin
                return (cand_idx < curr_idx);
            end
        end else begin
            return 1'b0;
        end
    endfunction

    rob_dist_t             entry_dist [INT_IQ_DEPTH];
    logic [INT_IQ_DEPTH-1:0] entry_is_br;
    always_comb begin
        for (int i = 0; i < INT_IQ_DEPTH; i++) begin
            entry_dist[i]  = rob_dist(entries_q[i].rob_idx, rob_head_i);
            entry_is_br[i] = entries_q[i].is_branch || (entries_q[i].uop_class == UOP_BRANCH);
        end
    end

    always_comb begin
        // Find oldest ready uop across all categories (u0)
        iq_idx_t   u0_idx;
        logic      u0_valid;
        rob_dist_t u0_dist;
        logic      u0_is_br;

        // Find second-oldest ready uop across all categories (u1)
        iq_idx_t   u1_idx;
        logic      u1_valid;
        rob_dist_t u1_dist;
        logic      u1_is_br;

        rob_dist_t best_p1_dist;
        rob_dist_t best_p0_dist;
        logic      best_p0_is_br;
        rob_dist_t d;

        sel_p0_idx   = '0;
        sel_p1_idx   = '0;
        sel_p0_valid = 1'b0;
        sel_p1_valid = 1'b0;

        u0_idx   = '0;
        u0_valid = 1'b0;
        u0_dist  = rob_dist_t'(ROB_DEPTH - 1);
        u0_is_br = 1'b0;

        u1_idx   = '0;
        u1_valid = 1'b0;
        u1_dist  = rob_dist_t'(ROB_DEPTH - 1);
        u1_is_br = 1'b0;

        best_p1_dist  = rob_dist_t'(ROB_DEPTH - 1);
        best_p0_dist  = rob_dist_t'(ROB_DEPTH - 1);
        best_p0_is_br = 1'b0;
        d             = '0;

        for (int i = 0; i < INT_IQ_DEPTH; i++) begin
            if (ready_p0[i] || ready_p1[i]) begin
                d = entry_dist[i];
                if (!u0_valid || is_older_or_tiebreak(d, entry_is_br[i], iq_idx_t'(i),
                                                      u0_dist, u0_is_br, u0_idx)) begin
                    u0_dist  = d;
                    u0_is_br = entry_is_br[i];
                    u0_idx   = iq_idx_t'(i);
                    u0_valid = 1'b1;
                end
            end
        end

        if (u0_valid) begin
            for (int i = 0; i < INT_IQ_DEPTH; i++) begin
                if ((iq_idx_t'(i) != u0_idx) && (ready_p0[i] || ready_p1[i])) begin
                    d = entry_dist[i];
                    if (!u1_valid || is_older_or_tiebreak(d, entry_is_br[i], iq_idx_t'(i),
                                                          u1_dist, u1_is_br, u1_idx)) begin
                        u1_dist  = d;
                        u1_is_br = entry_is_br[i];
                        u1_idx   = iq_idx_t'(i);
                        u1_valid = 1'b1;
                    end
                end
            end
        end

        // Port-Aware Bipartite Matching
        if (u0_valid) begin
            if (is_p0_only[u0_idx]) begin
                // Case 1: u0 is Port0-only (Branch/JAL/JALR)
                sel_p0_valid = 1'b1;
                sel_p0_idx   = u0_idx;

                // Port 1 picks oldest ready in P1-only or Flex
                best_p1_dist = rob_dist_t'(ROB_DEPTH - 1);
                for (int i = 0; i < INT_IQ_DEPTH; i++) begin
                    if ((iq_idx_t'(i) != u0_idx) && ready_p1[i]) begin
                        d = entry_dist[i];
                        if (!sel_p1_valid || is_older_or_tiebreak(d, 1'b0, iq_idx_t'(i),
                                                                  best_p1_dist, 1'b0, sel_p1_idx)) begin
                            best_p1_dist = d;
                            sel_p1_idx   = iq_idx_t'(i);
                            sel_p1_valid = 1'b1;
                        end
                    end
                end
            end else if (is_p1_only[u0_idx]) begin
                // Case 2: u0 is Port1-only (MUL/DIV)
                sel_p1_valid = 1'b1;
                sel_p1_idx   = u0_idx;

                // Port 0 picks oldest ready in P0-only or Flex
                best_p0_dist  = rob_dist_t'(ROB_DEPTH - 1);
                best_p0_is_br = 1'b0;
                for (int i = 0; i < INT_IQ_DEPTH; i++) begin
                    if ((iq_idx_t'(i) != u0_idx) && ready_p0[i]) begin
                        d = entry_dist[i];
                        if (!sel_p0_valid || is_older_or_tiebreak(d, entry_is_br[i], iq_idx_t'(i),
                                                                  best_p0_dist, best_p0_is_br, sel_p0_idx)) begin
                            best_p0_dist  = d;
                            best_p0_is_br = entry_is_br[i];
                            sel_p0_idx    = iq_idx_t'(i);
                            sel_p0_valid  = 1'b1;
                        end
                    end
                end
            end else begin
                // Case 3: u0 is Flexible ALU (port_mask == 2'b11)
                if (u1_valid) begin
                    if (is_p0_only[u1_idx] && ready_p1[u0_idx]) begin
                        // Critical optimization (P2-1):
                        // u1 is P0-only branch, u0 is flexible ALU.
                        // Assign u1 -> Port 0 and u0 -> Port 1! (Dual-issue in 1 cycle)
                        sel_p0_valid = 1'b1;
                        sel_p0_idx   = u1_idx;
                        sel_p1_valid = 1'b1;
                        sel_p1_idx   = u0_idx;
                    end else if (is_p1_only[u1_idx] && ready_p1[u1_idx]) begin
                        // u1 is P1-only (MUL/DIV), u0 is flexible ALU.
                        // Assign u0 -> Port 0 and u1 -> Port 1!
                        sel_p0_valid = 1'b1;
                        sel_p0_idx   = u0_idx;
                        sel_p1_valid = 1'b1;
                        sel_p1_idx   = u1_idx;
                    end else if (is_flex[u1_idx] && ready_p1[u1_idx]) begin
                        // Both u0 and u1 are flexible ALUs!
                        // Assign u0 -> Port 0 and u1 -> Port 1!
                        sel_p0_valid = 1'b1;
                        sel_p0_idx   = u0_idx;
                        sel_p1_valid = 1'b1;
                        sel_p1_idx   = u1_idx;
                    end else begin
                        // Single issue u0 to Port 0
                        sel_p0_valid = 1'b1;
                        sel_p0_idx   = u0_idx;
                        // See if any other uop can issue to Port 1
                        best_p1_dist = rob_dist_t'(ROB_DEPTH - 1);
                        for (int i = 0; i < INT_IQ_DEPTH; i++) begin
                            if ((iq_idx_t'(i) != u0_idx) && ready_p1[i]) begin
                                d = entry_dist[i];
                                if (!sel_p1_valid || is_older_or_tiebreak(d, 1'b0, iq_idx_t'(i),
                                                                          best_p1_dist, 1'b0, sel_p1_idx)) begin
                                    best_p1_dist = d;
                                    sel_p1_idx   = iq_idx_t'(i);
                                    sel_p1_valid = 1'b1;
                                end
                            end
                        end
                    end
                end else begin
                    // Only u0 ready; issue to Port 0
                    sel_p0_valid = 1'b1;
                    sel_p0_idx   = u0_idx;
                end
            end
        end
    end

    assign issue0_valid_o = sel_p0_valid && !flush_valid_i;
    assign issue0_uop_o   = entries_q[sel_p0_idx];

    assign issue1_valid_o = sel_p1_valid && !flush_valid_i;
    assign issue1_uop_o   = entries_q[sel_p1_idx];

    // -------------------------------------------------------------------------
    // Sequential State Update (Allocation, Deallocation, Wakeup, Squash, Flush)
    // -------------------------------------------------------------------------
    wire uop0_squashed = recover_valid_i && (rob_dist(uop0_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire uop1_squashed = recover_valid_i && (rob_dist(uop1_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    wire uop0_init_prs1_ready = uop0_prs1_ready_i || (uop0_prs1_i == preg_t'(0)) ||
                                (wb0_wake && (uop0_prs1_i == wb0_pnew_i)) ||
                                (wb1_wake && (uop0_prs1_i == wb1_pnew_i)) ||
                                (wb2_wake && (uop0_prs1_i == wb2_pnew_i)) ||
                                (wb3_wake && (uop0_prs1_i == wb3_pnew_i));
    wire uop0_init_prs2_ready = (uop0_use_imm_i && (uop0_class_i != UOP_BRANCH)) || uop0_prs2_ready_i || (uop0_prs2_i == preg_t'(0)) ||
                                (wb0_wake && (uop0_prs2_i == wb0_pnew_i)) ||
                                (wb1_wake && (uop0_prs2_i == wb1_pnew_i)) ||
                                (wb2_wake && (uop0_prs2_i == wb2_pnew_i)) ||
                                (wb3_wake && (uop0_prs2_i == wb3_pnew_i));
    wire uop1_init_prs1_ready = uop1_prs1_ready_i || (uop1_prs1_i == preg_t'(0)) ||
                                (wb0_wake && (uop1_prs1_i == wb0_pnew_i)) ||
                                (wb1_wake && (uop1_prs1_i == wb1_pnew_i)) ||
                                (wb2_wake && (uop1_prs1_i == wb2_pnew_i)) ||
                                (wb3_wake && (uop1_prs1_i == wb3_pnew_i));
    wire uop1_init_prs2_ready = (uop1_use_imm_i && (uop1_class_i != UOP_BRANCH)) || uop1_prs2_ready_i || (uop1_prs2_i == preg_t'(0)) ||
                                (wb0_wake && (uop1_prs2_i == wb0_pnew_i)) ||
                                (wb1_wake && (uop1_prs2_i == wb1_pnew_i)) ||
                                (wb2_wake && (uop1_prs2_i == wb2_pnew_i)) ||
                                (wb3_wake && (uop1_prs2_i == wb3_pnew_i));
    wire [1:0] uop0_port_mask = get_port_mask(uop0_class_i, uop0_exception_i);
    wire [1:0] uop1_port_mask = get_port_mask(uop1_class_i, uop1_exception_i);

    // Per-slot clocked update avoids dynamic multi-port memory inference in synthesis
    generate
        for (genvar gi = 0; gi < INT_IQ_DEPTH; gi++) begin : gen_iq_slot
            localparam iq_idx_t SLOT_IDX = iq_idx_t'(gi);
            wire slot_dealloc = (sel_p0_valid && (sel_p0_idx == SLOT_IDX)) ||
                                (sel_p1_valid && (sel_p1_idx == SLOT_IDX));
            wire slot_squash  = recover_valid_i && entries_q[gi].valid &&
                                (rob_dist(entries_q[gi].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
            wire slot_alloc0  = alloc0_fire && slot0_found && !uop0_squashed && (alloc_slot0 == SLOT_IDX);
            wire slot_alloc1  = alloc1_fire && !uop1_squashed && (alloc_slot1_eff == SLOT_IDX);

            wire slot_wake_prs1 = (wb0_wake && (entries_q[gi].prs1 == wb0_pnew_i)) ||
                                  (wb1_wake && (entries_q[gi].prs1 == wb1_pnew_i)) ||
                                  (wb2_wake && (entries_q[gi].prs1 == wb2_pnew_i)) ||
                                  (wb3_wake && (entries_q[gi].prs1 == wb3_pnew_i));
            wire slot_need_prs2 = !entries_q[gi].use_imm || (entries_q[gi].uop_class == UOP_BRANCH);
            wire slot_wake_prs2 = slot_need_prs2 && (
                                  (wb0_wake && (entries_q[gi].prs2 == wb0_pnew_i)) ||
                                  (wb1_wake && (entries_q[gi].prs2 == wb1_pnew_i)) ||
                                  (wb2_wake && (entries_q[gi].prs2 == wb2_pnew_i)) ||
                                  (wb3_wake && (entries_q[gi].prs2 == wb3_pnew_i)));

            always_ff @(posedge clk_i) begin
                if (rst_i || flush_valid_i) begin
                    entries_q[gi] <= '0;
                end else if (slot_alloc1) begin
                    entries_q[gi].valid         <= 1'b1;
                    entries_q[gi].uop_class     <= uop1_class_i;
                    entries_q[gi].sub_op        <= uop1_subop_i;
                    entries_q[gi].imm           <= uop1_imm_i;
                    entries_q[gi].use_imm       <= uop1_use_imm_i;
                    entries_q[gi].prs1          <= uop1_prs1_i;
                    entries_q[gi].prs1_ready    <= uop1_init_prs1_ready;
                    entries_q[gi].prs2          <= uop1_prs2_i;
                    entries_q[gi].prs2_ready    <= uop1_init_prs2_ready;
                    entries_q[gi].pnew          <= uop1_pnew_i;
                    entries_q[gi].rob_idx       <= uop1_rob_idx_i;
                    entries_q[gi].rob_epoch     <= uop1_rob_epoch_i;
                    entries_q[gi].chkpt_id      <= uop1_chkpt_id_i;
                    entries_q[gi].pc            <= uop1_pc_i;
                    entries_q[gi].pred_taken    <= uop1_pred_taken_i;
                    entries_q[gi].pred_target   <= uop1_pred_target_i;
                    entries_q[gi].is_branch     <= uop1_is_branch_i;
                    entries_q[gi].is_jal        <= uop1_is_jal_i;
                    entries_q[gi].is_jalr       <= uop1_is_jalr_i;
                    entries_q[gi].br_type       <= uop1_br_type_i;
                    entries_q[gi].pre_ghr       <= uop1_pre_ghr_i;
                    entries_q[gi].port_mask     <= uop1_port_mask;
                    entries_q[gi].exception     <= uop1_exception_i;
                    entries_q[gi].exc_cause     <= uop1_exc_cause_i;
                    entries_q[gi].prd_fp        <= uop1_prd_fp_i;
                    entries_q[gi].fp_dest_valid <= uop1_fp_dest_valid_i;
                    entries_q[gi].frm           <= uop1_frm_i;
                end else if (slot_alloc0) begin
                    entries_q[gi].valid         <= 1'b1;
                    entries_q[gi].uop_class     <= uop0_class_i;
                    entries_q[gi].sub_op        <= uop0_subop_i;
                    entries_q[gi].imm           <= uop0_imm_i;
                    entries_q[gi].use_imm       <= uop0_use_imm_i;
                    entries_q[gi].prs1          <= uop0_prs1_i;
                    entries_q[gi].prs1_ready    <= uop0_init_prs1_ready;
                    entries_q[gi].prs2          <= uop0_prs2_i;
                    entries_q[gi].prs2_ready    <= uop0_init_prs2_ready;
                    entries_q[gi].pnew          <= uop0_pnew_i;
                    entries_q[gi].rob_idx       <= uop0_rob_idx_i;
                    entries_q[gi].rob_epoch     <= uop0_rob_epoch_i;
                    entries_q[gi].chkpt_id      <= uop0_chkpt_id_i;
                    entries_q[gi].pc            <= uop0_pc_i;
                    entries_q[gi].pred_taken    <= uop0_pred_taken_i;
                    entries_q[gi].pred_target   <= uop0_pred_target_i;
                    entries_q[gi].is_branch     <= uop0_is_branch_i;
                    entries_q[gi].is_jal        <= uop0_is_jal_i;
                    entries_q[gi].is_jalr       <= uop0_is_jalr_i;
                    entries_q[gi].br_type       <= uop0_br_type_i;
                    entries_q[gi].pre_ghr       <= uop0_pre_ghr_i;
                    entries_q[gi].port_mask     <= uop0_port_mask;
                    entries_q[gi].exception     <= uop0_exception_i;
                    entries_q[gi].exc_cause     <= uop0_exc_cause_i;
                    entries_q[gi].prd_fp        <= uop0_prd_fp_i;
                    entries_q[gi].fp_dest_valid <= uop0_fp_dest_valid_i;
                    entries_q[gi].frm           <= uop0_frm_i;
                end else begin
                    if (slot_dealloc || slot_squash) begin
                        entries_q[gi].valid <= 1'b0;
                    end
                    if (entries_q[gi].valid && !slot_dealloc) begin
                        if (slot_wake_prs1) entries_q[gi].prs1_ready <= 1'b1;
                        if (slot_wake_prs2) entries_q[gi].prs2_ready <= 1'b1;
                    end
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Simulation Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    logic [IQ_CNT_W-1:0] occ_cnt;
    always_comb begin
        occ_cnt = '0;
        for (int i = 0; i < INT_IQ_DEPTH; i++) begin
            if (entries_q[i].valid) occ_cnt = occ_cnt + IQ_CNT_W'(1);
        end
    end

    logic     rec_active_q;
    rob_idx_t rec_idx_q, rec_head_q;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            rec_active_q <= 1'b0;
        end else begin
            rec_active_q <= recover_valid_i;
            rec_idx_q    <= recover_rob_idx_i;
            rec_head_q   <= rob_head_i;

            // 1. IQ occupancy <= INT_IQ_DEPTH
            if (occ_cnt > IQ_CNT_W'(INT_IQ_DEPTH)) begin
                $fatal(1, "[INT_IQ ASSERTION FAILED] IQ occupancy exceeds %0d!", INT_IQ_DEPTH);
            end

            // 2. Recovery must not leave younger IQ entries
            if (rec_active_q && !recover_valid_i && !flush_valid_i) begin
                for (int i = 0; i < INT_IQ_DEPTH; i++) begin
                    if (entries_q[i].valid && (rob_dist(entries_q[i].rob_idx, rec_head_q) > rob_dist(rec_idx_q, rec_head_q))) begin
                        $fatal(1, "[INT_IQ ASSERTION FAILED] Younger entry (slot %0d, rob %0d) survived branch recovery!", i, entries_q[i].rob_idx);
                    end
                end
            end

            // 3. Never issue an unready uop
            if (sel_p0_valid) begin
                if (!ready_p0[sel_p0_idx]) begin
                    $fatal(1, "[INT_IQ ASSERTION FAILED] Port 0 issued an unready uop (slot %0d)!", sel_p0_idx);
                end
                if (entries_q[sel_p0_idx].prs1 != preg_t'(0) && !entries_q[sel_p0_idx].prs1_ready) begin
                    $fatal(1, "[INT_IQ ASSERTION FAILED] Port 0 issued with unready prs1!");
                end
                if (entries_q[sel_p0_idx].prs2 != preg_t'(0) && (!entries_q[sel_p0_idx].use_imm || (entries_q[sel_p0_idx].uop_class == UOP_BRANCH)) && !entries_q[sel_p0_idx].prs2_ready) begin
                    $fatal(1, "[INT_IQ ASSERTION FAILED] Port 0 issued with unready prs2!");
                end
            end
            if (sel_p1_valid) begin
                if (!ready_p1[sel_p1_idx]) begin
                    $fatal(1, "[INT_IQ ASSERTION FAILED] Port 1 issued an unready uop (slot %0d)!", sel_p1_idx);
                end
                if (entries_q[sel_p1_idx].prs1 != preg_t'(0) && !entries_q[sel_p1_idx].prs1_ready) begin
                    $fatal(1, "[INT_IQ ASSERTION FAILED] Port 1 issued with unready prs1!");
                end
                if (entries_q[sel_p1_idx].prs2 != preg_t'(0) && (!entries_q[sel_p1_idx].use_imm || (entries_q[sel_p1_idx].uop_class == UOP_BRANCH)) && !entries_q[sel_p1_idx].prs2_ready) begin
                    $fatal(1, "[INT_IQ ASSERTION FAILED] Port 1 issued with unready prs2!");
                end
            end

            // 4. Never issue the same queue entry on both ports
            if (sel_p0_valid && sel_p1_valid && (sel_p0_idx == sel_p1_idx)) begin
                $fatal(1, "[INT_IQ ASSERTION FAILED] Same slot %0d issued to both Port 0 and Port 1!", sel_p0_idx);
            end

            // Phase B4: Strict Oldest-Ready Priority & No Age Inversion Assertions (Section 7.4)
            // 4a. Younger branch uop NEVER bypasses older ready ALU uop
            if (sel_p0_valid && (entries_q[sel_p0_idx].uop_class == UOP_BRANCH || entries_q[sel_p0_idx].is_branch)) begin
                for (int i = 0; i < INT_IQ_DEPTH; i++) begin
                    if (entries_q[i].valid && (iq_idx_t'(i) != sel_p0_idx) && ready_p0[i] &&
                        !(entries_q[i].uop_class == UOP_BRANCH || entries_q[i].is_branch) &&
                        (rob_dist(entries_q[i].rob_idx, rob_head_i) < rob_dist(entries_q[sel_p0_idx].rob_idx, rob_head_i))) begin
                        assert (sel_p1_valid && (sel_p1_idx == iq_idx_t'(i)))
                            else $fatal(1, "[INT_IQ ASSERTION FAILED] Younger branch (slot %0d, rob %0d) bypassed older ready ALU (slot %0d, rob %0d)!",
                                        sel_p0_idx, entries_q[sel_p0_idx].rob_idx, i, entries_q[i].rob_idx);
                    end
                end
            end

            // 4b. Port 0 strictly selects oldest/highest-priority ready uop unless issued to Port 1
            if (sel_p0_valid) begin
                for (int i = 0; i < INT_IQ_DEPTH; i++) begin
                    if (entries_q[i].valid && (iq_idx_t'(i) != sel_p0_idx) && ready_p0[i] &&
                        !(sel_p1_valid && (sel_p1_idx == iq_idx_t'(i)))) begin
                        assert (!is_older_or_tiebreak(
                            rob_dist(entries_q[i].rob_idx, rob_head_i),
                            entries_q[i].is_branch || (entries_q[i].uop_class == UOP_BRANCH),
                            iq_idx_t'(i),
                            rob_dist(entries_q[sel_p0_idx].rob_idx, rob_head_i),
                            entries_q[sel_p0_idx].is_branch || (entries_q[sel_p0_idx].uop_class == UOP_BRANCH),
                            sel_p0_idx))
                            else $fatal(1, "[INT_IQ ASSERTION FAILED] Port 0 selected slot %0d (rob %0d) when higher-priority slot %0d (rob %0d) was eligible!",
                                        sel_p0_idx, entries_q[sel_p0_idx].rob_idx, i, entries_q[i].rob_idx);
                    end
                end
            end

            // 5. Stale completion cannot wake operands
            if (wb0_valid_i && !wb0_comp_ack_i && (wb0_pnew_i != preg_t'(0))) begin
                for (int i = 0; i < INT_IQ_DEPTH; i++) begin
                    if (entries_q[i].valid && !entries_q[i].prs1_ready && (entries_q[i].prs1 == wb0_pnew_i)) begin
                        if (!wb1_wake || (wb1_pnew_i != entries_q[i].prs1)) begin
                            assert (!wb0_wake) else $fatal(1, "[INT_IQ ASSERTION FAILED] Stale Port 0 WB set prs1_ready!");
                        end
                    end
                    if (entries_q[i].valid && !entries_q[i].prs2_ready && (entries_q[i].prs2 == wb0_pnew_i)) begin
                        if (!wb1_wake || (wb1_pnew_i != entries_q[i].prs2)) begin
                            assert (!wb0_wake) else $fatal(1, "[INT_IQ ASSERTION FAILED] Stale Port 0 WB set prs2_ready!");
                        end
                    end
                end
            end
            if (wb1_valid_i && !wb1_comp_ack_i && (wb1_pnew_i != preg_t'(0))) begin
                for (int i = 0; i < INT_IQ_DEPTH; i++) begin
                    if (entries_q[i].valid && !entries_q[i].prs1_ready && (entries_q[i].prs1 == wb1_pnew_i)) begin
                        if (!wb0_wake || (wb0_pnew_i != entries_q[i].prs1)) begin
                            assert (!wb1_wake) else $fatal(1, "[INT_IQ ASSERTION FAILED] Stale Port 1 WB set prs1_ready!");
                        end
                    end
                    if (entries_q[i].valid && !entries_q[i].prs2_ready && (entries_q[i].prs2 == wb1_pnew_i)) begin
                        if (!wb0_wake || (wb0_pnew_i != entries_q[i].prs2)) begin
                            assert (!wb1_wake) else $fatal(1, "[INT_IQ ASSERTION FAILED] Stale Port 1 WB set prs2_ready!");
                        end
                    end
                end
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_INT_IQ_SV
