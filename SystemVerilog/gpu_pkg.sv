/**
library of macros / constants

**/

package gpu_pkg;

    parameter int N_THREADS       = 4;
    parameter int IMG_WIDTH       = 64;
    parameter int IMG_HEIGHT      = 64;
    parameter int BYTES_PER_PIXEL = 4;
    parameter int IMG_SIZE_BYTES  = IMG_WIDTH * IMG_HEIGHT * BYTES_PER_PIXEL;

    parameter logic [31:0] PROG_BASE = 32'h0000_0000;
    parameter logic [31:0] PROG_SIZE = 32'h0000_1000;
    parameter logic [31:0] IMG_BASE  = PROG_BASE + PROG_SIZE;
    parameter logic [31:0] MMIO_BASE = 32'hFFFF_0000;

    parameter int MEM_SIZE_BYTES = PROG_SIZE + IMG_SIZE_BYTES;

endpackage : gpu_pkg