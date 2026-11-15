`ifndef FURSOY_S1_FETCH_QUEUE_SV
`define FURSOY_S1_FETCH_QUEUE_SV

// =============================================================================
// Fursoy Slice-1 Decoupled Fetch Queue FIFO (16 Entries) — Milestone 5 Phase B2
// =============================================================================
// Buffers instruction supply from frontend stages (F0-F3) to Stage D0 Decode.
// Features:
// - 16-entry circular FIFO with wrap-safe modulo-16 pointers.
// - Up to 2 enqueues / cycle (Slot 0 and Slot 1 from Stage F3).
// - Up to 2 dequeues / cycle (Slot 0 and Slot 1 to Stage D0).
// - Support for partial enqueue (1 uop when 1 slot free) and partial dequeue.
// - Full metadata preservation (carried pre_branch_ghr, compact RAS undo checkpoint, exceptions).
// - Single-cycle synchronous clear on pipeline flush / redirect.
// Reference: docs/architecture/slice1-m5-performance-v1.md Section 7.2
// =============================================================================

`include "fursoy_s1_pkg.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_fetch_queue
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic              flush_i,              // Flush / redirect clear

    // -------------------------------------------------------------------------
    // Enqueue Interface (from Stage F3)
    // -------------------------------------------------------------------------
    input  logic              push0_valid_i,
    input  fetch_queue_entry_t push0_entry_i,
    input  logic              push1_valid_i,
    input  fetch_queue_entry_t push1_entry_i,
    output logic [1:0]        push_ack_o,           // Number of uops accepted (0, 1, or 2)

    // -------------------------------------------------------------------------
    // Dequeue Interface (to Stage D0 Decode)
    // -------------------------------------------------------------------------
    input  logic              pop0_i,
    input  logic              pop1_i,
    output logic              pop0_valid_o,
    output fetch_queue_entry_t pop0_entry_o,
    output logic              pop1_valid_o,
    output fetch_queue_entry_t pop1_entry_o,

    // Status & Capacity
    output logic              empty_o,
    output logic              full_o,
    output logic [4:0]        count_o,              // 0..16
    output logic [4:0]        free_count_o          // 16 - count
);

    localparam int unsigned DEPTH = FETCH_QUEUE_DEPTH; // 16

    fetch_queue_entry_t queue_mem [DEPTH];
    logic [3:0] head_q;
    logic [3:0] tail_q;
    logic [4:0] count_q; // 0..16

    assign count_o      = count_q;
    assign free_count_o = 5'd16 - count_q;
    assign empty_o      = (count_q == 5'd0);
    assign full_o       = (count_q >= 5'd16);

    // Dequeue outputs
    wire has_one = (count_q >= 5'd1);
    wire has_two = (count_q >= 5'd2);

    wire [3:0] head_plus_1 = head_q + 4'd1;
    wire [3:0] head_plus_2 = head_q + 4'd2;

    assign pop0_valid_o = has_one;
    assign pop0_entry_o = queue_mem[head_q];

    assign pop1_valid_o = has_two;
    assign pop1_entry_o = queue_mem[head_plus_1];

    // Enqueue admission calculation (respecting available capacity, accounting for simultaneous pops)
    wire [1:0] actual_pops = (pop0_i && pop1_i && has_two) ? 2'd2 : (pop0_i && has_one) ? 2'd1 : 2'd0;
    wire [4:0] avail_slots = (5'd16 - count_q) + {3'd0, actual_pops};

    logic do_push0, do_push1;
    always_comb begin
        do_push0 = 1'b0;
        do_push1 = 1'b0;
        push_ack_o = 2'd0;

        if (push0_valid_i && (avail_slots >= 5'd1)) begin
            do_push0   = 1'b1;
            push_ack_o = push_ack_o + 1'b1;
            if (push1_valid_i && (avail_slots >= 5'd2)) begin
                do_push1   = 1'b1;
                push_ack_o = push_ack_o + 1'b1;
            end
        end else if (push1_valid_i && (avail_slots >= 5'd1)) begin
            do_push1   = 1'b1;
            push_ack_o = push_ack_o + 1'b1;
        end
    end

    // Sequential Queue State Management
    wire [3:0] tail_plus_1 = tail_q + 4'd1;
    wire [3:0] tail_plus_2 = tail_q + 4'd2;

    wire [1:0] actual_pushes = (do_push0 ? 2'd1 : 2'd0) + (do_push1 ? 2'd1 : 2'd0);

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_i) begin
            head_q  <= 4'd0;
            tail_q  <= 4'd0;
            count_q <= 5'd0;
            for (int i = 0; i < DEPTH; i++) begin
                queue_mem[i] <= '0;
            end
        end else begin
            // 1. Enqueue data
            if (do_push0 && do_push1) begin
                queue_mem[tail_q]      <= push0_entry_i;
                queue_mem[tail_plus_1] <= push1_entry_i;
            end else if (do_push0) begin
                queue_mem[tail_q]      <= push0_entry_i;
            end else if (do_push1) begin
                queue_mem[tail_q]      <= push1_entry_i;
            end

            // 2. Advance tail pointer
            if (do_push0 && do_push1) begin
                tail_q <= tail_plus_2;
            end else if (do_push0 || do_push1) begin
                tail_q <= tail_plus_1;
            end

            // 3. Advance head pointer
            if (pop0_i && pop1_i && has_two) begin
                head_q <= head_plus_2;
            end else if (pop0_i && has_one) begin
                head_q <= head_plus_1;
            end

            // 4. Update count
            count_q <= count_q + {3'd0, actual_pushes} - {3'd0, actual_pops};
        end
    end

`ifndef SYNTHESIS
    // Queue Invariant Assertion
    always_ff @(posedge clk_i) begin
        if (!rst_i && !flush_i) begin
            assert(count_q <= 5'd16) else $fatal(1, "[FETCH QUEUE ASSERTION FAILED] Count exceeded 16!");
        end
    end
`endif

endmodule

`endif // FURSOY_S1_FETCH_QUEUE_SV
