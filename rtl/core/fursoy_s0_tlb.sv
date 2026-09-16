`ifndef FURSOY_S0_TLB_SV
`define FURSOY_S0_TLB_SV

// 16-entry fully associative Translation Lookaside Buffer (TLB) for Sv39.
// Supports 4 KiB, 2 MiB megapages, and 1 GiB gigapages.
// Implements True-LRU replacement via a 16x16 triangular age matrix.
// Pure translation cache: caches only static leaf PTE metadata.
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */
module fursoy_s0_tlb #(
    parameter int ENTRIES = 16
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // Invalidation interface
    input  logic        flush_all_i,
    input  logic        flush_va_valid_i,
    input  logic [63:0] flush_va_i,

    // Combinational Lookup interface (0-cycle hit detection & address formation)
    input  logic        lookup_valid_i,
    input  logic [63:0] lookup_va_i,
    output logic        hit_o,
    output logic [3:0]  hit_idx_o,
    output logic [55:0] hit_pa_o,
    output logic [1:0]  hit_level_o,
    output logic        hit_u_o,
    output logic        hit_g_o,
    output logic        hit_r_o,
    output logic        hit_w_o,
    output logic        hit_x_o,
    output logic        hit_a_o,
    output logic        hit_d_o,

    // Touch port (update True-LRU state on serviced hit)
    input  logic        touch_i,
    input  logic [3:0]  touch_idx_i,

    // Refill interface (install validated leaf translation)
    input  logic        refill_valid_i,
    input  logic [26:0] refill_vpn_i,
    input  logic [1:0]  refill_level_i,
    input  logic [43:0] refill_ppn_i,
    input  logic        refill_u_i,
    input  logic        refill_g_i,
    input  logic        refill_r_i,
    input  logic        refill_w_i,
    input  logic        refill_x_i,
    input  logic        refill_a_i,
    input  logic        refill_d_i,
    output logic [3:0]  refill_idx_o,

    // Observability
    output logic [4:0]  valid_count_o
);

    // TLB Entry Storage
    logic [ENTRIES-1:0] valid_q;
    logic [26:0]        vpn_q   [ENTRIES];
    logic [1:0]         level_q [ENTRIES];
    logic [43:0]        ppn_q   [ENTRIES];
    logic [ENTRIES-1:0] u_q, g_q, r_q, w_q, x_q, a_q, d_q;

    // True-LRU 16x16 age matrix
    // age_q[i][j] == 1 indicates entry i was accessed more recently than entry j
    logic [ENTRIES-1:0] age_q [ENTRIES];

    // Helper: tag matching function
    function automatic logic entry_match_vpn(
        input logic        entry_valid,
        input logic [26:0] entry_vpn,
        input logic [1:0]  entry_level,
        input logic [26:0] target_vpn
    );
        logic tag_match;
        case (entry_level)
            2'b00:   tag_match = (entry_vpn[26:0]  == target_vpn[26:0]);
            2'b01:   tag_match = (entry_vpn[26:9]  == target_vpn[26:9]);
            2'b10:   tag_match = (entry_vpn[26:18] == target_vpn[26:18]);
            default: tag_match = 1'b0;
        endcase
        return entry_valid && tag_match;
    endfunction

    // Helper: physical address formation function
    function automatic logic [55:0] form_paddr(
        input logic [43:0] entry_ppn,
        input logic [1:0]  entry_level,
        input logic [63:0] req_va
    );
        case (entry_level)
            2'b00:   return {entry_ppn[43:0], req_va[11:0]};
            2'b01:   return {entry_ppn[43:9], req_va[20:0]};
            2'b10:   return {entry_ppn[43:18], req_va[29:0]};
            default: return {entry_ppn[43:0], req_va[11:0]};
        endcase
    endfunction

    // Parallel CAM Tag Lookup
    logic [ENTRIES-1:0] match;
    wire [26:0] lookup_vpn = lookup_va_i[38:12];

    always_comb begin
        for (int i = 0; i < ENTRIES; i++) begin
            match[i] = lookup_valid_i && entry_match_vpn(valid_q[i], vpn_q[i], level_q[i], lookup_vpn);
        end
    end

    assign hit_o = |match;

    // Output MUX for matching entry
    always_comb begin
        hit_idx_o   = 4'd0;
        hit_pa_o    = 56'd0;
        hit_level_o = 2'd0;
        hit_u_o     = 1'b0;
        hit_g_o     = 1'b0;
        hit_r_o     = 1'b0;
        hit_w_o     = 1'b0;
        hit_x_o     = 1'b0;
        hit_a_o     = 1'b0;
        hit_d_o     = 1'b0;

        for (int i = 0; i < ENTRIES; i++) begin
            if (match[i]) begin
                hit_idx_o   = 4'(i);
                hit_pa_o    = form_paddr(ppn_q[i], level_q[i], lookup_va_i);
                hit_level_o = level_q[i];
                hit_u_o     = u_q[i];
                hit_g_o     = g_q[i];
                hit_r_o     = r_q[i];
                hit_w_o     = w_q[i];
                hit_x_o     = x_q[i];
                hit_a_o     = a_q[i];
                hit_d_o     = d_q[i];
            end
        end
    end

    // True-LRU Rank Calculation: count of entries this entry is newer than
    logic [4:0] age_sum [ENTRIES];
    logic [4:0] min_age_sum;
    logic [3:0] lru_idx;

    always_comb begin
        for (int i = 0; i < ENTRIES; i++) begin
            age_sum[i] = 5'd0;
            for (int j = 0; j < ENTRIES; j++) begin
                age_sum[i] = age_sum[i] + {4'd0, age_q[i][j]};
            end
        end

        min_age_sum = age_sum[0];
        lru_idx = 4'd0;
        for (int i = 1; i < ENTRIES; i++) begin
            if (age_sum[i] < min_age_sum) begin
                min_age_sum = age_sum[i];
                lru_idx = 4'(i);
            end
        end
    end

    // True-LRU Replacement Candidate Selection
    logic [3:0] replace_idx;
    logic       found_match, found_invalid;

    always_comb begin
        replace_idx   = 4'd0;
        found_match   = 1'b0;
        found_invalid = 1'b0;

        // 1. If an entry covering this VPN already exists, update in-place
        for (int i = 0; i < ENTRIES; i++) begin
            if (!found_match && entry_match_vpn(valid_q[i], vpn_q[i], level_q[i], refill_vpn_i)) begin
                replace_idx = 4'(i);
                found_match = 1'b1;
            end
        end

        // 2. Otherwise prefer the first invalid entry
        if (!found_match) begin
            for (int i = 0; i < ENTRIES; i++) begin
                if (!found_invalid && !valid_q[i]) begin
                    replace_idx   = 4'(i);
                    found_invalid = 1'b1;
                end
            end
            // 3. If all entries are valid, select the True-LRU entry
            if (!found_invalid) begin
                replace_idx = lru_idx;
            end
        end
    end

    assign refill_idx_o = replace_idx;

    // Count valid entries for observability
    always_comb begin
        valid_count_o = 5'd0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (valid_q[i]) valid_count_o = valid_count_o + 5'd1;
        end
    end

    // State Updates: Invalidation, Refill, and Age Matrix Maintenance
    logic [3:0] accessed_idx;
    logic       do_update_age;

    assign do_update_age = refill_valid_i || touch_i;
    assign accessed_idx  = refill_valid_i ? replace_idx : touch_idx_i;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_all_i) begin
            valid_q <= '0;
            for (int i = 0; i < ENTRIES; i++) begin
                vpn_q[i]   <= '0;
                level_q[i] <= '0;
                ppn_q[i]   <= '0;
                age_q[i]   <= '0;
            end
            u_q <= '0;
            g_q <= '0;
            r_q <= '0;
            w_q <= '0;
            x_q <= '0;
            a_q <= '0;
            d_q <= '0;
        end else begin
            // 1. Address-selective flush
            if (flush_va_valid_i) begin
                for (int i = 0; i < ENTRIES; i++) begin
                    if (entry_match_vpn(valid_q[i], vpn_q[i], level_q[i], flush_va_i[38:12])) begin
                        valid_q[i] <= 1'b0;
                    end
                end
            end

            // 2. Refill insertion
            if (refill_valid_i) begin
                valid_q[replace_idx] <= 1'b1;
                vpn_q[replace_idx]   <= refill_vpn_i;
                level_q[replace_idx] <= refill_level_i;
                ppn_q[replace_idx]   <= refill_ppn_i;
                u_q[replace_idx]     <= refill_u_i;
                g_q[replace_idx]     <= refill_g_i;
                r_q[replace_idx]     <= refill_r_i;
                w_q[replace_idx]     <= refill_w_i;
                x_q[replace_idx]     <= refill_x_i;
                a_q[replace_idx]     <= refill_a_i;
                d_q[replace_idx]     <= refill_d_i;
            end

            // 3. True-LRU age matrix update
            if (do_update_age) begin
                for (int j = 0; j < ENTRIES; j++) begin
                    if (j == int'(accessed_idx)) begin
                        // Entry becomes more recent than all other entries
                        for (int k = 0; k < ENTRIES; k++) begin
                            age_q[j][k] <= (k != j);
                        end
                    end else begin
                        // Entry j is less recent than accessed_idx
                        age_q[j][accessed_idx] <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
`endif
