/**

mem -> display_controller (this file) => vga-hdmi IP => fpga

rgb vals

reads pixel data out of shared memory and feeds it to the VGA/HDMI output logic which eventually drives the physical display

**/

import gpu_pkg::*;


module display_controller #(
    parameter int IMG_WIDTH     = gpu_pkg::IMG_WIDTH,
    parameter int IMG_HEIGHT    = gpu_pkg::IMG_HEIGHT,
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480
) (
    input  logic        clk, rst, ready,
    input  logic        kernel_done, // from scheduler.sv (via core.sv) -- named to match core.sv's
                                      // actual output so gpu.sv's `.*` wildcard wiring picks it up
                                      // automatically; the image in memory isn't valid until this is high

    // memory
    input  logic [31:0] disp_rdata, // data read from memory
    output logic [31:0] disp_addr,

    // to vga-hdmi IP
    output logic        hsync, vsync,  // horizontal / vertical
    output logic        video_active,
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b
);
    // how many screen pixels each rendered-image pixel gets stretched into.
    // NOTE: SCREEN_HEIGHT/IMG_HEIGHT = 480/64 = 7.5 -- integer division
    // truncates to 7, so the bottom 480 - 64*7 = 32 screen rows fall past
    // the last source row and wrap into whatever disp_addr that division
    // happens to compute. SCREEN_WIDTH/IMG_WIDTH = 640/64 = 10 does divide
    // evenly, so only the vertical axis has this problem.
    localparam int SCALE_X = SCREEN_WIDTH  / IMG_WIDTH;
    localparam int SCALE_Y = SCREEN_HEIGHT / IMG_HEIGHT;

    logic hs, vs, blank;
    logic [9:0] row, col;
    logic frame_complete;

    vga vga_gen (
        .clock_40MHz(clk), .reset(rst),
        .HS(hs), .VS(vs), .blank(blank),
        .row(row), .col(col),
        .frame_complete(frame_complete)
    );

    // shared_mem has 1-cycle read latency — delay HS/VS/blank by one
    // cycle so they land alongside the pixel data they actually correspond to
    logic hs_prev, vs_prev, blank_prev;
    always_ff @(posedge clk) begin
        hs_prev    <= hs;
        vs_prev    <= vs;
        blank_prev <= blank;
    end

    assign disp_addr = kernel_done
        ? gpu_pkg::IMG_BASE + ((row / SCALE_Y) * IMG_WIDTH + (col / SCALE_X))
        : gpu_pkg::IMG_BASE;

    // hs/vs are already driven by vga_gen above -- the delayed copies drive
    // the module's actual sync outputs instead of re-assigning those wires
    assign hsync = hs_prev;
    assign vsync = vs_prev;

    // blank_out: this delayed pixel should NOT be drawn -- either the vga
    // timing generator says we're outside the visible area, or the kernel
    // hasn't finished computing the image yet (nothing valid in memory to show)
    logic blank_out;
    assign blank_out    = blank_prev || !kernel_done;
    assign video_active = !blank_out;

    // if compute done - display rgb else '0 (black)
    logic [7:0] luma;
    assign luma  = disp_rdata[7:0];
    assign vga_r = blank_out ? 8'd0 : luma;
    assign vga_g = blank_out ? 8'd0 : luma;
    assign vga_b = blank_out ? 8'd0 : luma;

endmodule : display_controller