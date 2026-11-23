`ifndef FURSOY_S2_PLIC_SV
`define FURSOY_S2_PLIC_SV

// =============================================================================
// Fursoy Slice-2 Multi-Context Platform-Level Interrupt Controller (PLIC)
// =============================================================================
// Specification authority: docs/architecture/slice2-smp-v1.md §4.2, §5
// - Parameterized NUM_HARTS (default 2, tested 2 & 4); NUM_CONTEXTS = 2 * NUM_HARTS
//   (Context 2*h = Hart h M-mode MEIP; Context 2*h + 1 = Hart h S-mode SEIP).
// - 31 physical external level-sensitive interrupt sources (IDs 1..31; ID 0 RO0).
// - Global per-source gateway (pending_q, in_service_q) supporting preemption and
//   atomic single-hart claim via serialized MMIO bus.
// - Balanced 5-level binary priority reduction tree (32 -> 16 -> 8 -> 4 -> 2 -> 1)
//   feeding continuously registered claim_selected_id_q[c].
// - Registered MMIO request stage (P0 -> P1) and unified registered rsp_valid_q /
//   rsp_error_q across both loads and stores (claim_c_fire consumes the exact
//   registered claim_selected_id_q[c] returned in rsp_data_q).
// =============================================================================

module fursoy_s2_plic #(
    parameter logic [63:0] BASE_ADDR = 64'h0000_0000_0C00_0000,
    parameter int unsigned NUM_HARTS = 2
) (
    input  logic                 clk_i,
    input  logic                 rst_i,

    // Platform MMIO slave interface
    input  logic                 req_valid_i,
    output logic                 req_ready_o,
    input  logic                 req_store_i,
    input  logic [63:0]          req_addr_i,
    input  logic [2:0]           req_size_i,
    input  logic [63:0]          req_store_data_i,
    output logic                 rsp_valid_o,
    input  logic                 rsp_ready_i,
    output logic [63:0]          rsp_data_o,
    output logic                 rsp_error_o,
    output logic                 access_error_o,

    // External interrupt line inputs (level-sensitive, active-high; bit 0 unused)
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0]          irq_sources_i,
    /* verilator lint_on UNUSEDSIGNAL */

    // Per-hart M-mode / S-mode external interrupt notifications
    output logic [NUM_HARTS-1:0] irq_meip_o,
    output logic [NUM_HARTS-1:0] irq_seip_o
);

    localparam int unsigned NUM_CONTEXTS = 2 * NUM_HARTS;
    localparam int unsigned CTX_W        = (NUM_CONTEXTS > 1) ? $clog2(NUM_CONTEXTS) : 1;

    // =========================================================================
    // 1. Storage Registers
    // =========================================================================
    logic [2:0]  priority_q [31:1];
    logic [2:0]  threshold_q [NUM_CONTEXTS-1:0];
    logic [31:1] enable_q [NUM_CONTEXTS-1:0];
    logic [31:1] pending_q;
    logic [31:1] in_service_q;

    // Registered Claim Selection per Context (updated every cycle from 5-level tree)
    logic [4:0]  claim_selected_id_q [NUM_CONTEXTS-1:0];

    // Registered P0 -> P1 MMIO Stage
    logic             p1_valid_q;
    logic             p1_store_q;
    logic             p1_valid_access_q;
    logic [31:0]      p1_wdata_q;
    logic             p1_is_prio_s1_31_q;
    logic [4:0]       p1_prio_src_idx_q;
    logic             p1_is_pending_w0_q;
    logic             p1_is_enable_w0_q;
    logic             p1_is_threshold_q;
    logic             p1_is_claim_q;
    logic             p1_is_raz_wi_q;
    logic [CTX_W-1:0] p1_ctx_idx_q;

    // Unified Bus Response Registers
    logic        rsp_valid_q;
    logic        rsp_error_q;
    logic [31:0] rsp_data_q;

    // =========================================================================
    // 2. Eligibility & 5-Level Balanced Binary Priority Reduction Tree
    // =========================================================================
    logic [31:1] claim_eligible  [NUM_CONTEXTS-1:0];
    logic [31:1] notify_eligible [NUM_CONTEXTS-1:0];
    logic [4:0]  tree_winner_id  [NUM_CONTEXTS-1:0];

    typedef struct packed {
        logic [2:0] prio;
        logic [4:0] id;
    } plic_cand_t;

    function automatic plic_cand_t pick_better(
        input plic_cand_t left_c,
        input plic_cand_t right_c
    );
        // Left branch holds strictly lower numerical IDs (except slot 0 whose prio is 0).
        // Valid candidates always have prio >= 1, so right_c wins only on strictly higher prio.
        if (right_c.prio > left_c.prio) return right_c;
        else                            return left_c;
    endfunction

    for (genvar c = 0; c < NUM_CONTEXTS; c++) begin : gen_ctx_tree
        for (genvar i = 1; i <= 31; i++) begin : gen_src
            assign claim_eligible[c][i]  = pending_q[i] && enable_q[c][i] && (priority_q[i] > 3'd0);
            assign notify_eligible[c][i] = claim_eligible[c][i] && (priority_q[i] > threshold_q[c]);
        end

        // 5-level balanced tree: 32 -> 16 -> 8 -> 4 -> 2 -> 1
        plic_cand_t lvl0 [32];
        plic_cand_t lvl1 [16];
        plic_cand_t lvl2 [8];
        plic_cand_t lvl3 [4];
        plic_cand_t lvl4 [2];
        /* verilator lint_off UNUSEDSIGNAL */
        plic_cand_t lvl5;
        /* verilator lint_on UNUSEDSIGNAL */

        assign lvl0[0] = '{prio: 3'd0, id: 5'd0};
        for (genvar i = 1; i <= 31; i++) begin : gen_l0
            assign lvl0[i] = claim_eligible[c][i] ? '{prio: priority_q[i], id: 5'(i)} : '{prio: 3'd0, id: 5'd0};
        end
        for (genvar k = 0; k < 16; k++) begin : gen_l1
            assign lvl1[k] = pick_better(lvl0[2*k], lvl0[2*k + 1]);
        end
        for (genvar k = 0; k < 8; k++) begin : gen_l2
            assign lvl2[k] = pick_better(lvl1[2*k], lvl1[2*k + 1]);
        end
        for (genvar k = 0; k < 4; k++) begin : gen_l3
            assign lvl3[k] = pick_better(lvl2[2*k], lvl2[2*k + 1]);
        end
        for (genvar k = 0; k < 2; k++) begin : gen_l4
            assign lvl4[k] = pick_better(lvl3[2*k], lvl3[2*k + 1]);
        end
        assign lvl5 = pick_better(lvl4[0], lvl4[1]);
        assign tree_winner_id[c] = lvl5.id;
    end

    for (genvar h = 0; h < NUM_HARTS; h++) begin : gen_hart_irqs
        assign irq_meip_o[h] = |notify_eligible[2*h];
        assign irq_seip_o[h] = |notify_eligible[2*h + 1];
    end

    // =========================================================================
    // 3. MMIO Address Decode (Stage P0)
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    logic [23:0] offset;
    /* verilator lint_on UNUSEDSIGNAL */
    assign offset = req_addr_i[23:0];

    wire in_plic_range     = (req_addr_i >= BASE_ADDR) && (req_addr_i < (BASE_ADDR + 64'h0040_0000));
    wire is_word_access    = (req_size_i == 3'd2);
    wire is_aligned_access = (req_addr_i[1:0] == 2'b00);
    wire size_align_ok     = is_word_access && is_aligned_access;

    logic             dec_is_prio_s1_31;
    logic [4:0]       dec_prio_src_idx;
    logic             dec_is_pending_w0;
    logic             dec_is_enable_w0;
    logic             dec_is_threshold;
    logic             dec_is_claim;
    logic             dec_is_raz_wi;
    logic [CTX_W-1:0] dec_ctx_idx;
    logic             dec_valid_addr;

    always_comb begin
        dec_is_prio_s1_31 = 1'b0;
        dec_prio_src_idx  = offset[6:2];
        dec_is_pending_w0 = 1'b0;
        dec_is_enable_w0  = 1'b0;
        dec_is_threshold  = 1'b0;
        dec_is_claim      = 1'b0;
        dec_is_raz_wi     = 1'b0;
        dec_ctx_idx       = '0;
        dec_valid_addr    = 1'b0;

        if (in_plic_range) begin
            if (offset == 24'h000000) begin
                dec_is_raz_wi  = 1'b1;
                dec_valid_addr = 1'b1;
            end else if (offset >= 24'h000004 && offset <= 24'h00007C) begin
                dec_is_prio_s1_31 = 1'b1;
                dec_valid_addr    = 1'b1;
            end else if (offset >= 24'h000080 && offset <= 24'h000FFC) begin
                dec_is_raz_wi  = 1'b1;
                dec_valid_addr = 1'b1;
            end else if (offset == 24'h001000) begin
                dec_is_pending_w0 = 1'b1;
                dec_valid_addr    = 1'b1;
            end else if (offset >= 24'h001004 && offset <= 24'h00107C) begin
                dec_is_raz_wi  = 1'b1;
                dec_valid_addr = 1'b1;
            end else begin
                // Context enable blocks: 0x002000 + c * 0x80 (each 0x80 block covers 1024 sources)
                for (int c = 0; c < NUM_CONTEXTS; c++) begin
                    if (offset == (24'h002000 + 24'(c) * 24'h000080)) begin
                        dec_is_enable_w0 = 1'b1;
                        dec_ctx_idx      = CTX_W'(c);
                        dec_valid_addr   = 1'b1;
                    end else if ((offset > (24'h002000 + 24'(c) * 24'h000080)) &&
                                 (offset < (24'h002080 + 24'(c) * 24'h000080))) begin
                        dec_is_raz_wi  = 1'b1;
                        dec_ctx_idx    = CTX_W'(c);
                        dec_valid_addr = 1'b1;
                    end
                end

                // Context threshold / claim blocks: 0x200000 + c * 0x1000
                for (int c = 0; c < NUM_CONTEXTS; c++) begin
                    if (offset == (24'h200000 + 24'(c) * 24'h001000)) begin
                        dec_is_threshold = 1'b1;
                        dec_ctx_idx      = CTX_W'(c);
                        dec_valid_addr   = 1'b1;
                    end else if (offset == (24'h200004 + 24'(c) * 24'h001000)) begin
                        dec_is_claim   = 1'b1;
                        dec_ctx_idx    = CTX_W'(c);
                        dec_valid_addr = 1'b1;
                    end
                end
            end
        end
    end

    wire dec_valid_access = in_plic_range && dec_valid_addr && size_align_ok;
    wire [31:0] wdata_32  = req_addr_i[2] ? req_store_data_i[63:32] : req_store_data_i[31:0];

    wire req_fire;
    assign req_ready_o    = !p1_valid_q && !rsp_valid_q;
    assign req_fire       = req_valid_i && req_ready_o;
    assign access_error_o = req_fire && !dec_valid_access;

    assign rsp_valid_o    = rsp_valid_q;
    assign rsp_error_o    = rsp_error_q;
    assign rsp_data_o     = {rsp_data_q, rsp_data_q};

    // =========================================================================
    // 4. Stage P1 Execution: Read Mux & Claim/Complete Side Effects
    // =========================================================================
    logic [31:0] p1_read_data;
    always_comb begin
        p1_read_data = 32'd0;
        if (p1_is_raz_wi_q) begin
            p1_read_data = 32'd0;
        end else if (p1_is_prio_s1_31_q) begin
            p1_read_data = {29'd0, priority_q[p1_prio_src_idx_q]};
        end else if (p1_is_pending_w0_q) begin
            p1_read_data = {pending_q[31:1], 1'b0};
        end else if (p1_is_enable_w0_q) begin
            p1_read_data = {enable_q[p1_ctx_idx_q][31:1], 1'b0};
        end else if (p1_is_threshold_q) begin
            p1_read_data = {29'd0, threshold_q[p1_ctx_idx_q]};
        end else if (p1_is_claim_q) begin
            p1_read_data = {27'd0, claim_selected_id_q[p1_ctx_idx_q]};
        end
    end

    // Claim side effect uses the exact registered claim_selected_id_q[c] returned in rsp_data_q
    wire [4:0] p1_claimed_id     = claim_selected_id_q[p1_ctx_idx_q];
    wire       p1_claim_fire     = p1_valid_q && !p1_store_q && p1_valid_access_q && p1_is_claim_q &&
                                   (p1_claimed_id != 5'd0);

    wire       p1_complete_range = (p1_wdata_q >= 32'd1) && (p1_wdata_q <= 32'd31);
    wire [4:0] p1_complete_id    = p1_wdata_q[4:0];
    wire       p1_complete_fire  = p1_valid_q && p1_store_q && p1_valid_access_q && p1_is_claim_q &&
                                   p1_complete_range && enable_q[p1_ctx_idx_q][p1_complete_id] &&
                                   in_service_q[p1_complete_id];

    // =========================================================================
    // 5. Sequential State & Gateway Updates
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            for (int i = 1; i <= 31; i++) begin
                priority_q[i]   <= 3'd0;
                pending_q[i]    <= 1'b0;
                in_service_q[i] <= 1'b0;
            end
            for (int c = 0; c < NUM_CONTEXTS; c++) begin
                enable_q[c]            <= 31'd0;
                threshold_q[c]         <= 3'd0;
                claim_selected_id_q[c] <= 5'd0;
            end
            p1_valid_q        <= 1'b0;
            p1_store_q        <= 1'b0;
            p1_valid_access_q <= 1'b0;
            p1_wdata_q        <= 32'd0;
            p1_is_prio_s1_31_q<= 1'b0;
            p1_prio_src_idx_q <= 5'd0;
            p1_is_pending_w0_q<= 1'b0;
            p1_is_enable_w0_q <= 1'b0;
            p1_is_threshold_q <= 1'b0;
            p1_is_claim_q     <= 1'b0;
            p1_is_raz_wi_q    <= 1'b0;
            p1_ctx_idx_q      <= '0;
            rsp_valid_q       <= 1'b0;
            rsp_error_q       <= 1'b0;
            rsp_data_q        <= 32'd0;
        end else begin
            // Clear response handshake
            if (rsp_valid_q && rsp_ready_i) begin
                rsp_valid_q <= 1'b0;
                rsp_error_q <= 1'b0;
            end

            // Stage P0 latch
            if (req_fire) begin
                p1_valid_q         <= 1'b1;
                p1_store_q         <= req_store_i;
                p1_valid_access_q  <= dec_valid_access;
                p1_wdata_q         <= wdata_32;
                p1_is_prio_s1_31_q <= dec_is_prio_s1_31;
                p1_prio_src_idx_q  <= dec_prio_src_idx;
                p1_is_pending_w0_q <= dec_is_pending_w0;
                p1_is_enable_w0_q  <= dec_is_enable_w0;
                p1_is_threshold_q  <= dec_is_threshold;
                p1_is_claim_q      <= dec_is_claim;
                p1_is_raz_wi_q     <= dec_is_raz_wi;
                p1_ctx_idx_q       <= dec_ctx_idx;
            end else begin
                p1_valid_q         <= 1'b0;
            end

            // Stage P1 execute -> unified registered response for both loads and stores
            if (p1_valid_q) begin
                rsp_valid_q <= 1'b1;
                rsp_error_q <= !p1_valid_access_q;
                if (!p1_store_q) begin
                    rsp_data_q <= p1_valid_access_q ? p1_read_data : 32'd0;
                end else begin
                    rsp_data_q <= 32'd0;
                    if (p1_valid_access_q) begin
                        if (p1_is_prio_s1_31_q) begin
                            priority_q[p1_prio_src_idx_q] <= p1_wdata_q[2:0];
                        end else if (p1_is_enable_w0_q) begin
                            enable_q[p1_ctx_idx_q] <= p1_wdata_q[31:1];
                        end else if (p1_is_threshold_q) begin
                            threshold_q[p1_ctx_idx_q] <= p1_wdata_q[2:0];
                        end
                    end
                end
            end

            // Source gateway updates (IDs 1..31)
            for (int i = 1; i <= 31; i++) begin
                if (p1_claim_fire && (p1_claimed_id == 5'(i))) begin
                    pending_q[i]    <= 1'b0;
                    in_service_q[i] <= 1'b1;
                end else if (p1_complete_fire && (p1_complete_id == 5'(i))) begin
                    in_service_q[i] <= 1'b0;
                    pending_q[i]    <= irq_sources_i[i];
                end else if (!in_service_q[i]) begin
                    if (irq_sources_i[i]) begin
                        pending_q[i] <= 1'b1;
                    end
                end else begin
                    pending_q[i] <= 1'b0;
                end
            end

            // Registered 5-level tree winners (clear immediately if that source was just claimed)
            for (int c = 0; c < NUM_CONTEXTS; c++) begin
                if (p1_claim_fire && (tree_winner_id[c] == p1_claimed_id)) begin
                    claim_selected_id_q[c] <= 5'd0;
                end else begin
                    claim_selected_id_q[c] <= tree_winner_id[c];
                end
            end
        end
    end

    // =========================================================================
    // 6. Architectural Assertions
    // =========================================================================
    // pragma translate_off
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            for (int i = 1; i <= 31; i++) begin
                assert (!(pending_q[i] && in_service_q[i]))
                    else $fatal(1, "PLIC Gateway Invariant: source %0d both pending and in_service", i);
            end
            if (p1_claim_fire) begin
                assert (claim_eligible[p1_ctx_idx_q][p1_claimed_id])
                    else $fatal(1, "PLIC ctx %0d claimed ineligible source %0d", p1_ctx_idx_q, p1_claimed_id);
            end
        end
    end
    // pragma translate_on

endmodule

`endif // FURSOY_S2_PLIC_SV
