`ifndef FURSOY_S1_FREELIST_SV
`define FURSOY_S1_FREELIST_SV

// =============================================================================
// Fursoy Slice-1 Free List Module — Milestone 1
// =============================================================================
// Circular FIFO storage for 48 uncommitted physical registers (p32..p79 at reset).
// Supports:
// - Up to 2 allocations/cycle (pops from head)
// - Up to 2 retirement Pold returns/cycle (pushes to tail)
// - Up to 2 squash Pnew returns/cycle (pushes to tail)
// - Full architectural flush reconstruction from committed ARAT ownership
// - Explicit count, empty, and full tracking with circular modulo-48 wrap
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_freelist
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned FL_CAPACITY = FL_DEPTH // 48 entries
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // -------------------------------------------------------------------------
    // Allocation Interface (Rename Pops)
    // -------------------------------------------------------------------------
    // Number of allocations requested by Rename (0, 1, or 2)
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [1:0]             alloc_req_i,
    /* verilator lint_on UNUSEDSIGNAL */
    // Grant from Rename: which allocations actually occurred
    input  logic [1:0]             alloc_grant_i,
    // Speculatively peeked / allocated physical registers
    output preg_t                  alloc_preg_o [1:0],
    output logic [1:0]             alloc_ready_o, // [0]: >=1 available, [1]: >=2 available

    // -------------------------------------------------------------------------
    // Retirement Reclamation Interface (Commit Pold Pushes)
    // -------------------------------------------------------------------------
    input  logic [1:0]             retire_push_valid_i,
    input  preg_t                  retire_push_preg_i [1:0],

    // -------------------------------------------------------------------------
    // Squash Recovery Reclamation Interface (Squash Pnew Pushes)
    // -------------------------------------------------------------------------
    input  logic [1:0]             recover_push_valid_i,
    input  preg_t                  recover_push_preg_i [1:0],

    // -------------------------------------------------------------------------
    // Full Architectural Flush Reconstruction Interface
    // -------------------------------------------------------------------------
    input  logic                   reconstruct_req_i,
    input  logic [PRF_SIZE-1:0]    committed_mask_i, // bit p is 1 if p is in ARAT or p=0
    output logic                   reconstructing_o,

    // -------------------------------------------------------------------------
    // Status & Diagnostics
    // -------------------------------------------------------------------------
    output logic [FL_CNT_W-1:0]    count_o,
    output logic                   empty_o,
    output logic                   full_o
);

    // -------------------------------------------------------------------------
    // Internal Circular FIFO Storage & Pointers (128 entries: p32..p159 at reset)
    // -------------------------------------------------------------------------
    preg_t mem_q [FL_CAPACITY];
    logic [6:0] head_q;
    logic [6:0] tail_q;
    logic [FL_CNT_W-1:0] count_q;

    // Flush reconstruction scan index (0..159)
    logic [7:0] scan_idx_q;
    logic       reconstructing_q;

    // Modulo-128 pointer arithmetic (power-of-2 natural wrap on 7 bits)
    function automatic [6:0] inc128(input [6:0] ptr, input [3:0] val);
        return ptr + {3'b0, val};
    endfunction

    // -------------------------------------------------------------------------
    // Combinational Allocation Read / Readiness
    // -------------------------------------------------------------------------
    assign alloc_preg_o[0] = mem_q[head_q];
    assign alloc_preg_o[1] = mem_q[inc128(head_q, 4'd1)];

    assign alloc_ready_o[0] = !reconstructing_q && (count_q >= 8'd1);
    assign alloc_ready_o[1] = !reconstructing_q && (count_q >= 8'd2);

    assign count_o          = count_q;
    assign empty_o          = (count_q == 8'd0);
    assign full_o           = (count_q == FL_CNT_W'(FL_CAPACITY));
    assign reconstructing_o = reconstructing_q;

    // -------------------------------------------------------------------------
    // Reclamation Push Preparation (up to 4 pushes per cycle)
    // -------------------------------------------------------------------------
    logic [2:0] num_pushes;
    preg_t      push_pregs [4];

    always_comb begin
        num_pushes = 3'd0;
        for (int unsigned k = 0; k < 4; k++) begin
            push_pregs[k] = '0;
        end

        // Retirement Pold pushes
        if (retire_push_valid_i[0] && (retire_push_preg_i[0] != preg_t'(0))) begin
            push_pregs[num_pushes[1:0]] = retire_push_preg_i[0];
            num_pushes = num_pushes + 3'd1;
        end
        if (retire_push_valid_i[1] && (retire_push_preg_i[1] != preg_t'(0))) begin
            push_pregs[num_pushes[1:0]] = retire_push_preg_i[1];
            num_pushes = num_pushes + 3'd1;
        end

        // Squash Pnew pushes
        if (recover_push_valid_i[0] && (recover_push_preg_i[0] != preg_t'(0))) begin
            push_pregs[num_pushes[1:0]] = recover_push_preg_i[0];
            num_pushes = num_pushes + 3'd1;
        end
        if (recover_push_valid_i[1] && (recover_push_preg_i[1] != preg_t'(0))) begin
            push_pregs[num_pushes[1:0]] = recover_push_preg_i[1];
            num_pushes = num_pushes + 3'd1;
        end
    end

    // Number of pops granted
    logic [1:0] num_pops;
    assign num_pops = (alloc_grant_i == 2'b11) ? 2'd2 :
                      (alloc_grant_i[0])       ? 2'd1 : 2'd0;

    // Flush Reconstruction Candidate Calculation (8 registers/cycle -> 20 cycles for 160 regs)
    logic [3:0] recon_pushes_comb;
    preg_t      recon_p_comb [8];
    always_comb begin
        recon_pushes_comb = 4'd0;
        for (int unsigned k = 0; k < 8; k++) begin
            recon_p_comb[k] = '0;
        end
        for (int unsigned c = 0; c < 8; c++) begin
            logic [7:0] cand_p;
            cand_p = scan_idx_q + c[7:0];
            if ((cand_p > 8'd0) && (cand_p < PRF_SIZE[7:0]) && !committed_mask_i[cand_p]) begin
                recon_p_comb[recon_pushes_comb[2:0]] = cand_p;
                recon_pushes_comb = recon_pushes_comb + 4'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sequential State Update & Flush Reconstruction FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            head_q           <= 7'd0;
            tail_q           <= 7'd0;
            count_q          <= FL_CNT_W'(FL_CAPACITY);
            reconstructing_q <= 1'b0;
            scan_idx_q       <= 8'd0;

            // Reset state: p32..p159 (128 free registers) in Free List
            /* verilator lint_off BLKSEQ */
            for (int unsigned i = 0; i < FL_CAPACITY; i++) begin
                mem_q[i] = preg_t'(8'd32 + 8'(i));
            end
            /* verilator lint_on BLKSEQ */
        end else if (reconstruct_req_i) begin
            // Initiate full flush reconstruction
            head_q           <= 7'd0;
            tail_q           <= 7'd0;
            count_q          <= 8'd0;
            scan_idx_q       <= 8'd0;
            reconstructing_q <= 1'b1;
        end else if (reconstructing_q) begin
            // Reconstruct Free List by scanning uncommitted physical registers
            for (int unsigned c = 0; c < 8; c++) begin
                if (c[3:0] < recon_pushes_comb) begin
                    mem_q[inc128(tail_q, c[3:0])] <= recon_p_comb[c];
                end
            end

            tail_q  <= inc128(tail_q, recon_pushes_comb);
            count_q <= count_q + {4'b0, recon_pushes_comb};

            if (scan_idx_q + 8'd8 >= PRF_SIZE[7:0]) begin
                // Completed scan of all 160 registers
                reconstructing_q <= 1'b0;
            end else begin
                scan_idx_q <= scan_idx_q + 8'd8;
            end
        end else begin
            // -----------------------------------------------------------------
            // Normal Operation: Simultaneous Pops and Pushes
            // -----------------------------------------------------------------
            // Apply pushes to tail
            for (int unsigned p = 0; p < 4; p++) begin
                if (p < num_pushes) begin
                    mem_q[inc128(tail_q, p[3:0])] <= push_pregs[p];
                end
            end

            // Advance pointers
            tail_q  <= inc128(tail_q, {1'b0, num_pushes});
            head_q  <= inc128(head_q, {2'b0, num_pops});
            count_q <= count_q - {6'b0, num_pops} + {5'b0, num_pushes};
        end
    end

    // -------------------------------------------------------------------------
    // Invariant Checkers & Simulation Assertions
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    always @(posedge clk_i) begin
        if (!rst_i && !reconstructing_q && !reconstruct_req_i) begin
            // 1. Count must never exceed capacity or underflow
            if (count_q > FL_CNT_W'(FL_CAPACITY)) begin
                $fatal(1, "[FL ASSERTION FAILED] Free List count %0d exceeds capacity %0d", count_q, FL_CAPACITY);
            end

            // 2. p0 is never allocated
            if (alloc_grant_i[0] && (alloc_preg_o[0] == preg_t'(0))) begin
                $fatal(1, "[FL ASSERTION FAILED] p0 allocated on port 0!");
            end
            if ((alloc_grant_i == 2'b11) && (alloc_preg_o[1] == preg_t'(0))) begin
                $fatal(1, "[FL ASSERTION FAILED] p0 allocated on port 1!");
            end

            // 3. p0 is never freed
            if (retire_push_valid_i[0] && (retire_push_preg_i[0] == preg_t'(0))) begin
                $fatal(1, "[FL ASSERTION FAILED] p0 returned via retirement port 0!");
            end
            if (retire_push_valid_i[1] && (retire_push_preg_i[1] == preg_t'(0))) begin
                $fatal(1, "[FL ASSERTION FAILED] p0 returned via retirement port 1!");
            end
            if (recover_push_valid_i[0] && (recover_push_preg_i[0] == preg_t'(0))) begin
                $fatal(1, "[FL ASSERTION FAILED] p0 returned via recovery port 0!");
            end
            if (recover_push_valid_i[1] && (recover_push_preg_i[1] == preg_t'(0))) begin
                $fatal(1, "[FL ASSERTION FAILED] p0 returned via recovery port 1!");
            end

            // 4. No duplicates among currently valid entries in Free List
            begin
                logic [PRF_SIZE-1:0] fl_seen_mask;
                fl_seen_mask = '0;
                for (int unsigned e = 0; e < FL_CAPACITY; e++) begin
                    if (e < count_q) begin
                        logic [6:0] p_idx;
                        p_idx = head_q + e[6:0];
                        if (fl_seen_mask[mem_q[p_idx]]) begin
                            $fatal(1, "[FL ASSERTION FAILED] Duplicate physical register p%0d found in Free List!",
                                   mem_q[p_idx]);
                        end
                        fl_seen_mask[mem_q[p_idx]] = 1'b1;
                    end
                end
            end
        end
    end
`endif

endmodule

`endif // FURSOY_S1_FREELIST_SV
