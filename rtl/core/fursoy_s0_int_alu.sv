// Stateless RV64I integer-ALU decode/execute block for the first core slice.
// Memory, branches, traps and CSRs remain outside this block.
module fursoy_s0_int_alu (
    input  logic        insn_valid_i,
    input  logic [63:0] pc_i,
    input  logic [31:0] insn_i,
    input  logic [63:0] rs1_i,
    input  logic [63:0] rs2_i,

    output logic        retire_valid_o,
    output logic [63:0] retire_pc_o,
    output logic [31:0] retire_insn_o,
    output logic        rd_write_o,
    output logic [4:0]  rd_o,
    output logic [63:0] rd_data_o,
    output logic        illegal_o
);
    logic legal;
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [63:0] immediate_i;

    function automatic logic [63:0] sign_extend_word(input logic [31:0] value);
        return {{32{value[31]}}, value};
    endfunction

    assign opcode = insn_i[6:0];
    assign funct3 = insn_i[14:12];
    assign funct7 = insn_i[31:25];
    assign immediate_i = {{52{insn_i[31]}}, insn_i[31:20]};
    assign retire_valid_o = insn_valid_i && legal;
    assign retire_pc_o = retire_valid_o ? pc_i : '0;
    assign retire_insn_o = retire_valid_o ? insn_i : '0;
    assign rd_o = retire_valid_o ? insn_i[11:7] : '0;
    assign rd_write_o = retire_valid_o && (insn_i[11:7] != 5'd0);

    function automatic logic [63:0] op_div64(input logic [63:0] a, input logic [63:0] b);
        if (b == '0) return '1;
        if (a == 64'h8000_0000_0000_0000 && b == '1) return a;
        return $signed(a) / $signed(b);
    endfunction

    function automatic logic [63:0] op_divu64(input logic [63:0] a, input logic [63:0] b);
        if (b == '0) return '1;
        return a / b;
    endfunction

    function automatic logic [63:0] op_rem64(input logic [63:0] a, input logic [63:0] b);
        if (b == '0) return a;
        if (a == 64'h8000_0000_0000_0000 && b == '1) return '0;
        return $signed(a) % $signed(b);
    endfunction

    function automatic logic [63:0] op_remu64(input logic [63:0] a, input logic [63:0] b);
        if (b == '0) return a;
        return a % b;
    endfunction

    function automatic logic [63:0] op_divw(input logic [31:0] a, input logic [31:0] b);
        if (b == '0) return '1;
        if (a == 32'h8000_0000 && b == '1) return sign_extend_word(32'h8000_0000);
        return sign_extend_word($signed(a) / $signed(b));
    endfunction

    function automatic logic [63:0] op_divuw(input logic [31:0] a, input logic [31:0] b);
        if (b == '0) return '1;
        return sign_extend_word(a / b);
    endfunction

    function automatic logic [63:0] op_remw(input logic [31:0] a, input logic [31:0] b);
        if (b == '0) return sign_extend_word(a);
        if (a == 32'h8000_0000 && b == '1) return '0;
        return sign_extend_word($signed(a) % $signed(b));
    endfunction

    function automatic logic [63:0] op_remuw(input logic [31:0] a, input logic [31:0] b);
        if (b == '0) return sign_extend_word(a);
        return sign_extend_word(a % b);
    endfunction

    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [127:0] mul_ss;
    logic signed [127:0] mul_su;
    logic [127:0]        mul_uu;
    /* verilator lint_on UNUSEDSIGNAL */

    assign mul_ss = $signed(rs1_i) * $signed(rs2_i);
    assign mul_su = $signed(rs1_i) * $signed({1'b0, rs2_i});
    assign mul_uu = {1'b0, rs1_i} * {1'b0, rs2_i};

    always_comb begin
        legal = 1'b0;
        rd_data_o = '0;
        unique case (opcode)
            7'b0110111: begin // LUI
                legal = 1'b1;
                rd_data_o = {{32{insn_i[31]}}, insn_i[31:12], 12'd0};
            end
            7'b0010111: begin // AUIPC
                legal = 1'b1;
                rd_data_o = pc_i + {{32{insn_i[31]}}, insn_i[31:12], 12'd0};
            end
            7'b0010011: begin // OP-IMM
                unique case (funct3)
                    3'b000: begin legal = 1'b1; rd_data_o = rs1_i + immediate_i; end // ADDI
                    3'b010: begin legal = 1'b1; rd_data_o = {63'd0, $signed(rs1_i) < $signed(immediate_i)}; end // SLTI
                    3'b011: begin legal = 1'b1; rd_data_o = {63'd0, rs1_i < immediate_i}; end // SLTIU
                    3'b100: begin legal = 1'b1; rd_data_o = rs1_i ^ immediate_i; end // XORI
                    3'b110: begin legal = 1'b1; rd_data_o = rs1_i | immediate_i; end // ORI
                    3'b111: begin legal = 1'b1; rd_data_o = rs1_i & immediate_i; end // ANDI
                    3'b001: if (insn_i[31:26] == 6'b000000) begin // SLLI
                        legal = 1'b1; rd_data_o = rs1_i << insn_i[25:20];
                    end
                    3'b101: if (insn_i[31:26] == 6'b000000) begin // SRLI
                        legal = 1'b1; rd_data_o = rs1_i >> insn_i[25:20];
                    end else if (insn_i[31:26] == 6'b010000) begin // SRAI
                        legal = 1'b1; rd_data_o = $signed(rs1_i) >>> insn_i[25:20];
                    end
                    default: ;
                endcase
            end
            7'b0011011: begin // OP-IMM-32
                unique case (funct3)
                    3'b000: begin // ADDIW
                        legal = 1'b1;
                        rd_data_o = sign_extend_word(rs1_i[31:0] + immediate_i[31:0]);
                    end
                    3'b001: if (funct7 == 7'b0000000) begin // SLLIW
                        legal = 1'b1;
                        rd_data_o = sign_extend_word(rs1_i[31:0] << insn_i[24:20]);
                    end
                    3'b101: if (funct7 == 7'b0000000) begin // SRLIW
                        legal = 1'b1;
                        rd_data_o = sign_extend_word(rs1_i[31:0] >> insn_i[24:20]);
                    end else if (funct7 == 7'b0100000) begin // SRAIW
                        legal = 1'b1;
                        rd_data_o = sign_extend_word($signed(rs1_i[31:0]) >>> insn_i[24:20]);
                    end
                    default: ;
                endcase
            end
            7'b0110011: begin // OP
                if (funct7 == 7'b0000001) begin // RV64M
                    legal = 1'b1;
                    case (funct3)
                        3'b000: rd_data_o = rs1_i * rs2_i; // MUL
                        3'b001: rd_data_o = mul_ss[127:64]; // MULH
                        3'b010: rd_data_o = mul_su[127:64]; // MULHSU
                        3'b011: rd_data_o = mul_uu[127:64]; // MULHU
                        3'b100: rd_data_o = op_div64(rs1_i, rs2_i); // DIV
                        3'b101: rd_data_o = op_divu64(rs1_i, rs2_i); // DIVU
                        3'b110: rd_data_o = op_rem64(rs1_i, rs2_i); // REM
                        3'b111: rd_data_o = op_remu64(rs1_i, rs2_i); // REMU
                        default: legal = 1'b0;
                    endcase
                end else begin
                    case (funct3)
                        3'b000: if (funct7 == 7'b0000000) begin
                            legal = 1'b1; rd_data_o = rs1_i + rs2_i; // ADD
                        end else if (funct7 == 7'b0100000) begin
                            legal = 1'b1; rd_data_o = rs1_i - rs2_i; // SUB
                        end
                        3'b001: if (funct7 == 7'b0000000) begin legal = 1'b1; rd_data_o = rs1_i << rs2_i[5:0]; end
                        3'b010: if (funct7 == 7'b0000000) begin legal = 1'b1; rd_data_o = {63'd0, $signed(rs1_i) < $signed(rs2_i)}; end
                        3'b011: if (funct7 == 7'b0000000) begin legal = 1'b1; rd_data_o = {63'd0, rs1_i < rs2_i}; end
                        3'b100: if (funct7 == 7'b0000000) begin legal = 1'b1; rd_data_o = rs1_i ^ rs2_i; end
                        3'b101: if (funct7 == 7'b0000000) begin
                            legal = 1'b1; rd_data_o = rs1_i >> rs2_i[5:0];
                        end else if (funct7 == 7'b0100000) begin
                            legal = 1'b1; rd_data_o = $signed(rs1_i) >>> rs2_i[5:0];
                        end
                        3'b110: if (funct7 == 7'b0000000) begin legal = 1'b1; rd_data_o = rs1_i | rs2_i; end
                        3'b111: if (funct7 == 7'b0000000) begin legal = 1'b1; rd_data_o = rs1_i & rs2_i; end
                        default: ;
                    endcase
                end
            end
            7'b0111011: begin // OP-32
                if (funct7 == 7'b0000001) begin // RV64M 32-bit
                    legal = 1'b1;
                    case (funct3)
                        3'b000: rd_data_o = sign_extend_word(rs1_i[31:0] * rs2_i[31:0]); // MULW
                        3'b100: rd_data_o = op_divw(rs1_i[31:0], rs2_i[31:0]); // DIVW
                        3'b101: rd_data_o = op_divuw(rs1_i[31:0], rs2_i[31:0]); // DIVUW
                        3'b110: rd_data_o = op_remw(rs1_i[31:0], rs2_i[31:0]); // REMW
                        3'b111: rd_data_o = op_remuw(rs1_i[31:0], rs2_i[31:0]); // REMUW
                        default: legal = 1'b0;
                    endcase
                end else begin
                    case (funct3)
                        3'b000: if (funct7 == 7'b0000000) begin // ADDW
                            legal = 1'b1; rd_data_o = sign_extend_word(rs1_i[31:0] + rs2_i[31:0]);
                        end else if (funct7 == 7'b0100000) begin // SUBW
                            legal = 1'b1; rd_data_o = sign_extend_word(rs1_i[31:0] - rs2_i[31:0]);
                        end
                        3'b001: if (funct7 == 7'b0000000) begin // SLLW
                            legal = 1'b1; rd_data_o = sign_extend_word(rs1_i[31:0] << rs2_i[4:0]);
                        end
                        3'b101: if (funct7 == 7'b0000000) begin // SRLW
                            legal = 1'b1; rd_data_o = sign_extend_word(rs1_i[31:0] >> rs2_i[4:0]);
                        end else if (funct7 == 7'b0100000) begin // SRAW
                            legal = 1'b1; rd_data_o = sign_extend_word($signed(rs1_i[31:0]) >>> rs2_i[4:0]);
                        end
                        default: ;
                    endcase
                end
            end
            default: ;
        endcase
    end

    assign illegal_o = insn_valid_i && !legal;
endmodule
