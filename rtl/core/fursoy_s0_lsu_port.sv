// One-outstanding-transaction LSU port with RV64A atomic support.
// Implements LR/SC reservation tracking, exact-address/size matching,
// and 2-phase serialized AMO Read-Modify-Write FSM.
module fursoy_s0_lsu_port (
    input logic clk_i, input logic rst_i,
    input logic issue_valid_i, output logic issue_ready_o,
    input logic issue_store_i,
    input logic issue_lr_i,
    input logic issue_sc_i,
    input logic issue_amo_i,
    input logic [4:0] issue_amo_op_i,
    input logic [63:0] issue_addr_i, input logic [2:0] issue_size_i,
    input logic issue_unsigned_i, input logic [63:0] issue_store_data_i, input logic [4:0] issue_rd_i,
    input logic [63:0] issue_pc_i, input logic [31:0] issue_insn_i,
    input logic res_invalidate_i,

    output logic dmem_req_valid_o, input logic dmem_req_ready_i, output logic dmem_req_store_o,
    output logic dmem_req_amo_o, output logic dmem_req_sc_o,
    output logic res_valid_o,
    output logic [55:0] res_exact_pa_o,
    output logic [2:0]  res_size_o,
    input  logic dmem_sc_success_i,
    output logic [63:0] dmem_req_addr_o, output logic [2:0] dmem_req_size_o,
    output logic [63:0] dmem_req_store_data_o, input logic dmem_req_error_i,
    input logic dmem_req_page_fault_i,

    input logic dmem_rsp_valid_i, output logic dmem_rsp_ready_o,
    input logic [63:0] dmem_rsp_data_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [63:0] dmem_rsp_paddr_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic dmem_rsp_error_i,
    input logic dmem_rsp_page_fault_i,

    output logic dmem_amo_write_valid_o,
    output logic [63:0] dmem_amo_write_data_o,
    input  logic dmem_amo_write_ready_i,
    input  logic dmem_amo_write_error_i,

    output logic retire_valid_o, output logic retire_rd_write_o, output logic [4:0] retire_rd_o,
    output logic [63:0] retire_rd_data_o, output logic [63:0] retire_pc_o,
    output logic [31:0] retire_insn_o,
    output logic fault_valid_o, output logic fault_store_o,
    output logic [63:0] fault_addr_o, output logic [63:0] fault_pc_o,
    output logic [31:0] fault_insn_o, output logic fault_page_o
);
    typedef enum logic [1:0] {IDLE, REQUEST, RESPONSE, AMO_WRITE} state_t;
    state_t state_q;
    logic store_q, lr_q, sc_q, amo_q, unsigned_q;
    logic [4:0] amo_op_q;
    logic [63:0] addr_q, store_data_q;
    logic [2:0] size_q;
    logic [4:0] rd_q;
    logic [63:0] pc_q; logic [31:0] insn_q;
    logic [63:0] mem_orig_q;
    logic [63:0] amo_new_q;

    // Reservation state
    logic        res_valid_q;
    logic [55:0] res_exact_pa_q;
    logic [2:0]  res_size_q;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [49:0] res_granule_pa_q;
    /* verilator lint_on UNUSEDSIGNAL */

    assign res_valid_o    = res_valid_q;
    assign res_exact_pa_o = res_exact_pa_q;
    assign res_size_o     = res_size_q;

    function automatic logic [63:0] extend_load(input logic [63:0] value, input logic [2:0] size, input logic unsigned_load);
        case (size)
            3'd0: extend_load = unsigned_load ? {56'd0, value[7:0]} : {{56{value[7]}}, value[7:0]};
            3'd1: extend_load = unsigned_load ? {48'd0, value[15:0]} : {{48{value[15]}}, value[15:0]};
            3'd2: extend_load = unsigned_load ? {32'd0, value[31:0]} : {{32{value[31]}}, value[31:0]};
            default: extend_load = value;
        endcase
    endfunction

    function automatic logic [63:0] calc_amo(
        input logic [4:0]  amo_op,
        input logic [2:0]  size,
        input logic [63:0] mem_val,
        input logic [63:0] rs2_val
    );
        logic is_word;
        is_word = (size == 3'd2);
        if (is_word) begin
            logic [31:0] a, b, res;
            a = mem_val[31:0];
            b = rs2_val[31:0];
            case (amo_op)
                5'b00001: res = b;                                                          // AMOSWAP
                5'b00000: res = a + b;                                                      // AMOADD
                5'b00100: res = a ^ b;                                                      // AMOXOR
                5'b01100: res = a & b;                                                      // AMOAND
                5'b01000: res = a | b;                                                      // AMOOR
                5'b10000: res = ($signed(a) < $signed(b)) ? a : b;                         // AMOMIN
                5'b10100: res = ($signed(a) > $signed(b)) ? a : b;                         // AMOMAX
                5'b11000: res = ($unsigned(a) < $unsigned(b)) ? a : b;                     // AMOMINU
                5'b11100: res = ($unsigned(a) > $unsigned(b)) ? a : b;                     // AMOMAXU
                default:  res = a;
            endcase
            calc_amo = {{32{res[31]}}, res};
        end else begin
            logic [63:0] a, b, res;
            a = mem_val;
            b = rs2_val;
            case (amo_op)
                5'b00001: res = b;                                                          // AMOSWAP
                5'b00000: res = a + b;                                                      // AMOADD
                5'b00100: res = a ^ b;                                                      // AMOXOR
                5'b01100: res = a & b;                                                      // AMOAND
                5'b01000: res = a | b;                                                      // AMOOR
                5'b10000: res = ($signed(a) < $signed(b)) ? a : b;                         // AMOMIN
                5'b10100: res = ($signed(a) > $signed(b)) ? a : b;                         // AMOMAX
                5'b11000: res = ($unsigned(a) < $unsigned(b)) ? a : b;                     // AMOMINU
                5'b11100: res = ($unsigned(a) > $unsigned(b)) ? a : b;                     // AMOMAXU
                default:  res = a;
            endcase
            calc_amo = res;
        end
    endfunction

    assign issue_ready_o = state_q == IDLE;
    assign dmem_req_valid_o = !rst_i && (state_q == REQUEST);
    assign dmem_req_store_o = store_q && !amo_q;
    assign dmem_req_amo_o   = amo_q;
    assign dmem_req_sc_o    = sc_q;
    assign dmem_req_addr_o  = addr_q;
    assign dmem_req_size_o  = size_q;
    assign dmem_req_store_data_o = store_data_q;
    assign dmem_rsp_ready_o = !rst_i && (state_q == RESPONSE);

    assign dmem_amo_write_valid_o = !rst_i && (state_q == AMO_WRITE);
    assign dmem_amo_write_data_o  = amo_new_q;

    assign fault_valid_o = (state_q == REQUEST && (store_q || amo_q) && dmem_req_ready_i && dmem_req_error_i) ||
                           (state_q == RESPONSE && dmem_rsp_valid_i && dmem_rsp_error_i) ||
                           (state_q == AMO_WRITE && dmem_amo_write_ready_i && dmem_amo_write_error_i);
    assign fault_store_o = fault_valid_o && (store_q || amo_q);
    assign fault_addr_o  = fault_valid_o ? addr_q : '0;
    assign fault_pc_o    = fault_valid_o ? pc_q : '0;
    assign fault_insn_o  = fault_valid_o ? insn_q : '0;
    assign fault_page_o  = fault_valid_o && ((state_q == REQUEST) ? dmem_req_page_fault_i : dmem_rsp_page_fault_i);

    assign retire_valid_o = ((state_q == REQUEST && store_q && !amo_q && dmem_req_ready_i && !dmem_req_error_i) ||
                             (state_q == RESPONSE && !amo_q && dmem_rsp_valid_i && !dmem_rsp_error_i) ||
                             (state_q == AMO_WRITE && dmem_amo_write_ready_i && !dmem_amo_write_error_i));
    assign retire_rd_write_o = retire_valid_o && (rd_q != 5'd0) && (!store_q || sc_q || amo_q);
    assign retire_rd_o = retire_valid_o ? rd_q : 5'd0;
    assign retire_pc_o = retire_valid_o ? pc_q : 64'd0;
    assign retire_insn_o = retire_valid_o ? insn_q : 32'd0;

    always_comb begin
        if (sc_q) begin
            retire_rd_data_o = dmem_sc_success_i ? 64'd0 : 64'd1;
        end else if (amo_q) begin
            retire_rd_data_o = (size_q == 3'd2) ? {{32{mem_orig_q[31]}}, mem_orig_q[31:0]} : mem_orig_q;
        end else begin
            // Normal load or LR
            retire_rd_data_o = extend_load(dmem_rsp_data_i, size_q, unsigned_q);
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            res_valid_q      <= 1'b0;
            res_exact_pa_q   <= '0;
            res_size_q       <= '0;
            res_granule_pa_q <= '0;
        end else begin
            if (res_invalidate_i) begin
                res_valid_q <= 1'b0;
            end else if (retire_valid_o) begin
                if (lr_q) begin
                    res_valid_q      <= 1'b1;
                    res_exact_pa_q   <= dmem_rsp_paddr_i[55:0];
                    res_size_q       <= size_q;
                    res_granule_pa_q <= dmem_rsp_paddr_i[55:6];
                end else if (store_q || sc_q || amo_q) begin
                    res_valid_q <= 1'b0;
                end
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q      <= IDLE;
            store_q      <= 1'b0;
            lr_q         <= 1'b0;
            sc_q         <= 1'b0;
            amo_q        <= 1'b0;
            unsigned_q   <= 1'b0;
            amo_op_q     <= '0;
            addr_q       <= '0;
            store_data_q <= '0;
            size_q       <= '0;
            rd_q         <= '0;
            pc_q         <= '0;
            insn_q       <= '0;
            mem_orig_q   <= '0;
            amo_new_q    <= '0;
        end else case (state_q)
            IDLE: begin
                if (issue_valid_i) begin
                    store_q      <= issue_store_i;
                    lr_q         <= issue_lr_i;
                    sc_q         <= issue_sc_i;
                    amo_q        <= issue_amo_i;
                    amo_op_q     <= issue_amo_op_i;
                    addr_q       <= issue_addr_i;
                    store_data_q <= issue_store_data_i;
                    size_q       <= issue_size_i;
                    unsigned_q   <= issue_unsigned_i;
                    rd_q         <= issue_rd_i;
                    pc_q         <= issue_pc_i;
                    insn_q       <= issue_insn_i;
                    state_q      <= REQUEST;
                end
            end
            REQUEST: begin
                if (dmem_req_ready_i) begin
                    if (dmem_req_error_i && (store_q || amo_q)) begin
                        state_q <= IDLE;
                    end else if (store_q && !amo_q) begin
                        state_q <= IDLE;
                    end else begin
                        state_q <= RESPONSE;
                    end
                end
            end
            RESPONSE: begin
                if (dmem_rsp_valid_i) begin
                    if (dmem_rsp_error_i) begin
                        state_q <= IDLE;
                    end else if (amo_q) begin
                        mem_orig_q <= dmem_rsp_data_i;
                        amo_new_q  <= calc_amo(amo_op_q, size_q, dmem_rsp_data_i, store_data_q);
                        state_q    <= AMO_WRITE;
                    end else begin
                        state_q <= IDLE;
                    end
                end
            end
            AMO_WRITE: begin
                if (dmem_amo_write_ready_i) begin
                    state_q <= IDLE;
                end
            end
            default: $fatal(1, "invalid LSU state");
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            // RV64A safety assertions
            if (fault_valid_o) begin
                assert (!retire_valid_o)
                    else $fatal(1, "retire asserted simultaneously with fault");
                assert (!retire_rd_write_o)
                    else $fatal(1, "rd writeback asserted when faulting");
            end
            if (state_q == IDLE) begin
                assert (!dmem_amo_write_valid_o)
                    else $fatal(1, "AMO write valid asserted in IDLE state");
            end
        end
    end
endmodule
