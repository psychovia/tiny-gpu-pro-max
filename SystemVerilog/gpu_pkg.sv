/**
library of macros / constants

**/

package gpu_pkg;

    parameter int N_THREADS       = 4;
    // physical cpu lanes in core.sv == threads per block for scheduler.sv.
    // Was 32, which did not fit: each lane costs ~1410 LUTs (its own 32x32
    // dual-read-port register file + ALU + multiplier), and the 32-way memory
    // arbitration/mux glue in core.sv cost another ~13.8k, totalling 68641
    // LUTs against the xc7s50's 32600 (210%). 8 lanes brings the whole
    // design to roughly 24k LUTs (~75%), leaving room for place-and-route.
    parameter int N_LANES         = 8;
    parameter int IMG_WIDTH       = 64;
    parameter int IMG_HEIGHT      = 64;
    parameter int BYTES_PER_PIXEL = 3;
    parameter int IMG_SIZE_BYTES  = IMG_WIDTH * IMG_HEIGHT * BYTES_PER_PIXEL;

    parameter logic [31:0] PROG_BASE = 32'h0000_0000;
    parameter logic [31:0] PROG_SIZE = 32'h0000_1000; // reserving 4096 bytes for program region
    parameter logic [31:0] IMG_BASE  = PROG_BASE + PROG_SIZE;
    parameter logic [31:0] MMIO_BASE = 32'hFFFF_0000;

    parameter int MEM_SIZE_BYTES = PROG_SIZE + IMG_SIZE_BYTES;

    // one thread = one pixel; a single core (N_THREADS lanes) can't cover the
    // whole image in one pass, so the kernel is split into sequential blocks
    // of N_THREADS pixels each, dispatched one at a time by scheduler.sv
    parameter int TOTAL_THREADS  = IMG_WIDTH * IMG_HEIGHT;
    parameter int NUM_BLOCKS     = TOTAL_THREADS / N_THREADS;
    parameter int BLOCK_ID_WIDTH = $clog2(NUM_BLOCKS);

    // ------------------------------------------------------------------
    // Data buffer (the getdt / setdt / gettid extension)
    // ------------------------------------------------------------------
    // The image lives HERE, not in shared_mem. One 32-bit element per pixel
    // (packed RGB in the low 24 bits) indexed by pixel number, which buys
    // three things over the old "3 packed bytes in main memory" layout:
    //
    //   1. Parallelism. data_buffer.sv is banked one bank per lane, so the 8
    //      lanes of the usual `for (i = tid; i < N; i += N_LANES)` kernel hit
    //      8 different banks and are ALL serviced in one cycle. shared_mem
    //      grants one lane per cycle, so the same access there costs 8.
    //   2. No straddle. A pixel is one element, so nothing spans a word
    //      boundary -- no byte_en, no shifting, no two-word display read.
    //   3. No collisions. Pixels can't be scribbled on by the stack or the
    //      program, because they are not in that address space at all.
    //
    // DBUF_WORDS must be a power of two (the index is masked, not compared)
    // and a multiple of N_LANES (one bank per lane).
    parameter int DBUF_WORDS = IMG_WIDTH * IMG_HEIGHT;   // one element per pixel

    // The three instructions share RISC-V's "custom-0" major opcode, which
    // the spec reserves for exactly this so an implementation can add its own
    // instructions with no risk of colliding with a future extension. funct3
    // tells them apart, so decoding all three costs one opcode compare and a
    // 3-way case.
    // These values are NOT ours to choose -- they are fixed by the toolchain
    // in Lab4_gpu/doc/custom_instructions.md, which is the authority. Note
    // rdtid is 000 and getdt is 010 (an earlier version of this file had them
    // the other way round, which decodes every getdt as an rdtid and vice
    // versa: the kernel then fills the whole image with the lane id).
    parameter logic [6:0] OPC_GPU   = 7'b0001011; // 0x0B, custom-0
    parameter logic [2:0] F3_RDTID  = 3'b000;     // rdtid rd
    parameter logic [2:0] F3_SETDT  = 3'b001;     // setdt rs1, rs2
    parameter logic [2:0] F3_GETDT  = 3'b010;     // getdt rd, rs1

    typedef enum logic [3:0] {
        S_FETCH,        // present mem address = pc
        S_FETCH_WAIT,   // instruction now valid in mem_rdata/instr (decode is combinational off this)
        S_EXECUTE,      // ALU op / branch condition / jump target
        S_MEM_ADDR,     // (loads/stores only) present mem address = ea
        S_MEM_WAIT,     // (loads only) data now valid -> latch it
        S_WRITEBACK     // write rd (if any), compute next pc, loop back to S_FETCH
    } state_t;


endpackage : gpu_pkg

