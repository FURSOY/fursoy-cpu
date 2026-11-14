`ifndef FURSOY_S1_DIVIDER_SV
`define FURSOY_S1_DIVIDER_SV

// =============================================================================
// Fursoy Slice-1 Iterative 64-bit Radix-4 Divider — Milestone 2
// =============================================================================
// Supports RV64M integer division and remainder operations:
// DIV, DIVU, REM, REMU, DIVW, DIVUW, REMW, REMUW.
// Strictly conforms to RISC-V normative corner cases (div-by-zero, overflow)
// with exact 32-bit W-form sign extension.
// Features single-cycle abort upon branch mispredict or flush (divider_cancel_i).
// Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.5.3 & 15
// =============================================================================

module fursoy_s1_divider
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Flush and branch recovery cancel
    input  logic              flush_valid_i,
    input  logic              cancel_i,       // Single-cycle abort from mispredict or flush

    // Issue handshake
    input  logic              issue_valid_i,
    input  uop_subop_t        sub_op_i,
    input  logic [63:0]       op_a_i,
    input  logic [63:0]       op_b_i,
    input  preg_t             pnew_i,
    input  rob_idx_t          rob_idx_i,
    input  rob_epoch_t        rob_epoch_i,

    // Status
    output logic              busy_o,         // Single-occupancy backpressure
    output rob_idx_t          active_rob_idx_o,

    // Output result (to div_buf)
    output logic              out_valid_o,
    output logic [63:0]       out_data_o,
    output preg_t             out_pnew_o,
    output rob_idx_t          out_rob_idx_o,
    output rob_epoch_t        out_rob_epoch_o
);

    // -------------------------------------------------------------------------
    // Operation Decoding
    // -------------------------------------------------------------------------
    wire is_rem = (sub_op_i == DIV_REM)  || (sub_op_i == DIV_REMU) ||
                  (sub_op_i == DIV_REMW) || (sub_op_i == DIV_REMUW);

    wire is_unsigned = (sub_op_i == DIV_DIVU)  || (sub_op_i == DIV_REMU) ||
                       (sub_op_i == DIV_DIVUW) || (sub_op_i == DIV_REMUW);

    wire is_word = (sub_op_i == DIV_DIVW)  || (sub_op_i == DIV_DIVUW) ||
                   (sub_op_i == DIV_REMW)  || (sub_op_i == DIV_REMUW);

    // -------------------------------------------------------------------------
    // Operand Conditioning (W-form 32-bit truncation & sign handling)
    // -------------------------------------------------------------------------
    logic [63:0] effective_a, effective_b;
    always_comb begin
        if (is_word) begin
            if (is_unsigned) begin
                effective_a = {32'd0, op_a_i[31:0]};
                effective_b = {32'd0, op_b_i[31:0]};
            end else begin
                effective_a = {{32{op_a_i[31]}}, op_a_i[31:0]};
                effective_b = {{32{op_b_i[31]}}, op_b_i[31:0]};
            end
        end else begin
            effective_a = op_a_i;
            effective_b = op_b_i;
        end
    end

    // Corner Case Detection
    wire is_div_by_zero = (effective_b == 64'd0);

    wire is_signed_overflow = !is_unsigned &&
        ((!is_word && (effective_a == 64'h8000_0000_0000_0000) && (effective_b == 64'hFFFF_FFFF_FFFF_FFFF)) ||
         (is_word  && (effective_a[31:0] == 32'h8000_0000)      && (effective_b[31:0] == 32'hFFFF_FFFF)));

    // Immediate Corner Case Result Generation
    logic [63:0] corner_res;
    always_comb begin
        corner_res = 64'd0;
        if (is_div_by_zero) begin
            if (is_rem) begin
                if (is_word) begin
                    corner_res = {{32{effective_a[31]}}, effective_a[31:0]};
                end else begin
                    corner_res = effective_a;
                end
            end else begin
                // All division by zero returns all-ones
                // For DIVUW: returns 64'hFFFF_FFFF_FFFF_FFFF (sign-extended 32-bit -1/all-ones)
                corner_res = 64'hFFFF_FFFF_FFFF_FFFF;
            end
        end else if (is_signed_overflow) begin
            if (is_rem) begin
                corner_res = 64'd0;
            end else begin
                if (is_word) begin
                    corner_res = 64'hFFFF_FFFF_8000_0000;
                end else begin
                    corner_res = 64'h8000_0000_0000_0000;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Magnitude Normalization for Unsigned Division Engine
    // -------------------------------------------------------------------------
    wire sign_a = !is_unsigned && effective_a[63];
    wire sign_b = !is_unsigned && effective_b[63];

    wire sign_quot = !is_unsigned && (sign_a ^ sign_b);
    wire sign_rem  = !is_unsigned && sign_a;

    wire [63:0] unsigned_a = sign_a ? (-effective_a) : effective_a;
    wire [63:0] unsigned_b = sign_b ? (-effective_b) : effective_b;

    // -------------------------------------------------------------------------
    // State Machine
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        DIV_IDLE,
        DIV_BUSY,
        DIV_DONE
    } state_t;

    state_t state_q;

    logic [63:0]      q_q;
    logic [63:0]      r_q;
    logic [63:0]      divisor_q;
    logic [5:0]       iter_count_q;

    logic             neg_quot_q;
    logic             neg_rem_q;
    logic             word_q;
    logic             rem_op_q;

    preg_t            cur_pnew_q;
    rob_idx_t         cur_rob_idx_q;
    rob_epoch_t       cur_rob_epoch_q;
    logic [63:0]      final_result_q;

    assign busy_o           = (state_q != DIV_IDLE);
    assign active_rob_idx_o = cur_rob_idx_q;

    // Radix-4 Step Function (computes 2 quotient bits per cycle)
    function automatic void radix4_step(
        inout logic [63:0] rem_val,
        inout logic [63:0] quot_val,
        input logic [63:0] div_val
    );
        // Bit 1 step
        rem_val = {rem_val[62:0], quot_val[63]};
        quot_val = {quot_val[62:0], 1'b0};
        if (rem_val >= div_val) begin
            rem_val = rem_val - div_val;
            quot_val[0] = 1'b1;
        end

        // Bit 0 step
        rem_val = {rem_val[62:0], quot_val[63]};
        quot_val = {quot_val[62:0], 1'b0};
        if (rem_val >= div_val) begin
            rem_val = rem_val - div_val;
            quot_val[0] = 1'b1;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Sequential Engine
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i || cancel_i) begin
            state_q         <= DIV_IDLE;
            q_q             <= 64'd0;
            r_q             <= 64'd0;
            divisor_q       <= 64'd0;
            iter_count_q    <= 6'd0;
            final_result_q  <= 64'd0;
            cur_pnew_q      <= preg_t'(0);
            cur_rob_idx_q   <= '0;
            cur_rob_epoch_q <= '0;
            neg_quot_q      <= 1'b0;
            neg_rem_q       <= 1'b0;
            word_q          <= 1'b0;
            rem_op_q        <= 1'b0;
        end else begin
            case (state_q)
                DIV_IDLE: begin
                    if (issue_valid_i) begin
                        cur_pnew_q      <= pnew_i;
                        cur_rob_idx_q   <= rob_idx_i;
                        cur_rob_epoch_q <= rob_epoch_i;
                        rem_op_q        <= is_rem;
                        word_q          <= is_word;
                        neg_quot_q      <= sign_quot;
                        neg_rem_q       <= sign_rem;

                        if (is_div_by_zero || is_signed_overflow) begin
                            // Fast 1-cycle bypass for corner cases
                            final_result_q <= corner_res;
                            state_q        <= DIV_DONE;
                        end else begin
                            // Normal iterative start
                            q_q          <= unsigned_a;
                            r_q          <= 64'd0;
                            divisor_q    <= unsigned_b;
                            iter_count_q <= 6'd32; // 32 cycles @ 2 bits/cycle = 64 bits
                            state_q      <= DIV_BUSY;
                        end
                    end
                end

                DIV_BUSY: begin
                    logic [63:0] next_r;
                    logic [63:0] next_q;
                    next_r = r_q;
                    next_q = q_q;

                    radix4_step(next_r, next_q, divisor_q);

                    r_q <= next_r;
                    q_q <= next_q;

                    if (iter_count_q == 6'd1) begin
                        // Computation completed, form final result
                        logic [63:0] raw_res;
                        if (rem_op_q) begin
                            raw_res = neg_rem_q ? (-next_r) : next_r;
                        end else begin
                            raw_res = neg_quot_q ? (-next_q) : next_q;
                        end

                        if (word_q) begin
                            final_result_q <= {{32{raw_res[31]}}, raw_res[31:0]};
                        end else begin
                            final_result_q <= raw_res;
                        end
                        state_q <= DIV_DONE;
                    end else begin
                        iter_count_q <= iter_count_q - 6'd1;
                    end
                end

                DIV_DONE: begin
                    // 1-cycle handshake into div_buf
                    state_q <= DIV_IDLE;
                end

                default: state_q <= DIV_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Output Interface
    // -------------------------------------------------------------------------
    assign out_valid_o     = (state_q == DIV_DONE) && !cancel_i && !flush_valid_i;
    assign out_data_o      = final_result_q;
    assign out_pnew_o      = cur_pnew_q;
    assign out_rob_idx_o   = cur_rob_idx_q;
    assign out_rob_epoch_o = cur_rob_epoch_q;

endmodule

`endif // FURSOY_S1_DIVIDER_SV
