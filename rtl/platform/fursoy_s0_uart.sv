// Lite-16550A MMIO UART for Fursoy CPU (Slice-0 single-hart platform)
// Normative specification: docs/architecture/platform-sbi-v1.md (frozen v1)
// - Base Address: 0x1000_0000, Aperture: 4 KiB (0x1000_0000 - 0x1000_0FFF)
// - Access model: 32-bit naturally aligned MMIO only (reg-shift=2, reg-io-width=4)
// - DLAB divisor latches (DLL at 0x00, DLM at 0x04 when LCR[7]==1) with zero TX emission
// - Deterministic non-FIFO mode (IIR[7:6] = 2'b00, FCR writes ignored)
// - Active-high level-sensitive IRQ routed to PLIC source 1

module fursoy_s0_uart #(
    parameter logic [63:0] BASE_ADDR = 64'h0000_0000_1000_0000
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

    // Console TX emit interface (for simulation & platform capture)
    output logic        tx_valid_o,
    output logic [7:0]  tx_data_o,

    // External interrupt line (to PLIC Source 1)
    output logic        irq_o
);

    localparam logic [63:0] APERTURE_SIZE = 64'h1000; // 4 KiB
    localparam logic [63:0] END_ADDR      = BASE_ADDR + APERTURE_SIZE;

    // Storage registers
    logic [7:0] dll_q;      // Divisor Latch LSB (DLAB=1, offset 0x00)
    logic [7:0] dlm_q;      // Divisor Latch MSB (DLAB=1, offset 0x04)
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] ier_q;      // Interrupt Enable Register (DLAB=0, offset 0x04)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0] lcr_q;      // Line Control Register (offset 0x0C)
    logic [7:0] mcr_q;      // Modem Control Register (offset 0x10)
    logic [7:0] scr_q;      // Scratch Register (offset 0x1C)
    logic       thrempty_irq_pending_q; // THRE interrupt pending flag
    logic [7:0] tx_timer_q;             // TX transmission delay counter for THRE IRQ

    // Response registers
    logic        rsp_valid_q;
    logic        rsp_error_q;
    logic [31:0] rsp_data_q;

    // Address decoding
    logic in_aperture;
    logic [11:0] reg_offset;
    logic valid_alignment;
    logic valid_size;
    logic valid_access;
    logic req_fire;

    assign in_aperture     = (req_addr_i >= BASE_ADDR) && (req_addr_i < END_ADDR);
    assign reg_offset      = req_addr_i[11:0];
    assign valid_alignment = (req_addr_i[1:0] == 2'b00);
    assign valid_size      = (req_size_i == 3'd2); // Strict 32-bit naturally aligned access
    assign valid_access    = in_aperture && valid_alignment && valid_size;

    assign req_ready_o     = !rsp_valid_q;
    assign req_fire        = req_valid_i && req_ready_o;
    assign access_error_o  = req_fire && !valid_access;

    assign rsp_valid_o     = rsp_valid_q;
    assign rsp_error_o     = rsp_error_q;
    assign rsp_data_o      = {32'b0, rsp_data_q};

    // Interrupt generation (active-high level-sensitive)
    // In v1, RX data ready is 0. THRE interrupt fires when IER[1]==1 and pending.
    assign irq_o = ier_q[1] && thrempty_irq_pending_q;

    // Read mux
    logic [7:0] read_byte;
    always_comb begin
        read_byte = 8'h00;
        if (valid_access) begin
            case (reg_offset)
                12'h000: begin
                    if (lcr_q[7]) read_byte = dll_q; // DLL when DLAB=1
                    else          read_byte = 8'h00; // RBR when DLAB=0 (empty)
                end
                12'h004: begin
                    if (lcr_q[7]) read_byte = dlm_q; // DLM when DLAB=1
                    else          read_byte = {4'b0, ier_q[3:0]}; // IER
                end
                12'h008: begin
                    // IIR: bits 7:6=00 (non-FIFO), bit 3=0, bits 2:1=ID, bit 0=no_pending
                    if (irq_o) read_byte = 8'h02; // THRE interrupt pending (bit 0=0)
                    else       read_byte = 8'h01; // No interrupt pending (bit 0=1)
                end
                12'h00C: read_byte = lcr_q;
                12'h010: read_byte = mcr_q;
                12'h014: read_byte = 8'h60; // LSR: THRE=1 (bit 5), TEMT=1 (bit 6), DR=0
                12'h018: read_byte = 8'h00; // MSR: all lines inactive
                12'h01C: read_byte = scr_q;
                default: read_byte = 8'h00; // Unimplemented aperture offsets read as 0
            endcase
        end
    end

    // Sequential state updates
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            dll_q                  <= 8'h00;
            dlm_q                  <= 8'h00;
            ier_q                  <= 8'h00;
            lcr_q                  <= 8'h03; // 8 data bits, 1 stop bit, no parity; DLAB=0
            mcr_q                  <= 8'h00;
            scr_q                  <= 8'h00;
            thrempty_irq_pending_q <= 1'b0;
            tx_timer_q             <= 8'h00;
            rsp_valid_q            <= 1'b0;
            rsp_error_q            <= 1'b0;
            rsp_data_q             <= 32'h0;
            tx_valid_o             <= 1'b0;
            tx_data_o              <= 8'h00;
        end else begin
            // Clear single-cycle TX pulse
            tx_valid_o <= 1'b0;

            // Decrement TX transmission timer for THRE interrupt generation
            if (tx_timer_q > 8'd0) begin
                tx_timer_q <= tx_timer_q - 8'd1;
                if (tx_timer_q == 8'd1 && ier_q[1]) begin
                    thrempty_irq_pending_q <= 1'b1;
                end
            end

            // Clear response handshake
            if (rsp_valid_q && rsp_ready_i) begin
                rsp_valid_q <= 1'b0;
                rsp_error_q <= 1'b0;
            end

            // Process request
            if (req_fire) begin
                rsp_valid_q <= 1'b1;
                if (!valid_access) begin
                    rsp_error_q <= 1'b1;
                    rsp_data_q  <= 32'h0;
                end else begin
                    rsp_error_q <= 1'b0;
                    if (req_store_i) begin
                        rsp_data_q <= 32'h0;
                        case (reg_offset)
                            12'h000: begin
                                if (lcr_q[7]) begin
                                    dll_q <= req_store_data_i[7:0];
                                end else begin
                                    // Accepted THR store emits character
                                    tx_valid_o <= 1'b1;
                                    tx_data_o  <= req_store_data_i[7:0];
                                    // Writing THR clears THRE interrupt and starts TX timer
                                    thrempty_irq_pending_q <= 1'b0;
                                    tx_timer_q <= 8'd64;
                                end
                            end
                            12'h004: begin
                                if (lcr_q[7]) dlm_q <= req_store_data_i[7:0];
                                else begin
                                    ier_q <= req_store_data_i[7:0];
                                    // If ETBEI enabled from 0 to 1, flag pending
                                    if (req_store_data_i[1] && !ier_q[1])
                                         thrempty_irq_pending_q <= 1'b1;
                                    else if (!req_store_data_i[1]) begin
                                         thrempty_irq_pending_q <= 1'b0;
                                         tx_timer_q <= 8'd0;
                                    end
                                end
                            end
                            12'h008: begin
                                // FCR write: accepted and ignored per frozen contract
                            end
                            12'h00C: lcr_q <= req_store_data_i[7:0];
                            12'h010: mcr_q <= req_store_data_i[7:0];
                            12'h014: begin /* LSR is read-only; writes ignored */ end
                            12'h018: begin /* MSR is read-only; writes ignored */ end
                            12'h01C: scr_q <= req_store_data_i[7:0];
                            default: begin /* Unimplemented offsets: writes ignored */ end
                        endcase
                    end else begin
                        // Load access
                        rsp_data_q <= {24'b0, read_byte};
                        // Reading IIR clears pending THRE interrupt
                        if (reg_offset == 12'h008) begin
                            thrempty_irq_pending_q <= 1'b0;
                        end
                    end
                end
            end
        end
    end

    // =========================================================================
    // Safety Assertions
    // =========================================================================
    // pragma translate_off
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            // Invariant 4: Reset state has zero TX emission
            assert (!tx_valid_o)
                else $fatal(1, "UART: TX emitted while reset asserted");
        end else if ($past(!rst_i)) begin
            // Invariant 1: TX emission occurs ONLY from accepted store to offset 0x00 with DLAB=0
            if (tx_valid_o) begin
                assert ($past(req_fire && req_store_i && valid_access && (reg_offset == 12'h000) && !lcr_q[7]))
                    else $fatal(1, "UART: TX emitted without accepted THR write or while DLAB=1");
            end

            // Invariant 2: DLAB=1 writes must NEVER emit TX data
            if ($past(lcr_q[7] && req_fire && req_store_i)) begin
                assert (!tx_valid_o)
                    else $fatal(1, "UART: Spurious TX emission during DLAB=1 write");
            end

            // Invariant 3: Invalid/rejected access must never emit TX data
            if ($past(req_fire && !valid_access)) begin
                assert (!tx_valid_o)
                    else $fatal(1, "UART: TX emitted on rejected/invalid access");
            end
        end
    end
    // pragma translate_on

endmodule
