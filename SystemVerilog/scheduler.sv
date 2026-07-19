/**
scheduler
- manages execution of threads (won't pick up another block before completion)
- each cpu has it's own register, need to write scheduler that writes the values of the register for cpu

    array indexed by tid
    element = pc of corresponding thread

    detect different pcs among threads
        - if different - pick an arbitrary pc to work on, stall the rest, continue when done

    lane     = physical instances of units
    threads  = total number of computation
    block    =shifts

**/

// moving state/next_state logic here because we don't want 32 independent copies of "what phase am I in," each free to disagree with others which would break SIMD


import gpu_pkg::*;

module scheduler #(
    parameter int LANES         = gpu_pkg::N_LANES,                         // physical cpu lanes = threads per block
    parameter int TOTAL_THREADS = gpu_pkg::IMG_WIDTH * gpu_pkg::IMG_HEIGHT,  // one thread per pixel
    parameter int N_BLOCKS      = (TOTAL_THREADS + LANES - 1) / LANES       // compile-time, from image size
) (
    // ---- inputs ----
    input  logic        clk, rst,             // FROM: whatever instantiates core.sv (gpu_top.sv / testbench)
    input  logic [6:0]  opcode,               // FROM: decoder.sv -- decoded opcode of the currently fetched instr
    input  logic [31:0] next_pc,              // FROM: pc.sv -- leader-lane's resolved branch/jump target.
                                               // pc.sv needs to expose this (its internal `next_pc` reg) as
                                               // an output instead of owning the final registered pc itself --
                                               // scheduler now owns per-lane pc storage below. Not done yet.
    input  logic        done [0:LANES-1],     // FROM: cpu.sv -- each of the 32 lane instances' sticky done output

    // ---- outputs ----
    output state_t       state,               // TO: fetcher.sv, cpu.sv (all lanes), pc.sv -- shared FSM phase
                                               // they all key off to know when to latch/act
    output logic [31:0]  pc [0:LANES-1],      // TO: cpu.sv -- lane i's own pc input (once core.sv wires it in,
                                               // replacing the old single shared pc.sv wire). NEW.
    output logic [31:0]  thread_base,         // TO: cpu.sv -- lane i's thread_id = thread_base + i (once
                                               // core.sv wires it in, replacing the raw loop index). NEW.
    output logic         kernel_done          // TO: core.sv -- forwarded straight through as core's own
                                               // kernel_done output; existing, semantics widened to mean
                                               // "every block finished," not just the current one
);

    // ------------------------------------------------------------------
    // 1. shared FSM -- same states/transitions as before. Gated on
    //    kernel_done (the WHOLE dispatch finished), not just this block --
    //    a block with some lanes done early still needs to keep cycling
    //    S_FETCH..S_WRITEBACK for whichever lanes are still working.
    // ------------------------------------------------------------------
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
                    // do some math logic (R-type / I-type arithmetic / lui / auipc / jal / jalr / branches -> S_WRITEBACK)
                    // bc result can be calculated in execute w/o reading/writing data memory
                    7'b0110011, 7'b0010011, 7'b0110111, 7'b0010111, 7'b1101111, 7'b1100111, 7'b1100011:
                        next_state = S_WRITEBACK;
                    // load something out of memory/filing cabinet (memory -> register)
                    // store something in cabinet (register -> memory)
                    // (loads / stores -> S_MEM_ADDR)
                    7'b0000011, 7'b0100011:
                        next_state = S_MEM_ADDR;
                    default: next_state = S_WRITEBACK;
                endcase
            end
            // if loading (0000011) go to S_MEM_WAIT, otherwise store (0100011) 
            S_MEM_ADDR: begin
                next_state = (opcode == 7'b0000011) ? S_MEM_WAIT : S_WRITEBACK;
            end
            S_MEM_WAIT: next_state = S_WRITEBACK;

            S_WRITEBACK:  next_state = S_FETCH;
            default:      next_state = S_FETCH;
        endcase
    end

    // ------------------------------------------------------------------
    // 2. block bookkeeping
    // ------------------------------------------------------------------
    localparam int BLOCK_ID_W = (N_BLOCKS > 1) ? $clog2(N_BLOCKS) : 1;
    logic [BLOCK_ID_W-1:0] block_id;
    logic                  block_done;   // every lane assigned to *this* block has finished
    logic                  last_block;

    assign last_block  = (block_id == N_BLOCKS-1);
    assign kernel_done = block_done && last_block;
    assign thread_base = block_id * LANES;

    // TODO(blocking): done[i] is sticky in cpu.sv and only clears on global
    // rst, so the instant block 0 finishes, block 1 would see every lane
    // already "done" and block_id would race through every remaining block
    // in a few cycles without doing any real work. Needs either (a) a
    // per-block clear pulse added to cpu.sv, or (b) scheduler latching its
    // own block-local done bits off a one-shot "lane just finished" strobe
    // instead of reading cpu.sv's sticky flag directly. Not resolved here --
    // block advance below is structurally right but not functionally correct
    // until this is fixed.
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

    // ------------------------------------------------------------------
    // 3. per-lane pc -- lockstep: every still-running lane advances to the
    //    same next_pc (resolved once, off the leader lane, by pc.sv). A lane
    //    that's already done freezes at its last value instead of following
    //    the rest of the block. A new block starts every lane fresh at 0.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < LANES; i++) pc[i] <= 32'd0;
        end else if (state == S_WRITEBACK && block_done && !last_block) begin
            for (int i = 0; i < LANES; i++) pc[i] <= 32'd0;   // next block re-runs the kernel from the top
        end else if (state == S_WRITEBACK) begin
            for (int i = 0; i < LANES; i++) begin
                if (!done[i]) pc[i] <= next_pc;
            end
        end
    end

endmodule
