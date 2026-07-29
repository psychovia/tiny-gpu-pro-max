// test4_branch_tb.sv -- checks tests/test4_branch.s
//
// x10 is a bitmask error accumulator: each bit corresponds to one branch that
// went the wrong way, so a failure names the culprit instead of just reporting
// a mismatch.

`timescale 1ns/1ps

import gpu_pkg::*;

module test4_branch_tb;

    `include "tb_check.svh"

    localparam int L = gpu_pkg::N_LANES;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(.PROG_INIT_FILE("mems/test4_branch.mem")) h (.*);

    always #5 clk = ~clk;

    string bit_name [0:9] = '{
        "beq taken", "beq not-taken", "bne taken", "bne not-taken",
        "blt signed", "bltu unsigned", "bge signed", "bge not-taken",
        "bgeu unsigned", "bge equal operands"
    };

    initial begin
        $display("== test4_branch: all six conditions, both directions ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 5000)

        for (int i = 0; i < L; i++) begin
            `CHECK_EQ($sformatf("lane%0d error accumulator x10", i), h.regs[i][10], 32'd0)
            `CHECK_EQ($sformatf("lane%0d loop sum x20", i), h.regs[i][20], 32'd15)
            `CHECK_EQ($sformatf("lane%0d loop counter x21", i), h.regs[i][21], 32'd0)
        end

        // name whichever branches actually misbehaved
        for (int b = 0; b < 10; b++)
            if (h.regs[0][10][b] === 1'b1)
                $display("  ^ branch that went the wrong way: %s", bit_name[b]);

        `TB_SUMMARY("test4_branch")
    end

endmodule
