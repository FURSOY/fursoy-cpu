`ifndef FURSOY_S1_BPU_SV
`define FURSOY_S1_BPU_SV

// =============================================================================
// Fursoy Slice-1 Branch Prediction Subsystem (BPU) — Milestone 6 Phase A
// =============================================================================
// Integrates:
// - 512-Entry BTB (2-way set-associative, 256 sets) with dual-branch evaluation.
// - TAGE-Lite Direction Predictor:
//   * T0 Base Predictor: 2,048 entries x 2-bit bimodal saturating counters (4,096 bits)
//   * T1 Tagged Table:   512 entries x (8b tag + 3b ctr + 1b u = 12b) (6,144 bits, L=4)
//   * T2 Tagged Table:   512 entries x (8b tag + 3b ctr + 1b u = 12b) (6,144 bits, L=12)
//   * T3 Tagged Table:   512 entries x (9b tag + 3b ctr + 1b u = 13b) (6,656 bits, L=36)
//   * T4 Tagged Table:   512 entries x (10b tag + 3b ctr + 1b u = 14b) (7,168 bits, L=108)
//   Total Direction Predictor Storage = 30,208 bits (3.6875 KiB).
// - 108-bit Global History Register (GHR) with 1-cycle circular folded history CSRs.
// - 16-Entry Circular Return Address Stack (RAS) with full 16-entry checkpointing.
// - 8 Branch Checkpoints at Rename capturing live GHR and folded CSR bundle.
// - Single-cycle Port 0 Mispredict Recovery and Stage F3 Early JAL Restoration.
// - Periodic 256K retired-branch useful-bit flash reset.
// Reference: docs/architecture/slice1-m6-frontend-opt-v1.md Sections 5, 6, 9, 10
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
    output tage_csr_bundle_t  slot0_csr_chkpt_o,

    // Slot 1 Metadata
    output logic              slot1_btb_hit_o,
    output logic              slot1_pred_taken_o,
    output logic [63:0]       slot1_pred_target_o,
    output branch_type_t      slot1_br_type_o,
    output ghr_t              slot1_pre_ghr_o,
    output ras_chkpt_t        slot1_ras_chkpt_o,
    output tage_csr_bundle_t  slot1_csr_chkpt_o,

    // -------------------------------------------------------------------------
    // Early Stage F3 JAL Correction Interface (Section 3.3 & 6.2)
    // -------------------------------------------------------------------------
    input  logic              early_jal_valid_i,
    input  ghr_t              early_jal_restore_ghr_i,
    input  ras_chkpt_t        early_jal_restore_ras_i,
    input  tage_csr_bundle_t  early_jal_restore_csr_i,

    // -------------------------------------------------------------------------
    // Branch Checkpoint Allocation at Rename (from M1 Substrate)
    // -------------------------------------------------------------------------
    input  logic              chkpt_alloc_valid0_i,
    input  chkpt_idx_t        chkpt_alloc_id0_i,
    input  ghr_t              chkpt_alloc_ghr0_i,
    input  ras_chkpt_t        chkpt_alloc_ras0_i,
    input  tage_csr_bundle_t  chkpt_alloc_csr0_i,

    input  logic              chkpt_alloc_valid1_i,
    input  chkpt_idx_t        chkpt_alloc_id1_i,
    input  ghr_t              chkpt_alloc_ghr1_i,
    input  ras_chkpt_t        chkpt_alloc_ras1_i,
    input  tage_csr_bundle_t  chkpt_alloc_csr1_i,

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
    // Diagnostic / Verification Probes
    // -------------------------------------------------------------------------
    output logic              slot0_tage_pred_o,
    output logic              slot1_tage_pred_o,
    output logic [2:0]        slot0_tage_prov_o,
    output logic [2:0]        slot0_tage_alt_o,
    output logic              slot0_tage_alt_used_o,
    output logic [2:0]        slot1_tage_prov_o,
    output logic [2:0]        slot1_tage_alt_o,
    output logic              slot1_tage_alt_used_o,

    // -------------------------------------------------------------------------
    // Performance Event Probes (Section 8 & 14)
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
    // 2. Return Address Stack (RAS: 16 Entries, 64-bit Return Address)
    // =========================================================================
    logic [15:0][63:0] ras_array;
    logic [3:0]        ras_tos_q;
    logic [4:0]        ras_depth_q;

    wire [63:0] ras_top_val = ras_array[ras_tos_q];

    // Checkpoint Tables for 8 M1 Branch Checkpoints
    ras_chkpt_t       chkpt_ras_table [NUM_CHECKPOINTS];
    ghr_t             chkpt_ghr_table [NUM_CHECKPOINTS];
    tage_csr_bundle_t chkpt_csr_table [NUM_CHECKPOINTS];

    // Current full RAS logical snapshot
    ras_chkpt_t cur_ras_chkpt;
    always_comb begin
        cur_ras_chkpt.ras_array = ras_array;
        cur_ras_chkpt.tos_ptr   = ras_tos_q;
        cur_ras_chkpt.depth     = ras_depth_q;
    end

    assign slot0_ras_chkpt_o = cur_ras_chkpt;
    assign slot1_ras_chkpt_o = cur_ras_chkpt;

    // =========================================================================
    // 3. TAGE-Lite Direction Predictor Structures & Geometry (§5.1, §5.2)
    // =========================================================================
    localparam int T0_ENTRIES   = 2048; // Base table: 2,048 x 2b = 4,096 bits
    localparam int TAGGED_SETS  = 512;  // Tagged tables: 512 sets each

    typedef struct packed {
        logic [7:0] tag;
        logic [2:0] ctr;
        logic       u;
    } t1_entry_t; // 12 bits

    typedef struct packed {
        logic [7:0] tag;
        logic [2:0] ctr;
        logic       u;
    } t2_entry_t; // 12 bits

    typedef struct packed {
        logic [8:0] tag;
        logic [2:0] ctr;
        logic       u;
    } t3_entry_t; // 13 bits

    typedef struct packed {
        logic [9:0] tag;
        logic [2:0] ctr;
        logic       u;
    } t4_entry_t; // 14 bits

    // Table Storage: exactly 30,208 bits
    logic [1:0] t0_table [T0_ENTRIES];
    t1_entry_t  t1_table [TAGGED_SETS];
    t2_entry_t  t2_table [TAGGED_SETS];
    t3_entry_t  t3_table [TAGGED_SETS];
    t4_entry_t  t4_table [TAGGED_SETS];

    // Live Speculative History Vectors
    ghr_t             ghr_q;
    tage_csr_bundle_t csr_q;

    // 19-bit branch retirement counter for periodic useful-bit reset (§5.6)
    logic [18:0] branch_retire_cnt_q;

    wire [107:0] cur_ghr = ghr_q;
    wire tage_csr_bundle_t cur_csr = csr_q;

    // -------------------------------------------------------------------------
    // CSR Single-Cycle Circular Bit-Rotation Functions (§5.3)
    // CSR_next = {CSR_curr[k-2:0], CSR_curr[k-1]} ^ {{(k-1){1'b0}}, b} ^ (GHR[L] << (L % k))
    // -------------------------------------------------------------------------
    function automatic logic [8:0] update_csr_9(
        input logic [8:0] csr_curr,
        input logic       b,
        input logic       ghr_out,
        input int         L
    );
        logic [8:0] rot;
        logic [8:0] out_mask;
        rot = {csr_curr[7:0], csr_curr[8]};
        out_mask = '0;
        out_mask[L % 9] = ghr_out;
        return rot ^ {8'd0, b} ^ out_mask;
    endfunction

    function automatic logic [7:0] update_csr_8(
        input logic [7:0] csr_curr,
        input logic       b,
        input logic       ghr_out,
        input int         L
    );
        logic [7:0] rot;
        logic [7:0] out_mask;
        rot = {csr_curr[6:0], csr_curr[7]};
        out_mask = '0;
        out_mask[L % 8] = ghr_out;
        return rot ^ {7'd0, b} ^ out_mask;
    endfunction

    function automatic logic [9:0] update_csr_10(
        input logic [9:0] csr_curr,
        input logic       b,
        input logic       ghr_out,
        input int         L
    );
        logic [9:0] rot;
        logic [9:0] out_mask;
        rot = {csr_curr[8:0], csr_curr[9]};
        out_mask = '0;
        out_mask[L % 10] = ghr_out;
        return rot ^ {9'd0, b} ^ out_mask;
    endfunction

    function automatic tage_csr_bundle_t update_csr_bundle(
        input tage_csr_bundle_t curr,
        input logic             b,
        input logic [107:0]     ghr
    );
        tage_csr_bundle_t next;
        // T1: L_idx=4 (k=9), L_tagA=4 (k=8), L_tagB=2 (k=8)
        next.csr_idx1  = update_csr_9 (curr.csr_idx1,  b, ghr[3],   4);
        next.csr_taga1 = update_csr_8 (curr.csr_taga1, b, ghr[3],   4);
        next.csr_tagb1 = update_csr_8 (curr.csr_tagb1, b, ghr[1],   2);

        // T2: L_idx=12 (k=9), L_tagA=12 (k=8), L_tagB=6 (k=8)
        next.csr_idx2  = update_csr_9 (curr.csr_idx2,  b, ghr[11], 12);
        next.csr_taga2 = update_csr_8 (curr.csr_taga2, b, ghr[11], 12);
        next.csr_tagb2 = update_csr_8 (curr.csr_tagb2, b, ghr[5],   6);

        // T3: L_idx=36 (k=9), L_tagA=36 (k=9), L_tagB=18 (k=9)
        next.csr_idx3  = update_csr_9 (curr.csr_idx3,  b, ghr[35], 36);
        next.csr_taga3 = update_csr_9 (curr.csr_taga3, b, ghr[35], 36);
        next.csr_tagb3 = update_csr_9 (curr.csr_tagb3, b, ghr[17], 18);

        // T4: L_idx=108 (k=9), L_tagA=108 (k=10), L_tagB=54 (k=10)
        next.csr_idx4  = update_csr_9 (curr.csr_idx4,  b, ghr[107], 108);
        next.csr_taga4 = update_csr_10(curr.csr_taga4, b, ghr[107], 108);
        next.csr_tagb4 = update_csr_10(curr.csr_tagb4, b, ghr[53],  54);

        return next;
    endfunction

    // Fold entire 108-bit GHR from scratch into CSR bundle (§5.3)
    function automatic tage_csr_bundle_t fold_all_csr(input logic [107:0] ghr);
        tage_csr_bundle_t bundle;
        bundle = '0;
        for (int i = 0; i < 4; i++) begin
            bundle.csr_idx1[i % 9]  = bundle.csr_idx1[i % 9]  ^ ghr[i];
            bundle.csr_taga1[i % 8] = bundle.csr_taga1[i % 8] ^ ghr[i];
        end
        for (int i = 0; i < 2; i++) begin
            bundle.csr_tagb1[i % 8] = bundle.csr_tagb1[i % 8] ^ ghr[i];
        end

        for (int i = 0; i < 12; i++) begin
            bundle.csr_idx2[i % 9]  = bundle.csr_idx2[i % 9]  ^ ghr[i];
            bundle.csr_taga2[i % 8] = bundle.csr_taga2[i % 8] ^ ghr[i];
        end
        for (int i = 0; i < 6; i++) begin
            bundle.csr_tagb2[i % 8] = bundle.csr_tagb2[i % 8] ^ ghr[i];
        end

        for (int i = 0; i < 36; i++) begin
            bundle.csr_idx3[i % 9]  = bundle.csr_idx3[i % 9]  ^ ghr[i];
            bundle.csr_taga3[i % 9] = bundle.csr_taga3[i % 9] ^ ghr[i];
        end
        for (int i = 0; i < 18; i++) begin
            bundle.csr_tagb3[i % 9] = bundle.csr_tagb3[i % 9] ^ ghr[i];
        end

        for (int i = 0; i < 108; i++) begin
            bundle.csr_idx4[i % 9]   = bundle.csr_idx4[i % 9]   ^ ghr[i];
            bundle.csr_taga4[i % 10] = bundle.csr_taga4[i % 10] ^ ghr[i];
        end
        for (int i = 0; i < 54; i++) begin
            bundle.csr_tagb4[i % 10] = bundle.csr_tagb4[i % 10] ^ ghr[i];
        end
        return bundle;
    endfunction

    // -------------------------------------------------------------------------
    // Index and Tag Hashing Equations (§5.3)
    // -------------------------------------------------------------------------
    function automatic logic [8:0] calc_idx(
        input logic [63:0] pc,
        input logic [8:0]  csr_idx
    );
        return pc[11:3] ^ csr_idx ^ (csr_idx >> 5);
    endfunction

    function automatic logic [7:0] calc_tag1(
        input logic [63:0] pc,
        input logic [7:0]  csr_taga,
        input logic [7:0]  csr_tagb
    );
        return pc[19:12] ^ csr_taga ^ {csr_tagb[6:0], 1'b0};
    endfunction

    function automatic logic [7:0] calc_tag2(
        input logic [63:0] pc,
        input logic [7:0]  csr_taga,
        input logic [7:0]  csr_tagb
    );
        return pc[19:12] ^ csr_taga ^ {csr_tagb[6:0], 1'b0};
    endfunction

    function automatic logic [8:0] calc_tag3(
        input logic [63:0] pc,
        input logic [8:0]  csr_taga,
        input logic [8:0]  csr_tagb
    );
        return pc[20:12] ^ csr_taga ^ {csr_tagb[7:0], 1'b0};
    endfunction

    function automatic logic [9:0] calc_tag4(
        input logic [63:0] pc,
        input logic [9:0]  csr_taga,
        input logic [9:0]  csr_tagb
    );
        return pc[21:12] ^ csr_taga ^ {csr_tagb[8:0], 1'b0};
    endfunction

    // -------------------------------------------------------------------------
    // 4. Stage F2 Dual-Slot Parallel Prediction Lookup (§5.4)
    // -------------------------------------------------------------------------
    wire [63:0] pc_slot0 = {fetch_pc_i[63:3], 3'b000};
    wire [63:0] pc_slot1 = {fetch_pc_i[63:3], 3'b100};

    // Slot 0 Hash & Table Lookups (uses live cur_ghr and cur_csr)
    wire [10:0] s0_idx0 = pc_slot0[12:2];
    wire [8:0]  s0_idx1 = calc_idx(pc_slot0, cur_csr.csr_idx1);
    wire [8:0]  s0_idx2 = calc_idx(pc_slot0, cur_csr.csr_idx2);
    wire [8:0]  s0_idx3 = calc_idx(pc_slot0, cur_csr.csr_idx3);
    wire [8:0]  s0_idx4 = calc_idx(pc_slot0, cur_csr.csr_idx4);

    wire [7:0]  s0_tag1 = calc_tag1(pc_slot0, cur_csr.csr_taga1, cur_csr.csr_tagb1);
    wire [7:0]  s0_tag2 = calc_tag2(pc_slot0, cur_csr.csr_taga2, cur_csr.csr_tagb2);
    wire [8:0]  s0_tag3 = calc_tag3(pc_slot0, cur_csr.csr_taga3, cur_csr.csr_tagb3);
    wire [9:0]  s0_tag4 = calc_tag4(pc_slot0, cur_csr.csr_taga4, cur_csr.csr_tagb4);

    wire [1:0]      s0_t0_val = t0_table[s0_idx0];
    wire t1_entry_t s0_t1_val = t1_table[s0_idx1];
    wire t2_entry_t s0_t2_val = t2_table[s0_idx2];
    wire t3_entry_t s0_t3_val = t3_table[s0_idx3];
    wire t4_entry_t s0_t4_val = t4_table[s0_idx4];

    wire s0_match1 = (s0_t1_val.tag == s0_tag1);
    wire s0_match2 = (s0_t2_val.tag == s0_tag2);
    wire s0_match3 = (s0_t3_val.tag == s0_tag3);
    wire s0_match4 = (s0_t4_val.tag == s0_tag4);

    // Slot 0 Provider and Altpred Selection (§5.5)
    logic [2:0] s0_prov_id;
    logic [2:0] s0_alt_id;
    logic [2:0] s0_prov_ctr;
    logic       s0_prov_u;
    logic [2:0] s0_alt_ctr;

    always_comb begin
        // Provider: longest matching table T4 > T3 > T2 > T1 > T0
        if (s0_match4) begin
            s0_prov_id  = 3'd4;
            s0_prov_ctr = s0_t4_val.ctr;
            s0_prov_u   = s0_t4_val.u;
            if (s0_match3)      {s0_alt_id, s0_alt_ctr} = {3'd3, s0_t3_val.ctr};
            else if (s0_match2) {s0_alt_id, s0_alt_ctr} = {3'd2, s0_t2_val.ctr};
            else if (s0_match1) {s0_alt_id, s0_alt_ctr} = {3'd1, s0_t1_val.ctr};
            else                {s0_alt_id, s0_alt_ctr} = {3'd0, {1'b0, s0_t0_val}};
        end else if (s0_match3) begin
            s0_prov_id  = 3'd3;
            s0_prov_ctr = s0_t3_val.ctr;
            s0_prov_u   = s0_t3_val.u;
            if (s0_match2)      {s0_alt_id, s0_alt_ctr} = {3'd2, s0_t2_val.ctr};
            else if (s0_match1) {s0_alt_id, s0_alt_ctr} = {3'd1, s0_t1_val.ctr};
            else                {s0_alt_id, s0_alt_ctr} = {3'd0, {1'b0, s0_t0_val}};
        end else if (s0_match2) begin
            s0_prov_id  = 3'd2;
            s0_prov_ctr = s0_t2_val.ctr;
            s0_prov_u   = s0_t2_val.u;
            if (s0_match1)      {s0_alt_id, s0_alt_ctr} = {3'd1, s0_t1_val.ctr};
            else                {s0_alt_id, s0_alt_ctr} = {3'd0, {1'b0, s0_t0_val}};
        end else if (s0_match1) begin
            s0_prov_id  = 3'd1;
            s0_prov_ctr = s0_t1_val.ctr;
            s0_prov_u   = s0_t1_val.u;
            {s0_alt_id, s0_alt_ctr} = {3'd0, {1'b0, s0_t0_val}};
        end else begin
            s0_prov_id  = 3'd0;
            s0_prov_ctr = {1'b0, s0_t0_val};
            s0_prov_u   = 1'b0;
            s0_alt_id   = 3'd0;
            s0_alt_ctr  = {1'b0, s0_t0_val};
        end
    end

    wire s0_pred_prov = (s0_prov_id == 3'd0) ? (s0_t0_val >= 2'b10) : (s0_prov_ctr >= 3'd4);
    wire s0_pred_alt  = (s0_alt_id  == 3'd0) ? (s0_t0_val >= 2'b10) : (s0_alt_ctr  >= 3'd4);

    // Weak provider fallback exception (§5.5, PROP_M6_06)
    wire s0_weak_prov = (s0_prov_id != 3'd0) && (s0_prov_ctr == 3'd3 || s0_prov_ctr == 3'd4) && (s0_prov_u == 1'b0);
    wire s0_tage_pred = s0_weak_prov ? s0_pred_alt : s0_pred_prov;

    // Dual-Slot Speculative Carry Logic (§5.4 Rule P0-1)
    wire s0_is_cond_br = slot0_hit && (slot0_entry.br_type == BR_TYPE_COND);
    logic [107:0]     s1_ghr;
    tage_csr_bundle_t s1_csr;

    always_comb begin
        if (s0_is_cond_br) begin
            if (s0_tage_pred) begin
                // Slot 0 taken: Slot 1 will be suppressed
                s1_ghr = {cur_ghr[106:0], 1'b1};
                s1_csr = update_csr_bundle(cur_csr, 1'b1, cur_ghr);
            end else begin
                // Slot 0 untaken: carry shifted GHR and carried CSR bundle into Slot 1
                s1_ghr = {cur_ghr[106:0], 1'b0};
                s1_csr = update_csr_bundle(cur_csr, 1'b0, cur_ghr);
            end
        end else begin
            // Slot 0 NOT conditional branch: Slot 1 evaluates with unmodified live GHR/CSR
            s1_ghr = cur_ghr;
            s1_csr = cur_csr;
        end
    end

    // Slot 1 Hash & Table Lookups
    wire [10:0] s1_idx0 = pc_slot1[12:2];
    wire [8:0]  s1_idx1 = calc_idx(pc_slot1, s1_csr.csr_idx1);
    wire [8:0]  s1_idx2 = calc_idx(pc_slot1, s1_csr.csr_idx2);
    wire [8:0]  s1_idx3 = calc_idx(pc_slot1, s1_csr.csr_idx3);
    wire [8:0]  s1_idx4 = calc_idx(pc_slot1, s1_csr.csr_idx4);

    wire [7:0]  s1_tag1 = calc_tag1(pc_slot1, s1_csr.csr_taga1, s1_csr.csr_tagb1);
    wire [7:0]  s1_tag2 = calc_tag2(pc_slot1, s1_csr.csr_taga2, s1_csr.csr_tagb2);
    wire [8:0]  s1_tag3 = calc_tag3(pc_slot1, s1_csr.csr_taga3, s1_csr.csr_tagb3);
    wire [9:0]  s1_tag4 = calc_tag4(pc_slot1, s1_csr.csr_taga4, s1_csr.csr_tagb4);

    wire [1:0]      s1_t0_val = t0_table[s1_idx0];
    wire t1_entry_t s1_t1_val = t1_table[s1_idx1];
    wire t2_entry_t s1_t2_val = t2_table[s1_idx2];
    wire t3_entry_t s1_t3_val = t3_table[s1_idx3];
    wire t4_entry_t s1_t4_val = t4_table[s1_idx4];

    wire s1_match1 = (s1_t1_val.tag == s1_tag1);
    wire s1_match2 = (s1_t2_val.tag == s1_tag2);
    wire s1_match3 = (s1_t3_val.tag == s1_tag3);
    wire s1_match4 = (s1_t4_val.tag == s1_tag4);

    // Slot 1 Provider and Altpred Selection
    logic [2:0] s1_prov_id;
    logic [2:0] s1_alt_id;
    logic [2:0] s1_prov_ctr;
    logic       s1_prov_u;
    logic [2:0] s1_alt_ctr;

    always_comb begin
        if (s1_match4) begin
            s1_prov_id  = 3'd4;
            s1_prov_ctr = s1_t4_val.ctr;
            s1_prov_u   = s1_t4_val.u;
            if (s1_match3)      {s1_alt_id, s1_alt_ctr} = {3'd3, s1_t3_val.ctr};
            else if (s1_match2) {s1_alt_id, s1_alt_ctr} = {3'd2, s1_t2_val.ctr};
            else if (s1_match1) {s1_alt_id, s1_alt_ctr} = {3'd1, s1_t1_val.ctr};
            else                {s1_alt_id, s1_alt_ctr} = {3'd0, {1'b0, s1_t0_val}};
        end else if (s1_match3) begin
            s1_prov_id  = 3'd3;
            s1_prov_ctr = s1_t3_val.ctr;
            s1_prov_u   = s1_t3_val.u;
            if (s1_match2)      {s1_alt_id, s1_alt_ctr} = {3'd2, s1_t2_val.ctr};
            else if (s1_match1) {s1_alt_id, s1_alt_ctr} = {3'd1, s1_t1_val.ctr};
            else                {s1_alt_id, s1_alt_ctr} = {3'd0, {1'b0, s1_t0_val}};
        end else if (s1_match2) begin
            s1_prov_id  = 3'd2;
            s1_prov_ctr = s1_t2_val.ctr;
            s1_prov_u   = s1_t2_val.u;
            if (s1_match1)      {s1_alt_id, s1_alt_ctr} = {3'd1, s1_t1_val.ctr};
            else                {s1_alt_id, s1_alt_ctr} = {3'd0, {1'b0, s1_t0_val}};
        end else if (s1_match1) begin
            s1_prov_id  = 3'd1;
            s1_prov_ctr = s1_t1_val.ctr;
            s1_prov_u   = s1_t1_val.u;
            {s1_alt_id, s1_alt_ctr} = {3'd0, {1'b0, s1_t0_val}};
        end else begin
            s1_prov_id  = 3'd0;
            s1_prov_ctr = {1'b0, s1_t0_val};
            s1_prov_u   = 1'b0;
            s1_alt_id   = 3'd0;
            s1_alt_ctr  = {1'b0, s1_t0_val};
        end
    end

    wire s1_pred_prov = (s1_prov_id == 3'd0) ? (s1_t0_val >= 2'b10) : (s1_prov_ctr >= 3'd4);
    wire s1_pred_alt  = (s1_alt_id  == 3'd0) ? (s1_t0_val >= 2'b10) : (s1_alt_ctr  >= 3'd4);

    wire s1_weak_prov = (s1_prov_id != 3'd0) && (s1_prov_ctr == 3'd3 || s1_prov_ctr == 3'd4) && (s1_prov_u == 1'b0);
    wire s1_tage_pred = s1_weak_prov ? s1_pred_alt : s1_pred_prov;

    // Diagnostic Probes
    assign slot0_tage_pred_o     = s0_tage_pred;
    assign slot1_tage_pred_o     = s1_tage_pred;
    assign slot0_tage_prov_o     = s0_prov_id;
    assign slot0_tage_alt_o      = s0_alt_id;
    assign slot0_tage_alt_used_o = s0_weak_prov;
    assign slot1_tage_prov_o     = s1_prov_id;
    assign slot1_tage_alt_o      = s1_alt_id;
    assign slot1_tage_alt_used_o = s1_weak_prov;

    // Checkpoint Export to Rename
    assign slot0_pre_ghr_o   = cur_ghr;
    assign slot0_csr_chkpt_o = cur_csr;
    assign slot1_pre_ghr_o   = s1_ghr;
    assign slot1_csr_chkpt_o = s1_csr;

    // =========================================================================
    // 5. Combined Prediction & Priority Redirect Selection
    // =========================================================================
    logic slot0_taken, slot1_taken;
    logic [63:0] slot0_target, slot1_target;

    always_comb begin
        slot0_taken  = 1'b0;
        slot0_target = pc_slot0 + 64'd4;
        if (slot0_hit) begin
            case (slot0_entry.br_type)
                BR_TYPE_COND: begin
                    slot0_taken  = s0_tage_pred;
                    slot0_target = slot0_entry.target;
                end
                BR_TYPE_JAL, BR_TYPE_CALL: begin
                    slot0_taken  = 1'b1;
                    slot0_target = slot0_entry.target;
                end
                BR_TYPE_RET, BR_TYPE_CORO: begin
                    slot0_taken  = (ras_top_val != 64'd0);
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
                    slot1_taken  = s1_tage_pred;
                    slot1_target = slot1_entry.target;
                end
                BR_TYPE_JAL, BR_TYPE_CALL: begin
                    slot1_taken  = 1'b1;
                    slot1_target = slot1_entry.target;
                end
                BR_TYPE_RET, BR_TYPE_CORO: begin
                    slot1_target = (slot0_hit && (slot0_entry.br_type == BR_TYPE_CALL))
                                 ? (pc_slot0 + 64'd4)
                                 : ras_top_val;
                    slot1_taken  = (slot1_target != 64'd0);
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

    // Block Redirect Logic: Slot 0 priority over Slot 1
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
    assign event_ras_call_o  = fetch_lookup_valid_i && (
        (slot0_hit && ((slot0_entry.br_type == BR_TYPE_CALL) || (slot0_entry.br_type == BR_TYPE_CORO))) ||
        (!slot0_taken && slot1_hit && ((slot1_entry.br_type == BR_TYPE_CALL) || (slot1_entry.br_type == BR_TYPE_CORO)))
    );
    assign event_ras_ret_o   = fetch_lookup_valid_i && (
        (slot0_hit && ((slot0_entry.br_type == BR_TYPE_RET) || (slot0_entry.br_type == BR_TYPE_CORO))) ||
        (!slot0_taken && slot1_hit && ((slot1_entry.br_type == BR_TYPE_RET) || (slot1_entry.br_type == BR_TYPE_CORO)))
    );

    // =========================================================================
    // 6. Sequential State Updates & Training (§5.6, §6.1, §6.2)
    // =========================================================================
    wire [7:0] train_set = train_pc_i[10:3];
    wire [BTB_TAG_W-1:0] train_tag = train_pc_i[63:11];
    wire train_slot = train_pc_i[2];

    // Authoritative Training Combinational Lookup from train_pc_i & train_ghr_i
    wire tage_csr_bundle_t train_csr = fold_all_csr(train_ghr_i);

    wire [10:0] tr_idx0 = train_pc_i[12:2];
    wire [8:0]  tr_idx1 = calc_idx(train_pc_i, train_csr.csr_idx1);
    wire [8:0]  tr_idx2 = calc_idx(train_pc_i, train_csr.csr_idx2);
    wire [8:0]  tr_idx3 = calc_idx(train_pc_i, train_csr.csr_idx3);
    wire [8:0]  tr_idx4 = calc_idx(train_pc_i, train_csr.csr_idx4);

    wire [7:0]  tr_tag1 = calc_tag1(train_pc_i, train_csr.csr_taga1, train_csr.csr_tagb1);
    wire [7:0]  tr_tag2 = calc_tag2(train_pc_i, train_csr.csr_taga2, train_csr.csr_tagb2);
    wire [8:0]  tr_tag3 = calc_tag3(train_pc_i, train_csr.csr_taga3, train_csr.csr_tagb3);
    wire [9:0]  tr_tag4 = calc_tag4(train_pc_i, train_csr.csr_taga4, train_csr.csr_tagb4);

    wire tr_match1 = (t1_table[tr_idx1].tag == tr_tag1);
    wire tr_match2 = (t2_table[tr_idx2].tag == tr_tag2);
    wire tr_match3 = (t3_table[tr_idx3].tag == tr_tag3);
    wire tr_match4 = (t4_table[tr_idx4].tag == tr_tag4);

    logic [2:0] tr_prov_id;
    logic [2:0] tr_alt_id;
    logic [2:0] tr_prov_ctr;
    logic       tr_prov_u;
    logic [2:0] tr_alt_ctr;

    always_comb begin
        if (tr_match4) begin
            tr_prov_id  = 3'd4;
            tr_prov_ctr = t4_table[tr_idx4].ctr;
            tr_prov_u   = t4_table[tr_idx4].u;
            if (tr_match3)      {tr_alt_id, tr_alt_ctr} = {3'd3, t3_table[tr_idx3].ctr};
            else if (tr_match2) {tr_alt_id, tr_alt_ctr} = {3'd2, t2_table[tr_idx2].ctr};
            else if (tr_match1) {tr_alt_id, tr_alt_ctr} = {3'd1, t1_table[tr_idx1].ctr};
            else                {tr_alt_id, tr_alt_ctr} = {3'd0, {1'b0, t0_table[tr_idx0]}};
        end else if (tr_match3) begin
            tr_prov_id  = 3'd3;
            tr_prov_ctr = t3_table[tr_idx3].ctr;
            tr_prov_u   = t3_table[tr_idx3].u;
            if (tr_match2)      {tr_alt_id, tr_alt_ctr} = {3'd2, t2_table[tr_idx2].ctr};
            else if (tr_match1) {tr_alt_id, tr_alt_ctr} = {3'd1, t1_table[tr_idx1].ctr};
            else                {tr_alt_id, tr_alt_ctr} = {3'd0, {1'b0, t0_table[tr_idx0]}};
        end else if (tr_match2) begin
            tr_prov_id  = 3'd2;
            tr_prov_ctr = t2_table[tr_idx2].ctr;
            tr_prov_u   = t2_table[tr_idx2].u;
            if (tr_match1)      {tr_alt_id, tr_alt_ctr} = {3'd1, t1_table[tr_idx1].ctr};
            else                {tr_alt_id, tr_alt_ctr} = {3'd0, {1'b0, t0_table[tr_idx0]}};
        end else if (tr_match1) begin
            tr_prov_id  = 3'd1;
            tr_prov_ctr = t1_table[tr_idx1].ctr;
            tr_prov_u   = t1_table[tr_idx1].u;
            {tr_alt_id, tr_alt_ctr} = {3'd0, {1'b0, t0_table[tr_idx0]}};
        end else begin
            tr_prov_id  = 3'd0;
            tr_prov_ctr = {1'b0, t0_table[tr_idx0]};
            tr_prov_u   = 1'b0;
            tr_alt_id   = 3'd0;
            tr_alt_ctr  = {1'b0, t0_table[tr_idx0]};
        end
    end

    wire tr_pred_prov = (tr_prov_id == 3'd0) ? (t0_table[tr_idx0] >= 2'b10) : (tr_prov_ctr >= 3'd4);
    wire tr_pred_alt  = (tr_alt_id  == 3'd0) ? (t0_table[tr_idx0] >= 2'b10) : (tr_alt_ctr  >= 3'd4);

    wire tr_weak_prov = (tr_prov_id != 3'd0) && (tr_prov_ctr == 3'd3 || tr_prov_ctr == 3'd4) && (tr_prov_u == 1'b0);
    wire tr_final_pred = tr_weak_prov ? tr_pred_alt : tr_pred_prov;
    wire tr_mispred    = (tr_final_pred != train_actual_taken_i);

    // Allocation Target Selection (§5.6)
    // Smallest eligible history table (Lj > Lprov) with u == 0
    logic [2:0] alloc_table_id;
    logic       alloc_success;
    always_comb begin
        alloc_table_id = 3'd0;
        alloc_success  = 1'b0;

        if (tr_prov_id < 3'd1 && t1_table[tr_idx1].u == 1'b0) begin
            alloc_table_id = 3'd1;
            alloc_success  = 1'b1;
        end else if (tr_prov_id < 3'd2 && t2_table[tr_idx2].u == 1'b0) begin
            alloc_table_id = 3'd2;
            alloc_success  = 1'b1;
        end else if (tr_prov_id < 3'd3 && t3_table[tr_idx3].u == 1'b0) begin
            alloc_table_id = 3'd3;
            alloc_success  = 1'b1;
        end else if (tr_prov_id < 3'd4 && t4_table[tr_idx4].u == 1'b0) begin
            alloc_table_id = 3'd4;
            alloc_success  = 1'b1;
        end
    end

    // Sequential Clocked Logic
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ghr_q               <= '0;
            csr_q               <= '0;
            ras_tos_q           <= 4'd0;
            ras_depth_q         <= 5'd0;
            btb_plru            <= '0;
            branch_retire_cnt_q <= 19'd0;

            ras_array <= '0;

            /* verilator lint_off BLKSEQ */
            for (int s = 0; s < BTB_SETS; s++) begin
                for (int w = 0; w < BTB_WAYS; w++) begin
                    btb_array[s][w] = '0;
                end
            end

            for (int i = 0; i < T0_ENTRIES; i++) begin
                t0_table[i] = 2'b01; // Weakly not taken
            end

            for (int i = 0; i < TAGGED_SETS; i++) begin
                t1_table[i].tag = 8'd0;
                t1_table[i].ctr = 3'b011; // Weakly not taken (3)
                t1_table[i].u   = 1'b0;

                t2_table[i].tag = 8'd0;
                t2_table[i].ctr = 3'b011;
                t2_table[i].u   = 1'b0;

                t3_table[i].tag = 9'd0;
                t3_table[i].ctr = 3'b011;
                t3_table[i].u   = 1'b0;

                t4_table[i].tag = 10'd0;
                t4_table[i].ctr = 3'b011;
                t4_table[i].u   = 1'b0;
            end

            for (int k = 0; k < NUM_CHECKPOINTS; k++) begin
                chkpt_ras_table[k] <= '0;
                chkpt_ghr_table[k] <= '0;
                chkpt_csr_table[k] <= '0;
            end
            /* verilator lint_on BLKSEQ */
        end else begin
            // -----------------------------------------------------------------
            // A. Checkpoint Capture at Rename (§6.1)
            // -----------------------------------------------------------------
            if (chkpt_alloc_valid0_i) begin
                chkpt_ghr_table[chkpt_alloc_id0_i] <= chkpt_alloc_ghr0_i;
                chkpt_ras_table[chkpt_alloc_id0_i] <= chkpt_alloc_ras0_i;
                chkpt_csr_table[chkpt_alloc_id0_i] <= chkpt_alloc_csr0_i;
            end
            if (chkpt_alloc_valid1_i) begin
                chkpt_ghr_table[chkpt_alloc_id1_i] <= chkpt_alloc_ghr1_i;
                chkpt_ras_table[chkpt_alloc_id1_i] <= chkpt_alloc_ras1_i;
                chkpt_csr_table[chkpt_alloc_id1_i] <= chkpt_alloc_csr1_i;
            end

            // -----------------------------------------------------------------
            // B. GHR, CSR, and RAS Speculative and Recovery Updates (§6.1, §6.2)
            // Priority: Flush > Port 0 Recovery > Early JAL > Speculative Advance
            // -----------------------------------------------------------------
            if (flush_valid_i) begin
                ghr_q       <= '0;
                csr_q       <= '0;
                ras_tos_q   <= 4'd0;
                ras_depth_q <= 5'd0;
                ras_array   <= '0;
            end else if (recover_valid_i) begin
                // Port 0 Mispredict Recovery: Single-cycle direct restore from checkpoint
                ghr_q <= {chkpt_ghr_table[recover_chkpt_id_i][106:0], recover_actual_taken_i};
                csr_q <= update_csr_bundle(chkpt_csr_table[recover_chkpt_id_i],
                                           recover_actual_taken_i,
                                           chkpt_ghr_table[recover_chkpt_id_i]);
                ras_array   <= chkpt_ras_table[recover_chkpt_id_i].ras_array;
                ras_tos_q   <= chkpt_ras_table[recover_chkpt_id_i].tos_ptr;
                ras_depth_q <= chkpt_ras_table[recover_chkpt_id_i].depth;
            end else if (early_jal_valid_i) begin
                // Early F3 JAL Correction: Exact pre-rename restore
                ghr_q       <= early_jal_restore_ghr_i;
                csr_q       <= early_jal_restore_csr_i;
                ras_array   <= early_jal_restore_ras_i.ras_array;
                ras_tos_q   <= early_jal_restore_ras_i.tos_ptr;
                ras_depth_q <= early_jal_restore_ras_i.depth;
            end else if (fetch_lookup_valid_i) begin
                // Speculative live GHR and CSR advancement
                if (slot0_hit && (slot0_entry.br_type == BR_TYPE_COND)) begin
                    if (slot0_taken) begin
                        ghr_q <= {cur_ghr[106:0], 1'b1};
                        csr_q <= update_csr_bundle(cur_csr, 1'b1, cur_ghr);
                    end else if (slot1_hit && (slot1_entry.br_type == BR_TYPE_COND)) begin
                        // Slot 0 untaken, Slot 1 conditional: sequential 2-bit shift
                        logic [107:0]     mid_ghr;
                        tage_csr_bundle_t mid_csr;
                        mid_ghr = {cur_ghr[106:0], 1'b0};
                        mid_csr = update_csr_bundle(cur_csr, 1'b0, cur_ghr);
                        ghr_q <= {mid_ghr[106:0], s1_tage_pred};
                        csr_q <= update_csr_bundle(mid_csr, s1_tage_pred, mid_ghr);
                    end else begin
                        ghr_q <= {cur_ghr[106:0], 1'b0};
                        csr_q <= update_csr_bundle(cur_csr, 1'b0, cur_ghr);
                    end
                end else if (slot1_hit && (slot1_entry.br_type == BR_TYPE_COND)) begin
                    ghr_q <= {cur_ghr[106:0], s1_tage_pred};
                    csr_q <= update_csr_bundle(cur_csr, s1_tage_pred, cur_ghr);
                end

                // Speculative RAS push / pop / coroutine swap (§6.3)
                if (slot0_hit && (slot0_entry.br_type == BR_TYPE_CALL)) begin
                    ras_tos_q <= 4'(ras_tos_q + 4'd1);
                    ras_array[4'(ras_tos_q + 4'd1)] <= pc_slot0 + 64'd4;
                    if (ras_depth_q < 5'd16) ras_depth_q <= ras_depth_q + 1'b1;
                end else if (slot0_hit && (slot0_entry.br_type == BR_TYPE_RET)) begin
                    ras_tos_q <= 4'(ras_tos_q - 4'd1);
                    if (ras_depth_q > 5'd0) ras_depth_q <= ras_depth_q - 1'b1;
                end else if (slot0_hit && (slot0_entry.br_type == BR_TYPE_CORO)) begin
                    // Case 4: Coroutine Swap (POP then PUSH)
                    // In-place overwrite at current TOS; TOS and depth strictly invariant
                    ras_array[ras_tos_q] <= pc_slot0 + 64'd4;
                end else if (!slot0_taken && slot1_hit) begin
                    if (slot1_entry.br_type == BR_TYPE_CALL) begin
                        ras_tos_q <= 4'(ras_tos_q + 4'd1);
                        ras_array[4'(ras_tos_q + 4'd1)] <= pc_slot1 + 64'd4;
                        if (ras_depth_q < 5'd16) ras_depth_q <= ras_depth_q + 1'b1;
                    end else if (slot1_entry.br_type == BR_TYPE_RET) begin
                        ras_tos_q <= 4'(ras_tos_q - 4'd1);
                        if (ras_depth_q > 5'd0) ras_depth_q <= ras_depth_q - 1'b1;
                    end else if (slot1_entry.br_type == BR_TYPE_CORO) begin
                        // Case 4: Coroutine Swap (POP then PUSH)
                        ras_array[ras_tos_q] <= pc_slot1 + 64'd4;
                    end
                end
            end

            // -----------------------------------------------------------------
            // C. Authoritative Training from Port 0 Resolution (§5.6)
            // -----------------------------------------------------------------
            if (train_valid_i) begin
                // Update BTB Entry on Taken Control-Flow Transfer
                if (train_actual_taken_i) begin
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
                        btb_array[train_set][train_way].target  <= train_actual_target_i;
                        btb_array[train_set][train_way].br_type <= train_br_type_i;
                        btb_plru[train_set] <= ~train_way;
                    end else begin
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

                // Direction Predictor Training (Conditional Branches Only)
                if (train_br_type_i == BR_TYPE_COND) begin
                    // 1. Retirement Counter & Periodic 256K Useful-Bit Flash Reset (§5.6, PROP_M6_16)
                    if (branch_retire_cnt_q == 19'd262143) begin
                        branch_retire_cnt_q <= 19'd0;
                        /* verilator lint_off BLKSEQ */
                        for (int i = 0; i < TAGGED_SETS; i++) begin
                            t1_table[i].u = 1'b0;
                            t2_table[i].u = 1'b0;
                            t3_table[i].u = 1'b0;
                            t4_table[i].u = 1'b0;
                        end
                        /* verilator lint_on BLKSEQ */
                    end else begin
                        branch_retire_cnt_q <= branch_retire_cnt_q + 19'd1;
                    end

                    // 2. Provider Counter Update
                    case (tr_prov_id)
                        3'd0: begin
                            if (train_actual_taken_i) begin
                                if (t0_table[tr_idx0] < 2'b11) t0_table[tr_idx0] <= t0_table[tr_idx0] + 1'b1;
                            end else begin
                                if (t0_table[tr_idx0] > 2'b00) t0_table[tr_idx0] <= t0_table[tr_idx0] - 1'b1;
                            end
                        end
                        3'd1: begin
                            if (train_actual_taken_i) begin
                                if (t1_table[tr_idx1].ctr < 3'd7) t1_table[tr_idx1].ctr <= t1_table[tr_idx1].ctr + 1'b1;
                            end else begin
                                if (t1_table[tr_idx1].ctr > 3'd0) t1_table[tr_idx1].ctr <= t1_table[tr_idx1].ctr - 1'b1;
                            end
                            // Useful bit update when provider != altpred (§5.6, PROP_M6_12, PROP_M6_13)
                            if (tr_pred_prov != tr_pred_alt) begin
                                t1_table[tr_idx1].u <= (tr_pred_prov == train_actual_taken_i);
                            end
                        end
                        3'd2: begin
                            if (train_actual_taken_i) begin
                                if (t2_table[tr_idx2].ctr < 3'd7) t2_table[tr_idx2].ctr <= t2_table[tr_idx2].ctr + 1'b1;
                            end else begin
                                if (t2_table[tr_idx2].ctr > 3'd0) t2_table[tr_idx2].ctr <= t2_table[tr_idx2].ctr - 1'b1;
                            end
                            if (tr_pred_prov != tr_pred_alt) begin
                                t2_table[tr_idx2].u <= (tr_pred_prov == train_actual_taken_i);
                            end
                        end
                        3'd3: begin
                            if (train_actual_taken_i) begin
                                if (t3_table[tr_idx3].ctr < 3'd7) t3_table[tr_idx3].ctr <= t3_table[tr_idx3].ctr + 1'b1;
                            end else begin
                                if (t3_table[tr_idx3].ctr > 3'd0) t3_table[tr_idx3].ctr <= t3_table[tr_idx3].ctr - 1'b1;
                            end
                            if (tr_pred_prov != tr_pred_alt) begin
                                t3_table[tr_idx3].u <= (tr_pred_prov == train_actual_taken_i);
                            end
                        end
                        3'd4: begin
                            if (train_actual_taken_i) begin
                                if (t4_table[tr_idx4].ctr < 3'd7) t4_table[tr_idx4].ctr <= t4_table[tr_idx4].ctr + 1'b1;
                            end else begin
                                if (t4_table[tr_idx4].ctr > 3'd0) t4_table[tr_idx4].ctr <= t4_table[tr_idx4].ctr - 1'b1;
                            end
                            if (tr_pred_prov != tr_pred_alt) begin
                                t4_table[tr_idx4].u <= (tr_pred_prov == train_actual_taken_i);
                            end
                        end
                        default: ;
                    endcase

                    // 3. Allocation on Misprediction (§5.6, PROP_M6_14, PROP_M6_15)
                    if (tr_mispred) begin
                        if (alloc_success) begin
                            // Allocate entry into at most ONE eligible table with minimal L
                            case (alloc_table_id)
                                3'd1: begin
                                    t1_table[tr_idx1].tag <= tr_tag1;
                                    t1_table[tr_idx1].ctr <= train_actual_taken_i ? 3'd4 : 3'd3;
                                    t1_table[tr_idx1].u   <= 1'b0;
                                end
                                3'd2: begin
                                    t2_table[tr_idx2].tag <= tr_tag2;
                                    t2_table[tr_idx2].ctr <= train_actual_taken_i ? 3'd4 : 3'd3;
                                    t2_table[tr_idx2].u   <= 1'b0;
                                end
                                3'd3: begin
                                    t3_table[tr_idx3].tag <= tr_tag3;
                                    t3_table[tr_idx3].ctr <= train_actual_taken_i ? 3'd4 : 3'd3;
                                    t3_table[tr_idx3].u   <= 1'b0;
                                end
                                3'd4: begin
                                    t4_table[tr_idx4].tag <= tr_tag4;
                                    t4_table[tr_idx4].ctr <= train_actual_taken_i ? 3'd4 : 3'd3;
                                    t4_table[tr_idx4].u   <= 1'b0;
                                end
                                default: ;
                            endcase
                        end else begin
                            // All eligible tables have u == 1: decrement/clear useful bits to prevent deadlock
                            if (tr_prov_id < 3'd1) t1_table[tr_idx1].u <= 1'b0;
                            if (tr_prov_id < 3'd2) t2_table[tr_idx2].u <= 1'b0;
                            if (tr_prov_id < 3'd3) t3_table[tr_idx3].u <= 1'b0;
                            if (tr_prov_id < 3'd4) t4_table[tr_idx4].u <= 1'b0;
                        end
                    end
                end
            end
        end
    end

endmodule

`endif // FURSOY_S1_BPU_SV
