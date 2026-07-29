// ============================================================================
// tb_fifo.sv -- exhaustively exercise the FIFO primitive, especially the
// concurrency cases: simultaneous push+pop in the middle, at empty, and at full;
// overflow on push-while-full; pointer wraparound.
// ============================================================================
`timescale 1ns/1ps
module tb_fifo;
    logic clk = 0; always #5 clk = ~clk;

    localparam int DEPTH = 4;
    logic       rst = 0, push = 0, pop = 0;
    logic [7:0] wdata = 0, rdata;
    logic       full, empty, overflow;
    logic [7:0] count;

    fifo #(.WIDTH(8), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst(rst), .push(push), .wdata(wdata), .full(full),
        .pop(pop), .rdata(rdata), .empty(empty), .count(count), .overflow(overflow)
    );

    int passes = 0, fails = 0;
    task automatic chk(string n, logic [31:0] got, logic [31:0] exp);
        if (got === exp) begin passes++; $display("  PASS  %-26s = %0d", n, got); end
        else begin fails++; $display("  FAIL  %-26s = %0d (exp %0d)", n, got, exp); end
    endtask

    task automatic do_push(input [7:0] v);
        @(negedge clk); push = 1; wdata = v; @(negedge clk); push = 0;
    endtask
    task automatic do_pop(output [7:0] b);
        @(negedge clk); b = rdata; pop = 1; @(negedge clk); pop = 0;
    endtask
    task automatic do_pushpop(input [7:0] v, output [7:0] b);  // same cycle
        @(negedge clk); b = rdata; push = 1; wdata = v; pop = 1;
        @(negedge clk); push = 0; pop = 0;
    endtask
    task automatic do_reset;                                   // one cycle of rst
        @(negedge clk); rst = 1; @(negedge clk); rst = 0;
    endtask

    logic [7:0] b;
    initial begin
        @(negedge clk);
        $display("=== fifo (DEPTH=%0d) ===", DEPTH);
        chk("empty at reset", empty, 1);
        chk("count at reset", count, 0);

        do_push(8'hA1); do_push(8'hA2); do_push(8'hA3);
        chk("count after 3 push", count, 3);
        chk("not full", full, 0);

        do_pop(b); chk("pop #1 (FIFO order)", b, 8'hA1);
        do_pop(b); chk("pop #2", b, 8'hA2);
        chk("count now", count, 1);

        // fill to full and try to overflow
        do_push(8'hB1); do_push(8'hB2); do_push(8'hB3);   // head had A3; now A3,B1,B2,B3
        chk("count == DEPTH", count, DEPTH);
        chk("full", full, 1);
        do_push(8'hCC);                                    // push while full -> dropped
        chk("still full", full, 1);
        chk("overflow latched", overflow, 1);

        // simultaneous push+pop while FULL: count stays, oldest leaves, newest enters
        do_pushpop(8'hD4, b);
        chk("pushpop@full pops oldest", b, 8'hA3);
        chk("pushpop@full count stays", count, DEPTH);

        // drain and verify order incl the just-pushed D4
        do_pop(b); chk("drain B1", b, 8'hB1);
        do_pop(b); chk("drain B2", b, 8'hB2);
        do_pop(b); chk("drain B3", b, 8'hB3);
        do_pop(b); chk("drain D4", b, 8'hD4);
        chk("empty after drain", empty, 1);

        // simultaneous push+pop while EMPTY: pop ignored, push lands (count->1)
        do_pushpop(8'hE5, b);
        chk("pushpop@empty count", count, 1);
        do_pop(b); chk("pushpop@empty kept push", b, 8'hE5);

        // wraparound: cycle many through to exercise pointer wrap
        for (int i = 0; i < 10; i++) begin
            do_push(8'(i)); do_pop(b); chk($sformatf("wrap %0d", i), b, 8'(i));
        end
        chk("empty after wrap", empty, 1);
        chk("overflow sticky across all ops", overflow, 1);  // set once, never cleared

        // synchronous reset: clears the FIFO back to empty (and the overflow flag)
        do_push(8'h77); do_push(8'h88);
        chk("count before rst", count, 2);
        do_reset();
        chk("empty after rst", empty, 1);
        chk("count after rst", count, 0);
        chk("not full after rst", full, 0);
        chk("overflow cleared by rst", overflow, 0);
        do_push(8'h99); do_pop(b); chk("works again after rst", b, 8'h99);

        $display("=== %0d passed, %0d failed ===", passes, fails);
        if (fails) $fatal(1, "FIFO TESTS FAILED");
        $finish;
    end
    initial begin #1ms; $fatal(1, "TIMEOUT"); end
endmodule : tb_fifo
