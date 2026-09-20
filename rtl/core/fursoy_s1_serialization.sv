`ifndef FURSOY_S1_SERIALIZATION_SV
`define FURSOY_S1_SERIALIZATION_SV

// =============================================================================
// Fursoy Slice-1 System Serialization Controller (FENCE.I) — Milestone 4
// =============================================================================
// Real M4 serialization controller replacing all rejected historical phantom signals.
// Interfaces strictly with frozen M1 ROB and M3 LSU interfaces:
// 1. Captures exact FENCE.I ROB lifetime {fence_i_rob_idx, fence_i_rob_epoch, fence_i_pc}
//    at dispatch/rename from M1 allocation bus.
// 2. Monitors real frozen M1 ROB head interface (head_o, retire_epoch_o[0]).
// 3. Holds retirement by driving frozen retire_ready_o = 1'b0 while FENCE.I is at head.
// 4. Verifies older store quiescence via sq_empty_i.
// 5. Sweeps all dirty L1D lines via cross-milestone dcache_clean_all_req/done handshake.
// 6. Flashes L1I invalidation (l1i_inval_all_o) and purges frontend pipeline & Fetch Queue.
// 7. Releases retirement hold (retire_ready_o = 1'b1) to retire FENCE.I exactly once.
// 8. Redirects frontend fetch to FENCE.I PC + 4.
// Reference: docs/architecture/slice1-m4-frontend-v1.md Section 10.3 & 28
// =============================================================================

`include "fursoy_s1_pkg.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_serialization
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              flush_valid_i,

    // -------------------------------------------------------------------------
    // Allocation Interface (at Rename / Dispatch)
    // -------------------------------------------------------------------------
    input  logic              alloc0_fence_i_i,
    input  rob_idx_t          alloc0_rob_idx_i,
    input  rob_epoch_t        alloc0_rob_epoch_i,
    input  logic [63:0]       alloc0_pc_i,

    input  logic              alloc1_fence_i_i,
    input  rob_idx_t          alloc1_rob_idx_i,
    input  rob_epoch_t        alloc1_rob_epoch_i,
    input  logic [63:0]       alloc1_pc_i,

    // -------------------------------------------------------------------------
    // Real ROB Head & Retirement Monitoring (from frozen M1 ROB)
    // -------------------------------------------------------------------------
    input  rob_idx_t          rob_head_i,
    input  rob_epoch_t        retire_epoch_i,       // retire_epoch_o[0] from ROB
    input  logic              rob_retire_valid_i,   // retire_valid_o[0] from ROB
    output logic              retire_ready_o,       // Driven into ROB retire_ready_i

    // -------------------------------------------------------------------------
    // LSU Store Quiescence Interface (from M3 LSU)
    // -------------------------------------------------------------------------
    input  logic              sq_empty_i,

    // -------------------------------------------------------------------------
    // L1D Clean Maintenance Handshake (from/to M3 L1D)
    // -------------------------------------------------------------------------
    output logic              dcache_clean_all_req_o,
    input  logic              dcache_clean_all_done_i,

    // -------------------------------------------------------------------------
    // Frontend Maintenance & Redirect Outputs
    // -------------------------------------------------------------------------
    output logic              l1i_inval_all_o,
    output logic              frontend_purge_o,
    output logic              redirect_valid_o,
    output logic [63:0]       redirect_target_o,

    // Observability
    output logic              fence_i_active_o,
    output logic              event_fence_i_completed_o
);

    // =========================================================================
    // 1. Tracked FENCE.I Lifetime Registers
    // =========================================================================
    logic        fence_i_pending_q;
    rob_idx_t    fence_i_rob_idx_q;
    rob_epoch_t  fence_i_rob_epoch_q;
    logic [63:0] fence_i_pc_q;

    // FENCE.I detection at ROB head
    wire fence_i_at_head = fence_i_pending_q &&
                          (rob_head_i == fence_i_rob_idx_q) &&
                          (retire_epoch_i == fence_i_rob_epoch_q);

    // =========================================================================
    // 2. Serialization State Machine
    // =========================================================================
    typedef enum logic [2:0] {
        SERIAL_IDLE        = 3'd0,
        SERIAL_WAIT_HEAD   = 3'd1,
        SERIAL_WAIT_SQ     = 3'd2,
        SERIAL_CLEAN_L1D   = 3'd3,
        SERIAL_INVAL_FE    = 3'd4,
        SERIAL_RETIRE_HOLD = 3'd5,
        SERIAL_DONE        = 3'd6
    } serial_state_t;

    serial_state_t serial_state_q;
    assign fence_i_active_o = (serial_state_q != SERIAL_IDLE);

    // Hold retirement while serialization is in progress
    wire fence_i_hold = (fence_i_at_head && (serial_state_q != SERIAL_RETIRE_HOLD)) ||
                        (serial_state_q == SERIAL_WAIT_SQ) ||
                        (serial_state_q == SERIAL_CLEAN_L1D) ||
                        (serial_state_q == SERIAL_INVAL_FE);

    assign retire_ready_o = !fence_i_hold;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            fence_i_pending_q         <= 1'b0;
            fence_i_rob_idx_q         <= '0;
            fence_i_rob_epoch_q       <= '0;
            fence_i_pc_q              <= 64'd0;
            serial_state_q            <= SERIAL_IDLE;
            dcache_clean_all_req_o    <= 1'b0;
            l1i_inval_all_o           <= 1'b0;
            frontend_purge_o          <= 1'b0;
            redirect_valid_o          <= 1'b0;
            redirect_target_o         <= 64'd0;
            event_fence_i_completed_o <= 1'b0;
        end else begin
            redirect_valid_o          <= 1'b0;
            event_fence_i_completed_o <= 1'b0;
            l1i_inval_all_o           <= 1'b0;
            frontend_purge_o          <= 1'b0;

            // Capture allocation token at dispatch/rename
            if (!fence_i_pending_q) begin
                if (alloc0_fence_i_i) begin
                    fence_i_pending_q   <= 1'b1;
                    fence_i_rob_idx_q   <= alloc0_rob_idx_i;
                    fence_i_rob_epoch_q <= alloc0_rob_epoch_i;
                    fence_i_pc_q        <= alloc0_pc_i;
                end else if (alloc1_fence_i_i) begin
                    fence_i_pending_q   <= 1'b1;
                    fence_i_rob_idx_q   <= alloc1_rob_idx_i;
                    fence_i_rob_epoch_q <= alloc1_rob_epoch_i;
                    fence_i_pc_q        <= alloc1_pc_i;
                end
            end

            // Main serialization FSM
            case (serial_state_q)
                SERIAL_IDLE: begin
                    if (fence_i_pending_q) begin
                        serial_state_q <= SERIAL_WAIT_HEAD;
                    end
                end

                SERIAL_WAIT_HEAD: begin
                    if (fence_i_at_head) begin
                        serial_state_q <= SERIAL_WAIT_SQ;
                    end
                end

                SERIAL_WAIT_SQ: begin
                    // Wait until all older stores have drained from Store Queue into L1D
                    if (sq_empty_i) begin
                        dcache_clean_all_req_o <= 1'b1;
                        serial_state_q         <= SERIAL_CLEAN_L1D;
                    end
                end

                SERIAL_CLEAN_L1D: begin
                    if (dcache_clean_all_done_i) begin
                        dcache_clean_all_req_o <= 1'b0;
                        // Trigger L1I flash tag invalidation and frontend pipeline purge
                        l1i_inval_all_o        <= 1'b1;
                        frontend_purge_o       <= 1'b1;
                        serial_state_q         <= SERIAL_INVAL_FE;
                    end
                end

                SERIAL_INVAL_FE: begin
                    // Invalidation complete, release retirement hold
                    serial_state_q <= SERIAL_RETIRE_HOLD;
                end

                SERIAL_RETIRE_HOLD: begin
                    // FENCE.I is retired by ROB head (retire_ready_i was released)
                    if (rob_retire_valid_i) begin
                        fence_i_pending_q         <= 1'b0;
                        redirect_valid_o          <= 1'b1;
                        redirect_target_o         <= fence_i_pc_q + 64'd4;
                        event_fence_i_completed_o <= 1'b1;
                        serial_state_q            <= SERIAL_DONE;
                    end
                end

                SERIAL_DONE: begin
                    serial_state_q <= SERIAL_IDLE;
                end

                default: begin
                    serial_state_q <= SERIAL_IDLE;
                end
            endcase
        end
    end

endmodule

`endif // FURSOY_S1_SERIALIZATION_SV
