// io_top.sv -- PROVIDED top (set as the Vivado top; reuses top.xdc).
// i2c_target <-> io_bridge <-> fifo x2 (rx, tx).  fifo.sv is yours.
// BTN0 = reset (clears both FIFOs). 7-seg = last byte the Pi pushed into a FIFO.
// Runs on the raw 100 MHz osc.
module io_top (
    input  logic        CLOCK_100,
    input  logic        scl,
    inout  logic        sda,
    input  logic        BTN0,
    output logic [15:0] LD,
    output logic [3:0]  D1_AN,
    output logic [7:0]  D1_SEG,
    output logic [3:0]  D2_AN,
    output logic [7:0]  D2_SEG
);
    logic scl_s, sda_s, rst_s;
    Synchronizer u_sync_scl (.async(scl),  .clock(CLOCK_100), .sync(scl_s));
    Synchronizer u_sync_sda (.async(sda),  .clock(CLOCK_100), .sync(sda_s));
    Synchronizer u_sync_rst (.async(BTN0), .clock(CLOCK_100), .sync(rst_s));

    logic       drive_sda, ready, addr_match, is_read, rd_load;
    logic [7:0] cap_data, rd_data;

    i2c_target u_i2c (
        .clk(CLOCK_100), .scl(scl_s), .sda(sda_s), .drive_sda(drive_sda),
        .data(cap_data), .ready(ready), .addr_match(addr_match), .is_read(is_read),
        .rd_data(rd_data), .rd_load(rd_load)
    );
    assign sda = drive_sda ? 1'b0 : 1'bz;     // open-drain

    logic [7:0] last, rx_count, tx_count;
    logic       overflow;

    io_bridge u_bridge (
        .clk(CLOCK_100), .rst(rst_s), .data(cap_data), .ready(ready),
        .addr_match(addr_match), .is_read(is_read),
        .rd_data(rd_data), .rd_load(rd_load),
        .dbg_last(last), .dbg_rx_count(rx_count), .dbg_tx_count(tx_count),
        .dbg_overflow(overflow)
    );

    logic [26:0] hb = '0;
    always_ff @(posedge CLOCK_100) hb <= hb + 1'b1;
    assign LD[0]     = scl_s;
    assign LD[1]     = sda_s;
    assign LD[2]     = overflow;
    assign LD[3]     = '0;
    assign LD[7:4]   = rx_count[3:0];
    assign LD[11:8]  = tx_count[3:0];
    assign LD[14:12] = '0;
    assign LD[15]    = hb[26];

    function automatic logic [6:0] hex7(input logic [3:0] n);
        case (n)
            4'h0: hex7 = 7'h3F; 4'h1: hex7 = 7'h06; 4'h2: hex7 = 7'h5B; 4'h3: hex7 = 7'h4F;
            4'h4: hex7 = 7'h66; 4'h5: hex7 = 7'h6D; 4'h6: hex7 = 7'h7D; 4'h7: hex7 = 7'h07;
            4'h8: hex7 = 7'h7F; 4'h9: hex7 = 7'h6F; 4'hA: hex7 = 7'h77; 4'hB: hex7 = 7'h7C;
            4'hC: hex7 = 7'h39; 4'hD: hex7 = 7'h5E; 4'hE: hex7 = 7'h79; 4'hF: hex7 = 7'h71;
        endcase
    endfunction

    logic [16:0] refresh = '0;
    always_ff @(posedge CLOCK_100) refresh <= refresh + 1'b1;
    wire       sel = refresh[16];
    wire [3:0] nib = sel ? last[7:4] : last[3:0];

    assign D1_SEG = {1'b1, ~hex7(nib)};
    assign D1_AN  = sel ? 4'b1101 : 4'b1110;
    assign D2_AN  = 4'b1111;
    assign D2_SEG = 8'hFF;

endmodule : io_top
