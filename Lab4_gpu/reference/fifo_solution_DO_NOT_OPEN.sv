// fifo_solution_DO_NOT_OPEN.sv -- SEALED reference FIFO (answer key). Not in any
// build; kept in sync with the part_*_solution implementation. Do not hand out.

module fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             push,
    input  logic [WIDTH-1:0] wdata,
    output logic             full,
    input  logic             pop,
    output logic [WIDTH-1:0] rdata,
    output logic             empty,
    output logic [7:0]       count,
    output logic             overflow
);

    logic [$clog2(DEPTH)-1:0] head = '0, tail = '0;
    logic [$clog2(DEPTH)-1:0] head_p_1, tail_p_1;
    assign head_p_1 = head + 1;
    assign tail_p_1 = tail + 1;

    logic [7:0] internal_count = '0;
    assign count = internal_count;
    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    logic [DEPTH-1:0][WIDTH-1:0] circ_buffer;
    assign rdata = circ_buffer[tail_p_1];

    logic overflowed = '0;
    assign overflow = overflowed;

    logic do_push, do_pop;
    assign do_pop  = pop && !empty;
    assign do_push = push && (!full || do_pop);

    always_ff @( posedge clk ) begin : update_fifo
        if (rst) begin
            head           <= '0;
            tail           <= '0;
            internal_count <= '0;
            overflowed     <= '0;
        end else begin
            if (do_push) begin
                head <= head_p_1;
                circ_buffer[head_p_1] <= wdata;
            end
            if (do_pop) tail <= tail_p_1;
            internal_count <= internal_count + do_push - do_pop;
            if (push && full && !do_pop) overflowed <= 1;
        end
    end

endmodule : fifo
