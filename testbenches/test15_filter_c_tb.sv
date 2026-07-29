// test15_filter_c_tb.sv -- the full photo-filter path: a real source image
// loaded into the data buffer, filtered by compiled C, checked pixel by pixel.
//
// This is the only test that covers the buffer's INITIAL CONTENTS. Every other
// data-buffer test starts from the all-zeros set, so a broken image load would
// pass them all. It matters because the load is easy to get silently wrong:
// reading one flat file into an array and scattering it into the banks
// simulates perfectly and is DROPPED at synthesis ("[Synth 8-311] ignoring
// non-constant assignment in initial block"), so the board reads zeros while
// simulation reads the photo. Each bank now $readmemb's its own file, and this
// test is what proves the striding in img_tool.py matches what the hardware
// expects -- an off-by-one there scrambles the image into 8 interleaved
// columns, which still "looks like an image" in a thumbnail.

`timescale 1ns/1ps

import gpu_pkg::*;

module test15_filter_c_tb;

    `include "tb_check.svh"

    localparam int L = gpu_pkg::N_LANES;
    localparam int W = gpu_pkg::IMG_WIDTH;
    localparam int H = gpu_pkg::IMG_HEIGHT;
    localparam int W_R = 77, W_G = 150, W_B = 29;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(
        .PROG_INIT_FILE   ("mems/filter_c.mem"),
        .DBUF_INIT_PREFIX ("mems/dbuf_test_bank")
    ) h (.*);

    always #5 clk = ~clk;

    // Independent copy of the source, read from the FLAT file rather than the
    // per-bank ones -- so the expectation is derived from a different file than
    // the DUT loads. If img_tool's bank striding disagreed with data_buffer's
    // bank/row split, both would still be self-consistent; only comparing
    // against the flat original catches it.
    logic [31:0] src [0:W*H-1];
    initial $readmemb("mems/dbuf_test.mem", src);

    int checked, nonzero_src;

    initial begin
        $display("== test15_filter_c: photo -> data buffer -> compiled C filter ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 2000000)

        checked = 0; nonzero_src = 0;
        for (int i = 0; i < W * H; i++) begin
            automatic int r = src[i][7:0];
            automatic int g = src[i][15:8];
            automatic int b = src[i][23:16];
            automatic int y = (W_R * r + W_G * g + W_B * b) >> 8;
            automatic logic [31:0] want = {8'd0, y[7:0], y[7:0], y[7:0]};
            if (src[i] != 0) nonzero_src++;
            `CHECK_EQ($sformatf("pixel %0d (%0d,%0d)", i, i % W, i / W),
                      h.dbuf_read(i), want)
            checked++;
        end

        // Guard against the whole thing passing vacuously on an all-black
        // source: if the image failed to load, every expected value would be 0
        // and every check would trivially pass.
        `CHECK_TRUE("source image actually loaded (not all zeros)",
                    nonzero_src > (W * H) / 2)
        $display("  note: %0d pixels filtered, %0d non-black in the source",
                 checked, nonzero_src);

        `TB_SUMMARY("test15_filter_c")
    end

endmodule
