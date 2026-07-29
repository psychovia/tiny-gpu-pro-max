// tb_harness.sv
// Reusable DUT wrapper for the tiny-gpu compute-path testbenches.
//
// Wraps core.sv + shared_mem.sv (the same pairing test0.sv builds by hand) and
// adds the probe plumbing every test needs, so each test file only contains
// its program name and its expectations.
//
// Like test0.sv this deliberately excludes gpu.sv/display_controller.sv: the
// display path pulls in vga-hdmi.sv and the Counter/Comparator/RangeCheck/
// Subtracter/Mux2to1 helpers that live outside this repo. shared_mem's display
// port is still wired out (disp_addr/disp_rdata) so it can be exercised
// directly without the controller.
//
// PROG_INIT_FILE / IMG_INIT_FILE are parameters rather than hardcoded because
// each test loads its own program and its own data image. Both are passed
// straight through to shared_mem's $readmemb.

`timescale 1ns/1ps

import gpu_pkg::*;

module tb_harness #(
    parameter string PROG_INIT_FILE = "mems/prog.mem",
    parameter string IMG_INIT_FILE  = "mems/img.mem",
    // Source image for the data buffer (getdt/setdt). Defaults to a file of
    // zeros so tests that never touch the buffer need not care; a kernel that
    // filters an existing image points this at its own source.
    parameter string DBUF_INIT_PREFIX = "mems/dbuf_zeros_bank"
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] disp_addr,
    output logic [31:0] disp_rdata,
    output logic        kernel_done
);

    localparam int L = gpu_pkg::N_LANES;

    // Sized off gpu_pkg::N_LANES, not a hardcoded 32 -- core.sv's ports follow
    // N_LANES, so a literal 32 breaks elaboration for any other lane count.
    logic [31:0] mem_addr  [0:L-1];
    logic [31:0] mem_rdata [0:L-1];
    logic        mem_read  [0:L-1];
    logic        mem_write [0:L-1];
    logic [31:0] mem_wdata [0:L-1];
    logic [3:0]  byte_en   [0:L-1];
    logic        mem_valid [0:L-1];

    // data buffer (getdt / setdt)
    logic [31:0] dt_idx   [0:L-1];
    logic        dt_read  [0:L-1];
    logic        dt_write [0:L-1];
    logic [31:0] dt_wdata [0:L-1];
    logic [31:0] dt_rdata [0:L-1];
    logic        dt_valid [0:L-1];

    core u_core (.*);

    shared_mem #(
        .N_THREADS      (L),
        .PROG_INIT_FILE (PROG_INIT_FILE),
        .IMG_INIT_FILE  (IMG_INIT_FILE)
    ) u_shared_mem (.*);

    // The display port isn't part of the compute path these tests exercise
    // (same reason display_controller itself is excluded -- see the header),
    // so it is parked at element 0 and its output left unread.
    logic [31:0] disp_pixel;
    logic [31:0] disp_dt_rdata;
    assign disp_pixel = 32'd0;

    data_buffer #(
        .N_THREADS (L),
        .WORDS     (gpu_pkg::DBUF_WORDS),
        .INIT_PREFIX (DBUF_INIT_PREFIX)
    ) u_data_buffer (.*);

    // ------------------------------------------------------------------
    // Data-buffer probe.
    //
    // Flattened by a genvar loop for the same reason the register probe below
    // is: data_buffer.sv's banks live in a GENERATE block (bank[b].mem), and a
    // hierarchical path into a generate instance must resolve at elaboration
    // with a constant index -- a procedural `int` fails with "'mem' is not
    // declared under prefix 'bank'". The loop also undoes the bank split, so
    // tests ask for a flat element index and never have to know how the
    // buffer is organised inside.
    // ------------------------------------------------------------------
    logic [31:0] dbuf_flat [0:gpu_pkg::DBUF_WORDS-1];
    genvar gb, gr;
    generate
        for (gb = 0; gb < L; gb++) begin : dbuf_bank_probe
            for (gr = 0; gr < gpu_pkg::DBUF_WORDS / L; gr++) begin : dbuf_row_probe
                assign dbuf_flat[gr * L + gb] = u_data_buffer.bank[gb].mem[gr];
            end
        end
    endgenerate

    function automatic logic [31:0] dbuf_read(input int idx);
        dbuf_read = dbuf_flat[idx];
    endfunction

    // ------------------------------------------------------------------
    // Register-file probe.
    //
    // Flattened into a plain array by a genvar loop for the same reason
    // test0.sv does it: core.sv's lanes live in a generate block, and a
    // hierarchical path into a generate instance must resolve at elaboration
    // with a constant index. Indexing with a procedural `int i` fails with
    // "'u_cpu' is not declared under prefix 'lane'". A genvar IS a
    // compile-time constant, so binding into `regs` here lets tests use
    // ordinary procedural loops over both lane and register number.
    // ------------------------------------------------------------------
    logic [31:0] regs [0:L-1][0:31];
    genvar gl;
    generate
        for (gl = 0; gl < L; gl++) begin : lane_probe
            for (gr = 0; gr < 32; gr++) begin : reg_probe
                assign regs[gl][gr] = u_core.lane[gl].u_cpu.regs[gr];
            end
        end
    endgenerate

    // Convenience views of the shared control state, for tests that want to
    // check the pipeline rather than just the end result.
    wire state_t     state       = u_core.state;
    wire [31:0]      pc          = u_core.pc;
    wire [31:0]      instr       = u_core.instr;
    wire [6:0]       opcode      = u_core.opcode;
    wire             stall       = u_core.stall;

    // Word-indexed view of shared memory. mem is indexed by word, so a byte
    // address must be divided by 4 -- wrapped in a function so tests read
    // naturally in byte addresses, matching the assembly they came from.
    function automatic logic [31:0] mem_word(input logic [31:0] byte_addr);
        return u_shared_mem.mem[byte_addr >> 2];
    endfunction

endmodule
