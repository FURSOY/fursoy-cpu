`ifndef FURSOY_S1_SOC_SV
`define FURSOY_S1_SOC_SV

// =============================================================================
// Fursoy Slice-1 SoC Top-Level Module — Milestone 9 Phase C
// =============================================================================
// Encapsulates fursoy_s1_core and integrates:
// - 5-to-1 Crossbar/Arbiter multiplexing:
//     * Master 0: L1I cache line refills (512-bit)
//     * Master 1: L1D cache line demand refills (512-bit)
//     * Master 2: L1D dirty line writebacks (512-bit)
//     * Master 3: PTW page-table walks (64-bit)
//     * Master 4: Core uncached MMIO (64-bit)
// - Slave Decoders:
//     * DRAM Controller Interface (0x8000_0000 - 0x8FFF_FFFF, 256 MB)
//     * CLINT (0x0200_0000 - 0x0200_FFFF via rtl/platform/fursoy_s0_clint.sv)
//     * PLIC  (0x0C00_0000 - 0x0C3F_FFFF via rtl/platform/fursoy_s0_plic.sv)
//     * UART16550 (0x1000_0000 - 0x1000_0FFF via rtl/platform/fursoy_s0_uart.sv)
// - Route Interrupt Lines:
//     * CLINT timer interrupt    -> u_core.irq_timer_i
//     * CLINT software interrupt -> u_core.irq_software_i
//     * PLIC M-mode external     -> u_core.irq_external_i (ORed with external pin)
//     * PLIC S-mode external     -> u_core.irq_seip_i
//     * UART interrupt           -> PLIC source 1 input
// - Priority & Arbitration Hierarchy (§5.2):
//     * Tier 1 (Core MMIO) > Tier 2 (PTW Walks) > Tier 3 (L1I Refills)
//       > Tier 4 (L1D Refills) > Tier 5 (L1D Writebacks)
//     * Enforces fair forward-progress with starvation threshold counter.
// - Unmapped Aperture Termination (§5.2, PROP_M9_18):
//     * Any transaction to addresses outside mapped windows immediately returns
//       bus error response (error = 1), translating to precise Access Faults.
// Specification authority: docs/architecture/slice1-m9-soc-linux-v1.md v1.1 §5, §8.3
// =============================================================================

`include "fursoy_s1_pkg.sv"
`include "fursoy_s1_core.sv"
`include "fursoy_s0_clint.sv"
`include "fursoy_s0_plic.sv"
`include "fursoy_s0_uart.sv"

module fursoy_s1_soc
    import fursoy_s1_pkg::*;
#(
    /* verilator lint_off UNUSEDPARAM */
    parameter logic [63:0] RESET_PC       = 64'h0000_0000_8000_0000,
    parameter logic [63:0] RESET_MTVEC    = 64'h0000_0000_0000_0000,
    /* verilator lint_on UNUSEDPARAM */
    parameter logic [63:0] DRAM_BASE_ADDR = 64'h0000_0000_8000_0000,
    parameter logic [63:0] DRAM_SIZE      = 64'h0000_0000_1000_0000, // 256 MB
    parameter logic [63:0] CLINT_BASE_ADDR = 64'h0000_0000_0200_0000,
    parameter logic [63:0] PLIC_BASE_ADDR  = 64'h0000_0000_0C00_0000,
    parameter logic [63:0] UART_BASE_ADDR  = 64'h0000_0000_1000_0000
) (
    input  logic                   clk_i,
    input  logic                   rst_i,

    // Frontend autonomous fetch mode (1=autonomous via L1I; 0=legacy TB uop inputs)
    input  logic                   frontend_en_i,

    // -------------------------------------------------------------------------
    // External Interrupts & Console TX
    // -------------------------------------------------------------------------
    input  logic [31:0]            irq_sources_i, // PLIC inputs: bit 1 is overridden by UART
    input  logic                   irq_external_i,// Direct M-mode external interrupt injection
    output logic                   uart_tx_valid_o,
    output logic [7:0]             uart_tx_data_o,

    // -------------------------------------------------------------------------
    // External 256 MB DRAM Controller Interface (512-bit lines)
    // -------------------------------------------------------------------------
    // Unified Request Channel
    output logic                   dram_req_valid_o,
    input  logic                   dram_req_ready_i,
    output logic                   dram_req_write_o,
    output logic [49:0]            dram_req_addr_o,      // Line address (byte_addr >> 6)
    output logic [511:0]           dram_req_wdata_o,
    output logic [2:0]             dram_req_mid_o,       // Master ID (0=L1I, 1=L1D_RD, 2=L1D_WR, 3=PTW)
    output logic [1:0]             dram_req_tag_o,       // Master Tag

    // Read Response Channel
    input  logic                   dram_rd_rsp_valid_i,
    output logic                   dram_rd_rsp_ready_o,
    input  logic [2:0]             dram_rd_rsp_mid_i,
    input  logic [1:0]             dram_rd_rsp_tag_i,
    input  logic [511:0]           dram_rd_rsp_data_i,
    input  logic                   dram_rd_rsp_error_i,

    // Write Response Handshake
    input  logic                   dram_wr_rsp_valid_i,

    // -------------------------------------------------------------------------
    // Architectural In-Order Retirement Observability
    // -------------------------------------------------------------------------
    output logic [1:0]             retire_valid_o,
    output logic [63:0]            retire_pc_o           [1:0],
    output areg_t                  retire_rd_o           [1:0],
    output logic                   retire_exception_o,
    output logic [4:0]             retire_exc_cause_o,
    output logic [63:0]            retire_exc_pc_o,

    // -------------------------------------------------------------------------
    // Privileged Architectural State & CSR Observability
    // -------------------------------------------------------------------------
    output logic [1:0]             csr_priv_mode_o,
    output logic [63:0]            csr_mstatus_o,
    output logic [63:0]            csr_mie_o,
    output logic [63:0]            csr_mip_o,
    output logic [63:0]            csr_mepc_o,
    output logic [63:0]            csr_mcause_o,
    output logic [63:0]            csr_mtval_o,
    output logic [63:0]            csr_sepc_o,
    output logic [63:0]            csr_scause_o,
    output logic [63:0]            csr_stval_o,
    output logic [63:0]            csr_satp_o,
    output logic [63:0]            csr_mtvec_o,
    output logic [63:0]            csr_stvec_o,
    output logic                   wfi_sleep_o,

    // Performance telemetry
    output logic [63:0]            mcycle_o,
    output logic [63:0]            minstret_o,
    output logic [63:0]            cpi_category_o        [8],   // Single-owner CPI category counters
    output logic [64:1]            raw_event_pulse_o,           // 64 raw HPM event pulses (cycle-level)

    // -------------------------------------------------------------------------
    // Direct Testbench Diagnostic & Probe Ports
    // -------------------------------------------------------------------------
    input  logic                   test_csr_we_i,
    input  logic [11:0]            test_csr_addr_i,
    input  logic [63:0]            test_csr_wdata_i,

    input  logic                   uop0_valid_i,
    input  areg_t                  uop0_rs1_i,
    input  areg_t                  uop0_rs2_i,
    input  areg_t                  uop0_rd_i,
    input  uop_class_t             uop0_class_i,
    input  uop_subop_t             uop0_subop_i,
    input  logic [63:0]            uop0_imm_i,
    input  logic                   uop0_use_imm_i,
    input  logic [63:0]            uop0_pc_i,

    input  logic                   uop1_valid_i,
    input  areg_t                  uop1_rs1_i,
    input  areg_t                  uop1_rs2_i,
    input  areg_t                  uop1_rd_i,
    input  uop_class_t             uop1_class_i,
    input  uop_subop_t             uop1_subop_i,
    input  logic [63:0]            uop1_imm_i,
    input  logic                   uop1_use_imm_i,
    input  logic [63:0]            uop1_pc_i,
    output logic [1:0]             rename_ack_o,

    input  preg_t                  probe_paddr_i,
    output logic [63:0]            probe_pdata_o,

    // Diagnostics for testbench synchronization
    output logic [ROB_CNT_W-1:0]   rob_count_o,
    output logic [1:0]             dispatch_ready_o,
    output preg_t                  arat_map_o            [AREG_COUNT],

    // Diagnostic event exports
    output logic                   diag_irq_timer_o,
    output logic                   diag_irq_software_o,
    output logic                   diag_irq_external_o,
    output logic                   diag_irq_seip_o,
    output logic                   diag_uart_irq_o,
    output logic [2:0]             diag_arb_grant_mid_o
);

    // =========================================================================
    // 1. Memory Map Address Constants
    // =========================================================================
    localparam logic [63:0] DRAM_END_ADDR  = DRAM_BASE_ADDR + DRAM_SIZE;
    localparam logic [63:0] CLINT_END_ADDR = CLINT_BASE_ADDR + 64'h0001_0000; // 64 KiB
    localparam logic [63:0] PLIC_END_ADDR  = PLIC_BASE_ADDR  + 64'h0040_0000; // 4 MiB
    localparam logic [63:0] UART_END_ADDR  = UART_BASE_ADDR  + 64'h0000_1000; // 4 KiB

    // Master ID enumeration
    localparam logic [2:0] MID_L1I    = 3'd0;
    localparam logic [2:0] MID_L1D_RD = 3'd1;
    localparam logic [2:0] MID_L1D_WR = 3'd2;
    localparam logic [2:0] MID_PTW    = 3'd3;
    /* verilator lint_off UNUSEDPARAM */
    localparam logic [2:0] MID_MMIO   = 3'd4;
    /* verilator lint_on UNUSEDPARAM */
    localparam logic [2:0] MID_NONE   = 3'd7;

    // =========================================================================
    // 2. Internal Core Master Signals
    // =========================================================================
    // Master 0: L1I Refills (512-bit)
    logic                   l1i_bus_rd_req_valid;
    logic [49:0]            l1i_bus_rd_req_addr;
    logic [1:0]             l1i_bus_rd_req_tag;
    logic                   l1i_bus_rd_req_ready;
    logic                   l1i_bus_rd_rsp_valid;
    logic [1:0]             l1i_bus_rd_rsp_tag;
    logic [511:0]           l1i_bus_rd_rsp_data;
    logic                   l1i_bus_rd_rsp_error;

    // Master 1: L1D Refills (512-bit)
    logic                   bus_rd_req_valid;
    logic [49:0]            bus_rd_req_addr;
    mshr_idx_t              bus_rd_req_tag;
    logic                   bus_rd_req_ready;
    logic                   bus_rd_rsp_valid;
    mshr_idx_t              bus_rd_rsp_tag;
    logic [511:0]           bus_rd_rsp_data;

    // Master 2: L1D Dirty Evictions (512-bit)
    logic                   bus_wr_req_valid;
    logic [49:0]            bus_wr_req_addr;
    logic [511:0]           bus_wr_req_data;
    logic                   bus_wr_req_ready;
    logic                   bus_wr_rsp_valid;

    // Master 3: PTW Walks (64-bit)
    logic                   ptw_mem_req_valid;
    logic [55:0]            ptw_mem_req_addr;
    logic                   ptw_mem_req_ready;
    logic                   ptw_mem_rsp_valid;
    logic [63:0]            ptw_mem_rsp_data;
    logic                   ptw_mem_rsp_error;

    // Master 4: Core Uncached MMIO (64-bit)
    logic                   mmio_req_valid;
    logic [63:0]            mmio_req_addr;
    logic                   mmio_req_is_store;
    /* verilator lint_off UNUSEDSIGNAL */
    logic                   mmio_req_write;
    logic [7:0]             mmio_req_wstrb;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [2:0]             mmio_req_size;
    logic [63:0]            mmio_req_wdata;
    logic                   mmio_req_ready;
    logic                   mmio_rsp_valid;
    logic [63:0]            mmio_rsp_rdata;
    logic                   mmio_rsp_error;
    logic                   mmio_rsp_ready;

    // Interrupt Wires
    logic                   clint_irq_software;
    logic                   clint_irq_timer;
    logic [63:0]            clint_mtime;
    logic                   plic_irq_meip;
    logic                   plic_irq_seip;
    logic                   uart_irq;
    logic [31:0]            plic_irq_sources;

    // Core Interrupt Inputs
    logic                   core_irq_timer;
    logic                   core_irq_software;
    logic                   core_irq_external;
    logic                   core_irq_seip;

    assign core_irq_timer      = clint_irq_timer;
    assign core_irq_software   = clint_irq_software;
    assign core_irq_external   = plic_irq_meip | irq_external_i;
    assign core_irq_seip       = plic_irq_seip;

    // Observability exports
    assign diag_irq_timer_o    = core_irq_timer;
    assign diag_irq_software_o = core_irq_software;
    assign diag_irq_external_o = core_irq_external;
    assign diag_irq_seip_o     = core_irq_seip;
    assign diag_uart_irq_o     = uart_irq;

    // =========================================================================
    // 3. Peripheral Crossbar & Slave Integration (CLINT, PLIC, UART)
    // =========================================================================
    // Peripheral decodes for MMIO
    logic mmio_select_clint;
    logic mmio_select_plic;
    logic mmio_select_uart;

    assign mmio_select_clint = (mmio_req_addr >= CLINT_BASE_ADDR) && (mmio_req_addr < CLINT_END_ADDR);
    assign mmio_select_plic  = (mmio_req_addr >= PLIC_BASE_ADDR)  && (mmio_req_addr < PLIC_END_ADDR);
    assign mmio_select_uart  = (mmio_req_addr >= UART_BASE_ADDR)  && (mmio_req_addr < UART_END_ADDR);

    // CLINT signals
    logic        clint_req_ready;
    logic        clint_rsp_valid;
    logic        clint_rsp_ready;
    logic [63:0] clint_rsp_data;
    logic        clint_rsp_error;
    logic        clint_access_error;

    // PLIC signals
    logic        plic_req_ready;
    logic        plic_rsp_valid;
    logic        plic_rsp_ready;
    logic [63:0] plic_rsp_data;
    logic        plic_rsp_error;
    logic        plic_access_error;

    // UART signals
    logic        uart_req_ready;
    logic        uart_rsp_valid;
    logic        uart_rsp_ready;
    logic [63:0] uart_rsp_data;
    logic        uart_rsp_error;
    logic        uart_access_error;

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_rsp_high_bits = &{1'b0, plic_rsp_data[63:32], uart_rsp_data[63:32]};
    /* verilator lint_on UNUSEDSIGNAL */

    // MMIO Handshake State Machine
    typedef enum logic [2:0] {
        MMIO_TGT_IDLE     = 3'd0,
        MMIO_TGT_CLINT    = 3'd1,
        MMIO_TGT_PLIC     = 3'd2,
        MMIO_TGT_UART     = 3'd3,
        MMIO_TGT_UNMAPPED = 3'd4
    } mmio_target_t;

    mmio_target_t mmio_target_q;
    logic         mmio_inflight_q;
    logic         mmio_is_store_q;
    logic         mmio_clint_err_q;
    logic         mmio_plic_err_q;
    logic         mmio_uart_err_q;

    // Ready gating to core MMIO master: accept request when idle
    assign mmio_req_ready = !mmio_inflight_q &&
                            (mmio_select_clint ? clint_req_ready :
                             mmio_select_plic  ? plic_req_ready  :
                             mmio_select_uart  ? uart_req_ready  : 1'b1);

    wire mmio_req_fire = mmio_req_valid && mmio_req_ready;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            mmio_inflight_q  <= 1'b0;
            mmio_target_q    <= MMIO_TGT_IDLE;
            mmio_is_store_q  <= 1'b0;
            mmio_clint_err_q <= 1'b0;
            mmio_plic_err_q  <= 1'b0;
            mmio_uart_err_q  <= 1'b0;
        end else begin
            if (mmio_req_fire) begin
                mmio_inflight_q  <= 1'b1;
                mmio_is_store_q  <= mmio_req_is_store;
                mmio_clint_err_q <= clint_access_error;
                mmio_plic_err_q  <= plic_access_error;
                mmio_uart_err_q  <= uart_access_error;
                mmio_target_q    <= mmio_select_clint ? MMIO_TGT_CLINT :
                                    mmio_select_plic  ? MMIO_TGT_PLIC  :
                                    mmio_select_uart  ? MMIO_TGT_UART  : MMIO_TGT_UNMAPPED;
            end else if (mmio_rsp_valid && mmio_rsp_ready) begin
                mmio_inflight_q  <= 1'b0;
                mmio_target_q    <= MMIO_TGT_IDLE;
            end
        end
    end

    // Peripheral Response Multiplexing to Core MMIO
    always_comb begin
        mmio_rsp_valid = 1'b0;
        mmio_rsp_rdata = 64'h0;
        mmio_rsp_error = 1'b0;
        clint_rsp_ready = 1'b0;
        plic_rsp_ready  = 1'b0;
        uart_rsp_ready  = 1'b0;

        case (mmio_target_q)
            MMIO_TGT_CLINT: begin
                mmio_rsp_valid  = clint_rsp_valid;
                mmio_rsp_rdata  = mmio_is_store_q ? 64'h0 : clint_rsp_data;
                mmio_rsp_error  = clint_rsp_error || mmio_clint_err_q;
                clint_rsp_ready = mmio_rsp_ready;
            end

            MMIO_TGT_PLIC: begin
                if (!mmio_is_store_q) begin
                    mmio_rsp_valid  = plic_rsp_valid;
                    mmio_rsp_rdata  = {plic_rsp_data[31:0], plic_rsp_data[31:0]};
                    mmio_rsp_error  = plic_rsp_error;
                    plic_rsp_ready  = mmio_rsp_ready;
                end else begin
                    // PLIC stores execute in 1 cycle, errors report via access_error
                    mmio_rsp_valid  = 1'b1;
                    mmio_rsp_rdata  = 64'h0;
                    mmio_rsp_error  = mmio_plic_err_q;
                end
            end

            MMIO_TGT_UART: begin
                mmio_rsp_valid = uart_rsp_valid;
                mmio_rsp_rdata = {uart_rsp_data[31:0], uart_rsp_data[31:0]};
                mmio_rsp_error = uart_rsp_error || mmio_uart_err_q;
                uart_rsp_ready = mmio_rsp_ready;
            end

            MMIO_TGT_UNMAPPED: begin
                // Unmapped aperture MMIO load/store terminates with error
                mmio_rsp_valid = 1'b1;
                mmio_rsp_rdata = 64'h0;
                mmio_rsp_error = 1'b1;
            end

            default: begin
                mmio_rsp_valid = 1'b0;
                mmio_rsp_rdata = 64'h0;
                mmio_rsp_error = 1'b0;
            end
        endcase
    end

    // 32-bit lane steering for peripheral write data
    wire [63:0] mmio_wdata_32 = mmio_req_addr[2] ? {32'h0, mmio_req_wdata[63:32]} : {32'h0, mmio_req_wdata[31:0]};

    // CLINT Instance
    fursoy_s0_clint #(.BASE_ADDR(CLINT_BASE_ADDR)) u_clint (
        .clk_i            (clk_i),
        .rst_i            (rst_i),
        .req_valid_i      (mmio_req_valid && mmio_select_clint && !mmio_inflight_q),
        .req_ready_o      (clint_req_ready),
        .req_store_i      (mmio_req_is_store),
        .req_addr_i       (mmio_req_addr),
        .req_size_i       (mmio_req_size),
        .req_store_data_i (mmio_req_wdata),
        .rsp_valid_o      (clint_rsp_valid),
        .rsp_ready_i      (clint_rsp_ready),
        .rsp_data_o       (clint_rsp_data),
        .rsp_error_o      (clint_rsp_error),
        .access_error_o   (clint_access_error),
        .irq_software_o   (clint_irq_software),
        .irq_timer_o      (clint_irq_timer),
        .mtime_o          (clint_mtime)
    );

    // PLIC Instance (Source 1 owned by UART)
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_irq_sources_bits = &{1'b0, irq_sources_i[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */
    assign plic_irq_sources = {irq_sources_i[31:2], uart_irq, 1'b0};

    fursoy_s0_plic #(.BASE_ADDR(PLIC_BASE_ADDR)) u_plic (
        .clk_i            (clk_i),
        .rst_i            (rst_i),
        .req_valid_i      (mmio_req_valid && mmio_select_plic && !mmio_inflight_q),
        .req_ready_o      (plic_req_ready),
        .req_store_i      (mmio_req_is_store),
        .req_addr_i       (mmio_req_addr),
        .req_size_i       (mmio_req_size),
        .req_store_data_i (mmio_wdata_32),
        .rsp_valid_o      (plic_rsp_valid),
        .rsp_ready_i      (plic_rsp_ready),
        .rsp_data_o       (plic_rsp_data),
        .rsp_error_o      (plic_rsp_error),
        .access_error_o   (plic_access_error),
        .irq_sources_i    (plic_irq_sources),
        .irq_meip_o       (plic_irq_meip),
        .irq_seip_o       (plic_irq_seip)
    );

    // UART16550 Instance
    fursoy_s0_uart #(.BASE_ADDR(UART_BASE_ADDR)) u_uart (
        .clk_i            (clk_i),
        .rst_i            (rst_i),
        .req_valid_i      (mmio_req_valid && mmio_select_uart && !mmio_inflight_q),
        .req_ready_o      (uart_req_ready),
        .req_store_i      (mmio_req_is_store),
        .req_addr_i       (mmio_req_addr),
        .req_size_i       (mmio_req_size),
        .req_store_data_i (mmio_wdata_32),
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
    // 4. DRAM Decoders, Unmapped Aperture Generators & Crossbar Arbiter
    // =========================================================================
    // Address range qualifications & SBI M-mode aperture protection [0x8000_0000..0x801F_FFFF]
    wire [63:0] l1i_byte_addr = {8'b0, l1i_bus_rd_req_addr, 6'b0};
    wire        l1i_pmp_deny  = (csr_priv_mode_o != 2'b11) &&
                                (l1i_byte_addr >= DRAM_BASE_ADDR) &&
                                (l1i_byte_addr < (DRAM_BASE_ADDR + 64'h20_0000));
    wire        l1i_in_dram   = (l1i_byte_addr >= DRAM_BASE_ADDR) && (l1i_byte_addr < DRAM_END_ADDR) && !l1i_pmp_deny;
    wire        l1i_unmapped  = l1i_bus_rd_req_valid && !l1i_in_dram;

    wire [63:0] ptw_byte_addr = {8'h0, ptw_mem_req_addr};
    wire        ptw_in_dram   = (ptw_byte_addr >= DRAM_BASE_ADDR) && (ptw_byte_addr < DRAM_END_ADDR);
    wire        ptw_unmapped  = ptw_mem_req_valid && !ptw_in_dram;

    // DRAM Request Candidates
    wire ptw_dram_req    = ptw_mem_req_valid && ptw_in_dram;
    wire l1i_dram_req    = l1i_bus_rd_req_valid && l1i_in_dram;
    wire l1d_rd_dram_req = bus_rd_req_valid;
    wire l1d_wr_dram_req = bus_wr_req_valid;

    // -------------------------------------------------------------------------
    // Anti-Starvation Mechanism: Bounded Wait Counter (§5.2, PROP_M9_13)
    // -------------------------------------------------------------------------
    localparam logic [5:0] STARVE_LIMIT = 6'd16;

    logic [5:0] ptw_wait_cnt_q;
    logic [5:0] l1i_wait_cnt_q;
    logic [5:0] l1d_rd_wait_cnt_q;
    logic [5:0] l1d_wr_wait_cnt_q;

    wire ptw_starving    = ptw_dram_req    && (ptw_wait_cnt_q    >= STARVE_LIMIT);
    wire l1i_starving    = l1i_dram_req    && (l1i_wait_cnt_q    >= STARVE_LIMIT);
    wire l1d_rd_starving = l1d_rd_dram_req && (l1d_rd_wait_cnt_q >= STARVE_LIMIT);
    wire l1d_wr_starving = l1d_wr_dram_req && (l1d_wr_wait_cnt_q >= STARVE_LIMIT);
    wire any_starving    = ptw_starving || l1i_starving || l1d_rd_starving || l1d_wr_starving;

    // Arbiter Grant Decision:
    // If starvation threshold exceeded, grant starving master;
    // Otherwise enforce priority hierarchy: PTW > L1I > L1D_RD > L1D_WR.
    logic [2:0] grant_mid;
    always_comb begin
        grant_mid = MID_NONE;
        if (any_starving) begin
            // Oldest/lowest-priority starving master gets emergency service
            if (l1d_wr_starving)      grant_mid = MID_L1D_WR;
            else if (l1d_rd_starving) grant_mid = MID_L1D_RD;
            else if (l1i_starving)    grant_mid = MID_L1I;
            else if (ptw_starving)    grant_mid = MID_PTW;
        end else begin
            // Normal hierarchical priority
            if (ptw_dram_req)         grant_mid = MID_PTW;
            else if (l1i_dram_req)    grant_mid = MID_L1I;
            else if (l1d_rd_dram_req) grant_mid = MID_L1D_RD;
            else if (l1d_wr_dram_req) grant_mid = MID_L1D_WR;
        end
    end

    assign diag_arb_grant_mid_o = grant_mid;

    // Wait counters update
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ptw_wait_cnt_q    <= '0;
            l1i_wait_cnt_q    <= '0;
            l1d_rd_wait_cnt_q <= '0;
            l1d_wr_wait_cnt_q <= '0;
        end else begin
            // PTW wait counter
            if (!ptw_dram_req || (grant_mid == MID_PTW && dram_req_ready_i))
                ptw_wait_cnt_q <= '0;
            else if (ptw_wait_cnt_q != '1)
                ptw_wait_cnt_q <= ptw_wait_cnt_q + 6'd1;

            // L1I wait counter
            if (!l1i_dram_req || (grant_mid == MID_L1I && dram_req_ready_i))
                l1i_wait_cnt_q <= '0;
            else if (l1i_wait_cnt_q != '1)
                l1i_wait_cnt_q <= l1i_wait_cnt_q + 6'd1;

            // L1D RD wait counter
            if (!l1d_rd_dram_req || (grant_mid == MID_L1D_RD && dram_req_ready_i))
                l1d_rd_wait_cnt_q <= '0;
            else if (l1d_rd_wait_cnt_q != '1)
                l1d_rd_wait_cnt_q <= l1d_rd_wait_cnt_q + 6'd1;

            // L1D WR wait counter
            if (!l1d_wr_dram_req || (grant_mid == MID_L1D_WR && dram_req_ready_i))
                l1d_wr_wait_cnt_q <= '0;
            else if (l1d_wr_wait_cnt_q != '1)
                l1d_wr_wait_cnt_q <= l1d_wr_wait_cnt_q + 6'd1;
        end
    end

    // -------------------------------------------------------------------------
    // Unmapped Handlers for L1I and PTW
    // -------------------------------------------------------------------------
    logic       l1i_unmapped_rsp_q;
    logic [1:0] l1i_unmapped_tag_q;
    logic       ptw_unmapped_rsp_q;

    wire l1i_unmapped_fire = l1i_unmapped && !l1i_unmapped_rsp_q;
    wire ptw_unmapped_fire = ptw_unmapped && !ptw_unmapped_rsp_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            l1i_unmapped_rsp_q <= 1'b0;
            l1i_unmapped_tag_q <= 2'b0;
            ptw_unmapped_rsp_q <= 1'b0;
        end else begin
            // Single-cycle unmapped response generation
            l1i_unmapped_rsp_q <= l1i_unmapped_fire;
            if (l1i_unmapped_fire) l1i_unmapped_tag_q <= l1i_bus_rd_req_tag;

            ptw_unmapped_rsp_q <= ptw_unmapped_fire;
        end
    end

    // Ready acknowledgments back to Core Masters
    assign l1i_bus_rd_req_ready = l1i_unmapped ? (!l1i_unmapped_rsp_q) :
                                  ((grant_mid == MID_L1I) && dram_req_ready_i);

    assign ptw_mem_req_ready    = ptw_unmapped ? (!ptw_unmapped_rsp_q) :
                                  ((grant_mid == MID_PTW) && dram_req_ready_i);

    assign bus_rd_req_ready     = (grant_mid == MID_L1D_RD) && dram_req_ready_i;
    assign bus_wr_req_ready     = (grant_mid == MID_L1D_WR) && dram_req_ready_i;

    // -------------------------------------------------------------------------
    // External DRAM Request Output Multiplexing
    // -------------------------------------------------------------------------
    assign dram_req_valid_o = (grant_mid != MID_NONE);
    assign dram_req_write_o = (grant_mid == MID_L1D_WR);
    assign dram_req_mid_o   = grant_mid;

    assign dram_req_addr_o  = (grant_mid == MID_PTW)    ? ptw_mem_req_addr[55:6] :
                              (grant_mid == MID_L1I)    ? l1i_bus_rd_req_addr :
                              (grant_mid == MID_L1D_RD) ? bus_rd_req_addr :
                              (grant_mid == MID_L1D_WR) ? bus_wr_req_addr : 50'h0;

    assign dram_req_tag_o   = (grant_mid == MID_L1I)    ? l1i_bus_rd_req_tag :
                              (grant_mid == MID_L1D_RD) ? bus_rd_req_tag : 2'b0;

    assign dram_req_wdata_o = (grant_mid == MID_L1D_WR) ? bus_wr_req_data : 512'h0;

    // Save PTW 64-bit sub-line word offset when PTW DRAM request handshakes
    logic [2:0] ptw_word_idx_q;
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ptw_word_idx_q <= 3'd0;
        end else if (grant_mid == MID_PTW && dram_req_ready_i) begin
            ptw_word_idx_q <= ptw_mem_req_addr[5:3];
        end
    end

    // -------------------------------------------------------------------------
    // DRAM Response Demultiplexing to Core Masters
    // -------------------------------------------------------------------------
    assign dram_rd_rsp_ready_o = 1'b1;

    // Master 0: L1I Refill Response
    assign l1i_bus_rd_rsp_valid = l1i_unmapped_rsp_q || (dram_rd_rsp_valid_i && (dram_rd_rsp_mid_i == MID_L1I));
    assign l1i_bus_rd_rsp_tag   = l1i_unmapped_rsp_q ? l1i_unmapped_tag_q : dram_rd_rsp_tag_i;
    assign l1i_bus_rd_rsp_data  = l1i_unmapped_rsp_q ? 512'h0 : dram_rd_rsp_data_i;
    assign l1i_bus_rd_rsp_error = l1i_unmapped_rsp_q ? 1'b1 : dram_rd_rsp_error_i;

    // Master 1: L1D Demand Refill Response
    assign bus_rd_rsp_valid     = dram_rd_rsp_valid_i && (dram_rd_rsp_mid_i == MID_L1D_RD);
    assign bus_rd_rsp_tag       = dram_rd_rsp_tag_i;
    assign bus_rd_rsp_data      = dram_rd_rsp_data_i;

    // Master 2: L1D Dirty Eviction Writeback Ack
    assign bus_wr_rsp_valid     = dram_wr_rsp_valid_i;

    // Master 3: PTW Response
    assign ptw_mem_rsp_valid    = ptw_unmapped_rsp_q || (dram_rd_rsp_valid_i && (dram_rd_rsp_mid_i == MID_PTW));
    assign ptw_mem_rsp_error    = ptw_unmapped_rsp_q ? 1'b1 : dram_rd_rsp_error_i;
    assign ptw_mem_rsp_data     = ptw_unmapped_rsp_q ? 64'h0 :
                                  dram_rd_rsp_data_i[ptw_word_idx_q * 64 +: 64];

    // =========================================================================
    // 5. Slice-1 Core Subsystem Instance (`fursoy_s1_core`)
    // =========================================================================
    /* verilator lint_off PINCONNECTEMPTY */
    fursoy_s1_core #(
        .PRF_COUNT        (PRF_SIZE),
        .AREG_NUM         (AREG_COUNT),
        .ROB_NUM          (ROB_DEPTH),
        .CHKPT_NUM        (NUM_CHECKPOINTS),
        .SMP_COHERENCE_EN (1'b0)
    ) u_core (
        .clk_i            (clk_i),
        .rst_i            (rst_i),
        .mhartid_i        (64'd0),

        .frontend_en_i    (frontend_en_i),
        .priv_mode_i      (2'b11), // 2'b11 activates internal csr_priv_mode without override
        .mstatus_i        (64'h0), // 64'h0 activates internal csr_mstatus without override
        .satp_i           (64'h0), // 64'h0 activates internal csr_satp without override
        .pmp_allow_i      (1'b1),

        .trap_valid_i     (1'b0),
        .trap_target_i    (64'h0),
        .mret_valid_i     (1'b0),
        .mret_target_i    (64'h0),

        .sfence_vma_valid_i (1'b0),
        .sfence_vma_va_i    (64'h0),
        .sfence_vma_asid_i  (16'h0),

        // Legacy uop inputs
        .uop0_valid_i     (uop0_valid_i),
        .uop0_rs1_i       (uop0_rs1_i),
        .uop0_rs2_i       (uop0_rs2_i),
        .uop0_rd_i        (uop0_rd_i),
        .uop0_class_i     (uop0_class_i),
        .uop0_subop_i     (uop0_subop_i),
        .uop0_imm_i       (uop0_imm_i),
        .uop0_use_imm_i   (uop0_use_imm_i),
        .uop0_pc_i        (uop0_pc_i),
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

        .uop1_valid_i     (uop1_valid_i),
        .uop1_rs1_i       (uop1_rs1_i),
        .uop1_rs2_i       (uop1_rs2_i),
        .uop1_rd_i        (uop1_rd_i),
        .uop1_class_i     (uop1_class_i),
        .uop1_subop_i     (uop1_subop_i),
        .uop1_imm_i       (uop1_imm_i),
        .uop1_use_imm_i   (uop1_use_imm_i),
        .uop1_pc_i        (uop1_pc_i),
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

        .rename_ack_o     (rename_ack_o),
        .flush_valid_i    (1'b0),

        // Retirement interface
        .retire_ready_i   (1'b1),
        .retire_valid_o   (retire_valid_o),
        .retire_rd_o      (retire_rd_o),
        .retire_pnew_o    (),
        .retire_pold_o    (),
        .retire_is_branch_o(),
        .retire_chkpt_id_o(),
        .retire_pc_o      (retire_pc_o),

        .retire_exception_o (retire_exception_o),
        .retire_exc_cause_o (retire_exc_cause_o),
        .retire_exc_pc_o    (retire_exc_pc_o),

        // Observability
        .recovering_o     (),
        .reconstructing_o (),
        .rob_head_o       (),
        .rob_tail_o       (),
        .freelist_count_o (),
        .rob_count_o      (rob_count_o),
        .chkpt_free_count_o(),
        .dispatch_ready_o (dispatch_ready_o),
        .arat_map_o       (arat_map_o),
        .srat_map_o       (),
        .prf_ready_o      (),

        .comp_valid_o     (),
        .comp_rob_idx_o   (),
        .comp_epoch_o     (),
        .comp_preg_o      (),
        .comp_ack_o       (),
        .comp_fflags_o    (),

        .probe_paddr_i    (probe_paddr_i),
        .probe_pdata_o    (probe_pdata_o),

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

        // L1D Memory Channels
        .bus_rd_req_valid_o       (bus_rd_req_valid),
        .bus_rd_req_addr_o        (bus_rd_req_addr),
        .bus_rd_req_tag_o         (bus_rd_req_tag),
        .bus_rd_req_op_o          (),
        .bus_rd_req_ready_i       (bus_rd_req_ready),
        .bus_rd_rsp_valid_i       (bus_rd_rsp_valid),
        .bus_rd_rsp_tag_i         (bus_rd_rsp_tag),
        .bus_rd_rsp_data_i        (bus_rd_rsp_data),
        .bus_rd_rsp_state_i       (MESI_I),
        .bus_rd_rsp_has_data_i    (1'b0),

        .bus_wr_req_valid_o       (bus_wr_req_valid),
        .bus_wr_req_addr_o        (bus_wr_req_addr),
        .bus_wr_req_data_o        (bus_wr_req_data),
        .bus_wr_req_dirty_o       (),
        .bus_wr_req_ready_i       (bus_wr_req_ready),
        .bus_wr_rsp_valid_i       (bus_wr_rsp_valid),

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

        // L1I Memory Channel
        .l1i_bus_rd_req_valid_o   (l1i_bus_rd_req_valid),
        .l1i_bus_rd_req_addr_o    (l1i_bus_rd_req_addr),
        .l1i_bus_rd_req_tag_o     (l1i_bus_rd_req_tag),
        .l1i_bus_rd_req_ready_i   (l1i_bus_rd_req_ready),
        .l1i_bus_rd_rsp_valid_i   (l1i_bus_rd_rsp_valid),
        .l1i_bus_rd_rsp_tag_i     (l1i_bus_rd_rsp_tag),
        .l1i_bus_rd_rsp_data_i    (l1i_bus_rd_rsp_data),
        .l1i_bus_rd_rsp_error_i   (l1i_bus_rd_rsp_error),
        .l1i_inval_line_valid_i   (1'b0),
        .l1i_inval_line_addr_i    (50'd0),

        // Shared PTW Memory Channel
        .ptw_mem_req_valid_o      (ptw_mem_req_valid),
        .ptw_mem_req_addr_o       (ptw_mem_req_addr),
        .ptw_mem_req_ready_i      (ptw_mem_req_ready),
        .ptw_mem_rsp_valid_i      (ptw_mem_rsp_valid),
        .ptw_mem_rsp_data_i       (ptw_mem_rsp_data),
        .ptw_mem_rsp_error_i      (ptw_mem_rsp_error),

        // Frontend Diagnostics
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

        // CSR Observability
        .csr_priv_mode_o          (csr_priv_mode_o),
        .csr_mstatus_o            (csr_mstatus_o),
        .csr_satp_o               (csr_satp_o),
        .csr_mepc_o               (csr_mepc_o),
        .csr_mcause_o             (csr_mcause_o),
        .csr_mtval_o              (csr_mtval_o),
        .csr_sepc_o               (csr_sepc_o),
        .csr_scause_o             (csr_scause_o),
        .csr_stval_o              (csr_stval_o),
        .csr_mtvec_o              (csr_mtvec_o),
        .csr_stvec_o              (csr_stvec_o),

        // Interrupt Inputs & Status
        .irq_timer_i              (core_irq_timer),
        .irq_software_i           (core_irq_software),
        .irq_external_i           (core_irq_external),
        .irq_seip_i               (core_irq_seip),
        .mtime_i                  (clint_mtime),

        .wfi_sleep_o              (wfi_sleep_o),
        .irq_pending_valid_o      (),
        .irq_pending_cause_o      (),
        .csr_mip_o                (csr_mip_o),
        .csr_mie_o                (csr_mie_o),
        .csr_mideleg_o            (),
        .csr_sie_o                (),
        .csr_sip_o                (),

        .test_csr_we_i            (test_csr_we_i),
        .test_csr_addr_i          (test_csr_addr_i),
        .test_csr_wdata_i         (test_csr_wdata_i),

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

        .snoop_req_valid_i        (1'b0),
        .snoop_req_addr_i         (56'h0),
        .snoop_req_type_i         (2'b0),
        .snoop_req_ready_o        (),
        .snoop_rsp_valid_o        (),
        .snoop_rsp_has_data_o     (),
        .snoop_rsp_was_dirty_o    (),
        .snoop_rsp_data_o         (),
        .snoop_rsp_ready_i        (1'b1),
        .snoop_rsp_ack_only_o     (),

        .test_ev_fp_issue_i       (1'b0),
        .test_ev_fp_fma_busy_i    (1'b0),
        .test_ev_fp_fdiv_stall_i  (1'b0),
        .test_ev_fp_rename_stall_i(1'b0),
        .test_ev_vec_uop_commit_i (1'b0),
        .test_ev_vec_mem_traffic_i(1'b0),
        .test_ev_vec_viq_full_i   (1'b0),
        .test_ev_vec_fof_trunc_i  (1'b0),

        .mcycle_o                 (mcycle_o),
        .minstret_o               (minstret_o),
        .mhpmcounter_o            (),
        .cpi_category_o           (cpi_category_o),
        .cpi_active_owner_o       (),
        .raw_event_pulse_o        (raw_event_pulse_o),
        .raw_event_ext_pulse_o    (),

        // Uncached MMIO channel
        .mmio_req_valid_o         (mmio_req_valid),
        .mmio_req_addr_o          (mmio_req_addr),
        .mmio_req_is_store_o      (mmio_req_is_store),
        .mmio_req_write_o         (mmio_req_write),
        .mmio_req_size_o          (mmio_req_size),
        .mmio_req_wdata_o         (mmio_req_wdata),
        .mmio_req_wstrb_o         (mmio_req_wstrb),
        .mmio_req_ready_i         (mmio_req_ready),

        .mmio_rsp_valid_i         (mmio_rsp_valid),
        .mmio_rsp_rdata_i         (mmio_rsp_rdata),
        .mmio_rsp_error_i         (mmio_rsp_error),
        .mmio_rsp_ready_o         (mmio_rsp_ready)
    );
    /* verilator lint_on PINCONNECTEMPTY */

endmodule

`endif // FURSOY_S1_SOC_SV
