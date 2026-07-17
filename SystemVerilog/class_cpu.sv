// cpu.sv -- THIS IS THE FILE YOU EDIT. Implement your CPU here.
// New here? What a CPU is and the rules it must follow: ../../doc/CPU_explained.md
// It runs your program (loaded from INIT_FILE) and reaches the outside world
// ONLY through the byte mailbox below (the rx/tx FIFOs from Part A). Everything
// inside -- memory, registers, datapath, how you decode and execute -- is yours.
//
//   clk      : system clock.
//   rst      : on-board button 0 (active-high). Use it however you like.
//
//   input  side (a byte arrived from the Pi  -> your getchar / scanf):
//     rx_empty : 1 = nothing is waiting
//     rx_data  : the oldest waiting byte (valid while rx_empty is 0)
//     rx_pop   : raise for one clock to consume rx_data
//
//   output side (a byte you send back to the Pi -> your putchar / print):
//     tx_full  : 1 = no room to send right now
//     tx_data  : the byte you want to send
//     tx_push  : raise for one clock to send tx_data
module cpu #(
    parameter int MEM_SIZE_BYTES = 65536,    // byte-addressable memory size (64 KiB)
    // INIT_FILE = the program this CPU runs (the .mem you flash). $readmemb resolves
    // this path against Vivado's RUN directory, not the source tree -- read the synth
    // log to confirm it was picked up; if not, use an absolute path. (A path Vivado
    // can't find loads memory as all-zero, so the CPU just runs nothing.)
    parameter     INIT_FILE      = "mems/test9.mem"
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx_empty,
    input  logic [7:0] rx_data,
    output logic       rx_pop,
    input  logic       tx_full,
    output logic [7:0] tx_data,
    output logic       tx_push
);

    // ------------------------------------------------------------------
    // Important declarations
    // ------------------------------------------------------------------

    // MEM_SIZE_BYTES - total size in bytes
    // /4 convert to words bc each memory location stores 4 bytes (32 bits)
    logic [31:0] mem [0:MEM_SIZE_BYTES/4-1];
    initial $readmemb(INIT_FILE, mem);

    // 32 registers. x0 must always read as 0
    // msut never write regs[0].
    logic [31:0] regs [0:31];

    logic [31:0] pc; // stores address for current instruction
    logic[31:0] next_pc; // stores address that CPU should jump to
                         // after ts finishes

    // ------------------------------------------------------------------
    // FINITE STATE MACHINE
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_FETCH,        // present mem address = pc
        S_FETCH_WAIT,   // instruction byte(s) now valid
                        // give time for instruction to appear in mem_rdata
                        // latch into "instr"
        S_DECODE,       // pull instr apart into opcode/rd/funct3/rs1/rs2/funct7/imm
        S_EXECUTE,      // ALU op / branch condition / jump target / ecall dispatch
        S_MEM_ADDR,     // (loads/stores only) present mem address = ea
        S_MEM_WAIT,     // (loads only) data now valid -> latch it
        S_ECALL_RX,     // getchar: stall here while rx_empty
        S_ECALL_TX,     // putchar: stall here while tx_full
        S_WRITEBACK,    // write rd (if any), compute next pc, loop back to S_FETCH
        S_HALT          // ebreak: sit here forever, pc frozen
    } state_t;

    state_t state, next_state;

    logic [31:0] instr;

    // decoded fields
    logic [6:0] opcode;
    logic [4:0] rd, rs1, rs2;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [31:0] imm;

    assign opcode = instr[6:0];
    assign rd = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];
    assign funct7 = instr[31:25];

    logic [31:0] alu_result;

    // ------------------------------------------------------------------
    // State register
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) state <= S_FETCH;
        else     state <= next_state;
    end

    // ------------------------------------------------------------------
    // Next-state logic
    // ------------------------------------------------------------------

    always_comb begin
        next_state = state;
        case (state)
            S_FETCH:      next_state = S_FETCH_WAIT;
            S_FETCH_WAIT: next_state = S_DECODE;
            S_DECODE:     next_state = S_EXECUTE;

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
                    // grab a letter from inbox, wait until nonempty
                    // drop letter in outbox, if full, wait for space
                    // stop (ecall: getchar, putchar; ebreak)
                    7'b1110011:
                        if (instr[20] == 1) next_state = S_HALT; // based on i-type & ISA_explained, ebreak = 1
                        else if (regs[17] == 32'd1) next_state = S_ECALL_RX; // a7 ==1 told to receive input
                        else next_state = S_ECALL_TX; // transmit FIFO
                    default: ;
                endcase
            end
            // if loading (0000011) go to S_MEM_WAIT, otherwise store (0100011) 
            S_MEM_ADDR: begin
                next_state = (opcode == 7'b0000011) ? S_MEM_WAIT : S_WRITEBACK;
            end
            S_MEM_WAIT: next_state = S_WRITEBACK;

            S_ECALL_RX: begin
                // stay here (next_state = S_ECALL_RX) while rx_empty;
                // once a byte is available, pop it and move on
                next_state = rx_empty ? S_ECALL_RX : S_WRITEBACK;
            end
            S_ECALL_TX: begin
                // stay here (next_state = S_ECALL_TX) while tx_full;
                // once there's room, push and move on.
                next_state = tx_full ? S_ECALL_TX : S_WRITEBACK;
            end

            S_WRITEBACK:  next_state = S_FETCH;
            S_HALT:       next_state = S_HALT;
            default:      next_state = S_FETCH;
        endcase
    end

    // imm logic
    // ISA immediate encoding
    always_comb begin
        case(opcode)
            // i-type, jalr
            7'b0010011, 7'b0000011, 7'b1100111: imm = {{20{instr[31]}}, instr[31:20]};
            // s-type, b-type
            7'b0100011: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            // b-type
            7'b1100011: imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            // u-type: lui, auipc
            7'b0110111, 7'b0010111: imm = {instr[31:12], 12'd0};
            // j-type: jump, jal
            7'b1101111: imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default: imm = 32'd0;
        endcase
    end

    // ------------------------------------------------------------------
    // Memory port
    // Single-port synchronous BRAM: mem_addr muxes between pc (fetch) and ea (data).
    // Reads are registered — address set in S_MEM_ADDR, data captured in S_MEM_WAIT.
    // byte_shift converts ea[1:0] to a bit offset for sub-word load sign/zero-extension
    // and byte-lane store writes. Stores write immediately; loads cost one extra cycle.
    // ------------------------------------------------------------------
    logic [31:0] mem_addr;
    logic [31:0] mem_rdata;   // registered, valid the cycle after mem_addr is set
    logic [31:0] ea;
    logic [31:0] load_result;
    logic [31:0] rs1_val, rs2_val;

    assign mem_addr = (state == S_MEM_ADDR || state == S_MEM_WAIT) ? ea : pc;

    // ea[1:0] gives the byte offset within the 32-bit word (0-3).
    // Multiplying by 8 converts byte offset to bit offset so we can
    // extract the right byte(s) from mem_rdata using +: 8 or +: 16.
    // e.g. byte 2 -> bit 16 -> mem_rdata[16 +: 8] grabs bits [23:16].
    logic [4:0] byte_shift;
    assign byte_shift = {ea[1:0], 3'b000};

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
    always_ff @(posedge clk) begin
        case(state)
            S_EXECUTE:
                case(opcode)
                    // loads (I-type) and stores (S-type)
                    7'b0000011, 7'b0100011: ea <= rs1_val + imm;
                    default: ea <= ea;
                endcase
            S_FETCH, S_FETCH_WAIT, S_DECODE, S_MEM_ADDR, S_MEM_WAIT,
            S_ECALL_RX, S_ECALL_TX, S_WRITEBACK, S_HALT: ea <= ea;
            default: ea <= ea;
        endcase
    end

    always_ff @(posedge clk) begin
        // BRAM read port: mem_addr[31:2] strips the 2 LSBs to convert the byte
        // address to a word index (each word = 4 bytes). For fetch, mem_addr = pc
        // (already word-aligned). For loads/stores, mem_addr = ea and the byte
        // offset (ea[1:0]) is used later to extract/insert the right byte/halfword.
        mem_rdata <= mem[mem_addr[31:2]];

        if (state == S_FETCH_WAIT) instr <= mem_rdata;

    end

    // For stores (sb/sh/sw): we always write to one word in memory (mem[ea[31:2]]).
    // byte_shift selects which byte lane(s) inside that word to overwrite,
    // leaving the other bytes untouched. One word write = one BRAM write port.

    // basically ea is a 32-bit byte address. and want in terms of words so chop last two 
    // bits off bc words r 4 times bigger so divide by 4
    always_ff @(posedge clk) begin
        if (state == S_MEM_ADDR && opcode == 7'b0100011) begin // s-type
            case (funct3)
                // sb - ea[31:2] quotient, byte_shift remainder
                3'b000: mem[ea[31:2]][byte_shift +: 8] <= rs2_val[7:0];
                // sh
                3'b001: mem[ea[31:2]][byte_shift +: 16] <= rs2_val[15:0];
                // sw
                3'b010: mem[ea[31:2]] <= rs2_val;
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Register file
    // Combinational read, synchronous write, x0 hardwired to 0.
    // ------------------------------------------------------------------
    logic [31:0] alu_result_comb;

    assign rs1_val = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
    assign rs2_val = (rs2 == 5'd0) ? 32'd0 : regs[rs2];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 32; i++) regs[i] <= 32'd0;
            pc <= 32'd0;
        end else begin
            // in S_WRITEBACK, if rd != 0 and this instruction
            // writes a register, regs[rd] <= <result>.
            // in S_WRITEBACK, pc <= <next_pc> (pc+4, or a computed
            // branch/jump target).
            case(state)
                S_EXECUTE: begin
                    alu_result <= alu_result_comb;

                    case(opcode)
                        7'b1100011: // B-type (branches)
                            case (funct3)
                                //beq
                                3'b000: next_pc <= (rs1_val == rs2_val) ? pc + imm : pc + 32'd4;
                                //bne
                                3'b001: next_pc <= (rs1_val != rs2_val) ? pc + imm : pc + 32'd4;
                                //blt
                                3'b100: next_pc <= ($signed(rs1_val) < $signed(rs2_val)) ? pc + imm : pc + 32'd4;
                                //bge
                                3'b101: next_pc <= (($signed(rs1_val)) >= $signed(rs2_val)) ? pc + imm : pc + 32'd4;
                                //bltu
                                3'b110: next_pc <= (rs1_val < rs2_val) ? pc + imm : pc + 32'd4;
                                //bgeu
                                3'b111: next_pc <= (rs1_val >= rs2_val) ? pc + imm : pc + 32'd4;
                                default: next_pc <= pc + 32'd4;
                            endcase
                        //jal - jump AND save ra
                        7'b1101111: next_pc <= pc + imm;
                        // jalr - jump back to saved ra
                        7'b1100111: next_pc <= (rs1_val + imm) & ~32'd1;
                        default: next_pc <= pc + 32'd4;
                    endcase
                end
                S_ECALL_RX: begin
                    // getchar: write received byte into a0
                    if (~rx_empty) begin
                        regs[10] <= {24'd0, rx_data};
                    end
                end
                S_WRITEBACK: begin
                    // first register always 0 and B-type [11:7] doesn't store rd but rather imm
                    // same with S-type doesn't store rd
                    if (rd != 5'd0 & opcode != 7'b1100011 & opcode != 7'b0100011) begin
                        if (opcode == 7'b0000011) begin// Load (I-type)
                            regs[rd] <= load_result;
                        end
                        else regs[rd] <= alu_result;
                    end
                    pc <= next_pc;
                end
                S_FETCH, S_FETCH_WAIT, S_DECODE, S_MEM_ADDR, S_MEM_WAIT,
                S_ECALL_TX, S_HALT: ;
                default: ;
            endcase
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



    // ------------------------------------------------------------------
    // ecall / mailbox handshake
    // TODO: drive these from S_ECALL_RX / S_ECALL_TX only -- they must
    // be 0 everywhere else (a stray pulse pops/pushes a byte you didn't
    // mean to touch).
    // ------------------------------------------------------------------
    assign rx_pop  = (state == S_ECALL_RX) & ~rx_empty;
    assign tx_push = (state == S_ECALL_TX) & ~tx_full;
    assign tx_data = regs[10][7:0];

endmodule : cpu
