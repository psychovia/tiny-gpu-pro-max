/**
- instrctions
- frame buffer A - input, to be computed
- frame buffer B - results, to be outputed
- metadata - tid / width / etc

e.g.
apply a foo filter on an image

instruction - stores instr of a function named "foo"
fb_A - source image, indexed by position of pixel, each entry is rgb val of corresponding pixel
fb_B - result image with the filter applied, same structure as fb_A

fb_B[pixel_idx] = filter(fb_A[pixel_idx])

** overwrite in place - one large frame buffer instead of separating A / B
- works if output format / size identical to input

**/

import gpu_pkg::*;

module shared_mem #(
    parameter int    N_THREADS      = gpu_pkg::N_THREADS,
    parameter int    MEM_SIZE_BYTES = gpu_pkg::MEM_SIZE_BYTES,
    parameter string PROG_INIT_FILE = "mems/prog.mem",
    parameter string IMG_INIT_FILE  = "mems/img.mem"
) (
    input  logic         clk, rst,
    input  logic [31:0]  mem_addr  [0:N_THREADS-1], // per-lane address -- named to match core.sv/cpu.sv's mem_addr (was "addr", which .*-instantiation in gpu.sv silently failed to connect since names didn't match)

    // cpu / thread
    input  logic         mem_read  [0:N_THREADS-1],
    input  logic         mem_write [0:N_THREADS-1],
    input  logic [31:0]  mem_wdata [0:N_THREADS-1],
    input  logic [3:0]   byte_en   [0:N_THREADS-1],
    output logic [31:0]  mem_rdata [0:N_THREADS-1],
    output logic         mem_valid [0:N_THREADS-1], // tells lane i that the value sitting in mem_rdata[i] this cycle is your actual requested data and right now is where it's safe to read it

    // display
    input  logic [31:0]  disp_addr, // where does it get this from? display_controller
    output logic [31:0]  disp_rdata
);

    localparam int WORDS = MEM_SIZE_BYTES / 4;

    // ---- storage ----
    logic [31:0] mem [0:WORDS-1];

    initial begin
        // Zero the whole array BEFORE the file loads. $readmemb only writes
        // as many words as the file actually contains, not the full range it
        // is given: prog.mem holds a single instruction but the call below
        // covers PROG_SIZE/4 = 1024 words, so words 1..1023 were left
        // uninitialized (X in simulation -- the red traces in the waveform).
        // That X is also a sim/hardware divergence: on the FPGA this memory
        // powers up to whatever the bitstream loads, real 0s and 1s, so a
        // program running off its end would behave differently on the board
        // than it does here. Zeroing first makes both match and stays correct
        // however large the program file grows.
        for (int i = 0; i < WORDS; i++) mem[i] = '0;

        // loaded as two separate files so program/image can't drift out of sync
        // by hand-merging offsets — see PROG_BASE/IMG_BASE in gpu_pkg.sv
        $readmemb(PROG_INIT_FILE, mem, PROG_BASE/4, PROG_BASE/4 + PROG_SIZE/4 - 1);
        $readmemb(IMG_INIT_FILE, mem, IMG_BASE/4, IMG_BASE/4 + IMG_SIZE_BYTES/4 - 1);
    end

    // ============================================================
    // Port A: arbitration
    // Only one thread can access memory per cycle, so pick exactly
    // one requester ("granted_lane") out of however many have mem_read or mem_write at once.
    //
    // mem_read/mem_write are LEVEL signals -- cpu.sv holds them high for
    // as long as `state` doesn't change, not a one-shot pulse per request.
    // If we always picked the lowest requesting index with no memory of
    // past grants, that lowest lane would win *every* cycle forever and
    // every other lane would starve -- fatal now that the scheduler can
    // stall for many cycles waiting on all 32 lanes to be serviced. So:
    // track "granted_this_round" per lane, exclude already-granted lanes
    // from re-winning, and auto-reset the exclusion set once every
    // currently-requesting lane has had its turn (or nobody's requesting
    // at all) so the next round starts fresh.
    // ============================================================
    logic [$clog2(N_THREADS)-1:0] granted_lane;
    logic                          grant_valid; //is there at least one lane requesting meory right now?

    logic [N_THREADS-1:0] requesting;
    always_comb
        for (int i = 0; i < N_THREADS; i++)
            requesting[i] = mem_read[i] | mem_write[i];

    // Think of granted_this_round as a teacher's checklist: "who have I
    // already called on this round." It only makes sense while that round
    // is still in progress -- once every raised hand has been checked off
    // (or nobody's raising a hand at all), the round is over and the
    // checklist needs to be wiped blank so the *next* batch of requests
    // (e.g. the next instruction's lanes all raising their hands again)
    // isn't wrongly excluded by stale entries from a round that already
    // finished.
    logic [N_THREADS-1:0] granted_this_round;  // persistent checklist: who's already been called on this round
    logic [N_THREADS-1:0] effective_mask;      // prevents the lag that occurs. granted_this_round won't register that round is over until after cycle N's clock edge

    // requesting & ~granted_this_round = "hands raised that AREN'T on the
    // checklist yet." Nonzero means the round is still in progress (someone
    // is still waiting their turn), so keep using the checklist as-is. Zero
    // means the round just finished (or never started) -- wipe it blank so
    // this cycle's requesters are all treated as fresh.
    assign effective_mask = (|(requesting & ~granted_this_round)) ? granted_this_round : '0;

    always_comb begin
        granted_lane = '0;
        grant_valid  = 1'b0;
        for (int i = 0; i < N_THREADS; i++) begin
            // lane requesting, it's not already checked off, and no other lane is already occupying the memory
            if (requesting[i] & ~effective_mask[i] & ~grant_valid) begin
                granted_lane = i[$clog2(N_THREADS)-1:0];
                grant_valid  = 1'b1;
            end
        end
    end

    // ============================================================
    // Port A: drive the granted request into the array, register the
    // response one cycle later (matches synchronous BRAM: address in
    // this cycle, data out next cycle — same behavior cpu.sv's
    // original private `mem` array already had).
    // ============================================================
    // Word index width comes from WORDS, not a hardcoded 14. mem_addr[15:2] is
    // 14 bits wide but `mem` only has WORDS = MEM_SIZE_BYTES/4 = 4096 entries,
    // so a 14-bit index could name words 4096..16383 that do not exist -- an
    // out-of-range write (silently dropped in simulation) and an out-of-range
    // read (X in simulation) that on the FPGA would instead alias back into
    // real memory. Truncating to WIDX_BITS makes both behave the same way,
    // which is the same sim/hardware-parity argument as the pre-zeroing loop
    // above. Addresses at or above WORDS*4 alias rather than vanish; nothing
    // generates one today, and MMIO is neutralized separately in cpu.sv.
    localparam int WIDX_BITS = $clog2(WORDS);

    logic [WIDX_BITS-1:0] word_idx;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < N_THREADS; i++) mem_valid[i] <= 1'b0;
            granted_this_round <= '0;
        end else begin
            for (int i = 0; i < N_THREADS; i++) mem_valid[i] <= 1'b0;  // default low each cycle

            if (grant_valid) begin
                word_idx = mem_addr[granted_lane][WIDX_BITS+1:2];

                if (mem_write[granted_lane]) begin
                    // byte-masked write — same pattern as the original cpu.sv (lines 206-211)
                    if (byte_en[granted_lane][0]) mem[word_idx][7:0]   <= mem_wdata[granted_lane][7:0];
                    if (byte_en[granted_lane][1]) mem[word_idx][15:8]  <= mem_wdata[granted_lane][15:8];
                    if (byte_en[granted_lane][2]) mem[word_idx][23:16] <= mem_wdata[granted_lane][23:16];
                    if (byte_en[granted_lane][3]) mem[word_idx][31:24] <= mem_wdata[granted_lane][31:24];
                end

                // registered outputs -- address goes in this cycle, so this
                // naturally lands in mem_rdata/mem_valid one cycle later
                // (matches synchronous BRAM timing), with no need to track
                // who won arbitration last cycle.
                mem_rdata[granted_lane] <= mem[word_idx];
                mem_valid[granted_lane] <= 1'b1;
            end

            // update the "sign-up sheet" for next cycle: whoever just got
            // granted this cycle gets added to it.
            // | updates granted_this_round by | bit by bit with effective_mask
            granted_this_round <= grant_valid ? (effective_mask | (1 << granted_lane)) : effective_mask;
        end
    end

    // ============================================================
    // Port B: dedicated display read.
    // Always active, no req/valid handshake needed — it's the only
    // user of this port, so there's nothing to arbitrate.
    //
    // Pixels are 3 tightly-packed bytes, so disp_addr rarely lands on a
    // word boundary -- like reaching into cubbies that hold 4 items each
    // for 3 items in a row: if they straddle two cubbies, one grab isn't
    // enough. So grab both the addressed word and the next one, then
    // slice out whichever 3 bytes actually start at disp_addr. Registered
    // the same as before so display_controller.sv still sees 1-cycle latency.
    //
    // The +1 below is why disp_widx is truncated to WIDX_BITS rather than left
    // 14 bits wide: the very last pixel of the image lives in the last word, so
    // "the next word" is one past the end of `mem`. Truncating makes that read
    // wrap to word 0 instead of going out of bounds. The wrapped value is never
    // selected -- a 3-byte pixel starting in the last word has disp_addr[1:0]
    // = 1, so the slice below takes bits 8..31, all of which come from
    // disp_word_lo -- but the array read itself has to be in range regardless.
    // ============================================================
    logic [WIDX_BITS-1:0] disp_widx;
    assign disp_widx = disp_addr[WIDX_BITS+1:2];

    logic [31:0] disp_word_lo, disp_word_hi;
    assign disp_word_lo = mem[disp_widx];
    assign disp_word_hi = mem[WIDX_BITS'(disp_widx + 1'b1)];

    logic [63:0] disp_pair;
    assign disp_pair = {disp_word_hi, disp_word_lo};

    always_ff @(posedge clk) begin
        disp_rdata <= {8'd0, disp_pair[(disp_addr[1:0] * 8) +: 24]};
    end

    // ============================================================
    // TODO(sanity check, sim-only): MMIO addresses are EXPECTED to reach
    // shared_mem now -- cpu.sv deliberately lets an MMIO-targeted lane
    // still get arbitrated/serviced normally (so scheduler.sv's stall
    // logic doesn't hang waiting on a lane that never requests), and
    // instead relies on cpu.sv forcing byte_en to all-zero for MMIO
    // stores so no real bytes ever get written. So this can't check
    // "MMIO never appears here" anymore -- it checks the actual safety
    // contract instead: an MMIO-addressed write must always carry
    // byte_en == 0. If that ever fails, cpu.sv's is_mmio/byte_en
    // neutralization is broken, not this file.
    //
    // Like a museum's "look but don't touch" display case: visitors
    // (requests) are fine to walk up to it (grant_valid) -- that's not
    // suspicious anymore. The alarm only trips if a toucher (mem_write)
    // at that case (MMIO address) actually leaves a smudge on the glass
    // (byte_en nonzero) -- proof cpu.sv didn't wipe their hands first.
    // ============================================================
    // synthesis translate_off
    always_ff @(posedge clk) begin
        if (grant_valid & mem_write[granted_lane] & mem_addr[granted_lane][31:16] != 16'h0000) begin
            assert(byte_en[granted_lane] == 4'b0000)
                else $error("shared_mem saw a real write (byte_en=0x%h) to an MMIO address (0x%h) from lane %0d — cpu.sv should have zeroed byte_en for this",
                            byte_en[granted_lane], mem_addr[granted_lane], granted_lane);
        end
    end
    // synthesis translate_on

    // TODO: $readmemb can't actually overflow past PROG_SIZE into IMG_BASE
    // (it's bounded to that index range) -- but if the compiled program is
    // ever bigger than PROG_SIZE, it silently truncates instead of erroring.
    // Once a real compiler exists, add a loud check (e.g. compare $fread
    // byte count, or a word-count check) so a too-big program errors
    // instead of quietly losing instructions.
    // NEED REAL COMPILER THAT PRODUCES COMPILED PROGRAM IN BINARY B4 CHECK SIZE AGAINST PROG_SIZE

    // TODO: this file assumes N_THREADS pixels total (one thread = one pixel,
    // no block looping yet) — revisit once block id comes back.

endmodule