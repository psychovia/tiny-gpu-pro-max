/**

mem -> display_controller (this file) => vga-hdmi IP => fpga

rgb vals

**/

import gpu_pkg::*;


module display_controller #(
    parameter int IMG_WIDTH     = gpu_pkg::IMG_WIDTH,
    parameter int IMG_HEIGHT    = gpu_pkg::IMG_HEIGHT,
    parameter int SCREEN_WIDTH  = 640,
    parameter int SCREEN_HEIGHT = 480
) (
    input  logic        clk, rst, ready,

    // memory
    input  logic [31:0] disp_rdata,
    output logic [31:0] disp_addr,

    // to vga-hdmi IP
    output logic        hsync, vsync,  // horizontal / vertical
    output logic        video_active,
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b
);
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
    always_ff @(posedge clock_40MHz) begin
        hs_prev    <= vs;
        vs_prev    <= vs;
        blank_prev <= blank;
    end

    assign disp_addr = compute_done
        ? gpu_pkg::IMG_BASE + ((row / SCALE_Y) * IMG_WIDTH + (col / SCALE_X))
        : gpu_pkg::IMG_BASE;

    assign hs = hs_prev;
    assign vs = vs_prev;
    assign blank_out = blank_prev || !compute_done;

    // if compute done - diaplay rgb else '0(black)
    logic [7:0] luma;
    assign luma = disp_rdata[7:0];
    assign r = blank_out ? 8'd0 : luma;
    assign g = blank_out ? 8'd0 : luma;
    assign b = blank_out ? 8'd0 : luma;

endmodule : display_controller