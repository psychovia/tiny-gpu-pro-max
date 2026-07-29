# test10_dbuf.s -- exercise the data-buffer instructions: rdtid, setdt, getdt.
#
# Three phases, so a failure points at which instruction is broken rather than
# just "the buffer is wrong":
#
#   1. WRITE   every lane fills its own slice of the buffer with a value that
#              encodes both who wrote it and where: dbuf[i] = i*16 + tid.
#   2. READ    every lane reads its slice back with getdt and accumulates a
#              running sum, so a getdt that returns the wrong element (or the
#              wrong lane's element) shows up as a wrong total in a register.
#   3. STAMP   each lane writes its own checksum into the buffer's tail, at
#              dbuf[DBUF_WORDS - N_LANES + tid], so the testbench can compare
#              the register total and the buffered total.
#
# WORK SPLIT
#   Lane i owns elements i, i+8, i+16, ... -- the natural SIMT stride, and the
#   one data_buffer.sv is banked for: index % 8 == lane_id means each lane hits
#   its own bank, so all 8 are serviced in the SAME cycle instead of queueing
#   through an arbiter one at a time the way shared_mem does.
#
#   Every lane must issue its buffer op on the same instruction, because all 8
#   run in lockstep off one FSM and scheduler.sv will not leave S_MEM_ADDR
#   until every lane has been serviced. Interleaving keeps them in step.
#
# Buffer is 4096 elements (64x64), 8 lanes -> 512 elements per lane.

    rdtid  x5                # x5 = lane_id  (0..7) -- the instruction under test,
                             #      not the x30 preload the older kernels use

    mv   x1, x5              # x1 = current element index, starts at tid
    addi x6, x0, 512         # x6 = iterations left
    addi x7, x0, 0           # x7 = running checksum (phase 2)

# ---- phase 1: write dbuf[i] = i*16 + tid ----------------------------------
    mv   x10, x1             # x10 = write cursor
    addi x11, x0, 512
write_loop:
    slli x12, x10, 4         # i * 16
    add  x12, x12, x5        # + tid    -- encodes both index and writer
    setdt x10, x12
    addi x10, x10, 8         # next element this lane owns
    addi x11, x11, -1
    bne  x11, x0, write_loop

# ---- phase 2: read it all back and total it -------------------------------
read_loop:
    getdt x13, x1
    add  x7, x7, x13         # accumulate
    addi x1, x1, 8
    addi x6, x6, -1
    bne  x6, x0, read_loop

# ---- phase 3: stamp the checksum into the buffer tail ---------------------
# tail index = 4096 - 8 + tid = 4088 + tid, so lane i lands in bank i again.
    li   x14, 4088
    add  x14, x14, x5
    setdt x14, x7

    done
