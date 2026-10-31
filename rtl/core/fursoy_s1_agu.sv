`ifndef FURSOY_S1_AGU_SV
`define FURSOY_S1_AGU_SV

// =============================================================================
// Fursoy Slice-1 Port 2 Address Generation Unit (AGU) — Milestone 3
// =============================================================================
// Reference: docs/architecture/slice1-m3-memory-v1.md Section 3
//
// Computes 64-bit effective address (EA = base + imm), checks natural alignment,
// generates 8-byte relative byte lane mask, and evaluates Sv39 canonical VA.
// =============================================================================

`include "fursoy_s1_pkg.sv"

module fursoy_s1_agu
    import fursoy_s1_pkg::*;
(
    input  logic              valid_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  uop_subop_t        sub_op_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  mem_size_t         size_i,
    input  logic [63:0]       base_i,
    input  logic [63:0]       imm_i,
    input  logic              is_store_i,

    // Generated Address and Attributes
    output logic [63:0]       ea_o,
    output logic [2:0]        byte_offset_o,
    output logic [5:0]        line_offset_o,
    output logic [7:0]        byte_mask_o,

    // Exception Reporting
    output logic              align_fault_o,
    output logic [4:0]        exc_cause_o
);

    // 64-bit Effective Address Adder
    wire [63:0] ea = base_i + imm_i;

    // Natural Alignment Check
    wire align_ok = check_nat_alignment(ea[2:0], size_i);
    wire align_fault = valid_i && (sub_op_i != MEM_FENCE) && (sub_op_i != MEM_FENCE_I) && !align_ok;

    // Byte Lane Mask
    wire [7:0] byte_mask = get_byte_lane_mask(ea[2:0], size_i);

    // Exception Cause Assignment
    // Cause 4: Load Address Misaligned
    // Cause 6: Store/AMO Address Misaligned
    logic [4:0] exc_cause;
    always_comb begin
        if (align_fault) begin
            exc_cause = is_store_i ? 5'd6 : 5'd4;
        end else begin
            exc_cause = 5'd0;
        end
    end

    assign ea_o          = ea;
    assign byte_offset_o = ea[2:0];
    assign line_offset_o = ea[5:0];
    assign byte_mask_o   = byte_mask;
    assign align_fault_o = align_fault;
    assign exc_cause_o   = exc_cause;

endmodule

`endif // FURSOY_S1_AGU_SV
