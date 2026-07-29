// test2_rtype_tb.sv -- checks tests/test2_rtype.s

`timescale 1ns/1ps

import gpu_pkg::*;

module test2_rtype_tb;

    `include "tb_check.svh"

    localparam int L = gpu_pkg::N_LANES;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(.PROG_INIT_FILE("mems/test2_rtype.mem")) h (.*);

    always #5 clk = ~clk;

    initial begin
        $display("== test2_rtype: R-type ALU, mul, shift masking ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 2000)

        for (int i = 0; i < L; i++) begin
            `CHECK_EQ($sformatf("lane%0d add  x3",  i), h.regs[i][3],  32'd17)
            `CHECK_EQ($sformatf("lane%0d sub  x4",  i), h.regs[i][4],  32'd7)
            `CHECK_EQ($sformatf("lane%0d sub  x5",  i), h.regs[i][5],  -32'sd7)
            `CHECK_EQ($sformatf("lane%0d mul  x6",  i), h.regs[i][6],  32'd60)
            `CHECK_EQ($sformatf("lane%0d sll  x7",  i), h.regs[i][7],  32'd384)
            `CHECK_EQ($sformatf("lane%0d srl  x8",  i), h.regs[i][8],  32'd0)
            `CHECK_EQ($sformatf("lane%0d srl  x10", i), h.regs[i][10], 32'h07FF_FFFF)
            `CHECK_EQ($sformatf("lane%0d sra  x11", i), h.regs[i][11], 32'hFFFF_FFFF)
            `CHECK_EQ($sformatf("lane%0d slt  x12", i), h.regs[i][12], 32'd1)
            `CHECK_EQ($sformatf("lane%0d sltu x13", i), h.regs[i][13], 32'd0)
            `CHECK_EQ($sformatf("lane%0d sltu x22", i), h.regs[i][22], 32'd1)
            `CHECK_EQ($sformatf("lane%0d slt  x23", i), h.regs[i][23], 32'd0)
            `CHECK_EQ($sformatf("lane%0d xor  x14", i), h.regs[i][14], 32'd9)
            `CHECK_EQ($sformatf("lane%0d or   x15", i), h.regs[i][15], 32'd13)
            `CHECK_EQ($sformatf("lane%0d and  x16", i), h.regs[i][16], 32'd4)
            `CHECK_EQ($sformatf("lane%0d mul  x17", i), h.regs[i][17], 32'd1)
            `CHECK_EQ($sformatf("lane%0d mul  x20", i), h.regs[i][20], -32'sd12)
            `CHECK_EQ($sformatf("lane%0d sub  x21", i), h.regs[i][21], -32'sd12)
            `CHECK_EQ($sformatf("lane%0d sll  x18 (shamt masked)", i), h.regs[i][18], 32'd0)
            `CHECK_EQ($sformatf("lane%0d add  x19", i), h.regs[i][19], 32'd11)
        end

        `TB_SUMMARY("test2_rtype")
    end

endmodule
