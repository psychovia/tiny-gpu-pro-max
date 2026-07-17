// cpu.sv

import gpu_pkg::*;

module cpu (
    input logic clk, rst,
    input state_t state,       // shared phase, driven by scheduler.sv
    input logic [4:0] thread_id,
    input logic [6:0] opcode,
    input logic [4:0] rd, rs1, rs2,
    input logic [2:0] funct3,
    input logic [6:0] funct7,
    input logic [31:0] imm,
    input logic [31:0] pc,
    input  logic [31:0] mem_rdata,  // registered, valid the cycle after mem_addr is set
    output logic [31:0] mem_addr,
    output logic [31:0] rs1_val, rs2_val, 
    output logic mem_read,
    output logic mem_write,
    output logic [31:0] mem_wdata,
    output logic [3:0]  byte_en,  // ASSUMPTION: one-hot-per-byte write mask
    // signals this thread is done. Convention: a program marks a
    // thread complete by writing 1 to x31 via an ALU op, e.g. `addi x31,
    // x0, 1`. Sticky -- once set, stays set until reset, regardless of
    // what happens to x31 afterward.
    output logic done
);

    // ------------------------------------------------------------------
    // Important declarations
    // ------------------------------------------------------------------

    // 32 registers. x0 must always read as 0
    // msut never write regs[0].
    logic [31:0] regs [0:31];

    logic [31:0] alu_result;



    // ------------------------------------------------------------------
    // Memory port
    // ------------------------------------------------------------------
    logic [31:0] ea; // actual memory address computer from instruction
    logic [31:0] load_result;

    assign mem_addr = (state == S_MEM_ADDR || state == S_MEM_WAIT) ? ea : pc;

    // ea[1:0] gives the byte offset within the 32-bit word (0-3).
    // Multiplying by 8 converts byte offset to bit offset so we can
    // extract the right byte(s) from mem_rdata using +: 8 or +: 16.
    // e.g. byte 2 -> bit 16 -> mem_rdata[16 +: 8] grabs bits [23:16].
    //Memory is organized in 32-bit (4-byte) words, but instructions like lb (load byte) only want one byte out of that word. The bottom 2 bits of the address (ea[1:0]) tell you which byte (0, 1, 2, or 3) within the word you want
    logic [4:0] byte_shift;
    assign byte_shift = {ea[1:0], 3'b000};

    // loading out of the memory
    always_ff @(posedge clk) begin
        if (state == S_MEM_WAIT) begin
            case(funct3)
                3'b000: load_result <= {{24{mem_rdata[byte_shift+7]}}, mem_rdata[byte_shift +: 8]}; //lb sign extended
                3'b001: load_result <= {{16{mem_rdata[byte_shift+15]}}, mem_rdata[byte_shift +: 16]}; //lh sign extended
                3'b010: load_result <= mem_rdata; //lw
                3'b100: load_result <= {24'd0, mem_rdata[byte_shift +: 8]}; //lbu zero-extended
                3'b101: load_result <= {16'd0, mem_rdata[byte_shift +: 16]};//lhu zero extended
                default: load_result <= 32'd0;
            endcase
        end
    end

    // which address to take from in memory
    always_ff @(posedge clk) begin
        case(state)
            S_EXECUTE:
                case(opcode)
                    // loads (I-type) and stores (S-type)
                    7'b0000011, 7'b0100011: ea <= rs1_val + imm;
                    default: ea <= ea;
                endcase
            default: ea <= ea;
        endcase
    end


    assign mem_write = (state == S_MEM_ADDR & opcode == 7'b0100011); // s-type
    assign mem_read = (state == S_FETCH) | (state == S_FETCH_WAIT) |
                       (state == S_EXECUTE) | (state == S_WRITEBACK) |
                       ((state == S_MEM_ADDR | state == S_MEM_WAIT) & opcode == 7'b0000011);

    // byte enable to flag which bytes we are writing over
    logic [3:0] byte_en_comb;
    always_comb begin
        case (funct3)
            3'b000:  byte_en_comb = 4'b0001 << ea[1:0]; // sb
            3'b001:  byte_en_comb = 4'b0011 << ea[1:0]; // sh
            3'b010:  byte_en_comb = 4'b1111;            // sw
            default: byte_en_comb = 4'b0000;
        endcase
    end
    assign byte_en = byte_en_comb;

    // mem_wdata: rs2_val shifted into the same byte position byte_en marks
    // as active, so memory.sv can latch the whole word and let byte_en
    // decide what actually gets written.
    logic [31:0] mem_wdata_comb;
    always_comb begin
        case (funct3)
            3'b000:  mem_wdata_comb = {24'd0, rs2_val[7:0]}  << byte_shift; // sb
            3'b001:  mem_wdata_comb = {16'd0, rs2_val[15:0]} << byte_shift; // sh
            3'b010:  mem_wdata_comb = rs2_val;                              // sw
            default: mem_wdata_comb = 32'd0;
        endcase
    end
    assign mem_wdata = mem_wdata_comb;

    // ------------------------------------------------------------------
    // Register file
    // Combinational read, synchronous write, x0 hardwired to 0.
    // ------------------------------------------------------------------
    logic [31:0] alu_result_comb;
    logic is_S_EXECUTE, is_S_WRITEBACK, is_LOAD_RESULT, is_ALU_RESULT;

    assign rs1_val = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
    assign rs2_val = (rs2 == 5'd0) ? 32'd0 : regs[rs2];
    assign is_S_EXECUTE = (state == S_EXECUTE);
    assign is_S_WRITEBACK = (state == S_WRITEBACK);
    assign is_LOAD_RESULT = (state == S_WRITEBACK & rd != 5'd0 & opcode != 7'b1100011 & opcode != 7'b0100011 & opcode == 7'b0000011);
    assign is_ALU_RESULT = (state == S_WRITEBACK & rd != 5'd0 & opcode != 7'b1100011 & opcode != 7'b0100011);

    always_ff @(posedge clk) begin
        if (is_S_EXECUTE) begin
            alu_result <= alu_result_comb;
        end
        else begin
            alu_result <= 32'd0;
        end
    end

    // reset registers
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 32; i++) regs[i] <= 32'd0;
        end
    end

    // what to put back into register
    always_ff @(posedge clk) begin
        if (is_LOAD_RESULT) begin
            regs[rd] <= load_result;
        end
        else if (is_ALU_RESULT) begin
            regs[rd] <= alu_result;
        end
    end

    // done -- sticky, set once this lane writes 1 to x31 via an ALU
    // op, never cleared except on reset.
    always_ff @(posedge clk) begin
        if (rst) begin
            done <= 1'b0;
        end
        else if (is_ALU_RESULT && rd == 5'd31 && alu_result == 32'd1) begin
            done <= 1'b1;
        end
    end


    // combinational ALU
    always_comb begin
        case (opcode)
            // normal operations
            7'b0110011: 
                case(funct3)
                    3'b000: 
                        case(funct7)
                            7'd0: alu_result_comb = rs1_val + rs2_val;
                            7'b0100000: alu_result_comb = rs1_val - rs2_val;
                            7'b0000001: alu_result_comb = rs1_val * rs2_val; //mul
                            default: alu_result_comb = 32'd0;
                        endcase
                    3'b001: alu_result_comb = rs1_val << (rs2_val[4:0]);
                    3'b010: alu_result_comb = ($signed(rs1_val) < $signed(rs2_val)) ? 1: 0;
                    3'b011: alu_result_comb = (rs1_val < rs2_val) ? 1 : 0;
                    3'b100: alu_result_comb = rs1_val ^ rs2_val;
                    3'b101: 
                        case(funct7)
                            7'b0000000: alu_result_comb = rs1_val >> (rs2_val[4:0]);
                            7'b0100000: alu_result_comb = $signed(rs1_val) >>> (rs2_val[4:0]);
                            default: alu_result_comb = 32'd0;
                        endcase
                    3'b110: alu_result_comb = rs1_val | rs2_val;
                    3'b111: alu_result_comb = rs1_val & rs2_val;
                    default: alu_result_comb = 32'd0;
                endcase
            // i-type, shift-immediate
            7'b0010011:
                case(funct3)
                    3'b000: alu_result_comb = rs1_val + imm;
                    3'b010: alu_result_comb = ($signed(rs1_val) < $signed(imm)) ? 32'd1 : 32'd0;
                    3'b011: alu_result_comb = (rs1_val < imm) ? 32'd1 : 32'd0;
                    3'b100: alu_result_comb = rs1_val ^ imm;
                    3'b110: alu_result_comb = rs1_val | imm;
                    3'b111: alu_result_comb = rs1_val & imm;
                    3'b001: alu_result_comb = rs1_val << imm[4:0];
                    3'b101: 
                        case(funct7)
                            7'd0: alu_result_comb = rs1_val >> imm[4:0];
                            7'b0100000: alu_result_comb = $signed(rs1_val) >>> imm[4:0];
                            default: alu_result_comb = 32'd0;
                        endcase
                    default: alu_result_comb = 32'd0;
                endcase
            // lui , auipic u-type
            7'b0110111: alu_result_comb = imm;
            7'b0010111: alu_result_comb = pc + imm; 
            // jal/jalr
            7'b1101111: alu_result_comb = pc + 32'd4;
            7'b1100111: alu_result_comb = pc + 32'd4;
            default: alu_result_comb = 32'd0;
        endcase
    end

endmodule : cpu
