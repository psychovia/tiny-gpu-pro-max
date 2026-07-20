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
    input  logic [31:0] next_pc [0:LANES-1], // 1 candidate pc fromeach lane
    
    // from/to cpu
    input  logic        done [0:LANES-1], // sticky - stays same until rst
    output logic [31:0] current_pc, 
    output logic [31:0] thread_base, // lane i's thread_id = thread_base + i
    // TODO: clarify lane / thread id?

    output logic [LANES-1:0] active_mask; // TODO: pass in active_mask[i] as an anable signal for ith cpu
    
    // to fetcher
    output state_t state,

    // to core
    output logic kernel_done // when every block is done
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

    // EXECUTE - each lane evaluates branch and records next_pc[i]
    // WRITEBACK - scheduler compare next_pc[i], selects pc and mask for next fetch
    // FETCH - fetch instr at newly selected pc
    always_comb begin
        next_state = state;
        case (state)
            S_FETCH:      next_state = S_FETCH_WAIT;
            S_FETCH_WAIT: next_state = S_EXECUTE; // instr valid now; decode is combinational off it
            S_EXECUTE: begin
                // branch on opcode
                case (opcode)
                    // R-type / I-type arithmetic / lui / auipc / jump/ branches -> S_WRITEBACK)
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

    // ------------------------------------------------------------------
    // 2. block bookkeeping
    // ------------------------------------------------------------------
    localparam int BLOCK_ID_W = (N_BLOCKS > 1) ? $clog2(N_BLOCKS) : 1;
    logic [BLOCK_ID_W-1:0] block_id;
    logic                  block_done;  // every lane in this block has finished
    logic                  last_block;

    assign last_block  = (block_id == N_BLOCKS-1);
    assign kernel_done = block_done && last_block;
    assign thread_base = block_id * LANES;

    always_comb begin
        block_done = 1'b1;
        for (int i = 0; i < LANES; i++) block_done &= done[i]; // block done when every lane is done
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            block_id <= '0;
        end else if (state == S_WRITEBACK && block_done && !last_block) begin
            block_id <= block_id + 1'b1;
            for (int 1 = 0; i < LANES; i++) done[i] <= 1'b0; // todo: check if it's valid for resetting done
        end
    end

    // ------------------------------------------------------------------
    // 3. per-lane pc -- lockstep: every still-running lane advances to the
    //    same next_pc (resolved once, off the leader lane, by pc.sv). A lane
    //    that's already done freezes at its last value instead of following
    //    the rest of the block. A new block starts every lane fresh at 0.
    // ------------------------------------------------------------------

    // for branch divergence
    // assume only 2 branches: primary / branch
    // if more branches exist then do a stack_ptr logic

    logic [31:0] primary_pc,
    logic [31:0] branch_pc,

    logic [LANES-1:0] primary_mask,
    logic [LANES-1:0] branch_mask,

    logic primary_valid,
    logic branch_valid,
    logic divergence_detected;

    always_comb begin
        primary_pc <= '0;
        branch_pc  <= '0;

        primary_mask <= '0;
        branch_mask  <= '0;

        primary_valid <= 0;
        branch_valid  <= 0;

        for (int i = 0; i < LANES; i++) begin
            if (active_mask[i] & !done[i]) begin
                if (!primary_valid) begin 
                    // if primary_pc not set then set it as the first pc seen
                    primary_pc <= next_pc[i];
                    primary_mask[i] <= 1'b1;
                    primary_valid <= 1'b1;
                end
                else if (primary_pc == next_pc[i]) begin
                    primary_mask[i] <= 1'b1; // flip corresponding bit on mask
                end
                else if (!branch_valid & !done[i]) begin
                    // a different pc than primary_pc first seen, set as branch
                    branch_pc <= next_pc[i];
                    branch_mask[i] <= 1'b1;
                    branch_valid <= 1'b1;
                end
                else if (branch_pc == next_pc[i]) begin
                    branch_mask[i] <= 1'b1;
                end
            end
        end  
        divergence_detected = primary_valid & branch_valid;
    
    end

    logic [31:0] saved_pc;
    logic [LANES-1:0] saved_mask;

    always_ff @(posedge clk) begin
        if (rst) begin
            current_pc <= '0;
            active_mask <= '1
        end 
        else if (state == S_WRITEBACK && block_done && !last_block) begin
            current_pc <= '0; // next block re-runs the kernel from the top
            active_mask <= '1;
        end 
        else if (state == S_WRITEBACK) begin
            if (divergent_detected) begin
                current_pc <= primary_pc;
                active_mask <= primary_mask;

                // save branch pc and mask to be executed later
                saved_pc <= branch_pc;
                saved_mask <= branch_mask;

                // todo: 2 possibilities:
                // (1) active lanes reached the end of the kernel
                // (2) active lanes reached the point where the two branch paths rejoin - need to know addr of reconvergence
            
            end
            else if (primary_valid) begin
                current_pc <= primary_pc;
                active_mask <= primary_mask;
            end
        end
    end

endmodule
