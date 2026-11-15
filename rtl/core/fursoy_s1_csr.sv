`ifndef FURSOY_S1_CSR_SV
`define FURSOY_S1_CSR_SV

// =============================================================================
// Fursoy Slice-1 CSR & Privileged Architecture Subsystem (fursoy_s1_csr)
// =============================================================================
// Reference: docs/architecture/s-mode-bare-v1.md
//            docs/architecture/sv39-mmu-v1.md
//            docs/architecture/slice1-m4-frontend-v1.md
//
// Features:
// - Full RV64 M-mode and S-mode architectural CSR registers with standard WARL masks.
// - Privilege mode tracking (priv_mode_q: 2'b11 M-mode, 2'b01 S-mode, 2'b00 U-mode).
// - Execution stage (Port 0):
//     - Decodes CSR address and validates privilege (csr_addr[9:8] <= priv_mode_q).
//     - Read-only check: rejects writes to read-only CSRs (csr_addr[11:10] == 2'b11).
//     - S-mode TVM gating for satp access and SFENCE.VMA (mstatus.TVM).
//     - S-mode TSR gating for SRET (mstatus.TSR).
//     - S-mode TW gating for WFI (mstatus.TW).
//     - Counter access gates (mcounteren, scounteren) for cycle/time/instret.
//     - Computes RMW result (CSRRW/RS/RC, immediate forms, zero-rs1 read suppression).
//     - Flags illegal instruction exception (Cause 2).
// - Precise Serialization & Retirement:
//     - UOP_SYSTEM issues on Port 0 only when at ROB head.
//     - Side-effects commit at ROB head retirement.
//     - MRET/SRET privilege transitions, MIE/SIE restoration, and PC redirect.
//     - Precise trap vector redirection (mtvec / stvec) on any ROB head exception.
//     - satp/mstatus/sfence.vma serialization with pipeline flush and PC+4 redirect.
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_ks_adder.sv"

module fursoy_s1_csr
    import fursoy_s1_pkg::*;
#(
    parameter logic [63:0] RESET_MTVEC = 64'h0000_0000_8000_0000,
    parameter logic [63:0] RESET_STVEC = 64'h0000_0000_8000_0000
) (
    input  logic              clk_i,
    input  logic              rst_i,
    input  logic [1:0]        priv_mode_i,
    input  logic [63:0]       mstatus_i,

    // -------------------------------------------------------------------------
    // Execution Stage Interface (Port 0 EX0)
    // -------------------------------------------------------------------------
    input  logic              p0_sys_valid_i,
    input  uop_subop_t        p0_sys_subop_i,
    input  logic [11:0]       p0_sys_csr_addr_i,
    input  logic [4:0]        p0_sys_rs1_field_i, // inst[19:15]
    input  logic [63:0]       p0_sys_rs1_val_i,   // operand A
    input  logic [63:0]       p0_sys_rs2_val_i,   // operand B
    input  logic [63:0]       p0_sys_pc_i,
    input  rob_idx_t          p0_sys_rob_idx_i,

    output logic [63:0]       p0_sys_rdata_o,
    output logic              p0_sys_illegal_o,

    // -------------------------------------------------------------------------
    // Retirement / Commit Interface (from 2-Wide Superscalar ROB)
    // -------------------------------------------------------------------------
    input  logic [1:0]        retire_valid_i,
    input  rob_idx_t          retire_rob_idx_i     [1:0],
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]       retire_pc_i          [1:0],
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic              retire_exception_i,
    input  logic [4:0]        retire_exc_cause_i,
    input  logic [63:0]       retire_exc_pc_i,
    input  logic [63:0]       retire_exc_val_i,

    // Milestone 8 Phase A Floating-Point Retirement Interface
    input  logic [1:0]        retire_fp_dest_valid_i,
    input  logic [1:0]        retire_is_fp_i,
    input  logic [4:0]        retire_fflags_i      [1:0],

    // Milestone 8 Phase D Vector Retirement Interface
    input  logic [1:0]        retire_vec_dest_valid_i,

    // Milestone 8 Phase D Vector Configuration & Fault-Only-First Interface
    input  logic              vec_cfg_valid_i,
    input  logic [63:0]       vec_cfg_avl_i,
    input  logic [63:0]       vec_cfg_vtype_i,
    input  logic              vec_cfg_rs1_is_zero_i,
    input  logic              vec_cfg_rd_is_zero_i,
    output logic [63:0]       vec_cfg_new_vl_o,
    output logic [63:0]       vec_cfg_new_vtype_o,
    output logic              vec_cfg_illegal_o,

    input  logic              fof_fault_valid_i,
    input  logic [63:0]       fof_fault_elem_i,

    // -------------------------------------------------------------------------
    // Architectural State Outputs
    // -------------------------------------------------------------------------
    output logic [1:0]        priv_mode_o,
    output logic [63:0]       mstatus_o,
    output logic [63:0]       satp_o,

    // Milestone 8 Floating-Point Context Outputs
    output logic [1:0]        mstatus_fs_o,
    output logic [2:0]        frm_o,
    output logic [4:0]        fflags_o,

    // Milestone 8 Vector Context Outputs
    output logic [1:0]        mstatus_vs_o,
    output logic [63:0]       vtype_o,
    output logic [63:0]       vl_o,
    output logic [63:0]       vstart_o,
    output logic [63:0]       vcsr_o,
    output logic [1:0]        vxrm_o,
    output logic              vxsat_o,

    // Redirect & Flush Outputs
    output logic              sys_redirect_valid_o,
    output logic [63:0]       sys_redirect_target_o,
    output logic              sys_flush_valid_o,
    output logic              sys_pending_valid_o,

    // SFENCE.VMA Pulse Output
    output logic              sfence_vma_valid_o,
    output logic [63:0]       sfence_vma_va_o,
    output logic [15:0]       sfence_vma_asid_o,

    // L1D Clean Maintenance Handshake for SFENCE.VMA (P0-3)
    input  logic              dcache_clean_all_done_i,
    input  logic              sq_empty_i,
    output logic              dcache_clean_all_req_o,
    output logic              csr_sfence_active_o,

    // Architectural MIE output (P1-3)
    output logic [63:0]       csr_mie_o,

    // CSR Observability Outputs (Diagnostics)
    output logic [63:0]       csr_mepc_o,
    output logic [63:0]       csr_mcause_o,
    output logic [63:0]       csr_mtval_o,
    output logic [63:0]       csr_sepc_o,
    output logic [63:0]       csr_scause_o,
    output logic [63:0]       csr_stval_o,
    output logic [63:0]       csr_mtvec_o,
    output logic [63:0]       csr_stvec_o,

    // HPM Interface (Milestone 5)
    output logic [11:0]       hpm_csr_raddr_o,
    input  logic [63:0]       hpm_csr_rdata_i,
    input  logic              hpm_csr_hit_i,
    output logic              hpm_we_o,
    output logic [11:0]       hpm_waddr_o,
    output logic [63:0]       hpm_wdata_o,

    // Milestone 9 Phase A: Asynchronous Interrupt Inputs
    input  logic              irq_timer_i,
    input  logic              irq_software_i,
    input  logic              irq_external_i,
    input  logic              irq_seip_i,

    // Milestone 9 Phase A: ROB Head Instruction & Pipeline Status
    input  logic              rob_empty_i,
    input  logic [63:0]       rob_head_pc_i,
    input  logic [63:0]       fe_pc_i,
    input  logic              frontend_en_i,
    input  logic              recovering_i,
    input  logic              reconstructing_i,
    input  logic              retire_replay_i,

    // Milestone 9 Phase A: Candidate Interrupt Status & WFI Sleep Output
    output logic              irq_pending_valid_o,
    output logic [63:0]       irq_pending_cause_o,
    output logic [1:0]        irq_pending_priv_o,
    output logic              wfi_sleep_o,
    output logic [63:0]       csr_mip_o,
    output logic [63:0]       csr_mideleg_o,
    output logic [63:0]       csr_sie_o,
    output logic [63:0]       csr_sip_o,

    // Testbench Direct CSR State Injection Ports
    input  logic              test_csr_we_i,
    input  logic [11:0]       test_csr_addr_i,
    input  logic [63:0]       test_csr_wdata_i
);

    // =========================================================================
    // 1. Architectural Registers
    // =========================================================================
    logic [1:0]  priv_mode_q;

    // M-mode registers
    // mstatus[62:0]: reset value 0x0000_000a_0000_1800 (UXL=2, SXL=2, MPP=M); bit 63 (SD) is derived
    logic [62:0] mstatus_q;
    logic [63:0] mstatus_i_prev_q;
    logic [63:0] medeleg_q;
    logic [63:0] mideleg_q;
    logic [63:0] mie_q;
    logic [63:0] mtvec_q;
    logic [63:0] mcounteren_q;
    logic [63:0] menvcfg_q;
    logic [63:0] mscratch_q;
    logic [63:0] mepc_q;
    logic [63:0] mcause_q;
    logic [63:0] mtval_q;
    logic [63:0] mip_q;

    // S-mode registers
    logic [63:0] stvec_q;
    logic [63:0] scounteren_q;
    logic [63:0] senvcfg_q;
    logic [63:0] sscratch_q;
    logic [63:0] sepc_q;
    logic [63:0] scause_q;
    logic [63:0] stval_q;
    logic [63:0] satp_q;

    // Milestone 8 Floating-Point CSR Registers
    logic [2:0] frm_q;
    logic [4:0] fflags_q;

    // Milestone 8 Phase D Vector CSR Registers
    logic [63:0] vtype_q;
    logic [63:0] vl_q;
    logic [63:0] vstart_q;
    logic [1:0]  vxrm_q;
    logic        vxsat_q;

    // Effective privilege mode and architectural mstatus state
    // (mstatus_i is captured on reset and edge-triggered synchronously into mstatus_q;
    // combinational cone reads mstatus_q directly)
    wire [1:0]  eff_priv    = (priv_mode_i != 2'b11) ? priv_mode_i : priv_mode_q;
    wire [1:0]  eff_fs      = mstatus_q[14:13];
    wire [1:0]  eff_vs      = mstatus_q[10:9];
    wire        eff_sd      = (eff_fs == 2'b11) || (eff_vs == 2'b11);
    wire [63:0] eff_mstatus = {eff_sd, mstatus_q[62:0]};

    // Connect architectural outputs
    assign priv_mode_o  = eff_priv;
    assign mstatus_o    = eff_mstatus;
    assign satp_o       = satp_q;
    assign mstatus_fs_o = eff_fs;
    assign mstatus_vs_o = eff_vs;
    assign frm_o        = frm_q;
    assign fflags_o     = fflags_q;
    assign vtype_o      = vtype_q;
    assign vl_o         = vl_q;
    assign vstart_o     = vstart_q;
    assign vcsr_o       = {61'd0, vxrm_q, vxsat_q};
    assign vxrm_o       = vxrm_q;
    assign vxsat_o      = vxsat_q;

    assign csr_mepc_o   = mepc_q;
    assign csr_mcause_o = mcause_q;
    assign csr_mtval_o  = mtval_q;
    assign csr_sepc_o   = sepc_q;
    assign csr_scause_o = scause_q;
    assign csr_stval_o  = stval_q;
    assign csr_mtvec_o  = mtvec_q;
    assign csr_stvec_o  = stvec_q;

    // Milestone 9 Phase A: WFI State Machine Registers
    logic        wfi_sleep_q;
    logic [63:0] wfi_resume_pc_q;

    // Milestone 9 Phase A: Dynamic MIP Vector
    wire [63:0] mip_val = {52'd0,
                           irq_external_i,        1'b0, // [11:10] MEIP
                           mip_q[9] | irq_seip_i, 1'b0, // [9:8]   SEIP
                           irq_timer_i,           1'b0, // [7:6]   MTIP
                           mip_q[5],              1'b0, // [5:4]   STIP
                           irq_software_i,        1'b0, // [3:2]   MSIP
                           mip_q[1],              1'b0  // [1:0]   SSIP
                          };

    assign csr_mip_o     = mip_val;
    assign csr_mideleg_o = mideleg_q;
    assign wfi_sleep_o   = wfi_sleep_q;

    // Aliased supervisor CSR values (incorporating FS [14:13], VS [10:9] and SD [63])
    wire [63:0] sstatus_val = {eff_sd, 29'd0, 2'b10, 12'd0, mstatus_q[19:18], 3'd0, eff_fs, 2'b00, eff_vs, mstatus_q[8], 2'd0, mstatus_q[5], 3'd0, mstatus_q[1], 1'b0};
    wire [63:0] sie_val     = mie_q & mideleg_q & 64'h222;
    wire [63:0] sip_val     = mip_val & mideleg_q & 64'h222;

    assign csr_sie_o = sie_val;
    assign csr_sip_o = sip_val;

    // Interrupt Evaluation & Priority Arbitration
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0] pending_enabled = mip_val & mie_q;
    /* verilator lint_on UNUSEDSIGNAL */

    wire m_irq_global_en = (eff_priv < 2'b11) || (eff_priv == 2'b11 && eff_mstatus[3]);
    wire s_irq_global_en = (eff_priv == 2'b00) || (eff_priv == 2'b01 && eff_mstatus[1]);

    wire m_irq_eligible_mei = pending_enabled[11] && !mideleg_q[11] && m_irq_global_en;
    wire m_irq_eligible_msi = pending_enabled[3]  && !mideleg_q[3]  && m_irq_global_en;
    wire m_irq_eligible_mti = pending_enabled[7]  && !mideleg_q[7]  && m_irq_global_en;
    wire m_irq_eligible_sei = pending_enabled[9]  && !mideleg_q[9]  && m_irq_global_en;
    wire m_irq_eligible_ssi = pending_enabled[1]  && !mideleg_q[1]  && m_irq_global_en;
    wire m_irq_eligible_sti = pending_enabled[5]  && !mideleg_q[5]  && m_irq_global_en;

    wire s_irq_eligible_sei = pending_enabled[9] && mideleg_q[9] && s_irq_global_en;
    wire s_irq_eligible_ssi = pending_enabled[1] && mideleg_q[1] && s_irq_global_en;
    wire s_irq_eligible_sti = pending_enabled[5] && mideleg_q[5] && s_irq_global_en;

    // M destination priority: MEI (11) > MSI (3) > MTI (7) > SEI (9) > SSI (1) > STI (5)
    logic        m_irq_take;
    logic [63:0] m_irq_cause;
    always_comb begin
        m_irq_take  = 1'b0;
        m_irq_cause = 64'd0;
        if (m_irq_eligible_mei) begin
            m_irq_take  = 1'b1;
            m_irq_cause = {1'b1, 59'd0, 4'd11}; // MEIP
        end else if (m_irq_eligible_msi) begin
            m_irq_take  = 1'b1;
            m_irq_cause = {1'b1, 59'd0, 4'd3};  // MSIP
        end else if (m_irq_eligible_mti) begin
            m_irq_take  = 1'b1;
            m_irq_cause = {1'b1, 59'd0, 4'd7};  // MTIP
        end else if (m_irq_eligible_sei) begin
            m_irq_take  = 1'b1;
            m_irq_cause = {1'b1, 59'd0, 4'd9};  // SEIP (non-delegated)
        end else if (m_irq_eligible_ssi) begin
            m_irq_take  = 1'b1;
            m_irq_cause = {1'b1, 59'd0, 4'd1};  // SSIP (non-delegated)
        end else if (m_irq_eligible_sti) begin
            m_irq_take  = 1'b1;
            m_irq_cause = {1'b1, 59'd0, 4'd5};  // STI (non-delegated)
        end
    end

    // S destination priority: SEI (9) > SSI (1) > STI (5)
    logic        s_irq_take;
    logic [63:0] s_irq_cause;
    always_comb begin
        s_irq_take  = 1'b0;
        s_irq_cause = 64'd0;
        if (!m_irq_take) begin
            if (s_irq_eligible_sei) begin
                s_irq_take  = 1'b1;
                s_irq_cause = {1'b1, 59'd0, 4'd9}; // SEIP
            end else if (s_irq_eligible_ssi) begin
                s_irq_take  = 1'b1;
                s_irq_cause = {1'b1, 59'd0, 4'd1}; // SSIP
            end else if (s_irq_eligible_sti) begin
                s_irq_take  = 1'b1;
                s_irq_cause = {1'b1, 59'd0, 4'd5}; // STIP
            end
        end
    end

    wire irq_candidate_valid = m_irq_take || s_irq_take;
    wire [63:0] irq_candidate_cause = m_irq_take ? m_irq_cause : s_irq_cause;
    wire [1:0]  irq_candidate_priv  = m_irq_take ? 2'b11 : 2'b01;

    assign irq_pending_valid_o = irq_candidate_valid;
    assign irq_pending_cause_o = irq_candidate_cause;
    assign irq_pending_priv_o  = irq_candidate_priv;

    wire [63:0] captured_pc = (!rob_empty_i) ? rob_head_pc_i : fe_pc_i;

    // =========================================================================
    // 2. Port 0 Execution Stage: CSR Decode, Privilege Check, and RMW
    // =========================================================================
    logic [63:0] old_csr_val;
    logic        csr_implemented;
    logic        csr_read_only;

    assign hpm_csr_raddr_o = p0_sys_csr_addr_i;

    always_comb begin
        csr_implemented = 1'b1;
        csr_read_only   = (p0_sys_csr_addr_i[11:10] == 2'b11);
        old_csr_val     = 64'd0;

        case (p0_sys_csr_addr_i)
            // Milestone 8 Floating-Point CSRs (fcsr, frm, fflags)
            12'h001: old_csr_val = {59'd0, fflags_q};
            12'h002: old_csr_val = {61'd0, frm_q};
            12'h003: old_csr_val = {56'd0, frm_q, fflags_q};

            // Milestone 8 Phase D Vector CSRs
            12'h008: old_csr_val = vstart_q;
            12'h009: old_csr_val = {63'd0, vxsat_q};
            12'h00a: old_csr_val = {62'd0, vxrm_q};
            12'h00f: old_csr_val = {61'd0, vxrm_q, vxsat_q};
            12'hc20: begin
                old_csr_val   = vl_q;
                csr_read_only = 1'b1;
            end
            12'hc21: begin
                old_csr_val   = vtype_q;
                csr_read_only = 1'b1;
            end
            12'hc22: begin
                old_csr_val   = 64'd32; // VLENB = VLEN/8 = 32
                csr_read_only = 1'b1;
            end

            // M-mode CSRs
            12'h300: old_csr_val = eff_mstatus;
            12'h301: old_csr_val = 64'd0;       // misa (WARL zero)
            12'h302: old_csr_val = medeleg_q;
            12'h303: old_csr_val = mideleg_q;
            12'h304: old_csr_val = mie_q;
            12'h305: old_csr_val = mtvec_q;
            12'h306: old_csr_val = mcounteren_q;
            12'h30a: old_csr_val = menvcfg_q;
            12'h340: old_csr_val = mscratch_q;
            12'h341: old_csr_val = mepc_q;
            12'h342: old_csr_val = mcause_q;
            12'h343: old_csr_val = mtval_q;
            12'h344: old_csr_val = mip_val;

            // Machine Identification (Read-Only 0)
            12'hf11, 12'hf12, 12'hf13, 12'hf14: begin
                old_csr_val   = 64'd0;
                csr_read_only = 1'b1;
            end

            // S-mode CSRs
            12'h100: old_csr_val = sstatus_val;
            12'h104: old_csr_val = sie_val;
            12'h105: old_csr_val = stvec_q;
            12'h106: old_csr_val = scounteren_q;
            12'h10a: old_csr_val = senvcfg_q;
            12'h140: old_csr_val = sscratch_q;
            12'h141: old_csr_val = sepc_q;
            12'h142: old_csr_val = scause_q;
            12'h143: old_csr_val = stval_q;
            12'h144: old_csr_val = sip_val;
            12'h180: old_csr_val = satp_q;

            default: begin
                if (hpm_csr_hit_i) begin
                    old_csr_val     = hpm_csr_rdata_i;
                    csr_implemented = 1'b1;
                    csr_read_only   = (p0_sys_csr_addr_i[11:10] == 2'b11);
                end else begin
                    csr_implemented = 1'b0;
                    csr_read_only   = 1'b0;
                    old_csr_val     = 64'd0;
                end
            end
        endcase
    end

    // Write Intent & Source Operand Generation
    // RISC-V Priv Spec (§3.1.9): CSRRS/CSRRC read-modify-write on mip uses only the
    // software-writable SEIP bit (mip_q[9]), not the external irq_seip_i wire, while
    // p0_sys_rdata_o (rd) still returns mip_val (mip_q[9] | irq_seip_i).
    wire is_imm_csr = (p0_sys_subop_i == SYS_CSRRWI ||
                       p0_sys_subop_i == SYS_CSRRSI ||
                       p0_sys_subop_i == SYS_CSRRCI);

    wire [63:0] rmw_csr_val = (p0_sys_csr_addr_i == 12'h344)
                            ? {mip_val[63:10], mip_q[9], mip_val[8:0]}
                            : old_csr_val;

    logic [63:0] source_operand;
    logic [63:0] csr_write_val;
    logic        csr_write_intent;

    always_comb begin
        source_operand   = is_imm_csr ? {59'd0, p0_sys_rs1_field_i} : p0_sys_rs1_val_i;
        csr_write_intent = 1'b0;
        csr_write_val    = 64'd0;

        case (p0_sys_subop_i)
            SYS_CSRRW, SYS_CSRRWI: begin
                csr_write_intent = 1'b1;
                csr_write_val    = source_operand;
            end
            SYS_CSRRS, SYS_CSRRSI: begin
                csr_write_intent = (p0_sys_rs1_field_i != 5'd0);
                csr_write_val    = rmw_csr_val | source_operand;
            end
            SYS_CSRRC, SYS_CSRRCI: begin
                csr_write_intent = (p0_sys_rs1_field_i != 5'd0);
                csr_write_val    = rmw_csr_val & ~source_operand;
            end
            default: begin
                csr_write_intent = 1'b0;
                csr_write_val    = 64'd0;
            end
        endcase
    end

    // Privilege and Exception Check (flattened parallel decode cone)
    wire       priv_is_u     = (eff_priv == 2'b00);
    wire       priv_is_s     = (eff_priv == 2'b01);
    wire       priv_is_m     = (eff_priv == 2'b11);
    wire [1:0] csr_priv_lvl  = p0_sys_csr_addr_i[9:8];
    wire       csr_priv_bad  = (csr_priv_lvl == 2'b10) || (eff_priv < csr_priv_lvl);
    wire       csr_cnt_range = (p0_sys_csr_addr_i[11:5] == 7'b1100000); // 12'hc00..12'hc1f
    wire [5:0] csr_cnt_idx   = {1'b0, p0_sys_csr_addr_i[4:0]};
    wire       csr_cnt_bad   = csr_cnt_range &&
                               ((priv_is_s && !mcounteren_q[csr_cnt_idx]) ||
                                (priv_is_u && (!mcounteren_q[csr_cnt_idx] || !scounteren_q[csr_cnt_idx])));
    wire       csr_tvm_bad   = (p0_sys_csr_addr_i == 12'h180) && priv_is_s && mstatus_q[20];
    wire       csr_fp_addr   = (p0_sys_csr_addr_i[11:2] == 10'h000) && (p0_sys_csr_addr_i[1:0] != 2'b00);
    wire       csr_vec_addr  = (p0_sys_csr_addr_i == 12'h008) || (p0_sys_csr_addr_i == 12'h009) ||
                               (p0_sys_csr_addr_i == 12'h00a) || (p0_sys_csr_addr_i == 12'h00f) ||
                               ((p0_sys_csr_addr_i[11:2] == 10'h308) && (p0_sys_csr_addr_i[1:0] != 2'b11));
    wire       csr_fs_bad    = csr_fp_addr && (eff_fs == 2'b00);
    wire       csr_vs_bad    = csr_vec_addr && (eff_vs == 2'b00);

    wire       csr_access_illegal = csr_priv_bad || !csr_implemented || (csr_read_only && csr_write_intent) ||
                                    csr_tvm_bad || csr_cnt_bad || csr_fs_bad || csr_vs_bad;

    logic sys_illegal;

    always_comb begin
        sys_illegal = 1'b0;

        if (p0_sys_valid_i) begin
            case (p0_sys_subop_i)
                SYS_MRET:       sys_illegal = !priv_is_m;
                SYS_SRET:       sys_illegal = (eff_priv < 2'b01) || (priv_is_s && mstatus_q[22]); // TSR
                SYS_WFI:        sys_illegal = priv_is_u || (priv_is_s && mstatus_q[21]);        // TW
                SYS_SFENCE_VMA: sys_illegal = (eff_priv < 2'b01) || (priv_is_s && mstatus_q[20]); // TVM

                SYS_CSRRW, SYS_CSRRS, SYS_CSRRC,
                SYS_CSRRWI, SYS_CSRRSI, SYS_CSRRCI: begin
                    sys_illegal = csr_access_illegal;
                end

                VEC_VSETVLI, VEC_VSETVL, VEC_VSETIVLI: begin
                    sys_illegal = (eff_vs == 2'b00);
                end

                default: sys_illegal = 1'b1;
            endcase
        end
    end

    assign p0_sys_illegal_o = sys_illegal;

    // =========================================================================
    // 3. Pending System Operation Buffer (Captured at EX0)
    // =========================================================================
    typedef struct packed {
        logic              valid;
        uop_subop_t        sub_op;
        logic [11:0]       csr_addr;
        logic [63:0]       write_val;
        logic              write_intent;
        logic [63:0]       pc_p4;
        rob_idx_t          rob_idx;
        logic [63:0]       rs1_val;
        logic [63:0]       rs2_val;
    } sys_exec_entry_t;

    sys_exec_entry_t pending_sys_q;

    logic [63:0] p0_sys_pc_p4;
    fursoy_s1_ks_adder #(.WIDTH(64)) u_pc_p4_adder (
        .a_i   (p0_sys_pc_i),
        .b_i   (64'd4),
        .cin_i (1'b0),
        .sum_o (p0_sys_pc_p4)
    );

    // Match retirement across both superscalar commit slots
    wire sys_retire_fire = pending_sys_q.valid && (
        (retire_valid_i[0] && (retire_rob_idx_i[0] == pending_sys_q.rob_idx)) ||
        (retire_valid_i[1] && (retire_rob_idx_i[1] == pending_sys_q.rob_idx))
    );

    assign csr_mie_o            = mie_q;
    assign csr_sfence_active_o  = (sfence_state_q != SFENCE_IDLE);
    assign sys_pending_valid_o  = pending_sys_q.valid;

    // SFENCE.VMA L1D Clean Maintenance State Machine (P0-3)
    typedef enum logic [1:0] {
        SFENCE_IDLE    = 2'd0,
        SFENCE_WAIT_SQ = 2'd1,
        SFENCE_CLEAN   = 2'd2
    } sfence_clean_state_t;

    sfence_clean_state_t sfence_state_q;

    // =========================================================================
    // 4. Milestone 8 Phase D Vector Configuration Evaluation Logic (vsetvl*)
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic void eval_vtype_legal(
        input  logic [63:0] in_vtype,
        output logic [63:0] out_vtype,
        output logic [8:0]  out_vlmax,
        output logic        out_vill
    );
        logic [2:0] sew;
        logic [2:0] lmul;
        sew  = in_vtype[5:3];
        lmul = in_vtype[2:0];
        // Check illegal conditions per RVV 1.0 §3.1:
        // 1. Reserved upper bits [62:8] != 0
        // 2. vsew > 3 (SEW > 64)
        // 3. vlmul == 3'b100 (reserved)
        // 4. SEW/LMUL > ELEN (64)
        if ((in_vtype[62:8] != 55'd0) ||
            (sew > 3'd3) ||
            (lmul == 3'b100) ||
            (lmul == 3'b111 && sew == 3'd3) || // LMUL=1/2, SEW=64
            (lmul == 3'b110 && sew >= 3'd2) || // LMUL=1/4, SEW>=32
            (lmul == 3'b101 && sew >= 3'd1)    // LMUL=1/8, SEW>=16
           ) begin
            out_vill  = 1'b1;
            out_vtype = 64'h8000_0000_0000_0000;
            out_vlmax = 9'd0;
        end else begin
            vtype_bundle_t bundle;
            out_vill     = 1'b0;
            out_vtype    = {56'd0, in_vtype[7:0]};
            bundle.vill  = 1'b0;
            bundle.vma   = in_vtype[7];
            bundle.vta   = in_vtype[6];
            bundle.vsew  = vsew_t'(sew);
            bundle.vlmul = vlmul_t'(lmul);
            out_vlmax    = calc_vlmax(bundle);
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic void eval_vset_cfg(
        input  logic [63:0] in_vtype,
        input  logic [63:0] in_avl,
        input  logic        rs1_is_zero,
        input  logic        rd_is_zero,
        output logic [63:0] out_vtype,
        output logic [63:0] out_vl,
        output logic        out_vill
    );
        logic [63:0] cur_vtype_norm;
        logic [8:0]  cur_vlmax;
        logic        cur_vill;
        logic [63:0] next_vtype_norm;
        logic [8:0]  next_vlmax;
        logic        next_vill;

        eval_vtype_legal(vtype_q, cur_vtype_norm, cur_vlmax, cur_vill);
        eval_vtype_legal(in_vtype, next_vtype_norm, next_vlmax, next_vill);

        if (next_vill) begin
            out_vill  = 1'b1;
            out_vtype = 64'h8000_0000_0000_0000;
            out_vl    = 64'd0;
        end else if (rs1_is_zero && rd_is_zero) begin
            // RVV 1.0 §6.2: rs1==x0 && rd==x0 keeps existing vl only when prior vtype
            // is legal and the new vtype preserves VLMAX (ratio SEW/LMUL); otherwise vill=1, vl=0.
            if (vtype_q[63] || cur_vill || (next_vlmax != cur_vlmax) || (vl_q > {55'd0, next_vlmax})) begin
                out_vill  = 1'b1;
                out_vtype = 64'h8000_0000_0000_0000;
                out_vl    = 64'd0;
            end else begin
                out_vill  = 1'b0;
                out_vtype = next_vtype_norm;
                out_vl    = vl_q;
            end
        end else if (rs1_is_zero && !rd_is_zero) begin
            out_vill  = 1'b0;
            out_vtype = next_vtype_norm;
            out_vl    = {55'd0, next_vlmax};
        end else if (in_avl <= {55'd0, next_vlmax}) begin
            out_vill  = 1'b0;
            out_vtype = next_vtype_norm;
            out_vl    = in_avl;
        end else begin
            out_vill  = 1'b0;
            out_vtype = next_vtype_norm;
            out_vl    = {55'd0, next_vlmax};
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        eval_vset_cfg(
            vec_cfg_vtype_i,
            vec_cfg_avl_i,
            vec_cfg_rs1_is_zero_i,
            vec_cfg_rd_is_zero_i,
            vec_cfg_new_vtype_o,
            vec_cfg_new_vl_o,
            vec_cfg_illegal_o
        );
    end

    // Fetched vsetvli/vsetvl/vsetivli configuration calculation (Port 0 system path)
    wire        p0_is_vset = (p0_sys_subop_i == VEC_VSETVLI) ||
                             (p0_sys_subop_i == VEC_VSETVL)  ||
                             (p0_sys_subop_i == VEC_VSETIVLI);
    logic [63:0] p0_vcfg_new_vtype;
    logic [63:0] p0_vcfg_new_vl;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        p0_vcfg_vill;
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin
        logic [63:0] p0_vcfg_vtype_in;
        logic [63:0] p0_vcfg_avl_in;
        logic        p0_vcfg_rs1_zero;
        logic        p0_vcfg_rd_zero;

        p0_vcfg_vtype_in = (p0_sys_subop_i == VEC_VSETVL) ? p0_sys_rs2_val_i : {53'd0, p0_sys_csr_addr_i[10:0]};
        p0_vcfg_avl_in   = (p0_sys_subop_i == VEC_VSETIVLI) ? {59'd0, p0_sys_rs1_field_i} : p0_sys_rs1_val_i;
        p0_vcfg_rs1_zero = (p0_sys_subop_i != VEC_VSETIVLI) && (p0_sys_rs1_field_i == 5'd0);
        p0_vcfg_rd_zero  = p0_sys_csr_addr_i[11];

        eval_vset_cfg(
            p0_vcfg_vtype_in,
            p0_vcfg_avl_in,
            p0_vcfg_rs1_zero,
            p0_vcfg_rd_zero,
            p0_vcfg_new_vtype,
            p0_vcfg_new_vl,
            p0_vcfg_vill
        );
    end

    assign p0_sys_rdata_o = p0_is_vset ? p0_vcfg_new_vl : old_csr_val;

    // =========================================================================
    // 5. Sequential Architectural State & Retirement Handling
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            priv_mode_q      <= priv_mode_i;
            mstatus_i_prev_q <= mstatus_i;
            mstatus_q        <= (mstatus_i != 64'd0) ? mstatus_i[62:0] : 63'h0000_000a_0000_1800;
            medeleg_q    <= '0;
            mideleg_q    <= '0;
            mie_q        <= '0;
            mtvec_q      <= RESET_MTVEC;
            mcounteren_q <= '0;
            menvcfg_q    <= '0;
            mscratch_q   <= '0;
            mepc_q       <= '0;
            mcause_q     <= '0;
            mtval_q      <= '0;
            mip_q        <= '0;

            stvec_q      <= RESET_STVEC;
            scounteren_q <= '0;
            senvcfg_q    <= '0;
            sscratch_q   <= '0;
            sepc_q       <= '0;
            scause_q     <= '0;
            stval_q      <= '0;
            satp_q       <= '0;

            // Milestone 8 FP CSRs Reset
            frm_q        <= 3'd0;
            fflags_q     <= 5'd0;

            // Milestone 8 Phase D Vector CSRs Reset
            vtype_q      <= 64'h8000_0000_0000_0000; // vill = 1 at reset
            vl_q         <= 64'd0;
            vstart_q     <= 64'd0;
            vxrm_q       <= 2'd0;
            vxsat_q      <= 1'b0;

            hpm_we_o     <= 1'b0;
            hpm_waddr_o  <= '0;
            hpm_wdata_o  <= '0;

            pending_sys_q         <= '0;
            sys_redirect_valid_o  <= 1'b0;
            sys_redirect_target_o <= '0;
            sys_flush_valid_o     <= 1'b0;
            sfence_vma_valid_o    <= 1'b0;
            sfence_vma_va_o       <= '0;
            sfence_vma_asid_o     <= '0;
            sfence_state_q        <= SFENCE_IDLE;
            dcache_clean_all_req_o<= 1'b0;
            wfi_sleep_q           <= 1'b0;
            wfi_resume_pc_q       <= 64'd0;
        end else begin
            // Sample non-zero post-reset mstatus_i changes synchronously into mstatus_q so
            // unit TBs driving mstatus_i after reset stay compatible without adding a
            // combinational override mux on the CSR critical cone.
            mstatus_i_prev_q <= mstatus_i;
            if ((mstatus_i != 64'd0) && (mstatus_i != mstatus_i_prev_q)) begin
                mstatus_q <= mstatus_i[62:0];
            end

            // Default pulses
            sys_redirect_valid_o <= 1'b0;
            sys_flush_valid_o    <= 1'b0;
            sfence_vma_valid_o   <= 1'b0;
            hpm_we_o             <= 1'b0;

            // SFENCE.VMA Clean Progression
            case (sfence_state_q)
                SFENCE_IDLE: begin
                    dcache_clean_all_req_o <= 1'b0;
                end
                SFENCE_WAIT_SQ: begin
                    if (sq_empty_i) begin
                        dcache_clean_all_req_o <= 1'b1;
                        sfence_state_q         <= SFENCE_CLEAN;
                    end
                end
                SFENCE_CLEAN: begin
                    if (dcache_clean_all_done_i) begin
                        dcache_clean_all_req_o <= 1'b0;
                        sfence_state_q         <= SFENCE_IDLE;
                    end
                end
                default: sfence_state_q <= SFENCE_IDLE;
            endcase

            // Capture valid non-illegal system uop issued on Port 0
            if (sys_flush_valid_o || retire_replay_i) begin
                pending_sys_q.valid <= 1'b0;
            end else if (p0_sys_valid_i && !sys_illegal) begin
                pending_sys_q.valid        <= 1'b1;
                pending_sys_q.sub_op       <= p0_sys_subop_i;
                pending_sys_q.csr_addr     <= p0_sys_csr_addr_i;
                pending_sys_q.write_val    <= p0_is_vset ? p0_vcfg_new_vtype : csr_write_val;
                pending_sys_q.write_intent <= csr_write_intent;
                pending_sys_q.pc_p4        <= p0_sys_pc_p4;
                pending_sys_q.rob_idx      <= p0_sys_rob_idx_i;
                pending_sys_q.rs1_val      <= p0_sys_rs1_val_i;
                pending_sys_q.rs2_val      <= p0_is_vset ? p0_vcfg_new_vl : p0_sys_rs2_val_i;
            end

            // -----------------------------------------------------------------
            // Retirement Event Handling
            // -----------------------------------------------------------------
            // Milestone 8 Phase A: In-order FP instruction retirement
            // Accumulates accrued exception flags and transitions mstatus.FS to Dirty (2'b11)
            begin : fp_retire_block
                logic [4:0] eff_retire_fflags;
                eff_retire_fflags = 5'd0;
                if (retire_valid_i[0] && (retire_fp_dest_valid_i[0] || retire_is_fp_i[0]) && !retire_exception_i) begin
                    eff_retire_fflags = eff_retire_fflags | retire_fflags_i[0];
                    if (retire_fp_dest_valid_i[0] || (retire_fflags_i[0] != 5'd0)) begin
                        mstatus_q[14:13] <= 2'b11;
                    end
                end
                if (retire_valid_i[1] && (retire_fp_dest_valid_i[1] || retire_is_fp_i[1]) && !retire_exception_i) begin
                    eff_retire_fflags = eff_retire_fflags | retire_fflags_i[1];
                    if (retire_fp_dest_valid_i[1] || (retire_fflags_i[1] != 5'd0)) begin
                        mstatus_q[14:13] <= 2'b11;
                    end
                end
                if ((retire_valid_i[0] && (retire_fp_dest_valid_i[0] || retire_is_fp_i[0]) && !retire_exception_i) ||
                    (retire_valid_i[1] && (retire_fp_dest_valid_i[1] || retire_is_fp_i[1]) && !retire_exception_i)) begin
                    fflags_q <= fflags_q | eff_retire_fflags;
                end
            end

            // Milestone 8 Phase D: In-order Vector instruction retirement
            // Transitions mstatus.VS to Dirty (2'b11) and asserts mstatus.SD
            if ((retire_valid_i[0] && retire_vec_dest_valid_i[0] && !retire_exception_i) ||
                (retire_valid_i[1] && retire_vec_dest_valid_i[1] && !retire_exception_i)) begin
                mstatus_q[10:9] <= 2'b11; // VS Dirty
            end

            // Milestone 8 Phase D: Vector Configuration Update (vsetvli, vsetvl, vsetivli)
            if (vec_cfg_valid_i) begin
                if (eff_vs != 2'b00) begin
                    vtype_q         <= vec_cfg_new_vtype_o;
                    vl_q            <= vec_cfg_new_vl_o;
                    mstatus_q[10:9] <= 2'b11; // VS Dirty
                end
            end

            // Milestone 8 Phase D: Fault-Only-First Load Handling
            // Non-zero element fault suppresses trap and truncates vl (PROP_M8_35)
            if (fof_fault_valid_i) begin
                if (fof_fault_elem_i > 64'd0 && fof_fault_elem_i < vl_q) begin
                    vl_q <= fof_fault_elem_i;
                end
            end

            if (retire_exception_i && !sys_flush_valid_o) begin
                // Precise synchronous trap at ROB head
                logic trap_to_s;
                trap_to_s = (priv_mode_q <= 2'b01) && medeleg_q[{1'b0, retire_exc_cause_i}];

                if (trap_to_s) begin
                    sepc_q   <= retire_exc_pc_i;
                    scause_q <= {1'b0, 58'd0, retire_exc_cause_i};
                    if (retire_exc_cause_i == 5'd0 ||
                        retire_exc_cause_i == 5'd4 || retire_exc_cause_i == 5'd6 ||
                        retire_exc_cause_i == 5'd5 || retire_exc_cause_i == 5'd7 ||
                        retire_exc_cause_i == 5'd13 || retire_exc_cause_i == 5'd15) begin
                        stval_q <= retire_exc_val_i;
                    end else if (retire_exc_cause_i == 5'd1 || retire_exc_cause_i == 5'd12) begin
                        stval_q <= retire_exc_pc_i;
                    end else begin
                        stval_q <= 64'd0;
                    end
                    mstatus_q[5] <= mstatus_q[1]; // SPIE <= SIE
                    mstatus_q[1] <= 1'b0;         // SIE <= 0
                    mstatus_q[8] <= (priv_mode_q == 2'b01); // SPP <= (P == S)
                    priv_mode_q  <= 2'b01;        // privilege <= S

                    sys_redirect_valid_o  <= 1'b1;
                    // RISC-V Privileged Spec: synchronous exceptions always vector to BASE regardless of xtvec.MODE
                    sys_redirect_target_o <= {stvec_q[63:2], 2'b00};
                    sys_flush_valid_o     <= 1'b1;
                end else begin
                    mepc_q   <= retire_exc_pc_i;
                    mcause_q <= {1'b0, 58'd0, retire_exc_cause_i};
                    if (retire_exc_cause_i == 5'd0 ||
                        retire_exc_cause_i == 5'd4 || retire_exc_cause_i == 5'd6 ||
                        retire_exc_cause_i == 5'd5 || retire_exc_cause_i == 5'd7 ||
                        retire_exc_cause_i == 5'd13 || retire_exc_cause_i == 5'd15) begin
                        mtval_q <= retire_exc_val_i;
                    end else if (retire_exc_cause_i == 5'd1 || retire_exc_cause_i == 5'd12) begin
                        mtval_q <= retire_exc_pc_i;
                    end else begin
                        mtval_q <= 64'd0;
                    end
                    mstatus_q[7]     <= mstatus_q[3]; // MPIE <= MIE
                    mstatus_q[3]     <= 1'b0;         // MIE <= 0
                    mstatus_q[12:11] <= priv_mode_q;  // MPP <= P
                    priv_mode_q      <= 2'b11;        // privilege <= M

                    sys_redirect_valid_o  <= 1'b1;
                    // RISC-V Privileged Spec: synchronous exceptions always vector to BASE regardless of xtvec.MODE
                    sys_redirect_target_o <= {mtvec_q[63:2], 2'b00};
                    sys_flush_valid_o     <= 1'b1;
                end
                pending_sys_q.valid <= 1'b0;
            end else if (wfi_sleep_q) begin
                if (mip_val != 64'd0) begin
                    wfi_sleep_q <= 1'b0;
                    if (irq_candidate_valid) begin
                        if (irq_candidate_priv == 2'b01) begin
                            sepc_q   <= wfi_resume_pc_q;
                            scause_q <= irq_candidate_cause;
                            stval_q  <= 64'd0;
                            mstatus_q[5] <= mstatus_q[1]; // SPIE <= SIE
                            mstatus_q[1] <= 1'b0;         // SIE <= 0
                            mstatus_q[8] <= (priv_mode_q == 2'b01); // SPP <= (P == S)
                            priv_mode_q  <= 2'b01;        // privilege <= S

                            sys_redirect_valid_o  <= 1'b1;
                            sys_redirect_target_o <= (stvec_q[1:0] == 2'b01)
                                                   ? ({stvec_q[63:2], 2'b00} + {58'd0, irq_candidate_cause[3:0], 2'b00})
                                                   : {stvec_q[63:2], 2'b00};
                            sys_flush_valid_o     <= 1'b1;
                        end else begin
                            mepc_q   <= wfi_resume_pc_q;
                            mcause_q <= irq_candidate_cause;
                            mtval_q  <= 64'd0;
                            mstatus_q[7]     <= mstatus_q[3]; // MPIE <= MIE
                            mstatus_q[3]     <= 1'b0;         // MIE <= 0
                            mstatus_q[12:11] <= priv_mode_q;  // MPP <= P
                            priv_mode_q      <= 2'b11;        // privilege <= M

                            sys_redirect_valid_o  <= 1'b1;
                            sys_redirect_target_o <= (mtvec_q[1:0] == 2'b01)
                                                   ? ({mtvec_q[63:2], 2'b00} + {58'd0, irq_candidate_cause[3:0], 2'b00})
                                                   : {mtvec_q[63:2], 2'b00};
                            sys_flush_valid_o     <= 1'b1;
                        end
                    end else begin
                        sys_redirect_valid_o  <= 1'b1;
                        sys_redirect_target_o <= wfi_resume_pc_q;
                        sys_flush_valid_o     <= 1'b1;
                    end
                end
            end else if (irq_candidate_valid && !sys_retire_fire && !sys_redirect_valid_o && !sys_flush_valid_o && !recovering_i && !reconstructing_i && !retire_replay_i && (!rob_empty_i || !frontend_en_i)) begin
                // Asynchronous interrupt delivery at instruction boundary
                if (irq_candidate_priv == 2'b01) begin
                    sepc_q   <= captured_pc;
                    scause_q <= irq_candidate_cause;
                    stval_q  <= 64'd0;
                    mstatus_q[5] <= mstatus_q[1]; // SPIE <= SIE
                    mstatus_q[1] <= 1'b0;         // SIE <= 0
                    mstatus_q[8] <= (priv_mode_q == 2'b01); // SPP <= (P == S)
                    priv_mode_q  <= 2'b01;        // privilege <= S

                    sys_redirect_valid_o  <= 1'b1;
                    sys_redirect_target_o <= (stvec_q[1:0] == 2'b01)
                                           ? ({stvec_q[63:2], 2'b00} + {58'd0, irq_candidate_cause[3:0], 2'b00})
                                           : {stvec_q[63:2], 2'b00};
                    sys_flush_valid_o     <= 1'b1;
                end else begin
                    mepc_q   <= captured_pc;
                    mcause_q <= irq_candidate_cause;
                    mtval_q  <= 64'd0;
                    mstatus_q[7]     <= mstatus_q[3]; // MPIE <= MIE
                    mstatus_q[3]     <= 1'b0;         // MIE <= 0
                    mstatus_q[12:11] <= priv_mode_q;  // MPP <= P
                    priv_mode_q      <= 2'b11;        // privilege <= M

                    sys_redirect_valid_o  <= 1'b1;
                    sys_redirect_target_o <= (mtvec_q[1:0] == 2'b01)
                                           ? ({mtvec_q[63:2], 2'b00} + {58'd0, irq_candidate_cause[3:0], 2'b00})
                                           : {mtvec_q[63:2], 2'b00};
                    sys_flush_valid_o     <= 1'b1;
                end
                pending_sys_q.valid <= 1'b0;
            end else if (sys_retire_fire) begin
                pending_sys_q.valid <= 1'b0;

                case (pending_sys_q.sub_op)
                    SYS_MRET: begin
                        priv_mode_q      <= mstatus_q[12:11]; // privilege <= MPP
                        mstatus_q[12:11] <= 2'b00;            // MPP <= U
                        mstatus_q[3]     <= mstatus_q[7];     // MIE <= MPIE
                        mstatus_q[7]     <= 1'b1;             // MPIE <= 1
                        if (mstatus_q[12:11] != 2'b11) mstatus_q[17] <= 1'b0; // Clear MPRV if returning to S/U

                        sys_redirect_valid_o  <= 1'b1;
                        sys_redirect_target_o <= mepc_q;
                        sys_flush_valid_o     <= 1'b1;
                    end

                    SYS_SRET: begin
                        priv_mode_q  <= mstatus_q[8] ? 2'b01 : 2'b00; // privilege <= SPP
                        mstatus_q[8] <= 1'b0;                         // SPP <= U
                        mstatus_q[1] <= mstatus_q[5];                 // SIE <= SPIE
                        mstatus_q[5] <= 1'b1;                         // SPIE <= 1
                        mstatus_q[17]<= 1'b0;                         // Clear MPRV

                        sys_redirect_valid_o  <= 1'b1;
                        sys_redirect_target_o <= sepc_q;
                        sys_flush_valid_o     <= 1'b1;
                    end

                    SYS_SFENCE_VMA: begin
                        sys_redirect_valid_o   <= 1'b1;
                        sys_redirect_target_o  <= pending_sys_q.pc_p4;
                        sys_flush_valid_o      <= 1'b1;
                        sfence_vma_valid_o     <= 1'b1;
                        sfence_vma_va_o        <= pending_sys_q.rs1_val;
                        sfence_vma_asid_o      <= pending_sys_q.rs2_val[15:0];
                        if (sq_empty_i) begin
                            dcache_clean_all_req_o <= 1'b1;
                            sfence_state_q         <= SFENCE_CLEAN;
                        end else begin
                            sfence_state_q         <= SFENCE_WAIT_SQ;
                        end
                    end

                    SYS_WFI: begin
                        if (mip_val != 64'd0) begin
                            wfi_sleep_q           <= 1'b0;
                            sys_redirect_valid_o  <= 1'b1;
                            sys_redirect_target_o <= pending_sys_q.pc_p4;
                            sys_flush_valid_o     <= 1'b1;
                        end else begin
                            wfi_sleep_q     <= 1'b1;
                            wfi_resume_pc_q <= pending_sys_q.pc_p4;
                        end
                    end

                    SYS_CSRRW, SYS_CSRRS, SYS_CSRRC,
                    SYS_CSRRWI, SYS_CSRRSI, SYS_CSRRCI: begin
                        if (pending_sys_q.write_intent) begin
                            unique case (pending_sys_q.csr_addr)
                                // Milestone 8 Floating-Point CSRs
                                12'h001: begin // fflags
                                    fflags_q <= pending_sys_q.write_val[4:0];
                                    mstatus_q[14:13] <= 2'b11; // Dirty
                                end
                                12'h002: begin // frm
                                    frm_q <= pending_sys_q.write_val[2:0];
                                    mstatus_q[14:13] <= 2'b11; // Dirty
                                    sys_redirect_valid_o  <= 1'b1;
                                    sys_redirect_target_o <= pending_sys_q.pc_p4;
                                    sys_flush_valid_o     <= 1'b1;
                                end
                                12'h003: begin // fcsr
                                    fflags_q <= pending_sys_q.write_val[4:0];
                                    frm_q    <= pending_sys_q.write_val[7:5];
                                    mstatus_q[14:13] <= 2'b11; // Dirty
                                    sys_redirect_valid_o  <= 1'b1;
                                    sys_redirect_target_o <= pending_sys_q.pc_p4;
                                    sys_flush_valid_o     <= 1'b1;
                                end

                                // Milestone 8 Phase D Vector CSRs
                                12'h008: begin // vstart
                                    vstart_q <= pending_sys_q.write_val;
                                    mstatus_q[10:9] <= 2'b11; // VS Dirty
                                end
                                12'h009: begin // vxsat
                                    vxsat_q <= pending_sys_q.write_val[0];
                                    mstatus_q[10:9] <= 2'b11; // VS Dirty
                                end
                                12'h00A: begin // vxrm
                                    vxrm_q <= pending_sys_q.write_val[1:0];
                                    mstatus_q[10:9] <= 2'b11; // VS Dirty
                                end
                                12'h00F: begin // vcsr
                                    vxsat_q <= pending_sys_q.write_val[0];
                                    vxrm_q  <= pending_sys_q.write_val[2:1];
                                    mstatus_q[10:9] <= 2'b11; // VS Dirty
                                end

                                12'h300: begin // mstatus
                                    mstatus_q <= 63'h0000_000a_0000_0000 |
                                                 (pending_sys_q.write_val[62:0] & 63'h0000_0000_007e_7faa) |
                                                 (pending_sys_q.write_val[12:11] == 2'b10 ? 63'h1800 : 63'd0);
                                    sys_redirect_valid_o  <= 1'b1;
                                    sys_redirect_target_o <= pending_sys_q.pc_p4;
                                    sys_flush_valid_o     <= 1'b1;
                                end
                                12'h302: medeleg_q    <= pending_sys_q.write_val & 64'hb3ff;
                                12'h303: mideleg_q    <= pending_sys_q.write_val & 64'h222;
                                12'h304: mie_q        <= pending_sys_q.write_val & 64'haaa;
                                12'h305: mtvec_q      <= {pending_sys_q.write_val[63:2],
                                                         (pending_sys_q.write_val[1:0] <= 2'b01) ? pending_sys_q.write_val[1:0] : 2'b00};
                                12'h306: mcounteren_q <= pending_sys_q.write_val & 64'h0000_0000_ffff_ffff;
                                12'h30a: menvcfg_q    <= pending_sys_q.write_val & 64'd1;
                                12'h340: mscratch_q   <= pending_sys_q.write_val;
                                12'h341: mepc_q       <= {pending_sys_q.write_val[63:2], 2'b00};
                                12'h342: mcause_q     <= pending_sys_q.write_val;
                                12'h343: mtval_q      <= pending_sys_q.write_val;
                                12'h344: mip_q        <= (mip_q & ~64'h222) | (pending_sys_q.write_val & 64'h222);

                                // S-mode CSRs
                                12'h100: begin // sstatus
                                    mstatus_q[1]     <= pending_sys_q.write_val[1];     // SIE
                                    mstatus_q[5]     <= pending_sys_q.write_val[5];     // SPIE
                                    mstatus_q[8]     <= pending_sys_q.write_val[8];     // SPP
                                    mstatus_q[10:9]  <= pending_sys_q.write_val[10:9];  // VS
                                    mstatus_q[14:13] <= pending_sys_q.write_val[14:13]; // FS
                                    mstatus_q[18]    <= pending_sys_q.write_val[18];    // SUM
                                    mstatus_q[19]    <= pending_sys_q.write_val[19];    // MXR
                                    sys_redirect_valid_o  <= 1'b1;
                                    sys_redirect_target_o <= pending_sys_q.pc_p4;
                                    sys_flush_valid_o     <= 1'b1;
                                end
                                12'h104: mie_q        <= (mie_q & ~(mideleg_q & 64'h222)) | (pending_sys_q.write_val & (mideleg_q & 64'h222));
                                12'h105: stvec_q      <= {pending_sys_q.write_val[63:2],
                                                         (pending_sys_q.write_val[1:0] <= 2'b01) ? pending_sys_q.write_val[1:0] : 2'b00};
                                12'h106: scounteren_q <= pending_sys_q.write_val & 64'h0000_0000_ffff_ffff;
                                12'h10a: senvcfg_q    <= pending_sys_q.write_val & 64'd1;
                                12'h140: sscratch_q   <= pending_sys_q.write_val;
                                12'h141: sepc_q       <= {pending_sys_q.write_val[63:2], 2'b00};
                                12'h142: scause_q     <= pending_sys_q.write_val;
                                12'h143: stval_q      <= pending_sys_q.write_val;
                                12'h144: begin
                                    if (mideleg_q[1]) mip_q[1] <= pending_sys_q.write_val[1];
                                end
                                12'h180: begin // satp
                                    if (pending_sys_q.write_val[63:60] == 4'h0) satp_q <= 64'd0;
                                    else if (pending_sys_q.write_val[63:60] == 4'h8)
                                        satp_q <= {4'h8, 16'd0, pending_sys_q.write_val[43:0]};

                                    sys_redirect_valid_o  <= 1'b1;
                                    sys_redirect_target_o <= pending_sys_q.pc_p4;
                                    sys_flush_valid_o     <= 1'b1;
                                end

                                12'h320, 12'hB00, 12'hB02: begin
                                    hpm_we_o    <= 1'b1;
                                    hpm_waddr_o <= pending_sys_q.csr_addr;
                                    hpm_wdata_o <= pending_sys_q.write_val;
                                end

                                default: begin
                                    if ((pending_sys_q.csr_addr >= 12'hB03 && pending_sys_q.csr_addr <= 12'hB1F) ||
                                        (pending_sys_q.csr_addr >= 12'h323 && pending_sys_q.csr_addr <= 12'h33F)) begin
                                        hpm_we_o    <= 1'b1;
                                        hpm_waddr_o <= pending_sys_q.csr_addr;
                                        hpm_wdata_o <= pending_sys_q.write_val;
                                    end
                                end
                            endcase
                        end
                    end

                    VEC_VSETVLI, VEC_VSETVL, VEC_VSETIVLI: begin
                        vtype_q         <= pending_sys_q.write_val;
                        vl_q            <= pending_sys_q.rs2_val;
                        mstatus_q[10:9] <= 2'b11; // VS Dirty
                        sys_redirect_valid_o  <= 1'b1;
                        sys_redirect_target_o <= pending_sys_q.pc_p4;
                        sys_flush_valid_o     <= 1'b1;
                    end

                    default: ;
                endcase
            end

            // Testbench Direct CSR State Injection
            if (test_csr_we_i) begin
                unique case (test_csr_addr_i)
                    12'h000: priv_mode_q <= test_csr_wdata_i[1:0];
                    12'h300: mstatus_q   <= test_csr_wdata_i[62:0];
                    12'h302: medeleg_q   <= test_csr_wdata_i & 64'hb3ff;
                    12'h303: mideleg_q   <= test_csr_wdata_i & 64'h222;
                    12'h304: mie_q       <= test_csr_wdata_i & 64'haaa;
                    12'h305: mtvec_q     <= {test_csr_wdata_i[63:2], (test_csr_wdata_i[1:0] <= 2'b01) ? test_csr_wdata_i[1:0] : 2'b00};
                    12'h100: begin
                        mstatus_q[1]     <= test_csr_wdata_i[1];
                        mstatus_q[5]     <= test_csr_wdata_i[5];
                        mstatus_q[8]     <= test_csr_wdata_i[8];
                    end
                    12'h104: mie_q       <= (mie_q & ~(mideleg_q & 64'h222)) | (test_csr_wdata_i & (mideleg_q & 64'h222));
                    12'h105: stvec_q     <= {test_csr_wdata_i[63:2], (test_csr_wdata_i[1:0] <= 2'b01) ? test_csr_wdata_i[1:0] : 2'b00};
                    12'h341: mepc_q      <= {test_csr_wdata_i[63:2], 2'b00};
                    12'h342: mcause_q    <= test_csr_wdata_i;
                    12'h141: sepc_q      <= {test_csr_wdata_i[63:2], 2'b00};
                    12'h142: scause_q    <= test_csr_wdata_i;
                    default: ;
                endcase
            end
        end
    end

endmodule

`endif // FURSOY_S1_CSR_SV
