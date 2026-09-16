`ifndef FURSOY_S0_SB_SV
`define FURSOY_S0_SB_SV

// =============================================================================
// Fursoy Slice-0 Store Buffer (SB) Module — v1
// =============================================================================
// 4-Entry Circular FIFO Store Buffer with:
// - Tail-only unissued doubleword write merging (P0-1)
// - Immediate reservation invalidation at enqueue (P0-2)
// - Continuous RAW hazard participation until positive L1D application (P0-3)
// - Deterministic starvation-bounded L1D arbitration (P1-1)
// - Strict non-buffered SC synchronization (P1-2)
// - Complete serialization drain integration (P1-3)
// =============================================================================

module fursoy_s0_sb #(
    parameter int unsigned SB_DEPTH = 8
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // -------------------------------------------------------------------------
    // Stage E Store Enqueue Interface
    // -------------------------------------------------------------------------
    input  logic        enqueue_valid_i,
    input  logic [55:0] enqueue_pa_i,
    input  logic [2:0]  enqueue_size_i,
    input  logic [63:0] enqueue_data_i,
    input  logic [4:0]  enqueue_rd_i,
    input  logic [63:0] enqueue_pc_i,
    input  logic [31:0] enqueue_insn_i,
    output logic        enqueue_stall_o,
    output logic        retire_valid_o,

    // Reservation Invalidation on Enqueue (P0-2)
    input  logic        res_valid_i,
    input  logic [49:0] res_granule_pa_i,
    output logic        res_invalidate_o,

    // -------------------------------------------------------------------------
    // Stage E Load RAW Hazard Detection Interface
    // -------------------------------------------------------------------------
    input  logic        load_check_valid_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [55:0] load_check_pa_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic        load_raw_hazard_o /* verilator public_flat_rd */,

    // -------------------------------------------------------------------------
    // L1D Drain Interface
    // -------------------------------------------------------------------------
    input  logic        l1d_idle_i,
    output logic        drain_req_valid_o,
    output logic [55:0] drain_pa_o,
    output logic [63:0] drain_data_o,
    output logic [7:0]  drain_byte_mask_o,
    output logic [2:0]  drain_size_o,
    output logic [4:0]  drain_rd_o,
    output logic [63:0] drain_pc_o,
    output logic [31:0] drain_insn_o,
    input  logic        l1d_store_ack_i,

    // -------------------------------------------------------------------------
    // Arbitration Interface (P1-1)
    // -------------------------------------------------------------------------
    input  logic        stage_e_load_req_i,
    output logic        grant_sb_drain_o,
    output logic        grant_stage_e_load_o /* verilator public_flat_rd */,

    // -------------------------------------------------------------------------
    // Status and Serialization
    // -------------------------------------------------------------------------
    output logic        sb_empty_o,
    output logic        sb_full_o,
    output logic [3:0]  sb_count_o /* verilator public_flat_rd */,
    output logic [2:0]  sb_starve_count_o /* verilator public_flat_rd */,
    output logic        sb_merge_event_o /* verilator public_flat_rd */,

    // -------------------------------------------------------------------------
    // SRB Interlock Interface
    // -------------------------------------------------------------------------
    input  logic        srb_busy_i,
    input  logic [49:0] srb_line_pa_i,
    output logic        srb_raw_hazard_o /* verilator public_flat_rd */
);

    // -------------------------------------------------------------------------
    // Storage Elements
    // -------------------------------------------------------------------------
    logic        valid_q    [SB_DEPTH];
    logic        issued_q   [SB_DEPTH]; // 1 if presented to L1D, immutable (P0-1)
    logic [52:0] paddr_q    [SB_DEPTH]; // PA[55:3]
    logic [63:0] data_q     [SB_DEPTH]; // 64-bit aligned doubleword
    logic [7:0]  byte_mask_q[SB_DEPTH]; // Active byte mask
    logic [2:0]  size_q     [SB_DEPTH];
    logic [4:0]  rd_q       [SB_DEPTH];
    logic [63:0] pc_q       [SB_DEPTH];
    logic [31:0] insn_q     [SB_DEPTH];

    logic [2:0]  head_q;
    logic [2:0]  tail_q;
    logic [3:0]  count_q;
    logic [2:0]  starve_count_q;

    assign sb_count_o        = count_q;
    assign sb_empty_o        = (count_q == 4'd0);
    assign sb_full_o         = (count_q == 4'd8);
    assign sb_starve_count_o = starve_count_q;

    // -------------------------------------------------------------------------
    // Helper Functions: Byte Mask & Data Formatting
    // -------------------------------------------------------------------------
    function automatic logic [7:0] calc_byte_mask(
        input logic [2:0] byte_off,
        input logic [2:0] size
    );
        case (size)
            3'd0: calc_byte_mask = 8'b0000_0001 << byte_off;
            3'd1: calc_byte_mask = 8'b0000_0011 << (byte_off[2:1]*2);
            3'd2: calc_byte_mask = byte_off[2] ? 8'b1111_0000 : 8'b0000_1111;
            default: calc_byte_mask = 8'b1111_1111;
        endcase
    endfunction

    function automatic logic [63:0] format_store_data(
        input logic [63:0] raw_sdata,
        input logic [2:0]  byte_off,
        input logic [2:0]  size
    );
        logic [63:0] res;
        res = '0;
        case (size)
            3'd0: res[byte_off*8 +: 8] = raw_sdata[7:0];
            3'd1: res[(byte_off[2:1]*2)*8 +: 16] = raw_sdata[15:0];
            3'd2: res[(byte_off[2]*4)*8 +: 32] = raw_sdata[31:0];
            default: res = raw_sdata;
        endcase
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
    // Enqueue & Merge Decode (P0-1)
    // -------------------------------------------------------------------------
    wire [2:0]  tail_prev_idx = tail_q - 3'd1;
    wire [7:0]  in_byte_mask  = calc_byte_mask(enqueue_pa_i[2:0], enqueue_size_i);
    wire [63:0] in_fmt_data   = format_store_data(enqueue_data_i, enqueue_pa_i[2:0], enqueue_size_i);

    // Forward declaration of grant_sb_drain_o logic
    wire sb_drain_eligible = (count_q > 4'd0) && l1d_idle_i && !srb_busy_i;
    logic load_raw_hazard_comb;
    logic sb_raw_hazard_comb;
    wire load_eligible     = stage_e_load_req_i && !load_raw_hazard_comb && l1d_idle_i;
    wire arb_force_sb      = (count_q == 4'd8) || (starve_count_q >= 3'd4) || sb_raw_hazard_comb;
    wire sb_drain_granted  = sb_drain_eligible && (!load_eligible || arb_force_sb);

    // Strict tail-only unissued merge condition:
    // 1. Buffer not empty
    // 2. Tail entry valid
    // 3. Tail entry has NEVER been issued/presented to L1D (!issued_q)
    // 4. Tail entry is NOT currently granted/selected for drain on this cycle
    // 5. Exact 8-byte aligned doubleword match (PA[55:3])
    wire can_merge_tail = (count_q > 4'd0) &&
                          valid_q[tail_prev_idx] &&
                          !issued_q[tail_prev_idx] &&
                          !(sb_drain_granted && (tail_prev_idx == head_q)) &&
                          (paddr_q[tail_prev_idx] == enqueue_pa_i[55:3]);

    assign sb_merge_event_o = enqueue_valid_i && can_merge_tail;

    // Buffer full stall: full AND cannot merge into tail
    assign enqueue_stall_o = (count_q == 4'd8) && !can_merge_tail;
    assign retire_valid_o  = enqueue_valid_i && !enqueue_stall_o;

    // -------------------------------------------------------------------------
    // Immediate Reservation Invalidation (P0-2)
    // -------------------------------------------------------------------------
    // Cleared at Stage E enqueue/retirement, NEVER deferred to drain
    assign res_invalidate_o = enqueue_valid_i && !enqueue_stall_o && res_valid_i &&
                              (enqueue_pa_i[55:6] == res_granule_pa_i);

    // -------------------------------------------------------------------------
    // Continuous Load RAW Hazard Detection (SB Doubleword + SRB Full-Line)
    // -------------------------------------------------------------------------
    logic [SB_DEPTH-1:0] raw_match_vec;
    always_comb begin
        for (int i = 0; i < SB_DEPTH; i++) begin
            raw_match_vec[i] = valid_q[i] && (paddr_q[i] == load_check_pa_i[55:3]);
        end
    end
    assign sb_raw_hazard_comb   = load_check_valid_i && (|raw_match_vec);
    wire srb_raw_hazard_comb    = load_check_valid_i && srb_busy_i && (load_check_pa_i[55:6] == srb_line_pa_i);
    assign srb_raw_hazard_o     = srb_raw_hazard_comb;
    assign load_raw_hazard_comb = sb_raw_hazard_comb || srb_raw_hazard_comb;
    assign load_raw_hazard_o    = load_raw_hazard_comb;

    // -------------------------------------------------------------------------
    // Deterministic Single-Port L1D Arbitration (P1-1)
    // -------------------------------------------------------------------------
    assign grant_sb_drain_o     = sb_drain_granted;
    assign grant_stage_e_load_o = load_eligible && !grant_sb_drain_o;
    // Drain Port to L1D
    assign drain_req_valid_o = grant_sb_drain_o;
    assign drain_pa_o        = {paddr_q[head_q], 3'b000};
    assign drain_data_o      = data_q[head_q];
    assign drain_byte_mask_o = byte_mask_q[head_q];
    assign drain_size_o      = size_q[head_q];
    assign drain_rd_o        = rd_q[head_q];
    assign drain_pc_o        = pc_q[head_q];
    assign drain_insn_o      = insn_q[head_q];

    // -------------------------------------------------------------------------
    // Sequential State Update
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            head_q         <= 3'd0;
            tail_q         <= 3'd0;
            count_q        <= 4'd0;
            starve_count_q <= 3'd0;
            for (int i = 0; i < SB_DEPTH; i++) begin
                valid_q[i]     <= 1'b0;
                issued_q[i]    <= 1'b0;
                paddr_q[i]     <= '0;
                data_q[i]      <= '0;
                byte_mask_q[i] <= '0;
                size_q[i]      <= '0;
                rd_q[i]        <= '0;
                pc_q[i]        <= '0;
                insn_q[i]      <= '0;
            end
        end else begin
            // -----------------------------------------------------------------
            // 1. Arbitration Starvation Counter (P1-1)
            // -----------------------------------------------------------------
            if (grant_sb_drain_o || (count_q == 4'd0)) begin
                starve_count_q <= 3'd0;
            end else if (sb_drain_eligible && grant_stage_e_load_o) begin
                if (starve_count_q < 3'd4) begin
                    starve_count_q <= starve_count_q + 3'd1;
                end
            end

            // -----------------------------------------------------------------
            // 2. Drain Issue Tracking (P0-1)
            // -----------------------------------------------------------------
            // Mark head entry as issued when presented to L1D
            if (grant_sb_drain_o) begin
                issued_q[head_q] <= 1'b1;
            end

            // -----------------------------------------------------------------
            // 3. Deallocation / Pop on Positive Acknowledgement (P0-3)
            // -----------------------------------------------------------------
            if (l1d_store_ack_i) begin
                valid_q[head_q]  <= 1'b0;
                issued_q[head_q] <= 1'b0;
                head_q           <= head_q + 3'd1;
            end

            // -----------------------------------------------------------------
            // 4. Enqueue / Tail-Merge Logic (P0-1)
            // -----------------------------------------------------------------
            if (enqueue_valid_i && !enqueue_stall_o) begin
                if (can_merge_tail) begin
                    // Younger-byte overwrite precedence per P0-1
                    data_q[tail_prev_idx]      <= apply_byte_mask(data_q[tail_prev_idx], in_fmt_data, in_byte_mask);
                    byte_mask_q[tail_prev_idx] <= byte_mask_q[tail_prev_idx] | in_byte_mask;
                    // Tail pointer and count remain unchanged on merge (unless pop occurs)
                    if (l1d_store_ack_i) begin
                        count_q <= count_q - 4'd1;
                    end
                end else begin
                    // Allocate new entry at tail
                    valid_q[tail_q]     <= 1'b1;
                    issued_q[tail_q]    <= 1'b0;
                    paddr_q[tail_q]     <= enqueue_pa_i[55:3];
                    data_q[tail_q]      <= in_fmt_data;
                    byte_mask_q[tail_q] <= in_byte_mask;
                    size_q[tail_q]      <= enqueue_size_i;
                    rd_q[tail_q]        <= enqueue_rd_i;
                    pc_q[tail_q]        <= enqueue_pc_i;
                    insn_q[tail_q]      <= enqueue_insn_i;
                    tail_q              <= tail_q + 3'd1;

                    // Occupancy tracking with concurrent pop
                    if (!l1d_store_ack_i) begin
                        count_q <= count_q + 4'd1;
                    end
                end
            end else if (l1d_store_ack_i) begin
                // Pop only
                count_q <= count_q - 4'd1;
            end
        end
    end

endmodule

`endif // FURSOY_S0_SB_SV
