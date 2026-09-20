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

    // -------------------------------------------------------------------------
    // Architectural State Outputs
    // -------------------------------------------------------------------------
    output logic [1:0]        priv_mode_o,
    output logic [63:0]       mstatus_o,
    output logic [63:0]       satp_o,

    // Redirect & Flush Outputs
    output logic              sys_redirect_valid_o,
    output logic [63:0]       sys_redirect_target_o,
    output logic              sys_flush_valid_o,

    // SFENCE.VMA Pulse Output
    output logic              sfence_vma_valid_o,
    output logic [63:0]       sfence_vma_va_o,
    output logic [15:0]       sfence_vma_asid_o,

    // CSR Observability Outputs (Diagnostics)
    output logic [63:0]       csr_mepc_o,
    output logic [63:0]       csr_mcause_o,
    output logic [63:0]       csr_mtval_o,
    output logic [63:0]       csr_sepc_o,
    output logic [63:0]       csr_scause_o,
    output logic [63:0]       csr_stval_o,
    output logic [63:0]       csr_mtvec_o,
    output logic [63:0]       csr_stvec_o
);

    // =========================================================================
    // 1. Architectural Registers
    // =========================================================================
    logic [1:0]  priv_mode_q;

    // M-mode registers
    // mstatus: reset value 0x0000_000a_0000_1800 (UXL=2, SXL=2, MPP=M)
    logic [63:0] mstatus_q;
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

    // Free-running cycle counter
    logic [63:0] cycle_q;

    // Effective privilege mode and mstatus incorporating external injection
    wire [1:0]  eff_priv    = (priv_mode_i != 2'b11) ? priv_mode_i : priv_mode_q;
    wire [63:0] eff_mstatus = (mstatus_i != 64'd0) ? mstatus_i : mstatus_q;

    // Connect architectural outputs
    assign priv_mode_o = eff_priv;
    assign mstatus_o   = eff_mstatus;
    assign satp_o      = satp_q;

    assign csr_mepc_o   = mepc_q;
    assign csr_mcause_o = mcause_q;
    assign csr_mtval_o  = mtval_q;
    assign csr_sepc_o   = sepc_q;
    assign csr_scause_o = scause_q;
    assign csr_stval_o  = stval_q;
    assign csr_mtvec_o  = mtvec_q;
    assign csr_stvec_o  = stvec_q;

    // Aliased supervisor CSR values
    wire [63:0] sstatus_val = mstatus_q & 64'h0000_0003_000c_0122;
    wire [63:0] sie_val     = mie_q & mideleg_q & 64'h222;
    wire [63:0] sip_val     = mip_q & mideleg_q & 64'h222;

    // =========================================================================
    // 2. Port 0 Execution Stage: CSR Decode, Privilege Check, and RMW
    // =========================================================================
    logic [63:0] old_csr_val;
    logic        csr_implemented;
    logic        csr_read_only;

    always_comb begin
        csr_implemented = 1'b1;
        csr_read_only   = (p0_sys_csr_addr_i[11:10] == 2'b11);
        old_csr_val     = 64'd0;

        case (p0_sys_csr_addr_i)
            // M-mode CSRs
            12'h300: old_csr_val = mstatus_q;
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
            12'h344: old_csr_val = mip_q;

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

            // Counters (Read-Only)
            12'hc00, 12'hc01, 12'hc02: begin
                old_csr_val   = cycle_q;
                csr_read_only = 1'b1;
            end

            default: begin
                csr_implemented = 1'b0;
                csr_read_only   = 1'b0;
                old_csr_val     = 64'd0;
            end
        endcase
    end

    // Write Intent & Source Operand Generation
    wire is_imm_csr = (p0_sys_subop_i == SYS_CSRRWI ||
                       p0_sys_subop_i == SYS_CSRRSI ||
                       p0_sys_subop_i == SYS_CSRRCI);

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
                csr_write_val    = old_csr_val | source_operand;
            end
            SYS_CSRRC, SYS_CSRRCI: begin
                csr_write_intent = (p0_sys_rs1_field_i != 5'd0);
                csr_write_val    = old_csr_val & ~source_operand;
            end
            default: begin
                csr_write_intent = 1'b0;
                csr_write_val    = 64'd0;
            end
        endcase
    end

    // Privilege and Exception Check
    logic sys_illegal;

    always_comb begin
        sys_illegal = 1'b0;

        if (p0_sys_valid_i) begin
            case (p0_sys_subop_i)
                SYS_MRET: begin
                    if (eff_priv < 2'b11) sys_illegal = 1'b1;
                end

                SYS_SRET: begin
                    if (eff_priv < 2'b01) sys_illegal = 1'b1;
                    else if (eff_priv == 2'b01 && eff_mstatus[22]) sys_illegal = 1'b1; // TSR
                end

                SYS_WFI: begin
                    if (eff_priv == 2'b00) sys_illegal = 1'b1;
                    else if (eff_priv == 2'b01 && eff_mstatus[21]) sys_illegal = 1'b1; // TW
                end

                SYS_SFENCE_VMA: begin
                    if (eff_priv < 2'b01) sys_illegal = 1'b1;
                    else if (eff_priv == 2'b01 && eff_mstatus[20]) sys_illegal = 1'b1; // TVM
                end

                SYS_CSRRW, SYS_CSRRS, SYS_CSRRC,
                SYS_CSRRWI, SYS_CSRRSI, SYS_CSRRCI: begin
                    // Address bits [9:8] define privilege level
                    if (p0_sys_csr_addr_i[9:8] == 2'b10) sys_illegal = 1'b1; // Hypervisor unsupported
                    else if (eff_priv < p0_sys_csr_addr_i[9:8]) sys_illegal = 1'b1;
                    else if (!csr_implemented) sys_illegal = 1'b1;
                    else if (csr_read_only && csr_write_intent) sys_illegal = 1'b1;
                    // TVM check: satp (0x180) in S-mode with mstatus.TVM == 1
                    else if (p0_sys_csr_addr_i == 12'h180 && eff_priv == 2'b01 && eff_mstatus[20]) sys_illegal = 1'b1;
                    // Counter access gates
                    else if (p0_sys_csr_addr_i >= 12'hc00 && p0_sys_csr_addr_i <= 12'hc02) begin
                        if (eff_priv == 2'b01 && !mcounteren_q[{4'd0, p0_sys_csr_addr_i[1:0]}]) sys_illegal = 1'b1;
                        else if (eff_priv == 2'b00 && (!mcounteren_q[{4'd0, p0_sys_csr_addr_i[1:0]}] || !scounteren_q[{4'd0, p0_sys_csr_addr_i[1:0]}])) sys_illegal = 1'b1;
                    end
                end

                default: begin
                    sys_illegal = 1'b1;
                end
            endcase
        end
    end

    assign p0_sys_rdata_o   = old_csr_val;
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
        logic [63:0]       pc;
        rob_idx_t          rob_idx;
        logic [63:0]       rs1_val;
        logic [63:0]       rs2_val;
    } sys_exec_entry_t;

    sys_exec_entry_t pending_sys_q;

    // Match retirement across both superscalar commit slots
    wire sys_retire_fire = pending_sys_q.valid && (
        (retire_valid_i[0] && (retire_rob_idx_i[0] == pending_sys_q.rob_idx)) ||
        (retire_valid_i[1] && (retire_rob_idx_i[1] == pending_sys_q.rob_idx))
    );

    // =========================================================================
    // 4. Sequential Architectural State & Retirement Handling
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            priv_mode_q  <= priv_mode_i;
            mstatus_q    <= (mstatus_i != 64'd0) ? mstatus_i : 64'h0000_000a_0000_1800;
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

            cycle_q      <= '0;

            pending_sys_q         <= '0;
            sys_redirect_valid_o  <= 1'b0;
            sys_redirect_target_o <= '0;
            sys_flush_valid_o     <= 1'b0;
            sfence_vma_valid_o    <= 1'b0;
            sfence_vma_va_o       <= '0;
            sfence_vma_asid_o     <= '0;
        end else begin
            // Free-running cycle counter
            cycle_q <= cycle_q + 64'd1;

            // Default pulses
            sys_redirect_valid_o <= 1'b0;
            sys_flush_valid_o    <= 1'b0;
            sfence_vma_valid_o   <= 1'b0;

            // Capture valid non-illegal system uop issued on Port 0
            if (p0_sys_valid_i && !sys_illegal) begin
                pending_sys_q.valid        <= 1'b1;
                pending_sys_q.sub_op       <= p0_sys_subop_i;
                pending_sys_q.csr_addr     <= p0_sys_csr_addr_i;
                pending_sys_q.write_val    <= csr_write_val;
                pending_sys_q.write_intent <= csr_write_intent;
                pending_sys_q.pc           <= p0_sys_pc_i;
                pending_sys_q.rob_idx      <= p0_sys_rob_idx_i;
                pending_sys_q.rs1_val      <= p0_sys_rs1_val_i;
                pending_sys_q.rs2_val      <= p0_sys_rs2_val_i;
            end

            // -----------------------------------------------------------------
            // Retirement Event Handling
            // -----------------------------------------------------------------
            if (retire_exception_i) begin
                // Precise synchronous trap at ROB head
                logic trap_to_s;
                trap_to_s = (priv_mode_q <= 2'b01) && medeleg_q[{1'b0, retire_exc_cause_i}];

                if (trap_to_s) begin
                    sepc_q   <= retire_exc_pc_i;
                    scause_q <= {1'b0, 58'd0, retire_exc_cause_i};
                    stval_q  <= (retire_exc_cause_i == 5'd0 || retire_exc_cause_i == 5'd1 || retire_exc_cause_i == 5'd12)
                                ? retire_exc_pc_i : 64'd0;
                    mstatus_q[5] <= mstatus_q[1]; // SPIE <= SIE
                    mstatus_q[1] <= 1'b0;         // SIE <= 0
                    mstatus_q[8] <= (priv_mode_q == 2'b01); // SPP <= (P == S)
                    priv_mode_q  <= 2'b01;        // privilege <= S

                    sys_redirect_valid_o  <= 1'b1;
                    sys_redirect_target_o <= (stvec_q[1:0] == 2'b01)
                                           ? ({stvec_q[63:2], 2'b00} + {57'd0, retire_exc_cause_i, 2'b00})
                                           : {stvec_q[63:2], 2'b00};
                    sys_flush_valid_o     <= 1'b1;
                end else begin
                    mepc_q   <= retire_exc_pc_i;
                    mcause_q <= {1'b0, 58'd0, retire_exc_cause_i};
                    mtval_q  <= (retire_exc_cause_i == 5'd0 || retire_exc_cause_i == 5'd1 || retire_exc_cause_i == 5'd12)
                                ? retire_exc_pc_i : 64'd0;
                    mstatus_q[7]     <= mstatus_q[3]; // MPIE <= MIE
                    mstatus_q[3]     <= 1'b0;         // MIE <= 0
                    mstatus_q[12:11] <= priv_mode_q;  // MPP <= P
                    priv_mode_q      <= 2'b11;        // privilege <= M

                    sys_redirect_valid_o  <= 1'b1;
                    sys_redirect_target_o <= (mtvec_q[1:0] == 2'b01)
                                           ? ({mtvec_q[63:2], 2'b00} + {57'd0, retire_exc_cause_i, 2'b00})
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
                        sfence_vma_valid_o    <= 1'b1;
                        sfence_vma_va_o       <= pending_sys_q.rs1_val;
                        sfence_vma_asid_o     <= pending_sys_q.rs2_val[15:0];

                        sys_redirect_valid_o  <= 1'b1;
                        sys_redirect_target_o <= pending_sys_q.pc + 64'd4;
                        sys_flush_valid_o     <= 1'b1;
                    end

                    SYS_WFI: begin
                        // Legal architectural no-op
                    end

                    SYS_CSRRW, SYS_CSRRS, SYS_CSRRC,
                    SYS_CSRRWI, SYS_CSRRSI, SYS_CSRRCI: begin
                        if (pending_sys_q.write_intent) begin
                            unique case (pending_sys_q.csr_addr)
                                12'h300: begin // mstatus
                                    mstatus_q <= 64'h0000_000a_0000_0000 |
                                                 (pending_sys_q.write_val & 64'h0000_0000_007e_19aa) |
                                                 (pending_sys_q.write_val[12:11] == 2'b10 ? 64'h1800 : 64'd0);
                                    sys_redirect_valid_o  <= 1'b1;
                                    sys_redirect_target_o <= pending_sys_q.pc + 64'd4;
                                    sys_flush_valid_o     <= 1'b1;
                                end
                                12'h302: medeleg_q    <= pending_sys_q.write_val & 64'hb3ff;
                                12'h303: mideleg_q    <= pending_sys_q.write_val & 64'h222;
                                12'h304: mie_q        <= pending_sys_q.write_val & 64'haaa;
                                12'h305: mtvec_q      <= {pending_sys_q.write_val[63:2],
                                                         (pending_sys_q.write_val[1:0] <= 2'b01) ? pending_sys_q.write_val[1:0] : 2'b00};
                                12'h306: mcounteren_q <= pending_sys_q.write_val & 64'd7;
                                12'h30a: menvcfg_q    <= pending_sys_q.write_val & 64'd1;
                                12'h340: mscratch_q   <= pending_sys_q.write_val;
                                12'h341: mepc_q       <= {pending_sys_q.write_val[63:2], 2'b00};
                                12'h342: mcause_q     <= pending_sys_q.write_val;
                                12'h343: mtval_q      <= pending_sys_q.write_val;
                                12'h344: mip_q        <= (mip_q & ~64'h222) | (pending_sys_q.write_val & 64'h222);

                                // S-mode CSRs
                                12'h100: begin // sstatus
                                    mstatus_q[1]  <= pending_sys_q.write_val[1];  // SIE
                                    mstatus_q[5]  <= pending_sys_q.write_val[5];  // SPIE
                                    mstatus_q[8]  <= pending_sys_q.write_val[8];  // SPP
                                    mstatus_q[18] <= pending_sys_q.write_val[18]; // SUM
                                    mstatus_q[19] <= pending_sys_q.write_val[19]; // MXR
                                    sys_redirect_valid_o  <= 1'b1;
                                    sys_redirect_target_o <= pending_sys_q.pc + 64'd4;
                                    sys_flush_valid_o     <= 1'b1;
                                end
                                12'h104: mie_q        <= (mie_q & ~(mideleg_q & 64'h222)) | (pending_sys_q.write_val & (mideleg_q & 64'h222));
                                12'h105: stvec_q      <= {pending_sys_q.write_val[63:2],
                                                         (pending_sys_q.write_val[1:0] <= 2'b01) ? pending_sys_q.write_val[1:0] : 2'b00};
                                12'h106: scounteren_q <= pending_sys_q.write_val & 64'd7;
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
                                    sys_redirect_target_o <= pending_sys_q.pc + 64'd4;
                                    sys_flush_valid_o     <= 1'b1;
                                end

                                default: ;
                            endcase
                        end
                    end

                    default: ;
                endcase
            end
        end
    end

endmodule

`endif // FURSOY_S1_CSR_SV
