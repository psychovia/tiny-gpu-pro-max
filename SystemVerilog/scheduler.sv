/**
scheduler
- manages execution of threads (won't pick up another block before completion)
- each cpu has it's own register, need to write scheduler that writes the values of the register for cpu

    array indexed by tid
    element = pc of corresponding thread

    detect different pcs among threads
        - if different - pick an arbitrary pc to work on, stall the rest, continue when done

    lane     = physical instances of units - number of workers
    threads  = total amount of computation - total amount of work
    block    = "shift"

    hierarchy: kernal - block - thread

**/

// moving state/next_state logic here because we don't want 32 independent copies of "what phase am I in," each free to disagree with others which would break SIMD


import gpu_pkg::*;

module scheduler #(
    parameter int LANES         = gpu_pkg::N_LANES,                          // physical cpu lanes = threads per block
    parameter int TOTAL_THREADS = gpu_pkg::IMG_WIDTH * gpu_pkg::IMG_HEIGHT,  // one thread per pixel
    parameter int N_BLOCKS      = (TOTAL_THREADS + LANES - 1) / LANES        // compile-time, from image size
) (
    input  logic clk, rst,

    // from fetcher
    input  logic [6:0] opcode,

    // from pc.sv
    input  logic [31:0] next_pc,

    // from/to cpu
    input  logic        done    [0:LANES-1], // sticky - stays same until rst
    output logic [31:0] pc      [0:LANES-1], 
    output logic [31:0] thread_base,      // lane i's thread_id = thread_base + i
    
    // to fetcher
    output state_t state,

    // to core
    output logic kernel_done  // when every block is done
);

    // FSM
    // keep running for undone lanes in a block
    state_t next_state;

    always_ff @(posedge clk) begin
        if (rst)               state <= S_FETCH;
        else if (!kernel_done) state <= next_state;
    end

    // next state logic
    always_comb begin
        next_state = state;
        case (state)
            S_FETCH:      next_state = S_FETCH_WAIT;
            S_FETCH_WAIT: next_state = S_EXECUTE; // instr valid now; decode is combinational off it
            S_EXECUTE: begin
                // branch on opcode
                case (opcode)
                    // R-type / I-type / lui / auipc / jmp / branch
                    // bc result can be calculated in execute w/o reading/writing data memory
                    7'b0110011, 7'b0010011, 7'b0110111, 7'b0010111, 7'b1101111, 7'b1100111, 7'b1100011:
                        next_state = S_WRITEBACK;
                    // load / store between memory & register
                    7'b0000011, 7'b0100011:
                        next_state = S_MEM_ADDR;
                    default: next_state = S_WRITEBACK;
                endcase
            end
            S_MEM_ADDR: begin
                next_state = (opcode == 7'b0000011) ? S_MEM_WAIT : S_WRITEBACK; // if loading then wait else writeback
            end
            S_MEM_WAIT: next_state = S_WRITEBACK;

            S_WRITEBACK:  next_state = S_FETCH;
            default:      next_state = S_FETCH;
        endcase
    end

    

    // block
    localparam int BLOCK_ID_W = (N_BLOCKS > 1) ? $clog2(N_BLOCKS) : 1;
    logic [BLOCK_ID_W-1:0] block_id;
    logic                  block_done; // every lane in this block has finished
    logic                  last_block;

    assign last_block  = (block_id == N_BLOCKS-1);
    assign kernel_done = block_done && last_block;
    assign thread_base = block_id * LANES;

    // TODO(blocking): done[i] is sticky in cpu.sv and only clears on global
    // rst, so the instant block 0 finishes, block 1 would see every lane
    // already "done" and block_id would race through every remaining block
    // in a few cycles without doing any real work. Needs either 
    // (a) a per-block clear pulse added to cpu.sv
    // (b) scheduler latching its own block-local done bits off a one-shot "lane just finished" strobe

    always_comb begin
        block_done = 1'b1;
        for (int i = 0; i < LANES; i++) block_done &= done[i];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            block_id <= '0;
        end else if (state == S_WRITEBACK && block_done && !last_block) begin
            block_id <= block_id + 1'b1;
        end
    end


    // per-lane pc
    // running lane - next pc
    // done lane - stay at last value
    // new block starts at lane 0
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < LANES; i++) pc[i] <= 32'd0;
        end else if (state == S_WRITEBACK && block_done && !last_block) begin
            for (int i = 0; i < LANES; i++) pc[i] <= 32'd0;   // next block re-runs kernel from the top
        end else if (state == S_WRITEBACK) begin
            for (int i = 0; i < LANES; i++) begin
                if (!done[i]) pc[i] <= next_pc;
            end
        end
    end

endmodule
