// test7_kernel_tb.sv -- checks tests/test7_kernel.s
//
// The end-to-end case: 8 lanes cooperatively transform 32 words with loads and
// stores inside a backward branch. Expected values are derived by re-reading
// the SAME input file the DUT loaded, so there is no second hand-maintained
// copy of the input data to drift out of sync.

`timescale 1ns/1ps

import gpu_pkg::*;

module test7_kernel_tb;

    `include "tb_check.svh"

    localparam int L     = gpu_pkg::N_LANES;
    localparam int WORDS = 32;              // 8 lanes x 4 iterations

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(
        .PROG_INIT_FILE ("mems/test7_kernel.mem"),
        .IMG_INIT_FILE  ("mems/test7_data.mem")
    ) h (.*);

    always #5 clk = ~clk;

    // independent copy of the kernel's input, read from the same file
    logic [31:0] golden [0:WORDS-1];
    initial $readmemb("mems/test7_data.mem", golden);

    initial begin
        $display("== test7_kernel: strided data-parallel kernel, 8 lanes x 4 iters ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 20000)

        // out[j] = 3 * in[j] + 1, for all 32 words, in place
        for (int j = 0; j < WORDS; j++)
            `CHECK_EQ($sformatf("out[%0d] (word 0x%03h)", j, 32'h1000 + j * 4),
                      h.mem_word(32'h1000 + 32'(j) * 4),
                      golden[j] * 3 + 1)

        // the word just past the tiled region must be untouched
        `CHECK_EQ("mem past region untouched",
                  h.mem_word(32'h1000 + 32'(WORDS) * 4), 32'd0)

        // each lane's final pointer: started at 0x1000+4i, advanced 4 x 32 bytes
        for (int i = 0; i < L; i++) begin
            `CHECK_EQ($sformatf("lane%0d final ptr x3", i),
                      h.regs[i][3], 32'h1000 + 32'(i) * 4 + 32'd128)
            `CHECK_EQ($sformatf("lane%0d loop drained x7", i), h.regs[i][7], 32'd0)
        end

        `TB_SUMMARY("test7_kernel")
    end

endmodule
