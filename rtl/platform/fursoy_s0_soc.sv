// Slice-0 single-hart integration. The architectural data port is decoded
// between external RAM and the local CLINT window.
module fursoy_s0_soc #(
    parameter logic [63:0] RESET_PC = 64'h0000_0000_8000_0000,
    parameter logic [63:0] RESET_MTVEC = 64'h0000_0000_0000_0000,
    parameter logic [63:0] CLINT_BASE_ADDR = 64'h0000_0000_0200_0000,
    parameter logic [63:0] PLIC_BASE_ADDR  = 64'h0000_0000_0C00_0000,
    parameter logic [63:0] UART_BASE_ADDR  = 64'h0000_0000_1000_0000
) (
    input logic clk_i, input logic rst_i,
    output logic imem_req_valid_o, input logic imem_req_ready_i,
    output logic [63:0] imem_req_addr_o, input logic imem_rsp_valid_i,
    output logic imem_rsp_ready_o, input logic [31:0] imem_rsp_insn_i,
    input logic imem_rsp_error_i,
    output logic ram_req_valid_o, input logic ram_req_ready_i,
    output logic ram_req_store_o, output logic ram_req_ptw_o, output logic [63:0] ram_req_addr_o,
    output logic [2:0] ram_req_size_o, output logic [63:0] ram_req_store_data_o,
    input logic ram_req_error_i, input logic ram_rsp_valid_i,
    output logic ram_rsp_ready_o, input logic [63:0] ram_rsp_data_i,
    input logic ram_rsp_error_i,
    input logic [31:0] irq_sources_i,
    input logic irq_external_i,
    output logic uart_tx_valid_o,
    output logic [7:0] uart_tx_data_o,
    output logic commit_valid_o, output logic [63:0] commit_pc_o,
    output logic [31:0] commit_insn_o, output logic commit_rd_write_o,
    output logic [4:0] commit_rd_o, output logic [63:0] commit_rd_data_o,
    output logic fence_i_valid_o, output logic trap_valid_o,
    output logic [63:0] trap_pc_o, output logic [31:0] trap_insn_o,
    output logic [63:0] csr_mstatus_o, output logic [63:0] csr_mie_o,
    output logic [63:0] csr_mtvec_o, output logic [63:0] csr_mscratch_o,
    output logic [63:0] csr_mepc_o, output logic [63:0] csr_mcause_o,
    output logic [63:0] csr_mtval_o, output logic [63:0] csr_mip_o
);
    localparam logic [63:0] CLINT_END_ADDR = CLINT_BASE_ADDR + 64'h1_0000;
    localparam logic [63:0] PLIC_END_ADDR  = PLIC_BASE_ADDR  + 64'h40_0000;
    localparam logic [63:0] UART_END_ADDR  = UART_BASE_ADDR  + 64'h1000;
    typedef enum logic [2:0] {RSP_NONE, RSP_RAM, RSP_CLINT, RSP_PLIC, RSP_UART, RSP_ERROR} rsp_owner_t;
    rsp_owner_t rsp_owner_q;
    logic core_req_valid, core_req_ready, core_req_store, core_req_ptw, core_req_error;
    logic [63:0] core_req_addr, core_req_store_data;
    logic [2:0] core_req_size;
    logic core_rsp_valid, core_rsp_ready, core_rsp_error;
    logic [63:0] core_rsp_data;
    logic select_clint, select_plic, select_uart, reject_ptw_mmio, request_to_ram, request_fire;
    logic clint_req_ready, clint_rsp_valid, clint_rsp_ready;
    logic [63:0] clint_rsp_data;
    logic clint_rsp_error, clint_access_error, irq_software, irq_timer;
    logic plic_req_ready, plic_rsp_valid, plic_rsp_ready;
    logic [63:0] plic_rsp_data;
    logic plic_rsp_error, plic_access_error, plic_irq_meip, plic_irq_seip;
    logic [31:0] plic_irq_sources;
    logic uart_req_ready, uart_rsp_valid, uart_rsp_ready;
    logic [63:0] uart_rsp_data;
    logic uart_rsp_error, uart_access_error, uart_irq;

    assign select_clint = !core_req_ptw && (core_req_addr >= CLINT_BASE_ADDR) && (core_req_addr < CLINT_END_ADDR);
    assign select_plic  = !core_req_ptw && (core_req_addr >= PLIC_BASE_ADDR)  && (core_req_addr < PLIC_END_ADDR);
    assign select_uart  = !core_req_ptw && (core_req_addr >= UART_BASE_ADDR)  && (core_req_addr < UART_END_ADDR);
    assign reject_ptw_mmio = core_req_ptw && (((core_req_addr >= CLINT_BASE_ADDR) && (core_req_addr < CLINT_END_ADDR)) ||
                                              ((core_req_addr >= PLIC_BASE_ADDR)  && (core_req_addr < PLIC_END_ADDR)) ||
                                              ((core_req_addr >= UART_BASE_ADDR)  && (core_req_addr < UART_END_ADDR)));
    assign request_to_ram = !select_clint && !select_plic && !select_uart && !reject_ptw_mmio;
    assign request_fire = core_req_valid && core_req_ready;
    assign ram_req_valid_o = core_req_valid && request_to_ram;
    assign ram_req_store_o = core_req_store;
    assign ram_req_ptw_o = core_req_ptw;
    assign ram_req_addr_o = core_req_addr;
    assign ram_req_size_o = core_req_size;
    assign ram_req_store_data_o = core_req_store_data;
    assign core_req_ready = select_clint ? clint_req_ready :
                            select_plic  ? plic_req_ready  :
                            select_uart  ? uart_req_ready  :
                            (reject_ptw_mmio ? 1'b1 : ram_req_ready_i);
    assign core_req_error = select_clint ? clint_access_error :
                            select_plic  ? plic_access_error  :
                            select_uart  ? uart_access_error  :
                            (reject_ptw_mmio ? 1'b0 : ram_req_error_i);
    assign core_rsp_valid = (rsp_owner_q == RSP_CLINT) ? clint_rsp_valid :
                            (rsp_owner_q == RSP_PLIC)  ? plic_rsp_valid  :
                            (rsp_owner_q == RSP_UART)  ? uart_rsp_valid  :
                            (rsp_owner_q == RSP_RAM)   ? ram_rsp_valid_i  :
                            (rsp_owner_q == RSP_ERROR);
    assign core_rsp_data  = (rsp_owner_q == RSP_CLINT) ? clint_rsp_data :
                            (rsp_owner_q == RSP_PLIC)  ? plic_rsp_data  :
                            (rsp_owner_q == RSP_UART)  ? uart_rsp_data  : ram_rsp_data_i;
    assign core_rsp_error = (rsp_owner_q == RSP_CLINT) ? clint_rsp_error :
                            (rsp_owner_q == RSP_PLIC)  ? plic_rsp_error  :
                            (rsp_owner_q == RSP_UART)  ? uart_rsp_error  :
                            (rsp_owner_q == RSP_ERROR) ? 1'b1 : ram_rsp_error_i;
    assign clint_rsp_ready = core_rsp_ready && (rsp_owner_q == RSP_CLINT);
    assign plic_rsp_ready  = core_rsp_ready && (rsp_owner_q == RSP_PLIC);
    assign uart_rsp_ready  = (rsp_owner_q == RSP_NONE) || (core_rsp_ready && (rsp_owner_q == RSP_UART));
    // With no owner, drain unsolicited/stale responses except while accepting
    // a new RAM load. A zero-latency response to that load is backpressured for
    // one cycle, then accepted after RSP_RAM ownership is registered.
    assign ram_rsp_ready_o = rst_i ||
                             (rsp_owner_q == RSP_NONE &&
                              !(request_fire && !core_req_store && request_to_ram)) ||
                             (core_rsp_ready && rsp_owner_q == RSP_RAM);

    always_ff @(posedge clk_i) begin
        if (rst_i) rsp_owner_q <= RSP_NONE;
        else begin
            if (request_fire && !core_req_store)
                rsp_owner_q <= select_clint ? RSP_CLINT :
                               select_plic  ? RSP_PLIC  :
                               select_uart  ? RSP_UART  :
                               (reject_ptw_mmio ? RSP_ERROR : RSP_RAM);
            if (core_rsp_valid && core_rsp_ready) rsp_owner_q <= RSP_NONE;
        end
    end

    // The external request channel follows the usual valid/ready stability
    // rule. Keep this executable in simulation so future core/interconnect
    // changes cannot silently violate the contract.
    logic ram_stalled_q;
    logic ram_stalled_store_q;
    logic ram_stalled_ptw_q;
    logic [63:0] ram_stalled_addr_q, ram_stalled_data_q;
    logic [2:0] ram_stalled_size_q;
    always_ff @(posedge clk_i) begin
        if (rst_i) ram_stalled_q <= 1'b0;
        else begin
            if (ram_stalled_q) begin
                assert (ram_req_valid_o && ram_req_store_o == ram_stalled_store_q &&
                        ram_req_ptw_o == ram_stalled_ptw_q &&
                        ram_req_addr_o == ram_stalled_addr_q && ram_req_size_o == ram_stalled_size_q &&
                        ram_req_store_data_o == ram_stalled_data_q)
                    else $fatal(1, "RAM request changed while stalled");
            end
            if (ram_req_valid_o && !ram_req_ready_i && !ram_stalled_q) begin
                ram_stalled_store_q <= ram_req_store_o;
                ram_stalled_ptw_q <= ram_req_ptw_o;
                ram_stalled_addr_q <= ram_req_addr_o;
                ram_stalled_size_q <= ram_req_size_o;
                ram_stalled_data_q <= ram_req_store_data_o;
            end
            ram_stalled_q <= ram_req_valid_o && !ram_req_ready_i;
        end
    end

    fursoy_s0_clint #(.BASE_ADDR(CLINT_BASE_ADDR)) clint (
        .clk_i, .rst_i, .req_valid_i(core_req_valid && select_clint),
        .req_ready_o(clint_req_ready), .req_store_i(core_req_store),
        .req_addr_i(core_req_addr), .req_size_i(core_req_size),
        .req_store_data_i(core_req_store_data), .rsp_valid_o(clint_rsp_valid),
        .rsp_ready_i(clint_rsp_ready), .rsp_data_o(clint_rsp_data),
        .rsp_error_o(clint_rsp_error), .access_error_o(clint_access_error),
        .irq_software_o(irq_software), .irq_timer_o(irq_timer)
    );

    // PLIC Source 1 is exclusively owned by the UART peripheral.
    // External/injected irq_sources_i[1:0] are not production interrupt producers.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_irq = &{1'b0, irq_sources_i[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */
    assign plic_irq_sources = {irq_sources_i[31:2], uart_irq, 1'b0};

    fursoy_s0_plic #(.BASE_ADDR(PLIC_BASE_ADDR)) plic (
        .clk_i, .rst_i, .req_valid_i(core_req_valid && select_plic),
        .req_ready_o(plic_req_ready), .req_store_i(core_req_store),
        .req_addr_i(core_req_addr), .req_size_i(core_req_size),
        .req_store_data_i(core_req_store_data), .rsp_valid_o(plic_rsp_valid),
        .rsp_ready_i(plic_rsp_ready), .rsp_data_o(plic_rsp_data),
        .rsp_error_o(plic_rsp_error), .access_error_o(plic_access_error),
        .irq_sources_i(plic_irq_sources), .irq_meip_o(plic_irq_meip),
        .irq_seip_o(plic_irq_seip)
    );

    fursoy_s0_uart #(.BASE_ADDR(UART_BASE_ADDR)) uart (
        .clk_i, .rst_i, .req_valid_i(core_req_valid && select_uart),
        .req_ready_o(uart_req_ready), .req_store_i(core_req_store),
        .req_addr_i(core_req_addr), .req_size_i(core_req_size),
        .req_store_data_i(core_req_store_data), .rsp_valid_o(uart_rsp_valid),
        .rsp_ready_i(uart_rsp_ready), .rsp_data_o(uart_rsp_data),
        .rsp_error_o(uart_rsp_error), .access_error_o(uart_access_error),
        .tx_valid_o(uart_tx_valid_o), .tx_data_o(uart_tx_data_o),
        .irq_o(uart_irq)
    );

    /* verilator lint_off PINCONNECTEMPTY */
    fursoy_s0_core #(.RESET_PC(RESET_PC), .RESET_MTVEC(RESET_MTVEC)) core (
        .clk_i, .rst_i, .imem_req_valid_o, .imem_req_ready_i, .imem_req_addr_o,
        .imem_rsp_valid_i, .imem_rsp_ready_o, .imem_rsp_insn_i, .imem_rsp_error_i,
        .dmem_req_valid_o(core_req_valid), .dmem_req_ready_i(core_req_ready),
        .dmem_req_store_o(core_req_store), .dmem_req_addr_o(core_req_addr),
        .dmem_req_ptw_o(core_req_ptw),
        .dmem_req_size_o(core_req_size), .dmem_req_store_data_o(core_req_store_data),
        .dmem_req_error_i(core_req_error), .dmem_rsp_valid_i(core_rsp_valid),
        .dmem_rsp_ready_o(core_rsp_ready), .dmem_rsp_data_i(core_rsp_data),
        .dmem_rsp_error_i(core_rsp_error), .irq_software_i(irq_software),
        .irq_timer_i(irq_timer), .irq_external_i(plic_irq_meip | irq_external_i),
        .irq_seip_i(plic_irq_seip),
        .commit_valid_o, .commit_pc_o, .commit_insn_o, .commit_rd_write_o,
        .commit_rd_o, .commit_rd_data_o, .fence_i_valid_o, .trap_valid_o,
        .trap_pc_o, .trap_insn_o, .csr_mstatus_o, .csr_mie_o, .csr_mtvec_o,
        .csr_mscratch_o, .csr_mepc_o, .csr_mcause_o, .csr_mtval_o, .csr_mip_o,
        .priv_mode_o(), .csr_medeleg_o(), .csr_mideleg_o(), .csr_sstatus_o(), .csr_stvec_o(),
        .csr_sie_o(), .csr_sip_o(),
        .csr_sscratch_o(), .csr_sepc_o(), .csr_scause_o(), .csr_stval_o()
        ,.csr_satp_o(), .csr_menvcfg_o(), .csr_senvcfg_o(), .csr_pmpcfg0_o(), .csr_pmpcfg2_o()
    );
    /* verilator lint_on PINCONNECTEMPTY */
endmodule
