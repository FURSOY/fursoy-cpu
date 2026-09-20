`ifndef FURSOY_S1_BPU_SV
`define FURSOY_S1_BPU_SV

// =============================================================================
// Fursoy Slice-1 Branch Prediction Subsystem (BPU) — Milestone 4
// =============================================================================
// Integrates:
// - 512-Entry BTB (2-way set-associative, 256 sets) with dual-branch evaluation.
// - 4096-Entry Gshare direction predictor with 12-bit GHR and carried pre_branch_ghr.
// - 16-Entry Circular Return Address Stack (RAS) with full 16-entry checkpointing.
// - Frontend-local predictor recovery and M1 branch checkpoint rollback.
// Reference: docs/architecture/slice1-m4-frontend-v1.md Sections 5, 6, 7, 8, 9, 10
// =============================================================================

`include "fursoy_s1_pkg.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_bpu
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // -------------------------------------------------------------------------
    // Stage F2 Prediction Lookup Interface (parallel with L1I read)
    // -------------------------------------------------------------------------
    input  logic [63:0]       fetch_pc_i,           // Aligned 64-bit fetch block PC
    input  logic              fetch_lookup_valid_i, // Active fetch request

    // Prediction Outputs for 64-bit Fetch Block (Slot 0 and Slot 1)
    output logic              pred_redirect_o,      // Asserted if taken branch predicted in block
    output logic [63:0]       pred_target_o,        // Target PC to redirect F0
    output logic              pred_slot_o,          // Which slot predicted taken (0 or 1)

    // Slot 0 Metadata
    output logic              slot0_btb_hit_o,
    output logic              slot0_pred_taken_o,
    output logic [63:0]       slot0_pred_target_o,
    output branch_type_t      slot0_br_type_o,
    output ghr_t              slot0_pre_ghr_o,
    output ras_chkpt_t        slot0_ras_chkpt_o,

    // Slot 1 Metadata
    output logic              slot1_btb_hit_o,
    output logic              slot1_pred_taken_o,
    output logic [63:0]       slot1_pred_target_o,
    output branch_type_t      slot1_br_type_o,
    output ghr_t              slot1_pre_ghr_o,
    output ras_chkpt_t        slot1_ras_chkpt_o,

    // -------------------------------------------------------------------------
    // Early Stage F3 JAL Correction Interface (Section 3.3 & 5.2)
    // -------------------------------------------------------------------------
    input  logic              early_jal_valid_i,
    input  ghr_t              early_jal_restore_ghr_i,
    input  ras_chkpt_t        early_jal_restore_ras_i,

    // -------------------------------------------------------------------------
    // Branch Checkpoint Allocation at Rename (from M1 Substrate)
    // -------------------------------------------------------------------------
    input  logic              chkpt_alloc_valid0_i,
    input  chkpt_idx_t        chkpt_alloc_id0_i,
    input  ghr_t              chkpt_alloc_ghr0_i,
    input  ras_chkpt_t        chkpt_alloc_ras0_i,

    input  logic              chkpt_alloc_valid1_i,
    input  chkpt_idx_t        chkpt_alloc_id1_i,
    input  ghr_t              chkpt_alloc_ghr1_i,
    input  ras_chkpt_t        chkpt_alloc_ras1_i,

    // -------------------------------------------------------------------------
    // Backend Resolution & Recovery Interface (Port 0 EX/WB)
    // -------------------------------------------------------------------------
    input  logic              recover_valid_i,       // Port 0 mispredict recovery
    input  chkpt_idx_t        recover_chkpt_id_i,    // Checkpoint to restore
    input  logic              recover_actual_taken_i,
    input  logic [63:0]       recover_actual_target_i,

    // Full Flush (Traps, Interrupts, System Serialization)
    input  logic              flush_valid_i,

    // Predictor Training / Update from Resolved Control-Flow
    input  logic              train_valid_i,
    input  logic [63:0]       train_pc_i,
    input  logic              train_actual_taken_i,
    input  logic [63:0]       train_actual_target_i,
    input  branch_type_t      train_br_type_i,
    input  ghr_t              train_ghr_i,

    // -------------------------------------------------------------------------
    // Performance Event Probes (Section 14)
    // -------------------------------------------------------------------------
    output logic              event_btb_hit_o,
    output logic              event_btb_miss_o,
    output logic              event_cond_pred_o,
    output logic              event_ras_call_o,
    output logic              event_ras_ret_o
);

    // =========================================================================
    // 1. Branch Target Buffer (BTB: 512 Entries, 2-Way, 256 Sets)
    // =========================================================================
    // Fetch PC is 8-byte aligned (PC[2:0] == 3'b000)
    // Set index: PC[10:3] (8 bits -> 256 sets)
    // Tag: PC[63:11] (53 bits)
    localparam int BTB_TAG_W = 53;

    typedef struct packed {
        logic                 valid;
        logic [BTB_TAG_W-1:0] tag;
        logic [63:0]          target;
        logic                 slot;    // 0 = slot 0 (PC[2]==0), 1 = slot 1 (PC[2]==1)
        branch_type_t         br_type;
    } btb_entry_t;

    btb_entry_t btb_array [BTB_SETS][BTB_WAYS];
    logic [BTB_SETS-1:0] btb_plru;

    wire [7:0]            lookup_set = fetch_pc_i[10:3];
    wire [BTB_TAG_W-1:0]  lookup_tag = fetch_pc_i[63:11];

    // Lookup hit evaluation for both ways
    logic [BTB_WAYS-1:0] way_hit;
    btb_entry_t          way_entry [BTB_WAYS];

    always_comb begin
        for (int w = 0; w < BTB_WAYS; w++) begin
            way_entry[w] = btb_array[lookup_set][w];
            way_hit[w]   = way_entry[w].valid && (way_entry[w].tag == lookup_tag);
        end
    end

    // Classify hits by slot
    logic slot0_hit, slot1_hit;
    btb_entry_t slot0_entry, slot1_entry;

    always_comb begin
        slot0_hit   = 1'b0;
        slot1_hit   = 1'b0;
        slot0_entry = '0;
        slot1_entry = '0;

        for (int w = 0; w < BTB_WAYS; w++) begin
            if (way_hit[w]) begin
                if (way_entry[w].slot == 1'b0) begin
                    if (!fetch_pc_i[2]) begin
                        slot0_hit   = 1'b1;
                        slot0_entry = way_entry[w];
                    end
                end else begin
                    slot1_hit   = 1'b1;
                    slot1_entry = way_entry[w];
                end
            end
        end
    end

    assign slot0_btb_hit_o = slot0_hit;
    assign slot1_btb_hit_o = slot1_hit;

    // =========================================================================
    // 2. Gshare Direction Predictor (4096 Entries, 12-bit GHR)
    // =========================================================================
    logic [1:0] pht_array [GSHARE_ENTRIES];
    ghr_t       ghr_q;

    // Current speculative GHR snapshot
    wire [11:0] cur_ghr = ghr_q;

    // Index calculation for Slot 0 and Slot 1
    wire [63:0] pc_slot0 = {fetch_pc_i[63:3], 3'b000};
    wire [63:0] pc_slot1 = {fetch_pc_i[63:3], 3'b100};

    wire [11:0] gshare_idx_slot0 = pc_slot0[13:2] ^ cur_ghr;
    wire [11:0] gshare_idx_slot1 = pc_slot1[13:2] ^ (slot0_hit && (slot0_entry.br_type == BR_TYPE_COND)
                                                     ? {cur_ghr[10:0], pht_array[gshare_idx_slot0][1]}
                                                     : cur_ghr);

    wire slot0_gshare_pred = pht_array[gshare_idx_slot0][1];
    wire slot1_gshare_pred = pht_array[gshare_idx_slot1][1];

    // =========================================================================
    // 3. Return Address Stack (RAS: 16 Entries, 64-bit Return Address)
    // =========================================================================
    // 16-Entry Return Address Stack
    logic [15:0][63:0] ras_array;
    logic [3:0]        ras_tos_q;
    logic [4:0]        ras_depth_q;

    wire [63:0] ras_top_val = ras_array[ras_tos_q];

    // Full Logical State Checkpoints for 8 M1 Branch Checkpoints
    ras_chkpt_t chkpt_ras_table [NUM_CHECKPOINTS];
    ghr_t       chkpt_ghr_table [NUM_CHECKPOINTS];

    // Current full RAS logical snapshot
    ras_chkpt_t cur_ras_chkpt;
    always_comb begin
        cur_ras_chkpt.ras_array = ras_array;
        cur_ras_chkpt.tos_ptr   = ras_tos_q;
        cur_ras_chkpt.depth     = ras_depth_q;
    end

    assign slot0_ras_chkpt_o = cur_ras_chkpt;
    assign slot1_ras_chkpt_o = cur_ras_chkpt;

    assign slot0_pre_ghr_o   = cur_ghr;
    assign slot1_pre_ghr_o   = (slot0_hit && (slot0_entry.br_type == BR_TYPE_COND))
                             ? {cur_ghr[10:0], slot0_gshare_pred}
                             : cur_ghr;

    // =========================================================================
    // 4. Combined Prediction & Priority Redirect Selection
    // =========================================================================
    // Direction evaluation
    logic slot0_taken, slot1_taken;
    logic [63:0] slot0_target, slot1_target;

    always_comb begin
        slot0_taken  = 1'b0;
        slot0_target = pc_slot0 + 64'd4;
        if (slot0_hit) begin
            case (slot0_entry.br_type)
                BR_TYPE_COND: begin
                    slot0_taken  = slot0_gshare_pred;
                    slot0_target = slot0_entry.target;
                end
                BR_TYPE_JAL, BR_TYPE_CALL: begin
                    slot0_taken  = 1'b1;
                    slot0_target = slot0_entry.target;
                end
                BR_TYPE_RET: begin
                    slot0_taken  = 1'b1;
                    slot0_target = ras_top_val;
                end
                BR_TYPE_JALR, BR_TYPE_IND: begin
                    slot0_taken  = 1'b1;
                    slot0_target = slot0_entry.target;
                end
                default: begin
                    slot0_taken  = 1'b0;
                    slot0_target = pc_slot0 + 64'd4;
                end
            endcase
        end

        slot1_taken  = 1'b0;
        slot1_target = pc_slot1 + 64'd4;
        if (slot1_hit) begin
            case (slot1_entry.br_type)
                BR_TYPE_COND: begin
                    slot1_taken  = slot1_gshare_pred;
                    slot1_target = slot1_entry.target;
                end
                BR_TYPE_JAL, BR_TYPE_CALL: begin
                    slot1_taken  = 1'b1;
                    slot1_target = slot1_entry.target;
                end
                BR_TYPE_RET: begin
                    slot1_taken  = 1'b1;
                    slot1_target = (slot0_hit && (slot0_entry.br_type == BR_TYPE_CALL))
                                 ? (pc_slot0 + 64'd4)
                                 : ras_top_val;
                end
                BR_TYPE_JALR, BR_TYPE_IND: begin
                    slot1_taken  = 1'b1;
                    slot1_target = slot1_entry.target;
                end
                default: begin
                    slot1_taken  = 1'b0;
                    slot1_target = pc_slot1 + 64'd4;
                end
            endcase
        end
    end

    assign slot0_pred_taken_o  = slot0_taken;
    assign slot0_pred_target_o = slot0_target;
    assign slot0_br_type_o     = slot0_hit ? slot0_entry.br_type : BR_TYPE_COND;

    assign slot1_pred_taken_o  = slot1_taken;
    assign slot1_pred_target_o = slot1_target;
    assign slot1_br_type_o     = slot1_hit ? slot1_entry.br_type : BR_TYPE_COND;

    // Block Redirect Logic:
    // Slot 0 has priority! If Slot 0 redirects, Slot 1 is ignored completely.
    always_comb begin
        pred_redirect_o = 1'b0;
        pred_target_o   = pc_slot0 + 64'd8;
        pred_slot_o     = 1'b0;

        if (fetch_lookup_valid_i) begin
            if (slot0_taken) begin
                pred_redirect_o = 1'b1;
                pred_target_o   = slot0_target;
                pred_slot_o     = 1'b0;
            end else if (slot1_taken) begin
                pred_redirect_o = 1'b1;
                pred_target_o   = slot1_target;
                pred_slot_o     = 1'b1;
            end
        end
    end

    // Observability Events
    assign event_btb_hit_o   = fetch_lookup_valid_i && (slot0_hit || slot1_hit);
    assign event_btb_miss_o  = fetch_lookup_valid_i && !slot0_hit && !slot1_hit;
    assign event_cond_pred_o = fetch_lookup_valid_i && ((slot0_hit && (slot0_entry.br_type == BR_TYPE_COND)) ||
                                                        (slot1_hit && (slot1_entry.br_type == BR_TYPE_COND)));
    assign event_ras_call_o  = fetch_lookup_valid_i && ((slot0_hit && (slot0_entry.br_type == BR_TYPE_CALL)) ||
                                                        (slot1_hit && (slot1_entry.br_type == BR_TYPE_CALL)));
    assign event_ras_ret_o   = fetch_lookup_valid_i && ((slot0_hit && (slot0_entry.br_type == BR_TYPE_RET)) ||
                                                        (slot1_hit && (slot1_entry.br_type == BR_TYPE_RET)));

    // =========================================================================
    // 5. Sequential State Management (Speculative Updates, Checkpoints, Restores)
    // =========================================================================
    wire [7:0] train_set = train_pc_i[10:3];
    wire [BTB_TAG_W-1:0] train_tag = train_pc_i[63:11];
    wire train_slot = train_pc_i[2];

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ghr_q       <= 12'd0;
            ras_tos_q   <= 4'd0;
            ras_depth_q <= 5'd0;
            btb_plru    <= '0;

            ras_array   <= '0;

            /* verilator lint_off BLKSEQ */
            for (int s = 0; s < BTB_SETS; s++) begin
                for (int w = 0; w < BTB_WAYS; w++) begin
                    btb_array[s][w] = '0;
                end
            end

            for (int i = 0; i < GSHARE_ENTRIES; i++) begin
                pht_array[i] = 2'b01; // Weakly not taken
            end
            /* verilator lint_on BLKSEQ */

            for (int k = 0; k < NUM_CHECKPOINTS; k++) begin
                chkpt_ras_table[k] <= '0;
                chkpt_ghr_table[k] <= 12'd0;
            end
        end else begin
            // -----------------------------------------------------------------
            // A. Checkpoint Capture at Rename (from M1 Rename stage)
            // -----------------------------------------------------------------
            if (chkpt_alloc_valid0_i) begin
                chkpt_ghr_table[chkpt_alloc_id0_i] <= chkpt_alloc_ghr0_i;
                chkpt_ras_table[chkpt_alloc_id0_i] <= chkpt_alloc_ras0_i;
            end
            if (chkpt_alloc_valid1_i) begin
                chkpt_ghr_table[chkpt_alloc_id1_i] <= chkpt_alloc_ghr1_i;
                chkpt_ras_table[chkpt_alloc_id1_i] <= chkpt_alloc_ras1_i;
            end

            // -----------------------------------------------------------------
            // B. GHR and RAS Speculative and Recovery Updates (Priority Ordered)
            // Priority: Flush > Port 0 Recovery > Early JAL > Speculative Advance
            // -----------------------------------------------------------------
            if (flush_valid_i) begin
                ghr_q       <= 12'd0;
                ras_tos_q   <= 4'd0;
                ras_depth_q <= 5'd0;
                ras_array   <= '0;
            end else if (recover_valid_i) begin
                // Port 0 Mispredict Recovery: Exact reconstruction per Section 5.1 & 6.1
                ghr_q       <= {chkpt_ghr_table[recover_chkpt_id_i][10:0], recover_actual_taken_i};
                ras_array   <= chkpt_ras_table[recover_chkpt_id_i].ras_array;
                ras_tos_q   <= chkpt_ras_table[recover_chkpt_id_i].tos_ptr;
                ras_depth_q <= chkpt_ras_table[recover_chkpt_id_i].depth;
            end else if (early_jal_valid_i) begin
                // Early F3 JAL Correction: Exact pre-rename GHR and RAS reconstruction
                ghr_q       <= early_jal_restore_ghr_i;
                ras_array   <= early_jal_restore_ras_i.ras_array;
                ras_tos_q   <= early_jal_restore_ras_i.tos_ptr;
                ras_depth_q <= early_jal_restore_ras_i.depth;
            end else if (fetch_lookup_valid_i) begin
                // Speculative live GHR advancement
                if (slot0_hit && (slot0_entry.br_type == BR_TYPE_COND)) begin
                    if (slot0_taken) begin
                        ghr_q <= {cur_ghr[10:0], 1'b1};
                    end else if (slot1_hit && (slot1_entry.br_type == BR_TYPE_COND)) begin
                        ghr_q <= {cur_ghr[9:0], 1'b0, slot1_gshare_pred};
                    end else begin
                        ghr_q <= {cur_ghr[10:0], 1'b0};
                    end
                end else if (slot1_hit && (slot1_entry.br_type == BR_TYPE_COND)) begin
                    ghr_q <= {cur_ghr[10:0], slot1_gshare_pred};
                end

                // Speculative RAS push / pop
                if (slot0_hit) begin
                    if (slot0_entry.br_type == BR_TYPE_CALL) begin
                        ras_tos_q <= 4'(ras_tos_q + 4'd1);
                        ras_array[4'(ras_tos_q + 4'd1)] <= pc_slot0 + 64'd4;
                        if (ras_depth_q < 5'd16) ras_depth_q <= ras_depth_q + 1'b1;
                    end else if (slot0_entry.br_type == BR_TYPE_RET) begin
                        ras_tos_q <= 4'(ras_tos_q - 4'd1);
                        if (ras_depth_q > 5'd0) ras_depth_q <= ras_depth_q - 1'b1;
                    end
                end else if (slot1_hit) begin
                    if (slot1_entry.br_type == BR_TYPE_CALL) begin
                        ras_tos_q <= 4'(ras_tos_q + 4'd1);
                        ras_array[4'(ras_tos_q + 4'd1)] <= pc_slot1 + 64'd4;
                        if (ras_depth_q < 5'd16) ras_depth_q <= ras_depth_q + 1'b1;
                    end else if (slot1_entry.br_type == BR_TYPE_RET) begin
                        ras_tos_q <= 4'(ras_tos_q - 4'd1);
                        if (ras_depth_q > 5'd0) ras_depth_q <= ras_depth_q - 1'b1;
                    end
                end
            end

            // -----------------------------------------------------------------
            // C. Authoritative Training from Port 0 Resolution
            // -----------------------------------------------------------------
            if (train_valid_i) begin
                // Update Gshare 2-bit Saturating Counter
                if (train_br_type_i == BR_TYPE_COND) begin
                    logic [11:0] tidx;
                    tidx = train_pc_i[13:2] ^ train_ghr_i;
                    if (train_actual_taken_i) begin
                        if (pht_array[tidx] < 2'b11) begin
                            pht_array[tidx] <= pht_array[tidx] + 1'b1;
                        end
                    end else begin
                        if (pht_array[tidx] > 2'b00) begin
                            pht_array[tidx] <= pht_array[tidx] - 1'b1;
                        end
                    end
                end

                // Update BTB Entry on Taken Branch / Call / Jump
                if (train_actual_taken_i) begin
                    // Check if matching entry already exists in the set
                    logic train_hit;
                    logic train_way;
                    train_hit = 1'b0;
                    train_way = 1'b0;

                    for (int w = 0; w < BTB_WAYS; w++) begin
                        if (btb_array[train_set][w].valid &&
                            (btb_array[train_set][w].tag == train_tag) &&
                            (btb_array[train_set][w].slot == train_slot)) begin
                            train_hit = 1'b1;
                            train_way = 1'(w);
                        end
                    end

                    if (train_hit) begin
                        // Update existing entry
                        btb_array[train_set][train_way].target  <= train_actual_target_i;
                        btb_array[train_set][train_way].br_type <= train_br_type_i;
                        btb_plru[train_set] <= ~train_way;
                    end else begin
                        // Allocate into victim way according to pseudo-LRU
                        logic victim_way;
                        victim_way = btb_plru[train_set];

                        btb_array[train_set][victim_way].valid   <= 1'b1;
                        btb_array[train_set][victim_way].tag     <= train_tag;
                        btb_array[train_set][victim_way].slot    <= train_slot;
                        btb_array[train_set][victim_way].target  <= train_actual_target_i;
                        btb_array[train_set][victim_way].br_type <= train_br_type_i;
                        btb_plru[train_set] <= ~victim_way;
                    end
                end
            end
        end
    end

endmodule

`endif // FURSOY_S1_BPU_SV
