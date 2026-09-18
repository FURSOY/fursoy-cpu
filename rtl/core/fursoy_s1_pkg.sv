`ifndef FURSOY_S1_PKG_SV
`define FURSOY_S1_PKG_SV

// =============================================================================
// Fursoy Slice-1 Architectural Package — Milestone 1
// =============================================================================
// Canonical architecture parameters and types for Slice-1 out-of-order core.
// Reference: docs/architecture/slice1-core-v1.md
// =============================================================================

package fursoy_s1_pkg;
    /* verilator lint_off UNUSEDPARAM */

    // -------------------------------------------------------------------------
    // Architectural & Microarchitectural Dimensions
    // -------------------------------------------------------------------------
    localparam int unsigned AREG_COUNT       = 32; // Architectural integer registers x0..x31
    localparam int unsigned PRF_SIZE         = 80; // Unified physical integer registers p0..p79
    localparam int unsigned ROB_DEPTH        = 48; // Reorder buffer entries
    localparam int unsigned FL_DEPTH         = 48; // Free List depth = PRF_SIZE - AREG_COUNT = 48
    localparam int unsigned NUM_CHECKPOINTS  = 8;  // Parameterized branch checkpoints (baseline 8)

    // Bit widths
    localparam int unsigned AREG_IDX_W       = 5;  // $clog2(32)
    localparam int unsigned PRF_IDX_W        = 7;  // $clog2(80) <= 7 (0..79)
    localparam int unsigned ROB_IDX_W        = 6;  // $clog2(48) <= 6 (0..47)
    localparam int unsigned CHKPT_IDX_W      = 3;  // $clog2(8) = 3 (0..7)
    localparam int unsigned ROB_EPOCH_W      = 4;  // 4-bit generation tag (16 lifetimes/slot)
    localparam int unsigned ROB_CNT_W        = 7;  // 0..48
    localparam int unsigned FL_CNT_W         = 7;  // 0..48

    // Type aliases
    typedef logic [AREG_IDX_W-1:0]  areg_t;
    typedef logic [PRF_IDX_W-1:0]   preg_t;
    typedef logic [ROB_IDX_W-1:0]   rob_idx_t;
    typedef logic [CHKPT_IDX_W-1:0] chkpt_idx_t;
    typedef logic [ROB_EPOCH_W-1:0] rob_epoch_t;

    // -------------------------------------------------------------------------
    // Micro-operation Rename Input Structure (2-wide)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic       valid;
        areg_t      rs1;
        areg_t      rs2;
        areg_t      rd;
        logic       is_branch;      // Conditional branch requiring checkpoint
        logic [63:0] pc;
    } uop_rename_in_t;

    // -------------------------------------------------------------------------
    // Renamed Micro-operation Output Structure
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic       valid;
        areg_t      rd;
        preg_t      pnew;
        preg_t      pold;
        areg_t      rs1;
        preg_t      rs1_preg;
        logic       rs1_ready;
        areg_t      rs2;
        preg_t      rs2_preg;
        logic       rs2_ready;
        logic       is_branch;
        chkpt_idx_t chkpt_id;
        rob_idx_t   rob_idx;
        rob_epoch_t rob_epoch;      // Lifetime generation tag for stale completion protection
        logic [63:0] pc;
    } uop_renamed_t;

    // -------------------------------------------------------------------------
    // ROB Entry Structure
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic       valid;
        areg_t      rd;
        preg_t      pnew;
        preg_t      pold;
        rob_epoch_t epoch;          // Slot lifetime generation tag
        logic       completed;
        logic       exception;
        logic [4:0] exc_cause;
        logic       is_branch;
        chkpt_idx_t chkpt_id;
        logic       branch_mispred;
        logic [63:0] pc;
    } rob_entry_t;

    // -------------------------------------------------------------------------
    // Milestone 2 Backend Microarchitectural Dimensions
    // -------------------------------------------------------------------------
    localparam int unsigned INT_IQ_DEPTH     = 16; // Integer issue queue depth
    localparam int unsigned INT_IQ_IDX_W     = 4;  // $clog2(16)
    localparam int unsigned MUL_STAGES       = 3;  // Multiplier pipeline depth K=3 (provisional baseline)
    localparam int unsigned ALU1_FIFO_DEPTH  = 3;  // ALU1 completion buffer depth A=3 (A >= 2)
    localparam int unsigned DIV_BUF_DEPTH    = 1;  // Single-occupancy divider completion buffer

    // -------------------------------------------------------------------------
    // Micro-operation Operation Class & Sub-Operations
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        UOP_ALU_INT   = 4'd0,
        UOP_ALU_SHIFT = 4'd1,
        UOP_ALU_ZBA   = 4'd2,
        UOP_ALU_ZBB   = 4'd3,
        UOP_BRANCH    = 4'd4,
        UOP_JAL       = 4'd5,
        UOP_JALR      = 4'd6,
        UOP_MUL       = 4'd7,
        UOP_DIV       = 4'd8
    } uop_class_t;

    typedef enum logic [5:0] {
        // Base integer ALU (RV64I)
        ALU_ADD       = 6'd0,
        ALU_SUB       = 6'd1,
        ALU_AND       = 6'd2,
        ALU_OR        = 6'd3,
        ALU_XOR       = 6'd4,
        ALU_SLT       = 6'd5,
        ALU_SLTU      = 6'd6,
        ALU_LUI       = 6'd7,
        ALU_AUIPC     = 6'd8,
        // Shifts
        ALU_SLL       = 6'd9,
        ALU_SRL       = 6'd10,
        ALU_SRA       = 6'd11,
        // Word operations (RV64I W-forms)
        ALU_ADDW      = 6'd12,
        ALU_SUBW      = 6'd13,
        ALU_SLLW      = 6'd14,
        ALU_SRLW      = 6'd15,
        ALU_SRAW      = 6'd16,
        // Extension Zba
        ALU_SH1ADD    = 6'd17,
        ALU_SH2ADD    = 6'd18,
        ALU_SH3ADD    = 6'd19,
        ALU_SH1ADD_UW = 6'd20,
        ALU_SH2ADD_UW = 6'd21,
        ALU_SH3ADD_UW = 6'd22,
        ALU_ADD_UW    = 6'd23,
        ALU_SLLI_UW   = 6'd24,
        // Extension Zbb
        ALU_ANDN      = 6'd25,
        ALU_ORN       = 6'd26,
        ALU_XNOR      = 6'd27,
        ALU_CLZ       = 6'd28,
        ALU_CTZ       = 6'd29,
        ALU_CPOP      = 6'd30,
        ALU_MAX       = 6'd31,
        ALU_MAXU      = 6'd32,
        ALU_MIN       = 6'd33,
        ALU_MINU      = 6'd34,
        ALU_SEXTB     = 6'd35,
        ALU_SEXTH     = 6'd36,
        ALU_ZEXTH     = 6'd37,
        ALU_ROL       = 6'd38,
        ALU_ROR       = 6'd39,
        ALU_ORC_B     = 6'd40,
        ALU_REV8      = 6'd41,
        // Conditional Branches
        BR_EQ         = 6'd42,
        BR_NE         = 6'd43,
        BR_LT         = 6'd44,
        BR_GE         = 6'd45,
        BR_LTU        = 6'd46,
        BR_GEU        = 6'd47,
        // Multiplier (RV64M)
        MUL_MUL       = 6'd48,
        MUL_MULH      = 6'd49,
        MUL_MULHSU    = 6'd50,
        MUL_MULHU     = 6'd51,
        MUL_MULW      = 6'd52,
        // Divider (RV64M)
        DIV_DIV       = 6'd53,
        DIV_DIVU      = 6'd54,
        DIV_REM       = 6'd55,
        DIV_REMU      = 6'd56,
        DIV_DIVW      = 6'd57,
        DIV_DIVUW     = 6'd58,
        DIV_REMW      = 6'd59,
        DIV_REMUW     = 6'd60
    } uop_subop_t;

    // -------------------------------------------------------------------------
    // Decoded Micro-operation Structure (Dispatch into IntIQ)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;
        uop_class_t  uop_class;
        uop_subop_t  sub_op;
        logic [63:0] imm;
        logic        use_imm;
        areg_t       rd;
        areg_t       rs1;
        areg_t       rs2;
        logic        is_branch;
        logic        is_jal;
        logic        is_jalr;
        logic        pred_taken;
        logic [63:0] pred_target;
        logic [63:0] pc;
    } uop_decoded_t;

    // -------------------------------------------------------------------------
    // IntIQ Internal Entry Structure
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;
        uop_class_t  uop_class;
        uop_subop_t  sub_op;
        logic [63:0] imm;
        logic        use_imm;
        preg_t       prs1;
        logic        prs1_ready;
        preg_t       prs2;
        logic        prs2_ready;
        preg_t       pnew;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
        chkpt_idx_t  chkpt_id;
        logic [63:0] pc;
        logic        pred_taken;
        logic [63:0] pred_target;
        logic        is_branch;
        logic        is_jal;
        logic        is_jalr;
        logic [1:0]  port_mask;     // Bit 0: P0 eligible, Bit 1: P1 eligible
    } iq_entry_t;

    // -------------------------------------------------------------------------
    // Wrap-Safe ROB Circular Distance Helper
    // dist(idx, head) = (idx - head + 48) mod 48
    // Uses 7-bit intermediate arithmetic to prevent 6-bit modulo-64 wrapping
    // -------------------------------------------------------------------------
    function automatic logic [5:0] rob_dist(
        input rob_idx_t idx,
        input rob_idx_t head
    );
        logic [6:0] diff;
        begin
            diff = {1'b0, idx} + 7'd48 - {1'b0, head};
            rob_dist = (diff >= 7'd48)
                     ? diff[5:0] - 6'd48
                     : diff[5:0];
        end
    endfunction

endpackage

`endif // FURSOY_S1_PKG_SV
