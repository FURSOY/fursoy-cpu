// Correctness-first Sv39 translation unit with integrated Physical Memory Protection (PMP).
// There is deliberately no TLB or PTE cache: every translated access performs one
// serialized three-level walk.
/* verilator lint_off UNUSEDSIGNAL */
`include "rtl/core/fursoy_s0_pmp_check.sv"
module fursoy_s0_mmu (
    input  logic clk_i, input logic rst_i, input logic redirect_i,
    input  logic [1:0] priv_mode_i, input logic [63:0] mstatus_i,
    input  logic [63:0] satp_i,

    // PMP inputs
    input  logic [7:0]  pmp_cfg_i [16],
    input  logic [53:0] pmp_addr_i [16],

    // Virtual instruction frontend (fetch).
    input  logic vi_req_valid_i, output logic vi_req_ready_o,
    input  logic [63:0] vi_req_addr_i,
    output logic vi_rsp_valid_o, input logic vi_rsp_ready_i,
    output logic [31:0] vi_rsp_insn_o, output logic vi_rsp_error_o,
    output logic vi_rsp_page_fault_o,

    // Virtual data frontend (LSU).
    input  logic vd_req_valid_i, output logic vd_req_ready_o,
    input  logic vd_req_store_i, input logic [63:0] vd_req_addr_i,
    input  logic [2:0] vd_req_size_i, input logic [63:0] vd_req_store_data_i,
    input  logic vd_req_amo_i,
    input  logic vd_req_sc_i,
    input  logic res_valid_i,
    input  logic [55:0] res_exact_pa_i,
    input  logic [2:0]  res_size_i,
    output logic vd_sc_success_o,
    output logic [63:0] vd_rsp_paddr_o,
    input  logic vd_amo_write_valid_i,
    input  logic [63:0] vd_amo_write_data_i,
    output logic vd_amo_write_ready_o,
    output logic vd_amo_write_error_o,
    output logic vd_req_error_o, output logic vd_req_page_fault_o,
    output logic vd_rsp_valid_o, input logic vd_rsp_ready_i,
    output logic [63:0] vd_rsp_data_o, output logic vd_rsp_error_o,
    output logic vd_rsp_page_fault_o,

    // Physical instruction port.
    output logic pi_req_valid_o, input logic pi_req_ready_i,
    output logic [63:0] pi_req_addr_o,
    input  logic pi_rsp_valid_i, output logic pi_rsp_ready_o,
    input  logic [31:0] pi_rsp_insn_i, input logic pi_rsp_error_i,

    // Shared physical data port.  ptw distinguishes page-table reads from the
    // architectural final access so the platform can reject MMIO PTEs.
    output logic pd_req_valid_o, input logic pd_req_ready_i,
    output logic pd_req_store_o, output logic pd_req_ptw_o,
    output logic [63:0] pd_req_addr_o, output logic [2:0] pd_req_size_o,
    output logic [63:0] pd_req_store_data_o, input logic pd_req_error_i,
    input  logic pd_rsp_valid_i, output logic pd_rsp_ready_o,
    input  logic [63:0] pd_rsp_data_i, input logic pd_rsp_error_i,

    output logic idle_o
);
    typedef enum logic [3:0] {
        IDLE, PTW_REQ, PTW_RSP, FINAL_I_REQ, FINAL_I_RSP,
        FINAL_D_REQ, FINAL_D_RSP, I_FAULT_RSP, D_FAULT_RSP,
        STORE_FAULT_REQ, I_DRAIN_PTW, I_DRAIN_FINAL, I_CANCEL_RSP,
        I_DRAIN_HELD, AMO_WRITE_REQ
    } state_t;
    typedef enum logic [1:0] {OWNER_I, OWNER_LOAD, OWNER_STORE, OWNER_AMO} owner_t;
    state_t state_q;
    owner_t owner_q;
    logic [63:0] va_q, pa_q, pte_addr_q;
    logic [2:0] size_q;
    logic [63:0] store_data_q;
    logic [1:0] effective_priv_q;
    logic [1:0] level_q;
    logic sum_q, mxr_q;
    logic fault_page_q;

    logic [1:0] effective_data_priv;
    logic translate_i, translate_d, canonical_i, canonical_d;
    assign effective_data_priv = (priv_mode_i == 2'b11 && mstatus_i[17]) ?
                                 mstatus_i[12:11] : priv_mode_i;
    assign translate_i = satp_i[63:60] == 4'h8 && priv_mode_i != 2'b11;
    assign translate_d = satp_i[63:60] == 4'h8 && effective_data_priv != 2'b11;
    assign canonical_i = vi_req_addr_i[63:39] == {25{vi_req_addr_i[38]}};
    assign canonical_d = vd_req_addr_i[63:39] == {25{vd_req_addr_i[38]}};
    assign idle_o = state_q == IDLE;

    logic [55:0] current_paddr;
    logic        sc_matches;
    assign current_paddr = translate_d ? pa_q[55:0] : vd_req_addr_i[55:0];
    assign sc_matches = vd_req_sc_i && res_valid_i &&
                        (current_paddr == res_exact_pa_i) &&
                        (vd_req_size_i == res_size_i);
    assign vd_sc_success_o = sc_matches;
    assign vd_rsp_paddr_o  = pa_q;

    function automatic logic [8:0] vpn_for_level(input logic [63:0] va, input logic [1:0] level);
        case (level)
            2'd2: vpn_for_level = va[38:30];
            2'd1: vpn_for_level = va[29:21];
            default: vpn_for_level = va[20:12];
        endcase
    endfunction

    function automatic logic [63:0] table_address(input logic [43:0] ppn,
                                                   input logic [8:0] vpn);
        table_address = {8'd0, ppn, 12'd0} + {52'd0, vpn, 3'd0};
    endfunction

    function automatic logic [63:0] leaf_address(input logic [43:0] ppn,
                                                  input logic [63:0] va,
                                                  input logic [1:0] level);
        case (level)
            2'd2: leaf_address = {8'd0, ppn[43:18], va[29:12], va[11:0]};
            2'd1: leaf_address = {8'd0, ppn[43:9],  va[20:12], va[11:0]};
            default: leaf_address = {8'd0, ppn, va[11:0]};
        endcase
    endfunction

    // PMP checker instances
    logic pmp_allow_ptw;
    fursoy_s0_pmp_check u_pmp_check_ptw (
        .pmp_cfg_i  (pmp_cfg_i),
        .pmp_addr_i (pmp_addr_i),
        .req_addr_i (pte_addr_q[55:0]),
        .req_size_i (3'd3), // 8 bytes for PTE
        .req_op_i   (2'b01), // LOAD
        .req_priv_i (2'b01), // S-mode per contract
        .allow_o    (pmp_allow_ptw)
    );

    logic pmp_allow_final_i;
    fursoy_s0_pmp_check u_pmp_check_final_i (
        .pmp_cfg_i  (pmp_cfg_i),
        .pmp_addr_i (pmp_addr_i),
        .req_addr_i (pa_q[55:0]),
        .req_size_i (3'd2), // 4 bytes
        .req_op_i   (2'b00), // FETCH
        .req_priv_i (effective_priv_q),
        .allow_o    (pmp_allow_final_i)
    );

    logic pmp_allow_final_d;
    fursoy_s0_pmp_check u_pmp_check_final_d (
        .pmp_cfg_i  (pmp_cfg_i),
        .pmp_addr_i (pmp_addr_i),
        .req_addr_i (pa_q[55:0]),
        .req_size_i (size_q),
        .req_op_i   (owner_q == OWNER_AMO ? 2'b11 : (owner_q == OWNER_STORE ? 2'b10 : 2'b01)),
        .req_priv_i (effective_priv_q),
        .allow_o    (pmp_allow_final_d)
    );

    logic pmp_allow_bare_i;
    fursoy_s0_pmp_check u_pmp_check_bare_i (
        .pmp_cfg_i  (pmp_cfg_i),
        .pmp_addr_i (pmp_addr_i),
        .req_addr_i (vi_req_addr_i[55:0]),
        .req_size_i (3'd2), // 4 bytes
        .req_op_i   (2'b00), // FETCH
        .req_priv_i (priv_mode_i),
        .allow_o    (pmp_allow_bare_i)
    );

    logic pmp_allow_bare_d;
    fursoy_s0_pmp_check u_pmp_check_bare_d (
        .pmp_cfg_i  (pmp_cfg_i),
        .pmp_addr_i (pmp_addr_i),
        .req_addr_i (vd_req_addr_i[55:0]),
        .req_size_i (vd_req_size_i),
        .req_op_i   (vd_req_amo_i ? 2'b11 : (vd_req_store_i ? 2'b10 : 2'b01)),
        .req_priv_i (effective_data_priv),
        .allow_o    (pmp_allow_bare_d)
    );

    // Bare/M-mode-bypass traffic remains combinationally equivalent to the
    // pre-MMU path, gated by PMP.  Translated traffic is owned by the state machine below.
    always_comb begin
        vi_req_ready_o = 1'b0;
        vi_rsp_valid_o = 1'b0;
        vi_rsp_insn_o = pi_rsp_insn_i;
        vi_rsp_error_o = 1'b0;
        vi_rsp_page_fault_o = 1'b0;
        vd_req_ready_o = 1'b0;
        vd_req_error_o = 1'b0;
        vd_req_page_fault_o = 1'b0;
        vd_rsp_valid_o = 1'b0;
        vd_rsp_data_o = pd_rsp_data_i;
        vd_rsp_error_o = 1'b0;
        vd_rsp_page_fault_o = 1'b0;
        vd_amo_write_ready_o = 1'b0;
        vd_amo_write_error_o = 1'b0;
        pi_req_valid_o = 1'b0;
        pi_req_addr_o = va_q;
        pi_rsp_ready_o = 1'b0;
        pd_req_valid_o = 1'b0;
        pd_req_store_o = 1'b0;
        pd_req_ptw_o = 1'b0;
        pd_req_addr_o = pa_q;
        pd_req_size_o = size_q;
        pd_req_store_data_o = store_data_q;
        pd_rsp_ready_o = 1'b0;

        if (!rst_i) begin
            unique case (state_q)
                IDLE: begin
                    if (!translate_d) begin
                        if (vd_req_valid_i && !pmp_allow_bare_d) begin
                            // Denied by PMP: suppress external request entirely
                            pd_req_valid_o = 1'b0;
                            if (vd_req_store_i || vd_req_amo_i) begin
                                // Denied Bare store or AMO completes combinationally with error, 0 side effects
                                vd_req_ready_o = 1'b1;
                                vd_req_error_o = 1'b1;
                                vd_req_page_fault_o = 1'b0;
                            end else begin
                                // Denied Bare load accepted into MMU, returns error in D_FAULT_RSP
                                vd_req_ready_o = 1'b1;
                            end
                        end else if (vd_req_valid_i && vd_req_amo_i) begin
                            // Bare AMO accepted for Phase 1 read
                            vd_req_ready_o = 1'b1;
                        end else if (vd_req_valid_i && vd_req_store_i && vd_req_sc_i && !sc_matches) begin
                            // Failed SC in bare mode: suppress physical store, complete combinationally
                            pd_req_valid_o = 1'b0;
                            vd_req_ready_o = 1'b1;
                            vd_req_error_o = 1'b0;
                            vd_req_page_fault_o = 1'b0;
                        end else begin
                            vd_req_ready_o = pd_req_ready_i;
                            vd_req_error_o = pd_req_error_i;
                            pd_req_valid_o = vd_req_valid_i;
                            pd_req_store_o = vd_req_store_i;
                            pd_req_addr_o = vd_req_addr_i;
                            pd_req_size_o = vd_req_size_i;
                            pd_req_store_data_o = vd_req_store_data_i;
                            vd_rsp_valid_o = pd_rsp_valid_i;
                            vd_rsp_error_o = pd_rsp_error_i;
                            pd_rsp_ready_o = vd_rsp_ready_i;
                        end
                    end else if (vd_req_valid_i && (!vd_req_store_i || vd_req_amo_i)) begin
                        // Loads and AMOs are accepted into the one-outstanding translator;
                        // their success or error returns on the response path.
                        vd_req_ready_o = 1'b1;
                    end

                    if (!vd_req_valid_i) begin
                        if (!translate_i) begin
                            if (vi_req_valid_i && !pmp_allow_bare_i) begin
                                // Denied Bare fetch: suppress external request, return error in I_FAULT_RSP
                                pi_req_valid_o = 1'b0;
                                vi_req_ready_o = 1'b1;
                            end else begin
                                pi_req_valid_o = vi_req_valid_i;
                                pi_req_addr_o = vi_req_addr_i;
                                vi_req_ready_o = pi_req_ready_i;
                            end
                        end else begin
                            vi_req_ready_o = 1'b1;
                        end
                    end
                end
                PTW_REQ: begin
                    pd_req_valid_o = pmp_allow_ptw;
                    pd_req_store_o = 1'b0;
                    pd_req_ptw_o = 1'b1;
                    pd_req_addr_o = pte_addr_q;
                    pd_req_size_o = 3'd3;
                end
                PTW_RSP: pd_rsp_ready_o = 1'b1;
                FINAL_I_REQ: begin
                    pi_req_valid_o = pmp_allow_final_i;
                    pi_req_addr_o = pa_q;
                end
                FINAL_I_RSP: begin
                    pi_rsp_ready_o = vi_rsp_ready_i;
                    vi_rsp_valid_o = pi_rsp_valid_i;
                    vi_rsp_insn_o = pi_rsp_insn_i;
                    vi_rsp_error_o = pi_rsp_error_i;
                end
                FINAL_D_REQ: begin
                    if (owner_q == OWNER_AMO) begin
                        pd_req_valid_o = pmp_allow_final_d;
                        pd_req_store_o = 1'b0; // Phase 1 READ
                        pd_req_addr_o = pa_q;
                        pd_req_size_o = size_q;
                    end else if (owner_q == OWNER_STORE) begin
                        if (vd_req_sc_i && !sc_matches) begin
                            // Failed SC in translated mode: suppress physical store
                            pd_req_valid_o = 1'b0;
                            vd_req_ready_o = 1'b1;
                            vd_req_error_o = 1'b0;
                        end else begin
                            pd_req_valid_o = pmp_allow_final_d;
                            pd_req_store_o = 1'b1;
                            pd_req_addr_o = pa_q;
                            pd_req_size_o = size_q;
                            pd_req_store_data_o = store_data_q;
                            if (!pmp_allow_final_d) begin
                                vd_req_ready_o = 1'b0; // Will handshake in STORE_FAULT_REQ
                                vd_req_error_o = 1'b0;
                            end else begin
                                vd_req_ready_o = pd_req_ready_i;
                                vd_req_error_o = pd_req_error_i;
                            end
                        end
                    end else begin
                        // OWNER_LOAD
                        pd_req_valid_o = pmp_allow_final_d;
                        pd_req_store_o = 1'b0;
                        pd_req_addr_o = pa_q;
                        pd_req_size_o = size_q;
                    end
                end
                FINAL_D_RSP: begin
                    pd_rsp_ready_o = vd_rsp_ready_i;
                    vd_rsp_valid_o = pd_rsp_valid_i;
                    vd_rsp_data_o = pd_rsp_data_i;
                    vd_rsp_error_o = pd_rsp_error_i;
                end
                AMO_WRITE_REQ: begin
                    pd_req_valid_o = !rst_i && vd_amo_write_valid_i;
                    pd_req_store_o = 1'b1; // Phase 2 STORE
                    pd_req_addr_o = pa_q;
                    pd_req_size_o = size_q;
                    pd_req_store_data_o = vd_amo_write_data_i;
                    vd_amo_write_ready_o = pd_req_ready_i;
                    vd_amo_write_error_o = pd_req_error_i;
                end
                I_FAULT_RSP: begin
                    vi_rsp_valid_o = 1'b1;
                    vi_rsp_error_o = 1'b1;
                    vi_rsp_page_fault_o = fault_page_q;
                end
                D_FAULT_RSP: begin
                    vd_rsp_valid_o = 1'b1;
                    vd_rsp_error_o = 1'b1;
                    vd_rsp_page_fault_o = fault_page_q;
                end
                STORE_FAULT_REQ: begin
                    vd_req_ready_o = 1'b1;
                    vd_req_error_o = 1'b1;
                    vd_req_page_fault_o = fault_page_q;
                end
                I_DRAIN_PTW: pd_rsp_ready_o = 1'b1;
                I_DRAIN_FINAL: begin
                    pi_rsp_ready_o = 1'b1;
                    vi_rsp_valid_o = pi_rsp_valid_i;
                end
                I_DRAIN_HELD: begin
                    pi_rsp_ready_o = 1'b1;
                    vi_rsp_valid_o = pi_rsp_valid_i;
                end
                I_CANCEL_RSP: vi_rsp_valid_o = 1'b1;
                default: ;
            endcase
        end
    end

    logic pte_v, pte_r, pte_w, pte_x, pte_u, pte_a, pte_d, pte_leaf;
    logic pte_reserved, pte_bad_nonleaf, pte_bad_superpage, permission_ok;
    logic [43:0] pte_ppn;
    assign pte_v = pd_rsp_data_i[0];
    assign pte_r = pd_rsp_data_i[1];
    assign pte_w = pd_rsp_data_i[2];
    assign pte_x = pd_rsp_data_i[3];
    assign pte_u = pd_rsp_data_i[4];
    assign pte_a = pd_rsp_data_i[6];
    assign pte_d = pd_rsp_data_i[7];
    assign pte_leaf = pte_r || pte_x;
    assign pte_ppn = pd_rsp_data_i[53:10];
    assign pte_reserved = |pd_rsp_data_i[63:54];
    assign pte_bad_nonleaf = !pte_leaf && (pte_u || pte_a || pte_d);
    assign pte_bad_superpage = (level_q == 2'd2 && |pte_ppn[17:0]) ||
                               (level_q == 2'd1 && |pte_ppn[8:0]);
    always_comb begin
        permission_ok = 1'b0;
        if (owner_q == OWNER_I) permission_ok = pte_x;
        else if (owner_q == OWNER_STORE) permission_ok = pte_w;
        else if (owner_q == OWNER_AMO) permission_ok = pte_r && pte_w; // Both R and W required! MXR strictly excluded!
        else permission_ok = pte_r || (mxr_q && pte_x);
        if (effective_priv_q == 2'b00) permission_ok &= pte_u;
        else if (pte_u) permission_ok &= (owner_q != OWNER_I) && sum_q;
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q <= IDLE;
            owner_q <= OWNER_I;
            va_q <= '0; pa_q <= '0; pte_addr_q <= '0;
            size_q <= '0; store_data_q <= '0; effective_priv_q <= 2'b11;
            level_q <= 2'd0; sum_q <= 1'b0; mxr_q <= 1'b0;
            fault_page_q <= 1'b0;
        end else begin
            unique case (state_q)
                IDLE: begin
                    if (vd_req_valid_i && !translate_d) begin
                        if (vd_req_amo_i) begin
                            if (!pmp_allow_bare_d) begin
                                // Denied Bare AMO completes combinationally with error, 0 side effects
                                // State remains IDLE
                            end else begin
                                owner_q <= OWNER_AMO;
                                va_q <= vd_req_addr_i;
                                pa_q <= {8'd0, vd_req_addr_i[55:0]};
                                size_q <= vd_req_size_i;
                                store_data_q <= vd_req_store_data_i;
                                effective_priv_q <= effective_data_priv;
                                state_q <= FINAL_D_REQ;
                            end
                        end else if (!vd_req_store_i && !pmp_allow_bare_d) begin
                            // Bare load denied by PMP -> transition to D_FAULT_RSP
                            owner_q <= OWNER_LOAD;
                            va_q <= vd_req_addr_i;
                            fault_page_q <= 1'b0;
                            state_q <= D_FAULT_RSP;
                        end else if (vd_req_ready_o) begin
                            pa_q <= {8'd0, vd_req_addr_i[55:0]};
                        end
                    end else if (vd_req_valid_i && translate_d) begin
                        owner_q <= vd_req_amo_i ? OWNER_AMO : (vd_req_store_i ? OWNER_STORE : OWNER_LOAD);
                        va_q <= vd_req_addr_i;
                        size_q <= vd_req_size_i;
                        store_data_q <= vd_req_store_data_i;
                        effective_priv_q <= effective_data_priv;
                        sum_q <= mstatus_i[18];
                        mxr_q <= mstatus_i[19];
                        level_q <= 2'd2;
                        pte_addr_q <= table_address(satp_i[43:0], vd_req_addr_i[38:30]);
                        if (!canonical_d) begin
                            fault_page_q <= 1'b1;
                            state_q <= (vd_req_store_i && !vd_req_amo_i) ? STORE_FAULT_REQ : D_FAULT_RSP;
                        end else state_q <= PTW_REQ;
                    end else if (!vd_req_valid_i && vi_req_valid_i) begin
                        va_q <= vi_req_addr_i;
                        owner_q <= OWNER_I;
                        effective_priv_q <= priv_mode_i;
                        sum_q <= mstatus_i[18];
                        mxr_q <= mstatus_i[19];
                        if (translate_i) begin
                            level_q <= 2'd2;
                            pte_addr_q <= table_address(satp_i[43:0], vi_req_addr_i[38:30]);
                            if (redirect_i) state_q <= I_CANCEL_RSP;
                            else if (!canonical_i) begin
                                fault_page_q <= 1'b1;
                                state_q <= I_FAULT_RSP;
                            end else state_q <= PTW_REQ;
                        end else if (!pmp_allow_bare_i) begin
                            // Bare fetch denied by PMP
                            fault_page_q <= 1'b0;
                            state_q <= redirect_i ? I_CANCEL_RSP : I_FAULT_RSP;
                        end else if (pi_req_ready_i) begin
                            state_q <= redirect_i ? I_DRAIN_FINAL : FINAL_I_RSP;
                        end
                    end
                end
                PTW_REQ: begin
                    if (!pmp_allow_ptw) begin
                        // Local PMP denial of PTW PTE read: bypass bus wait, transition directly to fault
                        fault_page_q <= 1'b0;
                        if (owner_q == OWNER_I) begin
                            state_q <= redirect_i ? I_CANCEL_RSP : I_FAULT_RSP;
                        end else if (owner_q == OWNER_STORE) begin
                            state_q <= STORE_FAULT_REQ;
                        end else begin
                            state_q <= D_FAULT_RSP;
                        end
                    end else if (owner_q == OWNER_I && redirect_i) begin
                        state_q <= pd_req_ready_i ? I_DRAIN_PTW : I_CANCEL_RSP;
                    end else if (pd_req_valid_o && pd_req_ready_i) begin
                        // PTW loads follow the load contract: even a request-time
                        // error completes through a held response.
                        state_q <= PTW_RSP;
                    end
                end
                PTW_RSP: begin
                    if (owner_q == OWNER_I && redirect_i) begin
                        state_q <= pd_rsp_valid_i ? I_CANCEL_RSP : I_DRAIN_PTW;
                    end else if (pd_rsp_valid_i) begin
                        if (pd_rsp_error_i) begin
                            fault_page_q <= 1'b0;
                            state_q <= owner_q == OWNER_I ? I_FAULT_RSP :
                                       (owner_q == OWNER_STORE ? STORE_FAULT_REQ : D_FAULT_RSP);
                        end else if (!pte_v || (!pte_r && pte_w) || pte_reserved || pte_bad_nonleaf) begin
                            fault_page_q <= 1'b1;
                            state_q <= owner_q == OWNER_I ? I_FAULT_RSP :
                                       (owner_q == OWNER_STORE ? STORE_FAULT_REQ : D_FAULT_RSP);
                        end else if (pte_leaf) begin
                            if (pte_bad_superpage || !permission_ok || !pte_a ||
                                ((owner_q == OWNER_STORE || owner_q == OWNER_AMO) && !pte_d)) begin
                                fault_page_q <= 1'b1;
                                state_q <= owner_q == OWNER_I ? I_FAULT_RSP :
                                           (owner_q == OWNER_STORE ? STORE_FAULT_REQ : D_FAULT_RSP);
                            end else begin
                                pa_q <= leaf_address(pte_ppn, va_q, level_q);
                                state_q <= owner_q == OWNER_I ? FINAL_I_REQ : FINAL_D_REQ;
                            end
                        end else if (level_q == 2'd0) begin
                            fault_page_q <= 1'b1;
                            state_q <= owner_q == OWNER_I ? I_FAULT_RSP :
                                       (owner_q == OWNER_STORE ? STORE_FAULT_REQ : D_FAULT_RSP);
                        end else begin
                            level_q <= level_q - 2'd1;
                            pte_addr_q <= table_address(pte_ppn,
                                vpn_for_level(va_q, level_q - 2'd1));
                            state_q <= PTW_REQ;
                        end
                    end
                end
                FINAL_I_REQ: begin
                    if (!pmp_allow_final_i) begin
                        fault_page_q <= 1'b0;
                        state_q <= redirect_i ? I_CANCEL_RSP : I_FAULT_RSP;
                    end else if (redirect_i) state_q <= pi_req_ready_i ? I_DRAIN_FINAL : I_CANCEL_RSP;
                    else if (pi_req_ready_i) state_q <= FINAL_I_RSP;
                end
                FINAL_I_RSP: begin
                    if (redirect_i) begin
                        if (pi_rsp_valid_i && vi_rsp_ready_i) state_q <= IDLE;
                        else if (pi_rsp_valid_i) state_q <= I_DRAIN_HELD;
                        else state_q <= I_DRAIN_FINAL;
                    end else if (pi_rsp_valid_i && vi_rsp_ready_i) state_q <= IDLE;
                end
                FINAL_D_REQ: begin
                    if (owner_q == OWNER_AMO) begin
                        if (!pmp_allow_final_d) begin
                            fault_page_q <= 1'b0;
                            state_q <= D_FAULT_RSP;
                        end else if (pd_req_ready_i) begin
                            state_q <= FINAL_D_RSP;
                        end
                    end else if (owner_q == OWNER_STORE) begin
                        if (vd_req_sc_i && !sc_matches) begin
                            state_q <= IDLE;
                        end else if (!pmp_allow_final_d) begin
                            fault_page_q <= 1'b0;
                            state_q <= STORE_FAULT_REQ;
                        end else if (pd_req_ready_i) begin
                            state_q <= IDLE;
                        end
                    end else begin
                        // OWNER_LOAD
                        if (!pmp_allow_final_d) begin
                            fault_page_q <= 1'b0;
                            state_q <= D_FAULT_RSP;
                        end else if (pd_req_ready_i) begin
                            state_q <= FINAL_D_RSP;
                        end
                    end
                end
                FINAL_D_RSP: begin
                    if (pd_rsp_valid_i && vd_rsp_ready_i) begin
                        if (owner_q == OWNER_AMO && !pd_rsp_error_i) begin
                            state_q <= AMO_WRITE_REQ;
                        end else begin
                            state_q <= IDLE;
                        end
                    end
                end
                AMO_WRITE_REQ: begin
                    if (vd_amo_write_valid_i && pd_req_ready_i) begin
                        state_q <= IDLE;
                    end
                end
                I_FAULT_RSP: state_q <= IDLE;
                D_FAULT_RSP: state_q <= IDLE;
                STORE_FAULT_REQ: state_q <= IDLE;
                I_DRAIN_PTW: begin
                    if (pd_rsp_valid_i) state_q <= I_CANCEL_RSP;
                end
                I_DRAIN_FINAL: begin
                    if (pi_rsp_valid_i) state_q <= IDLE;
                end
                I_DRAIN_HELD: begin
                    if (pi_rsp_valid_i && pi_rsp_ready_o) state_q <= IDLE;
                end
                I_CANCEL_RSP: state_q <= IDLE;
                default: ;
            endcase
        end
    end

    // Safety and protocol invariants
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            assert (!(rst_i && (pi_req_valid_o || pd_req_valid_o)))
                else $fatal(1, "physical request valid asserted while reset is asserted");
            assert (!(vd_req_ready_o && vd_req_store_i && !vd_req_amo_i && translate_d &&
                      state_q != FINAL_D_REQ && state_q != STORE_FAULT_REQ))
                else $fatal(1, "translated store accepted before final access/fault");
            assert (!(pd_req_valid_o && pd_req_store_o &&
                      state_q != FINAL_D_REQ && state_q != AMO_WRITE_REQ && !(state_q == IDLE && !translate_d)))
                else $fatal(1, "physical store outside final translated access");
            if (state_q == FINAL_D_REQ || state_q == FINAL_I_REQ || state_q == AMO_WRITE_REQ)
                assert (pa_q[63:56] == 8'd0) else $fatal(1, "Sv39 PA truncated");

            // PMP safety assertions
            assert (!(pd_req_valid_o && pd_req_store_o &&
                      ((state_q == FINAL_D_REQ && !pmp_allow_final_d) ||
                       (state_q == AMO_WRITE_REQ && !pmp_allow_final_d) ||
                       (state_q == IDLE && !translate_d && !pmp_allow_bare_d))))
                else $fatal(1, "Physical store issued without PMP permission");

            assert (!(pd_req_valid_o && pd_req_ptw_o && !pmp_allow_ptw))
                else $fatal(1, "PTW PTE read issued without PMP permission");

            assert (!(pi_req_valid_o &&
                      ((state_q == FINAL_I_REQ && !pmp_allow_final_i) ||
                       (state_q == IDLE && !translate_i && !pmp_allow_bare_i))))
                else $fatal(1, "Physical instruction fetch issued without PMP permission");

            assert (!(state_q == PTW_REQ && !pmp_allow_ptw && pd_req_valid_o))
                else $fatal(1, "PTW request asserted when denied by PMP");

            // RV64A safety assertions
            assert (!(vd_req_sc_i && !sc_matches && pd_req_valid_o && pd_req_store_o))
                else $fatal(1, "Physical store emitted for failed SC");

            assert (!(state_q == FINAL_D_REQ && owner_q == OWNER_AMO && pd_req_store_o))
                else $fatal(1, "AMO read phase issued with store asserted");
        end
    end

    logic pi_inflight_q;
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            pi_inflight_q <= 1'b0;
        end else begin
            if (pi_req_valid_o && pi_req_ready_i)
                pi_inflight_q <= 1'b1;
            else if (pi_rsp_valid_i && pi_rsp_ready_o)
                pi_inflight_q <= 1'b0;

            if (state_q == IDLE) begin
                assert (!pi_inflight_q)
                    else $fatal(1, "MMU entered IDLE with unconsumed physical instruction response");
            end
        end
    end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
