/**
fetcher
- latch instr from mem_rdata during S_FETCH_WAIT
**/


import gpu_pkg::*;

module fetcher (
    input logic [31:0] mem_rdata, // from memory.sv?
    input clk,
    input state_t state,
    output logic [31:0] instr
);

    logic is_S_FETCH_WAIT;

    assign is_S_FETCH_WAIT = (state == S_FETCH_WAIT);

    always_ff @(posedge clk) begin
        if (is_S_FETCH_WAIT) begin
            instr <= mem_rdata;
        end
    end


endmodule