/** 
program counter
**/

import gpu_pkg::*;

module pc (
    input state_t state,
    input logic rst, clk,
    input logic [6:0] opcode,
    input logic [2:0] funct3, 
    input logic [31:0] rs1_val, rs2_val,
    input logic [31:0] imm,
    output logic [31:0] pc
);
    logic [31:0] next_pc, next_pc_comb;
    logic is_S_WRITEBACK, is_S_EXECUTE;

    assign is_S_WRITEBACK = (state == S_WRITEBACK);
    assign is_S_EXECUTE = (state == S_EXECUTE);

    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= 32'd0;
        end 
        else if (is_S_WRITEBACK) begin
            pc <= next_pc;
        end
    end

     // next_pc_comb: pure function of pc/opcode/rs1_val/rs2_val/imm, no
    // dependence on state -- it's a live calculation, always showing the
    // answer for whatever instruction is currently decoded.

    always_comb begin
        case(opcode)
            7'b1100011: // B-type (branches)
                case (funct3)
                    //beq
                    3'b000: next_pc_comb = (rs1_val == rs2_val) ? pc + imm : pc + 32'd4;
                    //bne
                    3'b001: next_pc_comb = (rs1_val != rs2_val) ? pc + imm : pc + 32'd4;
                    //blt
                    3'b100: next_pc_comb = ($signed(rs1_val) < $signed(rs2_val)) ? pc + imm : pc + 32'd4;
                    //bge
                    3'b101: next_pc_comb = (($signed(rs1_val)) >= $signed(rs2_val)) ? pc + imm : pc + 32'd4;
                    //bltu
                    3'b110: next_pc_comb = (rs1_val < rs2_val) ? pc + imm : pc + 32'd4;
                    //bgeu
                    3'b111: next_pc_comb = (rs1_val >= rs2_val) ? pc + imm : pc + 32'd4;
                    default: next_pc_comb = pc + 32'd4;
                endcase
            //jal - jump AND save ra
            7'b1101111: next_pc_comb = pc + imm;
            // jalr - jump back to saved ra
            7'b1100111: next_pc_comb = (rs1_val + imm) & ~32'd1;
            default: next_pc_comb = pc + 32'd4;
        endcase
    end

    // in S_WRITEBACK, if rd != 0 and this instruction
    // writes a register, regs[rd] <= <result>.
    // in S_WRITEBACK, pc <= <next_pc> (pc+4, or a computed
    // branch/jump target).
    // next_pc is recorded here during S_EXECUTE (like alu_result) so the
    // decision survives until S_WRITEBACK actually applies it to pc.
    always_ff @(posedge clk) begin
        if (is_S_EXECUTE) begin
            next_pc <= next_pc_comb;
        end
    end

endmodule