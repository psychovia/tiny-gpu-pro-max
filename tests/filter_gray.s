# filter_gray.s -- the GPU kernel: convert the 64x64 RGB image to grayscale
#                  in place, using all 8 lanes.
#
#   gray = (77*R + 150*G + 29*B) >> 8
#
# 8-bit fixed-point Rec.601 luma (0.299/0.587/0.114 scaled by 256). Integer
# multiply and shift only -- this core has `mul` but no divide.
#
# WORK SPLIT
#   4096 pixels / 8 lanes = 512 pixels per lane, interleaved rather than
#   block-partitioned: lane i owns pixels i, i+8, i+16, ...
#
#   Interleaved is the right choice here, not a stylistic one. All 8 lanes run
#   in lockstep off one shared FSM, and scheduler.sv will not leave S_MEM_ADDR
#   until every lane has been serviced -- so every lane must issue its memory
#   op on the same instruction. Interleaving keeps all 8 lanes at the same
#   instruction for all 512 iterations. It also keeps the 8 concurrent
#   addresses within a few words of each other.
#
#   Byte address for lane i, iteration k:  IMG_BASE + 3*i + 24*k
#   (3 bytes per pixel, and 8 pixels of stride = 24 bytes)
#
# CONCURRENT WRITES TO ONE WORD ARE SAFE HERE
#   Pixels are 3 bytes, so adjacent lanes' pixels share 32-bit words (pixel 0
#   is bytes 0-2, pixel 1 is bytes 3-5 -- both touch word 0). That is fine:
#   shared_mem grants one lane per cycle and applies byte_en per byte, so two
#   lanes never write the same byte. No lane ever reads a byte another lane
#   writes, either -- each lane only touches its own pixel's 3 bytes.
#
# Registers: x30 = lane_id (preloaded at reset), x31 = done flag.

    li   x1, 0x1000         # IMG_BASE
    addi x3, x0, 3
    mul  x4, x30, x3        # lane_id * 3 bytes
    add  x1, x1, x4         # this lane's first pixel address

    addi x5, x0, 512        # iterations (4096 pixels / 8 lanes)

    addi x6, x0, 77         # luma weights
    addi x7, x0, 150
    addi x8, x0, 29

loop:
    lbu  x10, 0(x1)         # R
    lbu  x11, 1(x1)         # G
    lbu  x12, 2(x1)         # B

    mul  x13, x10, x6
    mul  x14, x11, x7
    mul  x15, x12, x8
    add  x16, x13, x14
    add  x16, x16, x15
    srli x16, x16, 8        # >> 8, so the result is already 0..255

    sb   x16, 0(x1)         # write grey back over R, G and B
    sb   x16, 1(x1)
    sb   x16, 2(x1)

    addi x1, x1, 24         # next pixel for this lane (8 pixels ahead)
    addi x5, x5, -1
    bne  x5, x0, loop

    done
