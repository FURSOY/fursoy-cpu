`ifndef FURSOY_S2_CLINT_SV
`define FURSOY_S2_CLINT_SV

// =============================================================================
// Fursoy Slice-2 Multi-Hart CLINT (Core-Local Interruptor)
// =============================================================================
// Specification authority: docs/architecture/slice2-smp-v1.md §4.1, §5
// - Parameterized NUM_HARTS (default 2, tested 2 & 4).
// - msip[h] at BASE_ADDR + 0x0000 + 4*h (32-bit aligned RW, bit 0 -> irq_software_o[h]),
//   including 32-bit addr[2] lane steering for odd harts (h = 1, 3, ...).
// - mtimecmp[h] at BASE_ADDR + 0x4000 + 8*h (64-bit aligned RW, reset all-1s).
// - mtime at BASE_ADDR + 0xBFF8 (shared 64-bit RW, +1/cycle).
// - Registered irq_timer_q[h] <= (mtime_q >= mtimecmp_q[h]) for 500 MHz STA.
// - Unified registered rsp_valid_q / rsp_error_q across both loads and stores.
// =============================================================================

module fursoy_s2_clint #(
    parameter logic [63:0] BASE_ADDR = 64'h0000_0000_0200_0000,
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

    // Per-hart interrupt notification outputs & shared timebase
    output logic [NUM_HARTS-1:0] irq_software_o,
    output logic [NUM_HARTS-1:0] irq_timer_o,
    output logic [63:0]          mtime_o
);

    localparam logic [63:0] CLINT_APERTURE = 64'h0001_0000; // 64 KiB
    localparam logic [63:0] MTIME_OFFSET   = 64'h0000_BFF8;
    localparam int unsigned HART_W         = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1;

    // Architectural state
    logic [NUM_HARTS-1:0] msip_q;
    logic [63:0]          mtimecmp_q [NUM_HARTS];
    logic [63:0]          mtime_q;
    logic [NUM_HARTS-1:0] irq_timer_q;

    // Unified bus response registers
    logic        rsp_valid_q;
    logic        rsp_error_q;
    logic [63:0] rsp_data_q;

    // Address decode
    wire in_range = (req_addr_i >= BASE_ADDR) && (req_addr_i < (BASE_ADDR + CLINT_APERTURE));
    /* verilator lint_off UNUSEDSIGNAL */
    wire [15:0] offset = req_addr_i[15:0];
    /* verilator lint_on UNUSEDSIGNAL */

    logic        is_msip;
    logic        is_mtimecmp;
    logic        is_mtime;
    logic [HART_W-1:0] target_hart;
    logic        valid_access;

    always_comb begin
        is_msip      = 1'b0;
        is_mtimecmp  = 1'b0;
        is_mtime     = 1'b0;
        target_hart  = '0;
        valid_access = 1'b0;

        if (in_range) begin
            // msip[h]: 0x0000 + 4*h (32-bit aligned)
            for (int h = 0; h < NUM_HARTS; h++) begin
                if (offset == 16'(h * 4)) begin
                    is_msip     = 1'b1;
                    target_hart = HART_W'(h);
                    if ((req_size_i == 3'd2) && (req_addr_i[1:0] == 2'b00)) begin
                        valid_access = 1'b1;
                    end
                end
            end

            // mtimecmp[h]: 0x4000 + 8*h (64-bit aligned)
            for (int h = 0; h < NUM_HARTS; h++) begin
                if (offset == (16'h4000 + 16'(h * 8))) begin
                    is_mtimecmp = 1'b1;
                    target_hart = HART_W'(h);
                    if ((req_size_i == 3'd3) && (req_addr_i[2:0] == 3'b000)) begin
                        valid_access = 1'b1;
                    end
                end
            end

            // mtime: 0xBFF8 (64-bit aligned)
            if (offset == MTIME_OFFSET[15:0]) begin
                is_mtime = 1'b1;
                if ((req_size_i == 3'd3) && (req_addr_i[2:0] == 3'b000)) begin
                    valid_access = 1'b1;
                end
            end
        end
    end

    // 32-bit lane steering for msip[h] (odd harts h = 1, 3 have addr[2] == 1)
    wire        msip_store_bit = req_addr_i[2] ? req_store_data_i[32] : req_store_data_i[0];
    wire [31:0] msip_read_word = {31'd0, msip_q[target_hart]};

    wire req_fire;
    assign req_ready_o    = !rsp_valid_q;
    assign req_fire       = req_valid_i && req_ready_o;
    assign access_error_o = req_fire && !valid_access;

    assign rsp_valid_o    = rsp_valid_q;
    assign rsp_error_o    = rsp_error_q;
    assign rsp_data_o     = rsp_data_q;

    assign irq_software_o = msip_q;
    assign irq_timer_o    = irq_timer_q;
    assign mtime_o        = mtime_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            msip_q      <= '0;
            mtime_q     <= 64'd0;
            irq_timer_q <= '0;
            for (int h = 0; h < NUM_HARTS; h++) begin
                mtimecmp_q[h] <= 64'hFFFF_FFFF_FFFF_FFFF;
            end
            rsp_valid_q <= 1'b0;
            rsp_error_q <= 1'b0;
            rsp_data_q  <= 64'd0;
        end else begin
            // Free-running 64-bit shared timebase
            mtime_q <= mtime_q + 64'd1;

            // Registered timer comparison per hart (500 MHz timing isolation)
            for (int h = 0; h < NUM_HARTS; h++) begin
                irq_timer_q[h] <= (mtime_q >= mtimecmp_q[h]);
            end

            // Response handshake clear
            if (rsp_valid_q && rsp_ready_i) begin
                rsp_valid_q <= 1'b0;
                rsp_error_q <= 1'b0;
            end

            // Register read/write execution
            if (req_fire) begin
                rsp_valid_q <= 1'b1;
                rsp_error_q <= !valid_access;

                if (req_store_i) begin
                    rsp_data_q <= 64'd0;
                    if (valid_access) begin
                        if (is_msip) begin
                            msip_q[target_hart] <= msip_store_bit;
                        end else if (is_mtimecmp) begin
                            mtimecmp_q[target_hart] <= req_store_data_i;
                        end else if (is_mtime) begin
                            mtime_q <= req_store_data_i;
                        end
                    end
                end else begin
                    if (!valid_access) begin
                        rsp_data_q <= 64'd0;
                    end else if (is_msip) begin
                        rsp_data_q <= {msip_read_word, msip_read_word};
                    end else if (is_mtimecmp) begin
                        rsp_data_q <= mtimecmp_q[target_hart];
                    end else begin
                        rsp_data_q <= mtime_q;
                    end
                end
            end
        end
    end

endmodule

`endif // FURSOY_S2_CLINT_SV
