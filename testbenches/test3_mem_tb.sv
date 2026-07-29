// test3_mem_tb.sv -- checks tests/test3_mem.s
//
// Verifies both halves of every access: the value the load delivered into a
// register, AND the bytes actually sitting in shared_mem afterwards. Checking
// only the register would miss a store that wrote the right value to the wrong
// byte lane and a load that read it back with a mirror-image mistake.

`timescale 1ns/1ps

import gpu_pkg::*;

module test3_mem_tb;

    `include "tb_check.svh"

    localparam int L = gpu_pkg::N_LANES;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(.PROG_INIT_FILE("mems/test3_mem.mem")) h (.*);

    always #5 clk = ~clk;

    initial begin
        $display("== test3_mem: load/store widths and byte lanes ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 5000)

        // ---- what the loads delivered, on every lane ----
        for (int i = 0; i < L; i++) begin
            `CHECK_EQ($sformatf("lane%0d lw   x3",  i), h.regs[i][3],  32'hDEAD_BEEF)
            `CHECK_EQ($sformatf("lane%0d lb   x4",  i), h.regs[i][4],  32'hFFFF_FFEF)
            `CHECK_EQ($sformatf("lane%0d lbu  x5",  i), h.regs[i][5],  32'h0000_00EF)
            `CHECK_EQ($sformatf("lane%0d lb+1 x6",  i), h.regs[i][6],  32'hFFFF_FFBE)
            `CHECK_EQ($sformatf("lane%0d lbu+3 x7", i), h.regs[i][7],  32'h0000_00DE)
            `CHECK_EQ($sformatf("lane%0d lh   x8",  i), h.regs[i][8],  32'hFFFF_BEEF)
            `CHECK_EQ($sformatf("lane%0d lhu  x9",  i), h.regs[i][9],  32'h0000_BEEF)
            `CHECK_EQ($sformatf("lane%0d lh+2 x10", i), h.regs[i][10], 32'hFFFF_DEAD)
            `CHECK_EQ($sformatf("lane%0d lhu+2 x11",i), h.regs[i][11], 32'h0000_DEAD)
            `CHECK_EQ($sformatf("lane%0d sb   x15", i), h.regs[i][15], 32'h00BB_00AA)
            `CHECK_EQ($sformatf("lane%0d sh   x19", i), h.regs[i][19], 32'h5678_1234)
            `CHECK_EQ($sformatf("lane%0d sb over sw x22", i), h.regs[i][22], 32'hFFFF_00FF)
            `CHECK_EQ($sformatf("lane%0d neg-offset x25", i), h.regs[i][25], 32'h1122_3344)
        end

        // ---- what actually landed in memory ----
        `CHECK_EQ("mem[0x1000] after sw",       h.mem_word(32'h1000), 32'hDEAD_BEEF)
        `CHECK_EQ("mem[0x1010] after 2x sb",    h.mem_word(32'h1010), 32'h00BB_00AA)
        `CHECK_EQ("mem[0x1020] after 2x sh",    h.mem_word(32'h1020), 32'h5678_1234)
        `CHECK_EQ("mem[0x1030] after sb clear", h.mem_word(32'h1030), 32'hFFFF_00FF)
        `CHECK_EQ("mem[0x103C] neg offset",     h.mem_word(32'h103C), 32'h1122_3344)

        // stores must not have splashed into neighbouring words
        `CHECK_EQ("mem[0x1004] untouched", h.mem_word(32'h1004), 32'd0)
        `CHECK_EQ("mem[0x100C] untouched", h.mem_word(32'h100C), 32'd0)
        `CHECK_EQ("mem[0x1014] untouched", h.mem_word(32'h1014), 32'd0)
        `CHECK_EQ("mem[0x1024] untouched", h.mem_word(32'h1024), 32'd0)
        `CHECK_EQ("mem[0x1034] untouched", h.mem_word(32'h1034), 32'd0)

        `TB_SUMMARY("test3_mem")
    end

endmodule
