/**
library of macros / constants

**/

package gpu_pkg;

    parameter int N_THREADS       = 4;
    parameter int N_LANES         = 32;   // physical cpu lanes in core.sv == threads per block for scheduler.sv
    parameter int IMG_WIDTH       = 64;
    parameter int IMG_HEIGHT      = 64;
    parameter int BYTES_PER_PIXEL = 4;
    parameter int IMG_SIZE_BYTES  = IMG_WIDTH * IMG_HEIGHT * BYTES_PER_PIXEL;

    parameter logic [31:0] PROG_BASE = 32'h0000_0000;
    parameter logic [31:0] PROG_SIZE = 32'h0000_1000;
    parameter logic [31:0] IMG_BASE  = PROG_BASE + PROG_SIZE;
    parameter logic [31:0] MMIO_BASE = 32'hFFFF_0000;

    parameter int MEM_SIZE_BYTES = PROG_SIZE + IMG_SIZE_BYTES;

    typedef enum logic [3:0] {
        S_FETCH,        // present mem address = pc
        S_FETCH_WAIT,   // instruction now valid in mem_rdata/instr (decode is combinational off this)
        S_EXECUTE,      // ALU op / branch condition / jump target
        S_MEM_ADDR,     // (loads/stores only) present mem address = ea
        S_MEM_WAIT,     // (loads only) data now valid -> latch it
        S_WRITEBACK     // write rd (if any), compute next pc, loop back to S_FETCH
    } state_t;


endpackage : gpu_pkg

