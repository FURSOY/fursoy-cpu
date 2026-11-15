`ifndef FURSOY_S0_PLIC_SV
`define FURSOY_S0_PLIC_SV

// Platform-Level Interrupt Controller (PLIC) v1 for Fursoy CPU (Slice-0 single-core)
// Specification authority: docs/architecture/plic-v1.md (frozen v1)
// - 31 physical external level-sensitive interrupt sources (IDs 1..31; ID 0 reserved RO0)
// - 2 contexts: Context 0 (Hart 0 M-mode, MEIP), Context 1 (Hart 0 S-mode, SEIP)
// - 3-bit priority and threshold (priorities 0..7; 0 disabled; strictly priority > threshold)
// - Decoupled Claim eligibility (threshold-independent) and Notification eligibility
// - Gateway lifecycle: IDLE -> PENDING -> IN_SERVICE (max 1 outstanding claim globally)
// - Validated completion: enable[c][k] && in_service[k]
// - Standard 4 MiB MMIO map at BASE_ADDR (0x0C00_0000) with strict 32-bit aligned access

module fursoy_s0_plic #(
    parameter logic [63:0] BASE_ADDR = 64'h0000_0000_0C00_0000
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // Platform bus slave interface
    input  logic        req_valid_i,
    output logic        req_ready_o,
    input  logic        req_store_i,
    input  logic [63:0] req_addr_i,
    input  logic [2:0]  req_size_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0] req_store_data_i,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic        rsp_valid_o,
    input  logic        rsp_ready_i,
    output logic [63:0] rsp_data_o,
    output logic        rsp_error_o,
    output logic        access_error_o,

    // External interrupt line inputs (level-sensitive, active-high)
    // Bit 0 is unused (Source 0 is architectural no-interrupt)
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] irq_sources_i,
    /* verilator lint_on UNUSEDSIGNAL */

    // Core interrupt notification outputs
    output logic        irq_meip_o, // Context 0: Hart 0 M-mode MEIP
    output logic        irq_seip_o  // Context 1: Hart 0 S-mode SEIP
);

    // =========================================================================
    // 1. Storage Registers
    // =========================================================================
    // Priorities for sources 1..31 (3 bits each; source 0 is hardwired to 0)
    logic [2:0] priority_q [31:1];

    // Thresholds for Context 0 (M) and Context 1 (S) (3 bits each)
    logic [2:0] threshold_q [1:0];

    // Enables for Context 0 and Context 1 (bit 0 is hardwired to 0)
    logic [31:1] enable_q [1:0];

    // Gateway states per source (source 0 is permanently 0)
    logic [31:1] pending_q;
    logic [31:1] in_service_q;

    // Bus response registers
    logic        rsp_valid_q;
    logic        rsp_error_q;
    logic [31:0] rsp_data_q;

    // =========================================================================
    // 2. Eligibility and Priority Arbitration
    // =========================================================================
    // Claim eligibility: pending && enabled && priority > 0 (strictly NO threshold check)
    logic [31:1] claim_eligible [1:0];
    // Notification eligibility: claim_eligible && priority > threshold
    logic [31:1] notify_eligible [1:0];
    logic [1:0]  context_irq;

    // Highest-priority claim candidate per context (with lowest numerical ID tie-break)
    logic [4:0]  claim_selected_id [1:0];

    for (genvar c = 0; c < 2; c++) begin : gen_eligibility
        for (genvar i = 1; i <= 31; i++) begin : gen_src
            assign claim_eligible[c][i]  = pending_q[i] && enable_q[c][i] && (priority_q[i] > 3'd0);
            assign notify_eligible[c][i] = claim_eligible[c][i] && (priority_q[i] > threshold_q[c]);
        end
        assign context_irq[c] = |notify_eligible[c];
    end

    // Core notification outputs directly from notification eligibility
    assign irq_meip_o = context_irq[0];
    assign irq_seip_o = context_irq[1];

    // Combinational arbitration for Claim reads (strictly independent of threshold)
    always_comb begin
        for (int c = 0; c < 2; c++) begin
            claim_selected_id[c] = 5'd0;
            for (int i = 1; i <= 31; i++) begin
                if (claim_eligible[c][i]) begin
                    if (claim_selected_id[c] == 5'd0) begin
                        claim_selected_id[c] = 5'(i);
                    end else if (priority_q[i] > priority_q[claim_selected_id[c]]) begin
                        claim_selected_id[c] = 5'(i);
                    end
                    // Equal priority retains earlier i (lowest numerical ID wins)
                end
            end
        end
    end

    // =========================================================================
    // 3. MMIO Address Decode and Access Validation
    // =========================================================================
    logic [23:0] offset;
    assign offset = req_addr_i[23:0];

    logic in_plic_range;
    assign in_plic_range = (req_addr_i >= BASE_ADDR) && (req_addr_i < (BASE_ADDR + 64'h0040_0000));

    logic is_word_access, is_aligned_access, size_align_ok;
    assign is_word_access    = (req_size_i == 3'd2);
    assign is_aligned_access = (req_addr_i[1:0] == 2'b00);
    assign size_align_ok     = is_word_access && is_aligned_access;

    // Address region decode
    logic is_priority_s0;
    logic is_priority_s1_31;
    logic is_priority_unimpl;
    logic is_pending_w0;
    logic is_pending_unimpl;
    logic is_enable_c0_w0;
    logic is_enable_c0_unimpl;
    logic is_enable_c1_w0;
    logic is_enable_c1_unimpl;
    logic is_threshold_c0;
    logic is_claim_c0;
    logic is_threshold_c1;
    logic is_claim_c1;
    logic valid_addr;
    logic valid_access;

    assign is_priority_s0     = in_plic_range && (offset == 24'h000000);
    assign is_priority_s1_31  = in_plic_range && (offset >= 24'h000004 && offset <= 24'h00007C);
    assign is_priority_unimpl = in_plic_range && (offset >= 24'h000080 && offset <= 24'h000FFC);
    assign is_pending_w0      = in_plic_range && (offset == 24'h001000);
    assign is_pending_unimpl  = in_plic_range && (offset >= 24'h001004 && offset <= 24'h00107C);
    assign is_enable_c0_w0    = in_plic_range && (offset == 24'h002000);
    assign is_enable_c0_unimpl= in_plic_range && (offset >= 24'h002004 && offset <= 24'h00207C);
    assign is_enable_c1_w0    = in_plic_range && (offset == 24'h002080);
    assign is_enable_c1_unimpl= in_plic_range && (offset >= 24'h002084 && offset <= 24'h0020FC);
    assign is_threshold_c0    = in_plic_range && (offset == 24'h200000);
    assign is_claim_c0        = in_plic_range && (offset == 24'h200004);
    assign is_threshold_c1    = in_plic_range && (offset == 24'h201000);
    assign is_claim_c1        = in_plic_range && (offset == 24'h201004);

    assign valid_addr = is_priority_s0 || is_priority_s1_31 || is_priority_unimpl ||
                        is_pending_w0  || is_pending_unimpl  ||
                        is_enable_c0_w0 || is_enable_c0_unimpl ||
                        is_enable_c1_w0 || is_enable_c1_unimpl ||
                        is_threshold_c0 || is_claim_c0 ||
                        is_threshold_c1 || is_claim_c1;

    assign valid_access = in_plic_range && valid_addr && size_align_ok;

    // Bus handshake
    logic req_fire;
    assign req_ready_o    = !rsp_valid_q;
    assign req_fire       = req_valid_i && req_ready_o;
    assign access_error_o = req_fire && !valid_access;

    assign rsp_valid_o = rsp_valid_q;
    assign rsp_error_o = rsp_error_q;
    assign rsp_data_o  = {32'd0, rsp_data_q}; // Right-justified 32-bit load data

    // Target source index for priority accesses
    logic [4:0] priority_src_idx;
    assign priority_src_idx = offset[6:2];

    // Read multiplexer (evaluated combinationally on req_fire)
    logic [31:0] read_data_comb;
    always_comb begin
        read_data_comb = 32'd0;
        if (is_priority_s0 || is_priority_unimpl || is_pending_unimpl ||
            is_enable_c0_unimpl || is_enable_c1_unimpl) begin
            read_data_comb = 32'd0; // RAZ
        end else if (is_priority_s1_31) begin
            read_data_comb = {29'd0, priority_q[priority_src_idx]};
        end else if (is_pending_w0) begin
            read_data_comb = {pending_q[31:1], 1'b0};
        end else if (is_enable_c0_w0) begin
            read_data_comb = {enable_q[0][31:1], 1'b0};
        end else if (is_enable_c1_w0) begin
            read_data_comb = {enable_q[1][31:1], 1'b0};
        end else if (is_threshold_c0) begin
            read_data_comb = {29'd0, threshold_q[0]};
        end else if (is_claim_c0) begin
            read_data_comb = {27'd0, claim_selected_id[0]};
        end else if (is_threshold_c1) begin
            read_data_comb = {29'd0, threshold_q[1]};
        end else if (is_claim_c1) begin
            read_data_comb = {27'd0, claim_selected_id[1]};
        end
    end

    // =========================================================================
    // 4. Claim and Complete Side Effect Detection
    // =========================================================================
    // Claim side effect executes ONLY on an accepted, valid Claim read
    logic claim_c0_fire;
    logic claim_c1_fire;
    logic [4:0] claimed_id;

    assign claim_c0_fire = req_fire && !req_store_i && valid_access && is_claim_c0 && (claim_selected_id[0] != 5'd0);
    assign claim_c1_fire = req_fire && !req_store_i && valid_access && is_claim_c1 && (claim_selected_id[1] != 5'd0);
    assign claimed_id    = claim_c0_fire ? claim_selected_id[0] : (claim_c1_fire ? claim_selected_id[1] : 5'd0);

    // Complete transaction: valid_complete(c, k) = (1 <= k <= 31) && enable[c][k] && in_service[k]
    logic complete_c0_fire;
    logic complete_c1_fire;
    logic [31:0] complete_write_val;
    logic [4:0]  complete_src_id;
    logic        complete_id_in_range;

    assign complete_write_val   = req_store_data_i[31:0];
    assign complete_id_in_range = (complete_write_val >= 32'd1) && (complete_write_val <= 32'd31);
    assign complete_src_id      = complete_write_val[4:0];

    assign complete_c0_fire = req_fire && req_store_i && valid_access && is_claim_c0 &&
                              complete_id_in_range && enable_q[0][complete_src_id] && in_service_q[complete_src_id];

    assign complete_c1_fire = req_fire && req_store_i && valid_access && is_claim_c1 &&
                              complete_id_in_range && enable_q[1][complete_src_id] && in_service_q[complete_src_id];

    logic [4:0] completed_id;
    assign completed_id = complete_c0_fire ? complete_src_id : (complete_c1_fire ? complete_src_id : 5'd0);

    // =========================================================================
    // 5. Gateway and Register Sequential Updates
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            // Reset state: quiescent, no pending, no in-service, all disabled
            for (int i = 1; i <= 31; i++) begin
                priority_q[i]   <= 3'd0;
                pending_q[i]    <= 1'b0;
                in_service_q[i] <= 1'b0;
            end
            enable_q[0]    <= 31'd0;
            enable_q[1]    <= 31'd0;
            threshold_q[0] <= 3'd0;
            threshold_q[1] <= 3'd0;

            rsp_valid_q <= 1'b0;
            rsp_error_q <= 1'b0;
            rsp_data_q  <= 32'd0;
        end else begin
            // -----------------------------------------------------------------
            // Bus Response Handshake
            // -----------------------------------------------------------------
            if (rsp_valid_q && rsp_ready_i) begin
                rsp_valid_q <= 1'b0;
            end

            if (req_fire) begin
                if (!req_store_i) begin
                    // Load transaction response
                    rsp_valid_q <= 1'b1;
                    rsp_error_q <= !valid_access;
                    rsp_data_q  <= valid_access ? read_data_comb : 32'd0;
                end
                // Store transactions complete in one cycle; errors propagate via access_error_o

                // -------------------------------------------------------------
                // Register Writes (strictly gated by valid_access && req_store_i)
                // -------------------------------------------------------------
                if (req_store_i && valid_access) begin
                    if (is_priority_s1_31) begin
                        priority_q[priority_src_idx] <= req_store_data_i[2:0];
                    end else if (is_enable_c0_w0) begin
                        enable_q[0] <= req_store_data_i[31:1];
                    end else if (is_enable_c1_w0) begin
                        enable_q[1] <= req_store_data_i[31:1];
                    end else if (is_threshold_c0) begin
                        threshold_q[0] <= req_store_data_i[2:0];
                    end else if (is_threshold_c1) begin
                        threshold_q[1] <= req_store_data_i[2:0];
                    end
                    // Unimplemented, RO0, and Pending writes are silently ignored
                end
            end

            // -----------------------------------------------------------------
            // Source Gateway Transitions (IDs 1..31)
            // -----------------------------------------------------------------
            for (int i = 1; i <= 31; i++) begin
                if ((claim_c0_fire || claim_c1_fire) && (claimed_id == 5'(i))) begin
                    // Claim transition: PENDING -> IN_SERVICE (atomically clear pending)
                    pending_q[i]    <= 1'b0;
                    in_service_q[i] <= 1'b1;
                end else if ((complete_c0_fire || complete_c1_fire) && (completed_id == 5'(i))) begin
                    // Complete transition: release IN_SERVICE and resample physical line
                    in_service_q[i] <= 1'b0;
                    if (irq_sources_i[i]) begin
                        pending_q[i] <= 1'b1; // Held high -> immediately re-pend
                    end else begin
                        pending_q[i] <= 1'b0; // Deasserted -> return to IDLE
                    end
                end else if (!in_service_q[i]) begin
                    // Gateway IDLE or PENDING: latch level transition
                    if (irq_sources_i[i]) begin
                        pending_q[i] <= 1'b1;
                    end
                    // If line falls while PENDING, pending_q[i] remains latched (holds value)
                end else begin
                    // While IN_SERVICE and not completing: line assertion cannot set pending
                    pending_q[i] <= 1'b0;
                end
            end
        end
    end

    // =========================================================================
    // 6. Architectural Assertions and Invariants
    // =========================================================================
    // pragma translate_off
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            // 1. In-service ownership is at most 1 globally
            for (int i = 1; i <= 31; i++) begin
                assert (!(pending_q[i] && in_service_q[i]))
                    else $fatal(1, "PLIC Gateway Invariant: source %0d is both pending and in_service", i);
            end

            // 2. Context interrupt output strictly matches notification eligibility
            assert (irq_meip_o == (|notify_eligible[0]))
                else $fatal(1, "PLIC MEIP mismatch with Context 0 notification eligibility");
            assert (irq_seip_o == (|notify_eligible[1]))
                else $fatal(1, "PLIC SEIP mismatch with Context 1 notification eligibility");

            // 3. Successful claim returns claim-eligible source
            if (claim_c0_fire) begin
                assert (claim_eligible[0][claimed_id])
                    else $fatal(1, "PLIC Context 0 claimed source %0d was not claim-eligible", claimed_id);
            end
            if (claim_c1_fire) begin
                assert (claim_eligible[1][claimed_id])
                    else $fatal(1, "PLIC Context 1 claimed source %0d was not claim-eligible", claimed_id);
            end
        end
    end
    // pragma translate_on

endmodule

`endif // FURSOY_S0_PLIC_SV
