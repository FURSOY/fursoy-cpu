`ifndef FURSOY_S2_SOC_SV
`define FURSOY_S2_SOC_SV

// =============================================================================
// Fursoy Slice-2 SMP Multi-Core SoC Top-Level — Coherent Dual/Quad Architecture
// =============================================================================
// Specification authority: docs/architecture/slice2-smp-v1.md §1, §2, §4, §5, §6
// - Parameterized NUM_HARTS (default 2, tested 2 & 4) & SMP_COHERENCE_EN (default 1).
// - Instantiates NUM_HARTS copies of fursoy_s1_core (mhartid_i = 64'(h)).
// - Integrates fursoy_s2_coherence_mgr + inclusive fursoy_s2_l2 (256 KiB, 8-way),
//   fursoy_s2_mmio_xbar, fursoy_s2_clint, fursoy_s2_plic, fursoy_s0_uart.
// - Routes coherent L1D, L1I, and PTW transactions through fursoy_s2_coherence_mgr
//   with non-coherent round-robin fallback when SMP_COHERENCE_EN = 0.
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_core.sv"
`include "fursoy_s2_clint.sv"
`include "fursoy_s2_plic.sv"
`include "fursoy_s0_uart.sv"
`include "fursoy_s2_mmio_xbar.sv"
`include "fursoy_s2_coherence_mgr.sv"

module fursoy_s2_soc
    import fursoy_s1_pkg::*;
#(
    parameter int unsigned NUM_HARTS        = 2,
    parameter bit          SMP_COHERENCE_EN = 1'b1,
    parameter logic [63:0] DRAM_BASE_ADDR   = 64'h0000_0000_8000_0000,
    parameter logic [63:0] DRAM_SIZE        = 64'h0000_0000_1000_0000, // 256 MB
    parameter logic [63:0] CLINT_BASE_ADDR  = 64'h0000_0000_0200_0000,
    parameter logic [63:0] PLIC_BASE_ADDR   = 64'h0000_0000_0C00_0000,
    parameter logic [63:0] UART_BASE_ADDR   = 64'h0000_0000_1000_0000,
    localparam int unsigned HART_W          = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1
) (
    input  logic                  clk_i,
    input  logic                  rst_i,
    input  logic                  frontend_en_i,

    // External Interrupts & Console TX
    input  logic [31:0]           irq_sources_i,
    input  logic [NUM_HARTS-1:0]  irq_external_i,
    output logic                  uart_tx_valid_o,
    output logic [7:0]            uart_tx_data_o,

    // External 256 MB DRAM Controller Interface (512-bit lines)
    output logic                  dram_req_valid_o,
    input  logic                  dram_req_ready_i,
    output logic                  dram_req_write_o,
    output logic [49:0]           dram_req_addr_o,
    output logic [511:0]          dram_req_wdata_o,
    output logic [HART_W-1:0]     dram_req_hart_o,
    output logic [2:0]            dram_req_mid_o,
    output logic [1:0]            dram_req_tag_o,

    input  logic                  dram_rd_rsp_valid_i,
    output logic                  dram_rd_rsp_ready_o,
    input  logic [HART_W-1:0]     dram_rd_rsp_hart_i,
    input  logic [2:0]            dram_rd_rsp_mid_i,
    input  logic [1:0]            dram_rd_rsp_tag_i,
    input  logic [511:0]          dram_rd_rsp_data_i,
    input  logic                  dram_rd_rsp_error_i,

    input  logic                  dram_wr_rsp_valid_i,
    input  logic [HART_W-1:0]     dram_wr_rsp_hart_i,

    // Per-Hart Architectural & Interrupt Observability
    output logic [1:0]            retire_valid_o     [NUM_HARTS],
    output logic [63:0]           retire_pc_o        [NUM_HARTS][1:0],
    output logic [NUM_HARTS-1:0]  retire_exception_o,
    output logic [1:0]            csr_priv_mode_o    [NUM_HARTS],
    output logic [63:0]           csr_mstatus_o      [NUM_HARTS],
    output logic [63:0]           csr_mie_o          [NUM_HARTS],
    output logic [63:0]           csr_mip_o          [NUM_HARTS],
    output logic [63:0]           csr_mcause_o       [NUM_HARTS],
    output logic [63:0]           csr_mepc_o         [NUM_HARTS],
    output logic [63:0]           csr_scause_o       [NUM_HARTS],
    output logic [63:0]           csr_sepc_o         [NUM_HARTS],
    output logic [NUM_HARTS-1:0]  wfi_sleep_o,
    output logic [63:0]           mcycle_o           [NUM_HARTS],
    output logic [63:0]           minstret_o         [NUM_HARTS],

    // Diagnostic Interrupt Exports
    output logic [NUM_HARTS-1:0]  diag_irq_timer_o,
    output logic [NUM_HARTS-1:0]  diag_irq_software_o,
    output logic [NUM_HARTS-1:0]  diag_irq_external_o,
    output logic [NUM_HARTS-1:0]  diag_irq_seip_o,
    output logic                  diag_uart_irq_o
);

    localparam logic [63:0] DRAM_END_ADDR = DRAM_BASE_ADDR + DRAM_SIZE;

    localparam logic [2:0] MID_L1I    = 3'd0;
    localparam logic [2:0] MID_L1D_RD = 3'd1;
    localparam logic [2:0] MID_L1D_WR = 3'd2;
    localparam logic [2:0] MID_PTW    = 3'd3;
    localparam logic [2:0] MID_NONE   = 3'd7;

    // =========================================================================
    // 1. Per-Hart Core Memory & MMIO Arrays
    // =========================================================================
    logic [NUM_HARTS-1:0] l1i_bus_rd_req_valid;
    logic [49:0]          l1i_bus_rd_req_addr  [NUM_HARTS];
    logic [1:0]           l1i_bus_rd_req_tag   [NUM_HARTS];
    logic [NUM_HARTS-1:0] l1i_bus_rd_req_ready;
    logic [NUM_HARTS-1:0] l1i_bus_rd_rsp_valid;
    logic [1:0]           l1i_bus_rd_rsp_tag   [NUM_HARTS];
    logic [511:0]         l1i_bus_rd_rsp_data  [NUM_HARTS];
    logic [NUM_HARTS-1:0] l1i_bus_rd_rsp_error;

    logic [NUM_HARTS-1:0] bus_rd_req_valid;
    logic [49:0]          bus_rd_req_addr      [NUM_HARTS];
    mshr_idx_t            bus_rd_req_tag       [NUM_HARTS];
    coh_req_op_t          bus_rd_req_op        [NUM_HARTS];
    logic [NUM_HARTS-1:0] bus_rd_req_ready;
    logic [NUM_HARTS-1:0] bus_rd_rsp_valid;
    mshr_idx_t            bus_rd_rsp_tag       [NUM_HARTS];
    logic [511:0]         bus_rd_rsp_data      [NUM_HARTS];
    mesi_state_t          bus_rd_rsp_state     [NUM_HARTS];
    logic [NUM_HARTS-1:0] bus_rd_rsp_has_data;

    logic [NUM_HARTS-1:0] bus_wr_req_valid;
    logic [49:0]          bus_wr_req_addr      [NUM_HARTS];
    logic [511:0]         bus_wr_req_data      [NUM_HARTS];
    logic [NUM_HARTS-1:0] bus_wr_req_dirty;
    logic [NUM_HARTS-1:0] bus_wr_req_ready;
    logic [NUM_HARTS-1:0] bus_wr_rsp_valid;

    logic [NUM_HARTS-1:0] snoop_req_valid;
    logic [49:0]          snoop_req_addr       [NUM_HARTS];
    logic [1:0]           snoop_req_type       [NUM_HARTS];
    logic [NUM_HARTS-1:0] snoop_req_ready;
    logic [NUM_HARTS-1:0] snoop_rsp_valid;
    logic [NUM_HARTS-1:0] snoop_rsp_has_data;
    logic [NUM_HARTS-1:0] snoop_rsp_was_dirty;
    logic [511:0]         snoop_rsp_data       [NUM_HARTS];
    logic [NUM_HARTS-1:0] snoop_rsp_ready;
    logic [NUM_HARTS-1:0] snoop_rsp_ack_only;

    logic                 l1i_inval_line_valid;
    logic [49:0]          l1i_inval_line_addr;

    logic [NUM_HARTS-1:0] ptw_mem_req_valid;
    logic [55:0]          ptw_mem_req_addr     [NUM_HARTS];
    logic [NUM_HARTS-1:0] ptw_mem_req_ready;
    logic [NUM_HARTS-1:0] ptw_mem_rsp_valid;
    logic [63:0]          ptw_mem_rsp_data     [NUM_HARTS];
    logic [NUM_HARTS-1:0] ptw_mem_rsp_error;

    logic [NUM_HARTS-1:0] mmio_req_valid;
    logic [63:0]          mmio_req_addr        [NUM_HARTS];
    logic [NUM_HARTS-1:0] mmio_req_is_store;
    logic [2:0]           mmio_req_size        [NUM_HARTS];
    logic [63:0]          mmio_req_wdata       [NUM_HARTS];
    logic [7:0]           mmio_req_wstrb       [NUM_HARTS];
    logic [NUM_HARTS-1:0] mmio_req_ready;
    logic [NUM_HARTS-1:0] mmio_rsp_valid;
    logic [63:0]          mmio_rsp_rdata       [NUM_HARTS];
    logic [NUM_HARTS-1:0] mmio_rsp_error;
    logic [NUM_HARTS-1:0] mmio_rsp_ready;

    // =========================================================================
    // 2. Platform Peripherals (CLINT, PLIC, UART16550) & Registered MMIO Xbar
    // =========================================================================
    logic [NUM_HARTS-1:0] clint_irq_software;
    logic [NUM_HARTS-1:0] clint_irq_timer;
    logic [63:0]          clint_mtime;
    logic [NUM_HARTS-1:0] plic_irq_meip;
    logic [NUM_HARTS-1:0] plic_irq_seip;
    logic                 uart_irq;

    logic [NUM_HARTS-1:0] core_irq_external;
    assign core_irq_external = plic_irq_meip | irq_external_i;

    assign diag_irq_timer_o    = clint_irq_timer;
    assign diag_irq_software_o = clint_irq_software;
    assign diag_irq_external_o = core_irq_external;
    assign diag_irq_seip_o     = plic_irq_seip;
    assign diag_uart_irq_o     = uart_irq;

    // Xbar <-> Slave wires
    logic        clint_req_valid, clint_req_ready, clint_req_store;
    logic [63:0] clint_req_addr, clint_req_wdata, clint_rsp_data;
    logic [2:0]  clint_req_size;
    logic        clint_rsp_valid, clint_rsp_ready, clint_rsp_error;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        clint_access_error;
    /* verilator lint_on UNUSEDSIGNAL */

    logic        plic_req_valid, plic_req_ready, plic_req_store;
    logic [63:0] plic_req_addr, plic_req_wdata, plic_rsp_data;
    logic [2:0]  plic_req_size;
    logic        plic_rsp_valid, plic_rsp_ready, plic_rsp_error;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        plic_access_error;
    /* verilator lint_on UNUSEDSIGNAL */

    logic        uart_req_valid, uart_req_ready, uart_req_store;
    logic [63:0] uart_req_addr, uart_req_wdata, uart_rsp_data;
    logic [2:0]  uart_req_size;
    logic        uart_rsp_valid, uart_rsp_ready, uart_rsp_error;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        uart_access_error;
    /* verilator lint_on UNUSEDSIGNAL */

    fursoy_s2_mmio_xbar #(
        .NUM_HARTS       (NUM_HARTS),
        .CLINT_BASE_ADDR (CLINT_BASE_ADDR),
        .PLIC_BASE_ADDR  (PLIC_BASE_ADDR),
        .UART_BASE_ADDR  (UART_BASE_ADDR)
    ) u_mmio_xbar (
        .clk_i              (clk_i),
        .rst_i              (rst_i),
        .mmio_req_valid_i   (mmio_req_valid),
        .mmio_req_addr_i    (mmio_req_addr),
        .mmio_req_is_store_i(mmio_req_is_store),
        .mmio_req_size_i    (mmio_req_size),
        .mmio_req_wdata_i   (mmio_req_wdata),
        .mmio_req_wstrb_i   (mmio_req_wstrb),
        .mmio_req_ready_o   (mmio_req_ready),
        .mmio_rsp_valid_o   (mmio_rsp_valid),
        .mmio_rsp_rdata_o   (mmio_rsp_rdata),
        .mmio_rsp_error_o   (mmio_rsp_error),
        .mmio_rsp_ready_i   (mmio_rsp_ready),

        .clint_req_valid_o  (clint_req_valid),
        .clint_req_ready_i  (clint_req_ready),
        .clint_req_store_o  (clint_req_store),
        .clint_req_addr_o   (clint_req_addr),
        .clint_req_size_o   (clint_req_size),
        .clint_req_wdata_o  (clint_req_wdata),
        .clint_rsp_valid_i  (clint_rsp_valid),
        .clint_rsp_ready_o  (clint_rsp_ready),
        .clint_rsp_data_i   (clint_rsp_data),
        .clint_rsp_error_i  (clint_rsp_error),

        .plic_req_valid_o   (plic_req_valid),
        .plic_req_ready_i   (plic_req_ready),
        .plic_req_store_o   (plic_req_store),
        .plic_req_addr_o    (plic_req_addr),
        .plic_req_size_o    (plic_req_size),
        .plic_req_wdata_o   (plic_req_wdata),
        .plic_rsp_valid_i   (plic_rsp_valid),
        .plic_rsp_ready_o   (plic_rsp_ready),
        .plic_rsp_data_i    (plic_rsp_data),
        .plic_rsp_error_i   (plic_rsp_error),

        .uart_req_valid_o   (uart_req_valid),
        .uart_req_ready_i   (uart_req_ready),
        .uart_req_store_o   (uart_req_store),
        .uart_req_addr_o    (uart_req_addr),
        .uart_req_size_o    (uart_req_size),
        .uart_req_wdata_o   (uart_req_wdata),
        .uart_rsp_valid_i   (uart_rsp_valid),
        .uart_rsp_ready_o   (uart_rsp_ready),
        .uart_rsp_data_i    (uart_rsp_data),
        .uart_rsp_error_i   (uart_rsp_error)
    );

    fursoy_s2_clint #(
        .BASE_ADDR (CLINT_BASE_ADDR),
        .NUM_HARTS (NUM_HARTS)
    ) u_clint (
        .clk_i            (clk_i),
        .rst_i            (rst_i),
        .req_valid_i      (clint_req_valid),
        .req_ready_o      (clint_req_ready),
        .req_store_i      (clint_req_store),
        .req_addr_i       (clint_req_addr),
        .req_size_i       (clint_req_size),
        .req_store_data_i (clint_req_wdata),
        .rsp_valid_o      (clint_rsp_valid),
        .rsp_ready_i      (clint_rsp_ready),
        .rsp_data_o       (clint_rsp_data),
        .rsp_error_o      (clint_rsp_error),
        .access_error_o   (clint_access_error),
        .irq_software_o   (clint_irq_software),
        .irq_timer_o      (clint_irq_timer),
        .mtime_o          (clint_mtime)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_irq_sources = &{1'b0, irq_sources_i[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] plic_irq_sources = {irq_sources_i[31:2], uart_irq, 1'b0};

    fursoy_s2_plic #(
        .BASE_ADDR (PLIC_BASE_ADDR),
        .NUM_HARTS (NUM_HARTS)
    ) u_plic (
        .clk_i            (clk_i),
        .rst_i            (rst_i),
        .req_valid_i      (plic_req_valid),
        .req_ready_o      (plic_req_ready),
        .req_store_i      (plic_req_store),
        .req_addr_i       (plic_req_addr),
        .req_size_i       (plic_req_size),
        .req_store_data_i (plic_req_wdata),
        .rsp_valid_o      (plic_rsp_valid),
        .rsp_ready_i      (plic_rsp_ready),
        .rsp_data_o       (plic_rsp_data),
        .rsp_error_o      (plic_rsp_error),
        .access_error_o   (plic_access_error),
        .irq_sources_i    (plic_irq_sources),
        .irq_meip_o       (plic_irq_meip),
        .irq_seip_o       (plic_irq_seip)
    );

    fursoy_s0_uart #(.BASE_ADDR(UART_BASE_ADDR)) u_uart (
        .clk_i            (clk_i),
        .rst_i            (rst_i),
        .req_valid_i      (uart_req_valid),
        .req_ready_o      (uart_req_ready),
        .req_store_i      (uart_req_store),
        .req_addr_i       (uart_req_addr),
        .req_size_i       (uart_req_size),
        .req_store_data_i (uart_req_wdata),
        .rsp_valid_o      (uart_rsp_valid),
        .rsp_ready_i      (uart_rsp_ready),
        .rsp_data_o       (uart_rsp_data),
        .rsp_error_o      (uart_rsp_error),
        .access_error_o   (uart_access_error),
        .tx_valid_o       (uart_tx_valid_o),
        .tx_data_o        (uart_tx_data_o),
        .irq_o            (uart_irq)
    );

    // =========================================================================
    // 3. Per-Hart Unmapped Handlers & Coherence Hub / Non-Coherent Arbiter
    // =========================================================================
    logic [NUM_HARTS-1:0] ptw_dram_req, l1i_dram_req, l1d_rd_dram_req, l1d_wr_dram_req;
    logic [NUM_HARTS-1:0] l1i_unmapped_rsp_q, ptw_unmapped_rsp_q;
    logic [1:0]           l1i_unmapped_tag_q [NUM_HARTS];
    logic [2:0]           ptw_word_idx_q     [NUM_HARTS];

    if (SMP_COHERENCE_EN) begin : gen_coherence
        logic [NUM_HARTS-1:0] l1i_coh_req_ready;
        logic [NUM_HARTS-1:0] l1i_coh_rsp_valid;
        logic [1:0]           l1i_coh_rsp_tag   [NUM_HARTS];
        logic [511:0]         l1i_coh_rsp_data  [NUM_HARTS];
        logic [NUM_HARTS-1:0] l1i_coh_rsp_error;
        logic [49:0]          ptw_coh_req_addr  [NUM_HARTS];
        logic [NUM_HARTS-1:0] ptw_coh_req_ready;
        logic [NUM_HARTS-1:0] ptw_coh_rsp_valid;
        logic [511:0]         ptw_coh_rsp_data  [NUM_HARTS];
        logic [NUM_HARTS-1:0] ptw_coh_rsp_error;
        logic [NUM_HARTS-1:0] ptw_coh_rsp_valid_q;
        logic [63:0]          ptw_coh_rsp_data64_q [NUM_HARTS];
        logic [NUM_HARTS-1:0] ptw_coh_rsp_error_q;

        for (genvar h = 0; h < NUM_HARTS; h++) begin : gen_mem_decode_coh
            wire [63:0] l1i_byte_addr = {8'b0, l1i_bus_rd_req_addr[h], 6'b0};
            wire        l1i_pmp_deny  = (csr_priv_mode_o[h] != 2'b11) &&
                                        (l1i_byte_addr >= DRAM_BASE_ADDR) &&
                                        (l1i_byte_addr < (DRAM_BASE_ADDR + 64'h20_0000));
            wire        l1i_in_dram   = (l1i_byte_addr >= DRAM_BASE_ADDR) && (l1i_byte_addr < DRAM_END_ADDR) && !l1i_pmp_deny;
            wire        l1i_unmapped  = l1i_bus_rd_req_valid[h] && !l1i_in_dram;

            wire [63:0] ptw_byte_addr = {8'h0, ptw_mem_req_addr[h]};
            wire        ptw_in_dram   = (ptw_byte_addr >= DRAM_BASE_ADDR) && (ptw_byte_addr < DRAM_END_ADDR);
            wire        ptw_unmapped  = ptw_mem_req_valid[h] && !ptw_in_dram;

            assign ptw_dram_req[h]     = ptw_mem_req_valid[h] && ptw_in_dram;
            assign ptw_coh_req_addr[h] = ptw_mem_req_addr[h][55:6];
            assign l1i_dram_req[h]     = l1i_bus_rd_req_valid[h] && l1i_in_dram;
            assign l1d_rd_dram_req[h]  = bus_rd_req_valid[h];
            assign l1d_wr_dram_req[h]  = bus_wr_req_valid[h];

            wire l1i_unmapped_fire = l1i_unmapped && !l1i_unmapped_rsp_q[h];
            wire ptw_unmapped_fire = ptw_unmapped && !ptw_unmapped_rsp_q[h];

            always_ff @(posedge clk_i) begin
                if (rst_i) begin
                    l1i_unmapped_rsp_q[h]   <= 1'b0;
                    l1i_unmapped_tag_q[h]   <= 2'b0;
                    ptw_unmapped_rsp_q[h]   <= 1'b0;
                    ptw_word_idx_q[h]       <= 3'd0;
                    ptw_coh_rsp_valid_q[h]  <= 1'b0;
                    ptw_coh_rsp_data64_q[h] <= 64'h0;
                    ptw_coh_rsp_error_q[h]  <= 1'b0;
                end else begin
                    // Never drop an in-flight Hub grant arriving simultaneously with an unmapped response
                    if (l1i_unmapped_fire) begin
                        l1i_unmapped_rsp_q[h] <= 1'b1;
                        l1i_unmapped_tag_q[h] <= l1i_bus_rd_req_tag[h];
                    end else if (l1i_unmapped_rsp_q[h] && !l1i_coh_rsp_valid[h]) begin
                        l1i_unmapped_rsp_q[h] <= 1'b0;
                    end

                    if (ptw_unmapped_fire) begin
                        ptw_unmapped_rsp_q[h] <= 1'b1;
                    end else if (ptw_unmapped_rsp_q[h] && !ptw_coh_rsp_valid_q[h]) begin
                        ptw_unmapped_rsp_q[h] <= 1'b0;
                    end

                    if (ptw_dram_req[h] && ptw_coh_req_ready[h]) begin
                        ptw_word_idx_q[h] <= ptw_mem_req_addr[h][5:3];
                    end

                    // Isolate 512b->64b PTW word-slice mux on a local register for 500 MHz timing closure
                    ptw_coh_rsp_valid_q[h] <= ptw_coh_rsp_valid[h];
                    if (ptw_coh_rsp_valid[h]) begin
                        ptw_coh_rsp_data64_q[h] <= ptw_coh_rsp_data[h][ptw_word_idx_q[h] * 64 +: 64];
                        ptw_coh_rsp_error_q[h]  <= ptw_coh_rsp_error[h];
                    end
                end
            end

            assign l1i_bus_rd_req_ready[h] = l1i_unmapped ? l1i_unmapped_fire : l1i_coh_req_ready[h];
            assign ptw_mem_req_ready[h]    = ptw_unmapped ? ptw_unmapped_fire : ptw_coh_req_ready[h];

            assign l1i_bus_rd_rsp_valid[h] = l1i_coh_rsp_valid[h] || l1i_unmapped_rsp_q[h];
            assign l1i_bus_rd_rsp_tag[h]   = l1i_coh_rsp_valid[h] ? l1i_coh_rsp_tag[h]   : l1i_unmapped_tag_q[h];
            assign l1i_bus_rd_rsp_data[h]  = l1i_coh_rsp_valid[h] ? l1i_coh_rsp_data[h]  : 512'h0;
            assign l1i_bus_rd_rsp_error[h] = l1i_coh_rsp_valid[h] ? l1i_coh_rsp_error[h] : 1'b1;

            assign ptw_mem_rsp_valid[h]    = ptw_coh_rsp_valid_q[h] || ptw_unmapped_rsp_q[h];
            assign ptw_mem_rsp_error[h]    = ptw_coh_rsp_valid_q[h] ? ptw_coh_rsp_error_q[h]  : 1'b1;
            assign ptw_mem_rsp_data[h]     = ptw_coh_rsp_valid_q[h] ? ptw_coh_rsp_data64_q[h] : 64'h0;
        end

        /* verilator lint_off UNUSEDSIGNAL */
        wire [HART_W-1:0] _unused_coh_dram_hart = dram_rd_rsp_hart_i ^ dram_wr_rsp_hart_i;
        wire [1:0]        _unused_coh_dram_mid  = dram_rd_rsp_mid_i[2:1];
        /* verilator lint_on UNUSEDSIGNAL */
        assign dram_req_hart_o = '0;

        fursoy_s2_coherence_mgr #(
            .NUM_HARTS      (NUM_HARTS),
            .L2_SETS        (512),
            .L2_WAYS        (8),
            .DIR_MSHR_DEPTH (8)
        ) u_coherence_mgr (
            .clk_i                 (clk_i),
            .rst_i                 (rst_i),

            .l1d_rd_req_valid_i    (l1d_rd_dram_req),
            .l1d_rd_req_addr_i     (bus_rd_req_addr),
            .l1d_rd_req_tag_i      (bus_rd_req_tag),
            .l1d_rd_req_op_i       (bus_rd_req_op),
            .l1d_rd_req_ready_o    (bus_rd_req_ready),
            .l1d_rd_rsp_valid_o    (bus_rd_rsp_valid),
            .l1d_rd_rsp_tag_o      (bus_rd_rsp_tag),
            .l1d_rd_rsp_data_o     (bus_rd_rsp_data),
            .l1d_rd_rsp_state_o    (bus_rd_rsp_state),
            .l1d_rd_rsp_has_data_o (bus_rd_rsp_has_data),

            .l1d_wr_req_valid_i    (l1d_wr_dram_req),
            .l1d_wr_req_addr_i     (bus_wr_req_addr),
            .l1d_wr_req_data_i     (bus_wr_req_data),
            .l1d_wr_req_dirty_i    (bus_wr_req_dirty),
            .l1d_wr_req_ready_o    (bus_wr_req_ready),
            .l1d_wr_rsp_valid_o    (bus_wr_rsp_valid),

            .snoop_req_valid_o     (snoop_req_valid),
            .snoop_req_addr_o      (snoop_req_addr),
            .snoop_req_type_o      (snoop_req_type),
            .snoop_req_ready_i     (snoop_req_ready),
            .snoop_rsp_valid_i     (snoop_rsp_valid),
            .snoop_rsp_has_data_i  (snoop_rsp_has_data),
            .snoop_rsp_data_i      (snoop_rsp_data),
            .snoop_rsp_was_dirty_i (snoop_rsp_was_dirty),
            .snoop_rsp_ack_only_i  (snoop_rsp_ack_only),
            .snoop_rsp_ready_o     (snoop_rsp_ready),

            .l1i_rd_req_valid_i    (l1i_dram_req),
            .l1i_rd_req_addr_i     (l1i_bus_rd_req_addr),
            .l1i_rd_req_tag_i      (l1i_bus_rd_req_tag),
            .l1i_rd_req_ready_o    (l1i_coh_req_ready),
            .l1i_rd_rsp_valid_o    (l1i_coh_rsp_valid),
            .l1i_rd_rsp_tag_o      (l1i_coh_rsp_tag),
            .l1i_rd_rsp_data_o     (l1i_coh_rsp_data),
            .l1i_rd_rsp_error_o    (l1i_coh_rsp_error),
            .l1i_inval_valid_o     (l1i_inval_line_valid),
            .l1i_inval_addr_o      (l1i_inval_line_addr),

            .ptw_rd_req_valid_i    (ptw_dram_req),
            .ptw_rd_req_addr_i     (ptw_coh_req_addr),
            .ptw_rd_req_ready_o    (ptw_coh_req_ready),
            .ptw_rd_rsp_valid_o    (ptw_coh_rsp_valid),
            .ptw_rd_rsp_data_o     (ptw_coh_rsp_data),
            .ptw_rd_rsp_error_o    (ptw_coh_rsp_error),

            .dram_req_valid_o      (dram_req_valid_o),
            .dram_req_ready_i      (dram_req_ready_i),
            .dram_req_write_o      (dram_req_write_o),
            .dram_req_addr_o       (dram_req_addr_o),
            .dram_req_wdata_o      (dram_req_wdata_o),
            .dram_req_mid_o        (dram_req_mid_o),
            .dram_req_tag_o        (dram_req_tag_o),
            .dram_rd_rsp_valid_i   (dram_rd_rsp_valid_i),
            .dram_rd_rsp_ready_o   (dram_rd_rsp_ready_o),
            .dram_rd_rsp_mid_i     (dram_rd_rsp_mid_i),
            .dram_rd_rsp_tag_i     (dram_rd_rsp_tag_i),
            .dram_rd_rsp_data_i    (dram_rd_rsp_data_i),
            .dram_rd_rsp_error_i   (dram_rd_rsp_error_i),
            .dram_wr_rsp_valid_i   (dram_wr_rsp_valid_i)
        );
    end else begin : gen_noncoherent
        /* verilator lint_off UNUSEDSIGNAL */
        logic [NUM_HARTS-1:0] _unused_nc_op;
        logic [NUM_HARTS-1:0] _unused_nc_dirty;
        logic [NUM_HARTS-1:0] _unused_nc_snoop;
        for (genvar u = 0; u < NUM_HARTS; u++) begin : gen_nc_tie
            assign _unused_nc_op[u]    = &{1'b0, bus_rd_req_op[u]};
            assign _unused_nc_dirty[u] = bus_wr_req_dirty[u];
            assign _unused_nc_snoop[u] = &{1'b0, snoop_req_ready[u], snoop_rsp_valid[u], snoop_rsp_has_data[u],
                                           snoop_rsp_was_dirty[u], snoop_rsp_data[u], snoop_rsp_ack_only[u]};
            assign bus_rd_rsp_state[u]    = MESI_I;
            assign bus_rd_rsp_has_data[u] = 1'b0;
            assign snoop_req_valid[u]     = 1'b0;
            assign snoop_req_addr[u]      = 50'd0;
            assign snoop_req_type[u]      = 2'd0;
            assign snoop_rsp_ready[u]     = 1'b1;
        end
        /* verilator lint_on UNUSEDSIGNAL */
        assign l1i_inval_line_valid = 1'b0;
        assign l1i_inval_line_addr  = 50'd0;

        for (genvar h = 0; h < NUM_HARTS; h++) begin : gen_mem_decode
            wire [63:0] l1i_byte_addr = {8'b0, l1i_bus_rd_req_addr[h], 6'b0};
            wire        l1i_pmp_deny  = (csr_priv_mode_o[h] != 2'b11) &&
                                        (l1i_byte_addr >= DRAM_BASE_ADDR) &&
                                        (l1i_byte_addr < (DRAM_BASE_ADDR + 64'h20_0000));
            wire        l1i_in_dram   = (l1i_byte_addr >= DRAM_BASE_ADDR) && (l1i_byte_addr < DRAM_END_ADDR) && !l1i_pmp_deny;
            wire        l1i_unmapped  = l1i_bus_rd_req_valid[h] && !l1i_in_dram;

            wire [63:0] ptw_byte_addr = {8'h0, ptw_mem_req_addr[h]};
            wire        ptw_in_dram   = (ptw_byte_addr >= DRAM_BASE_ADDR) && (ptw_byte_addr < DRAM_END_ADDR);
            wire        ptw_unmapped  = ptw_mem_req_valid[h] && !ptw_in_dram;

            assign ptw_dram_req[h]    = ptw_mem_req_valid[h] && ptw_in_dram;
            assign l1i_dram_req[h]    = l1i_bus_rd_req_valid[h] && l1i_in_dram;
            assign l1d_rd_dram_req[h] = bus_rd_req_valid[h];
            assign l1d_wr_dram_req[h] = bus_wr_req_valid[h];

            wire l1i_nc_dram_rsp = dram_rd_rsp_valid_i && (dram_rd_rsp_hart_i == HART_W'(h)) && (dram_rd_rsp_mid_i == MID_L1I);
            wire ptw_nc_dram_rsp = dram_rd_rsp_valid_i && (dram_rd_rsp_hart_i == HART_W'(h)) && (dram_rd_rsp_mid_i == MID_PTW);
            wire l1i_unmapped_fire = l1i_unmapped && !l1i_unmapped_rsp_q[h];
            wire ptw_unmapped_fire = ptw_unmapped && !ptw_unmapped_rsp_q[h];

            always_ff @(posedge clk_i) begin
                if (rst_i) begin
                    l1i_unmapped_rsp_q[h] <= 1'b0;
                    l1i_unmapped_tag_q[h] <= 2'b0;
                    ptw_unmapped_rsp_q[h] <= 1'b0;
                    ptw_word_idx_q[h]     <= 3'd0;
                end else begin
                    if (l1i_unmapped_fire) begin
                        l1i_unmapped_rsp_q[h] <= 1'b1;
                        l1i_unmapped_tag_q[h] <= l1i_bus_rd_req_tag[h];
                    end else if (l1i_unmapped_rsp_q[h] && !l1i_nc_dram_rsp) begin
                        l1i_unmapped_rsp_q[h] <= 1'b0;
                    end
                    if (ptw_unmapped_fire) begin
                        ptw_unmapped_rsp_q[h] <= 1'b1;
                    end else if (ptw_unmapped_rsp_q[h] && !ptw_nc_dram_rsp) begin
                        ptw_unmapped_rsp_q[h] <= 1'b0;
                    end

                    if (dram_req_valid_o && dram_req_ready_i && (dram_req_hart_o == HART_W'(h)) && (dram_req_mid_o == MID_PTW)) begin
                        ptw_word_idx_q[h] <= ptw_mem_req_addr[h][5:3];
                    end
                end
            end

            assign l1i_bus_rd_req_ready[h] = l1i_unmapped ? l1i_unmapped_fire :
                                             (dram_req_valid_o && dram_req_ready_i &&
                                              (dram_req_hart_o == HART_W'(h)) && (dram_req_mid_o == MID_L1I));
            assign ptw_mem_req_ready[h]    = ptw_unmapped ? ptw_unmapped_fire :
                                             (dram_req_valid_o && dram_req_ready_i &&
                                              (dram_req_hart_o == HART_W'(h)) && (dram_req_mid_o == MID_PTW));
            assign bus_rd_req_ready[h]     = dram_req_valid_o && dram_req_ready_i &&
                                             (dram_req_hart_o == HART_W'(h)) && (dram_req_mid_o == MID_L1D_RD);
            assign bus_wr_req_ready[h]     = dram_req_valid_o && dram_req_ready_i &&
                                             (dram_req_hart_o == HART_W'(h)) && (dram_req_mid_o == MID_L1D_WR);

            assign l1i_bus_rd_rsp_valid[h] = l1i_nc_dram_rsp || l1i_unmapped_rsp_q[h];
            assign l1i_bus_rd_rsp_tag[h]   = l1i_nc_dram_rsp ? dram_rd_rsp_tag_i : l1i_unmapped_tag_q[h];
            assign l1i_bus_rd_rsp_data[h]  = l1i_nc_dram_rsp ? dram_rd_rsp_data_i : 512'h0;
            assign l1i_bus_rd_rsp_error[h] = l1i_nc_dram_rsp ? dram_rd_rsp_error_i : 1'b1;

            assign bus_rd_rsp_valid[h]     = dram_rd_rsp_valid_i && (dram_rd_rsp_hart_i == HART_W'(h)) && (dram_rd_rsp_mid_i == MID_L1D_RD);
            assign bus_rd_rsp_tag[h]       = dram_rd_rsp_tag_i;
            assign bus_rd_rsp_data[h]      = dram_rd_rsp_data_i;

            assign bus_wr_rsp_valid[h]     = dram_wr_rsp_valid_i && (dram_wr_rsp_hart_i == HART_W'(h));

            assign ptw_mem_rsp_valid[h]    = ptw_nc_dram_rsp || ptw_unmapped_rsp_q[h];
            assign ptw_mem_rsp_error[h]    = ptw_nc_dram_rsp ? dram_rd_rsp_error_i : 1'b1;
            assign ptw_mem_rsp_data[h]     = ptw_nc_dram_rsp ? dram_rd_rsp_data_i[ptw_word_idx_q[h] * 64 +: 64] : 64'h0;
        end

        // Rotating round-robin hart arbiter, priority PTW > L1I > L1D_RD > L1D_WR per hart
        logic [HART_W-1:0] dram_rr_hart_q;
        logic              grant_valid;
        logic [HART_W-1:0] grant_hart;
        logic [2:0]        grant_mid;
        logic [HART_W-1:0] arb_h_cand;

        always_comb begin
            grant_valid = 1'b0;
            grant_hart  = dram_rr_hart_q;
            grant_mid   = MID_NONE;
            arb_h_cand  = '0;

            for (int off = 0; off < NUM_HARTS; off++) begin
                arb_h_cand = HART_W'((int'(dram_rr_hart_q) + off) % int'(NUM_HARTS));
                if (!grant_valid) begin
                    if (ptw_dram_req[arb_h_cand]) begin
                        grant_valid = 1'b1; grant_hart = arb_h_cand; grant_mid = MID_PTW;
                    end else if (l1i_dram_req[arb_h_cand]) begin
                        grant_valid = 1'b1; grant_hart = arb_h_cand; grant_mid = MID_L1I;
                    end else if (l1d_rd_dram_req[arb_h_cand]) begin
                        grant_valid = 1'b1; grant_hart = arb_h_cand; grant_mid = MID_L1D_RD;
                    end else if (l1d_wr_dram_req[arb_h_cand]) begin
                        grant_valid = 1'b1; grant_hart = arb_h_cand; grant_mid = MID_L1D_WR;
                    end
                end
            end
        end

        always_ff @(posedge clk_i) begin
            if (rst_i) begin
                dram_rr_hart_q <= '0;
            end else if (grant_valid && dram_req_ready_i) begin
                dram_rr_hart_q <= HART_W'((int'(grant_hart) + 1) % int'(NUM_HARTS));
            end
        end

        assign dram_req_valid_o    = grant_valid;
        assign dram_req_write_o    = (grant_mid == MID_L1D_WR);
        assign dram_req_hart_o     = grant_hart;
        assign dram_req_mid_o      = grant_mid;
        assign dram_req_addr_o     = (grant_mid == MID_PTW)    ? ptw_mem_req_addr[grant_hart][55:6] :
                                     (grant_mid == MID_L1I)    ? l1i_bus_rd_req_addr[grant_hart]    :
                                     (grant_mid == MID_L1D_RD) ? bus_rd_req_addr[grant_hart]        :
                                     (grant_mid == MID_L1D_WR) ? bus_wr_req_addr[grant_hart]        : 50'h0;
        assign dram_req_tag_o      = (grant_mid == MID_L1I)    ? l1i_bus_rd_req_tag[grant_hart]     :
                                     (grant_mid == MID_L1D_RD) ? bus_rd_req_tag[grant_hart]         : 2'b0;
        assign dram_req_wdata_o    = (grant_mid == MID_L1D_WR) ? bus_wr_req_data[grant_hart]        : 512'h0;
        assign dram_rd_rsp_ready_o = 1'b1;
    end

    // =========================================================================
    // 4. Multi-Hart Core Instances (`fursoy_s1_core`, h = 0 .. NUM_HARTS-1)
    // =========================================================================
    for (genvar h = 0; h < NUM_HARTS; h++) begin : gen_harts
        /* verilator lint_off PINCONNECTEMPTY */
        fursoy_s1_core #(
            .PRF_COUNT        (PRF_SIZE),
            .AREG_NUM         (AREG_COUNT),
            .ROB_NUM          (ROB_DEPTH),
            .CHKPT_NUM        (NUM_CHECKPOINTS),
            .SMP_COHERENCE_EN (SMP_COHERENCE_EN)
        ) u_core (
            .clk_i            (clk_i),
            .rst_i            (rst_i),
            .mhartid_i        (64'(h)),

            .frontend_en_i    (frontend_en_i),
            .priv_mode_i      (2'b11),
            .mstatus_i        (64'h0),
            .satp_i           (64'h0),
            .pmp_allow_i      (1'b1),

            .trap_valid_i     (1'b0),
            .trap_target_i    (64'h0),
            .mret_valid_i     (1'b0),
            .mret_target_i    (64'h0),

            .sfence_vma_valid_i (1'b0),
            .sfence_vma_va_i    (64'h0),
            .sfence_vma_asid_i  (16'h0),

            .uop0_valid_i     (1'b0),
            .uop0_rs1_i       ('0),
            .uop0_rs2_i       ('0),
            .uop0_rd_i        ('0),
            .uop0_class_i     (UOP_ALU_INT),
            .uop0_subop_i     (ALU_ADD),
            .uop0_imm_i       (64'h0),
            .uop0_use_imm_i   (1'b0),
            .uop0_pc_i        (64'h0),
            .uop0_pred_taken_i(1'b0),
            .uop0_pred_target_i(64'h0),
            .uop0_is_branch_i (1'b0),
            .uop0_is_jal_i    (1'b0),
            .uop0_is_jalr_i   (1'b0),
            .uop0_is_fp_i     (1'b0),
            .uop0_fp_dest_valid_i(1'b0),
            .uop0_fs3_i       (5'b0),
            .uop0_frm_i       (3'b0),
            .uop0_is_vec_i    (1'b0),
            .uop0_vec_dest_valid_i(1'b0),
            .uop0_prd_vec_i   (6'b0),

            .uop1_valid_i     (1'b0),
            .uop1_rs1_i       ('0),
            .uop1_rs2_i       ('0),
            .uop1_rd_i        ('0),
            .uop1_class_i     (UOP_ALU_INT),
            .uop1_subop_i     (ALU_ADD),
            .uop1_imm_i       (64'h0),
            .uop1_use_imm_i   (1'b0),
            .uop1_pc_i        (64'h0),
            .uop1_pred_taken_i(1'b0),
            .uop1_pred_target_i(64'h0),
            .uop1_is_branch_i (1'b0),
            .uop1_is_jal_i    (1'b0),
            .uop1_is_jalr_i   (1'b0),
            .uop1_is_fp_i     (1'b0),
            .uop1_fp_dest_valid_i(1'b0),
            .uop1_fs3_i       (5'b0),
            .uop1_frm_i       (3'b0),
            .uop1_is_vec_i    (1'b0),
            .uop1_vec_dest_valid_i(1'b0),
            .uop1_prd_vec_i   (6'b0),

            .rename_ack_o     (),
            .flush_valid_i    (1'b0),

            .retire_ready_i   (1'b1),
            .retire_valid_o   (retire_valid_o[h]),
            .retire_rd_o      (),
            .retire_pnew_o    (),
            .retire_pold_o    (),
            .retire_is_branch_o(),
            .retire_chkpt_id_o(),
            .retire_pc_o      (retire_pc_o[h]),
            .retire_exception_o(retire_exception_o[h]),
            .retire_exc_cause_o(),
            .retire_exc_pc_o  (),

            .recovering_o     (),
            .reconstructing_o (),
            .rob_head_o       (),
            .rob_tail_o       (),
            .freelist_count_o (),
            .rob_count_o      (),
            .chkpt_free_count_o(),
            .dispatch_ready_o (),
            .arat_map_o       (),
            .srat_map_o       (),
            .prf_ready_o      (),
            .comp_valid_o     (),
            .comp_rob_idx_o   (),
            .comp_epoch_o     (),
            .comp_preg_o      (),
            .comp_ack_o       (),
            .comp_fflags_o    (),
            .probe_paddr_i    ('0),
            .probe_pdata_o    (),
            .diag_valid_mask_o(),
            .diag_ready_p0_o  (),
            .diag_ready_p1_o  (),
            .diag_prs1_rdy_o  (),
            .diag_prs2_rdy_o  (),
            .diag_rob_idx_o   (),
            .diag_head_valid_o(),
            .diag_head_completed_o(),
            .diag_head_exception_o(),
            .diag_head_rd_o   (),
            .diag_head_pnew_o (),
            .diag_head_is_branch_o(),
            .diag_recover_valid_o(),
            .diag_recover_rob_idx_o(),

            .test_inject_valid_i      (1'b0),
            .test_inject_data_i       (64'h0),
            .test_inject_pnew_i       (preg_t'(0)),
            .test_inject_rob_idx_i    (rob_idx_t'(0)),
            .test_inject_rob_epoch_i  (rob_epoch_t'(0)),
            .test_inject_mispredict_i (1'b0),

            .comp_fp_wb_valid_i       (3'b0),
            .comp_fp_wb_preg_i        ('{default: '0}),
            .comp_fflags_i            ('{default: '0}),
            .test_fp_w0_valid_i       (1'b0),
            .test_fp_w0_paddr_i       ('0),
            .test_fp_w0_data_i        (64'h0),
            .test_fp_w1_valid_i       (1'b0),
            .test_fp_w1_paddr_i       ('0),
            .test_fp_w1_data_i        (64'h0),
            .test_fp_w2_valid_i       (1'b0),
            .test_fp_w2_paddr_i       ('0),
            .test_fp_w2_data_i        (64'h0),
            .probe_fp_paddr_i         ('0),
            .probe_fp_pdata_o         (),
            .uop0_prd_fp_o            (),
            .uop0_pold_fp_o           (),
            .uop0_prs1_fp_o           (),
            .uop0_prs1_fp_ready_o     (),
            .uop0_prs2_fp_o           (),
            .uop0_prs2_fp_ready_o     (),
            .uop0_prs3_fp_o           (),
            .uop0_prs3_fp_ready_o     (),
            .uop1_prd_fp_o            (),
            .uop1_pold_fp_o           (),
            .uop1_prs1_fp_o           (),
            .uop1_prs1_fp_ready_o     (),
            .uop1_prs2_fp_o           (),
            .uop1_prs2_fp_ready_o     (),
            .uop1_prs3_fp_o           (),
            .uop1_prs3_fp_ready_o     (),
            .retire_is_fp_o           (),
            .retire_fp_dest_valid_o   (),
            .retire_prd_fp_o          (),
            .retire_pold_fp_o         (),
            .retire_fflags_o          (),
            .retire_is_vec_o          (),
            .retire_vec_dest_valid_o  (),
            .retire_prd_vec_o         (),
            .fl_fp_count_o            (),
            .fl_fp_ready_o            (),
            .fl_fp_reconstructing_o   (),
            .arat_fp_map_o            (),
            .srat_fp_map_o            (),
            .prf_fp_ready_o           (),
            .mstatus_fs_o             (),
            .fcsr_frm_o               (),
            .fcsr_fflags_o            (),
            .mstatus_vs_o             (),
            .vtype_o                  (),
            .vl_o                     (),
            .vstart_o                 (),
            .vcsr_o                   (),
            .bank_collision_o         (),
            .viq_full_o               (),
            .viq_count_o              (),
            .test_vrf_w_valid_i       (1'b0),
            .test_vrf_w_paddr_i       ('0),
            .test_vrf_w_byte_mask_i   ('0),
            .test_vrf_w_data_i        ('0),
            .probe_vrf_paddr_i        ('0),
            .probe_vrf_pdata_o        (),
            .test_vec_cfg_valid_i     (1'b0),
            .test_vec_cfg_avl_i       (64'h0),
            .test_vec_cfg_vtype_i     (64'h0),
            .test_vec_cfg_rs1_is_zero_i(1'b0),
            .test_vec_cfg_rd_is_zero_i(1'b0),
            .test_fof_fault_valid_i   (1'b0),
            .test_fof_fault_elem_i    (64'h0),

            .bus_rd_req_valid_o       (bus_rd_req_valid[h]),
            .bus_rd_req_addr_o        (bus_rd_req_addr[h]),
            .bus_rd_req_tag_o         (bus_rd_req_tag[h]),
            .bus_rd_req_op_o          (bus_rd_req_op[h]),
            .bus_rd_req_ready_i       (bus_rd_req_ready[h]),
            .bus_rd_rsp_valid_i       (bus_rd_rsp_valid[h]),
            .bus_rd_rsp_tag_i         (bus_rd_rsp_tag[h]),
            .bus_rd_rsp_data_i        (bus_rd_rsp_data[h]),
            .bus_rd_rsp_state_i       (bus_rd_rsp_state[h]),
            .bus_rd_rsp_has_data_i    (bus_rd_rsp_has_data[h]),

            .bus_wr_req_valid_o       (bus_wr_req_valid[h]),
            .bus_wr_req_addr_o        (bus_wr_req_addr[h]),
            .bus_wr_req_data_o        (bus_wr_req_data[h]),
            .bus_wr_req_dirty_o       (bus_wr_req_dirty[h]),
            .bus_wr_req_ready_i       (bus_wr_req_ready[h]),
            .bus_wr_rsp_valid_i       (bus_wr_rsp_valid[h]),

            .ptw_req_valid_o          (),
            .ptw_req_tr_id_o          (),
            .ptw_req_vpn_o            (),
            .ptw_req_access_type_o    (),
            .ptw_req_ready_i          (1'b1),
            .ptw_rsp_valid_i          (1'b0),
            .ptw_rsp_tr_id_i          ('0),
            .ptw_rsp_pa_i             (56'h0),
            .ptw_rsp_page_fault_i     (1'b0),
            .ptw_rsp_access_fault_i   (1'b0),

            .l1i_bus_rd_req_valid_o   (l1i_bus_rd_req_valid[h]),
            .l1i_bus_rd_req_addr_o    (l1i_bus_rd_req_addr[h]),
            .l1i_bus_rd_req_tag_o     (l1i_bus_rd_req_tag[h]),
            .l1i_bus_rd_req_ready_i   (l1i_bus_rd_req_ready[h]),
            .l1i_bus_rd_rsp_valid_i   (l1i_bus_rd_rsp_valid[h]),
            .l1i_bus_rd_rsp_tag_i     (l1i_bus_rd_rsp_tag[h]),
            .l1i_bus_rd_rsp_data_i    (l1i_bus_rd_rsp_data[h]),
            .l1i_bus_rd_rsp_error_i   (l1i_bus_rd_rsp_error[h]),
            .l1i_inval_line_valid_i   (l1i_inval_line_valid),
            .l1i_inval_line_addr_i    (l1i_inval_line_addr),

            .ptw_mem_req_valid_o      (ptw_mem_req_valid[h]),
            .ptw_mem_req_addr_o       (ptw_mem_req_addr[h]),
            .ptw_mem_req_ready_i      (ptw_mem_req_ready[h]),
            .ptw_mem_rsp_valid_i      (ptw_mem_rsp_valid[h]),
            .ptw_mem_rsp_data_i       (ptw_mem_rsp_data[h]),
            .ptw_mem_rsp_error_i      (ptw_mem_rsp_error[h]),

            .fe_fetch_queue_count_o   (),
            .fe_fetch_queue_full_o    (),
            .fe_fetch_queue_empty_o   (),
            .hpm_fetch_words_o        (),
            .hpm_fetch_uops_o         (),
            .hpm_fetch_empty_cyc_o    (),
            .hpm_fetch_full_cyc_o     (),
            .hpm_l1i_hits_o           (),
            .hpm_l1i_misses_o         (),
            .hpm_itlb_hits_o          (),
            .hpm_itlb_misses_o        (),
            .hpm_btb_hits_o           (),
            .hpm_btb_misses_o         (),
            .hpm_bpu_cond_pred_o      (),
            .hpm_ras_calls_o          (),
            .hpm_ras_returns_o        (),
            .hpm_fence_i_flushes_o    (),
            .hpm_redirect_cyc_o       (),

            .csr_priv_mode_o          (csr_priv_mode_o[h]),
            .csr_mstatus_o            (csr_mstatus_o[h]),
            .csr_satp_o               (),
            .csr_mepc_o               (csr_mepc_o[h]),
            .csr_mcause_o             (csr_mcause_o[h]),
            .csr_mtval_o              (),
            .csr_sepc_o               (csr_sepc_o[h]),
            .csr_scause_o             (csr_scause_o[h]),
            .csr_stval_o              (),
            .csr_mtvec_o              (),
            .csr_stvec_o              (),

            .irq_timer_i              (clint_irq_timer[h]),
            .irq_software_i           (clint_irq_software[h]),
            .irq_external_i           (core_irq_external[h]),
            .irq_seip_i               (plic_irq_seip[h]),
            .mtime_i                  (clint_mtime),

            .wfi_sleep_o              (wfi_sleep_o[h]),
            .irq_pending_valid_o      (),
            .irq_pending_cause_o      (),
            .csr_mip_o                (csr_mip_o[h]),
            .csr_mie_o                (csr_mie_o[h]),
            .csr_mideleg_o            (),
            .csr_sie_o                (),
            .csr_sip_o                (),

            .test_csr_we_i            (1'b0),
            .test_csr_addr_i          (12'h0),
            .test_csr_wdata_i         (64'h0),

            .test_dtlb_req_valid_i    (1'b0),
            .test_dtlb_req_tr_id_i    ('0),
            .test_dtlb_req_vpn_i      (27'b0),
            .test_dtlb_req_is_store_i (1'b0),
            .test_dtlb_req_is_amo_i   (1'b0),
            .test_dtlb_req_ready_o    (),
            .test_dtlb_rsp_valid_o    (),
            .test_dtlb_rsp_tr_id_o    (),
            .test_dtlb_rsp_pa_o       (),
            .test_dtlb_rsp_page_fault_o(),
            .test_dtlb_rsp_access_fault_o(),
            .ptw_dtlb_grants_since_itlb_o(),

            .snoop_req_valid_i        (snoop_req_valid[h]),
            .snoop_req_addr_i         ({snoop_req_addr[h], 6'b0}),
            .snoop_req_type_i         (snoop_req_type[h]),
            .snoop_req_ready_o        (snoop_req_ready[h]),
            .snoop_rsp_valid_o        (snoop_rsp_valid[h]),
            .snoop_rsp_has_data_o     (snoop_rsp_has_data[h]),
            .snoop_rsp_was_dirty_o    (snoop_rsp_was_dirty[h]),
            .snoop_rsp_data_o         (snoop_rsp_data[h]),
            .snoop_rsp_ready_i        (snoop_rsp_ready[h]),
            .snoop_rsp_ack_only_o     (snoop_rsp_ack_only[h]),

            .test_ev_fp_issue_i       (1'b0),
            .test_ev_fp_fma_busy_i    (1'b0),
            .test_ev_fp_fdiv_stall_i  (1'b0),
            .test_ev_fp_rename_stall_i(1'b0),
            .test_ev_vec_uop_commit_i (1'b0),
            .test_ev_vec_mem_traffic_i(1'b0),
            .test_ev_vec_viq_full_i   (1'b0),
            .test_ev_vec_fof_trunc_i  (1'b0),

            .mcycle_o                 (mcycle_o[h]),
            .minstret_o               (minstret_o[h]),
            .mhpmcounter_o            (),
            .cpi_category_o           (),
            .cpi_active_owner_o       (),
            .raw_event_pulse_o        (),
            .raw_event_ext_pulse_o    (),

            .mmio_req_valid_o         (mmio_req_valid[h]),
            .mmio_req_addr_o          (mmio_req_addr[h]),
            .mmio_req_is_store_o      (mmio_req_is_store[h]),
            .mmio_req_write_o         (),
            .mmio_req_size_o          (mmio_req_size[h]),
            .mmio_req_wdata_o         (mmio_req_wdata[h]),
            .mmio_req_wstrb_o         (mmio_req_wstrb[h]),
            .mmio_req_ready_i         (mmio_req_ready[h]),
            .mmio_rsp_valid_i         (mmio_rsp_valid[h]),
            .mmio_rsp_rdata_i         (mmio_rsp_rdata[h]),
            .mmio_rsp_error_i         (mmio_rsp_error[h]),
            .mmio_rsp_ready_o         (mmio_rsp_ready[h])
        );
        /* verilator lint_on PINCONNECTEMPTY */
    end

endmodule

`endif // FURSOY_S2_SOC_SV
