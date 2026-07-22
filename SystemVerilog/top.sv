/**

**/

module top (
    input  logic        CLOCK_100,
    input  logic [3:0]  BTN,
    output logic        hdmi_clk_n, hdmi_clk_p,
    output logic [2:0]  hdmi_tx_p, hdmi_tx_n
);
    logic clk_40MHz, clk_200MHz, locked, reset_sync;

    clk_wiz_0 clk_wiz (
        .clk_out1(clk_40MHz), .clk_out2(clk_200MHz),
        .reset(BTN[0]), .locked(locked), .clk_in1(CLOCK_100)
    );

    Synchronizer sync_reset (.async(BTN[0]), .clock(clk_40MHz), .sync(reset_sync));

    logic [31:0] disp_addr, disp_rdata;
    logic        compute_done;

    core my_core (
        .clk(clk_40MHz), .rst(reset_sync),
        .disp_addr(disp_addr), .disp_rdata(disp_rdata),
        .compute_done(compute_done)
    );

    logic       hsync, vsync, video_active;
    logic [7:0] red, green, blue;

    display_controller disp_ctrl (
        .clk(clk_40MHz), .rst(reset_sync), .compute_done(compute_done),
        .disp_rdata(disp_rdata), .disp_addr(disp_addr),
        .hsync(hsync), .vsync(vsync), .video_active(video_active),
        .vga_r(red), .vga_g(green), .vga_b(blue)
    );

    hdmi_tx_0 vga_to_hdmi (
        .pix_clk(clk_40MHz), .pix_clkx5(clk_200MHz), .pix_clk_locked(locked),
        .rst(1'b0),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .vde(video_active),
        .TMDS_CLK_P(hdmi_clk_p), .TMDS_CLK_N(hdmi_clk_n),
        .TMDS_DATA_P(hdmi_tx_p), .TMDS_DATA_N(hdmi_tx_n)
    );
endmodule : top