// RV64I branch and jump decode/target calculation. No compressed instructions.
module fursoy_s0_control (
    input  logic        insn_valid_i,
    input  logic [63:0] pc_i,
    input  logic [31:0] insn_i,
    input  logic [63:0] rs1_i,
    input  logic [63:0] rs2_i,
    output logic        control_valid_o,
    output logic        rd_write_o,
    output logic [4:0]  rd_o,
    output logic [63:0] rd_data_o,
    output logic [63:0] target_pc_o,
    output logic        target_misaligned_o
);
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [63:0] target;
    logic branch_taken;

    assign opcode = insn_i[6:0];
    assign funct3 = insn_i[14:12];
    assign rd_o = (control_valid_o && (opcode != 7'b1100011)) ? insn_i[11:7] : '0;
    assign rd_write_o = control_valid_o && (opcode != 7'b1100011) && (insn_i[11:7] != 0);
    assign rd_data_o = rd_write_o ? pc_i + 64'd4 : '0;
    assign target_pc_o = control_valid_o ? target : '0;
    assign target_misaligned_o = control_valid_o && (target[1:0] != 2'b00);

    always_comb begin
        control_valid_o = 1'b0;
        branch_taken = 1'b0;
        target = pc_i + 64'd4;
        unique case (opcode)
            7'b1101111: begin // JAL
                control_valid_o = insn_valid_i;
                target = pc_i + {{43{insn_i[31]}}, insn_i[31], insn_i[19:12], insn_i[20], insn_i[30:21], 1'b0};
            end
            7'b1100111: if (funct3 == 3'b000) begin // JALR
                control_valid_o = insn_valid_i;
                target = (rs1_i + {{52{insn_i[31]}}, insn_i[31:20]}) & ~64'd1;
            end
            7'b1100011: begin // BRANCH
                unique case (funct3)
                    3'b000: begin control_valid_o = insn_valid_i; branch_taken = rs1_i == rs2_i; end
                    3'b001: begin control_valid_o = insn_valid_i; branch_taken = rs1_i != rs2_i; end
                    3'b100: begin control_valid_o = insn_valid_i; branch_taken = $signed(rs1_i) < $signed(rs2_i); end
                    3'b101: begin control_valid_o = insn_valid_i; branch_taken = $signed(rs1_i) >= $signed(rs2_i); end
                    3'b110: begin control_valid_o = insn_valid_i; branch_taken = rs1_i < rs2_i; end
                    3'b111: begin control_valid_o = insn_valid_i; branch_taken = rs1_i >= rs2_i; end
                    default: ;
                endcase
                if (branch_taken) target = pc_i + {{51{insn_i[31]}}, insn_i[31], insn_i[7], insn_i[30:25], insn_i[11:8], 1'b0};
            end
            default: ;
        endcase
    end
endmodule
