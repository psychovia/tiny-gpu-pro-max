// test6_lanes_tb.sv -- checks tests/test6_lanes.s
//
// The first test where the 8 lanes present 8 DIFFERENT addresses to
// shared_mem at once. That makes it the real exercise of the arbiter's
// round-robin exclusion and of scheduler.sv's requirement that every lane be
// serviced before S_MEM_ADDR is allowed to end.

`timescale 1ns/1ps

import gpu_pkg::*;

module test6_lanes_tb;

    `include "tb_check.svh"

    localparam int L = gpu_pkg::N_LANES;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(.PROG_INIT_FILE("mems/test6_lanes.mem")) h (.*);

    always #5 clk = ~clk;

    initial begin
        $display("== test6_lanes: per-lane addresses and data ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 5000)

        for (int i = 0; i < L; i++) begin
            `CHECK_EQ($sformatf("lane%0d owns addr x3", i),
                      h.regs[i][3], 32'h1000 + 32'(i) * 4)
            `CHECK_EQ($sformatf("lane%0d computed x5", i),
                      h.regs[i][5], 32'(i) * 10 + 3)
            // read-back must return THIS lane's value, not a neighbour's
            `CHECK_EQ($sformatf("lane%0d read back x6", i),
                      h.regs[i][6], 32'(i) * 10 + 3)
            // every lane reading lane 0's slot must see lane 0's value
            `CHECK_EQ($sformatf("lane%0d sees slot0 x7", i), h.regs[i][7], 32'd3)
            // and the value must genuinely be in memory
            `CHECK_EQ($sformatf("mem[0x%03h] lane%0d slot", 32'h1000 + i * 4, i),
                      h.mem_word(32'h1000 + 32'(i) * 4), 32'(i) * 10 + 3)
        end

        // nothing should have been written past the 8 lane slots
        `CHECK_EQ("mem[0x1020] untouched", h.mem_word(32'h1020), 32'd0)

        `TB_SUMMARY("test6_lanes")
    end

endmodule
