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
    // funct3 too, because the three data-buffer instructions share one opcode:
    // getdt/setdt need the S_MEM_ADDR phase, rdtid does not.
    input  logic [2:0] funct3,

    // from/to cpu
    input  logic        done [0:LANES-1],      // sticky - stays same until rst
    input  logic        mem_valid [0:LANES-1], // per-lane "your request from shared_mem landed this cycle" -- drives stall
    input  logic        dt_valid  [0:LANES-1], // the same, from data_buffer.sv

    output logic [LANES-1:0] active_mask, // enable signal for each cpu lane -- see NOTE below
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
    //
    // "Serviced" means shared_mem OR data_buffer answered, whichever this
    // instruction was asking. ORing them is safe rather than ambiguous: every
    // lane runs the same instruction (SIMT lockstep, one shared FSM), so only
    // one of the two can have anything in flight at a time -- a load never
    // makes dt_valid fire, a getdt never makes mem_valid fire.
    logic serviced [0:LANES-1];
    always_ff @(posedge clk) begin
        if (rst || !stall) begin
            for (int i = 0; i < LANES; i++) serviced[i] <= 1'b0;
        end else begin
            for (int i = 0; i < LANES; i++)
                if (mem_valid[i] | dt_valid[i]) serviced[i] <= 1'b1;
        end
    end

    logic stall_comb;
    always_comb begin
        stall_comb = 1'b0;
        for (int i = 0; i < LANES; i++)
            stall_comb = stall_comb | (require_mask[i] & ~serviced[i]);
    end
    assign stall = stall_comb;

    // Declared up here, not next to the always_comb below that drives it:
    // the state register reads next_state, and SystemVerilog requires a
    // declaration to precede first use. Vivado synthesis only warned about
    // this (Synth 8-6901) so the bitstream built fine, but xvlog rejects it
    // outright (VRFC 10-3380), which stopped the testbench compiling.
    state_t next_state;

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

    // EXECUTE - leader lane (lane 0) evaluates branch, pc.sv records next_pc
    // WRITEBACK - pc.sv applies next_pc; every lane just followed along
    // FETCH - fetch instr at the newly selected pc
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
                    // getdt/setdt reach the data buffer, so they take the same
                    // detour as a load/store. rdtid reads no memory at all --
                    // cpu.sv computes it in the ALU -- so it goes straight to
                    // writeback like any other arithmetic instruction.
                    OPC_GPU:
                        next_state = (funct3 == F3_RDTID) ? S_WRITEBACK : S_MEM_ADDR;
                    default: next_state = S_WRITEBACK;
                endcase
            end
            S_MEM_ADDR: begin
                // Only reads need the extra cycle for their data to come back;
                // a store/setdt has already committed by the end of this state.
                next_state = (opcode == 7'b0000011
                              || (opcode == OPC_GPU && funct3 == F3_GETDT))
                             ? S_MEM_WAIT : S_WRITEBACK;
            end
            S_MEM_WAIT: next_state = S_WRITEBACK;

            S_WRITEBACK:  next_state = S_FETCH;
            default:      next_state = S_FETCH;
        endcase
    end



    // ------------------------------------------------------------------
    // 2. active_mask -- core.sv runs a single leader-lane pc.sv shared by
    //    every lane (SIMD lockstep, see core.sv's note), so there's no
    //    per-thread divergence support today: every lane is active for
    //    the whole run. This used to carry real per-lane branch-divergence
    //    bookkeeping (primary/branch pc splitting, a saved deferred path),
    //    but that logic depended on a per-lane `next_pc` array that
    //    nothing in core.sv ever produced (only lane 0 resolves branches)
    //    -- it was dead code sitting on a floating port. Revive it here
    //    (and give pc.sv one instance per lane) if divergent control flow
    //    is ever actually implemented.
    // ------------------------------------------------------------------
    assign active_mask = '1;

endmodule
