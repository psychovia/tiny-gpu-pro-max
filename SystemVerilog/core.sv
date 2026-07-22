/**
core
- main for thread execution

- scheduler.sv
- fetcher.sv
- decoder.sv
- pc.sv
- cpu.sv
**/

import gpu_pkg::*;

module core (
    input logic clk, rst,
    input  logic [31:0] mem_rdata [0:31], // one read-data word per lane (indexed by lane, not shared) -MEMORY.SV
    input  logic        mem_valid [0:31], // one cycle pulse per lane -- "the data/write I asked for just landed." scheduler.sv uses this to know when it's safe to leave S_FETCH_WAIT/S_MEM_ADDR
    output logic [31:0] mem_addr  [0:31], // one address per lane; each cpu lane drives its own (pc during fetch, ea during load/store)
    output logic        mem_read  [0:31], // per lane -- asserted whenever that lane wants read data this cycle
    output logic        mem_write [0:31], // per lane -- asserted on the one cycle a store commits
    output logic [31:0] mem_wdata [0:31], // per lane -- store data, shifted into byte position
    output logic [3:0]  byte_en   [0:31], // per lane -- which byte lane(s) of mem_wdata are valid
    output logic        block_done,       // high once every lane in the current block has signaled done
    output logic        kernel_done,      // high once every block has been dispatched and completed
    output logic [gpu_pkg::BLOCK_ID_WIDTH-1:0] block_id  // which block is currently assigned to this core
);

    // ------------------------------------------------------------------
    // wires connecting the five submodules
    // ------------------------------------------------------------------
    state_t state;              // shared phase, driven by scheduler

    logic [31:0] instr;

    logic [6:0] opcode;
    logic [4:0] rd, rs1, rs2;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [31:0] imm;

    logic [31:0] pc;            // current pc: pc.sv output -> cpu.sv input
    logic [31:0] rs1_val [0:31], rs2_val [0:31];  // register values, one per lane. pc.sv only needs
                                                    // ONE lane's copy (the leader lane) to resolve
                                                    // branches -- picking which lane and wiring it
                                                    // into pc.sv is step #3, not done yet.
    logic        done [0:31];                     // per-lane done, feeds scheduler's block_done reduction
    logic        block_start;                     // pulses when advancing to the next block; resets pc/regs/done like rst does, without touching block_id
    logic        stall;                           // scheduler.sv now drives this (freezes `state` until every lane it's waiting on has mem_valid) -- not yet consumed by pc.sv/cpu.sv themselves, since they still latch off `state` directly. Fine for now: freezing `state` already keeps them from advancing past a phase early.

    // ------------------------------------------------------------------
    // 1. scheduler - owns the shared state machine, decides when to move
    //    S_FETCH -> S_FETCH_WAIT -> S_EXECUTE -> ... -> S_WRITEBACK
    // ------------------------------------------------------------------
    scheduler u_scheduler (.*);

    // ------------------------------------------------------------------
    // 2. fetcher - latches mem_rdata into instr. The fetch *address* is
    //    driven onto mem_addr by cpu.sv below (it muxes pc vs ea).
    // ------------------------------------------------------------------
    // mem_rdata is now a per-lane array; every lane sees the identical
    // address during fetch (all present pc), so any lane's copy is valid --
    // explicitly picking lane 0, same leader-lane convention used for pc.sv.
    
    // input logic [31:0] mem_rdata
    // input logic clk
    // input logic state_t state
    // output logic [31:0] instr
    fetcher u_fetcher (.*, .mem_rdata(mem_rdata[0]));

    // ------------------------------------------------------------------
    // 3. decoder - splits instr into opcode/rd/rs1/rs2/funct3/funct7/imm
    // ------------------------------------------------------------------
    /**
    input logic [31:0] instr,
    output logic [6:0] opcode,
    output logic [4:0] rd, rs1, rs2,
    output logic [2:0] funct3,
    output logic [6:0] funct7,
    output logic [31:0] imm
    **/
    decoder u_decoder (.*);

    // ------------------------------------------------------------------
    // 4. cpu - register file + ALU + load/store, also drives mem_addr.
    //    32 lanes, one per thread. clk/rst/state/pc/opcode/rd/rs1/rs2/
    //    funct3/funct7/imm/block_id are the *same* wire fanned out to all
    //    32 (SIMD lockstep -- matched by .* below). lane_id/mem_addr/
    //    mem_rdata/rs1_val/rs2_val differ per lane, so those are connected
    //    explicitly to array element [i], overriding the .* match for
    //    just those ports.
    // ------------------------------------------------------------------
    /**
    input logic clk, rst,
    input logic block_start,
    input state_t state,
    input logic [gpu_pkg::BLOCK_ID_WIDTH-1:0] block_id,
    input logic [4:0] lane_id,
    input logic [6:0] opcode,
    input logic [4:0] rd, rs1, rs2,
    input logic [2:0] funct3,
    input logic [6:0] funct7,
    input logic [31:0] imm,
    input logic [31:0] pc,
    input  logic [31:0] mem_rdata, - from memory
    output logic [31:0] mem_addr,
    output logic [31:0] rs1_val, rs2_val,
    output logic mem_read,
    output logic mem_write,
    output logic [31:0] mem_wdata,
    output logic [3:0]  byte_en,
    output logic done
    **/

    genvar i;
    generate
        for (i = 0; i < 32; i++) begin : lane
            cpu u_cpu (
                .*,
                .lane_id(i[4:0]), // from this generation statement -- pre-loaded into x30 on reset/block_start
                .mem_rdata(mem_rdata[i]), // from memory
                .mem_addr(mem_addr[i]), // output
                .rs1_val(rs1_val[i]),
                .rs2_val(rs2_val[i]),
                .mem_read(mem_read[i]),
                .mem_write(mem_write[i]),
                .mem_wdata(mem_wdata[i]),
                .byte_en(byte_en[i]),
                .done(done[i])
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // 5. pc - computes next pc from branch/jump condition. rs1_val/rs2_val
    //    are now per-lane arrays (one per thread), but pc.sv only takes a
    //    single scalar rs1_val/rs2_val -- it needs exactly one lane's
    //    values to resolve a branch for the whole core. We designate lane
    //    0 the "leader lane": its registers decide every branch/jump for
    //    all 32 lanes. This assumes uniform control flow -- every thread
    //    must agree on the branch outcome, since only lane 0's registers
    //    are actually consulted. Divergent per-thread branching isn't
    //    supported by this design.
    // ------------------------------------------------------------------
    
    /**
    input state_t state,
    input logic rst, clk,
    input logic block_start, 
    input logic [6:0] opcode,
    input logic [2:0] funct3, 
    input logic [31:0] rs1_val, rs2_val,
    input logic [31:0] imm,
    output logic [31:0] pc
    **/
    
    pc u_pc (
        .*,
        .rs1_val(rs1_val[0]),
        .rs2_val(rs2_val[0])
    );

endmodule
