`ifndef FURSOY_S0_BPU_SV
`define FURSOY_S0_BPU_SV

// =============================================================================
// Fursoy Slice-0 Branch Prediction Unit (BPU) v1
// Strictly conformant to frozen docs/architecture/branch-prediction-v1.md
// =============================================================================
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off UNUSEDSIGNAL */

module fursoy_s0_bpu #(
    parameter int SETS = 256,
    parameter int WAYS = 2,
    parameter int RAS_DEPTH = 16
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // Stage-F Lookup Interface (parallel with L1I lookup)
    input  logic [63:0] fetch_pc_i,
    input  logic        transfer_fire_f_i, // fetched_valid && !stall_f && !redirect_any_e
    output logic        pred_taken_o,
    output logic [63:0] pred_target_o,
    output logic        btb_hit_o,
    output logic [7:0]  btb_set_o,
    output logic        btb_way_o,
    output logic [1:0]  ras_action_o,
    output logic [3:0]  ras_tos_prev_o,

    // Stage-E Authoritative Interface
    input  logic        commit_fire_i,
    input  logic        stall_e_i,
    input  logic        trap_take_i,
    input  logic        sync_trap_e_i,
    input  logic        fe_valid_i,
    input  logic [63:0] fe_pc_i,
    input  logic [31:0] fe_insn_i,
    input  logic        fe_btb_hit_i,
    input  logic [7:0]  fe_btb_set_i,
    input  logic        fe_btb_way_i,
    input  logic        fe_pred_taken_i,
    input  logic [63:0] fe_pred_target_i,
    input  logic [1:0]  fe_ras_action_i,
    input  logic [3:0]  fe_ras_tos_prev_i,

    // Execution Outcome from Stage E
    input  logic        control_valid_i,
    input  logic        control_misaligned_i,
    input  logic        actual_taken_i,
    input  logic [63:0] actual_target_i,
    input  logic        is_branch_i,
    input  logic        is_jal_i,
    input  logic        is_jalr_i,
    input  logic        is_call_i,
    input  logic        is_ret_i,

    // Stage E Redirect Outputs
    output logic        redirect_branch_o,
    output logic [63:0] redirect_target_o,
    output logic        bpu_mispredict_o,

    // Maintenance / Flush Interface
    input  logic        fence_i_flush_i,
    input  logic        sfence_vma_flush_i,
    input  logic        satp_write_flush_i,

    // Telemetry Event Outputs
    output logic        bpu_branch_count_o   /* verilator public_flat_rd */,
    output logic        bpu_branch_taken_o   /* verilator public_flat_rd */,
    output logic        bpu_branch_correct_o /* verilator public_flat_rd */,
    output logic        bpu_branch_mispred_o /* verilator public_flat_rd */,
    output logic        bpu_jal_count_o      /* verilator public_flat_rd */,
    output logic        bpu_jal_correct_o    /* verilator public_flat_rd */,
    output logic        bpu_jalr_count_o     /* verilator public_flat_rd */,
    output logic        bpu_jalr_correct_o   /* verilator public_flat_rd */,
    output logic        bpu_ras_push_count_o /* verilator public_flat_rd */,
    output logic        bpu_ras_pop_count_o  /* verilator public_flat_rd */,
    output logic        bpu_ras_correct_o    /* verilator public_flat_rd */,
    output logic        bpu_btb_hit_count_o  /* verilator public_flat_rd */,
    output logic        bpu_btb_miss_count_o /* verilator public_flat_rd */,
    output logic        bpu_false_hit_count_o /* verilator public_flat_rd */,
    output logic        bpu_bubble_saved_o   /* verilator public_flat_rd */
);

    // -------------------------------------------------------------------------
    // BTB & RAS Storage Structures
    // -------------------------------------------------------------------------
    // 512 entries: 256 sets x 2 ways
    logic [SETS-1:0][WAYS-1:0]        btb_valid_q   /* verilator public_flat_rd */;
    logic [28:0]                      btb_tag_q     [0:SETS-1][0:WAYS-1] /* verilator public_flat_rd */;
    logic [2:0]                       btb_type_q    [0:SETS-1][0:WAYS-1] /* verilator public_flat_rd */;
    logic [1:0]                       btb_counter_q [0:SETS-1][0:WAYS-1] /* verilator public_flat_rd */;
    logic [63:0]                      btb_target_q  [0:SETS-1][0:WAYS-1] /* verilator public_flat_rd */;
    logic [SETS-1:0]                  btb_plru_q    /* verilator public_flat_rd */;

    // 16-entry Return Address Stack (RAS)
    logic [63:0]                      ras_stack_q   [0:RAS_DEPTH-1]      /* verilator public_flat_rd */;
    logic [3:0]                       ras_tos_q                          /* verilator public_flat_rd */;

    // -------------------------------------------------------------------------
    // Stage-F Combinational Lookup Logic
    // -------------------------------------------------------------------------
    wire [7:0]  set_idx_f      = fetch_pc_i[9:2];
    wire [28:0] tag_f          = fetch_pc_i[38:10];
    wire        is_canonical_f = (fetch_pc_i[63:39] == {25{fetch_pc_i[38]}});

    wire hit_w0 = is_canonical_f && btb_valid_q[set_idx_f][0] && (btb_tag_q[set_idx_f][0] == tag_f);
    wire hit_w1 = is_canonical_f && btb_valid_q[set_idx_f][1] && (btb_tag_q[set_idx_f][1] == tag_f);
    wire btb_hit = hit_w0 || hit_w1;
    wire hit_way = hit_w1 ? 1'b1 : 1'b0;

    wire [2:0]  hit_type    = btb_type_q[set_idx_f][hit_way];
    wire [1:0]  hit_counter = btb_counter_q[set_idx_f][hit_way];
    wire [63:0] hit_target  = btb_target_q[set_idx_f][hit_way];

    // Branch Type Decodes:
    // 3'b000: COND_BRANCH
    // 3'b001: JAL_JUMP
    // 3'b010: CALL_DIRECT
    // 3'b011: RET
    // 3'b100: CALL_INDIRECT
    // 3'b101: JUMP_INDIRECT
    // 3'b110: CO_SWAP
    wire is_uncond       = (hit_type != 3'b000);
    wire is_ret_or_swap  = (hit_type == 3'b011) || (hit_type == 3'b110);

    wire pred_taken = btb_hit && (is_uncond || hit_counter[1]);
    wire [63:0] ras_target = ras_stack_q[ras_tos_q];
    wire [63:0] pred_target = is_ret_or_swap ? ras_target : hit_target;

    assign pred_taken_o   = pred_taken;
    assign pred_target_o  = pred_target;
    assign btb_hit_o      = btb_hit;
    assign btb_set_o      = set_idx_f;
    assign btb_way_o      = hit_way;
    assign ras_tos_prev_o = ras_tos_q;

    // Speculative RAS Action in Stage F (Strictly Qualified by transfer_fire_f_i)
    logic [1:0] spec_ras_action;
    always_comb begin
        spec_ras_action = 2'b00; // None
        if (transfer_fire_f_i && btb_hit && pred_taken) begin
            if (hit_type == 3'b010 || hit_type == 3'b100) begin
                spec_ras_action = 2'b01; // Push
            end else if (hit_type == 3'b011) begin
                spec_ras_action = 2'b10; // Pop
            end else if (hit_type == 3'b110) begin
                spec_ras_action = 2'b11; // Swap
            end
        end
    end
    assign ras_action_o = spec_ras_action;

    // -------------------------------------------------------------------------
    // Stage-E Resolution & Misprediction Recovery
    // -------------------------------------------------------------------------
    wire dir_mispredict    = (fe_pred_taken_i != actual_taken_i);
    wire target_mispredict = actual_taken_i && (fe_pred_target_i != actual_target_i);
    wire false_btb_hit     = fe_pred_taken_i && !control_valid_i;

    // Stage-E Redirect Safety:
    // Mispredict MUST NOT fire while stalled (stall_e_i == 1) or taking a trap/interrupt
    wire mispredict_e = fe_valid_i && !sync_trap_e_i && !trap_take_i && !stall_e_i &&
                        (dir_mispredict || target_mispredict || false_btb_hit);

    assign redirect_branch_o = mispredict_e;
    assign redirect_target_o = actual_taken_i ? actual_target_i : (fe_pc_i + 64'd4);
    assign bpu_mispredict_o  = mispredict_e;

    // Exactly-once authoritative commit condition
    wire bpu_commit_fire = commit_fire_i && !stall_e_i && !sync_trap_e_i && !trap_take_i &&
                          fe_valid_i && control_valid_i && !control_misaligned_i;

    // False BTB hit deallocation condition (on retirement of the non-control instruction)
    wire false_hit_dealloc = commit_fire_i && !stall_e_i && !sync_trap_e_i && !trap_take_i &&
                             fe_valid_i && fe_btb_hit_i && !control_valid_i;

    // Unified flush signal
    wire maintenance_flush = fence_i_flush_i || sfence_vma_flush_i || satp_write_flush_i;

    // Replacement victim selection for allocations
    wire [7:0] fe_set = fe_pc_i[9:2];
    wire victim_way = !btb_valid_q[fe_set][0] ? 1'b0 :
                      (!btb_valid_q[fe_set][1] ? 1'b1 : btb_plru_q[fe_set]);

    // -------------------------------------------------------------------------
    // Sequential State Update Logic
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            btb_valid_q <= '0;
            btb_plru_q  <= '0;
            ras_tos_q   <= 4'd0;
        end else if (maintenance_flush) begin
            // Flash-invalidate all BTB entries & reset RAS
            btb_valid_q <= '0;
            ras_tos_q   <= 4'd0;
        end else begin
            // 1. False BTB Hit Deallocation
            if (false_hit_dealloc) begin
                btb_valid_q[fe_btb_set_i][fe_btb_way_i] <= 1'b0;
            end

            // 2. Authoritative Predictor Updates (Conditional branches, JAL, JALR)
            if (bpu_commit_fire) begin
                if (is_branch_i) begin
                    if (fe_btb_hit_i) begin
                        // Update existing entry counter and target
                        if (actual_taken_i) begin
                            btb_counter_q[fe_btb_set_i][fe_btb_way_i] <= (btb_counter_q[fe_btb_set_i][fe_btb_way_i] == 2'b11) ?
                                                                          2'b11 : (btb_counter_q[fe_btb_set_i][fe_btb_way_i] + 2'b01);
                        end else begin
                            btb_counter_q[fe_btb_set_i][fe_btb_way_i] <= (btb_counter_q[fe_btb_set_i][fe_btb_way_i] == 2'b00) ?
                                                                          2'b00 : (btb_counter_q[fe_btb_set_i][fe_btb_way_i] - 2'b01);
                        end
                        btb_target_q[fe_btb_set_i][fe_btb_way_i] <= actual_target_i;
                        btb_plru_q[fe_btb_set_i] <= ~fe_btb_way_i;
                    end else if (actual_taken_i) begin
                        // Allocate only on taken miss
                        btb_valid_q[fe_set][victim_way]   <= 1'b1;
                        btb_tag_q[fe_set][victim_way]     <= fe_pc_i[38:10];
                        btb_type_q[fe_set][victim_way]    <= 3'b000; // COND_BRANCH
                        btb_counter_q[fe_set][victim_way] <= 2'b10; // Weakly Taken
                        btb_target_q[fe_set][victim_way]  <= actual_target_i;
                        btb_plru_q[fe_set]                <= ~victim_way;
                    end
                end else if (is_jal_i) begin
                    // JAL allocation / update
                    if (fe_btb_hit_i) begin
                        btb_type_q[fe_btb_set_i][fe_btb_way_i]   <= is_call_i ? 3'b010 : 3'b001;
                        btb_target_q[fe_btb_set_i][fe_btb_way_i] <= actual_target_i;
                        btb_plru_q[fe_btb_set_i]                 <= ~fe_btb_way_i;
                    end else begin
                        btb_valid_q[fe_set][victim_way]   <= 1'b1;
                        btb_tag_q[fe_set][victim_way]     <= fe_pc_i[38:10];
                        btb_type_q[fe_set][victim_way]    <= is_call_i ? 3'b010 : 3'b001;
                        btb_counter_q[fe_set][victim_way] <= 2'b11; // Strongly Taken
                        btb_target_q[fe_set][victim_way]  <= actual_target_i;
                        btb_plru_q[fe_set]                <= ~victim_way;
                    end
                end else if (is_jalr_i) begin
                    // JALR allocation / update
                    logic [2:0] jalr_type;
                    jalr_type = (is_call_i && is_ret_i) ? 3'b110 :
                                (is_ret_i ? 3'b011 : (is_call_i ? 3'b100 : 3'b101));
                    if (fe_btb_hit_i) begin
                        btb_type_q[fe_btb_set_i][fe_btb_way_i]   <= jalr_type;
                        btb_target_q[fe_btb_set_i][fe_btb_way_i] <= actual_target_i;
                        btb_plru_q[fe_btb_set_i]                 <= ~fe_btb_way_i;
                    end else begin
                        btb_valid_q[fe_set][victim_way]   <= 1'b1;
                        btb_tag_q[fe_set][victim_way]     <= fe_pc_i[38:10];
                        btb_type_q[fe_set][victim_way]    <= jalr_type;
                        btb_counter_q[fe_set][victim_way] <= 2'b11; // Strongly Taken
                        btb_target_q[fe_set][victim_way]  <= actual_target_i;
                        btb_plru_q[fe_set]                <= ~victim_way;
                    end
                end
            end

            // 3. Return Address Stack (RAS) Updates
            if (trap_take_i || sync_trap_e_i) begin
                // Synchronous trap or asynchronous interrupt: rollback any speculative RAS action
                if (fe_valid_i && (fe_ras_action_i != 2'b00)) begin
                    ras_tos_q <= fe_ras_tos_prev_i;
                end
            end else if (false_hit_dealloc) begin
                // Spurious speculative action on non-control instruction: rollback
                if (fe_ras_action_i != 2'b00) begin
                    ras_tos_q <= fe_ras_tos_prev_i;
                end
            end else if (bpu_commit_fire) begin
                if (is_call_i) begin
                    if (fe_ras_action_i == 2'b00) begin
                        // Cold call (BTB miss): authoritatively push PC+4
                        ras_stack_q[ras_tos_q + 4'd1] <= fe_pc_i + 64'd4;
                        ras_tos_q <= ras_tos_q + 4'd1;
                    end
                    // If fe_ras_action_i == 2'b01, speculative push in Stage F is preserved,
                    // even on target misprediction redirect!
                end else if (is_ret_i) begin
                    if (fe_ras_action_i == 2'b00) begin
                        // Cold return (BTB miss): authoritatively pop
                        ras_tos_q <= ras_tos_q - 4'd1;
                    end
                    // If fe_ras_action_i == 2'b10, speculative pop is preserved.
                end else begin
                    // Not a call, not a return
                    if (fe_ras_action_i != 2'b00) begin
                        // Rollback spurious speculative action
                        ras_tos_q <= fe_ras_tos_prev_i;
                    end
                end
            end else if (spec_ras_action != 2'b00) begin
                // Stage-F Speculative Action (only fires when transfer_fire_f_i is asserted)
                if (spec_ras_action == 2'b01) begin
                    ras_stack_q[ras_tos_q + 4'd1] <= fetch_pc_i + 64'd4;
                    ras_tos_q <= ras_tos_q + 4'd1;
                end else if (spec_ras_action == 2'b10) begin
                    ras_tos_q <= ras_tos_q - 4'd1;
                end else if (spec_ras_action == 2'b11) begin
                    ras_stack_q[ras_tos_q] <= fetch_pc_i + 64'd4;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Observational Performance Telemetry Pulses
    // -------------------------------------------------------------------------
    assign bpu_branch_count_o   = bpu_commit_fire && is_branch_i;
    assign bpu_branch_taken_o   = bpu_commit_fire && is_branch_i && actual_taken_i;
    assign bpu_branch_correct_o = bpu_commit_fire && is_branch_i &&
                                  (fe_pred_taken_i == actual_taken_i) &&
                                  (!actual_taken_i || (fe_pred_target_i == actual_target_i));
    assign bpu_branch_mispred_o = bpu_commit_fire && is_branch_i &&
                                  ((fe_pred_taken_i != actual_taken_i) ||
                                   (actual_taken_i && (fe_pred_target_i != actual_target_i)));

    assign bpu_jal_count_o      = bpu_commit_fire && is_jal_i;
    assign bpu_jal_correct_o    = bpu_commit_fire && is_jal_i && fe_btb_hit_i && fe_pred_taken_i &&
                                  (fe_pred_target_i == actual_target_i);

    assign bpu_jalr_count_o     = bpu_commit_fire && is_jalr_i;
    assign bpu_jalr_correct_o   = bpu_commit_fire && is_jalr_i && fe_btb_hit_i && fe_pred_taken_i &&
                                  (fe_pred_target_i == actual_target_i);

    assign bpu_ras_push_count_o = bpu_commit_fire && is_call_i;
    assign bpu_ras_pop_count_o  = bpu_commit_fire && is_ret_i;
    assign bpu_ras_correct_o    = bpu_commit_fire && is_ret_i && fe_btb_hit_i && (fe_pred_target_i == actual_target_i);
    assign bpu_btb_hit_count_o  = bpu_commit_fire && fe_btb_hit_i;
    assign bpu_btb_miss_count_o = bpu_commit_fire && !fe_btb_hit_i;
    assign bpu_false_hit_count_o = false_hit_dealloc;

    assign bpu_bubble_saved_o   = bpu_commit_fire && actual_taken_i && fe_pred_taken_i &&
                                  (fe_pred_target_i == actual_target_i);

endmodule

`endif // FURSOY_S0_BPU_SV
