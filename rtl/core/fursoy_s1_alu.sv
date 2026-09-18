`ifndef FURSOY_S1_ALU_SV
`define FURSOY_S1_ALU_SV

// =============================================================================
// Fursoy Slice-1 64-bit Integer ALU — Milestone 2
// =============================================================================
// Symmetric 64-bit execution unit for ALU0 (Port 0) and ALU1 (Port 1).
// Computes RV64I base integer ops, 32-bit W-forms, Zba, and Zbb extensions.
// Latency: 1 cycle combinational execution (registered into WB).
// Reference: docs/architecture/slice1-m2-backend-v1.md Section 2.4.1 & 2.5.1
// =============================================================================

module fursoy_s1_alu
    import fursoy_s1_pkg::*;
(
    input  uop_subop_t   sub_op_i,
    input  logic [63:0]  op_a_i,
    input  logic [63:0]  op_b_i,
    output logic [63:0]  result_o
);

    // -------------------------------------------------------------------------
    // Bitmanip & Helper Functions
    // -------------------------------------------------------------------------
    function automatic logic [63:0] f_clz64(input logic [63:0] val);
        logic [6:0] count;
        count = 7'd64;
        for (int i = 63; i >= 0; i--) begin
            if (val[i]) begin
                count = 7'd63 - 7'(i);
                break;
            end
        end
        return {57'd0, count};
    endfunction

    function automatic logic [63:0] f_ctz64(input logic [63:0] val);
        logic [6:0] count;
        count = 7'd64;
        for (int i = 0; i < 64; i++) begin
            if (val[i]) begin
                count = 7'(i);
                break;
            end
        end
        return {57'd0, count};
    endfunction

    function automatic logic [63:0] f_cpop64(input logic [63:0] val);
        logic [6:0] count;
        count = 7'd0;
        for (int i = 0; i < 64; i++) begin
            if (val[i]) count = count + 7'd1;
        end
        return {57'd0, count};
    endfunction

    function automatic logic [63:0] f_orcb64(input logic [63:0] val);
        logic [63:0] res;
        for (int i = 0; i < 8; i++) begin
            res[i*8 +: 8] = (|val[i*8 +: 8]) ? 8'hFF : 8'h00;
        end
        return res;
    endfunction

    function automatic logic [63:0] f_rev8_64(input logic [63:0] val);
        logic [63:0] res;
        for (int i = 0; i < 8; i++) begin
            res[i*8 +: 8] = val[(7-i)*8 +: 8];
        end
        return res;
    endfunction

    function automatic logic [63:0] f_rol64(input logic [63:0] a, input logic [5:0] shamt);
        if (shamt == 6'd0) return a;
        return (a << shamt) | (a >> (7'd64 - {1'b0, shamt}));
    endfunction

    function automatic logic [63:0] f_ror64(input logic [63:0] a, input logic [5:0] shamt);
        if (shamt == 6'd0) return a;
        return (a >> shamt) | (a << (7'd64 - {1'b0, shamt}));
    endfunction

    // -------------------------------------------------------------------------
    // Combinational Execution Datapath
    // -------------------------------------------------------------------------
    logic [63:0] res;
    logic [31:0] w_res;
    logic [5:0]  shamt6;
    logic [4:0]  shamt5;

    assign shamt6 = op_b_i[5:0];
    assign shamt5 = op_b_i[4:0];

    always_comb begin
        res   = 64'd0;
        w_res = 32'd0;

        case (sub_op_i)
            // -----------------------------------------------------------------
            // Base RV64I Operations
            // -----------------------------------------------------------------
            ALU_ADD:   res = op_a_i + op_b_i;
            ALU_SUB:   res = op_a_i - op_b_i;
            ALU_AND:   res = op_a_i & op_b_i;
            ALU_OR:    res = op_a_i | op_b_i;
            ALU_XOR:   res = op_a_i ^ op_b_i;
            ALU_SLT:   res = ($signed(op_a_i) < $signed(op_b_i)) ? 64'd1 : 64'd0;
            ALU_SLTU:  res = (op_a_i < op_b_i) ? 64'd1 : 64'd0;
            ALU_LUI:   res = op_b_i; // op_b_i carries immediate
            ALU_AUIPC: res = op_a_i + op_b_i; // op_a_i carries pc, op_b_i carries imm

            // Shifts
            ALU_SLL:   res = op_a_i << shamt6;
            ALU_SRL:   res = op_a_i >> shamt6;
            ALU_SRA:   res = $signed(op_a_i) >>> shamt6;

            // -----------------------------------------------------------------
            // RV64I Word Operations (W-forms, 32-bit sign-extended to 64)
            // -----------------------------------------------------------------
            ALU_ADDW: begin
                w_res = op_a_i[31:0] + op_b_i[31:0];
                res   = {{32{w_res[31]}}, w_res};
            end
            ALU_SUBW: begin
                w_res = op_a_i[31:0] - op_b_i[31:0];
                res   = {{32{w_res[31]}}, w_res};
            end
            ALU_SLLW: begin
                w_res = op_a_i[31:0] << shamt5;
                res   = {{32{w_res[31]}}, w_res};
            end
            ALU_SRLW: begin
                w_res = op_a_i[31:0] >> shamt5;
                res   = {{32{w_res[31]}}, w_res};
            end
            ALU_SRAW: begin
                w_res = $signed(op_a_i[31:0]) >>> shamt5;
                res   = {{32{w_res[31]}}, w_res};
            end

            // -----------------------------------------------------------------
            // Extension Zba (Address Generation)
            // -----------------------------------------------------------------
            ALU_SH1ADD:    res = (op_a_i << 1) + op_b_i;
            ALU_SH2ADD:    res = (op_a_i << 2) + op_b_i;
            ALU_SH3ADD:    res = (op_a_i << 3) + op_b_i;
            ALU_SH1ADD_UW: res = ({32'd0, op_a_i[31:0]} << 1) + op_b_i;
            ALU_SH2ADD_UW: res = ({32'd0, op_a_i[31:0]} << 2) + op_b_i;
            ALU_SH3ADD_UW: res = ({32'd0, op_a_i[31:0]} << 3) + op_b_i;
            ALU_ADD_UW:    res = {32'd0, op_a_i[31:0]} + op_b_i;
            ALU_SLLI_UW:   res = {32'd0, op_a_i[31:0]} << shamt6;

            // -----------------------------------------------------------------
            // Extension Zbb (Basic Bitmanipulation)
            // -----------------------------------------------------------------
            ALU_ANDN:  res = op_a_i & ~op_b_i;
            ALU_ORN:   res = op_a_i | ~op_b_i;
            ALU_XNOR:  res = ~(op_a_i ^ op_b_i);
            ALU_CLZ:   res = f_clz64(op_a_i);
            ALU_CTZ:   res = f_ctz64(op_a_i);
            ALU_CPOP:  res = f_cpop64(op_a_i);
            ALU_MAX:   res = ($signed(op_a_i) > $signed(op_b_i)) ? op_a_i : op_b_i;
            ALU_MAXU:  res = (op_a_i > op_b_i) ? op_a_i : op_b_i;
            ALU_MIN:   res = ($signed(op_a_i) < $signed(op_b_i)) ? op_a_i : op_b_i;
            ALU_MINU:  res = (op_a_i < op_b_i) ? op_a_i : op_b_i;
            ALU_SEXTB: res = {{56{op_a_i[7]}}, op_a_i[7:0]};
            ALU_SEXTH: res = {{48{op_a_i[15]}}, op_a_i[15:0]};
            ALU_ZEXTH: res = {48'd0, op_a_i[15:0]};
            ALU_ROL:   res = f_rol64(op_a_i, shamt6);
            ALU_ROR:   res = f_ror64(op_a_i, shamt6);
            ALU_ORC_B: res = f_orcb64(op_a_i);
            ALU_REV8:  res = f_rev8_64(op_a_i);

            default: res = op_a_i + op_b_i;
        endcase
    end

    assign result_o = res;

endmodule

`endif // FURSOY_S1_ALU_SV
