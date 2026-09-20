`ifndef FURSOY_S1_PTW_SV
`define FURSOY_S1_PTW_SV

// =============================================================================
// Fursoy Slice-1 Centralized Shared Sv39 Hardware Page Table Walker (PTW)
// =============================================================================
// Serves:
// - Milestone 3 Data TLB / TRT (DTLB)
// - Milestone 4 Instruction TLB / ITRT (ITLB)
// Features:
// - Bounded fairness arbitration (4:1 grant ratio with dtlb_grants_since_itlb).
// - Full 3-level page table walk (Level 2 -> Level 1 -> Level 0).
// - 4 KiB base pages, 2 MiB and 1 GiB superpage support with alignment checks.
// - Privilege, execute (X), read (R), write (W), SUM, MXR, and A/D bit validation.
// - Dedicated external memory read port for coherent 64-bit PTE fetches outside L1D.
// Reference: docs/architecture/slice1-m4-frontend-v1.md Section 9
// =============================================================================

`include "fursoy_s1_pkg.sv"

/* verilator lint_off UNUSEDSIGNAL */
module fursoy_s1_ptw
    import fursoy_s1_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_i,

    // Architectural System Controls (from CSRs / Privilege Mode)
    input  logic [1:0]        priv_mode_i,       // 00=U, 01=S, 11=M
    input  logic [63:0]       mstatus_i,
    input  logic [63:0]       satp_i,

    // -------------------------------------------------------------------------
    // Request Interface from M3 DTLB / TRT
    // -------------------------------------------------------------------------
    input  logic              dtlb_req_valid_i,
    input  tr_id_t            dtlb_req_tr_id_i,
    input  logic [26:0]       dtlb_req_vpn_i,
    input  logic              dtlb_req_is_store_i,
    input  logic              dtlb_req_is_amo_i,
    output logic              dtlb_req_ready_o,

    // Response Interface to M3 DTLB / TRT
    output logic              dtlb_rsp_valid_o,
    output tr_id_t            dtlb_rsp_tr_id_o,
    output logic [55:0]       dtlb_rsp_pa_o,
    output logic              dtlb_rsp_page_fault_o,
    output logic              dtlb_rsp_access_fault_o,

    // -------------------------------------------------------------------------
    // Request Interface from M4 ITLB / ITRT
    // -------------------------------------------------------------------------
    input  logic              itlb_req_valid_i,
    input  logic              itlb_req_itrt_id_i,
    input  logic [26:0]       itlb_req_vpn_i,
    output logic              itlb_req_ready_o,

    // Response Interface to M4 ITLB / ITRT
    output logic              itlb_rsp_valid_o,
    output logic              itlb_rsp_itrt_id_o,
    output logic [55:0]       itlb_rsp_pa_o,
    output logic              itlb_rsp_page_fault_o,
    output logic              itlb_rsp_access_fault_o,
    output logic [1:0]        itlb_rsp_level_o,
    output logic [63:0]       itlb_rsp_pte_o,

    // -------------------------------------------------------------------------
    // Memory Interface (Coherent 64-bit PTE Reads outside L1D)
    // -------------------------------------------------------------------------
    output logic              mem_req_valid_o,
    output logic [55:0]       mem_req_addr_o,
    input  logic              mem_req_ready_i,

    input  logic              mem_rsp_valid_i,
    input  logic [63:0]       mem_rsp_data_i,
    input  logic              mem_rsp_error_i,

    // Diagnostics
    output logic [2:0]        diag_grants_since_itlb_o
);

    // SATP fields
    wire        satp_mode_sv39 = (satp_i[63:60] == 4'd8);
    wire [43:0] satp_ppn       = satp_i[43:0];

    // Status bits
    wire sstatus_sum = mstatus_i[18]; // Permit Supervisor User Memory access
    wire sstatus_mxr = mstatus_i[19]; // Make eXecutable Readable

    // =========================================================================
    // 1. Bounded Fairness Request Arbiter (Section 9.2)
    // =========================================================================
    // DTLB Priority 1; ITLB Priority 2.
    // If ITLB is pending and 4 consecutive DTLB grants occurred: force grant to ITLB.
    logic [2:0] dtlb_grants_since_itlb;
    assign diag_grants_since_itlb_o = dtlb_grants_since_itlb;

    logic arb_grant_dtlb;
    logic arb_grant_itlb;

    typedef enum logic [2:0] {
        PTW_IDLE        = 3'd0,
        PTW_REQ_MEM     = 3'd1,
        PTW_WAIT_RSP    = 3'd2,
        PTW_SEND_RSP    = 3'd3
    } ptw_state_t;

    ptw_state_t ptw_state_q;

    always_comb begin
        arb_grant_dtlb = 1'b0;
        arb_grant_itlb = 1'b0;

        if (ptw_state_q == PTW_IDLE) begin
            if (itlb_req_valid_i && (dtlb_grants_since_itlb >= 3'd4)) begin
                arb_grant_itlb = 1'b1;
            end else if (dtlb_req_valid_i) begin
                arb_grant_dtlb = 1'b1;
            end else if (itlb_req_valid_i) begin
                arb_grant_itlb = 1'b1;
            end
        end
    end

    assign dtlb_req_ready_o = (ptw_state_q == PTW_IDLE) && arb_grant_dtlb;
    assign itlb_req_ready_o = (ptw_state_q == PTW_IDLE) && arb_grant_itlb;

    // =========================================================================
    // 2. Walker Datapath and State Variables
    // =========================================================================
    logic        active_is_itlb;     // 1=ITLB, 0=DTLB
    tr_id_t      active_dtlb_tr_id;
    logic        active_itlb_itrt_id;
    logic [26:0] active_vpn;
    logic        active_is_store;
    logic [1:0]  active_level;       // 2=Level 2, 1=Level 1, 0=Level 0
    logic [55:0] active_pte_addr;
    logic [43:0] next_base_ppn;

    logic        rsp_valid_q;
    logic [55:0] rsp_pa_q;
    logic        rsp_page_fault_q;
    logic        rsp_access_fault_q;
    logic [1:0]  rsp_level_q;
    logic [63:0] rsp_pte_q;

    // Split VPN into 9-bit chunks
    wire [8:0] vpn2 = active_vpn[26:18];
    wire [8:0] vpn1 = active_vpn[17:9];
    wire [8:0] vpn0 = active_vpn[8:0];

    // =========================================================================
    // 3. PTE Permission & Alignment Validation
    // =========================================================================
    function automatic logic check_leaf_valid(
        input logic [63:0] pte,
        input logic [1:0]  level,
        input logic        is_itlb,
        input logic        is_store,
        input logic [1:0]  priv,
        input logic        sum,
        input logic        mxr,
        output logic       is_page_fault
    );
        logic v, r, w, x, u, a, d;
        begin
            v = pte[0];
            r = pte[1];
            w = pte[2];
            x = pte[3];
            u = pte[4];
            a = pte[6];
            d = pte[7];

            is_page_fault = 1'b0;

            // V==0 or (R==0 and W==1) is invalid
            if (!v || (!r && w)) begin
                is_page_fault = 1'b1;
                return 1'b0;
            end

            // Must be leaf
            if (!r && !x) begin
                return 1'b0; // Pointer, not leaf
            end

            // Superpage alignment check
            if (level == 2'd2 && (pte[27:10] != 18'd0)) is_page_fault = 1'b1;
            if (level == 2'd1 && (pte[18:10] != 9'd0))  is_page_fault = 1'b1;

            // Privilege check
            if (priv == 2'b00) begin // User mode
                if (!u) is_page_fault = 1'b1;
            end else if (priv == 2'b01) begin // Supervisor mode
                if (is_itlb) begin
                    // Section 2: S-mode instruction fetch from U-pages MUST fault regardless of SUM
                    if (u) is_page_fault = 1'b1;
                end else begin
                    if (u && !sum) is_page_fault = 1'b1;
                end
            end

            // Type permission check
            if (is_itlb) begin
                // Fetch requires Execute
                if (!x) is_page_fault = 1'b1;
                if (!a) is_page_fault = 1'b1;
            end else begin
                // Data load/store
                if (is_store) begin
                    if (!w) is_page_fault = 1'b1;
                    if (!d) is_page_fault = 1'b1;
                end else begin
                    if (!r && !(mxr && x)) is_page_fault = 1'b1;
                end
                if (!a) is_page_fault = 1'b1;
            end

            return 1'b1; // Valid leaf
        end
    endfunction

    // =========================================================================
    // 4. State Machine Execution
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ptw_state_q             <= PTW_IDLE;
            dtlb_grants_since_itlb  <= 3'd0;
            active_is_itlb          <= 1'b0;
            active_dtlb_tr_id       <= '0;
            active_itlb_itrt_id     <= 1'b0;
            active_vpn              <= '0;
            active_is_store         <= 1'b0;
            active_level            <= 2'd2;
            active_pte_addr         <= '0;
            next_base_ppn           <= '0;
            rsp_valid_q             <= 1'b0;
            rsp_pa_q                <= '0;
            rsp_page_fault_q        <= 1'b0;
            rsp_access_fault_q      <= 1'b0;
            rsp_level_q             <= 2'd0;
            rsp_pte_q               <= 64'd0;
            mem_req_valid_o         <= 1'b0;
            mem_req_addr_o          <= '0;
        end else begin
            rsp_valid_q <= 1'b0;

            case (ptw_state_q)
                PTW_IDLE: begin
                    if (arb_grant_itlb) begin
                        active_is_itlb          <= 1'b1;
                        active_itlb_itrt_id     <= itlb_req_itrt_id_i;
                        active_vpn              <= itlb_req_vpn_i;
                        active_is_store         <= 1'b0;
                        active_level            <= 2'd2;
                        next_base_ppn           <= satp_ppn;
                        active_pte_addr         <= {satp_ppn[43:0], itlb_req_vpn_i[26:18], 3'b000};
                        ptw_state_q             <= PTW_REQ_MEM;
                        dtlb_grants_since_itlb  <= 3'd0; // Reset counter on ITLB grant
                    end else if (arb_grant_dtlb) begin
                        active_is_itlb          <= 1'b0;
                        active_dtlb_tr_id       <= dtlb_req_tr_id_i;
                        active_vpn              <= dtlb_req_vpn_i;
                        active_is_store         <= dtlb_req_is_store_i || dtlb_req_is_amo_i;
                        active_level            <= 2'd2;
                        next_base_ppn           <= satp_ppn;
                        active_pte_addr         <= {satp_ppn[43:0], dtlb_req_vpn_i[26:18], 3'b000};
                        ptw_state_q             <= PTW_REQ_MEM;
                        if (itlb_req_valid_i) begin
                            dtlb_grants_since_itlb <= dtlb_grants_since_itlb + 1'b1;
                        end
                    end
                end

                PTW_REQ_MEM: begin
                    mem_req_valid_o <= 1'b1;
                    mem_req_addr_o  <= active_pte_addr;
                    if (mem_req_ready_i) begin
                        ptw_state_q <= PTW_WAIT_RSP;
                    end
                end

                PTW_WAIT_RSP: begin
                    mem_req_valid_o <= 1'b0;
                    if (mem_rsp_valid_i) begin
                        if (mem_rsp_error_i) begin
                            // External memory access error
                            rsp_valid_q        <= 1'b1;
                            rsp_pa_q           <= '0;
                            rsp_page_fault_q   <= 1'b0;
                            rsp_access_fault_q <= 1'b1;
                            rsp_level_q        <= 2'd0;
                            rsp_pte_q          <= 64'd0;
                            ptw_state_q        <= PTW_SEND_RSP;
                        end else begin
                            logic is_fault;
                            logic is_leaf;
                            logic [63:0] pte;
                            pte = mem_rsp_data_i;

                            is_leaf = check_leaf_valid(
                                pte,
                                active_level,
                                active_is_itlb,
                                active_is_store,
                                priv_mode_i,
                                sstatus_sum,
                                sstatus_mxr,
                                is_fault
                            );

                            if (is_fault) begin
                                rsp_valid_q        <= 1'b1;
                                rsp_pa_q           <= '0;
                                rsp_page_fault_q   <= 1'b1;
                                rsp_access_fault_q <= 1'b0;
                                rsp_level_q        <= 2'd0;
                                rsp_pte_q          <= 64'd0;
                                ptw_state_q        <= PTW_SEND_RSP;
                            end else if (is_leaf) begin
                                // Valid leaf PTE reached!
                                logic [55:0] leaf_pa;
                                if (active_level == 2'd2) begin
                                    // 1 GiB superpage
                                    leaf_pa = {pte[53:28], vpn1, vpn0, 12'd0};
                                end else if (active_level == 2'd1) begin
                                    // 2 MiB superpage
                                    leaf_pa = {pte[53:19], vpn0, 12'd0};
                                end else begin
                                    // 4 KiB base page
                                    leaf_pa = {pte[53:10], 12'd0};
                                end

                                rsp_valid_q        <= 1'b1;
                                rsp_pa_q           <= leaf_pa;
                                rsp_page_fault_q   <= 1'b0;
                                rsp_access_fault_q <= 1'b0;
                                rsp_level_q        <= active_level;
                                rsp_pte_q          <= pte;
                                ptw_state_q        <= PTW_SEND_RSP;
                            end else begin
                                // Valid pointer to next table level
                                if (active_level == 2'd2) begin
                                    active_level    <= 2'd1;
                                    next_base_ppn   <= pte[53:10];
                                    active_pte_addr <= {pte[53:10], vpn1, 3'b000};
                                    ptw_state_q     <= PTW_REQ_MEM;
                                end else if (active_level == 2'd1) begin
                                    active_level    <= 2'd0;
                                    next_base_ppn   <= pte[53:10];
                                    active_pte_addr <= {pte[53:10], vpn0, 3'b000};
                                    ptw_state_q     <= PTW_REQ_MEM;
                                end else begin
                                    // Level 0 cannot be a pointer!
                                    rsp_valid_q        <= 1'b1;
                                    rsp_pa_q           <= '0;
                                    rsp_page_fault_q   <= 1'b1;
                                    rsp_access_fault_q <= 1'b0;
                                    ptw_state_q        <= PTW_SEND_RSP;
                                end
                            end
                        end
                    end
                end

                PTW_SEND_RSP: begin
                    // 1-cycle response pulse delivered to DTLB or ITLB
                    ptw_state_q <= PTW_IDLE;
                end

                default: begin
                    ptw_state_q <= PTW_IDLE;
                end
            endcase
        end
    end

    // Response Routing
    assign dtlb_rsp_valid_o        = rsp_valid_q && !active_is_itlb;
    assign dtlb_rsp_tr_id_o        = active_dtlb_tr_id;
    assign dtlb_rsp_pa_o           = rsp_pa_q;
    assign dtlb_rsp_page_fault_o   = rsp_page_fault_q;
    assign dtlb_rsp_access_fault_o = rsp_access_fault_q;

    assign itlb_rsp_valid_o        = rsp_valid_q && active_is_itlb;
    assign itlb_rsp_itrt_id_o      = active_itlb_itrt_id;
    assign itlb_rsp_pa_o           = rsp_pa_q;
    assign itlb_rsp_page_fault_o   = rsp_page_fault_q;
    assign itlb_rsp_access_fault_o = rsp_access_fault_q;
    assign itlb_rsp_level_o        = rsp_level_q;
    assign itlb_rsp_pte_o          = rsp_pte_q;

endmodule

/* verilator lint_on UNUSEDSIGNAL */

`endif // FURSOY_S1_PTW_SV
