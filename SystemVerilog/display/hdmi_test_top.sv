/**
hdmi_test_top.sv -- a board top that outputs colour bars over HDMI and NOTHING
else. Purely a diagnostic; not part of the GPU.

WHY
    The real top (`top`) chains: MMCM -> core+shared_mem+data_buffer -> kernel
    runs -> kernel_done -> display_controller un-blanks -> TMDS encode ->
    serialize -> HDMI. When the monitor says "no signal", any one of those could
    be at fault, and the status LEDs can only prove the first four are healthy.
    They cannot see past `video_active` into the TMDS bitstream itself, which is
    the one part no simulation testbench covers.

    This strips the chain down to: MMCM -> vga timing -> colour bars -> TMDS ->
    HDMI. No CPU, no memories, no kernel, no data buffer, no display_controller,
    and crucially NO kernel_done gating -- pixels are driven from the instant the
    MMCM locks.

HOW TO READ THE RESULT
    Bars on the monitor -> the entire HDMI output path works: clocking, TMDS
        encoding, OSERDES serialization, differential pins, cable, monitor
        EDID/mode support. The fault is then upstream, in how gpu.sv/
        display_controller drive it, and `top` is where to look.
    Still "no signal" -> the fault is in this path. Since the encoder matches
        the DVI 1.0 spec and the MMCM is verified 40/200MHz phase-aligned, the
        suspects are the OSERDES cascade, the TMDS pin assignment (p/n swap or
        wrong lane order), or the monitor rejecting DVI-over-HDMI (no data
        islands / InfoFrames are transmitted -- this is DVI signalling).

LEDs: LD[0] heartbeat, LD[1] MMCM locked, LD[2] tied high (bitstream identity:
      this is the TEST bitstream, not the GPU), LD[3] video_active.
**/

module hdmi_test_top (
    input  logic        CLOCK_100,
    input  logic [3:0]  BTN,
    output logic        hdmi_clk_n, hdmi_clk_p,
    output logic [2:0]  hdmi_tx_p, hdmi_tx_n,
    output logic [3:0]  LD
);
    logic clk_40MHz, clk_200MHz, locked, reset_sync;

    clk_wiz_0 clk_wiz (
        .clk_out1(clk_40MHz), .clk_out2(clk_200MHz),
        .reset(BTN[0]), .locked(locked), .clk_in1(CLOCK_100)
    );

    Synchronizer sync_reset (.async(BTN[0]), .clock(clk_40MHz), .sync(reset_sync));

    // Same timing generator the real design uses: VESA 800x600@60 on a 40MHz
    // pixel clock. Kept identical on purpose -- if the bars appear, the timing
    // is proven for the real design too.
    logic       hs, vs, blank, frame_complete;
    logic [9:0] row, col;

    vga vga_gen (
        .clock_40MHz(clk_40MHz), .reset(reset_sync),
        .HS(hs), .VS(vs), .blank(blank),
        .row(row), .col(col), .frame_complete(frame_complete)
    );

    // Eight vertical colour bars, 100 pixels each across the 800-pixel width.
    // Combinational off `col`, so it lands in the same cycle as blank -- no
    // memory read, so none of display_controller's 1-cycle delay alignment is
    // needed here.
    //
    // Deliberately saturated primaries: a wrong TMDS channel order shows up as
    // recognisably swapped colours rather than as a subtly wrong picture, and
    // white/black bars at the ends prove full-scale and blanking both work.
    logic [2:0] bar;
    assign bar = col[9:7];               // col/128 -> 0..6 across 800 px

    logic [7:0] r, g, b;
    always_comb begin
        case (bar)
            3'd0: {r, g, b} = {8'hFF, 8'hFF, 8'hFF};  // white
            3'd1: {r, g, b} = {8'hFF, 8'hFF, 8'h00};  // yellow
            3'd2: {r, g, b} = {8'h00, 8'hFF, 8'hFF};  // cyan
            3'd3: {r, g, b} = {8'h00, 8'hFF, 8'h00};  // green
            3'd4: {r, g, b} = {8'hFF, 8'h00, 8'hFF};  // magenta
            3'd5: {r, g, b} = {8'hFF, 8'h00, 8'h00};  // red
            3'd6: {r, g, b} = {8'h00, 8'h00, 8'hFF};  // blue
            default: {r, g, b} = {8'h00, 8'h00, 8'h00}; // black
        endcase
    end

    logic video_active;
    assign video_active = ~blank;

    // Black outside the visible area. The TMDS encoder emits control codes
    // whenever displayEn is low, so the RGB value there is don't-care, but
    // forcing it to 0 keeps the intent obvious.
    hdmi_tx_0 vga_to_hdmi (
        .pix_clk(clk_40MHz), .pix_clkx5(clk_200MHz), .pix_clk_locked(locked),
        .rst(1'b0),
        .red  (video_active ? r : 8'd0),
        .green(video_active ? g : 8'd0),
        .blue (video_active ? b : 8'd0),
        .hsync(hs), .vsync(vs), .vde(video_active),
        .TMDS_CLK_P(hdmi_clk_p), .TMDS_CLK_N(hdmi_clk_n),
        .TMDS_DATA_P(hdmi_tx_p), .TMDS_DATA_N(hdmi_tx_n)
    );

    logic [24:0] heartbeat = '0;
    always_ff @(posedge clk_40MHz) heartbeat <= heartbeat + 1'b1;

    assign LD[0] = heartbeat[24];
    assign LD[1] = locked;
    assign LD[2] = 1'b1;            // always on: "this is the HDMI test bitstream"
    assign LD[3] = video_active;

endmodule : hdmi_test_top
