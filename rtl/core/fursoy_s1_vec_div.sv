`ifndef FURSOY_S1_VEC_DIV_SV
`define FURSOY_S1_VEC_DIV_SV

// =============================================================================
// Fursoy Slice-1 Iterative Radix-4 Restoring Vector Element Divider — S2.5-M1b
// =============================================================================
// Genuine multi-cycle synthesizable element divider for RVV 1.0 VEC_VDIV and
// VEC_VDIVU across SEW = 8 / 16 / 32 / 64 bits (zero behavioral '/' or '%').
//
// Algorithm:
// - Parallel 3-subtractor Radix-4 restoring division (2 quotient bits/cycle)
//   using shared 66-bit Kogge-Stone subtractors (fursoy_s1_ks_adder) to close
//   500 MHz Nangate45 timing cleanly.
// - Adaptive iteration counts by SEW:
//     * SEW=8:  4 iter cycles (+ 1 setup)
//     * SEW=16: 8 iter cycles (+ 1 setup)
//     * SEW=32: 16 iter cycles (+ 1 setup)
//     * SEW=64: 32 iter cycles (+ 1 setup)
// - Fast 1-cycle corner-case bypass for RVV 1.0 divide-by-zero (all-1s mask)
//   and signed overflow (INT_MIN / -1 = INT_MIN).
// - Clean single-cycle abort on rst_i or flush_i.
// =============================================================================

`include "fursoy_s1_ks_adder.sv"

module fursoy_s1_vec_div (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        flush_i,

    input  logic        start_i,
    input  logic        is_signed_i,
    input  logic [1:0]  sew_i,      // 0=8b, 1=16b, 2=32b, 3=64b
    input  logic [63:0] dividend_i, // vs2 element (zero-extended above SEW)
    input  logic [63:0] divisor_i,  // vs1/rs1 element (zero-extended above SEW)

    output logic        busy_o,
    output logic        done_o,
    output logic [63:0] result_o
);

    typedef enum logic [2:0] {
        VDIV_IDLE = 3'd0,
        VDIV_PREP = 3'd1,
        VDIV_ITER = 3'd2,
        VDIV_SIGN = 3'd3,
        VDIV_DONE = 3'd4
    } vdiv_state_t;

    vdiv_state_t state_q;

    // Input conditioning helpers
    function automatic logic [63:0] sew_mask(input logic [1:0] s);
        case (s)
            2'd0:    return 64'h0000_0000_0000_00FF;
            2'd1:    return 64'h0000_0000_0000_FFFF;
            2'd2:    return 64'h0000_0000_FFFF_FFFF;
            default: return 64'hFFFF_FFFF_FFFF_FFFF;
        endcase
    endfunction

    function automatic logic [63:0] sew_sign_min(input logic [1:0] s);
        case (s)
            2'd0:    return 64'h0000_0000_0000_0080;
            2'd1:    return 64'h0000_0000_0000_8000;
            2'd2:    return 64'h0000_0000_8000_0000;
            default: return 64'h8000_0000_0000_0000;
        endcase
    endfunction

    function automatic logic sew_sign_bit(
        input logic b7, input logic b15, input logic b31, input logic b63,
        input logic [1:0] s
    );
        case (s)
            2'd0:    return b7;
            2'd1:    return b15;
            2'd2:    return b31;
            default: return b63;
        endcase
    endfunction

    // Operand normalization (registered at VDIV_IDLE -> VDIV_PREP)
    wire [63:0] in_mask      = sew_mask(sew_i);
    wire [63:0] in_smin      = sew_sign_min(sew_i);
    wire [63:0] in_num       = dividend_i & in_mask;
    wire [63:0] in_den       = divisor_i  & in_mask;
    wire        in_div_zero  = (in_den == 64'd0);
    wire        in_overflow  = is_signed_i && (in_num == in_smin) && (in_den == in_mask);
    wire        in_sign_n    = is_signed_i && sew_sign_bit(in_num[7], in_num[15], in_num[31], in_num[63], sew_i);
    wire        in_sign_d    = is_signed_i && sew_sign_bit(in_den[7], in_den[15], in_den[31], in_den[63], sew_i);
    wire        in_neg_quot  = in_sign_n ^ in_sign_d;

    // Magnitude via 64-bit Kogge-Stone negation (only needed on signed negative)
    logic [63:0] neg_num_w, neg_den_w;
    fursoy_s1_ks_adder #(.WIDTH(64)) u_neg_num (
        .a_i   (~in_num),
        .b_i   (64'd0),
        .cin_i (1'b1),
        .sum_o (neg_num_w)
    );
    fursoy_s1_ks_adder #(.WIDTH(64)) u_neg_den (
        .a_i   (~in_den),
        .b_i   (64'd0),
        .cin_i (1'b1),
        .sum_o (neg_den_w)
    );

    wire [63:0] mag_num = (in_sign_n ? neg_num_w : in_num) & in_mask;
    wire [63:0] mag_den = (in_sign_d ? neg_den_w : in_den) & in_mask;

    // Left-align dividend into bits [63:0] so MSB is always at bit 63
    logic [63:0] aligned_num;
    logic [5:0]  init_iters;
    always_comb begin
        case (sew_i)
            2'd0: begin aligned_num = {mag_num[7:0],  56'd0}; init_iters = 6'd4;  end
            2'd1: begin aligned_num = {mag_num[15:0], 48'd0}; init_iters = 6'd8;  end
            2'd2: begin aligned_num = {mag_num[31:0], 32'd0}; init_iters = 6'd16; end
            default: begin aligned_num = mag_num;             init_iters = 6'd32; end
        endcase
    end

    // Datapath registers (rem_q < D < 2^64, so 64 bits suffice)
    logic [63:0] rem_q;
    logic [63:0] quot_q;
    logic [65:0] d1_q, d2_q, d3_q;
    logic [5:0]  iter_q;
    logic [1:0]  sew_q;
    logic        neg_quot_q;
    logic [63:0] result_q;

    // Precompute 3 * d1 in VDIV_PREP using 64-bit KS adder + 3-bit carry-select
    logic [63:0] d3_lo_w;
    fursoy_s1_ks_adder #(.WIDTH(64)) u_d3_add_lo (
        .a_i   ({1'b0, d1_q[62:0]}),
        .b_i   ({1'b0, d2_q[62:0]}),
        .cin_i (1'b0),
        .sum_o (d3_lo_w)
    );
    wire [2:0]  d3_hi_c0  = d1_q[65:63] + d2_q[65:63];
    wire [2:0]  d3_hi_c1  = d1_q[65:63] + d2_q[65:63] + 3'd1;
    wire [65:0] d3_prep_w = {(d3_lo_w[63] ? d3_hi_c1 : d3_hi_c0), d3_lo_w[62:0]};

    // Parallel Radix-4 restoring step (2 quotient bits/cycle):
    // rem_sh = {rem_q[63:0], quot_q[63:62]} < 4 * D < 2^66.
    // 67-bit signed subtraction via 64-bit KS adder (low 63b + cout63) + 4-bit
    // carry-select upper slice: bit [66] == 0 means rem_sh >= k*D.
    wire [65:0] rem_sh   = {rem_q, quot_q[63:62]};
    wire [66:0] a67      = {1'b0, rem_sh};
    wire [66:0] b1_67inv = ~{1'b0, d1_q};
    wire [66:0] b2_67inv = ~{1'b0, d2_q};
    wire [66:0] b3_67inv = ~{1'b0, d3_q};

    logic [63:0] sub1_lo_w, sub2_lo_w, sub3_lo_w;
    fursoy_s1_ks_adder #(.WIDTH(64)) u_sub1_lo (
        .a_i   ({1'b0, a67[62:0]}),
        .b_i   ({1'b0, b1_67inv[62:0]}),
        .cin_i (1'b1),
        .sum_o (sub1_lo_w)
    );
    fursoy_s1_ks_adder #(.WIDTH(64)) u_sub2_lo (
        .a_i   ({1'b0, a67[62:0]}),
        .b_i   ({1'b0, b2_67inv[62:0]}),
        .cin_i (1'b1),
        .sum_o (sub2_lo_w)
    );
    fursoy_s1_ks_adder #(.WIDTH(64)) u_sub3_lo (
        .a_i   ({1'b0, a67[62:0]}),
        .b_i   ({1'b0, b3_67inv[62:0]}),
        .cin_i (1'b1),
        .sum_o (sub3_lo_w)
    );

    wire [3:0] sub1_hi_c0 = a67[66:63] + b1_67inv[66:63];
    wire [3:0] sub1_hi_c1 = a67[66:63] + b1_67inv[66:63] + 4'd1;
    wire [3:0] sub1_hi    = sub1_lo_w[63] ? sub1_hi_c1 : sub1_hi_c0;
    wire [66:0] sub1_w    = {sub1_hi, sub1_lo_w[62:0]};

    wire [3:0] sub2_hi_c0 = a67[66:63] + b2_67inv[66:63];
    wire [3:0] sub2_hi_c1 = a67[66:63] + b2_67inv[66:63] + 4'd1;
    wire [3:0] sub2_hi    = sub2_lo_w[63] ? sub2_hi_c1 : sub2_hi_c0;
    wire [66:0] sub2_w    = {sub2_hi, sub2_lo_w[62:0]};

    wire [3:0] sub3_hi_c0 = a67[66:63] + b3_67inv[66:63];
    wire [3:0] sub3_hi_c1 = a67[66:63] + b3_67inv[66:63] + 4'd1;
    wire [3:0] sub3_hi    = sub3_lo_w[63] ? sub3_hi_c1 : sub3_hi_c0;
    wire [66:0] sub3_w    = {sub3_hi, sub3_lo_w[62:0]};

    wire _unused_sub_hi = &{1'b0, sub1_w[65:64], sub2_w[65:64], sub3_w[65:64]};

    logic [1:0]  q_dig;
    logic [63:0] rem_next;
    always_comb begin
        if (!sub3_w[66]) begin
            q_dig    = 2'b11;
            rem_next = sub3_w[63:0];
        end else if (!sub2_w[66]) begin
            q_dig    = 2'b10;
            rem_next = sub2_w[63:0];
        end else if (!sub1_w[66]) begin
            q_dig    = 2'b01;
            rem_next = sub1_w[63:0];
        end else begin
            q_dig    = 2'b00;
            rem_next = rem_sh[63:0];
        end
    end

    wire [63:0] quot_next = {quot_q[61:0], q_dig};

    // Final quotient sign negation (separate VDIV_SIGN stage: 1 KS adder/cycle)
    logic [63:0] neg_quot_w;
    fursoy_s1_ks_adder #(.WIDTH(64)) u_neg_quot (
        .a_i   (~quot_q),
        .b_i   (64'd0),
        .cin_i (1'b1),
        .sum_o (neg_quot_w)
    );

    wire [63:0] final_mask = sew_mask(sew_q);
    wire [63:0] final_res  = (neg_quot_q ? neg_quot_w : quot_q) & final_mask;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_i) begin
            state_q    <= VDIV_IDLE;
            rem_q      <= 64'd0;
            quot_q     <= 64'd0;
            d1_q       <= 66'd0;
            d2_q       <= 66'd0;
            d3_q       <= 66'd0;
            iter_q     <= 6'd0;
            sew_q      <= 2'd0;
            neg_quot_q <= 1'b0;
            result_q   <= 64'd0;
        end else begin
            case (state_q)
                VDIV_IDLE: begin
                    if (start_i) begin
                        sew_q      <= sew_i;
                        neg_quot_q <= in_neg_quot;
                        if (in_div_zero) begin
                            result_q <= in_mask;
                            state_q  <= VDIV_DONE;
                        end else if (in_overflow) begin
                            result_q <= in_smin;
                            state_q  <= VDIV_DONE;
                        end else begin
                            rem_q   <= 64'd0;
                            quot_q  <= aligned_num;
                            d1_q    <= {2'b00, mag_den};
                            d2_q    <= {1'b0,  mag_den, 1'b0};
                            iter_q  <= init_iters;
                            state_q <= VDIV_PREP;
                        end
                    end
                end

                VDIV_PREP: begin
                    d3_q    <= d3_prep_w;
                    state_q <= VDIV_ITER;
                end

                VDIV_ITER: begin
                    rem_q  <= rem_next;
                    quot_q <= quot_next;
                    if (iter_q == 6'd1) begin
                        state_q <= VDIV_SIGN;
                    end else begin
                        iter_q <= iter_q - 6'd1;
                    end
                end

                VDIV_SIGN: begin
                    result_q <= final_res;
                    state_q  <= VDIV_DONE;
                end

                VDIV_DONE: begin
                    state_q <= VDIV_IDLE;
                end

                default: state_q <= VDIV_IDLE;
            endcase
        end
    end

    assign busy_o   = (state_q != VDIV_IDLE) && (state_q != VDIV_DONE);
    assign done_o   = (state_q == VDIV_DONE);
    assign result_o = result_q;

endmodule

`endif // FURSOY_S1_VEC_DIV_SV
