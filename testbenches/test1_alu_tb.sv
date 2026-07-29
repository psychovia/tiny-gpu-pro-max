// test1_alu_tb.sv -- checks tests/test1_alu.s
//
// The program is lane-uniform, so every expected value is checked on every
// lane. That is not redundant: each cpu.sv lane has its own register file and
// its own ALU, and only lane 0 is ever consulted for control flow, so a lane
// whose datapath is mis-wired would otherwise go unnoticed.

`timescale 1ns/1ps

import gpu_pkg::*;

module test1_alu_tb;

    `include "tb_check.svh"

    localparam int L = gpu_pkg::N_LANES;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(.PROG_INIT_FILE("mems/test1_alu.mem")) h (.*);

    always #5 clk = ~clk;

    initial begin
        $display("== test1_alu: I-type / U-type ALU ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 2000)

        for (int i = 0; i < L; i++) begin
            `CHECK_EQ($sformatf("lane%0d auipc x16", i), h.regs[i][16], 32'h0000_1000)
            `CHECK_EQ($sformatf("lane%0d addi  x1",  i), h.regs[i][1],  32'd100)
            `CHECK_EQ($sformatf("lane%0d addi- x2",  i), h.regs[i][2],  32'hFFFF_FFFB)
            `CHECK_EQ($sformatf("lane%0d addi  x3",  i), h.regs[i][3],  32'd70)
            `CHECK_EQ($sformatf("lane%0d xori  x4",  i), h.regs[i][4],  32'd107)
            `CHECK_EQ($sformatf("lane%0d ori   x5",  i), h.regs[i][5],  32'd111)
            `CHECK_EQ($sformatf("lane%0d andi  x6",  i), h.regs[i][6],  32'd4)
            `CHECK_EQ($sformatf("lane%0d slti  x7",  i), h.regs[i][7],  32'd1)
            `CHECK_EQ($sformatf("lane%0d slti  x8",  i), h.regs[i][8],  32'd0)
            `CHECK_EQ($sformatf("lane%0d sltiu x9",  i), h.regs[i][9],  32'd0)
            `CHECK_EQ($sformatf("lane%0d sltiu x10", i), h.regs[i][10], 32'd1)
            `CHECK_EQ($sformatf("lane%0d slli  x11", i), h.regs[i][11], 32'd1600)
            `CHECK_EQ($sformatf("lane%0d srli  x12", i), h.regs[i][12], 32'd25)
            `CHECK_EQ($sformatf("lane%0d srai  x13", i), h.regs[i][13], -32'sd3)
            `CHECK_EQ($sformatf("lane%0d srli  x14", i), h.regs[i][14], 32'd15)
            `CHECK_EQ($sformatf("lane%0d andi  x15", i), h.regs[i][15], 32'hFFFF_FFFB)
            `CHECK_EQ($sformatf("lane%0d lui   x17", i), h.regs[i][17], 32'hABCD_E000)
            `CHECK_EQ($sformatf("lane%0d addi  x18", i), h.regs[i][18], 32'd2047)
            `CHECK_EQ($sformatf("lane%0d addi  x19", i), h.regs[i][19], -32'sd2048)
            `CHECK_EQ($sformatf("lane%0d xori  x20", i), h.regs[i][20], 32'hFFFF_FFFF)

            // x0 must stay hardwired at zero despite `addi x0, x0, 5`
            `CHECK_EQ($sformatf("lane%0d x0 stays zero", i), h.regs[i][0], 32'd0)
            // x30 is preloaded with lane_id at reset and never written here
            `CHECK_EQ($sformatf("lane%0d x30 == lane_id", i), h.regs[i][30], i[31:0])
        end

        `TB_SUMMARY("test1_alu")
    end

endmodule
