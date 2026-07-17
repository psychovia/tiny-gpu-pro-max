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

    ** overwrite in place - one large fram buffer instead of separating A / B
    - works if output format / size identical to input

**/

import gpu_pkg::*;

module shared_mem #(
    parameter int    N_THREADS      = gpu_pkg::N_THREADS,
    parameter int    MEM_SIZE_BYTES = gpu_pkg::MEM_SIZE_BYTES,
    parameter string INIT_FILE      = "mems/kernel.mem"
) (
    input logic         clk, rst,
    input logic [31:0]  addr,

    // cpu / thread
    input logic         mem_read,
    input logic         mem_write,
    input logic  [31:0] mem_wdata,
    output logic [31:0] mem_rdata,
    output logic        mem_valid

    // display
    input logic  disp_addr,
    output logic disp_rdata,
);

    localparam int WORDS = MEM_SIZE_BYTES / 4;

    // ---- storage ----
    logic [31:0] mem [0:WORDS-1];

    initial begin
        // loaded as two separate files so program/image can't drift out of sync
        // by hand-merging offsets — see PROG_BASE/IMG_BASE in gpu_pkg.sv
        $readmemb(PROG_INIT_FILE, mem, PROG_BASE/4, PROG_BASE/4 + PROG_SIZE/4 - 1);
        $readmemb(IMG_INIT_FILE,  mem, IMG_BASE/4,  IMG_BASE/4  + IMG_SIZE_BYTES/4 - 1);
    end

    // ============================================================
    // Port A: arbitration
    // Only one thread can access memory per cycle, so pick exactly
    // one requester ("granted_lane") out of however many have req=1.
    // Fixed priority for now (lowest index always wins ties) — fine
    // given a short kernel and roughly-synced threads. Revisit with
    // round-robin only if a thread is observed stalling badly.
    // ============================================================
    logic [$clog2(N_THREADS)-1:0] granted_lane;
    logic                          grant_valid;

    always_comb begin
        granted_lane = '0;
        grant_valid  = 1'b0;
        for (int i = 0; i < N_THREADS; i++) begin
            if (req[i] && !grant_valid) begin
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
    logic [$clog2(N_THREADS)-1:0] granted_lane_prev;
    logic [13:0]                   word_idx;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < N_THREADS; i++) valid[i] <= 1'b0;
        end else begin
            for (int i = 0; i < N_THREADS; i++) valid[i] <= 1'b0;  // default low each cycle

            if (grant_valid) begin
                word_idx = addr[granted_lane][15:2];

                if (we[granted_lane]) begin
                    // byte-masked write — same pattern as the original cpu.sv (lines 206-211)
                    if (byte_en[granted_lane][0]) mem[word_idx][7:0]   <= wdata[granted_lane][7:0];
                    if (byte_en[granted_lane][1]) mem[word_idx][15:8]  <= wdata[granted_lane][15:8];
                    if (byte_en[granted_lane][2]) mem[word_idx][23:16] <= wdata[granted_lane][23:16];
                    if (byte_en[granted_lane][3]) mem[word_idx][31:24] <= wdata[granted_lane][31:24];
                end

                rdata[granted_lane_prev] <= mem[word_idx];
                valid[granted_lane_prev] <= 1'b1;
                granted_lane_prev         <= granted_lane;
            end
        end
    end

    // ============================================================
    // Port B: dedicated display read.
    // Always active, no req/valid handshake needed — it's the only
    // user of this port, so there's nothing to arbitrate.
    // ============================================================
    always_ff @(posedge clk) begin
        disp_rdata <= mem[disp_addr[15:2]];
    end

    // ============================================================
    // TODO(sanity check, sim-only): catch MMIO addresses that leaked
    // through here instead of being intercepted inside cpu.sv. Should
    // never fire if cpu.sv's is_mmio logic is correct — if it does
    // fire, that's a bug in cpu.sv, not here.
    // ============================================================
    // synthesis translate_off
    always_ff @(posedge clk) begin
        if (grant_valid) begin
            assert(addr[granted_lane][31:16] == 16'h0000)
                else $error("shared_mem saw an MMIO address (0x%h) from lane %0d — cpu.sv's MMIO intercept should have caught this",
                            addr[granted_lane], granted_lane);
        end
    end
    // synthesis translate_on

    // TODO: confirm PROG_SIZE in gpu_pkg.sv is larger than the actual compiled
    // kernel binary once it exists — nothing here checks for overflow into IMG_BASE.

    // TODO: this file assumes N_THREADS pixels total (one thread = one pixel,
    // no block looping yet) — revisit once block id comes back.

endmodule