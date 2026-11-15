`ifndef FURSOY_S0_CLINT_SV
`define FURSOY_S0_CLINT_SV

// Minimal single-hart CLINT-style interrupt source.  This block is platform
// logic: it exposes level-sensitive interrupt pins and deliberately contains
// no core trap or CSR policy.
module fursoy_s0_clint #(
    parameter logic [63:0] BASE_ADDR = 64'h0000_0000_0200_0000
) (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        req_valid_i,
    output logic        req_ready_o,
    input  logic        req_store_i,
    input  logic [63:0] req_addr_i,
    input  logic [2:0]  req_size_i,
    input  logic [63:0] req_store_data_i,
    output logic        rsp_valid_o,
    input  logic        rsp_ready_i,
    output logic [63:0] rsp_data_o,
    output logic        rsp_error_o,
    output logic        access_error_o,
    output logic        irq_software_o,
    output logic        irq_timer_o,
    output logic [63:0] mtime_o
);
    localparam logic [63:0] MSIP_ADDR     = BASE_ADDR;
    localparam logic [63:0] MTIMECMP_ADDR = BASE_ADDR + 64'h4000;
    localparam logic [63:0] MTIME_ADDR    = BASE_ADDR + 64'hbff8;

    logic msip_q;
    logic [63:0] mtimecmp_q, mtime_q;
    logic rsp_valid_q, rsp_error_q;
    logic [63:0] rsp_data_q;
    logic req_fire, valid_access;

    always_comb begin
        valid_access = 1'b0;
        if (req_addr_i == MSIP_ADDR && req_size_i == 3'd2) valid_access = 1'b1;
        if ((req_addr_i == MTIMECMP_ADDR || req_addr_i == MTIME_ADDR) && req_size_i == 3'd3)
            valid_access = 1'b1;
    end

    assign req_ready_o = !rsp_valid_q;
    assign req_fire = req_valid_i && req_ready_o;
    assign access_error_o = req_fire && !valid_access;
    assign rsp_valid_o = rsp_valid_q;
    assign rsp_error_o = rsp_error_q;
    assign rsp_data_o = rsp_data_q;
    assign irq_software_o = msip_q;
    assign irq_timer_o = (mtime_q >= mtimecmp_q);
    assign mtime_o = mtime_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            msip_q <= 1'b0;
            mtime_q <= '0;
            mtimecmp_q <= '1; // Disabled until software programs a threshold.
            rsp_valid_q <= 1'b0;
            rsp_error_q <= 1'b0;
            rsp_data_q <= '0;
        end else begin
            mtime_q <= mtime_q + 64'd1;
            if (rsp_valid_q && rsp_ready_i) rsp_valid_q <= 1'b0;
            if (req_fire) begin
                if (req_store_i) begin
                    if (valid_access) begin
                        if (req_addr_i == MSIP_ADDR) msip_q <= req_store_data_i[0];
                        else if (req_addr_i == MTIMECMP_ADDR) mtimecmp_q <= req_store_data_i;
                        else if (req_addr_i == MTIME_ADDR) mtime_q <= req_store_data_i;
                    end
                end else begin
                    rsp_valid_q <= 1'b1;
                    rsp_error_q <= !valid_access;
                    if (!valid_access) rsp_data_q <= '0;
                    else if (req_addr_i == MSIP_ADDR) rsp_data_q <= {63'd0, msip_q};
                    else if (req_addr_i == MTIMECMP_ADDR) rsp_data_q <= mtimecmp_q;
                    else rsp_data_q <= mtime_q;
                end
            end
        end
    end
endmodule

`endif // FURSOY_S0_CLINT_SV
