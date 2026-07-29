/**
Name/port adapter: `hdmi_tx_0` (what top.sv instantiates) -> `hdmiTx`
(the actual TMDS transmitter, vendored from Lab2 alongside this file).

top.sv was written against an IP-style name and port list that never
existed in this repo. Rather than rewrite top.sv, the mismatch is
isolated here so the board wrapper stays as-is and the mapping is
obvious in one place.

Port mapping:
    pix_clk        -> pixClk       (40MHz pixel clock)
    pix_clkx5      -> serClk       (200MHz, 5x -- the serializer runs
                                    10:1 DDR off this, so the 5x ratio
                                    is required, not incidental)
    red/green/blue -> same
    hsync/vsync    -> same         (encoded into the blue channel during blanking)
    vde            -> displayEn
    TMDS_CLK_P/N   -> hdmiClkP/hdmiClkN
    TMDS_DATA_P/N  -> hdmiTxP/hdmiTxN

`pix_clk_locked` has no counterpart on hdmiTx, but hdmiTx does have a
real `rst`, so the two are joined here: hold the transmitter in reset
until the MMCM reports lock. Without this the OSERDES chain starts
shifting off an unstable clock and drives garbage TMDS during startup.
top.sv's own `.rst(1'b0)` is intentionally ignored -- see the `rst`
assignment below.
**/

module hdmi_tx_0 (
    input  logic       pix_clk,          // pixel clock (40MHz)
    input  logic       pix_clkx5,        // 5x pixel clock (200MHz) for the 10:1 serializers
    input  logic       pix_clk_locked,   // MMCM lock; low means the clocks aren't trustworthy yet
    input  logic       rst,              // unused -- see note above
    input  logic [7:0] red, green, blue,
    input  logic       hsync, vsync, vde,
    output logic       TMDS_CLK_P, TMDS_CLK_N,
    output logic [2:0] TMDS_DATA_P, TMDS_DATA_N
);
    // Reset the transmitter whenever the clocks aren't locked, OR-ed with
    // whatever top.sv passes in, so an explicit reset still works.
    logic tx_rst;
    assign tx_rst = rst | ~pix_clk_locked;

    hdmiTx u_hdmiTx (
        .pixClk    (pix_clk),
        .serClk    (pix_clkx5),
        .rst       (tx_rst),
        .red       (red),
        .green     (green),
        .blue      (blue),
        .hsync     (hsync),
        .vsync     (vsync),
        .displayEn (vde),
        .hdmiClkP  (TMDS_CLK_P),
        .hdmiClkN  (TMDS_CLK_N),
        .hdmiTxP   (TMDS_DATA_P),
        .hdmiTxN   (TMDS_DATA_N)
    );

endmodule : hdmi_tx_0
