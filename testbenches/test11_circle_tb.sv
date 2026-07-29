// test11_circle_tb.sv -- checks tests/render_circle.s
//
// The rendering path end to end: a kernel that writes a real image into the
// data buffer with setdt, checked against the circle equation for every one of
// the 4096 pixels. Where test10 proves the instructions move the right bits,
// this proves a kernel written the way gpu.c is written produces the right
// picture.
//
// It is also the regression test for lane divergence. Every pixel is checked,
// including the ones on the circle's edge where neighbouring lanes disagree
// about inside-vs-outside -- which is precisely where a per-pixel `if` would
// paint lane 0's answer across all 8 lanes and produce a wrong image. A
// spot-check of a few pixels would miss it; checking all 4096 cannot.

`timescale 1ns/1ps

import gpu_pkg::*;

module test11_circle_tb;

    `include "tb_check.svh"

    localparam int L  = gpu_pkg::N_LANES;
    localparam int W  = gpu_pkg::IMG_WIDTH;
    localparam int H  = gpu_pkg::IMG_HEIGHT;
    localparam int CX = 32, CY = 32, R2 = 144;
    localparam logic [31:0] WHITE = 32'h00ff_ffff;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(
        .PROG_INIT_FILE ("mems/render_circle.mem"),
        .DBUF_INIT_PREFIX ("mems/dbuf_zeros_bank")
    ) h (.*);

    always #5 clk = ~clk;

    int inside_count = 0;

    initial begin
        $display("== test11_circle: render a circle into the data buffer ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 100000)

        for (int i = 0; i < W * H; i++) begin
            automatic int x  = i % W;
            automatic int y  = i / W;
            automatic int d2 = (x - CX) * (x - CX) + (y - CY) * (y - CY);
            automatic logic [31:0] want = (d2 < R2) ? WHITE : 32'd0;
            if (d2 < R2) inside_count++;
            `CHECK_EQ($sformatf("pixel (%0d,%0d)", x, y), h.dbuf_read(i), want)
        end

        // Sanity-check the expectation itself: a radius-12 disc is ~pi*144 =
        // 452 pixels. If this were 0 or 4096 the loop above would "pass" while
        // comparing every pixel against a constant.
        `CHECK_TRUE("circle covers a plausible area",
                    inside_count > 400 && inside_count < 500)
        $display("  note: %0d of %0d pixels inside the circle", inside_count, W * H);

        `TB_SUMMARY("test11_circle")
    end

endmodule
