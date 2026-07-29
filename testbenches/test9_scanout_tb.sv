// test9_scanout_tb.sv -- the whole render path, end to end.
//
// Instantiates gpu.sv (core + shared_mem + display_controller + vga timing),
// runs the grayscale kernel to completion, then captures one entire video frame
// and checks three separate things:
//
//   1. VGA timing matches what vga-hdmi.sv is specified to generate
//      (VESA 800x600@60 on a 40MHz pixel clock).
//   2. Every visible pixel carries the value the filtered image says it should,
//      at the right screen position -- so the address math, the 1-cycle
//      read-latency alignment and the scaling are all verified, not assumed.
//   3. No pixel is ever X while video_active is high. This is the one that
//      caught the original 640x480-vs-800x600 parameter mismatch: a quarter of
//      every frame was reading out of bounds.
//
// Dumps what was actually scanned out to .sim/scanout.txt, which
// `img_tool.py from-frame` turns into a PNG -- the image the monitor would show.
//
// This is the longest test in the suite: ~70k cycles of kernel plus a full
// 663,168-cycle frame.

`timescale 1ns/1ps

import gpu_pkg::*;

module test9_scanout_tb;

    `include "tb_check.svh"

    localparam int W    = gpu_pkg::IMG_WIDTH;
    localparam int H    = gpu_pkg::IMG_HEIGHT;
    localparam int NPIX = W * H;
    localparam int IMG_WORDS = (NPIX * gpu_pkg::BYTES_PER_PIXEL) / 4;

    localparam int W_R = 77, W_G = 150, W_B = 29;

    // vga-hdmi.sv: 1056 columns x 628 rows total, 800x600 visible,
    // hsync 128 columns wide, vsync 4 rows deep.
    localparam int LINE_CYCLES  = 1056;
    localparam int FRAME_ROWS   = 628;
    localparam int FRAME_CYCLES = LINE_CYCLES * FRAME_ROWS;   // 663168
    localparam int HS_WIDTH     = 128;
    localparam int VS_WIDTH     = 4 * LINE_CYCLES;            // 4224

    // display_controller draws the image at an integer zoom, centred
    localparam int SCALE     = 8;
    localparam int ACTIVE_PX = (W * SCALE) * (H * SCALE);      // 512x512 image
    localparam int SCREEN_W_VIS = 800, SCREEN_H_VIS = 600;     // vde window

    logic        clk = 1'b0;
    logic        rst;
    logic        kernel_done;
    logic        hsync, vsync, video_active;
    logic [7:0]  vga_r, vga_g, vga_b;

    // DISPLAY_FROM_DBUF pinned to 0 explicitly: this test covers the SHARED_MEM
    // scanout path (filter_gray writes its image there with sw), and gpu.sv's
    // default now selects the data buffer because that is what the flashed demo
    // uses. Relying on the default here made this test silently follow whatever
    // the current demo happened to be.
    gpu #(
        .PROG_INIT_FILE    ("mems/filter_gray.mem"),
        .IMG_INIT_FILE     ("mems/img_source.mem"),
        .DISPLAY_FROM_DBUF (1'b0)
    ) u (.*);

    always #12.5 clk = ~clk;      // 40 MHz pixel clock

    // independent copy of the source image, to derive expected grey levels
    logic [31:0] src_words [0:IMG_WORDS-1];
    initial $readmemb("mems/img_source.mem", src_words);

    function automatic logic [7:0] src_byte(input int off);
        return src_words[off >> 2][((off & 3) * 8) +: 8];
    endfunction

    function automatic int expected_gray(input int px, input int py);
        return (W_R * int'(src_byte((py * W + px) * 3 + 0))
              + W_G * int'(src_byte((py * W + px) * 3 + 1))
              + W_B * int'(src_byte((py * W + px) * 3 + 2))) >> 8;
    endfunction

    // vga_r/g/b belong to the address presented one cycle earlier, so the
    // image coordinates have to be delayed to match. Same reason
    // display_controller delays blank/in_image.
    logic [9:0] ix_d, iy_d;

    always_ff @(posedge clk) begin
        ix_d <= u.u_display_controller.img_x;
        iy_d <= u.u_display_controller.img_y;
    end

    // ---- frame capture and timing measurement ----
    int  active_seen, x_pixels, wrong_pixels, reported, surround_wrong;
    // Measures the ASSERTED (low) width: this design drives active-low sync,
    // matching lab3_src/vga2.sv, which displays correctly on the real monitor.
    // See the polarity note in vga-hdmi.sv before "fixing" this to positive.
    int  hs_lo_len, hs_lo_measured, hs_period, hs_period_measured, hs_last_fall;
    int  vs_lo_len, vs_lo_measured, vs_last_fall, vs_period_measured;
    int  cyc;
    logic hs_q, vs_q;
    logic [7:0] captured [0:NPIX-1];
    logic       captured_valid [0:NPIX-1];

    logic capture_en = 1'b0;

    always @(negedge clk) if (capture_en) begin
        cyc++;

        // hsync: active low. Measure pulse width and period.
        if (hs_q && !hsync) begin                       // falling edge = pulse start
            if (hs_last_fall > 0) hs_period_measured = cyc - hs_last_fall;
            hs_last_fall = cyc;
            hs_lo_len = 0;
        end
        if (!hsync) hs_lo_len++;
        if (!hs_q && hsync) hs_lo_measured = hs_lo_len;     // rising edge = pulse end
        hs_q <= hsync;

        if (vs_q && !vsync) begin
            if (vs_last_fall > 0) vs_period_measured = cyc - vs_last_fall;
            vs_last_fall = cyc;
            vs_lo_len = 0;
        end
        if (!vsync) vs_lo_len++;
        if (!vs_q && vsync) vs_lo_measured = vs_lo_len;
        vs_q <= vsync;

        // video_active spans the whole VISIBLE WINDOW now, not just the image
        // rectangle: vde has to stay high across active video or the encoder
        // emits control codes mid-line (see display_controller.sv). So the
        // image comparison is gated on in_image, and the black surround gets
        // its own check.
        if (video_active) begin
            active_seen++;
            if ((^{vga_r, vga_g, vga_b}) === 1'bx) begin
                x_pixels++;
            end else if (!u.u_display_controller.in_image_prev) begin
                if (vga_r !== 8'd0 || vga_g !== 8'd0 || vga_b !== 8'd0) begin
                    surround_wrong++;
                    if (surround_wrong <= 3)
                        $display("  FAIL surround pixel not black: rgb %0d,%0d,%0d",
                                 vga_r, vga_g, vga_b);
                end
            end else if (int'(ix_d) < W && int'(iy_d) < H) begin
                // grayscale, so all three channels must equal the grey level
                if (int'(vga_r) !== expected_gray(int'(ix_d), int'(iy_d))
                 || vga_g !== vga_r || vga_b !== vga_r) begin
                    wrong_pixels++;
                    if (reported < 10) begin
                        reported++;
                        $display("  FAIL scanout at image (%0d,%0d): got rgb %0d,%0d,%0d, expected grey %0d",
                                 ix_d, iy_d, vga_r, vga_g, vga_b,
                                 expected_gray(int'(ix_d), int'(iy_d)));
                    end
                end
                captured[int'(iy_d) * W + int'(ix_d)]       <= vga_r;
                captured_valid[int'(iy_d) * W + int'(ix_d)] <= 1'b1;
            end else begin
                wrong_pixels++;   // active pixel outside the image is a bug
            end
        end
    end

    int fd, missing;

    initial begin
        $display("== test9_scanout: full render path, one complete 800x600 frame ==");
        for (int i = 0; i < NPIX; i++) captured_valid[i] = 1'b0;
        active_seen = 0; x_pixels = 0; wrong_pixels = 0; reported = 0;
        surround_wrong = 0;
        hs_lo_len = 0; hs_lo_measured = 0; hs_period_measured = 0; hs_last_fall = 0;
        vs_lo_len = 0; vs_lo_measured = 0; vs_last_fall = 0; vs_period_measured = 0;
        cyc = 0; hs_q = 1'b1; vs_q = 1'b1;

        `TB_RESET
        `RUN_KERNEL(kernel_done, 500000)

        // Start capturing at a line boundary so the first measured hsync
        // period is a whole line rather than a partial one.
        @(negedge clk);
        capture_en = 1'b1;
        // two full frames: the first gives clean edges to measure from, the
        // second guarantees every pixel of a complete frame has been seen
        repeat (2 * FRAME_CYCLES + LINE_CYCLES) @(posedge clk);
        capture_en = 1'b0;
        @(negedge clk);

        // ---- 1. timing ----
        `CHECK_EQ("hsync pulse width (cycles)", hs_lo_measured,    HS_WIDTH)
        `CHECK_EQ("hsync period (cycles/line)", hs_period_measured, LINE_CYCLES)
        `CHECK_EQ("vsync pulse width (cycles)", vs_lo_measured,    VS_WIDTH)
        `CHECK_EQ("vsync period (cycles/frame)", vs_period_measured, FRAME_CYCLES)
        // Assert the polarity itself, not just the widths -- a measurement of
        // the low period would also "pass" on a positive-sync signal by
        // measuring the long inactive stretch. A pulse narrower than half the
        // period means the ASSERTED level is the low one: negative sync, which
        // is what lab3_src/vga2.sv drives and what this monitor accepts.
        `CHECK_TRUE("hsync is NEGATIVE polarity", hs_lo_measured * 2 < LINE_CYCLES)
        `CHECK_TRUE("vsync is NEGATIVE polarity", vs_lo_measured * 2 < FRAME_CYCLES)

        // ---- 2. pixel correctness ----
        `CHECK_EQ("undefined (X) pixels while video_active", x_pixels, 32'd0)
        `CHECK_EQ("mismatched scanout pixels", wrong_pixels, 32'd0)
        // two frames captured, so twice the per-frame active count
        `CHECK_EQ("surround pixels not black", surround_wrong, 32'd0)
        // The whole 800x600 visible window, twice -- NOT just the 512x512
        // image. Anything less means vde dropped inside active video.
        // Two full visible windows, plus however much of a third frame the
        // capture window happens to overlap -- bounded to under one extra line
        // so a genuinely wrong vde window still fails.
        `CHECK_TRUE($sformatf("active pixels over 2 frames (%0d)", active_seen),
                    active_seen >= 2 * SCREEN_W_VIS * SCREEN_H_VIS &&
                    active_seen <  2 * SCREEN_W_VIS * SCREEN_H_VIS + LINE_CYCLES)

        // ---- 3. every source pixel actually appeared on screen ----
        missing = 0;
        for (int i = 0; i < NPIX; i++) if (!captured_valid[i]) missing++;
        `CHECK_EQ("source pixels never scanned out", missing, 32'd0)

        // ---- dump what the monitor would show ----
        fd = $fopen(".sim/scanout.txt", "w");
        if (fd == 0) begin
            $display("  NOTE: could not open .sim/scanout.txt (no image dump written)");
        end else begin
            $fdisplay(fd, "# scanned-out frame as seen on vga_r/g/b: <x> <y> <rrggbb>");
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                    $fdisplay(fd, "%0d %0d %02h%02h%02h", x, y,
                              captured[y * W + x], captured[y * W + x], captured[y * W + x]);
            $fclose(fd);
            $display("  wrote .sim/scanout.txt (%0dx%0d)", W, H);
        end

        $display("  measured: line=%0d cycles, frame=%0d cycles (%0d Hz at 40MHz), active=%0d px/frame",
                 hs_period_measured, vs_period_measured,
                 40000000 / (vs_period_measured == 0 ? 1 : vs_period_measured),
                 active_seen / 2);

        `TB_SUMMARY("test9_scanout")
    end

endmodule
