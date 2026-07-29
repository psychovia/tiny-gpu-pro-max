// cpu.sv

import gpu_pkg::*;

module cpu (
    input logic clk, rst,
    input state_t state,       // shared phase, driven by scheduler.sv
    input logic [4:0] lane_id, // which of the 32 lanes this cpu instance is (core.sv's generate index) -- differs per lane
    input logic [6:0] opcode,
    input logic [4:0] rd, rs1, rs2,
    input logic [2:0] funct3,
    input logic [6:0] funct7,
    input logic [31:0] imm,
    input logic [31:0] pc,
    input  logic [31:0] mem_rdata,  // registered, valid the cycle after mem_addr is set
    output logic [31:0] mem_addr,

    // ---- data buffer port (getdt / setdt), see data_buffer.sv ----
    // The image store, separate from shared_mem. Indexed by ELEMENT, so
    // there is no address arithmetic here at all: the index is just rs1_val,
    // and the store value just rs2_val. Same registered-read + valid-pulse
    // contract as the memory port above.
    output logic [31:0] dt_idx,
    output logic        dt_read,
    output logic        dt_write,
    output logic [31:0] dt_wdata,
    input  logic [31:0] dt_rdata,
    // (dt_valid goes straight from data_buffer.sv to scheduler.sv -- it drives
    // the stall, and nothing in here reads it, exactly like mem_valid.)
    output logic [31:0] rs1_val, rs2_val, 
    output logic mem_read,
    output logic mem_write,
    output logic [31:0] mem_wdata,
    output logic [3:0]  byte_en,  // ASSUMPTION: one-hot-per-byte write mask
    // signals this thread is done. Convention: a program marks a
    // thread complete by writing 1 to x31 via an ALU op, e.g. `addi x31,
    // x0, 1`. Sticky -- once set, stays set until reset, regardless of
    // what happens to x31 afterward.
    output logic done,

    input logic active // connected with active_mask[i] when instantiating
);

    // ------------------------------------------------------------------
    // Important declarations
    // ------------------------------------------------------------------

    // 32 registers. x0 must always read as 0
    // must never write regs[0].
    logic [31:0] regs [0:31];

    logic [31:0] alu_result;      // registered at the end of S_EXECUTE
    logic [31:0] alu_result_comb; // combinational ALU output (bottom of file)

    // Opcode names. Identical encodings to the raw 7'b... literals these
    // replace -- but each one is compared in several places (memory port,
    // writeback enables, ALU), and a mistyped bit pattern is invisible in
    // review while a mistyped name fails to compile.
    localparam logic [6:0] OP_R      = 7'b0110011; // add/sub/mul, shift, compare, logic
    localparam logic [6:0] OP_I      = 7'b0010011; // same ops, second operand is an immediate
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;

    // ------------------------------------------------------------------
    // Data-buffer instructions (getdt / setdt / gettid)
    // ------------------------------------------------------------------
    // All three share OPC_GPU and are told apart by funct3, so this is their
    // entire decode. See gpu_pkg.sv for the encoding and data_buffer.sv for
    // what they talk to.
    //
    //   getdt rd, rs1      rd  <- dbuf[rs1]        (a load, but of the buffer)
    //   setdt rs1, rs2     dbuf[rs1] <- rs2        (a store, likewise)
    //   rdtid rd           rd  <- lane_id          (pure ALU, no memory at all)
    logic is_getdt, is_setdt, is_rdtid;
    assign is_getdt = (opcode == OPC_GPU) & (funct3 == F3_GETDT);
    assign is_setdt = (opcode == OPC_GPU) & (funct3 == F3_SETDT);
    assign is_rdtid = (opcode == OPC_GPU) & (funct3 == F3_RDTID);

    // ------------------------------------------------------------------
    // Memory port
    // ------------------------------------------------------------------
    logic [31:0] ea; // actual memory address computer from instruction
    logic [31:0] load_result;

    assign mem_addr = (state == S_MEM_ADDR || state == S_MEM_WAIT) ? ea : pc;

    // MMIO_BASE (gpu_pkg.sv) reserves a slice of the address space for
    // future device registers rather than real memory -- nothing generates
    // an MMIO address today (no compiler/program targets it yet), but if a
    // load/store's `ea` ever landed there, it must NOT be allowed to fall
    // through to shared_mem.sv, since word_idx only looks at the low bits
    // of the address and would silently alias into real program/image
    // memory. This is a defensive stub only: it makes MMIO accesses inert
    // (loads read 0, stores are dropped) rather than defining real device
    // behavior, which depends on hardware/toolchain decisions not made yet.
    logic is_mmio;
    assign is_mmio = (ea[31:16] == MMIO_BASE[31:16]);

    // ea[1:0] gives the byte offset within the 32-bit word (0-3).
    // Multiplying by 8 converts byte offset to bit offset so we can
    // extract the right byte(s) from mem_rdata using +: 8 or +: 16.
    // e.g. byte 2 -> bit 16 -> mem_rdata[16 +: 8] grabs bits [23:16].
    //Memory is organized in 32-bit (4-byte) words, but instructions like lb (load byte) only want one byte out of that word. The bottom 2 bits of the address (ea[1:0]) tell you which byte (0, 1, 2, or 3) within the word you want
    logic [4:0] byte_shift;
    assign byte_shift = {ea[1:0], 3'b000};

    // Slide the addressed byte/halfword down to bit 0 once, up front, so
    // the case below only has to choose a width and how to extend it.
    // Doing the part-select inside each arm instead (mem_rdata[byte_shift
    // +: 8], mem_rdata[byte_shift +: 16], ...) asks the tool for a separate
    // variable shifter per arm; this gets the same answer out of one.
    logic [31:0] rdata_aligned;
    assign rdata_aligned = mem_rdata >> byte_shift;

    // loading out of the memory
    always_ff @(posedge clk) begin
        if (active & state == S_MEM_WAIT) begin
            if (is_mmio) begin
                load_result <= 32'd0; // no real device behind MMIO_BASE yet -- reads as 0
            end else begin
                case(funct3)
                    3'b000:  load_result <= {{24{rdata_aligned[7]}},  rdata_aligned[7:0]};  // lb  sign extended
                    3'b001:  load_result <= {{16{rdata_aligned[15]}}, rdata_aligned[15:0]}; // lh  sign extended
                    3'b010:  load_result <= mem_rdata;                                      // lw
                    3'b100:  load_result <= {24'd0, rdata_aligned[7:0]};                    // lbu zero extended
                    3'b101:  load_result <= {16'd0, rdata_aligned[15:0]};                   // lhu zero extended
                    default: load_result <= 32'd0;
                endcase
            end
        end
    end

    // which address to take from in memory. Only a load or a store ever
    // computes one; every other state/opcode just leaves ea holding what it
    // had, which is what the old nested case's two `ea <= ea` arms said.
    always_ff @(posedge clk) begin
        if (active & (state == S_EXECUTE) & (opcode == OP_LOAD | opcode == OP_STORE)) begin
            ea <= rs1_val + imm;
        end
    end


    assign mem_write = (state == S_MEM_ADDR & opcode == OP_STORE); // s-type
    // Only assert mem_read when something actually needs the result:
    // fetching the instruction (S_FETCH/S_FETCH_WAIT) or a load's data
    // (S_MEM_ADDR/S_MEM_WAIT). Not S_EXECUTE/S_WRITEBACK -- instr was
    // already latched, so reading again there was just wasted bandwidth.
    assign mem_read = (state == S_FETCH) | (state == S_FETCH_WAIT) |
                       (active & (state == S_MEM_ADDR | state == S_MEM_WAIT) & opcode == OP_LOAD); // l-type loading from memory to register
    // NOTE: mem_read/mem_write deliberately stay ungated by is_mmio -- an
    // MMIO-targeted lane still needs to be granted+serviced normally so
    // scheduler.sv's stall bookkeeping (which waits for every lane's
    // mem_valid during S_MEM_ADDR) doesn't hang waiting on a lane that
    // would otherwise never request anything. MMIO safety is enforced
    // below instead, by neutralizing byte_en (no real bytes ever get
    // written) and by the load_result override above (reads as 0).

    // A word is 4 mail slots in a row; a store only wants to drop a letter
    // into 1 (sb) or 2 (sh) of them. ea[1:0] says which slot to start at,
    // so we slide the "letters here" mask over by that many slots.
    logic [3:0] byte_en_comb;
    always_comb begin
        if (is_mmio) begin
            byte_en_comb = 4'b0000; // no real device yet -- never actually commit bytes to shared_mem for an MMIO store, no matter what address it aliases to
        end else begin
            case (funct3)
                3'b000:  byte_en_comb = 4'b0001 << ea[1:0]; // one hot encoding so 0001 refers to one byte that should be replaced and then ea[1:0] shifts the to which byte supposed to store - sb
                3'b001:  byte_en_comb = 4'b0011 << ea[1:0]; // sh
                3'b010:  byte_en_comb = 4'b1111;            // sw
                default: byte_en_comb = 4'b0000;
            endcase
        end
    end
    assign byte_en = byte_en_comb;

    // mem_wdata: rs2_val shifted into the same byte position byte_en marks
    // as active, so memory.sv can latch the whole word and let byte_en
    // decide what actually gets written.
    //
    // Split into "pick the bytes" then "position them" so the shift is
    // written once -- shifting inside each arm (<< byte_shift on both the
    // sb and sh arms) is a barrel shifter per store size. sw already fills
    // the word, so it bypasses the shifter entirely.
    logic [31:0] store_data; // the bytes being stored, right-justified
    always_comb begin
        case (funct3)
            3'b000:  store_data = {24'd0, rs2_val[7:0]};  // sb
            3'b001:  store_data = {16'd0, rs2_val[15:0]}; // sh
            3'b010:  store_data = rs2_val;                // sw
            default: store_data = 32'd0;
        endcase
    end
    assign mem_wdata = (funct3 == 3'b010) ? store_data : (store_data << byte_shift);

    // ------------------------------------------------------------------
    // Data buffer port (getdt / setdt)
    // ------------------------------------------------------------------
    // No `ea` register and no address arithmetic, unlike the memory port
    // above: the index IS rs1_val and the store value IS rs2_val. Both come
    // straight out of the register file, which doesn't move until
    // S_WRITEBACK, so they are already stable for the whole S_MEM_ADDR /
    // S_MEM_WAIT window the buffer is being asked during.
    assign dt_idx   = rs1_val;
    assign dt_wdata = rs2_val;

    // Same phases as a load/store, so scheduler.sv's existing S_MEM_ADDR
    // stall (wait until every lane has been serviced) covers these too.
    assign dt_read  = active & (state == S_MEM_ADDR | state == S_MEM_WAIT) & is_getdt;
    assign dt_write = active & (state == S_MEM_ADDR) & is_setdt;

    // Latched in S_MEM_WAIT for the same reason load_result is: data_buffer
    // registers its read data, so it is valid the cycle after the grant and
    // holds until this lane is granted again.
    logic [31:0] dt_result;
    always_ff @(posedge clk) begin
        if (active & state == S_MEM_WAIT) begin
            dt_result <= dt_rdata;
        end
    end

    // ------------------------------------------------------------------
    // Register file
    // Combinational read, synchronous write, x0 hardwired to 0.
    // ------------------------------------------------------------------
    logic is_S_EXECUTE, wb_en, wb_load;

    assign rs1_val = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
    assign rs2_val = (rs2 == 5'd0) ? 32'd0 : regs[rs2];
    assign is_S_EXECUTE = active & (state == S_EXECUTE);

    // wb_en: this lane writes rd this cycle. Branches and stores have no
    // destination register, and x0 is hardwired to 0, so neither may write.
    // wb_load then picks where the data comes from -- a load brings its
    // value in from memory, everything else uses the latched ALU result.
    // (The old pair spelled this out twice: is_LOAD_RESULT repeated
    // is_ALU_RESULT's "not a branch, not a store" terms even though
    // `opcode == load` already implies both, and had to be tested first to
    // stop loads writing the ALU result. One enable + one source select
    // can't get that ordering wrong.)
    // setdt joins branch and store on the "no destination register" list;
    // getdt and rdtid both produce a value, so they write rd like any load
    // or ALU op does.
    assign wb_en   = active & (state == S_WRITEBACK) & (rd != 5'd0) &
                     (opcode != OP_BRANCH) & (opcode != OP_STORE) & ~is_setdt;
    assign wb_load = (opcode == OP_LOAD);

    // Where the written value comes from. rdtid isn't listed because it goes
    // through the ALU (see the bottom of this file) -- it needs no memory
    // access, so making it an ALU result keeps it off this path entirely.
    logic [31:0] wb_data;
    always_comb begin
        if      (wb_load)  wb_data = load_result; // lw / lb / lh / lbu / lhu
        else if (is_getdt) wb_data = dt_result;   // data buffer
        else               wb_data = alu_result;  // ALU, gettid included
    end

    // Latch the ALU result at the end of S_EXECUTE and hold it. This used
    // to clear to 0 in every other state, which only worked because
    // S_EXECUTE is immediately followed by S_WRITEBACK for every opcode
    // that writes alu_result -- holding drops a 32-bit mux and stops
    // depending on that adjacency. rst still clears it so the value is
    // never X before the first instruction retires.
    always_ff @(posedge clk) begin
        if (rst) begin
            alu_result <= 32'd0;
        end
        else if (is_S_EXECUTE) begin
            alu_result <= alu_result_comb;
        end
    end

    // reset registers. x30 is the exception: instead of zeroing it like
    // everything else, pre-load it with this lane's identity (lane_id) so
    // a program can compute which pixel it owns just by reading a
    // register -- no new instruction needed. Reserved by convention only
    // (like x31 for "done"), not hardware-enforced -- a program could
    // still clobber it if it used x30 as scratch.
    // x29 used to hold block_id (see block_logic.sv) back when this core
    // cycled through multiple blocks of threads; now lane_id alone is the
    // thread id, so x29 is just a normal zeroed register.
    // Reset and writeback MUST live in the same always_ff block. They used
    // to be two separate blocks, which is a multi-driver on `regs`: Vivado
    // kept the constant (reset) driver, silently discarded the writeback
    // driver, and left the register file permanently zero -- which
    // constant-folded the entire datapath away (whole design synthesized to
    // ~30 LUTs). Keep reset as the first branch so it has priority.
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 32; i++) regs[i] <= 32'd0;
            regs[30] <= {27'd0, lane_id};
        end
        // what to put back into the register
        else if (wb_en) begin
            regs[rd] <= wb_data;
        end
    end

    // done -- sticky, set once this lane writes 1 to x31 via an ALU
    // op, never cleared except on reset. ~wb_load keeps that "via an ALU
    // op" wording literal: a load landing 1 in x31 doesn't count.
    always_ff @(posedge clk) begin
        if (rst) begin
            done <= 1'b0;
        end
        else if (wb_en & ~wb_load & rd == 5'd31 & alu_result == 32'd1) begin
            done <= 1'b1;
        end
    end


    // ------------------------------------------------------------------
    // Combinational ALU
    //
    // Register-register (OP_R) and register-immediate (OP_I) run the same
    // eight funct3 operations; the only difference is where the second
    // operand comes from. Decoding them in two separate branches (as this
    // used to) asks the tool for two adders, two comparator pairs, two
    // shifters and two logic blocks. Muxing the operand first and decoding
    // once gives one of each -- same behavior, about half the ALU.
    //
    // funct3=000 is the one place the two forms genuinely differ: on OP_R
    // funct7 selects add/sub/mul, but on OP_I those same instruction bits
    // are the top of the immediate, so addi must ignore them and always
    // add. Shifts are safe to share -- RISC-V deliberately puts srai's
    // funct7=0100000 in that same field.
    // ------------------------------------------------------------------
    logic        use_rs2; // second operand is rs2 rather than imm
    logic [31:0] alu_b;   // the second operand itself
    logic [4:0]  shamt;
    logic [31:0] sum, diff;

    assign use_rs2 = (opcode == OP_R);
    assign alu_b   = use_rs2 ? rs2_val : imm;
    assign shamt   = alu_b[4:0];
    assign sum     = rs1_val + alu_b;
    assign diff    = rs1_val - alu_b;

    always_comb begin
        case (opcode)
            OP_R, OP_I:
                case (funct3)
                    3'b000: begin // add / sub / mul -- addi always adds
                        if (!use_rs2 | funct7 == 7'b0000000) alu_result_comb = sum;
                        else if (funct7 == 7'b0100000)       alu_result_comb = diff;
                        else if (funct7 == 7'b0000001)       alu_result_comb = rs1_val * rs2_val; // mul
                        else                                 alu_result_comb = 32'd0;
                    end
                    3'b001: alu_result_comb = rs1_val << shamt;                                    // sll(i)
                    3'b010: alu_result_comb = ($signed(rs1_val) < $signed(alu_b)) ? 32'd1 : 32'd0; // slt(i)
                    3'b011: alu_result_comb = (rs1_val < alu_b) ? 32'd1 : 32'd0;                   // sltu(i)
                    3'b100: alu_result_comb = rs1_val ^ alu_b;                                     // xor(i)
                    3'b101: // srl(i) / sra(i) -- funct7 is meaningful for both forms
                        case (funct7)
                            7'b0000000: alu_result_comb = rs1_val >> shamt;
                            7'b0100000: alu_result_comb = $signed(rs1_val) >>> shamt;
                            default:    alu_result_comb = 32'd0;
                        endcase
                    3'b110: alu_result_comb = rs1_val | alu_b;                                     // or(i)
                    3'b111: alu_result_comb = rs1_val & alu_b;                                     // and(i)
                    default: alu_result_comb = 32'd0;
                endcase
            // rdtid -- this lane's identity, straight out of the generate
            // index core.sv instantiated it with. Handled here rather than as
            // its own writeback source because it touches no memory: it is an
            // ALU op whose "operand" happens to be a constant per lane.
            // (getdt/setdt are NOT here; they go to the data buffer.)
            OPC_GPU:  alu_result_comb = {27'd0, lane_id};
            // u-type
            OP_LUI:   alu_result_comb = imm;
            OP_AUIPC: alu_result_comb = pc + imm;
            // jal/jalr: rd gets the link address
            OP_JAL, OP_JALR: alu_result_comb = pc + 32'd4;
            default: alu_result_comb = 32'd0;
        endcase
    end

endmodule : cpu
