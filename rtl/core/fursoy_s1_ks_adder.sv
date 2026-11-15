`ifndef FURSOY_S1_KS_ADDER_SV
`define FURSOY_S1_KS_ADDER_SV

// =============================================================================
// Fursoy Slice-1 Parameterized Kogge-Stone Parallel-Prefix Adder
// =============================================================================
// Logarithmic-depth parallel-prefix adder supporting arbitrary carry-in (`cin_i`)
// for two's-complement addition/subtraction across ALU, Branch Unit, AGU, and CSR
// (`u_pc_p4_adder`). Preserves intermediate prefix cut points (`p2/g2`, `p4/g4`
// for 64-bit) so AIG functional reduction cannot collapse the prefix tree into
// a ripple chain.
// =============================================================================

module fursoy_s1_ks_adder #(
    parameter int unsigned WIDTH = 64
) (
    input  logic [WIDTH-1:0] a_i,
    input  logic [WIDTH-1:0] b_i,
    input  logic             cin_i,
    output logic [WIDTH-1:0] sum_o
);

    localparam int unsigned NUM_CARRY = (WIDTH > 1) ? (WIDTH - 1) : 1;

    wire [WIDTH-1:0]     p0     = a_i ^ b_i;
    wire [NUM_CARRY-1:0] g0_raw = a_i[NUM_CARRY-1:0] & b_i[NUM_CARRY-1:0];
    logic [NUM_CARRY-1:0] g0;
    always_comb begin
        g0[0] = g0_raw[0] | (p0[0] & cin_i);
        for (int i = 1; i < int'(NUM_CARRY); i++) begin
            g0[i] = g0_raw[i];
        end
    end

    generate
        if (WIDTH == 64) begin : gen_ks64
            logic [62:0] p1, g1;
            (* keep = "true" *) logic [62:0] p2, g2;
            logic [62:0] p3, g3;
            (* keep = "true" *) logic [62:0] p4, g4;
            logic [62:0] p5, g5;
            logic [62:0] g6;

            always_comb begin
                p1[0] = p0[0];
                g1[0] = g0[0];
                for (int i = 1; i < 63; i++) begin
                    p1[i] = p0[i] & p0[i-1];
                    g1[i] = g0[i] | (p0[i] & g0[i-1]);
                end

                for (int i = 0; i < 2; i++) begin
                    p2[i] = p1[i];
                    g2[i] = g1[i];
                end
                for (int i = 2; i < 63; i++) begin
                    p2[i] = p1[i] & p1[i-2];
                    g2[i] = g1[i] | (p1[i] & g1[i-2]);
                end

                for (int i = 0; i < 4; i++) begin
                    p3[i] = p2[i];
                    g3[i] = g2[i];
                end
                for (int i = 4; i < 63; i++) begin
                    p3[i] = p2[i] & p2[i-4];
                    g3[i] = g2[i] | (p2[i] & g2[i-4]);
                end

                for (int i = 0; i < 8; i++) begin
                    p4[i] = p3[i];
                    g4[i] = g3[i];
                end
                for (int i = 8; i < 63; i++) begin
                    p4[i] = p3[i] & p3[i-8];
                    g4[i] = g3[i] | (p3[i] & g3[i-8]);
                end

                for (int i = 0; i < 16; i++) begin
                    p5[i] = p4[i];
                    g5[i] = g4[i];
                end
                for (int i = 16; i < 63; i++) begin
                    p5[i] = p4[i] & p4[i-16];
                    g5[i] = g4[i] | (p4[i] & g4[i-16]);
                end

                for (int i = 0; i < 32; i++) begin
                    g6[i] = g5[i];
                end
                for (int i = 32; i < 63; i++) begin
                    g6[i] = g5[i] | (p5[i] & g5[i-32]);
                end
            end

            assign sum_o = p0 ^ {g6[62:0], cin_i};
        end else if (WIDTH == 1) begin : gen_ks1
            assign sum_o = p0 ^ cin_i;
        end else begin : gen_ks_param
            // When WIDTH == 2, NUM_CARRY == 1 so STAGES == $clog2(1) == 0; the
            // loop runs 0 iterations and stage_g[0] directly supplies carry-out.
            localparam int unsigned STAGES = $clog2(NUM_CARRY);
            logic [NUM_CARRY-1:0] stage_p [STAGES+1];
            logic [NUM_CARRY-1:0] stage_g [STAGES+1];

            always_comb begin
                stage_p[0] = p0[NUM_CARRY-1:0];
                stage_g[0] = g0;
                for (int s = 0; s < STAGES; s++) begin
                    int stride;
                    stride = (1 << s);
                    for (int i = 0; i < NUM_CARRY; i++) begin
                        if (i < stride) begin
                            stage_p[s+1][i] = stage_p[s][i];
                            stage_g[s+1][i] = stage_g[s][i];
                        end else begin
                            stage_p[s+1][i] = stage_p[s][i] & stage_p[s][i-stride];
                            stage_g[s+1][i] = stage_g[s][i] | (stage_p[s][i] & stage_g[s][i-stride]);
                        end
                    end
                end
            end

            assign sum_o = p0 ^ {stage_g[STAGES], cin_i};
        end
    endgenerate

endmodule

`endif // FURSOY_S1_KS_ADDER_SV
