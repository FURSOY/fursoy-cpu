`ifndef FURSOY_S2_MMIO_XBAR_SV
`define FURSOY_S2_MMIO_XBAR_SV

// =============================================================================
// Fursoy Slice-2 Multi-Hart Registered MMIO Crossbar
// =============================================================================
// Specification authority: docs/architecture/slice2-smp-v1.md §1.1, §4, §5
// - Arbitrates NUM_HARTS core uncached MMIO masters with rotating round-robin.
// - Serializes transactions (1 in flight globally) to guarantee atomic PLIC
//   claim/complete and CLINT/UART ordering across harts.
// - Registered arbiter -> slave output stage AND registered slave -> hart
//   response stage for 500 MHz timing closure.
// =============================================================================

module fursoy_s2_mmio_xbar #(
    parameter int unsigned NUM_HARTS       = 2,
    parameter logic [63:0] CLINT_BASE_ADDR = 64'h0000_0000_0200_0000,
    parameter logic [63:0] PLIC_BASE_ADDR  = 64'h0000_0000_0C00_0000,
    parameter logic [63:0] UART_BASE_ADDR  = 64'h0000_0000_1000_0000
) (
    input  logic                 clk_i,
    input  logic                 rst_i,

    // Per-hart core MMIO master interfaces
    input  logic [NUM_HARTS-1:0] mmio_req_valid_i,
    input  logic [63:0]          mmio_req_addr_i     [NUM_HARTS],
    input  logic [NUM_HARTS-1:0] mmio_req_is_store_i,
    input  logic [2:0]           mmio_req_size_i     [NUM_HARTS],
    input  logic [63:0]          mmio_req_wdata_i    [NUM_HARTS],
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [7:0]           mmio_req_wstrb_i    [NUM_HARTS],
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [NUM_HARTS-1:0] mmio_req_ready_o,

    output logic [NUM_HARTS-1:0] mmio_rsp_valid_o,
    output logic [63:0]          mmio_rsp_rdata_o    [NUM_HARTS],
    output logic [NUM_HARTS-1:0] mmio_rsp_error_o,
    input  logic [NUM_HARTS-1:0] mmio_rsp_ready_i,

    // Slave 0: CLINT (64-bit native, 32-bit msip steered internally)
    output logic                 clint_req_valid_o,
    input  logic                 clint_req_ready_i,
    output logic                 clint_req_store_o,
    output logic [63:0]          clint_req_addr_o,
    output logic [2:0]           clint_req_size_o,
    output logic [63:0]          clint_req_wdata_o,
    input  logic                 clint_rsp_valid_i,
    output logic                 clint_rsp_ready_o,
    input  logic [63:0]          clint_rsp_data_i,
    input  logic                 clint_rsp_error_i,

    // Slave 1: PLIC (64-bit bus, 32-bit lane steered internally)
    output logic                 plic_req_valid_o,
    input  logic                 plic_req_ready_i,
    output logic                 plic_req_store_o,
    output logic [63:0]          plic_req_addr_o,
    output logic [2:0]           plic_req_size_o,
    output logic [63:0]          plic_req_wdata_o,
    input  logic                 plic_rsp_valid_i,
    output logic                 plic_rsp_ready_o,
    input  logic [63:0]          plic_rsp_data_i,
    input  logic                 plic_rsp_error_i,

    // Slave 2: UART16550 (32-bit steered at crossbar boundary)
    output logic                 uart_req_valid_o,
    input  logic                 uart_req_ready_i,
    output logic                 uart_req_store_o,
    output logic [63:0]          uart_req_addr_o,
    output logic [2:0]           uart_req_size_o,
    output logic [63:0]          uart_req_wdata_o,
    input  logic                 uart_rsp_valid_i,
    output logic                 uart_rsp_ready_o,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [63:0]          uart_rsp_data_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                 uart_rsp_error_i
);

    localparam logic [63:0] CLINT_END_ADDR = CLINT_BASE_ADDR + 64'h0001_0000;
    localparam logic [63:0] PLIC_END_ADDR  = PLIC_BASE_ADDR  + 64'h0040_0000;
    localparam logic [63:0] UART_END_ADDR  = UART_BASE_ADDR  + 64'h0000_1000;
    localparam int unsigned HART_W         = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1;

    typedef enum logic [1:0] {
        XBAR_IDLE      = 2'd0,
        XBAR_SLAVE_REQ = 2'd1,
        XBAR_WAIT_RSP  = 2'd2,
        XBAR_HART_RSP  = 2'd3
    } xbar_state_t;

    typedef enum logic [1:0] {
        TGT_CLINT    = 2'd0,
        TGT_PLIC     = 2'd1,
        TGT_UART     = 2'd2,
        TGT_UNMAPPED = 2'd3
    } mmio_tgt_t;

    xbar_state_t      state_q;
    logic [HART_W-1:0] rr_ptr_q;
    logic [HART_W-1:0] active_hart_q;
    mmio_tgt_t        tgt_q;

    // Registered arbiter -> slave request stage
    logic        slave_req_valid_q;
    logic        slave_req_store_q;
    logic [63:0] slave_req_addr_q;
    logic [2:0]  slave_req_size_q;
    logic [63:0] slave_req_wdata_q;

    // Registered slave -> hart response stage
    logic [NUM_HARTS-1:0] hart_rsp_valid_q;
    logic [63:0]          hart_rsp_rdata_q;
    logic                 hart_rsp_error_q;

    // Round-robin winner selection in XBAR_IDLE
    logic              win_found;
    logic [HART_W-1:0] win_hart;
    logic [HART_W-1:0] rr_idx_cand;

    always_comb begin
        win_found   = 1'b0;
        win_hart    = rr_ptr_q;
        rr_idx_cand = '0;
        if (state_q == XBAR_IDLE) begin
            for (int off = 0; off < NUM_HARTS; off++) begin
                rr_idx_cand = HART_W'((int'(rr_ptr_q) + off) % int'(NUM_HARTS));
                if (!win_found && mmio_req_valid_i[rr_idx_cand]) begin
                    win_found = 1'b1;
                    win_hart  = rr_idx_cand;
                end
            end
        end
    end

    // Accept winning hart in XBAR_IDLE
    always_comb begin
        mmio_req_ready_o = '0;
        if ((state_q == XBAR_IDLE) && win_found) begin
            mmio_req_ready_o[win_hart] = 1'b1;
        end
    end

    // Address decode for winning hart
    wire [63:0] win_addr = mmio_req_addr_i[win_hart];
    wire mmio_tgt_t win_tgt = ((win_addr >= CLINT_BASE_ADDR) && (win_addr < CLINT_END_ADDR)) ? TGT_CLINT :
                              ((win_addr >= PLIC_BASE_ADDR)  && (win_addr < PLIC_END_ADDR))  ? TGT_PLIC  :
                              ((win_addr >= UART_BASE_ADDR)  && (win_addr < UART_END_ADDR))  ? TGT_UART  :
                                                                                               TGT_UNMAPPED;

    // Registered slave request outputs
    assign clint_req_valid_o = slave_req_valid_q && (tgt_q == TGT_CLINT);
    assign clint_req_store_o = slave_req_store_q;
    assign clint_req_addr_o  = slave_req_addr_q;
    assign clint_req_size_o  = slave_req_size_q;
    assign clint_req_wdata_o = slave_req_wdata_q;

    assign plic_req_valid_o  = slave_req_valid_q && (tgt_q == TGT_PLIC);
    assign plic_req_store_o  = slave_req_store_q;
    assign plic_req_addr_o   = slave_req_addr_q;
    assign plic_req_size_o   = slave_req_size_q;
    assign plic_req_wdata_o  = slave_req_wdata_q;

    wire [63:0] uart_wdata_32 = slave_req_addr_q[2] ? {32'd0, slave_req_wdata_q[63:32]}
                                                    : {32'd0, slave_req_wdata_q[31:0]};
    assign uart_req_valid_o  = slave_req_valid_q && (tgt_q == TGT_UART);
    assign uart_req_store_o  = slave_req_store_q;
    assign uart_req_addr_o   = slave_req_addr_q;
    assign uart_req_size_o   = slave_req_size_q;
    assign uart_req_wdata_o  = uart_wdata_32;

    wire selected_slave_req_ready = (tgt_q == TGT_CLINT) ? clint_req_ready_i :
                                    (tgt_q == TGT_PLIC)  ? plic_req_ready_i  :
                                    (tgt_q == TGT_UART)  ? uart_req_ready_i  : 1'b1;

    wire selected_slave_rsp_valid = (tgt_q == TGT_CLINT) ? clint_rsp_valid_i :
                                    (tgt_q == TGT_PLIC)  ? plic_rsp_valid_i  :
                                    (tgt_q == TGT_UART)  ? uart_rsp_valid_i  : 1'b1;

    wire [63:0] selected_slave_rsp_data =
        (tgt_q == TGT_CLINT) ? clint_rsp_data_i :
        (tgt_q == TGT_PLIC)  ? plic_rsp_data_i  :
        (tgt_q == TGT_UART)  ? {uart_rsp_data_i[31:0], uart_rsp_data_i[31:0]} : 64'd0;

    wire selected_slave_rsp_error =
        (tgt_q == TGT_CLINT) ? clint_rsp_error_i :
        (tgt_q == TGT_PLIC)  ? plic_rsp_error_i  :
        (tgt_q == TGT_UART)  ? uart_rsp_error_i  : 1'b1;

    assign clint_rsp_ready_o = (state_q == XBAR_WAIT_RSP) && (tgt_q == TGT_CLINT);
    assign plic_rsp_ready_o  = (state_q == XBAR_WAIT_RSP) && (tgt_q == TGT_PLIC);
    assign uart_rsp_ready_o  = (state_q == XBAR_WAIT_RSP) && (tgt_q == TGT_UART);

    // Registered response outputs back to harts
    assign mmio_rsp_valid_o = hart_rsp_valid_q;
    always_comb begin
        for (int h = 0; h < NUM_HARTS; h++) begin
            mmio_rsp_rdata_o[h] = hart_rsp_valid_q[h] ? hart_rsp_rdata_q : 64'd0;
            mmio_rsp_error_o[h] = hart_rsp_valid_q[h] ? hart_rsp_error_q : 1'b0;
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q           <= XBAR_IDLE;
            rr_ptr_q          <= '0;
            active_hart_q     <= '0;
            tgt_q             <= TGT_CLINT;
            slave_req_valid_q <= 1'b0;
            slave_req_store_q <= 1'b0;
            slave_req_addr_q  <= 64'd0;
            slave_req_size_q  <= 3'd0;
            slave_req_wdata_q <= 64'd0;
            hart_rsp_valid_q  <= '0;
            hart_rsp_rdata_q  <= 64'd0;
            hart_rsp_error_q  <= 1'b0;
        end else begin
            case (state_q)
                XBAR_IDLE: begin
                    if (win_found) begin
                        active_hart_q     <= win_hart;
                        rr_ptr_q          <= HART_W'((int'(win_hart) + 1) % int'(NUM_HARTS));
                        tgt_q             <= win_tgt;
                        slave_req_valid_q <= (win_tgt != TGT_UNMAPPED);
                        slave_req_store_q <= mmio_req_is_store_i[win_hart];
                        slave_req_addr_q  <= mmio_req_addr_i[win_hart];
                        slave_req_size_q  <= mmio_req_size_i[win_hart];
                        slave_req_wdata_q <= mmio_req_wdata_i[win_hart];
                        if (win_tgt == TGT_UNMAPPED) begin
                            hart_rsp_valid_q[win_hart] <= 1'b1;
                            hart_rsp_rdata_q           <= 64'd0;
                            hart_rsp_error_q           <= 1'b1;
                            state_q                    <= XBAR_HART_RSP;
                        end else begin
                            state_q <= XBAR_SLAVE_REQ;
                        end
                    end
                end

                XBAR_SLAVE_REQ: begin
                    if (selected_slave_req_ready) begin
                        slave_req_valid_q <= 1'b0;
                        state_q           <= XBAR_WAIT_RSP;
                    end
                end

                XBAR_WAIT_RSP: begin
                    if (selected_slave_rsp_valid) begin
                        hart_rsp_valid_q[active_hart_q] <= 1'b1;
                        hart_rsp_rdata_q                <= selected_slave_rsp_data;
                        hart_rsp_error_q                <= selected_slave_rsp_error;
                        state_q                         <= XBAR_HART_RSP;
                    end
                end

                XBAR_HART_RSP: begin
                    if (mmio_rsp_ready_i[active_hart_q]) begin
                        hart_rsp_valid_q[active_hart_q] <= 1'b0;
                        hart_rsp_error_q                <= 1'b0;
                        state_q                         <= XBAR_IDLE;
                    end
                end

                default: begin
                    state_q <= XBAR_IDLE;
                end
            endcase
        end
    end

endmodule

`endif // FURSOY_S2_MMIO_XBAR_SV
