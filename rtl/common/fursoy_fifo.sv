module fursoy_fifo #(
    parameter int unsigned WIDTH = 32,
    parameter int unsigned DEPTH = 8
) (
    input  logic             clk_i,
    input  logic             rst_i,
    input  logic             flush_i,
    input  logic             in_valid_i,
    output logic             in_ready_o,
    input  logic [WIDTH-1:0] in_data_i,
    output logic             out_valid_o,
    input  logic             out_ready_i,
    output logic [WIDTH-1:0] out_data_o
);
    localparam int unsigned PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int unsigned COUNT_W = $clog2(DEPTH + 1);
    logic [WIDTH-1:0] mem [DEPTH];
    logic [PTR_W-1:0] read_ptr, write_ptr;
    logic [COUNT_W-1:0] count;
    logic push, pop;

    initial begin
        assert (WIDTH > 0 && DEPTH > 0) else $fatal(1, "Invalid FIFO parameters");
    end

    function automatic logic [PTR_W-1:0] advance(input logic [PTR_W-1:0] ptr);
        return (ptr == PTR_W'(DEPTH - 1)) ? '0 : ptr + 1'b1;
    endfunction

    assign out_valid_o = !rst_i && !flush_i && (count != 0);
    assign in_ready_o = !rst_i && !flush_i &&
                        ((count < COUNT_W'(DEPTH)) || out_ready_i);
    assign out_data_o = out_valid_o ? mem[read_ptr] : '0;
    assign push = in_valid_i && in_ready_o;
    assign pop = out_valid_o && out_ready_i;

    always_ff @(posedge clk_i) begin
        if (rst_i || flush_i) begin
            read_ptr <= '0;
            write_ptr <= '0;
            count <= '0;
        end else begin
            if (push) begin
                mem[write_ptr] <= in_data_i;
                write_ptr <= advance(write_ptr);
            end
            if (pop) read_ptr <= advance(read_ptr);
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
            assert (int'(count) <= DEPTH) else $fatal(1, "FIFO count overflow");
            assert (int'(read_ptr) < DEPTH && int'(write_ptr) < DEPTH)
                else $fatal(1, "FIFO pointer overflow");
        end
    end
endmodule
