/**
scheduler
- manages execution of threads (won't pick up another block before completion)
- each cpu has it's own register, need to write scheduler that writes the values of the register for cpu

    array indexed by tid
    element = pc of corresponding thread

    detect different pcs among threads
        - if different - pick an arbitrary pc to work on, stall the rest, continue when done


=======
    block
=======
    lane     = physical instances of units - number of workers
    threads  = total amount of computation - total amount of work
    block    = "shift"

    hierarchy: kernal - block - thread

    NOTE: block-based dispatch (cycling through gpu_pkg::NUM_BLOCKS batches
    of LANES threads each, tracked via block_id/thread_base) has been
    pulled out of this file -- we don't want block logic right now. This
    scheduler currently only ever runs ONE batch of LANES threads:
    kernel_done fires as soon as those LANES lanes are done, regardless of
    TOTAL_THREADS/gpu_pkg::NUM_BLOCKS. The removed bookkeeping is archived
    as-is in block_logic.sv for future reference if multi-block dispatch
    comes back.

**/

// moving state/next_state logic here because we don't want 32 independent copies of "what phase am I in," each free to disagree with others which would break SIMD


import gpu_pkg::*;

module scheduler #(
    parameter int LANES = gpu_pkg::N_LANES // physical cpu lanes = threads per block
) (
    input  logic clk, rst,

    // from fetcher
    input  logic [6:0] opcode,

    // from pc.sv
    input  logic [31:0] next_pc [0:LANES-1], // 1 candidate pc fromeach lane

    // from/to cpu
    input  logic        done [0:LANES-1],      // sticky - stays same until rst
    input  logic        mem_valid [0:LANES-1], // per-lane "your request from shared_mem landed this cycle" -- drives stall
    output logic [31:0] current_pc,

    output logic [LANES-1:0] active_mask, // TODO: pass in active_mask[i] as an anable signal for ith cpu
    output logic             stall,

    // to fetcher
    output state_t state,

    // to core
    output logic kernel_done // when every lane is done
);

    // ------------------------------------------------------------------
    // 1. shared FSM -- same states/transitions as before.
    // ------------------------------------------------------------------

    // kernel_done: every one of the LANES lanes has signaled done. This is
    // the only "done" concept left now that block dispatch is gone -- see
    // the NOTE at the top of this file / block_logic.sv.
    logic kernel_done_comb;
    always_comb begin
        kernel_done_comb = 1'b1;
        for (int i = 0; i < LANES; i++) begin
            kernel_done_comb = kernel_done_comb & done[i];
        end
    end
    assign kernel_done = kernel_done_comb;

    // ------------------------------------------------------------------
    // stall: freezes `state` while a memory-dependent phase is still
    // waiting on lanes it needs data/writes from. Only S_FETCH_WAIT (needs
    // the fetched instruction) and S_MEM_ADDR (load address must be
    // accepted / store write must land) actually gate progress -- cpu.sv
    // also asserts mem_read during S_EXECUTE/S_WRITEBACK, but nothing
    // there depends on that data, so we deliberately don't block on it.
    //
    // require_mask says *which* lanes must be serviced before this state
    // is allowed to end: only lane 0 for fetch (fetcher.sv only ever reads
    // mem_rdata[0], since every lane presents the identical shared pc this
    // cycle, so lane 0's copy speaks for all of them), and every lane for
    // S_MEM_ADDR (each lane's load/store targets its own distinct address,
    // so each one genuinely needs its own grant).
    // ------------------------------------------------------------------
    logic require_mask [0:LANES-1];
    always_comb begin
        for (int i = 0; i < LANES; i++) require_mask[i] = 1'b0;
        case (state)
            S_FETCH_WAIT: require_mask[0] = 1'b1;
            S_MEM_ADDR:   for (int i = 0; i < LANES; i++) require_mask[i] = 1'b1;
            default: ; // this state doesn't need anyone serviced before it ends
        endcase
    end

    // serviced accumulates mem_valid pulses across the stall and resets the
    // moment stall goes low, so a state that never actually stalls (an
    // all-0 require_mask) always starts the next state with a clean slate.
    logic serviced [0:LANES-1];
    always_ff @(posedge clk) begin
        if (rst || !stall) begin
            for (int i = 0; i < LANES; i++) serviced[i] <= 1'b0;
        end else begin
            for (int i = 0; i < LANES; i++)
                if (mem_valid[i]) serviced[i] <= 1'b1;
        end
    end

    logic stall_comb;
    always_comb begin
        stall_comb = 1'b0;
        for (int i = 0; i < LANES; i++)
            stall_comb = stall_comb | (require_mask[i] & ~serviced[i]);
    end
    assign stall = stall_comb;

    // state register
    // freezes once kernel_done (every lane finished) or while stalled.
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH;
        end else if (kernel_done) begin
            // frozen -- nothing left to run
        end else if (stall) begin
            // frozen -- still waiting for shared_mem to service every lane
            // this state's require_mask depends on
        end else begin
            state <= next_state;
        end
    end

    // next state logic

    // EXECUTE - each lane evaluates branch and records next_pc[i]
    // WRITEBACK - scheduler compare next_pc[i], selects pc and mask for next fetch
    // FETCH - fetch instr at newly selected pc
    state_t next_state;
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
    // 2. per-lane pc -- lockstep: every still-running lane advances to the
    //    same next_pc (resolved once, off the leader lane, by pc.sv). A lane
    //    that's already done freezes at its last value instead of following
    //    the rest of the pack.
    // ------------------------------------------------------------------

    // for branch divergence
    // assume only 2 branches: primary / branch
    // if more branches exist then do a stack_ptr logic

    logic [31:0] primary_pc;
    logic [31:0] branch_pc;

    logic [LANES-1:0] primary_mask;
    logic [LANES-1:0] branch_mask;

    logic primary_valid;
    logic branch_valid;
    logic divergence_detected;

    logic [31:0] saved_pc;
    logic [LANES-1:0] saved_mask;
    logic saved_path_valid;

    logic all_active_done; // all lanes under active_mask done / current branch done
    // todo: what if a branch diverge again


    always_comb begin
        primary_pc = '0;
        branch_pc  = '0;

        primary_mask = '0;
        branch_mask  = '0;

        primary_valid = 1'b0;
        branch_valid  = 1'b0;

        all_active_done = 1'b1;

        for (int i = 0; i < LANES; i++) begin
            if (active_mask[i] & !done[i]) begin
                all_active_done = 1'b0;

                if (!primary_valid) begin
                    // if primary_pc not set then set it as the first pc seen
                    primary_pc = next_pc[i];
                    primary_mask[i] = 1'b1;
                    primary_valid = 1'b1;
                end
                else if (primary_pc == next_pc[i]) begin
                    primary_mask[i] = 1'b1; // flip corresponding bit on mask
                end
                else if (!branch_valid) begin
                    // a different pc than primary_pc first seen, set as branch
                    branch_pc = next_pc[i];
                    branch_mask[i] = 1'b1;
                    branch_valid = 1'b1;
                end
                else if (branch_pc == next_pc[i]) begin
                    branch_mask[i] = 1'b1;
                end
            end
        end

        divergence_detected = primary_valid & branch_valid;
    end

    // current pc
    // active mask
    // saved pc / mask / valid
    always_ff @(posedge clk) begin
        if (rst) begin
            current_pc <= '0;
            active_mask <= '0; // todo: double check - add a condition of if #threads > #lanes?

            saved_pc <= '0;
            saved_mask <= '0;
            saved_path_valid <= 1'b0;
        end
        else if (state == S_WRITEBACK) begin
            if (all_active_done) begin
                if (saved_path_valid) begin
                    // current path finished - run deferred path
                    current_pc <= saved_pc;
                    active_mask <= saved_mask;
                    saved_path_valid <= 1'b0;
                end
                else begin
                    active_mask <= '0;
                end
            end

            else if (divergence_detected) begin
                current_pc <= primary_pc;
                active_mask <= primary_mask;

                // save branch pc and mask to be executed later
                saved_pc <= branch_pc;
                saved_mask <= branch_mask;
                saved_path_valid <= 1'b1;

            end
            else if (primary_valid) begin // normal execution
                current_pc <= primary_pc;
                active_mask <= primary_mask;
            end
        end
    end

endmodule
