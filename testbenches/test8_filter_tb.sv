// test8_filter_tb.sv -- runs tests/filter_gray.s over a real 64x64 image and
// checks every one of the 4096 pixels.
//
// Expected values are computed from the SAME input file the DUT loaded
// (mems/img_source.mem, re-read here independently), so there is no second
// hand-maintained copy of the image to drift out of sync.
//
// Also dumps the filtered framebuffer to .sim/filter_out.txt, which
// `img_tool.py from-frame` turns into a PNG -- so the result is inspectable as
// an image, not just as a pass/fail line.

`timescale 1ns/1ps

import gpu_pkg::*;

module test8_filter_tb;

    `include "tb_check.svh"

    localparam int L        = gpu_pkg::N_LANES;
    localparam int W        = gpu_pkg::IMG_WIDTH;
    localparam int H        = gpu_pkg::IMG_HEIGHT;
    localparam int NPIX     = W * H;
    localparam int IMG_WORDS = (NPIX * gpu_pkg::BYTES_PER_PIXEL) / 4;

    // Must match tests/filter_gray.s and img_tool.py's W_R/W_G/W_B.
    localparam int W_R = 77, W_G = 150, W_B = 29;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(
        .PROG_INIT_FILE ("mems/filter_gray.mem"),
        .IMG_INIT_FILE  ("mems/img_source.mem")
    ) h (.*);

    always #5 clk = ~clk;

    // independent copy of the untouched source image
    logic [31:0] src_words [0:IMG_WORDS-1];
    initial $readmemb("mems/img_source.mem", src_words);

    // byte `off` of the image region, as loaded (little-endian within a word)
    function automatic logic [7:0] src_byte(input int off);
        return src_words[off >> 2][((off & 3) * 8) +: 8];
    endfunction

    // byte `off` of the image region, as it stands in the DUT's memory now
    function automatic logic [7:0] dut_byte(input int off);
        return h.mem_word(gpu_pkg::IMG_BASE + 32'(off))[((off & 3) * 8) +: 8];
    endfunction

    int fd, bad, reported;
    int r, g, b, expect_gray;

    initial begin
        $display("== test8_filter: grayscale kernel over a %0dx%0d image, %0d lanes ==",
                 W, H, L);
        `TB_RESET
        // 512 pixels per lane, ~15 instructions each, and every load/store
        // costs ~10 cycles of arbitration for 8 lanes -- so this is ~72k
        // cycles, two orders of magnitude longer than any other test here.
        `RUN_KERNEL(kernel_done, 500000)

        bad = 0; reported = 0;
        fd = $fopen(".sim/filter_out.txt", "w");
        if (fd == 0)
            $display("  NOTE: could not open .sim/filter_out.txt (no image dump written)");
        else
            $fdisplay(fd, "# filtered framebuffer: <x> <y> <rrggbb>");

        for (int p = 0; p < NPIX; p++) begin
            r = int'(src_byte(p * 3 + 0));
            g = int'(src_byte(p * 3 + 1));
            b = int'(src_byte(p * 3 + 2));
            expect_gray = (W_R * r + W_G * g + W_B * b) >> 8;

            // all three channels must hold the same grey level
            for (int c = 0; c < 3; c++) begin
                tb_checks++;
                if (int'(dut_byte(p * 3 + c)) !== expect_gray) begin
                    bad++;
                    tb_fails++;
                    if (reported < 15) begin
                        reported++;
                        $display("  FAIL pixel %0d (%0d,%0d) chan %0d: got %0d, expected %0d  [src rgb %0d,%0d,%0d]",
                                 p, p % W, p / W, c,
                                 int'(dut_byte(p * 3 + c)), expect_gray, r, g, b);
                    end
                end
            end

            if (fd != 0)
                $fdisplay(fd, "%0d %0d %02h%02h%02h", p % W, p / W,
                          dut_byte(p * 3 + 0), dut_byte(p * 3 + 1), dut_byte(p * 3 + 2));
        end
        if (fd != 0) $fclose(fd);

        if (bad > reported)
            $display("  ... and %0d more mismatched channels (suppressed)", bad - reported);

        // Every lane must have drained its 512 iterations and ended at the
        // address one stride past its last pixel. A lane that exited early
        // would leave part of the image unfiltered.
        for (int i = 0; i < L; i++) begin
            `CHECK_EQ($sformatf("lane%0d loop counter drained", i), h.regs[i][5], 32'd0)
            `CHECK_EQ($sformatf("lane%0d final pixel pointer", i), h.regs[i][1],
                      32'h1000 + 32'(i) * 3 + 32'd512 * 24)
        end

        $display("  checked %0d pixels (%0d channel comparisons)", NPIX, NPIX * 3);
        `TB_SUMMARY("test8_filter")
    end

endmodule
