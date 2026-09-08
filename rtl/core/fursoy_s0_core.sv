// First end-to-end in-order DUT slice. ALU, control-flow and one-outstanding
`include "rtl/core/fursoy_s0_pmp.sv"
module fursoy_s0_core #(
    parameter logic [63:0] RESET_PC = 64'h0000_0000_8000_0000,
    parameter logic [63:0] RESET_MTVEC = 64'h0000_0000_0000_0000
) (
    input  logic        clk_i,
    input  logic        rst_i,
    output logic        imem_req_valid_o,
    input  logic        imem_req_ready_i,
    output logic [63:0] imem_req_addr_o,
    input  logic        imem_rsp_valid_i,
    output logic        imem_rsp_ready_o,
    input  logic [31:0] imem_rsp_insn_i,
    input  logic        imem_rsp_error_i,
    output logic        dmem_req_valid_o,
    input  logic        dmem_req_ready_i,
    output logic        dmem_req_store_o,
    output logic [63:0] dmem_req_addr_o,
    output logic [2:0]  dmem_req_size_o,
    output logic [63:0] dmem_req_store_data_o,
    output logic        dmem_req_ptw_o,
    input  logic        dmem_req_error_i,
    input  logic        dmem_rsp_valid_i,
    output logic        dmem_rsp_ready_o,
    input  logic [63:0] dmem_rsp_data_i,
    input  logic        dmem_rsp_error_i,

    input  logic        irq_software_i,
    input  logic        irq_timer_i,
    input  logic        irq_external_i,
    input  logic        irq_seip_i,

    output logic        commit_valid_o,
    output logic [63:0] commit_pc_o,
    output logic [31:0] commit_insn_o,
    output logic        commit_rd_write_o,
    output logic [4:0]  commit_rd_o,
    output logic [63:0] commit_rd_data_o,
    output logic        fence_i_valid_o,
    output logic        trap_valid_o,
    output logic [63:0] trap_pc_o,
    output logic [31:0] trap_insn_o
    ,output logic [1:0]  priv_mode_o
    ,output logic [63:0] csr_mstatus_o
    ,output logic [63:0] csr_mie_o
    ,output logic [63:0] csr_mtvec_o
    ,output logic [63:0] csr_mscratch_o
    ,output logic [63:0] csr_mepc_o
    ,output logic [63:0] csr_mcause_o
    ,output logic [63:0] csr_mtval_o
    ,output logic [63:0] csr_mip_o
    ,output logic [63:0] csr_medeleg_o
    ,output logic [63:0] csr_sstatus_o
    ,output logic [63:0] csr_stvec_o
    ,output logic [63:0] csr_sscratch_o
    ,output logic [63:0] csr_sepc_o
    ,output logic [63:0] csr_scause_o
    ,output logic [63:0] csr_stval_o
    ,output logic [63:0] csr_mideleg_o
    ,output logic [63:0] csr_sie_o
    ,output logic [63:0] csr_sip_o
    ,output logic [63:0] csr_satp_o
    ,output logic [63:0] csr_menvcfg_o
    ,output logic [63:0] csr_senvcfg_o
    ,output logic [63:0] csr_pmpcfg0_o
    ,output logic [63:0] csr_pmpcfg2_o
);
    logic [1:0]  priv_mode_q;
    logic [63:0] pc_q;
    logic [63:0] registers [0:31];
    logic [63:0] mstatus_q, mie_q, mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q, cycle_q;
    logic [63:0] medeleg_q, mideleg_q, mcounteren_q;
    logic [63:0] menvcfg_q, senvcfg_q, satp_q;
    logic ssip_q, stip_q, seip_q;
    logic [63:0] stvec_q, scounteren_q, sscratch_q, sepc_q, scause_q, stval_q;
    logic fetched_valid, fetched_ready, fetched_error, fetched_page_fault;
    logic [63:0] fetched_pc;
    logic [31:0] fetched_insn;
    logic alu_valid, alu_rd_write, alu_illegal;
    logic ecall, ebreak, fence, fence_i, trap_take;
    logic mret_valid, mret_legal, sret_valid, sret_legal, wfi_valid, wfi_legal;
    logic sfence_vma, sfence_legal;
    logic priv_insn_illegal, other_alu_illegal, insn_illegal;
    logic control_valid, control_rd_write, control_misaligned;
    logic [4:0] control_rd;
    logic [63:0] control_rd_data, control_target;
    logic lsu_valid, lsu_store, lsu_lr, lsu_sc, lsu_amo, lsu_unsigned, lsu_misaligned, lsu_issue_ready, lsu_retire, lsu_rd_write;
    logic [4:0] lsu_amo_op;
    logic [2:0] lsu_size;
    logic [4:0] lsu_retire_rd;
    logic [63:0] lsu_address, lsu_store_data, lsu_retire_data, lsu_retire_pc;
    logic [31:0] lsu_retire_insn;
    logic lsu_fault, lsu_fault_store, lsu_fault_page;
    logic [63:0] lsu_fault_addr, lsu_fault_pc;
    logic [31:0] lsu_fault_insn;
    logic csr_valid, csr_illegal, csr_write, csr_rd_write;
    logic [11:0] csr_addr;
    logic [4:0] csr_rd;
    logic [63:0] csr_write_data, csr_rd_data;
    logic [63:0] alu_pc, alu_result;
    logic [31:0] alu_insn;
    logic [4:0] alu_rd;

    logic vi_req_valid, vi_req_ready, vi_rsp_valid, vi_rsp_ready;
    logic [63:0] vi_req_addr;
    logic [31:0] vi_rsp_insn;
    logic vi_rsp_error, vi_rsp_page_fault;
    logic vd_req_valid, vd_req_ready, vd_req_store, vd_req_error, vd_req_page_fault;
    logic vd_req_amo, vd_req_sc, vd_sc_success;
    logic res_valid;
    logic [55:0] res_exact_pa;
    logic [2:0]  res_size;
    logic [63:0] vd_rsp_paddr;
    logic vd_amo_write_valid, vd_amo_write_ready, vd_amo_write_error;
    logic [63:0] vd_amo_write_data;
    logic res_invalidate;
    logic [63:0] vd_req_addr, vd_req_store_data, vd_rsp_data;
    logic [2:0] vd_req_size;
    logic vd_rsp_valid, vd_rsp_ready, vd_rsp_error, vd_rsp_page_fault;
    logic mmu_idle;

    assign res_invalidate = trap_take ||
                            (mret_valid && mret_legal) ||
                            (sret_valid && sret_legal) ||
                            sfence_legal ||
                            (csr_valid && !csr_illegal && csr_write && (csr_addr == 12'h180));

    fursoy_s0_fetch #(.RESET_PC(RESET_PC)) fetch (
        .clk_i, .rst_i, .fetch_enable_i(lsu_issue_ready), .redirect_i(trap_take), .fetch_pc_i(pc_q),
        .imem_req_valid_o(vi_req_valid), .imem_req_ready_i(vi_req_ready), .imem_req_addr_o(vi_req_addr),
        .imem_rsp_valid_i(vi_rsp_valid), .imem_rsp_ready_o(vi_rsp_ready),
        .imem_rsp_insn_i(vi_rsp_insn), .imem_rsp_error_i(vi_rsp_error),
        .imem_rsp_page_fault_i(vi_rsp_page_fault),
        .fetched_valid_o(fetched_valid), .fetched_ready_i(fetched_ready),
        .fetched_pc_o(fetched_pc), .fetched_insn_o(fetched_insn), .fetched_error_o(fetched_error),
        .fetched_page_fault_o(fetched_page_fault)
    );
    fursoy_s0_int_alu alu (
        .insn_valid_i(fetched_valid && !fetched_error), .pc_i(fetched_pc), .insn_i(fetched_insn),
        .rs1_i(registers[fetched_insn[19:15]]), .rs2_i(registers[fetched_insn[24:20]]),
        .retire_valid_o(alu_valid), .retire_pc_o(alu_pc), .retire_insn_o(alu_insn),
        .rd_write_o(alu_rd_write), .rd_o(alu_rd), .rd_data_o(alu_result), .illegal_o(alu_illegal)
    );
    fursoy_s0_control control (
        .insn_valid_i(fetched_valid && !fetched_error), .pc_i(fetched_pc), .insn_i(fetched_insn),
        .rs1_i(registers[fetched_insn[19:15]]), .rs2_i(registers[fetched_insn[24:20]]),
        .control_valid_o(control_valid), .rd_write_o(control_rd_write), .rd_o(control_rd),
        .rd_data_o(control_rd_data), .target_pc_o(control_target),
        .target_misaligned_o(control_misaligned)
    );
    fursoy_s0_lsu_decode lsu_decode (
        .insn_valid_i(fetched_valid && !fetched_error), .insn_i(fetched_insn), .rs1_i(registers[fetched_insn[19:15]]),
        .rs2_i(registers[fetched_insn[24:20]]), .lsu_valid_o(lsu_valid), .lsu_store_o(lsu_store),
        .lsu_lr_o(lsu_lr), .lsu_sc_o(lsu_sc), .lsu_amo_o(lsu_amo), .amo_op_o(lsu_amo_op),
        .address_o(lsu_address), .size_o(lsu_size), .load_unsigned_o(lsu_unsigned),
        .store_data_o(lsu_store_data), .misaligned_o(lsu_misaligned)
    );
    fursoy_s0_lsu_port lsu_port (
        .clk_i, .rst_i, .issue_valid_i(fetched_valid && lsu_valid && !lsu_misaligned && !trap_take), .issue_ready_o(lsu_issue_ready),
        .issue_store_i(lsu_store), .issue_lr_i(lsu_lr), .issue_sc_i(lsu_sc), .issue_amo_i(lsu_amo), .issue_amo_op_i(lsu_amo_op),
        .issue_addr_i(lsu_address), .issue_size_i(lsu_size), .issue_unsigned_i(lsu_unsigned),
        .issue_store_data_i(lsu_store_data), .issue_rd_i(fetched_insn[11:7]), .issue_pc_i(fetched_pc), .issue_insn_i(fetched_insn),
        .res_invalidate_i(res_invalidate),
        .dmem_req_valid_o(vd_req_valid), .dmem_req_ready_i(vd_req_ready),
        .dmem_req_store_o(vd_req_store), .dmem_req_amo_o(vd_req_amo), .dmem_req_sc_o(vd_req_sc),
        .res_valid_o(res_valid), .res_exact_pa_o(res_exact_pa), .res_size_o(res_size),
        .dmem_sc_success_i(vd_sc_success),
        .dmem_req_addr_o(vd_req_addr), .dmem_req_size_o(vd_req_size),
        .dmem_req_store_data_o(vd_req_store_data), .dmem_req_error_i(vd_req_error),
        .dmem_req_page_fault_i(vd_req_page_fault), .dmem_rsp_valid_i(vd_rsp_valid),
        .dmem_rsp_ready_o(vd_rsp_ready), .dmem_rsp_data_i(vd_rsp_data),
        .dmem_rsp_paddr_i(vd_rsp_paddr),
        .dmem_rsp_error_i(vd_rsp_error),
        .dmem_rsp_page_fault_i(vd_rsp_page_fault),
        .dmem_amo_write_valid_o(vd_amo_write_valid),
        .dmem_amo_write_data_o(vd_amo_write_data),
        .dmem_amo_write_ready_i(vd_amo_write_ready),
        .dmem_amo_write_error_i(vd_amo_write_error),
        .retire_valid_o(lsu_retire), .retire_rd_write_o(lsu_rd_write), .retire_rd_o(lsu_retire_rd),
        .retire_rd_data_o(lsu_retire_data), .retire_pc_o(lsu_retire_pc), .retire_insn_o(lsu_retire_insn),
        .fault_valid_o(lsu_fault), .fault_store_o(lsu_fault_store), .fault_addr_o(lsu_fault_addr),
        .fault_pc_o(lsu_fault_pc), .fault_insn_o(lsu_fault_insn), .fault_page_o(lsu_fault_page)
    );

    logic [63:0] pmpcfg0_w, pmpcfg2_w;
    logic [63:0] pmpaddr_w [16];
    logic [7:0]  pmp_cfg_w [16];
    logic [53:0] pmp_addr_w [16];

    fursoy_s0_pmp pmp (
        .clk_i,
        .rst_i,
        .csr_we_i    (csr_valid && !csr_illegal && csr_write),
        .csr_addr_i  (csr_addr),
        .csr_wdata_i (csr_write_data),
        .pmpcfg0_o   (pmpcfg0_w),
        .pmpcfg2_o   (pmpcfg2_w),
        .pmpaddr_o   (pmpaddr_w),
        .pmp_cfg_o   (pmp_cfg_w),
        .pmp_addr_o  (pmp_addr_w)
    );

    assign csr_pmpcfg0_o = pmpcfg0_w;
    assign csr_pmpcfg2_o = pmpcfg2_w;

    fursoy_s0_mmu mmu (
        .clk_i, .rst_i, .redirect_i(trap_take), .priv_mode_i(priv_mode_q),
        .mstatus_i(mstatus_q), .satp_i(satp_q),
        .pmp_cfg_i(pmp_cfg_w), .pmp_addr_i(pmp_addr_w),
        .vi_req_valid_i(vi_req_valid), .vi_req_ready_o(vi_req_ready), .vi_req_addr_i(vi_req_addr),
        .vi_rsp_valid_o(vi_rsp_valid), .vi_rsp_ready_i(vi_rsp_ready), .vi_rsp_insn_o(vi_rsp_insn),
        .vi_rsp_error_o(vi_rsp_error), .vi_rsp_page_fault_o(vi_rsp_page_fault),
        .vd_req_valid_i(vd_req_valid), .vd_req_ready_o(vd_req_ready), .vd_req_store_i(vd_req_store),
        .vd_req_addr_i(vd_req_addr), .vd_req_size_i(vd_req_size), .vd_req_store_data_i(vd_req_store_data),
        .vd_req_amo_i(vd_req_amo),
        .vd_req_sc_i(vd_req_sc),
        .res_valid_i(res_valid),
        .res_exact_pa_i(res_exact_pa),
        .res_size_i(res_size),
        .vd_sc_success_o(vd_sc_success),
        .vd_rsp_paddr_o(vd_rsp_paddr),
        .vd_amo_write_valid_i(vd_amo_write_valid),
        .vd_amo_write_data_i(vd_amo_write_data),
        .vd_amo_write_ready_o(vd_amo_write_ready),
        .vd_amo_write_error_o(vd_amo_write_error),
        .vd_req_error_o(vd_req_error), .vd_req_page_fault_o(vd_req_page_fault),
        .vd_rsp_valid_o(vd_rsp_valid), .vd_rsp_ready_i(vd_rsp_ready), .vd_rsp_data_o(vd_rsp_data),
        .vd_rsp_error_o(vd_rsp_error), .vd_rsp_page_fault_o(vd_rsp_page_fault),
        .pi_req_valid_o(imem_req_valid_o), .pi_req_ready_i(imem_req_ready_i), .pi_req_addr_o(imem_req_addr_o),
        .pi_rsp_valid_i(imem_rsp_valid_i), .pi_rsp_ready_o(imem_rsp_ready_o),
        .pi_rsp_insn_i(imem_rsp_insn_i), .pi_rsp_error_i(imem_rsp_error_i),
        .pd_req_valid_o(dmem_req_valid_o), .pd_req_ready_i(dmem_req_ready_i),
        .pd_req_store_o(dmem_req_store_o), .pd_req_ptw_o(dmem_req_ptw_o),
        .pd_req_addr_o(dmem_req_addr_o), .pd_req_size_o(dmem_req_size_o),
        .pd_req_store_data_o(dmem_req_store_data_o), .pd_req_error_i(dmem_req_error_i),
        .pd_rsp_valid_i(dmem_rsp_valid_i), .pd_rsp_ready_o(dmem_rsp_ready_o),
        .pd_rsp_data_i(dmem_rsp_data_i), .pd_rsp_error_i(dmem_rsp_error_i), .idle_o(mmu_idle)
    );
    fursoy_s0_csr csr (
        .insn_valid_i(fetched_valid && !fetched_error), .insn_i(fetched_insn),
        .rs1_i(registers[fetched_insn[19:15]]),
        .priv_mode_i(priv_mode_q),
        .mstatus_i(mstatus_q), .mie_i(mie_q),
        .mtvec_i(mtvec_q), .mscratch_i(mscratch_q), .mepc_i(mepc_q),
        .mcause_i(mcause_q), .mtval_i(mtval_q), .mip_i(mip_val),
        .medeleg_i(medeleg_q), .mideleg_i(mideleg_q), .mcounteren_i(mcounteren_q), .menvcfg_i(menvcfg_q),
        .stvec_i(stvec_q), .scounteren_i(scounteren_q),
        .sscratch_i(sscratch_q), .sepc_i(sepc_q),
        .scause_i(scause_q), .stval_i(stval_q), .senvcfg_i(senvcfg_q), .satp_i(satp_q),
        .pmpcfg0_i(pmpcfg0_w), .pmpcfg2_i(pmpcfg2_w), .pmpaddr_i(pmpaddr_w),
        .cycle_i(cycle_q),
        .csr_valid_o(csr_valid), .csr_illegal_o(csr_illegal), .csr_write_o(csr_write),
        .csr_addr_o(csr_addr), .csr_write_data_o(csr_write_data),
        .rd_write_o(csr_rd_write), .rd_o(csr_rd), .rd_data_o(csr_rd_data)
    );

    logic [63:0] mip_val;
    assign mip_val = {52'd0,
                      irq_external_i,      1'b0,
                      seip_q | irq_seip_i, 1'b0,
                      irq_timer_i,         1'b0,
                      stip_q,              1'b0,
                      irq_software_i,      1'b0,
                      ssip_q,              1'b0};
    assign csr_mip_o = mip_val;
    assign csr_mideleg_o = mideleg_q;
    assign csr_sie_o = mie_q & mideleg_q & 64'h222;
    assign csr_sip_o = mip_val & mideleg_q & 64'h222;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] pending_enabled;
    /* verilator lint_on UNUSEDSIGNAL */
    assign pending_enabled = mip_val & mie_q;

    logic m_irq_global_en, s_irq_global_en;
    assign m_irq_global_en = (priv_mode_q < 2'b11) || (priv_mode_q == 2'b11 && mstatus_q[3]);
    assign s_irq_global_en = (priv_mode_q == 2'b00) || (priv_mode_q == 2'b01 && mstatus_q[1]);

    // Interrupt eligibility per destination
    logic m_irq_eligible_mei, m_irq_eligible_msi, m_irq_eligible_mti;
    logic m_irq_eligible_sei, m_irq_eligible_ssi, m_irq_eligible_sti;
    assign m_irq_eligible_mei = pending_enabled[11] && !mideleg_q[11] && m_irq_global_en;
    assign m_irq_eligible_msi = pending_enabled[3]  && !mideleg_q[3]  && m_irq_global_en;
    assign m_irq_eligible_mti = pending_enabled[7]  && !mideleg_q[7]  && m_irq_global_en;
    assign m_irq_eligible_sei = pending_enabled[9]  && !mideleg_q[9]  && m_irq_global_en;
    assign m_irq_eligible_ssi = pending_enabled[1]  && !mideleg_q[1]  && m_irq_global_en;
    assign m_irq_eligible_sti = pending_enabled[5]  && !mideleg_q[5]  && m_irq_global_en;

    logic s_irq_eligible_sei, s_irq_eligible_ssi, s_irq_eligible_sti;
    assign s_irq_eligible_sei = pending_enabled[9] && mideleg_q[9] && s_irq_global_en;
    assign s_irq_eligible_ssi = pending_enabled[1] && mideleg_q[1] && s_irq_global_en;
    assign s_irq_eligible_sti = pending_enabled[5] && mideleg_q[5] && s_irq_global_en;

    // M destination priority: MEI (11) > MSI (3) > MTI (7) > SEI (9) > SSI (1) > STI (5)
    logic m_irq_take;
    logic [3:0] irq_code_m;
    always_comb begin
        m_irq_take = 1'b0;
        irq_code_m = 4'd0;
        if (m_irq_eligible_mei) begin
            m_irq_take = 1'b1; irq_code_m = 4'd11; // MEIP
        end else if (m_irq_eligible_msi) begin
            m_irq_take = 1'b1; irq_code_m = 4'd3;  // MSIP
        end else if (m_irq_eligible_mti) begin
            m_irq_take = 1'b1; irq_code_m = 4'd7;  // MTIP
        end else if (m_irq_eligible_sei) begin
            m_irq_take = 1'b1; irq_code_m = 4'd9;  // SEIP (non-delegated)
        end else if (m_irq_eligible_ssi) begin
            m_irq_take = 1'b1; irq_code_m = 4'd1;  // SSIP (non-delegated)
        end else if (m_irq_eligible_sti) begin
            m_irq_take = 1'b1; irq_code_m = 4'd5;  // STI (non-delegated)
        end
    end

    // S destination priority: SEI (9) > SSI (1) > STI (5)
    // Filtered by: eligible M-target interrupts before eligible S-target interrupts
    logic s_irq_take;
    logic [3:0] irq_code_s;
    always_comb begin
        s_irq_take = 1'b0;
        irq_code_s = 4'd0;
        if (!m_irq_take) begin
            if (s_irq_eligible_sei) begin
                s_irq_take = 1'b1; irq_code_s = 4'd9; // SEIP
            end else if (s_irq_eligible_ssi) begin
                s_irq_take = 1'b1; irq_code_s = 4'd1; // SSIP
            end else if (s_irq_eligible_sti) begin
                s_irq_take = 1'b1; irq_code_s = 4'd5; // STIP
            end
        end
    end

    assign ecall = fetched_valid && !fetched_error && (fetched_insn == 32'h0000_0073);
    assign ebreak = fetched_valid && !fetched_error && (fetched_insn == 32'h0010_0073);

    assign mret_valid = fetched_valid && !fetched_error && (fetched_insn == 32'h3020_0073);
    assign mret_legal = mret_valid && (priv_mode_q == 2'b11);

    assign sret_valid = fetched_valid && !fetched_error && (fetched_insn == 32'h1020_0073);
    assign sret_legal = sret_valid && ((priv_mode_q == 2'b11) ||
                                       (priv_mode_q == 2'b01 && !mstatus_q[22]));

    assign wfi_valid = fetched_valid && !fetched_error && (fetched_insn == 32'h1050_0073);
    assign wfi_legal = wfi_valid && ((priv_mode_q == 2'b11) ||
                                     (priv_mode_q == 2'b01 && !mstatus_q[21]));

    assign sfence_vma = fetched_valid && !fetched_error &&
                        (fetched_insn[31:25] == 7'b0001001) &&
                        (fetched_insn[14:12] == 3'b000) &&
                        (fetched_insn[11:7] == 5'd0) &&
                        (fetched_insn[6:0] == 7'b1110011);
    assign sfence_legal = sfence_vma && ((priv_mode_q == 2'b11) ||
                                        (priv_mode_q == 2'b01 && !mstatus_q[20]));

    assign fence = fetched_valid && !fetched_error && fetched_insn[6:0] == 7'b0001111 && fetched_insn[14:12] == 3'b000;
    assign fence_i = fetched_valid && !fetched_error && fetched_insn == 32'h0000_100f;

    assign priv_insn_illegal = (mret_valid && !mret_legal) ||
                               (sret_valid && !sret_legal) ||
                               (wfi_valid && !wfi_legal) ||
                               (sfence_vma && !sfence_legal);

    assign other_alu_illegal = fetched_valid && alu_illegal &&
                               !mret_valid && !sret_valid && !wfi_valid && !sfence_vma &&
                               !ebreak && !fence && !fence_i &&
                               !control_valid && !lsu_valid && !csr_valid;

    assign insn_illegal = other_alu_illegal || priv_insn_illegal || csr_illegal;

    logic [63:0] sync_trap_cause;
    logic [63:0] sync_trap_tval;
    always_comb begin
        sync_trap_cause = 64'd2;
        sync_trap_tval = '0;
        if (lsu_fault) begin
            sync_trap_cause = lsu_fault_page ? (lsu_fault_store ? 64'd15 : 64'd13) :
                                               (lsu_fault_store ? 64'd7 : 64'd5);
            sync_trap_tval = lsu_fault_addr;
        end else if (fetched_error) begin
            sync_trap_cause = fetched_page_fault ? 64'd12 : 64'd1;
            sync_trap_tval = fetched_pc;
        end else if (ecall) begin
            sync_trap_cause = (priv_mode_q == 2'b11) ? 64'd11 :
                              ((priv_mode_q == 2'b01) ? 64'd9 : 64'd8);
            sync_trap_tval = '0;
        end else if (ebreak) begin
            sync_trap_cause = 64'd3;
            sync_trap_tval = '0;
        end else if (control_misaligned) begin
            sync_trap_cause = 64'd0;
            sync_trap_tval = control_target;
        end else if (lsu_valid && lsu_misaligned) begin
            sync_trap_cause = (lsu_store || lsu_amo) ? 64'd6 : 64'd4;
            sync_trap_tval = lsu_address;
        end else begin
            sync_trap_cause = 64'd2;
            sync_trap_tval = {32'd0, fetched_insn};
        end
    end

    logic sync_trap_take, irq_take;
    assign sync_trap_take = fetched_error || insn_illegal || ecall || ebreak ||
                            control_misaligned || (lsu_valid && lsu_misaligned);

    assign irq_take = lsu_issue_ready && !sync_trap_take && (m_irq_take || s_irq_take);
    assign trap_take = sync_trap_take || lsu_fault || irq_take;

    // Trap delegation to S-mode: M-mode traps are NEVER delegated
    logic trap_to_s;
    assign trap_to_s = irq_take ? s_irq_take :
                       ((priv_mode_q != 2'b11) && (sync_trap_cause < 64) && medeleg_q[sync_trap_cause[5:0]]);

    assign fetched_ready = alu_valid || (mret_valid && mret_legal) ||
                           (sret_valid && sret_legal) || (wfi_valid && wfi_legal) ||
                           fence || fence_i || (sfence_legal && mmu_idle) || control_valid ||
                           csr_valid || trap_take ||
                           (fetched_valid && lsu_valid && !lsu_misaligned && lsu_issue_ready);
    assign commit_valid_o = !trap_take && (alu_valid || (mret_valid && mret_legal) ||
                            (sret_valid && sret_legal) || (wfi_valid && wfi_legal) ||
                            fence || fence_i || (sfence_legal && mmu_idle) ||
                            (control_valid && !control_misaligned) ||
                            (csr_valid && !csr_illegal) || lsu_retire);
    assign commit_pc_o = trap_take ? '0 : (alu_valid ? alu_pc : (lsu_retire ? lsu_retire_pc : (commit_valid_o ? fetched_pc : '0)));
    assign commit_insn_o = trap_take ? '0 : (alu_valid ? alu_insn : (lsu_retire ? lsu_retire_insn : (commit_valid_o ? fetched_insn : '0)));
    assign commit_rd_write_o = !trap_take && (alu_valid ? alu_rd_write : (lsu_retire ? lsu_rd_write :
                               ((csr_valid && !csr_illegal) ? csr_rd_write : (control_valid && control_rd_write && !control_misaligned))));
    assign commit_rd_o = trap_take ? '0 : (alu_valid ? alu_rd : (lsu_retire ? lsu_retire_rd :
                         ((csr_valid && !csr_illegal) ? csr_rd : (control_valid ? control_rd : '0))));
    assign commit_rd_data_o = trap_take ? '0 : (alu_valid ? alu_result : (lsu_retire ? lsu_retire_data :
                              ((csr_valid && !csr_illegal) ? csr_rd_data : (control_valid ? control_rd_data : '0))));
    assign fence_i_valid_o = commit_valid_o && fence_i;
    assign trap_valid_o = trap_take;
    assign trap_pc_o = trap_valid_o ? (lsu_fault ? lsu_fault_pc : (fetched_valid ? fetched_pc : pc_q)) : '0;
    assign trap_insn_o = trap_valid_o ? (lsu_fault ? lsu_fault_insn :
                         (fetched_valid && !fetched_error ? fetched_insn : '0)) : '0;

    assign priv_mode_o    = priv_mode_q;
    assign csr_mstatus_o  = mstatus_q;
    assign csr_mie_o      = mie_q;
    assign csr_mtvec_o    = mtvec_q;
    assign csr_mscratch_o = mscratch_q;
    assign csr_mepc_o     = mepc_q;
    assign csr_mcause_o   = mcause_q;
    assign csr_mtval_o    = mtval_q;
    assign csr_medeleg_o  = medeleg_q;

    assign csr_sstatus_o  = mstatus_q & 64'h0000_0003_000c_0122;
    assign csr_stvec_o    = stvec_q;
    assign csr_sscratch_o = sscratch_q;
    assign csr_sepc_o     = sepc_q;
    assign csr_scause_o   = scause_q;
    assign csr_stval_o    = stval_q;
    assign csr_satp_o     = satp_q;
    assign csr_menvcfg_o  = menvcfg_q;
    assign csr_senvcfg_o  = senvcfg_q;

    logic [63:0] event_pc;
    assign event_pc = lsu_fault ? lsu_fault_pc : (fetched_valid ? fetched_pc : pc_q);

    integer index;
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            priv_mode_q <= 2'b11; // Reset enters M-mode
            pc_q <= RESET_PC;
            for (index = 0; index < 32; index++) registers[index] <= '0;
            mstatus_q <= 64'h0000_000a_0000_1800; // UXL=2, SXL=2, MPP=M
            mie_q <= '0;
            mtvec_q <= RESET_MTVEC;
            mscratch_q <= '0;
            mepc_q <= '0;
            mcause_q <= '0;
            mtval_q <= '0;
            cycle_q <= '0;
            medeleg_q <= '0;
            mideleg_q <= '0;
            mcounteren_q <= '0;
            menvcfg_q <= '0;
            ssip_q <= 1'b0;
            stip_q <= 1'b0;
            seip_q <= 1'b0;
            stvec_q <= '0;
            scounteren_q <= '0;
            sscratch_q <= '0;
            sepc_q <= '0;
            scause_q <= '0;
            stval_q <= '0;
            senvcfg_q <= '0;
            satp_q <= '0;
        end else begin
            cycle_q <= cycle_q + 64'd1;
            if (trap_take) begin
                if (trap_to_s) begin
                    sepc_q <= event_pc;
                    if (irq_take) begin
                        scause_q <= {1'b1, 59'd0, irq_code_s};
                        stval_q <= '0;
                        pc_q <= (stvec_q[1:0] == 2'b01) ?
                                ({stvec_q[63:2], 2'b00} + {58'd0, irq_code_s, 2'b00}) :
                                {stvec_q[63:2], 2'b00};
                    end else begin
                        scause_q <= sync_trap_cause;
                        stval_q <= sync_trap_tval;
                        pc_q <= {stvec_q[63:2], 2'b00};
                    end
                    mstatus_q[5] <= mstatus_q[1]; // SPIE <- SIE
                    mstatus_q[1] <= 1'b0;         // SIE <- 0
                    mstatus_q[8] <= (priv_mode_q == 2'b01); // SPP <- (P == S)
                    priv_mode_q <= 2'b01;         // privilege <- S
                end else begin
                    mepc_q <= event_pc;
                    if (irq_take) begin
                        mcause_q <= {1'b1, 59'd0, irq_code_m};
                        mtval_q <= '0;
                        pc_q <= (mtvec_q[1:0] == 2'b01) ?
                                ({mtvec_q[63:2], 2'b00} + {58'd0, irq_code_m, 2'b00}) :
                                {mtvec_q[63:2], 2'b00};
                    end else begin
                        mcause_q <= sync_trap_cause;
                        mtval_q <= sync_trap_tval;
                        pc_q <= {mtvec_q[63:2], 2'b00};
                    end
                    mstatus_q[7] <= mstatus_q[3]; // MPIE <- MIE
                    mstatus_q[3] <= 1'b0;         // MIE <- 0
                    mstatus_q[12:11] <= priv_mode_q; // MPP <- P
                    priv_mode_q <= 2'b11;         // privilege <- M
                end
            end else if (alu_valid) begin
                if (alu_rd_write) registers[alu_rd] <= alu_result;
                registers[0] <= '0;
                pc_q <= fetched_pc + 64'd4;
            end else if (mret_valid && mret_legal) begin
                priv_mode_q <= mstatus_q[12:11]; // privilege <- MPP
                mstatus_q[12:11] <= 2'b00;       // MPP <- U
                mstatus_q[3] <= mstatus_q[7];    // MIE <- MPIE
                mstatus_q[7] <= 1'b1;            // MPIE <- 1
                if (mstatus_q[12:11] != 2'b11) begin
                    mstatus_q[17] <= 1'b0;       // clear MPRV if y != M
                end
                pc_q <= mepc_q;
            end else if (sret_valid && sret_legal) begin
                priv_mode_q <= mstatus_q[8] ? 2'b01 : 2'b00; // privilege <- (SPP ? S : U)
                mstatus_q[8] <= 1'b0;                        // SPP <- U
                mstatus_q[1] <= mstatus_q[5];                // SIE <- SPIE
                mstatus_q[5] <= 1'b1;                        // SPIE <- 1
                mstatus_q[17] <= 1'b0;                       // clear MPRV
                pc_q <= sepc_q;
            end else if (wfi_valid && wfi_legal) begin
                pc_q <= fetched_pc + 64'd4;
            end else if (fence || fence_i || (sfence_legal && mmu_idle)) begin
                pc_q <= fetched_pc + 64'd4;
            end else if (csr_valid && !csr_illegal) begin
                if (csr_rd_write) registers[csr_rd] <= csr_rd_data;
                registers[0] <= '0;
                if (csr_write) begin
                    unique case (csr_addr)
                        12'h300: begin
                            mstatus_q <= 64'h0000_000a_0000_0000 |
                                         (csr_write_data & 64'h0000_0000_007e_19aa) |
                                         (csr_write_data[12:11] == 2'b10 ? 64'h1800 : 64'd0);
                        end
                        12'h302: medeleg_q <= csr_write_data & 64'hb3ff;
                        12'h303: mideleg_q <= csr_write_data & 64'h222;
                        12'h304: mie_q <= csr_write_data & 64'haaa;
                        12'h305: mtvec_q <= {csr_write_data[63:2],
                                             (csr_write_data[1:0] <= 2'b01) ? csr_write_data[1:0] : 2'b00};
                        12'h306: mcounteren_q <= csr_write_data & 64'd7;
                        12'h30a: menvcfg_q <= csr_write_data & 64'd1;
                        12'h340: mscratch_q <= csr_write_data;
                        12'h341: mepc_q <= {csr_write_data[63:2], 2'b00};
                        12'h342: mcause_q <= csr_write_data;
                        12'h343: mtval_q <= csr_write_data;
                        12'h344: begin
                            ssip_q <= csr_write_data[1];
                            stip_q <= csr_write_data[5];
                            seip_q <= csr_write_data[9];
                        end

                        // S-mode CSRs
                        12'h100: begin
                            mstatus_q[1] <= csr_write_data[1]; // SIE
                            mstatus_q[5] <= csr_write_data[5]; // SPIE
                            mstatus_q[8] <= csr_write_data[8]; // SPP
                            mstatus_q[18] <= csr_write_data[18]; // SUM
                            mstatus_q[19] <= csr_write_data[19]; // MXR
                        end
                        12'h104: begin
                            mie_q <= (mie_q & ~(mideleg_q & 64'h222)) | (csr_write_data & (mideleg_q & 64'h222));
                        end
                        12'h105: stvec_q <= {csr_write_data[63:2],
                                             (csr_write_data[1:0] <= 2'b01) ? csr_write_data[1:0] : 2'b00};
                        12'h106: scounteren_q <= csr_write_data & 64'd7;
                        12'h10a: senvcfg_q <= csr_write_data & 64'd1;
                        12'h140: sscratch_q <= csr_write_data;
                        12'h141: sepc_q <= {csr_write_data[63:2], 2'b00};
                        12'h142: scause_q <= csr_write_data;
                        12'h143: stval_q <= csr_write_data;
                        12'h144: begin
                            if (mideleg_q[1]) ssip_q <= csr_write_data[1];
                        end
                        12'h180: begin
                            if (csr_write_data[63:60] == 4'h0) satp_q <= 64'd0;
                            else if (csr_write_data[63:60] == 4'h8)
                                satp_q <= {4'h8, 16'd0, csr_write_data[43:0]};
                        end

                        default: ;
                    endcase
                end
                pc_q <= fetched_pc + 64'd4;
            end else if (control_valid) begin
                if (control_rd_write) registers[control_rd] <= control_rd_data;
                registers[0] <= '0;
                pc_q <= control_target;
            end else if (lsu_retire) begin
                if (lsu_rd_write) registers[lsu_retire_rd] <= lsu_retire_data;
                registers[0] <= '0;
                pc_q <= lsu_retire_pc + 64'd4;
            end
        end
    end
endmodule
