// ============================================================================
// tb_io_top.sv -- full integration: bit-bang the real I2C bus into io_top and
// push/pop each FIFO over the register protocol, the way the Pi does. Needs a
// working `fifo` (your fifo.sv).
// ============================================================================
`timescale 1ns/1ps
module tb_io_top;
    logic CLOCK_100 = 0; always #5 CLOCK_100 = ~CLOCK_100;

    tri1 scl_w, sda_w;
    logic c_scl_oe = 0, c_sda_oe = 0;
    assign scl_w = c_scl_oe ? 1'b0 : 1'bz;
    assign sda_w = c_sda_oe ? 1'b0 : 1'bz;

    logic [15:0] LD; logic [3:0] D1_AN, D2_AN; logic [7:0] D1_SEG, D2_SEG;
    io_top dut (.CLOCK_100(CLOCK_100), .scl(scl_w), .sda(sda_w), .BTN0(1'b0),
        .LD(LD), .D1_AN(D1_AN), .D1_SEG(D1_SEG), .D2_AN(D2_AN), .D2_SEG(D2_SEG));

    localparam time Q = 200ns;
    localparam logic [7:0] WR = 8'hA0, RD = 8'hA1;            // addr 0x50 + R/W
    localparam logic [7:0] REG_RX = 8'h01, REG_TX = 8'h02, REG_STATUS = 8'h00;

    int passes=0, fails=0;
    task automatic chk(string n, logic [7:0] got, logic [7:0] exp);
        if (got === exp) begin passes++; $display("  PASS  %-20s 0x%02h", n, got); end
        else begin fails++; $display("  FAIL  %-20s 0x%02h (exp 0x%02h)", n, got, exp); end
    endtask

    task automatic i2c_start; c_sda_oe=0; c_scl_oe=0; #Q; c_sda_oe=1; #Q; c_scl_oe=1; #Q; endtask
    task automatic i2c_stop;  c_scl_oe=1; c_sda_oe=1; #Q; c_scl_oe=0; #Q; c_sda_oe=0; #Q; endtask
    task automatic tx_bit(input logic b);
        c_sda_oe=~b; #Q; c_scl_oe=0; #(2*Q); c_scl_oe=1; #Q;
    endtask
    task automatic tx_byte(input [7:0] d, output logic nak);
        for (int i=7;i>=0;i--) tx_bit(d[i]);
        c_sda_oe=0; #Q; c_scl_oe=0; #Q; nak=sda_w; #Q; c_scl_oe=1; #Q;
    endtask
    task automatic rx_byte(input logic ack, output [7:0] d);
        d=0;
        for (int i=7;i>=0;i--) begin
            c_sda_oe=0; #Q; c_scl_oe=0; #Q; d[i]=(sda_w===1'b0)?1'b0:1'b1; #Q; c_scl_oe=1; #Q;
        end
        c_sda_oe=ack; #Q; c_scl_oe=0; #(2*Q); c_scl_oe=1; #Q; c_sda_oe=0;
    endtask

    logic nak; logic [7:0] b;
    task automatic push_reg(input [7:0] r, input [7:0] v);   // write_byte_data(r, v)
        i2c_start; tx_byte(WR,nak); tx_byte(r,nak); tx_byte(v,nak); i2c_stop;
    endtask
    task automatic read_reg(input [7:0] r, output [7:0] v);  // read_byte_data(r)
        i2c_start; tx_byte(WR,nak); tx_byte(r,nak);
        i2c_start; tx_byte(RD,nak); rx_byte(1'b0, v); i2c_stop;
    endtask

    initial begin
        c_scl_oe=0; c_sda_oe=0; #(20*Q);
        $display("=== io_top integration (push/pop each FIFO over I2C) ===");

        // RX FIFO round-trip
        push_reg(REG_RX, 8'h48); push_reg(REG_RX, 8'h69);   // 'H','i'
        read_reg(REG_RX, b); chk("rx byte #1", b, 8'h48);
        read_reg(REG_RX, b); chk("rx byte #2", b, 8'h69);

        // TX FIFO round-trip (independent)
        push_reg(REG_TX, 8'hC3); push_reg(REG_TX, 8'h5A);
        read_reg(REG_TX, b); chk("tx byte #1", b, 8'hC3);
        read_reg(REG_TX, b); chk("tx byte #2", b, 8'h5A);

        read_reg(REG_STATUS, b);
        chk("overflow clear", {7'b0, b[4]}, 8'h00);

        $display("=== %0d passed, %0d failed ===", passes, fails);
        if (fails) $fatal(1, "IO_TOP TESTS FAILED");
        $finish;
    end
    initial begin #30ms; $fatal(1, "TIMEOUT"); end
endmodule : tb_io_top
