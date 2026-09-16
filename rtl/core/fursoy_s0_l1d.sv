`ifndef FURSOY_S0_L1D_SV
`define FURSOY_S0_L1D_SV

// =============================================================================
// Fursoy Slice-0 Hardware L1 Data Cache (L1D) Subsystem - v1
// Normative Baseline: docs/architecture/l1d-cache-v1.md (Frozen Architecture)
//
// Geometry:
//   - 16 KiB total capacity
//   - 4-way set-associative
//   - 64-byte line size (eight 64-bit doublewords, 512 bits)
//   - 64 sets (PA[11:6] index, PA[55:12] physical tag)
//   - Virtually Indexed, Physically Tagged (VIPT) with PIPT equivalence (zero aliasing)
//   - Tree-PLRU replacement policy (3 bits per set)
//   - Write-Back with Write-Allocate (WB-WA)
//   - Strict synchronous dirty eviction (no asynchronous store buffer)
//   - 8-beat 64-bit burst refill and writeback
//   - Indivisible 2-cycle atomic (AMO) execution with interrupt masking
//   - Authoritative PMP checking on every hit/cycle
//   - DRAM-only cacheability (0x8000_0000 - 0x8FFF_FFFF), uncached MMIO bypass
//   - Serialized 7-step FENCE.I and conservative SFENCE.VMA / PMP maintenance flushes
// =============================================================================

module fursoy_s0_l1d #(
    parameter logic [63:0] DRAM_BASE = 64'h0000_0000_8000_0000,
    parameter logic [63:0] DRAM_END  = 64'h0000_0000_8FFF_FFFF,
    parameter int unsigned SETS      = 64,
    parameter int unsigned WAYS      = 4,
    /* verilator lint_off UNUSEDPARAM */
    parameter int unsigned LINE_SIZE = 64
    /* verilator lint_on UNUSEDPARAM */
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // Pipeline Stage E Request Interface
    input  logic        req_valid_i,
    input  logic        req_store_i,
    input  logic        req_lr_i,
    input  logic        req_sc_i,
    input  logic        req_amo_i,
    input  logic [4:0]  req_amo_op_i,
    input  logic [63:0] req_addr_i,
    input  logic [2:0]  req_size_i,
    input  logic        req_unsigned_i,
    input  logic [63:0] req_store_data_i,
    input  logic [4:0]  req_rd_i,
    input  logic [63:0] req_pc_i,
    input  logic [31:0] req_insn_i,
    input  logic [7:0]  req_byte_mask_i,
    input  logic        req_is_sb_drain_i,
    input  logic        res_invalidate_i,
    input  logic        retire_ack_i,
    input  logic        redirect_i,

    // Translation & Protection Interface (from MMU & PMP)
    input  logic        trans_valid_i,
    input  logic        trans_busy_i,
    input  logic [55:0] trans_pa_i,
    input  logic        trans_page_fault_i,
    input  logic        trans_pmp_allow_i,

    // Maintenance Request Triggers (from Stage E)
    input  logic        fence_i_req_i,
    input  logic        sfence_vma_req_i,
    input  logic        pmp_flush_req_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        fence_req_i,
    /* verilator lint_on UNUSEDSIGNAL */

    // Pipeline Stage E Control & Retirement Outputs
    output logic        issue_ready_o,
    output logic        l1d_idle_o,
    output logic        stall_e_o,
    output logic        retire_valid_o,
    output logic        retire_rd_write_o,
    output logic [4:0]  retire_rd_o,
    output logic [63:0] retire_rd_data_o,
    output logic [63:0] retire_pc_o,
    output logic [31:0] retire_insn_o,
    output logic        store_ack_o,
    output logic        res_valid_o,
    output logic [49:0] res_granule_pa_o,

    // Precise Exception & Fault Outputs
    output logic        fault_valid_o,
    output logic        fault_store_o,
    output logic [63:0] fault_addr_o,
    output logic [63:0] fault_pc_o,
    output logic [31:0] fault_insn_o,
    output logic        fault_page_o,

    // Maintenance Flush Handshake & Override Outputs
    output logic        maintenance_active_o,
    output logic        fence_i_flush_l1i_o,
    output logic        sfence_vma_flush_tlb_o,
    output logic        pmp_flush_l1i_o,
    output logic        fatal_error_o,
    output logic        fatal_event_o,
    output logic        refill_error_edge_o,
    output logic        er_retire_pending_o,
    output logic        er_load_retired_o,
    output logic [63:0] er_retire_pc_o,
    output logic [31:0] er_retire_insn_o,

    // Shared Memory Bus Interface (to external DRAM / interconnect)
    output logic        dmem_req_valid_o,
    input  logic        dmem_req_ready_i,
    output logic        dmem_req_store_o,
    output logic [63:0] dmem_req_addr_o,
    output logic [2:0]  dmem_req_size_o,
    output logic [63:0] dmem_req_store_data_o,
    input  logic        dmem_req_error_i,

    input  logic        dmem_rsp_valid_i,
    output logic        dmem_rsp_ready_o,
    input  logic [63:0] dmem_rsp_data_i,
    input  logic        dmem_rsp_error_i,

    // Performance Telemetry Events
    output logic        l1d_hit_event_o /* verilator public_flat_rd */,
    output logic        l1d_miss_event_o /* verilator public_flat_rd */,
    output logic        l1d_evict_event_o /* verilator public_flat_rd */,
    output logic        l1d_refill_event_o /* verilator public_flat_rd */,
    output logic        l1d_load_hit_o /* verilator public_flat_rd */,
    output logic        l1d_load_miss_o /* verilator public_flat_rd */,
    output logic        l1d_store_hit_o /* verilator public_flat_rd */,
    output logic        l1d_store_miss_o /* verilator public_flat_rd */,

    // SRB Interlock & Telemetry Interface (docs/architecture/l1d-srb-v1.md)
    output logic        srb_busy_o /* verilator public_flat_rd */,
    output logic [49:0] srb_line_pa_o /* verilator public_flat_rd */,
    output logic        srb_install_event_o /* verilator public_flat_rd */,
    output logic        srb_victim_dirty_o /* verilator public_flat_rd */,
    output logic        srb_victim_clean_o /* verilator public_flat_rd */,
    output logic        srb_sec_load_stall_o /* verilator public_flat_rd */,

    // L1D-ER v1 Telemetry Interface (docs/architecture/l1d-refill-opt-v1.md)
    output logic        l1d_er_event_o /* verilator public_flat_rd */,
    output logic [4:0]  l1d_er_saved_cycles_o /* verilator public_flat_rd */
);

    // -------------------------------------------------------------------------
    // Cache Storage Arrays
    // -------------------------------------------------------------------------
    logic        valid_q [SETS][WAYS];
    logic        dirty_q [SETS][WAYS];
    logic [43:0] tag_q   [SETS][WAYS];
    logic [2:0]  plru_q  [SETS];
    logic [63:0] data_q  [SETS][WAYS][8]; // 8 doublewords = 64 bytes

    // -------------------------------------------------------------------------
    // Address Decomposition & Cacheability
    // -------------------------------------------------------------------------
    wire [5:0]  set_idx    = trans_pa_i[11:6];
    wire [43:0] check_tag  = trans_pa_i[55:12];
    wire [2:0]  dword_idx  = trans_pa_i[5:3];
    wire [2:0]  byte_idx   = trans_pa_i[2:0];

    wire is_dram = (trans_pa_i >= DRAM_BASE[55:0]) && (trans_pa_i <= DRAM_END[55:0]);

    // -------------------------------------------------------------------------
    // Tree-PLRU Functions (Identical to L1I)
    // -------------------------------------------------------------------------
    function automatic logic [1:0] plru_victim(input logic [2:0] plru, input logic [3:0] valids);
        if (!valids[0]) return 2'd0;
        else if (!valids[1]) return 2'd1;
        else if (!valids[2]) return 2'd2;
        else if (!valids[3]) return 2'd3;
        else begin
            if (!plru[0]) return plru[1] ? 2'd1 : 2'd0;
            else          return plru[2] ? 2'd3 : 2'd2;
        end
    endfunction

    function automatic logic [2:0] plru_update(input logic [2:0] plru, input logic [1:0] way);
        logic [2:0] next_plru;
        next_plru = plru;
        case (way)
            2'd0: begin next_plru[0] = 1'b1; next_plru[1] = 1'b1; end
            2'd1: begin next_plru[0] = 1'b1; next_plru[1] = 1'b0; end
            2'd2: begin next_plru[0] = 1'b0; next_plru[2] = 1'b1; end
            2'd3: begin next_plru[0] = 1'b0; next_plru[2] = 1'b0; end
        endcase
        return next_plru;
    endfunction

    // -------------------------------------------------------------------------
    // Tag Matching & Hit Evaluation
    // -------------------------------------------------------------------------
    logic [3:0] way_hit;
    for (genvar w = 0; w < WAYS; w++) begin : gen_way_hit
        assign way_hit[w] = valid_q[set_idx][w] && (tag_q[set_idx][w] == check_tag);
    end

    wire tag_matched = |way_hit;
    logic [1:0] hit_way;
    always_comb begin
        case (1'b1)
            way_hit[0]: hit_way = 2'd0;
            way_hit[1]: hit_way = 2'd1;
            way_hit[2]: hit_way = 2'd2;
            default:    hit_way = 2'd3;
        endcase
    end

    // -------------------------------------------------------------------------
    // Data Extraction & Sign/Zero Extension Helper
    // -------------------------------------------------------------------------
    function automatic logic [63:0] extend_load(
        input logic [63:0] val,
        input logic [2:0]  byte_off,
        input logic [2:0]  size,
        input logic        is_unsigned
    );
        logic [7:0]  b;
        logic [15:0] h;
        logic [31:0] w;
        case (size)
            3'd0: begin // Byte
                b = val[byte_off*8 +: 8];
                extend_load = is_unsigned ? {56'd0, b} : {{56{b[7]}}, b};
            end
            3'd1: begin // Halfword
                h = val[byte_off[2:1]*16 +: 16];
                extend_load = is_unsigned ? {48'd0, h} : {{48{h[15]}}, h};
            end
            3'd2: begin // Word
                w = byte_off[2] ? val[63:32] : val[31:0];
                extend_load = is_unsigned ? {32'd0, w} : {{32{w[31]}}, w};
            end
            default: extend_load = val; // Doubleword
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Right-Justified MMIO Bus Load Extension Helper
    // -------------------------------------------------------------------------
    function automatic logic [63:0] extend_mmio_load(
        input logic [63:0] val,
        input logic [2:0]  size,
        input logic        is_unsigned
    );
        logic [7:0]  b;
        logic [15:0] h;
        logic [31:0] w;
        case (size)
            3'd0: begin // Byte
                b = val[7:0];
                extend_mmio_load = is_unsigned ? {56'd0, b} : {{56{b[7]}}, b};
            end
            3'd1: begin // Halfword
                h = val[15:0];
                extend_mmio_load = is_unsigned ? {48'd0, h} : {{48{h[15]}}, h};
            end
            3'd2: begin // Word
                w = val[31:0];
                extend_mmio_load = is_unsigned ? {32'd0, w} : {{32{w[31]}}, w};
            end
            default: extend_mmio_load = val; // Doubleword
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Partial Store Byte-Lane Merge Helper
    // -------------------------------------------------------------------------
    function automatic logic [63:0] merge_store_byte(
        input logic [63:0] orig,
        input logic [63:0] sdata,
        input logic [2:0]  byte_off,
        input logic [2:0]  size
    );
        logic [7:0] wmask;
        logic [63:0] res;
        case (size)
            3'd0: wmask = 8'b0000_0001 << byte_off;
            3'd1: wmask = 8'b0000_0011 << (byte_off[2:1]*2);
            3'd2: wmask = byte_off[2] ? 8'b1111_0000 : 8'b0000_1111;
            default: wmask = 8'b1111_1111;
        endcase
        for (int i = 0; i < 8; i++) begin
            if (wmask[i]) begin
                case (size)
                    3'd0: res[i*8 +: 8] = sdata[7:0];
                    3'd1: res[i*8 +: 8] = sdata[(i - byte_off[2:1]*2)*8 +: 8];
                    3'd2: res[i*8 +: 8] = byte_off[2] ? sdata[(i-4)*8 +: 8] : sdata[i*8 +: 8];
                    default: res[i*8 +: 8] = sdata[i*8 +: 8];
                endcase
            end else begin
                res[i*8 +: 8] = orig[i*8 +: 8];
            end
        end
        return res;
    endfunction

    function automatic logic [63:0] apply_byte_mask(
        input logic [63:0] old_val,
        input logic [63:0] new_val,
        input logic [7:0]  mask
    );
        logic [63:0] res;
        for (int b = 0; b < 8; b++) begin
            res[b*8 +: 8] = mask[b] ? new_val[b*8 +: 8] : old_val[b*8 +: 8];
        end
        return res;
    endfunction

    // -------------------------------------------------------------------------
    // AMO Arithmetic Logic Unit
    // -------------------------------------------------------------------------
    function automatic logic [63:0] calc_amo(
        input logic [4:0]  amo_op,
        input logic [2:0]  size,
        input logic [63:0] mem_val,
        input logic [63:0] operand_b
    );
        if (size == 3'd2) begin
            logic [31:0] a, b, res;
            a = mem_val[31:0];
            b = operand_b[31:0];
            case (amo_op)
                5'b00001: res = b;                                                          // AMOSWAP
                5'b00000: res = a + b;                                                      // AMOADD
                5'b00100: res = a ^ b;                                                      // AMOXOR
                5'b01100: res = a & b;                                                      // AMOAND
                5'b01000: res = a | b;                                                      // AMOOR
                5'b10000: res = ($signed(a) < $signed(b)) ? a : b;                         // AMOMIN
                5'b10100: res = ($signed(a) > $signed(b)) ? a : b;                         // AMOMAX
                5'b11000: res = ($unsigned(a) < $unsigned(b)) ? a : b;                     // AMOMINU
                5'b11100: res = ($unsigned(a) > $unsigned(b)) ? a : b;                     // AMOMAXU
                default:  res = a;
            endcase
            calc_amo = {{32{res[31]}}, res};
        end else begin
            logic [63:0] a, b, res;
            a = mem_val;
            b = operand_b;
            case (amo_op)
                5'b00001: res = b;                                                          // AMOSWAP
                5'b00000: res = a + b;                                                      // AMOADD
                5'b00100: res = a ^ b;                                                      // AMOXOR
                5'b01100: res = a & b;                                                      // AMOAND
                5'b01000: res = a | b;                                                      // AMOOR
                5'b10000: res = ($signed(a) < $signed(b)) ? a : b;                         // AMOMIN
                5'b10100: res = ($signed(a) > $signed(b)) ? a : b;                         // AMOMAX
                5'b11000: res = ($unsigned(a) < $unsigned(b)) ? a : b;                     // AMOMINU
                5'b11100: res = ($unsigned(a) > $unsigned(b)) ? a : b;                     // AMOMAXU
                default:  res = a;
            endcase
            calc_amo = res;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Reservation Tracking (LR/SC)
    // -------------------------------------------------------------------------
    logic        res_valid_q;
    logic [55:0] res_exact_pa_q;
    logic [2:0]  res_size_q;
    logic [49:0] res_granule_pa_q;

    wire sc_matches = res_valid_q && (trans_pa_i == res_exact_pa_q) && (req_size_i == res_size_q);

    // -------------------------------------------------------------------------
    // Subsystem States
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        IDLE,
        AMO_CYCLE2,
        EVICT_REQ,
        EVICT_BURST,
        REFILL_REQ,
        REFILL_RSP,
        INSTALL,
        MMIO_REQ,
        MMIO_RSP,
        FLUSH_SWEEP,
        FLUSH_REQ,
        FLUSH_BURST,
        FLUSH_DONE
    } state_t;

    state_t state_q /* verilator public_flat_rd */;

    // Registers for in-flight transaction
    logic [63:0] target_va_q /* verilator public_flat_rd */;
    logic [55:0] target_pa_q;
    logic [2:0]  target_size_q;
    logic        target_unsigned_q;
    logic [63:0] target_store_data_q;
    logic [7:0]  target_byte_mask_q;
    logic        target_is_sb_drain_q;
    logic [4:0]  target_rd_q;
    logic [63:0] target_pc_q;
    logic [31:0] target_insn_q;
    logic        target_is_store_q /* verilator public_flat_rd */;
    logic        target_is_lr_q /* verilator public_flat_rd */;
    logic        target_is_sc_q /* verilator public_flat_rd */;
    logic        target_is_amo_q /* verilator public_flat_rd */;
    logic [4:0]  target_amo_op_q;
    logic        target_is_ordinary_load_q /* verilator public_flat_rd */;
    logic [2:0]  target_crit_beat_q /* verilator public_flat_rd */;

    // Dedicated Early-Restart Handshake Registers (L1D-ER v1)
    logic        crit_beat_captured_q /* verilator public_flat_rd */;
    logic        er_retire_valid_q /* verilator public_flat_rd */;
    logic [63:0] er_retire_rd_data_q /* verilator public_flat_rd */;
    logic        er_load_retired_q /* verilator public_flat_rd */;
    logic        er_load_squashed_q /* verilator public_flat_rd */;
    logic        rfb_crit_consumed_q /* verilator public_flat_rd */;
    logic        refill_poisoned_q /* verilator public_flat_rd */;

`ifndef SYNTHESIS
    // Verification-only A/B control. The production configuration always
    // enables L1D-ER and exposes no corresponding module port.
    logic verification_disable_er /* verilator public_flat_rw */;
    initial verification_disable_er = 1'b0;
`else
    wire verification_disable_er = 1'b0;
`endif

    assign l1d_er_event_o = er_retire_valid_q && retire_ack_i;
    assign l1d_er_saved_cycles_o = (er_retire_valid_q && retire_ack_i && (target_crit_beat_q < 3'd7)) ?
        5'(2 * (32'd7 - {29'd0, target_crit_beat_q}) - 1) : 5'd0;

    // Victim Eviction Buffer & Refill Buffer
    logic [1:0]  target_victim_way_q;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] eb_addr_q;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0] eb_data_q [8];
    logic [1:0]  eb_way_q;
    logic [5:0]  eb_set_q;
    logic [63:0] refill_buf_q [8];
    logic [2:0]  beat_cnt_q;

    // AMO temporary holding
    logic [63:0] amo_rdata_q;
    logic [1:0]  amo_hit_way_q;

    // Maintenance Flush sweep counters
    logic [5:0]  flush_set_q;
    logic        flush_is_fence_i_q /* verilator public_flat_rd */;
    logic        flush_is_sfence_q /* verilator public_flat_rd */;
    logic        flush_is_pmp_q /* verilator public_flat_rd */;
    logic [8:0]  dirty_count_q;
    wire any_cache_dirty = (dirty_count_q != 9'd0);

    wire [3:0] flush_set_dirty = {
        valid_q[flush_set_q][3] && dirty_q[flush_set_q][3],
        valid_q[flush_set_q][2] && dirty_q[flush_set_q][2],
        valid_q[flush_set_q][1] && dirty_q[flush_set_q][1],
        valid_q[flush_set_q][0] && dirty_q[flush_set_q][0]
    };

    logic        fatal_error_q /* verilator public_flat_rd */;
    assign fatal_error_o = fatal_error_q;
    assign er_retire_pending_o = er_retire_valid_q;
    assign er_load_retired_o   = er_load_retired_q;
    assign er_retire_pc_o       = target_pc_q;
    assign er_retire_insn_o     = target_insn_q;

    wire primary_refill_req_error = (state_q == REFILL_REQ) && dmem_req_valid_o &&
                                    dmem_req_ready_i && dmem_req_error_i;
    wire primary_refill_rsp_error = (state_q == REFILL_RSP) && dmem_rsp_valid_i &&
                                    dmem_rsp_ready_o && dmem_rsp_error_i;
    assign refill_error_edge_o = primary_refill_req_error || primary_refill_rsp_error;

    // This edge excludes the same-cycle ER acknowledgement case to avoid a
    // combinational loop through the core commit decision.  The core combines
    // refill_error_edge_o with the same-instruction commit candidate; the L1D
    // sequential classification below uses the authoritative acknowledgement.
    assign fatal_event_o =
        (refill_error_edge_o && er_load_retired_q) ||
        ((state_q == EVICT_BURST || state_q == FLUSH_BURST) &&
         (dmem_rsp_error_i || dmem_req_error_i)) ||
        ((srb_state_q == SRB_EVICT_BURST) && (dmem_rsp_error_i || dmem_req_error_i)) ||
        ((srb_state_q == SRB_REFILL_REQ) && dmem_req_valid_o && dmem_req_ready_i && dmem_req_error_i) ||
        ((srb_state_q == SRB_REFILL_RSP) && dmem_rsp_valid_i && dmem_rsp_ready_o && dmem_rsp_error_i);

    // -------------------------------------------------------------------------
    // Store Refill Buffer (SRB) Registers & Definitions (docs/architecture/l1d-srb-v1.md)
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        SRB_IDLE,
        SRB_EVICT_REQ,
        SRB_EVICT_BURST,
        SRB_REFILL_REQ,
        SRB_REFILL_RSP,
        SRB_INSTALL,
        SRB_FATAL_ERROR
    } srb_state_t;

    srb_state_t  srb_state_q /* verilator public_flat_rd */;
    logic        srb_busy_q /* verilator public_flat_rd */;
    logic [49:0] srb_line_pa_q /* verilator public_flat_rd */;
    logic [5:0]  srb_set_q /* verilator public_flat_rd */;
    logic [1:0]  srb_way_q /* verilator public_flat_rd */;
    logic        srb_victim_dirty_q /* verilator public_flat_rd */;
    logic [43:0] srb_victim_tag_q /* verilator public_flat_rd */;
    logic [63:0] srb_victim_data_q [8] /* verilator public_flat_rd */;
    logic [63:0] srb_refill_data_q [8] /* verilator public_flat_rd */;
    logic [2:0]  srb_word_offset_q /* verilator public_flat_rd */;
    logic [63:0] srb_store_data_q /* verilator public_flat_rd */;
    logic [7:0]  srb_store_mask_q /* verilator public_flat_rd */;
    logic [2:0]  srb_beat_cnt_q /* verilator public_flat_rd */;

    assign srb_busy_o    = srb_busy_q;
    assign srb_line_pa_o = srb_line_pa_q;

    wire srb_install_active = (srb_state_q == SRB_INSTALL);
    assign srb_install_event_o = srb_install_active;

    // Combinational Hit/Miss signals in IDLE
    wire op_is_amo   = req_amo_i;
    wire op_is_store = req_store_i && !req_amo_i;
    wire op_is_load  = !req_store_i && !req_amo_i;

    wire can_lookup = (state_q == IDLE) && !fatal_error_q && !srb_install_active && !reg_retire_valid && !reg_fault_valid &&
                      req_valid_i && trans_valid_i && !trans_busy_i &&
                      !trans_page_fault_i && trans_pmp_allow_i && is_dram &&
                      (!srb_busy_q || op_is_load);

    wire hit_in_idle = can_lookup && tag_matched;
    wire miss_in_idle = can_lookup && !tag_matched;

    wire srb_capture /* verilator public_flat_rd */ = (state_q == IDLE) && !fatal_error_q && !srb_install_active && !reg_retire_valid && !reg_fault_valid &&
                       req_valid_i && trans_valid_i && !trans_busy_i &&
                       !trans_page_fault_i && trans_pmp_allow_i && is_dram &&
                       !tag_matched && op_is_store && req_is_sb_drain_i && !srb_busy_q;

    wire srb_sec_load_stall = (state_q == IDLE) && req_valid_i && trans_valid_i && !trans_busy_i &&
                              !trans_page_fault_i && trans_pmp_allow_i && is_dram &&
                              !tag_matched && op_is_load && srb_busy_q;
    assign srb_sec_load_stall_o = srb_sec_load_stall;

    /* verilator lint_off UNUSEDSIGNAL */
    // SC failure never misses
    wire sc_fail_in_idle = can_lookup && req_sc_i && !sc_matches;
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // Combinational Output Assignments
    // -------------------------------------------------------------------------
    assign maintenance_active_o = (state_q == FLUSH_SWEEP) || (state_q == FLUSH_REQ) ||
                                  (state_q == FLUSH_BURST) || (state_q == FLUSH_DONE);
    assign issue_ready_o = (state_q == IDLE) && !fatal_error_q && !srb_install_active && !reg_retire_valid && !reg_fault_valid && !er_retire_valid_q;
    assign l1d_idle_o    = (state_q == IDLE) && !fatal_error_q && !er_retire_valid_q;
    assign store_ack_o      = (state_q == IDLE && hit_in_idle && op_is_store && req_is_sb_drain_i) ||
                              srb_capture ||
                              (state_q == INSTALL && target_is_store_q && !target_is_amo_q && target_is_sb_drain_q);
    assign res_valid_o      = res_valid_q;
    assign res_granule_pa_o = res_granule_pa_q;

    // Stall Stage E when busy
    assign stall_e_o = fatal_error_q || ((state_q != IDLE) && !er_retire_valid_q) ||
                       srb_install_active ||
                       (req_valid_i && trans_busy_i) ||
                       (!reg_retire_valid && !reg_fault_valid && !er_retire_valid_q && req_valid_i && !trans_busy_i && trans_valid_i && !trans_page_fault_i && trans_pmp_allow_i &&
                        ((is_dram && !tag_matched && !(req_sc_i && !sc_matches) && (!req_is_sb_drain_i || srb_busy_q)) || // Miss refill stall
                         (!is_dram && (srb_busy_q || state_q != IDLE))));                                                   // MMIO stall

    // Retire signal (Combinational for hits in IDLE, registered upon completion)
    logic        comb_retire_valid;
    logic        comb_retire_rd_write;
    logic [4:0]  comb_retire_rd;
    logic [63:0] comb_retire_rd_data;

    always_comb begin
        comb_retire_valid    = 1'b0;
        comb_retire_rd_write = 1'b0;
        comb_retire_rd       = req_rd_i;
        comb_retire_rd_data  = 64'd0;

        if (state_q == IDLE && can_lookup) begin
            if (req_sc_i && !sc_matches) begin
                // SC mismatch -> 1 cycle failure
                comb_retire_valid    = 1'b1;
                comb_retire_rd_write = (req_rd_i != 5'd0);
                comb_retire_rd_data  = 64'd1;
            end else if (hit_in_idle) begin
                if (op_is_load) begin
                    // Load hit -> 1 cycle
                    comb_retire_valid    = 1'b1;
                    comb_retire_rd_write = (req_rd_i != 5'd0);
                    comb_retire_rd_data  = extend_load(data_q[set_idx][hit_way][dword_idx], byte_idx, req_size_i, req_unsigned_i);
                end else if (op_is_store) begin
                    if (req_sc_i) begin
                        // SC hit -> 1 cycle success
                        comb_retire_valid    = 1'b1;
                        comb_retire_rd_write = (req_rd_i != 5'd0);
                        comb_retire_rd_data  = 64'd0;
                    end else if (req_is_sb_drain_i) begin
                        // SB drain store -> already retired in Stage E, no retirement pulse
                        comb_retire_valid    = 1'b0;
                        comb_retire_rd_write = 1'b0;
                    end else begin
                        // Store hit -> 1 cycle
                        comb_retire_valid    = 1'b1;
                        comb_retire_rd_write = 1'b0;
                    end
                end
                // Note: AMO hit takes 2 cycles (retires in AMO_CYCLE2)
            end
        end
    end

    // Registered Fault Information
    logic        reg_fault_valid;
    logic        reg_fault_store;
    logic [63:0] reg_fault_addr;
    logic [63:0] reg_fault_pc;
    logic [31:0] reg_fault_insn;
    logic        reg_fault_page;

    // Precise Fault Generation
    always_comb begin
        if (reg_fault_valid) begin
            fault_valid_o = 1'b1;
            fault_store_o = reg_fault_store;
            fault_addr_o  = reg_fault_addr;
            fault_pc_o    = reg_fault_pc;
            fault_insn_o  = reg_fault_insn;
            fault_page_o  = reg_fault_page;
        end else if (state_q == IDLE && !reg_retire_valid && !reg_fault_valid && req_valid_i && trans_valid_i && !trans_busy_i) begin
            if (trans_page_fault_i) begin
                fault_valid_o = 1'b1;
                fault_store_o = req_store_i || req_amo_i;
                fault_addr_o  = req_addr_i;
                fault_pc_o    = req_pc_i;
                fault_insn_o  = req_insn_i;
                fault_page_o  = 1'b1;
            end else if (!trans_pmp_allow_i) begin
                fault_valid_o = 1'b1;
                fault_store_o = req_store_i || req_amo_i;
                fault_addr_o  = req_addr_i;
                fault_pc_o    = req_pc_i;
                fault_insn_o  = req_insn_i;
                fault_page_o  = 1'b0;
            end else begin
                fault_valid_o = 1'b0;
                fault_store_o = req_store_i || req_amo_i;
                fault_addr_o  = req_addr_i;
                fault_pc_o    = req_pc_i;
                fault_insn_o  = req_insn_i;
                fault_page_o  = 1'b0;
            end
        end else begin
            fault_valid_o = 1'b0;
            fault_store_o = req_store_i || req_amo_i;
            fault_addr_o  = req_addr_i;
            fault_pc_o    = req_pc_i;
            fault_insn_o  = req_insn_i;
            fault_page_o  = 1'b0;
        end
    end

    // Retirement Multiplexer
    logic        reg_retire_valid;
    logic        reg_retire_rd_write;
    logic [4:0]  reg_retire_rd;
    logic [63:0] reg_retire_rd_data;
    logic [63:0] reg_retire_pc;
    logic [31:0] reg_retire_insn;

    assign retire_valid_o    = comb_retire_valid || reg_retire_valid || er_retire_valid_q;
    assign retire_rd_write_o = comb_retire_valid ? comb_retire_rd_write :
                               er_retire_valid_q ? (target_rd_q != 5'd0) : reg_retire_rd_write;
    assign retire_rd_o       = comb_retire_valid ? comb_retire_rd       :
                               er_retire_valid_q ? target_rd_q           : reg_retire_rd;
    assign retire_rd_data_o  = comb_retire_valid ? comb_retire_rd_data  :
                               er_retire_valid_q ? er_retire_rd_data_q  : reg_retire_rd_data;
    assign retire_pc_o       = comb_retire_valid ? req_pc_i             :
                               er_retire_valid_q ? target_pc_q           : reg_retire_pc;
    assign retire_insn_o     = comb_retire_valid ? req_insn_i           :
                               er_retire_valid_q ? target_insn_q         : reg_retire_insn;

    // Performance Telemetry Signals
    assign l1d_hit_event_o    = hit_in_idle;
    assign l1d_miss_event_o   = (miss_in_idle && !(req_sc_i && !sc_matches) && !srb_sec_load_stall) || srb_capture;
    assign l1d_load_hit_o     = hit_in_idle && op_is_load;
    assign l1d_load_miss_o    = miss_in_idle && op_is_load && !srb_busy_q;
    assign l1d_store_hit_o    = hit_in_idle && (op_is_store || op_is_amo) && !(req_sc_i && !sc_matches);
    assign l1d_store_miss_o   = (miss_in_idle && (op_is_store || op_is_amo) && !(req_sc_i && !sc_matches) && !srb_busy_q) || srb_capture;
    assign l1d_evict_event_o  = ((state_q == EVICT_REQ) && dmem_req_ready_i) ||
                                ((srb_state_q == SRB_EVICT_REQ) && dmem_req_ready_i) ||
                                ((srb_state_q == SRB_EVICT_BURST) && (srb_beat_cnt_q == 3'd0) && dmem_req_valid_o && dmem_req_ready_i);
    assign l1d_refill_event_o = (state_q == INSTALL) || srb_install_active;

    wire [1:0] v_way_peek = plru_victim(plru_q[set_idx], {valid_q[set_idx][3], valid_q[set_idx][2], valid_q[set_idx][1], valid_q[set_idx][0]});
    assign srb_victim_dirty_o = srb_capture ? (valid_q[set_idx][v_way_peek] && dirty_q[set_idx][v_way_peek]) : srb_victim_dirty_q;
    assign srb_victim_clean_o = srb_capture ? !(valid_q[set_idx][v_way_peek] && dirty_q[set_idx][v_way_peek]) : (srb_busy_q && !srb_victim_dirty_q);

    // -------------------------------------------------------------------------
    // Main L1D Sequential Controller & FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q                 <= IDLE;
            reg_retire_valid        <= 1'b0;
            reg_retire_rd_write     <= 1'b0;
            reg_retire_rd           <= '0;
            reg_retire_rd_data      <= '0;
            reg_retire_pc           <= '0;
            reg_retire_insn         <= '0;
            reg_fault_valid         <= 1'b0;
            reg_fault_store         <= 1'b0;
            reg_fault_addr          <= '0;
            reg_fault_pc            <= '0;
            reg_fault_insn          <= '0;
            reg_fault_page          <= 1'b0;
            res_valid_q             <= 1'b0;
            res_exact_pa_q          <= '0;
            res_size_q              <= '0;
            res_granule_pa_q        <= '0;
            beat_cnt_q              <= '0;
            dmem_req_valid_o        <= 1'b0;
            dmem_req_store_o        <= 1'b0;
            dmem_req_addr_o         <= '0;
            dmem_req_size_o         <= '0;
            dmem_req_store_data_o   <= '0;
            dmem_rsp_ready_o        <= 1'b0;
            fence_i_flush_l1i_o     <= 1'b0;
            sfence_vma_flush_tlb_o  <= 1'b0;
            pmp_flush_l1i_o         <= 1'b0;
            fatal_error_q           <= 1'b0;
            flush_set_q             <= '0;
            flush_is_fence_i_q      <= 1'b0;
            flush_is_sfence_q       <= 1'b0;
            flush_is_pmp_q          <= 1'b0;
            target_byte_mask_q      <= '0;
            target_va_q             <= '0;
            target_is_sb_drain_q    <= 1'b0;
            target_is_ordinary_load_q <= 1'b0;
            target_crit_beat_q      <= '0;
            crit_beat_captured_q    <= 1'b0;
            er_retire_valid_q       <= 1'b0;
            er_retire_rd_data_q     <= '0;
            er_load_retired_q       <= 1'b0;
            er_load_squashed_q      <= 1'b0;
            rfb_crit_consumed_q     <= 1'b0;
            refill_poisoned_q       <= 1'b0;
            dirty_count_q           <= '0;
            srb_state_q             <= SRB_IDLE;
            srb_busy_q              <= 1'b0;
            srb_line_pa_q           <= '0;
            srb_set_q               <= '0;
            srb_way_q               <= '0;
            srb_victim_dirty_q      <= 1'b0;
            srb_victim_tag_q        <= '0;
            srb_word_offset_q       <= '0;
            srb_store_data_q        <= '0;
            srb_store_mask_q        <= '0;
            srb_beat_cnt_q          <= '0;
            for (int d = 0; d < 8; d++) begin
                srb_victim_data_q[d] <= '0;
                srb_refill_data_q[d] <= '0;
            end

            /* verilator lint_off BLKSEQ */
            for (int s = 0; s < SETS; s++) begin
                plru_q[s] = '0;
                for (int w = 0; w < WAYS; w++) begin
                    valid_q[s][w] = 1'b0;
                    dirty_q[s][w] = 1'b0;
                    tag_q[s][w]   = '0;
                    for (int d = 0; d < 8; d++) begin
                        data_q[s][w][d] = '0;
                    end
                end
            end
            /* verilator lint_on BLKSEQ */
        end else begin
            reg_retire_valid       <= 1'b0;
            reg_fault_valid        <= 1'b0;
            fence_i_flush_l1i_o    <= 1'b0;
            sfence_vma_flush_tlb_o <= 1'b0;
            pmp_flush_l1i_o        <= 1'b0;

            // Handle asynchronous reservation invalidations
            if (res_invalidate_i) begin
                res_valid_q <= 1'b0;
            end

            // Persistent early retirement handshake update (L1D-ER v1)
            if (retire_ack_i && er_retire_valid_q) begin
                er_retire_valid_q   <= 1'b0;
                rfb_crit_consumed_q <= 1'b1;
                er_load_retired_q   <= 1'b1;
            end else if (redirect_i) begin
                er_retire_valid_q   <= 1'b0;
                rfb_crit_consumed_q <= 1'b1; // Squashed
                if (target_is_ordinary_load_q && state_q != IDLE && !er_load_retired_q)
                    er_load_squashed_q <= 1'b1;
            end else if (crit_beat_captured_q && !rfb_crit_consumed_q && !refill_poisoned_q) begin
                // Cycle T+1: Registered extraction from refill_buf_q into er_retire_rd_data_q
                er_retire_rd_data_q  <= extend_load(refill_buf_q[target_crit_beat_q], target_pa_q[2:0], target_size_q, target_unsigned_q);
                er_retire_valid_q    <= 1'b1;
                crit_beat_captured_q <= 1'b0;
            end else if (state_q == IDLE && !er_retire_valid_q) begin
                rfb_crit_consumed_q <= 1'b0;
            end

            // -----------------------------------------------------------------
            // Store Refill Buffer (SRB) FSM (docs/architecture/l1d-srb-v1.md)
            // -----------------------------------------------------------------
            case (srb_state_q)
                SRB_IDLE: begin
                    if (srb_capture) begin
                        logic [1:0] v_way;
                        v_way = plru_victim(plru_q[set_idx], {valid_q[set_idx][3], valid_q[set_idx][2], valid_q[set_idx][1], valid_q[set_idx][0]});

                        // Atomic victim-way invalidation (P0-1)
                        valid_q[set_idx][v_way] <= 1'b0;
                        dirty_q[set_idx][v_way] <= 1'b0;

                        // Static coordinates & payload latching (P0-2, P0-3)
                        srb_busy_q        <= 1'b1;
                        srb_set_q         <= set_idx;
                        srb_way_q         <= v_way;
                        srb_line_pa_q     <= trans_pa_i[55:6];
                        srb_word_offset_q <= trans_pa_i[5:3];
                        srb_store_data_q  <= req_store_data_i;
                        srb_store_mask_q  <= req_byte_mask_i;
                        srb_beat_cnt_q    <= 3'd0;

                        // Victim snapshot & dirty accounting (P0-1, P1-4)
                        if (valid_q[set_idx][v_way] && dirty_q[set_idx][v_way]) begin
                            srb_victim_dirty_q <= 1'b1;
                            srb_victim_tag_q   <= tag_q[set_idx][v_way];
                            for (int d = 0; d < 8; d++) begin
                                srb_victim_data_q[d] <= data_q[set_idx][v_way][d];
                            end
                            if (dirty_count_q > 9'd0) dirty_count_q <= dirty_count_q - 9'd1;
                            dmem_req_valid_o      <= 1'b1;
                            dmem_req_store_o      <= 1'b1;
                            dmem_req_addr_o       <= {8'd0, tag_q[set_idx][v_way], set_idx, 6'b000000};
                            dmem_req_size_o       <= 3'd3;
                            dmem_req_store_data_o <= data_q[set_idx][v_way][0];
                            srb_state_q           <= SRB_EVICT_BURST;
                        end else begin
                            srb_victim_dirty_q <= 1'b0;
                            dmem_req_valid_o   <= 1'b1;
                            dmem_req_store_o   <= 1'b0;
                            dmem_req_addr_o    <= {8'd0, trans_pa_i[55:6], 6'b000000};
                            dmem_req_size_o    <= 3'd3;
                            dmem_rsp_ready_o   <= 1'b0;
                            srb_state_q        <= SRB_REFILL_REQ;
                        end
                    end
                end

                SRB_EVICT_REQ: begin
                    dmem_req_valid_o      <= 1'b1;
                    dmem_req_store_o      <= 1'b1;
                    dmem_req_addr_o       <= {8'd0, srb_victim_tag_q, srb_set_q, srb_beat_cnt_q, 3'b000};
                    dmem_req_size_o       <= 3'd3;
                    dmem_req_store_data_o <= srb_victim_data_q[srb_beat_cnt_q];
                    srb_state_q           <= SRB_EVICT_BURST;
                end

                SRB_EVICT_BURST: begin
                    if (dmem_rsp_error_i || dmem_req_error_i) begin
                        fatal_error_q    <= 1'b1;
                        dmem_req_valid_o <= 1'b0;
                        srb_state_q      <= SRB_FATAL_ERROR;
                    end else if (dmem_req_valid_o && dmem_req_ready_i) begin
                        if (srb_beat_cnt_q == 3'd7) begin
                            srb_beat_cnt_q   <= 3'd0;
                            dmem_req_valid_o <= 1'b1;
                            dmem_req_store_o <= 1'b0;
                            dmem_req_addr_o  <= {8'd0, srb_line_pa_q, 6'b000000};
                            dmem_req_size_o  <= 3'd3;
                            dmem_rsp_ready_o <= 1'b0;
                            srb_state_q      <= SRB_REFILL_REQ;
                        end else begin
                            srb_beat_cnt_q <= srb_beat_cnt_q + 1'b1;
                            dmem_req_addr_o <= {8'd0, srb_victim_tag_q, srb_set_q, srb_beat_cnt_q + 1'b1, 3'b000};
                            dmem_req_store_data_o <= srb_victim_data_q[srb_beat_cnt_q + 1'b1];
                        end
                    end
                end

                SRB_REFILL_REQ: begin
                    dmem_req_valid_o <= 1'b1;
                    dmem_req_store_o <= 1'b0;
                    dmem_req_addr_o  <= {8'd0, srb_line_pa_q, srb_beat_cnt_q, 3'b000};
                    dmem_req_size_o  <= 3'd3;
                    dmem_rsp_ready_o <= 1'b0;
                    if (dmem_req_valid_o && dmem_req_ready_i) begin
                        dmem_req_valid_o <= 1'b0;
                        if (dmem_req_error_i) begin
                            fatal_error_q <= 1'b1;
                            srb_state_q   <= SRB_FATAL_ERROR;
                        end else begin
                            dmem_rsp_ready_o <= 1'b1;
                            srb_state_q      <= SRB_REFILL_RSP;
                        end
                    end
                end

                SRB_REFILL_RSP: begin
                    dmem_req_valid_o <= 1'b0;
                    dmem_rsp_ready_o <= 1'b1;
                    if (dmem_rsp_valid_i && dmem_rsp_ready_o) begin
                        if (dmem_rsp_error_i) begin
                            fatal_error_q    <= 1'b1;
                            dmem_rsp_ready_o <= 1'b0;
                            srb_state_q      <= SRB_FATAL_ERROR;
                        end else begin
                            srb_refill_data_q[srb_beat_cnt_q] <= dmem_rsp_data_i;
                            if (srb_beat_cnt_q == 3'd7) begin
                                dmem_rsp_ready_o <= 1'b0;
                                srb_state_q      <= SRB_INSTALL;
                            end else begin
                                srb_beat_cnt_q   <= srb_beat_cnt_q + 1'b1;
                                dmem_req_valid_o <= 1'b1;
                                dmem_req_store_o <= 1'b0;
                                dmem_req_addr_o  <= {8'd0, srb_line_pa_q, srb_beat_cnt_q + 1'b1, 3'b000};
                                dmem_req_size_o  <= 3'd3;
                                dmem_rsp_ready_o <= 1'b0;
                                srb_state_q      <= SRB_REFILL_REQ;
                            end
                        end
                    end
                end

                SRB_INSTALL: begin
                    // 1-cycle installation (P1-2)
                    // Merge store payload into refilled line
                    for (int d = 0; d < 8; d++) begin
                        if (3'(d) == srb_word_offset_q) begin
                            data_q[srb_set_q][srb_way_q][d] <= apply_byte_mask(
                                srb_refill_data_q[d],
                                srb_store_data_q,
                                srb_store_mask_q
                            );
                        end else begin
                            data_q[srb_set_q][srb_way_q][d] <= srb_refill_data_q[d];
                        end
                    end
                    tag_q[srb_set_q][srb_way_q]   <= srb_line_pa_q[49:6]; // PA[55:12]
                    valid_q[srb_set_q][srb_way_q] <= 1'b1;
                    dirty_q[srb_set_q][srb_way_q] <= 1'b1;
                    dirty_count_q                 <= dirty_count_q + 9'd1;

                    // Update Tree-PLRU to mark srb_way_q as MRU only at install cycle (P0-2)
                    plru_q[srb_set_q] <= plru_update(plru_q[srb_set_q], srb_way_q);

                    srb_busy_q  <= 1'b0;
                    srb_state_q <= SRB_IDLE;
                end

                SRB_FATAL_ERROR: begin
                    fatal_error_q    <= 1'b1;
                    dmem_req_valid_o <= 1'b0;
                    dmem_rsp_ready_o <= 1'b0;
                end

                default: srb_state_q <= SRB_IDLE;
            endcase

            case (state_q)
                // -------------------------------------------------------------
                // IDLE: Accept new operations, serve 1-cycle hits
                // -------------------------------------------------------------
                IDLE: begin
                    if (!fatal_error_q && !reg_retire_valid && !reg_fault_valid && !er_retire_valid_q) begin
                        // Priority 1: Serialized Maintenance Flushes
                        if ((fence_i_req_i || sfence_vma_req_i || pmp_flush_req_i) && !srb_busy_q && !srb_capture) begin
                            flush_is_fence_i_q <= fence_i_req_i;
                            flush_is_sfence_q  <= sfence_vma_req_i;
                            flush_is_pmp_q     <= pmp_flush_req_i;
                            flush_set_q        <= '0;
                            if (!any_cache_dirty) begin
                                state_q <= FLUSH_DONE;
                            end else begin
                                state_q <= FLUSH_SWEEP;
                            end
                        end
                        // Priority 2: Uncached MMIO Access
                        else if (req_valid_i && trans_valid_i && !trans_busy_i &&
                                 !trans_page_fault_i && trans_pmp_allow_i && !is_dram && !srb_busy_q && !srb_capture) begin
                            target_va_q         <= req_addr_i;
                            target_pa_q         <= trans_pa_i;
                            target_size_q       <= req_size_i;
                            target_unsigned_q   <= req_unsigned_i;
                            target_store_data_q <= req_store_data_i;
                            target_rd_q         <= req_rd_i;
                            target_pc_q         <= req_pc_i;
                            target_insn_q       <= req_insn_i;
                            target_is_store_q   <= req_store_i;
                            dmem_req_valid_o    <= 1'b1;
                            dmem_req_store_o    <= req_store_i;
                            dmem_req_addr_o     <= {8'd0, trans_pa_i};
                            dmem_req_size_o     <= req_size_i;
                            dmem_req_store_data_o <= req_store_data_i;
                            if (req_store_i) begin
                                res_valid_q <= 1'b0;
                            end
                            state_q             <= MMIO_REQ;
                        end
                        // Priority 3: Normal Cached Hit or Miss in DRAM
                        else if (can_lookup) begin
                        // Case A: SC Mismatch -> 1 cycle failure
                        if (req_sc_i && !sc_matches) begin
                            res_valid_q <= 1'b0;
                        end
                        // Case B: Hit in Cache
                        else if (tag_matched) begin
                            plru_q[set_idx] <= plru_update(plru_q[set_idx], hit_way);

                            if (op_is_load) begin
                                if (req_lr_i) begin
                                    res_valid_q      <= 1'b1;
                                    res_exact_pa_q   <= trans_pa_i;
                                    res_size_q       <= req_size_i;
                                    res_granule_pa_q <= trans_pa_i[55:6];
                                end
                            end else if (op_is_store) begin
                                res_valid_q <= 1'b0;
                                // Perform store update into cache line
                                data_q[set_idx][hit_way][dword_idx] <= req_is_sb_drain_i ?
                                    apply_byte_mask(data_q[set_idx][hit_way][dword_idx], req_store_data_i, req_byte_mask_i) :
                                    merge_store_byte(data_q[set_idx][hit_way][dword_idx], req_store_data_i, byte_idx, req_size_i);
                                if (!dirty_q[set_idx][hit_way]) begin
                                    dirty_count_q <= dirty_count_q + 9'd1;
                                end
                                dirty_q[set_idx][hit_way] <= 1'b1;
                            end else if (op_is_amo) begin
                                // 2-cycle atomic sequence: Read Phase (Cycle 1)
                                amo_rdata_q         <= data_q[set_idx][hit_way][dword_idx];
                                amo_hit_way_q       <= hit_way;
                                target_va_q         <= req_addr_i;
                                target_pa_q         <= trans_pa_i;
                                target_size_q       <= req_size_i;
                                target_store_data_q <= req_store_data_i;
                                target_rd_q         <= req_rd_i;
                                target_pc_q         <= req_pc_i;
                                target_insn_q       <= req_insn_i;
                                target_amo_op_q     <= req_amo_op_i;
                                state_q             <= AMO_CYCLE2;
                            end
                        end
                        // Case C: Miss in Cache -> Initiate Synchronous Write-Allocate Flow
                        else begin
                            if (!srb_capture && !srb_busy_q) begin
                                logic [1:0] victim;
                                victim = plru_victim(plru_q[set_idx], {valid_q[set_idx][3], valid_q[set_idx][2], valid_q[set_idx][1], valid_q[set_idx][0]});
                                target_victim_way_q <= victim;
                                target_va_q         <= req_addr_i;
                                target_pa_q         <= trans_pa_i;
                                target_size_q        <= req_size_i;
                                target_unsigned_q    <= req_unsigned_i;
                                target_store_data_q  <= req_store_data_i;
                                target_byte_mask_q   <= req_byte_mask_i;
                                target_is_sb_drain_q <= req_is_sb_drain_i;
                                target_rd_q          <= req_rd_i;
                                target_pc_q         <= req_pc_i;
                                target_insn_q       <= req_insn_i;
                                target_is_store_q   <= req_store_i;
                                target_is_lr_q      <= req_lr_i;
                                target_is_sc_q      <= req_sc_i;
                                target_is_amo_q     <= req_amo_i;
                                target_amo_op_q     <= req_amo_op_i;
                                target_is_ordinary_load_q <= req_valid_i && is_dram && !req_store_i && !req_lr_i && !req_sc_i && !req_amo_i;
                                target_crit_beat_q        <= trans_pa_i[5:3];
                                crit_beat_captured_q      <= 1'b0;
                                er_retire_valid_q         <= 1'b0;
                                er_load_retired_q         <= 1'b0;
                                er_load_squashed_q        <= 1'b0;
                                rfb_crit_consumed_q       <= 1'b0;
                                refill_poisoned_q         <= 1'b0;

                                // If victim is dirty, synchronously evict to DRAM before refilling
                                if (valid_q[set_idx][victim] && dirty_q[set_idx][victim]) begin
                                    eb_addr_q <= {8'd0, tag_q[set_idx][victim], set_idx, 6'b000000};
                                    for (int d = 0; d < 8; d++) begin
                                        eb_data_q[d] <= data_q[set_idx][victim][d];
                                    end
                                    eb_way_q <= victim;
                                    eb_set_q <= set_idx;
                                    beat_cnt_q <= '0;
                                    state_q <= EVICT_REQ;
                                end else begin
                                    // Clean victim: skip eviction, initiate refill immediately
                                    beat_cnt_q <= '0;
                                    state_q <= REFILL_REQ;
                                end
                            end
                        end
                    end
                end
            end

                // -------------------------------------------------------------
                // AMO_CYCLE2: Compute & Write Phase (Indivisible Cycle 2)
                // -------------------------------------------------------------
                AMO_CYCLE2: begin
                    logic [31:0] mem_word;
                    logic [63:0] alu_in_mem;
                    logic [63:0] alu_result;

                    mem_word = target_pa_q[2] ? amo_rdata_q[63:32] : amo_rdata_q[31:0];
                    alu_in_mem = (target_size_q == 3'd2) ? {{32{mem_word[31]}}, mem_word} : amo_rdata_q;

                    alu_result = calc_amo(target_amo_op_q, target_size_q, alu_in_mem, target_store_data_q);

                    // Write result to cache line
                    data_q[target_pa_q[11:6]][amo_hit_way_q][target_pa_q[5:3]] <= merge_store_byte(
                        data_q[target_pa_q[11:6]][amo_hit_way_q][target_pa_q[5:3]],
                        alu_result,
                        target_pa_q[2:0],
                        target_size_q
                    );
                    if (!dirty_q[target_pa_q[11:6]][amo_hit_way_q]) begin
                        dirty_count_q <= dirty_count_q + 9'd1;
                    end
                    dirty_q[target_pa_q[11:6]][amo_hit_way_q] <= 1'b1;
                    plru_q[target_pa_q[11:6]] <= plru_update(plru_q[target_pa_q[11:6]], amo_hit_way_q);

                    if (target_pa_q[55:6] == res_granule_pa_q) begin
                        res_valid_q <= 1'b0;
                    end

                    // Retire instruction
                    reg_retire_valid    <= 1'b1;
                    reg_retire_rd_write <= (target_rd_q != 5'd0);
                    reg_retire_rd       <= target_rd_q;
                    reg_retire_rd_data  <= (target_size_q == 3'd2) ? {{32{mem_word[31]}}, mem_word} : amo_rdata_q;
                    reg_retire_pc       <= target_pc_q;
                    reg_retire_insn     <= target_insn_q;
                    state_q             <= IDLE;
                end

                // -------------------------------------------------------------
                // EVICT_REQ / EVICT_BURST: 8-Beat Dirty Victim Burst to DRAM
                // -------------------------------------------------------------
                EVICT_REQ: begin
                    dmem_req_valid_o      <= 1'b1;
                    dmem_req_store_o      <= 1'b1;
                    dmem_req_addr_o       <= {eb_addr_q[63:6], beat_cnt_q, 3'b000};
                    dmem_req_size_o       <= 3'd3; // 8-byte doubleword
                    dmem_req_store_data_o <= eb_data_q[beat_cnt_q];
                    state_q               <= EVICT_BURST;
                end

                EVICT_BURST: begin
                    // Detect injected writeback error -> Fatal Platform Error (P1-1)
                    if (dmem_rsp_error_i || dmem_req_error_i) begin
                        fatal_error_q    <= 1'b1;
                        dmem_req_valid_o <= 1'b0;
                        dmem_rsp_ready_o <= 1'b0;
                        state_q          <= IDLE;
                    end else if (dmem_req_valid_o && dmem_req_ready_i) begin
                        if (beat_cnt_q == 3'd7) begin
                            dmem_req_valid_o <= 1'b0;
                            dirty_q[eb_set_q][eb_way_q] <= 1'b0;
                            if (dirty_count_q > 9'd0) dirty_count_q <= dirty_count_q - 9'd1;
                            beat_cnt_q <= '0;
                            dmem_req_valid_o <= 1'b1;
                            dmem_req_store_o <= 1'b0;
                            dmem_req_addr_o  <= {8'd0, target_pa_q[55:6], 6'b000000};
                            dmem_req_size_o  <= 3'd3;
                            dmem_rsp_ready_o <= 1'b0;
                            state_q <= REFILL_REQ;
                        end else begin
                            beat_cnt_q <= beat_cnt_q + 1'b1;
                            dmem_req_addr_o <= {eb_addr_q[63:6], beat_cnt_q + 1'b1, 3'b000};
                            dmem_req_store_data_o <= eb_data_q[beat_cnt_q + 1'b1];
                        end
                    end
                end

                // -------------------------------------------------------------
                // REFILL_REQ / REFILL_RSP: 8-Beat Line Refill from DRAM
                // -------------------------------------------------------------
                REFILL_REQ: begin
                    dmem_req_valid_o <= 1'b1;
                    dmem_req_store_o <= 1'b0;
                    dmem_req_addr_o  <= {8'd0, target_pa_q[55:6], beat_cnt_q, 3'b000};
                    dmem_req_size_o  <= 3'd3;
                    dmem_rsp_ready_o <= 1'b0;
                    if (dmem_req_valid_o && dmem_req_ready_i) begin
                        dmem_req_valid_o <= 1'b0;
                        if (dmem_req_error_i) begin
                            valid_q[target_pa_q[11:6]][target_victim_way_q] <= 1'b0;
                            er_retire_valid_q    <= 1'b0;
                            crit_beat_captured_q <= 1'b0;
                            refill_poisoned_q    <= 1'b1;
                            if (er_load_retired_q || (retire_ack_i && er_retire_valid_q)) begin
                                fatal_error_q <= 1'b1;
                            end else if (!er_load_squashed_q && !redirect_i) begin
                                reg_fault_valid      <= 1'b1;
                                reg_fault_store      <= target_is_store_q || target_is_amo_q;
                                reg_fault_addr       <= target_va_q;
                                reg_fault_pc         <= target_pc_q;
                                reg_fault_insn       <= target_insn_q;
                                reg_fault_page       <= 1'b0;
                            end
                            er_load_retired_q  <= 1'b0;
                            er_load_squashed_q <= 1'b0;
                            state_q          <= IDLE;
                        end else begin
                            dmem_rsp_ready_o <= 1'b1;
                            state_q          <= REFILL_RSP;
                        end
                    end
                end

                REFILL_RSP: begin
                    dmem_req_valid_o <= 1'b0;
                    dmem_rsp_ready_o <= 1'b1;
                    if (dmem_rsp_valid_i && dmem_rsp_ready_o) begin
                        if (dmem_rsp_error_i) begin
                            // Refill error -> Invalidate line & assert precise access fault
                            valid_q[target_pa_q[11:6]][target_victim_way_q] <= 1'b0;
                            dmem_rsp_ready_o <= 1'b0;
                            er_retire_valid_q    <= 1'b0;
                            crit_beat_captured_q <= 1'b0;
                            refill_poisoned_q    <= 1'b1;
                            if (er_load_retired_q || (retire_ack_i && er_retire_valid_q)) begin
                                fatal_error_q <= 1'b1;
                            end else if (!er_load_squashed_q && !redirect_i) begin
                                reg_fault_valid      <= 1'b1;
                                reg_fault_store      <= target_is_store_q || target_is_amo_q;
                                reg_fault_addr       <= target_va_q;
                                reg_fault_pc         <= target_pc_q;
                                reg_fault_insn       <= target_insn_q;
                                reg_fault_page       <= 1'b0;
                            end
                            er_load_retired_q  <= 1'b0;
                            er_load_squashed_q <= 1'b0;
                            state_q          <= IDLE;
                        end else begin
                            refill_buf_q[beat_cnt_q] <= dmem_rsp_data_i;
                            if (!verification_disable_er && target_is_ordinary_load_q && (target_crit_beat_q != 3'd7) &&
                                (beat_cnt_q == target_crit_beat_q) && !rfb_crit_consumed_q && !refill_poisoned_q) begin
                                crit_beat_captured_q <= 1'b1;
                            end
                            if (beat_cnt_q == 3'd7) begin
                                dmem_rsp_ready_o <= 1'b0;
                                state_q          <= INSTALL;
                            end else begin
                                beat_cnt_q <= beat_cnt_q + 1'b1;
                                dmem_req_valid_o <= 1'b1;
                                dmem_req_store_o <= 1'b0;
                                dmem_req_addr_o  <= {8'd0, target_pa_q[55:6], beat_cnt_q + 1'b1, 3'b000};
                                dmem_req_size_o  <= 3'd3;
                                dmem_rsp_ready_o <= 1'b0;
                                state_q          <= REFILL_REQ;
                            end
                        end
                    end
                end

                // -------------------------------------------------------------
                // INSTALL: Install refilled line and complete requesting op
                // -------------------------------------------------------------
                INSTALL: begin
                    logic [5:0] set_i;
                    logic [1:0] way_i;
                    set_i = target_pa_q[11:6];
                    way_i = target_victim_way_q;
                    // INSTALL/error rejection is terminal for the ER transaction;
                    // trailing-error classification can no longer consult these bits.
                    er_load_retired_q  <= 1'b0;
                    er_load_squashed_q <= 1'b0;

                    if (refill_poisoned_q || fatal_error_q) begin
                        valid_q[set_i][way_i] <= 1'b0;
                        state_q               <= IDLE;
                    end else begin
                    // Install line into tag and valid arrays
                    tag_q[set_i][way_i]   <= target_pa_q[55:12];
                    valid_q[set_i][way_i] <= 1'b1;
                    plru_q[set_i]         <= plru_update(plru_q[set_i], way_i);

                    if (target_is_load(target_is_store_q, target_is_amo_q)) begin
                        // Load / LR completion
                        for (int d = 0; d < 8; d++) begin
                            data_q[set_i][way_i][d] <= refill_buf_q[d];
                        end
                        dirty_q[set_i][way_i] <= 1'b0;

                        if (target_is_lr_q) begin
                            res_valid_q      <= 1'b1;
                            res_exact_pa_q   <= target_pa_q;
                            res_size_q       <= target_size_q;
                            res_granule_pa_q <= target_pa_q[55:6];
                        end

                        if (!rfb_crit_consumed_q && !er_retire_valid_q) begin
                            reg_retire_valid    <= 1'b1;
                            reg_retire_rd_write <= (target_rd_q != 5'd0);
                            reg_retire_rd       <= target_rd_q;
                            reg_retire_rd_data  <= extend_load(refill_buf_q[target_pa_q[5:3]], target_pa_q[2:0], target_size_q, target_unsigned_q);
                            reg_retire_pc       <= target_pc_q;
                            reg_retire_insn     <= target_insn_q;
                        end
                        state_q             <= IDLE;
                    end else if (target_is_store_q && !target_is_amo_q) begin
                        // Store / SC completion
                        for (int d = 0; d < 8; d++) begin
                            if (3'(d) == target_pa_q[5:3]) begin
                                data_q[set_i][way_i][d] <= target_is_sb_drain_q ?
                                    apply_byte_mask(refill_buf_q[d], target_store_data_q, target_byte_mask_q) :
                                    merge_store_byte(refill_buf_q[d], target_store_data_q, target_pa_q[2:0], target_size_q);
                            end else begin
                                data_q[set_i][way_i][d] <= refill_buf_q[d];
                            end
                        end
                        dirty_q[set_i][way_i] <= 1'b1;
                        dirty_count_q <= dirty_count_q + 9'd1;

                        res_valid_q <= 1'b0;

                        if (target_is_sc_q) begin
                            reg_retire_valid    <= 1'b1;
                            reg_retire_pc       <= target_pc_q;
                            reg_retire_insn     <= target_insn_q;
                            reg_retire_rd_write <= (target_rd_q != 5'd0);
                            reg_retire_rd       <= target_rd_q;
                            reg_retire_rd_data  <= 64'd0;
                            res_valid_q         <= 1'b0;
                        end else if (target_is_sb_drain_q) begin
                            reg_retire_valid    <= 1'b0;
                            reg_retire_rd_write <= 1'b0;
                            reg_retire_rd       <= 5'd0;
                            reg_retire_rd_data  <= 64'd0;
                            reg_retire_pc       <= '0;
                            reg_retire_insn     <= '0;
                        end else begin
                            reg_retire_valid    <= 1'b1;
                            reg_retire_pc       <= target_pc_q;
                            reg_retire_insn     <= target_insn_q;
                            reg_retire_rd_write <= 1'b0;
                            reg_retire_rd       <= 5'd0;
                            reg_retire_rd_data  <= 64'd0;
                        end
                        state_q <= IDLE;
                    end else if (target_is_amo_q) begin
                        // AMO Miss: install clean line, capture data, transition to AMO_CYCLE2
                        for (int d = 0; d < 8; d++) begin
                            data_q[set_i][way_i][d] <= refill_buf_q[d];
                        end
                        dirty_q[set_i][way_i] <= 1'b0;
                        amo_rdata_q   <= refill_buf_q[target_pa_q[5:3]];
                        amo_hit_way_q <= way_i;
                        state_q       <= AMO_CYCLE2;
                    end
                    end
                end

                // -------------------------------------------------------------
                // MMIO_REQ / MMIO_RSP: Uncached Peripheral Accesses
                // -------------------------------------------------------------
                MMIO_REQ: begin
                    if (dmem_req_valid_o && dmem_req_ready_i) begin
                        dmem_req_valid_o <= 1'b0;
                        if (dmem_req_store_o) begin
                            if (dmem_req_error_i) begin
                                reg_fault_valid <= 1'b1;
                                reg_fault_store <= 1'b1;
                                reg_fault_addr  <= target_va_q;
                                reg_fault_pc    <= target_pc_q;
                                reg_fault_insn  <= target_insn_q;
                                reg_fault_page  <= 1'b0;
                            end else begin
                                // MMIO Store retires upon request handshake
                                reg_retire_valid    <= 1'b1;
                                reg_retire_rd_write <= 1'b0;
                                reg_retire_pc       <= target_pc_q;
                                reg_retire_insn     <= target_insn_q;
                            end
                            state_q <= IDLE;
                        end else begin
                            // MMIO Load waits for response
                            dmem_rsp_ready_o <= 1'b1;
                            state_q          <= MMIO_RSP;
                        end
                    end
                end

                MMIO_RSP: begin
                    if (dmem_rsp_valid_i && dmem_rsp_ready_o) begin
                        dmem_rsp_ready_o <= 1'b0;
                        if (dmem_rsp_error_i) begin
                            reg_fault_valid <= 1'b1;
                            reg_fault_store <= 1'b0;
                            reg_fault_addr  <= target_va_q;
                            reg_fault_pc    <= target_pc_q;
                            reg_fault_insn  <= target_insn_q;
                            reg_fault_page  <= 1'b0;
                        end else begin
                            reg_retire_valid    <= 1'b1;
                            reg_retire_rd_write <= (target_rd_q != 5'd0);
                            reg_retire_rd       <= target_rd_q;
                            reg_retire_rd_data  <= extend_mmio_load(dmem_rsp_data_i, target_size_q, target_unsigned_q);
                            reg_retire_pc       <= target_pc_q;
                            reg_retire_insn     <= target_insn_q;
                        end
                        state_q <= IDLE;
                    end
                end

                // -------------------------------------------------------------
                // FLUSH_SWEEP: Conservative Set Sweep for FENCE.I / SFENCE.VMA
                // -------------------------------------------------------------
                FLUSH_SWEEP: begin
                    if (!any_cache_dirty) begin
                        state_q <= FLUSH_DONE;
                    end else if (flush_set_dirty != 4'b0000) begin
                        logic [1:0] pick_way;
                        pick_way = flush_set_dirty[0] ? 2'd0 : (flush_set_dirty[1] ? 2'd1 : (flush_set_dirty[2] ? 2'd2 : 2'd3));
                        eb_addr_q <= {8'd0, tag_q[flush_set_q][pick_way], flush_set_q, 6'b000000};
                        for (int d = 0; d < 8; d++) begin
                            eb_data_q[d] <= data_q[flush_set_q][pick_way][d];
                        end
                        eb_set_q   <= flush_set_q;
                        eb_way_q   <= pick_way;
                        beat_cnt_q <= '0;
                        state_q    <= FLUSH_REQ;
                    end else begin
                        if (flush_set_q == 6'd63) begin
                            state_q <= FLUSH_DONE;
                        end else begin
                            flush_set_q <= flush_set_q + 1'b1;
                        end
                    end
                end

                FLUSH_REQ: begin
                    dmem_req_valid_o      <= 1'b1;
                    dmem_req_store_o      <= 1'b1;
                    dmem_req_addr_o       <= {eb_addr_q[63:6], beat_cnt_q, 3'b000};
                    dmem_req_size_o       <= 3'd3;
                    dmem_req_store_data_o <= eb_data_q[beat_cnt_q];
                    state_q               <= FLUSH_BURST;
                end

                FLUSH_BURST: begin
                    if (dmem_rsp_error_i || dmem_req_error_i) begin
                        fatal_error_q    <= 1'b1;
                        dmem_req_valid_o <= 1'b0;
                        dmem_rsp_ready_o <= 1'b0;
                        state_q          <= IDLE;
                    end else if (dmem_req_valid_o && dmem_req_ready_i) begin
                        if (beat_cnt_q == 3'd7) begin
                            dmem_req_valid_o <= 1'b0;
                            dirty_q[eb_set_q][eb_way_q] <= 1'b0;
                            if (dirty_count_q > 9'd0) dirty_count_q <= dirty_count_q - 9'd1;
                            beat_cnt_q <= '0;
                            state_q    <= FLUSH_SWEEP;
                        end else begin
                            beat_cnt_q <= beat_cnt_q + 1'b1;
                            dmem_req_addr_o <= {eb_addr_q[63:6], beat_cnt_q + 1'b1, 3'b000};
                            dmem_req_store_data_o <= eb_data_q[beat_cnt_q + 1'b1];
                        end
                    end
                end

                // -------------------------------------------------------------
                // FLUSH_DONE: Pulse Target Invalidation and Release Freeze
                // -------------------------------------------------------------
                FLUSH_DONE: begin
                    if (flush_is_fence_i_q) begin
                        fence_i_flush_l1i_o <= 1'b1;
                    end
                    if (flush_is_sfence_q) begin
                        sfence_vma_flush_tlb_o <= 1'b1;
                    end
                    if (flush_is_pmp_q) begin
                        pmp_flush_l1i_o <= 1'b1;
                    end
                    state_q <= IDLE;
                end

                default: state_q <= IDLE;
            endcase
        end
    end

    // Helper functions
    function automatic logic target_is_load(input logic s, input logic a);
        return (!s && !a);
    endfunction

endmodule
`endif
