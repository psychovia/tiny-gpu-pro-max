/**
data_buffer.sv -- the image store the rendering kernel reads and writes with
`getdt` / `setdt`. A second memory, entirely separate from shared_mem.sv.

WHY THIS EXISTS AT ALL
    shared_mem.sv has ONE port shared by every lane, so its arbiter grants one
    lane per cycle: an 8-lane load costs 8 cycles of arbitration, and
    scheduler.sv sits in S_MEM_ADDR the whole time waiting for the last lane.
    Pixel traffic is the bulk of a rendering kernel's work, so that arbiter is
    the whole cost of the program.

    This buffer is BANKED instead -- one bank per lane, each an independent
    single-port memory. A kernel written the natural SIMT way

        for (i = tid; i < N; i += N_LANES) setdt(i, ...);

    has lane i touching only indices where (i % N_LANES) == lane_id, which is
    exactly one bank per lane, all different. All 8 lanes are granted in the
    SAME cycle. Nothing is stalled, nothing queues.

    Banking is only a fast path, never a correctness requirement: if several
    lanes do land on one bank, that bank hands out grants round-robin over as
    many cycles as it takes, exactly like shared_mem, and the kernel still
    gets the right answer -- just slower. A kernel can index however it likes.

ADDRESSING
    Indexed by ELEMENT, not by byte: index 7 is the 8th element, full stop.
    There is no alignment rule, no byte enable and no straddle, because one
    element is one 32-bit value. For image data that value is a pixel,
    0x00_BB_GG_RR (the same channel order shared_mem's display port produced,
    so display_controller.sv slices it the same way).

    index -> (bank, row) is a pure bit split, no divider:
        bank = index[BANK_BITS-1:0]     (which lane's bank -- the low bits, so
                                         a stride of N_LANES walks one bank)
        row  = index[.. : BANK_BITS]    (which entry within that bank)

    An out-of-range index WRAPS (the row is truncated) rather than trapping.
    That keeps every array read in bounds -- an out-of-range SystemVerilog
    array read is X in simulation but real aliased data on the FPGA, which is
    the sim/hardware divergence shared_mem.sv's word_idx comment warns about.
**/

import gpu_pkg::*;

module data_buffer #(
    parameter int    N_THREADS = gpu_pkg::N_LANES,
    parameter int    WORDS     = gpu_pkg::DBUF_WORDS,
    // Initial contents = the SOURCE image. This is a PREFIX, not a filename:
    // bank b reads "<INIT_PREFIX>b.mem". python3 python_scripts/img_tool.py
    // to-dbuf writes the whole set. A kernel that renders from scratch rather
    // than filtering an input can point this at the all-zeros set.
    parameter string INIT_PREFIX = "mems/dbuf_zeros_bank"
) (
    input  logic clk, rst,

    // ---- per-lane element port (cpu.sv's getdt / setdt) ----
    input  logic [31:0] dt_idx   [0:N_THREADS-1], // element index, not a byte address
    input  logic        dt_read  [0:N_THREADS-1],
    input  logic        dt_write [0:N_THREADS-1],
    input  logic [31:0] dt_wdata [0:N_THREADS-1],
    output logic [31:0] dt_rdata [0:N_THREADS-1],
    output logic        dt_valid [0:N_THREADS-1], // 1-cycle pulse: your data landed

    // ---- display read port ----
    // Dedicated, like shared_mem's port B: the only user, so nothing to
    // arbitrate. Takes a PIXEL INDEX (not a byte address) -- one element per
    // pixel means display_controller.sv no longer has to read two words and
    // slice a straddling pixel out of them.
    input  logic [31:0] disp_pixel,
    output logic [31:0] disp_dt_rdata
);

    localparam int BANKS     = N_THREADS;
    localparam int BANK_BITS = $clog2(BANKS);
    localparam int ROWS      = WORDS / BANKS;
    localparam int ROW_BITS  = $clog2(ROWS);
    localparam int LANE_BITS = $clog2(N_THREADS);

    // ------------------------------------------------------------------
    // Initial contents -- the SOURCE image, one file per bank.
    //
    // This USED to $readmemb one flat file into an `init_flat` array and then
    // scatter it into the banks. That works in simulation and is silently
    // dropped in hardware: Vivado cannot constant-fold a read of another array
    // written in an initial block, so it reports
    //     WARNING: [Synth 8-311] ignoring non-constant assignment in initial block
    // once per bank and leaves the block RAMs powering up as zeros. A filter
    // kernel then reads the image fine in simulation and reads all zeros on the
    // board -- the worst kind of divergence, because nothing errors.
    //
    // Each bank now reads its OWN file directly, which is a plain memory
    // initialisation Vivado turns into the BRAM's INIT contents. Bank b holds
    // every element whose index ends in b, in order, so img_tool.py writes
    // <prefix>0.mem .. <prefix>7.mem with that stride already applied.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Which bank does each lane want, and is it asking?
    // ------------------------------------------------------------------
    logic [N_THREADS-1:0]    requesting;
    logic [BANK_BITS-1:0]    lane_bank [0:N_THREADS-1];
    logic [ROW_BITS-1:0]     lane_row  [0:N_THREADS-1];

    always_comb begin
        for (int i = 0; i < N_THREADS; i++) begin
            requesting[i] = dt_read[i] | dt_write[i];
            lane_bank[i]  = dt_idx[i][BANK_BITS-1:0];
            lane_row[i]   = dt_idx[i][BANK_BITS +: ROW_BITS];
        end
    end

    // ------------------------------------------------------------------
    // Round bookkeeping -- the same anti-starvation scheme shared_mem.sv
    // uses, and for the same reason: dt_read/dt_write are LEVEL signals held
    // for as long as `state` doesn't change, so without a memory of past
    // grants one lane could win its bank every cycle forever while another
    // lane on that bank starves and scheduler.sv stalls on it for good.
    //
    // ONE checklist covers all banks: a lane is done once it has been
    // granted, and it only ever wants one bank, so there is nothing per-bank
    // to track. The round ends (and the checklist wipes) once no requesting
    // lane is still unserved.
    // ------------------------------------------------------------------
    logic [N_THREADS-1:0] served;      // granted at some point this round
    logic [N_THREADS-1:0] eff_served;  // ...wiped once the requests go away

    // The round ends when the request lines DROP, not when everyone currently
    // asking has been answered. Those look the same until you remember the
    // requests are level-held: a lane keeps dt_read high for the whole
    // S_MEM_ADDR/S_MEM_WAIT window, so clearing the checklist the moment the
    // last lane is served just re-grants all of them on the next cycle -- the
    // same access answered three or four times over. Harmless but pure waste,
    // and it makes "one grant per buffer instruction" untestable.
    //
    // Waiting for requesting == 0 is safe here because the lanes run in
    // lockstep off one FSM: they all raise their request on the same
    // instruction and all drop it in S_WRITEBACK, so the line genuinely does
    // go idle between buffer instructions. Nobody can starve in the meantime
    // either -- each bank keeps granting its lowest unserved requester until
    // none are left.
    assign eff_served = (requesting == '0) ? '0 : served;

    // Per-bank grant: the lowest-numbered lane that wants this bank and has
    // not been served yet. Banks pick independently, so in the common case
    // (one lane per bank) every lane is granted in the same cycle.
    logic                 bank_gnt      [0:BANKS-1];
    logic [LANE_BITS-1:0] bank_gnt_lane [0:BANKS-1];
    logic [N_THREADS-1:0] granted_now;

    always_comb begin
        granted_now = '0;
        for (int b = 0; b < BANKS; b++) begin
            bank_gnt[b]      = 1'b0;
            bank_gnt_lane[b] = '0;
            for (int i = 0; i < N_THREADS; i++) begin
                if (requesting[i] & ~eff_served[i] & ~bank_gnt[b]
                        & (lane_bank[i] == b[BANK_BITS-1:0])) begin
                    bank_gnt[b]      = 1'b1;
                    bank_gnt_lane[b] = i[LANE_BITS-1:0];
                    granted_now[i]   = 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // The banks themselves.
    //
    // Each bank is its OWN plain 1-D array inside a generate block, not a
    // slice of one `bank_mem[BANKS][ROWS]`. That is not a style preference:
    // the 2-D form does not infer block RAM. The display port indexes the
    // outer dimension with a runtime value (disp_bank), and Vivado responds to
    // a dynamically-indexed outer dimension by building the whole thing out of
    // fabric -- measured at 80,021 LUTs and 131,376 flip-flops, 245% and 201%
    // of an xc7s50, against 0 block RAMs. Split this way each array has one
    // write port and two read ports at fixed addresses, which is exactly a
    // true dual-port BRAM, and the bank select becomes an 8:1 mux on the
    // output instead of a rebuild of the storage.
    //
    // Port A is the lane port (write + read share one address, as a BRAM port
    // requires); port B is the display read. Registered read data + a 1-cycle
    // valid pulse matches shared_mem.sv's contract exactly, so cpu.sv treats a
    // getdt like a load and scheduler.sv treats dt_valid like mem_valid.
    // ------------------------------------------------------------------
    logic [BANK_BITS-1:0] disp_bank;
    logic [ROW_BITS-1:0]  disp_row;
    assign disp_bank = disp_pixel[BANK_BITS-1:0];
    assign disp_row  = disp_pixel[BANK_BITS +: ROW_BITS];

    logic [31:0] bank_rq [0:BANKS-1];   // lane-port read data, one cycle later
    logic [31:0] bank_dq [0:BANKS-1];   // display-port read data, likewise

    genvar gb;
    generate
        for (gb = 0; gb < BANKS; gb++) begin : bank
            logic [31:0] mem [0:ROWS-1];

            // Bank gb holds every element whose index ends in gb, in order.
            // Zero first for the same reason shared_mem.sv does: $readmemb only
            // writes as many words as the file actually contains, and an
            // unwritten entry is X in simulation but a real 0 on the FPGA.
            localparam string BANK_FILE = $sformatf("%s%0d.mem", INIT_PREFIX, gb);
            initial begin
                for (int r = 0; r < ROWS; r++) mem[r] = 32'd0;
                $readmemb(BANK_FILE, mem);
            end

            always_ff @(posedge clk) begin
                if (bank_gnt[gb] && dt_write[bank_gnt_lane[gb]])
                    mem[lane_row[bank_gnt_lane[gb]]] <= dt_wdata[bank_gnt_lane[gb]];
                bank_rq[gb] <= mem[lane_row[bank_gnt_lane[gb]]];
                bank_dq[gb] <= mem[disp_row];
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Route each bank's answer back to the lane it served.
    //
    // Registered and HELD, exactly like shared_mem's mem_rdata, because the
    // consumer is a cycle further out than it first looks: the grant is in
    // S_MEM_ADDR, but dt_valid only reaches scheduler.sv's `serviced` register
    // the cycle after that, so the stall doesn't lift and S_MEM_WAIT doesn't
    // start until one cycle later still. A combinational mux off the bank
    // output is valid for exactly one cycle and would already be gone by then
    // -- which reads back as 0, not as a timing warning.
    // ------------------------------------------------------------------
    logic                 bank_gnt_q  [0:BANKS-1];
    logic [LANE_BITS-1:0] bank_lane_q [0:BANKS-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int b = 0; b < BANKS; b++) bank_gnt_q[b] <= 1'b0;
            for (int i = 0; i < N_THREADS; i++) dt_valid[i] <= 1'b0;
            served <= '0;
        end else begin
            for (int b = 0; b < BANKS; b++) begin
                bank_gnt_q[b]  <= bank_gnt[b];
                bank_lane_q[b] <= bank_gnt_lane[b];
            end
            for (int i = 0; i < N_THREADS; i++) dt_valid[i] <= 1'b0; // default low
            for (int b = 0; b < BANKS; b++)
                if (bank_gnt[b]) dt_valid[bank_gnt_lane[b]] <= 1'b1;

            served <= eff_served | granted_now;
        end
    end

    always_ff @(posedge clk) begin
        for (int b = 0; b < BANKS; b++)
            if (bank_gnt_q[b]) dt_rdata[bank_lane_q[b]] <= bank_rq[b];
    end

    // Display port. disp_bank is delayed to line up with bank_dq, which is a
    // cycle behind the address that produced it.
    logic [BANK_BITS-1:0] disp_bank_q;
    always_ff @(posedge clk) disp_bank_q <= disp_bank;
    assign disp_dt_rdata = bank_dq[disp_bank_q];

endmodule : data_buffer
