// ============================================================================
// hdmiTx.sv - HDMI/DVI Transmitter
//
// Combines 3 TMDS encoders (R, G, B) and 4 serializers (3 data + 1 clock).
// Blue channel carries hsync/vsync during blanking.
// ============================================================================

module hdmiTx (
    input  logic       pixClk,
    input  logic       serClk,
    input  logic       rst,
    input  logic [7:0] red,
    input  logic [7:0] green,
    input  logic [7:0] blue,
    input  logic       hsync,
    input  logic       vsync,
    input  logic       displayEn,
    output logic       hdmiClkP,
    output logic       hdmiClkN,
    output logic [2:0] hdmiTxP,
    output logic [2:0] hdmiTxN
);

    logic [9:0] tmdsRed, tmdsGreen, tmdsBlue;

    // TMDS encoders
    tmdsEncoder encBlue (
        .pixClk  (pixClk),
        .rst     (rst),
        .dataIn  (blue),
        .ctrl0   (hsync),
        .ctrl1   (vsync),
        .dataEn  (displayEn),
        .tmdsOut (tmdsBlue)
    );

    tmdsEncoder encGreen (
        .pixClk  (pixClk),
        .rst     (rst),
        .dataIn  (green),
        .ctrl0   (1'b0),
        .ctrl1   (1'b0),
        .dataEn  (displayEn),
        .tmdsOut (tmdsGreen)
    );

    tmdsEncoder encRed (
        .pixClk  (pixClk),
        .rst     (rst),
        .dataIn  (red),
        .ctrl0   (1'b0),
        .ctrl1   (1'b0),
        .dataEn  (displayEn),
        .tmdsOut (tmdsRed)
    );

    // Serializers for data channels
    serializer serBlue (
        .pixClk  (pixClk),
        .serClk  (serClk),
        .rst     (rst),
        .parIn   (tmdsBlue),
        .serOutP (hdmiTxP[0]),
        .serOutN (hdmiTxN[0])
    );

    serializer serGreen (
        .pixClk  (pixClk),
        .serClk  (serClk),
        .rst     (rst),
        .parIn   (tmdsGreen),
        .serOutP (hdmiTxP[1]),
        .serOutN (hdmiTxN[1])
    );

    serializer serRed (
        .pixClk  (pixClk),
        .serClk  (serClk),
        .rst     (rst),
        .parIn   (tmdsRed),
        .serOutP (hdmiTxP[2]),
        .serOutN (hdmiTxN[2])
    );

    // Clock channel: constant pattern 1111100000 (pixel clock as TMDS)
    serializer serClock (
        .pixClk  (pixClk),
        .serClk  (serClk),
        .rst     (rst),
        .parIn   (10'b0000011111),
        .serOutP (hdmiClkP),
        .serOutN (hdmiClkN)
    );

endmodule
