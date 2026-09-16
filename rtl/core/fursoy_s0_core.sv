// First end-to-end in-order DUT slice. ALU, control-flow and one-outstanding
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off PINMISSING */
`include "rtl/core/fursoy_s0_pmp.sv"
`include "rtl/core/fursoy_s0_l1i.sv"
`include "rtl/core/fursoy_s0_l1d.sv"
`include "rtl/core/fursoy_s0_sb.sv"
`include "rtl/core/fursoy_s0_bpu.sv"
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
    input  logic [63:0] imem_rsp_data_i,
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
    ,output logic        fatal_halt_o
);
    logic [1:0]  priv_mode_q;
    logic [63:0] pc_q; // Stage F Fetch PC (pc_f_q)
    wire  [63:0] pc_f_q = pc_q;
    logic [63:0] pending_pc_q; // Registered next expected instruction PC for bubbles/interrupts
    logic [63:0] registers [0:31];
    logic [63:0] mstatus_q, mie_q, mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q, cycle_q;
    logic [63:0] medeleg_q, mideleg_q, mcounteren_q;
    logic [63:0] menvcfg_q, senvcfg_q, satp_q;
    logic ssip_q, stip_q, seip_q;
    logic [63:0] stvec_q, scounteren_q, sscratch_q, sepc_q, scause_q, stval_q;

    // Inter-stage pipeline register fe_q (Fetch -> Execute)
    typedef struct packed {
        logic        valid;
        logic [63:0] pc;
        logic [31:0] insn;
        logic        fetch_error;
        logic        page_fault;
        // Branch Prediction Metadata (Stage F -> Stage E)
        logic        pred_taken;
        logic [63:0] pred_target;
        logic        btb_hit;
        logic [7:0]  btb_set;
        logic        btb_way;
        logic [1:0]  ras_action;
        logic [3:0]  ras_tos_prev;
    } fe_reg_t;
    fe_reg_t fe_q;

    // Branch Prediction Unit (BPU) signals
    logic        bpu_pred_taken;
    logic [63:0] bpu_pred_target;
    logic        bpu_btb_hit;
    logic [7:0]  bpu_btb_set;
    logic        bpu_btb_way;
    logic [1:0]  bpu_ras_action;
    logic [3:0]  bpu_ras_tos_prev;

    logic        bpu_redirect_branch /* verilator public_flat_rd */;
    logic [63:0] bpu_redirect_target /* verilator public_flat_rd */;
    logic        bpu_mispredict /* verilator public_flat_rd */;

    // BPU Telemetry Events
    logic        bpu_branch_count   /* verilator public_flat_rd */;
    logic        bpu_branch_taken   /* verilator public_flat_rd */;
    logic        bpu_branch_correct /* verilator public_flat_rd */;
    logic        bpu_branch_mispred /* verilator public_flat_rd */;
    logic        bpu_jal_count      /* verilator public_flat_rd */;
    logic        bpu_jal_correct    /* verilator public_flat_rd */;
    logic        bpu_jalr_count     /* verilator public_flat_rd */;
    logic        bpu_jalr_correct   /* verilator public_flat_rd */;
    logic        bpu_ras_push_count /* verilator public_flat_rd */;
    logic        bpu_ras_pop_count  /* verilator public_flat_rd */;
    logic        bpu_ras_correct    /* verilator public_flat_rd */;
    logic        bpu_btb_hit_count  /* verilator public_flat_rd */;
    logic        bpu_btb_miss_count /* verilator public_flat_rd */;
    logic        bpu_false_hit_count/* verilator public_flat_rd */;
    logic        bpu_bubble_saved   /* verilator public_flat_rd */;

    // Public mirrors of Stage E instruction state
    logic        fe_valid_w         /* verilator public_flat_rd */;
    logic [63:0] fe_pc_w            /* verilator public_flat_rd */;
    logic [31:0] fe_insn_w          /* verilator public_flat_rd */;
    assign fe_valid_w = fe_q.valid;
    assign fe_pc_w    = fe_q.pc;
    assign fe_insn_w  = fe_q.insn;

    // L1I signals
    logic fetched_valid, fetched_ready_w, fetched_error, fetched_page_fault;
    logic [63:0] fetched_pc;
    logic [31:0] fetched_insn;
    logic l1i_miss_active, l1i_hold_active;
    logic l1i_hit_event /* verilator public_flat_rd */;
    logic l1i_miss_event /* verilator public_flat_rd */;
    logic l1i_refill_event /* verilator public_flat_rd */;
    logic l1i_early_restart_event /* verilator public_flat_rd */;
    logic [3:0] l1i_early_restart_saved_cycles /* verilator public_flat_rd */;
    logic l1i_streaming_hit_event /* verilator public_flat_rd */;
    logic l1i_refill_abort_event /* verilator public_flat_rd */;

    // L1I-NLP Telemetry Events
    logic        l1i_nlp_candidate_event /* verilator public_flat_rd */;
    logic        l1i_nlp_issued_event /* verilator public_flat_rd */;
    logic        l1i_nlp_suppressed_page /* verilator public_flat_rd */;
    logic        l1i_nlp_suppressed_pmp /* verilator public_flat_rd */;
    logic        l1i_nlp_suppressed_resident /* verilator public_flat_rd */;
    logic        l1i_nlp_suppressed_duplicate /* verilator public_flat_rd */;
    logic        l1i_nlp_useful_hit_event /* verilator public_flat_rd */;
    logic        l1i_nlp_streaming_hit_event /* verilator public_flat_rd */;
    logic        l1i_nlp_preempted_event /* verilator public_flat_rd */;
    logic        l1i_nlp_dormant_abandon_event /* verilator public_flat_rd */;
    logic        l1i_nlp_discard_redirect /* verilator public_flat_rd */;
    logic        l1i_nlp_discard_maint /* verilator public_flat_rd */;
    logic        l1i_nlp_discard_error /* verilator public_flat_rd */;
    logic        l1i_nlp_promote_event /* verilator public_flat_rd */;
    logic [4:0]  l1i_nlp_hidden_cycles /* verilator public_flat_rd */;

    // Translation interface
    logic [63:0] itrans_req_addr;
    logic        itrans_req_valid;
    logic        itrans_busy;
    logic        itrans_valid;
    logic [55:0] itrans_pa;
    logic        itrans_page_fault;
    logic        itrans_pmp_allow;
    logic        itrans_pmp_uniform_x;
    logic        pmp_flush_w;
    logic        fence_i_flush_w;
    assign fence_i_flush_w = l1d_fence_i_flush_l1i;
    assign pmp_flush_w     = l1d_pmp_flush_l1i;

    // Register file combinational reads (zero forwarding required)
    wire [63:0] rs1_val = (fe_q.insn[19:15] == 5'd0) ? 64'd0 : registers[fe_q.insn[19:15]];
    wire [63:0] rs2_val = (fe_q.insn[24:20] == 5'd0) ? 64'd0 : registers[fe_q.insn[24:20]];

    // ALU
    logic alu_valid, alu_rd_write, alu_illegal;
    logic [63:0] alu_result;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] alu_pc;
    logic [31:0] alu_insn;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [4:0]  alu_rd;

    fursoy_s0_int_alu alu (
        .insn_valid_i(fe_q.valid && !fe_q.fetch_error),
        .pc_i(fe_q.pc),
        .insn_i(fe_q.insn),
        .rs1_i(rs1_val),
        .rs2_i(rs2_val),
        .retire_valid_o(alu_valid),
        .retire_pc_o(alu_pc),
        .retire_insn_o(alu_insn),
        .rd_write_o(alu_rd_write),
        .rd_o(alu_rd),
        .rd_data_o(alu_result),
        .illegal_o(alu_illegal)
    );

    // Control engine (Branch / JAL / JALR)
    logic control_valid, control_rd_write, control_misaligned;
    logic [4:0]  control_rd;
    logic [63:0] control_rd_data, control_target;

    fursoy_s0_control control (
        .insn_valid_i(fe_q.valid && !fe_q.fetch_error),
        .pc_i(fe_q.pc),
        .insn_i(fe_q.insn),
        .rs1_i(rs1_val),
        .rs2_i(rs2_val),
        .control_valid_o(control_valid),
        .rd_write_o(control_rd_write),
        .rd_o(control_rd),
        .rd_data_o(control_rd_data),
        .target_pc_o(control_target),
        .target_misaligned_o(control_misaligned)
    );

    wire is_jal_or_jalr = (fe_q.insn[6:0] == 7'b1101111) || (fe_q.insn[6:0] == 7'b1100111);
    wire is_branch      = (fe_q.insn[6:0] == 7'b1100011);
    wire is_jal         = (fe_q.insn[6:0] == 7'b1101111);
    wire is_jalr        = (fe_q.insn[6:0] == 7'b1100111);
    wire [4:0] ctrl_rd  = fe_q.insn[11:7];
    wire [4:0] ctrl_rs1 = fe_q.insn[19:15];
    wire is_link_rd     = (ctrl_rd == 5'd1) || (ctrl_rd == 5'd5);
    wire is_link_rs1    = (ctrl_rs1 == 5'd1) || (ctrl_rs1 == 5'd5);
    wire is_ctrl_call   = (is_jal || is_jalr) && is_link_rd;
    wire is_ctrl_ret    = is_jalr && is_link_rs1 && !is_link_rd;
    logic branch_cond_met;
    always_comb begin
        case (fe_q.insn[14:12])
            3'b000: branch_cond_met = (rs1_val == rs2_val);
            3'b001: branch_cond_met = (rs1_val != rs2_val);
            3'b100: branch_cond_met = ($signed(rs1_val) < $signed(rs2_val));
            3'b101: branch_cond_met = ($signed(rs1_val) >= $signed(rs2_val));
            3'b110: branch_cond_met = (rs1_val < rs2_val);
            3'b111: branch_cond_met = (rs1_val >= rs2_val);
            default: branch_cond_met = 1'b0;
        endcase
    end
    wire branch_taken = is_jal_or_jalr || (is_branch && branch_cond_met);

    // LSU decode and port
    logic lsu_valid, lsu_store, lsu_lr, lsu_sc, lsu_amo, lsu_unsigned, lsu_misaligned;
    logic [4:0]  lsu_amo_op;
    logic [2:0]  lsu_size;
    logic [63:0] lsu_address, lsu_store_data;

    fursoy_s0_lsu_decode lsu_decode (
        .insn_valid_i(fe_q.valid && !fe_q.fetch_error),
        .insn_i(fe_q.insn),
        .rs1_i(rs1_val),
        .rs2_i(rs2_val),
        .lsu_valid_o(lsu_valid),
        .lsu_store_o(lsu_store),
        .lsu_lr_o(lsu_lr),
        .lsu_sc_o(lsu_sc),
        .lsu_amo_o(lsu_amo),
        .amo_op_o(lsu_amo_op),
        .address_o(lsu_address),
        .size_o(lsu_size),
        .load_unsigned_o(lsu_unsigned),
        .store_data_o(lsu_store_data),
        .misaligned_o(lsu_misaligned)
    );

    // Dedicated MMU data translation interface for L1D
    logic        dtrans_busy, dtrans_valid, dtrans_page_fault, dtrans_pmp_allow;
    logic [55:0] dtrans_pa;

    // L1D Interface Signals
    logic        l1d_issue_ready, l1d_idle;
    logic        l1d_stall_e /* verilator public_flat_rd */;
    logic        l1d_retire_valid /* verilator public_flat_rd */, l1d_retire_rd_write;
    logic [4:0]  l1d_retire_rd;
    logic [63:0] l1d_retire_rd_data;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] l1d_retire_pc;
    logic [31:0] l1d_retire_insn;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        l1d_fault_valid, l1d_fault_store, l1d_fault_page;
    logic [63:0] l1d_fault_addr;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] l1d_fault_pc;
    logic [31:0] l1d_fault_insn;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        l1d_maintenance_active /* verilator public_flat_rd */;
    logic        l1d_fence_i_flush_l1i, l1d_sfence_vma_flush_tlb, l1d_pmp_flush_l1i;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        l1d_fatal_error /* verilator public_flat_rd */;
    logic        l1d_fatal_event /* verilator public_flat_rd */;
    logic        l1d_refill_error_edge /* verilator public_flat_rd */;
    logic        l1d_er_pending /* verilator public_flat_rd */;
    logic        l1d_er_load_retired /* verilator public_flat_rd */;
    logic [63:0] l1d_er_retire_pc;
    logic [31:0] l1d_er_retire_insn;
    logic        fatal_halt_q /* verilator public_flat_rd */;
    logic        commit_candidate_raw;
    logic        same_er_pending_identity;
    logic        same_er_commit_candidate;
    logic        same_er_error_commit_edge;
    logic        l1d_er_raw_error_edge /* verilator public_flat_rd */;
    logic        fatal_detect_edge /* verilator public_flat_rd */;
    logic        fatal_block_now;
    logic        fatal_stop_new;
    logic        l1d_error_quiesce_edge;
    /* verilator lint_on UNUSEDSIGNAL */

`ifndef SYNTHESIS
    // Verification-only Stage-E backpressure injection.  This state is not a
    // production port and is removed from synthesized builds.
    logic verification_stall_e /* verilator public_flat_rw */;
    logic verification_l1d_error_edge /* verilator public_flat_rw */;
    initial verification_stall_e = 1'b0;
    initial verification_l1d_error_edge = 1'b0;
`else
    wire verification_stall_e = 1'b0;
    wire verification_l1d_error_edge = 1'b0;
`endif

    logic        l1d_dmem_req_valid /* verilator public_flat_rd */, l1d_dmem_req_ready, l1d_dmem_req_store;
    logic [63:0] l1d_dmem_req_addr, l1d_dmem_req_store_data;
    logic [2:0]  l1d_dmem_req_size;
    logic        l1d_dmem_req_error;
    logic        l1d_dmem_rsp_valid, l1d_dmem_rsp_ready, l1d_dmem_rsp_error;
    logic [63:0] l1d_dmem_rsp_data;

    logic        l1d_retire_ack;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        l1d_hit_event, l1d_miss_event, l1d_evict_event, l1d_refill_event;
    logic        l1d_load_hit, l1d_load_miss, l1d_store_hit, l1d_store_miss;
    logic        l1d_er_event /* verilator public_flat_rd */;
    logic [4:0]  l1d_er_saved_cycles /* verilator public_flat_rd */;
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // Store Buffer (SB) Subsystem Integration
    // -------------------------------------------------------------------------
    wire is_dram = (dtrans_pa >= 56'h0000_0000_8000_0000) && (dtrans_pa <= 56'h0000_0000_8FFF_FFFF);

    wire is_ordinary_dram_store /* verilator public_flat_rd */ = fe_q.valid && !fe_q.fetch_error &&
                                  lsu_valid && lsu_store && !lsu_sc && !lsu_amo &&
                                  !lsu_misaligned && !insn_illegal &&
                                  dtrans_valid && !dtrans_busy && !dtrans_page_fault && dtrans_pmp_allow &&
                                  is_dram;

    wire is_stage_e_load = fe_q.valid && !fe_q.fetch_error &&
                           lsu_valid && !lsu_store && !lsu_amo &&
                           !lsu_misaligned && !insn_illegal &&
                           dtrans_valid && !dtrans_busy && !dtrans_page_fault && dtrans_pmp_allow &&
                           is_dram;

    /* verilator lint_off UNUSEDSIGNAL */
    logic        sb_enqueue_stall;
    logic        sb_retire_valid;
    logic        sb_res_invalidate;
    logic        sb_load_raw_hazard;
    logic        sb_drain_req_valid;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [55:0] sb_drain_pa;
    logic [63:0] sb_drain_data;
    logic [7:0]  sb_drain_byte_mask;
    logic [2:0]  sb_drain_size;
    logic [4:0]  sb_drain_rd;
    logic [63:0] sb_drain_pc;
    logic [31:0] sb_drain_insn;
    logic        sb_grant_drain;
    logic        sb_grant_stage_e_load;
    logic        sb_empty /* verilator public_flat_rd */;
    logic        sb_full /* verilator public_flat_rd */;
    logic [3:0]  sb_count /* verilator public_flat_rd */;
    logic [2:0]  sb_starve_count /* verilator public_flat_rd */;
    logic        sb_merge_event /* verilator public_flat_rd */;

    logic        l1d_store_ack;
    logic        l1d_res_valid;
    logic [49:0] l1d_res_granule_pa;

    // SRB Interlock & Telemetry Signals
    logic        l1d_srb_busy /* verilator public_flat_rd */;
    logic [49:0] l1d_srb_line_pa /* verilator public_flat_rd */;
    logic        l1d_srb_install_event /* verilator public_flat_rd */;
    logic        l1d_srb_victim_dirty /* verilator public_flat_rd */;
    logic        l1d_srb_victim_clean /* verilator public_flat_rd */;
    logic        l1d_srb_sec_load_stall /* verilator public_flat_rd */;
    logic        sb_srb_raw_hazard /* verilator public_flat_rd */;

    // Unified Memory Drain Predicate (docs/architecture/l1d-srb-v1.md Section 5.1)
    wire memory_drained /* verilator public_flat_rd */ = sb_empty && !l1d_srb_busy && l1d_idle;

    fursoy_s0_sb #(
        .SB_DEPTH(8)
    ) sb (
        .clk_i               (clk_i),
        .rst_i               (rst_i),

        .enqueue_valid_i     (is_ordinary_dram_store && !fatal_stop_new),
        .enqueue_pa_i        (dtrans_pa),
        .enqueue_size_i      (lsu_size),
        .enqueue_data_i      (lsu_store_data),
        .enqueue_rd_i        (fe_q.insn[11:7]),
        .enqueue_pc_i        (fe_q.pc),
        .enqueue_insn_i      (fe_q.insn),
        .enqueue_stall_o     (sb_enqueue_stall),
        .retire_valid_o      (sb_retire_valid),

        .res_valid_i         (l1d_res_valid),
        .res_granule_pa_i    (l1d_res_granule_pa),
        .res_invalidate_o    (sb_res_invalidate),

        .load_check_valid_i  (is_stage_e_load),
        .load_check_pa_i     (dtrans_pa),
        .load_raw_hazard_o   (sb_load_raw_hazard),

        .l1d_idle_i          (l1d_issue_ready),
        .drain_req_valid_o   (sb_drain_req_valid),
        .drain_pa_o          (sb_drain_pa),
        .drain_data_o        (sb_drain_data),
        .drain_byte_mask_o   (sb_drain_byte_mask),
        .drain_size_o        (sb_drain_size),
        .drain_rd_o          (sb_drain_rd),
        .drain_pc_o          (sb_drain_pc),
        .drain_insn_o        (sb_drain_insn),
        .l1d_store_ack_i     (l1d_store_ack),

        .stage_e_load_req_i  (is_stage_e_load),
        .grant_sb_drain_o    (sb_grant_drain),
        .grant_stage_e_load_o(sb_grant_stage_e_load),

        .sb_empty_o          (sb_empty),
        .sb_full_o           (sb_full),
        .sb_count_o          (sb_count),
        .sb_starve_count_o   (sb_starve_count),
        .sb_merge_event_o    (sb_merge_event),

        .srb_busy_i          (l1d_srb_busy),
        .srb_line_pa_i       (l1d_srb_line_pa),
        .srb_raw_hazard_o    (sb_srb_raw_hazard)
    );

    // Maintenance tracking in Stage E
    logic fence_i_flushed_q;
    logic sfence_flushed_q;
    logic pmp_flushed_q;

    wire l1d_fence_i_req   = !fatal_stop_new && fe_q.valid && !fe_q.fetch_error && fence_i && memory_drained && !fence_i_flushed_q && !l1d_maintenance_active;
    wire fence_i_stall /* verilator public_flat_rd */ = fe_q.valid && !fe_q.fetch_error && fence_i && (!memory_drained || !fence_i_flushed_q || l1d_maintenance_active);

    wire l1d_sfence_vma_req = !fatal_stop_new && fe_q.valid && !fe_q.fetch_error && sfence_vma && sfence_legal && memory_drained && !sfence_flushed_q && !l1d_maintenance_active;
    wire sfence_stall /* verilator public_flat_rd */ = fe_q.valid && !fe_q.fetch_error && sfence_vma && sfence_legal && (!memory_drained || !sfence_flushed_q || l1d_maintenance_active);

    wire is_pmp_csr_write = fe_q.valid && !fe_q.fetch_error && csr_valid && !csr_illegal && csr_write &&
                            ((csr_addr == 12'h3a0) || (csr_addr == 12'h3a2) || (csr_addr >= 12'h3b0 && csr_addr <= 12'h3bf));
    wire l1d_pmp_flush_req = !fatal_stop_new && is_pmp_csr_write && memory_drained && !pmp_flushed_q && !l1d_maintenance_active;
    wire pmp_csr_stall /* verilator public_flat_rd */ = is_pmp_csr_write && (!memory_drained || !pmp_flushed_q || l1d_maintenance_active);

    wire res_invalidate = !fatal_stop_new && (sb_res_invalidate ||
                          trap_take ||
                          (fe_q.valid && mret_valid && mret_legal) ||
                          (fe_q.valid && sret_valid && sret_legal) ||
                          (fe_q.valid && sfence_legal && mmu_idle) ||
                          (fe_q.valid && csr_valid && !csr_illegal && csr_write && (csr_addr == 12'h180)));

    // L1D Request Multiplexer (Store Buffer Drain vs Stage E)
    logic        l1d_req_valid_w;
    logic        l1d_req_store_w;
    logic        l1d_req_lr_w;
    logic        l1d_req_sc_w;
    logic        l1d_req_amo_w;
    logic [4:0]  l1d_req_amo_op_w;
    logic [63:0] l1d_req_addr_w;
    logic [2:0]  l1d_req_size_w;
    logic        l1d_req_unsigned_w;
    logic [63:0] l1d_req_store_data_w;
    logic [4:0]  l1d_req_rd_w;
    logic [63:0] l1d_req_pc_w;
    logic [31:0] l1d_req_insn_w;
    logic [7:0]  l1d_req_byte_mask_w;
    logic        l1d_req_is_sb_drain_w;

    logic        l1d_trans_valid_w;
    logic        l1d_trans_busy_w;
    logic [55:0] l1d_trans_pa_w;
    logic        l1d_trans_page_fault_w;
    logic        l1d_trans_pmp_allow_w;

    always_comb begin
        if (sb_grant_drain) begin
            l1d_req_valid_w       = !fatal_stop_new;
            l1d_req_store_w       = 1'b1;
            l1d_req_lr_w          = 1'b0;
            l1d_req_sc_w          = 1'b0;
            l1d_req_amo_w         = 1'b0;
            l1d_req_amo_op_w      = 5'd0;
            l1d_req_addr_w        = {8'd0, sb_drain_pa};
            l1d_req_size_w        = sb_drain_size;
            l1d_req_unsigned_w    = 1'b0;
            l1d_req_store_data_w  = sb_drain_data;
            l1d_req_rd_w          = sb_drain_rd;
            l1d_req_pc_w          = sb_drain_pc;
            l1d_req_insn_w        = sb_drain_insn;
            l1d_req_byte_mask_w   = sb_drain_byte_mask;
            l1d_req_is_sb_drain_w = 1'b1;

            l1d_trans_valid_w      = 1'b1;
            l1d_trans_busy_w       = 1'b0;
            l1d_trans_pa_w         = sb_drain_pa;
            l1d_trans_page_fault_w = 1'b0;
            l1d_trans_pmp_allow_w  = 1'b1;
        end else begin
            l1d_req_valid_w       = !fatal_stop_new && fe_q.valid && lsu_valid && !lsu_misaligned && !insn_illegal && !is_ordinary_dram_store &&
                                    (!is_stage_e_load || sb_grant_stage_e_load);
            l1d_req_store_w       = lsu_store;
            l1d_req_lr_w          = lsu_lr;
            l1d_req_sc_w          = lsu_sc;
            l1d_req_amo_w         = lsu_amo;
            l1d_req_amo_op_w      = lsu_amo_op;
            l1d_req_addr_w        = lsu_address;
            l1d_req_size_w        = lsu_size;
            l1d_req_unsigned_w    = lsu_unsigned;
            l1d_req_store_data_w  = lsu_store_data;
            l1d_req_rd_w          = fe_q.insn[11:7];
            l1d_req_pc_w          = fe_q.pc;
            l1d_req_insn_w        = fe_q.insn;
            l1d_req_byte_mask_w   = 8'h00;
            l1d_req_is_sb_drain_w = 1'b0;

            l1d_trans_valid_w      = dtrans_valid;
            l1d_trans_busy_w       = dtrans_busy;
            l1d_trans_pa_w         = dtrans_pa;
            l1d_trans_page_fault_w = dtrans_page_fault;
            l1d_trans_pmp_allow_w  = dtrans_pmp_allow;
        end
    end

    fursoy_s0_l1d l1d (
        .clk_i,
        .rst_i,
        .req_valid_i         (l1d_req_valid_w),
        .req_store_i         (l1d_req_store_w),
        .req_lr_i            (l1d_req_lr_w),
        .req_sc_i            (l1d_req_sc_w),
        .req_amo_i           (l1d_req_amo_w),
        .req_amo_op_i        (l1d_req_amo_op_w),
        .req_addr_i          (l1d_req_addr_w),
        .req_size_i          (l1d_req_size_w),
        .req_unsigned_i      (l1d_req_unsigned_w),
        .req_store_data_i    (l1d_req_store_data_w),
        .req_rd_i            (l1d_req_rd_w),
        .req_pc_i            (l1d_req_pc_w),
        .req_insn_i          (l1d_req_insn_w),
        .req_byte_mask_i     (l1d_req_byte_mask_w),
        .req_is_sb_drain_i   (l1d_req_is_sb_drain_w),
        .res_invalidate_i    (res_invalidate),
        .retire_ack_i        (l1d_retire_ack),
        .redirect_i          (redirect_any_e),

        .trans_valid_i       (l1d_trans_valid_w),
        .trans_busy_i        (l1d_trans_busy_w),
        .trans_pa_i          (l1d_trans_pa_w),
        .trans_page_fault_i  (l1d_trans_page_fault_w),
        .trans_pmp_allow_i   (l1d_trans_pmp_allow_w),

        .fence_i_req_i       (l1d_fence_i_req),
        .sfence_vma_req_i    (l1d_sfence_vma_req),
        .pmp_flush_req_i     (l1d_pmp_flush_req),
        .fence_req_i         (fence && memory_drained),

        .issue_ready_o       (l1d_issue_ready),
        .l1d_idle_o          (l1d_idle),
        .stall_e_o           (l1d_stall_e),
        .retire_valid_o      (l1d_retire_valid),
        .retire_rd_write_o   (l1d_retire_rd_write),
        .retire_rd_o         (l1d_retire_rd),
        .retire_rd_data_o    (l1d_retire_rd_data),
        .retire_pc_o         (l1d_retire_pc),
        .retire_insn_o       (l1d_retire_insn),
        .store_ack_o         (l1d_store_ack),
        .res_valid_o         (l1d_res_valid),
        .res_granule_pa_o    (l1d_res_granule_pa),

        .fault_valid_o       (l1d_fault_valid),
        .fault_store_o       (l1d_fault_store),
        .fault_addr_o        (l1d_fault_addr),
        .fault_pc_o          (l1d_fault_pc),
        .fault_insn_o        (l1d_fault_insn),
        .fault_page_o        (l1d_fault_page),

        .maintenance_active_o(l1d_maintenance_active),
        .fence_i_flush_l1i_o (l1d_fence_i_flush_l1i),
        .sfence_vma_flush_tlb_o(l1d_sfence_vma_flush_tlb),
        .pmp_flush_l1i_o     (l1d_pmp_flush_l1i),
        .fatal_error_o       (l1d_fatal_error),
        .fatal_event_o       (l1d_fatal_event),
        .refill_error_edge_o (l1d_refill_error_edge),
        .er_retire_pending_o (l1d_er_pending),
        .er_load_retired_o   (l1d_er_load_retired),
        .er_retire_pc_o      (l1d_er_retire_pc),
        .er_retire_insn_o    (l1d_er_retire_insn),

        .dmem_req_valid_o    (l1d_dmem_req_valid),
        .dmem_req_ready_i    (l1d_dmem_req_ready),
        .dmem_req_store_o    (l1d_dmem_req_store),
        .dmem_req_addr_o     (l1d_dmem_req_addr),
        .dmem_req_size_o     (l1d_dmem_req_size),
        .dmem_req_store_data_o(l1d_dmem_req_store_data),
        .dmem_req_error_i    (l1d_dmem_req_error),

        .dmem_rsp_valid_i    (l1d_dmem_rsp_valid),
        .dmem_rsp_ready_o    (l1d_dmem_rsp_ready),
        .dmem_rsp_data_i     (l1d_dmem_rsp_data),
        .dmem_rsp_error_i    (l1d_dmem_rsp_error),

        .l1d_hit_event_o     (l1d_hit_event),
        .l1d_miss_event_o    (l1d_miss_event),
        .l1d_evict_event_o   (l1d_evict_event),
        .l1d_refill_event_o  (l1d_refill_event),
        .l1d_load_hit_o      (l1d_load_hit),
        .l1d_load_miss_o     (l1d_load_miss),
        .l1d_store_hit_o     (l1d_store_hit),
        .l1d_store_miss_o    (l1d_store_miss),

        .srb_busy_o          (l1d_srb_busy),
        .srb_line_pa_o       (l1d_srb_line_pa),
        .srb_install_event_o (l1d_srb_install_event),
        .srb_victim_dirty_o  (l1d_srb_victim_dirty),
        .srb_victim_clean_o  (l1d_srb_victim_clean),
        .srb_sec_load_stall_o(l1d_srb_sec_load_stall),
        .l1d_er_event_o      (l1d_er_event),
        .l1d_er_saved_cycles_o(l1d_er_saved_cycles)
    );

    // PMP Unit
    logic [63:0] pmpcfg0_w, pmpcfg2_w;
    logic [63:0] pmpaddr_w [16];
    logic [7:0]  pmp_cfg_w [16];
    logic [53:0] pmp_addr_w [16];

    fursoy_s0_pmp pmp (
        .clk_i,
        .rst_i,
        .csr_we_i    (commit_fire && csr_valid && !csr_illegal && csr_write),
        .csr_addr_i  (csr_addr),
        .csr_wdata_i (csr_write_data),
        .pmpcfg0_o   (pmpcfg0_w),
        .pmpcfg2_o   (pmpcfg2_w),
        .pmpaddr_o   (pmpaddr_w),
        .pmp_cfg_o   (pmp_cfg_w),
        .pmp_addr_o  (pmp_addr_w),
        .pmp_flush_o () // Handled via l1d maintenance flush
    );

    assign csr_pmpcfg0_o = pmpcfg0_w;
    assign csr_pmpcfg2_o = pmpcfg2_w;

    // MMU PTW memory interface signals
    logic        mmu_pd_req_valid, mmu_pd_req_ready, mmu_pd_req_store, mmu_pd_req_ptw, mmu_pd_req_error;
    logic [63:0] mmu_pd_req_addr, mmu_pd_req_store_data;
    logic [2:0]  mmu_pd_req_size;
    logic        mmu_pd_rsp_valid, mmu_pd_rsp_ready, mmu_pd_rsp_error;
    logic [63:0] mmu_pd_rsp_data;
    logic        mmu_idle;
    logic        sfence_all_w;
    logic [63:0] sfence_va_w;

    assign sfence_all_w = (fe_q.insn[19:15] == 5'd0);
    assign sfence_va_w  = rs1_val;

    // MMU
    fursoy_s0_mmu mmu (
        .clk_i, .rst_i, .redirect_i(redirect_any_e || l1d_error_quiesce_edge), .priv_mode_i(priv_mode_q),
        .mstatus_i(mstatus_q), .satp_i(satp_q),
        .sfence_vma_i(l1d_sfence_vma_flush_tlb), .sfence_all_i(sfence_all_w), .sfence_va_i(sfence_va_w),
        .pmp_cfg_i(pmp_cfg_w), .pmp_addr_i(pmp_addr_w),
        .itrans_req_addr_i(itrans_req_addr), .itrans_req_valid_i(itrans_req_valid),
        .itrans_busy_o(itrans_busy), .itrans_valid_o(itrans_valid),
        .itrans_pa_o(itrans_pa), .itrans_page_fault_o(itrans_page_fault),
        .itrans_pmp_allow_o(itrans_pmp_allow),
        .itrans_pmp_uniform_x_o(itrans_pmp_uniform_x),

        .dtrans_req_addr_i(lsu_address),
        .dtrans_req_valid_i((!fatal_stop_new || same_er_pending_identity) && fe_q.valid && lsu_valid && !lsu_misaligned && !insn_illegal),
        .dtrans_req_store_i(lsu_store),
        .dtrans_req_amo_i(lsu_amo),
        .dtrans_req_size_i(lsu_size),
        .dtrans_busy_o(dtrans_busy),
        .dtrans_valid_o(dtrans_valid),
        .dtrans_pa_o(dtrans_pa),
        .dtrans_page_fault_o(dtrans_page_fault),
        .dtrans_pmp_allow_o(dtrans_pmp_allow),

        .vi_req_valid_i(1'b0), .vi_req_ready_o(), .vi_req_addr_i(64'd0),
        .vi_rsp_valid_o(), .vi_rsp_ready_i(1'b0), .vi_rsp_insn_o(),
        .vi_rsp_error_o(), .vi_rsp_page_fault_o(),

        .vd_req_valid_i(1'b0), .vd_req_ready_o(), .vd_req_store_i(1'b0),
        .vd_req_addr_i(64'd0), .vd_req_size_i(3'd0), .vd_req_store_data_i(64'd0),
        .vd_req_amo_i(1'b0), .vd_req_sc_i(1'b0),
        .res_valid_i(1'b0), .res_exact_pa_i(56'd0), .res_size_i(3'd0),
        .vd_sc_success_o(), .vd_rsp_paddr_o(),
        .vd_amo_write_valid_i(1'b0), .vd_amo_write_data_i(64'd0),
        .vd_amo_write_ready_o(), .vd_amo_write_error_o(),
        .vd_req_error_o(), .vd_req_page_fault_o(),
        .vd_rsp_valid_o(), .vd_rsp_ready_i(1'b0), .vd_rsp_data_o(),
        .vd_rsp_error_o(), .vd_rsp_page_fault_o(),

        .pi_req_valid_o(), .pi_req_ready_i(1'b0), .pi_req_addr_o(),
        .pi_rsp_valid_i(1'b0), .pi_rsp_ready_o(),
        .pi_rsp_insn_i(32'd0), .pi_rsp_error_i(1'b0),

        .pd_req_valid_o(mmu_pd_req_valid), .pd_req_ready_i(mmu_pd_req_ready),
        .pd_req_store_o(mmu_pd_req_store), .pd_req_ptw_o(mmu_pd_req_ptw),
        .pd_req_addr_o(mmu_pd_req_addr), .pd_req_size_o(mmu_pd_req_size),
        .pd_req_store_data_o(mmu_pd_req_store_data), .pd_req_error_i(mmu_pd_req_error),
        .pd_rsp_valid_i(mmu_pd_rsp_valid), .pd_rsp_ready_o(mmu_pd_rsp_ready),
        .pd_rsp_data_i(mmu_pd_rsp_data), .pd_rsp_error_i(mmu_pd_rsp_error),
        .idle_o(mmu_idle),
        .itlb_hit_event_o(), .itlb_miss_event_o(), .itlb_refill_event_o(),
        .dtlb_hit_event_o(), .dtlb_miss_event_o(), .dtlb_refill_event_o()
    );

    // -------------------------------------------------------------------------
    // Shared Memory Bus Arbitration (PTW > L1D with Serialization Override)
    // -------------------------------------------------------------------------
    logic ptw_pending_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ptw_pending_q <= 1'b0;
        end else begin
            if (mmu_pd_req_valid && mmu_pd_req_ready && !mmu_pd_req_store) begin
                ptw_pending_q <= 1'b1;
            end else if (dmem_rsp_valid_i && dmem_rsp_ready_o && ptw_pending_q) begin
                ptw_pending_q <= 1'b0;
            end
        end
    end

    // Serialization override: during L1D maintenance flushes, PTW is blocked
    // Once the MMU has presented a PTW request, arbitration must not withdraw
    // it.  New translation inputs are blocked separately at the producers.
    wire ptw_active_req = mmu_pd_req_valid && !l1d_maintenance_active;
    wire l1d_bus_busy   = !l1d_issue_ready || l1d_srb_busy;

    // Priority 1: PTW (when active and L1D is not in an atomic burst, or awaiting response)
    // Priority 2: L1D
    wire ptw_grant /* verilator public_flat_rd */ = ptw_pending_q || (ptw_active_req && !l1d_bus_busy);

    assign dmem_req_valid_o      = ptw_grant ? mmu_pd_req_valid : l1d_dmem_req_valid;
    assign dmem_req_store_o      = ptw_grant ? mmu_pd_req_store : l1d_dmem_req_store;
    assign dmem_req_ptw_o        = ptw_grant ? mmu_pd_req_ptw   : 1'b0;
    assign dmem_req_addr_o       = ptw_grant ? mmu_pd_req_addr  : l1d_dmem_req_addr;
    assign dmem_req_size_o       = ptw_grant ? mmu_pd_req_size  : l1d_dmem_req_size;
    assign dmem_req_store_data_o = ptw_grant ? mmu_pd_req_store_data : l1d_dmem_req_store_data;
    assign mmu_pd_req_error      = ptw_grant ? dmem_req_error_i : 1'b0;
    assign l1d_dmem_req_error    = !ptw_grant ? dmem_req_error_i : 1'b0;

    assign mmu_pd_req_ready      = ptw_grant && dmem_req_ready_i;
    assign l1d_dmem_req_ready    = !ptw_grant && dmem_req_ready_i;

    assign mmu_pd_rsp_valid      = ptw_pending_q && dmem_rsp_valid_i;
    assign mmu_pd_rsp_data       = dmem_rsp_data_i;
    assign mmu_pd_rsp_error      = dmem_rsp_error_i;

    assign l1d_dmem_rsp_valid    = !ptw_pending_q && dmem_rsp_valid_i;
    assign l1d_dmem_rsp_data     = dmem_rsp_data_i;
    assign l1d_dmem_rsp_error    = dmem_rsp_error_i;

    assign dmem_rsp_ready_o      = ptw_pending_q ? mmu_pd_rsp_ready : l1d_dmem_rsp_ready;

    // CSR Unit
    logic csr_valid, csr_illegal, csr_write, csr_rd_write;
    logic [11:0] csr_addr;
    logic [4:0]  csr_rd;
    logic [63:0] csr_write_data, csr_rd_data;

    fursoy_s0_csr csr (
        .insn_valid_i(fe_q.valid && !fe_q.fetch_error), .insn_i(fe_q.insn),
        .rs1_i(rs1_val),
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

    // Interrupt Infrastructure
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

    // Instruction Special Decodes in Stage E
    logic ecall, ebreak, fence, fence_i /* verilator public_flat_rd */;
    logic mret_valid /* verilator public_flat_rd */, mret_legal /* verilator public_flat_rd */, sret_valid /* verilator public_flat_rd */, sret_legal /* verilator public_flat_rd */, wfi_valid, wfi_legal;
    logic sfence_vma /* verilator public_flat_rd */, sfence_legal /* verilator public_flat_rd */;
    logic priv_insn_illegal, other_alu_illegal, insn_illegal;

    assign ecall  = fe_q.valid && !fe_q.fetch_error && (fe_q.insn == 32'h0000_0073);
    assign ebreak = fe_q.valid && !fe_q.fetch_error && (fe_q.insn == 32'h0010_0073);

    assign mret_valid = fe_q.valid && !fe_q.fetch_error && (fe_q.insn == 32'h3020_0073);
    assign mret_legal = mret_valid && (priv_mode_q == 2'b11);

    assign sret_valid = fe_q.valid && !fe_q.fetch_error && (fe_q.insn == 32'h1020_0073);
    assign sret_legal = sret_valid && ((priv_mode_q == 2'b11) ||
                                       (priv_mode_q == 2'b01 && !mstatus_q[22]));

    assign wfi_valid = fe_q.valid && !fe_q.fetch_error && (fe_q.insn == 32'h1050_0073);
    assign wfi_legal = wfi_valid && ((priv_mode_q == 2'b11) ||
                                     (priv_mode_q == 2'b01 && !mstatus_q[21]));

    assign sfence_vma = fe_q.valid && !fe_q.fetch_error &&
                        (fe_q.insn[31:25] == 7'b0001001) &&
                        (fe_q.insn[14:12] == 3'b000) &&
                        (fe_q.insn[11:7] == 5'd0) &&
                        (fe_q.insn[6:0] == 7'b1110011);
    assign sfence_legal = sfence_vma && ((priv_mode_q == 2'b11) ||
                                         (priv_mode_q == 2'b01 && !mstatus_q[20]));

    assign fence   = fe_q.valid && !fe_q.fetch_error && fe_q.insn[6:0] == 7'b0001111 && fe_q.insn[14:12] == 3'b000;
    assign fence_i = fe_q.valid && !fe_q.fetch_error && fe_q.insn == 32'h0000_100f;

    assign priv_insn_illegal = (mret_valid && !mret_legal) ||
                               (sret_valid && !sret_legal) ||
                               (wfi_valid && !wfi_legal) ||
                               (sfence_vma && !sfence_legal);

    assign other_alu_illegal = fe_q.valid && alu_illegal &&
                               !mret_valid && !sret_valid && !wfi_valid && !sfence_vma &&
                               !ebreak && !fence && !fence_i &&
                               !control_valid && !lsu_valid && !csr_valid;

    assign insn_illegal = other_alu_illegal || priv_insn_illegal || csr_illegal;

    // Synchronous Trap Cause & TVAL Generation
    logic [63:0] sync_trap_cause;
    logic [63:0] sync_trap_tval;
    always_comb begin
        sync_trap_cause = 64'd2;
        sync_trap_tval = '0;
        if (l1d_fault_valid) begin
            sync_trap_cause = l1d_fault_page ? (l1d_fault_store ? 64'd15 : 64'd13) :
                                               (l1d_fault_store ? 64'd7 : 64'd5);
            sync_trap_tval = l1d_fault_addr;
        end else if (fe_q.fetch_error) begin
            sync_trap_cause = fe_q.page_fault ? 64'd12 : 64'd1;
            sync_trap_tval = fe_q.pc;
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
            sync_trap_tval = {32'd0, fe_q.insn};
        end
    end

    // Oldest-Instruction Synchronous Exception Dominance (P1-4)
    wire sync_trap_e /* verilator public_flat_rd */ = fe_q.valid && (fe_q.fetch_error || insn_illegal || ecall || ebreak ||
                                      control_misaligned || (lsu_valid && lsu_misaligned) || l1d_fault_valid);

    // Trap / Interrupt Control (P0-2, P1-4, SB Section 9.6)
    wire pending_irq_eligible = (m_irq_take || s_irq_take);
    // Interrupts can be taken at instruction boundary when not in an indivisible LSU transaction,
    // and synchronous exception takes absolute priority over interrupts.
    // Store Buffer and SRB must be drained completely before vectoring to mtvec (Section 5.2).
    wire trap_sb_drained = sb_empty && !l1d_srb_busy;
    wire irq_take = !fatal_stop_new && !sync_trap_e && trap_sb_drained && pending_irq_eligible && (!fe_q.valid || (!stall_e && !lsu_valid));
    wire trap_take_raw = (sync_trap_e || irq_take) && trap_sb_drained;
    wire trap_take /* verilator public_flat_rd */ = trap_take_raw && !fatal_block_now;

    // Trap delegation to S-mode: M-mode exceptions/interrupts are NEVER delegated
    wire trap_to_s = irq_take ? s_irq_take :
                     ((priv_mode_q != 2'b11) && (sync_trap_cause < 64) && medeleg_q[sync_trap_cause[5:0]]);

    // Architectural Resume-PC Rule (P0-2)
    logic [63:0] saved_epc;
    always_comb begin
        if (sync_trap_e) begin
            saved_epc = fe_q.pc;
        end else if (fe_q.valid) begin
            saved_epc = fe_q.pc;
        end else begin
            saved_epc = pending_pc_q;
        end
    end

    // Trap vector target calculation (mtvec / stvec)
    logic [63:0] trap_target_pc_e;
    always_comb begin
        if (trap_to_s) begin
            trap_target_pc_e = (stvec_q[1:0] == 2'b01 && irq_take) ?
                               ({stvec_q[63:2], 2'b00} + {58'd0, irq_code_s, 2'b00}) :
                               {stvec_q[63:2], 2'b00};
        end else begin
            trap_target_pc_e = (mtvec_q[1:0] == 2'b01 && irq_take) ?
                               ({mtvec_q[63:2], 2'b00} + {58'd0, irq_code_m, 2'b00}) :
                               {mtvec_q[63:2], 2'b00};
        end
    end

    // CSR write serialization classification (P1-3)
    wire csr_flush_e = csr_valid && !csr_illegal && csr_write &&
                       ((csr_addr == 12'h180) || // satp
                        (csr_addr == 12'h300) || // mstatus
                        (csr_addr == 12'h100) || // sstatus
                        (csr_addr == 12'h3a0) || (csr_addr == 12'h3a2) || // pmpcfg0/2
                        (csr_addr >= 12'h3b0 && csr_addr <= 12'h3bf));    // pmpaddr0..15

    // Stage E Redirect Sources
    wire redirect_trap_e   = trap_take;
    wire redirect_mret_e   = !fatal_stop_new && fe_q.valid && !sync_trap_e && (mret_valid && mret_legal) && memory_drained;
    wire redirect_sret_e   = !fatal_stop_new && fe_q.valid && !sync_trap_e && (sret_valid && sret_legal) && memory_drained;
    wire redirect_branch_e = !fatal_stop_new && bpu_redirect_branch;
    wire redirect_flush_e  = !fatal_stop_new && fe_q.valid && !sync_trap_e && !irq_take &&
                             ((fence_i && fence_i_flushed_q && !l1d_maintenance_active && memory_drained) ||
                              (sfence_legal && sfence_flushed_q && !l1d_maintenance_active && mmu_idle && memory_drained) ||
                              (csr_flush_e && (!is_pmp_csr_write || (pmp_flushed_q && !l1d_maintenance_active)) && memory_drained));
    wire redirect_any_e    = redirect_trap_e || redirect_mret_e || redirect_sret_e || redirect_branch_e || redirect_flush_e;

    // Stage E Stall Conditions
    wire store_sb_stall     = is_ordinary_dram_store && sb_enqueue_stall;
    wire lsu_trans_stall /* verilator public_flat_rd */ = fe_q.valid && lsu_valid && !lsu_misaligned && !insn_illegal &&
                              (dtrans_busy || !dtrans_valid);
    wire lsu_sb_empty_stall /* verilator public_flat_rd */ = fe_q.valid && lsu_valid && !lsu_misaligned && !insn_illegal &&
                              (!is_dram || lsu_sc || lsu_amo || lsu_lr) && !memory_drained && !l1d_retire_valid;
    wire lsu_load_stall /* verilator public_flat_rd */ = is_stage_e_load && !l1d_retire_valid &&
                              (sb_load_raw_hazard || !sb_grant_stage_e_load || l1d_stall_e) && !l1d_fault_valid;
    wire lsu_other_stall /* verilator public_flat_rd */ = fe_q.valid && lsu_valid && !lsu_misaligned && !insn_illegal && !is_ordinary_dram_store && !is_stage_e_load &&
                              (l1d_stall_e || !l1d_retire_valid) && !l1d_fault_valid;

    wire lsu_stall /* verilator public_flat_rd */ = store_sb_stall || lsu_trans_stall || lsu_sb_empty_stall || lsu_load_stall || lsu_other_stall;

    wire fence_stall /* verilator public_flat_rd */ = fe_q.valid && !fe_q.fetch_error && fence && !memory_drained;
    wire csr_drain_stall /* verilator public_flat_rd */ = csr_flush_e && !memory_drained;
    wire ret_drain_stall /* verilator public_flat_rd */ = fe_q.valid && !fe_q.fetch_error && ((mret_valid && mret_legal) || (sret_valid && sret_legal)) && !memory_drained;
    wire trap_drain_stall /* verilator public_flat_rd */ = sync_trap_e && !trap_sb_drained;
    wire stall_e /* verilator public_flat_rd */ = lsu_stall || fence_stall || sfence_stall || fence_i_stall || pmp_csr_stall ||
                     csr_drain_stall || ret_drain_stall || trap_drain_stall || l1d_maintenance_active ||
                     fatal_halt_q || verification_stall_e;

    // Stage F Stall Definition (P1-2)
    wire serialize_active = l1d_maintenance_active;
    logic stall_f /* verilator public_flat_rd */;
    assign stall_f = rst_i || stall_e || l1i_miss_active || itrans_busy || l1i_hold_active || serialize_active;

    // Redirect Target Mux (Priorities 1 to 5, independent of stall_f)
    logic [63:0] redirect_target_e;
    always_comb begin
        if (redirect_trap_e)        redirect_target_e = trap_target_pc_e;       // Priority 1: Trap/interrupt vector
        else if (redirect_mret_e)   redirect_target_e = mepc_q;                 // Priority 2: MRET return PC
        else if (redirect_sret_e)   redirect_target_e = sepc_q;                 // Priority 3: SRET return PC
        else if (redirect_branch_e) redirect_target_e = bpu_redirect_target;    // Priority 4: Branch / JAL / JALR mispredict or false BTB hit
        else                        redirect_target_e = fe_q.pc + 64'd4;        // Priority 5: CSR serialize / FENCE.I / SFENCE
    end

    // Stage F qualified transfer signal (BPU Section 4.2 / 5.2)
    wire transfer_fire_f = fetched_valid && !stall_f && !redirect_any_e && !fatal_stop_new && !l1d_refill_error_edge;

    // Next-PC Mux Priority (P1-2, BPU Section 5.2)
    logic [63:0] next_pc_f;
    always_comb begin
        if (redirect_any_e)                         next_pc_f = redirect_target_e;
        else if (stall_f)                           next_pc_f = pc_f_q;         // Priority 2: Stall hold
        else if (transfer_fire_f && bpu_pred_taken) next_pc_f = bpu_pred_target; // Priority 3: Predicted Taken Target
        else if (transfer_fire_f)                   next_pc_f = pc_f_q + 64'd4; // Priority 4: Sequential streaming advance
        else                                        next_pc_f = pc_f_q;         // Priority 5: Fetch hold
    end

    wire [63:0] fetch_pc_w = next_pc_f;
    wire fetch_enable_w = !rst_i && !serialize_active && !fatal_stop_new && !l1d_refill_error_edge;
    assign fetched_ready_w = !stall_e && !fatal_stop_new && !l1d_refill_error_edge;

    // L1 Instruction Cache Instantiation
    wire mem_bus_busy_w /* verilator public_flat_rd */ = dmem_req_valid_o || ptw_grant || l1d_dmem_req_valid || l1d_srb_busy;

    fursoy_s0_l1i #(.RESET_PC(RESET_PC)) l1i (
        .clk_i,
        .rst_i,
        .fetch_enable_i      (fetch_enable_w),
        .redirect_i          (redirect_any_e || l1d_error_quiesce_edge),
        .halt_i              (fatal_halt_q || l1d_error_quiesce_edge),
        .fetch_pc_i          (fetch_pc_w),
        .fetched_valid_o     (fetched_valid),
        .fetched_ready_i     (fetched_ready_w),
        .fetched_pc_o        (fetched_pc),
        .fetched_insn_o      (fetched_insn),
        .fetched_error_o     (fetched_error),
        .fetched_page_fault_o(fetched_page_fault),

        .trans_req_addr_o    (itrans_req_addr),
        .trans_req_valid_o   (itrans_req_valid),
        .trans_busy_i        (itrans_busy),
        .trans_valid_i       (itrans_valid),
        .trans_pa_i          (itrans_pa),
        .trans_page_fault_i  (itrans_page_fault),
        .trans_pmp_allow_i   (itrans_pmp_allow),
        .trans_pmp_uniform_x_i(itrans_pmp_uniform_x),

        .mem_bus_busy_i      (mem_bus_busy_w),

        .fence_i_flush_i     (fence_i_flush_w),
        .pmp_flush_i         (pmp_flush_w),

        .imem_req_valid_o    (imem_req_valid_o),
        .imem_req_ready_i    (imem_req_ready_i),
        .imem_req_addr_o     (imem_req_addr_o),
        .imem_rsp_valid_i    (imem_rsp_valid_i),
        .imem_rsp_ready_o    (imem_rsp_ready_o),
        .imem_rsp_data_i     (imem_rsp_data_i),
        .imem_rsp_error_i    (imem_rsp_error_i),

        .l1i_hit_event_o     (l1i_hit_event),
        .l1i_miss_event_o    (l1i_miss_event),
        .l1i_refill_event_o  (l1i_refill_event),
        .l1i_miss_active_o   (l1i_miss_active),
        .l1i_hold_active_o   (l1i_hold_active),
        .l1i_early_restart_event_o       (l1i_early_restart_event),
        .l1i_early_restart_saved_cycles_o(l1i_early_restart_saved_cycles),
        .l1i_streaming_hit_event_o       (l1i_streaming_hit_event),
        .l1i_refill_abort_event_o        (l1i_refill_abort_event),

        .l1i_nlp_candidate_event_o        (l1i_nlp_candidate_event),
        .l1i_nlp_issued_event_o           (l1i_nlp_issued_event),
        .l1i_nlp_suppressed_page_o        (l1i_nlp_suppressed_page),
        .l1i_nlp_suppressed_pmp_o         (l1i_nlp_suppressed_pmp),
        .l1i_nlp_suppressed_resident_o    (l1i_nlp_suppressed_resident),
        .l1i_nlp_suppressed_duplicate_o   (l1i_nlp_suppressed_duplicate),
        .l1i_nlp_useful_hit_event_o       (l1i_nlp_useful_hit_event),
        .l1i_nlp_streaming_hit_event_o    (l1i_nlp_streaming_hit_event),
        .l1i_nlp_preempted_event_o        (l1i_nlp_preempted_event),
        .l1i_nlp_dormant_abandon_event_o  (l1i_nlp_dormant_abandon_event),
        .l1i_nlp_discard_redirect_o       (l1i_nlp_discard_redirect),
        .l1i_nlp_discard_maint_o          (l1i_nlp_discard_maint),
        .l1i_nlp_discard_error_o          (l1i_nlp_discard_error),
        .l1i_nlp_promote_event_o          (l1i_nlp_promote_event),
        .l1i_nlp_hidden_cycles_o          (l1i_nlp_hidden_cycles)
    );

    // Commit and Retirement Interface (Section 4.3.2)
    wire lsu_retire_fire /* verilator public_flat_rd */ = is_ordinary_dram_store ? !sb_enqueue_stall : (lsu_valid && !lsu_misaligned && l1d_retire_valid);

    assign commit_candidate_raw = fe_q.valid && !trap_take_raw && !sync_trap_e && !stall_e && (
        alu_valid ||
        (mret_valid && mret_legal && memory_drained) ||
        (sret_valid && sret_legal && memory_drained) ||
        (wfi_valid && wfi_legal) ||
        (fence && memory_drained) ||
        (fence_i && fence_i_flushed_q && !l1d_maintenance_active && memory_drained) ||
        (sfence_legal && sfence_flushed_q && !l1d_maintenance_active && mmu_idle && memory_drained) ||
        (control_valid && !control_misaligned) ||
        (csr_valid && !csr_illegal && (!is_pmp_csr_write || (pmp_flushed_q && !l1d_maintenance_active)) && (!csr_flush_e || memory_drained)) ||
        lsu_retire_fire
    );

    assign same_er_pending_identity = fe_q.valid && !fe_q.fetch_error && lsu_valid &&
                                      !lsu_store && !lsu_amo && !lsu_misaligned && !insn_illegal &&
                                      l1d_er_pending &&
                                      (l1d_er_retire_pc == fe_q.pc) &&
                                      (l1d_er_retire_insn == fe_q.insn);
    assign same_er_commit_candidate = commit_candidate_raw && same_er_pending_identity;
    // Every accepted refill-error edge directly blocks architectural activity.
    // The simulation-only term verifies this boundary without adding a
    // production port; synthesis reduces it to the real L1D indication alone.
    assign l1d_er_raw_error_edge = l1d_refill_error_edge || verification_l1d_error_edge;
    assign same_er_error_commit_edge = !fatal_halt_q && l1d_er_raw_error_edge &&
                                       same_er_commit_candidate && !l1d_er_load_retired;
    assign fatal_detect_edge = l1d_fatal_event ||
                               (l1d_er_raw_error_edge &&
                                (l1d_er_load_retired || same_er_commit_candidate));
    assign fatal_block_now = fatal_halt_q || l1d_fatal_event || l1d_er_raw_error_edge;
    assign fatal_stop_new = fatal_block_now;
    assign l1d_error_quiesce_edge = l1d_fatal_event || l1d_er_raw_error_edge;

    wire commit_fire /* verilator public_flat_rd */ = commit_candidate_raw &&
        (!fatal_block_now || same_er_error_commit_edge);

    assign commit_valid_o = commit_fire;
    assign l1d_retire_ack = commit_fire && is_stage_e_load && l1d_er_pending &&
                            (l1d_retire_pc == fe_q.pc) && (l1d_retire_insn == fe_q.insn);
    assign commit_pc_o    = commit_fire ? fe_q.pc : 64'd0;
    assign commit_insn_o  = commit_fire ? fe_q.insn : 32'd0;
    assign commit_rd_write_o = commit_fire && (
        alu_valid ? alu_rd_write :
        (lsu_valid && !lsu_misaligned) ? (is_ordinary_dram_store ? 1'b0 : l1d_retire_rd_write) :
        (csr_valid && !csr_illegal) ? csr_rd_write :
        (control_valid && !control_misaligned) ? control_rd_write : 1'b0
    );
    assign commit_rd_o = commit_fire ? (
        alu_valid ? alu_rd :
        (lsu_valid && !lsu_misaligned) ? (is_ordinary_dram_store ? 5'd0 : l1d_retire_rd) :
        (csr_valid && !csr_illegal) ? csr_rd :
        (control_valid && !control_misaligned) ? control_rd : 5'd0
    ) : 5'd0;
    assign commit_rd_data_o = commit_fire ? (
        alu_valid ? alu_result :
        (lsu_valid && !lsu_misaligned) ? (is_ordinary_dram_store ? 64'd0 : l1d_retire_rd_data) :
        (csr_valid && !csr_illegal) ? csr_rd_data :
        (control_valid && !control_misaligned) ? control_rd_data : 64'd0
    ) : 64'd0;

    assign fence_i_valid_o = commit_valid_o && fence_i;
    assign trap_valid_o    = trap_take;
    assign trap_pc_o       = trap_valid_o ? saved_epc : 64'd0;
    assign trap_insn_o     = trap_valid_o ? (fe_q.valid && !fe_q.fetch_error ? fe_q.insn : 32'd0) : 32'd0;

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
    assign fatal_halt_o   = fatal_halt_q;

    // Branch Prediction Unit (BPU) Instantiation
    wire is_satp_csr_write = commit_fire && csr_valid && !csr_illegal && csr_write && (csr_addr == 12'h180);

    fursoy_s0_bpu #(
        .SETS(256),
        .WAYS(2),
        .RAS_DEPTH(16)
    ) bpu (
        .clk_i,
        .rst_i,

        // Stage F
        .fetch_pc_i          (pc_f_q),
        .transfer_fire_f_i   (transfer_fire_f),
        .pred_taken_o        (bpu_pred_taken),
        .pred_target_o       (bpu_pred_target),
        .btb_hit_o           (bpu_btb_hit),
        .btb_set_o           (bpu_btb_set),
        .btb_way_o           (bpu_btb_way),
        .ras_action_o        (bpu_ras_action),
        .ras_tos_prev_o      (bpu_ras_tos_prev),

        // Stage E
        .commit_fire_i       (commit_fire),
        .stall_e_i           (stall_e),
        .trap_take_i         (trap_take),
        .sync_trap_e_i       (sync_trap_e),
        .fe_valid_i          (fe_q.valid),
        .fe_pc_i             (fe_q.pc),
        .fe_insn_i           (fe_q.insn),
        .fe_btb_hit_i        (fe_q.btb_hit),
        .fe_btb_set_i        (fe_q.btb_set),
        .fe_btb_way_i        (fe_q.btb_way),
        .fe_pred_taken_i     (fe_q.pred_taken),
        .fe_pred_target_i    (fe_q.pred_target),
        .fe_ras_action_i     (fe_q.ras_action),
        .fe_ras_tos_prev_i   (fe_q.ras_tos_prev),

        // Control outcomes
        .control_valid_i     (control_valid),
        .control_misaligned_i(control_misaligned),
        .actual_taken_i      (branch_taken),
        .actual_target_i     (control_target),
        .is_branch_i         (is_branch),
        .is_jal_i            (is_jal),
        .is_jalr_i           (is_jalr),
        .is_call_i           (is_ctrl_call),
        .is_ret_i            (is_ctrl_ret),

        // Redirects
        .redirect_branch_o   (bpu_redirect_branch),
        .redirect_target_o   (bpu_redirect_target),
        .bpu_mispredict_o    (bpu_mispredict),

        // Maintenance
        .fence_i_flush_i     (l1d_fence_i_flush_l1i),
        .sfence_vma_flush_i  (l1d_sfence_vma_flush_tlb),
        .satp_write_flush_i  (is_satp_csr_write),

        // Telemetry
        .bpu_branch_count_o  (bpu_branch_count),
        .bpu_branch_taken_o  (bpu_branch_taken),
        .bpu_branch_correct_o(bpu_branch_correct),
        .bpu_branch_mispred_o(bpu_branch_mispred),
        .bpu_jal_count_o     (bpu_jal_count),
        .bpu_jal_correct_o   (bpu_jal_correct),
        .bpu_jalr_count_o    (bpu_jalr_count),
        .bpu_jalr_correct_o  (bpu_jalr_correct),
        .bpu_ras_push_count_o(bpu_ras_push_count),
        .bpu_ras_pop_count_o (bpu_ras_pop_count),
        .bpu_ras_correct_o   (bpu_ras_correct),
        .bpu_btb_hit_count_o (bpu_btb_hit_count),
        .bpu_btb_miss_count_o(bpu_btb_miss_count),
        .bpu_false_hit_count_o(bpu_false_hit_count),
        .bpu_bubble_saved_o  (bpu_bubble_saved)
    );

    integer index;
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            priv_mode_q  <= 2'b11; // Reset enters M-mode
            pc_q         <= RESET_PC;
            pending_pc_q <= RESET_PC;
            fe_q         <= '0;
            for (index = 0; index < 32; index++) registers[index] <= '0;
            mstatus_q    <= 64'h0000_000a_0000_1800; // UXL=2, SXL=2, MPP=M
            mie_q        <= '0;
            mtvec_q      <= RESET_MTVEC;
            mscratch_q   <= '0;
            mepc_q       <= '0;
            mcause_q     <= '0;
            mtval_q      <= '0;
            cycle_q      <= '0;
            medeleg_q    <= '0;
            mideleg_q    <= '0;
            mcounteren_q <= '0;
            menvcfg_q    <= '0;
            ssip_q       <= 1'b0;
            stip_q       <= 1'b0;
            seip_q       <= 1'b0;
            stvec_q      <= '0;
            scounteren_q <= '0;
            sscratch_q   <= '0;
            sepc_q       <= '0;
            scause_q     <= '0;
            stval_q      <= '0;
            senvcfg_q    <= '0;
            satp_q       <= '0;
            fence_i_flushed_q <= 1'b0;
            sfence_flushed_q  <= 1'b0;
            pmp_flushed_q     <= 1'b0;
            fatal_halt_q      <= 1'b0;
        end else begin
            if (l1d_fatal_error || fatal_detect_edge)
                fatal_halt_q <= 1'b1;

            if (!fatal_block_now) begin
            cycle_q <= cycle_q + 64'd1;

            if (l1d_fence_i_flush_l1i) fence_i_flushed_q <= 1'b1;
            if (l1d_sfence_vma_flush_tlb) sfence_flushed_q <= 1'b1;
            if (l1d_pmp_flush_l1i) pmp_flushed_q <= 1'b1;

            if (redirect_any_e) begin
                fence_i_flushed_q <= 1'b0;
                sfence_flushed_q  <= 1'b0;
                pmp_flushed_q     <= 1'b0;
            end

            // Fetch PC update
            pc_q <= next_pc_f;

            // Pending PC update for bubbles and interrupts
            if (redirect_any_e) begin
                pending_pc_q <= next_pc_f;
            end else if (commit_fire) begin
                if (control_valid && !control_misaligned && branch_taken) begin
                    pending_pc_q <= control_target;
                end else begin
                    pending_pc_q <= fe_q.pc + 64'd4;
                end
            end else if (fe_q.valid) begin
                pending_pc_q <= fe_q.pc;
            end

            // Stage F/E Pipeline Register Update
            if (redirect_any_e) begin
                fe_q.valid        <= 1'b0;
                fe_q.pc           <= 64'd0;
                fe_q.insn         <= 32'd0;
                fe_q.fetch_error  <= 1'b0;
                fe_q.page_fault   <= 1'b0;
                fe_q.pred_taken   <= 1'b0;
                fe_q.pred_target  <= 64'd0;
                fe_q.btb_hit      <= 1'b0;
                fe_q.btb_set      <= 8'd0;
                fe_q.btb_way      <= 1'b0;
                fe_q.ras_action   <= 2'b00;
                fe_q.ras_tos_prev <= 4'd0;
            end else if (stall_e) begin
                fe_q <= fe_q;
            end else begin
                fe_q.valid        <= fetched_valid;
                fe_q.pc           <= fetched_pc;
                fe_q.insn         <= fetched_insn;
                fe_q.fetch_error  <= fetched_error;
                fe_q.page_fault   <= fetched_page_fault;
                fe_q.pred_taken   <= bpu_pred_taken;
                fe_q.pred_target  <= bpu_pred_target;
                fe_q.btb_hit      <= bpu_btb_hit;
                fe_q.btb_set      <= bpu_btb_set;
                fe_q.btb_way      <= bpu_btb_way;
                fe_q.ras_action   <= bpu_ras_action;
                fe_q.ras_tos_prev <= bpu_ras_tos_prev;
            end
            end

            // Register File Writeback (Zero Forwarding)
            if (commit_valid_o && commit_rd_write_o && (commit_rd_o != 5'd0)) begin
                registers[commit_rd_o] <= commit_rd_data_o;
            end
            registers[0] <= '0;

            // Trap / Interrupt Entry
            if (trap_take) begin
                if (trap_to_s) begin
                    sepc_q <= saved_epc;
                    if (irq_take) begin
                        scause_q <= {1'b1, 59'd0, irq_code_s};
                        stval_q  <= '0;
                    end else begin
                        scause_q <= sync_trap_cause;
                        stval_q  <= sync_trap_tval;
                    end
                    mstatus_q[5] <= mstatus_q[1]; // SPIE <- SIE
                    mstatus_q[1] <= 1'b0;         // SIE <- 0
                    mstatus_q[8] <= (priv_mode_q == 2'b01); // SPP <- (P == S)
                    priv_mode_q  <= 2'b01;         // privilege <- S
                end else begin
                    mepc_q <= saved_epc;
                    if (irq_take) begin
                        mcause_q <= {1'b1, 59'd0, irq_code_m};
                        mtval_q  <= '0;
                    end else begin
                        mcause_q <= sync_trap_cause;
                        mtval_q  <= sync_trap_tval;
                    end
                    mstatus_q[7] <= mstatus_q[3]; // MPIE <- MIE
                    mstatus_q[3] <= 1'b0;         // MIE <- 0
                    mstatus_q[12:11] <= priv_mode_q; // MPP <- P
                    priv_mode_q  <= 2'b11;         // privilege <- M
                end
            end else if (commit_fire && mret_valid && mret_legal) begin
                priv_mode_q <= mstatus_q[12:11]; // privilege <- MPP
                mstatus_q[12:11] <= 2'b00;       // MPP <- U
                mstatus_q[3] <= mstatus_q[7];    // MIE <- MPIE
                mstatus_q[7] <= 1'b1;            // MPIE <- 1
                if (mstatus_q[12:11] != 2'b11) begin
                    mstatus_q[17] <= 1'b0;       // clear MPRV if y != M
                end
            end else if (commit_fire && sret_valid && sret_legal) begin
                priv_mode_q <= mstatus_q[8] ? 2'b01 : 2'b00; // privilege <- (SPP ? S : U)
                mstatus_q[8] <= 1'b0;                        // SPP <- U
                mstatus_q[1] <= mstatus_q[5];                // SIE <- SPIE
                mstatus_q[5] <= 1'b1;                        // SPIE <- 1
                mstatus_q[17] <= 1'b0;                       // clear MPRV
            end else if (commit_fire && csr_valid && !csr_illegal && csr_write) begin
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
                        seip_q <= (fe_q.insn[14:12] == 3'b001 || fe_q.insn[14:12] == 3'b101) ? csr_write_data[9] :
                                  (fe_q.insn[14:12] == 3'b010 || fe_q.insn[14:12] == 3'b110) ?
                                      (seip_q | (fe_q.insn[14] ? 1'b0 : rs1_val[9])) :
                                      (seip_q & ~(fe_q.insn[14] ? 1'b0 : rs1_val[9]));
                    end

                    // S-mode CSRs
                    12'h100: begin
                        mstatus_q[1]  <= csr_write_data[1];  // SIE
                        mstatus_q[5]  <= csr_write_data[5];  // SPIE
                        mstatus_q[8]  <= csr_write_data[8];  // SPP
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
        end
    end
endmodule
