// Slice-0 fetch transaction block. It deliberately does not decode or retire
// instructions; those behaviors begin only with the architectural core stage.
module fursoy_s0_fetch #(
    parameter logic [63:0] RESET_PC = 64'h0000_0000_8000_0000
) (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        fetch_enable_i,
    input  logic        redirect_i,
    input  logic [63:0] fetch_pc_i,

    output logic        imem_req_valid_o,
    input  logic        imem_req_ready_i,
    output logic [63:0] imem_req_addr_o,

    input  logic        imem_rsp_valid_i,
    output logic        imem_rsp_ready_o,
    input  logic [31:0] imem_rsp_insn_i,
    input  logic        imem_rsp_error_i,
    input  logic        imem_rsp_page_fault_i,

    output logic        fetched_valid_o,
    input  logic        fetched_ready_i,
    output logic [63:0] fetched_pc_o,
    output logic [31:0] fetched_insn_o,
    output logic        fetched_error_o,
    output logic        fetched_page_fault_o
);
    typedef enum logic [2:0] { REQUEST, RESPONSE, COMPLETE, DISCARD } state_t;
    state_t state_q;
    logic [63:0] fetched_pc_q;

    initial begin
        assert (RESET_PC[1:0] == 2'b00) else $fatal(1, "RESET_PC must be instruction aligned");
    end

    assign imem_req_valid_o = !rst_i && fetch_enable_i && (state_q == REQUEST);
    assign imem_req_addr_o = fetch_pc_i;
    assign imem_rsp_ready_o = !rst_i && ((state_q == RESPONSE) || (state_q == DISCARD));
    assign fetched_valid_o = !rst_i && (state_q == COMPLETE);
    assign fetched_pc_o = fetched_valid_o ? fetched_pc_q : '0;
    assign fetched_insn_o = fetched_valid_o ? fetched_insn_q : '0;
    assign fetched_error_o = fetched_valid_o && fetched_error_q;
    assign fetched_page_fault_o = fetched_valid_o && fetched_page_fault_q;

    logic [31:0] fetched_insn_q;
    logic fetched_error_q;
    logic fetched_page_fault_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q <= REQUEST;
            fetched_pc_q <= RESET_PC;
            fetched_insn_q <= '0;
            fetched_error_q <= 1'b0;
            fetched_page_fault_q <= 1'b0;
        end else begin
            if (redirect_i) begin
                // The instruction interface has no transaction IDs.  If a trap
                // redirects while a response is outstanding, discard that stale
                // response before issuing the redirected request.
                if ((state_q == RESPONSE && !imem_rsp_valid_i) ||
                    (state_q == REQUEST && imem_req_valid_o && imem_req_ready_i)) state_q <= DISCARD;
                else state_q <= REQUEST;
            end else case (state_q)
                REQUEST: if (imem_req_valid_o && imem_req_ready_i) begin
                    fetched_pc_q <= fetch_pc_i;
                    state_q <= RESPONSE;
                end
                RESPONSE: if (imem_rsp_valid_i) begin
                    fetched_insn_q <= imem_rsp_insn_i;
                    fetched_error_q <= imem_rsp_error_i;
                    fetched_page_fault_q <= imem_rsp_page_fault_i;
                    state_q <= COMPLETE;
                end
                COMPLETE: if (fetched_ready_i) state_q <= REQUEST;
                DISCARD: if (imem_rsp_valid_i) state_q <= REQUEST;
                default: $fatal(1, "Invalid fetch state");
            endcase
        end
    end
endmodule
