/**
FPGA-board top level: takes the board's raw 100MHz clock + buttons in,
drives the physical HDMI pins out. Everything board-specific (clock
generation, reset synchronization, the HDMI serializer IP) lives here so
gpu.sv/core.sv/etc. stay simulation-friendly and hardware-agnostic.

Wires through gpu.sv, which is the module that actually matches the
current core.sv/shared_mem.sv/display_controller.sv port lists (it
instantiates core <-> shared_mem <-> data_buffer <-> display_controller
internally) -- this file used to instantiate `core`/`display_controller`
directly with a stale port list from before the shared_mem split, which no
longer elaborated against current core.sv.

NOTE: `top` is the module to synthesize, NOT `gpu`. Vivado's auto-top
heuristic picks `gpu`, which has no board pins at all -- every constraint in
the XDC then matches nothing and write_bitstream fails on unconstrained I/O
(DRC NSTD-1 / UCIO-1) after synthesis and implementation have both passed.
**/

module top #(
    // ---- which demo gets baked into this bitstream ----
    // A program is baked into the bitstream (there is no way to load a new one
    // over a wire), so these decide what the monitor shows. Defaults are the
    // C-compiled circle kernel rendering into the data buffer.
    //
    //   mems/invert_c.mem      = invert.c  -- negative of the source photo
    //   mems/filter_c.mem      = filter.c  -- greyscale of the source photo
    //   mems/gpu_c.mem         = gpu.c     -- draws a circle, ignores the source
    //                            (all three: the instructor's compiler ->
    //                             gpu_link.py -> assembler)
    //   mems/render_circle.mem = the same picture, hand-written assembly
    //   mems/filter_gray.mem   = the older lw/sw kernel, which writes its image
    //                            into shared_mem -- pair it with
    //                            DISPLAY_FROM_DBUF = 0 and IMG_INIT_FILE
    parameter string PROG_INIT_FILE    = "mems/invert_c.mem",
    parameter string DBUF_INIT_PREFIX  = "mems/dbuf_photo_bank",
    parameter bit    DISPLAY_FROM_DBUF = 1'b1
) (
    input  logic        CLOCK_100,   // board's raw input clock
    input  logic [3:0]  BTN,         // board push-buttons; BTN[0] doubles as reset
    output logic        hdmi_clk_n, hdmi_clk_p,  // HDMI differential clock pair
    output logic [2:0]  hdmi_tx_p, hdmi_tx_n,    // HDMI differential data lanes (R/G/B)

    // ---- status LEDs -------------------------------------------------
    // Without these the board is opaque: display_controller blanks all video
    // until kernel_done, so "the kernel hung" and "HDMI is broken" produce the
    // identical symptom -- a dark screen -- with no way to tell them apart.
    // Each LED isolates one link in the chain; see the assignments below.
    output logic [3:0]  LD
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
    logic       kernel_done;   // surfaced on LD[2], see below

    // gpu.sv owns the whole compute+memory+scanout pipeline (core <->
    // shared_mem <-> data_buffer <-> display_controller); this board wrapper
    // just feeds it the board clock/reset and forwards its VGA-style outputs
    // to the HDMI serializer below.
    gpu #(
        .PROG_INIT_FILE    (PROG_INIT_FILE),
        .DBUF_INIT_PREFIX  (DBUF_INIT_PREFIX),
        .DISPLAY_FROM_DBUF (DISPLAY_FROM_DBUF)
    ) u_gpu (
        .clk(clk_40MHz), .rst(reset_sync),
        .kernel_done(kernel_done),
        .hsync(hsync), .vsync(vsync), .video_active(video_active),
        .vga_r(red), .vga_g(green), .vga_b(blue)
    );

    // ------------------------------------------------------------------
    // Status LEDs -- read these first when the screen is blank.
    //
    //   LD[0] heartbeat, ~1.2 Hz off the 40MHz pixel clock.
    //         dark/steady -> the MMCM never locked, or the bitstream is not
    //                        running at all. Nothing downstream can work.
    //         blinking    -> clock and configuration are fine.
    //   LD[1] clk_wiz locked. Must be solid on.
    //   LD[2] kernel_done -- every lane wrote 1 to x31. The kernel takes about
    //         28ms, so this should light essentially instantly after reset and
    //         STAY on.
    //         off -> compute is stuck (or program memory is empty) and
    //                display_controller is blanking the video deliberately: a
    //                dark screen here is the CPU's fault, not HDMI's.
    //         on  -> compute finished; a dark screen now is the video path.
    //   LD[3] video_active -- pixels are being driven. High ~64% of the time
    //         at 800x600, so it reads as a dim-but-lit LED.
    //         off while LD[2] is on -> scanout is dead.
    // ------------------------------------------------------------------
    logic [24:0] heartbeat = '0;
    always_ff @(posedge clk_40MHz) heartbeat <= heartbeat + 1'b1;

    assign LD[0] = heartbeat[24];
    assign LD[1] = locked;
    assign LD[2] = kernel_done;
    assign LD[3] = video_active;

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
