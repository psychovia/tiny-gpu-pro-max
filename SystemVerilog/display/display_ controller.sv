/**

mem -> display_controller (this file) => vga-hdmi IP => fpga

rgb vals

reads pixel data out of shared memory and feeds it, in right format and timing to the VGA/HDMI output logic frame by frame, dozens of times per second which eventually drives the physical display

**/

import gpu_pkg::*;


module display_controller #(
    parameter int IMG_WIDTH     = gpu_pkg::IMG_WIDTH,
    parameter int IMG_HEIGHT    = gpu_pkg::IMG_HEIGHT,

    // vga-hdmi.sv generates VESA 800x600@60 on a 40MHz pixel clock (1056
    // columns x 628 rows total, 800x600 visible). These parameters used to say
    // 640x480, which is not what that module produces -- and because the old
    // address math divided by the resulting SCALE without any bounds check,
    // col/10 reached 102 and row/7 reached 146 against a valid image index
    // range of 0..63. That walked disp_addr up to byte 32434 (word 8108) in a
    // 4096-word memory, so a quarter of every frame (122720 of 480000 visible
    // pixels, measured) read out of bounds and scanned out as X.
    parameter int SCREEN_WIDTH  = 800,
    parameter int SCREEN_HEIGHT = 600,

    // Integer zoom, as a power of two so the pixel->image mapping is a shift
    // rather than a divider. 64 << 3 = 512, which fits inside 800x600 with
    // room to centre it. Deliberately NOT the largest integer scale that fits
    // (9): a non-power-of-two would put a real divider on the critical path of
    // every pixel, for one extra step of zoom.
    parameter int SCALE_LOG2    = 3
) (
    input  logic        clk, rst,
    input  logic        kernel_done, // from scheduler.sv (via core.sv) -- named to match core.sv's
                                      // actual output so gpu.sv's `.*` wildcard wiring picks it up
                                      // automatically; the image in memory isn't valid until this is high

    // memory
    input  logic [31:0] disp_rdata, // data read from whichever image store gpu.sv selected
    output logic [31:0] disp_addr,  // BYTE address, for shared_mem's 3-packed-bytes layout
    // The same request as a PIXEL INDEX, for data_buffer.sv -- one 32-bit
    // element per pixel, so there is no *3 and no IMG_BASE. Both are driven
    // every cycle; gpu.sv muxes whichever store's answer it wants back into
    // disp_rdata, and this file doesn't care which it got (the RGB slicing at
    // the bottom is identical either way).
    output logic [31:0] disp_pixel,

    // to vga-hdmi IP
    // hsync - pulse fires at end of every row to reset back to left edge
    // vsync - at the end of every full frame
    output logic        hsync, vsync,  // horizontal / vertical
    output logic        video_active,
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b
);
    localparam int SCALE  = 1 << SCALE_LOG2;
    localparam int DRAW_W = IMG_WIDTH  * SCALE;              // 512
    localparam int DRAW_H = IMG_HEIGHT * SCALE;              // 512
    localparam int OFF_X  = (SCREEN_WIDTH  - DRAW_W) / 2;    // 144
    localparam int OFF_Y  = (SCREEN_HEIGHT - DRAW_H) / 2;    // 44

    logic hs, vs, blank;
    logic [9:0] row, col;
    logic frame_complete;

    // timing generator, know every signle clock cycle
    vga vga_gen (
        .clock_40MHz(clk), .reset(rst),
        .HS(hs), .VS(vs), .blank(blank),
        .row(row), .col(col),
        .frame_complete(frame_complete)
    );

    // Is this screen pixel inside the centred image rectangle? Everything
    // outside it is drawn black, which is what keeps the address math in
    // range: img_x/img_y below are only meaningful (and only used) when this
    // is true, so they can never exceed IMG_WIDTH-1 / IMG_HEIGHT-1.
    logic in_image;
    assign in_image = (col >= OFF_X) && (col < OFF_X + DRAW_W)
                   && (row >= OFF_Y) && (row < OFF_Y + DRAW_H);

    logic [9:0] img_x, img_y;
    assign img_x = (col - OFF_X) >> SCALE_LOG2;
    assign img_y = (row - OFF_Y) >> SCALE_LOG2;

    // shared_mem has 1-cycle read latency — delay HS/VS/blank by one
    // cycle so they land alongside the pixel data they actually correspond to
    // i.e. bc shared_mem takes on clk cycle to return read data after address is presented
    //
    // in_image is delayed by the same one cycle for the same reason: it gates
    // the RGB outputs, which belong to the address presented last cycle.
    logic hs_prev, vs_prev, blank_prev, in_image_prev;
    always_ff @(posedge clk) begin
        hs_prev       <= hs;
        vs_prev       <= vs;
        blank_prev    <= blank;
        in_image_prev <= in_image;
    end

    // pixels are 3 tightly-packed bytes (R,G,B) each, so the byte address
    // is the pixel index times BYTES_PER_PIXEL, not the pixel index itself.
    // Parked at IMG_BASE whenever there is nothing valid to fetch, so no
    // out-of-range address is ever presented to shared_mem.
    logic [31:0] pixel_index;
    assign pixel_index = {22'd0, img_y} * IMG_WIDTH + {22'd0, img_x};

    assign disp_addr = (kernel_done && in_image)
        ? gpu_pkg::IMG_BASE + (pixel_index * gpu_pkg::BYTES_PER_PIXEL)
        : gpu_pkg::IMG_BASE;

    // Parked at element 0 when there's nothing valid to fetch, for the same
    // reason disp_addr parks at IMG_BASE: never present an out-of-range index.
    assign disp_pixel = (kernel_done && in_image) ? pixel_index : 32'd0;

    // hs/vs are already driven by vga_gen above -- the delayed copies drive
    // the module's actual sync outputs instead of re-assigning those wires
    assign hsync = hs_prev;
    assign vsync = vs_prev;

    // ------------------------------------------------------------------
    // video_active drives the HDMI transmitter's `vde` (video data enable),
    // and it MUST follow the visible window and nothing else.
    //
    // In DVI, vde low means the TMDS encoder emits CONTROL codes instead of
    // pixel data. Control codes are only legal during blanking. This used to be
    //     ~(blank | ~kernel_done | ~in_image)
    // which drops vde inside the active area everywhere outside the 512x512
    // image -- 45% of an 800x600 screen -- and for the whole frame before the
    // kernel finishes. That sprays control codes through the middle of every
    // active line, so the receiver never establishes a valid link and the
    // monitor reports "no signal" rather than showing a partly-black picture.
    //
    // lab3_src/chipInterface.sv drives `.vde(~blank)` and paints a background
    // colour outside its image, which is the correct shape: the data-enable
    // window is fixed by the video timing, and "nothing to show here" is
    // expressed as a BLACK PIXEL, not as a dropped pixel.
    // ------------------------------------------------------------------
    assign video_active = ~blank_prev;

    // Whether this pixel shows image data. Everything else inside the visible
    // window is drawn black -- still real pixel data, still sent as data.
    logic show_image;
    assign show_image = kernel_done & in_image_prev & ~blank_prev;

    // shared_mem's display port already assembled this pixel's 3 packed bytes
    // into disp_rdata's low 24 bits (handling the word-boundary straddle), and
    // data_buffer's port supplies the same layout, so just slice them out.
    assign vga_r = show_image ? disp_rdata[7:0]   : 8'd0;
    assign vga_g = show_image ? disp_rdata[15:8]  : 8'd0;
    assign vga_b = show_image ? disp_rdata[23:16] : 8'd0;

endmodule : display_controller
