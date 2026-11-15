`ifndef FURSOY_S1_ALU_SV
`define FURSOY_S1_ALU_SV

// =============================================================================
// Fursoy Slice-1 64-bit Integer ALU — Milestone 2 (PPA Stage 3 Timing Closure)
// =============================================================================
// Symmetric 64-bit execution unit for ALU0 (Port 0) and ALU1 (Port 1).
// Computes RV64I base integer ops, 32-bit W-forms, Zba, and Zbb extensions.
// Latency: 1 cycle combinational execution (registered into WB).
// Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.4.1 & 2.5.1
//
// Timing structure (PPA Stage 3 — 500 MHz closure):
// - Single shared 64-bit Kogge-Stone parallel-prefix adder/subtractor with
//   preserved intermediate prefix cut points covers ADD/SUB/AUIPC/ADDW/SUBW/Zba.
// - Unified 6-stage parallel-prefix magnitude comparator covers SLT/SLTU/MIN/MAX.
// - Unified 6-stage logarithmic barrel shifter/rotator with input/output bit
//   reversal covers SLL/SRL/SRA/SLLW/SRLW/SRAW/SLLI.UW/ROL/ROR.
// - Shared 6-level binary-tree leading/trailing zero counter covers CLZ/CTZ.
// - Balanced nibble-LUT + tree adder implements CPOP without ripple chains.
// =============================================================================

`include "fursoy_s1_ks_adder.sv"

module fursoy_s1_alu
    import fursoy_s1_pkg::*;
(
    input  uop_subop_t   sub_op_i,
    input  logic [63:0]  op_a_i,
    input  logic [63:0]  op_b_i,
    output logic [63:0]  result_o
);

    // -------------------------------------------------------------------------
    // 1. Shared 64-bit Kogge-Stone Adder / Subtractor (RV64I + Zba)
    // -------------------------------------------------------------------------
    logic [63:0] add_a;
    logic [63:0] add_b;
    logic        add_cin;
    logic        add_is_w;

    always_comb begin
        add_cin  = (sub_op_i == ALU_SUB) || (sub_op_i == ALU_SUBW);
        add_is_w = (sub_op_i == ALU_ADDW) || (sub_op_i == ALU_SUBW);
        add_b    = add_cin ? ~op_b_i : op_b_i;

        case (sub_op_i)
            ALU_SH1ADD:    add_a = {op_a_i[62:0], 1'b0};
            ALU_SH2ADD:    add_a = {op_a_i[61:0], 2'b0};
            ALU_SH3ADD:    add_a = {op_a_i[60:0], 3'b0};
            ALU_ADD_UW:    add_a = {32'd0, op_a_i[31:0]};
            ALU_SH1ADD_UW: add_a = {31'd0, op_a_i[31:0], 1'b0};
            ALU_SH2ADD_UW: add_a = {30'd0, op_a_i[31:0], 2'b0};
            ALU_SH3ADD_UW: add_a = {29'd0, op_a_i[31:0], 3'b0};
            default:       add_a = op_a_i;
        endcase
    end

    logic [63:0] add_sum;
    fursoy_s1_ks_adder #(
        .WIDTH (64)
    ) u_ks_adder (
        .a_i   (add_a),
        .b_i   (add_b),
        .cin_i (add_cin),
        .sum_o (add_sum)
    );

    wire [63:0] add_res = add_is_w ? {{32{add_sum[31]}}, add_sum[31:0]} : add_sum;

    // -------------------------------------------------------------------------
    // 2. 6-Stage Parallel-Prefix Magnitude Comparator (SLT/SLTU/MIN/MAX)
    // -------------------------------------------------------------------------
    wire [63:0] cmp_p0 = ~(op_a_i ^ op_b_i);
    wire [63:0] cmp_g0 = (~op_a_i) & op_b_i;
    logic [31:0] cmp_p1, cmp_g1;
    (* keep = "true" *) logic [15:0] cmp_p2, cmp_g2;
    logic [7:0]  cmp_p3, cmp_g3;
    (* keep = "true" *) logic [3:0]  cmp_p4, cmp_g4;
    logic [1:0]  cmp_p5, cmp_g5;
    logic        ult;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0]  cmp_p5_unused;
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        for (int i = 0; i < 32; i++) begin
            cmp_p1[i] = cmp_p0[2*i+1] & cmp_p0[2*i];
            cmp_g1[i] = cmp_g0[2*i+1] | (cmp_p0[2*i+1] & cmp_g0[2*i]);
        end
        for (int i = 0; i < 16; i++) begin
            cmp_p2[i] = cmp_p1[2*i+1] & cmp_p1[2*i];
            cmp_g2[i] = cmp_g1[2*i+1] | (cmp_p1[2*i+1] & cmp_g1[2*i]);
        end
        for (int i = 0; i < 8; i++) begin
            cmp_p3[i] = cmp_p2[2*i+1] & cmp_p2[2*i];
            cmp_g3[i] = cmp_g2[2*i+1] | (cmp_p2[2*i+1] & cmp_g2[2*i]);
        end
        for (int i = 0; i < 4; i++) begin
            cmp_p4[i] = cmp_p3[2*i+1] & cmp_p3[2*i];
            cmp_g4[i] = cmp_g3[2*i+1] | (cmp_p3[2*i+1] & cmp_g3[2*i]);
        end
        for (int i = 0; i < 2; i++) begin
            cmp_p5[i] = cmp_p4[2*i+1] & cmp_p4[2*i];
            cmp_g5[i] = cmp_g4[2*i+1] | (cmp_p4[2*i+1] & cmp_g4[2*i]);
        end
        cmp_p5_unused = cmp_p5;
        ult = cmp_g5[1] | (cmp_p5[1] & cmp_g5[0]);
    end

    wire slt = (op_a_i[63] ^ op_b_i[63]) ? op_a_i[63] : ult;

    // -------------------------------------------------------------------------
    // 3. Unified 6-Stage Logarithmic Barrel Shifter / Rotator
    // -------------------------------------------------------------------------
    logic        sh_is_w;
    logic        sh_is_left;
    logic        sh_is_rotate;
    logic        sh_fill_bit;
    logic [5:0]  sh_amt;
    logic [63:0] sh_data_base;
    logic [63:0] sh_in;
    logic [63:0] sh_s5, sh_s4;
    (* keep = "true" *) logic [63:0] sh_s3;
    logic [63:0] sh_s2, sh_s1, sh_s0;
    logic [63:0] sh_raw_out;
    logic [63:0] sh_res;

    always_comb begin
        sh_is_w      = (sub_op_i == ALU_SLLW) || (sub_op_i == ALU_SRLW) || (sub_op_i == ALU_SRAW) ||
                       (sub_op_i == ALU_ROLW) || (sub_op_i == ALU_RORW);
        sh_is_left   = (sub_op_i == ALU_SLL)  || (sub_op_i == ALU_SLLW) ||
                       (sub_op_i == ALU_SLLI_UW) || (sub_op_i == ALU_ROL) || (sub_op_i == ALU_ROLW);
        sh_is_rotate = (sub_op_i == ALU_ROL)  || (sub_op_i == ALU_ROR)  ||
                       (sub_op_i == ALU_ROLW) || (sub_op_i == ALU_RORW);
        sh_fill_bit  = (sub_op_i == ALU_SRA)  ? op_a_i[63] :
                       (sub_op_i == ALU_SRAW) ? op_a_i[31] : 1'b0;
        sh_amt       = sh_is_w ? {1'b0, op_b_i[4:0]} : op_b_i[5:0];

        if (sub_op_i == ALU_SRAW) begin
            sh_data_base = {{32{op_a_i[31]}}, op_a_i[31:0]};
        end else if ((sub_op_i == ALU_ROLW) || (sub_op_i == ALU_RORW)) begin
            sh_data_base = {op_a_i[31:0], op_a_i[31:0]};
        end else if ((sub_op_i == ALU_SLLW) || (sub_op_i == ALU_SRLW) || (sub_op_i == ALU_SLLI_UW)) begin
            sh_data_base = {32'd0, op_a_i[31:0]};
        end else begin
            sh_data_base = op_a_i;
        end

        for (int i = 0; i < 64; i++) begin
            sh_in[i] = sh_is_left ? sh_data_base[63 - i] : sh_data_base[i];
        end

        sh_s5 = sh_amt[5] ? {(sh_is_rotate ? sh_in[31:0] : {32{sh_fill_bit}}), sh_in[63:32]} : sh_in;
        sh_s4 = sh_amt[4] ? {(sh_is_rotate ? sh_s5[15:0] : {16{sh_fill_bit}}), sh_s5[63:16]} : sh_s5;
        sh_s3 = sh_amt[3] ? {(sh_is_rotate ? sh_s4[7:0]  : {8{sh_fill_bit}}),  sh_s4[63:8]}  : sh_s4;
        sh_s2 = sh_amt[2] ? {(sh_is_rotate ? sh_s3[3:0]  : {4{sh_fill_bit}}),  sh_s3[63:4]}  : sh_s3;
        sh_s1 = sh_amt[1] ? {(sh_is_rotate ? sh_s2[1:0]  : {2{sh_fill_bit}}),  sh_s2[63:2]}  : sh_s2;
        sh_s0 = sh_amt[0] ? {(sh_is_rotate ? sh_s1[0]    : sh_fill_bit),       sh_s1[63:1]}  : sh_s1;

        for (int i = 0; i < 64; i++) begin
            sh_raw_out[i] = sh_is_left ? sh_s0[63 - i] : sh_s0[i];
        end

        sh_res = sh_is_w ? {{32{sh_raw_out[31]}}, sh_raw_out[31:0]} : sh_raw_out;
    end

    // -------------------------------------------------------------------------
    // 4. Unified 6-Level Binary-Tree CLZ / CTZ / CLZW / CTZW
    // -------------------------------------------------------------------------
    wire        clz_is_ctz = (sub_op_i == ALU_CTZ) || (sub_op_i == ALU_CTZW);
    wire        clz_is_w   = (sub_op_i == ALU_CLZW) || (sub_op_i == ALU_CTZW);
    logic [63:0] cz_x;
    logic [31:0] cz_v1, cz_z1;
    logic [15:0] cz_v2;
    logic [15:0][1:0] cz_z2;
    logic [7:0]  cz_v3;
    logic [7:0][2:0]  cz_z3;
    logic [3:0]  cz_v4;
    logic [3:0][3:0]  cz_z4;
    logic [1:0]  cz_v5;
    logic [1:0][4:0]  cz_z5;
    logic        cz_v6;
    logic [5:0]  cz_z6;
    logic [63:0] clz_ctz_res;

    always_comb begin
        for (int i = 0; i < 32; i++) begin
            cz_x[i] = clz_is_ctz ? op_a_i[i] :
                      (clz_is_w ? op_a_i[31 - i] : op_a_i[63 - i]);
        end
        for (int i = 32; i < 64; i++) begin
            cz_x[i] = clz_is_w ? 1'b1 : (clz_is_ctz ? op_a_i[i] : op_a_i[63 - i]);
        end
        for (int i = 0; i < 32; i++) begin
            cz_v1[i] = cz_x[2*i] | cz_x[2*i+1];
            cz_z1[i] = ~cz_x[2*i];
        end
        for (int i = 0; i < 16; i++) begin
            cz_v2[i] = cz_v1[2*i] | cz_v1[2*i+1];
            cz_z2[i] = cz_v1[2*i] ? {1'b0, cz_z1[2*i]} : {1'b1, cz_z1[2*i+1]};
        end
        for (int i = 0; i < 8; i++) begin
            cz_v3[i] = cz_v2[2*i] | cz_v2[2*i+1];
            cz_z3[i] = cz_v2[2*i] ? {1'b0, cz_z2[2*i]} : {1'b1, cz_z2[2*i+1]};
        end
        for (int i = 0; i < 4; i++) begin
            cz_v4[i] = cz_v3[2*i] | cz_v3[2*i+1];
            cz_z4[i] = cz_v3[2*i] ? {1'b0, cz_z3[2*i]} : {1'b1, cz_z3[2*i+1]};
        end
        for (int i = 0; i < 2; i++) begin
            cz_v5[i] = cz_v4[2*i] | cz_v4[2*i+1];
            cz_z5[i] = cz_v4[2*i] ? {1'b0, cz_z4[2*i]} : {1'b1, cz_z4[2*i+1]};
        end
        cz_v6 = cz_v5[0] | cz_v5[1];
        cz_z6 = cz_v5[0] ? {1'b0, cz_z5[0]} : {1'b1, cz_z5[1]};
        clz_ctz_res = cz_v6 ? {58'd0, cz_z6} : 64'd64;
    end

    // -------------------------------------------------------------------------
    // 5. Tree-Structured 64-bit CPOP (Nibble Popcount + 4-Level Adder Tree)
    // -------------------------------------------------------------------------
    (* keep = "true" *) logic [15:0][2:0] pop4;
    logic [7:0][3:0]  pop_s1;
    (* keep = "true" *) logic [3:0][4:0]  pop_s2;
    logic [1:0][5:0]  pop_s3;
    logic [6:0] pop_s4;
    logic [63:0] cpop_res;

    always_comb begin
        for (int i = 0; i < 16; i++) begin
            logic b0, b1, b2, b3;
            logic fa_s, fa_c, ha_s, ha_c;
            logic mask_hi;
            mask_hi = (sub_op_i == ALU_CPOPW) && (i >= 8);
            b0   = mask_hi ? 1'b0 : op_a_i[4*i + 0];
            b1   = mask_hi ? 1'b0 : op_a_i[4*i + 1];
            b2   = mask_hi ? 1'b0 : op_a_i[4*i + 2];
            b3   = mask_hi ? 1'b0 : op_a_i[4*i + 3];
            fa_s = b0 ^ b1 ^ b2;
            fa_c = (b0 & b1) | (b2 & (b0 ^ b1));
            ha_s = fa_s ^ b3;
            ha_c = fa_s & b3;
            pop4[i][0] = ha_s;
            pop4[i][1] = fa_c ^ ha_c;
            pop4[i][2] = fa_c & ha_c;
        end
        for (int i = 0; i < 8; i++) begin
            pop_s1[i] = {1'b0, pop4[2*i]} + {1'b0, pop4[2*i+1]};
        end
        for (int i = 0; i < 4; i++) begin
            pop_s2[i] = {1'b0, pop_s1[2*i]} + {1'b0, pop_s1[2*i+1]};
        end
        for (int i = 0; i < 2; i++) begin
            pop_s3[i] = {1'b0, pop_s2[2*i]} + {1'b0, pop_s2[2*i+1]};
        end
        pop_s4   = {1'b0, pop_s3[0]} + {1'b0, pop_s3[1]};
        cpop_res = {57'd0, pop_s4};
    end

    // -------------------------------------------------------------------------
    // 6. Byte & Bitwise Helpers
    // -------------------------------------------------------------------------
    logic [63:0] orcb_res;
    logic [63:0] rev8_res;

    always_comb begin
        for (int i = 0; i < 8; i++) begin
            orcb_res[i*8 +: 8] = (|op_a_i[i*8 +: 8]) ? 8'hFF : 8'h00;
            rev8_res[i*8 +: 8] = op_a_i[(7 - i)*8 +: 8];
        end
    end

    // -------------------------------------------------------------------------
    // 7. Shallow Balanced Final Result Selection
    // -------------------------------------------------------------------------
    always_comb begin
        case (sub_op_i)
            ALU_AND:   result_o = op_a_i & op_b_i;
            ALU_OR:    result_o = op_a_i | op_b_i;
            ALU_XOR:   result_o = op_a_i ^ op_b_i;
            ALU_ANDN:  result_o = op_a_i & ~op_b_i;
            ALU_ORN:   result_o = op_a_i | ~op_b_i;
            ALU_XNOR:  result_o = ~(op_a_i ^ op_b_i);
            ALU_LUI:   result_o = op_b_i;
            ALU_SEXTB: result_o = {{56{op_a_i[7]}},  op_a_i[7:0]};
            ALU_SEXTH: result_o = {{48{op_a_i[15]}}, op_a_i[15:0]};
            ALU_ZEXTH: result_o = {48'd0, op_a_i[15:0]};
            ALU_ORC_B: result_o = orcb_res;
            ALU_REV8:  result_o = rev8_res;

            ALU_SLT:   result_o = {63'd0, slt};
            ALU_SLTU:  result_o = {63'd0, ult};
            ALU_MAX:   result_o = slt ? op_b_i : op_a_i;
            ALU_MAXU:  result_o = ult ? op_b_i : op_a_i;
            ALU_MIN:   result_o = slt ? op_a_i : op_b_i;
            ALU_MINU:  result_o = ult ? op_a_i : op_b_i;

            ALU_SLL, ALU_SRL, ALU_SRA,
            ALU_SLLW, ALU_SRLW, ALU_SRAW,
            ALU_SLLI_UW, ALU_ROL, ALU_ROR,
            ALU_ROLW, ALU_RORW: result_o = sh_res;

            ALU_CLZ, ALU_CTZ,
            ALU_CLZW, ALU_CTZW: result_o = clz_ctz_res;
            ALU_CPOP, ALU_CPOPW: result_o = cpop_res;

            default: result_o = add_res;
        endcase
    end

endmodule

`endif // FURSOY_S1_ALU_SV
