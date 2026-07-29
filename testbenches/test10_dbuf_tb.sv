// test10_dbuf_tb.sv -- checks tests/test10_dbuf.s
//
// The data-buffer extension end to end: gettid, setdt, getdt, and the banked
// buffer behind them.
//
// What each check is actually for:
//
//   gettid   Every lane's x5 must be its own lane_id. If gettid were wired to
//            a shared signal instead of the per-lane generate index, all 8
//            lanes would report the same number and this is where it shows.
//
//   setdt    Every one of the 4096 elements must hold i*16 + (i%8) -- a value
//            that encodes BOTH the index and the writer. A setdt that dropped
//            a write leaves a 0; one that landed in the wrong bank or the
//            wrong row leaves the wrong lane's tag; one that clobbered a
//            neighbour shows up as a duplicate. A checksum alone would miss
//            all three, so this compares element by element.
//
//   getdt    Each lane's accumulated total must match the sum of exactly its
//            own 512 elements. A getdt that returned a neighbour's element
//            (the bank-select bug that matters most here) still produces a
//            plausible-looking number, but not this one.
//
//   banking  The kernel strides by N_LANES, so every lane sits on its own
//            bank and all 8 should be granted in the same cycle. The cycle
//            count is checked against a ceiling that only a genuinely
//            parallel buffer can meet -- see the note on it below.

`timescale 1ns/1ps

import gpu_pkg::*;

module test10_dbuf_tb;

    `include "tb_check.svh"

    localparam int L     = gpu_pkg::N_LANES;
    localparam int WORDS = gpu_pkg::DBUF_WORDS;
    localparam int PER_LANE = WORDS / L;          // 512 elements per lane
    localparam int TAIL  = WORDS - L;             // where phase 3 stamps checksums

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(
        .PROG_INIT_FILE ("mems/test10_dbuf.mem"),
        .DBUF_INIT_PREFIX ("mems/dbuf_zeros_bank")
    ) h (.*);

    always #5 clk = ~clk;

    // ---- banking probe -------------------------------------------------
    // Every cycle in which the buffer answered anybody, record how many lanes
    // it answered at once. Banked, a buffer instruction is one grant cycle
    // serving all L lanes; serialised through a one-lane-per-cycle arbiter it
    // would be L grant cycles serving one lane each. Counting grant cycles and
    // the widest simultaneous grant tells those two apart directly, instead of
    // inferring it from a total-runtime threshold that also moves whenever the
    // FSM or the kernel changes.
    int dt_grant_cycles = 0;
    int dt_widest_grant = 0;
    int dt_lanes_served = 0;

    always @(posedge clk) if (!rst) begin
        automatic int n = 0;
        for (int i = 0; i < L; i++) if (h.dt_valid[i]) n++;
        if (n > 0) begin
            dt_grant_cycles++;
            dt_lanes_served += n;
            if (n > dt_widest_grant) dt_widest_grant = n;
        end
    end

    // Expected per-lane checksum: lane t summed dbuf[8k+t] for k = 0..511,
    // and each of those held (8k+t)*16 + t = 128k + 17t.
    function automatic logic [31:0] expected_sum(input int t);
        expected_sum = 32'd0;
        for (int k = 0; k < PER_LANE; k++)
            expected_sum += 32'(128 * k + 17 * t);
    endfunction

    initial begin
        $display("== test10_dbuf: gettid / setdt / getdt ==");
        `TB_RESET
        `RUN_KERNEL(kernel_done, 100000)

        // ---- gettid gave each lane its own identity ----
        for (int i = 0; i < L; i++)
            `CHECK_EQ($sformatf("lane%0d gettid -> x5", i), h.regs[i][5], 32'(i))

        // ---- setdt wrote every element, with the right tag ----
        // Skips the tail, which phase 3 deliberately overwrites.
        for (int i = 0; i < TAIL; i++)
            `CHECK_EQ($sformatf("dbuf[%0d]", i),
                      h.dbuf_read(i), 32'(i * 16 + (i % L)))

        // ---- getdt read back this lane's own elements, not a neighbour's ----
        for (int i = 0; i < L; i++)
            `CHECK_EQ($sformatf("lane%0d getdt total x7", i),
                      h.regs[i][7], expected_sum(i))

        // ---- and the same total survived a round trip through the buffer ----
        for (int i = 0; i < L; i++)
            `CHECK_EQ($sformatf("dbuf tail[%0d] checksum", i),
                      h.dbuf_read(TAIL + i), expected_sum(i))

        // ---- the banking actually bought the parallelism it exists for ----
        // The kernel issues 1025 buffer instructions (512 setdt + 512 getdt +
        // the tail stamp), each one asking all L lanes at once. If every lane
        // really does land on its own bank, that is 1025 grant cycles of L
        // lanes each. One grant per cycle instead would be L times as many.
        `CHECK_EQ("lanes served in total", dt_lanes_served, 32'((2 * PER_LANE + 1) * L))
        `CHECK_EQ("all L lanes granted together", dt_widest_grant, 32'(L))
        `CHECK_EQ("one grant cycle per buffer instruction",
                  dt_grant_cycles, 32'(2 * PER_LANE + 1))
        $display("  note: %0d buffer instructions, %0d grant cycles, %0d lanes each",
                 2 * PER_LANE + 1, dt_grant_cycles,
                 dt_lanes_served / dt_grant_cycles);

        `TB_SUMMARY("test10_dbuf")
    end

endmodule
