// test5_jump_tb.sv -- checks tests/test5_jump.s
//
// The literal addresses below come from the address comments in
// mems/test5_jump.mem. If you edit tests/test5_jump.s, re-read that listing.

`timescale 1ns/1ps

import gpu_pkg::*;

module test5_jump_tb;

    `include "tb_check.svh"

    localparam int L = gpu_pkg::N_LANES;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(.PROG_INIT_FILE("mems/test5_jump.mem")) h (.*);

    always #5 clk = ~clk;

    initial begin
        $display("== test5_jump: jal / jalr / auipc ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 2000)

        for (int i = 0; i < L; i++) begin
            // jal's link must be pc+4 (0x08), not the jump target (0x10)
            `CHECK_EQ($sformatf("lane%0d jal link x1", i), h.regs[i][1], 32'h0000_0008)
            // call + return both executed exactly once: 0 + 1 + 10
            `CHECK_EQ($sformatf("lane%0d call/ret x20", i), h.regs[i][20], 32'd11)
            // auipc with imm 0 yields its own pc
            `CHECK_EQ($sformatf("lane%0d auipc x2", i), h.regs[i][2], 32'h0000_0018)
            // jalr target 0x18+13 = 0x25, bit 0 cleared -> 0x24, skipping 0x20
            `CHECK_EQ($sformatf("lane%0d jalr &~1 x21", i), h.regs[i][21], 32'd42)
        end

        `TB_SUMMARY("test5_jump")
    end

endmodule
