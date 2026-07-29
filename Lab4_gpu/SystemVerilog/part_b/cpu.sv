// cpu.sv -- THIS IS THE FILE YOU EDIT. Implement your CPU (one GPU thread) here.
// New here? What a CPU is and the rules it must follow: ../../doc/CPU_explained.md
// The GPU idea and the three custom instructions: ../../doc/GPU_explained.md
// It runs your program (loaded from INIT_FILE). Everything inside -- memory,
// registers, datapath, how you decode and execute -- is yours.
//
//   clk      : system clock.
//   rst      : on-board button 0 (active-high). Use it however you like.
//
// This is ONE THREAD. The board instantiates many copies of it (io_top.sv),
// each with a different `tid`, all sharing one data memory. So your job here is
// the ordinary RV32I + mul CPU, PLUS the three custom-0 instructions:
//
//   tid  : this thread's id (a constant input, different for each copy).
//     rdtid rd        (opcode 0001011, funct3 000):  rd <- tid
//   shared data memory (all threads share ONE; drive these ports):
//     setdt rs1, rs2  (funct3 001):  data[rs1] <- rs2   -> pulse dt_we with
//                     dt_addr=registers[rs1], dt_wdata=registers[rs2][7:0].
//                     A one-clock, never-blocking write.
//     getdt rd, rs1   (funct3 010):  rd <- data[rs1]    -> dt_raddr=registers[rs1];
//                     dt_rdata is the value (combinational), zero-extend into rd.
//
// The old rx/tx byte mailbox is still here (tie it off / use it for debug print):
//   rx_empty/rx_data/rx_pop (input side), tx_full/tx_data/tx_push (output side).
module cpu #(
    parameter int MEM_SIZE_BYTES = 8192,     // byte-addressable memory size (8 KiB)
    parameter int DATA_AW        = 10,        // shared data memory: 2**10 = 1024 cells (32x32)
    // INIT_FILE = the program this CPU runs (the .mem you flash). $readmemb resolves
    // this path against Vivado's RUN directory, not the source tree -- read the synth
    // log to confirm it was picked up; if not, use an absolute path.
    parameter     INIT_FILE      = "mems/gpu_draw.mem"
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx_empty,
    input  logic [7:0] rx_data,
    output logic       rx_pop,
    input  logic       tx_full,
    output logic [7:0] tx_data,
    output logic       tx_push,
    // ---- GPU variant: thread id in, shared data memory out ----
    input  logic [31:0]        tid,       // this thread's id (constant per instance)
    output logic               dt_we,     // setdt write strobe (one clock)
    output logic [DATA_AW-1:0] dt_addr,   // setdt index = registers[rs1]
    output logic [7:0]         dt_wdata,  // setdt value = registers[rs2]
    output logic [DATA_AW-1:0] dt_raddr,  // getdt index = registers[rs1]
    input  logic [7:0]         dt_rdata   // getdt value (combinational read)
);

    // TODO: implement your CPU (RV32I + mul + the three custom-0 instructions).

endmodule : cpu
