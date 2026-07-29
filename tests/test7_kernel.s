# test7_kernel.s -- the real end-to-end case: a strided data-parallel kernel.
#
# 8 lanes cooperatively transform 32 words of the image region, 4 iterations
# each, striding by N_LANES*4 = 32 bytes so the lanes tile the buffer without
# overlapping:
#
#     lane i, iteration k  ->  word (i + 8*k)
#
# out[j] = 3 * in[j] + 1, in place.
#
# This is the only test that puts loads and stores INSIDE a backward branch,
# which is where the interaction between scheduler.sv's stall bookkeeping and
# shared_mem's per-round grant checklist actually gets stressed: the checklist
# has to reset cleanly between iterations or lane 0 starves everyone.

li   x1, 0x1000         # IMG_BASE
slli x2, x30, 2         # lane_id * 4
add  x3, x1, x2         # this lane's first word

addi x7, x0, 4          # iteration count
addi x8, x0, 3          # multiplier

loop:
lw   x4, 0(x3)
mul  x6, x4, x8
addi x6, x6, 1
sw   x6, 0(x3)
addi x3, x3, 32         # stride N_LANES * 4
addi x7, x7, -1
bne  x7, x0, loop

done
