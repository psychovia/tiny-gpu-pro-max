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
    // All per-lane arrays are sized off gpu_pkg::N_LANES rather than a
    // hardcoded [0:31]. They used to be literal 32s, which silently pinned
    // the whole design to 32 lanes even though gpu_pkg/scheduler/shared_mem
    // were already parameterized -- changing N_LANES alone would have left
    // these ports the wrong width.
    input  logic [31:0] mem_rdata [0:N_LANES-1], // one read-data word per lane (indexed by lane, not shared) -MEMORY.SV
    input  logic        mem_valid [0:N_LANES-1], // one cycle pulse per lane -- "the data/write I asked for just landed." scheduler.sv uses this to know when it's safe to leave S_FETCH_WAIT/S_MEM_ADDR
    output logic [31:0] mem_addr  [0:N_LANES-1], // one address per lane; each cpu lane drives its own (pc during fetch, ea during load/store)
    output logic        mem_read  [0:N_LANES-1], // per lane -- asserted whenever that lane wants read data this cycle
    output logic        mem_write [0:N_LANES-1], // per lane -- asserted on the one cycle a store commits
    output logic [31:0] mem_wdata [0:N_LANES-1], // per lane -- store data, shifted into byte position
    output logic [3:0]  byte_en   [0:N_LANES-1], // per lane -- which byte lane(s) of mem_wdata are valid

    // ---- data buffer (getdt / setdt) -- see data_buffer.sv ----
    // A second, independent memory port set, one per lane. Unlike the
    // shared_mem ports above these are NOT arbitrated down to one winner per
    // cycle: the buffer is banked one bank per lane, so a kernel striding by
    // N_LANES has all of them serviced simultaneously.
    input  logic [31:0] dt_rdata  [0:N_LANES-1],
    input  logic        dt_valid  [0:N_LANES-1], // straight to the scheduler's stall logic
    output logic [31:0] dt_idx    [0:N_LANES-1], // element index, not a byte address
    output logic        dt_read   [0:N_LANES-1],
    output logic        dt_write  [0:N_LANES-1],
    output logic [31:0] dt_wdata  [0:N_LANES-1],

    output logic        kernel_done       // high once every lane has signaled done -- see scheduler.sv's NOTE on block dispatch being removed
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
    logic [31:0] rs1_val [0:N_LANES-1], rs2_val [0:N_LANES-1];  // register values, one per lane. pc.sv only needs
                                                    // ONE lane's copy (the leader lane) to resolve
                                                    // branches -- picking which lane and wiring it
                                                    // into pc.sv is step #3, not done yet.
    logic        done [0:N_LANES-1];              // per-lane done, feeds scheduler's kernel_done reduction
    logic        stall;                           // scheduler.sv now drives this (freezes `state` until every lane it's waiting on has mem_valid) -- not yet consumed by pc.sv/cpu.sv themselves, since they still latch off `state` directly. Fine for now: freezing `state` already keeps them from advancing past a phase early.
    // Must track scheduler.sv, which declares this as [LANES-1:0]. It was
    // [31:0] here, which only happened to match while N_LANES was 32 --
    // with any other lane count the widths disagree and the upper bits
    // would be left undriven.
    logic [N_LANES-1:0] active_mask;              // scheduler.sv output -> each cpu lane's `active` input (bit i = lane i)

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
    //    funct3/funct7/imm are the *same* wire fanned out to all
    //    32 (SIMD lockstep -- matched by .* below). lane_id/mem_addr/
    //    mem_rdata/rs1_val/rs2_val differ per lane, so those are connected
    //    explicitly to array element [i], overriding the .* match for
    //    just those ports.
    // ------------------------------------------------------------------
    /**
    input logic clk, rst,
    input state_t state,
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
        for (i = 0; i < N_LANES; i++) begin : lane
            cpu u_cpu (
                .*,
                .lane_id(i[4:0]), // from this generation statement -- pre-loaded into x30 on reset
                .mem_rdata(mem_rdata[i]), // from memory
                .mem_addr(mem_addr[i]), // output
                .rs1_val(rs1_val[i]),
                .rs2_val(rs2_val[i]),
                .mem_read(mem_read[i]),
                .mem_write(mem_write[i]),
                .mem_wdata(mem_wdata[i]),
                .byte_en(byte_en[i]),
                .dt_rdata(dt_rdata[i]),
                .dt_idx(dt_idx[i]),
                .dt_read(dt_read[i]),
                .dt_write(dt_write[i]),
                .dt_wdata(dt_wdata[i]),
                .done(done[i]),
                .active(active_mask[i])
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
