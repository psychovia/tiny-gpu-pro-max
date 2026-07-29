// test_shared_mem_tb.sv -- standalone unit test for shared_mem.sv
//
// Drives the memory directly, without a core, so arbitration can be tested in
// isolation. This is the module test0 exercises least: with one instruction
// and one address, every lane wants the same word, so a totally broken arbiter
// still looks fine. Here each lane asks for a different word.
//
// All stimulus is applied and all responses sampled on the negative clock
// edge, so nothing races the DUT's own posedge-registered outputs.

`timescale 1ns/1ps

import gpu_pkg::*;

module test_shared_mem_tb;

    `include "tb_check.svh"

    localparam int L = gpu_pkg::N_LANES;

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] mem_addr  [0:L-1];
    logic        mem_read  [0:L-1];
    logic        mem_write [0:L-1];
    logic [31:0] mem_wdata [0:L-1];
    logic [3:0]  byte_en   [0:L-1];
    logic [31:0] mem_rdata [0:L-1];
    logic        mem_valid [0:L-1];
    logic [31:0] disp_addr;
    logic [31:0] disp_rdata;

    shared_mem #(
        .N_THREADS      (L),
        .PROG_INIT_FILE ("mems/zeros.mem"),
        .IMG_INIT_FILE  ("mems/memtest_data.mem")
    ) dut (.*);

    always #5 clk = ~clk;

    // independent copy of what was loaded at IMG_BASE
    logic [31:0] golden [0:L-1];
    initial $readmemb("mems/memtest_data.mem", golden);

    int          served_cycle [0:L-1];
    logic [31:0] served_data  [0:L-1];

    // The display port should return the 3 bytes starting at disp_addr,
    // little-endian. Expressed here byte-by-byte rather than by mirroring the
    // DUT's word-pair-and-slice construction, so the two are independent.
    //
    // `golden` is indexed by word WITHIN the image file, so the byte address
    // has to have IMG_BASE subtracted off first -- indexing it with the raw
    // address runs off the end of the array and yields X.
    function automatic logic [7:0] golden_byte(input int off);
        return golden[off >> 2][((off & 3) * 8) +: 8];
    endfunction

    function automatic logic [31:0] disp_expect(input logic [31:0] a);
        int off = int'(a - gpu_pkg::IMG_BASE);
        return {8'd0, golden_byte(off + 2), golden_byte(off + 1), golden_byte(off)};
    endfunction

    task automatic idle_all();
        for (int i = 0; i < L; i++) begin
            mem_read[i]  = 1'b0;
            mem_write[i] = 1'b0;
            mem_addr[i]  = 32'd0;
            mem_wdata[i] = 32'd0;
            byte_en[i]   = 4'd0;
        end
    endtask

    // Every lane reads its own word; record when each was first serviced.
    task automatic read_round(input string label, input int max_cycles);
        for (int i = 0; i < L; i++) begin
            served_cycle[i] = -1;
            served_data[i]  = 32'hXXXX_XXXX;
        end
        @(negedge clk);
        for (int i = 0; i < L; i++) begin
            mem_read[i] = 1'b1;
            mem_addr[i] = gpu_pkg::IMG_BASE + 32'(i) * 4;
        end
        for (int c = 0; c < max_cycles; c++) begin
            @(negedge clk);
            for (int i = 0; i < L; i++)
                if (mem_valid[i] && served_cycle[i] < 0) begin
                    served_cycle[i] = c;
                    served_data[i]  = mem_rdata[i];
                end
        end
        idle_all();
        @(negedge clk);

        for (int i = 0; i < L; i++) begin
            `CHECK_TRUE($sformatf("%s: lane%0d was serviced", label, i),
                        served_cycle[i] >= 0)
            `CHECK_EQ($sformatf("%s: lane%0d got its own word", label, i),
                      served_data[i], golden[i])
        end
    endtask

    initial begin
        $display("== test_shared_mem: arbitration, byte writes, display port ==");
        idle_all();
        disp_addr = '0;
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // ---- 1. every lane serviced within one round, with its own data ----
        // L lanes at one grant per cycle plus a cycle of registered-output
        // latency; anything beyond that means a lane is starving.
        read_round("round1", L + 4);

        // ---- 2. the grant checklist resets, so a second round works too ----
        // If granted_this_round were not wiped between rounds, every lane but
        // one would starve here even though round 1 passed.
        read_round("round2", L + 4);

        // ---- 3. byte-masked write touches only the selected lane ----
        @(negedge clk);
        mem_write[0] = 1'b1;
        mem_addr[0]  = 32'h1080;
        mem_wdata[0] = 32'hFFFF_FFFF;
        byte_en[0]   = 4'b1111;
        repeat (3) @(negedge clk);
        idle_all();
        @(negedge clk);
        `CHECK_EQ("full word write", dut.mem[32'h1080 >> 2], 32'hFFFF_FFFF)

        @(negedge clk);
        mem_write[3] = 1'b1;
        mem_addr[3]  = 32'h1080;
        mem_wdata[3] = 32'h0000_AA00;
        byte_en[3]   = 4'b0010;          // byte 1 only
        repeat (3) @(negedge clk);
        idle_all();
        @(negedge clk);
        `CHECK_EQ("byte_en=0010 changes only byte 1",
                  dut.mem[32'h1080 >> 2], 32'hFFFF_AAFF)

        // ---- 4. MMIO safety contract ----
        // cpu.sv forces byte_en to 0 for MMIO addresses. shared_mem only looks
        // at addr[15:2], so 0xFFFF0000 aliases to word 0; with byte_en zeroed,
        // word 0 must survive untouched. (shared_mem's own sim-only assertion
        // fires if a real write ever reaches an MMIO address.)
        @(negedge clk);
        mem_write[1] = 1'b1;
        mem_addr[1]  = gpu_pkg::MMIO_BASE;
        mem_wdata[1] = 32'hDEAD_DEAD;
        byte_en[1]   = 4'b0000;
        repeat (3) @(negedge clk);
        idle_all();
        @(negedge clk);
        `CHECK_EQ("MMIO store with byte_en=0 leaves word 0 alone",
                  dut.mem[0], 32'd0)

        // ---- 5. display port: 3 packed bytes, 1 cycle of latency ----
        for (int a = 0; a < 6; a++) begin
            @(negedge clk);
            disp_addr = gpu_pkg::IMG_BASE + 32'(a);
            @(negedge clk);   // registered output settles
            `CHECK_EQ($sformatf("disp_rdata @ IMG_BASE+%0d", a),
                      disp_rdata, disp_expect(gpu_pkg::IMG_BASE + 32'(a)))
        end

        // ---- 6. an idle lane must never be told its data landed ----
        idle_all();
        repeat (4) @(negedge clk);
        for (int i = 0; i < L; i++)
            `CHECK_BIT($sformatf("lane%0d idle -> no mem_valid", i),
                       mem_valid[i], 1'b0)

        `TB_SUMMARY("test_shared_mem")
    end

endmodule
