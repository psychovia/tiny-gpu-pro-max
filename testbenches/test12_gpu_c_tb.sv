// test12_gpu_c_tb.sv -- runs COMPILED C on the hardware.
//
// mems/gpu_c.mem is Lab4_gpu/python_scripts/part_b/programs/gpu.c put through
// the INSTRUCTOR's C compiler and assembler (Lab4_gpu/python_scripts/toolchain),
// with python_scripts/gpu_link.py in between to adapt the entry stub. Every
// other test in this suite runs hand-written assembly; this one closes the loop
// from C source to 8 lanes of silicon, and it is the only test that exercises:
//
//   * the compiler's rdtid/setdt/getdt lowering (one custom instruction each),
//     against the funct3 mapping in Lab4_gpu/doc/custom_instructions.md
//   * gpu_link's entry stub -- halting via x31 (this core has no ebreak) and
//     giving each lane its own stack slice
//   * a stack-using program on 8 lanes at once. Every lane runs the same binary
//     out of the same shared_mem, so if they shared one sp they would overwrite
//     each other's locals; one lane wins each arbitrated write and all 8 read
//     that lane's loop index back, so all 8 compute the SAME pixel. The image
//     comes out wrong with nothing else misbehaving, which is why this checks
//     all 4096 pixels rather than sampling.
//
// gpu.c writes `inside - 1`: 0 inside the circle, 0xFFFFFFFF outside -- the two
// values its original if/else wrote, minus the branch. Note that is the inverse
// of render_circle.s (white disc on black); both are checked against the same
// circle equation, so agreeing on the geometry is what matters.

`timescale 1ns/1ps

import gpu_pkg::*;

module test12_gpu_c_tb;

    `include "tb_check.svh"

    localparam int L  = gpu_pkg::N_LANES;
    localparam int W  = gpu_pkg::IMG_WIDTH;
    localparam int H  = gpu_pkg::IMG_HEIGHT;
    localparam int CX = 32, CY = 32, R2 = 144;   // must match gpu.c

    logic        clk = 1'b0;
    logic        rst;
    logic [31:0] disp_addr = '0;
    logic [31:0] disp_rdata;
    logic        kernel_done;

    tb_harness #(
        .PROG_INIT_FILE ("mems/gpu_c.mem"),
        .DBUF_INIT_PREFIX ("mems/dbuf_zeros_bank")
    ) h (.*);

    always #5 clk = ~clk;

    int inside_count = 0;

    initial begin
        $display("== test12_gpu_c: compiled gpu.c on %0d lanes ==", L);
        `TB_RESET
        // Compiled code is far less dense than hand-written asm (a stack frame
        // and an expression stack per statement), so this needs a much bigger
        // budget than test11's equivalent kernel.
        `RUN_KERNEL(kernel_done, 2000000)

        // Each lane must have ended up with its own stack pointer. Checked
        // directly, because it is the difference between a correct image and
        // 8 lanes silently working on one pixel.
        for (int i = 0; i < L; i++)
            `CHECK_EQ($sformatf("lane%0d sp slice", i),
                      h.regs[i][2], 32'(16384 - i * 1024))

        for (int i = 0; i < W * H; i++) begin
            automatic int x  = i % W;
            automatic int y  = i / W;
            automatic int d2 = (x - CX) * (x - CX) + (y - CY) * (y - CY);
            automatic logic [31:0] want = (d2 < R2) ? 32'd0 : 32'hffff_ffff;
            if (d2 < R2) inside_count++;
            `CHECK_EQ($sformatf("pixel (%0d,%0d)", x, y), h.dbuf_read(i), want)
        end

        `CHECK_TRUE("circle covers a plausible area",
                    inside_count > 400 && inside_count < 500)
        $display("  note: %0d of %0d pixels inside the circle", inside_count, W * H);

        `TB_SUMMARY("test12_gpu_c")
    end

endmodule
