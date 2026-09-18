`ifndef FURSOY_S1_PORT1_BUFFERS_SV
`define FURSOY_S1_PORT1_BUFFERS_SV

// =============================================================================
// Fursoy Slice-1 Port 1 Completion Network & Arbiter — Milestone 2
// =============================================================================
// Provably lossless completion buffering for heterogeneous Port 1 execution units:
// - div_buf: 1 entry (single-occupancy divider)
// - mul_fifo: K=3 entries (K-stage multiplier)
// - alu1_fifo: A=2 entries (1-cycle ALU1)
//
// Features:
// - Pre-issue credit accounting preventing buffer overflow under any collision pattern.
// - Deterministic priority arbitration: Divider > Multiplier > ALU1.
// - Wrap-safe squash invalidation and instantaneous credit reclamation.
// Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.6
// =============================================================================

module fursoy_s1_port1_buffers
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Flush and recovery
    input  logic              flush_valid_i,
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  rob_idx_t          rob_head_i,    // In-flight counts from execution pipelines (for credit calculation)
    input  logic [2:0]        mul_in_flight_i,  // Multiplier pipeline occupancy (0..4)
    input  logic [1:0]        alu1_in_flight_i, // ALU1 pipeline occupancy (0..2)
    input  logic              divider_busy_i,

    // Pre-issue credit availability (to IntIQ scheduler)
    output logic              can_issue_mul_o,
    output logic              can_issue_alu1_o,
    output logic              can_issue_div_o,

    // Execution Unit Completion Inputs
    // Divider
    input  logic              div_valid_i,
    input  logic [63:0]       div_data_i,
    input  preg_t             div_pnew_i,
    input  rob_idx_t          div_rob_idx_i,
    input  rob_epoch_t        div_rob_epoch_i,

    // Multiplier
    input  logic              mul_valid_i,
    input  logic [63:0]       mul_data_i,
    input  preg_t             mul_pnew_i,
    input  rob_idx_t          mul_rob_idx_i,
    input  rob_epoch_t        mul_rob_epoch_i,

    // ALU1
    input  logic              alu1_valid_i,
    input  logic [63:0]       alu1_data_i,
    input  preg_t             alu1_pnew_i,
    input  rob_idx_t          alu1_rob_idx_i,
    input  rob_epoch_t        alu1_rob_epoch_i,

    // Writeback Output (to M1 / WB Stage)
    output logic              wb_valid_o,
    output logic [63:0]       wb_data_o,
    output preg_t             wb_pnew_o,
    output rob_idx_t          wb_rob_idx_o,
    output rob_epoch_t        wb_rob_epoch_o
);

    typedef struct packed {
        logic       valid;
        logic [63:0] data;
        preg_t      pnew;
        rob_idx_t   rob_idx;
        rob_epoch_t rob_epoch;
    } buf_entry_t;

    // -------------------------------------------------------------------------
    // 1. Divider Buffer (1 Entry)
    // -------------------------------------------------------------------------
    buf_entry_t div_buf_q;

    wire div_squashed = div_buf_q.valid && recover_valid_i &&
                        (rob_dist(div_buf_q.rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    // -------------------------------------------------------------------------
    // 2. Multiplier FIFO (3 Entries)
    // -------------------------------------------------------------------------
    buf_entry_t mul_q [3];

    // -------------------------------------------------------------------------
    // 3. ALU1 FIFO (3 Entries, A=3 >= 2)
    // -------------------------------------------------------------------------
    buf_entry_t alu1_q [3];

    // -------------------------------------------------------------------------
    // Arbitration & Priority Selection: Divider > Multiplier > ALU1
    // -------------------------------------------------------------------------
    wire div_ready  = div_buf_q.valid;
    wire mul_ready  = mul_q[0].valid;
    wire alu1_ready = alu1_q[0].valid;

    logic div_pop, mul_pop, alu1_pop;

    always_comb begin
        wb_valid_o     = 1'b0;
        wb_data_o      = 64'd0;
        wb_pnew_o      = 7'd0;
        wb_rob_idx_o   = '0;
        wb_rob_epoch_o = '0;
        div_pop        = 1'b0;
        mul_pop        = 1'b0;
        alu1_pop       = 1'b0;

        if (flush_valid_i) begin
            // Output suppressed during flush
        end else if (div_ready) begin
            wb_valid_o     = 1'b1;
            wb_data_o      = div_buf_q.data;
            wb_pnew_o      = div_buf_q.pnew;
            wb_rob_idx_o   = div_buf_q.rob_idx;
            wb_rob_epoch_o = div_buf_q.rob_epoch;
            div_pop        = 1'b1;
        end else if (mul_ready) begin
            wb_valid_o     = 1'b1;
            wb_data_o      = mul_q[0].data;
            wb_pnew_o      = mul_q[0].pnew;
            wb_rob_idx_o   = mul_q[0].rob_idx;
            wb_rob_epoch_o = mul_q[0].rob_epoch;
            mul_pop        = 1'b1;
        end else if (alu1_ready) begin
            wb_valid_o     = 1'b1;
            wb_data_o      = alu1_q[0].data;
            wb_pnew_o      = alu1_q[0].pnew;
            wb_rob_idx_o   = alu1_q[0].rob_idx;
            wb_rob_epoch_o = alu1_q[0].rob_epoch;
            alu1_pop       = 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Pre-Issue Credit Accounting
    // -------------------------------------------------------------------------
    // Free entries in mul_fifo
    logic [2:0] mul_free_cnt;
    always_comb begin
        mul_free_cnt = 3'd0;
        for (int i = 0; i < 3; i++) begin
            if (!mul_q[i].valid) mul_free_cnt = mul_free_cnt + 3'd1;
        end
        // If an entry is being popped this cycle, account for the newly opened slot
        if (mul_pop && (mul_free_cnt < 3'd3)) mul_free_cnt = mul_free_cnt + 3'd1;
    end

    // Free entries in alu1_fifo
    logic [2:0] alu1_free_cnt;
    always_comb begin
        alu1_free_cnt = 3'd0;
        for (int i = 0; i < 3; i++) begin
            if (!alu1_q[i].valid) alu1_free_cnt = alu1_free_cnt + 3'd1;
        end
        if (alu1_pop && (alu1_free_cnt < 3'd3)) alu1_free_cnt = alu1_free_cnt + 3'd1;
    end

    // Pre-issue credit rules:
    assign can_issue_mul_o  = (mul_free_cnt > mul_in_flight_i) && !flush_valid_i;
    assign can_issue_alu1_o = (alu1_free_cnt > {1'b0, alu1_in_flight_i}) && !flush_valid_i;
    assign can_issue_div_o  = !divider_busy_i && !div_buf_q.valid && !div_valid_i && !flush_valid_i;

    wire div_in_squashed = recover_valid_i &&
        (rob_dist(div_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire mul_in_squashed = recover_valid_i &&
        (rob_dist(mul_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));
    wire alu1_in_squashed = recover_valid_i &&
        (rob_dist(alu1_rob_idx_i, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i));

    // -------------------------------------------------------------------------
    // Divider Buffer Update
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            div_buf_q <= '0;
        end else begin
            if (div_pop) begin
                div_buf_q <= '0;
            end else if (div_squashed) begin
                div_buf_q.valid <= 1'b0;
            end

            // New arrival into div_buf
            if (div_valid_i) begin
                if (!div_in_squashed) begin
                    div_buf_q.valid     <= 1'b1;
                    div_buf_q.data      <= div_data_i;
                    div_buf_q.pnew      <= div_pnew_i;
                    div_buf_q.rob_idx   <= div_rob_idx_i;
                    div_buf_q.rob_epoch <= div_rob_epoch_i;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Multiplier FIFO Update (3 Entries, Shift-Register Topology)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            for (int i = 0; i < 3; i++) mul_q[i] <= '0;
        end else begin
            // 1. Squash invalidation of younger entries
            if (recover_valid_i) begin
                for (int i = 0; i < 3; i++) begin
                    if (mul_q[i].valid && (rob_dist(mul_q[i].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        mul_q[i].valid <= 1'b0;
                    end
                end
            end

            // 2. Shift on Pop or Compress Bubbles
            if (mul_pop) begin
                mul_q[0] <= mul_q[1];
                mul_q[1] <= mul_q[2];
                mul_q[2] <= '0;
            end

            // 3. Insert new completed multiplier uop
            if (mul_valid_i) begin
                if (!mul_in_squashed) begin
                    buf_entry_t new_e;
                    new_e.valid     = 1'b1;
                    new_e.data      = mul_data_i;
                    new_e.pnew      = mul_pnew_i;
                    new_e.rob_idx   = mul_rob_idx_i;
                    new_e.rob_epoch = mul_rob_epoch_i;

                    if (mul_pop) begin
                        // Entry was shifting down
                        if (!mul_q[1].valid) begin
                            mul_q[0] <= new_e;
                        end else if (!mul_q[2].valid) begin
                            mul_q[1] <= new_e;
                        end else begin
                            mul_q[2] <= new_e;
                        end
                    end else begin
                        // No pop
                        if (!mul_q[0].valid) begin
                            mul_q[0] <= new_e;
                        end else if (!mul_q[1].valid) begin
                            mul_q[1] <= new_e;
                        end else begin
                            mul_q[2] <= new_e;
                        end
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // ALU1 FIFO Update (3 Entries, Shift-Register Topology)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            for (int i = 0; i < 3; i++) alu1_q[i] <= '0;
        end else begin
            // 1. Squash invalidation of younger entries
            if (recover_valid_i) begin
                for (int i = 0; i < 3; i++) begin
                    if (alu1_q[i].valid && (rob_dist(alu1_q[i].rob_idx, rob_head_i) > rob_dist(recover_rob_idx_i, rob_head_i))) begin
                        alu1_q[i].valid <= 1'b0;
                    end
                end
            end

            // 2. Shift on Pop
            if (alu1_pop) begin
                alu1_q[0] <= alu1_q[1];
                alu1_q[1] <= alu1_q[2];
                alu1_q[2] <= '0;
            end

            // 3. Insert new completed ALU1 uop
            if (alu1_valid_i) begin
                if (!alu1_in_squashed) begin
                    buf_entry_t new_e;
                    new_e.valid     = 1'b1;
                    new_e.data      = alu1_data_i;
                    new_e.pnew      = alu1_pnew_i;
                    new_e.rob_idx   = alu1_rob_idx_i;
                    new_e.rob_epoch = alu1_rob_epoch_i;

                    if (alu1_pop) begin
                        if (!alu1_q[1].valid) begin
                            alu1_q[0] <= new_e;
                        end else if (!alu1_q[2].valid) begin
                            alu1_q[1] <= new_e;
                        end else begin
                            alu1_q[2] <= new_e;
                        end
                    end else begin
                        if (!alu1_q[0].valid) begin
                            alu1_q[0] <= new_e;
                        end else if (!alu1_q[1].valid) begin
                            alu1_q[1] <= new_e;
                        end else begin
                            alu1_q[2] <= new_e;
                        end
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Simulation Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i && !flush_valid_i) begin
            // 1. Multiplier FIFO must never overflow
            if (mul_valid_i && mul_q[0].valid && mul_q[1].valid && mul_q[2].valid && !mul_pop) begin
                $fatal(1, "[PORT1 BUFFER ASSERTION FAILED] mul_fifo overflowed!");
            end
            // 2. ALU1 FIFO must never overflow
            if (alu1_valid_i && alu1_q[0].valid && alu1_q[1].valid && alu1_q[2].valid && !alu1_pop) begin
                $fatal(1, "[PORT1 BUFFER ASSERTION FAILED] alu1_fifo overflowed!");
            end
            // 3. Divider buffer must never overflow
            if (div_valid_i && div_buf_q.valid && !div_pop) begin
                $fatal(1, "[PORT1 BUFFER ASSERTION FAILED] div_buf overflowed!");
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_PORT1_BUFFERS_SV
