// ============================================================================
// serializer.sv - 10:1 TMDS Serializer using OSERDESE2 (Spartan-7)
//
// Serializes 10-bit parallel TMDS data using DDR at 5x pixel clock.
// Uses master/slave OSERDESE2 cascade for 10:1 serialization.
// Output through OBUFDS for differential TMDS signaling.
// ============================================================================

module serializer (
    input  logic       pixClk,
    input  logic       serClk,
    input  logic       rst,
    input  logic [9:0] parIn,
    output logic       serOutP,
    output logic       serOutN
);

    logic serOut;
    logic shiftOut1, shiftOut2;

    // Master OSERDESE2: handles bits [0:7]
    OSERDESE2 #(
        .DATA_RATE_OQ  ("DDR"),
        .DATA_RATE_TQ  ("SDR"),
        .DATA_WIDTH    (10),
        .SERDES_MODE   ("MASTER"),
        .TRISTATE_WIDTH(1),
        .TBYTE_CTL     ("FALSE"),
        .TBYTE_SRC     ("FALSE")
    ) master (
        .OQ       (serOut),
        .OFB      (),
        .TQ       (),
        .TFB      (),
        .SHIFTOUT1(),
        .SHIFTOUT2(),
        .TBYTEOUT (),
        .CLK      (serClk),
        .CLKDIV   (pixClk),
        .D1       (parIn[0]),
        .D2       (parIn[1]),
        .D3       (parIn[2]),
        .D4       (parIn[3]),
        .D5       (parIn[4]),
        .D6       (parIn[5]),
        .D7       (parIn[6]),
        .D8       (parIn[7]),
        .TCE      (1'b0),
        .OCE      (1'b1),
        .TBYTEIN  (1'b0),
        .RST      (rst),
        .SHIFTIN1 (shiftOut1),
        .SHIFTIN2 (shiftOut2),
        .T1       (1'b0),
        .T2       (1'b0),
        .T3       (1'b0),
        .T4       (1'b0)
    );

    // Slave OSERDESE2: handles bits [8:9]
    OSERDESE2 #(
        .DATA_RATE_OQ  ("DDR"),
        .DATA_RATE_TQ  ("SDR"),
        .DATA_WIDTH    (10),
        .SERDES_MODE   ("SLAVE"),
        .TRISTATE_WIDTH(1),
        .TBYTE_CTL     ("FALSE"),
        .TBYTE_SRC     ("FALSE")
    ) slave (
        .OQ       (),
        .OFB      (),
        .TQ       (),
        .TFB      (),
        .SHIFTOUT1(shiftOut1),
        .SHIFTOUT2(shiftOut2),
        .TBYTEOUT (),
        .CLK      (serClk),
        .CLKDIV   (pixClk),
        .D1       (1'b0),
        .D2       (1'b0),
        .D3       (parIn[8]),
        .D4       (parIn[9]),
        .D5       (1'b0),
        .D6       (1'b0),
        .D7       (1'b0),
        .D8       (1'b0),
        .TCE      (1'b0),
        .OCE      (1'b1),
        .TBYTEIN  (1'b0),
        .RST      (rst),
        .SHIFTIN1 (1'b0),
        .SHIFTIN2 (1'b0),
        .T1       (1'b0),
        .T2       (1'b0),
        .T3       (1'b0),
        .T4       (1'b0)
    );

    // Differential output buffer
    OBUFDS obuf (
        .I  (serOut),
        .O  (serOutP),
        .OB (serOutN)
    );

endmodule
