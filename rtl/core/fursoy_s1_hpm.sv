`ifndef FURSOY_S1_HPM_SV
`define FURSOY_S1_HPM_SV

// =============================================================================
// Fursoy Slice-1 Hardware Performance Monitor (HPM) Subsystem — Milestone 5
// =============================================================================
// Canonical Reference: docs/architecture/slice1-m5-performance-v1.md Section 8 & 9
//
// Key Features:
// - 48 Hardware Performance Event Sources (0x01 .. 0x30).
//   (Events 0x24 and 0x27 are Phase B only and driven to zero in Phase A).
// - Up to 29 Programmable 64-bit Performance Event Counters (hpmcounter3..31).
// - 29 Event Selector Registers (mhpmevent3..31), storing 6-bit event IDs.
// - Base Architected Counters: mcycle (0xB00/0xC00), minstret (0xB02/0xC02).
// - Deterministic Single-Owner CPI Cycle Accounting Engine:
//   8 mutually exclusive master categories evaluated in strict priority order:
//     1. C_serialize
//     2. C_br_recover
//     3. C_productive
//     4. C_mem_stall
//     5. C_be_rename
//     6. C_be_sched
//     7. C_fe_starve
//     8. C_idle_other
//   Zero-leakage invariant: sum(C_k) == delta(mcycle) guaranteed by construction.
// - All-mode monitoring: Hardware events count core activity across M, S, and U modes.
// - Precise branch misprediction retirement tracking (0x0E, 0x0F, 0x12).
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_hpm
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // -------------------------------------------------------------------------
    // CSR Read / Write Bus (from fursoy_s1_csr)
    // -------------------------------------------------------------------------
    input  logic [11:0]       csr_raddr_i,
    output logic [63:0]       csr_rdata_o,
    output logic              csr_hit_o,

    input  logic              csr_we_i,
    input  logic [11:0]       csr_waddr_i,
    input  logic [63:0]       csr_wdata_i,

    // -------------------------------------------------------------------------
    // Retirement Interface (from Superscalar ROB)
    // -------------------------------------------------------------------------
    input  logic [1:0]        retire_valid_i,
    input  rob_idx_t          retire_rob_idx_i     [1:0],

    // -------------------------------------------------------------------------
    // Branch Recovery Interface (for Precise Mispredict Retirement Events)
    // -------------------------------------------------------------------------
    input  logic              recover_valid_i,
    input  rob_idx_t          recover_rob_idx_i,
    input  branch_type_t      recover_br_type_i,
    input  logic              flush_valid_i,

    // -------------------------------------------------------------------------
    // 48 Hardware Performance Event Sources (0x01 .. 0x30)
    // -------------------------------------------------------------------------
    input  logic              ev_fetch_cycles_i,     // 0x01: EV_FETCH_CYCLES
    input  logic              ev_fetch_blocks_i,     // 0x02: EV_FETCH_BLOCKS
    input  logic [1:0]        ev_fetch_uops_i,       // 0x03: EV_FETCH_UOPS
    input  logic              ev_fetch_fq_starved_i, // 0x04: EV_FETCH_FQ_STARVED
    input  logic              ev_fetch_fq_full_i,    // 0x05: EV_FETCH_FQ_FULL
    input  logic              ev_fetch_odd_slot_i,   // 0x06: EV_FETCH_ODD_SLOT
    input  logic              ev_l1i_hits_i,         // 0x07: EV_L1I_HITS
    input  logic              ev_l1i_misses_i,       // 0x08: EV_L1I_MISSES
    input  logic [1:0]        ev_l1i_imshr_occ_i,    // 0x09: EV_L1I_IMSHR_OCC
    input  logic              ev_itlb_misses_i,      // 0x0A: EV_ITLB_MISSES
    input  logic              ev_btb_queries_i,      // 0x0B: EV_BTB_QUERIES
    input  logic              ev_btb_hits_i,         // 0x0C: EV_BTB_HITS
    input  logic              ev_bpu_cond_pred_i,    // 0x0D: EV_BPU_COND_PRED
    // 0x0E: EV_BPU_DIR_MISPRED (precise at retire, generated internally)
    // 0x0F: EV_BPU_TGT_MISPRED (precise at retire, generated internally)
    input  logic              ev_ras_call_push_i,    // 0x10: EV_RAS_CALL_PUSH
    input  logic              ev_ras_ret_pop_i,      // 0x11: EV_RAS_RET_POP
    // 0x12: EV_RAS_RET_MISPRED (precise at retire, generated internally)
    input  logic [1:0]        ev_rename_uops_i,      // 0x13: EV_RENAME_UOPS
    input  logic              ev_stall_rob_full_i,   // 0x14: EV_STALL_ROB_FULL
    input  logic              ev_stall_intiq_full_i, // 0x15: EV_STALL_INTIQ_FULL
    input  logic              ev_stall_memiq_full_i, // 0x16: EV_STALL_MEMIQ_FULL
    input  logic              ev_stall_lq_full_i,    // 0x17: EV_STALL_LQ_FULL
    input  logic              ev_stall_sq_full_i,    // 0x18: EV_STALL_SQ_FULL
    input  logic              ev_stall_chkpt_full_i, // 0x19: EV_STALL_CHKPT_FULL
    input  logic              ev_stall_recovery_i,   // 0x1A: EV_STALL_RECOVERY
    input  logic              ev_issue_port0_i,      // 0x1B: EV_ISSUE_PORT0
    input  logic              ev_issue_port1_alu_i,  // 0x1C: EV_ISSUE_PORT1_ALU
    input  logic              ev_issue_port1_mul_i,  // 0x1D: EV_ISSUE_PORT1_MUL
    input  logic              ev_issue_port1_div_i,  // 0x1E: EV_ISSUE_PORT1_DIV
    input  logic              ev_issue_port2_agu_i,  // 0x1F: EV_ISSUE_PORT2_AGU
    input  logic              ev_port1_wb_stall_i,   // 0x20: EV_PORT1_WB_STALL
    input  logic              ev_intiq_empty_i,      // 0x21: EV_INTIQ_EMPTY
    input  logic              ev_memiq_empty_i,      // 0x22: EV_MEMIQ_EMPTY
    input  logic              ev_load_issued_i,      // 0x23: EV_LOAD_ISSUED
    input  logic              ev_load_speculative_i, // 0x24: EV_LOAD_SPECULATIVE (Phase B)
    input  logic              ev_load_fwd_exact_i,   // 0x25: EV_LOAD_FWD_EXACT
    input  logic              ev_load_fwd_partial_i, // 0x26: EV_LOAD_FWD_PARTIAL
    input  logic              ev_load_raw_violat_i,  // 0x27: EV_LOAD_RAW_VIOLAT (Phase B)
    input  logic              ev_l1d_hits_i,         // 0x28: EV_L1D_HITS
    input  logic              ev_l1d_misses_i,       // 0x29: EV_L1D_MISSES
    input  logic [2:0]        ev_l1d_mshr_occ_i,     // 0x2A: EV_L1D_MSHR_OCC
    input  logic              ev_l1d_wbb_full_i,     // 0x2B: EV_L1D_WBB_FULL
    input  logic              ev_dtlb_misses_i,      // 0x2C: EV_DTLB_MISSES
    input  logic              ev_retire_cycles_0_i,  // 0x2D: EV_RETIRE_CYCLES_0
    input  logic              ev_retire_cycles_1_i,  // 0x2E: EV_RETIRE_CYCLES_1
    input  logic              ev_retire_cycles_2_i,  // 0x2F: EV_RETIRE_CYCLES_2
    input  logic              ev_serialize_cycles_i, // 0x30: EV_SERIALIZE_CYCLES

    // -------------------------------------------------------------------------
    // Deterministic Single-Owner CPI Classification Predicates (Section 9.1)
    // -------------------------------------------------------------------------
    input  logic              cpi_serialize_i,       // Priority 1: FENCE.I, SFENCE.VMA, CSR serialize
    input  logic              cpi_br_recover_i,      // Priority 2: recovering_o == 1
    input  logic              cpi_productive_i,      // Priority 3: retire_count > 0
    input  logic              cpi_mem_stall_i,       // Priority 4: ROB head waiting on memory
    input  logic              cpi_be_rename_i,       // Priority 5: FQ non-empty, Rename stalled
    input  logic              cpi_be_sched_i,        // Priority 6: ROB non-empty, 0 ready uops
    input  logic              cpi_fe_starve_i,       // Priority 7: FQ empty while core active

    // -------------------------------------------------------------------------
    // Observability & Diagnostics Outputs (for TB & Profiling Engine)
    // -------------------------------------------------------------------------
    output logic [63:0]       mcycle_o,
    output logic [63:0]       minstret_o,
    output logic [63:0]       mhpmcounter_o        [32],
    output logic [63:0]       cpi_category_o       [8],
    output logic [7:0]        cpi_active_owner_o,
    output logic [48:1]       raw_event_pulse_o
);

    // =========================================================================
    // 1. Precise Branch Mispredict Retirement Tracking (Events 0x0E, 0x0F, 0x12)
    // =========================================================================
    logic         pending_mispred_valid_q;
    rob_idx_t     pending_mispred_rob_idx_q;
    branch_type_t pending_mispred_type_q;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_valid_i) begin
            pending_mispred_valid_q   <= 1'b0;
            pending_mispred_rob_idx_q <= '0;
            pending_mispred_type_q    <= BR_TYPE_COND;
        end else begin
            if (recover_valid_i) begin
                pending_mispred_valid_q   <= 1'b1;
                pending_mispred_rob_idx_q <= recover_rob_idx_i;
                pending_mispred_type_q    <= recover_br_type_i;
            end else if (pending_mispred_valid_q) begin
                if ((retire_valid_i[0] && (retire_rob_idx_i[0] == pending_mispred_rob_idx_q)) ||
                    (retire_valid_i[1] && (retire_rob_idx_i[1] == pending_mispred_rob_idx_q))) begin
                    pending_mispred_valid_q <= 1'b0;
                end
            end
        end
    end

    wire mispred_retiring = pending_mispred_valid_q && (
        (retire_valid_i[0] && (retire_rob_idx_i[0] == pending_mispred_rob_idx_q)) ||
        (retire_valid_i[1] && (retire_rob_idx_i[1] == pending_mispred_rob_idx_q))
    );

    wire ev_bpu_dir_mispred = mispred_retiring && (pending_mispred_type_q == BR_TYPE_COND);
    wire ev_bpu_tgt_mispred = mispred_retiring && ((pending_mispred_type_q == BR_TYPE_JALR) ||
                                                   (pending_mispred_type_q == BR_TYPE_IND) ||
                                                   (pending_mispred_type_q == BR_TYPE_CALL));
    wire ev_ras_ret_mispred = mispred_retiring && (pending_mispred_type_q == BR_TYPE_RET);

    // =========================================================================
    // 2. Hardware Performance Event Value Multiplexer (0x01 .. 0x30)
    // =========================================================================
    logic [63:0] event_val [49]; // 0x00 .. 0x30

    always_comb begin
        event_val[6'h00] = 64'd0;
        event_val[6'h01] = {63'd0, ev_fetch_cycles_i};
        event_val[6'h02] = {63'd0, ev_fetch_blocks_i};
        event_val[6'h03] = {62'd0, ev_fetch_uops_i};
        event_val[6'h04] = {63'd0, ev_fetch_fq_starved_i};
        event_val[6'h05] = {63'd0, ev_fetch_fq_full_i};
        event_val[6'h06] = {63'd0, ev_fetch_odd_slot_i};
        event_val[6'h07] = {63'd0, ev_l1i_hits_i};
        event_val[6'h08] = {63'd0, ev_l1i_misses_i};
        event_val[6'h09] = {62'd0, ev_l1i_imshr_occ_i};
        event_val[6'h0A] = {63'd0, ev_itlb_misses_i};
        event_val[6'h0B] = {63'd0, ev_btb_queries_i};
        event_val[6'h0C] = {63'd0, ev_btb_hits_i};
        event_val[6'h0D] = {63'd0, ev_bpu_cond_pred_i};
        event_val[6'h0E] = {63'd0, ev_bpu_dir_mispred};
        event_val[6'h0F] = {63'd0, ev_bpu_tgt_mispred};
        event_val[6'h10] = {63'd0, ev_ras_call_push_i};
        event_val[6'h11] = {63'd0, ev_ras_ret_pop_i};
        event_val[6'h12] = {63'd0, ev_ras_ret_mispred};
        event_val[6'h13] = {62'd0, ev_rename_uops_i};
        event_val[6'h14] = {63'd0, ev_stall_rob_full_i};
        event_val[6'h15] = {63'd0, ev_stall_intiq_full_i};
        event_val[6'h16] = {63'd0, ev_stall_memiq_full_i};
        event_val[6'h17] = {63'd0, ev_stall_lq_full_i};
        event_val[6'h18] = {63'd0, ev_stall_sq_full_i};
        event_val[6'h19] = {63'd0, ev_stall_chkpt_full_i};
        event_val[6'h1A] = {63'd0, ev_stall_recovery_i};
        event_val[6'h1B] = {63'd0, ev_issue_port0_i};
        event_val[6'h1C] = {63'd0, ev_issue_port1_alu_i};
        event_val[6'h1D] = {63'd0, ev_issue_port1_mul_i};
        event_val[6'h1E] = {63'd0, ev_issue_port1_div_i};
        event_val[6'h1F] = {63'd0, ev_issue_port2_agu_i};
        event_val[6'h20] = {63'd0, ev_port1_wb_stall_i};
        event_val[6'h21] = {63'd0, ev_intiq_empty_i};
        event_val[6'h22] = {63'd0, ev_memiq_empty_i};
        event_val[6'h23] = {63'd0, ev_load_issued_i};
        event_val[6'h24] = {63'd0, ev_load_speculative_i}; // Phase B only (0 in Phase A)
        event_val[6'h25] = {63'd0, ev_load_fwd_exact_i};
        event_val[6'h26] = {63'd0, ev_load_fwd_partial_i};
        event_val[6'h27] = {63'd0, ev_load_raw_violat_i};  // Phase B only (0 in Phase A)
        event_val[6'h28] = {63'd0, ev_l1d_hits_i};
        event_val[6'h29] = {63'd0, ev_l1d_misses_i};
        event_val[6'h2A] = {61'd0, ev_l1d_mshr_occ_i};
        event_val[6'h2B] = {63'd0, ev_l1d_wbb_full_i};
        event_val[6'h2C] = {63'd0, ev_dtlb_misses_i};
        event_val[6'h2D] = {63'd0, ev_retire_cycles_0_i};
        event_val[6'h2E] = {63'd0, ev_retire_cycles_1_i};
        event_val[6'h2F] = {63'd0, ev_retire_cycles_2_i};
        event_val[6'h30] = {63'd0, ev_serialize_cycles_i};
    end

    // Raw pulse output for observability
    always_comb begin
        for (int e = 1; e <= 48; e++) begin
            raw_event_pulse_o[e] = (event_val[e] != 64'd0);
        end
    end

    // =========================================================================
    // 3. Base Architected Performance Counters: mcycle & minstret
    // =========================================================================
    logic [63:0] mcycle_q;
    logic [63:0] minstret_q;

    wire mcycle_we   = csr_we_i && (csr_waddr_i == 12'hB00);
    wire minstret_we = csr_we_i && (csr_waddr_i == 12'hB02);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            mcycle_q <= 64'd0;
        end else if (mcycle_we) begin
            mcycle_q <= csr_wdata_i;
        end else begin
            mcycle_q <= mcycle_q + 64'd1;
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            minstret_q <= 64'd0;
        end else if (minstret_we) begin
            minstret_q <= csr_wdata_i;
        end else begin
            minstret_q <= minstret_q + {63'd0, retire_valid_i[0]} + {63'd0, retire_valid_i[1]};
        end
    end

    assign mcycle_o   = mcycle_q;
    assign minstret_o = minstret_q;

    // =========================================================================
    // 4. Programmable Performance Counters & Selectors (hpmcounter3..31)
    // =========================================================================
    logic [5:0]  mhpmevent_q   [3:31];
    logic [63:0] mhpmcounter_q [3:31];

    generate
        for (genvar c = 3; c <= 31; c++) begin : g_hpm_counters
            wire sel_we = csr_we_i && (csr_waddr_i == (12'h320 + 12'(c)));
            wire cnt_we = csr_we_i && (csr_waddr_i == (12'hB00 + 12'(c)));

            always_ff @(posedge clk_i) begin
                if (rst_i) begin
                    mhpmevent_q[c]   <= 6'd0;
                    mhpmcounter_q[c] <= 64'd0;
                end else begin
                    // Selector update
                    if (sel_we) begin
                        mhpmevent_q[c] <= csr_wdata_i[5:0];
                    end

                    // Counter update: CSR write overrides hardware increment
                    if (cnt_we) begin
                        mhpmcounter_q[c] <= csr_wdata_i;
                    end else if (mhpmevent_q[c] <= 6'h30) begin
                        mhpmcounter_q[c] <= mhpmcounter_q[c] + event_val[mhpmevent_q[c]];
                    end
                end
            end
        end
    endgenerate

    // Export array of 32 counters for observability
    always_comb begin
        mhpmcounter_o[0] = mcycle_q;
        mhpmcounter_o[1] = mcycle_q; // shadow time
        mhpmcounter_o[2] = minstret_q;
        for (int i = 3; i <= 31; i++) begin
            mhpmcounter_o[i] = mhpmcounter_q[i];
        end
    end

    // =========================================================================
    // 5. Authoritative Single-Owner CPI Cycle Accounting Engine (Section 9)
    // =========================================================================
    // Priority Hierarchy (Priority 1 through Priority 8, mutually exclusive):
    // 1. C_serialize
    // 2. C_br_recover
    // 3. C_productive
    // 4. C_mem_stall
    // 5. C_be_rename
    // 6. C_be_sched
    // 7. C_fe_starve
    // 8. C_idle_other
    logic [7:0] cpi_owner; // One-hot active category owner

    always_comb begin
        cpi_owner = 8'b0;
        if (cpi_serialize_i) begin
            cpi_owner[0] = 1'b1; // Category 0: C_serialize (Priority 1)
        end else if (cpi_br_recover_i) begin
            cpi_owner[1] = 1'b1; // Category 1: C_br_recover (Priority 2)
        end else if (cpi_productive_i) begin
            cpi_owner[2] = 1'b1; // Category 2: C_productive (Priority 3)
        end else if (cpi_mem_stall_i) begin
            cpi_owner[3] = 1'b1; // Category 3: C_mem_stall (Priority 4)
        end else if (cpi_be_rename_i) begin
            cpi_owner[4] = 1'b1; // Category 4: C_be_rename (Priority 5)
        end else if (cpi_be_sched_i) begin
            cpi_owner[5] = 1'b1; // Category 5: C_be_sched (Priority 6)
        end else if (cpi_fe_starve_i) begin
            cpi_owner[6] = 1'b1; // Category 6: C_fe_starve (Priority 7)
        end else begin
            cpi_owner[7] = 1'b1; // Category 7: C_idle_other (Priority 8)
        end
    end

    assign cpi_active_owner_o = cpi_owner;

    logic [63:0] cpi_category_q [8];

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int k = 0; k < 8; k++) begin
                cpi_category_q[k] <= 64'd0;
            end
        end else begin
            for (int k = 0; k < 8; k++) begin
                if (cpi_owner[k]) begin
                    cpi_category_q[k] <= cpi_category_q[k] + 64'd1;
                end
            end
        end
    end

    always_comb begin
        for (int k = 0; k < 8; k++) begin
            cpi_category_o[k] = cpi_category_q[k];
        end
    end

    // Dynamic Zero-Leakage Assertion (Section 9.2)
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            // Verify that the sum of the 8 categories equals mcycle
            // (holding when mcycle has not been overwritten by CSR)
            assert (
                cpi_category_q[0] + cpi_category_q[1] + cpi_category_q[2] + cpi_category_q[3] +
                cpi_category_q[4] + cpi_category_q[5] + cpi_category_q[6] + cpi_category_q[7] == mcycle_q
            ) else $error("[HPM CPI LEAKAGE ERROR] Sum of 8 CPI categories != mcycle!");
        end
    end
`endif

    // =========================================================================
    // 6. CSR Read Bus Decoder
    // =========================================================================
    always_comb begin
        csr_hit_o   = 1'b1;
        csr_rdata_o = 64'd0;

        case (csr_raddr_i)
            12'hB00, 12'hC00, 12'hC01: csr_rdata_o = mcycle_q;
            12'hB02, 12'hC02:         csr_rdata_o = minstret_q;
            default: begin
                if (csr_raddr_i >= 12'hB03 && csr_raddr_i <= 12'hB1F) begin
                    csr_rdata_o = mhpmcounter_q[csr_raddr_i[4:0]];
                end else if (csr_raddr_i >= 12'hC03 && csr_raddr_i <= 12'hC1F) begin
                    csr_rdata_o = mhpmcounter_q[csr_raddr_i[4:0]];
                end else if (csr_raddr_i >= 12'h323 && csr_raddr_i <= 12'h33F) begin
                    csr_rdata_o = {58'd0, mhpmevent_q[csr_raddr_i[4:0]]};
                end else begin
                    csr_hit_o   = 1'b0;
                    csr_rdata_o = 64'd0;
                end
            end
        endcase
    end

endmodule

`endif // FURSOY_S1_HPM_SV
