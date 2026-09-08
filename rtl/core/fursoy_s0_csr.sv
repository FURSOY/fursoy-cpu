// Zicsr decode/read-modify-write calculation for M-mode and S-mode CSRs.
module fursoy_s0_csr (
    input  logic        insn_valid_i,
    input  logic [31:0] insn_i,
    input  logic [63:0] rs1_i,
    input  logic [1:0]  priv_mode_i,

    // M-mode CSR inputs
    input  logic [63:0] mstatus_i,
    input  logic [63:0] mie_i,
    input  logic [63:0] mtvec_i,
    input  logic [63:0] mscratch_i,
    input  logic [63:0] mepc_i,
    input  logic [63:0] mcause_i,
    input  logic [63:0] mtval_i,
    input  logic [63:0] mip_i,
    input  logic [63:0] medeleg_i,
    input  logic [63:0] mideleg_i,
    input  logic [63:0] mcounteren_i,
    input  logic [63:0] menvcfg_i,

    // S-mode CSR inputs
    input  logic [63:0] stvec_i,
    input  logic [63:0] scounteren_i,
    input  logic [63:0] sscratch_i,
    input  logic [63:0] sepc_i,
    input  logic [63:0] scause_i,
    input  logic [63:0] stval_i,
    input  logic [63:0] senvcfg_i,
    input  logic [63:0] satp_i,

    // PMP inputs
    input  logic [63:0] pmpcfg0_i,
    input  logic [63:0] pmpcfg2_i,
    input  logic [63:0] pmpaddr_i [16],

    // Performance / timer counters
    input  logic [63:0] cycle_i,

    output logic        csr_valid_o,
    output logic        csr_illegal_o,
    output logic        csr_write_o,
    output logic [11:0] csr_addr_o,
    output logic [63:0] csr_write_data_o,
    output logic        rd_write_o,
    output logic [4:0]  rd_o,
    output logic [63:0] rd_data_o
);
    logic [2:0] funct3;
    logic [63:0] old_value, source, sstatus_val, sie_val, sip_val;
    logic implemented, read_only, write_intent, operation_supported;
    logic priv_enc_valid, priv_ok, counter_illegal, tvm_illegal;

    assign funct3 = insn_i[14:12];
    assign csr_addr_o = insn_i[31:20];
    assign rd_o = csr_valid_o ? insn_i[11:7] : 5'd0;
    assign rd_write_o = csr_valid_o && !csr_illegal_o && (insn_i[11:7] != 5'd0);
    assign rd_data_o = rd_write_o ? old_value : 64'd0;

    assign sstatus_val = mstatus_i & 64'h0000_0003_000c_0122;
    assign sie_val     = mie_i & mideleg_i & 64'h222;
    assign sip_val     = mip_i & mideleg_i & 64'h222;

    // Privilege checks: CSR address bits [9:8] encode minimum required privilege.
    // Encoding 2'b10 (Hypervisor) is unsupported.
    assign priv_enc_valid = (csr_addr_o[9:8] != 2'b10);
    assign priv_ok = priv_enc_valid && (priv_mode_i >= csr_addr_o[9:8]);

    always_comb begin
        counter_illegal = 1'b0;
        tvm_illegal = (csr_addr_o == 12'h180) && (priv_mode_i == 2'b01) && mstatus_i[20];
        if (csr_addr_o == 12'hc00) begin
            if (priv_mode_i == 2'b01 && !mcounteren_i[0]) begin
                counter_illegal = 1'b1;
            end else if (priv_mode_i == 2'b00 && (!mcounteren_i[0] || !scounteren_i[0])) begin
                counter_illegal = 1'b1;
            end
        end else if (csr_addr_o == 12'hc01) begin
            if (priv_mode_i == 2'b01 && !mcounteren_i[1]) begin
                counter_illegal = 1'b1;
            end else if (priv_mode_i == 2'b00 && (!mcounteren_i[1] || !scounteren_i[1])) begin
                counter_illegal = 1'b1;
            end
        end else if (csr_addr_o == 12'hc02) begin
            if (priv_mode_i == 2'b01 && !mcounteren_i[2]) begin
                counter_illegal = 1'b1;
            end else if (priv_mode_i == 2'b00 && (!mcounteren_i[2] || !scounteren_i[2])) begin
                counter_illegal = 1'b1;
            end
        end
    end

    always_comb begin
        csr_valid_o = insn_valid_i && (insn_i[6:0] == 7'b1110011) && (funct3 != 3'b000);
        implemented = 1'b1;
        read_only = (csr_addr_o[11:10] == 2'b11);
        old_value = 64'd0;

        unique case (csr_addr_o)
            // M-mode CSRs
            12'h300: old_value = mstatus_i;
            12'h301: old_value = 64'd0;         // misa (WARL zero)
            12'h302: old_value = medeleg_i;     // medeleg
            12'h303: old_value = mideleg_i;     // mideleg
            12'h304: old_value = mie_i;
            12'h305: old_value = mtvec_i;
            12'h306: old_value = mcounteren_i;  // mcounteren
            12'h30a: old_value = menvcfg_i;
            12'h340: old_value = mscratch_i;
            12'h341: old_value = mepc_i;
            12'h342: old_value = mcause_i;
            12'h343: old_value = mtval_i;
            12'h344: old_value = mip_i;         // mip (SSIP/STIP/SEIP software bits writable)
            12'hf11: begin old_value = 64'd0; read_only = 1'b1; end // mvendorid
            12'hf12: begin old_value = 64'd0; read_only = 1'b1; end // marchid
            12'hf13: begin old_value = 64'd0; read_only = 1'b1; end // mimpid
            12'hf14: begin old_value = 64'd0; read_only = 1'b1; end // mhartid

            // PMP CSRs
            12'h3a0: old_value = pmpcfg0_i;
            12'h3a2: old_value = pmpcfg2_i;
            12'h3b0, 12'h3b1, 12'h3b2, 12'h3b3,
            12'h3b4, 12'h3b5, 12'h3b6, 12'h3b7,
            12'h3b8, 12'h3b9, 12'h3ba, 12'h3bb,
            12'h3bc, 12'h3bd, 12'h3be, 12'h3bf: old_value = pmpaddr_i[csr_addr_o[3:0]];

            // S-mode CSRs
            12'h100: old_value = sstatus_val;   // sstatus alias
            12'h104: old_value = sie_val;       // sie alias
            12'h105: old_value = stvec_i;       // stvec
            12'h106: old_value = scounteren_i;  // scounteren
            12'h10a: old_value = senvcfg_i;
            12'h140: old_value = sscratch_i;    // sscratch
            12'h141: old_value = sepc_i;        // sepc
            12'h142: old_value = scause_i;      // scause
            12'h143: old_value = stval_i;       // stval
            12'h144: old_value = sip_val;       // sip alias
            12'h180: old_value = satp_i;

            // Counters
            12'hc00: begin old_value = cycle_i; read_only = 1'b1; end
            12'hc01: begin old_value = cycle_i; read_only = 1'b1; end
            12'hc02: begin old_value = cycle_i; read_only = 1'b1; end

            default: begin
                implemented = 1'b0;
                read_only = 1'b0;
            end
        endcase

        source = funct3[2] ? {59'd0, insn_i[19:15]} : rs1_i;
        operation_supported = funct3 == 3'b001 || funct3 == 3'b010 || funct3 == 3'b011 ||
                              funct3 == 3'b101 || funct3 == 3'b110 || funct3 == 3'b111;
        unique case (funct3)
            3'b001, 3'b101: begin
                write_intent = 1'b1;
                csr_write_data_o = source;
            end
            3'b010, 3'b110: begin
                write_intent = (insn_i[19:15] != 5'd0);
                csr_write_data_o = old_value | source;
            end
            3'b011, 3'b111: begin
                write_intent = (insn_i[19:15] != 5'd0);
                csr_write_data_o = old_value & ~source;
            end
            default: begin
                write_intent = 1'b0;
                csr_write_data_o = 64'd0;
            end
        endcase

        csr_illegal_o = csr_valid_o && (!operation_supported || !implemented || !priv_ok ||
                                        (read_only && write_intent) || counter_illegal || tvm_illegal);
        csr_write_o = csr_valid_o && !csr_illegal_o && write_intent;
    end
endmodule
