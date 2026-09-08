// Combinational Physical Memory Protection (PMP) checker for Fursoy CPU (RV64, G=0, 16 entries).
`ifndef FURSOY_S0_PMP_CHECK_SV
`define FURSOY_S0_PMP_CHECK_SV

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */
module fursoy_s0_pmp_check (
    input  logic [7:0]  pmp_cfg_i [16],
    input  logic [53:0] pmp_addr_i [16],
    input  logic [55:0] req_addr_i,
    input  logic [2:0]  req_size_i,
    input  logic [1:0]  req_op_i,    // 2'b00: FETCH, 2'b01: LOAD, 2'b10: STORE
    input  logic [1:0]  req_priv_i,  // 2'b00: U, 2'b01: S, 2'b11: M
    output logic        allow_o
);
    localparam logic [1:0] OP_FETCH = 2'b00;
    localparam logic [1:0] OP_LOAD  = 2'b01;
    localparam logic [1:0] OP_STORE = 2'b10;
    localparam logic [1:0] OP_AMO   = 2'b11;

    logic [56:0] a_start;
    logic [56:0] a_end;
    logic [3:0]  len_bytes;

    logic [56:0] b_lower [16];
    logic [56:0] b_upper [16];
    logic [15:0] overlaps;
    logic [15:0] contains;

    logic        any_overlap;
    logic [3:0]  selected_entry;
    logic        req_perm;
    int          k;
    logic [55:0] base_val;

    always_comb begin
        allow_o        = 1'b0;
        any_overlap    = 1'b0;
        selected_entry = 4'd0;
        req_perm       = 1'b0;
        k              = 0;
        base_val       = '0;
        for (int idx = 0; idx < 16; idx++) begin
            b_lower[idx]  = 57'd0;
            b_upper[idx]  = 57'd0;
            overlaps[idx] = 1'b0;
            contains[idx] = 1'b0;
        end

        case (req_size_i)
            3'd0: len_bytes = 4'd1;
            3'd1: len_bytes = 4'd2;
            3'd2: len_bytes = 4'd4;
            3'd3: len_bytes = 4'd8;
            default: len_bytes = 4'd1;
        endcase

        a_start = {1'b0, req_addr_i};
        a_end   = a_start + {53'd0, len_bytes} - 57'd1;

        for (int i = 0; i < 16; i++) begin
            logic [1:0]  a_mode;
            logic [53:0] p;
            a_mode = pmp_cfg_i[i][4:3];
            p      = pmp_addr_i[i];

            case (a_mode)
                2'b00: begin // OFF
                    b_lower[i]  = 57'd0;
                    b_upper[i]  = 57'd0;
                    overlaps[i] = 1'b0;
                    contains[i] = 1'b0;
                end
                2'b01: begin // TOR
                    if (i == 0) begin
                        b_lower[i] = 57'd0;
                    end else begin
                        b_lower[i] = {1'b0, pmp_addr_i[i-1], 2'b00};
                    end
                    b_upper[i] = {1'b0, p, 2'b00};
                    if (b_lower[i] >= b_upper[i]) begin
                        overlaps[i] = 1'b0;
                        contains[i] = 1'b0;
                    end else begin
                        overlaps[i] = (a_start < b_upper[i]) && (a_end >= b_lower[i]);
                        contains[i] = (a_start >= b_lower[i]) && (a_end < b_upper[i]);
                    end
                end
                2'b10: begin // NA4
                    b_lower[i]  = {1'b0, p, 2'b00};
                    b_upper[i]  = b_lower[i] + 57'd4;
                    overlaps[i] = (a_start < b_upper[i]) && (a_end >= b_lower[i]);
                    contains[i] = (a_start >= b_lower[i]) && (a_end < b_upper[i]);
                end
                2'b11: begin // NAPOT
                    k = 54;
                    for (int b = 0; b < 54; b++) begin
                        if (!p[b] && k == 54) begin
                            k = b;
                        end
                    end
                    if (k >= 53) begin
                        b_lower[i] = 57'd0;
                        b_upper[i] = 57'h1_0000_0000_0000_00; // 2^56: covers entire 56-bit PA space
                    end else begin
                        base_val = {2'b00, p};
                        b_lower[i] = 57'd0;
                        b_lower[i][55:0] = (base_val >> (k + 1)) << (k + 3);
                        b_upper[i] = b_lower[i] + (57'd1 << (k + 3));
                    end
                    overlaps[i] = (a_start < b_upper[i]) && (a_end >= b_lower[i]);
                    contains[i] = (a_start >= b_lower[i]) && (a_end < b_upper[i]);
                end
            endcase
        end

        // First-entry priority selection: lowest index i with overlaps[i] == 1
        any_overlap    = 1'b0;
        selected_entry = 4'd0;
        for (int j = 15; j >= 0; j--) begin
            if (overlaps[j]) begin
                any_overlap    = 1'b1;
                selected_entry = 4'(j);
            end
        end

        if (any_overlap) begin
            if (!contains[selected_entry]) begin
                // Boundary crossing / partial overlap: immediate access fault!
                // Never inspect subsequent entries; applies even in M-mode when L=0!
                allow_o = 1'b0;
            end else begin
                case (req_op_i)
                    OP_FETCH: req_perm = pmp_cfg_i[selected_entry][2]; // X
                    OP_LOAD:  req_perm = pmp_cfg_i[selected_entry][0]; // R
                    OP_STORE: req_perm = pmp_cfg_i[selected_entry][1]; // W
                    OP_AMO:   req_perm = pmp_cfg_i[selected_entry][0] && pmp_cfg_i[selected_entry][1]; // R && W
                    default:  req_perm = 1'b0;
                endcase

                if (req_priv_i == 2'b11) begin // M-mode
                    if (!pmp_cfg_i[selected_entry][7]) begin // L == 0
                        allow_o = 1'b1; // M-mode bypasses unlocked entry
                    end else begin // L == 1
                        allow_o = req_perm;
                    end
                end else begin // S-mode or U-mode
                    allow_o = req_perm;
                end
            end
        end else begin
            // No matching entry
            if (req_priv_i == 2'b11) begin
                allow_o = 1'b1; // M-mode default allow
            end else begin
                allow_o = 1'b0; // S/U-mode default deny
            end
        end
    end
endmodule
/* verilator lint_on DECLFILENAME */

`endif // FURSOY_S0_PMP_CHECK_SV
