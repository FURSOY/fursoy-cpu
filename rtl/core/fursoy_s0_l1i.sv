`ifndef FURSOY_S0_L1I_SV
`define FURSOY_S0_L1I_SV

// Fursoy Slice-0 Level 1 Instruction Cache (L1I) — v1
// Integrated with L1I-ER v1 (Early Restart & Streaming) and L1I-NLP v1 (Next-Line Prefetcher)
// 16 KiB, 4-way set-associative, 64 sets, 64-byte lines, Tree-PLRU, 1-cycle registered hit path.
// Dedicated 64-bit refill bus with registered critical-beat early restart and intra-line streaming.
// Decoupled 1-Line Prefetch Buffer (PFB) with Policy B beat-preemptible demand dominance and dual-trigger chaining.
// Normative Contracts: docs/architecture/l1i-refill-opt-v1.md and docs/architecture/l1i-nlp-v1.md
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */

module fursoy_s0_l1i #(
    parameter logic [63:0] RESET_PC = 64'h0000_0000_8000_0000
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // Core Pipeline / Fetch Control
    input  logic        fetch_enable_i,
    input  logic        redirect_i,
    input  logic        halt_i,
    input  logic [63:0] fetch_pc_i,
    output logic        fetched_valid_o,
    input  logic        fetched_ready_i,
    output logic [63:0] fetched_pc_o,
    output logic [31:0] fetched_insn_o,
    output logic        fetched_error_o,
    output logic        fetched_page_fault_o,

    // Translation & Authorization Interface (from fursoy_s0_mmu)
    output logic [63:0] trans_req_addr_o,
    output logic        trans_req_valid_o,
    input  logic        trans_busy_i,         // Asserted when ITLB misses and PTW is active
    input  logic        trans_valid_i,        // Translation valid
    input  logic [55:0] trans_pa_i,           // Translated physical address
    input  logic        trans_page_fault_i,   // Canonical or page permission fault
    input  logic        trans_pmp_allow_i,    // Authoritative PMP execution permission
    input  logic        trans_pmp_uniform_x_i,// PMP execute permission uniform across 4 KiB page

    // Interconnect bus activity
    input  logic        mem_bus_busy_i,

    // Flush and Invalidation Inputs
    input  logic        fence_i_flush_i,      // FENCE.I flash invalidation pulse
    input  logic        pmp_flush_i,          // PMP CSR write flush pulse

    // Dedicated Physical Refill Bus (64-bit)
    output logic        imem_req_valid_o,
    input  logic        imem_req_ready_i,
    output logic [63:0] imem_req_addr_o,
    input  logic        imem_rsp_valid_i,
    output logic        imem_rsp_ready_o,
    input  logic [63:0] imem_rsp_data_i,
    input  logic        imem_rsp_error_i,

    // Observability Events (L1I-ER v1)
    output logic        l1i_hit_event_o /* verilator public_flat_rd */,
    output logic        l1i_miss_event_o /* verilator public_flat_rd */,
    output logic        l1i_refill_event_o /* verilator public_flat_rd */,
    output logic        l1i_miss_active_o,
    output logic        l1i_hold_active_o,
    output logic        l1i_early_restart_event_o /* verilator public_flat_rd */,
    output logic [3:0]  l1i_early_restart_saved_cycles_o /* verilator public_flat_rd */,
    output logic        l1i_streaming_hit_event_o /* verilator public_flat_rd */,
    output logic        l1i_refill_abort_event_o /* verilator public_flat_rd */,

    // Observability Events (L1I-NLP v1)
    output logic        l1i_nlp_candidate_event_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_issued_event_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_suppressed_page_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_suppressed_pmp_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_suppressed_resident_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_suppressed_duplicate_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_useful_hit_event_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_streaming_hit_event_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_preempted_event_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_dormant_abandon_event_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_discard_redirect_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_discard_maint_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_discard_error_o /* verilator public_flat_rd */,
    output logic        l1i_nlp_promote_event_o /* verilator public_flat_rd */,
    output logic [4:0]  l1i_nlp_hidden_cycles_o /* verilator public_flat_rd */
);

    // Cache Geometry Parameters
    localparam int SETS = 64;
    localparam int WAYS = 4;
    localparam logic [55:0] DRAM_BASE = 56'h0000_0000_8000_0000;
    localparam logic [55:0] DRAM_END  = 56'h0000_0000_8FFF_FFFF;

    // Cache Storage Arrays
    logic [SETS-1:0][WAYS-1:0] valid_q;
    logic [43:0] tag_q   [SETS][WAYS];
    logic [63:0] data_q  [SETS][WAYS][8];
    logic [SETS-1:0][2:0] plru_q;

    // FSM State Encoding
    typedef enum logic [2:0] {
        FETCH_REQ,
        FETCH_CHECK,
        FETCH_HOLD,
        REFILL_REQ,
        REFILL_RSP
    } state_t;
    state_t state_q;

    // Registered Fetch Control and Holding Registers
    logic [63:0] req_pc_q;
    logic        held_valid_q;
    logic [63:0] held_pc_q;
    logic [31:0] held_insn_q;
    logic        held_error_q;
    logic        held_page_fault_q;
    logic        held_is_hit_q;

    // Refill Buffering and Tracking
    logic [55:0] refill_line_base;
    logic [5:0]  refill_set_idx;
    logic [43:0] refill_tag;
    logic [1:0]  refill_victim;
    logic [3:0]  refill_target_word;
    logic [2:0]  refill_beat_cnt;
    logic [63:0] refill_buf_q [8];
    logic [7:0]  refill_beat_valid_q;
    logic [7:0]  refill_beat_error_q;
    logic        line_has_error_q;
    logic        refill_abort_q;
    logic        refill_error_q;
    logic        refill_pmp_allow_q;
    logic        refill_pmp_uniform_x_q;

    // L1I-ER Early Restart & Streaming Control Registers
    logic        early_restarted_q;
    logic        early_restart_pulse_q;
    logic        streaming_hit_pulse_q;
    logic        refill_abort_pulse_q;
    logic        streaming_wait_beat_q;
    logic        streaming_exit_wait_q;
    logic        streaming_pf_wait_q;
    logic        redirect_pending_q;
    logic [63:0] pending_redirect_pc_q;

    // -------------------------------------------------------------------------
    // L1I-NLP v1 Hardware Prefetcher Structures & Registers
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        PF_IDLE,
        PF_REQ,
        PF_RSP,
        PF_DRAIN
    } pf_state_t;
    pf_state_t pf_state_q;
    logic [2:0] pf_beat_cnt_q;

    // Prefetch Candidate Tracking
    logic        pf_cand_valid_q;
    logic [49:0] pf_cand_pa_q;
    logic [49:0] last_pf_line_q;

    // Standalone 1-Line Prefetch Buffer (PFB)
    logic        pfb_valid_q;
    logic [49:0] pfb_line_pa_q;
    logic [63:0] pfb_data_q [8];
    logic [7:0]  pfb_beat_valid_q;
    logic [7:0]  pfb_beat_error_q;
    logic        pfb_complete_q;
    logic        pfb_has_error_q;

    // Single-Port Promotion Bubble Control
    logic        promotion_bubble_q;

    // NLP Telemetry Strobes
    logic        l1i_nlp_candidate_pulse_q;
    logic        l1i_nlp_issued_pulse_q;
    logic        l1i_nlp_suppressed_page_pulse_q;
    logic        l1i_nlp_suppressed_pmp_pulse_q;
    logic        l1i_nlp_suppressed_resident_pulse_q;
    logic        l1i_nlp_suppressed_duplicate_pulse_q;
    logic        l1i_nlp_useful_hit_pulse_q;
    logic        l1i_nlp_streaming_hit_pulse_q;
    logic        l1i_nlp_preempted_pulse_q;
    logic        l1i_nlp_dormant_abandon_pulse_q;
    logic        l1i_nlp_discard_redirect_pulse_q;
    logic        l1i_nlp_discard_maint_pulse_q;
    logic        l1i_nlp_discard_error_pulse_q;
    logic        l1i_nlp_promote_pulse_q;
    logic [4:0]  l1i_nlp_hidden_cycles_q;

    // Translation Request Driving
    assign trans_req_addr_o  = req_pc_q;
    assign trans_req_valid_o = !rst_i && !halt_i && (state_q == FETCH_CHECK);

    // Address Indexing and Decomposition
    wire [5:0]  check_set_idx = req_pc_q[11:6];
    wire [43:0] check_pa_tag  = trans_pa_i[55:12];
    wire [3:0]  check_word    = trans_pa_i[5:2];

    wire is_dram = (trans_pa_i >= DRAM_BASE) && (trans_pa_i <= DRAM_END);

    // Refill Coordinate Helpers
    wire [2:0] b_crit = refill_target_word[3:1];
    wire       s_crit = refill_target_word[0];
    wire       fetch_in_active_line = (fetch_pc_i[55:6] == refill_line_base[55:6]);
    wire [2:0] b_next = fetch_pc_i[5:3];
    wire       s_next = fetch_pc_i[2];

    // Tree-PLRU Helper Functions
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

    // 4-Way Combinational Hit Evaluation for Main L1I
    logic [3:0] way_hit;
    for (genvar w = 0; w < WAYS; w++) begin : gen_hit_eval
        assign way_hit[w] = valid_q[check_set_idx][w] && (tag_q[check_set_idx][w] == check_pa_tag);
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

    // Instruction Extraction from Hit Way
    wire [63:0] hit_dword = data_q[check_set_idx][hit_way][check_word[3:1]];
    wire [31:0] hit_insn  = check_word[0] ? hit_dword[63:32] : hit_dword[31:0];

    // Combinational Hit, Fault, and Miss Conditions in FETCH_CHECK
    wire hit_condition = (state_q == FETCH_CHECK) && trans_valid_i && !trans_busy_i &&
                         !trans_page_fault_i && trans_pmp_allow_i && is_dram && tag_matched;

    wire fault_condition = (state_q == FETCH_CHECK) && trans_valid_i && !trans_busy_i &&
                          (trans_page_fault_i || !trans_pmp_allow_i || !is_dram);

    // -------------------------------------------------------------------------
    // L1I-NLP Matching Logic with Prefetch Buffer (PFB)
    // -------------------------------------------------------------------------
    wire pf_is_active = (pf_state_q == PF_REQ) || (pf_state_q == PF_RSP);
    wire pfb_line_match = pfb_valid_q && (trans_pa_i[55:6] == pfb_line_pa_q);

    // Case 1: Completed PFB Hit (1-cycle hit with promotion)
    wire pfb_complete_hit = (state_q == FETCH_CHECK) && trans_valid_i && !trans_busy_i &&
                            !trans_page_fault_i && trans_pmp_allow_i && is_dram &&
                            !tag_matched && pfb_line_match && pfb_complete_q;

    // Case 2: Active PFB Hit with demanded beat already arrived (Early Restart from PFB)
    wire pfb_arriving_beat = (pf_state_q == PF_RSP) && imem_rsp_valid_i && (pf_beat_cnt_q == check_word[3:1]);

    wire pfb_active_arrived_hit = (state_q == FETCH_CHECK) && trans_valid_i && !trans_busy_i &&
                                 !trans_page_fault_i && trans_pmp_allow_i && is_dram &&
                                 !tag_matched && pfb_line_match && !pfb_complete_q && pf_is_active &&
                                 (pfb_beat_valid_q[check_word[3:1]] || pfb_arriving_beat) &&
                                 !(pfb_beat_error_q[check_word[3:1]] || (pfb_arriving_beat && imem_rsp_error_i));

    // Case 3: Active PFB with demanded beat pending (Streaming wait on active prefetch)
    wire pfb_active_pending = (state_q == FETCH_CHECK) && trans_valid_i && !trans_busy_i &&
                             !trans_page_fault_i && trans_pmp_allow_i && is_dram &&
                             !tag_matched && pfb_line_match && !pfb_complete_q && pf_is_active &&
                             !pfb_beat_valid_q[check_word[3:1]] && !pfb_arriving_beat;

    // Case 4: Dormant Partial PFB with demanded beat missing or errored (Abandon and demand refill — P0-1 Deadlock fix & §6.2)
    wire pfb_dormant_missing = (state_q == FETCH_CHECK) && trans_valid_i && !trans_busy_i &&
                              !trans_page_fault_i && trans_pmp_allow_i && is_dram &&
                              !tag_matched && pfb_line_match && !pfb_complete_q && !pf_is_active &&
                              (!pfb_beat_valid_q[check_word[3:1]] || pfb_beat_error_q[check_word[3:1]] || pfb_has_error_q);

    // Case 5: Dormant Partial PFB with demanded beat valid (Serve valid beat, no promotion)
    wire pfb_dormant_valid_hit = (state_q == FETCH_CHECK) && trans_valid_i && !trans_busy_i &&
                                !trans_page_fault_i && trans_pmp_allow_i && is_dram &&
                                !tag_matched && pfb_line_match && !pfb_complete_q && !pf_is_active &&
                                !pfb_has_error_q && pfb_beat_valid_q[check_word[3:1]] && !pfb_beat_error_q[check_word[3:1]];

    // Sourced PFB instruction
    wire [63:0] pfb_dword = pfb_arriving_beat ? imem_rsp_data_i : pfb_data_q[check_word[3:1]];
    wire [31:0] pfb_hit_insn = check_word[0] ? pfb_dword[63:32] : pfb_dword[31:0];

    // Standard Miss Condition: misses main cache AND misses/abandons PFB
    wire miss_condition = (state_q == FETCH_CHECK) && trans_valid_i && !trans_busy_i &&
                          !trans_page_fault_i && trans_pmp_allow_i && is_dram &&
                          !tag_matched && (!pfb_line_match || pfb_dormant_missing);

    // Pipeline Output Assignments (Registered Decoupling)
    assign fetched_valid_o = (state_q == FETCH_HOLD)                          ? held_valid_q :
                             (state_q == REFILL_REQ || state_q == REFILL_RSP) ? held_valid_q :
                             hit_condition                                    ? 1'b1 :
                             pfb_complete_hit                                 ? 1'b1 :
                             pfb_active_arrived_hit                           ? 1'b1 :
                             pfb_dormant_valid_hit                            ? 1'b1 :
                             fault_condition                                  ? 1'b1 : 1'b0;

    assign fetched_pc_o = (state_q == FETCH_HOLD || state_q == REFILL_REQ || state_q == REFILL_RSP) ?
                          held_pc_q : req_pc_q;

    assign fetched_insn_o = (state_q == FETCH_HOLD || state_q == REFILL_REQ || state_q == REFILL_RSP) ?
                            held_insn_q :
                            hit_condition ? hit_insn :
                            (pfb_complete_hit || pfb_active_arrived_hit || pfb_dormant_valid_hit) ? pfb_hit_insn : 32'd0;

    assign fetched_error_o = (state_q == FETCH_HOLD || state_q == REFILL_REQ || state_q == REFILL_RSP) ?
                             held_error_q :
                             fault_condition ? 1'b1 : 1'b0;

    assign fetched_page_fault_o = (state_q == FETCH_HOLD || state_q == REFILL_REQ || state_q == REFILL_RSP) ?
                                  held_page_fault_q :
                                  fault_condition ? trans_page_fault_i : 1'b0;

    // -------------------------------------------------------------------------
    // Memory Bus Arbitration: Demand Dominance (Demand > Prefetch)
    // -------------------------------------------------------------------------
    wire demand_bus_req = !rst_i && (state_q == REFILL_REQ);
    wire pf_bus_req     = !rst_i && (state_q != REFILL_REQ) && (state_q != REFILL_RSP) &&
                          (pf_state_q == PF_REQ) && !mem_bus_busy_i &&
                          !redirect_i && !fence_i_flush_i && !pmp_flush_i;

    assign imem_req_valid_o = demand_bus_req || pf_bus_req;
    assign imem_req_addr_o  = demand_bus_req ? ({8'd0, refill_line_base} + {58'd0, refill_beat_cnt, 3'b000}) :
                                               ({8'd0, pfb_line_pa_q, 6'b000000} + {58'd0, pf_beat_cnt_q, 3'b000});

    assign imem_rsp_ready_o = !rst_i && ((state_q == REFILL_RSP) || (pf_state_q == PF_RSP) || (pf_state_q == PF_DRAIN));

    // Observability Event Outputs (L1I-ER v1)
    assign l1i_hit_event_o    = (hit_condition && fetched_ready_i) ||
                                ((state_q == FETCH_HOLD) && held_valid_q && held_is_hit_q && fetched_ready_i);
    assign l1i_miss_event_o   = miss_condition;
    assign l1i_refill_event_o = (state_q == REFILL_RSP) && imem_rsp_valid_i && (refill_beat_cnt == 3'd7) &&
                                !refill_abort_q && !refill_error_q && !line_has_error_q && !imem_rsp_error_i &&
                                !redirect_i && !fence_i_flush_i && !pmp_flush_i;

    // Stage F Stall Predicates:
    assign l1i_miss_active_o = ((state_q == REFILL_REQ || state_q == REFILL_RSP) && !held_valid_q) ||
                               (streaming_wait_beat_q && !held_valid_q && !(pfb_active_arrived_hit || pfb_dormant_valid_hit || pfb_complete_hit)) ||
                               promotion_bubble_q;
    assign l1i_hold_active_o = (state_q == FETCH_HOLD) && !fetched_ready_i;

    assign l1i_early_restart_event_o        = early_restart_pulse_q;
    assign l1i_early_restart_saved_cycles_o = 4'd14 - {refill_target_word[3:1], 1'b0};
    assign l1i_streaming_hit_event_o        = streaming_hit_pulse_q;
    assign l1i_refill_abort_event_o         = refill_abort_pulse_q;

    // Observability Event Outputs (L1I-NLP v1)
    assign l1i_nlp_candidate_event_o        = l1i_nlp_candidate_pulse_q;
    assign l1i_nlp_issued_event_o           = l1i_nlp_issued_pulse_q;
    assign l1i_nlp_suppressed_page_o        = l1i_nlp_suppressed_page_pulse_q;
    assign l1i_nlp_suppressed_pmp_o         = l1i_nlp_suppressed_pmp_pulse_q;
    assign l1i_nlp_suppressed_resident_o    = l1i_nlp_suppressed_resident_pulse_q;
    assign l1i_nlp_suppressed_duplicate_o   = l1i_nlp_suppressed_duplicate_pulse_q;
    assign l1i_nlp_useful_hit_event_o       = l1i_nlp_useful_hit_pulse_q;
    assign l1i_nlp_streaming_hit_event_o    = l1i_nlp_streaming_hit_pulse_q;
    assign l1i_nlp_preempted_event_o        = l1i_nlp_preempted_pulse_q;
    assign l1i_nlp_dormant_abandon_event_o  = l1i_nlp_dormant_abandon_pulse_q;
    assign l1i_nlp_discard_redirect_o       = l1i_nlp_discard_redirect_pulse_q;
    assign l1i_nlp_discard_maint_o          = l1i_nlp_discard_maint_pulse_q;
    assign l1i_nlp_discard_error_o          = l1i_nlp_discard_error_pulse_q;
    assign l1i_nlp_promote_event_o          = l1i_nlp_promote_pulse_q;
    assign l1i_nlp_hidden_cycles_o          = l1i_nlp_hidden_cycles_q;

    // -------------------------------------------------------------------------
    // Candidate Generation & Trigger Logic (Dual-Trigger Chaining: P0-2)
    // -------------------------------------------------------------------------
    logic [55:0] cand_trigger_base_pa;
    logic        cand_trigger_fire;

    always_comb begin
        cand_trigger_fire    = 1'b0;
        cand_trigger_base_pa = 56'd0;

        // Trigger 1: Authoritative demand-miss refill completion on Beat 7
        if ((state_q == REFILL_RSP) && imem_rsp_valid_i && (refill_beat_cnt == 3'd7) &&
            !refill_abort_q && !refill_error_q && !line_has_error_q && !imem_rsp_error_i &&
            !redirect_i && !fence_i_flush_i && !pmp_flush_i) begin
            cand_trigger_fire    = 1'b1;
            cand_trigger_base_pa = refill_line_base;
        // Trigger 2: Useful PFB line consumption and promotion
        end else if (pfb_complete_hit && fetched_ready_i && !redirect_i) begin
            cand_trigger_fire    = 1'b1;
            cand_trigger_base_pa = {pfb_line_pa_q, 6'b000000};
        end
    end

    wire [55:0] cand_next_pa       = cand_trigger_base_pa + 56'd64;
    wire        cand_same_page     = (cand_next_pa[55:12] == cand_trigger_base_pa[55:12]);
    wire        cand_is_dram       = (cand_next_pa >= DRAM_BASE) && ((cand_next_pa + 56'd63) <= DRAM_END);
    wire        cand_pmp_allow     = (cand_trigger_base_pa == refill_line_base) ? refill_pmp_allow_q : trans_pmp_allow_i;
    wire        cand_pmp_uniform_x = (cand_trigger_base_pa == refill_line_base) ? refill_pmp_uniform_x_q : trans_pmp_uniform_x_i;
    wire        cand_pmp_ok        = cand_pmp_allow && cand_pmp_uniform_x;
    wire        cand_is_duplicate  = (cand_next_pa[55:6] == last_pf_line_q) ||
                                     (pfb_valid_q && (cand_next_pa[55:6] == pfb_line_pa_q)) ||
                                     (pf_cand_valid_q && (cand_next_pa[55:6] == pf_cand_pa_q));

    // Single-Port Scheduled Candidate Tag Residency Check
    logic cand_already_cached;
    always_comb begin
        cand_already_cached = 1'b0;
        for (int w = 0; w < WAYS; w++) begin
            if (valid_q[cand_next_pa[11:6]][w] && (tag_q[cand_next_pa[11:6]][w] == cand_next_pa[55:12])) begin
                cand_already_cached = 1'b1;
            end
        end
    end

    wire pf_demand_miss_active = ((state_q == REFILL_REQ) || (state_q == REFILL_RSP)) && !held_valid_q;

    wire pf_can_issue = !halt_i && pf_cand_valid_q && (pf_state_q == PF_IDLE) &&
                        !pf_demand_miss_active && !redirect_pending_q && !redirect_i &&
                        !fence_i_flush_i && !pmp_flush_i && !mem_bus_busy_i;

    // -------------------------------------------------------------------------
    // Sequential Datapath and FSM Controller
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q               <= FETCH_REQ;
            req_pc_q              <= RESET_PC;
            held_valid_q          <= 1'b0;
            held_pc_q             <= RESET_PC;
            held_insn_q           <= 32'd0;
            held_error_q          <= 1'b0;
            held_page_fault_q     <= 1'b0;
            held_is_hit_q         <= 1'b0;
            refill_line_base      <= 56'd0;
            refill_set_idx        <= 6'd0;
            refill_tag            <= 44'd0;
            refill_victim         <= 2'd0;
            refill_target_word    <= 4'd0;
            refill_beat_cnt       <= 3'd0;
            refill_buf_q          <= '{default: '0};
            refill_beat_valid_q   <= 8'd0;
            refill_beat_error_q   <= 8'd0;
            line_has_error_q      <= 1'b0;
            refill_abort_q        <= 1'b0;
            refill_error_q        <= 1'b0;
            refill_pmp_allow_q    <= 1'b0;
            refill_pmp_uniform_x_q<= 1'b0;
            early_restarted_q     <= 1'b0;
            early_restart_pulse_q <= 1'b0;
            streaming_hit_pulse_q <= 1'b0;
            refill_abort_pulse_q  <= 1'b0;
            streaming_wait_beat_q <= 1'b0;
            streaming_exit_wait_q <= 1'b0;
            streaming_pf_wait_q   <= 1'b0;
            redirect_pending_q    <= 1'b0;
            pending_redirect_pc_q <= 64'd0;

            valid_q               <= '0;
            plru_q                <= '0;

            // NLP Registers
            pf_state_q            <= PF_IDLE;
            pf_beat_cnt_q         <= 3'd0;
            pf_cand_valid_q       <= 1'b0;
            pf_cand_pa_q          <= 50'd0;
            last_pf_line_q        <= 50'd0;
            pfb_valid_q           <= 1'b0;
            pfb_line_pa_q         <= 50'd0;
            pfb_data_q            <= '{default: '0};
            pfb_beat_valid_q      <= 8'd0;
            pfb_beat_error_q      <= 8'd0;
            pfb_complete_q        <= 1'b0;
            pfb_has_error_q       <= 1'b0;
            promotion_bubble_q    <= 1'b0;

            l1i_nlp_candidate_pulse_q            <= 1'b0;
            l1i_nlp_issued_pulse_q               <= 1'b0;
            l1i_nlp_suppressed_page_pulse_q      <= 1'b0;
            l1i_nlp_suppressed_pmp_pulse_q       <= 1'b0;
            l1i_nlp_suppressed_resident_pulse_q  <= 1'b0;
            l1i_nlp_suppressed_duplicate_pulse_q <= 1'b0;
            l1i_nlp_useful_hit_pulse_q           <= 1'b0;
            l1i_nlp_streaming_hit_pulse_q        <= 1'b0;
            l1i_nlp_preempted_pulse_q            <= 1'b0;
            l1i_nlp_dormant_abandon_pulse_q      <= 1'b0;
            l1i_nlp_discard_redirect_pulse_q     <= 1'b0;
            l1i_nlp_discard_maint_pulse_q        <= 1'b0;
            l1i_nlp_discard_error_pulse_q        <= 1'b0;
            l1i_nlp_promote_pulse_q              <= 1'b0;
            l1i_nlp_hidden_cycles_q              <= 5'd0;
        end else begin
            // Default 1-cycle strobe deassertions
            early_restart_pulse_q                <= 1'b0;
            streaming_hit_pulse_q                <= 1'b0;
            refill_abort_pulse_q                 <= 1'b0;
            promotion_bubble_q                   <= 1'b0;

            l1i_nlp_candidate_pulse_q            <= 1'b0;
            l1i_nlp_issued_pulse_q               <= 1'b0;
            l1i_nlp_suppressed_page_pulse_q      <= 1'b0;
            l1i_nlp_suppressed_pmp_pulse_q       <= 1'b0;
            l1i_nlp_suppressed_resident_pulse_q  <= 1'b0;
            l1i_nlp_suppressed_duplicate_pulse_q <= 1'b0;
            l1i_nlp_useful_hit_pulse_q           <= 1'b0;
            l1i_nlp_streaming_hit_pulse_q        <= 1'b0;
            l1i_nlp_preempted_pulse_q            <= 1'b0;
            l1i_nlp_dormant_abandon_pulse_q      <= 1'b0;
            l1i_nlp_discard_redirect_pulse_q     <= 1'b0;
            l1i_nlp_discard_maint_pulse_q        <= 1'b0;
            l1i_nlp_discard_error_pulse_q        <= 1'b0;
            l1i_nlp_promote_pulse_q              <= 1'b0;
            l1i_nlp_hidden_cycles_q              <= 5'd0;

            // Flash Invalidation Handling for FENCE.I and PMP Writes
            if (fence_i_flush_i || pmp_flush_i) begin
                valid_q          <= '0;
                held_valid_q     <= 1'b0;
                held_is_hit_q    <= 1'b0;
                pfb_valid_q      <= 1'b0;
                pfb_complete_q   <= 1'b0;
                pf_cand_valid_q  <= 1'b0;
                l1i_nlp_discard_maint_pulse_q <= 1'b1;
            end

            // Reviewer Option A: Unconditional Refill Abort on ANY Redirect / Flush during active demand refill
            if ((state_q == REFILL_REQ || state_q == REFILL_RSP) &&
                (redirect_i || halt_i || fence_i_flush_i || pmp_flush_i)) begin
                refill_abort_q       <= 1'b1;
                refill_abort_pulse_q <= 1'b1;
                if (redirect_i) begin
                    pending_redirect_pc_q <= fetch_pc_i;
                    redirect_pending_q    <= 1'b1;
                end
                held_valid_q          <= 1'b0;
                held_is_hit_q         <= 1'b0;
                streaming_wait_beat_q <= 1'b0;
                streaming_pf_wait_q   <= 1'b0;
            end

            // Purge pending prefetch candidates on pipeline redirect
            if (redirect_i) begin
                pf_cand_valid_q <= 1'b0;
            end

            if (halt_i) begin
                held_valid_q          <= 1'b0;
                held_is_hit_q         <= 1'b0;
                pf_cand_valid_q       <= 1'b0;
                streaming_wait_beat_q <= 1'b0;
                streaming_pf_wait_q   <= 1'b0;
            end

            // -----------------------------------------------------------------
            // Dual-Trigger Candidate Generation Evaluation (P0-2)
            // -----------------------------------------------------------------
            if (cand_trigger_fire && !halt_i) begin
                if (!cand_same_page) begin
                    l1i_nlp_suppressed_page_pulse_q <= 1'b1;
                end else if (!cand_pmp_ok) begin
                    l1i_nlp_suppressed_pmp_pulse_q <= 1'b1;
                end else if (cand_is_duplicate) begin
                    l1i_nlp_suppressed_duplicate_pulse_q <= 1'b1;
                end else if (cand_already_cached) begin
                    l1i_nlp_suppressed_resident_pulse_q <= 1'b1;
                end else if (cand_is_dram) begin
                    pf_cand_valid_q                 <= 1'b1;
                    pf_cand_pa_q                    <= cand_next_pa[55:6];
                    last_pf_line_q                  <= cand_next_pa[55:6];
                    l1i_nlp_candidate_pulse_q       <= 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // Prefetch State Machine (Policy B: Beat-Preemptible Refill)
            // -----------------------------------------------------------------
            case (pf_state_q)
                PF_IDLE: begin
                    if (pf_can_issue) begin
                        pf_state_q             <= PF_REQ;
                        pf_beat_cnt_q          <= 3'd0;
                        pfb_valid_q            <= 1'b1;
                        pfb_complete_q         <= 1'b0;
                        pfb_has_error_q        <= 1'b0;
                        pfb_line_pa_q          <= pf_cand_pa_q;
                        pfb_beat_valid_q       <= 8'd0;
                        pfb_beat_error_q       <= 8'd0;
                        pf_cand_valid_q        <= 1'b0;
                        l1i_nlp_issued_pulse_q <= 1'b1;
                    end
                end

                PF_REQ: begin
                    if (halt_i) begin
                        pfb_valid_q    <= 1'b0;
                        pfb_complete_q <= 1'b0;
                        if (imem_req_ready_i && !mem_bus_busy_i)
                            pf_state_q <= PF_RSP;
                    end else if (redirect_i || fence_i_flush_i || pmp_flush_i) begin
                        pf_state_q     <= PF_IDLE;
                        pfb_complete_q <= 1'b0;
                        if (fence_i_flush_i || pmp_flush_i || (pfb_beat_valid_q == 8'd0)) begin
                            pfb_valid_q <= 1'b0;
                        end
                        if (redirect_i) l1i_nlp_discard_redirect_pulse_q <= 1'b1;
                        else            l1i_nlp_discard_maint_pulse_q    <= 1'b1;
                    // Policy B Preemption: if demand miss arrives before beat request handshakes, abort immediately!
                    end else if ((state_q == REFILL_REQ) || (state_q == REFILL_RSP) ||
                                 ((state_q == FETCH_CHECK) && miss_condition &&
                                  (!pfb_valid_q || (trans_pa_i[55:6] != pfb_line_pa_q)))) begin
                        pf_state_q                <= PF_IDLE;
                        l1i_nlp_preempted_pulse_q <= 1'b1;
                    end else if (imem_req_ready_i && !mem_bus_busy_i) begin
                        pf_state_q <= PF_RSP;
                    end
                end

                PF_RSP: begin
                    if (halt_i) begin
                        // A response accepted on this edge is already drained;
                        // otherwise retain the response owner until it arrives.
                        pf_state_q     <= imem_rsp_valid_i ? PF_IDLE : PF_DRAIN;
                        pfb_valid_q    <= 1'b0;
                        pfb_complete_q <= 1'b0;
                    end else if (redirect_i || fence_i_flush_i || pmp_flush_i) begin
                        // In-flight beat request must be drained upon arrival to prevent orphaned responses
                        pf_state_q     <= PF_DRAIN;
                        pfb_complete_q <= 1'b0;
                        if (fence_i_flush_i || pmp_flush_i || (pfb_beat_valid_q == 8'd0)) begin
                            pfb_valid_q <= 1'b0;
                        end
                        if (redirect_i) l1i_nlp_discard_redirect_pulse_q <= 1'b1;
                        else            l1i_nlp_discard_maint_pulse_q    <= 1'b1;
                    end else if (imem_rsp_valid_i) begin
                        pfb_data_q[pf_beat_cnt_q]        <= imem_rsp_data_i;
                        pfb_beat_valid_q[pf_beat_cnt_q] <= 1'b1;
                        pfb_beat_error_q[pf_beat_cnt_q] <= imem_rsp_error_i;

                        // Wake up Stage F streaming wait if waiting on this exact beat
                        if (streaming_wait_beat_q && streaming_pf_wait_q && (held_pc_q[5:3] == pf_beat_cnt_q)) begin
                            streaming_wait_beat_q <= 1'b0;
                            streaming_pf_wait_q   <= 1'b0;
                        end

                        if (imem_rsp_error_i) begin
                            pfb_has_error_q               <= 1'b1;
                            pf_state_q                    <= PF_IDLE;
                            l1i_nlp_discard_error_pulse_q <= 1'b1;
                            if (streaming_wait_beat_q && streaming_pf_wait_q) begin
                                streaming_wait_beat_q <= 1'b0;
                                streaming_pf_wait_q   <= 1'b0;
                            end
                        // Policy B Preemption: complete this accepted beat, then yield to demand refill
                        end else if ((state_q == REFILL_REQ) || (state_q == REFILL_RSP) ||
                                     ((state_q == FETCH_CHECK) && miss_condition && (trans_pa_i[55:6] != pfb_line_pa_q))) begin
                            pf_state_q                <= PF_IDLE;
                            l1i_nlp_preempted_pulse_q <= 1'b1;
                        end else if (pf_beat_cnt_q == 3'd7) begin
                            pf_state_q            <= PF_IDLE;
                            pfb_complete_q        <= !pfb_has_error_q;
                            streaming_wait_beat_q <= 1'b0;
                            streaming_pf_wait_q   <= 1'b0;
                        end else begin
                            pf_beat_cnt_q <= pf_beat_cnt_q + 3'd1;
                            pf_state_q    <= PF_REQ;
                        end
                    end
                end

                PF_DRAIN: begin
                    if (imem_rsp_valid_i) begin
                        pf_state_q <= PF_IDLE;
                    end
                end

                default: pf_state_q <= PF_IDLE;
            endcase

            // -----------------------------------------------------------------
            // Demand Fetch State Machine
            // -----------------------------------------------------------------
            unique case (state_q)
                FETCH_REQ: begin
                    if (halt_i) begin
                        state_q <= FETCH_REQ;
                    end else if (redirect_i) begin
                        req_pc_q <= fetch_pc_i;
                        state_q  <= FETCH_CHECK;
                    end else if (promotion_bubble_q) begin
                        // Single-Port Promotion 1-Cycle Bubble (P1-1)
                        promotion_bubble_q <= 1'b0;
                        state_q            <= fetch_enable_i ? FETCH_CHECK : FETCH_REQ;
                    end else if (fetch_enable_i) begin
                        req_pc_q <= fetch_pc_i;
                        state_q  <= FETCH_CHECK;
                    end
                end

                FETCH_CHECK: begin
                    logic [3:0] valids;
                    valids = {valid_q[check_set_idx][3], valid_q[check_set_idx][2],
                              valid_q[check_set_idx][1], valid_q[check_set_idx][0]};

                    if (halt_i) begin
                        held_valid_q        <= 1'b0;
                        held_is_hit_q       <= 1'b0;
                        state_q             <= FETCH_REQ;
                        streaming_pf_wait_q <= 1'b0;
                    end else if (redirect_i) begin
                        held_valid_q        <= 1'b0;
                        held_is_hit_q       <= 1'b0;
                        req_pc_q            <= fetch_pc_i;
                        state_q             <= FETCH_CHECK;
                        streaming_pf_wait_q <= 1'b0;
                    end else if (trans_busy_i || !trans_valid_i) begin
                        state_q <= FETCH_CHECK;
                    end else if (fault_condition) begin
                        if (fetched_ready_i) begin
                            if (fetch_enable_i) begin
                                req_pc_q <= fetch_pc_i;
                                state_q  <= FETCH_CHECK;
                            end else begin
                                state_q  <= FETCH_REQ;
                            end
                        end else begin
                            held_valid_q      <= 1'b1;
                            held_pc_q         <= req_pc_q;
                            held_insn_q       <= 32'd0;
                            held_error_q      <= 1'b1;
                            held_page_fault_q <= trans_page_fault_i;
                            held_is_hit_q     <= 1'b0;
                            state_q           <= FETCH_HOLD;
                        end
                    end else if (hit_condition) begin
                        // Main L1I Cache Hit!
                        plru_q[check_set_idx] <= plru_update(plru_q[check_set_idx], hit_way);
                        streaming_wait_beat_q <= 1'b0;
                        streaming_pf_wait_q   <= 1'b0;
                        if (pfb_line_match) begin
                            pfb_valid_q    <= 1'b0;
                            pfb_complete_q <= 1'b0;
                        end

                        if (fetched_ready_i) begin
                            if (fetch_enable_i) begin
                                req_pc_q <= fetch_pc_i;
                                state_q  <= FETCH_CHECK;
                            end else begin
                                state_q  <= FETCH_REQ;
                            end
                        end else begin
                            held_valid_q      <= 1'b1;
                            held_pc_q         <= req_pc_q;
                            held_insn_q       <= hit_insn;
                            held_error_q      <= 1'b0;
                            held_page_fault_q <= 1'b0;
                            held_is_hit_q     <= 1'b1;
                            state_q           <= FETCH_HOLD;
                        end
                    // ---------------------------------------------------------
                    // PFB Hit & Collision Handling (P0-1 Deadlock Resolution)
                    // ---------------------------------------------------------
                    end else if (pfb_complete_hit) begin
                        // Case 1: Hit in Completed PFB (1-cycle hit + atomic L1I promotion)
                        logic [1:0] prom_victim;
                        if (tag_matched) begin
                            prom_victim = hit_way;
                        end else begin
                            prom_victim = plru_victim(plru_q[check_set_idx], valids);
                        end

                        // Directory and Data Array Promotion
                        valid_q[check_set_idx][prom_victim] <= 1'b1;
                        tag_q[check_set_idx][prom_victim]   <= check_pa_tag;
                        for (int b = 0; b < 8; b++) begin
                            data_q[check_set_idx][prom_victim][b] <= pfb_data_q[b];
                        end
                        plru_q[check_set_idx] <= plru_update(plru_q[check_set_idx], prom_victim);

                        pfb_valid_q           <= 1'b0;
                        pfb_complete_q        <= 1'b0;
                        streaming_wait_beat_q <= 1'b0;
                        streaming_pf_wait_q   <= 1'b0;

                        l1i_nlp_promote_pulse_q    <= 1'b1;
                        l1i_nlp_useful_hit_pulse_q <= 1'b1;
                        l1i_nlp_hidden_cycles_q    <= 5'd18;

                        if (fetched_ready_i) begin
                            // Insert deterministic 1-cycle frontend promotion bubble (P1-1)
                            promotion_bubble_q <= 1'b1;
                            req_pc_q           <= fetch_pc_i;
                            state_q            <= FETCH_REQ;
                        end else begin
                            held_valid_q      <= 1'b1;
                            held_pc_q         <= req_pc_q;
                            held_insn_q       <= pfb_hit_insn;
                            held_error_q      <= 1'b0;
                            held_page_fault_q <= 1'b0;
                            held_is_hit_q     <= 1'b1;
                            state_q           <= FETCH_HOLD;
                        end
                    end else if (pfb_active_arrived_hit) begin
                        // Case 2: Hit in Active PFB (Early Restart from arrived beat)
                        streaming_wait_beat_q         <= 1'b0;
                        streaming_pf_wait_q           <= 1'b0;
                        l1i_nlp_streaming_hit_pulse_q <= 1'b1;
                        if (fetched_ready_i) begin
                            req_pc_q <= fetch_pc_i;
                            state_q  <= fetch_enable_i ? FETCH_CHECK : FETCH_REQ;
                        end else begin
                            held_valid_q      <= 1'b1;
                            held_pc_q         <= req_pc_q;
                            held_insn_q       <= pfb_hit_insn;
                            held_error_q      <= 1'b0;
                            held_page_fault_q <= 1'b0;
                            held_is_hit_q     <= 1'b1;
                            state_q           <= FETCH_HOLD;
                        end
                    end else if (pfb_active_pending) begin
                        // Case 3: Streaming wait on active prefetch producer
                        held_pc_q             <= req_pc_q;
                        held_valid_q          <= 1'b0;
                        streaming_wait_beat_q <= 1'b1;
                        streaming_pf_wait_q   <= 1'b1;
                    end else if (pfb_dormant_valid_hit) begin
                        // Case 5: Hit in Dormant Partial PFB (Demanded beat valid)
                        streaming_wait_beat_q         <= 1'b0;
                        streaming_pf_wait_q           <= 1'b0;
                        l1i_nlp_streaming_hit_pulse_q <= 1'b1;
                        if (fetched_ready_i) begin
                            req_pc_q <= fetch_pc_i;
                            state_q  <= fetch_enable_i ? FETCH_CHECK : FETCH_REQ;
                        end else begin
                            held_valid_q      <= 1'b1;
                            held_pc_q         <= req_pc_q;
                            held_insn_q       <= pfb_hit_insn;
                            held_error_q      <= 1'b0;
                            held_page_fault_q <= 1'b0;
                            held_is_hit_q     <= 1'b1;
                            state_q           <= FETCH_HOLD;
                        end
                    end else if (miss_condition) begin
                        // Case 4 (if dormant missing) or standard miss: launch authoritative demand refill
                        if (pfb_dormant_missing) begin
                            pfb_valid_q                     <= 1'b0;
                            l1i_nlp_dormant_abandon_pulse_q <= 1'b1;
                        end

                        refill_line_base      <= {trans_pa_i[55:6], 6'b000000};
                        refill_set_idx        <= check_set_idx;
                        refill_tag            <= check_pa_tag;
                        refill_victim         <= plru_victim(plru_q[check_set_idx], valids);
                        refill_target_word    <= check_word;
                        refill_pmp_allow_q    <= trans_pmp_allow_i;
                        refill_pmp_uniform_x_q<= trans_pmp_uniform_x_i;
                        refill_beat_cnt       <= 3'd0;
                        refill_buf_q          <= '{default: '0};
                        refill_beat_valid_q   <= 8'd0;
                        refill_beat_error_q   <= 8'd0;
                        line_has_error_q      <= 1'b0;
                        refill_abort_q        <= 1'b0;
                        refill_error_q        <= 1'b0;
                        early_restarted_q     <= 1'b0;
                        streaming_wait_beat_q <= 1'b0;
                        streaming_exit_wait_q <= 1'b0;
                        streaming_pf_wait_q   <= 1'b0;
                        redirect_pending_q    <= 1'b0;
                        pending_redirect_pc_q <= 64'd0;
                        held_valid_q          <= 1'b0;
                        held_is_hit_q         <= 1'b0;
                        state_q               <= REFILL_REQ;
                    end
                end

                FETCH_HOLD: begin
                    if (halt_i) begin
                        held_valid_q        <= 1'b0;
                        held_is_hit_q       <= 1'b0;
                        state_q             <= FETCH_REQ;
                        streaming_pf_wait_q <= 1'b0;
                    end else if (redirect_i) begin
                        held_valid_q        <= 1'b0;
                        held_is_hit_q       <= 1'b0;
                        req_pc_q            <= fetch_pc_i;
                        state_q             <= FETCH_CHECK;
                        streaming_pf_wait_q <= 1'b0;
                    end else if (fetched_ready_i) begin
                        held_valid_q  <= 1'b0;
                        held_is_hit_q <= 1'b0;
                        if (fetch_enable_i) begin
                            req_pc_q <= fetch_pc_i;
                            state_q  <= FETCH_CHECK;
                        end else begin
                            state_q  <= FETCH_REQ;
                        end
                    end
                end

                REFILL_REQ: begin
                    if (held_valid_q && !redirect_i && !fence_i_flush_i && !pmp_flush_i && !refill_abort_q) begin
                        if (fetched_ready_i) begin
                            if (fetch_in_active_line) begin
                                if (refill_beat_valid_q[b_next]) begin
                                    held_valid_q          <= 1'b1;
                                    held_pc_q             <= fetch_pc_i;
                                    held_error_q          <= refill_beat_error_q[b_next];
                                    held_insn_q           <= refill_beat_error_q[b_next] ? 32'd0 : (s_next ? refill_buf_q[b_next][63:32] : refill_buf_q[b_next][31:0]);
                                    streaming_wait_beat_q <= 1'b0;
                                    streaming_hit_pulse_q <= 1'b1;
                                end else begin
                                    held_valid_q          <= 1'b0;
                                    held_pc_q             <= fetch_pc_i;
                                    streaming_wait_beat_q <= 1'b1;
                                end
                            end else begin
                                held_valid_q          <= 1'b0;
                                req_pc_q              <= fetch_pc_i;
                                streaming_exit_wait_q <= 1'b1;
                            end
                        end
                    end

                    if (imem_req_ready_i) begin
                        state_q <= REFILL_RSP;
                    end
                end

                REFILL_RSP: begin
                    if (imem_rsp_valid_i) begin
                        refill_buf_q[refill_beat_cnt]        <= imem_rsp_data_i;
                        refill_beat_valid_q[refill_beat_cnt] <= 1'b1;
                        refill_beat_error_q[refill_beat_cnt] <= imem_rsp_error_i;
                        if (imem_rsp_error_i) begin
                            refill_error_q   <= 1'b1;
                            line_has_error_q <= 1'b1;
                        end

                        if (halt_i) begin
                            refill_abort_q        <= 1'b0;
                            early_restarted_q     <= 1'b0;
                            streaming_wait_beat_q <= 1'b0;
                            streaming_exit_wait_q <= 1'b0;
                            held_valid_q          <= 1'b0;
                            held_is_hit_q         <= 1'b0;
                            redirect_pending_q    <= 1'b0;
                            state_q               <= FETCH_REQ;
                        end else if (refill_beat_cnt == 3'd7) begin
                            if (refill_abort_q || redirect_i || fence_i_flush_i || pmp_flush_i) begin
                                refill_abort_q        <= 1'b0;
                                early_restarted_q     <= 1'b0;
                                streaming_wait_beat_q <= 1'b0;
                                streaming_exit_wait_q <= 1'b0;
                                held_valid_q          <= 1'b0;
                                held_is_hit_q         <= 1'b0;
                                if (redirect_i) begin
                                    req_pc_q <= fetch_pc_i;
                                end else if (redirect_pending_q) begin
                                    req_pc_q <= pending_redirect_pc_q;
                                end
                                redirect_pending_q <= 1'b0;
                                state_q            <= FETCH_CHECK;
                            end else if (line_has_error_q || imem_rsp_error_i) begin
                                refill_abort_q        <= 1'b0;
                                early_restarted_q     <= 1'b0;
                                streaming_wait_beat_q <= 1'b0;
                                streaming_exit_wait_q <= 1'b0;
                                if (b_crit == 3'd7 && !early_restarted_q) begin
                                    held_valid_q      <= 1'b1;
                                    held_pc_q         <= req_pc_q;
                                    held_insn_q       <= 32'd0;
                                    held_error_q      <= 1'b1;
                                    held_page_fault_q <= 1'b0;
                                    held_is_hit_q     <= 1'b0;
                                    state_q           <= FETCH_HOLD;
                                end else if (held_valid_q && !fetched_ready_i) begin
                                    state_q <= FETCH_HOLD;
                                end else begin
                                    held_valid_q <= 1'b0;
                                    req_pc_q     <= fetch_pc_i;
                                    state_q      <= FETCH_CHECK;
                                end
                            end else begin
                                // Clean Refill Installation & PLRU update
                                valid_q[refill_set_idx][refill_victim] <= 1'b1;
                                tag_q[refill_set_idx][refill_victim]   <= refill_tag;
                                for (int b = 0; b < 7; b++) begin
                                    data_q[refill_set_idx][refill_victim][b] <= refill_buf_q[b];
                                end
                                data_q[refill_set_idx][refill_victim][7] <= imem_rsp_data_i;
                                plru_q[refill_set_idx] <= plru_update(plru_q[refill_set_idx], refill_victim);

                                if (!early_restarted_q) begin
                                    early_restarted_q     <= 1'b0;
                                    early_restart_pulse_q <= 1'b1;
                                    if (fetched_ready_i) begin
                                        held_valid_q <= 1'b0;
                                        req_pc_q     <= fetch_pc_i;
                                        state_q      <= fetch_enable_i ? FETCH_CHECK : FETCH_REQ;
                                    end else begin
                                        held_valid_q      <= 1'b1;
                                        held_pc_q         <= req_pc_q;
                                        held_insn_q       <= s_crit ? imem_rsp_data_i[63:32] : imem_rsp_data_i[31:0];
                                        held_error_q      <= 1'b0;
                                        held_page_fault_q <= 1'b0;
                                        held_is_hit_q     <= 1'b0;
                                        state_q           <= FETCH_HOLD;
                                    end
                                end else begin
                                    early_restarted_q <= 1'b0;
                                    if (held_valid_q && !fetched_ready_i) begin
                                        state_q <= FETCH_HOLD;
                                    end else if (streaming_wait_beat_q && (held_pc_q[5:3] == 3'd7)) begin
                                        streaming_wait_beat_q <= 1'b0;
                                        if (fetched_ready_i) begin
                                            held_valid_q <= 1'b0;
                                            req_pc_q     <= fetch_pc_i;
                                            state_q      <= FETCH_CHECK;
                                        end else begin
                                            held_valid_q      <= 1'b1;
                                            held_pc_q         <= held_pc_q;
                                            held_insn_q       <= held_pc_q[2] ? imem_rsp_data_i[63:32] : imem_rsp_data_i[31:0];
                                            held_error_q      <= 1'b0;
                                            held_page_fault_q <= 1'b0;
                                            held_is_hit_q     <= 1'b1;
                                            state_q           <= FETCH_HOLD;
                                        end
                                    end else begin
                                        held_valid_q          <= 1'b0;
                                        streaming_wait_beat_q <= 1'b0;
                                        streaming_exit_wait_q <= 1'b0;
                                        req_pc_q              <= fetch_pc_i;
                                        state_q               <= FETCH_CHECK;
                                    end
                                end
                            end
                        end else begin
                            refill_beat_cnt <= refill_beat_cnt + 3'd1;
                            state_q         <= REFILL_REQ;

                            if (!refill_abort_q && !redirect_i && !fence_i_flush_i && !pmp_flush_i) begin
                                if (!early_restarted_q && (refill_beat_cnt == b_crit)) begin
                                    early_restarted_q     <= 1'b1;
                                    early_restart_pulse_q <= 1'b1;
                                    held_valid_q          <= 1'b1;
                                    held_pc_q             <= req_pc_q;
                                    held_page_fault_q     <= 1'b0;
                                    held_is_hit_q         <= 1'b0;
                                    if (imem_rsp_error_i) begin
                                        held_error_q <= 1'b1;
                                        held_insn_q  <= 32'd0;
                                    end else begin
                                        held_error_q <= 1'b0;
                                        held_insn_q  <= s_crit ? imem_rsp_data_i[63:32] : imem_rsp_data_i[31:0];
                                    end
                                end else if (streaming_wait_beat_q && (held_pc_q[5:3] == refill_beat_cnt)) begin
                                    streaming_wait_beat_q <= 1'b0;
                                    held_valid_q          <= 1'b1;
                                    held_page_fault_q     <= 1'b0;
                                    held_is_hit_q         <= 1'b0;
                                    if (imem_rsp_error_i) begin
                                        held_error_q <= 1'b1;
                                        held_insn_q  <= 32'd0;
                                    end else begin
                                        held_error_q <= 1'b0;
                                        held_insn_q  <= held_pc_q[2] ? imem_rsp_data_i[63:32] : imem_rsp_data_i[31:0];
                                    end
                                end else if (held_valid_q) begin
                                    if (fetched_ready_i) begin
                                        if (fetch_in_active_line) begin
                                            if (refill_beat_cnt == b_next) begin
                                                held_valid_q          <= 1'b1;
                                                held_pc_q             <= fetch_pc_i;
                                                held_error_q          <= imem_rsp_error_i;
                                                held_insn_q           <= imem_rsp_error_i ? 32'd0 : (s_next ? imem_rsp_data_i[63:32] : imem_rsp_data_i[31:0]);
                                                streaming_wait_beat_q <= 1'b0;
                                                streaming_hit_pulse_q <= 1'b1;
                                            end else if (refill_beat_valid_q[b_next]) begin
                                                held_valid_q          <= 1'b1;
                                                held_pc_q             <= fetch_pc_i;
                                                held_error_q          <= refill_beat_error_q[b_next];
                                                held_insn_q           <= refill_beat_error_q[b_next] ? 32'd0 : (s_next ? refill_buf_q[b_next][63:32] : refill_buf_q[b_next][31:0]);
                                                streaming_wait_beat_q <= 1'b0;
                                                streaming_hit_pulse_q <= 1'b1;
                                            end else begin
                                                held_valid_q          <= 1'b0;
                                                held_pc_q             <= fetch_pc_i;
                                                streaming_wait_beat_q <= 1'b1;
                                            end
                                        end else begin
                                            held_valid_q          <= 1'b0;
                                            req_pc_q              <= fetch_pc_i;
                                            streaming_exit_wait_q <= 1'b1;
                                        end
                                    end
                                end
                            end
                        end
                    end else begin
                        if (held_valid_q && !redirect_i && !fence_i_flush_i && !pmp_flush_i && !refill_abort_q) begin
                            if (fetched_ready_i) begin
                                if (fetch_in_active_line) begin
                                    if (refill_beat_valid_q[b_next]) begin
                                        held_valid_q          <= 1'b1;
                                        held_pc_q             <= fetch_pc_i;
                                        held_error_q          <= refill_beat_error_q[b_next];
                                        held_insn_q           <= refill_beat_error_q[b_next] ? 32'd0 : (s_next ? refill_buf_q[b_next][63:32] : refill_buf_q[b_next][31:0]);
                                        streaming_wait_beat_q <= 1'b0;
                                        streaming_hit_pulse_q <= 1'b1;
                                    end else begin
                                        held_valid_q          <= 1'b0;
                                        held_pc_q             <= fetch_pc_i;
                                        streaming_wait_beat_q <= 1'b1;
                                    end
                                end else begin
                                    held_valid_q          <= 1'b0;
                                    req_pc_q              <= fetch_pc_i;
                                    streaming_exit_wait_q <= 1'b1;
                                end
                            end
                        end
                    end
                end

                default: state_q <= FETCH_REQ;
            endcase
        end
    end

endmodule
`endif
