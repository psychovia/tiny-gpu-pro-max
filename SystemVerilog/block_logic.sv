/**
ARCHIVE ONLY -- not compiled/included into the design.

This is the block-dispatch bookkeeping that used to live inline in
scheduler.sv: cycling through gpu_pkg::NUM_BLOCKS batches of LANES threads
each (block_id, thread_base, last_block/block_lane_mask, start_new_block),
so a single core could cover TOTAL_THREADS > LANES by running one block at
a time. We've decided not to use block logic right now -- scheduler.sv
only ever runs one batch of LANES threads and freezes on kernel_done.

Kept here verbatim for future reference in case multi-block dispatch comes
back. Assumes it's spliced into a scope that already has: clk, rst, state,
done[], kernel_done, thread_base, start_new_block, current_pc, active_mask,
and the LANES/TOTAL_THREADS/N_BLOCKS parameters from scheduler.sv's old
parameter list (LANES = gpu_pkg::N_LANES, TOTAL_THREADS = gpu_pkg::IMG_WIDTH
* gpu_pkg::IMG_HEIGHT, N_BLOCKS = (TOTAL_THREADS + LANES - 1) / LANES) --
none of that is declared in this file.
**/

  // ------------------------------------------------------------------
    // 2. block bookkeeping
    // ------------------------------------------------------------------
    localparam int BLOCK_ID_W = (N_BLOCKS > 1) ? $clog2(N_BLOCKS) : 1;
    logic [BLOCK_ID_W-1:0] block_id;
    logic                  block_done;  // every lane in this block has finished
    logic                  last_block;

    logic [LANES-1:0]      block_lane_mask; // last block = thread % block - may not be full block
    logic [LANES-1:0]      next_block_lane_mask;
    // todo: next block lane mask?

    assign last_block  = (block_id == N_BLOCKS-1);
    assign kernel_done = block_done & last_block;
    assign thread_base = block_id * LANES;

    assign start_new_block = state == S_WRITEBACK && block_done && !last_block;

    always_comb begin
        block_done          = 1'b1;
        block_lane_mask     = '0;
        next_block_lane_mask = '0;

        for (int i = 0; i < LANES; i++) begin
            // valid lanes in current block
            if ((thread_base + i) < TOTAL_THREADS)
                block_lane_mask[i] = 1'b1;

            // valid unfinished lane - the block is not done
            if (block_lane_mask[i] && !done[i])
                block_done = 1'b0;

            // valid lanes in the next block
            if ((((block_id + 1'b1) * LANES) + i) < TOTAL_THREADS)
                next_block_lane_mask[i] = 1'b1;
        end
    end

    // block id
    always_ff @(posedge clk) begin
        if (rst) begin
            block_id <= '0;
        end
        else if (state == S_WRITEBACK && block_done && !last_block) begin
            block_id <= block_id + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // 3. per-lane pc reset on block advance -- spliced into scheduler.sv's
    // current_pc/active_mask always_ff (the S_WRITEBACK branch), guarding
    // the "next block re-runs the kernel from the top" case ahead of the
    // normal within-block handling. Without this, advancing block_id would
    // leave current_pc/active_mask/saved_* holding the finished block's
    // stale values instead of restarting lane 0..LANES-1 at pc 0.
    // ------------------------------------------------------------------
    // else if (state == S_WRITEBACK && block_done && !last_block) begin
    //     current_pc <= '0; // next block re-runs the kernel from the top
    //     active_mask <= '0;
    //
    //     saved_pc <= '0;
    //     saved_mask <= '0;
    //     saved_path_valid <= 1'b0;
    // end
