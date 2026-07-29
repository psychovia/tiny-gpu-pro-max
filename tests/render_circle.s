# render_circle.s -- the gpu.c circle kernel, written against this GPU.
#
# Draws a filled white circle on a black 64x64 field, straight into the data
# buffer with setdt. This is the assembly equivalent of gpu.c, adjusted in
# three ways that matter (see the notes at the bottom):
#   * 64x64 geometry, because that is what gpu_pkg.sv's IMG_WIDTH/HEIGHT say
#   * stride N_LANES = 8, not 32, so every pixel gets covered exactly once
#   * BRANCH-FREE per-pixel select, because this core cannot diverge
#
#   inside(x,y):  (x-32)^2 + (y-32)^2 < 12^2
#
# WORK SPLIT
#   Lane i owns pixels i, i+8, i+16, ... -- the stride data_buffer.sv is banked
#   for, so all 8 lanes write in the same cycle instead of queueing.
#
# Registers: x5 = tid, x1 = pixel index, x8 = iteration counter.

    rdtid  x5                # x5 = lane id, 0..7
    mv   x1, x5              # first pixel this lane owns
    li   x8, 512             # 4096 pixels / 8 lanes

    li   x3, 63              # mask for x = i % 64
    li   x4, 32              # circle centre (32, 32)
    li   x6, 144             # radius^2 = 12^2
    li   x7, 0x00ffffff      # white, as data_buffer stores it: 0x00BBGGRR

loop:
    and  x10, x1, x3         # curr_x = i & 63     (i % 64)
    srli x11, x1, 6          # curr_y = i >> 6     (i / 64)

    sub  x12, x10, x4        # dx
    sub  x13, x11, x4        # dy
    mul  x12, x12, x12       # dx*dx
    mul  x13, x13, x13       # dy*dy
    add  x14, x12, x13       # squared distance from the centre

    # Branch-free select. See the NO DIVERGENCE note below -- an if/else here
    # would be silently wrong, not slow.
    slt  x15, x14, x6        # 1 when inside the circle, else 0
    sub  x15, x0, x15        # 0x00000000 or 0xFFFFFFFF
    and  x15, x15, x7        # black or white

    setdt x1, x15            # dbuf[i] = colour

    addi x1, x1, 8           # next pixel this lane owns
    addi x8, x8, -1
    bne  x8, x0, loop

    done

# ---------------------------------------------------------------------------
# NO DIVERGENCE -- the one thing to carry back into gpu.c
#
# gpu.c writes
#
#     if (x_dist + y_dist < allowed) setdt(i, 0); else setdt(i, ~0);
#
# and that cannot work here, however it is compiled. All 8 lanes share one
# program counter: pc.sv resolves every branch from LANE 0's registers only
# (see core.sv's "leader lane" note), so all 8 lanes take whichever way lane 0
# went. A per-pixel `if` therefore paints lane 0's answer onto all 8 pixels.
#
# It is not a stall or a slowdown -- it is a wrong image, and only for pixels
# where the lanes disagree, which is exactly the circle's edge. Anything
# per-pixel has to become arithmetic, the way the slt/sub/and above does.
#
# Two other things in gpu.c to fix while you are there:
#   * `i += 32` should be `i += N_LANES` (8). With 8 lanes and a stride of 32,
#     lanes cover residues 0-7 mod 32 and 24 of every 32 pixels are never
#     written at all.
#   * `x_dist + y_dist < allowed` compares a sum of SIGNED distances against a
#     squared radius. It should be `x_dist_squared + y_dist_squared` -- the
#     squares are computed in gpu.c and then never used.
# ---------------------------------------------------------------------------
