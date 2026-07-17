/**
also copied from lab3 lol

TODO: delete i2c_reveiver and assember - put equivelant logic into core.sv later

**/


// ============================================================================
// chipInterface.sv  --  module chipInterface2.  PROVIDED TOP-LEVEL. Do not edit.
//
// The top module for Part 2. It wires your two modules into the display path:
//
//   scl/sda (from the Pi, synchronized)
//        |
//        v
//   i2c_receiver (rcv) --(data, ready)--> assembler (a) --> img[28][28]
//                                                              |
//        vga timing --> img lookup (8x zoom) --> hdmi_tx_0 ----+--> monitor
//
// It also instantiates the regenerated IP: clk_wiz_0 (100 MHz in; 40 MHz pixel
// clock + 200 MHz 5x clock out) and hdmi_tx_0 (DVI, 8/8/8). See docs/setup.md
// for how to create that IP. Build with top = chipInterface2.
// ============================================================================
module chipInterface2 (
    input  logic        CLOCK_100,
    input  logic [ 3:0] BTN,
    input  wire         scl,
    inout  wire         sda,
    inout  logic [9:0]  GPIO,
    input  logic [15:0] SW,
    output logic [15:0] LD,
    output logic        hdmi_clk_n, hdmi_clk_p,
    output logic [ 2:0] hdmi_tx_p, hdmi_tx_n
    );

    logic        drive_sda, ready;
    logic [7:0]  data;
    logic        in;
    logic [27:0][27:0][23:0] img;

    // open-drain SDA: the receiver pulls it low (ACK) or releases it (high-Z)
    assign sda = drive_sda ? 1'b0 : 1'bz;

    logic btn3, reset_sync;
    logic sda_sync, scl_sync;

    // ---- the two modules YOU implement (i2c_receiver.sv + assembler.sv) ----
    i2c_receiver rcv (
        .clk(CLOCK_100), .scl(scl_sync), .sda(sda_sync), .rst(btn3),
        .drive_sda, .data(data), .debug(GPIO[2]), .ready);

    assembler a (.data, .ready, .clk(CLOCK_100), .rst(btn3), .img);

    logic clk_40MHz, clk_200MHz;
    logic locked;
    logic HS, VS, blank;
    logic [9:0] row, col;
    logic [7:0] red, green, blue;
    logic frame_done;

    // clock wizard: 100 MHz in -> 40 MHz pixel clock (clk_out1) + 200 MHz 5x (clk_out2)
    clk_wiz_0 clk_wiz (
        .clk_out1(clk_40MHz),
        .clk_out2(clk_200MHz),
        .reset(btn3),          // active-high reset
        .locked(locked),
        .clk_in1(CLOCK_100)
    );

    // synchronize all buttons
    Synchronizer sync_start_pt(.async(BTN[3]), .clock(CLOCK_100),
                .sync(btn3));
    Synchronizer sync_sda(.async(sda), .clock(CLOCK_100),
                .sync(sda_sync));
    Synchronizer sync_scl(.async(scl), .clock(CLOCK_100),
                .sync(scl_sync));
    Synchronizer sync_reset(.async(BTN[0]), .clock(clk_40MHz),
                .sync(reset_sync));

    vga v (.clock_40MHz(clk_40MHz), .reset(reset_sync), .HS(HS), .VS(VS),
           .blank(blank), .row(row), .col(col), .frame_complete(frame_done));


    areaCheck ac(.x('d200), .y('d200), .length('d224), .height('d224), .row, .col,
       .is_in(in));   // 28 px * 8 = 224 px on-screen

    always_comb begin
        {red, green, blue} = 24'hAA_00AA;
        if (in) begin
            {red, green, blue} = img[(col - 'd200) >> 3][(row - 'd200) >> 3];   // 8x nearest-neighbor zoom
        end
    end


    // Connect signals to the VGA to HDMI converter
    hdmi_tx_0 vga_to_hdmi (
        //Clocking and Reset
        .pix_clk(clk_40MHz),
        .pix_clkx5(clk_200MHz),
        .pix_clk_locked(locked),

        //Reset is active HIGH
        .rst(1'b0),

        //Color and Sync Signals
        .red( red ),
        .green( green ),
        .blue( blue ),

        .hsync( HS ),
        .vsync( VS ),
        .vde( ~blank ),

        //Differential outputs
        .TMDS_CLK_P(hdmi_clk_p),
        .TMDS_CLK_N(hdmi_clk_n),
        .TMDS_DATA_P(hdmi_tx_p),
        .TMDS_DATA_N(hdmi_tx_n)
    );

endmodule : chipInterface2
