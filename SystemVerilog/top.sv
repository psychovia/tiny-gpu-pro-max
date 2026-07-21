/**
FPGA-board top level: takes the board's raw 100MHz clock + buttons in,
drives the physical HDMI pins out. Everything board-specific (clock
generation, reset synchronization, the HDMI serializer IP) lives here so
gpu.sv/core.sv/etc. stay simulation-friendly and hardware-agnostic.

Wires through gpu.sv, which is the module that actually matches the
current core.sv/shared_mem.sv/display_controller.sv port lists (it
instantiates core <-> shared_mem <-> display_controller internally) --
this file used to instantiate `core`/`display_controller` directly with
a stale port list from before the shared_mem split, which no longer
elaborated against current core.sv.
**/

module top (
    input  logic        CLOCK_100,   // board's raw input clock
    input  logic [3:0]  BTN,         // board push-buttons; BTN[0] doubles as reset
    output logic        hdmi_clk_n, hdmi_clk_p,   // HDMI differential clock pair
    output logic [2:0]  hdmi_tx_p, hdmi_tx_n      // HDMI differential data lanes (R/G/B)
);
    logic clk_40MHz, clk_200MHz, locked, reset_sync;

    // clock wizard IP: derives the two clocks we actually need (40MHz for
    // pixel/logic timing, 200MHz for the HDMI serializer) from the board's
    // 100MHz input, and reports `locked` once both are stable.
    clk_wiz_0 clk_wiz (
        .clk_out1(clk_40MHz), .clk_out2(clk_200MHz),
        .reset(BTN[0]), .locked(locked), .clk_in1(CLOCK_100)
    );

    // BTN[0] is an async physical button press -- sync it into the 40MHz
    // clock domain before using it as reset, so it can't glitch logic
    // that's mid-transition on the clock edge.
    Synchronizer sync_reset (.async(BTN[0]), .clock(clk_40MHz), .sync(reset_sync));

    logic       hsync, vsync, video_active;
    logic [7:0] red, green, blue;
    logic       kernel_done;   // unused up here -- nothing on the board consumes it today

    // gpu.sv owns the whole compute+memory+scanout pipeline (core <->
    // shared_mem <-> display_controller); this board wrapper just feeds
    // it the board clock/reset and forwards its VGA-style outputs to the
    // HDMI serializer below.
    gpu u_gpu (
        .clk(clk_40MHz), .rst(reset_sync),
        .kernel_done(kernel_done),
        .hsync(hsync), .vsync(vsync), .video_active(video_active),
        .vga_r(red), .vga_g(green), .vga_b(blue)
    );

    // Xilinx HDMI transmitter IP: takes plain VGA-style signals (sync +
    // RGB + video-active) and serializes them into the TMDS differential
    // pairs HDMI actually runs over on the physical pins.
    hdmi_tx_0 vga_to_hdmi (
        .pix_clk(clk_40MHz), .pix_clkx5(clk_200MHz), .pix_clk_locked(locked),
        .rst(1'b0),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .vde(video_active),
        .TMDS_CLK_P(hdmi_clk_p), .TMDS_CLK_N(hdmi_clk_n),
        .TMDS_DATA_P(hdmi_tx_p), .TMDS_DATA_N(hdmi_tx_n)
    );
endmodule : top