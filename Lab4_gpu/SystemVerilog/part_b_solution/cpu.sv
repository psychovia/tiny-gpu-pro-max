// cpu.sv -- THIS IS THE FILE YOU EDIT. Implement your CPU here.
// New here? What a CPU is and the rules it must follow: ../../doc/CPU_explained.md
// It runs your program (loaded from INIT_FILE) and reaches the outside world
// ONLY through the byte mailbox below (the rx/tx FIFOs from Part A). Everything
// inside -- memory, registers, datapath, how you decode and execute -- is yours.
//
//   clk      : system clock.
//   rst      : on-board button 0 (active-high). Restart the program.
//
//   input  side (a byte arrived from the Pi):
//     rx_empty : 1 = nothing is waiting
//     rx_data  : the oldest waiting byte (valid while rx_empty is 0)
//     rx_pop   : raise for one clock to consume rx_data
//
//   output side (a byte you send back to the Pi):
//     tx_full  : 1 = no room to send right now
//     tx_data  : the byte you want to send
//     tx_push  : raise for one clock to send tx_data
//
// GPU variant (see ../../doc/GPU_explained.md). This CPU is one THREAD; the
// board instantiates many of them, each with a different `tid`:
//   tid       : this thread's id (a constant input, unique per instance).
//               `rdtid rd`  copies it into rd.  C: int x = tid;
//   shared data memory (all threads share ONE; a display can scan it out):
//     dt_we/dt_addr/dt_wdata : `setdt rs1,rs2` writes data[rs1]=rs2 (one pulse,
//                              never blocks).  C: setdata(i, v);
//     dt_raddr/dt_rdata      : `getdt rd,rs1` reads rd=data[rs1].  C: getdata(i);

// RV32I opcodes (instr[6:0]).
`define OPCODE_OP      7'b0110011
`define OPCODE_OP_IMM  7'b0010011
`define OPCODE_LOAD    7'b0000011
`define OPCODE_STORE   7'b0100011
`define OPCODE_BRANCH  7'b1100011
`define OPCODE_LUI     7'b0110111
`define OPCODE_AUIPC   7'b0010111
`define OPCODE_JAL     7'b1101111
`define OPCODE_JALR    7'b1100111
`define OPCODE_SYSTEM  7'b1110011
`define OPCODE_CUSTOM  7'b0001011   // GPU: rdtid (f3=000), setdt (f3=001), getdt (f3=010)

module cpu #(
    parameter int MEM_SIZE_BYTES = 262144,   // 256 KiB (64 of 75 BRAM tiles)
    parameter int DATA_AW        = 10,        // shared data memory: 2**10 = 1024 cells (32x32)
    parameter     INIT_FILE      = "mems/test9.mem" // Read vivado's messages to see if this got picked up. If not, use an absolute path
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx_empty,
    input  logic [7:0] rx_data,
    output logic       rx_pop,
    input  logic       tx_full,
    output logic [7:0] tx_data,
    output logic       tx_push,
    // ---- GPU variant: thread id in, shared data memory out ----
    input  logic [31:0]        tid,       // this thread's id (constant per instance)
    output logic               dt_we,     // setdt write strobe (one clock)
    output logic [DATA_AW-1:0] dt_addr,   // setdt index = registers[rs1]
    output logic [7:0]         dt_wdata,  // setdt value = registers[rs2]
    output logic [DATA_AW-1:0] dt_raddr,  // getdt index = registers[rs1]
    input  logic [7:0]         dt_rdata   // getdt value (combinational read)
);

    localparam int AW = $clog2(MEM_SIZE_BYTES); // GIVE THESE THREE LINES TO STUDENTS?
    logic [31:0] memory [MEM_SIZE_BYTES/4];
    initial $readmemb(INIT_FILE, memory);

    logic [31:0][31:0] registers;
    logic [31:0]       pc;
    logic [31:0]       instr;            // memory read reg: the instruction in EXECUTE, load data in MEM

    logic [6:0]  opcode;
    logic [4:0]  rd;
    logic [2:0]  funct3;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [6:0]  funct7;
    logic [31:0] imm_i;
    logic [31:0] imm_s;
    logic [31:0] imm_b;
    logic [31:0] imm_j;
    logic [31:0] ea_l;                   // load  address = rs1 + imm_i
    logic [31:0] ea_s;                   // store address = rs1 + imm_s
    logic [3:0]  st_be;                  // store byte-enables
    logic [31:0] st_data;                // store data, shifted into its word lane
    logic [4:0]  ld_rd;                  // load: dest reg / funct3 / byte-offset, latched for the MEM stage
    logic [2:0]  ld_funct3;
    logic [1:0]  ld_lo;

    enum logic [1:0] { FETCH, EXECUTE, MEM } state = FETCH;

    // ALU: funct3 picks the op; alt (instr[30]) = sub / arithmetic-shift.
    function automatic logic [31:0] alu(input logic [31:0] a, b, input logic [2:0] f3, input logic alt);
        case(f3)
            3'b000: alu = alt ? (a - b) : (a + b);                       // add / sub
            3'b001: alu = a << b[4:0];                                   // sll
            3'b010: alu = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;     // slt
            3'b011: alu = (a < b) ? 32'd1 : 32'd0;                       // sltu
            3'b100: alu = a ^ b;                                         // xor
            3'b101: alu = alt ? $unsigned($signed(a) >>> b[4:0]) : (a >> b[4:0]); // sra / srl
            3'b110: alu = a | b;                                         // or
            3'b111: alu = a & b;                                         // and
        endcase
    endfunction

    // Branch taken? funct3 picks the test.
    function automatic logic br_taken(input logic [31:0] a, b, input logic [2:0] f3);
        case(f3)
            3'b000:  br_taken = (a == b);                   // beq
            3'b001:  br_taken = (a != b);                   // bne
            3'b100:  br_taken = ($signed(a) <  $signed(b)); // blt
            3'b101:  br_taken = ($signed(a) >= $signed(b)); // bge
            3'b110:  br_taken = (a <  b);                   // bltu
            3'b111:  br_taken = (a >= b);                   // bgeu
            default: br_taken = 1'b0;
        endcase
    endfunction

    // Load: pull the addressed byte/half/word out of the read word and extend it.
    function automatic logic [31:0] load_ext(input logic [31:0] word, input logic [1:0] lo, input logic [2:0] f3);
        logic [7:0]  b;
        logic [15:0] h;
        b = word[lo*8 +: 8];
        h = lo[1] ? word[31:16] : word[15:0];
        case(f3)
            3'b000:  load_ext = {{24{b[7]}}, b};   // lb
            3'b001:  load_ext = {{16{h[15]}}, h};  // lh
            3'b010:  load_ext = word;              // lw
            3'b100:  load_ext = {24'b0, b};        // lbu
            3'b101:  load_ext = {16'b0, h};        // lhu
            default: load_ext = word;
        endcase
    endfunction

    // Single-port memory: ONE read per cycle (address muxed -- fetch uses pc, a load
    // uses ea), or a byte-enabled write for a store. One read port => one BRAM.
    always_ff @( posedge clk ) begin : mem_port
        if(rst) begin
            instr <= '0;
        end
        else if(state == EXECUTE && opcode == `OPCODE_STORE) begin
            if(st_be[0]) memory[ea_s[AW-1:2]][ 7: 0] <= st_data[ 7: 0];
            if(st_be[1]) memory[ea_s[AW-1:2]][15: 8] <= st_data[15: 8];
            if(st_be[2]) memory[ea_s[AW-1:2]][23:16] <= st_data[23:16];
            if(st_be[3]) memory[ea_s[AW-1:2]][31:24] <= st_data[31:24];
        end
        else begin
            instr <= memory[(state == EXECUTE && opcode == `OPCODE_LOAD) ? ea_l[AW-1:2] : pc[AW-1:2]];
        end
    end

    always_ff @( posedge clk ) begin : cpu_fsm
        if(rst) begin
            pc        <= '0;
            registers <= '0;
            state     <= FETCH;
        end
        else if(state == FETCH) begin
            state <= EXECUTE;                            // instr <= memory[pc] happens in mem_port
        end
        else if(state == EXECUTE) begin
            case(opcode)                                 // writeback (loads write in MEM; x0 stays 0)
                `OPCODE_OP:     if(rd != '0) registers[rd] <= (funct7 == 7'b0000001)        // mul (M ext): low 32 bits
                                                              ? registers[rs1] * registers[rs2]
                                                              : alu(registers[rs1], registers[rs2], funct3, instr[30]);
                `OPCODE_OP_IMM: if(rd != '0) registers[rd] <= alu(registers[rs1], imm_i, funct3, (funct3 == 3'b101) & instr[30]);
                `OPCODE_LUI:    if(rd != '0) registers[rd] <= {instr[31:12], 12'b0};
                `OPCODE_AUIPC:  if(rd != '0) registers[rd] <= pc + {instr[31:12], 12'b0};
                `OPCODE_JAL,
                `OPCODE_JALR:   if(rd != '0) registers[rd] <= pc + 4;       // return address
                `OPCODE_CUSTOM: if(rd != '0) registers[rd] <= (funct3 == 3'b000) // rdtid -> tid
                                                              ? tid
                                                              : {24'b0, dt_rdata}; // getdt -> data[rs1] (setdt has rd=0)
            endcase

            if(opcode == `OPCODE_SYSTEM && instr[20]) begin
                state <= EXECUTE;                        // ebreak: halt
            end
            else if(opcode == `OPCODE_SYSTEM) begin      // ecall: a7==1 getchar, else putchar
                if(registers[17] == 32'd1) begin
                    if(!rx_empty) begin                  // getchar: take a byte into a0 (else wait)
                        registers[10] <= {24'b0, rx_data};
                        pc <= pc + 4; state <= FETCH;
                    end
                end
                else if(!tx_full) begin                  // putchar: a0 low byte goes out (else wait)
                    pc <= pc + 4; state <= FETCH;
                end
            end
            else if(opcode == `OPCODE_LOAD) begin         // read started in mem_port; finish in MEM
                ld_rd     <= rd;
                ld_funct3 <= funct3;
                ld_lo     <= ea_l[1:0];
                state     <= MEM;
            end
            else if(opcode == `OPCODE_STORE) begin        // write happens in mem_port
                pc <= pc + 4; state <= FETCH;
            end
            else begin
                state <= FETCH;
                case(opcode)                             // next pc
                    `OPCODE_JAL:    pc <= pc + imm_j;
                    `OPCODE_JALR:   pc <= (registers[rs1] + imm_i) & ~32'd1;
                    `OPCODE_BRANCH: pc <= br_taken(registers[rs1], registers[rs2], funct3) ? pc + imm_b : pc + 4;
                    default:        pc <= pc + 4;
                endcase
            end
        end
        else if(state == MEM) begin                       // load result is in instr now
            if(ld_rd != '0) registers[ld_rd] <= load_ext(instr, ld_lo, ld_funct3);
            pc    <= pc + 4;
            state <= FETCH;
        end
    end

    always_comb begin : decode
        opcode = instr[6:0];
        rd     = instr[11:7];
        funct3 = instr[14:12];
        rs1    = instr[19:15];
        rs2    = instr[24:20];
        funct7 = instr[31:25];
        imm_i  = {{20{instr[31]}}, instr[31:20]};
        imm_s  = {{20{instr[31]}}, instr[31:25], instr[11:7]};
        imm_b  = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
        imm_j  = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
        ea_l   = registers[rs1] + imm_i;
        ea_s   = registers[rs1] + imm_s;
        st_data = registers[rs2] << (8 * ea_s[1:0]);
        case(funct3)
            3'b000:  st_be = 4'b0001 << ea_s[1:0];   // sb
            3'b001:  st_be = 4'b0011 << ea_s[1:0];   // sh
            3'b010:  st_be = 4'b1111;                // sw
            default: st_be = 4'b0000;
        endcase
    end

    // ecall = putchar (a0 low byte out) or getchar (a7==1, a byte in -> a0).
    always_comb begin : outputs
        rx_pop  = 1'b0;
        tx_push = 1'b0;
        tx_data = registers[10][7:0];
        if(state == EXECUTE && opcode == `OPCODE_SYSTEM && !instr[20]) begin
            if(registers[17] == 32'd1) rx_pop  = !rx_empty;   // getchar consumes one byte
            else                       tx_push = !tx_full;    // putchar sends one byte
        end
    end

    // GPU: getdt reads the shared data memory combinationally; setdt writes it
    // with a one-clock pulse. Both index with registers[rs1]. setdt never blocks.
    always_comb begin : data_port
        dt_raddr = registers[rs1][DATA_AW-1:0];
        dt_addr  = registers[rs1][DATA_AW-1:0];
        dt_wdata = registers[rs2][7:0];
        dt_we    = (state == EXECUTE) && (opcode == `OPCODE_CUSTOM) && (funct3 == 3'b001);
    end

endmodule : cpu
