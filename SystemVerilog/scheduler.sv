/**
scheduler
- manages execution of threads (won't pick up another block before completion)
- each cpu has it's own register, need to write scheduler that writes the values of the register for cpu

    array indexed by tid
    element = pc of corresponding thread

    detect different pcs among threads
        - if different - pick an arbitrary pc to work on, stall the rest, continue when done

**/

// moving state/next_state logic here because we don't want 32 independent copies of "what phase am I in," each free to disagree with others which would break SIMD


import gpu_pkg::*;

module scheduler(
    input clk, rst,
    input logic [6:0] opcode,
    input logic done [0:31],
    input logic [31:0] pc,
    output state_t state,          // exposed so core.sv can hand the shared phase to fetcher/cpu/pc
    output logic block_done,
    output logic kernel_done,
    output logic [gpu_pkg::BLOCK_ID_WIDTH-1:0] block_id,
    output logic block_start,
    output logic stall
);

    state_t next_state;

    // block_done true if all lanes in the *current* block are done
    logic block_done_comb;
    always_comb begin
        block_done_comb = 1'b1;
        for (int i = 0; i < 32; i++) begin
            block_done_comb = block_done_comb & done[i];
        end
    end
    assign block_done = block_done_comb;

    // block_id: which of the NUM_BLOCKS sequential blocks is currently
    // assigned to this core. Advances by one each time block_done fires,
    // until every block has been dispatched.
    logic [gpu_pkg::BLOCK_ID_WIDTH-1:0] block_id_reg;
    assign block_id = block_id_reg;

    // kernel_done: the last block (block_id == NUM_BLOCKS-1) has finished --
    // the whole image is done, not just the current block.
    assign kernel_done = block_done & (block_id_reg == gpu_pkg::NUM_BLOCKS - 1);

    // block_start: pulses the cycle a non-final block finishes, telling
    // cpu.sv/pc.sv to reset their per-block state (regs/done/pc) for the
    // next block the same way rst does -- without touching block_id.
    assign block_start = block_done & ~kernel_done;

    // state register
    // freezes once kernel_done (whole kernel finished). On block_done that
    // isn't the last block, restart at S_FETCH for the next block instead of
    // advancing next_state, and bump block_id.
    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= S_FETCH;
            block_id_reg <= '0;
        end else if (kernel_done) begin
            // frozen -- nothing left to dispatch
        end else if (block_done) begin
            state        <= S_FETCH;
            block_id_reg <= block_id_reg + 1'b1;
        end else begin
            state <= next_state;
        end
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

endmodule
