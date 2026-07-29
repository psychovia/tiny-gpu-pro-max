// test0.sv
// Minimal smoke test for core.sv + shared_mem.sv.
//
// Deliberately skips gpu.sv/display_controller.sv: the display path pulls
// in vga-hdmi.sv, which itself depends on Counter/Comparator/RangeCheck/
// Subtracter/Mux2to1 -- small helper modules that live outside this repo
// (course-lab infrastructure) and aren't needed to exercise the compute
// pipeline. This test only checks that core.sv + shared_mem.sv actually
// run a kernel to completion.
//
// mems/prog.mem holds one instruction -- addi x31, x0, 1 -- which every
// lane executes in lockstep and immediately marks itself done via x31.
// Passing this test confirms fetch -> execute -> writeback -> done ->
// kernel_done works end to end.

`timescale 1ns/1ps

import gpu_pkg::*;

module test0;

    logic clk = 1'b0;
    logic rst;

    // Sized off gpu_pkg::N_LANES, not a hardcoded [0:31]. core.sv's ports
    // follow N_LANES, so hardcoding 32 here breaks elaboration with
    // "unpacked array widths (N versus 32) do not match" for any other
    // lane count.
    logic [31:0] mem_addr  [0:gpu_pkg::N_LANES-1];
    logic [31:0] mem_rdata [0:gpu_pkg::N_LANES-1];
    logic        mem_read  [0:gpu_pkg::N_LANES-1];
    logic        mem_write [0:gpu_pkg::N_LANES-1];
    logic [31:0] mem_wdata [0:gpu_pkg::N_LANES-1];
    logic [3:0]  byte_en   [0:gpu_pkg::N_LANES-1];
    logic        mem_valid [0:gpu_pkg::N_LANES-1];
    logic        kernel_done;

    logic [31:0] disp_addr;
    logic [31:0] disp_rdata;

    // Data buffer (getdt/setdt). This test's program never touches it, but
    // core.sv's dt_rdata/dt_valid inputs still need a driver, so the buffer is
    // instantiated rather than tied off -- same wiring gpu.sv uses, just with
    // the display port parked.
    logic [31:0] dt_idx   [0:gpu_pkg::N_LANES-1];
    logic        dt_read  [0:gpu_pkg::N_LANES-1];
    logic        dt_write [0:gpu_pkg::N_LANES-1];
    logic [31:0] dt_wdata [0:gpu_pkg::N_LANES-1];
    logic [31:0] dt_rdata [0:gpu_pkg::N_LANES-1];
    logic        dt_valid [0:gpu_pkg::N_LANES-1];
    logic [31:0] disp_pixel = 32'd0;
    logic [31:0] disp_dt_rdata;

    core u_core (.*);

    shared_mem #(.N_THREADS(gpu_pkg::N_LANES)) u_shared_mem (.*);

    data_buffer #(
        .N_THREADS (gpu_pkg::N_LANES),
        .INIT_PREFIX ("mems/dbuf_zeros_bank")
    ) u_data_buffer (.*);

    // Probe each lane's x31 out through a genvar loop so the check below can
    // be an ordinary procedural loop. core.sv's lanes live in a generate
    // block (`lane[i]`), and a hierarchical path into a generate instance
    // has to be resolved at elaboration with a constant index -- indexing it
    // with a procedural `int i` fails with "'u_cpu' is not declared under
    // prefix 'lane'". A genvar IS a compile-time constant, so binding the
    // values into a plain array here and looping over that works.
    logic [31:0] lane_x31 [0:gpu_pkg::N_LANES-1];
    genvar g;
    generate
        for (g = 0; g < gpu_pkg::N_LANES; g++) begin : probe
            assign lane_x31[g] = u_core.lane[g].u_cpu.regs[31];
        end
    endgenerate

    always #5 clk = ~clk; // 100MHz-equivalent, arbitrary -- no display timing to match here

    int timeout;

    initial begin
        $dumpfile("test0.vcd");
        $dumpvars(0, test0);

        rst = 1'b1;
        disp_addr = '0; // display port unused by this test

        repeat (3) @(posedge clk);
        rst = 1'b0;

        timeout = 0;
        while (!kernel_done && timeout < 2000) begin
            @(posedge clk);
            timeout++;
        end

        if (kernel_done) begin
            $display("PASS: kernel_done asserted after %0d cycles", timeout);
            // sanity check every lane actually landed x31 == 1, not just done
            // Must stop at N_LANES: core.sv only generates that many
            // lane[] instances, so walking to 31 is an elaboration error
            // ("'u_cpu' is not declared under prefix 'lane'"), not just a
            // runtime miss.
            for (int i = 0; i < gpu_pkg::N_LANES; i++) begin
                if (lane_x31[i] !== 32'd1) begin
                    $display("FAIL: lane %0d done but x31 = %0d (expected 1)", i, lane_x31[i]);
                    $finish;
                end
            end
            $display("PASS: all %0d lanes latched x31 == 1", gpu_pkg::N_LANES);
        end else begin
            $display("FAIL: kernel_done never asserted (timed out after %0d cycles)", timeout);
        end

        $finish;
    end

endmodule
