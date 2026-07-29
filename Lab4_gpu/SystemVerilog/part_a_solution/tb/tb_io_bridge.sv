// ============================================================================
// tb_io_bridge.sv -- drive io_bridge's target-side signals directly and check
// that the Pi can push AND pop each FIFO independently: order, depth, overflow,
// status. Needs a working `fifo` (your fifo.sv).
// ============================================================================
`timescale 1ns/1ps
module tb_io_bridge;
    logic clk = 0; always #5 clk = ~clk;

    localparam logic [7:0] REG_STATUS  = 8'h00;
    localparam logic [7:0] REG_RX      = 8'h01;
    localparam logic [7:0] REG_TX      = 8'h02;
    localparam int RX_EMPTY=0, RX_FULL=1, TX_EMPTY=2, TX_FULL=3, OVERFLOW=4;

    logic       ready=0, addr_match=0, is_read=0, rd_load=0;
    logic [7:0] data=0;
    logic [7:0] rd_data;
    logic [7:0] dbg_last, dbg_rx_count, dbg_tx_count;
    logic       dbg_overflow;

    io_bridge dut (
        .clk(clk), .rst(1'b0), .data(data), .ready(ready), .addr_match(addr_match),
        .is_read(is_read), .rd_data(rd_data), .rd_load(rd_load),
        .dbg_last(dbg_last), .dbg_rx_count(dbg_rx_count),
        .dbg_tx_count(dbg_tx_count), .dbg_overflow(dbg_overflow)
    );

    int passes=0, fails=0;
    task automatic chk(string n, logic [31:0] got, logic [31:0] exp);
        if (got === exp) begin passes++; $display("  PASS  %-26s = 0x%02h", n, got); end
        else begin fails++; $display("  FAIL  %-26s = 0x%02h (exp 0x%02h)", n, got, exp); end
    endtask

    // emulate i2c_target's outputs to the bridge:
    task automatic pi_point(input [7:0] r);            // address(W) then the pointer byte
        @(negedge clk); addr_match=1; is_read=0; @(negedge clk); addr_match=0;
        @(negedge clk); ready=1; data=r;           @(negedge clk); ready=0;
    endtask
    task automatic pi_write(input [7:0] d);            // a data byte -> push current reg
        @(negedge clk); ready=1; data=d; @(negedge clk); ready=0;
    endtask
    task automatic pi_read(output [7:0] b);            // read/pop current reg
        @(negedge clk); b=rd_data; rd_load=1; @(negedge clk); rd_load=0;
    endtask

    logic [7:0] b;
    initial begin
        @(negedge clk);
        $display("=== io_bridge (Pi drives both ends) ===");

        // RX: push 3, pop 3 in FIFO order
        pi_point(REG_RX); pi_write(8'hA1); pi_write(8'hA2); pi_write(8'hA3);
        chk("rx count = 3", dbg_rx_count, 3);
        pi_point(REG_RX);
        pi_read(b); chk("rx pop #1", b, 8'hA1);
        pi_read(b); chk("rx pop #2", b, 8'hA2);
        pi_read(b); chk("rx pop #3", b, 8'hA3);
        chk("rx empty", dbg_rx_count, 0);

        // TX: independent
        pi_point(REG_TX); pi_write(8'h51); pi_write(8'h52);
        chk("tx count = 2", dbg_tx_count, 2);
        chk("rx still empty", dbg_rx_count, 0);
        pi_point(REG_TX);
        pi_read(b); chk("tx pop #1", b, 8'h51);
        pi_read(b); chk("tx pop #2", b, 8'h52);

        // empty pop = safe no-op
        pi_point(REG_RX); pi_read(b); chk("empty rx read", b, 8'h00);
        chk("empty read didn't pop", dbg_rx_count, 0);

        // depth + overflow on RX (DEPTH 16)
        pi_point(REG_RX);
        for (int i=0;i<16;i++) pi_write(8'(i));
        chk("rx caps at DEPTH", dbg_rx_count, 16);
        pi_write(8'hEE);                                  // 17th -> dropped
        chk("overflow latched", dbg_overflow, 1);
        chk("rx still DEPTH", dbg_rx_count, 16);
        pi_point(REG_STATUS); pi_read(b);
        chk("status RX_FULL",  {31'b0,b[RX_FULL]},  1);
        chk("status OVERFLOW", {31'b0,b[OVERFLOW]}, 1);
        pi_point(REG_RX);
        for (int i=0;i<16;i++) begin pi_read(b); chk($sformatf("drain %0d", i), b, 8'(i)); end
        chk("rx empty again", dbg_rx_count, 0);

        $display("=== %0d passed, %0d failed ===", passes, fails);
        if (fails) $fatal(1, "IO_BRIDGE TESTS FAILED");
        $finish;
    end
    initial begin #2ms; $fatal(1, "TIMEOUT"); end
endmodule : tb_io_bridge
