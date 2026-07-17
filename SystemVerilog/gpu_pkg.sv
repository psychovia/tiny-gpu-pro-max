// gpu_pkg.sv
// Shared types for the core's control path. state_t is defined once here so
// scheduler.sv (which owns the register) and cpu.sv (which reads it as an
// input) are guaranteed to agree on the type, instead of relying on file
// compile order / implicit cross-file scoping.

package gpu_pkg;

    typedef enum logic [3:0] {
        S_FETCH,        // present mem address = pc
        S_FETCH_WAIT,   // instruction now valid in mem_rdata/instr (decode is combinational off this)
        S_EXECUTE,      // ALU op / branch condition / jump target
        S_MEM_ADDR,     // (loads/stores only) present mem address = ea
        S_MEM_WAIT,     // (loads only) data now valid -> latch it
        S_WRITEBACK     // write rd (if any), compute next pc, loop back to S_FETCH
    } state_t;

endpackage
