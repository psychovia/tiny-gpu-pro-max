// test14_tmds_tb.sv -- verify the TMDS encoder against the DVI 1.0 spec.
//
// This is the one link in the display chain no other test covers. test13 proves
// pixels reach vga_r/g/b; everything past that -- 8b/10b encoding, running
// disparity, control codes, serialization -- was unverified, which is exactly
// where a "no signal" monitor points.
//
// A monitor rejects the link outright (rather than showing a wrong picture) if
// the CONTROL codes are wrong, because that is what it locks onto during
// blanking. So those are checked exactly, against the four literal words in the
// spec. The data path is checked structurally instead of against a golden table:
//
//   * running disparity must stay bounded. The whole point of the 8b/10b
//     encoding is DC balance; if disparity drifts, the receiver's equalizer
//     loses lock and the monitor drops the link even though every individual
//     word looks plausible.
//   * every emitted word must be recoverable back to the byte that produced it.
//     Decoding is the real correctness property -- a word can be DC-balanced,
//     have few transitions, and still be the wrong symbol.
//   * transition count must be <= 5 within the 8 data bits (transition
//     minimization -- the "TM" in TMDS).
//
// Exhaustive over all 256 byte values, in several disparity states.

`timescale 1ns/1ps

module test14_tmds_tb;

    `include "tb_check.svh"

    logic       clk = 1'b0;
    logic       rst;
    logic [7:0] dataIn;
    logic       ctrl0, ctrl1, dataEn;
    logic [9:0] tmdsOut;

    tmdsEncoder dut (
        .pixClk(clk), .rst(rst), .dataIn(dataIn),
        .ctrl0(ctrl0), .ctrl1(ctrl1), .dataEn(dataEn), .tmdsOut(tmdsOut)
    );

    always #5 clk = ~clk;

    // The DVI decoder, run in reverse: undo the invert, then undo the XOR/XNOR
    // chain. If this doesn't return the byte we put in, the link carries the
    // wrong pixels no matter how well balanced it is.
    function automatic logic [7:0] tmds_decode(input logic [9:0] w);
        logic [7:0] q;
        begin
            q = w[9] ? ~w[7:0] : w[7:0];
            tmds_decode[0] = q[0];
            for (int i = 1; i < 8; i++)
                tmds_decode[i] = w[8] ? (q[i] ^ q[i-1]) : ~(q[i] ^ q[i-1]);
        end
    endfunction

    function automatic int ones10(input logic [9:0] w);
        ones10 = 0;
        for (int i = 0; i < 10; i++) ones10 += w[i];
    endfunction

    function automatic int transitions8(input logic [9:0] w);
        transitions8 = 0;
        for (int i = 1; i < 8; i++) transitions8 += (w[i] !== w[i-1]);
    endfunction

    int running_disp, worst_disp, bad_decode, bad_trans;
    logic [7:0] got;

    task automatic feed(input logic [7:0] d);
        begin
            dataEn = 1'b1; dataIn = d;
            @(posedge clk); #1;
            running_disp += (ones10(tmdsOut) - (10 - ones10(tmdsOut)));
            if (running_disp > worst_disp)  worst_disp = running_disp;
            if (-running_disp > worst_disp) worst_disp = -running_disp;
            got = tmds_decode(tmdsOut);
            if (got !== d) begin
                bad_decode++;
                if (bad_decode <= 5)
                    $display("  FAIL data 0x%02h encoded to %010b, decodes back as 0x%02h",
                             d, tmdsOut, got);
            end
            if (transitions8(tmdsOut) > 5) begin
                bad_trans++;
                if (bad_trans <= 5)
                    $display("  FAIL data 0x%02h -> %010b has %0d transitions (max 5)",
                             d, tmdsOut, transitions8(tmdsOut));
            end
        end
    endtask

    initial begin
        $display("== test14_tmds: DVI 1.0 encoder conformance ==");
        rst = 1'b1; dataEn = 1'b0; ctrl0 = 1'b0; ctrl1 = 1'b0; dataIn = '0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 1'b0;

        // ---- control codes. A monitor locks onto these during blanking; wrong
        // ones mean it never establishes a link at all -- "no signal".
        for (int c = 0; c < 4; c++) begin
            logic [9:0] want;
            dataEn = 1'b0;
            {ctrl1, ctrl0} = c[1:0];
            @(posedge clk); #1;
            case (c)
                0: want = 10'b1101010100;
                1: want = 10'b0010101011;
                2: want = 10'b0101010100;
                3: want = 10'b1010101011;
            endcase
            `CHECK_EQ($sformatf("control code {vsync,hsync}=%02b", c[1:0]), tmdsOut, want)
        end

        // ---- data path, exhaustive ----
        running_disp = 0; worst_disp = 0; bad_decode = 0; bad_trans = 0;
        for (int d = 0; d < 256; d++) feed(d[7:0]);
        // again in the reverse direction, to drive disparity the other way
        for (int d = 255; d >= 0; d--) feed(d[7:0]);
        // and a long run of a deliberately unbalanced byte, the worst case for
        // DC balance -- 0xFF has eight 1s, so a broken disparity update walks
        // off immediately here rather than averaging out.
        for (int i = 0; i < 200; i++) feed(8'hFF);
        dataEn = 1'b0;

        `CHECK_EQ("bytes that failed to decode back", bad_decode, 32'd0)
        `CHECK_EQ("words exceeding 5 transitions",    bad_trans,  32'd0)
        // The spec bounds running disparity; anything beyond a handful means
        // the encoding is not DC balanced and a real receiver would lose lock.
        `CHECK_TRUE($sformatf("running disparity bounded (worst |%0d| <= 10)", worst_disp),
                    worst_disp <= 10)
        $display("  note: %0d bytes checked, worst running disparity |%0d|",
                 256 * 2 + 200, worst_disp);

        `TB_SUMMARY("test14_tmds")
    end

endmodule
