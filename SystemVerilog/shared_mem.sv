/**
- instrctions
- frame buffer A - input, to be computed
- frame buffer B - results, to be outputed
- metadata - tid / width / etc

    e.g.
    apply a foo filter on an image

    instruction - stores instr of a function named "foo"
    fb_A - source image, indexed by position of pixel, each entry is rgb val of corresponding pixel
    fb_B - result image with the filter applied, same structure as fb_A
    
    fb_B[pixel_idx] = filter(fb_A[pixel_idx])

    ** overwrite in place - one large fram buffer instead of separating A / B
    - works if output format / size identical to input

**/

import gpu_pkg::*;

module shared_mem #(
    parameter int    N_THREADS      = gpu_pkg::N_THREADS,
    parameter int    MEM_SIZE_BYTES = gpu_pkg::MEM_SIZE_BYTES,
    parameter string INIT_FILE      = "mems/kernel.mem"
) (
    input logic         clk, rst,
    input logic [31:0]  addr,

    // cpu / thread
    input logic         mem_read,
    input logic         mem_write,
    input logic  [31:0] mem_wdata,
    output logic [31:0] mem_rdata,
    output logic        mem_valid

    // display
    input logic  disp_addr,
    output logic disp_rdata,
);

endmodule