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
    localparam int unsigned AREG_COUNT       = 32;  // Architectural integer registers x0..x31
    localparam int unsigned PRF_SIZE         = 160; // Unified physical integer registers p0..p159 (Stage 2 PPA/IPC: 128 -> 160)
    localparam int unsigned ROB_DEPTH        = 128; // Reorder buffer entries (Stage 3 PPA/IPC: 48 -> 128)
    localparam int unsigned FL_DEPTH         = 128; // Free List depth = PRF_SIZE - AREG_COUNT = 128
    localparam int unsigned NUM_CHECKPOINTS  = 8;   // Parameterized branch checkpoints (baseline 8)

    // Bit widths
    localparam int unsigned AREG_IDX_W       = 5;  // $clog2(32)
    localparam int unsigned PRF_IDX_W        = 8;  // $clog2(160) = 8 (0..159)
    localparam int unsigned ROB_IDX_W        = 7;  // $clog2(128) = 7 (0..127)
    localparam int unsigned CHKPT_IDX_W      = 3;  // $clog2(8) = 3 (0..7)
    localparam int unsigned ROB_EPOCH_W      = 4;  // 4-bit generation tag (16 lifetimes/slot)
    localparam int unsigned ROB_CNT_W        = 8;  // 0..128
    localparam int unsigned FL_CNT_W         = 8;  // 0..128

    // Type aliases
    typedef logic [AREG_IDX_W-1:0]  areg_t;
    typedef logic [PRF_IDX_W-1:0]   preg_t;
    typedef preg_t                  prf_id_t;
    typedef logic [ROB_IDX_W-1:0]   rob_idx_t;
    typedef logic [ROB_IDX_W-1:0]   rob_dist_t;
    typedef logic [CHKPT_IDX_W-1:0] chkpt_idx_t;
    typedef logic [ROB_EPOCH_W-1:0] rob_epoch_t;

    // -------------------------------------------------------------------------
    // Milestone 8 Floating-Point (RV64FD) Dimensions & Types
    // -------------------------------------------------------------------------
    localparam int unsigned FAREG_COUNT      = 32; // Architectural FP registers f0..f31
    localparam int unsigned FPRF_SIZE        = 64; // Dedicated FP physical registers fp0..fp63
    localparam int unsigned FL_FP_DEPTH      = 32; // Free List depth = FPRF_SIZE - FAREG_COUNT = 32
    localparam int unsigned FAREG_IDX_W      = 5;  // $clog2(32)
    localparam int unsigned FPRF_IDX_W       = 6;  // $clog2(64)
    localparam int unsigned FL_FP_IDX_W      = 5;  // $clog2(32)
    localparam int unsigned FL_FP_CNT_W      = 6;  // 0..32

    // Type aliases for FP
    typedef logic [FAREG_IDX_W-1:0] fareg_t;
    typedef logic [FPRF_IDX_W-1:0]  fpreg_t;
    typedef logic [FL_FP_IDX_W-1:0] fl_fp_idx_t;

    // Standard RISC-V fcsr structure (CSR 0x003: [7:5] frm, [4:0] fflags)
    typedef struct packed {
        logic [2:0] frm;    // Rounding mode: RNE(0), RTZ(1), RDN(2), RUP(3), RMM(4), DYN(7)
        logic [4:0] fflags; // Accrued exception flags: NV(4), DZ(3), OF(2), UF(1), NX(0)
    } fcsr_t;

    // -------------------------------------------------------------------------
    // Milestone 8 Phase D Vector Architectural Dimensions & Types (RVV 1.0)
    // Reference: docs/architecture/slice1-m8-fp-vector-v1.md Section 8, Section 10
    // -------------------------------------------------------------------------
    localparam int unsigned VLEN           = 256;      // Vector Register Length in bits
    localparam int unsigned ELEN           = 64;       // Maximum Element Width in bits
    localparam int unsigned VLENB          = VLEN / 8; // Vector Register Length in bytes (32)
    localparam int unsigned VRF_NUM_PREGS  = 48;       // 48 Physical Vector Registers
    localparam int unsigned VRF_NUM_BANKS  = 4;        // 4 Banks x 64 bits per physical register
    localparam int unsigned VRF_BANK_WIDTH = 64;       // 64-bit Bank Width
    localparam int unsigned VIQ_DEPTH      = 8;        // 8-entry Decoupled Vector Issue Queue
    localparam int unsigned VIQ_IDX_W      = 3;        // $clog2(8)

    typedef logic [5:0] vreg_t;     // 6-bit physical vector register index (0..47)
    typedef logic [4:0] areg_v_t;   // 5-bit architectural vector register index (v0..v31)
    typedef logic [2:0] viq_idx_t;  // 3-bit VIQ index

    // Vector SEW (Selected Element Width)
    typedef enum logic [2:0] {
        VSEW_8  = 3'b000, // 8-bit elements
        VSEW_16 = 3'b001, // 16-bit elements
        VSEW_32 = 3'b010, // 32-bit elements
        VSEW_64 = 3'b011  // 64-bit elements
    } vsew_t;

    // Vector LMUL (Register Grouping Multiplier)
    typedef enum logic [2:0] {
        VLMUL_1        = 3'b000, // LMUL = 1
        VLMUL_2        = 3'b001, // LMUL = 2
        VLMUL_4        = 3'b010, // LMUL = 4
        VLMUL_8        = 3'b011, // LMUL = 8
        VLMUL_RESERVED = 3'b100, // Reserved (vill=1)
        VLMUL_F8       = 3'b101, // LMUL = 1/8
        VLMUL_F4       = 3'b110, // LMUL = 1/4
        VLMUL_F2       = 3'b111  // LMUL = 1/2
    } vlmul_t;

    // Vector Type Configuration Structure
    typedef struct packed {
        logic       vill;   // Bit 63: Illegal vtype value
        logic       vma;    // Bit 7: Mask Agnostic (1=agnostic, 0=undisturbed)
        logic       vta;    // Bit 6: Tail Agnostic (1=agnostic, 0=undisturbed)
        vsew_t      vsew;   // Bits [5:3]: Selected Element Width
        vlmul_t     vlmul;  // Bits [2:0]: Vector Register Grouping
    } vtype_bundle_t;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [8:0] calc_vlmax(input vtype_bundle_t vt);
        if (vt.vill) return 9'd0;
        case (vt.vlmul)
            VLMUL_1: begin
                case (vt.vsew)
                    VSEW_8:  return 9'd32;
                    VSEW_16: return 9'd16;
                    VSEW_32: return 9'd8;
                    VSEW_64: return 9'd4;
                    default: return 9'd0;
                endcase
            end
            VLMUL_2: begin
                case (vt.vsew)
                    VSEW_8:  return 9'd64;
                    VSEW_16: return 9'd32;
                    VSEW_32: return 9'd16;
                    VSEW_64: return 9'd8;
                    default: return 9'd0;
                endcase
            end
            VLMUL_4: begin
                case (vt.vsew)
                    VSEW_8:  return 9'd128;
                    VSEW_16: return 9'd64;
                    VSEW_32: return 9'd32;
                    VSEW_64: return 9'd16;
                    default: return 9'd0;
                endcase
            end
            VLMUL_8: begin
                case (vt.vsew)
                    VSEW_8:  return 9'd256;
                    VSEW_16: return 9'd128;
                    VSEW_32: return 9'd64;
                    VSEW_64: return 9'd32;
                    default: return 9'd0;
                endcase
            end
            VLMUL_F2: begin
                case (vt.vsew)
                    VSEW_8:  return 9'd16;
                    VSEW_16: return 9'd8;
                    VSEW_32: return 9'd4;
                    default: return 9'd0;
                endcase
            end
            VLMUL_F4: begin
                case (vt.vsew)
                    VSEW_8:  return 9'd8;
                    VSEW_16: return 9'd4;
                    default: return 9'd0;
                endcase
            end
            VLMUL_F8: begin
                case (vt.vsew)
                    VSEW_8:  return 9'd4;
                    default: return 9'd0;
                endcase
            end
            default: return 9'd0;
        endcase
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

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
        // Milestone 8 Phase A Floating-Point Extensions
        logic       is_fp;
        logic       fp_dest_valid;
        fareg_t     fs3;            // Third FP source register (FMA)
        logic [2:0] frm;            // Rounding mode (instruction rm or dynamic)
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
        // Milestone 8 Phase A Floating-Point Extensions
        logic       is_fp;
        logic       fp_dest_valid;
        fpreg_t     prd_fp;
        fpreg_t     pold_fp;
        fpreg_t     prs1_fp;
        logic       prs1_fp_ready;
        fpreg_t     prs2_fp;
        logic       prs2_fp_ready;
        fpreg_t     prs3_fp;
        logic       prs3_fp_ready;
        logic [2:0] frm;
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
        logic [63:0] exc_val;
        logic       is_branch;
        chkpt_idx_t chkpt_id;
        logic       branch_mispred;
        logic       mem_violation;  // Phase B1: Sticky memory-order RAW violation
        logic [63:0] pc;
        // Milestone 8 Phase A Floating-Point Extensions
        logic       is_fp;
        logic       fp_dest_valid;
        fpreg_t     prd_fp;
        fpreg_t     pold_fp;
        logic [4:0] fflags;
        // Milestone 8 Phase D Vector Extensions
        logic       is_vec;
        logic       vec_dest_valid;
        vreg_t      prd_vec;
    } rob_entry_t;

    // -------------------------------------------------------------------------
    // Milestone 2 Backend Microarchitectural Dimensions
    // -------------------------------------------------------------------------
    localparam int unsigned INT_IQ_DEPTH     = 32; // Integer issue queue depth (Stage 3 PPA/IPC: 16 -> 32)
    localparam int unsigned INT_IQ_IDX_W     = 5;  // $clog2(32)
    localparam int unsigned MUL_STAGES       = 3;  // Multiplier pipeline depth K=3 (provisional baseline)
    localparam int unsigned ALU1_FIFO_DEPTH  = 3;  // ALU1 completion buffer depth A=3 (A >= 2)
    localparam int unsigned DIV_BUF_DEPTH    = 1;  // Single-occupancy divider completion buffer

    // -------------------------------------------------------------------------
    // Milestone 3 Memory Subsystem Microarchitectural Dimensions
    // -------------------------------------------------------------------------
    localparam int unsigned MEM_IQ_DEPTH     = 32; // Memory issue queue depth (Stage 3 PPA/IPC: 16 -> 32)
    localparam int unsigned MEM_IQ_IDX_W     = 5;  // $clog2(32) = 5 (0..31)
    localparam int unsigned LQ_DEPTH         = 16; // Load queue depth (provisional parameter)
    localparam int unsigned LQ_IDX_W         = 4;  // $clog2(16) = 4 (0..15)
    localparam int unsigned SQ_DEPTH         = 16; // Store queue depth (provisional parameter)
    localparam int unsigned SQ_IDX_W         = 4;  // $clog2(16) = 4 (0..15)
    localparam int unsigned MSHR_DEPTH       = 4;  // Miss Status Holding Register count (provisional parameter)
    localparam int unsigned MSHR_IDX_W       = 2;  // $clog2(4) = 2 (0..3)
    localparam int unsigned WBB_DEPTH        = 2;  // Writeback buffer depth (provisional parameter)
    localparam int unsigned WBB_IDX_W        = 1;  // $clog2(2) = 1 (0..1)
    localparam int unsigned TRT_DEPTH        = 32; // Translation request table depth (sized to LQ_DEPTH+SQ_DEPTH)
    localparam int unsigned TRT_IDX_W        = 5;  // $clog2(32) = 5 (0..31)

    localparam int unsigned L1D_WAYS         = 4;  // 16 KiB 4-Way baseline
    localparam int unsigned L1D_SETS         = 64; // 64 sets
    localparam int unsigned L1D_LINE_BYTES   = 64; // 64 bytes per cache line (512 bits)
    localparam int unsigned L1D_LINE_BITS    = 512;

    // Physical Memory Map Classification (Milestone 5 Phase B1)
    localparam logic [55:0] DRAM_BASE_PA  = 56'h00_0000_8000_0000;
    localparam logic [55:0] DRAM_LIMIT_PA = 56'h00_0000_8FFF_FFFF;

    function automatic logic is_dram_pa(input logic [55:0] pa);
        return (pa[55:32] == 24'h0) && (pa[31:0] >= 32'h8000_0000) && (pa[31:0] <= 32'h8FFF_FFFF);
    endfunction

    // Type aliases for M3 queue indices
    typedef logic [MEM_IQ_IDX_W-1:0] memiq_idx_t;
    typedef logic [LQ_IDX_W-1:0]     lq_idx_t;
    typedef logic [SQ_IDX_W-1:0]     sq_idx_t;
    typedef logic [MSHR_IDX_W-1:0]   mshr_idx_t;
    typedef logic [WBB_IDX_W-1:0]    wbb_idx_t;
    typedef logic [TRT_IDX_W-1:0]    tr_id_t;

    // Memory Access Size: 0=Byte, 1=Halfword, 2=Word, 3=Doubleword
    typedef enum logic [1:0] {
        MEM_SIZE_BYTE   = 2'b00,
        MEM_SIZE_HALF   = 2'b01,
        MEM_SIZE_WORD   = 2'b10,
        MEM_SIZE_DOUBLE = 2'b11
    } mem_size_t;

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
        UOP_DIV       = 4'd8,
        // Milestone 3 Memory Operation Classes
        UOP_LOAD      = 4'd9,
        UOP_STORE     = 4'd10,
        UOP_AMO       = 4'd11,
        UOP_FENCE     = 4'd12,
        UOP_SYSTEM    = 4'd13,
        UOP_FP        = 4'd14,
        UOP_VEC       = 4'd15
    } uop_class_t;

    typedef enum logic [7:0] {
        // Base integer ALU (RV64I)
        ALU_ADD       = 8'd0,
        ALU_SUB       = 8'd1,
        ALU_AND       = 8'd2,
        ALU_OR        = 8'd3,
        ALU_XOR       = 8'd4,
        ALU_SLT       = 8'd5,
        ALU_SLTU      = 8'd6,
        ALU_LUI       = 8'd7,
        ALU_AUIPC     = 8'd8,
        // Shifts
        ALU_SLL       = 8'd9,
        ALU_SRL       = 8'd10,
        ALU_SRA       = 8'd11,
        // Word operations (RV64I W-forms)
        ALU_ADDW      = 8'd12,
        ALU_SUBW      = 8'd13,
        ALU_SLLW      = 8'd14,
        ALU_SRLW      = 8'd15,
        ALU_SRAW      = 8'd16,
        // Extension Zba
        ALU_SH1ADD    = 8'd17,
        ALU_SH2ADD    = 8'd18,
        ALU_SH3ADD    = 8'd19,
        ALU_SH1ADD_UW = 8'd20,
        ALU_SH2ADD_UW = 8'd21,
        ALU_SH3ADD_UW = 8'd22,
        ALU_ADD_UW    = 8'd23,
        ALU_SLLI_UW   = 8'd24,
        // Extension Zbb
        ALU_ANDN      = 8'd25,
        ALU_ORN       = 8'd26,
        ALU_XNOR      = 8'd27,
        ALU_CLZ       = 8'd28,
        ALU_CTZ       = 8'd29,
        ALU_CPOP      = 8'd30,
        ALU_MAX       = 8'd31,
        ALU_MAXU      = 8'd32,
        ALU_MIN       = 8'd33,
        ALU_MINU      = 8'd34,
        ALU_SEXTB     = 8'd35,
        ALU_SEXTH     = 8'd36,
        ALU_ZEXTH     = 8'd37,
        ALU_ROL       = 8'd38,
        ALU_ROR       = 8'd39,
        ALU_ORC_B     = 8'd40,
        ALU_REV8      = 8'd41,
        // Conditional Branches
        BR_EQ         = 8'd42,
        BR_NE         = 8'd43,
        BR_LT         = 8'd44,
        BR_GE         = 8'd45,
        BR_LTU        = 8'd46,
        BR_GEU        = 8'd47,
        // Multiplier (RV64M)
        MUL_MUL       = 8'd48,
        MUL_MULH      = 8'd49,
        MUL_MULHSU    = 8'd50,
        MUL_MULHU     = 8'd51,
        MUL_MULW      = 8'd52,
        // Divider (RV64M)
        DIV_DIV       = 8'd53,
        DIV_DIVU      = 8'd54,
        DIV_REM       = 8'd55,
        DIV_REMU      = 8'd56,
        DIV_DIVW      = 8'd57,
        DIV_DIVUW     = 8'd58,
        DIV_REMW      = 8'd59,
        DIV_REMUW     = 8'd60,
        // Milestone 3 Loads (RV64I)
        MEM_LB        = 8'd61,
        MEM_LBU       = 8'd62,
        MEM_LH        = 8'd63,
        MEM_LHU       = 8'd64,
        MEM_LW        = 8'd65,
        MEM_LWU       = 8'd66,
        MEM_LD        = 8'd67,
        // Milestone 3 Stores (RV64I)
        MEM_SB        = 8'd68,
        MEM_SH        = 8'd69,
        MEM_SW        = 8'd70,
        MEM_SD        = 8'd71,
        // Milestone 3 Atomics (RV64A LR/SC)
        MEM_LR_W      = 8'd72,
        MEM_LR_D      = 8'd73,
        MEM_SC_W      = 8'd74,
        MEM_SC_D      = 8'd75,
        // Milestone 3 AMO Operations (RV64A)
        AMO_SWAP_W    = 8'd76,
        AMO_SWAP_D    = 8'd77,
        AMO_ADD_W     = 8'd78,
        AMO_ADD_D     = 8'd79,
        AMO_XOR_W     = 8'd80,
        AMO_XOR_D     = 8'd81,
        AMO_AND_W     = 8'd82,
        AMO_AND_D     = 8'd83,
        AMO_OR_W      = 8'd84,
        AMO_OR_D      = 8'd85,
        AMO_MIN_W     = 8'd86,
        AMO_MIN_D     = 8'd87,
        AMO_MAX_W     = 8'd88,
        AMO_MAX_D     = 8'd89,
        AMO_MINU_W    = 8'd90,
        AMO_MINU_D    = 8'd91,
        AMO_MAXU_W    = 8'd92,
        AMO_MAXU_D    = 8'd93,
        // Milestone 3 Fences
        MEM_FENCE     = 8'd94,
        MEM_FENCE_I   = 8'd95,
        // System & CSR Sub-Operations
        SYS_CSRRW     = 8'd96,
        SYS_CSRRS     = 8'd97,
        SYS_CSRRC     = 8'd98,
        SYS_CSRRWI    = 8'd99,
        SYS_CSRRSI    = 8'd100,
        SYS_CSRRCI    = 8'd101,
        SYS_MRET      = 8'd102,
        SYS_SRET      = 8'd103,
        SYS_WFI       = 8'd104,
        SYS_SFENCE_VMA= 8'd105,
        // Milestone 8 Phase B Floating-Point Sub-Operations
        // Pipelined FMA Unit (.S and .D)
        FP_FADD_S     = 8'd106,
        FP_FADD_D     = 8'd107,
        FP_FSUB_S     = 8'd108,
        FP_FSUB_D     = 8'd109,
        FP_FMUL_S     = 8'd110,
        FP_FMUL_D     = 8'd111,
        FP_FMADD_S    = 8'd112,
        FP_FMADD_D    = 8'd113,
        FP_FMSUB_S    = 8'd114,
        FP_FMSUB_D    = 8'd115,
        FP_FNMSUB_S   = 8'd116,
        FP_FNMSUB_D   = 8'd117,
        FP_FNMADD_S   = 8'd118,
        FP_FNMADD_D   = 8'd119,
        // Sign Injection & Min/Max
        FP_FSGNJ_S    = 8'd120,
        FP_FSGNJ_D    = 8'd121,
        FP_FSGNJN_S   = 8'd122,
        FP_FSGNJN_D   = 8'd123,
        FP_FSGNJX_S   = 8'd124,
        FP_FSGNJX_D   = 8'd125,
        FP_FMIN_S     = 8'd126,
        FP_FMIN_D     = 8'd127,
        FP_FMAX_S     = 8'd128,
        FP_FMAX_D     = 8'd129,
        // Iterative Radix-4 SRT FDIV / FSQRT Unit
        FP_FDIV_S     = 8'd130,
        FP_FDIV_D     = 8'd131,
        FP_FSQRT_S    = 8'd132,
        FP_FSQRT_D    = 8'd133,
        // Float-to-Float Conversions
        FP_FCVT_S_D   = 8'd134,
        FP_FCVT_D_S   = 8'd135,
        // FP Comparisons & Classification
        FP_FEQ_S      = 8'd136,
        FP_FEQ_D      = 8'd137,
        FP_FLT_S      = 8'd138,
        FP_FLT_D      = 8'd139,
        FP_FLE_S      = 8'd140,
        FP_FLE_D      = 8'd141,
        FP_FCLASS_S   = 8'd142,
        FP_FCLASS_D   = 8'd143,
        // Float-to-Integer Moves & Conversions
        FP_FMV_X_W    = 8'd144,
        FP_FMV_X_D    = 8'd145,
        FP_FCVT_W_S   = 8'd146,
        FP_FCVT_W_D   = 8'd147,
        FP_FCVT_WU_S  = 8'd148,
        FP_FCVT_WU_D  = 8'd149,
        FP_FCVT_L_S   = 8'd150,
        FP_FCVT_L_D   = 8'd151,
        FP_FCVT_LU_S  = 8'd152,
        FP_FCVT_LU_D  = 8'd153,
        // Integer-to-Float Moves & Conversions
        FP_FMV_W_X    = 8'd154,
        FP_FMV_D_X    = 8'd155,
        FP_FCVT_S_W   = 8'd156,
        FP_FCVT_D_W   = 8'd157,
        FP_FCVT_S_WU  = 8'd158,
        FP_FCVT_D_WU  = 8'd159,
        FP_FCVT_S_L   = 8'd160,
        FP_FCVT_D_L   = 8'd161,
        FP_FCVT_S_LU  = 8'd162,
        FP_FCVT_D_LU  = 8'd163,
        // Milestone 8 Phase C Floating-Point Memory Sub-Operations
        MEM_FLW       = 8'd164,
        MEM_FLD       = 8'd165,
        MEM_FSW       = 8'd166,
        MEM_FSD       = 8'd167,
        // Milestone 8 Phase D Vector Sub-Operations
        VEC_VSETVLI   = 8'd168,
        VEC_VSETVL    = 8'd169,
        VEC_VSETIVLI  = 8'd170,
        // Vector Memory Operations
        VEC_VLE       = 8'd171,
        VEC_VSE       = 8'd172,
        VEC_VLSE      = 8'd173,
        VEC_VSSE      = 8'd174,
        VEC_VLUXEI    = 8'd175,
        VEC_VSOXEI    = 8'd176,
        VEC_VLEFF     = 8'd177,
        // Vector Arithmetic & Logic
        VEC_VADD      = 8'd178,
        VEC_VSUB      = 8'd179,
        VEC_VMUL      = 8'd180,
        VEC_VDIV      = 8'd181,
        VEC_VAND      = 8'd182,
        VEC_VOR       = 8'd183,
        VEC_VXOR      = 8'd184,
        VEC_VREDSUM   = 8'd185,
        VEC_VSLIDEUP  = 8'd186,
        VEC_VSLIDEDOWN= 8'd187,
        VEC_VMAND     = 8'd188,
        VEC_VMOR      = 8'd189,
        // RV64 Zbb Word Sub-Operations
        ALU_CLZW      = 8'd190,
        ALU_CTZW      = 8'd191,
        ALU_CPOPW     = 8'd192,
        ALU_ROLW      = 8'd193,
        ALU_RORW      = 8'd194,
        // Extended Vector Sub-Operations (Full Frontend Integration)
        VEC_VRSUB     = 8'd195,
        VEC_VMV       = 8'd196,
        VEC_VDIVU     = 8'd197,
        VEC_VSLIDE1UP = 8'd198,
        VEC_VSLIDE1DOWN = 8'd199,
        VEC_VMINU     = 8'd200,
        VEC_VMAXU     = 8'd201,
        VEC_VMSEQ     = 8'd202,
        VEC_VMSNE     = 8'd203,
        VEC_VMSLTU    = 8'd204,
        VEC_VMSLT     = 8'd205,
        VEC_VMSLEU    = 8'd206,
        VEC_VMSLE     = 8'd207,
        VEC_VMSGTU    = 8'd208,
        VEC_VMSGT     = 8'd209,
        VEC_VSLL      = 8'd210,
        VEC_VSRL      = 8'd211,
        VEC_VSRA      = 8'd212,
        VEC_VMIN      = 8'd213,
        VEC_VMAX      = 8'd214
    } uop_subop_t;

    // -------------------------------------------------------------------------
    // Milestone 8 Phase B Floating-Point Issue Queue Dimensions & Types
    // -------------------------------------------------------------------------
    localparam int unsigned FPIQ_DEPTH = 16;
    localparam int unsigned FPIQ_IDX_W = 4; // $clog2(16)
    typedef logic [FPIQ_IDX_W-1:0] fpiq_idx_t;

    typedef struct packed {
        logic           valid;
        uop_class_t     uop_class;
        uop_subop_t     sub_op;
        logic [2:0]     frm;
        fpreg_t         prs1_fp;
        logic           prs1_fp_ready;
        logic           use_rs1_fp;
        fpreg_t         prs2_fp;
        logic           prs2_fp_ready;
        logic           use_rs2_fp;
        fpreg_t         prs3_fp;
        logic           prs3_fp_ready;
        logic           use_rs3_fp;
        fpreg_t         prd_fp;
        logic           fp_dest_valid;
        preg_t          pnew;
        logic           int_dest_valid;
        areg_t          rd;
        rob_idx_t       rob_idx;
        rob_epoch_t     rob_epoch;
        logic [63:0]    pc;
    } fpiq_entry_t;



    localparam int unsigned GHR_WIDTH = 108; // 108-bit GHR for Milestone 6 Phase A TAGE-Lite
    typedef logic [GHR_WIDTH-1:0] ghr_t;

    // -------------------------------------------------------------------------
    // Milestone 6 Phase A TAGE-Lite Folded History CSR Bundle (106 bits)
    // Reference: docs/architecture/slice1-m6-frontend-opt-v1.md Section 5.3
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic [8:0]  csr_idx1; // T1 index CSR (9b, L=4)
        logic [8:0]  csr_idx2; // T2 index CSR (9b, L=12)
        logic [8:0]  csr_idx3; // T3 index CSR (9b, L=36)
        logic [8:0]  csr_idx4; // T4 index CSR (9b, L=108)
        logic [7:0]  csr_taga1; // T1 tagA CSR (8b, L=4)
        logic [7:0]  csr_taga2; // T2 tagA CSR (8b, L=12)
        logic [8:0]  csr_taga3; // T3 tagA CSR (9b, L=36)
        logic [9:0]  csr_taga4; // T4 tagA CSR (10b, L=108)
        logic [7:0]  csr_tagb1; // T1 tagB CSR (8b, L=2)
        logic [7:0]  csr_tagb2; // T2 tagB CSR (8b, L=6)
        logic [8:0]  csr_tagb3; // T3 tagB CSR (9b, L=18)
        logic [9:0]  csr_tagb4; // T4 tagB CSR (10b, L=54)
    } tage_csr_bundle_t;

    // Branch Type Classification (including Milestone 6 Phase B Coroutine Swap)
    typedef enum logic [2:0] {
        BR_TYPE_COND = 3'd0,
        BR_TYPE_JAL  = 3'd1,
        BR_TYPE_JALR = 3'd2,
        BR_TYPE_CALL = 3'd3,
        BR_TYPE_RET  = 3'd4,
        BR_TYPE_IND  = 3'd5,
        BR_TYPE_CORO = 3'd6
    } branch_type_t;

    // 5-Case RISC-V Calling Convention Link-Register Classification (§2.5, M6 §6.3)
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic branch_type_t classify_branch(
        input logic [31:0] inst,
        input logic        is_branch,
        input logic        is_jal,
        input logic        is_jalr
    );
        logic [4:0] rd;
        logic [4:0] rs1;
        logic is_link_rd;
        logic is_link_rs;
        rd  = inst[11:7];
        rs1 = inst[19:15];
        is_link_rd = (rd == 5'd1 || rd == 5'd5);
        is_link_rs = (rs1 == 5'd1 || rs1 == 5'd5);
        if (is_jal) begin
            return is_link_rd ? BR_TYPE_CALL : BR_TYPE_JAL;
        end else if (is_jalr) begin
            if (!is_link_rd && !is_link_rs) begin
                // Case 1: Neither link -> None (standard indirect jump)
                return BR_TYPE_IND;
            end else if (is_link_rd && !is_link_rs) begin
                // Case 2: Link rd, non-link rs1 -> PUSH (Call)
                return BR_TYPE_CALL;
            end else if (!is_link_rd && is_link_rs) begin
                // Case 3: Non-link rd, link rs1 -> POP (Return)
                return BR_TYPE_RET;
            end else if (is_link_rd && is_link_rs && (rd != rs1)) begin
                // Case 4: Link rd, link rs1, rd != rs1 -> POP then PUSH (Coroutine Swap)
                return BR_TYPE_CORO;
            end else begin
                // Case 5: Link rd, link rs1, rd == rs1 -> PUSH only (Special link re-use)
                return BR_TYPE_CALL;
            end
        end else if (is_branch) begin
            return BR_TYPE_COND;
        end
        return BR_TYPE_COND;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */


    // -------------------------------------------------------------------------
    // Decoded Micro-operation Structure (Dispatch into IntIQ / MemIQ)
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
        branch_type_t br_type;
        ghr_t        pre_ghr;
        logic        pred_taken;
        logic [63:0] pred_target;
        logic [63:0] pc;
        logic        exception;
        logic [4:0]  exc_cause;
        logic        replay_safe;   // Phase B1: One-shot conservative issue token
        // Milestone 8 Phase A Floating-Point Extensions
        logic        is_fp;
        logic        fp_dest_valid;
        fareg_t      fs3;
        logic [2:0]  frm;
        // Milestone 8 Full Vector Frontend Metadata
        logic        is_vec;
        logic        vec_dest_valid;
        logic        vec_vm;
        logic        vec_uses_rs1;
        logic        vec_uses_rs2;
        logic        vec_uses_vs1;
        logic        vec_uses_vs2;
        logic [2:0]  vec_eew;
        logic [1:0]  vec_mop;
        logic [4:0]  vec_vd;
        logic [4:0]  vec_vs1;
        logic [4:0]  vec_vs2;
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
        branch_type_t br_type;
        ghr_t        pre_ghr;
        logic [1:0]  port_mask;     // Bit 0: P0 eligible, Bit 1: P1 eligible
        logic        exception;
        logic [4:0]  exc_cause;
        // Milestone 8 Int-to-Float fields
        fpreg_t      prd_fp;
        logic        fp_dest_valid;
        logic [2:0]  frm;
    } iq_entry_t;

    // -------------------------------------------------------------------------
    // MemIQ Internal Entry Structure (Section 4.1)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;
        uop_class_t  uop_class;     // UOP_LOAD, UOP_STORE, UOP_AMO, UOP_FENCE
        uop_subop_t  sub_op;
        mem_size_t   size;          // Byte, Halfword, Word, Doubleword
        logic        sign_ext;      // 1=signed, 0=unsigned
        logic [63:0] imm;           // Address displacement
        preg_t       prs1;          // Base address physical register
        logic        prs1_ready;
        preg_t       prs2;          // Store data physical register (stores only)
        logic        prs2_ready;
        preg_t       pnew;          // Destination physical register (loads only)
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
        lq_idx_t     lq_idx;        // Assigned Load Queue slot
        sq_idx_t     sq_idx;        // Assigned Store Queue slot
        logic [63:0] pc;
        logic        addr_issued;   // Set when address has been issued to AGU
        logic        replay_safe;   // Phase B1: Stamped conservative issue flag
    } memiq_entry_t;

    // -------------------------------------------------------------------------
    // Load Queue Entry Structure (Section 5)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;
        uop_subop_t  sub_op;
        mem_size_t   size;
        logic        sign_ext;
        preg_t       pnew;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
        logic [63:0] pc;
        logic [63:0] va;
        logic [55:0] pa;
        logic        pa_valid;
        logic        wait_translation;
        tr_id_t      tr_id;
        logic [15:0] sq_older_mask; // Explicit older-store bitmask at allocation
        logic [15:0] sq_unresolved_mask; // Stores older at dispatch whose PA/CAM is unresolved
        logic        is_speculative; // Issued speculatively past unresolved store
        logic        replay_safe;   // Conservative issue constraint active
        logic        violated;      // Violated by an older store CAM check
        logic        wb_done;       // Execution writeback completed to PRF/ROB
        logic        is_mmio;
        logic        is_lr;
        logic        align_fault;
        logic        page_fault;
        logic        access_fault;
        logic        issued_to_l1d;
        mshr_idx_t   mshr_id;
        logic        forwarded;
        logic [63:0] forward_data;
        logic        completed;     // Reported to ROB
        logic [63:0] result_data;
        // Milestone 8 Phase C FP Memory attributes
        logic        is_fp;
        fpreg_t      prd_fp;
    } lq_entry_t;

    // -------------------------------------------------------------------------
    // Store Queue Entry Structure (Section 5)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;
        uop_subop_t  sub_op;
        mem_size_t   size;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
        logic [63:0] pc;
        logic [63:0] va;
        logic [55:0] pa;
        logic        pa_valid;
        logic        wait_translation;
        tr_id_t      tr_id;
        logic [63:0] data;
        logic        data_valid;
        preg_t       prs2;          // Monitored for async data capture
        logic [7:0]  mask;          // Active byte lane mask relative to aligned 8B word
        logic        align_fault;
        logic        page_fault;
        logic        access_fault;
        logic        is_mmio;
        logic        is_sc;
        logic        is_amo;
        logic        is_fence;
        preg_t       pnew;          // Destination physical register (SC / AMO)
        logic        sc_success;    // Outcome of reservation match (SC only)
        logic        exception_pending;
        logic [4:0]  exc_cause;
        logic        completed;     // Reported to ROB (bifurcated completion)
        logic        committed;     // Retired at ROB head; awaiting in-order L1D drain
        logic        drained;
        // Milestone 8 Phase C FP Memory attributes
        logic        is_fp;
        fpreg_t      prs2_fp;
    } sq_entry_t;

    // -------------------------------------------------------------------------
    // MSHR Per-Waiter Active Descriptor Structure (Section 9)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        waiter_valid;
        lq_idx_t     lq_idx;
        logic [5:0]  line_offset;   // Byte offset within 64B cache line (PA[5:0])
        mem_size_t   size;
        logic        sign_ext;
        preg_t       pnew;
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
    } mshr_waiter_t;

    // -------------------------------------------------------------------------
    // MSHR Entry Structure (Section 9)
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        MSHR_IDLE          = 3'd0,
        MSHR_WAIT_BUS      = 3'd1,
        MSHR_REQ_SENT      = 3'd2,
        MSHR_REFILL_DATA   = 3'd3,
        MSHR_DRAIN_WAITERS = 3'd4
    } mshr_state_t;

    typedef struct packed {
        logic             valid;
        logic [49:0]      line_addr;          // PA[55:6] (64-byte line aligned)
        mshr_state_t      state;
        mshr_idx_t        bus_tag;            // External transaction tag
        wbb_idx_t         wbb_reserved_slot;  // Pre-reserved WBB dirty victim slot
        logic             wbb_has_reservation;
        logic [1:0]       victim_way;         // Frozen replacement victim way
        logic [43:0]      victim_tag;         // Frozen victim tag
        logic [511:0]     victim_data;        // Frozen victim data payload
        logic             victim_dirty;       // Frozen victim dirty status
        logic [15:0]      waiter_mask;        // Active LQ waiters
        logic [15:0]      store_drain_mask;   // Committed SQ entries waiting to write-allocate
    } mshr_entry_t;

    // -------------------------------------------------------------------------
    // Writeback Buffer (WBB) Entry Structure (Section 10)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;
        logic        dirty;
        logic [49:0] line_addr;     // PA[55:6]
        logic [511:0] data;         // 64-byte dirty line
        logic [63:0] dirty_mask;    // Per-byte dirty mask (64 bits)
        logic        draining;      // Bus drain in progress
    } wbb_entry_t;

    // -------------------------------------------------------------------------
    // Translation Request Table (TRT) Entry Structure (Section 12)
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;
        logic        is_store;      // 1=Store/AMO, 0=Load
        logic [3:0]  q_idx;         // Target LQ or SQ index
        logic [26:0] vpn;           // EA[38:12] for sanity checks
        logic [1:0]  access_type;   // Read, Write, AMO
        logic        waiter_valid;  // Cleared on branch squash/flush
        rob_idx_t    rob_idx;
        rob_epoch_t  rob_epoch;
    } trt_entry_t;

    // -------------------------------------------------------------------------
    // Helper Functions for Milestone 3 Address, Masks, and Data Alignment
    // -------------------------------------------------------------------------

    // Natural Alignment Check: Half=EA[0]==0, Word=EA[1:0]==0, Double=EA[2:0]==0
    function automatic logic check_nat_alignment(
        input logic [2:0] offset,
        input mem_size_t  size
    );
        case (size)
            MEM_SIZE_BYTE:   return 1'b1;
            MEM_SIZE_HALF:   return (offset[0] == 1'b0);
            MEM_SIZE_WORD:   return (offset[1:0] == 2'b00);
            MEM_SIZE_DOUBLE: return (offset[2:0] == 3'b000);
            default:         return 1'b0;
        endcase
    endfunction

    // Generate Active Byte Lane Mask Relative to 8-Byte Aligned Word (PA[55:3])
    function automatic logic [7:0] get_byte_lane_mask(
        input logic [2:0] offset,
        input mem_size_t  size
    );
        case (size)
            MEM_SIZE_BYTE:   return 8'b0000_0001 << offset;
            MEM_SIZE_HALF:   return 8'b0000_0011 << offset;
            MEM_SIZE_WORD:   return 8'b0000_1111 << offset;
            MEM_SIZE_DOUBLE: return 8'b1111_1111;
            default:         return 8'b0000_0000;
        endcase
    endfunction

    // Format and Sign/Zero Extend Loaded Data from 8-Byte Aligned Word
    function automatic logic [63:0] format_load_result(
        input logic [63:0] raw_word,
        input logic [2:0]  offset,
        input mem_size_t   size,
        input logic        sign_ext
    );
        logic [63:0] shifted;
        shifted = raw_word >> (offset * 8);
        case (size)
            MEM_SIZE_BYTE:   return sign_ext ? {{56{shifted[7]}},  shifted[7:0]}  : {56'd0, shifted[7:0]};
            MEM_SIZE_HALF:   return sign_ext ? {{48{shifted[15]}}, shifted[15:0]} : {48'd0, shifted[15:0]};
            MEM_SIZE_WORD:   return sign_ext ? {{32{shifted[31]}}, shifted[31:0]} : {32'd0, shifted[31:0]};
            MEM_SIZE_DOUBLE: return shifted;
            default:         return shifted;
        endcase
    endfunction

    // Position Store Data within 8-Byte Aligned Word
    function automatic logic [63:0] format_store_payload(
        input logic [63:0] raw_data,
        input logic [2:0]  offset,
        input mem_size_t   size
    );
        case (size)
            MEM_SIZE_BYTE:   return (64'(raw_data[7:0]))  << (offset * 8);
            MEM_SIZE_HALF:   return (64'(raw_data[15:0])) << (offset * 8);
            MEM_SIZE_WORD:   return (64'(raw_data[31:0])) << (offset * 8);
            MEM_SIZE_DOUBLE: return raw_data;
            default:         return raw_data;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Wrap-Safe ROB Circular Distance Helper
    // dist(idx, head) = (idx - head + ROB_DEPTH) mod ROB_DEPTH
    // Power-of-2 ROB_DEPTH (128) simplifies circular distance to idx - head.
    // -------------------------------------------------------------------------
    function automatic rob_dist_t rob_dist(
        input rob_idx_t idx,
        input rob_idx_t head
    );
        if (ROB_DEPTH == (1 << ROB_IDX_W)) begin
            return idx - head;
        end else begin
            logic [ROB_IDX_W:0] diff;
            diff = {1'b0, idx} + (ROB_IDX_W+1)'(ROB_DEPTH) - {1'b0, head};
            return (diff >= (ROB_IDX_W+1)'(ROB_DEPTH))
                 ? diff[ROB_IDX_W-1:0] - ROB_IDX_W'(ROB_DEPTH)
                 : diff[ROB_IDX_W-1:0];
        end
    endfunction

    // -------------------------------------------------------------------------
    // Milestone 4 Frontend Microarchitectural Dimensions & Parameters
    // -------------------------------------------------------------------------
    localparam int unsigned FETCH_QUEUE_DEPTH   = 16; // Decoupled Fetch Queue depth (Milestone 5 Phase B2)
    localparam int unsigned FETCH_QUEUE_IDX_W   = 4;  // $clog2(16) = 4 (0..15)
    localparam int unsigned BTB_SETS            = 256;// BTB 256 sets
    localparam int unsigned BTB_WAYS            = 2;  // BTB 2 ways (512 entries total)
    localparam int unsigned GSHARE_ENTRIES      = 4096;// Gshare 4096 2-bit counters
    localparam int unsigned RAS_DEPTH           = 16; // 16-entry circular RAS
    localparam int unsigned L1I_WAYS            = 4;  // 16 KiB 4-Way baseline
    localparam int unsigned L1I_SETS            = 64; // 64 sets (Way size = 4 KiB, VIPT-safe)
    localparam int unsigned L1I_LINE_BYTES      = 64; // 64 bytes per cache line (512 bits)
    localparam int unsigned IMSHR_DEPTH         = 2;  // 2 Instruction MSHRs
    localparam int unsigned ITLB_BASE_ENTRIES   = 64; // 64 base page entries (4-way, 16 sets)
    localparam int unsigned ITLB_SUPER_ENTRIES  = 8;  // 8 superpage CAM entries
    localparam int unsigned ITRT_DEPTH          = 2;  // Instruction Translation Request Table
    localparam int unsigned L1I_NLP_PAGE_LINE_LIMIT = 63; // Line 63 within 4 KiB page triggers silent prefetch abort (§7.3)

    typedef logic [FETCH_QUEUE_IDX_W-1:0] fetch_queue_idx_t;

    // Full 16-Entry Logical Return Address Stack Checkpoint Structure (Section 6)
    typedef struct packed {
        logic [15:0][63:0] ras_array;
        logic [3:0]        tos_ptr;
        logic [4:0]        depth;
    } ras_chkpt_t;

    // BPU-Side Indexed RAS Checkpoint Table Configuration (Section 6)
    // Slot 0 is reserved for post-reset / post-flush / post-recover baseline;
    // slots 1..31 (31 slots > FETCH_QUEUE_DEPTH + BPU_FIFO_DEPTH = 24) cycle
    // monotonically so Rename backpressure cannot wrap and overwrite an active ID.
    localparam int unsigned RAS_CHKPT_ENTRIES = 32;
    localparam int unsigned RAS_CHKPT_IDX_W   = $clog2(RAS_CHKPT_ENTRIES);
    typedef logic [RAS_CHKPT_IDX_W-1:0] ras_chkpt_id_t;

    // Fetch Queue Entry Structure (Section 5)
    typedef struct packed {
        logic             valid;
        logic [63:0]      pc;
        logic [31:0]      inst;
        logic             exception_valid;
        logic [4:0]       exception_cause;
        logic [63:0]      fault_addr;
        logic             pred_taken;
        logic [63:0]      pred_target;
        logic             is_branch;
        logic             is_jal;
        logic             is_jalr;
        branch_type_t     br_type;
        ghr_t             pre_branch_ghr;
        ras_chkpt_id_t    ras_chkpt;
        tage_csr_bundle_t csr_chkpt;
    } fetch_queue_entry_t;

endpackage

`endif // FURSOY_S1_PKG_SV
