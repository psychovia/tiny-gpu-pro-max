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
    output logic [4:0] thread_id,
    output state_t state,          // exposed so core.sv can hand the shared phase to fetcher/cpu/pc
    input  logic done [0:31],
    output logic kernel_done
    input logic [31:0] pc, 
    output logic stall
);

    state_t next_state;

    // kernel_done true if all lanes are done
    logic kernel_done_comb;
    always_comb begin
        kernel_done_comb = 1'b1;
        for (int i = 0; i < 32; i++) begin
            kernel_done_comb = kernel_done_comb & done[i];
        end
    end
    assign kernel_done = kernel_done_comb;

    // state register
    // freezes once kernel_done; stop advancing/fetching once the
    // whole kernel has finished, instead of looping past the end forever.
    always_ff @(posedge clk) begin
        if (rst) state <= S_FETCH;
        else if (~kernel_done) state <= next_state;
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
