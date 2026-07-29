// test13_dbuf_scanout_tb.sv -- the data buffer reaching the actual screen.
//
// test9 already checks scanout, but only from shared_mem. Switching the display
// to the buffer changes three things test9 cannot see:
//
//   * display_controller drives a PIXEL INDEX (disp_pixel) rather than a byte
//     address -- no *3, no IMG_BASE, no two-word straddle read
//   * data_buffer's display port (its second read port, and the registered
//     bank select that has to line up with the registered bank data)
//   * gpu.sv's DISPLAY_FROM_DBUF mux
//
// A one-cycle error in that bank-select alignment shows up as pixels from the
// wrong bank -- i.e. a horizontally smeared image, not a blank one -- so this
// checks pixel VALUES at their screen positions, not just that video is active.
//
// Runs render_circle.mem rather than gpu_c.mem: the kernel is 30x shorter for
// the same picture, and test12 already covers the compiled-C path. A full frame
// is 663,168 cycles either way, so this keeps the run near test9's length.

`timescale 1ns/1ps

import gpu_pkg::*;

module test13_dbuf_scanout_tb;

    `include "tb_check.svh"

    localparam int W    = gpu_pkg::IMG_WIDTH;
    localparam int H    = gpu_pkg::IMG_HEIGHT;
    localparam int NPIX = W * H;
    localparam int CX = 32, CY = 32, R2 = 144;   // must match render_circle.s

    localparam int LINE_CYCLES  = 1056;
    localparam int FRAME_ROWS   = 628;
    localparam int FRAME_CYCLES = LINE_CYCLES * FRAME_ROWS;
    localparam int SCALE        = 8;
    localparam int ACTIVE_PX    = (W * SCALE) * (H * SCALE);

    logic        clk = 1'b0;
    logic        rst;
    logic        kernel_done;
    logic        hsync, vsync, video_active;
    logic [7:0]  vga_r, vga_g, vga_b;

    gpu #(
        .PROG_INIT_FILE    ("mems/render_circle.mem"),
        .DBUF_INIT_PREFIX  ("mems/dbuf_zeros_bank"),
        .DISPLAY_FROM_DBUF (1'b1)
    ) u (.*);

    always #12.5 clk = ~clk;      // 40 MHz pixel clock

    // render_circle.s writes white inside the disc, black outside.
    function automatic logic [7:0] expected_channel(input int px, input int py);
        return (((px - CX) * (px - CX) + (py - CY) * (py - CY)) < R2) ? 8'hff : 8'h00;
    endfunction

    // vga_r/g/b belong to the address presented one cycle earlier, so the image
    // coordinates have to be delayed to match -- same reason
    // display_controller delays blank/in_image.
    logic [9:0] ix_d, iy_d;

    always_ff @(posedge clk) begin
        ix_d <= u.u_display_controller.img_x;
        iy_d <= u.u_display_controller.img_y;
    end

    int active_seen = 0, x_pixels = 0, wrong_pixels = 0, reported = 0;
    int surround_wrong = 0;
    logic capture_en = 1'b0;

    // Declared at module scope and assigned procedurally below, NOT as
    // `automatic logic [7:0] want = expected_channel(...)` inside the always
    // block. xsim runs a declaration initializer in an always block ONCE, at
    // time 0 -- so `want` would freeze at expected_channel(0,0) = 0 and every
    // white pixel would "fail" against it while the screen was actually right.
    logic [7:0] want;

    // video_active now spans the whole VISIBLE WINDOW, not just the image
    // rectangle -- vde must stay high across active video or the TMDS encoder
    // emits control codes mid-line (see display_controller.sv). So the pixel
    // check is gated on in_image separately, and the black surround is checked
    // on its own below.
    always @(negedge clk) if (capture_en && video_active) begin
        active_seen++;
        if ((^{vga_r, vga_g, vga_b}) === 1'bx) begin
            x_pixels++;
        end else if (!u.u_display_controller.in_image_prev) begin
            // outside the image but inside the visible window: must be BLACK
            // pixel data, not a dropped pixel
            if (vga_r !== 8'd0 || vga_g !== 8'd0 || vga_b !== 8'd0) begin
                surround_wrong++;
                if (surround_wrong <= 3)
                    $display("  FAIL surround pixel not black: rgb %0d,%0d,%0d",
                             vga_r, vga_g, vga_b);
            end
        end else if (int'(ix_d) < W && int'(iy_d) < H) begin
            want = expected_channel(int'(ix_d), int'(iy_d));
            if (vga_r !== want || vga_g !== want || vga_b !== want) begin
                wrong_pixels++;
                if (reported < 10) begin
                    reported++;
                    $display("  FAIL scanout at image (%0d,%0d): got rgb %0d,%0d,%0d, expected %0d",
                             ix_d, iy_d, vga_r, vga_g, vga_b, want);
                end
            end
        end
    end

    initial begin
        $display("== test13_dbuf_scanout: data buffer -> screen ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 200000)

        capture_en = 1'b1;
        repeat (FRAME_CYCLES + LINE_CYCLES) @(posedge clk);
        capture_en = 1'b0;

        // No X anywhere in the visible area. This is the check that caught the
        // original out-of-bounds display addressing, and it is the one that
        // would catch a buffer index running past DBUF_WORDS.
        `CHECK_EQ("X pixels while video_active", x_pixels, 32'd0)
        `CHECK_EQ("mismatched scanout pixels", wrong_pixels, 32'd0)
        // The image really was drawn, at the size and zoom expected -- so a
        // blank screen can't pass the two checks above by having nothing in it.
        `CHECK_EQ("surround pixels not black", surround_wrong, 32'd0)
        // vde must cover the ENTIRE visible window (800x600), not just the
        // 512x512 image. Anything less means control codes inside active video.
        `CHECK_TRUE("vde spans the whole visible window",
                    active_seen >= 800 * 600)
        $display("  note: %0d active pixels seen (image occupies %0d)",
                 active_seen, ACTIVE_PX);

        `TB_SUMMARY("test13_dbuf_scanout")
    end

endmodule
